options(stringsAsFactors = FALSE)

suppressPackageStartupMessages({
  library(readr)
  library(dplyr)
  library(stringr)
  library(tibble)
  library(tidyr)
  library(ggplot2)
  library(MASS)
})

# Power for Outcome 1 with primary focus on pair-specific Romano-Wolf discovery.
# Headline: control = phase-1 empirical bootstrap; treated has same Sigma_Y as
# control with mean shifted by tau. Two tau shapes reported: diffuse (monotone
# Plackett-Luce shift on uniform-K4 utilities) and pilot-proportional (the
# observed phase-2-final minus phase-1 tau direction, rescaled to RMS = 3 pp).
# Run from repo root: Rscript reports/pairwise-preferences/analysis/run_pairwise_ate_power.R

# -----------------------------------------------------------------------------
# Config
# -----------------------------------------------------------------------------

control_input_path   <- "analysis/output/phase1_participant_changes.csv"
treatment_input_path <- "analysis/output/phase2_participant_changes.csv"
control_id_col       <- "user_id"
treatment_id_col     <- "user_id"
control_ranking_col  <- "final_ranking"
treated_ranking_col  <- "final_ranking"

option_codes <- c("animal_rescue", "community_clinic", "food_pantry", "urban_tree")
K            <- length(option_codes)

target_rms       <- 0.03
power_target     <- 0.80
alpha            <- 0.05
n_grid           <- seq(100, 4000, by = 50)
sim_n_per_arm    <- NULL  # set after we find n*; checked via simulation
sim_S            <- 200
seed             <- 20260510L

output_dir  <- "reports/pairwise-preferences/analysis/output"
figures_dir <- "reports/pairwise-preferences/figures"

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

parse_ranking <- function(x) {
  parts <- str_split(x, "\\s*>\\s*")[[1]]
  parts[nzchar(parts)]
}

permn <- function(x) {
  if (length(x) <= 1) return(list(x))
  out <- list()
  for (i in seq_along(x)) {
    rest <- x[-i]
    sub  <- permn(rest)
    for (s in sub) out[[length(out) + 1]] <- c(x[i], s)
  }
  out
}

build_pair_table <- function(codes) {
  sorted_codes <- sort(codes)
  pairs <- expand.grid(first = sorted_codes, second = sorted_codes,
                       stringsAsFactors = FALSE)
  pairs <- pairs[pairs$first < pairs$second, ]
  pairs <- pairs[order(pairs$first, pairs$second), ]
  pairs$pair_id <- paste(pairs$first, ">", pairs$second)
  rownames(pairs) <- NULL
  pairs
}

build_indicator_matrix_from_idx <- function(ranking_list, pairs_idx_first, pairs_idx_second, codes) {
  P <- length(pairs_idx_first)
  n <- length(ranking_list)
  Y <- matrix(0L, nrow = n, ncol = P)
  for (i in seq_len(n)) {
    rk  <- ranking_list[[i]]
    pos <- match(codes, rk)
    names(pos) <- codes
    for (p in seq_len(P)) {
      Y[i, p] <- as.integer(pos[pairs_idx_first[p]] < pos[pairs_idx_second[p]])
    }
  }
  Y
}

# Plackett-Luce sample via Gumbel-max trick
draw_pl <- function(n, theta) {
  K <- length(theta)
  out <- vector("list", n)
  for (i in seq_len(n)) {
    g <- -log(-log(runif(K)))
    out[[i]] <- option_codes[order(theta + g, decreasing = TRUE)]
  }
  out
}

# Pairwise probabilities P(j > k) for full Plackett-Luce on K items have the
# clean Luce-axiom marginal: P(j > k) = exp(theta_j) / (exp(theta_j) + exp(theta_k)).
pl_pairwise_probs <- function(theta, pairs, codes) {
  P <- nrow(pairs)
  out <- numeric(P)
  for (p in seq_len(P)) {
    j <- pairs$first[p]; k <- pairs$second[p]
    tj <- theta[match(j, codes)]; tk <- theta[match(k, codes)]
    out[p] <- exp(tj) / (exp(tj) + exp(tk))
  }
  out
}

# -----------------------------------------------------------------------------
# Load pilot, build pair table, compute pilot-empirical Sigma_Y_C
# -----------------------------------------------------------------------------

control_raw <- read_csv(control_input_path, show_col_types = FALSE)
treatment_raw <- read_csv(treatment_input_path, show_col_types = FALSE)

control_df <- control_raw %>%
  dplyr::select(user_id = all_of(control_id_col),
                ranking_string = all_of(control_ranking_col)) %>%
  filter(!is.na(user_id), !is.na(ranking_string), ranking_string != "") %>%
  distinct(user_id, .keep_all = TRUE)
treatment_df <- treatment_raw %>%
  dplyr::select(user_id = all_of(treatment_id_col),
                ranking_string = all_of(treated_ranking_col)) %>%
  filter(!is.na(user_id), !is.na(ranking_string), ranking_string != "") %>%
  distinct(user_id, .keep_all = TRUE)

control_rankings <- lapply(control_df$ranking_string, parse_ranking)
treated_rankings <- lapply(treatment_df$ranking_string, parse_ranking)
n_C_pilot <- length(control_rankings)
n_T_pilot <- length(treated_rankings)

option_set <- sort(unique(unlist(c(control_rankings, treated_rankings))))
if (!setequal(option_set, option_codes)) {
  stop("Option set mismatch: got ", paste(option_set, collapse = ", "),
       " but expected ", paste(option_codes, collapse = ", "))
}
bad_rankings <- vapply(c(control_rankings, treated_rankings),
                       function(r) length(r) != K || anyDuplicated(r) > 0 || !setequal(r, option_codes),
                       logical(1))
if (any(bad_rankings)) {
  stop("Malformed ranking(s) found in pilot data.")
}

pairs <- build_pair_table(option_codes)
P     <- nrow(pairs)

Y_C_pilot <- build_indicator_matrix_from_idx(control_rankings,
                                             pairs$first, pairs$second, option_codes)
Y_T_pilot <- build_indicator_matrix_from_idx(treated_rankings,
                                             pairs$first, pairs$second, option_codes)
p_C_pilot <- colMeans(Y_C_pilot)
p_T_pilot <- colMeans(Y_T_pilot)
tau_pilot <- p_T_pilot - p_C_pilot

# Empirical within-respondent covariance from phase 1
Sigma_Y_pilot <- cov(Y_C_pilot)

# -----------------------------------------------------------------------------
# Sigma_Y under uniform K=4 (closed-form via enumeration of all rankings)
# -----------------------------------------------------------------------------

uniform_perms <- permn(option_codes)
Y_uniform <- build_indicator_matrix_from_idx(uniform_perms,
                                             pairs$first, pairs$second, option_codes)
Sigma_Y_uniform <- cov(Y_uniform) * (length(uniform_perms) - 1) / length(uniform_perms)
# Note: cov() uses (n-1) denom; since we want population covariance over all
# equiprobable rankings, multiply by (R-1)/R where R = length(uniform_perms).

# -----------------------------------------------------------------------------
# Build candidate tau vectors at RMS = 3 pp
# -----------------------------------------------------------------------------

# 1) Diffuse: monotone Plackett-Luce shift on top of uniform
theta_C_diffuse <- rep(0, K)
pl_pair_shift <- function(c) {
  theta <- c * seq_len(K)
  pl_pairwise_probs(theta, pairs, option_codes) - 0.5
}
obj_diffuse <- function(c) sqrt(mean(pl_pair_shift(c)^2)) - target_rms
c_star <- uniroot(obj_diffuse, c(0, 1))$root
theta_T_diffuse <- c_star * seq_len(K)
tau_diffuse <- pl_pair_shift(c_star)

# 2) Pilot-proportional: tau = tau_pilot rescaled to RMS = 3 pp
rms_pilot <- sqrt(mean(tau_pilot^2))
tau_pilot_scaled <- tau_pilot * (target_rms / rms_pilot)

# -----------------------------------------------------------------------------
# Asymptotic noncentrality and power
# -----------------------------------------------------------------------------

asym_power <- function(n_per_arm, tau_vec, Sigma_Y) {
  # Sigma_tauhat = 2 * Sigma_Y / n  (assumes treated has same Sigma_Y as control,
  # which is exact under uniform-vs-shifted-PL by symmetry of pair indicators
  # and a reasonable approximation under bootstrap-control-vs-shifted-bootstrap.)
  Sigma_tauhat <- (2 / n_per_arm) * Sigma_Y
  Sigma_pinv   <- ginv(Sigma_tauhat)
  lambda <- as.numeric(t(tau_vec) %*% Sigma_pinv %*% tau_vec)
  rk <- sum(svd(Sigma_Y)$d > 1e-8 * max(svd(Sigma_Y)$d))
  crit <- qchisq(1 - alpha, df = rk)
  list(lambda = lambda, rank = rk, crit = crit,
       power = 1 - pchisq(crit, df = rk, ncp = lambda))
}

find_n_for_power <- function(tau_vec, Sigma_Y, n_grid, target = power_target) {
  pw <- sapply(n_grid, function(n) asym_power(n, tau_vec, Sigma_Y)$power)
  idx <- which(pw >= target)[1]
  if (is.na(idx)) NA_integer_ else as.integer(n_grid[idx])
}

# T_max power via multivariate-normal approximation.
# Under H0: (t_1, ..., t_P) ~ N(0, C) where C is the correlation matrix of Sigma_Y.
# Under H1: (t_1, ..., t_P) ~ N(delta, C) with delta_p = tau_p * sqrt(n / (2 * Sigma_diag_p)).
# Critical value c is the (1 - alpha)-quantile of max|Z| under H0.
# Power = P(max|Z| > c) under H1.
# We use a single Monte Carlo draw of B_mvn samples for both null and each n.
B_mvn <- 20000L
rw_B_null <- 20000L
rw_B_alt  <- 5000L
rw_eps    <- 1e-10

build_corr <- function(Sigma_Y, floor_var_frac = 1e-3) {
  # Floor zero/near-zero diagonals to avoid division by zero (e.g. when an
  # empirical test-retest correlation is exactly 1 in a small phase-2 sample).
  d <- diag(Sigma_Y)
  floor_v <- max(d) * floor_var_frac
  d_safe  <- pmax(d, floor_v)
  s <- sqrt(d_safe)
  C <- Sigma_Y / outer(s, s)
  diag(C) <- 1
  C
}

tmax_critical <- function(C, alpha = 0.05, B = B_mvn) {
  Z <- MASS::mvrnorm(B, mu = rep(0, ncol(C)), Sigma = C, empirical = FALSE)
  quantile(apply(abs(Z), 1, max), 1 - alpha, names = FALSE)
}

tmax_power <- function(n_per_arm, tau_vec, Sigma_Y, C, crit, B = B_mvn) {
  Sigma_diag <- diag(Sigma_Y)
  delta <- tau_vec * sqrt(n_per_arm / (2 * Sigma_diag))
  Z <- MASS::mvrnorm(B, mu = delta, Sigma = C, empirical = FALSE)
  mean(apply(abs(Z), 1, max) > crit)
}

find_n_for_tmax_power <- function(tau_vec, Sigma_Y, n_grid, C, crit,
                                  target = power_target, B = B_mvn) {
  pw <- sapply(n_grid, function(n) tmax_power(n, tau_vec, Sigma_Y, C, crit, B))
  idx <- which(pw >= target)[1]
  list(n = if (is.na(idx)) NA_integer_ else as.integer(n_grid[idx]),
       powers = pw)
}

build_rw_crit_cache <- function(C, alpha = 0.05, B = rw_B_null) {
  P <- ncol(C)
  Z_null <- MASS::mvrnorm(B, mu = rep(0, P), Sigma = C, empirical = FALSE)
  abs_null <- abs(Z_null)
  crit <- list()
  for (mask in seq_len(2^P - 1L)) {
    idx <- which(as.logical(intToBits(mask))[seq_len(P)])
    key <- paste(idx, collapse = ",")
    max_null <- if (length(idx) == 1L) {
      abs_null[, idx]
    } else {
      apply(abs_null[, idx, drop = FALSE], 1, max)
    }
    crit[[key]] <- as.numeric(quantile(max_null, 1 - alpha, names = FALSE))
  }
  crit
}

rw_rejections_stepdown <- function(t_obs, crit_cache) {
  P <- length(t_obs)
  abs_obs <- abs(t_obs)
  ord <- order(abs_obs, decreasing = TRUE)
  rejected <- rep(FALSE, P)
  active <- ord
  for (s in seq_along(ord)) {
    j <- ord[s]
    key <- paste(sort(active), collapse = ",")
    crit <- crit_cache[[key]]
    if (is.null(crit)) stop("Missing RW critical value for active set: ", key)
    if (abs_obs[j] > crit) {
      rejected[j] <- TRUE
      active <- active[active != j]
      if (length(active) == 0L) break
    } else {
      break
    }
  }
  rejected
}

rw_power_for_n <- function(n_per_arm, tau_vec, Sigma_Y, C, crit_cache,
                           B_alt = rw_B_alt, signal_eps = rw_eps) {
  P <- length(tau_vec)
  Sigma_diag <- pmax(diag(Sigma_Y), 1e-10)
  delta <- tau_vec * sqrt(n_per_arm / (2 * Sigma_diag))
  Z_alt <- MASS::mvrnorm(B_alt, mu = delta, Sigma = C, empirical = FALSE)
  rejections <- matrix(FALSE, nrow = B_alt, ncol = P)
  for (b in seq_len(B_alt)) {
    rejections[b, ] <- rw_rejections_stepdown(Z_alt[b, ], crit_cache)
  }
  signal <- abs(tau_vec) > signal_eps
  if (!any(signal)) signal[] <- TRUE
  list(
    power_any_signal = mean(apply(rejections[, signal, drop = FALSE], 1, any)),
    power_by_pair = colMeans(rejections),
    signal = signal
  )
}

# Build the 4-cell grid: (control DGP) x (tau shape)
cells <- list(
  list(control_dgp = "phase1_empirical", tau_shape = "diffuse_PL",
       tau_vec = tau_diffuse,         Sigma_Y = Sigma_Y_pilot),
  list(control_dgp = "phase1_empirical", tau_shape = "pilot_proportional",
       tau_vec = tau_pilot_scaled,    Sigma_Y = Sigma_Y_pilot),
  list(control_dgp = "uniform_K4",       tau_shape = "diffuse_PL",
       tau_vec = tau_diffuse,         Sigma_Y = Sigma_Y_uniform),
  list(control_dgp = "uniform_K4",       tau_shape = "pilot_proportional",
       tau_vec = tau_pilot_scaled,    Sigma_Y = Sigma_Y_uniform)
)

results <- list()
power_curve <- list()
rw_pair_n_required <- list()

set.seed(seed)
for (i in seq_along(cells)) {
  cell    <- cells[[i]]
  Sigma_Y <- cell$Sigma_Y
  tau_vec <- as.numeric(cell$tau_vec)
  rms_check <- sqrt(mean(tau_vec^2))

  # Joint Wald
  n_star_wald <- find_n_for_power(tau_vec, Sigma_Y, n_grid)

  # T_max via mvn approximation
  C_corr  <- build_corr(Sigma_Y)
  crit_tmax <- tmax_critical(C_corr, alpha = alpha, B = B_mvn)
  tmax_search <- find_n_for_tmax_power(tau_vec, Sigma_Y, n_grid, C_corr, crit_tmax,
                                       target = power_target, B = B_mvn)
  n_star_tmax <- tmax_search$n
  tmax_powers <- tmax_search$powers

  # Romano-Wolf stepdown discovery power (primary, pair-specific)
  rw_crit_cache <- build_rw_crit_cache(C_corr, alpha = alpha, B = rw_B_null)
  rw_any_powers <- numeric(length(n_grid))
  rw_pair_powers <- matrix(NA_real_, nrow = length(n_grid), ncol = P)
  rw_signal <- rep(FALSE, P)
  for (k in seq_along(n_grid)) {
    rw_n <- rw_power_for_n(n_grid[k], tau_vec, Sigma_Y, C_corr, rw_crit_cache,
                           B_alt = rw_B_alt, signal_eps = rw_eps)
    rw_any_powers[k] <- rw_n$power_any_signal
    rw_pair_powers[k, ] <- rw_n$power_by_pair
    rw_signal <- rw_n$signal
  }
  idx_any <- which(rw_any_powers >= power_target)[1]
  n_star_rw_any <- if (is.na(idx_any)) NA_integer_ else as.integer(n_grid[idx_any])
  n_star_rw_pair <- sapply(seq_len(P), function(p) {
    idx <- which(rw_pair_powers[, p] >= power_target)[1]
    if (is.na(idx)) NA_integer_ else as.integer(n_grid[idx])
  })

  for (k in seq_along(n_grid)) {
    n  <- n_grid[k]
    ap <- asym_power(n, tau_vec, Sigma_Y)
    power_curve[[length(power_curve) + 1]] <- tibble(
      control_dgp = cell$control_dgp,
      tau_shape   = cell$tau_shape,
      n_per_arm   = n,
      lambda      = ap$lambda,
      rank        = ap$rank,
      crit_wald   = ap$crit,
      power_wald  = ap$power,
      crit_tmax   = crit_tmax,
      power_tmax  = tmax_powers[k],
      power_rw_any = rw_any_powers[k]
    )
  }

  results[[i]] <- tibble(
    control_dgp        = cell$control_dgp,
    tau_shape          = cell$tau_shape,
    rms_target         = target_rms,
    rms_check          = rms_check,
    n_per_arm_80_wald  = n_star_wald,
    n_total_80_wald    = if (is.na(n_star_wald)) NA_integer_ else 2L * n_star_wald,
    n_per_arm_80_tmax  = n_star_tmax,
    n_total_80_tmax    = if (is.na(n_star_tmax)) NA_integer_ else 2L * n_star_tmax,
    n_per_arm_80_rw_any = n_star_rw_any,
    n_total_80_rw_any   = if (is.na(n_star_rw_any)) NA_integer_ else 2L * n_star_rw_any,
    crit_tmax          = crit_tmax
  )

  rw_pair_n_required[[i]] <- tibble(
    control_dgp = cell$control_dgp,
    tau_shape   = cell$tau_shape,
    pair_id     = pairs$pair_id,
    is_signal   = rw_signal,
    n_per_arm_80_rw = as.integer(n_star_rw_pair),
    n_total_80_rw   = as.integer(2L * n_star_rw_pair)
  )
}

results_df <- bind_rows(results)
power_curve_df <- bind_rows(power_curve)
rw_pair_n_required_df <- bind_rows(rw_pair_n_required)

cat("\n=== 80%-power n requirement (RW-focused) ===\n")
print(results_df)

# -----------------------------------------------------------------------------
# Simulation verification at the headline cell (phase1 control, diffuse tau)
# -----------------------------------------------------------------------------

sim_one_dataset <- function(n_per_arm, theta_T, control_pool_Y) {
  # Control: bootstrap from phase 1 indicator matrix
  idx_C <- sample.int(nrow(control_pool_Y), size = n_per_arm, replace = TRUE)
  Y_C_b <- control_pool_Y[idx_C, , drop = FALSE]
  # Treated: PL with theta_T
  T_rk <- draw_pl(n_per_arm, theta_T)
  Y_T_b <- build_indicator_matrix_from_idx(T_rk, pairs$first, pairs$second, option_codes)
  list(Y_C = Y_C_b, Y_T = Y_T_b)
}

sim_power_phase1_diffuse_rw <- function(n_per_arm, rw_cache, S = sim_S) {
  # Treated DGP: PL utilities theta_T_diffuse on uniform baseline.
  # Combined with phase 1 empirical control, the resulting tau vector is
  # tau_combined = pl_pairwise_probs(theta_T_diffuse) - p_C_pilot
  # which is NOT the diffuse_PL tau vector; this verification therefore
  # checks the simulation under a slightly different effect structure.
  # To match the asymptotic prediction headline, we instead simulate control
  # from PL(theta = 0) (i.e., uniform), so tau realised matches tau_diffuse.
  reject_any <- 0L
  reject_pair <- numeric(P)
  for (s in seq_len(S)) {
    rk_C <- draw_pl(n_per_arm, rep(0, K))
    Y_C  <- build_indicator_matrix_from_idx(rk_C, pairs$first, pairs$second, option_codes)
    rk_T <- draw_pl(n_per_arm, theta_T_diffuse)
    Y_T  <- build_indicator_matrix_from_idx(rk_T, pairs$first, pairs$second, option_codes)

    tau_hat <- colMeans(Y_T) - colMeans(Y_C)
    se_hat <- sqrt(pmax(diag(cov(Y_T)) / n_per_arm + diag(cov(Y_C)) / n_per_arm, 1e-10))
    t_obs <- tau_hat / se_hat
    rej <- rw_rejections_stepdown(t_obs, rw_cache)
    if (any(rej)) reject_any <- reject_any + 1L
    reject_pair <- reject_pair + as.numeric(rej)
  }
  list(any = reject_any / S, pair = reject_pair / S)
}

# Find headline n_star from RW-any discovery
headline_n <- results_df$n_per_arm_80_rw_any[results_df$control_dgp == "uniform_K4" &
                                             results_df$tau_shape   == "diffuse_PL"]
rw_cache_uniform <- build_rw_crit_cache(build_corr(Sigma_Y_uniform), alpha = alpha, B = rw_B_null)

set.seed(seed)
cat(sprintf("\n=== Simulation check (uniform control, diffuse tau, S=%d) ===\n", sim_S))
sim_results <- list()
for (n_check in c(headline_n - 200, headline_n, headline_n + 200)) {
  if (n_check > 0) {
    sp <- sim_power_phase1_diffuse_rw(n_check, rw_cache_uniform, S = sim_S)
    cat(sprintf("  n_per_arm = %4d  empirical RW any-signal power = %.3f\n", n_check, sp$any))
    sim_results[[length(sim_results) + 1]] <- tibble(
      n_per_arm = n_check,
      empirical_rw_any_power = sp$any,
      S = sim_S
    )
  }
}
sim_results_df <- bind_rows(sim_results)

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------

dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
write_csv(results_df,        file.path(output_dir, "power_n_required.csv"))
write_csv(power_curve_df,    file.path(output_dir, "power_curve.csv"))
write_csv(sim_results_df,    file.path(output_dir, "power_simulation_check.csv"))
write_csv(rw_pair_n_required_df, file.path(output_dir, "power_rw_pair_n_required.csv"))

# Also write the candidate tau vectors as a small reference file
tau_table <- tibble(
  pair_id              = pairs$pair_id,
  tau_diffuse_PL       = tau_diffuse,
  tau_pilot_proportional = tau_pilot_scaled,
  tau_pilot_observed   = tau_pilot
)
write_csv(tau_table, file.path(output_dir, "power_tau_candidates.csv"))

# -----------------------------------------------------------------------------
# Figure: power curves
# -----------------------------------------------------------------------------

dir.create(figures_dir, recursive = TRUE, showWarnings = FALSE)

power_long <- power_curve_df %>%
  mutate(cell = paste0(control_dgp, " / ", tau_shape)) %>%
  pivot_longer(cols = c(power_rw_any, power_wald, power_tmax),
               names_to = "statistic", values_to = "power") %>%
  mutate(statistic = dplyr::recode(statistic,
                                   power_rw_any = "RW any-signal discovery",
                                   power_wald = "Joint Wald",
                                   power_tmax = "T_max"))

p_pow <- ggplot(power_long,
                aes(x = n_per_arm, y = power, color = cell, linetype = cell)) +
  geom_line(linewidth = 0.9) +
  geom_hline(yintercept = power_target, linetype = "dashed", color = "grey30") +
  geom_hline(yintercept = alpha, linetype = "dotted", color = "grey60") +
  facet_wrap(~ statistic) +
  scale_y_continuous(limits = c(0, 1), breaks = seq(0, 1, 0.2)) +
  scale_color_manual(values = c(
    "phase1_empirical / diffuse_PL"          = "#1B4F72",
    "phase1_empirical / pilot_proportional"  = "#117A65",
    "uniform_K4 / diffuse_PL"                = "#B03A2E",
    "uniform_K4 / pilot_proportional"        = "#7D3C98"
  )) +
  scale_linetype_manual(values = c(
    "phase1_empirical / diffuse_PL"          = "solid",
    "phase1_empirical / pilot_proportional"  = "solid",
    "uniform_K4 / diffuse_PL"                = "dashed",
    "uniform_K4 / pilot_proportional"        = "dashed"
  )) +
  labs(
    title    = "Outcome 1 power: RW discovery, joint Wald, and T_max",
    subtitle = sprintf("RMS pairwise shift = %.0f pp; alpha = %.2f; power target = %.0f%%",
                       100 * target_rms, alpha, 100 * power_target),
    x        = "n per arm (balanced design)",
    y        = "Power",
    color    = "Control DGP / tau shape",
    linetype = "Control DGP / tau shape"
  ) +
  theme_minimal(base_size = 12) +
  theme(legend.position = "bottom",
        legend.box = "vertical")

ggsave(file.path(figures_dir, "power_curves.png"), p_pow,
       width = 12, height = 6, dpi = 150)

# -----------------------------------------------------------------------------
# Console summary
# -----------------------------------------------------------------------------

cat("\n=== Tau candidates (each scaled to RMS = 3 pp) ===\n")
print(tau_table %>% mutate(across(where(is.numeric), ~ round(., 4))))

cat("\n=== Headline numbers ===\n")
print(results_df)

# -----------------------------------------------------------------------------
# DiD variant: power under a within-respondent pre/post design on both arms.
# Uses phase 2's empirical Y_pre/Y_post to estimate Sigma_Delta.
# This is conservative: a true control arm with no treatment between waves
# would have higher test-retest rho -> smaller Sigma_Delta -> easier to detect.
# -----------------------------------------------------------------------------

cat("\n=== DiD variant: empirical panel pre/post (phase 2 calibration) ===\n")

phase2_full <- read_csv(treatment_input_path, show_col_types = FALSE) %>%
  filter(!is.na(initial_ranking), !is.na(final_ranking),
         initial_ranking != "", final_ranking != "") %>%
  distinct(user_id, .keep_all = TRUE)

initial_rankings <- lapply(phase2_full$initial_ranking, parse_ranking)
final_rankings   <- lapply(phase2_full$final_ranking,   parse_ranking)

Y_pre  <- build_indicator_matrix_from_idx(initial_rankings,
                                          pairs$first, pairs$second, option_codes)
Y_post <- build_indicator_matrix_from_idx(final_rankings,
                                          pairs$first, pairs$second, option_codes)
DY     <- Y_post - Y_pre
Sigma_Delta_raw <- cov(DY)

per_pair_rho <- sapply(seq_len(P), function(p) {
  v_pre  <- var(Y_pre[, p]); v_post <- var(Y_post[, p])
  if (v_pre == 0 || v_post == 0) 1 else cor(Y_pre[, p], Y_post[, p])
})
mean_rho       <- mean(per_pair_rho)
var_cross_ph2  <- mean(diag(cov(Y_post)))
var_paired_ph2 <- mean(diag(Sigma_Delta_raw))
vr_factor_raw  <- var_paired_ph2 / var_cross_ph2

# Regularization: cap per-pair test-retest correlation at rho_max to avoid
# zero-variance artifacts at n_phase2 = 18. With cross-sectional Var(Y) ~= 0.25
# and the cap rho_max = 0.95, the floor on Var(ΔY[p]) is 2*0.25*0.05 = 0.025.
rho_max     <- 0.95
diag_floor  <- 2 * 0.25 * (1 - rho_max)
diag_reg    <- pmax(diag(Sigma_Delta_raw), diag_floor)
# Build regularized Sigma_Delta: keep raw off-diagonals, floor the diagonal,
# then symmetrize and project to nearest PSD via eigendecomposition.
Sigma_Delta_reg <- Sigma_Delta_raw
diag(Sigma_Delta_reg) <- diag_reg
Sigma_Delta_reg <- (Sigma_Delta_reg + t(Sigma_Delta_reg)) / 2
ev <- eigen(Sigma_Delta_reg, symmetric = TRUE)
ev$values <- pmax(ev$values, 1e-8)
Sigma_Delta_reg <- ev$vectors %*% diag(ev$values) %*% t(ev$vectors)
diag(Sigma_Delta_reg) <- diag_reg  # restore exact diagonal after PSD projection

cat(sprintf("  Phase 2 n = %d, mean rho_emp = %.3f (capped at rho_max = %.2f for power calc)\n",
            nrow(Y_pre), mean_rho, rho_max))
cat(sprintf("  Var(Y_post) mean diag                       = %.4f\n", var_cross_ph2))
cat(sprintf("  Var(Y_post - Y_pre) mean diag (raw)         = %.4f  (vr factor = %.3f)\n",
            var_paired_ph2, vr_factor_raw))
cat(sprintf("  Var(Y_post - Y_pre) mean diag (regularized) = %.4f  (vr factor = %.3f)\n",
            mean(diag(Sigma_Delta_reg)), mean(diag(Sigma_Delta_reg)) / var_cross_ph2))
cat(sprintf("  diag floor = 2*0.25*(1-%.2f) = %.4f\n", rho_max, diag_floor))

results_did       <- list()
power_curve_did   <- list()
did_rw_pair_n_required <- list()

# Two Sigma_Delta variants:
#   "parametric" (headline): Sigma_Delta = 2 * Sigma_Y_phase1 * (1 - rho_bar)
#       — same eigenstructure as the cross-sectional, scaled by the empirical
#       average variance-reduction factor. Stable, interpretable.
#   "regularized_empirical" (sensitivity): phase 2's own Sigma_Delta_emp with
#       diagonal floored at 2 * 0.25 * (1 - 0.95) = 0.025 to handle the
#       n_phase2 = 18 zero-variance artifact.
Sigma_Delta_param <- 2 * Sigma_Y_pilot * (1 - mean_rho)

did_variants <- list(
  list(label = "parametric",            Sigma = Sigma_Delta_param),
  list(label = "regularized_empirical", Sigma = Sigma_Delta_reg)
)

set.seed(seed)
for (variant in did_variants) {
  Sigma_use <- variant$Sigma
  for (tau_label in c("diffuse_PL", "pilot_proportional")) {
    tau_vec <- if (tau_label == "diffuse_PL") tau_diffuse else tau_pilot_scaled

    n_star_wald <- find_n_for_power(tau_vec, Sigma_use, n_grid)

    C_did    <- build_corr(Sigma_use)
    crit_did <- tmax_critical(C_did, alpha = alpha, B = B_mvn)
    tmax_search_did <- find_n_for_tmax_power(tau_vec, Sigma_use, n_grid,
                                              C_did, crit_did,
                                              target = power_target, B = B_mvn)
    n_star_tmax     <- tmax_search_did$n
    tmax_powers_did <- tmax_search_did$powers

    rw_crit_cache_did <- build_rw_crit_cache(C_did, alpha = alpha, B = rw_B_null)
    rw_any_powers_did <- numeric(length(n_grid))
    rw_pair_powers_did <- matrix(NA_real_, nrow = length(n_grid), ncol = P)
    rw_signal_did <- rep(FALSE, P)
    for (k in seq_along(n_grid)) {
      rw_n_did <- rw_power_for_n(n_grid[k], tau_vec, Sigma_use, C_did, rw_crit_cache_did,
                                 B_alt = rw_B_alt, signal_eps = rw_eps)
      rw_any_powers_did[k] <- rw_n_did$power_any_signal
      rw_pair_powers_did[k, ] <- rw_n_did$power_by_pair
      rw_signal_did <- rw_n_did$signal
    }
    idx_any_did <- which(rw_any_powers_did >= power_target)[1]
    n_star_rw_any_did <- if (is.na(idx_any_did)) NA_integer_ else as.integer(n_grid[idx_any_did])
    n_star_rw_pair_did <- sapply(seq_len(P), function(p) {
      idx <- which(rw_pair_powers_did[, p] >= power_target)[1]
      if (is.na(idx)) NA_integer_ else as.integer(n_grid[idx])
    })

    for (k in seq_along(n_grid)) {
      n  <- n_grid[k]
      ap <- asym_power(n, tau_vec, Sigma_use)
      power_curve_did[[length(power_curve_did) + 1]] <- tibble(
        design       = paste0("DiD_", variant$label),
        tau_shape    = tau_label,
        n_per_arm    = n,
        lambda       = ap$lambda,
        rank         = ap$rank,
        crit_wald    = ap$crit,
        power_wald   = ap$power,
        crit_tmax    = crit_did,
        power_tmax   = tmax_powers_did[k],
        power_rw_any = rw_any_powers_did[k]
      )
    }

    results_did[[length(results_did) + 1]] <- tibble(
      design                   = paste0("DiD_", variant$label),
      tau_shape                = tau_label,
      rms_target               = target_rms,
      n_per_arm_80_wald        = n_star_wald,
      n_total_80_wald          = if (is.na(n_star_wald)) NA_integer_ else 2L * n_star_wald,
      n_per_arm_80_tmax        = n_star_tmax,
      n_total_80_tmax          = if (is.na(n_star_tmax)) NA_integer_ else 2L * n_star_tmax,
      n_per_arm_80_rw_any      = n_star_rw_any_did,
      n_total_80_rw_any        = if (is.na(n_star_rw_any_did)) NA_integer_ else 2L * n_star_rw_any_did,
      crit_tmax                = crit_did,
      mean_rho                 = mean_rho,
      var_reduction_factor_raw = vr_factor_raw,
      var_reduction_factor_reg = mean(diag(Sigma_Delta_reg)) / var_cross_ph2,
      rho_max_cap              = rho_max
    )

    did_rw_pair_n_required[[length(did_rw_pair_n_required) + 1]] <- tibble(
      design = paste0("DiD_", variant$label),
      tau_shape = tau_label,
      pair_id = pairs$pair_id,
      is_signal = rw_signal_did,
      n_per_arm_80_rw = as.integer(n_star_rw_pair_did),
      n_total_80_rw = as.integer(2L * n_star_rw_pair_did)
    )
  }
}
results_did_df     <- bind_rows(results_did)
power_curve_did_df <- bind_rows(power_curve_did)
did_rw_pair_n_required_df <- bind_rows(did_rw_pair_n_required)

cat("\n=== DiD 80%-power n requirement ===\n")
print(results_did_df %>% dplyr::select(-mean_rho, -var_reduction_factor_raw,
                                       -var_reduction_factor_reg, -rho_max_cap))

cs_row     <- results_df    %>% filter(control_dgp == "phase1_empirical", tau_shape == "diffuse_PL")
did_param  <- results_did_df %>% filter(design == "DiD_parametric",            tau_shape == "diffuse_PL")
did_regemp <- results_did_df %>% filter(design == "DiD_regularized_empirical", tau_shape == "diffuse_PL")
cat(sprintf("\nCross-sectional vs DiD (diffuse PL alternative; phase1 control):\n"))
cat(sprintf("  RW-any cross-sectional        n* = %4d / arm\n", cs_row$n_per_arm_80_rw_any))
cat(sprintf("  RW-any DiD (parametric)       n* = %4d / arm   ratio %.2fx\n",
            did_param$n_per_arm_80_rw_any, cs_row$n_per_arm_80_rw_any / did_param$n_per_arm_80_rw_any))
cat(sprintf("  RW-any DiD (reg. empirical)   n* = %4d / arm   ratio %.2fx\n",
            did_regemp$n_per_arm_80_rw_any, cs_row$n_per_arm_80_rw_any / did_regemp$n_per_arm_80_rw_any))
cat(sprintf("  Wald  cross-sectional         n* = %4d / arm\n", cs_row$n_per_arm_80_wald))
cat(sprintf("  Wald  DiD (parametric)        n* = %4d / arm   ratio %.2fx\n",
            did_param$n_per_arm_80_wald, cs_row$n_per_arm_80_wald / did_param$n_per_arm_80_wald))
cat(sprintf("  Wald  DiD (reg. empirical)    n* = %4d / arm   ratio %.2fx\n",
            did_regemp$n_per_arm_80_wald, cs_row$n_per_arm_80_wald / did_regemp$n_per_arm_80_wald))
cat(sprintf("  T_max cross-sectional         n* = %4d / arm\n", cs_row$n_per_arm_80_tmax))
cat(sprintf("  T_max DiD (parametric)        n* = %4d / arm   ratio %.2fx\n",
            did_param$n_per_arm_80_tmax, cs_row$n_per_arm_80_tmax / did_param$n_per_arm_80_tmax))
cat(sprintf("  T_max DiD (reg. empirical)    n* = %4d / arm   ratio %.2fx\n",
            did_regemp$n_per_arm_80_tmax, cs_row$n_per_arm_80_tmax / did_regemp$n_per_arm_80_tmax))

rho_table <- tibble(
  pair_id         = pairs$pair_id,
  rho_test_retest = per_pair_rho,
  mean_pre        = colMeans(Y_pre),
  mean_post       = colMeans(Y_post),
  agreement_count = sapply(seq_len(P), function(p) sum(Y_pre[, p] == Y_post[, p])),
  n_phase2        = nrow(Y_pre)
)
write_csv(rho_table,          file.path(output_dir, "did_test_retest_rho.csv"))
write_csv(results_did_df,     file.path(output_dir, "did_n_required.csv"))
write_csv(power_curve_did_df, file.path(output_dir, "did_power_curve.csv"))
write_csv(did_rw_pair_n_required_df, file.path(output_dir, "did_power_rw_pair_n_required.csv"))

power_long_did <- power_curve_did_df %>%
  pivot_longer(cols = c(power_rw_any, power_wald, power_tmax),
               names_to = "statistic", values_to = "power") %>%
  mutate(statistic = dplyr::recode(statistic,
                                   power_rw_any = "RW any-signal discovery",
                                   power_wald = "Joint Wald",
                                   power_tmax = "T_max"),
         design_label = dplyr::recode(design,
                                      DiD_parametric            = "DiD parametric",
                                      DiD_regularized_empirical = "DiD reg. empirical"))

p_pow_did <- ggplot(power_long_did,
                    aes(x = n_per_arm, y = power, color = design_label, linetype = tau_shape)) +
  geom_line(linewidth = 0.9) +
  geom_hline(yintercept = power_target, linetype = "dashed", color = "grey30") +
  geom_hline(yintercept = alpha, linetype = "dotted", color = "grey60") +
  facet_wrap(~ statistic) +
  scale_y_continuous(limits = c(0, 1), breaks = seq(0, 1, 0.2)) +
  scale_color_manual(values = c("DiD parametric"      = "#1B4F72",
                                "DiD reg. empirical"  = "#B03A2E")) +
  scale_linetype_manual(values = c(diffuse_PL = "solid", pilot_proportional = "dashed")) +
  labs(
    title    = "Outcome 1 power under a DiD design",
    subtitle = sprintf("rho_bar = %.2f from phase 2; RMS shift = %.0f pp; alpha = %.2f",
                       mean_rho, 100 * target_rms, alpha),
    x        = "n per arm (balanced; same n for pre and post per respondent)",
    y        = "Power",
    color    = "Sigma_Delta source",
    linetype = "tau shape"
  ) +
  theme_minimal(base_size = 12) +
  theme(legend.position = "bottom", legend.box = "vertical")
ggsave(file.path(figures_dir, "power_curves_did.png"), p_pow_did,
       width = 12, height = 6, dpi = 150)

cat("\nWrote:\n")
cat(sprintf("  %s/power_n_required.csv\n", output_dir))
cat(sprintf("  %s/power_curve.csv\n", output_dir))
cat(sprintf("  %s/power_simulation_check.csv\n", output_dir))
cat(sprintf("  %s/power_tau_candidates.csv\n", output_dir))
cat(sprintf("  %s/power_rw_pair_n_required.csv\n", output_dir))
cat(sprintf("  %s/did_test_retest_rho.csv\n", output_dir))
cat(sprintf("  %s/did_n_required.csv\n", output_dir))
cat(sprintf("  %s/did_power_curve.csv\n", output_dir))
cat(sprintf("  %s/did_power_rw_pair_n_required.csv\n", output_dir))
cat(sprintf("  %s/power_curves.png\n", figures_dir))
cat(sprintf("  %s/power_curves_did.png\n", figures_dir))

cat("\nDone.\n")
