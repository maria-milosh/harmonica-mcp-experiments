# Phase 2 Regression Notes

These models are descriptive and should be interpreted cautiously.

- Sample size: 17 participants
- Top-choice changers: 3
- Standardized predictors make coefficient magnitudes more comparable across models.
- The linear probability model is used for top-choice change because the event count is very low.
- The OLS models for footrule distance and clinic rank gain are exploratory, not confirmatory.

## Models

1. Top-choice change (LPM): whether the participant changed their top-ranked option.
2. Ranking distance (OLS): how much the full ranking changed, measured by footrule distance.
3. Clinic rank gain (OLS): how much `community_clinic` moved up in the participant's ranking.

## Included predictors

- Embedding shift intensity
- Lexical similarity
- User word count
- Conversation duration
- Initial top choice not clinic indicator (clinic gain model only)
