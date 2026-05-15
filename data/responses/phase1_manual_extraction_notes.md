# Phase 1 Manual Extraction Notes

Date noted: 2026-05-13

The analyst identified two Phase 1 extraction rows where the initial ranking was not parsed correctly from the raw transcript:

- `461bc6fd-3f01-486f-84d5-366f9fcf803f`
- `72db18c1-7eca-44df-a7a6-de036041946d`

In both cases, the extraction file incorrectly recorded a top-choice change. The raw conversation indicates that the participant's initial and final submitted rankings were the same.

Manual correction note:

- `461bc6...`: should be treated as no top-choice change. The participant clarified the initial ranking as `food_pantry > community_clinic > animal_rescue > urban_tree`, matching the final ranking.
- `72db...`: should be treated as no top-choice change. The participant clarified the initial ranking as `animal_rescue > community_clinic > food_pantry > urban_tree`, matching the final ranking.

No JSON files were modified as part of this note.
