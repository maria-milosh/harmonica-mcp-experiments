# Pairwise Preference DiD on the Harmonica Deliberation Pilot

**Outcome 1** of the [analysis plan](../../notes/analysis-plan.md): for every option pair, estimate treatment-attributable change in the probability that the first option is ranked above the second.

## Setup

The current analysis is **DiD-first**:

- Control arm and treatment arm both have pre/post rankings available in analysis inputs.
- Unit of analysis is respondent-level pair indicator change.
- Options: `animal_rescue`, `community_clinic`, `food_pantry`, `urban_tree` (`K=4`, so 6 unordered pairs).
- Sample sizes in this run: `n_C = 30`, `n_T = 32`.

Full context: [`notes/analysis-plan.md`](../../notes/analysis-plan.md).

**Reproducibility.** From repo root:

```bash
Rscript reports/pairwise-preferences/analysis/run_pairwise_ate.R
```

Primary outputs are written to `reports/pairwise-preferences/analysis/output/` and figures to `reports/pairwise-preferences/figures/`.

## Methods

### Estimand

For pair `(j, k)`, respondent `i`, and wave `w in {pre, post}`:

- `Y_iw,jk = 1{ j ranked above k at wave w }`
- Within-arm pair change: `Delta_d,jk = E[Y_post - Y_pre | D=d]`
- **DiD estimand**:

`tau_did,jk = Delta_T,jk - Delta_C,jk`

Positive `tau_did,jk` means treatment increased `P(j ≻ k)` relative to control trend.

### Point estimates and descriptive uncertainty

- Point estimate per pair: sample mean of respondent-level pair deltas.
- Descriptive SE per pair: variance of respondent-level pair deltas in each arm combined as
  `SE = sqrt(Var(D_T)/n_T + Var(D_C)/n_C)`.
- Descriptive 95% CI: `tau_did ± 1.96*SE`.

### Primary inference

- **Randomization inference (RI):** permute arm labels across respondent-level delta vectors (`B=10,000`), preserving arm sizes.
- Per-pair p-values from permutation null.
- Multiplicity control across 6 pairs with **Romano-Wolf step-down** using max-|t| reconstruction.

### Joint omnibus and magnitude scalar

The report keeps the analysis-plan headline scalars:

1. Joint Wald statistic (`tau' Sigma^+ tau`, rank-aware)
2. Permutation `T_max = max |t|`
3. Permutation `T_ss = sum t^2`
4. RMS DiD magnitude: `sqrt(mean(tau_did^2))`

## Results

### Headline scalars

| Quantity | Value |
|---|---:|
| **RMS DiD shift** | **0.0750** (= **7.50 pp**) |
| Joint Wald `W` | 12.980 |
| Wald rank | 6 |
| Wald p-value | 0.0434 |
| Permutation `T_max` p-value | 0.3890 |
| Permutation `T_ss` p-value | 0.1951 |
| Joint reject @ `alpha=0.05` | **Yes by Wald; No by RI** |

Interpretation: directional movement is present but more modest after manual correction of two Phase 1 extraction rows. The rank-aware Wald diagnostic rejects at `alpha=0.05`, but the RI-based joint tests remain well above 0.05.

### Per-pair DiD estimates

| Pair | `tau_did` | SE | 95% CI | raw RI p | RW-adjusted p |
|---|---:|---:|---:|---:|---:|
| community_clinic > food_pantry | +0.1271 | 0.0766 | [-0.0231, +0.2772] | 0.1356 | 0.3890 |
| animal_rescue > community_clinic | -0.0938 | 0.0690 | [-0.2289, +0.0414] | 0.2369 | 0.7569 |
| animal_rescue > urban_tree | -0.0625 | 0.0435 | [-0.1477, +0.0227] | 0.4944 | 0.7569 |
| community_clinic > urban_tree | -0.0625 | 0.0435 | [-0.1477, +0.0227] | 0.4976 | 0.7569 |
| food_pantry > urban_tree | -0.0312 | 0.0547 | [-0.1385, +0.0760] | 0.6495 | 0.8239 |
| animal_rescue > food_pantry | +0.0000 | 0.0449 | [-0.0880, +0.0880] | 1.0000 | 1.0000 |

No pair rejects after RW correction.

### Matrix and forest figures

- Heatmap: [`figures/tau_heatmap.png`](figures/tau_heatmap.png)
- Forest: [`figures/tau_forest.png`](figures/tau_forest.png)

### Level/trend decomposition columns in output

`pairwise_ate.csv` includes:

- `p_C_pre`, `p_C_post`, `p_T_pre`, `p_T_post`
- `delta_C`, `delta_T`
- `tau_did`
- `tau_post_only` (post-only cross-sectional companion; secondary diagnostic)

## Power analysis (RW-first)

Power is computed in:

```bash
Rscript reports/pairwise-preferences/analysis/run_pairwise_ate_power.R
```

The power script is now **Romano-Wolf discovery first** (pair-specific multiplicity-aware discovery), with Wald/Tmax retained as secondary omnibus diagnostics.

### Cross-sectional-style calibration (`power_n_required.csv`)

| Control DGP / Tau shape | `n_per_arm_80_rw_any` | `n_per_arm_80_wald` | `n_per_arm_80_tmax` |
|---|---:|---:|---:|
| `phase1_empirical / diffuse_PL` | 900 | 600 | 950 |
| `phase1_empirical / pilot_proportional` | 950 | 900 | 950 |
| `uniform_K4 / diffuse_PL` | 2050 | 2150 | 2000 |
| `uniform_K4 / pilot_proportional` | 1750 | 1500 | 1750 |

Interpretation: under the current pilot calibrations, RW discovery requires about `n=900–950` per arm in the phase-1-empirical cells, and about `n=1750–2050` per arm in the uniform control cells.

### DiD calibration (`did_n_required.csv`)

| DiD design / Tau shape | `n_per_arm_80_rw_any` | `n_per_arm_80_wald` | `n_per_arm_80_tmax` |
|---|---:|---:|---:|
| `DiD_parametric / diffuse_PL` | 500 | 300 | 500 |
| `DiD_parametric / pilot_proportional` | 500 | 450 | 450 |
| `DiD_regularized_empirical / diffuse_PL` | 450 | 300 | 450 |
| `DiD_regularized_empirical / pilot_proportional` | 500 | 400 | 500 |

Interpretation: under paired DiD calibration, RW-any discovery is around `n=450–500` per arm.

### Pair-level RW detectability (`power_rw_pair_n_required.csv`, `did_power_rw_pair_n_required.csv`)

Some pairs are much harder to detect than others at 80% RW power. In this run:

- Cross-sectional (`phase1_empirical / diffuse_PL`): `animal_rescue > urban_tree` reaches 80% at `n=1150/arm`, while `animal_rescue > food_pantry` needs `n=3500/arm`; several pairs remain above grid (`NA`, i.e. >4000/arm).
- DiD (`DiD_parametric / diffuse_PL`): `animal_rescue > urban_tree` reaches 80% at `n=600/arm`, `community_clinic > urban_tree` at `n=1400/arm`, `animal_rescue > food_pantry` at `n=1850/arm`.

### Simulation check

At the cross-sectional headline cell (`uniform_K4 / diffuse_PL`), empirical RW-any power checks are:

- `n=1850`: 0.815
- `n=2050`: 0.855
- `n=2250`: 0.895

This is consistent with the reported `n_per_arm_80_rw_any = 2050`.

## Caveats

1. **Control pre/post now comes from extracted phase-1 initial/final rankings.** The current pipeline maps `initial_vote_ranking` and `final_vote_ranking` into `phase1_participant_changes.csv`, so `Delta_C` is no longer mechanically fixed at zero.
2. **Pairwise marginals are not the full ranking distribution.** Outcome 3 remains necessary for collective-choice consequences.
3. **Multiplicity scope.** RW family here is the six pair tests only.
4. **Pilot uncertainty.** RI calibration is exact under label-exchangeability, but sample size still limits power.

## Verification checks in script

The script computes and writes:

- per-pair RI null summaries (`perm_null_summary.csv`)
- joint statistics and p-values (`omnibus_scalars.csv`)
- full pair table with RW decisions (`pairwise_ate.csv`)

## Outputs

- [`analysis/output/pairwise_ate.csv`](analysis/output/pairwise_ate.csv)
- [`analysis/output/pairwise_levels.csv`](analysis/output/pairwise_levels.csv)
- [`analysis/output/omnibus_scalars.csv`](analysis/output/omnibus_scalars.csv)
- [`analysis/output/perm_null_summary.csv`](analysis/output/perm_null_summary.csv)
- [`analysis/output/power_n_required.csv`](analysis/output/power_n_required.csv)
- [`analysis/output/power_rw_pair_n_required.csv`](analysis/output/power_rw_pair_n_required.csv)
- [`analysis/output/power_curve.csv`](analysis/output/power_curve.csv)
- [`analysis/output/power_simulation_check.csv`](analysis/output/power_simulation_check.csv)
- [`analysis/output/power_tau_candidates.csv`](analysis/output/power_tau_candidates.csv)
- [`analysis/output/did_n_required.csv`](analysis/output/did_n_required.csv)
- [`analysis/output/did_power_curve.csv`](analysis/output/did_power_curve.csv)
- [`analysis/output/did_power_rw_pair_n_required.csv`](analysis/output/did_power_rw_pair_n_required.csv)
- [`analysis/output/did_test_retest_rho.csv`](analysis/output/did_test_retest_rho.csv)
- [`figures/tau_heatmap.png`](figures/tau_heatmap.png)
- [`figures/tau_forest.png`](figures/tau_forest.png)
- [`figures/power_curves.png`](figures/power_curves.png)
- [`figures/power_curves_did.png`](figures/power_curves_did.png)
