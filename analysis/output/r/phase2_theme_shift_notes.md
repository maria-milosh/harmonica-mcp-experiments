# Phase 2 Theme Shift Pipeline

## Steps implemented
1. Reasoning -> normalized theme vectors (Option A: divide by total theme matches).
2. Within-person change per theme (delta and abs delta).
3. Aggregate change across participants (means and presence shares).
4. Wilcoxon signed-rank tests by theme (paired initial vs final weights).
5. Global reasoning-shift metric: participant-level L1 distance.
6. Global Wilcoxon test: is L1 distance greater than 0?
7. Visual outputs for theme-level and participant-level shifts.

## Key global metrics
- Participants: 17
- Themes: 14
- Mean L1 distance: 1.3431
- Median L1 distance: 1.3333
- Wilcoxon(L1 > 0) p-value: 0.0002115
