options(stringsAsFactors = FALSE)

suppressPackageStartupMessages({
  library(readr)
  library(dplyr)
  library(stringr)
  library(tibble)
  library(tidyr)
  library(ggplot2)
})

# Outcome 2 from notes/analysis-plan.md
# Main estimand: DiD on within-arm Kendall dispersion
#   did = (dbar_T_post - dbar_T_pre) - (dbar_C_post - dbar_C_pre)
#
# Run from repo root:
#   Rscript reports/kendall-dispersion/analysis/run_kendall_dispersion.R

# -----------------------------------------------------------------------------
# Config
# -----------------------------------------------------------------------------

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

B_perm <- 10000L
B_boot <- 10000L
seed   <- 20260510L
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

assert_has_cols <- function(df, cols, label) {
  missing <- setdiff(cols, names(df))
  if (length(missing) > 0) {
    stop(label, " is missing required column(s): ", paste(missing, collapse = ", "),
         "\nAvailable columns: ", paste(names(df), collapse = ", "))
  }
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
    rk <- ranking_list[[i]]
    pos <- match(option_codes, rk)
    names(pos) <- option_codes
    for (p in seq_len(P)) {
      Y[i, p] <- as.integer(pos[pairs_df$first[p]] < pos[pairs_df$second[p]])
    }
  }
  Y
}

mean_kendall_identity <- function(Y) {
  n <- nrow(Y)
  if (n < 2) return(NA_real_)
  p <- colMeans(Y)
  mean(2 * p * (1 - p)) * n / (n - 1)
}

hajek_h_values <- function(Y) {
  p <- colMeans(Y)
  apply(Y, 1, function(y) mean((1 - y) * p + y * (1 - p)))
}

asymptotic_var_dbar <- function(Y) {
  h <- hajek_h_values(Y)
  4 * var(h) / nrow(Y)
}

delta_stats <- function(Y_pre, Y_post) {
  d_pre <- mean_kendall_identity(Y_pre)
  d_post <- mean_kendall_identity(Y_post)
  c(d_pre = d_pre, d_post = d_post, delta = d_post - d_pre)
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
# Pair table + indicator matrices
# -----------------------------------------------------------------------------

sorted_codes <- sort(option_codes)
pairs <- expand.grid(first = sorted_codes, second = sorted_codes,
                     stringsAsFactors = FALSE) %>%
  filter(first < second) %>%
  arrange(first, second) %>%
  mutate(pair_id = paste(first, ">", second))
P <- nrow(pairs)

Y_C_pre  <- build_indicator_matrix(control_pre_rankings, pairs)
Y_C_post <- build_indicator_matrix(control_post_rankings, pairs)
Y_T_pre  <- build_indicator_matrix(treated_pre_rankings, pairs)
Y_T_post <- build_indicator_matrix(treated_post_rankings, pairs)

# -----------------------------------------------------------------------------
# DiD estimate
# -----------------------------------------------------------------------------

st_C <- delta_stats(Y_C_pre, Y_C_post)
st_T <- delta_stats(Y_T_pre, Y_T_post)

did_obs <- unname(st_T["delta"] - st_C["delta"])

# Hájek descriptive SE by combining pre/post arm-level asymptotic variances
# (conservative; primary inference is permutation RI)
se_C_pre  <- sqrt(asymptotic_var_dbar(Y_C_pre))
se_C_post <- sqrt(asymptotic_var_dbar(Y_C_post))
se_T_pre  <- sqrt(asymptotic_var_dbar(Y_T_pre))
se_T_post <- sqrt(asymptotic_var_dbar(Y_T_post))

se_did_hajek <- sqrt(se_C_pre^2 + se_C_post^2 + se_T_pre^2 + se_T_post^2)
ci_lower_hajek <- did_obs - 1.96 * se_did_hajek
ci_upper_hajek <- did_obs + 1.96 * se_did_hajek

# -----------------------------------------------------------------------------
# Bootstrap (paired within respondent, by arm)
# -----------------------------------------------------------------------------

set.seed(seed)
boot_did <- numeric(B_boot)
for (b in seq_len(B_boot)) {
  idx_C <- sample.int(n_C, size = n_C, replace = TRUE)
  idx_T <- sample.int(n_T, size = n_T, replace = TRUE)

  st_C_b <- delta_stats(Y_C_pre[idx_C, , drop = FALSE], Y_C_post[idx_C, , drop = FALSE])
  st_T_b <- delta_stats(Y_T_pre[idx_T, , drop = FALSE], Y_T_post[idx_T, , drop = FALSE])

  boot_did[b] <- st_T_b["delta"] - st_C_b["delta"]
}

se_did_boot  <- sd(boot_did)
ci_pct_lower <- as.numeric(quantile(boot_did, 0.025))
ci_pct_upper <- as.numeric(quantile(boot_did, 0.975))
ci_basic_lower <- 2 * did_obs - ci_pct_upper
ci_basic_upper <- 2 * did_obs - ci_pct_lower

# -----------------------------------------------------------------------------
# Randomization inference (primary)
# -----------------------------------------------------------------------------

set.seed(seed)
Y_pre_all  <- rbind(Y_C_pre, Y_T_pre)
Y_post_all <- rbind(Y_C_post, Y_T_post)
N <- n_C + n_T

did_null <- numeric(B_perm)
t0 <- Sys.time()
for (b in seq_len(B_perm)) {
  treated_idx <- sample.int(N, size = n_T, replace = FALSE)
  control_idx <- setdiff(seq_len(N), treated_idx)

  st_C_b <- delta_stats(Y_pre_all[control_idx, , drop = FALSE],
                        Y_post_all[control_idx, , drop = FALSE])
  st_T_b <- delta_stats(Y_pre_all[treated_idx, , drop = FALSE],
                        Y_post_all[treated_idx, , drop = FALSE])
  did_null[b] <- st_T_b["delta"] - st_C_b["delta"]

  if (b %% 2000 == 0) {
    message(sprintf("perm %d / %d (%.1fs elapsed)", b, B_perm,
                    as.numeric(difftime(Sys.time(), t0, units = "secs"))))
  }
}

p_two_sided <- (1 + sum(abs(did_null) >= abs(did_obs))) / (B_perm + 1)
p_one_sided_lt <- (1 + sum(did_null <= did_obs)) / (B_perm + 1)
p_one_sided_gt <- (1 + sum(did_null >= did_obs)) / (B_perm + 1)

# -----------------------------------------------------------------------------
# Decomposition (level changes)
# -----------------------------------------------------------------------------

p_C_pre  <- colMeans(Y_C_pre)
p_C_post <- colMeans(Y_C_post)
p_T_pre  <- colMeans(Y_T_pre)
p_T_post <- colMeans(Y_T_post)

contrib_C_pre  <- 2 * p_C_pre * (1 - p_C_pre)
contrib_C_post <- 2 * p_C_post * (1 - p_C_post)
contrib_T_pre  <- 2 * p_T_pre * (1 - p_T_pre)
contrib_T_post <- 2 * p_T_post * (1 - p_T_post)

contrib_delta_C <- contrib_C_post - contrib_C_pre
contrib_delta_T <- contrib_T_post - contrib_T_pre
contrib_did <- contrib_delta_T - contrib_delta_C

# -----------------------------------------------------------------------------
# Write outputs
# -----------------------------------------------------------------------------

dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(figures_dir, recursive = TRUE, showWarnings = FALSE)

headline <- tibble(
  estimator = "did",
  dbar_C_pre  = st_C["d_pre"],
  dbar_C_post = st_C["d_post"],
  dbar_T_pre  = st_T["d_pre"],
  dbar_T_post = st_T["d_post"],
  delta_C = st_C["delta"],
  delta_T = st_T["delta"],
  did = did_obs,
  did_pp = 100 * did_obs,
  se_did_hajek = se_did_hajek,
  ci_lower_hajek = ci_lower_hajek,
  ci_upper_hajek = ci_upper_hajek,
  se_did_boot = se_did_boot,
  ci_lower_boot_pct = ci_pct_lower,
  ci_upper_boot_pct = ci_pct_upper,
  ci_lower_boot_basic = ci_basic_lower,
  ci_upper_boot_basic = ci_basic_upper,
  p_two_sided_RI = p_two_sided,
  p_one_sided_lt_RI = p_one_sided_lt,
  p_one_sided_gt_RI = p_one_sided_gt,
  B_perm = B_perm,
  B_boot = B_boot,
  seed = seed,
  alpha = alpha,
  n_control = n_C,
  n_treated = n_T,
  n_pairs = P
)
write_csv(headline, file.path(output_dir, "kendall_dispersion.csv"))

decomp <- tibble(
  pair_id       = pairs$pair_id,
  first_option  = pairs$first,
  second_option = pairs$second,
  p_C_pre       = p_C_pre,
  p_C_post      = p_C_post,
  p_T_pre       = p_T_pre,
  p_T_post      = p_T_post,
  contrib_delta_C = contrib_delta_C,
  contrib_delta_T = contrib_delta_T,
  contrib_did     = contrib_did
)
write_csv(decomp, file.path(output_dir, "pair_dispersion_decomposition.csv"))

hajek_components <- bind_rows(
  tibble(arm = "control_pre",  user_id = control_df$user_id, h = hajek_h_values(Y_C_pre)),
  tibble(arm = "control_post", user_id = control_df$user_id, h = hajek_h_values(Y_C_post)),
  tibble(arm = "treated_pre",  user_id = treatment_df$user_id, h = hajek_h_values(Y_T_pre)),
  tibble(arm = "treated_post", user_id = treatment_df$user_id, h = hajek_h_values(Y_T_post))
)
write_csv(hajek_components, file.path(output_dir, "hajek_components.csv"))

perm_summary <- tibble(
  did_null_mean = mean(did_null),
  did_null_sd   = sd(did_null),
  did_null_q025 = as.numeric(quantile(did_null, 0.025)),
  did_null_q975 = as.numeric(quantile(did_null, 0.975)),
  did_obs       = did_obs,
  B_perm        = B_perm
)
write_csv(perm_summary, file.path(output_dir, "perm_null_summary.csv"))

bootstrap_summary <- tibble(
  did_obs          = did_obs,
  boot_mean        = mean(boot_did),
  boot_sd          = se_did_boot,
  boot_bias        = mean(boot_did) - did_obs,
  ci_lower_pct     = ci_pct_lower,
  ci_upper_pct     = ci_pct_upper,
  ci_lower_basic   = ci_basic_lower,
  ci_upper_basic   = ci_basic_upper,
  B_boot           = B_boot
)
write_csv(bootstrap_summary, file.path(output_dir, "bootstrap_summary.csv"))

# Keep legacy file name; now stores arm-level pre/post deltas and DiD.
within_results <- tibble(
  n_control = n_C,
  n_treated = n_T,
  delta_control = st_C["delta"],
  delta_treated = st_T["delta"],
  did = did_obs,
  did_pp = 100 * did_obs,
  se_boot = se_did_boot,
  ci_lower = ci_pct_lower,
  ci_upper = ci_pct_upper,
  p_two_sided = p_two_sided
)
write_csv(within_results, file.path(output_dir, "within_phase2_results.csv"))

# -----------------------------------------------------------------------------
# Figures
# -----------------------------------------------------------------------------

decomp_long <- decomp %>%
  mutate(pair_label = paste0(option_labels[first_option], " > ", option_labels[second_option])) %>%
  select(pair_label, contrib_delta_C, contrib_delta_T) %>%
  pivot_longer(cols = c(contrib_delta_C, contrib_delta_T),
               names_to = "arm", values_to = "contrib") %>%
  mutate(arm = recode(arm,
                      contrib_delta_C = "Control: post-pre",
                      contrib_delta_T = "Treated: post-pre"))

decomp_order <- decomp %>%
  mutate(pair_label = paste0(option_labels[first_option], " > ", option_labels[second_option])) %>%
  arrange(desc(abs(contrib_did)))
decomp_long$pair_label <- factor(decomp_long$pair_label, levels = rev(decomp_order$pair_label))

p_decomp <- ggplot(decomp_long, aes(x = contrib, y = pair_label, fill = arm)) +
  geom_col(position = position_dodge(width = 0.7), width = 0.6) +
  geom_vline(xintercept = 0, linetype = "dotted", color = "grey50") +
  scale_fill_manual(values = c("Control: post-pre" = "#5D6D7E",
                               "Treated: post-pre" = "#1B4F72")) +
  labs(
    title = "Per-pair change in dispersion contribution: 2 p(1-p)",
    subtitle = sprintf("DiD = (treated post-pre) - (control post-pre) = %+.3f", did_obs),
    x = "Change in pair contribution",
    y = NULL,
    fill = NULL
  ) +
  theme_minimal(base_size = 12) +
  theme(legend.position = "bottom")
ggsave(file.path(figures_dir, "dispersion_decomposition.png"), p_decomp,
       width = 10, height = 5, dpi = 150)

plot_df <- bind_rows(
  tibble(value = did_null, source = "Permutation null"),
  tibble(value = boot_did, source = "Bootstrap distribution")
)
plot_df$source <- factor(plot_df$source,
                         levels = c("Permutation null", "Bootstrap distribution"))

p_dist <- ggplot(plot_df, aes(x = value, fill = source)) +
  geom_histogram(bins = 60, alpha = 0.55, position = "identity") +
  geom_vline(xintercept = did_obs, linetype = "dashed", color = "#B03A2E", linewidth = 0.7) +
  geom_vline(xintercept = 0, linetype = "dotted", color = "grey40") +
  scale_fill_manual(values = c("Permutation null" = "#5D6D7E",
                               "Bootstrap distribution" = "#1B4F72")) +
  labs(
    title = expression(paste("Inference for Kendall DiD ", (bar(d)[T,post]-bar(d)[T,pre])-(bar(d)[C,post]-bar(d)[C,pre]))),
    subtitle = sprintf("Observed DiD = %+.4f. RI two-sided p = %.3f.", did_obs, p_two_sided),
    x = "DiD estimate",
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
cat("KENDALL DISPERSION DID RESULTS\n")
cat("============================================================\n")
cat(sprintf("Control pre/post:  %.4f -> %.4f (delta = %+.4f)\n", st_C["d_pre"], st_C["d_post"], st_C["delta"]))
cat(sprintf("Treated pre/post:  %.4f -> %.4f (delta = %+.4f)\n", st_T["d_pre"], st_T["d_post"], st_T["delta"]))
cat(sprintf("DiD:               %+.4f (%.2f pp)\n", did_obs, 100 * did_obs))
cat(sprintf("RI two-sided p:    %.4f\n", p_two_sided))
cat(sprintf("Bootstrap 95%% CI:  [%+.4f, %+.4f]\n", ci_pct_lower, ci_pct_upper))

cat("\nWrote:\n")
cat(sprintf("  %s/{kendall_dispersion,pair_dispersion_decomposition,hajek_components,perm_null_summary,bootstrap_summary,within_phase2_results}.csv\n", output_dir))
cat(sprintf("  %s/{dispersion_decomposition,delta_distribution}.png\n", figures_dir))

cat("\nR sessionInfo:\n")
print(sessionInfo())
