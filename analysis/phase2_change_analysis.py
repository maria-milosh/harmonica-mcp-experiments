from __future__ import annotations

from collections import Counter, defaultdict
from typing import Any

from utils import ranking_positions, safe_mean


def footrule_distance(initial: list[str], final: list[str], options: list[str]) -> int:
    initial_pos = ranking_positions(initial, options)
    final_pos = ranking_positions(final, options)
    return sum(abs(initial_pos[option] - final_pos[option]) for option in options)


def analyze_changes(rows: list[dict[str, Any]], options: list[str]) -> dict[str, Any]:
    transition_counter = Counter()
    per_option_movement: dict[str, list[int]] = defaultdict(list)
    participant_rows = []
    change_distances = []
    top_choice_changed = 0

    for row in rows:
        initial = row.get("initial_vote_ranking") or []
        final = row.get("final_vote_ranking") or []
        if not initial or not final:
            continue
        transition_counter[(initial[0], final[0])] += 1
        changed_top = initial[0] != final[0]
        if changed_top:
            top_choice_changed += 1

        initial_pos = ranking_positions(initial, options)
        final_pos = ranking_positions(final, options)
        distance = footrule_distance(initial, final, options)
        change_distances.append(distance)

        for option in options:
            per_option_movement[option].append(initial_pos[option] - final_pos[option])

        participant_rows.append(
            {
                "user_id": row["user_id"],
                "initial_top_choice": initial[0],
                "final_top_choice": final[0],
                "changed_top_choice": changed_top,
                "footrule_distance": distance,
                "initial_ranking": " > ".join(initial),
                "final_ranking": " > ".join(final),
            }
        )

    transition_rows = []
    for from_option in options:
        row = {"from_option": from_option}
        for to_option in options:
            row[to_option] = transition_counter.get((from_option, to_option), 0)
        transition_rows.append(row)

    option_movement_rows = []
    for option in options:
        movements = per_option_movement.get(option, [])
        option_movement_rows.append(
            {
                "option": option,
                "avg_rank_gain": round(safe_mean(movements) or 0, 3),
                "moved_up_count": sum(1 for item in movements if item > 0),
                "moved_down_count": sum(1 for item in movements if item < 0),
                "unchanged_count": sum(1 for item in movements if item == 0),
            }
        )

    summary = {
        "participants_with_complete_pre_post": len(participant_rows),
        "changed_top_choice_count": top_choice_changed,
        "changed_top_choice_share": round((top_choice_changed / len(participant_rows)) if participant_rows else 0, 3),
        "avg_footrule_distance": round(safe_mean(change_distances) or 0, 3),
        "max_footrule_distance": max(change_distances) if change_distances else 0,
    }

    return {
        "summary": summary,
        "transition_rows": transition_rows,
        "option_movement_rows": option_movement_rows,
        "participant_rows": participant_rows,
    }
