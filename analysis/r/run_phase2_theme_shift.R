options(stringsAsFactors = FALSE)

suppressPackageStartupMessages({
  library(readr)
  library(dplyr)
  library(tidyr)
  library(stringr)
  library(purrr)
  library(ggplot2)
  library(broom)
})

script_arg <- commandArgs(trailingOnly = FALSE)[grep("^--file=", commandArgs(trailingOnly = FALSE))]
script_path <- sub("^--file=", "", script_arg[1])
root_dir <- normalizePath(file.path(dirname(script_path), ".."), mustWork = TRUE)
output_dir <- file.path(root_dir, "output", "r")
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

reasoning_shift <- read_csv(file.path(root_dir, "output", "phase2_reasoning_shift.csv"), show_col_types = FALSE)
participant_changes <- read_csv(file.path(root_dir, "output", "phase2_participant_changes.csv"), show_col_types = FALSE)

parse_theme_list <- function(value) {
  if (is.na(value) || value == "") {
    return(character(0))
  }
  parts <- str_split(value, ",\\s*")[[1]]
  parts[nzchar(parts)]
}

reasoning_lists <- reasoning_shift %>%
  transmute(
    user_id,
    initial_theme_list = map(initial_themes, parse_theme_list),
    final_theme_list = map(final_themes, parse_theme_list)
  )

observed_theme_catalog <- reasoning_lists %>%
  transmute(all_themes = map2(initial_theme_list, final_theme_list, ~ unique(c(.x, .y)))) %>%
  pull(all_themes) %>%
  unlist(use.names = FALSE) %>%
  unique() %>%
  sort()

# Keep this canonical catalog in sync with reasoning_analysis.py (THEME_KEYWORDS).
canonical_theme_catalog <- c(
  "urgency_basic_needs",
  "cost_effectiveness_impact",
  "fairness_equity",
  "long_term_structural",
  "short_term_relief",
  "local_community_focus",
  "global_scale_impact",
  "personal_connection_identity",
  "moral_duty_compassion",
  "tradeoffs_balancing",
  "skepticism_uncertainty",
  "effectiveness_skepticism",
  "deservingness_targeting",
  "visibility_salience"
)

theme_catalog <- sort(unique(c(canonical_theme_catalog, observed_theme_catalog)))

build_theme_vectors <- function(df, list_col_name, phase_label) {
  base <- df %>%
    transmute(
      user_id,
      theme_list = .data[[list_col_name]],
      total_matches = lengths(.data[[list_col_name]])
    )

  detected <- base %>%
    transmute(user_id, theme = theme_list) %>%
    unnest(theme, keep_empty = FALSE) %>%
    distinct(user_id, theme) %>%
    mutate(match = 1)

  crossing(user_id = unique(base$user_id), theme = theme_catalog) %>%
    left_join(detected, by = c("user_id", "theme")) %>%
    left_join(base %>% select(user_id, total_matches), by = "user_id") %>%
    mutate(
      match = if_else(is.na(match), 0, match),
      # Option A: normalize by total theme matches in each reasoning text.
      weight = if_else(total_matches > 0, match / total_matches, 0),
      phase = phase_label
    ) %>%
    select(user_id, phase, theme, match, total_matches, weight)
}

initial_vectors <- build_theme_vectors(reasoning_lists, "initial_theme_list", "initial")
final_vectors <- build_theme_vectors(reasoning_lists, "final_theme_list", "final")

write_csv(initial_vectors, file.path(output_dir, "phase2_theme_vectors_initial_long.csv"))
write_csv(final_vectors, file.path(output_dir, "phase2_theme_vectors_final_long.csv"))

wide_initial <- initial_vectors %>%
  select(user_id, theme, weight) %>%
  pivot_wider(names_from = theme, values_from = weight)
wide_final <- final_vectors %>%
  select(user_id, theme, weight) %>%
  pivot_wider(names_from = theme, values_from = weight)

write_csv(wide_initial, file.path(output_dir, "phase2_theme_vectors_initial_wide.csv"))
write_csv(wide_final, file.path(output_dir, "phase2_theme_vectors_final_wide.csv"))

within_person <- initial_vectors %>%
  select(user_id, theme, initial_match = match, initial_weight = weight) %>%
  left_join(
    final_vectors %>% select(user_id, theme, final_match = match, final_weight = weight),
    by = c("user_id", "theme")
  ) %>%
  mutate(
    delta = final_weight - initial_weight,
    abs_delta = abs(delta)
  )

write_csv(within_person, file.path(output_dir, "phase2_theme_within_person_change.csv"))

theme_aggregate <- within_person %>%
  group_by(theme) %>%
  summarise(
    mean_initial_weight = mean(initial_weight),
    mean_final_weight = mean(final_weight),
    mean_delta = mean(delta),
    mean_abs_delta = mean(abs_delta),
    share_initial_present = mean(initial_match > 0),
    share_final_present = mean(final_match > 0),
    .groups = "drop"
  ) %>%
  arrange(desc(mean_abs_delta))

write_csv(theme_aggregate, file.path(output_dir, "phase2_theme_aggregate_summary.csv"))

wilcoxon_theme <- within_person %>%
  group_by(theme) %>%
  group_modify(~ {
    test <- tryCatch(
      wilcox.test(.x$final_weight, .x$initial_weight, paired = TRUE, exact = FALSE),
      error = function(e) NULL
    )
    tibble(
      n = nrow(.x),
      median_delta = median(.x$delta),
      statistic = if (!is.null(test)) unname(test$statistic) else NA_real_,
      p_value = if (!is.null(test)) test$p.value else NA_real_
    )
  }) %>%
  ungroup() %>%
  mutate(p_value_fdr = p.adjust(p_value, method = "fdr")) %>%
  arrange(p_value_fdr, desc(abs(median_delta)))

write_csv(wilcoxon_theme, file.path(output_dir, "phase2_theme_wilcoxon_by_theme.csv"))

participant_l1 <- within_person %>%
  group_by(user_id) %>%
  summarise(
    l1_distance = sum(abs_delta),
    .groups = "drop"
  ) %>%
  left_join(
    participant_changes %>% select(user_id, changed_top_choice),
    by = "user_id"
  )

global_l1 <- mean(participant_l1$l1_distance)
global_l1_median <- median(participant_l1$l1_distance)

global_l1_test <- tryCatch(
  wilcox.test(participant_l1$l1_distance, mu = 0, alternative = "greater", exact = FALSE),
  error = function(e) NULL
)

global_metrics <- tibble(
  participant_n = nrow(participant_l1),
  theme_n = length(theme_catalog),
  mean_l1_distance = global_l1,
  median_l1_distance = global_l1_median,
  wilcoxon_l1_vs_zero_statistic = if (!is.null(global_l1_test)) unname(global_l1_test$statistic) else NA_real_,
  wilcoxon_l1_vs_zero_p = if (!is.null(global_l1_test)) global_l1_test$p.value else NA_real_
)

write_csv(participant_l1, file.path(output_dir, "phase2_theme_participant_l1.csv"))
write_csv(global_metrics, file.path(output_dir, "phase2_theme_global_metrics.csv"))

theme_plot <- theme_aggregate %>%
  mutate(theme = factor(theme, levels = rev(theme)))

plot_theme_shift <- ggplot(theme_plot, aes(y = theme)) +
  geom_segment(
    aes(x = mean_initial_weight, xend = mean_final_weight, yend = theme),
    color = "#cbd5e1",
    linewidth = 1.2
  ) +
  geom_point(aes(x = mean_initial_weight), color = "#0f766e", size = 2.8) +
  geom_point(aes(x = mean_final_weight), color = "#dc2626", size = 2.8) +
  labs(
    title = "Theme Shift: Initial vs Final Mean Weights",
    subtitle = "Theme vectors normalized by total theme matches per reasoning text",
    x = "Mean normalized theme weight",
    y = NULL,
    caption = "Teal = initial, red = final"
  ) +
  theme_minimal(base_size = 12) +
  theme(
    panel.grid.minor = element_blank(),
    plot.title = element_text(face = "bold", size = 15)
  )

ggsave(
  filename = file.path(output_dir, "phase2_theme_shift_dumbbell.png"),
  plot = plot_theme_shift,
  width = 11,
  height = 7,
  dpi = 180
)

participant_plot_data <- participant_l1 %>%
  arrange(desc(l1_distance)) %>%
  mutate(user_id = factor(user_id, levels = rev(user_id)))

plot_l1 <- ggplot(participant_plot_data, aes(y = user_id, x = l1_distance, color = changed_top_choice)) +
  geom_segment(aes(x = 0, xend = l1_distance, yend = user_id), color = "#cbd5e1", linewidth = 1) +
  geom_point(size = 3) +
  geom_vline(xintercept = global_l1, linetype = "dashed", color = "#d97706", linewidth = 0.8) +
  scale_color_manual(values = c("FALSE" = "#2563eb", "TRUE" = "#dc2626")) +
  labs(
    title = "Participant-Level Global Reasoning Shift (L1)",
    subtitle = "L1 distance between each participant's initial and final theme vectors",
    x = "L1 distance (sum of absolute theme-weight changes)",
    y = "Participant",
    color = "Changed top choice"
  ) +
  theme_minimal(base_size = 12) +
  theme(
    panel.grid.minor = element_blank(),
    plot.title = element_text(face = "bold", size = 15)
  )

ggsave(
  filename = file.path(output_dir, "phase2_theme_shift_l1_lollipop.png"),
  plot = plot_l1,
  width = 11,
  height = 7,
  dpi = 180
)

notes_lines <- c(
  "# Phase 2 Theme Shift Pipeline",
  "",
  "## Steps implemented",
  "1. Reasoning -> normalized theme vectors (Option A: divide by total theme matches).",
  "2. Within-person change per theme (delta and abs delta).",
  "3. Aggregate change across participants (means and presence shares).",
  "4. Wilcoxon signed-rank tests by theme (paired initial vs final weights).",
  "5. Global reasoning-shift metric: participant-level L1 distance.",
  "6. Global Wilcoxon test: is L1 distance greater than 0?",
  "7. Visual outputs for theme-level and participant-level shifts.",
  "",
  "## Key global metrics",
  paste0("- Participants: ", global_metrics$participant_n),
  paste0("- Themes: ", global_metrics$theme_n),
  paste0("- Mean L1 distance: ", round(global_metrics$mean_l1_distance, 4)),
  paste0("- Median L1 distance: ", round(global_metrics$median_l1_distance, 4)),
  paste0("- Wilcoxon(L1 > 0) p-value: ", signif(global_metrics$wilcoxon_l1_vs_zero_p, 4))
)

writeLines(notes_lines, con = file.path(output_dir, "phase2_theme_shift_notes.md"))

cat("Wrote theme-shift outputs to", output_dir, "\n")
