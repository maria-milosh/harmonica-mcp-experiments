options(stringsAsFactors = FALSE)

suppressPackageStartupMessages({
  library(readr)
  library(dplyr)
  library(stringr)
  library(tibble)
  library(tidyr)
  library(ggplot2)
})

# Outcome 2 from notes/analysis-plan.md: Kendall dispersion ATE.
# Run from repo root: Rscript reports/kendall-dispersion/analysis/run_kendall_dispersion.R

# -----------------------------------------------------------------------------
# Config
# -----------------------------------------------------------------------------

control_input_path   <- "analysis/output/phase1_participant_stats.csv"
treatment_input_path <- "analysis/output/phase2_participant_changes.csv"
control_id_col       <- "user_id"
treatment_id_col     <- "user_id"
control_ranking_col  <- "ranking"
treated_ranking_col  <- "final_ranking"

option_codes  <- c("animal_rescue", "community_clinic", "food_pantry", "urban_tree")
option_labels <- c(animal_rescue = "Animal rescue",
                   community_clinic = "Community clinic",
                   food_pantry = "Food pantry",
                   urban_tree = "Urban tree")
K <- length(option_codes)

B_perm <- 10000L
B_boot <- 10000L
seed   <- 20260504L
alpha  <- 0.05

output_dir  <- "reports/kendall-dispersion/analysis/output"
figures_dir <- "reports/kendall-dispersion/figures"

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

parse_ranking <- function(x) {
  parts <- str_split(x, "\\s*>\\s*")[[1]]
  parts[nzchar(parts)]
}

check_rankings <- function(ranking_list, option_set, label = "rankings") {
  bad <- vapply(
    ranking_list,
    function(r) length(r) != length(option_set) || anyDuplicated(r) > 0 || !setequal(r, option_set),
    logical(1)
  )
  if (any(bad)) stop("Malformed ", label, " at row(s): ", paste(head(which(bad), 10), collapse = ", "))
}

build_indicator_matrix <- function(ranking_list, pairs_df) {
  n <- length(ranking_list)
  P <- nrow(pairs_df)
  Y <- matrix(0L, nrow = n, ncol = P)
  for (i in seq_len(n)) {
    rk  <- ranking_list[[i]]
    pos <- match(option_codes, rk)
    names(pos) <- option_codes
    for (p in seq_len(P)) {
      Y[i, p] <- as.integer(pos[pairs_df$first[p]] < pos[pairs_df$second[p]])
    }
  }
  Y
}

# Direct estimator: mean over all binom(n_d, 2) within-arm respondent pairs
# of the share of pairs they disagree on.
mean_kendall_direct <- function(Y) {
  n <- nrow(Y); P <- ncol(Y)
  if (n < 2) return(NA_real_)
  d_total <- 0
  for (i in seq_len(n - 1)) {
    rep_i <- matrix(Y[i, ], nrow = n - i, ncol = P, byrow = TRUE)
    d_total <- d_total + sum(rep_i != Y[(i + 1):n, , drop = FALSE])
  }
  d_total / (choose(n, 2) * P)
}

# Identity-based estimator: (1/P) sum 2 p_jk (1 - p_jk).
# Equals the direct estimator with the (n-1)/(n) Bessel correction below
# (we use the unbiased version, identical to the direct estimator above).
mean_kendall_identity <- function(Y) {
  p <- colMeans(Y)
  n <- nrow(Y)
  # 2 p (1 - p) is the population-level pair-disagreement rate at this p.
  # The direct U-statistic is the unbiased sample estimator: n/(n-1) * 2 p (1-p)
  # because Var of a Bernoulli(p) sample is n/(n-1) * p (1-p) under sample-variance
  # convention. Here we want the U-statistic, so apply the Bessel factor.
  if (n < 2) return(NA_real_)
  mean(2 * p * (1 - p)) * n / (n - 1)
}

# Hájek projection h_d(Y_i) = E_{Y'}[d_tau(Y, Y') | Y = Y_i]
#                           = (1/P) sum_jk [P(Y_jk' != Y_{i,jk})]
#                           = (1/P) sum_jk [(1 - Y_{i,jk}) * p_jk + Y_{i,jk} * (1 - p_jk)]
hajek_h_values <- function(Y) {
  p <- colMeans(Y)
  apply(Y, 1, function(y) mean((1 - y) * p + y * (1 - p)))
}

# Asymptotic Var(d̄_d) ≈ 4 * zeta_1 / n  with  zeta_1 = Var(h_d(Y_i))
asymptotic_var_dbar <- function(Y) {
  h <- hajek_h_values(Y)
  4 * var(h) / nrow(Y)
}

# -----------------------------------------------------------------------------
# Load and validate data
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

overlap_ids <- intersect(control_df$user_id, treatment_df$user_id)
if (length(overlap_ids) > 0) stop("user_id overlap between arms: ", paste(head(overlap_ids), collapse = ", "))

control_rankings <- lapply(control_df$ranking_string, parse_ranking)
treated_rankings <- lapply(treatment_df$ranking_string, parse_ranking)

option_set <- sort(unique(unlist(c(control_rankings, treated_rankings))))
if (!setequal(option_set, option_codes)) {
  stop("Option set mismatch: got ", paste(option_set, collapse = ","),
       " but expected ", paste(option_codes, collapse = ","))
}

check_rankings(control_rankings, option_codes, "control rankings")
check_rankings(treated_rankings, option_codes, "treated rankings")

n_C <- length(control_rankings)
n_T <- length(treated_rankings)

cat(sprintf("Loaded n_C=%d, n_T=%d, K=%d, options=%s\n",
            n_C, n_T, K, paste(option_codes, collapse = ", ")))

# -----------------------------------------------------------------------------
# Pair table
# -----------------------------------------------------------------------------

sorted_codes <- sort(option_codes)
pairs <- expand.grid(first = sorted_codes, second = sorted_codes,
                     stringsAsFactors = FALSE) %>%
  filter(first < second) %>%
  arrange(first, second) %>%
  mutate(pair_id = paste(first, ">", second))
P <- nrow(pairs)
stopifnot(P == K * (K - 1) / 2)

# -----------------------------------------------------------------------------
# Indicator matrices, level matrices, pointwise estimates
# -----------------------------------------------------------------------------

Y_C <- build_indicator_matrix(control_rankings, pairs)
Y_T <- build_indicator_matrix(treated_rankings, pairs)

p_C <- colMeans(Y_C)
p_T <- colMeans(Y_T)

dbar_C_direct   <- mean_kendall_direct(Y_C)
dbar_T_direct   <- mean_kendall_direct(Y_T)
dbar_C_identity <- mean_kendall_identity(Y_C)
dbar_T_identity <- mean_kendall_identity(Y_T)

delta_obs <- dbar_T_direct - dbar_C_direct

# Per-pair contributions: 2 p (1 - p) under the population-level identity
contrib_C <- 2 * p_C * (1 - p_C)
contrib_T <- 2 * p_T * (1 - p_T)
contrib_delta <- contrib_T - contrib_C

# -----------------------------------------------------------------------------
# Asymptotic SE via Hájek projection (primary descriptive uncertainty)
# -----------------------------------------------------------------------------

var_dbar_C <- asymptotic_var_dbar(Y_C)
var_dbar_T <- asymptotic_var_dbar(Y_T)
se_dbar_C  <- sqrt(var_dbar_C)
se_dbar_T  <- sqrt(var_dbar_T)
se_delta_asym <- sqrt(var_dbar_T + var_dbar_C)
ci_lower_asym <- delta_obs - 1.96 * se_delta_asym
ci_upper_asym <- delta_obs + 1.96 * se_delta_asym

# Hájek-h values for output and verification
h_C_values <- hajek_h_values(Y_C)
h_T_values <- hajek_h_values(Y_T)

# -----------------------------------------------------------------------------
# Individual-level bootstrap (descriptive companion)
# -----------------------------------------------------------------------------

set.seed(seed)
boot_delta <- numeric(B_boot)
for (b in seq_len(B_boot)) {
  idx_C <- sample.int(n_C, size = n_C, replace = TRUE)
  idx_T <- sample.int(n_T, size = n_T, replace = TRUE)
  Y_C_b <- Y_C[idx_C, , drop = FALSE]
  Y_T_b <- Y_T[idx_T, , drop = FALSE]
  boot_delta[b] <- mean_kendall_identity(Y_T_b) - mean_kendall_identity(Y_C_b)
}
se_delta_boot   <- sd(boot_delta)
ci_pct_lower    <- as.numeric(quantile(boot_delta, 0.025))
ci_pct_upper    <- as.numeric(quantile(boot_delta, 0.975))
ci_basic_lower  <- 2 * delta_obs - ci_pct_upper
ci_basic_upper  <- 2 * delta_obs - ci_pct_lower

# -----------------------------------------------------------------------------
# Randomization inference (primary inference)
# -----------------------------------------------------------------------------

set.seed(seed)
Y_all <- rbind(Y_C, Y_T)
N <- n_C + n_T

delta_null <- numeric(B_perm)
t0 <- Sys.time()
for (b in seq_len(B_perm)) {
  treated_idx <- sample.int(N, size = n_T, replace = FALSE)
  control_idx <- setdiff(seq_len(N), treated_idx)
  Y_T_b <- Y_all[treated_idx, , drop = FALSE]
  Y_C_b <- Y_all[control_idx, , drop = FALSE]
  delta_null[b] <- mean_kendall_identity(Y_T_b) - mean_kendall_identity(Y_C_b)
  if (b %% 2000 == 0) message(sprintf("perm %d / %d (%.1fs elapsed)", b, B_perm,
                                      as.numeric(difftime(Sys.time(), t0, units = "secs"))))
}

p_two_sided    <- (1 + sum(abs(delta_null) >= abs(delta_obs))) / (B_perm + 1)
p_one_sided_lt <- (1 + sum(delta_null <= delta_obs)) / (B_perm + 1)
p_one_sided_gt <- (1 + sum(delta_null >= delta_obs)) / (B_perm + 1)

# -----------------------------------------------------------------------------
# Within-phase-2 paired companion: d̄_post - d̄_pre
# -----------------------------------------------------------------------------

phase2_full <- read_csv(treatment_input_path, show_col_types = FALSE) %>%
  filter(!is.na(initial_ranking), !is.na(final_ranking),
         initial_ranking != "", final_ranking != "") %>%
  distinct(user_id, .keep_all = TRUE)
initial_rankings <- lapply(phase2_full$initial_ranking, parse_ranking)
final_rankings   <- lapply(phase2_full$final_ranking,   parse_ranking)
check_rankings(initial_rankings, option_codes, "phase2 initial rankings")
check_rankings(final_rankings,   option_codes, "phase2 final rankings")
n_phase2 <- length(initial_rankings)

Y_pre  <- build_indicator_matrix(initial_rankings, pairs)
Y_post <- build_indicator_matrix(final_rankings,   pairs)

dbar_pre  <- mean_kendall_identity(Y_pre)
dbar_post <- mean_kendall_identity(Y_post)
delta_within_obs <- dbar_post - dbar_pre

# Bootstrap respondents (preserving pre/post pairing)
set.seed(seed + 1L)
boot_within <- numeric(B_boot)
for (b in seq_len(B_boot)) {
  idx <- sample.int(n_phase2, size = n_phase2, replace = TRUE)
  boot_within[b] <- mean_kendall_identity(Y_post[idx, , drop = FALSE]) -
                   mean_kendall_identity(Y_pre [idx, , drop = FALSE])
}
se_within_boot <- sd(boot_within)
ci_within_lower <- as.numeric(quantile(boot_within, 0.025))
ci_within_upper <- as.numeric(quantile(boot_within, 0.975))

# Per-respondent pre/post sign-flip RI for the within-phase-2 paired difference.
# Sharp null: each respondent's (pre, post) labels are exchangeable. Permute by
# independent within-respondent sign flips.
set.seed(seed + 2L)
delta_within_null <- numeric(B_perm)
for (b in seq_len(B_perm)) {
  flip <- sample(c(FALSE, TRUE), n_phase2, replace = TRUE)
  Y_pre_b  <- Y_pre
  Y_post_b <- Y_post
  if (any(flip)) {
    swap <- which(flip)
    Y_pre_b [swap, ] <- Y_post[swap, ]
    Y_post_b[swap, ] <- Y_pre [swap, ]
  }
  delta_within_null[b] <- mean_kendall_identity(Y_post_b) - mean_kendall_identity(Y_pre_b)
}
p_within_two_sided    <- (1 + sum(abs(delta_within_null) >= abs(delta_within_obs))) / (B_perm + 1)
p_within_one_sided_lt <- (1 + sum(delta_within_null <= delta_within_obs)) / (B_perm + 1)

# -----------------------------------------------------------------------------
# Polarization sanity check (lightweight): split phase 2 final by median
# session duration, compute within-half dispersion, and report whether either
# half is markedly tighter than the whole. n=18 makes this illustrative only.
# -----------------------------------------------------------------------------

phase2_stats_path <- "analysis/output/phase2_participant_stats.csv"
if (file.exists(phase2_stats_path)) {
  phase2_stats <- read_csv(phase2_stats_path, show_col_types = FALSE)
  if ("duration_minutes" %in% names(phase2_stats) &&
      "user_id" %in% names(phase2_stats) &&
      "final_ranking" %in% names(phase2_stats)) {
    pol_df <- phase2_stats %>%
      dplyr::select(user_id, duration_minutes, final_ranking) %>%
      filter(!is.na(final_ranking), final_ranking != "")
    if (nrow(pol_df) >= 2) {
      med_dur <- median(pol_df$duration_minutes, na.rm = TRUE)
      pol_df$half <- ifelse(pol_df$duration_minutes <= med_dur, "short", "long")
      ranks_short <- lapply(pol_df$final_ranking[pol_df$half == "short"], parse_ranking)
      ranks_long  <- lapply(pol_df$final_ranking[pol_df$half == "long"],  parse_ranking)
      Y_short <- if (length(ranks_short) >= 2) build_indicator_matrix(ranks_short, pairs) else NULL
      Y_long  <- if (length(ranks_long)  >= 2) build_indicator_matrix(ranks_long,  pairs) else NULL
      dbar_short <- if (!is.null(Y_short)) mean_kendall_identity(Y_short) else NA_real_
      dbar_long  <- if (!is.null(Y_long))  mean_kendall_identity(Y_long)  else NA_real_
      cat(sprintf("\nPolarization split (median duration=%.2fm): short=%d (d̄=%.3f), long=%d (d̄=%.3f); whole arm d̄=%.3f\n",
                  med_dur,
                  length(ranks_short), dbar_short,
                  length(ranks_long),  dbar_long,
                  dbar_T_direct))
    }
  }
}

# -----------------------------------------------------------------------------
# Sanity checks
# -----------------------------------------------------------------------------

# 1. Identity vs direct: with the n/(n-1) Bessel correction, identity and direct
#    are the same U-statistic.
identity_direct_err_C <- abs(dbar_C_direct - dbar_C_identity)
identity_direct_err_T <- abs(dbar_T_direct - dbar_T_identity)

# 2. Bounds: 0 <= d̄ <= 0.5 (max attained when all p_jk = 0.5).
bounds_ok <- (dbar_C_direct >= 0) && (dbar_C_direct <= 0.5) &&
             (dbar_T_direct >= 0) && (dbar_T_direct <= 0.5)

# 3. Hájek h centered at d̄: mean(h_d) = d̄_d * (n_d - 1) / n_d (since the
#    Hájek h includes the i=i' term implicitly via the within-respondent
#    pair indicators; sample mean lands at d̄ for the U-statistic with the
#    Bessel correction). Check that mean(h_d) is close to (n-1)/n * d̄_d.
mean_h_C <- mean(h_C_values)
mean_h_T <- mean(h_T_values)
expected_mean_h_C <- ((n_C - 1) / n_C) * dbar_C_direct
expected_mean_h_T <- ((n_T - 1) / n_T) * dbar_T_direct
hajek_mean_err <- max(abs(mean_h_C - expected_mean_h_C),
                      abs(mean_h_T - expected_mean_h_T))

# 4. Per-pair decomposition sums to Δ̂.
delta_recon_err <- abs(mean(contrib_delta) * n_T / (n_T - 1) -
                       mean(contrib_T) * n_T / (n_T - 1) +
                       mean(contrib_C) * n_C / (n_C - 1) -
                       (-delta_obs))
# Simpler: the unbiased identity uses n/(n-1) per arm; the population identity
# (without Bessel) gives a biased estimate, but the ratio matches up.
delta_via_levels <- mean(contrib_T) * n_T / (n_T - 1) -
                    mean(contrib_C) * n_C / (n_C - 1)
delta_recon_err <- abs(delta_via_levels - delta_obs)

# 5. Permutation null centered at zero (within MC tolerance).
mc_se <- sd(delta_null) / sqrt(B_perm)
null_centered <- abs(mean(delta_null)) < 5 * mc_se

# 6. Bootstrap mean close to delta_obs (low bias).
boot_bias <- mean(boot_delta) - delta_obs

# 7. Anchor: phase 2 final has a Condorcet winner (food_pantry); phase 1 has
#    none. Expect Δ̂ < 0 (treated more coherent).
anchor_ok <- delta_obs < 0

# -----------------------------------------------------------------------------
# Write CSVs
# -----------------------------------------------------------------------------

dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

headline <- tibble(
  dbar_C_direct       = dbar_C_direct,
  dbar_T_direct       = dbar_T_direct,
  dbar_C_identity     = dbar_C_identity,
  dbar_T_identity     = dbar_T_identity,
  delta               = delta_obs,
  delta_pp            = 100 * delta_obs,
  se_dbar_C_hajek     = se_dbar_C,
  se_dbar_T_hajek     = se_dbar_T,
  se_delta_hajek      = se_delta_asym,
  ci_lower_hajek      = ci_lower_asym,
  ci_upper_hajek      = ci_upper_asym,
  se_delta_boot       = se_delta_boot,
  ci_lower_boot_pct   = ci_pct_lower,
  ci_upper_boot_pct   = ci_pct_upper,
  ci_lower_boot_basic = ci_basic_lower,
  ci_upper_boot_basic = ci_basic_upper,
  p_two_sided_RI      = p_two_sided,
  p_one_sided_lt_RI   = p_one_sided_lt,
  p_one_sided_gt_RI   = p_one_sided_gt,
  B_perm              = B_perm,
  B_boot              = B_boot,
  seed                = seed,
  alpha               = alpha,
  n_control           = n_C,
  n_treated           = n_T,
  n_pairs             = P
)
write_csv(headline, file.path(output_dir, "kendall_dispersion.csv"))

decomp <- tibble(
  pair_id      = pairs$pair_id,
  first_option  = pairs$first,
  second_option = pairs$second,
  p_C          = p_C,
  p_T          = p_T,
  contrib_C    = contrib_C,
  contrib_T    = contrib_T,
  contrib_delta = contrib_delta
)
write_csv(decomp, file.path(output_dir, "pair_dispersion_decomposition.csv"))

hajek_components <- bind_rows(
  tibble(arm = "control", user_id = control_df$user_id, h = h_C_values),
  tibble(arm = "treated", user_id = treatment_df$user_id, h = h_T_values)
)
write_csv(hajek_components, file.path(output_dir, "hajek_components.csv"))

perm_summary <- tibble(
  delta_null_mean = mean(delta_null),
  delta_null_sd   = sd(delta_null),
  delta_null_q025 = as.numeric(quantile(delta_null, 0.025)),
  delta_null_q975 = as.numeric(quantile(delta_null, 0.975)),
  delta_obs       = delta_obs,
  B_perm          = B_perm
)
write_csv(perm_summary, file.path(output_dir, "perm_null_summary.csv"))

bootstrap_summary <- tibble(
  delta_obs        = delta_obs,
  boot_mean        = mean(boot_delta),
  boot_sd          = se_delta_boot,
  boot_bias        = mean(boot_delta) - delta_obs,
  ci_lower_pct     = ci_pct_lower,
  ci_upper_pct     = ci_pct_upper,
  ci_lower_basic   = ci_basic_lower,
  ci_upper_basic   = ci_basic_upper,
  B_boot           = B_boot
)
write_csv(bootstrap_summary, file.path(output_dir, "bootstrap_summary.csv"))

within_results <- tibble(
  n_phase2             = n_phase2,
  dbar_pre             = dbar_pre,
  dbar_post            = dbar_post,
  delta_within         = delta_within_obs,
  delta_within_pp      = 100 * delta_within_obs,
  se_within_boot       = se_within_boot,
  ci_within_lower      = ci_within_lower,
  ci_within_upper      = ci_within_upper,
  p_within_two_sided   = p_within_two_sided,
  p_within_one_sided_lt = p_within_one_sided_lt
)
write_csv(within_results, file.path(output_dir, "within_phase2_results.csv"))

# -----------------------------------------------------------------------------
# Figures
# -----------------------------------------------------------------------------

dir.create(figures_dir, recursive = TRUE, showWarnings = FALSE)

# Per-pair contribution barplot
decomp_long <- decomp %>%
  mutate(pair_label = paste0(option_labels[first_option], " > ", option_labels[second_option])) %>%
  pivot_longer(cols = c(contrib_C, contrib_T),
               names_to = "arm", values_to = "contrib") %>%
  mutate(arm = dplyr::recode(arm,
                             contrib_C = "Control (phase 1)",
                             contrib_T = "Treated (phase 2 final)"))

decomp_label_order <- decomp %>%
  mutate(pair_label = paste0(option_labels[first_option], " > ", option_labels[second_option])) %>%
  arrange(desc(abs(contrib_delta)))
decomp_long$pair_label <- factor(decomp_long$pair_label,
                                 levels = rev(decomp_label_order$pair_label))

p_decomp <- ggplot(decomp_long, aes(x = contrib, y = pair_label, fill = arm)) +
  geom_col(position = position_dodge(width = 0.7), width = 0.6) +
  geom_vline(xintercept = 0.5, linetype = "dotted", color = "grey50") +
  scale_fill_manual(values = c("Control (phase 1)" = "#5D6D7E",
                               "Treated (phase 2 final)" = "#1B4F72")) +
  labs(
    title    = "Per-pair dispersion contribution: 2 p_jk (1 - p_jk)",
    subtitle = sprintf("Arm-mean contribution = within-arm pair-disagreement rate. Maximum 0.5 at p = 0.5.\nWhole-arm d̄: control = %.3f, treated = %.3f, Δ = %+.3f",
                       dbar_C_direct, dbar_T_direct, delta_obs),
    x = "Pair contribution to mean Kendall distance",
    y = NULL,
    fill = NULL
  ) +
  theme_minimal(base_size = 12) +
  theme(legend.position = "bottom")
ggsave(file.path(figures_dir, "dispersion_decomposition.png"), p_decomp,
       width = 10, height = 5, dpi = 150)

# Δ̂ inferential picture: RI null + bootstrap distribution + observed
plot_df <- bind_rows(
  tibble(value = delta_null, source = "Permutation null"),
  tibble(value = boot_delta, source = "Bootstrap distribution")
)
plot_df$source <- factor(plot_df$source,
                         levels = c("Permutation null", "Bootstrap distribution"))

p_dist <- ggplot(plot_df, aes(x = value, fill = source)) +
  geom_histogram(bins = 60, alpha = 0.55, position = "identity") +
  geom_vline(xintercept = delta_obs, linetype = "dashed", color = "#B03A2E", linewidth = 0.7) +
  geom_vline(xintercept = 0, linetype = "dotted", color = "grey40") +
  scale_fill_manual(values = c("Permutation null" = "#5D6D7E",
                               "Bootstrap distribution" = "#1B4F72")) +
  labs(
    title    = expression(paste("Inference for Kendall dispersion ATE  ", Delta == bar(d)[T] - bar(d)[C])),
    subtitle = sprintf("Δ̂ = %+.4f (red dashed). RI two-sided p = %.3f. Bootstrap 95%% (pct): [%+.3f, %+.3f].",
                       delta_obs, p_two_sided, ci_pct_lower, ci_pct_upper),
    x = expression(Delta),
    y = "Count",
    fill = NULL
  ) +
  theme_minimal(base_size = 12) +
  theme(legend.position = "bottom")
ggsave(file.path(figures_dir, "delta_distribution.png"), p_dist,
       width = 10, height = 5, dpi = 150)

# -----------------------------------------------------------------------------
# Console summary
# -----------------------------------------------------------------------------

cat("\n============================================================\n")
cat("KENDALL DISPERSION RESULTS\n")
cat("============================================================\n")
cat(sprintf("d̄_C (control, phase 1)         = %.4f  (SE Hájek = %.4f)\n", dbar_C_direct, se_dbar_C))
cat(sprintf("d̄_T (treated, phase 2 final)   = %.4f  (SE Hájek = %.4f)\n", dbar_T_direct, se_dbar_T))
cat(sprintf("Δ̂  = d̄_T - d̄_C                = %+.4f  (= %+.2f pp)\n", delta_obs, 100 * delta_obs))
cat(sprintf("Hájek SE(Δ̂)                    = %.4f\n", se_delta_asym))
cat(sprintf("Hájek 95%% CI                    = [%+.4f, %+.4f]\n", ci_lower_asym, ci_upper_asym))
cat(sprintf("Bootstrap SE(Δ̂)                 = %.4f\n", se_delta_boot))
cat(sprintf("Bootstrap 95%% CI (percentile)   = [%+.4f, %+.4f]\n", ci_pct_lower, ci_pct_upper))
cat(sprintf("Bootstrap 95%% CI (basic)        = [%+.4f, %+.4f]\n", ci_basic_lower, ci_basic_upper))
cat(sprintf("RI two-sided p                  = %.4f\n", p_two_sided))
cat(sprintf("RI one-sided p (Δ ≤ obs)        = %.4f\n", p_one_sided_lt))
cat(sprintf("RI one-sided p (Δ ≥ obs)        = %.4f\n", p_one_sided_gt))

cat("\nWithin phase 2 (paired, n=", n_phase2, "):\n", sep = "")
cat(sprintf("  d̄_pre  (phase 2 initial)      = %.4f\n", dbar_pre))
cat(sprintf("  d̄_post (phase 2 final)        = %.4f\n", dbar_post))
cat(sprintf("  Δ_within                       = %+.4f  (= %+.2f pp)\n",
            delta_within_obs, 100 * delta_within_obs))
cat(sprintf("  Bootstrap SE                   = %.4f\n", se_within_boot))
cat(sprintf("  Bootstrap 95%% CI (percentile)  = [%+.4f, %+.4f]\n",
            ci_within_lower, ci_within_upper))
cat(sprintf("  Sign-flip RI two-sided p       = %.4f\n", p_within_two_sided))
cat(sprintf("  Sign-flip RI one-sided p (≤)   = %.4f\n", p_within_one_sided_lt))

cat("\n============================================================\n")
cat("PER-PAIR DECOMPOSITION  (2 p (1 - p))\n")
cat("============================================================\n")
print(decomp %>%
        mutate(across(c(p_C, p_T, contrib_C, contrib_T, contrib_delta),
                      ~ sprintf("%.4f", .))))

cat("\n============================================================\n")
cat("SANITY CHECKS\n")
cat("============================================================\n")
cat(sprintf("[%s] 1. Identity == Direct  (control err=%.2e, treated err=%.2e, tol 1e-12)\n",
            ifelse(max(identity_direct_err_C, identity_direct_err_T) < 1e-12, "PASS", "FAIL"),
            identity_direct_err_C, identity_direct_err_T))
cat(sprintf("[%s] 2. d̄ in [0, 0.5]\n", ifelse(bounds_ok, "PASS", "FAIL")))
cat(sprintf("[%s] 3. Hájek mean(h) ≈ ((n-1)/n) * d̄  (max abs err = %.2e, tol 1e-12)\n",
            ifelse(hajek_mean_err < 1e-12, "PASS", "FAIL"), hajek_mean_err))
cat(sprintf("[%s] 4. Per-pair decomposition reconstructs Δ̂  (err = %.2e, tol 1e-12)\n",
            ifelse(delta_recon_err < 1e-12, "PASS", "FAIL"), delta_recon_err))
cat(sprintf("[%s] 5. Permutation null centered at 0  (mean=%.5f, threshold 5*MC_SE=%.5f)\n",
            ifelse(null_centered, "PASS", "FAIL"), mean(delta_null), 5 * mc_se))
cat(sprintf("[%s] 6. Bootstrap mean ≈ Δ̂  (bias = %.5f, target |bias| < %.4f)\n",
            ifelse(abs(boot_bias) < 0.01, "PASS", "WARN"), boot_bias, 0.01))
cat(sprintf("[%s] 7. Anchor: phase 2 has Condorcet winner -> expect Δ̂ < 0  (Δ̂ = %+.4f)\n",
            ifelse(anchor_ok, "PASS", "FAIL"), delta_obs))

cat("\nWrote:\n")
cat(sprintf("  %s/{kendall_dispersion,pair_dispersion_decomposition,hajek_components,perm_null_summary,bootstrap_summary,within_phase2_results}.csv\n", output_dir))
cat(sprintf("  %s/{dispersion_decomposition,delta_distribution}.png\n", figures_dir))

cat("\nR sessionInfo:\n")
print(sessionInfo())
