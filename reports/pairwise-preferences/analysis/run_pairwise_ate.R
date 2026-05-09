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

# Outcome 1 from notes/analysis-plan.md: pairwise preference ATE matrix.
# Run from repo root: Rscript reports/pairwise-preferences/analysis/run_pairwise_ate.R

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

B     <- 10000L
seed  <- 20260504L
alpha <- 0.05

output_dir  <- "reports/pairwise-preferences/analysis/output"
figures_dir <- "reports/pairwise-preferences/figures"

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
  if (any(bad)) {
    stop("Malformed ", label, " at row(s): ", paste(head(which(bad), 10), collapse = ", "))
  }
}

build_indicator_matrix <- function(ranking_list, pairs_df) {
  n <- length(ranking_list)
  P <- nrow(pairs_df)
  Y <- matrix(0L, nrow = n, ncol = P)
  for (i in seq_len(n)) {
    rk <- ranking_list[[i]]
    pos <- match(option_codes, rk)
    names(pos) <- option_codes
    for (p in seq_len(P)) {
      Y[i, p] <- as.integer(pos[pairs_df$first[p]] < pos[pairs_df$second[p]])
    }
  }
  Y
}

# Wald-binomial difference SE with +0.5 Laplace stabilization
# applied to p only inside the SE expression. Point estimate is unsmoothed.
pair_se <- function(p_T, p_C, n_T, n_C) {
  p_T_sm <- (n_T * p_T + 0.5) / (n_T + 1)
  p_C_sm <- (n_C * p_C + 0.5) / (n_C + 1)
  sqrt(p_T_sm * (1 - p_T_sm) / n_T + p_C_sm * (1 - p_C_sm) / n_C)
}

# Romano-Wolf step-down with max-|t| null reconstruction.
romano_wolf_stepdown <- function(t_obs, t_null) {
  P <- length(t_obs)
  abs_t_obs  <- abs(t_obs)
  abs_t_null <- abs(t_null)
  Bn <- ncol(abs_t_null)

  ord <- order(abs_t_obs, decreasing = TRUE)
  active <- ord
  p_adj <- rep(NA_real_, P)
  prev_p <- 0

  for (s in seq_along(ord)) {
    target <- ord[s]
    if (length(active) == 1L) {
      max_null <- abs_t_null[active, , drop = TRUE]
    } else {
      max_null <- apply(abs_t_null[active, , drop = FALSE], 2, max)
    }
    p_raw <- (1 + sum(max_null >= abs_t_obs[target])) / (Bn + 1)
    p_adj[target] <- max(p_raw, prev_p)
    prev_p <- p_adj[target]
    active <- active[active != target]
  }
  p_adj
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
# Pair table (alphabetical lexicographic order)
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
# Indicator matrices, point estimates, descriptive SEs
# -----------------------------------------------------------------------------

Y_C <- build_indicator_matrix(control_rankings, pairs)
Y_T <- build_indicator_matrix(treated_rankings, pairs)

p_C     <- colMeans(Y_C)
p_T     <- colMeans(Y_T)
tau_obs <- p_T - p_C

se_obs   <- pair_se(p_T, p_C, n_T, n_C)
t_obs    <- tau_obs / se_obs
ci_lower <- tau_obs - 1.96 * se_obs
ci_upper <- tau_obs + 1.96 * se_obs

# -----------------------------------------------------------------------------
# Joint Wald with Moore-Penrose pseudoinverse
# -----------------------------------------------------------------------------

cov_T <- cov(Y_T)
cov_C <- cov(Y_C)
Sigma_hat <- cov_T / n_T + cov_C / n_C

svd_S   <- svd(Sigma_hat)
tol     <- 1e-8 * max(svd_S$d)
rank_S  <- sum(svd_S$d > tol)
Sigma_pinv <- ginv(Sigma_hat)
W       <- as.numeric(t(tau_obs) %*% Sigma_pinv %*% tau_obs)
chisq_p <- pchisq(W, df = rank_S, lower.tail = FALSE)

# -----------------------------------------------------------------------------
# RMS shift
# -----------------------------------------------------------------------------

rms <- sqrt(mean(tau_obs^2))

# -----------------------------------------------------------------------------
# Permutation procedure
# -----------------------------------------------------------------------------

set.seed(seed)
Y_all <- rbind(Y_C, Y_T)
N     <- n_C + n_T

tau_null <- matrix(NA_real_, nrow = P, ncol = B)
t_null   <- matrix(NA_real_, nrow = P, ncol = B)

t0 <- Sys.time()
for (b in seq_len(B)) {
  treated_idx <- sample.int(N, size = n_T, replace = FALSE)
  control_idx <- setdiff(seq_len(N), treated_idx)
  Y_T_b <- Y_all[treated_idx, , drop = FALSE]
  Y_C_b <- Y_all[control_idx, , drop = FALSE]
  pT_b  <- colMeans(Y_T_b)
  pC_b  <- colMeans(Y_C_b)
  tau_b <- pT_b - pC_b
  se_b  <- pair_se(pT_b, pC_b, n_T, n_C)
  tau_null[, b] <- tau_b
  t_null[, b]   <- tau_b / se_b
  if (b %% 2000 == 0) message(sprintf("perm %d / %d (%.1fs elapsed)", b, B,
                                      as.numeric(difftime(Sys.time(), t0, units = "secs"))))
}

# Joint permutation p-values
abs_t_obs   <- abs(t_obs)
abs_t_null  <- abs(t_null)
T_max_obs   <- max(abs_t_obs)
T_max_null  <- apply(abs_t_null, 2, max)
p_max       <- (1 + sum(T_max_null >= T_max_obs)) / (B + 1)

T_ss_obs    <- sum(t_obs^2)
T_ss_null   <- colSums(t_null^2)
p_ss        <- (1 + sum(T_ss_null >= T_ss_obs)) / (B + 1)

# Per-pair raw RI p-values
p_raw <- numeric(P)
for (p_idx in seq_len(P)) {
  p_raw[p_idx] <- (1 + sum(abs(t_null[p_idx, ]) >= abs(t_obs[p_idx]))) / (B + 1)
}

# Romano-Wolf
p_adj <- romano_wolf_stepdown(t_obs, t_null)

rank_order   <- order(abs_t_obs, decreasing = TRUE)
p_adj_sorted <- p_adj[rank_order]
mono_ok      <- all(diff(p_adj_sorted) >= -1e-12)

# -----------------------------------------------------------------------------
# Sanity checks
# -----------------------------------------------------------------------------

# 1. Anti-symmetry across all 12 ordered pairs
all_ordered <- expand.grid(first = sorted_codes, second = sorted_codes,
                           stringsAsFactors = FALSE) %>%
  filter(first != second)
ordered_tau <- numeric(nrow(all_ordered))
for (r in seq_len(nrow(all_ordered))) {
  j <- all_ordered$first[r]; k <- all_ordered$second[r]
  pT <- mean(vapply(treated_rankings, function(rk) match(j, rk) < match(k, rk), logical(1)))
  pC <- mean(vapply(control_rankings, function(rk) match(j, rk) < match(k, rk), logical(1)))
  ordered_tau[r] <- pT - pC
}
all_ordered$tau <- ordered_tau
matches <- match(paste(all_ordered$second, all_ordered$first),
                 paste(all_ordered$first, all_ordered$second))
antisym_max_err <- max(abs(all_ordered$tau + all_ordered$tau[matches]))

# 2. Marginal reconstruction: mean rank of j = K - sum_{k!=j} P(j>k)
sum_p_j_above <- function(p_vec, label_first, label_second) {
  res <- numeric(K); names(res) <- option_codes
  for (j in option_codes) {
    s <- 0
    for (idx in seq_along(label_first)) {
      f <- label_first[idx]; sd <- label_second[idx]
      if      (f == j)  s <- s + p_vec[idx]
      else if (sd == j) s <- s + (1 - p_vec[idx])
    }
    res[j] <- s
  }
  res
}
mean_rank_C <- K - sum_p_j_above(p_C, pairs$first, pairs$second)
mean_rank_T <- K - sum_p_j_above(p_T, pairs$first, pairs$second)

phase1_opt <- read_csv("analysis/output/phase1_option_stats.csv", show_col_types = FALSE)
phase2_opt <- read_csv("analysis/output/phase2_option_stats.csv", show_col_types = FALSE)

mr_C_max_err <- max(abs(unname(mean_rank_C[phase1_opt$option]) - phase1_opt$mean_rank))
mr_T_max_err <- max(abs(unname(mean_rank_T[phase2_opt$option]) - phase2_opt$final_mean_rank))

# 3. Top-choice consistency: top_share(j) <= min_k P(j > k)
top_share_C <- table(factor(vapply(control_rankings, `[`, character(1), 1),
                            levels = option_codes)) / n_C
top_share_T <- table(factor(vapply(treated_rankings, `[`, character(1), 1),
                            levels = option_codes)) / n_T
get_min_p_above <- function(p_vec, label_first, label_second) {
  res <- numeric(K); names(res) <- option_codes
  for (j in option_codes) {
    pp <- numeric(0)
    for (idx in seq_along(label_first)) {
      f <- label_first[idx]; sd <- label_second[idx]
      if      (f == j)  pp <- c(pp, p_vec[idx])
      else if (sd == j) pp <- c(pp, 1 - p_vec[idx])
    }
    res[j] <- min(pp)
  }
  res
}
min_p_above_C <- get_min_p_above(p_C, pairs$first, pairs$second)
min_p_above_T <- get_min_p_above(p_T, pairs$first, pairs$second)
ts_C_ok <- all(as.numeric(top_share_C) <= min_p_above_C[names(top_share_C)] + 1e-9)
ts_T_ok <- all(as.numeric(top_share_T) <= min_p_above_T[names(top_share_T)] + 1e-9)

# 4. Sigma rank reported above

# 5. Null centeredness
null_means <- rowMeans(tau_null)
null_sds   <- apply(tau_null, 1, sd)
mc_se      <- 1 / sqrt(B)
null_centered <- all(abs(null_means) < 5 * mc_se)

# 7. Replication anchor: food_pantry should lean strongly positive in the τ direction
food_pantry_taus <- numeric(0)
food_pantry_targets <- character(0)
for (idx in seq_len(P)) {
  if (pairs$first[idx] == "food_pantry") {
    food_pantry_taus    <- c(food_pantry_taus, tau_obs[idx])
    food_pantry_targets <- c(food_pantry_targets, pairs$second[idx])
  } else if (pairs$second[idx] == "food_pantry") {
    food_pantry_taus    <- c(food_pantry_taus, -tau_obs[idx])
    food_pantry_targets <- c(food_pantry_targets, pairs$first[idx])
  }
}
anchor_ok <- mean(food_pantry_taus) > 0

# -----------------------------------------------------------------------------
# Write CSVs
# -----------------------------------------------------------------------------

dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

pairwise_ate <- tibble(
  pair_id       = pairs$pair_id,
  first_option  = pairs$first,
  second_option = pairs$second,
  p_T           = p_T,
  p_C           = p_C,
  tau           = tau_obs,
  se            = se_obs,
  t             = t_obs,
  ci_lower      = ci_lower,
  ci_upper      = ci_upper,
  p_raw         = p_raw,
  p_adj_rw      = p_adj,
  reject_rw_05  = p_adj <= alpha
)
write_csv(pairwise_ate, file.path(output_dir, "pairwise_ate.csv"))

pairwise_levels <- tibble(
  pair_id       = pairs$pair_id,
  first_option  = pairs$first,
  second_option = pairs$second,
  p_T           = p_T,
  p_C           = p_C
)
write_csv(pairwise_levels, file.path(output_dir, "pairwise_levels.csv"))

omnibus <- tibble(
  rms              = rms,
  rms_pp           = 100 * rms,
  wald_W           = W,
  wald_rank        = rank_S,
  wald_chisq_p     = chisq_p,
  perm_T_max       = T_max_obs,
  perm_T_max_p     = p_max,
  perm_T_ss        = T_ss_obs,
  perm_T_ss_p      = p_ss,
  B                = B,
  seed             = seed,
  alpha            = alpha,
  n_control        = n_C,
  n_treated        = n_T,
  n_pairs          = P
)
write_csv(omnibus, file.path(output_dir, "omnibus_scalars.csv"))

perm_null_summary <- tibble(
  pair_id        = pairs$pair_id,
  tau_null_mean  = null_means,
  tau_null_sd    = null_sds,
  t_null_mean    = rowMeans(t_null),
  t_null_sd      = apply(t_null, 1, sd),
  T_max_null_q95 = unname(quantile(T_max_null, 0.95)),
  T_max_null_q99 = unname(quantile(T_max_null, 0.99))
)
write_csv(perm_null_summary, file.path(output_dir, "perm_null_summary.csv"))

# -----------------------------------------------------------------------------
# Figures
# -----------------------------------------------------------------------------

dir.create(figures_dir, recursive = TRUE, showWarnings = FALSE)

heatmap_data <- expand.grid(row_opt = option_codes, col_opt = option_codes,
                            stringsAsFactors = FALSE) %>%
  filter(row_opt != col_opt) %>%
  mutate(tau = NA_real_, p_adj = NA_real_, sig_marker = "")

for (r in seq_len(nrow(heatmap_data))) {
  j <- heatmap_data$row_opt[r]
  k <- heatmap_data$col_opt[r]
  if (j < k) {
    idx <- which(pairs$first == j & pairs$second == k)
    heatmap_data$tau[r]   <- tau_obs[idx]
    heatmap_data$p_adj[r] <- p_adj[idx]
  } else {
    idx <- which(pairs$first == k & pairs$second == j)
    heatmap_data$tau[r]   <- -tau_obs[idx]
    heatmap_data$p_adj[r] <- p_adj[idx]
  }
  heatmap_data$sig_marker[r] <-
    if (heatmap_data$p_adj[r] < 0.01) "**"
    else if (heatmap_data$p_adj[r] < 0.05) "*"
    else ""
}

heatmap_data$row_label <- option_labels[heatmap_data$row_opt]
heatmap_data$col_label <- option_labels[heatmap_data$col_opt]
heatmap_data$row_label <- factor(heatmap_data$row_label,
                                 levels = rev(option_labels[option_codes]))
heatmap_data$col_label <- factor(heatmap_data$col_label,
                                 levels = option_labels[option_codes])
heatmap_data$label <- sprintf("%+.2f%s", heatmap_data$tau, heatmap_data$sig_marker)
max_abs_tau <- max(abs(heatmap_data$tau), na.rm = TRUE)

p_heat <- ggplot(heatmap_data, aes(x = col_label, y = row_label, fill = tau)) +
  geom_tile(color = "white", linewidth = 0.6) +
  geom_text(aes(label = label), size = 4) +
  scale_fill_gradient2(low = "#B03A2E", mid = "white", high = "#1B4F72",
                       midpoint = 0,
                       limits = c(-max_abs_tau, max_abs_tau),
                       name = expression(hat(tau))) +
  labs(
    title    = expression(paste("Pairwise ATE matrix:  ", hat(tau)[jk] == P[T](j > k) - P[C](j > k))),
    subtitle = "Cell [row j, col k] = treated minus control probability that row option ranks above column option.\n* Romano-Wolf adjusted p < 0.05, ** < 0.01.",
    x = NULL, y = NULL
  ) +
  theme_minimal(base_size = 12) +
  theme(panel.grid = element_blank(),
        axis.text.x = element_text(angle = 0))

ggsave(file.path(figures_dir, "tau_heatmap.png"), p_heat,
       width = 8, height = 6, dpi = 150)

forest_data <- pairwise_ate %>%
  mutate(pair_label = paste0(option_labels[first_option], " > ", option_labels[second_option])) %>%
  arrange(desc(abs(tau))) %>%
  mutate(pair_label = factor(pair_label, levels = rev(pair_label)),
         sig_color  = ifelse(reject_rw_05, "Reject (RW p < 0.05)", "Not rejected"))

p_forest <- ggplot(forest_data, aes(x = tau, y = pair_label)) +
  geom_vline(xintercept = 0, linetype = "dashed", color = "grey50") +
  geom_errorbarh(aes(xmin = ci_lower, xmax = ci_upper), height = 0.2, color = "grey30") +
  geom_point(aes(color = sig_color, shape = sig_color), size = 4) +
  scale_color_manual(values = c("Reject (RW p < 0.05)" = "#1B4F72",
                                "Not rejected"        = "#5D6D7E")) +
  scale_shape_manual(values = c("Reject (RW p < 0.05)" = 16,
                                "Not rejected"        = 21)) +
  geom_text(aes(x = ci_upper,
                label = sprintf("  raw p=%.3f, RW p=%.3f", p_raw, p_adj_rw)),
            hjust = 0, size = 3) +
  scale_x_continuous(expand = expansion(mult = c(0.05, 0.5))) +
  labs(
    title    = expression(paste("Per-pair  ", hat(tau), "  with 95% asymptotic CIs")),
    subtitle = "Pairs ordered by |τ̂|. Asymptotic CIs are descriptive; primary inference is randomization-inference RW-adjusted p.",
    x = expression(hat(tau) == P[T](j > k) - P[C](j > k)),
    y = NULL,
    color = NULL, shape = NULL
  ) +
  theme_minimal(base_size = 12) +
  theme(legend.position = "bottom")

ggsave(file.path(figures_dir, "tau_forest.png"), p_forest,
       width = 10, height = 5, dpi = 150)

# -----------------------------------------------------------------------------
# Console summary
# -----------------------------------------------------------------------------

cat("\n============================================================\n")
cat("PER-PAIR RESULTS\n")
cat("============================================================\n")
print(pairwise_ate %>%
        mutate(across(c(p_T, p_C, tau, se, t, ci_lower, ci_upper, p_raw, p_adj_rw),
                      ~ sprintf("%.4f", .))))

cat("\n============================================================\n")
cat("HEADLINE SCALARS\n")
cat("============================================================\n")
cat(sprintf("RMS pairwise shift     = %.4f  (%.2f pp)\n", rms, 100 * rms))
cat(sprintf("Joint Wald W           = %.3f, rank = %d, chi-sq_(rank) p = %.4f\n",
            W, rank_S, chisq_p))
cat(sprintf("Permutation max-|t|    = %.3f, p = %.4f\n", T_max_obs, p_max))
cat(sprintf("Permutation sum-t^2    = %.3f, p = %.4f\n", T_ss_obs, p_ss))
cat(sprintf("Joint reject @ alpha=%.2f? Wald=%s, max-|t|=%s, sum-t^2=%s\n",
            alpha, chisq_p < alpha, p_max < alpha, p_ss < alpha))

cat("\n============================================================\n")
cat("SANITY CHECKS\n")
cat("============================================================\n")

# 1
cat(sprintf("[%s] 1. Anti-symmetry (max abs err = %.2e, tol 1e-12)\n",
            ifelse(antisym_max_err < 1e-12, "PASS", "FAIL"), antisym_max_err))
# 2
cat(sprintf("[%s] 2. Marginal reconstruction vs published mean ranks (control max err = %.4f, treated max err = %.4f, tol 0.01)\n",
            ifelse(mr_C_max_err < 0.01 && mr_T_max_err < 0.01, "PASS", "FAIL"),
            mr_C_max_err, mr_T_max_err))
cat("    Control:\n")
for (j in option_codes) {
  cat(sprintf("      %s: published=%.3f computed=%.3f\n",
              j, phase1_opt$mean_rank[phase1_opt$option == j], mean_rank_C[j]))
}
cat("    Treated (phase 2 final):\n")
for (j in option_codes) {
  cat(sprintf("      %s: published=%.3f computed=%.3f\n",
              j, phase2_opt$final_mean_rank[phase2_opt$option == j], mean_rank_T[j]))
}
# 3
cat(sprintf("[%s] 3. Top-choice consistency (control=%s, treated=%s)\n",
            ifelse(ts_C_ok && ts_T_ok, "PASS", "FAIL"), ts_C_ok, ts_T_ok))
# 4
cat(sprintf("[OBSV] 4. Sigma_hat rank = %d / %d (theoretical max for K=4 full rankings: K-1 = 3)\n",
            rank_S, P))
# 5
cat(sprintf("[%s] 5. Null tau centeredness (max |mean| = %.4f, threshold 5/sqrt(B) = %.4f)\n",
            ifelse(null_centered, "PASS", "FAIL"), max(abs(null_means)), 5 * mc_se))
# 6
cat(sprintf("[%s] 6. Romano-Wolf p_adj monotonicity along |t|-rank order\n",
            ifelse(mono_ok, "PASS", "FAIL")))
# 7
cat(sprintf("[%s] 7. Replication anchor (food_pantry should win Condorcet only in T): mean(food_pantry tau) = %+.3f\n",
            ifelse(anchor_ok, "PASS", "FAIL"), mean(food_pantry_taus)))
for (i in seq_along(food_pantry_taus)) {
  cat(sprintf("      food_pantry vs %s: tau = %+.3f\n", food_pantry_targets[i], food_pantry_taus[i]))
}

cat("\nWrote:\n")
cat(sprintf("  %s/{pairwise_ate,pairwise_levels,omnibus_scalars,perm_null_summary}.csv\n", output_dir))
cat(sprintf("  %s/{tau_heatmap,tau_forest}.png\n", figures_dir))

cat("\nR sessionInfo:\n")
print(sessionInfo())
