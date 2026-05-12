# Rule-Output Panel DiD under Randomization Inference

**Outcome 3** of the [analysis plan](../../notes/analysis-plan.md): whether treatment changes collective-choice outputs across voting rules.

## Setup

This report is now **DiD-first** at the rule-output level.

For each `k in {3,5,7}` and each rule (plurality, Borda, IRV, Copeland):

1. Compute winner distributions by arm at pre and post.
2. Compute arm-level change vector `delta_arm = P_post - P_pre`.
3. Compute DiD distance:

`TVD_did(rule,k) = 1/2 * sum_j |delta_T(j) - delta_C(j)|`

For Condorcet existence:

`abs_did_cw(k) = |(theta_T_post-theta_T_pre) - (theta_C_post-theta_C_pre)|`

Current run:

- `n_C = 30`, `n_T = 32`, `K=4`
- `k = 3,5,7`
- `B = 5000` permutations

## Methods

### Why DiD here

Outcome 3 now asks whether **changes over time** in rule outputs differ between treatment and control, rather than whether post levels differ cross-sectionally.

### Inference

- Primary inference: permutation RI shuffling arm labels on pre/post respondent tuples.
- Family-wise correction: Romano-Wolf across 5 stats per `k`.
- Joint omnibus: `max-t` over those 5 stats.

### Group construction

- If `choose(n_arm,k)` is modest, script uses exhaustive arm subsets.
- Otherwise, it samples `groups_per_arm` subsets (`4000` current config).

### Power planning

The `Target effect` and `N/arm 80%` columns are planning heuristics, not additional RI tests. For plurality/Borda/IRV/Copeland, the assumed effect is `0.10` TVD, matching the rounded Farrar-scale deliberation benchmark (`0.068`-`0.117`, average `0.092`) rather than the larger cross-rule disagreement anchor. For each k/rule, the recommended `N/arm` uses that rule's permutation-null 95th percentile and SD, scaled as respondent-level balanced-arm sample size grows, and rounded up to the nearest 10. Condorcet power planning is skipped for now.

## Results

### Omnibus by k

| k | T_max_obs | p_omnibus |
|---:|---:|---:|
| 3 | 4.4917 | 0.0256 |
| 5 | 4.2020 | 0.0458 |
| 7 | 4.3220 | 0.0374 |

Omnibus rejects at `alpha=0.05` for each k in this run.

### Per-statistic DiD distances and inference

| k | Statistic | Value | null_mean | null_sd | raw p | RW p | Target effect | N/arm 80% |
|---:|---|---:|---:|---:|---:|---:|---:|---:|
| 3 | plurality | 0.3380 | 0.1446 | 0.0752 | 0.0124 | 0.0256 | 0.10 | 360 |
| 3 | borda | 0.2848 | 0.1198 | 0.0693 | 0.0266 | 0.0422 | 0.10 | 300 |
| 3 | irv | 0.2769 | 0.1287 | 0.0666 | 0.0308 | 0.0422 | 0.10 | 300 |
| 3 | copeland | 0.2857 | 0.1224 | 0.0664 | 0.0190 | 0.0302 | 0.10 | 290 |
| 3 | condorcet | 0.0253 | 0.0155 | 0.0112 | 0.2012 | 0.2012 | skipped | skipped |
| 5 | plurality | 0.3977 | 0.1707 | 0.0961 | 0.0222 | 0.0480 | 0.10 | 600 |
| 5 | borda | 0.3360 | 0.1407 | 0.0903 | 0.0334 | 0.0624 | 0.10 | 470 |
| 5 | irv | 0.3575 | 0.1446 | 0.0851 | 0.0198 | 0.0458 | 0.10 | 460 |
| 5 | copeland | 0.3172 | 0.1413 | 0.0848 | 0.0360 | 0.0624 | 0.10 | 450 |
| 5 | condorcet | 0.0213 | 0.0147 | 0.0111 | 0.2537 | 0.2537 | skipped | skipped |
| 7 | plurality | 0.5020 | 0.2021 | 0.1162 | 0.0130 | 0.0374 | 0.10 | 900 |
| 7 | borda | 0.3965 | 0.1564 | 0.1058 | 0.0286 | 0.0560 | 0.10 | 620 |
| 7 | irv | 0.4152 | 0.1669 | 0.1058 | 0.0256 | 0.0508 | 0.10 | 660 |
| 7 | copeland | 0.3613 | 0.1588 | 0.1005 | 0.0414 | 0.0682 | 0.10 | 610 |
| 7 | condorcet | 0.0143 | 0.0113 | 0.0092 | 0.3031 | 0.3031 | skipped | skipped |

### Condorcet existence DiD component

| k | delta_T_cw | delta_C_cw | did_cw | abs_did_cw |
|---:|---:|---:|---:|---:|
| 3 | -0.0149 | 0.0103 | -0.0253 | 0.0253 |
| 5 | -0.0050 | 0.0163 | -0.0213 | 0.0213 |
| 7 | -0.0043 | 0.0100 | -0.0143 | 0.0143 |

### k=5 winner-change diagnostics (DiD components)

At `k=5`, control deltas are expected to be smaller than treated deltas in many runs because phase 1 is a no-cross-pollination baseline, but they are no longer forced to zero by construction.

Largest absolute `did` cells:

- plurality, community_clinic: `+0.3882`
- irv, community_clinic: `+0.3350`
- borda, community_clinic: `+0.3260`
- borda, food_pantry: `-0.3020`
- copeland, community_clinic: `+0.3015`
- irv, food_pantry: `-0.2848`

## Literature Benchmarks

Direct apples-to-apples benchmarks are scarce: the literature usually reports attitude change, cross-rule winner agreement, or Condorcet failure/cyclicity, not DiD TVD of synthetic-group winner distributions. Read these as scale anchors, not priors for the exact estimand.

| Anchor | Published benchmark | How to read against this report |
|---|---|---|
| Deliberation-induced attitude movement | Farrar et al. summarize seven deliberative polls where mean absolute net attitude change across 50 policy indices ranges from `0.068` to `0.117` (average `0.092`). | The power columns use `0.10` TVD as the planning target, because it is closer to this deliberation-effect scale than the larger cross-rule disagreement benchmark. The observed rule-output TVD DiD values are larger, but they are downstream collective-choice shifts after a non-linear rule map, not individual attitude ATEs. |
| Cross-rule winner disagreement | McCune and McCune, as summarized by Fox and Bruyns, find pairwise method agreement in the vast majority of U.S. RCV elections, with the lowest-agreement pair (plurality vs. a Borda variant) agreeing about `76%` of the time. Fox and Bruyns also find all five Borda variants agree in `384/421` elections (about `91%`). | The `24%` highest cross-method disagreement benchmark is a useful upper-scale anchor, but it is too aggressive for the power target if the goal is to plan around literature-sized deliberation effects. |
| Large-panel RCV rule agreement | The Institute for Mathematics and Democracy analyzed about `4,000` ranked-ballot elections, including about `2,000` political elections, and reports that IRV and Condorcet methods agree overwhelmingly often in their real-world sample. | The similar nonzero TVD range across plurality, Borda, IRV, and Copeland is useful because empirical social-choice work often finds rule outputs agree more than worst-case theory suggests. |
| Empirical IRV failure rates | Graham-Squire and McCune's IRV panel, summarized by Fox and Bruyns, reports low empirical failure rates: Condorcet-winner failure `1.1%`, compromise `3.8%`, spoiler `1.6%`, upward monotonicity `1.6%`, downward monotonicity `1.1%`, and no-show `0.5%`. | The report's treated-control changes are not failure rates, but these numbers are useful guardrails: major real-election rule failures are usually rare; the movement here is about which charity wins synthetic groups, not whether a rule violates a fairness criterion. |
| Condorcet existence/cycles | Felsenthal, Maoz, and Rapoport find a Condorcet winner in `35/37` British organizational elections. Fox and Bruyns' U.S. RCV panel has a Condorcet winner in `419/421` elections. Barbaro and Kurella find no robust Condorcet paradox in `253` national-election surveys and only `5` cyclical triplets among `8,099` triplets (`0.06%`). | The Condorcet-existence DiD values here are small (`0.014`-`0.025`), which is in line with empirical work: when preferences are coherent enough that a Condorcet winner usually exists, treatment has little room to change existence. The more relevant movement is winner identity under rules, not Condorcet existence. |

Practical read: the `k=5` rule-output TVDs around `0.32`-`0.40` are substantively large as distributional movements. The power-planning target is intentionally lower (`0.10`) because it is anchored to Farrar-scale deliberation movement, not to the larger observed pilot effects. Condorcet-existence power is skipped for now and should remain framed as a separate, ceiling-limited diagnostic.

## Caveats

1. **Control trend is now measured, not synthetic.** The current pipeline builds `phase1_participant_changes.csv` from extracted `initial_vote_ranking` and `final_vote_ranking`, so `delta_C` is not mechanically fixed at zero.
2. **Interpretation remains design-sensitive.** Phase 1 still serves as a no-cross-pollination baseline, so control pre/post movement should be interpreted as within-session drift or measurement variation rather than exposure-induced change.
3. **Sampling of synthetic groups.** For larger combinatorics, group sets are Monte Carlo sampled (`groups_per_arm=4000`) and then embedded within RI; this introduces simulation variance beyond permutation variance.
4. **Multiplicity scope.** RW correction is within each-k family of 5 stats, not across all ks combined.

## Figures

- [`figures/winner_distributions_primary.png`](figures/winner_distributions_primary.png)
- [`figures/tvd_panel.png`](figures/tvd_panel.png)
- [`figures/condorcet_existence.png`](figures/condorcet_existence.png)
- [`figures/null_distributions.png`](figures/null_distributions.png)

## References

- Barbaro, S. and Kurella, A.-S. (2025). [On the prevalence of Condorcet's paradox](https://link.springer.com/article/10.1007/s11127-025-01353-7). *Public Choice*.
- Farrar, C., Fishkin, J. S., Green, D. P., List, C., Luskin, R. C., and Paluck, E. L. (2010). [Disaggregating Deliberation's Effects: An Experiment within a Deliberative Poll](https://doi.org/10.1017/S0007123409990433). *British Journal of Political Science*, 40(2), 333-347.
- Felsenthal, D. S., Maoz, Z., and Rapoport, A. (1993). [An Empirical Evaluation of Six Voting Procedures: Do They Really Make Any Difference?](https://doi.org/10.1017/S0007123400006542). *British Journal of Political Science*, 23(1), 1-27.
- Fox, N. B. and Bruyns, B. (2025). [An evaluation of Borda count variations using ranked choice voting data](https://link.springer.com/article/10.1007/s00355-025-01638-2). *Social Choice and Welfare*.
- Graham-Squire, A. and McCune, D. (2025). [An Examination of Ranked-Choice Voting in the United States, 2004-2022](https://doi.org/10.1080/00344893.2023.2221689). *Representation*, 61(1), 1-19.
- Institute for Mathematics and Democracy. (2025). [Empirical analysis of ranked choice voting methods](https://mathematics-democracy-institute.org/empirical-analysis-of-ranked-choice-voting-methods/).
- McCune, D. and McCune, L. (2024). [Does the Choice of Preferential Voting Method Matter? An Empirical Study Using Ranked Choice Elections in the United States](https://doi.org/10.1080/00344893.2022.2133003). *Representation*, 60(1), 1-16.
- Regenwetter, M., Kim, A., Kantor, A., and Ho, M.-H. R. (2007). [The Unexpected Empirical Consensus Among Consensus Methods](https://doi.org/10.1111/j.1467-9280.2007.01950.x). *Psychological Science*, 18(7), 629-635.

## Reproducibility

```bash
Rscript reports/rule-output-panel/analysis/run_rule_panel.R
```

## Outputs

- [`analysis/output/winner_distributions.csv`](analysis/output/winner_distributions.csv)
- [`analysis/output/test_statistics.csv`](analysis/output/test_statistics.csv)
- [`analysis/output/condorcet_existence.csv`](analysis/output/condorcet_existence.csv)
- [`analysis/output/omnibus_scalars.csv`](analysis/output/omnibus_scalars.csv)
- [`analysis/output/null_quantiles.csv`](analysis/output/null_quantiles.csv)
- [`analysis/output/conditional_condorcet_winner.csv`](analysis/output/conditional_condorcet_winner.csv)
