options(stringsAsFactors = FALSE)

suppressPackageStartupMessages({
  library(readr)
  library(dplyr)
  library(stringr)
  library(tibble)
})

# -----------------------------------------------------------------------------
# Manual config
# -----------------------------------------------------------------------------

# Pilot data used as empirical DGPs
control_input_path <- "analysis/output/phase1_participant_stats.csv"
treatment_input_path <- "analysis/output/phase2_participant_changes.csv"
id_col <- "user_id"
control_ranking_col <- "ranking"
treated_ranking_col <- "final_ranking"

# Condorcet statistic configuration
group_size <- 5L

# Power simulation configuration
n_grid <- seq(60L, 300, by = 30L)  # treated and control sample sizes per arm
sims_per_n <- 1000
alpha <- 0.05

# RI inside each simulation (keep smaller for speed)
ri_b <- 999
ri_two_sided <- TRUE

# Group-set construction for Condorcet-share
# exhaustive: all C(n, group_size) groups (exact but expensive)
# mc: random groups (approximate but scalable)
# auto: exhaustive when small enough, mc otherwise
group_mode <- "auto"               # one of: "exhaustive", "mc", "auto"
max_exhaustive_groups <- 2000000L  # threshold used when group_mode = "auto"
mc_groups_per_arm <- 50000L        # used when group_mode resolves to "mc"

seed <- 20260406L
progress_every <- 10L

# Optional outputs
write_output <- TRUE
output_summary_path <- "analysis/output/r/condorcet_power_between_summary.csv"
output_curve_path <- "analysis/output/r/condorcet_power_between_curve.csv"
output_plot_path <- "analysis/output/r/condorcet_power_between_curve.png"

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

parse_rankings <- function(x) {
  lapply(x, function(v) {
    parts <- str_split(v, "\\s*>\\s*", simplify = FALSE)[[1]]
    parts[nzchar(parts)]
  })
}

check_rankings <- function(ranking_list, option_set, label = "rankings") {
  bad <- vapply(
    ranking_list,
    function(r) length(r) != length(option_set) || anyDuplicated(r) > 0 || !setequal(r, option_set),
    logical(1)
  )
  if (any(bad)) {
    stop("Malformed ", label, " at row(s): ", paste(head(which(bad), 10), collapse = ", "))
  }
}

condorcet_share <- function(rankings_list, groups_matrix, option_set) {
  n_groups <- ncol(groups_matrix)
  cw_count <- 0L

  for (i in seq_len(n_groups)) {
    grp <- rankings_list[groups_matrix[, i]]
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

  cw_count / n_groups
}

build_groups_matrix <- function(n,
                                group_size,
                                group_mode,
                                max_exhaustive_groups,
                                mc_groups_per_arm) {
  total_groups <- choose(n, group_size)

  use_exhaustive <- switch(
    group_mode,
    exhaustive = TRUE,
    mc = FALSE,
    auto = is.finite(total_groups) && total_groups <= max_exhaustive_groups,
    stop("group_mode must be one of: exhaustive, mc, auto")
  )

  if (use_exhaustive) {
    groups_matrix <- combn(n, group_size)
    mode_used <- "exhaustive"
  } else {
    groups_matrix <- replicate(
      mc_groups_per_arm,
      sort(sample.int(n, size = group_size, replace = FALSE)),
      simplify = "matrix"
    )
    mode_used <- "mc"
  }

  list(
    groups_matrix = groups_matrix,
    mode_used = mode_used,
    n_groups_used = ncol(groups_matrix),
    total_groups = total_groups
  )
}

ri_test_between <- function(control_rankings,
                            treated_rankings,
                            option_set,
                            groups_control,
                            groups_treated,
                            perm_treated_idx,
                            alpha,
                            two_sided = TRUE) {
  n_control <- length(control_rankings)
  n_treated <- length(treated_rankings)
  all_rankings <- c(control_rankings, treated_rankings)

  theta_control <- condorcet_share(control_rankings, groups_control, option_set)
  theta_treated <- condorcet_share(treated_rankings, groups_treated, option_set)
  tau_observed <- theta_treated - theta_control

  b <- ncol(perm_treated_idx)
  extreme_count <- 0L

  for (perm_i in seq_len(b)) {
    t_idx <- perm_treated_idx[, perm_i]
    c_idx <- setdiff(seq_len(n_control + n_treated), t_idx)

    tau_b <- condorcet_share(all_rankings[t_idx], groups_treated, option_set) -
      condorcet_share(all_rankings[c_idx], groups_control, option_set)

    if (two_sided) {
      if (abs(tau_b) >= abs(tau_observed)) extreme_count <- extreme_count + 1L
    } else {
      if (tau_b >= tau_observed) extreme_count <- extreme_count + 1L
    }
  }

  p_value <- (extreme_count + 1) / (b + 1)

  list(
    tau_observed = tau_observed,
    p_value = p_value,
    reject = (p_value < alpha)
  )
}

# -----------------------------------------------------------------------------
# Load pilot data and build empirical DGPs
# -----------------------------------------------------------------------------

control_raw <- read_csv(control_input_path, show_col_types = FALSE)
treatment_raw <- read_csv(treatment_input_path, show_col_types = FALSE)

control_required_cols <- c(id_col, control_ranking_col)
treatment_required_cols <- c(id_col, treated_ranking_col)

control_missing <- setdiff(control_required_cols, names(control_raw))
if (length(control_missing) > 0) {
  stop("Missing control columns: ", paste(control_missing, collapse = ", "))
}

treatment_missing <- setdiff(treatment_required_cols, names(treatment_raw))
if (length(treatment_missing) > 0) {
  stop("Missing treatment columns: ", paste(treatment_missing, collapse = ", "))
}

control_df <- control_raw %>%
  select(all_of(control_required_cols)) %>%
  rename(user_id = all_of(id_col), ranking_string = all_of(control_ranking_col)) %>%
  filter(!is.na(user_id), !is.na(ranking_string), ranking_string != "") %>%
  distinct(user_id, .keep_all = TRUE)

treatment_df <- treatment_raw %>%
  select(all_of(treatment_required_cols)) %>%
  rename(user_id = all_of(id_col), ranking_string = all_of(treated_ranking_col)) %>%
  filter(!is.na(user_id), !is.na(ranking_string), ranking_string != "") %>%
  distinct(user_id, .keep_all = TRUE)

if (nrow(control_df) == 0 || nrow(treatment_df) == 0) {
  stop("Pilot data has no valid control and/or treatment rows after filtering.")
}

overlap_ids <- intersect(control_df$user_id, treatment_df$user_id)
if (length(overlap_ids) > 0) {
  stop(
    "Control and treatment pilot files share user IDs; between-group bootstrap expects disjoint arms. Example overlap: ",
    paste(head(overlap_ids, 10), collapse = ", "),
    if (length(overlap_ids) > 10) " ..."
  )
}

control_rankings_pilot <- parse_rankings(control_df$ranking_string)
treated_rankings_pilot <- parse_rankings(treatment_df$ranking_string)

option_set <- sort(unique(unlist(c(control_rankings_pilot, treated_rankings_pilot))))
if (length(option_set) < 2) {
  stop("Could not infer at least two options from pilot rankings.")
}

check_rankings(control_rankings_pilot, option_set, label = "control pilot rankings")
check_rankings(treated_rankings_pilot, option_set, label = "treatment pilot rankings")

n_control_pilot <- length(control_rankings_pilot)
n_treated_pilot <- length(treated_rankings_pilot)

if (any(n_grid < group_size)) {
  stop("All n values must be >= group_size.")
}

cat(sprintf(
  "Pilot loaded: control=%d treatment=%d options=%d group_size=%d\n",
  n_control_pilot, n_treated_pilot, length(option_set), group_size
))

# -----------------------------------------------------------------------------
# Precompute reusable objects by n
# -----------------------------------------------------------------------------

set.seed(seed)

prep_by_n <- vector("list", length(n_grid))
names(prep_by_n) <- as.character(n_grid)

for (n in n_grid) {
  n <- as.integer(n)

  groups_info <- build_groups_matrix(
    n = n,
    group_size = group_size,
    group_mode = group_mode,
    max_exhaustive_groups = max_exhaustive_groups,
    mc_groups_per_arm = mc_groups_per_arm
  )

  # Fixed-size complete-randomization label draws for RI in each simulated dataset
  perm_treated_idx <- replicate(
    n = ri_b,
    expr = sample.int(2L * n, size = n, replace = FALSE),
    simplify = "matrix"
  )

  prep_by_n[[as.character(n)]] <- list(
    groups_control = groups_info$groups_matrix,
    groups_treated = groups_info$groups_matrix,
    n_groups = groups_info$n_groups_used,
    group_mode_used = groups_info$mode_used,
    total_groups = groups_info$total_groups,
    perm_treated_idx = perm_treated_idx
  )

  message(
    "Prepared n=", n,
    " (mode=", groups_info$mode_used,
    ", groups_used=", groups_info$n_groups_used,
    ", total_C(n,k)=", format(groups_info$total_groups, scientific = FALSE), ")"
  )
}

# -----------------------------------------------------------------------------
# Power simulation
# -----------------------------------------------------------------------------

curve_rows <- vector("list", length(n_grid))

for (n_i in seq_along(n_grid)) {
  n <- as.integer(n_grid[n_i])
  prep <- prep_by_n[[as.character(n)]]
  t0_n <- Sys.time()

  rejected <- logical(sims_per_n)
  p_values <- numeric(sims_per_n)
  tau_values <- numeric(sims_per_n)

  for (sim_i in seq_len(sims_per_n)) {
    control_sim <- control_rankings_pilot[sample.int(n_control_pilot, size = n, replace = TRUE)]
    treated_sim <- treated_rankings_pilot[sample.int(n_treated_pilot, size = n, replace = TRUE)]

    ri_result <- ri_test_between(
      control_rankings = control_sim,
      treated_rankings = treated_sim,
      option_set = option_set,
      groups_control = prep$groups_control,
      groups_treated = prep$groups_treated,
      perm_treated_idx = prep$perm_treated_idx,
      alpha = alpha,
      two_sided = ri_two_sided
    )

    rejected[sim_i] <- ri_result$reject
    p_values[sim_i] <- ri_result$p_value
    tau_values[sim_i] <- ri_result$tau_observed

    if (sim_i %% progress_every == 0 || sim_i == 1L) {
      elapsed_sec <- as.numeric(difftime(Sys.time(), t0_n, units = "secs"))
      sec_per_sim <- elapsed_sec / sim_i
      remaining_sec <- sec_per_sim * (sims_per_n - sim_i)
      message(
        "n=", n,
        " sim ", sim_i, " / ", sims_per_n,
        " | elapsed=", sprintf("%.1f", elapsed_sec), "s",
        " | ETA=", sprintf("%.1f", remaining_sec), "s"
      )
    }
  }

  curve_rows[[n_i]] <- tibble(
    n_per_arm = n,
    n_total = 2L * n,
    sims = sims_per_n,
    ri_b = ri_b,
    alpha = alpha,
    power = mean(rejected),
    rejection_count = sum(rejected),
    mean_p_value = mean(p_values),
    mean_tau_observed = mean(tau_values),
    sd_tau_observed = sd(tau_values))

  n_elapsed_min <- as.numeric(difftime(Sys.time(), t0_n, units = "mins"))
  message(
    "Finished n=", n,
    " -> power=", sprintf("%.3f", curve_rows[[n_i]]$power),
    " | runtime=", sprintf("%.2f", n_elapsed_min), " min"
  )
}

power_curve <- bind_rows(curve_rows) %>%
  arrange(n_per_arm)

# First n where estimated power crosses target
power_target <- 0.80
crossing_row <- power_curve %>%
  filter(power >= power_target) %>% slice(1)

if (nrow(crossing_row) == 0) {
  n_per_arm_for_target <- NA_integer_
  n_total_for_target <- NA_integer_
} else {
  n_per_arm_for_target <- crossing_row$n_per_arm[[1]]
  n_total_for_target <- crossing_row$n_total[[1]]
}

summary_row <- tibble(
  control_input_path = control_input_path,
  treatment_input_path = treatment_input_path,
  control_ranking_col = control_ranking_col,
  treated_ranking_col = treated_ranking_col,
  n_control_pilot = n_control_pilot,
  n_treated_pilot = n_treated_pilot,
  options_count = length(option_set),
  group_size = group_size,
  sims_per_n = sims_per_n,
  ri_b = ri_b,
  group_mode = group_mode,
  max_exhaustive_groups = max_exhaustive_groups,
  mc_groups_per_arm = mc_groups_per_arm,
  alpha = alpha,
  two_sided = ri_two_sided,
  power_target = power_target,
  n_grid_min = min(n_grid),
  n_grid_max = max(n_grid),
  n_grid_step = if (length(n_grid) > 1) n_grid[2] - n_grid[1] else NA_integer_,
  n_per_arm_for_power_target = n_per_arm_for_target,
  n_total_for_power_target = n_total_for_target,
  seed = seed
)

# -----------------------------------------------------------------------------
# Plot
# -----------------------------------------------------------------------------

if (isTRUE(write_output)) {
  dir.create(dirname(output_summary_path), recursive = TRUE, showWarnings = FALSE)
  write_csv(summary_row, output_summary_path)
  write_csv(power_curve, output_curve_path)

  png(filename = output_plot_path, width = 900, height = 600)
  plot(
    power_curve$n_per_arm,
    power_curve$power,
    type = "b",
    pch = 19,
    col = "#1B4F72",
    xlab = "Sample Size Per Arm (n)",
    ylab = "Estimated Power",
    ylim = c(0, 1),
    main = "Condorcet RI Power Curve (Between-Group Design)"
  )
  abline(h = power_target, col = "#B03A2E", lty = 2, lwd = 2)
  if (!is.na(n_per_arm_for_target)) {
    abline(v = n_per_arm_for_target, col = "#117A65", lty = 3, lwd = 2)
  }
  grid()
  dev.off()
}

print(glimpse(summary_row))
print(power_curve)

if (is.na(n_per_arm_for_target)) {
  message("Power target ", power_target, " not reached in tested grid.")
} else {
  message(
    "Estimated minimum n per arm for power >= ", power_target,
    ": ", n_per_arm_for_target,
    " (total N=", n_total_for_target, ")"
  )
}
