options(stringsAsFactors = FALSE)

suppressPackageStartupMessages({
  library(readr)
  library(dplyr)
  library(tidyr)
  library(purrr)
  library(tibble)
})

# Optional for closed-form power calculations when placeholders are filled.
if (!requireNamespace("pwr", quietly = TRUE)) {
  message("Package 'pwr' is not installed. Placeholder mode is still available.")
}

script_args <- commandArgs(trailingOnly = FALSE)
script_arg <- script_args[grep("^--file=", script_args)]
script_path <- if (length(script_arg) > 0) sub("^--file=", "", script_arg[1]) else NA_character_

# Build candidate roots so the script works in all modes:
# - Rscript analysis/r/run_power_analysis_scaffold.R
# - source("analysis/r/run_power_analysis_scaffold.R")
# - line-by-line execution from the repo root in an interactive R terminal
candidate_roots <- character(0)
if (!is.na(script_path) && nzchar(script_path)) {
  candidate_roots <- c(
    candidate_roots,
    file.path(dirname(script_path), ".."),
    file.path(dirname(script_path), "..", "..")
  )
}

cwd <- getwd()
candidate_roots <- c(
  candidate_roots,
  cwd,
  file.path(cwd, "analysis"),
  file.path(cwd, "..", "analysis")
)

candidate_roots <- unique(normalizePath(candidate_roots, winslash = "/", mustWork = FALSE))
required_inputs <- c(
  "output/phase2_reasoning_embedding_shift.csv",
  "output/phase2_participant_changes.csv",
  "output/r/phase2_theme_participant_l1.csv",
  "output/r/phase2_resampling_group_results.csv"
)

root_dir <- NA_character_
for (candidate in candidate_roots) {
  if (all(file.exists(file.path(candidate, required_inputs)))) {
    root_dir <- candidate
    break
  }
}

if (is.na(root_dir)) {
  stop(
    "Could not infer root_dir. Checked candidates:\n",
    paste0(" - ", candidate_roots, collapse = "\n"),
    "\nExpected inputs under <root>/output and <root>/output/r."
  )
}

output_dir <- file.path(root_dir, "output", "r")
# dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

# --- Pilot inputs -------------------------------------------------------------

embedding_shift <- read_csv(
  file.path(root_dir, "output", "phase2_reasoning_embedding_shift.csv"),
  show_col_types = FALSE
)

participant_changes <- read_csv(
  file.path(root_dir, "output", "phase2_participant_changes.csv"),
  show_col_types = FALSE
)

theme_shift <- read_csv(
  file.path(root_dir, "output", "r", "phase2_theme_participant_l1.csv"),
  show_col_types = FALSE
)

group_resampling <- read_csv(
  file.path(root_dir, "output", "r", "phase2_resampling_group_results.csv"),
  show_col_types = FALSE
)

pilot_summary <- list(
  cosine_shift = embedding_shift %>%
    summarise(
      n = n(),
      mean = mean(embedding_shift_intensity, na.rm = TRUE),
      sd = sd(embedding_shift_intensity, na.rm = TRUE)
    ),
  ranking_l1_shift = participant_changes %>%
    summarise(
      n = n(),
      mean = mean(footrule_distance, na.rm = TRUE),
      sd = sd(footrule_distance, na.rm = TRUE)
    ),
  theme_l1_shift = theme_shift %>%
    summarise(
      n = n(),
      mean = mean(l1_distance, na.rm = TRUE),
      sd = sd(l1_distance, na.rm = TRUE)
    ),
  condorcet_efficiency = group_resampling %>%
    mutate(
      condorcet_exists = as.logical(condorcet_exists),
      outcome_matches_condorcet = as.logical(outcome_matches_condorcet)
    ) %>%
    filter(condorcet_exists) %>%
    group_by(phase) %>%
    summarise(
      groups = n(),
      efficiency = mean(outcome_matches_condorcet, na.rm = TRUE),
      .groups = "drop"
    )
)

# --- Analysis assumptions (fill these from pilot estimates / design choices) --

power_spec <- tribble(
  ~outcome_id, ~level, ~outcome_label, ~test_family, ~alpha, ~power, ~min_effect, ~pilot_sd, ~pilot_p_before, ~pilot_p_after, ~cluster_size, ~icc,
  "cosine_shift", "individual", "Cosine difference shift after cross-pollination", "paired_continuous", 0.05, 0.80, NA_real_, NA_real_, NA_real_, NA_real_, NA_real_, NA_real_,
  "ranking_l1_shift", "individual", "L1 shift in rankings", "paired_continuous", 0.05, 0.80, NA_real_, NA_real_, NA_real_, NA_real_, NA_real_, NA_real_,
  "theme_l1_shift", "individual", "L1 shift in themes mentioned", "paired_continuous", 0.05, 0.80, NA_real_, NA_real_, NA_real_, NA_real_, NA_real_, NA_real_,
  "condorcet_efficiency", "group", "Condorcet efficiency (5-person permutations)", "clustered_binary_diff", 0.05, 0.80, NA_real_, NA_real_, NA_real_, NA_real_, 5, NA_real_
)

# Auto-fill Condorcet pilot probabilities from observed resampling efficiency.
p_before <- pilot_summary$condorcet_efficiency %>%
  filter(phase == "before") %>%
  pull(efficiency)
p_after <- pilot_summary$condorcet_efficiency %>%
  filter(phase == "after") %>%
  pull(efficiency)

power_spec <- power_spec %>%
  mutate(
    pilot_p_before = if_else(
      outcome_id == "condorcet_efficiency" & length(p_before) > 0,
      p_before[[1]],
      pilot_p_before
    ),
    pilot_p_after = if_else(
      outcome_id == "condorcet_efficiency" & length(p_after) > 0,
      p_after[[1]],
      pilot_p_after
    )
  )

# min_effect means:
# - paired_continuous: standardized paired effect size dz to detect.
# - clustered_binary_diff: absolute difference in Condorcet efficiency (p_after - p_before).

# --- Scaffold calculators -----------------------------------------------------

calc_required_n_paired <- function(effect_size_dz, alpha = 0.05, power = 0.80, two_sided = TRUE) {
  if (is.na(effect_size_dz) || effect_size_dz <= 0) {
    return(NA_integer_)
  }
  if (!requireNamespace("pwr", quietly = TRUE)) {
    return(NA_integer_)
  }
  alternative <- if (two_sided) "two.sided" else "greater"
  out <- pwr::pwr.t.test(
    d = effect_size_dz,
    sig.level = alpha,
    power = power,
    type = "paired",
    alternative = alternative
  )
  ceiling(out$n)
}

calc_required_n_clustered_binary <- function(
  p_before,
  p_after,
  alpha = 0.05,
  power = 0.80,
  m = 5,
  icc = NA_real_,
  two_sided = TRUE
) {
  if (any(is.na(c(p_before, p_after, m))) || m <= 1) {
    return(tibble(
      required_groups_total = NA_integer_,
      required_participants_total = NA_integer_,
      design_effect = NA_real_
    ))
  }
  if (!requireNamespace("pwr", quietly = TRUE)) {
    return(tibble(
      required_groups_total = NA_integer_,
      required_participants_total = NA_integer_,
      design_effect = NA_real_
    ))
  }

  h <- 2 * asin(sqrt(p_after)) - 2 * asin(sqrt(p_before))
  if (h == 0) {
    return(tibble(
      required_groups_total = NA_integer_,
      required_participants_total = NA_integer_,
      design_effect = NA_real_
    ))
  }

  alternative <- if (two_sided) "two.sided" else "greater"
  n_individual_per_arm <- pwr::pwr.2p.test(
    h = abs(h),
    sig.level = alpha,
    power = power,
    alternative = alternative
  )$n

  design_effect <- ifelse(is.na(icc), NA_real_, 1 + (m - 1) * icc)
  total_individuals <- ceiling(2 * n_individual_per_arm * design_effect)
  total_groups <- ceiling(total_individuals / m)

  tibble(
    required_groups_total = total_groups,
    required_participants_total = total_groups * m,
    design_effect = design_effect
  )
}

compute_required_n <- function(spec_row) {
  test_family <- spec_row$test_family[[1]]

  if (test_family == "paired_continuous") {
    n_required <- calc_required_n_paired(
      effect_size_dz = spec_row$min_effect[[1]],
      alpha = spec_row$alpha[[1]],
      power = spec_row$power[[1]],
      two_sided = TRUE
    )
    return(tibble(
      required_n_participants = n_required,
      required_n_groups = NA_integer_,
      design_effect = NA_real_
    ))
  }

  if (test_family == "clustered_binary_diff") {
    group_calc <- calc_required_n_clustered_binary(
      p_before = spec_row$pilot_p_before[[1]],
      p_after = spec_row$pilot_p_after[[1]],
      alpha = spec_row$alpha[[1]],
      power = spec_row$power[[1]],
      m = spec_row$cluster_size[[1]],
      icc = spec_row$icc[[1]],
      two_sided = TRUE
    )
    return(tibble(
      required_n_participants = group_calc$required_participants_total,
      required_n_groups = group_calc$required_groups_total,
      design_effect = group_calc$design_effect
    ))
  }

  tibble(
    required_n_participants = NA_integer_,
    required_n_groups = NA_integer_,
    design_effect = NA_real_
  )
}

required_n_table <- power_spec %>%
  rowwise() %>%
  mutate(calc = list(compute_required_n(pick(everything())))) %>%
  ungroup() %>%
  unnest(calc)

# --- Outputs -----------------------------------------------------------------

write_csv(required_n_table, file.path(output_dir, "phase2_power_analysis_scaffold.csv"))

pilot_summary_rows <- bind_rows(
  pilot_summary$cosine_shift %>% mutate(outcome_id = "cosine_shift"),
  pilot_summary$ranking_l1_shift %>% mutate(outcome_id = "ranking_l1_shift"),
  pilot_summary$theme_l1_shift %>% mutate(outcome_id = "theme_l1_shift")
) %>%
  select(outcome_id, everything())

write_csv(pilot_summary_rows, file.path(output_dir, "phase2_power_pilot_summary.csv"))
write_csv(pilot_summary$condorcet_efficiency, file.path(output_dir, "phase2_power_condorcet_efficiency_by_phase.csv"))

notes <- c(
  "# Phase 2 Power Analysis Scaffold",
  "",
  "This script scaffolds sample-size planning based on pilot outcomes.",
  "",
  "Outcomes included:",
  "- Individual level: cosine difference shift after cross-pollination",
  "- Individual level: L1 shift in rankings",
  "- Individual level: L1 shift in themes mentioned",
  "- Group level (5-person groups from permutations): Condorcet efficiency",
  "",
  "Placeholders to fill in `power_spec` before final N calculation:",
  "- `min_effect` for each continuous outcome (paired dz)",
  "- `pilot_p_before` and `pilot_p_after` for Condorcet efficiency",
  "- `icc` for clustered group-level design",
  "",
  "When placeholders are left as NA, required N outputs stay NA by design."
)

writeLines(notes, con = file.path(output_dir, "phase2_power_analysis_notes.md"))

cat("Wrote power-analysis scaffold outputs to", output_dir, "\n")
