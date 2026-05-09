# Data handoff for Condorcet power / RI work

Scope: everything you need to reuse [analysis/r/run_condorcet_power_simulation_between_design.R](analysis/r/run_condorcet_power_simulation_between_design.R) and adjacent ranking-effect analyses on this pilot.

## 1. The experiment in one paragraph

A two-phase Harmonica deliberation pilot. Each participant has a private 1:1 chat with an AI facilitator and is asked to **rank four NYC charities** for a hypothetical $10 donation. The four options are fixed across both phases and across participants:

| code | label |
|---|---|
| `animal_rescue` | Community Animal Rescue Shelter |
| `food_pantry` | Community Food Pantry Network |
| `urban_tree` | Urban Tree Initiative |
| `community_clinic` | Community Health Clinic |

Topic, descriptions, and option codes live in [example_pilot.yaml](example_pilot.yaml); the participant-facing wording is [Participant task description.md](Participant%20task%20description.md).

**Phase 1** (treated as the *control* arm): a participant reads the descriptions and produces a single ranking + a short reasoning. **n = 12.**

**Phase 2** (treated as the *treatment* arm): a different cohort produces an *initial* ranking, is then exposed to anonymized rephrasings of the Phase 1 reasonings ("reflect on others"), and produces a *final* ranking + final reasoning. **n = 18.** For the between-design power script, only the Phase 2 **final** ranking is used.

Participant IDs are disjoint between phases — the script enforces this with a hard stop on overlap ([run_condorcet_power_simulation_between_design.R:214-221](analysis/r/run_condorcet_power_simulation_between_design.R#L214-L221)). There is **no within-subject control + treatment**; the comparison is *cross-cohort*. Treatment effects estimated this way conflate the deliberation effect with any cohort difference between the two participant pools — flag this when reporting.

Treatment is not randomized at the individual level in the pilot data. The randomization-inference framing in [notes/plan.md](notes/plan.md) and [notes/analysis-plan.md](notes/analysis-plan.md) treats arm assignment *as if* it were the randomization device for power-simulation purposes.

## 2. The two files the Condorcet power script actually reads

```r
control_input_path   <- "analysis/output/phase1_participant_stats.csv"   # control = Phase 1
treatment_input_path <- "analysis/output/phase2_participant_changes.csv" # treated = Phase 2 final
control_ranking_col  <- "ranking"
treated_ranking_col  <- "final_ranking"
```

Both ranking columns are **strict, complete orderings of all four options**, encoded as a single string with `>` separators and surrounding whitespace, e.g.:

```
urban_tree > animal_rescue > community_clinic > food_pantry
```

The script splits on `\s*>\s*` and then asserts (`check_rankings`) that every row contains all four option codes with no duplicates. Whitespace around `>` is tolerated but the option codes themselves must match the four codes above exactly (they're auto-discovered from the union of pilot rankings, so they have to be consistent).

The script bootstraps from these as empirical DGPs: for each candidate $n$ in the `n_grid`, it draws $n$ rankings with replacement from the control pool and $n$ from the treated pool, then runs randomization inference for the Condorcet-share statistic with $b = 999$ permutations. Group size for Condorcet detection is $k = 5$ (`group_size`). At $n \in [60, 300]$, $\binom{n}{5}$ exceeds the `max_exhaustive_groups = 2{,}000{,}000` threshold immediately, so `auto` mode falls through to MC sampling with `mc_groups_per_arm = 50{,}000`.

### `analysis/output/phase1_participant_stats.csv` (n = 12)

Columns:

| column | type | notes |
|---|---|---|
| `user_id` | string | hex or UUID; **primary key**; disjoint from Phase 2 |
| `participant_name` | string | human-readable handle (e.g. "Alabaster Phoenix"); not load-bearing |
| `top_choice` | option code | first element of `ranking` |
| `ranking` | `"a > b > c > d"` | **what the script reads** |
| `reasoning_word_count` | int | word count of LLM-extracted reasoning |
| `message_count`, `user_message_count`, `assistant_message_count` | int | full chat length |
| `user_word_count`, `assistant_word_count` | int | |
| `assistant_question_count`, `assistant_redirect_count` | int | facilitator behavior |
| `duration_minutes` | float | wall-clock chat duration |

### `analysis/output/phase2_participant_changes.csv` (n = 18)

Columns:

| column | type | notes |
|---|---|---|
| `user_id` | string | disjoint from Phase 1 |
| `initial_top_choice`, `final_top_choice` | option code | |
| `changed_top_choice` | bool (`True`/`False`) | string-cased — `read_csv` will parse to logical |
| `footrule_distance` | int | Spearman footrule between initial and final rankings (sum of \|rank diffs\|, max 8 for $K = 4$) |
| `initial_ranking`, `final_ranking` | `"a > b > c > d"` | the script reads `final_ranking` |

Note: `footrule_distance` here is reported as integer values 0/2/4 — that's the actual footrule metric on permutations of 4 items (always even, max 8).

## 3. Other pilot artifacts you may want

All under [analysis/output/](analysis/output/). Fully derivable from the two transcripts plus extractions, but already computed.

### Per-participant, richer than what the power script uses

- [phase2_participant_stats.csv](analysis/output/phase2_participant_stats.csv) — Phase 2 participants with **both** initial and final rankings *plus* full session-behavior columns (message counts, durations). The Condorcet script's slim file (`phase2_participant_changes.csv`) is a projection of this; if you need session behavior at the individual level for the treated arm, use this one.
- [phase2_reasoning_shift.csv](analysis/output/phase2_reasoning_shift.csv) — per-user lexical Jaccard similarity between initial and final reasoning, plus theme add/drop/retain lists (themes are LLM-coded categorical tags like `urgency_basic_needs`, `local_community_focus`).
- [phase2_reasoning_embedding_shift.csv](analysis/output/phase2_reasoning_embedding_shift.csv) — per-user cosine similarity and shift intensity between initial and final reasoning embeddings (`text-embedding-3-small`).
- [phase1_reasoning_embedding_vectors.json](analysis/output/phase1_reasoning_embedding_vectors.json), [phase2_reasoning_embedding_vectors.json](analysis/output/phase2_reasoning_embedding_vectors.json) — raw embedding vectors per user (1536-dim floats); allows local recomputation of distances without re-calling OpenAI.

### Aggregates (sanity checks for the Condorcet sim's empirical DGPs)

- [phase1_summary.json](analysis/output/phase1_summary.json), [phase2_summary.json](analysis/output/phase2_summary.json) — counts, top-choice entropy.
- [phase1_option_stats.csv](analysis/output/phase1_option_stats.csv), [phase2_option_stats.csv](analysis/output/phase2_option_stats.csv) — top-choice votes and mean rank per option.
- [phase1_voting_rules.csv](analysis/output/phase1_voting_rules.csv), [phase2_initial_voting_rules.csv](analysis/output/phase2_initial_voting_rules.csv), [phase2_final_voting_rules.csv](analysis/output/phase2_final_voting_rules.csv) — winner under plurality / Borda / IRV / Condorcet / Copeland / anti-plurality. Note the Phase 1 Condorcet winner is empty (no Condorcet winner in the pilot rankings); Phase 2 final has `food_pantry` as Condorcet winner. So the empirical pilot already shows the kind of effect the Condorcet-share statistic is targeting.
- [phase2_transition_matrix.csv](analysis/output/phase2_transition_matrix.csv) — 4×4 top-choice transitions inside Phase 2.
- [phase2_option_movement.csv](analysis/output/phase2_option_movement.csv) — per-option average rank gain / moved-up / moved-down counts inside Phase 2.

### Already-run R companions (precedents for further work)

[analysis/output/r/](analysis/output/r/) has output from sibling scripts in [analysis/r/](analysis/r/):

- `run_condorcet_randomization_inference_{between,within}_design.R` — observed-data RI test (the actual point estimate + p-value, not a power sim).
- `run_condorcet_power_simulation_between_design_fast.R` — vectorized variant of the script you've been handed; outputs in `*_fast.csv`.
- `run_phase2_resampling_social_choice.R` — synthetic-group resampling under multiple voting rules (Outcome 3 in [analysis-plan.md](notes/analysis-plan.md)).
- `run_phase2_regressions.R` — individual-level regressions of change outcomes on session-behavior and reasoning-shift covariates.
- `run_phase2_theme_shift.R` — Wilcoxon / L1 analysis of theme prevalence shifts.

The corresponding output files live next to the script outputs in `analysis/output/r/` and are reasonable starting points if you need to wire the pilot's behavioral covariates into a richer analysis.

## 4. Upstream layers (only read if regenerating the CSVs)

You almost certainly don't need these for the power script, but the chain exists:

1. **Raw transcripts** — `data/responses/phase{1,2}_hst_<session_id>.json`. Per-participant chat messages with timestamps. Same data is mirrored in [data/archive/20260223_230510_pilot_001/](data/archive/20260223_230510_pilot_001/) under different session IDs (an earlier cycle).
2. **LLM extractions** — `data/responses/phase{1,2}_hst_<session_id>_extractions.json`. Phase 1 rows have `vote_ranking` (array of option codes, most→least preferred) + `reasoning` (one-paragraph LLM summary). Phase 2 rows have `initial_vote_ranking`, `initial_reasoning`, `final_vote_ranking`, `final_reasoning`. Generated by [scripts/](scripts/) / `npm run reasoning:extract` per [README.md](README.md).
3. **Aggregated CSVs in [analysis/output/](analysis/output/)** — produced by [analysis/run_analysis.py](analysis/run_analysis.py) from steps 1+2. This is the layer the R scripts consume.

If extractions get re-run, the `>`-joined ranking strings in `analysis/output/*.csv` are written by joining `vote_ranking` arrays with `" > "` — same convention the R script's parser expects.

## 5. Constraints and gotchas worth flagging

- **K = 4 only.** The `analysis-plan.md` discusses $K \in \{4, 5, 6\}$; this pilot only realizes $K = 4$. The Condorcet-share group size $k = 5$ in the script is the synthetic-group size, not the option count.
- **Disjoint cohorts, not within-subject.** Phase 2 *does* have within-subject pre/post (`initial_ranking` vs `final_ranking`), but the between-design script throws away the Phase 2 initials and pairs Phase 1 vs Phase 2-final. The within-design RI script (`run_condorcet_randomization_inference_within_design.R`) is the one that uses the matched pre/post structure.
- **Tiny pilot.** Pool sizes (12 / 18) are pilot-grade; bootstrap-from-pilot variance is what the power sim is exploring across `n_grid`.
- **Footrule values are even.** For $K = 4$ permutations the Spearman footrule is always even, so `footrule_distance ∈ {0, 2, 4, 6, 8}` (only 0/2/4 observed).
- **Top-choice entropy is similar across phases** (1.855 vs 1.891 → 1.905 init→final). The substantive shift is *which* option wins under which rule, not in the marginal top-choice distribution.
- **Date stamps are 2026-04-14 (extraction) and 2026-03-14 (chats).** Don't be confused if you see future-looking dates — that is the actual data.
- **`ranking_null_if_ambiguous: true`** in [example_pilot.yaml](example_pilot.yaml) means rows where the LLM couldn't infer a clean full ranking would be null. The CSVs the R script reads are already filtered (`filter(!is.na(...), ranking_string != "")`), and in this pilot every participant produced a complete ranking — `complete_rankings == participant_count` in both summary JSONs. If a future cycle has missing rankings, the filter step silently drops them.
