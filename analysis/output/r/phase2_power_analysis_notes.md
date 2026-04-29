# Phase 2 Power Analysis Scaffold

This script scaffolds sample-size planning based on pilot outcomes.

Outcomes included:
- Individual level: cosine difference shift after cross-pollination
- Individual level: L1 shift in rankings
- Individual level: L1 shift in themes mentioned
- Group level (5-person groups from permutations): Condorcet efficiency

Placeholders to fill in `power_spec` before final N calculation:
- `min_effect` for each continuous outcome (paired dz)
- `pilot_p_before` and `pilot_p_after` for Condorcet efficiency
- `icc` for clustered group-level design

When placeholders are left as NA, required N outputs stay NA by design.
