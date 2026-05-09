options(stringsAsFactors = FALSE)

suppressPackageStartupMessages({
  library(readr)
  library(dplyr)
  library(stringr)
  library(tibble)
  library(tidyr)
  library(ggplot2)
})

# Power for Outcome 2 (Kendall dispersion ATE Δ = d̄_T - d̄_C).
# Headline: how large does n have to be to detect Δ at 80% power, given
# specified (p^C, p^T) levels? Uses Hájek-projection asymptotic variance
# σ²_d = 4 * Var(h_d(R)) / n_d  with  h_d(R) = (1/P) Σ_jk [(1-Y_{jk}) p^d_jk + Y_{jk}(1 - p^d_jk)].
# Run from repo root: Rscript reports/kendall-dispersion/analysis/run_kendall_dispersion_power.R

# -----------------------------------------------------------------------------
# Config
# -----------------------------------------------------------------------------

control_input_path   <- "analysis/output/phase1_participant_stats.csv"
treatment_input_path <- "analysis/output/phase2_participant_changes.csv"
control_id_col       <- "user_id"
treatment_id_col     <- "user_id"
control_ranking_col  <- "ranking"
treated_ranking_col  <- "final_ranking"

option_codes <- c("animal_rescue", "community_clinic", "food_pantry", "urban_tree")
K <- length(option_codes)

target_rms       <- 0.03                       # match Outcome 1 headline
delta_targets_pp <- c(3, 5, 8, 10)             # absolute pp targets for direct-Δ sweep
power_target     <- 0.80
alpha            <- 0.05
n_grid           <- seq(50, 6000, by = 50)
sim_S            <- 200
seed             <- 20260504L
M_sim            <- 50000L                     # for PL/empirical zeta_1 estimation

output_dir  <- "reports/kendall-dispersion/analysis/output"
figures_dir <- "reports/kendall-dispersion/figures"

# -----------------------------------------------------------------------------
# Helpers (subset from main analysis + Outcome 1 power)
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

build_indicator_matrix <- function(ranking_list, pairs, codes) {
  P <- nrow(pairs)
  n <- length(ranking_list)
  Y <- matrix(0L, nrow = n, ncol = P)
  for (i in seq_len(n)) {
    rk  <- ranking_list[[i]]
    pos <- match(codes, rk)
    names(pos) <- codes
    for (p in seq_len(P)) {
      Y[i, p] <- as.integer(pos[pairs$first[p]] < pos[pairs$second[p]])
    }
  }
  Y
}

draw_pl <- function(n, theta, codes) {
  Kk <- length(theta)
  out <- vector("list", n)
  for (i in seq_len(n)) {
    g <- -log(-log(runif(Kk)))
    out[[i]] <- codes[order(theta + g, decreasing = TRUE)]
  }
  out
}

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

# Identity-form d̄ (population-level: 2 p (1 - p) average; this is the U-stat
# population value, not the n/(n-1) sample-corrected version).
dbar_pop <- function(p) mean(2 * p * (1 - p))

# zeta_1 = Var(h_d(R)) where h_d is the Hájek projection
zeta_1_from_Y <- function(Y) {
  p <- colMeans(Y)
  h <- apply(Y, 1, function(y) mean((1 - y) * p + y * (1 - p)))
  var(h)
}

# -----------------------------------------------------------------------------
# Load pilot, build pair table
# -----------------------------------------------------------------------------

control_raw   <- read_csv(control_input_path,   show_col_types = FALSE)
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

pairs <- build_pair_table(option_codes)
P     <- nrow(pairs)

Y_C_pilot <- build_indicator_matrix(control_rankings, pairs, option_codes)
Y_T_pilot <- build_indicator_matrix(treated_rankings, pairs, option_codes)
p_C_pilot <- colMeans(Y_C_pilot)
p_T_pilot <- colMeans(Y_T_pilot)
tau_pilot <- p_T_pilot - p_C_pilot
rms_pilot <- sqrt(mean(tau_pilot^2))

# -----------------------------------------------------------------------------
# Specify alternatives: 4 cells matching Outcome 1
#  (control DGP) x (treated tau shape, scaled to RMS = 3 pp)
# -----------------------------------------------------------------------------

# Diffuse PL: monotone evenly-spaced utilities on the treated arm
pl_pair_shift <- function(c) {
  theta <- c * seq_len(K)
  pl_pairwise_probs(theta, pairs, option_codes) - 0.5
}
obj_diffuse <- function(c) sqrt(mean(pl_pair_shift(c)^2)) - target_rms
c_star <- uniroot(obj_diffuse, c(0, 1))$root
tau_diffuse <- pl_pair_shift(c_star)

# Pilot-proportional tau, rescaled to RMS = 3 pp
tau_pilot_scaled <- tau_pilot * (target_rms / rms_pilot)

# -----------------------------------------------------------------------------
# Build large simulated populations under each cell's (control, treated) DGP
# so we can compute d̄ and zeta_1 directly.
# -----------------------------------------------------------------------------

set.seed(seed)

# Control DGP samples
M <- M_sim

# Uniform K=4: enumerate all 24 rankings, repeat to size M for stability
unif_perms <- permn(option_codes)
unif_pop_idx <- rep(seq_along(unif_perms), length.out = M)
unif_pop <- unif_perms[unif_pop_idx]
Y_unif_pop <- build_indicator_matrix(unif_pop, pairs, option_codes)

# Phase-1 empirical: bootstrap with replacement
emp1_idx <- sample.int(nrow(Y_C_pilot), size = M, replace = TRUE)
Y_emp1_pop <- Y_C_pilot[emp1_idx, , drop = FALSE]

# Treated DGP for "diffuse" cell: shift control distribution by τ_diffuse via
# PL. With PL the marginals factor cleanly; we draw fresh PL samples at each
# control DGP using the same theta = c_star * seq(K).
theta_T_diffuse <- c_star * seq_len(K)
treated_diffuse_unif <- draw_pl(M, theta_T_diffuse, option_codes)
Y_T_diffuse_unif <- build_indicator_matrix(treated_diffuse_unif, pairs, option_codes)

# For "pilot-proportional" treated under uniform control, the implied p^T is
# 0.5 + tau_pilot_scaled. Sample by independent Bernoulli on each pair? That
# breaks ranking validity. Instead, fit PL utilities to those marginal targets.
# Approximation: choose theta_T such that PL marginals are close to
# 0.5 + tau_pilot_scaled (if achievable). When marginals are inconsistent
# with any PL distribution, we accept a small mismatch and report the actual
# induced p^T at the fitted theta.
fit_pl_to_marginals <- function(target_p, codes, pairs, init = NULL) {
  obj <- function(theta) {
    pp <- pl_pairwise_probs(theta, pairs, codes)
    sum((pp - target_p)^2)
  }
  if (is.null(init)) init <- rep(0, length(codes) - 1)
  fit <- optim(init, function(th) obj(c(0, th)), method = "BFGS",
               control = list(reltol = 1e-10, maxit = 500))
  theta <- c(0, fit$par)
  list(theta = theta, achieved_p = pl_pairwise_probs(theta, pairs, codes), value = fit$value)
}

# pilot-proportional treated under uniform control
pp_target_unif <- 0.5 + tau_pilot_scaled
fit_pp_unif <- fit_pl_to_marginals(pp_target_unif, option_codes, pairs)
treated_pp_unif <- draw_pl(M, fit_pp_unif$theta, option_codes)
Y_T_pp_unif <- build_indicator_matrix(treated_pp_unif, pairs, option_codes)

# diffuse PL under phase-1 empirical control: same theta_T_diffuse, but
# control DGP is empirical -> p^C = p_C_pilot.
treated_diffuse_emp1 <- draw_pl(M, theta_T_diffuse, option_codes)
Y_T_diffuse_emp1 <- build_indicator_matrix(treated_diffuse_emp1, pairs, option_codes)

# pilot-proportional under phase-1 empirical: target p^T = p_C_pilot + tau_pilot_scaled
pp_target_emp1 <- p_C_pilot + tau_pilot_scaled
fit_pp_emp1 <- fit_pl_to_marginals(pp_target_emp1, option_codes, pairs)
treated_pp_emp1 <- draw_pl(M, fit_pp_emp1$theta, option_codes)
Y_T_pp_emp1 <- build_indicator_matrix(treated_pp_emp1, pairs, option_codes)

# -----------------------------------------------------------------------------
# Cell descriptors & zeta_1 / d̄ at the simulated populations
# -----------------------------------------------------------------------------

cell_descriptors <- list(
  list(label = "uniform_K4 / diffuse_PL",          Y_C = Y_unif_pop,  Y_T = Y_T_diffuse_unif),
  list(label = "uniform_K4 / pilot_proportional",  Y_C = Y_unif_pop,  Y_T = Y_T_pp_unif),
  list(label = "phase1_empirical / diffuse_PL",    Y_C = Y_emp1_pop,  Y_T = Y_T_diffuse_emp1),
  list(label = "phase1_empirical / pilot_proportional", Y_C = Y_emp1_pop, Y_T = Y_T_pp_emp1)
)

asym_power_at_n <- function(n_per_arm, zeta_C, zeta_T, delta) {
  var_delta <- 4 * zeta_C / n_per_arm + 4 * zeta_T / n_per_arm
  se <- sqrt(var_delta)
  zcrit <- qnorm(1 - alpha / 2)
  pnorm(abs(delta) / se - zcrit) + pnorm(-abs(delta) / se - zcrit)
}

find_n_for_power <- function(zeta_C, zeta_T, delta, n_grid, target = power_target) {
  pw <- sapply(n_grid, function(n) asym_power_at_n(n, zeta_C, zeta_T, delta))
  idx <- which(pw >= target)[1]
  if (is.na(idx)) NA_integer_ else as.integer(n_grid[idx])
}

results_rms_cells <- list()
power_curves_cells <- list()

for (cell in cell_descriptors) {
  Y_C <- cell$Y_C; Y_T <- cell$Y_T
  zeta_C <- zeta_1_from_Y(Y_C)
  zeta_T <- zeta_1_from_Y(Y_T)
  pC <- colMeans(Y_C); pT <- colMeans(Y_T)
  dC <- dbar_pop(pC); dT <- dbar_pop(pT)
  delta <- dT - dC

  n_star <- find_n_for_power(zeta_C, zeta_T, delta, n_grid)

  results_rms_cells[[length(results_rms_cells) + 1]] <- tibble(
    cell                = cell$label,
    rms_target          = target_rms,
    delta_induced       = delta,
    delta_pp_induced    = 100 * delta,
    dbar_C              = dC,
    dbar_T              = dT,
    zeta_1_C            = zeta_C,
    zeta_1_T            = zeta_T,
    n_per_arm_80        = n_star,
    n_total_80          = if (is.na(n_star)) NA_integer_ else 2L * n_star
  )

  for (n in n_grid) {
    power_curves_cells[[length(power_curves_cells) + 1]] <- tibble(
      cell        = cell$label,
      shape_class = "RMS=3pp Outcome-1 alternative",
      n_per_arm   = n,
      delta       = delta,
      power       = asym_power_at_n(n, zeta_C, zeta_T, delta)
    )
  }
}
results_rms_df <- bind_rows(results_rms_cells)

# -----------------------------------------------------------------------------
# Δ-targeted alternative: directly fix |Δ| ∈ {3, 5, 8, 10} pp.
# Use phase-1 empirical control + a "diffuse PL" treated whose θ is tuned so
# that the induced Δ_d̄ matches the target. This decouples the τ specification
# from the dispersion change so we can ask "what n to detect Δ = -5 pp?"
# -----------------------------------------------------------------------------

build_diffuse_pl_for_delta <- function(target_delta_signed, control_population_Y,
                                       direction_sign = 1) {
  # Use control DGP fixed; sweep theta scale c through PL with monotone utils.
  # Δ(c) = dbar_pop(pT(c)) - dbar_pop(pC). Sign via direction_sign on c.
  pC <- colMeans(control_population_Y)
  dC <- dbar_pop(pC)
  obj <- function(c) {
    theta_T <- c * seq_len(K)
    pT <- pl_pairwise_probs(theta_T, pairs, option_codes)
    (dbar_pop(pT) - dC) - target_delta_signed
  }
  # Monotone increasing |c| -> tighter pT -> Δ more negative when target < 0.
  # We expect target_delta_signed < 0 (treated tighter); search c > 0.
  if (target_delta_signed >= 0) {
    return(NULL)
  }
  fit <- tryCatch(uniroot(obj, c(1e-3, 5)), error = function(e) NULL)
  if (is.null(fit)) return(NULL)
  c_use <- fit$root
  theta_T <- c_use * seq_len(K)
  pT <- pl_pairwise_probs(theta_T, pairs, option_codes)
  list(c = c_use, theta = theta_T, pT = pT)
}

results_delta_cells <- list()
power_curves_delta <- list()
delta_design_grid <- expand.grid(
  control_dgp = c("uniform_K4", "phase1_empirical"),
  delta_pp    = delta_targets_pp,
  stringsAsFactors = FALSE
)
delta_design_grid$delta_signed <- -delta_design_grid$delta_pp / 100

set.seed(seed + 11L)
for (i in seq_len(nrow(delta_design_grid))) {
  control_dgp_label <- delta_design_grid$control_dgp[i]
  delta_signed      <- delta_design_grid$delta_signed[i]
  Y_C_pop <- if (control_dgp_label == "uniform_K4") Y_unif_pop else Y_emp1_pop

  fit <- build_diffuse_pl_for_delta(delta_signed, Y_C_pop)
  if (is.null(fit)) next

  treated_pop_rk <- draw_pl(M, fit$theta, option_codes)
  Y_T_pop <- build_indicator_matrix(treated_pop_rk, pairs, option_codes)

  zeta_C <- zeta_1_from_Y(Y_C_pop)
  zeta_T <- zeta_1_from_Y(Y_T_pop)
  pC <- colMeans(Y_C_pop); pT <- colMeans(Y_T_pop)
  dC <- dbar_pop(pC); dT <- dbar_pop(pT)
  delta_realised <- dT - dC

  n_star <- find_n_for_power(zeta_C, zeta_T, delta_realised, n_grid)

  results_delta_cells[[length(results_delta_cells) + 1]] <- tibble(
    control_dgp           = control_dgp_label,
    delta_target_pp       = delta_design_grid$delta_pp[i],
    delta_realised        = delta_realised,
    delta_realised_pp     = 100 * delta_realised,
    dbar_C                = dC,
    dbar_T                = dT,
    zeta_1_C              = zeta_C,
    zeta_1_T              = zeta_T,
    n_per_arm_80          = n_star,
    n_total_80            = if (is.na(n_star)) NA_integer_ else 2L * n_star
  )

  for (n in n_grid) {
    power_curves_delta[[length(power_curves_delta) + 1]] <- tibble(
      cell        = sprintf("%s / Δ=%dpp", control_dgp_label, delta_design_grid$delta_pp[i]),
      shape_class = "Direct Δ target",
      n_per_arm   = n,
      delta       = delta_realised,
      power       = asym_power_at_n(n, zeta_C, zeta_T, delta_realised)
    )
  }
}
results_delta_df <- bind_rows(results_delta_cells)

# -----------------------------------------------------------------------------
# Simulation verification at the headline Δ-target cell
# (phase-1 empirical control, Δ = -5 pp)
# -----------------------------------------------------------------------------

mean_kendall_identity <- function(Y) {
  p <- colMeans(Y); n <- nrow(Y)
  if (n < 2) return(NA_real_)
  mean(2 * p * (1 - p)) * n / (n - 1)
}

asymp_var_dbar_estimate <- function(Y) {
  p <- colMeans(Y)
  h <- apply(Y, 1, function(y) mean((1 - y) * p + y * (1 - p)))
  4 * var(h) / nrow(Y)
}

sim_one_dataset <- function(n_per_arm, control_pool_Y, theta_T) {
  idx_C <- sample.int(nrow(control_pool_Y), size = n_per_arm, replace = TRUE)
  Y_C_b <- control_pool_Y[idx_C, , drop = FALSE]
  T_rk  <- draw_pl(n_per_arm, theta_T, option_codes)
  Y_T_b <- build_indicator_matrix(T_rk, pairs, option_codes)
  list(Y_C = Y_C_b, Y_T = Y_T_b)
}

sim_z_test_power <- function(n_per_arm, control_pool_Y, theta_T, S) {
  reject <- 0L
  zcrit <- qnorm(1 - alpha / 2)
  for (s in seq_len(S)) {
    one <- sim_one_dataset(n_per_arm, control_pool_Y, theta_T)
    delta_hat <- mean_kendall_identity(one$Y_T) - mean_kendall_identity(one$Y_C)
    se_hat <- sqrt(asymp_var_dbar_estimate(one$Y_T) +
                   asymp_var_dbar_estimate(one$Y_C))
    z <- delta_hat / se_hat
    if (!is.na(z) && abs(z) > zcrit) reject <- reject + 1L
  }
  reject / S
}

# Headline n_star for empirical / Δ=5pp, then check straddle
emp_5pp_row <- results_delta_df %>%
  filter(control_dgp == "phase1_empirical", delta_target_pp == 5)

if (nrow(emp_5pp_row) > 0 && !is.na(emp_5pp_row$n_per_arm_80)) {
  fit5 <- build_diffuse_pl_for_delta(-0.05, Y_emp1_pop)
  headline_n <- emp_5pp_row$n_per_arm_80[1]
  set.seed(seed + 33L)
  sim_results <- list()
  cat(sprintf("\n=== Simulation check (phase-1 empirical, Δ ≈ -5 pp; S=%d) ===\n", sim_S))
  for (n_check in unique(c(max(50, headline_n - 200L),
                           headline_n,
                           headline_n + 200L))) {
    sp <- sim_z_test_power(n_check, Y_emp1_pop, fit5$theta, S = sim_S)
    cat(sprintf("  n_per_arm = %5d  empirical Z-test power = %.3f\n", n_check, sp))
    sim_results[[length(sim_results) + 1]] <- tibble(
      n_per_arm = n_check, empirical_power = sp, S = sim_S
    )
  }
  sim_results_df <- bind_rows(sim_results)
} else {
  sim_results_df <- tibble(n_per_arm = integer(0), empirical_power = numeric(0), S = integer(0))
}

# -----------------------------------------------------------------------------
# DiD variant
# -----------------------------------------------------------------------------
# For Outcome 2 the natural within-design analog is harder to specify cleanly:
# dispersion is intrinsically a between-respondents quantity, so the DiD
# reduction-factor argument from Outcome 1 (variance scales by 2(1 - rho))
# does not directly apply. We do not include a DiD power section; the
# within-phase-2 paired d̄_post - d̄_pre quantity is reported in the main
# analysis script as a triangulation rather than a power-design choice.

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------

dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

write_csv(results_rms_df,   file.path(output_dir, "power_n_required_rms.csv"))
write_csv(results_delta_df, file.path(output_dir, "power_n_required_delta.csv"))
write_csv(bind_rows(power_curves_cells, power_curves_delta),
          file.path(output_dir, "power_curve.csv"))
write_csv(sim_results_df, file.path(output_dir, "power_simulation_check.csv"))

# -----------------------------------------------------------------------------
# Figures
# -----------------------------------------------------------------------------

dir.create(figures_dir, recursive = TRUE, showWarnings = FALSE)

# Figure 1: power curves under the RMS=3pp Outcome-1 alternatives
power_curves_cells_df <- bind_rows(power_curves_cells)
p_rms <- ggplot(power_curves_cells_df,
                aes(x = n_per_arm, y = power, color = cell, linetype = cell)) +
  geom_line(linewidth = 0.9) +
  geom_hline(yintercept = power_target, linetype = "dashed", color = "grey30") +
  geom_hline(yintercept = alpha, linetype = "dotted", color = "grey60") +
  scale_y_continuous(limits = c(0, 1), breaks = seq(0, 1, 0.2)) +
  scale_color_manual(values = c(
    "uniform_K4 / diffuse_PL"               = "#B03A2E",
    "uniform_K4 / pilot_proportional"       = "#7D3C98",
    "phase1_empirical / diffuse_PL"         = "#1B4F72",
    "phase1_empirical / pilot_proportional" = "#117A65"
  )) +
  scale_linetype_manual(values = c(
    "uniform_K4 / diffuse_PL"               = "dashed",
    "uniform_K4 / pilot_proportional"       = "dashed",
    "phase1_empirical / diffuse_PL"         = "solid",
    "phase1_empirical / pilot_proportional" = "solid"
  )) +
  labs(
    title    = "Outcome 2 power under the Outcome-1 RMS = 3 pp alternatives",
    subtitle = "Z-test on Δ = d̄_T - d̄_C with Hájek-projection variance; alpha = 0.05",
    x        = "n per arm (balanced design)",
    y        = "Power",
    color    = "Control DGP / tau shape",
    linetype = "Control DGP / tau shape"
  ) +
  theme_minimal(base_size = 12) +
  theme(legend.position = "bottom",
        legend.box = "vertical")
ggsave(file.path(figures_dir, "power_curves_rms.png"), p_rms,
       width = 12, height = 6, dpi = 150)

# Figure 2: power curves under Δ-targeted alternatives
power_curves_delta_df <- bind_rows(power_curves_delta)
p_delta <- ggplot(power_curves_delta_df,
                  aes(x = n_per_arm, y = power, color = cell, linetype = cell)) +
  geom_line(linewidth = 0.9) +
  geom_hline(yintercept = power_target, linetype = "dashed", color = "grey30") +
  geom_hline(yintercept = alpha, linetype = "dotted", color = "grey60") +
  scale_y_continuous(limits = c(0, 1), breaks = seq(0, 1, 0.2)) +
  labs(
    title    = "Outcome 2 power under Δ-targeted alternatives",
    subtitle = "Treated DGP = monotone-PL with theta tuned so Δ = -3, -5, -8, -10 pp",
    x        = "n per arm (balanced design)",
    y        = "Power",
    color    = "Control DGP / Δ target",
    linetype = "Control DGP / Δ target"
  ) +
  theme_minimal(base_size = 12) +
  theme(legend.position = "bottom",
        legend.box = "vertical")
ggsave(file.path(figures_dir, "power_curves_delta.png"), p_delta,
       width = 12, height = 6, dpi = 150)

# -----------------------------------------------------------------------------
# Console summary
# -----------------------------------------------------------------------------

cat("\n=== Outcome 2 power: Outcome-1 RMS=3pp alternatives ===\n")
print(results_rms_df %>% mutate(across(c(delta_induced, dbar_C, dbar_T, zeta_1_C, zeta_1_T),
                                       ~ round(., 5))))

cat("\n=== Outcome 2 power: Δ-targeted alternatives ===\n")
print(results_delta_df %>% mutate(across(c(delta_realised, dbar_C, dbar_T, zeta_1_C, zeta_1_T),
                                         ~ round(., 5))))

cat("\nWrote:\n")
cat(sprintf("  %s/power_n_required_rms.csv\n",   output_dir))
cat(sprintf("  %s/power_n_required_delta.csv\n", output_dir))
cat(sprintf("  %s/power_curve.csv\n",            output_dir))
cat(sprintf("  %s/power_simulation_check.csv\n", output_dir))
cat(sprintf("  %s/power_curves_rms.png\n",       figures_dir))
cat(sprintf("  %s/power_curves_delta.png\n",     figures_dir))

cat("\nDone.\n")
