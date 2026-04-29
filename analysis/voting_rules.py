from __future__ import annotations

from collections import Counter, defaultdict
from typing import Any

from utils import first_choice_counts, option_label, ranking_positions


def plurality(rankings: list[list[str]]) -> dict[str, int]:
    return dict(first_choice_counts(rankings))


def borda(rankings: list[list[str]], options: list[str]) -> dict[str, int]:
    scores = {option: 0 for option in options}
    max_points = len(options) - 1
    for ranking in rankings:
        for idx, option in enumerate(ranking):
            scores[option] += max_points - idx
    return scores


def anti_plurality(rankings: list[list[str]], options: list[str]) -> dict[str, int]:
    scores = {option: 0 for option in options}
    for ranking in rankings:
        if not ranking:
            continue
        last = ranking[-1]
        for option in options:
            if option != last:
                scores[option] += 1
    return scores


def pairwise_matrix(rankings: list[list[str]], options: list[str]) -> dict[str, dict[str, int]]:
    matrix: dict[str, dict[str, int]] = {option: {other: 0 for other in options if other != option} for option in options}
    for ranking in rankings:
        positions = ranking_positions(ranking, options)
        for option in options:
            for other in options:
                if option == other:
                    continue
                if positions[option] < positions[other]:
                    matrix[option][other] += 1
    return matrix


def condorcet_winner(matrix: dict[str, dict[str, int]], rankings_count: int) -> str | None:
    for option, wins in matrix.items():
        if all(score > rankings_count / 2 for score in wins.values()):
            return option
    return None


def copeland_scores(matrix: dict[str, dict[str, int]], options: list[str], rankings_count: int) -> dict[str, float]:
    scores: dict[str, float] = {option: 0.0 for option in options}
    for option in options:
        for other in options:
            if option == other:
                continue
            forward = matrix[option][other]
            backward = matrix[other][option]
            if forward > backward:
                scores[option] += 1.0
            elif forward == backward == rankings_count / 2:
                scores[option] += 0.5
    return scores


def irv(rankings: list[list[str]], options: list[str]) -> dict[str, Any]:
    active = options[:]
    rounds = []
    while len(active) > 1:
        round_counts = Counter()
        for ranking in rankings:
            for option in ranking:
                if option in active:
                    round_counts[option] += 1
                    break
        total = sum(round_counts.values())
        if total == 0:
            break
        winner, top_votes = max(round_counts.items(), key=lambda item: (item[1], item[0]))
        rounds.append({"active": active[:], "counts": dict(round_counts)})
        if top_votes > total / 2:
            return {"winner": winner, "rounds": rounds}
        loser, _ = min(round_counts.items(), key=lambda item: (item[1], item[0]))
        active.remove(loser)
    final_winner = active[0] if active else None
    return {"winner": final_winner, "rounds": rounds}


def ranking_frequency(rankings: list[list[str]]) -> dict[str, int]:
    counts = Counter()
    for ranking in rankings:
        counts[" > ".join(ranking)] += 1
    return dict(counts)


def compare_rules(rankings: list[list[str]], options: list[str], option_labels: dict[str, str]) -> dict[str, Any]:
    pairwise = pairwise_matrix(rankings, options)
    rankings_count = len(rankings)
    plurality_scores = plurality(rankings)
    borda_scores = borda(rankings, options)
    anti_scores = anti_plurality(rankings, options)
    copeland = copeland_scores(pairwise, options, rankings_count)
    irv_result = irv(rankings, options)
    condorcet = condorcet_winner(pairwise, rankings_count)

    def winner_from_scores(scores: dict[str, float | int]) -> str | None:
        if not scores:
            return None
        return max(scores.items(), key=lambda item: (item[1], item[0]))[0]

    rules = [
        {
            "rule": "plurality",
            "winner": winner_from_scores(plurality_scores),
            "data_required": "top choice only",
            "valid_with_available_data": True,
        },
        {
            "rule": "borda",
            "winner": winner_from_scores(borda_scores),
            "data_required": "full ranking",
            "valid_with_available_data": True,
        },
        {
            "rule": "instant_runoff",
            "winner": irv_result["winner"],
            "data_required": "full ranking",
            "valid_with_available_data": True,
        },
        {
            "rule": "condorcet",
            "winner": condorcet,
            "data_required": "full ranking",
            "valid_with_available_data": True,
        },
        {
            "rule": "copeland",
            "winner": winner_from_scores(copeland),
            "data_required": "full ranking",
            "valid_with_available_data": True,
        },
        {
            "rule": "anti_plurality",
            "winner": winner_from_scores(anti_scores),
            "data_required": "full ranking",
            "valid_with_available_data": True,
        },
        {
            "rule": "approval_proxy_top2",
            "winner": None,
            "data_required": "approval ballots",
            "valid_with_available_data": False,
            "note": "Skipped because only rankings are available; a top-2 proxy would be derived rather than observed.",
        },
    ]

    score_table = []
    for option in options:
        score_table.append(
            {
                "option": option,
                "label": option_label(option, option_labels),
                "plurality_votes": plurality_scores.get(option, 0),
                "borda_score": borda_scores.get(option, 0),
                "copeland_score": copeland.get(option, 0),
                "anti_plurality_score": anti_scores.get(option, 0),
            }
        )

    pairwise_rows = []
    for option in options:
        row = {"option": option}
        row.update(pairwise[option])
        pairwise_rows.append(row)

    return {
        "rules": rules,
        "score_table": score_table,
        "pairwise_matrix": pairwise_rows,
        "pairwise_lookup": pairwise,
        "irv_rounds": irv_result["rounds"],
        "ranking_frequencies": ranking_frequency(rankings),
    }
