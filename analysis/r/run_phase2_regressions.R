options(stringsAsFactors = FALSE)

suppressPackageStartupMessages({
  library(readr)
  library(dplyr)
  library(ggplot2)
  library(broom)
})
pacman::p_load(here, tidyverse, modelsummary, fixest, kableExtra, marginaleffects)


root_dir <- file.path('Documents/GitHub/harmonica-mcp-experiments/analysis')
setwd(root_dir)


participant_changes <- read_csv("output/phase2_participant_changes.csv")
participant_stats <- read_csv(file.path("output", "phase2_participant_stats.csv"), show_col_types = FALSE)
reasoning_shift <- read_csv(file.path("output", "phase2_reasoning_shift.csv"), show_col_types = FALSE)
embedding_shift <- read_csv(file.path("output", "phase2_reasoning_embedding_shift.csv"), show_col_types = FALSE)

rank_of <- function(ranking_string, option) {
  parts <- strsplit(ranking_string, " > ", fixed = TRUE)[[1]]
  match_value <- match(option, parts)
  if (is.na(match_value)) {
    return(NA_integer_)
  }
  match_value
}

analysis_df <- participant_changes %>%
  left_join(
    participant_stats %>%
      select(
        user_id,
        participant_name,
        user_word_count,
        assistant_word_count,
        message_count,
        assistant_question_count,
        duration_minutes
      ),
    by = "user_id"
  ) %>%
  left_join(
    reasoning_shift %>%
      select(
        user_id,
        lexical_jaccard_similarity,
        themes_added,
        themes_removed,
        themes_retained
      ),
    by = "user_id"
  ) %>%
  left_join(
    embedding_shift %>%
      select(
        user_id,
        embedding_cosine_similarity,
        embedding_shift_intensity
      ),
    by = "user_id"
  ) %>%
  mutate(
    changed_top_choice_num = as.integer(changed_top_choice),
    initial_clinic_rank = vapply(initial_ranking, rank_of, integer(1), option = "community_clinic"),
    final_clinic_rank = vapply(final_ranking, rank_of, integer(1), option = "community_clinic"),
    clinic_rank_gain = initial_clinic_rank - final_clinic_rank,
    initial_not_clinic = as.integer(initial_top_choice != "community_clinic"),
    log_user_word_count = log(pmax(user_word_count, 1)),
    z_embedding_shift = as.numeric(scale(embedding_shift_intensity)),
    z_lexical_similarity = as.numeric(scale(lexical_jaccard_similarity)),
    z_log_user_word_count = as.numeric(scale(log_user_word_count)),
    z_duration_minutes = as.numeric(scale(duration_minutes))
  )

write_csv(analysis_df, file.path(output_dir, "phase2_regression_dataset.csv"))

model_specs <- list(
  changed_top_lpm = list(
    formula = changed_top_choice_num ~ z_embedding_shift + z_lexical_similarity + z_log_user_word_count + z_duration_minutes,
    label = "Top-choice change (LPM)"
  ),
  footrule_ols = list(
    formula = footrule_distance ~ z_embedding_shift + z_lexical_similarity + z_log_user_word_count + z_duration_minutes,
    label = "Ranking distance (OLS)"
  ),
  clinic_gain_ols = list(
    formula = clinic_rank_gain ~ z_embedding_shift + z_lexical_similarity + z_log_user_word_count + initial_not_clinic,
    label = "Clinic rank gain (OLS)"
  )
)

fit_model <- function(spec, data) {
  lm(spec$formula, data = data)
}

models <- lapply(model_specs, fit_model, data = analysis_df)

summaries <- lapply(names(models), function(name) {
  model <- models[[name]]
  glance_row <- broom::glance(model)
  tibble(
    model = name,
    label = model_specs[[name]]$label,
    n = nrow(analysis_df),
    r_squared = if ("r.squared" %in% names(glance_row)) glance_row$r.squared else NA_real_,
    adj_r_squared = if ("adj.r.squared" %in% names(glance_row)) glance_row$adj.r.squared else NA_real_,
    aic = if ("AIC" %in% names(glance_row)) glance_row$AIC else NA_real_,
    bic = if ("BIC" %in% names(glance_row)) glance_row$BIC else NA_real_
  )
}) %>%
  bind_rows()

write_csv(summaries, file.path(output_dir, "phase2_regression_model_summary.csv"))

coef_rows <- lapply(names(models), function(name) {
  model <- models[[name]]
  label <- model_specs[[name]]$label
  tidy_row <- broom::tidy(model, conf.int = TRUE, conf.level = 0.95)
  tidy_row$model <- name
  tidy_row$model_label <- label
  tidy_row
}) %>%
  bind_rows() %>%
  filter(term != "(Intercept)") %>%
  mutate(
    term_label = recode(
      term,
      z_embedding_shift = "Embedding shift intensity (z)",
      z_lexical_similarity = "Lexical similarity (z)",
      z_log_user_word_count = "User word count (log, z)",
      z_duration_minutes = "Conversation duration (z)",
      initial_not_clinic = "Initial top choice was not clinic"
    )
  )

write_csv(coef_rows, file.path(output_dir, "phase2_regression_coefficients.csv"))

coef_plot <- ggplot(coef_rows, aes(x = estimate, y = reorder(term_label, estimate), xmin = conf.low, xmax = conf.high, color = model_label)) +
  geom_vline(xintercept = 0, linetype = "dashed", color = "#9ca3af") +
  geom_errorbarh(height = 0.16, position = position_dodge(width = 0.7), linewidth = 0.7) +
  geom_point(position = position_dodge(width = 0.7), size = 2.7) +
  facet_wrap(~ model_label, scales = "free_x") +
  scale_color_manual(values = c("#2563eb", "#d97706", "#0f766e")) +
  labs(
    title = "Phase 2 regression coefficients",
    subtitle = "Descriptive small-sample regressions; confidence intervals are wide and should be interpreted cautiously",
    x = "Coefficient estimate",
    y = NULL,
    color = NULL,
    caption = "Models use N = 17 participants. Outcomes: top-choice change, footrule ranking distance, and clinic rank gain."
  ) +
  theme_minimal(base_size = 12) +
  theme(
    legend.position = "none",
    panel.grid.minor = element_blank(),
    strip.text = element_text(face = "bold"),
    plot.title = element_text(face = "bold", size = 16)
  )

ggsave(
  filename = file.path(output_dir, "phase2_regression_coefficients.png"),
  plot = coef_plot,
  width = 12,
  height = 7,
  dpi = 180
)

model_text <- lapply(names(models), function(name) {
  capture.output(summary(models[[name]]))
})
names(model_text) <- names(models)
writeLines(
  unlist(
    lapply(names(model_text), function(name) {
      c(
        paste0("===== ", model_specs[[name]]$label, " ====="),
        model_text[[name]],
        ""
      )
    })
  ),
  con = file.path(output_dir, "phase2_regression_summaries.txt")
)

report_lines <- c(
  "# Phase 2 Regression Notes",
  "",
  "These models are descriptive and should be interpreted cautiously.",
  "",
  paste0("- Sample size: ", nrow(analysis_df), " participants"),
  paste0("- Top-choice changers: ", sum(analysis_df$changed_top_choice_num)),
  "- Standardized predictors make coefficient magnitudes more comparable across models.",
  "- The linear probability model is used for top-choice change because the event count is very low.",
  "- The OLS models for footrule distance and clinic rank gain are exploratory, not confirmatory.",
  "",
  "## Models",
  "",
  "1. Top-choice change (LPM): whether the participant changed their top-ranked option.",
  "2. Ranking distance (OLS): how much the full ranking changed, measured by footrule distance.",
  "3. Clinic rank gain (OLS): how much `community_clinic` moved up in the participant's ranking.",
  "",
  "## Included predictors",
  "",
  "- Embedding shift intensity",
  "- Lexical similarity",
  "- User word count",
  "- Conversation duration",
  "- Initial top choice not clinic indicator (clinic gain model only)"
)
writeLines(report_lines, con = file.path(output_dir, "phase2_regression_notes.md"))

cat("Wrote R regression outputs to", output_dir, "\n")
