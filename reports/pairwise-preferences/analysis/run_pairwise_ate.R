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

# Outcome 1 from notes/analysis-plan.md
# Main estimand: DiD on pairwise indicators
#   tau_did_jk = E[(Y_post - Y_pre) | T] - E[(Y_post - Y_pre) | C]
# where Y_ijk = 1{ j ranked above k }.
#
# Run from repo root:
#   Rscript reports/pairwise-preferences/analysis/run_pairwise_ate.R

# -----------------------------------------------------------------------------
# Config
# -----------------------------------------------------------------------------

# Panel data for both arms (must contain pre + post ranking columns).
control_input_path   <- "analysis/output/phase1_participant_changes.csv"
treatment_input_path <- "analysis/output/phase2_participant_changes.csv"

control_id_col       <- "user_id"
treatment_id_col     <- "user_id"
control_pre_col      <- "initial_ranking"
control_post_col     <- "final_ranking"
treated_pre_col      <- "initial_ranking"
treated_post_col     <- "final_ranking"

option_codes  <- c("animal_rescue", "community_clinic", "food_pantry", "urban_tree")
option_labels <- c(animal_rescue = "Animal rescue",
                   community_clinic = "Community clinic",
                   food_pantry = "Food pantry",
                   urban_tree = "Urban tree")
K <- length(option_codes)

B     <- 10000L
seed  <- 20260510L
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

assert_has_cols <- function(df, cols, label) {
  missing <- setdiff(cols, names(df))
  if (length(missing) > 0) {
    stop(label, " is missing required column(s): ", paste(missing, collapse = ", "),
         "\nAvailable columns: ", paste(names(df), collapse = ", "))
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

safe_colvars <- function(M) {
  v <- apply(M, 2, var)
  v[is.na(v)] <- 0
  v
}

delta_se <- function(D_T, D_C, n_T, n_C) {
  v_T <- safe_colvars(D_T)
  v_C <- safe_colvars(D_C)
  pmax(sqrt(v_T / n_T + v_C / n_C), 1e-10)
}

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
# Load and validate panel data
# -----------------------------------------------------------------------------

if (!file.exists(control_input_path)) {
  stop("Control input not found: ", control_input_path)
}
if (!file.exists(treatment_input_path)) {
  stop("Treatment input not found: ", treatment_input_path)
}

control_raw   <- read_csv(control_input_path,   show_col_types = FALSE)
treatment_raw <- read_csv(treatment_input_path, show_col_types = FALSE)

assert_has_cols(control_raw,
                c(control_id_col, control_pre_col, control_post_col),
                "control_input_path")
assert_has_cols(treatment_raw,
                c(treatment_id_col, treated_pre_col, treated_post_col),
                "treatment_input_path")

control_df <- control_raw %>%
  dplyr::select(user_id = all_of(control_id_col),
                pre_ranking = all_of(control_pre_col),
                post_ranking = all_of(control_post_col)) %>%
  filter(!is.na(user_id), !is.na(pre_ranking), !is.na(post_ranking),
         pre_ranking != "", post_ranking != "") %>%
  distinct(user_id, .keep_all = TRUE)

treatment_df <- treatment_raw %>%
  dplyr::select(user_id = all_of(treatment_id_col),
                pre_ranking = all_of(treated_pre_col),
                post_ranking = all_of(treated_post_col)) %>%
  filter(!is.na(user_id), !is.na(pre_ranking), !is.na(post_ranking),
         pre_ranking != "", post_ranking != "") %>%
  distinct(user_id, .keep_all = TRUE)

overlap_ids <- intersect(control_df$user_id, treatment_df$user_id)
if (length(overlap_ids) > 0) {
  stop("user_id overlap between arms: ", paste(head(overlap_ids), collapse = ", "))
}

control_pre_rankings  <- lapply(control_df$pre_ranking,  parse_ranking)
control_post_rankings <- lapply(control_df$post_ranking, parse_ranking)
treated_pre_rankings  <- lapply(treatment_df$pre_ranking,  parse_ranking)
treated_post_rankings <- lapply(treatment_df$post_ranking, parse_ranking)

all_rankings <- c(control_pre_rankings, control_post_rankings,
                  treated_pre_rankings, treated_post_rankings)
option_set <- sort(unique(unlist(all_rankings)))
if (!setequal(option_set, option_codes)) {
  stop("Option set mismatch: got ", paste(option_set, collapse = ","),
       " but expected ", paste(option_codes, collapse = ","))
}

check_rankings(control_pre_rankings, option_codes, "control pre rankings")
check_rankings(control_post_rankings, option_codes, "control post rankings")
check_rankings(treated_pre_rankings, option_codes, "treated pre rankings")
check_rankings(treated_post_rankings, option_codes, "treated post rankings")

n_C <- length(control_pre_rankings)
n_T <- length(treated_pre_rankings)

cat(sprintf("Loaded panel data: n_C=%d, n_T=%d, K=%d\n", n_C, n_T, K))

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
# Build indicators and DiD estimator
# -----------------------------------------------------------------------------

Y_C_pre  <- build_indicator_matrix(control_pre_rankings, pairs)
Y_C_post <- build_indicator_matrix(control_post_rankings, pairs)
Y_T_pre  <- build_indicator_matrix(treated_pre_rankings, pairs)
Y_T_post <- build_indicator_matrix(treated_post_rankings, pairs)

D_C <- Y_C_post - Y_C_pre
D_T <- Y_T_post - Y_T_pre

delta_C <- colMeans(D_C)
delta_T <- colMeans(D_T)
tau_obs <- delta_T - delta_C

# also keep post-level and cross-sectional companion for reporting
p_C_pre  <- colMeans(Y_C_pre)
p_C_post <- colMeans(Y_C_post)
p_T_pre  <- colMeans(Y_T_pre)
p_T_post <- colMeans(Y_T_post)
tau_cross_post <- p_T_post - p_C_post

se_obs   <- delta_se(D_T, D_C, n_T, n_C)
t_obs    <- tau_obs / se_obs
ci_lower <- tau_obs - 1.96 * se_obs
ci_upper <- tau_obs + 1.96 * se_obs

# -----------------------------------------------------------------------------
# Joint Wald (DiD)
# -----------------------------------------------------------------------------

cov_T <- cov(D_T)
cov_C <- cov(D_C)
Sigma_hat <- cov_T / n_T + cov_C / n_C

svd_S <- svd(Sigma_hat)
tol <- 1e-8 * max(svd_S$d)
rank_S <- sum(svd_S$d > tol)
Sigma_pinv <- ginv(Sigma_hat)
W <- as.numeric(t(tau_obs) %*% Sigma_pinv %*% tau_obs)
chisq_p <- pchisq(W, df = rank_S, lower.tail = FALSE)

rms <- sqrt(mean(tau_obs^2))

# -----------------------------------------------------------------------------
# Randomization inference on panel deltas (primary inference)
# -----------------------------------------------------------------------------

set.seed(seed)
D_all <- rbind(D_C, D_T)
N <- n_C + n_T

tau_null <- matrix(NA_real_, nrow = P, ncol = B)
t_null   <- matrix(NA_real_, nrow = P, ncol = B)

t0 <- Sys.time()
for (b in seq_len(B)) {
  treated_idx <- sample.int(N, size = n_T, replace = FALSE)
  control_idx <- setdiff(seq_len(N), treated_idx)

  D_T_b <- D_all[treated_idx, , drop = FALSE]
  D_C_b <- D_all[control_idx, , drop = FALSE]

  tau_b <- colMeans(D_T_b) - colMeans(D_C_b)
  se_b  <- delta_se(D_T_b, D_C_b, n_T, n_C)

  tau_null[, b] <- tau_b
  t_null[, b]   <- tau_b / se_b

  if (b %% 2000 == 0) {
    message(sprintf("perm %d / %d (%.1fs elapsed)", b, B,
                    as.numeric(difftime(Sys.time(), t0, units = "secs"))))
  }
}

abs_t_obs  <- abs(t_obs)
abs_t_null <- abs(t_null)
T_max_obs  <- max(abs_t_obs)
T_max_null <- apply(abs_t_null, 2, max)
p_max      <- (1 + sum(T_max_null >= T_max_obs)) / (B + 1)

T_ss_obs <- sum(t_obs^2)
T_ss_null <- colSums(t_null^2)
p_ss <- (1 + sum(T_ss_null >= T_ss_obs)) / (B + 1)

p_raw <- vapply(seq_len(P), function(p_idx) {
  (1 + sum(abs(t_null[p_idx, ]) >= abs(t_obs[p_idx]))) / (B + 1)
}, numeric(1))

p_adj <- romano_wolf_stepdown(t_obs, t_null)

# -----------------------------------------------------------------------------
# Write outputs
# -----------------------------------------------------------------------------

dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

dir.create(figures_dir, recursive = TRUE, showWarnings = FALSE)

pairwise_ate <- tibble(
  pair_id       = pairs$pair_id,
  first_option  = pairs$first,
  second_option = pairs$second,
  p_T_pre       = p_T_pre,
  p_T_post      = p_T_post,
  p_C_pre       = p_C_pre,
  p_C_post      = p_C_post,
  delta_T       = delta_T,
  delta_C       = delta_C,
  tau_did       = tau_obs,
  tau_post_only = tau_cross_post,
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
  p_T_pre       = p_T_pre,
  p_T_post      = p_T_post,
  p_C_pre       = p_C_pre,
  p_C_post      = p_C_post
)
write_csv(pairwise_levels, file.path(output_dir, "pairwise_levels.csv"))

omnibus <- tibble(
  estimator         = "did",
  rms               = rms,
  rms_pp            = 100 * rms,
  wald_W            = W,
  wald_rank         = rank_S,
  wald_chisq_p      = chisq_p,
  perm_T_max        = T_max_obs,
  perm_T_max_p      = p_max,
  perm_T_ss         = T_ss_obs,
  perm_T_ss_p       = p_ss,
  B                 = B,
  seed              = seed,
  alpha             = alpha,
  n_control         = n_C,
  n_treated         = n_T,
  n_pairs           = P
)
write_csv(omnibus, file.path(output_dir, "omnibus_scalars.csv"))

perm_null_summary <- tibble(
  pair_id        = pairs$pair_id,
  tau_null_mean  = rowMeans(tau_null),
  tau_null_sd    = apply(tau_null, 1, sd),
  t_null_mean    = rowMeans(t_null),
  t_null_sd      = apply(t_null, 1, sd),
  T_max_null_q95 = unname(quantile(T_max_null, 0.95)),
  T_max_null_q99 = unname(quantile(T_max_null, 0.99))
)
write_csv(perm_null_summary, file.path(output_dir, "perm_null_summary.csv"))

# -----------------------------------------------------------------------------
# Figures
# -----------------------------------------------------------------------------

heatmap_data <- expand.grid(row_opt = option_codes, col_opt = option_codes,
                            stringsAsFactors = FALSE) %>%
  filter(row_opt != col_opt) %>%
  mutate(tau = NA_real_, p_adj = NA_real_)

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
}

heatmap_data$row_label <- factor(option_labels[heatmap_data$row_opt],
                                 levels = rev(option_labels[option_codes]))
heatmap_data$col_label <- factor(option_labels[heatmap_data$col_opt],
                                 levels = option_labels[option_codes])
heatmap_data$label <- sprintf("%+.2f%s", heatmap_data$tau,
                              ifelse(heatmap_data$p_adj < 0.01, "**",
                                     ifelse(heatmap_data$p_adj < 0.05, "*", "")))

max_abs_tau <- max(abs(heatmap_data$tau), na.rm = TRUE)

p_heat <- ggplot(heatmap_data, aes(x = col_label, y = row_label, fill = tau)) +
  geom_tile(color = "white", linewidth = 0.6) +
  geom_text(aes(label = label), size = 4) +
  scale_fill_gradient2(low = "#B03A2E", mid = "white", high = "#1B4F72",
                       midpoint = 0,
                       limits = c(-max_abs_tau, max_abs_tau),
                       name = expression(hat(tau)[DiD])) +
  labs(
    title = expression(paste("Pairwise DiD matrix:  ", hat(tau)[jk] == Delta[T](j > k) - Delta[C](j > k))),
    subtitle = "Cell [row j, col k] uses DiD on pair indicators. * RW p<0.05, ** RW p<0.01.",
    x = NULL, y = NULL
  ) +
  theme_minimal(base_size = 12) +
  theme(panel.grid = element_blank())

ggsave(file.path(figures_dir, "tau_heatmap.png"), p_heat,
       width = 8, height = 6, dpi = 150)

forest_data <- pairwise_ate %>%
  mutate(pair_label = paste0(option_labels[first_option], " > ", option_labels[second_option])) %>%
  arrange(desc(abs(tau_did))) %>%
  mutate(pair_label = factor(pair_label, levels = rev(pair_label)),
         sig_color = ifelse(reject_rw_05, "Reject (RW p < 0.05)", "Not rejected"))

p_forest <- ggplot(forest_data, aes(x = tau_did, y = pair_label)) +
  geom_vline(xintercept = 0, linetype = "dashed", color = "grey50") +
  geom_errorbarh(aes(xmin = ci_lower, xmax = ci_upper), height = 0.2, color = "grey30") +
  geom_point(aes(color = sig_color, shape = sig_color), size = 4) +
  scale_color_manual(values = c("Reject (RW p < 0.05)" = "#1B4F72",
                                "Not rejected" = "#5D6D7E")) +
  scale_shape_manual(values = c("Reject (RW p < 0.05)" = 16,
                                "Not rejected" = 21)) +
  labs(
    title = expression(paste("Per-pair DiD ", hat(tau), " with 95% CIs")),
    subtitle = "Primary inference is panel-label permutation RI with Romano-Wolf correction.",
    x = expression(hat(tau)[DiD]),
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
cat("PAIRWISE DID RESULTS\n")
cat("============================================================\n")
print(pairwise_ate %>%
        dplyr::select(pair_id, tau_did, se, t, p_raw, p_adj_rw, reject_rw_05) %>%
        mutate(across(c(tau_did, se, t, p_raw, p_adj_rw), ~ sprintf("%.4f", .))))

cat("\n============================================================\n")
cat("HEADLINE SCALARS\n")
cat("============================================================\n")
cat(sprintf("RMS DiD shift           = %.4f (%.2f pp)\n", rms, 100 * rms))
cat(sprintf("Joint Wald W            = %.3f, rank = %d, chi-sq p = %.4f\n", W, rank_S, chisq_p))
cat(sprintf("Permutation max-|t| p   = %.4f\n", p_max))
cat(sprintf("Permutation sum-t^2 p   = %.4f\n", p_ss))

cat("\nWrote:\n")
cat(sprintf("  %s/{pairwise_ate,pairwise_levels,omnibus_scalars,perm_null_summary}.csv\n", output_dir))
cat(sprintf("  %s/{tau_heatmap,tau_forest}.png\n", figures_dir))

cat("\nR sessionInfo:\n")
print(sessionInfo())
