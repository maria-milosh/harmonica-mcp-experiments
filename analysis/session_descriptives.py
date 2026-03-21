from __future__ import annotations

from collections import Counter
from typing import Any

from utils import entropy_from_counts, mean_ranks, median, safe_mean, transcript_metrics, word_count


def describe_phase1(
    extraction_rows: list[dict[str, Any]],
    transcript_rows: list[dict[str, Any]],
    options: list[str],
) -> tuple[dict[str, Any], list[dict[str, Any]], list[dict[str, Any]]]:
    rankings = [row["vote_ranking"] for row in extraction_rows if row.get("vote_ranking")]
    top_counts = Counter(ranking[0] for ranking in rankings if ranking)
    transcript_map = {row["participant_id"]: row for row in transcript_rows}

    participant_rows = []
    reasoning_lengths = []
    convo_lengths = []
    user_word_counts = []
    assistant_word_counts = []
    redirect_counts = []

    for row in extraction_rows:
        transcript = transcript_map.get(row["user_id"], {})
        metrics = transcript_metrics(transcript.get("messages", []))
        reasoning_length = word_count(row.get("reasoning"))
        reasoning_lengths.append(reasoning_length)
        convo_lengths.append(metrics["message_count"])
        user_word_counts.append(metrics["user_word_count"])
        assistant_word_counts.append(metrics["assistant_word_count"])
        redirect_counts.append(metrics["assistant_redirect_count"])
        participant_rows.append(
            {
                "user_id": row["user_id"],
                "participant_name": transcript.get("participant_name"),
                "top_choice": row["vote_ranking"][0] if row.get("vote_ranking") else None,
                "ranking": " > ".join(row["vote_ranking"]) if row.get("vote_ranking") else None,
                "reasoning_word_count": reasoning_length,
                "message_count": metrics["message_count"],
                "user_message_count": metrics["user_message_count"],
                "assistant_message_count": metrics["assistant_message_count"],
                "user_word_count": metrics["user_word_count"],
                "assistant_word_count": metrics["assistant_word_count"],
                "assistant_question_count": metrics["assistant_question_count"],
                "assistant_redirect_count": metrics["assistant_redirect_count"],
                "duration_minutes": metrics["duration_minutes"],
            }
        )

    option_rows = []
    avg_ranks = mean_ranks(rankings, options)
    for option in options:
        option_rows.append(
            {
                "option": option,
                "top_choice_votes": top_counts.get(option, 0),
                "top_choice_share": round(top_counts.get(option, 0) / len(rankings), 3) if rankings else 0,
                "mean_rank": round(avg_ranks.get(option) or 0, 3) if avg_ranks.get(option) is not None else None,
            }
        )

    summary = {
        "participant_count": len(extraction_rows),
        "complete_rankings": len(rankings),
        "unique_full_rankings": len(set(" > ".join(r) for r in rankings)),
        "top_choice_entropy": round(entropy_from_counts(dict(top_counts)), 3),
        "avg_reasoning_word_count": round(safe_mean(reasoning_lengths) or 0, 2),
        "median_reasoning_word_count": median(reasoning_lengths),
        "avg_message_count": round(safe_mean(convo_lengths) or 0, 2),
        "avg_user_word_count": round(safe_mean(user_word_counts) or 0, 2),
        "avg_assistant_word_count": round(safe_mean(assistant_word_counts) or 0, 2),
        "avg_assistant_redirect_count": round(safe_mean(redirect_counts) or 0, 2),
    }
    return summary, option_rows, participant_rows


def describe_phase2(
    extraction_rows: list[dict[str, Any]],
    transcript_rows: list[dict[str, Any]],
    options: list[str],
) -> tuple[dict[str, Any], list[dict[str, Any]], list[dict[str, Any]]]:
    initial_rankings = [row["initial_vote_ranking"] for row in extraction_rows if row.get("initial_vote_ranking")]
    final_rankings = [row["final_vote_ranking"] for row in extraction_rows if row.get("final_vote_ranking")]
    initial_top = Counter(ranking[0] for ranking in initial_rankings if ranking)
    final_top = Counter(ranking[0] for ranking in final_rankings if ranking)
    transcript_map = {row["participant_id"]: row for row in transcript_rows}

    participant_rows = []
    change_flags = []
    convo_lengths = []
    reasoning_lengths = []
    for row in extraction_rows:
        transcript = transcript_map.get(row["user_id"], {})
        metrics = transcript_metrics(transcript.get("messages", []))
        changed_top = row.get("initial_vote_ranking", [None])[0] != row.get("final_vote_ranking", [None])[0]
        change_flags.append(1 if changed_top else 0)
        convo_lengths.append(metrics["message_count"])
        reasoning_lengths.append(word_count(row.get("final_reasoning")) + word_count(row.get("initial_reasoning")))
        participant_rows.append(
            {
                "user_id": row["user_id"],
                "participant_name": transcript.get("participant_name"),
                "initial_top_choice": row["initial_vote_ranking"][0] if row.get("initial_vote_ranking") else None,
                "final_top_choice": row["final_vote_ranking"][0] if row.get("final_vote_ranking") else None,
                "changed_top_choice": changed_top,
                "initial_ranking": " > ".join(row["initial_vote_ranking"]) if row.get("initial_vote_ranking") else None,
                "final_ranking": " > ".join(row["final_vote_ranking"]) if row.get("final_vote_ranking") else None,
                "message_count": metrics["message_count"],
                "user_message_count": metrics["user_message_count"],
                "assistant_message_count": metrics["assistant_message_count"],
                "user_word_count": metrics["user_word_count"],
                "assistant_word_count": metrics["assistant_word_count"],
                "assistant_question_count": metrics["assistant_question_count"],
                "assistant_redirect_count": metrics["assistant_redirect_count"],
                "duration_minutes": metrics["duration_minutes"],
            }
        )

    option_rows = []
    initial_mean = mean_ranks(initial_rankings, options)
    final_mean = mean_ranks(final_rankings, options)
    for option in options:
        option_rows.append(
            {
                "option": option,
                "initial_top_votes": initial_top.get(option, 0),
                "final_top_votes": final_top.get(option, 0),
                "net_top_vote_change": final_top.get(option, 0) - initial_top.get(option, 0),
                "initial_mean_rank": round(initial_mean.get(option) or 0, 3) if initial_mean.get(option) is not None else None,
                "final_mean_rank": round(final_mean.get(option) or 0, 3) if final_mean.get(option) is not None else None,
            }
        )

    summary = {
        "participant_count": len(extraction_rows),
        "complete_initial_rankings": len(initial_rankings),
        "complete_final_rankings": len(final_rankings),
        "changed_top_choice_count": sum(change_flags),
        "changed_top_choice_share": round((sum(change_flags) / len(change_flags)) if change_flags else 0, 3),
        "initial_top_choice_entropy": round(entropy_from_counts(dict(initial_top)), 3),
        "final_top_choice_entropy": round(entropy_from_counts(dict(final_top)), 3),
        "avg_message_count": round(safe_mean(convo_lengths) or 0, 2),
        "avg_reasoning_word_count": round(safe_mean(reasoning_lengths) or 0, 2),
    }
    return summary, option_rows, participant_rows
