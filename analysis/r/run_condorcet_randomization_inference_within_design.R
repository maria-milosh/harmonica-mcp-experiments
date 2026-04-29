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

input_path <- "analysis/output/phase2_participant_changes.csv"
id_col <- "user_id"
control_ranking_col <- "initial_ranking"  # control observations
treated_ranking_col <- "final_ranking"    # treatment observations
group_size <- 5L

# Randomization inference settings (paired randomization)
# Under the sharp null in this paired setup, we randomly swap each person's
# initial/final label with probability 0.5.
method <- "mc"           # one of: "exact", "mc", "auto"
b <- 5000L                # used for mc; for exact, all 2^n swap patterns are used
seed <- 123L
max_exact_swaps <- 65536  # exact if 2^n <= this when method = "auto"
max_groups <- 500000

# Optional outputs
write_output <- TRUE
output_path <- "analysis/output/r/condorcet_randomization_inference_summary.csv"
null_path <- "analysis/output/r/condorcet_randomization_inference_null.csv"

# -----------------------------------------------------------------------------
# Load and validate data
# -----------------------------------------------------------------------------

raw_df <- read_csv(input_path, show_col_types = FALSE)
required_cols <- c(id_col, control_ranking_col, treated_ranking_col)
missing_cols <- setdiff(required_cols, names(raw_df))
if (length(missing_cols) > 0) {
  stop("Missing required columns: ", paste(missing_cols, collapse = ", "))
}

df <- raw_df %>%
  select(all_of(required_cols)) %>%
  rename(
    user_id = all_of(id_col),
    control_ranking_string = all_of(control_ranking_col),
    treated_ranking_string = all_of(treated_ranking_col)
  ) %>%
  filter(
    !is.na(user_id),
    !is.na(control_ranking_string), control_ranking_string != "",
    !is.na(treated_ranking_string), treated_ranking_string != ""
  ) %>%
  distinct(user_id, .keep_all = TRUE)

if (nrow(df) == 0) {
  stop("No valid rows after filtering missing id/control/treated rankings.")
}

df <- df %>%
  mutate(
    control_ranking = lapply(control_ranking_string, function(x) {
      parts <- str_split(x, "\\s*>\\s*", simplify = FALSE)[[1]]
      parts[nzchar(parts)]
    }),
    treated_ranking = lapply(treated_ranking_string, function(x) {
      parts <- str_split(x, "\\s*>\\s*", simplify = FALSE)[[1]]
      parts[nzchar(parts)]
    })
  )

option_set <- sort(unique(unlist(c(df$control_ranking, df$treated_ranking))))
if (length(option_set) < 2) {
  stop("Could not infer at least two options from rankings.")
}

check_rankings <- function(ranking_list, label, option_set) {
  bad <- vapply(ranking_list, function(r)
    length(r) != length(option_set) || anyDuplicated(r) > 0 || !setequal(r, option_set),
    logical(1))
  if (any(bad))
    stop("Malformed ", label, " rankings at row(s): ",
         paste(head(which(bad), 10), collapse = ", "))
}
check_rankings(df$control_ranking, "control", option_set)
check_rankings(df$treated_ranking, "treated", option_set)

n_participants <- nrow(df)
if (n_participants < group_size)
  stop("Need at least group_size=", group_size, " participants; have ", n_participants)
control_rankings_obs <- df$control_ranking
treated_rankings_obs <- df$treated_ranking


# -----------------------------------------------------------------------------
# Helper: share of groups (from a pre-built index matrix) that have a CW
# -----------------------------------------------------------------------------

condorcet_share <- function(rankings_list, groups_matrix, option_set) {
  n_groups <- ncol(groups_matrix)
  cw_count <- 0L
  for (i in seq_len(n_groups)) {
    g            <- groups_matrix[, i]
    grp          <- rankings_list[g]
    grp_size     <- length(grp)
    has_cw       <- FALSE
    for (cand in option_set) {
      beats_all <- TRUE
      for (opp in option_set[option_set != cand]) {
        votes <- sum(vapply(grp,
                            function(r) match(cand, r) < match(opp, r),
                            logical(1)))
        # strict majority: cand must get MORE than half the votes
        if (votes * 2L <= grp_size) { beats_all <- FALSE; break }
      }
      if (beats_all) { has_cw <- TRUE; break }
    }
    if (has_cw) cw_count <- cw_count + 1L
  }
  cw_count / n_groups
}

# -----------------------------------------------------------------------------
# Helper: apply a swap vector and return tau
# Both arms use the same shared groups_matrix (correct for within-person:
# each group of 5 is evaluated under both label assignments)
# -----------------------------------------------------------------------------

compute_tau <- function(swap_vec,
                        control_rankings_obs,
                        treated_rankings_obs,
                        groups_matrix,
                        option_set) {
  n    <- length(swap_vec)
  ctrl <- vector("list", n)
  trt  <- vector("list", n)
  for (k in seq_len(n)) {
    if (swap_vec[k] == 1L) {
      ctrl[[k]] <- treated_rankings_obs[[k]]
      trt[[k]]  <- control_rankings_obs[[k]]
    } else {
      ctrl[[k]] <- control_rankings_obs[[k]]
      trt[[k]]  <- treated_rankings_obs[[k]]
    }
  }
  condorcet_share(trt, groups_matrix, option_set) -
    condorcet_share(ctrl, groups_matrix, option_set)
}


# -----------------------------------------------------------------------------
# Observed U-statistic: theta_treated - theta_control
# -----------------------------------------------------------------------------

groups_matrix <- combn(n_participants, group_size)
n_groups <- ncol(groups_matrix)
if (n_groups > max_groups)
  stop("C(", n_participants, ",", group_size, ") = ",
       format(n_groups, scientific = FALSE), " exceeds max_groups.")

theta_control <- condorcet_share(control_rankings_obs, groups_matrix, option_set)
theta_treated <- condorcet_share(treated_rankings_obs, groups_matrix, option_set)
tau_observed  <- theta_treated - theta_control

cat(sprintf("Observed: theta_treated=%.4f  theta_control=%.4f  tau=%.4f\n",
            theta_treated, theta_control, tau_observed))

# -----------------------------------------------------------------------------
# Fisher randomization inference for paired initial-vs-final setup
# -----------------------------------------------------------------------------

n_swap_patterns <- 2^n_participants
use_exact <- switch(method,
  exact = TRUE,
  mc    = FALSE,
  auto  = is.finite(n_swap_patterns) && n_swap_patterns <= max_exact_swaps,
  stop("method must be one of: exact, mc, auto"))

set.seed(seed)

if (use_exact) {
  swap_grid     <- expand.grid(rep(list(c(0L, 1L)), n_participants))
  n_perms       <- nrow(swap_grid)
  tau_null      <- numeric(n_perms)
  extreme_count <- 0L

  for (perm_i in seq_len(n_perms)) {
    tau_b <- compute_tau(as.integer(swap_grid[perm_i, ]),
                                    control_rankings_obs, treated_rankings_obs,
                                    groups_matrix, option_set)
    tau_null[perm_i] <- tau_b
    if (abs(tau_b) >= abs(tau_observed)) extreme_count <- extreme_count + 1L
    if (perm_i %% 500 == 0)
      message("Exact: ", perm_i, " / ", n_perms)
  }
  n_reassignments  <- n_perms
  inference_method <- "exact"

} else {
  tau_null <- numeric(b)
  extreme_count <- 0L

  for (perm_i in seq_len(b)) {
    tau_b            <- compute_tau(rbinom(n_participants, 1L, 0.5),
                                    control_rankings_obs, treated_rankings_obs,
                                    groups_matrix, option_set)
    tau_null[perm_i] <- tau_b
    if (abs(tau_b) >= abs(tau_observed)) extreme_count <- extreme_count + 1L
    if (perm_i %% 500 == 0)
      message("MC: ", perm_i, " / ", b)
  }
  n_reassignments  <- b
  inference_method <- "mc"
}

p_value_two_sided <- (extreme_count + 1) / (n_reassignments + 1)

# -----------------------------------------------------------------------------
# Final objects
# -----------------------------------------------------------------------------

summary_row <- tibble(
  n_participants = n_participants,
  group_size = group_size,
  options_count = length(option_set),
  control_ranking_col = control_ranking_col,
  treated_ranking_col = treated_ranking_col,
  theta_treated = theta_treated,
  theta_control = theta_control,
  tau_observed = tau_observed,
  cw_groups_treated = cw_treated,
  cw_groups_control = cw_control,
  n_groups = as.integer(n_groups),
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

print(glimpse(summary_row))
message("Done. p-value = ", signif(p_value_two_sided, 4), " (", inference_method, ")")
