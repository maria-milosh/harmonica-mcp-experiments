# Analysis Scripts

This folder contains Python scripts for analyzing the two-phase Harmonica study outputs.

## What it produces

- Session-level descriptives for Phase 1 and Phase 2
- Voting-rule comparisons using ranked-ballot methods only
- Phase 2 pre/post change analysis
- Reasoning-shift analysis using lexical overlap and optional embeddings
- CSV tables, JSON summaries, Markdown report, and SVG charts
- A static HTML dashboard at `analysis/output/dashboard.html`

## Run

```bash
python3 analysis/run_analysis.py
```

Optional embedding analysis:

```bash
OPENAI_API_KEY=... python3 analysis/run_analysis.py --with-embeddings
```

If you have already run embeddings once, the dashboard will reuse
`analysis/output/phase2_reasoning_embedding_shift.csv` on later runs.
That embedding run also saves raw vectors to
`analysis/output/phase2_reasoning_embedding_vectors.json`, which allows
local recomputation of random-pair initial-reasoning distances without
calling the API again.

## Default inputs

- `data/responses/phase1_hst_dbf516d28d66.json`
- `data/responses/phase1_hst_dbf516d28d66_extractions.json`
- `data/responses/phase2_hst_f3f99c5cc524.json`
- `data/responses/phase2_hst_f3f99c5cc524_extractions.json`

Outputs are written to `analysis/output/`.
