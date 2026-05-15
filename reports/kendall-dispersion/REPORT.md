# Kendall Dispersion DiD on the Harmonica Deliberation Pilot

**Outcome 2** of the [analysis plan](../../notes/analysis-plan.md): treatment-attributable change in interpersonal ranking dispersion.

## Setup

This report is now **DiD-first**.

- For each arm and wave, compute within-arm mean Kendall dispersion `dbar`.
- Arm-level change: `delta_arm = dbar_post - dbar_pre`.
- DiD estimand: `did = delta_T - delta_C`.

Current run sample sizes:

- `n_C = 30`
- `n_T = 32`

## Methods

### Estimand

Let `dbar_d,w` be mean Kendall pair-disagreement rate within arm `d` at wave `w`.

- `delta_C = dbar_C,post - dbar_C,pre`
- `delta_T = dbar_T,post - dbar_T,pre`
- **DiD:** `did = delta_T - delta_C`

Positive DiD means treatment increased dispersion relative to control trend.

### Estimation details

- Rankings are converted to pair-indicator matrices.
- Within-wave dispersion uses the identity/U-statistic form based on pairwise disagreement rates.
- Script also stores per-pair contributions via `2p(1-p)` at pre and post in each arm for decomposition.

### Inference

- **Primary:** permutation RI by shuffling arm labels on respondent pre/post tuples (`B_perm=10,000`).
- **Bootstrap companion:** respondent-level paired resampling within arm (`B_boot=10,000`).
- Hájek-style SE is retained as descriptive uncertainty.

## Results

### Headline scalars

| Quantity | Value |
|---|---:|
| `dbar_C_pre` | 0.3153 |
| `dbar_C_post` | 0.3119 |
| `delta_C` | -0.0034 |
| `dbar_T_pre` | 0.3884 |
| `dbar_T_post` | 0.3968 |
| `delta_T` | +0.0084 |
| **DiD** | **+0.0118** (= **+1.18 pp**) |
| RI two-sided p | 0.7178 |
| Bootstrap 95% CI | [-0.0464, +0.0689] |
| Hájek 95% CI | [-0.1597, +0.1834] |

Interpretation: no evidence of a detectable DiD effect on dispersion in this run.

### Per-pair contribution decomposition

Per pair, the script tracks contribution shifts through `2p(1-p)` and reports DiD contribution change:

| Pair | `p_C_pre` | `p_C_post` | `p_T_pre` | `p_T_post` | `contrib_did` |
|---|---:|---:|---:|---:|---:|
| animal_rescue > community_clinic | 0.3000 | 0.3000 | 0.2812 | 0.1875 | -0.0996 |
| animal_rescue > food_pantry | 0.2333 | 0.2333 | 0.2188 | 0.2188 | +0.0000 |
| animal_rescue > urban_tree | 0.8667 | 0.8667 | 0.6562 | 0.5938 | +0.0312 |
| community_clinic > food_pantry | 0.3667 | 0.3333 | 0.4375 | 0.5312 | +0.0259 |
| community_clinic > urban_tree | 0.8667 | 0.8667 | 0.8125 | 0.7500 | +0.0703 |
| food_pantry > urban_tree | 0.9333 | 0.9333 | 0.8438 | 0.8125 | +0.0410 |

Figure references:

- [`figures/dispersion_decomposition.png`](figures/dispersion_decomposition.png)
- [`figures/delta_distribution.png`](figures/delta_distribution.png)

## Power analysis

Power is computed in:

```bash
Rscript reports/kendall-dispersion/analysis/run_kendall_dispersion_power.R
```

The script reports two complementary calibrations:

1. Outcome-1-aligned RMS pairwise shift alternatives (`RMS = 3 pp`), translated into induced dispersion shifts.
2. Direct `Δ`-target alternatives (`Δ = -3, -5, -8, -10 pp`).

### RMS-alternative calibration (`power_n_required_rms.csv`)

| Cell | Induced `Δ` (pp) | `n_per_arm_80` |
|---|---:|---:|
| `uniform_K4 / diffuse_PL` | -0.18 | 2400 |
| `uniform_K4 / pilot_proportional` | -0.16 | 2650 |
| `phase1_empirical / diffuse_PL` | +19.65 | 50 |
| `phase1_empirical / pilot_proportional` | +1.93 | 2100 |

Interpretation: an RMS=3pp pairwise shift can imply very different dispersion effects depending on the control level matrix and tau shape.

### Direct-Δ calibration (`power_n_required_delta.csv`)

Phase-1-empirical control (most design-relevant row family):

| Target `Δ` | Realized `Δ` (pp) | `n_per_arm_80` |
|---|---:|---:|
| `-3 pp` | -3.10 | 800 |
| `-5 pp` | -5.01 | 300 |
| `-8 pp` | -8.12 | 150 |
| `-10 pp` | -9.99 | 100 |

Uniform-control calibration (for comparison):

| Target `Δ` | Realized `Δ` (pp) | `n_per_arm_80` |
|---|---:|---:|
| `-3 pp` | -3.03 | 150 |
| `-5 pp` | -4.92 | 100 |
| `-8 pp` | -8.01 | 50 |
| `-10 pp` | -9.98 | 50 |

### Simulation check (`power_simulation_check.csv`)

For the headline direct-Δ empirical-control target (`Δ ≈ -5 pp`):

- `n=100`: power 0.33
- `n=300`: power 0.78
- `n=500`: power 0.92

This puts `n_per_arm_80 = 300` near the practical 80% threshold for that target in this run.

## Caveats

1. **Control pre/post now comes from extracted phase-1 initial/final rankings.** The current pipeline maps `initial_vote_ranking` and `final_vote_ranking` into `phase1_participant_changes.csv` (via `analysis/run_analysis.py`, `build_phase1_changes_rows`). So `delta_C` is no longer mechanically forced to zero.
2. **Dispersion is symmetric around 0.5 pair marginals.** Directional preference changes can be weakly represented in this scalar.
3. **Single-scalar summary.** Outcome 2 is complementary to pairwise (Outcome 1), not a substitute.
4. **Pilot uncertainty remains high.** RI is valid, but effect detectability is limited.

## Reproducibility

```bash
Rscript reports/kendall-dispersion/analysis/run_kendall_dispersion.R
```

## Outputs

- [`analysis/output/kendall_dispersion.csv`](analysis/output/kendall_dispersion.csv)
- [`analysis/output/pair_dispersion_decomposition.csv`](analysis/output/pair_dispersion_decomposition.csv)
- [`analysis/output/hajek_components.csv`](analysis/output/hajek_components.csv)
- [`analysis/output/perm_null_summary.csv`](analysis/output/perm_null_summary.csv)
- [`analysis/output/bootstrap_summary.csv`](analysis/output/bootstrap_summary.csv)
- [`analysis/output/within_phase2_results.csv`](analysis/output/within_phase2_results.csv)
- [`analysis/output/power_n_required_rms.csv`](analysis/output/power_n_required_rms.csv)
- [`analysis/output/power_n_required_delta.csv`](analysis/output/power_n_required_delta.csv)
- [`analysis/output/power_curve.csv`](analysis/output/power_curve.csv)
- [`analysis/output/power_simulation_check.csv`](analysis/output/power_simulation_check.csv)
- [`figures/dispersion_decomposition.png`](figures/dispersion_decomposition.png)
- [`figures/delta_distribution.png`](figures/delta_distribution.png)
- [`figures/power_curves_rms.png`](figures/power_curves_rms.png)
- [`figures/power_curves_delta.png`](figures/power_curves_delta.png)
