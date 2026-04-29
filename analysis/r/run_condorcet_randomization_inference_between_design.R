options(stringsAsFactors = FALSE)

suppressPackageStartupMessages({
  library(readr)
  library(dplyr)
  library(stringr)
  library(tibble)
})

# -----------------------------------------------------------------------------
# Manual config (edit these directly when working interactively)
# -----------------------------------------------------------------------------

control_input_path <- "analysis/output/phase1_participant_stats.csv"
treatment_input_path <- "analysis/output/phase2_participant_changes.csv"
id_col <- "user_id"
control_ranking_col <- "ranking"
treated_ranking_col <- "final_ranking"

group_size <- 5L

# Randomization inference settings (between-person complete randomization)
# Under the sharp null, labels are reassigned across participants while keeping
# the observed treated-group size fixed.
method <- "mc"                    # one of: "exact", "mc", "auto"
b <- 5000L                         # used for mc
seed <- 123L
max_exact_assignments <- 200000L   # exact if C(n, n_treated) <= this when method = "auto"
max_groups <- 500000L

# Optional outputs
write_output <- TRUE
output_path <- "analysis/output/r/condorcet_randomization_inference_between_summary.csv"
null_path <- "analysis/output/r/condorcet_randomization_inference_between_null.csv"

# -----------------------------------------------------------------------------
# Load and validate data
# -----------------------------------------------------------------------------

control_raw <- read_csv(control_input_path, show_col_types = FALSE)
treatment_raw <- read_csv(treatment_input_path, show_col_types = FALSE)

control_required_cols <- c(id_col, control_ranking_col)
treatment_required_cols <- c(id_col, treated_ranking_col)

control_missing_cols <- setdiff(control_required_cols, names(control_raw))
if (length(control_missing_cols) > 0) {
  stop("Missing required columns in control file: ", paste(control_missing_cols, collapse = ", "))
}

treatment_missing_cols <- setdiff(treatment_required_cols, names(treatment_raw))
if (length(treatment_missing_cols) > 0) {
  stop("Missing required columns in treatment file: ", paste(treatment_missing_cols, collapse = ", "))
}

control_df <- control_raw %>%
  select(all_of(control_required_cols)) %>%
  rename(
    user_id = all_of(id_col),
    ranking_string = all_of(control_ranking_col)
  ) %>%
  filter(!is.na(user_id), !is.na(ranking_string), ranking_string != "")

treatment_df <- treatment_raw %>%
  select(all_of(treatment_required_cols)) %>%
  rename(
    user_id = all_of(id_col),
    ranking_string = all_of(treated_ranking_col)
  ) %>%
  filter(!is.na(user_id), !is.na(ranking_string), ranking_string != "")

if (anyDuplicated(control_df$user_id) > 0) {
  stop("Control file has duplicate user IDs.")
}
if (anyDuplicated(treatment_df$user_id) > 0) {
  stop("Treatment file has duplicate user IDs.")
}

control_df <- control_df %>% mutate(assignment = 0L)
treatment_df <- treatment_df %>% mutate(assignment = 1L)

df <- bind_rows(control_df, treatment_df)

if (nrow(df) == 0) {
  stop("No valid rows after filtering missing id/ranking values.")
}

df <- df %>%
  mutate(
    ranking = lapply(ranking_string, function(x) {
      parts <- str_split(x, "\\s*>\\s*", simplify = FALSE)[[1]]
      parts[nzchar(parts)]
    })
  )

option_set <- sort(unique(unlist(df$ranking)))
if (length(option_set) < 2) {
  stop("Could not infer at least two options from rankings.")
}

check_rankings <- function(ranking_list, option_set) {
  bad <- vapply(
    ranking_list,
    function(r) length(r) != length(option_set) || anyDuplicated(r) > 0 || !setequal(r, option_set),
    logical(1)
  )
  if (any(bad)) {
    stop("Malformed rankings at row(s): ", paste(head(which(bad), 10), collapse = ", "))
  }
}
check_rankings(df$ranking, option_set)

n_participants <- nrow(df)
n_treated <- sum(df$assignment == 1L)
n_control <- n_participants - n_treated

if (n_treated < group_size) {
  stop("Need at least group_size=", group_size, " treated participants; have ", n_treated)
}
if (n_control < group_size) {
  stop("Need at least group_size=", group_size, " control participants; have ", n_control)
}

rankings_obs <- df$ranking
assignment_obs <- df$assignment

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

condorcet_count_share <- function(rankings_list, groups_matrix, option_set) {
  n_groups <- ncol(groups_matrix)
  cw_count <- 0L

  for (i in seq_len(n_groups)) {
    g <- groups_matrix[, i]
    grp <- rankings_list[g]
    grp_size <- length(grp)
    has_cw <- FALSE

    for (cand in option_set) {
      beats_all <- TRUE
      for (opp in option_set[option_set != cand]) {
        votes <- sum(vapply(grp, function(r) match(cand, r) < match(opp, r), logical(1)))
        if (votes * 2L <= grp_size) {
          beats_all <- FALSE
          break
        }
      }
      if (beats_all) {
        has_cw <- TRUE
        break
      }
    }

    if (has_cw) cw_count <- cw_count + 1L
  }

  list(
    count = cw_count,
    share = cw_count / n_groups
  )
}

compute_tau <- function(assignment_vec, rankings, group_size, option_set, max_groups) {
  treated_idx <- which(assignment_vec == 1L)
  control_idx <- which(assignment_vec == 0L)

  if (length(treated_idx) < group_size || length(control_idx) < group_size) {
    return(NA_real_)
  }

  groups_treated <- combn(treated_idx, group_size)
  groups_control <- combn(control_idx, group_size)

  n_groups_treated <- ncol(groups_treated)
  n_groups_control <- ncol(groups_control)

  if (n_groups_treated > max_groups || n_groups_control > max_groups) {
    stop(
      "Group combinations exceed max_groups. Treated: ",
      format(n_groups_treated, scientific = FALSE),
      ", Control: ",
      format(n_groups_control, scientific = FALSE),
      ", max_groups=", max_groups
    )
  }

  treated_stats <- condorcet_count_share(rankings, groups_treated, option_set)
  control_stats <- condorcet_count_share(rankings, groups_control, option_set)

  list(
    tau = treated_stats$share - control_stats$share,
    theta_treated = treated_stats$share,
    theta_control = control_stats$share,
    cw_groups_treated = treated_stats$count,
    cw_groups_control = control_stats$count,
    n_groups_treated = n_groups_treated,
    n_groups_control = n_groups_control
  )
}

# -----------------------------------------------------------------------------
# Observed statistic: theta_treated - theta_control
# -----------------------------------------------------------------------------

obs_stats <- compute_tau(
  assignment_vec = assignment_obs,
  rankings = rankings_obs,
  group_size = group_size,
  option_set = option_set,
  max_groups = max_groups
)

theta_treated <- obs_stats$theta_treated
theta_control <- obs_stats$theta_control
tau_observed <- obs_stats$tau
cw_treated <- obs_stats$cw_groups_treated
cw_control <- obs_stats$cw_groups_control
n_groups_treated <- obs_stats$n_groups_treated
n_groups_control <- obs_stats$n_groups_control

cat(sprintf(
  "Observed: theta_treated=%.4f  theta_control=%.4f  tau=%.4f\n",
  theta_treated, theta_control, tau_observed
))

# -----------------------------------------------------------------------------
# Fisher randomization inference for between-group complete randomization
# -----------------------------------------------------------------------------

n_assignments <- choose(n_participants, n_treated)
use_exact <- switch(
  method,
  exact = TRUE,
  mc = FALSE,
  auto = is.finite(n_assignments) && n_assignments <= max_exact_assignments,
  stop("method must be one of: exact, mc, auto")
)

set.seed(seed)

if (use_exact) {
  treated_sets <- combn(n_participants, n_treated)
  n_perms <- ncol(treated_sets)
  tau_null <- numeric(n_perms)
  extreme_count <- 0L

  for (perm_i in seq_len(n_perms)) {
    assignment_b <- integer(n_participants)
    assignment_b[treated_sets[, perm_i]] <- 1L

    tau_b <- compute_tau(
      assignment_vec = assignment_b,
      rankings = rankings_obs,
      group_size = group_size,
      option_set = option_set,
      max_groups = max_groups
    )$tau

    tau_null[perm_i] <- tau_b
    if (abs(tau_b) >= abs(tau_observed)) extreme_count <- extreme_count + 1L

    if (perm_i %% 500 == 0) {
      message("Exact: ", perm_i, " / ", n_perms)
    }
  }

  n_reassignments <- n_perms
  inference_method <- "exact"

} else {
  tau_null <- numeric(b)
  extreme_count <- 0L

  for (perm_i in seq_len(b)) {
    assignment_b <- integer(n_participants)
    assignment_b[sample.int(n_participants, size = n_treated, replace = FALSE)] <- 1L

    tau_b <- compute_tau(
      assignment_vec = assignment_b,
      rankings = rankings_obs,
      group_size = group_size,
      option_set = option_set,
      max_groups = max_groups
    )$tau

    tau_null[perm_i] <- tau_b
    if (abs(tau_b) >= abs(tau_observed)) extreme_count <- extreme_count + 1L

    if (perm_i %% 500 == 0) {
      message("MC: ", perm_i, " / ", b)
    }
  }

  n_reassignments <- b
  inference_method <- "mc"
}

p_value_two_sided <- (extreme_count + 1) / (n_reassignments + 1)

# -----------------------------------------------------------------------------
# Final objects
# -----------------------------------------------------------------------------

summary_row <- tibble(
  n_participants = n_participants,
  n_treated = n_treated,
  n_control = n_control,
  group_size = group_size,
  options_count = length(option_set),
  control_input_path = control_input_path,
  treatment_input_path = treatment_input_path,
  control_ranking_col = control_ranking_col,
  treated_ranking_col = treated_ranking_col,
  theta_treated = theta_treated,
  theta_control = theta_control,
  tau_observed = tau_observed,
  cw_groups_treated = cw_treated,
  cw_groups_control = cw_control,
  n_groups_treated = as.integer(n_groups_treated),
  n_groups_control = as.integer(n_groups_control),
  p_value_two_sided = p_value_two_sided,
  inference_method = inference_method,
  n_reassignments = n_reassignments,
  seed = seed
)

null_df <- tibble(
  permutation_id = seq_along(tau_null),
  tau_null = tau_null
)

if (isTRUE(write_output)) {
  dir.create(dirname(output_path), recursive = TRUE, showWarnings = FALSE)
  dir.create(dirname(null_path), recursive = TRUE, showWarnings = FALSE)
  write_csv(summary_row, output_path)
  write_csv(null_df, null_path)
}

glimpse(summary_row)
message("Done. p-value = ", signif(p_value_two_sided, 4), " (", inference_method, ")")
