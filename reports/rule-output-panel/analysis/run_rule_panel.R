options(stringsAsFactors = FALSE)

suppressPackageStartupMessages({
  library(readr)
  library(dplyr)
  library(stringr)
  library(tibble)
  library(tidyr)
  library(ggplot2)
})

# Outcome 3 from notes/analysis-plan.md
# Main estimand: DiD on rule outputs
#   For each rule r and group size k,
#   compare arm-specific post-pre winner-distribution changes,
#   then summarize with TVD on those change vectors.
#
# Run from repo root:
#   Rscript reports/rule-output-panel/analysis/run_rule_panel.R

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

k_values     <- c(3L, 5L, 7L)
k_primary    <- 5L
k_secondary  <- 7L

B            <- 5000L
seed         <- 20260510L
alpha        <- 0.05
power_target <- 0.80
power_n_round_to <- 10L

# Literature-scale planning targets. Farrar et al. report deliberation-induced
# mean absolute net attitude movement around 7-12 pp, so use a 10 pp target
# for winner-distribution TVD. Condorcet power planning is skipped for now:
# it is ceiling-limited and not the main rule-output movement in this report.
assumed_effect <- c(plurality = 0.10,
                    borda = 0.10,
                    irv = 0.10,
                    copeland = 0.10,
                    condorcet = NA_real_)
assumed_effect_source <- c(plurality = "Farrar_scale_tvd_10pp",
                           borda = "Farrar_scale_tvd_10pp",
                           irv = "Farrar_scale_tvd_10pp",
                           copeland = "Farrar_scale_tvd_10pp",
                           condorcet = "skipped")

# Number of synthetic groups sampled per arm, per wave, per permutation, per k.
# If choose(n_arm, k) <= max_exhaustive_groups, use exhaustive enumeration.
groups_per_arm       <- 4000L
max_exhaustive_groups <- 50000L

output_dir   <- "reports/rule-output-panel/analysis/output"
figures_dir  <- "reports/rule-output-panel/figures"

stat_names <- c("plurality", "borda", "irv", "copeland", "condorcet")

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

build_ranks_matrix <- function(ranking_list, codes) {
  n <- length(ranking_list)
  K_ <- length(codes)
  out <- matrix(NA_integer_, nrow = n, ncol = K_)
  for (i in seq_len(n)) out[i, ] <- match(codes, ranking_list[[i]])
  colnames(out) <- codes
  out
}

build_pref_array <- function(ranks_mat) {
  n <- nrow(ranks_mat)
  K_ <- ncol(ranks_mat)
  pref <- array(FALSE, dim = c(n, K_, K_))
  for (a in seq_len(K_)) for (b in seq_len(K_)) {
    if (a != b) pref[, a, b] <- ranks_mat[, a] < ranks_mat[, b]
  }
  pref
}

compute_winners_all <- function(pref_full, ranks_full, all_groups) {
  k <- nrow(all_groups)
  G <- ncol(all_groups)
  K_ <- ncol(ranks_full)
  voters_flat <- as.vector(all_groups)

  pair_counts <- array(0L, dim = c(K_, K_, G))
  for (a in 1:K_) for (b in 1:K_) {
    if (a == b) next
    pair_counts[a, b, ] <- colSums(matrix(pref_full[voters_flat, a, b], nrow = k))
  }

  plur_counts <- matrix(0L, nrow = K_, ncol = G)
  for (a in 1:K_) {
    plur_counts[a, ] <- colSums(matrix(ranks_full[voters_flat, a] == 1L, nrow = k))
  }
  plurality_winner <- max.col(t(plur_counts), ties.method = "first")

  borda_scores <- matrix(0L, nrow = K_, ncol = G)
  for (a in 1:K_) {
    borda_scores[a, ] <- K_ * k - colSums(matrix(ranks_full[voters_flat, a], nrow = k))
  }
  borda_winner <- max.col(t(borda_scores), ties.method = "first")

  copeland_scores <- matrix(0, nrow = K_, ncol = G)
  for (a in 1:K_) for (b in 1:K_) {
    if (a == b) next
    copeland_scores[a, ] <- copeland_scores[a, ] +
      as.integer(pair_counts[a, b, ] * 2L >  k) +
      0.5 * as.integer(pair_counts[a, b, ] * 2L == k)
  }
  copeland_winner <- max.col(t(copeland_scores), ties.method = "first")

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

  # IRV (for K=4 this vectorized tree is compact and stable)
  irv_winner <- integer(G)
  max_plur1 <- apply(plur_counts, 2, max)
  maj_round1 <- max_plur1 * 2L > k
  if (any(maj_round1)) {
    irv_winner[maj_round1] <- max.col(t(plur_counts[, maj_round1, drop = FALSE]), ties.method = "first")
  }

  loser_round1 <- max.col(-t(plur_counts), ties.method = "first")
  for (loser1 in 1:K_) {
    idx1 <- which(!maj_round1 & loser_round1 == loser1)
    if (length(idx1) == 0L) next

    remaining <- setdiff(1:K_, loser1)
    groups_b <- all_groups[, idx1, drop = FALSE]
    vf_b <- as.vector(groups_b)

    sub_ranks <- ranks_full[vf_b, remaining, drop = FALSE]
    top_in_rem <- remaining[max.col(-sub_ranks, ties.method = "first")]

    plur2 <- matrix(0L, nrow = K_, ncol = length(idx1))
    for (a in remaining) {
      plur2[a, ] <- colSums(matrix(top_in_rem == a, nrow = k))
    }

    max_plur2 <- apply(plur2[remaining, , drop = FALSE], 2, max)
    maj_round2 <- max_plur2 * 2L > k
    if (any(maj_round2)) {
      win_idx <- max.col(t(plur2[remaining, maj_round2, drop = FALSE]), ties.method = "first")
      irv_winner[idx1[maj_round2]] <- remaining[win_idx]
    }

    idx_need3 <- which(!maj_round2)
    if (length(idx_need3) > 0L) {
      loser2_idx <- max.col(-t(plur2[remaining, , drop = FALSE]), ties.method = "first")
      loser2 <- remaining[loser2_idx]
      for (l2 in remaining) {
        idx2 <- idx_need3[loser2[idx_need3] == l2]
        if (length(idx2) == 0L) next

        final_two <- setdiff(remaining, l2)
        groups_s <- groups_b[, idx2, drop = FALSE]
        vf_s <- as.vector(groups_s)
        sub2 <- ranks_full[vf_s, final_two, drop = FALSE]
        top_final <- final_two[max.col(-sub2, ties.method = "first")]

        plur3 <- matrix(0L, nrow = K_, ncol = length(idx2))
        for (a in final_two) {
          plur3[a, ] <- colSums(matrix(top_final == a, nrow = k))
        }
        win_idx <- max.col(t(plur3[final_two, , drop = FALSE]), ties.method = "first")
        irv_winner[idx1[idx2]] <- final_two[win_idx]
      }
    }
  }

  list(plurality = plurality_winner,
       borda = borda_winner,
       irv = irv_winner,
       copeland = copeland_winner,
       condorcet = cw_winner,
       has_cw = has_cw)
}

get_groups <- function(ids, k, groups_per_arm, max_exhaustive_groups) {
  n <- length(ids)
  total <- choose(n, k)
  if (is.finite(total) && total <= max_exhaustive_groups) {
    combn(ids, k)
  } else {
    replicate(groups_per_arm, sample(ids, size = k, replace = FALSE))
  }
}

winner_distributions_from_groups <- function(winners, K_) {
  out <- list()
  for (rule in c("plurality", "borda", "irv", "copeland")) {
    out[[rule]] <- tabulate(winners[[rule]], nbins = K_) / length(winners[[rule]])
  }
  out$cw_share <- mean(winners$has_cw)
  if (sum(winners$has_cw) > 0L) {
    out$cw_cond <- tabulate(winners$condorcet[winners$has_cw], nbins = K_) / sum(winners$has_cw)
  } else {
    out$cw_cond <- rep(0, K_)
  }
  out
}

compute_did_stats <- function(pref_pre, ranks_pre, pref_post, ranks_post, treated_ids, control_ids,
                              k, groups_per_arm, max_exhaustive_groups, K_) {
  gT <- get_groups(treated_ids, k, groups_per_arm, max_exhaustive_groups)
  gC <- get_groups(control_ids, k, groups_per_arm, max_exhaustive_groups)

  wT_pre  <- compute_winners_all(pref_pre,  ranks_pre,  gT)
  wT_post <- compute_winners_all(pref_post, ranks_post, gT)
  wC_pre  <- compute_winners_all(pref_pre,  ranks_pre,  gC)
  wC_post <- compute_winners_all(pref_post, ranks_post, gC)

  dT_pre  <- winner_distributions_from_groups(wT_pre,  K_)
  dT_post <- winner_distributions_from_groups(wT_post, K_)
  dC_pre  <- winner_distributions_from_groups(wC_pre,  K_)
  dC_post <- winner_distributions_from_groups(wC_post, K_)

  delta_rule <- list()
  tvd_rule <- list()
  for (rule in c("plurality", "borda", "irv", "copeland")) {
    dd <- (dT_post[[rule]] - dT_pre[[rule]]) - (dC_post[[rule]] - dC_pre[[rule]])
    delta_rule[[rule]] <- dd
    tvd_rule[[rule]] <- 0.5 * sum(abs(dd))
  }

  delta_cw <- (dT_post$cw_share - dT_pre$cw_share) - (dC_post$cw_share - dC_pre$cw_share)

  list(
    k = k,
    treated_pre = dT_pre,
    treated_post = dT_post,
    control_pre = dC_pre,
    control_post = dC_post,
    delta_rule = delta_rule,
    tvd = c(plurality = tvd_rule$plurality,
            borda = tvd_rule$borda,
            irv = tvd_rule$irv,
            copeland = tvd_rule$copeland,
            condorcet = abs(delta_cw)),
    delta_cw = delta_cw,
    n_groups_treated = ncol(gT),
    n_groups_control = ncol(gC)
  )
}

romano_wolf_stepdown <- function(t_obs, t_null) {
  M <- length(t_obs)
  Bn <- ncol(t_null)
  ord <- order(t_obs, decreasing = TRUE)
  active <- ord
  p_adj <- rep(NA_real_, M)
  prev <- 0
  for (s in seq_along(ord)) {
    target <- ord[s]
    max_null <- if (length(active) == 1L) t_null[active, ] else apply(t_null[active, , drop = FALSE], 2, max)
    p_raw <- (1 + sum(max_null >= t_obs[target])) / (Bn + 1)
    p_adj[target] <- max(p_raw, prev)
    prev <- p_adj[target]
    active <- active[active != target]
  }
  p_adj
}

round_up_to <- function(x, step) {
  ifelse(is.na(x) | !is.finite(x), NA_real_, ceiling(x / step) * step)
}

calc_power_plan <- function(null_values, effect, n_treated, n_control,
                            alpha, power_target, round_to) {
  if (is.na(effect) || !is.finite(effect) || effect <= 0) {
    return(c(power_null_crit = NA_real_,
             n_per_arm_80_power_raw = NA_real_,
             n_per_arm_80_power = NA_real_,
             n_total_80_power = NA_real_))
  }

  null_sd <- sd(null_values)
  null_crit <- as.numeric(quantile(null_values, probs = 1 - alpha,
                                   names = FALSE))
  current_design_factor <- 1 / n_treated + 1 / n_control
  n_raw <- 2 * ((null_crit + qnorm(power_target) * null_sd) / effect)^2 /
    current_design_factor
  n_per_arm <- round_up_to(n_raw, round_to)

  c(power_null_crit = null_crit,
    n_per_arm_80_power_raw = n_raw,
    n_per_arm_80_power = n_per_arm,
    n_total_80_power = 2 * n_per_arm)
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
if (length(overlap_ids) > 0) stop("user_id overlap: ", paste(head(overlap_ids), collapse = ", "))

control_pre_rankings  <- lapply(control_df$pre_ranking,  parse_ranking)
control_post_rankings <- lapply(control_df$post_ranking, parse_ranking)
treated_pre_rankings  <- lapply(treatment_df$pre_ranking,  parse_ranking)
treated_post_rankings <- lapply(treatment_df$post_ranking, parse_ranking)

all_rankings <- c(control_pre_rankings, control_post_rankings,
                  treated_pre_rankings, treated_post_rankings)
option_set <- sort(unique(unlist(all_rankings)))
if (!setequal(option_set, option_codes)) {
  stop("Option set mismatch: got ", paste(option_set, collapse = ","))
}
check_rankings(control_pre_rankings, option_codes, "control pre rankings")
check_rankings(control_post_rankings, option_codes, "control post rankings")
check_rankings(treated_pre_rankings, option_codes, "treated pre rankings")
check_rankings(treated_post_rankings, option_codes, "treated post rankings")

n_C <- length(control_pre_rankings)
n_T <- length(treated_pre_rankings)
N <- n_C + n_T
cat(sprintf("Loaded panel data: n_C=%d, n_T=%d, N=%d, K=%d\n", n_C, n_T, N, K))

# stack as control first then treated for observed labels
rankings_pre_all <- c(control_pre_rankings, treated_pre_rankings)
rankings_post_all <- c(control_post_rankings, treated_post_rankings)

ranks_pre_all  <- build_ranks_matrix(rankings_pre_all, option_codes)
ranks_post_all <- build_ranks_matrix(rankings_post_all, option_codes)
pref_pre_all   <- build_pref_array(ranks_pre_all)
pref_post_all  <- build_pref_array(ranks_post_all)

treated_idx_obs <- (n_C + 1):N
control_idx_obs <- 1:n_C

# -----------------------------------------------------------------------------
# Observed stats
# -----------------------------------------------------------------------------

obs_stats <- list()
for (k in k_values) {
  obs_stats[[as.character(k)]] <- compute_did_stats(
    pref_pre_all, ranks_pre_all,
    pref_post_all, ranks_post_all,
    treated_ids = treated_idx_obs,
    control_ids = control_idx_obs,
    k = k,
    groups_per_arm = groups_per_arm,
    max_exhaustive_groups = max_exhaustive_groups,
    K_ = K
  )
}

# -----------------------------------------------------------------------------
# Permutation null
# -----------------------------------------------------------------------------

set.seed(seed)
null_stats <- list()
for (k in k_values) {
  null_stats[[as.character(k)]] <- list(
    plurality = numeric(B),
    borda = numeric(B),
    irv = numeric(B),
    copeland = numeric(B),
    condorcet = numeric(B)
  )
}

t0 <- Sys.time()
for (b in seq_len(B)) {
  treated_perm <- sample.int(N, n_T, replace = FALSE)
  control_perm <- setdiff(seq_len(N), treated_perm)

  for (k in k_values) {
    s <- compute_did_stats(
      pref_pre_all, ranks_pre_all,
      pref_post_all, ranks_post_all,
      treated_ids = treated_perm,
      control_ids = control_perm,
      k = k,
      groups_per_arm = groups_per_arm,
      max_exhaustive_groups = max_exhaustive_groups,
      K_ = K
    )

    null_stats[[as.character(k)]]$plurality[b] <- s$tvd["plurality"]
    null_stats[[as.character(k)]]$borda[b]     <- s$tvd["borda"]
    null_stats[[as.character(k)]]$irv[b]       <- s$tvd["irv"]
    null_stats[[as.character(k)]]$copeland[b]  <- s$tvd["copeland"]
    null_stats[[as.character(k)]]$condorcet[b] <- s$tvd["condorcet"]
  }

  if (b %% 500L == 0L) {
    message(sprintf("perm %d / %d (%.1fs elapsed)", b, B,
                    as.numeric(difftime(Sys.time(), t0, units = "secs"))))
  }
}

# -----------------------------------------------------------------------------
# p-values + RW correction + omnibus
# -----------------------------------------------------------------------------

stats_per_k <- list()
for (k in k_values) {
  o <- obs_stats[[as.character(k)]]
  n <- null_stats[[as.character(k)]]

  abs_obs <- c(plurality = as.numeric(o$tvd["plurality"]),
               borda = as.numeric(o$tvd["borda"]),
               irv = as.numeric(o$tvd["irv"]),
               copeland = as.numeric(o$tvd["copeland"]),
               condorcet = as.numeric(o$tvd["condorcet"]))

  abs_null <- list(plurality = as.numeric(n$plurality),
                   borda = as.numeric(n$borda),
                   irv = as.numeric(n$irv),
                   copeland = as.numeric(n$copeland),
                   condorcet = as.numeric(n$condorcet))

  raw_p <- vapply(names(abs_obs), function(sname) {
    (1 + sum(abs_null[[sname]] >= abs_obs[sname])) / (B + 1)
  }, numeric(1))

  null_sd <- vapply(abs_null, sd, numeric(1))
  null_mean <- vapply(abs_null, mean, numeric(1))

  sd_floor <- pmax(null_sd, 1e-9)
  t_obs <- abs_obs / sd_floor

  t_null <- rbind(
    abs_null$plurality / sd_floor["plurality"],
    abs_null$borda / sd_floor["borda"],
    abs_null$irv / sd_floor["irv"],
    abs_null$copeland / sd_floor["copeland"],
    abs_null$condorcet / sd_floor["condorcet"]
  )
  rownames(t_null) <- names(abs_obs)

  p_adj <- romano_wolf_stepdown(t_obs, t_null)
  names(p_adj) <- names(abs_obs)

  T_max_obs <- max(t_obs)
  T_max_null <- apply(t_null, 2, max)
  p_omnibus <- (1 + sum(T_max_null >= T_max_obs)) / (B + 1)

  power_plan_fields <- c("power_null_crit",
                         "n_per_arm_80_power_raw",
                         "n_per_arm_80_power",
                         "n_total_80_power")
  power_plan <- t(vapply(names(abs_obs), function(sname) {
    calc_power_plan(
      null_values = abs_null[[sname]],
      effect = assumed_effect[sname],
      n_treated = n_T,
      n_control = n_C,
      alpha = alpha,
      power_target = power_target,
      round_to = power_n_round_to
    )
  }, setNames(numeric(length(power_plan_fields)), power_plan_fields)))

  stats_per_k[[as.character(k)]] <- list(
    abs_obs = abs_obs,
    raw_p = raw_p,
    p_adj_rw = p_adj,
    null_sd = null_sd,
    null_mean = null_mean,
    t_obs = t_obs,
    T_max_obs = T_max_obs,
    p_omnibus = p_omnibus,
    assumed_effect = assumed_effect[names(abs_obs)],
    assumed_effect_source = assumed_effect_source[names(abs_obs)],
    power_null_crit = power_plan[, "power_null_crit"],
    n_per_arm_80_power_raw = power_plan[, "n_per_arm_80_power_raw"],
    n_per_arm_80_power = power_plan[, "n_per_arm_80_power"],
    n_total_80_power = power_plan[, "n_total_80_power"]
  )
}

# -----------------------------------------------------------------------------
# Write outputs
# -----------------------------------------------------------------------------

dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(figures_dir, recursive = TRUE, showWarnings = FALSE)

wd_rows <- list()
for (k in k_values) {
  o <- obs_stats[[as.character(k)]]
  for (rule in c("plurality", "borda", "irv", "copeland")) {
    for (j in seq_len(K)) {
      wd_rows[[length(wd_rows) + 1]] <- tibble(
        k = k,
        rule = rule,
        option = option_codes[j],
        p_treated_pre = o$treated_pre[[rule]][j],
        p_treated_post = o$treated_post[[rule]][j],
        p_control_pre = o$control_pre[[rule]][j],
        p_control_post = o$control_post[[rule]][j],
        delta_treated = o$treated_post[[rule]][j] - o$treated_pre[[rule]][j],
        delta_control = o$control_post[[rule]][j] - o$control_pre[[rule]][j],
        did = (o$treated_post[[rule]][j] - o$treated_pre[[rule]][j]) -
              (o$control_post[[rule]][j] - o$control_pre[[rule]][j])
      )
    }
  }
}
winner_distributions <- bind_rows(wd_rows)
write_csv(winner_distributions, file.path(output_dir, "winner_distributions.csv"))

ce_rows <- list()
for (k in k_values) {
  o <- obs_stats[[as.character(k)]]
  s <- stats_per_k[[as.character(k)]]
  ce_rows[[length(ce_rows) + 1]] <- tibble(
    k = k,
    theta_T_pre = o$treated_pre$cw_share,
    theta_T_post = o$treated_post$cw_share,
    theta_C_pre = o$control_pre$cw_share,
    theta_C_post = o$control_post$cw_share,
    delta_T_cw = o$treated_post$cw_share - o$treated_pre$cw_share,
    delta_C_cw = o$control_post$cw_share - o$control_pre$cw_share,
    did_cw = (o$treated_post$cw_share - o$treated_pre$cw_share) -
             (o$control_post$cw_share - o$control_pre$cw_share),
    abs_did_cw = abs((o$treated_post$cw_share - o$treated_pre$cw_share) -
                     (o$control_post$cw_share - o$control_pre$cw_share)),
    raw_p_cw = s$raw_p["condorcet"],
    p_adj_rw_cw = s$p_adj_rw["condorcet"],
    null_mean = s$null_mean["condorcet"],
    null_sd = s$null_sd["condorcet"]
  )
}
condorcet_existence <- bind_rows(ce_rows)
write_csv(condorcet_existence, file.path(output_dir, "condorcet_existence.csv"))

ts_rows <- list()
for (k in k_values) {
  s <- stats_per_k[[as.character(k)]]
  for (stat in stat_names) {
    ts_rows[[length(ts_rows) + 1]] <- tibble(
      k = k,
      statistic = stat,
      value = s$abs_obs[stat],
      null_mean = s$null_mean[stat],
      null_sd = s$null_sd[stat],
      t_obs = s$t_obs[stat],
      raw_p = s$raw_p[stat],
      p_adj_rw = s$p_adj_rw[stat],
      reject_rw_05 = s$p_adj_rw[stat] <= alpha,
      assumed_effect = s$assumed_effect[stat],
      assumed_effect_source = s$assumed_effect_source[stat],
      power_null_crit = s$power_null_crit[stat],
      n_per_arm_80_power = as.integer(s$n_per_arm_80_power[stat]),
      n_total_80_power = as.integer(s$n_total_80_power[stat])
    )
  }
}
test_statistics <- bind_rows(ts_rows)
write_csv(test_statistics, file.path(output_dir, "test_statistics.csv"))

omnibus_rows <- list()
for (k in k_values) {
  s <- stats_per_k[[as.character(k)]]
  o <- obs_stats[[as.character(k)]]
  omnibus_rows[[length(omnibus_rows) + 1]] <- tibble(
    k = k,
    estimator = "did",
    T_max_obs = s$T_max_obs,
    p_omnibus = s$p_omnibus,
    n_treated_groups = o$n_groups_treated,
    n_control_groups = o$n_groups_control,
    groups_per_arm = groups_per_arm,
    B = B,
    seed = seed,
    alpha = alpha,
    power_target = power_target,
    power_n_round_to = power_n_round_to,
    n_treated = n_T,
    n_control = n_C,
    K = K
  )
}
omnibus_scalars <- bind_rows(omnibus_rows)
write_csv(omnibus_scalars, file.path(output_dir, "omnibus_scalars.csv"))

nq_rows <- list()
for (k in k_values) {
  ns <- null_stats[[as.character(k)]]
  for (stat in stat_names) {
    v <- ns[[stat]]
    qs <- quantile(v, probs = c(0.50, 0.90, 0.95, 0.99), names = FALSE)
    nq_rows[[length(nq_rows) + 1]] <- tibble(
      k = k,
      statistic = stat,
      null_q50 = qs[1],
      null_q90 = qs[2],
      null_q95 = qs[3],
      null_q99 = qs[4],
      null_mean = mean(v),
      null_sd = sd(v)
    )
  }
}
null_quantiles <- bind_rows(nq_rows)
write_csv(null_quantiles, file.path(output_dir, "null_quantiles.csv"))

ccw_rows <- list()
for (k in k_values) {
  o <- obs_stats[[as.character(k)]]
  for (j in seq_len(K)) {
    ccw_rows[[length(ccw_rows) + 1]] <- tibble(
      k = k,
      option = option_codes[j],
      p_cond_T_pre = o$treated_pre$cw_cond[j],
      p_cond_T_post = o$treated_post$cw_cond[j],
      p_cond_C_pre = o$control_pre$cw_cond[j],
      p_cond_C_post = o$control_post$cw_cond[j],
      did = (o$treated_post$cw_cond[j] - o$treated_pre$cw_cond[j]) -
            (o$control_post$cw_cond[j] - o$control_pre$cw_cond[j])
    )
  }
}
conditional_cw <- bind_rows(ccw_rows)
write_csv(conditional_cw, file.path(output_dir, "conditional_condorcet_winner.csv"))

# -----------------------------------------------------------------------------
# Figures
# -----------------------------------------------------------------------------

wd_primary <- winner_distributions %>%
  filter(k == k_primary) %>%
  mutate(option_label = option_labels[option]) %>%
  pivot_longer(cols = c(delta_treated, delta_control, did),
               names_to = "series", values_to = "value") %>%
  mutate(series = recode(series,
                         delta_treated = "Treated post-pre",
                         delta_control = "Control post-pre",
                         did = "DiD"),
         rule = factor(rule,
                       levels = c("plurality", "borda", "irv", "copeland"),
                       labels = c("Plurality", "Borda", "IRV", "Copeland")))

p_wd <- ggplot(wd_primary, aes(x = option_label, y = value, fill = series)) +
  geom_col(position = position_dodge(width = 0.75), width = 0.7) +
  facet_wrap(~ rule, ncol = 2) +
  scale_fill_manual(values = c("Treated post-pre" = "#1B4F72",
                               "Control post-pre" = "#5D6D7E",
                               "DiD" = "#B03A2E")) +
  labs(
    title = sprintf("Rule winner changes at k=%d: post-pre by arm and DiD", k_primary),
    x = NULL,
    y = "Probability change",
    fill = NULL
  ) +
  theme_minimal(base_size = 12) +
  theme(legend.position = "bottom",
        axis.text.x = element_text(angle = 25, hjust = 1))
ggsave(file.path(figures_dir, "winner_distributions_primary.png"), p_wd,
       width = 11, height = 7, dpi = 150)

tvd_panel <- test_statistics %>%
  filter(statistic %in% c("plurality", "borda", "irv", "copeland")) %>%
  mutate(rule = factor(statistic,
                       levels = c("plurality", "borda", "irv", "copeland"),
                       labels = c("Plurality", "Borda", "IRV", "Copeland")),
         k_label = factor(sprintf("k = %d", k), levels = sprintf("k = %d", k_values)),
         label = sprintf("raw p=%.3f\nRW p=%.3f", raw_p, p_adj_rw))

p_tvd <- ggplot(tvd_panel, aes(x = rule, y = value, fill = reject_rw_05)) +
  geom_col(width = 0.65) +
  geom_text(aes(label = label, y = value), vjust = -0.2, size = 2.8) +
  facet_wrap(~ k_label, ncol = length(k_values)) +
  scale_fill_manual(values = c(`TRUE` = "#1B4F72", `FALSE` = "#5D6D7E"),
                    labels = c(`TRUE` = "Reject RW p<.05", `FALSE` = "Not rejected")) +
  scale_y_continuous(limits = c(0, max(tvd_panel$value) * 1.4)) +
  labs(
    title = "Per-rule DiD TVD between treated and control change vectors",
    subtitle = "TVD = 1/2 * sum_j |(post-pre)_T - (post-pre)_C|",
    x = NULL,
    y = "TVD on changes",
    fill = NULL
  ) +
  theme_minimal(base_size = 12) +
  theme(legend.position = "bottom",
        axis.text.x = element_text(angle = 25, hjust = 1))
ggsave(file.path(figures_dir, "tvd_panel.png"), p_tvd,
       width = 12, height = 6, dpi = 150)

ce_plot <- condorcet_existence %>%
  mutate(k_label = factor(sprintf("k = %d", k), levels = sprintf("k = %d", k_values))) %>%
  select(k_label, delta_T_cw, delta_C_cw, did_cw) %>%
  pivot_longer(cols = c(delta_T_cw, delta_C_cw, did_cw), names_to = "series", values_to = "value") %>%
  mutate(series = recode(series,
                         delta_T_cw = "Treated post-pre",
                         delta_C_cw = "Control post-pre",
                         did_cw = "DiD"))

p_ce <- ggplot(ce_plot, aes(x = series, y = value, fill = series)) +
  geom_col(width = 0.6) +
  facet_wrap(~ k_label, ncol = length(k_values)) +
  scale_fill_manual(values = c("Treated post-pre" = "#1B4F72",
                               "Control post-pre" = "#5D6D7E",
                               "DiD" = "#B03A2E")) +
  labs(
    title = "Condorcet-existence change by arm and DiD",
    x = NULL,
    y = "Change in P(CW exists)",
    fill = NULL
  ) +
  theme_minimal(base_size = 12) +
  theme(legend.position = "none",
        axis.text.x = element_text(angle = 25, hjust = 1))
ggsave(file.path(figures_dir, "condorcet_existence.png"), p_ce,
       width = 11, height = 5, dpi = 150)

null_long <- bind_rows(lapply(k_values, function(k) {
  ns <- null_stats[[as.character(k)]]
  bind_rows(
    tibble(k = k, statistic = "plurality", value = ns$plurality),
    tibble(k = k, statistic = "borda", value = ns$borda),
    tibble(k = k, statistic = "irv", value = ns$irv),
    tibble(k = k, statistic = "copeland", value = ns$copeland),
    tibble(k = k, statistic = "condorcet", value = ns$condorcet)
  )
})) %>%
  mutate(stat_label = factor(statistic,
                             levels = c("plurality", "borda", "irv", "copeland", "condorcet"),
                             labels = c("Plurality TVD", "Borda TVD", "IRV TVD", "Copeland TVD", "|DiD CW|")),
         k_label = factor(sprintf("k = %d", k), levels = sprintf("k = %d", k_values)))

obs_long <- test_statistics %>%
  mutate(stat_label = factor(statistic,
                             levels = c("plurality", "borda", "irv", "copeland", "condorcet"),
                             labels = c("Plurality TVD", "Borda TVD", "IRV TVD", "Copeland TVD", "|DiD CW|")),
         k_label = factor(sprintf("k = %d", k), levels = sprintf("k = %d", k_values)))

p_null <- ggplot(null_long, aes(x = value)) +
  geom_histogram(bins = 40, fill = "#D6DBDF", color = "white") +
  geom_vline(data = obs_long, aes(xintercept = value), color = "#B03A2E", linewidth = 0.8) +
  facet_grid(k_label ~ stat_label, scales = "free") +
  labs(
    title = "Permutation null distributions and observed DiD statistics",
    subtitle = sprintf("B = %d permutations; red line = observed value.", B),
    x = "Statistic value",
    y = "Count"
  ) +
  theme_minimal(base_size = 11) +
  theme(strip.text = element_text(size = 9))
ggsave(file.path(figures_dir, "null_distributions.png"), p_null,
       width = 14, height = 7, dpi = 150)

# -----------------------------------------------------------------------------
# Console summary
# -----------------------------------------------------------------------------

cat("\n============================================================\n")
cat("RULE PANEL DID RESULTS\n")
cat("============================================================\n")
print(test_statistics %>%
        mutate(across(c(value, null_mean, null_sd, t_obs, raw_p, p_adj_rw,
                        assumed_effect, power_null_crit),
                      ~ sprintf("%.4f", .))))

cat("\n--- Joint omnibus per k ---\n")
print(omnibus_scalars)

cat("\nWrote:\n")
cat(sprintf("  %s/{winner_distributions,test_statistics,condorcet_existence,omnibus_scalars,null_quantiles,conditional_condorcet_winner}.csv\n", output_dir))
cat(sprintf("  %s/{winner_distributions_primary,tvd_panel,condorcet_existence,null_distributions}.png\n", figures_dir))

cat("\nR sessionInfo:\n")
print(sessionInfo())
