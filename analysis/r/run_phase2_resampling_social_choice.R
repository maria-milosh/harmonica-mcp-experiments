options(stringsAsFactors = FALSE)

suppressPackageStartupMessages({
  library(readr)
  library(dplyr)
  library(tidyr)
  library(purrr)
  library(ggplot2)
  library(stringr)
})


group_size <- 5L

# participant_changes <- read_csv(file.path(root_dir, "output", "phase2_participant_changes.csv"), show_col_types = FALSE)

parse_ranking <- function(ranking_string) {
  if (is.na(ranking_string) || ranking_string == "") {
    return(character(0))
  }
  str_split(ranking_string, " > ", simplify = FALSE)[[1]]
}

plurality_winner <- function(rankings) {
  top_choices <- map_chr(rankings, ~ if (length(.x) > 0) .x[1] else NA_character_)
  top_choices <- top_choices[!is.na(top_choices)]
  if (length(top_choices) == 0) { return(NA_character_) }
  tally <- table(top_choices)
  winners <- names(tally)[tally == max(tally)]
  if (length(winners) == 1) winners else NA_character_
}

condorcet_winner <- function(rankings, options) {
  n <- length(rankings)
  for (cand in options) {
    beats_all <- TRUE
    for (opp in options[options != cand]) {
      cand_votes <- sum(map_lgl(rankings, ~ match(cand, .x) < match(opp, .x)))
      if (cand_votes <= n / 2) {
        beats_all <- FALSE
        break
      }
    }
    if (beats_all) {
      return(cand)
    }
  }
  NA_character_
}

ids <- unique(participant_changes$user_id)
if (length(ids) < group_size) {
  stop("Not enough participants for requested synthetic group size.")
}

all_group_matrix <- combn(ids, group_size)
n_unique_groups <- ncol(all_group_matrix)

group_index <- seq_len(n_unique_groups)
synthetic_groups <- lapply(group_index, function(i) all_group_matrix[, i])

initial_lookup <- setNames(participant_changes$initial_ranking, participant_changes$user_id)
final_lookup <- setNames(participant_changes$final_ranking, participant_changes$user_id)
option_set <- sort(unique(unlist(map(participant_changes$initial_ranking, parse_ranking))))
initial_parsed <- setNames(map(initial_lookup, parse_ranking), names(initial_lookup))
final_parsed <- setNames(map(final_lookup, parse_ranking), names(final_lookup))

evaluate_group <- function(group_ids, phase_label) {
  rankings <- if (phase_label == "before") {
    unname(initial_parsed[group_ids])
  } else {
    unname(final_parsed[group_ids])
  }
  cw <- condorcet_winner(rankings, option_set)
  pl <- plurality_winner(rankings)
  cw_exists <- !is.na(cw)
  match <- cw_exists && !is.na(pl) && (pl == cw)
  tibble(
    phase = phase_label,
    condorcet_exists = cw_exists,
    condorcet_winner = if_else(cw_exists, cw, NA_character_),
    group_outcome_rule = "plurality",
    group_outcome = pl,
    outcome_matches_condorcet = match
  )
}

group_rows <- vector("list", length = n_unique_groups * 2)
row_idx <- 1L
for (i in seq_len(n_unique_groups)) {
  g <- synthetic_groups[[i]]
  group_members <- paste(g, collapse = ",")

  before_row <- evaluate_group(g, "before") %>%
    mutate(
      synthetic_group_id = i,
      sampled_from_unique_group = group_index[i],
      group_members = group_members
    )

  after_row <- evaluate_group(g, "after") %>%
    mutate(
      synthetic_group_id = i,
      sampled_from_unique_group = group_index[i],
      group_members = group_members
    )

  group_rows[[row_idx]] <- before_row
  group_rows[[row_idx + 1L]] <- after_row
  row_idx <- row_idx + 2L
}

group_results <- bind_rows(group_rows) %>%
  relocate(synthetic_group_id, sampled_from_unique_group, group_members, phase)

write_csv(group_results, file.path(output_dir, "phase2_resampling_group_results.csv"))

phase_summary <- group_results %>%
  group_by(phase) %>%
  summarise(
    n_groups = n(),
    p_condorcet_exists = mean(condorcet_exists),
    p_outcome_equals_condorcet = mean(outcome_matches_condorcet),
    p_outcome_equals_condorcet_given_exists = if_else(
      sum(condorcet_exists) > 0,
      mean(outcome_matches_condorcet[condorcet_exists]),
      NA_real_
    ),
    .groups = "drop"
  )

write_csv(phase_summary, file.path(output_dir, "phase2_resampling_phase_summary.csv"))

wide_eval <- group_results %>%
  select(synthetic_group_id, phase, condorcet_exists, outcome_matches_condorcet) %>%
  pivot_wider(
    names_from = phase,
    values_from = c(condorcet_exists, outcome_matches_condorcet),
    names_glue = "{.value}_{phase}"
  )

calc_delta_metrics <- function(df) {
  tibble(
    metric = c(
      "P(outcome = Condorcet winner)",
      "P(outcome = Condorcet winner | Condorcet exists)",
      "P(Condorcet winner exists)"
    ),
    delta_after_minus_before = c(
      mean(df$outcome_matches_condorcet_after) - mean(df$outcome_matches_condorcet_before),
      (sum(df$outcome_matches_condorcet_after & df$condorcet_exists_after) / sum(df$condorcet_exists_after)) -
        (sum(df$outcome_matches_condorcet_before & df$condorcet_exists_before) / sum(df$condorcet_exists_before)),
      mean(df$condorcet_exists_after) - mean(df$condorcet_exists_before)
    )
  )
}

delta_point <- calc_delta_metrics(wide_eval)
delta_summary <- delta_point %>%
  arrange(desc(abs(delta_after_minus_before)))

write_csv(delta_summary, file.path(output_dir, "phase2_resampling_delta_summary.csv"))

condorcet_winner_distribution <- group_results %>%
  filter(condorcet_exists) %>%
  count(phase, condorcet_winner, name = "n_groups") %>%
  group_by(phase) %>%
  mutate(share = n_groups / sum(n_groups)) %>%
  ungroup() %>%
  arrange(phase, desc(n_groups))

write_csv(condorcet_winner_distribution, file.path(output_dir, "phase2_resampling_condorcet_winner_distribution.csv"))

plot_data <- phase_summary %>%
  transmute(
    phase,
    `P(outcome = Condorcet winner)` = p_outcome_equals_condorcet,
    `P(outcome = Condorcet winner | Condorcet exists)` = p_outcome_equals_condorcet_given_exists,
    `P(Condorcet winner exists)` = p_condorcet_exists
  ) %>%
  pivot_longer(-phase, names_to = "metric", values_to = "probability")

plot_prob <- ggplot(plot_data, aes(x = phase, y = probability, fill = phase)) +
  geom_col(width = 0.65, alpha = 0.9) +
  facet_wrap(~ metric, ncol = 1) +
  scale_fill_manual(values = c("before" = "#0f766e", "after" = "#dc2626")) +
  scale_y_continuous(labels = scales::percent_format(accuracy = 1)) +
  labs(
    title = "Social Choice Over All 5-Person Synthetic Groups",
    subtitle = paste0(
      "Exhaustive evaluation of all ", n_unique_groups, " combinations (17 choose 5)"
    ),
    x = NULL,
    y = "Probability",
    fill = NULL
  ) +
  theme_minimal(base_size = 12) +
  theme(
    strip.text = element_text(face = "bold"),
    legend.position = "none",
    panel.grid.minor = element_blank(),
    plot.title = element_text(face = "bold", size = 15)
  )

ggsave(
  filename = file.path(output_dir, "phase2_resampling_probability_comparison.png"),
  plot = plot_prob,
  width = 10,
  height = 9,
  dpi = 180
)

plot_delta <- ggplot(delta_summary, aes(x = delta_after_minus_before, y = reorder(metric, delta_after_minus_before))) +
  geom_vline(xintercept = 0, linetype = "dashed", color = "#9ca3af") +
  geom_col(fill = "#2563eb", width = 0.55, alpha = 0.9) +
  scale_x_continuous(labels = scales::percent_format(accuracy = 0.1)) +
  labs(
    title = "Exact After - Before Effect on Condorcet Alignment",
    subtitle = "Computed across all 6188 synthetic groups",
    x = "Probability difference (after minus before)",
    y = NULL
  ) +
  theme_minimal(base_size = 12) +
  theme(
    panel.grid.minor = element_blank(),
    plot.title = element_text(face = "bold", size = 15)
  )

ggsave(
  filename = file.path(output_dir, "phase2_resampling_delta_effects.png"),
  plot = plot_delta,
  width = 10,
  height = 5,
  dpi = 180
)

notes <- c(
  "# Exhaustive Social Choice Analysis",
  "",
  "## Setup",
  paste0("- Participants in source pool: ", length(ids)),
  paste0("- Synthetic group size: ", group_size),
  paste0("- Unique 5-person groups: ", n_unique_groups),
  "- Group generation: exhaustive (all combinations, no sampling)",
  paste0("- Outcome rule for group choice: plurality"),
  "",
  "## Main estimands",
  "- P(group outcome = Condorcet winner) difference: after - before",
  "- P(group outcome = Condorcet winner | Condorcet exists) difference: after - before",
  "- Condorcet existence probability difference: after - before",
  "",
  "## Point estimates (after - before)"
)

for (i in seq_len(nrow(delta_summary))) {
  row <- delta_summary[i, ]
  notes <- c(
    notes,
    paste0(
      "- ", row$metric, ": ",
      sprintf("%.4f", row$delta_after_minus_before)
    )
  )
}

writeLines(notes, con = file.path(output_dir, "phase2_resampling_notes.md"))

cat("Wrote resampling social-choice outputs to", output_dir, "\n")
