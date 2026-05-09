options(stringsAsFactors = FALSE)

suppressPackageStartupMessages({
  library(readr)
  library(dplyr)
  library(stringr)
  library(tibble)
  library(tidyr)
  library(ggplot2)
})

# Outcome 3 from notes/analysis-plan.md: rule-output panel under randomization inference.
# Run from repo root: Rscript reports/rule-output-panel/analysis/run_rule_panel.R

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

k_values     <- c(3L, 5L, 7L)   # synthetic group sizes; odd only (no even k per analysis-plan)
k_primary    <- 5L
k_secondary  <- 7L
B            <- 5000L
seed         <- 20260504L
alpha        <- 0.05

output_dir   <- "reports/rule-output-panel/analysis/output"
figures_dir  <- "reports/rule-output-panel/figures"

# Statistic family per k: 4 winner-distribution TVDs + |Delta P(Condorcet exists)|
stat_names <- c("plurality", "borda", "irv", "copeland", "condorcet")

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

# (N, K) ranks matrix: ranks[i, c] = position of option c in voter i's ranking (1 = top).
build_ranks_matrix <- function(ranking_list, codes) {
  n <- length(ranking_list); K_ <- length(codes)
  out <- matrix(NA_integer_, nrow = n, ncol = K_)
  for (i in seq_len(n)) out[i, ] <- match(codes, ranking_list[[i]])
  colnames(out) <- codes
  out
}

# (N, K, K) preference array: pref[i, a, b] = TRUE iff voter i prefers a to b.
build_pref_array <- function(ranks_mat) {
  n <- nrow(ranks_mat); K_ <- ncol(ranks_mat)
  pref <- array(FALSE, dim = c(n, K_, K_))
  for (a in seq_len(K_)) for (b in seq_len(K_)) {
    if (a != b) pref[, a, b] <- ranks_mat[, a] < ranks_mat[, b]
  }
  pref
}

# Compute, vectorised across all G subsets at once, the winner under each rule
# plus the Condorcet winner (0 = none). all_groups is k x G (each column a sorted
# k-subset of 1..N). Returns integer vectors of length G keyed by rule + has_cw.
# IRV is vectorised by branching on the round-1 / round-2 loser identity, so each
# of the at-most K * (K-1) elimination paths is a single vectorised colSums pass.
compute_winners_all <- function(pref_full, ranks_full, all_groups) {
  k <- nrow(all_groups); G <- ncol(all_groups); K_ <- ncol(ranks_full)
  voters_flat <- as.vector(all_groups)        # length k*G

  # Pairwise counts (K, K, G): pair_counts[a, b, g] = #voters in group g preferring a to b.
  pair_counts <- array(0L, dim = c(K_, K_, G))
  for (a in 1:K_) for (b in 1:K_) {
    if (a == b) next
    pair_counts[a, b, ] <- colSums(matrix(pref_full[voters_flat, a, b], nrow = k))
  }

  # Plurality (K x G): top-rank counts per group.
  plur_counts <- matrix(0L, nrow = K_, ncol = G)
  for (a in 1:K_) {
    plur_counts[a, ] <- colSums(matrix(ranks_full[voters_flat, a] == 1L, nrow = k))
  }
  plurality_winner <- max.col(t(plur_counts), ties.method = "first")

  # Borda: score[a, g] = K_ * k - sum_{i in group} ranks[i, a].
  borda_scores <- matrix(0L, nrow = K_, ncol = G)
  for (a in 1:K_) {
    borda_scores[a, ] <- K_ * k - colSums(matrix(ranks_full[voters_flat, a], nrow = k))
  }
  borda_winner <- max.col(t(borda_scores), ties.method = "first")

  # Copeland: score[a, g] = sum_{b != a} I(pair[a,b] > k/2) + 0.5 * I(pair[a,b] == k/2).
  # Strict full rankings -> pair[a,b] + pair[b,a] = k, so half-counts only at even k.
  copeland_scores <- matrix(0, nrow = K_, ncol = G)
  for (a in 1:K_) for (b in 1:K_) {
    if (a == b) next
    copeland_scores[a, ] <- copeland_scores[a, ] +
      as.integer(pair_counts[a, b, ] * 2L >  k) +
      0.5 * as.integer(pair_counts[a, b, ] * 2L == k)
  }
  copeland_winner <- max.col(t(copeland_scores), ties.method = "first")

  # Condorcet: a is CW iff pair[a, b] * 2 > k for all b != a.
  cw_mat <- matrix(TRUE, nrow = K_, ncol = G)
  for (a in 1:K_) for (b in 1:K_) {
    if (a == b) next
    cw_mat[a, ] <- cw_mat[a, ] & (pair_counts[a, b, ] * 2L > k)
  }
  has_cw <- colSums(cw_mat) > 0L
  cw_winner <- integer(G)
  if (any(has_cw)) {
    cw_winner[has_cw] <- max.col(t(cw_mat[, has_cw, drop = FALSE]), ties.method = "first")
  }

  # IRV: vectorised decision tree on round-1 / round-2 losers.
  irv_winner <- integer(G)
  max_plur1  <- apply(plur_counts, 2, max)
  maj_round1 <- max_plur1 * 2L > k
  if (any(maj_round1)) {
    irv_winner[maj_round1] <- max.col(
      t(plur_counts[, maj_round1, drop = FALSE]), ties.method = "first"
    )
  }
  loser_round1 <- max.col(-t(plur_counts), ties.method = "first")  # argmin per group, low-index tie-break

  for (loser1 in 1:K_) {
    branch_mask <- !maj_round1 & (loser_round1 == loser1)
    branch_idx  <- which(branch_mask)
    if (length(branch_idx) == 0L) next
    remaining   <- setdiff(1:K_, loser1)            # K_ - 1 options
    groups_b    <- all_groups[, branch_idx, drop = FALSE]
    voters_flat_b <- as.vector(groups_b)

    sub_ranks  <- ranks_full[voters_flat_b, remaining, drop = FALSE]
    top_in_rem <- remaining[max.col(-sub_ranks, ties.method = "first")]
    plur2_counts <- matrix(0L, nrow = K_, ncol = length(branch_idx))
    for (a in remaining) {
      plur2_counts[a, ] <- colSums(matrix(top_in_rem == a, nrow = k))
    }

    max_plur2  <- apply(plur2_counts[remaining, , drop = FALSE], 2, max)
    maj_round2 <- max_plur2 * 2L > k
    if (any(maj_round2)) {
      win_idx <- max.col(
        t(plur2_counts[remaining, maj_round2, drop = FALSE]), ties.method = "first"
      )
      irv_winner[branch_idx[maj_round2]] <- remaining[win_idx]
    }

    needs_round3 <- !maj_round2
    if (any(needs_round3)) {
      loser2_idx <- max.col(
        -t(plur2_counts[remaining, , drop = FALSE]), ties.method = "first"
      )
      loser_round2 <- remaining[loser2_idx]
      for (loser2 in remaining) {
        sub_mask <- needs_round3 & (loser_round2 == loser2)
        sub_idx  <- which(sub_mask)
        if (length(sub_idx) == 0L) next
        final_two <- setdiff(remaining, loser2)
        groups_s  <- groups_b[, sub_idx, drop = FALSE]
        voters_flat_s <- as.vector(groups_s)
        sub2_ranks   <- ranks_full[voters_flat_s, final_two, drop = FALSE]
        top_in_final <- final_two[max.col(-sub2_ranks, ties.method = "first")]
        plur3_counts <- matrix(0L, nrow = K_, ncol = length(sub_idx))
        for (a in final_two) {
          plur3_counts[a, ] <- colSums(matrix(top_in_final == a, nrow = k))
        }
        win_idx <- max.col(
          t(plur3_counts[final_two, , drop = FALSE]), ties.method = "first"
        )
        irv_winner[branch_idx[sub_idx]] <- final_two[win_idx]
      }
    }
  }

  list(plurality = plurality_winner,
       borda     = borda_winner,
       copeland  = copeland_winner,
       irv       = irv_winner,
       condorcet = cw_winner,
       has_cw    = has_cw)
}

# Test statistics from per-arm subset indices.
compute_test_stats <- function(winners, treated_idx, control_idx, K_) {
  out <- list()
  for (rule in c("plurality", "borda", "irv", "copeland")) {
    w_T <- winners[[rule]][treated_idx]
    w_C <- winners[[rule]][control_idx]
    dist_T <- tabulate(w_T, nbins = K_) / length(w_T)
    dist_C <- tabulate(w_C, nbins = K_) / length(w_C)
    out[[paste0("dist_T_", rule)]] <- dist_T
    out[[paste0("dist_C_", rule)]] <- dist_C
    out[[paste0("tvd_",    rule)]] <- 0.5 * sum(abs(dist_T - dist_C))
  }
  share_T_cw <- mean(winners$has_cw[treated_idx])
  share_C_cw <- mean(winners$has_cw[control_idx])
  out$cw_share_T <- share_T_cw
  out$cw_share_C <- share_C_cw
  out$delta_cw   <- share_T_cw - share_C_cw

  for (arm in list(list(name = "T", idx = treated_idx),
                   list(name = "C", idx = control_idx))) {
    has_arm <- winners$has_cw[arm$idx]
    cw_arm  <- winners$condorcet[arm$idx]
    cond_dist <- if (sum(has_arm) > 0L) tabulate(cw_arm[has_arm], nbins = K_) / sum(has_arm)
                 else rep(0, K_)
    out[[paste0("cond_cw_dist_", arm$name)]] <- cond_dist
  }
  out
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
if (length(overlap_ids) > 0) stop("user_id overlap: ", paste(head(overlap_ids), collapse = ", "))

control_rankings <- lapply(control_df$ranking_string, parse_ranking)
treated_rankings <- lapply(treatment_df$ranking_string, parse_ranking)

option_set <- sort(unique(unlist(c(control_rankings, treated_rankings))))
if (!setequal(option_set, option_codes)) {
  stop("Option set mismatch: got ", paste(option_set, collapse = ","))
}
check_rankings(control_rankings, option_codes, "control rankings")
check_rankings(treated_rankings, option_codes, "treated rankings")

n_C <- length(control_rankings); n_T <- length(treated_rankings); N <- n_C + n_T
cat(sprintf("Loaded n_C=%d, n_T=%d, N=%d, K=%d\n", n_C, n_T, N, K))

# Stack control then treated; observed treated indices are the last n_T positions.
all_rankings    <- c(control_rankings, treated_rankings)
ranks_full      <- build_ranks_matrix(all_rankings, option_codes)
pref_full       <- build_pref_array(ranks_full)
control_idx_obs <- 1:n_C
treated_idx_obs <- (n_C + 1):N

# -----------------------------------------------------------------------------
# Per-k precomputation: enumerate all C(N, k) subsets, compute winners
# -----------------------------------------------------------------------------

power_two   <- bitwShiftL(1L, 0:(N - 1L))   # 2^0 .. 2^(N-1), all fit in int32 for N<=30
all_mask    <- sum(power_two)               # 2^N - 1

precomp <- list()
for (k in k_values) {
  cat(sprintf("\n--- Precomputing k = %d ---\n", k))
  t0 <- Sys.time()
  ag <- combn(N, k)                         # k x G integer matrix
  G  <- ncol(ag)
  cat(sprintf("  G = %d subsets\n", G))

  winners <- compute_winners_all(pref_full, ranks_full, ag)
  cat(sprintf("  Winners computed in %.2fs\n",
              as.numeric(difftime(Sys.time(), t0, units = "secs"))))

  masks <- as.integer(colSums(matrix(power_two[as.vector(ag)], nrow = k)))
  cat(sprintf("  Masks built in %.2fs\n",
              as.numeric(difftime(Sys.time(), t0, units = "secs"))))

  precomp[[as.character(k)]] <- list(
    k = k, G = G, all_groups = ag, masks = masks, winners = winners
  )
}

# -----------------------------------------------------------------------------
# Observed test statistics
# -----------------------------------------------------------------------------

treated_mask_obs <- as.integer(sum(power_two[treated_idx_obs]))
control_mask_obs <- bitwXor(treated_mask_obs, all_mask)

obs_stats <- list()
for (k in k_values) {
  pc <- precomp[[as.character(k)]]
  treated_g <- which(bitwAnd(pc$masks, treated_mask_obs) == pc$masks)
  control_g <- which(bitwAnd(pc$masks, control_mask_obs) == pc$masks)
  stopifnot(length(treated_g) == choose(n_T, k),
            length(control_g) == choose(n_C, k))
  obs_stats[[as.character(k)]] <- compute_test_stats(pc$winners, treated_g, control_g, K)
}

# -----------------------------------------------------------------------------
# Permutation procedure
# -----------------------------------------------------------------------------

set.seed(seed)
null_stats <- list()
for (k in k_values) {
  null_stats[[as.character(k)]] <- list(
    tvd_plurality = numeric(B),
    tvd_borda     = numeric(B),
    tvd_irv       = numeric(B),
    tvd_copeland  = numeric(B),
    delta_cw      = numeric(B)
  )
}

t0 <- Sys.time()
for (b in seq_len(B)) {
  treated_perm <- sample.int(N, n_T, replace = FALSE)
  treated_mask_b <- as.integer(sum(power_two[treated_perm]))
  control_mask_b <- bitwXor(treated_mask_b, all_mask)

  for (k in k_values) {
    pc <- precomp[[as.character(k)]]
    treated_g <- which(bitwAnd(pc$masks, treated_mask_b) == pc$masks)
    control_g <- which(bitwAnd(pc$masks, control_mask_b) == pc$masks)
    ts <- compute_test_stats(pc$winners, treated_g, control_g, K)

    null_stats[[as.character(k)]]$tvd_plurality[b] <- ts$tvd_plurality
    null_stats[[as.character(k)]]$tvd_borda[b]     <- ts$tvd_borda
    null_stats[[as.character(k)]]$tvd_irv[b]       <- ts$tvd_irv
    null_stats[[as.character(k)]]$tvd_copeland[b]  <- ts$tvd_copeland
    null_stats[[as.character(k)]]$delta_cw[b]      <- ts$delta_cw
  }
  if (b %% 500L == 0L) {
    message(sprintf("  perm %d / %d (%.1fs elapsed)", b, B,
                    as.numeric(difftime(Sys.time(), t0, units = "secs"))))
  }
}

# -----------------------------------------------------------------------------
# p-values, Romano-Wolf step-down (FWER), and joint omnibus per k
# -----------------------------------------------------------------------------

# Studentised RW step-down with max-T null reconstruction.
romano_wolf_stepdown <- function(t_obs, t_null) {
  M <- length(t_obs); Bn <- ncol(t_null)
  ord <- order(t_obs, decreasing = TRUE)
  active <- ord
  p_adj <- rep(NA_real_, M)
  prev <- 0
  for (s in seq_along(ord)) {
    target <- ord[s]
    max_null <- if (length(active) == 1L) t_null[active, ] else apply(t_null[active, , drop = FALSE], 2, max)
    p_raw_s <- (1 + sum(max_null >= t_obs[target])) / (Bn + 1)
    p_adj[target] <- max(p_raw_s, prev)
    prev <- p_adj[target]
    active <- active[active != target]
  }
  p_adj
}

stats_per_k <- list()
for (k in k_values) {
  o <- obs_stats[[as.character(k)]]
  n <- null_stats[[as.character(k)]]

  abs_obs <- c(plurality = o$tvd_plurality, borda = o$tvd_borda,
               irv = o$tvd_irv, copeland = o$tvd_copeland,
               condorcet = abs(o$delta_cw))
  abs_null_list <- list(
    plurality = n$tvd_plurality, borda = n$tvd_borda,
    irv = n$tvd_irv, copeland = n$tvd_copeland,
    condorcet = abs(n$delta_cw)
  )

  raw_p <- mapply(function(obs_v, null_v) (1 + sum(null_v >= obs_v)) / (B + 1),
                  abs_obs, abs_null_list)
  null_sd <- vapply(abs_null_list, sd, numeric(1))
  null_mean <- vapply(abs_null_list, mean, numeric(1))

  # Studentise; floor SD to a tiny positive value so zero-variance cells
  # (e.g. discrete TVD that is identical across permutations) don't blow up.
  sd_floor <- pmax(null_sd, 1e-9)
  t_obs   <- abs_obs / sd_floor
  t_null  <- mapply(function(v, s) v / s, abs_null_list, sd_floor)
  if (is.matrix(t_null)) {
    t_null <- t(t_null)   # M x B
  }
  rownames(t_null) <- names(abs_obs)

  p_adj <- romano_wolf_stepdown(t_obs, t_null)
  names(p_adj) <- names(abs_obs)

  T_max_obs  <- max(t_obs)
  T_max_null <- apply(t_null, 2, max)
  p_omnibus  <- (1 + sum(T_max_null >= T_max_obs)) / (B + 1)

  stats_per_k[[as.character(k)]] <- list(
    obs        = o,
    abs_obs    = abs_obs,
    raw_p      = raw_p,
    p_adj_rw   = p_adj,
    null_sd    = null_sd,
    null_mean  = null_mean,
    t_obs      = t_obs,
    T_max_obs  = T_max_obs,
    p_omnibus  = p_omnibus
  )
}

# -----------------------------------------------------------------------------
# Sanity checks
# -----------------------------------------------------------------------------

# 1. Every per-arm group count matches choose(n_arm, k).
groups_count_ok <- TRUE
for (k in k_values) {
  pc <- precomp[[as.character(k)]]
  treated_g <- which(bitwAnd(pc$masks, treated_mask_obs) == pc$masks)
  control_g <- which(bitwAnd(pc$masks, control_mask_obs) == pc$masks)
  if (length(treated_g) != choose(n_T, k) || length(control_g) != choose(n_C, k)) {
    groups_count_ok <- FALSE; break
  }
}

# 2. Winner-distribution probabilities sum to 1 in each arm under each rule.
dist_sum_ok <- TRUE
for (k in k_values) {
  o <- obs_stats[[as.character(k)]]
  for (rule in c("plurality", "borda", "irv", "copeland")) {
    if (abs(sum(o[[paste0("dist_T_", rule)]]) - 1) > 1e-9) dist_sum_ok <- FALSE
    if (abs(sum(o[[paste0("dist_C_", rule)]]) - 1) > 1e-9) dist_sum_ok <- FALSE
  }
}

# 3. Permutation null centeredness: E[delta_cw*] approx 0 (sharp null with
#    arm-symmetric statistic implies zero mean under random label shuffles).
null_dcw_centered_ok <- TRUE
for (k in k_values) {
  m <- mean(null_stats[[as.character(k)]]$delta_cw)
  if (abs(m) > 5 / sqrt(B)) null_dcw_centered_ok <- FALSE
}

# 4. Romano-Wolf monotonicity along |t|-rank order, per k.
rw_mono_ok <- TRUE
for (k in k_values) {
  s <- stats_per_k[[as.character(k)]]
  ord <- order(s$t_obs, decreasing = TRUE)
  if (any(diff(s$p_adj_rw[ord]) < -1e-12)) rw_mono_ok <- FALSE
}

# 5. Replication anchor: per analysis/output/phase2_final_voting_rules.csv,
#    food_pantry is the phase-2-final Condorcet winner while phase 1 has none.
#    The synthetic-group ATE for food_pantry's conditional-CW share should
#    therefore be strictly positive at every k.
fp_idx <- match("food_pantry", option_codes)
anchor_per_k <- vapply(k_values, function(k) {
  o <- obs_stats[[as.character(k)]]
  o$cond_cw_dist_T[fp_idx] - o$cond_cw_dist_C[fp_idx]
}, numeric(1))
anchor_ok <- all(anchor_per_k > 0)

# 6. IRV consistency check on a tiny case: any group whose plurality has a
#    strict majority (> k/2) should produce IRV winner == plurality winner.
irv_consistency_ok <- TRUE
for (k in k_values) {
  pc <- precomp[[as.character(k)]]
  pl <- pc$winners$plurality
  ir <- pc$winners$irv
  ag <- pc$all_groups
  voters_flat <- as.vector(ag)
  K_ <- ncol(ranks_full)
  pc_top <- matrix(0L, nrow = K_, ncol = pc$G)
  for (a in 1:K_) {
    pc_top[a, ] <- colSums(matrix(ranks_full[voters_flat, a] == 1L, nrow = k))
  }
  has_majority <- apply(pc_top, 2, max) * 2L > k
  if (any(has_majority) && !all(pl[has_majority] == ir[has_majority])) {
    irv_consistency_ok <- FALSE; break
  }
}

# -----------------------------------------------------------------------------
# Write outputs
# -----------------------------------------------------------------------------

dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

# winner_distributions.csv: per k, per rule, per arm, per option probability.
wd_rows <- list()
for (k in k_values) {
  o <- obs_stats[[as.character(k)]]
  for (rule in c("plurality", "borda", "irv", "copeland")) {
    for (j in 1:K) {
      wd_rows[[length(wd_rows) + 1]] <- tibble(
        k = k, rule = rule, option = option_codes[j],
        p_treated = o[[paste0("dist_T_", rule)]][j],
        p_control = o[[paste0("dist_C_", rule)]][j],
        diff      = o[[paste0("dist_T_", rule)]][j] - o[[paste0("dist_C_", rule)]][j]
      )
    }
  }
}
winner_distributions <- bind_rows(wd_rows)
write_csv(winner_distributions, file.path(output_dir, "winner_distributions.csv"))

# condorcet_existence.csv: per k, theta_T, theta_C, delta, RI two-sided p-value.
ce_rows <- list()
for (k in k_values) {
  o <- obs_stats[[as.character(k)]]
  s <- stats_per_k[[as.character(k)]]
  ce_rows[[length(ce_rows) + 1]] <- tibble(
    k = k,
    theta_T_cw = o$cw_share_T,
    theta_C_cw = o$cw_share_C,
    delta_cw   = o$delta_cw,
    raw_p_cw   = s$raw_p["condorcet"],
    p_adj_rw_cw= s$p_adj_rw["condorcet"],
    null_mean  = s$null_mean["condorcet"],
    null_sd    = s$null_sd["condorcet"]
  )
}
condorcet_existence <- bind_rows(ce_rows)
write_csv(condorcet_existence, file.path(output_dir, "condorcet_existence.csv"))

# test_statistics.csv: per k, per stat, value + raw p + RW-adj p.
ts_rows <- list()
for (k in k_values) {
  s <- stats_per_k[[as.character(k)]]
  for (stat in stat_names) {
    ts_rows[[length(ts_rows) + 1]] <- tibble(
      k = k,
      statistic = stat,
      value     = s$abs_obs[stat],
      null_mean = s$null_mean[stat],
      null_sd   = s$null_sd[stat],
      t_obs     = s$t_obs[stat],
      raw_p     = s$raw_p[stat],
      p_adj_rw  = s$p_adj_rw[stat],
      reject_rw_05 = s$p_adj_rw[stat] <= alpha
    )
  }
}
test_statistics <- bind_rows(ts_rows)
write_csv(test_statistics, file.path(output_dir, "test_statistics.csv"))

# omnibus_scalars.csv: per k headline.
om_rows <- list()
for (k in k_values) {
  s <- stats_per_k[[as.character(k)]]
  om_rows[[length(om_rows) + 1]] <- tibble(
    k = k,
    T_max_obs  = s$T_max_obs,
    p_omnibus  = s$p_omnibus,
    n_treated_groups = choose(n_T, k),
    n_control_groups = choose(n_C, k),
    B = B, seed = seed, alpha = alpha,
    n_treated = n_T, n_control = n_C, K = K
  )
}
omnibus_scalars <- bind_rows(om_rows)
write_csv(omnibus_scalars, file.path(output_dir, "omnibus_scalars.csv"))

# null_quantiles.csv: null distribution shape per k, per stat.
nq_rows <- list()
for (k in k_values) {
  n <- null_stats[[as.character(k)]]
  ns <- list(plurality = n$tvd_plurality, borda = n$tvd_borda,
             irv = n$tvd_irv, copeland = n$tvd_copeland,
             condorcet = abs(n$delta_cw))
  for (stat in names(ns)) {
    qs <- quantile(ns[[stat]], probs = c(0.50, 0.90, 0.95, 0.99), names = FALSE)
    nq_rows[[length(nq_rows) + 1]] <- tibble(
      k = k, statistic = stat,
      null_q50 = qs[1], null_q90 = qs[2], null_q95 = qs[3], null_q99 = qs[4],
      null_mean = mean(ns[[stat]]), null_sd = sd(ns[[stat]])
    )
  }
}
null_quantiles <- bind_rows(nq_rows)
write_csv(null_quantiles, file.path(output_dir, "null_quantiles.csv"))

# Conditional CW distribution among groups with a CW.
ccw_rows <- list()
for (k in k_values) {
  o <- obs_stats[[as.character(k)]]
  for (j in 1:K) {
    ccw_rows[[length(ccw_rows) + 1]] <- tibble(
      k = k, option = option_codes[j],
      p_cond_T = o$cond_cw_dist_T[j],
      p_cond_C = o$cond_cw_dist_C[j],
      diff     = o$cond_cw_dist_T[j] - o$cond_cw_dist_C[j]
    )
  }
}
conditional_cw <- bind_rows(ccw_rows)
write_csv(conditional_cw, file.path(output_dir, "conditional_condorcet_winner.csv"))

# -----------------------------------------------------------------------------
# Figures
# -----------------------------------------------------------------------------

dir.create(figures_dir, recursive = TRUE, showWarnings = FALSE)

# Figure 1: winner distributions per rule, k = primary
wd_primary <- winner_distributions %>%
  filter(k == k_primary) %>%
  mutate(option_label = option_labels[option]) %>%
  pivot_longer(cols = c(p_treated, p_control), names_to = "arm", values_to = "p") %>%
  mutate(arm = recode(arm, p_treated = "Treated (phase-2 final)", p_control = "Control (phase-1)"),
         rule = factor(rule, levels = c("plurality", "borda", "irv", "copeland"),
                       labels = c("Plurality", "Borda", "IRV", "Copeland")))
p_wd <- ggplot(wd_primary, aes(x = option_label, y = p, fill = arm)) +
  geom_col(position = position_dodge(width = 0.75), width = 0.7) +
  facet_wrap(~ rule, ncol = 2) +
  scale_fill_manual(values = c("Treated (phase-2 final)" = "#1B4F72",
                               "Control (phase-1)"       = "#B03A2E")) +
  scale_y_continuous(labels = scales::percent_format(accuracy = 1),
                     limits = c(0, 1.0)) +
  labs(
    title    = sprintf("Winner distributions across synthetic %d-person groups", k_primary),
    subtitle = sprintf("Treated: all C(%d, %d)=%d groups in phase-2-final arm. Control: all C(%d, %d)=%d groups in phase-1 arm.",
                       n_T, k_primary, choose(n_T, k_primary),
                       n_C, k_primary, choose(n_C, k_primary)),
    x = NULL, y = "P(rule winner = option)", fill = NULL
  ) +
  theme_minimal(base_size = 12) +
  theme(legend.position = "bottom",
        axis.text.x = element_text(angle = 25, hjust = 1))
ggsave(file.path(figures_dir, "winner_distributions_primary.png"), p_wd,
       width = 11, height = 7, dpi = 150)

# Figure 2: TVD bar chart with p-values, faceted by k
tvd_panel <- test_statistics %>%
  filter(statistic %in% c("plurality", "borda", "irv", "copeland")) %>%
  mutate(rule = factor(statistic,
                       levels = c("plurality", "borda", "irv", "copeland"),
                       labels = c("Plurality", "Borda", "IRV", "Copeland")),
         k_label = factor(sprintf("k = %d", k), levels = sprintf("k = %d", k_values)),
         label = sprintf("raw p=%.3f\nRW p=%.3f", raw_p, p_adj_rw))

p_tvd <- ggplot(tvd_panel, aes(x = rule, y = value, fill = reject_rw_05)) +
  geom_col(width = 0.65) +
  geom_text(aes(label = label, y = value),
            vjust = -0.2, size = 2.8) +
  facet_wrap(~ k_label, ncol = length(k_values)) +
  scale_fill_manual(values = c(`TRUE` = "#1B4F72", `FALSE` = "#5D6D7E"),
                    labels = c(`TRUE` = "Reject RW p<.05", `FALSE` = "Not rejected")) +
  scale_y_continuous(limits = c(0, max(tvd_panel$value) * 1.4),
                     labels = scales::percent_format(accuracy = 1)) +
  labs(
    title    = "Per-rule total-variation distance between treated and control winner distributions",
    subtitle = "TVD = (1/2) * sum_j |P_T(winner = j) - P_C(winner = j)|. Annotations: raw RI p / Romano-Wolf adjusted p.",
    x = NULL, y = "TVD",
    fill = NULL
  ) +
  theme_minimal(base_size = 12) +
  theme(legend.position = "bottom",
        axis.text.x = element_text(angle = 25, hjust = 1))
ggsave(file.path(figures_dir, "tvd_panel.png"), p_tvd,
       width = 12, height = 6, dpi = 150)

# Figure 3: Condorcet existence across k
ce_plot <- condorcet_existence %>%
  pivot_longer(cols = c(theta_T_cw, theta_C_cw),
               names_to = "arm", values_to = "share") %>%
  mutate(arm = recode(arm, theta_T_cw = "Treated", theta_C_cw = "Control"),
         k_label = factor(sprintf("k = %d", k), levels = sprintf("k = %d", k_values)))

p_ce <- ggplot(ce_plot, aes(x = arm, y = share, fill = arm)) +
  geom_col(width = 0.6) +
  geom_text(aes(label = sprintf("%.0f%%", 100 * share)), vjust = -0.3, size = 3.5) +
  facet_wrap(~ k_label, ncol = length(k_values)) +
  scale_fill_manual(values = c("Treated" = "#1B4F72", "Control" = "#B03A2E")) +
  scale_y_continuous(limits = c(0, 1), labels = scales::percent_format(accuracy = 1)) +
  labs(
    title    = "Probability that a synthetic group has a Condorcet winner",
    subtitle = sprintf("Per-arm share of synthetic %s groups in which some option beats every other in pairwise majority.",
                       paste(sprintf("k = %d", k_values), collapse = ", ")),
    x = NULL, y = "Share of groups with a Condorcet winner", fill = NULL
  ) +
  theme_minimal(base_size = 12) +
  theme(legend.position = "none")
ggsave(file.path(figures_dir, "condorcet_existence.png"), p_ce,
       width = 11, height = 5, dpi = 150)

# Figure 4: Null distributions overlaid with observed values for primary k
null_long <- bind_rows(lapply(k_values, function(k) {
  ns <- null_stats[[as.character(k)]]
  bind_rows(
    tibble(k = k, statistic = "plurality", value = ns$tvd_plurality),
    tibble(k = k, statistic = "borda",     value = ns$tvd_borda),
    tibble(k = k, statistic = "irv",       value = ns$tvd_irv),
    tibble(k = k, statistic = "copeland",  value = ns$tvd_copeland),
    tibble(k = k, statistic = "condorcet", value = abs(ns$delta_cw))
  )
})) %>%
  mutate(stat_label = factor(statistic,
                             levels = c("plurality", "borda", "irv", "copeland", "condorcet"),
                             labels = c("Plurality TVD", "Borda TVD", "IRV TVD", "Copeland TVD", "|Delta P(CW exists)|")),
         k_label = factor(sprintf("k = %d", k), levels = sprintf("k = %d", k_values)))

obs_long <- test_statistics %>%
  mutate(stat_label = factor(statistic,
                             levels = c("plurality", "borda", "irv", "copeland", "condorcet"),
                             labels = c("Plurality TVD", "Borda TVD", "IRV TVD", "Copeland TVD", "|Delta P(CW exists)|")),
         k_label = factor(sprintf("k = %d", k), levels = sprintf("k = %d", k_values)))

p_null <- ggplot(null_long, aes(x = value)) +
  geom_histogram(bins = 40, fill = "#D6DBDF", color = "white") +
  geom_vline(data = obs_long, aes(xintercept = value), color = "#B03A2E", linewidth = 0.8) +
  facet_grid(k_label ~ stat_label, scales = "free") +
  labs(
    title    = "Permutation null distributions and observed test statistics",
    subtitle = sprintf("B = %d permutations; red line = observed value.", B),
    x = "Statistic value", y = "Count"
  ) +
  theme_minimal(base_size = 11) +
  theme(strip.text = element_text(size = 9))
ggsave(file.path(figures_dir, "null_distributions.png"), p_null,
       width = 14, height = 7, dpi = 150)

# -----------------------------------------------------------------------------
# Console summary
# -----------------------------------------------------------------------------

cat("\n============================================================\n")
cat("HEADLINE: per-k panel (k=", paste(k_values, collapse = ","), ")\n", sep = "")
cat("============================================================\n")
print(test_statistics %>% mutate(across(c(value, null_mean, null_sd, t_obs, raw_p, p_adj_rw),
                                        ~ sprintf("%.4f", .))))

cat("\n--- Condorcet existence ATE per k ---\n")
print(condorcet_existence %>% mutate(across(where(is.numeric), ~ sprintf("%.4f", .))))

cat("\n--- Joint omnibus per k ---\n")
print(omnibus_scalars)

cat("\n============================================================\n")
cat("SANITY CHECKS\n")
cat("============================================================\n")
cat(sprintf("[%s] 1. Group counts match C(n_arm, k) for every (arm, k)\n",
            ifelse(groups_count_ok, "PASS", "FAIL")))
cat(sprintf("[%s] 2. Per-rule per-arm winner distributions sum to 1\n",
            ifelse(dist_sum_ok, "PASS", "FAIL")))
cat(sprintf("[%s] 3. Permutation null mean of Delta P(CW) within 5/sqrt(B) of zero, all k\n",
            ifelse(null_dcw_centered_ok, "PASS", "FAIL")))
cat(sprintf("[%s] 4. Romano-Wolf p_adj monotone along |t|-rank order, all k\n",
            ifelse(rw_mono_ok, "PASS", "FAIL")))
cat(sprintf("[%s] 5. Replication anchor: food_pantry's conditional-CW share strictly higher in treated than control at every k\n",
            ifelse(anchor_ok, "PASS", "FAIL")))
for (i in seq_along(k_values)) {
  cat(sprintf("      k = %d: food_pantry share T=%.3f, C=%.3f, diff = %+0.3f\n",
              k_values[i],
              obs_stats[[as.character(k_values[i])]]$cond_cw_dist_T[fp_idx],
              obs_stats[[as.character(k_values[i])]]$cond_cw_dist_C[fp_idx],
              anchor_per_k[i]))
}
cat(sprintf("[%s] 6. IRV consistency: round-1 majority groups -> IRV winner == plurality winner\n",
            ifelse(irv_consistency_ok, "PASS", "FAIL")))

cat("\nWrote:\n")
cat(sprintf("  %s/{winner_distributions,test_statistics,condorcet_existence,omnibus_scalars,null_quantiles,conditional_condorcet_winner}.csv\n",
            output_dir))
cat(sprintf("  %s/{winner_distributions_primary,tvd_panel,condorcet_existence,null_distributions}.png\n", figures_dir))

cat("\nR sessionInfo:\n")
print(sessionInfo())
