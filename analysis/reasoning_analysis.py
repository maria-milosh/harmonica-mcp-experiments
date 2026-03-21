from __future__ import annotations

import json
import os
from collections import Counter, defaultdict
from itertools import combinations
from typing import Any
from urllib import request

from utils import AnalysisConfig, cosine_similarity, jaccard_similarity, safe_mean, write_json


THEME_KEYWORDS = {
    "urgency_basic_needs": [
        "urgent", "immediate", "right now", "asap",
        "hunger", "starving", "food insecurity", "basic need",
        "survival", "life-saving", "essential", "critical",
        "can't wait", "emergency", "dire", "necessity"
    ],

    "cost_effectiveness_impact": [
        "effective", "efficient", "cost-effective", "maximize",
        "most good", "greatest impact", "high impact",
        "per dollar", "low cost", "low-cost", "scalable", "evidence-based",
        "measurable", "return", "benefit", "bang for"
    ],

    "fairness_equity": [
        "fair", "unfair", "equity", "equality",
        "deserve", "deserving", "justice",
        "opportunity", "level playing field",
        "disadvantaged", "inequality", "redistribute",
        "systemic", "structural"
    ],

    "long_term_structural": [
        "long-term", "root cause", "systemic", "structural",
        "sustainable", "lasting", "future",
        "break the cycle", "cycle of", "prevention",
        "investment", "upstream", "address causes"
    ],

    "short_term_relief": [
        "immediate help", "direct aid", "relief",
        "short-term", "quick help", "right away",
        "temporary", "stopgap", "assist now", "help now",
        "meet needs", "basic support"
    ],

    "local_community_focus": [
        "local", "community", "neighborhood", "nearby",
        "city", "people around", "our community",
        "visible", "close to home", "directly see",
        "impact here", "local impact"
    ],

    "global_scale_impact": [
        "global", "world", "international",
        "many people", "large scale", "millions",
        "widespread", "across countries",
        "broad impact", "reach more people"
    ],

    "personal_connection_identity": [
        "personal", "i've seen", "i know", "experience",
        "worked with", "familiar", "relate",
        "close to me", "my community", "my experience",
        "i care about", "matters to me"
    ],

    "moral_duty_compassion": [
        "moral", "duty", "responsibility",
        "should help", "obligation", "imperative",
        "compassion", "care", "empathy",
        "right thing", "wrong", "ethical",
        "can't ignore", "help those in need"
    ],

    "tradeoffs_balancing": [
        "trade-off", "trade off", "balance", "weigh",
        "on the one hand", "on the other hand",
        "however", "although", "at the same time",
        "compromise", "consider both",
        "difficult choice", "no perfect option"
    ],

    "skepticism_uncertainty": [
        "not sure", "uncertain", "unclear",
        "might", "could", "depends", "don't know",
        "hard to say", "who knows",
        "skeptical", "doubt", "unknown",
        "lack of information", "lack information"
    ],

    "effectiveness_skepticism": [
        "ineffective", "waste", "doesn't work",
        "corruption", "misuse", "overhead", "futile",
        "not reaching", "limited impact", "useless",
        "question effectiveness", "concern"
    ],

    "deservingness_targeting": [
        "most in need", "worst off",
        "prioritize", "target", "focus on",
        "deserving", "vulnerable",
        "those who need it most",
        "high-risk", "marginalized"
    ],

    "visibility_salience": [
        "visible", "see the impact",
        "tangible", "concrete",
        "clear results", "noticeable",
        "immediate effect", "obvious",
        "easy to understand", "measurable"
    ]
}


def detect_themes(text: str | None) -> list[str]:
    content = (text or "").lower()
    hits = []
    for theme, keywords in THEME_KEYWORDS.items():
        if any(keyword in content for keyword in keywords):
            hits.append(theme)
    return hits


def theme_counts(rows: list[dict[str, Any]], key: str) -> list[dict[str, Any]]:
    counts = Counter()
    for row in rows:
        for theme in detect_themes(row.get(key)):
            counts[theme] += 1
    return [{"theme": theme, "count": count} for theme, count in counts.most_common()]


def embedding_request(texts: list[str], model: str) -> list[list[float]]:
    api_key = os.environ.get("OPENAI_API_KEY")
    if not api_key:
        raise RuntimeError("OPENAI_API_KEY is required for embedding analysis.")
    payload = {
        "model": model,
        "input": texts,
    }
    req = request.Request(
        "https://api.openai.com/v1/embeddings",
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    with request.urlopen(req, timeout=120) as response:
        data = response.read().decode("utf-8")
    parsed = json.loads(data)
    return [item["embedding"] for item in parsed["data"]]


def analyze_reasoning_shift(
    rows: list[dict[str, Any]],
    config: AnalysisConfig,
    output_dir: str,
    with_embeddings: bool = False,
) -> dict[str, Any]:
    participant_rows = []
    lexical_similarities = []
    changed_top_lexical = []
    stable_top_lexical = []

    for row in rows:
        initial = row.get("initial_reasoning") or ""
        final = row.get("final_reasoning") or ""
        lexical = jaccard_similarity(initial, final)
        lexical_similarities.append(lexical)
        changed_top = (row.get("initial_vote_ranking") or [None])[0] != (row.get("final_vote_ranking") or [None])[0]
        if changed_top:
            changed_top_lexical.append(lexical)
        else:
            stable_top_lexical.append(lexical)

        initial_themes = set(detect_themes(initial))
        final_themes = set(detect_themes(final))
        participant_rows.append(
            {
                "user_id": row["user_id"],
                "initial_top_choice": (row.get("initial_vote_ranking") or [None])[0],
                "final_top_choice": (row.get("final_vote_ranking") or [None])[0],
                "changed_top_choice": changed_top,
                "lexical_jaccard_similarity": round(lexical, 4),
                "initial_themes": ", ".join(sorted(initial_themes)),
                "final_themes": ", ".join(sorted(final_themes)),
                "themes_added": ", ".join(sorted(final_themes - initial_themes)),
                "themes_removed": ", ".join(sorted(initial_themes - final_themes)),
                "themes_retained": ", ".join(sorted(initial_themes & final_themes)),
            }
        )

    summary = {
        "avg_lexical_similarity": round(safe_mean(lexical_similarities) or 0, 4),
        "avg_lexical_similarity_changed_top": round(safe_mean(changed_top_lexical) or 0, 4),
        "avg_lexical_similarity_stable_top": round(safe_mean(stable_top_lexical) or 0, 4),
        "embedding_analysis_enabled": with_embeddings,
    }

    output = {
        "summary": summary,
        "initial_theme_counts": theme_counts(rows, "initial_reasoning"),
        "final_theme_counts": theme_counts(rows, "final_reasoning"),
        "participant_rows": participant_rows,
    }

    if with_embeddings:
        texts = []
        text_index = []
        for row in rows:
            texts.extend([row.get("initial_reasoning") or "", row.get("final_reasoning") or ""])
            text_index.append(row["user_id"])
        embeddings = embedding_request(texts, config.embedding_model)
        embedding_rows = []
        embedding_vectors = []
        pair_sims = []
        changed_pair_sims = []
        stable_pair_sims = []
        initial_vectors = []
        for idx, user_id in enumerate(text_index):
            initial_vec = embeddings[idx * 2]
            final_vec = embeddings[(idx * 2) + 1]
            initial_vectors.append(initial_vec)
            similarity = cosine_similarity(initial_vec, final_vec)
            row = next(item for item in rows if item["user_id"] == user_id)
            changed_top = (row.get("initial_vote_ranking") or [None])[0] != (row.get("final_vote_ranking") or [None])[0]
            if similarity is not None:
                pair_sims.append(similarity)
                if changed_top:
                    changed_pair_sims.append(similarity)
                else:
                    stable_pair_sims.append(similarity)
            embedding_rows.append(
                {
                    "user_id": user_id,
                    "changed_top_choice": changed_top,
                    "embedding_cosine_similarity": similarity,
                    "embedding_shift_intensity": (1 - similarity) if similarity is not None else None,
                }
            )
            embedding_vectors.append(
                {
                    "user_id": user_id,
                    "changed_top_choice": changed_top,
                    "initial_embedding": initial_vec,
                    "final_embedding": final_vec,
                }
            )

        random_initial_distances = []
        for left_vec, right_vec in combinations(initial_vectors, 2):
            similarity = cosine_similarity(left_vec, right_vec)
            if similarity is not None:
                random_initial_distances.append(1 - similarity)

        output["embedding_summary"] = {
            "avg_embedding_similarity": safe_mean(pair_sims),
            "avg_embedding_distance": safe_mean([(1 - item) for item in pair_sims]),
            "avg_embedding_similarity_changed_top": safe_mean(changed_pair_sims),
            "avg_embedding_similarity_stable_top": safe_mean(stable_pair_sims),
            "avg_random_initial_distance": safe_mean(random_initial_distances),
        }
        output["embedding_rows"] = embedding_rows
        output["embedding_vectors"] = embedding_vectors
        write_json(os.path.join(output_dir, "phase2_reasoning_embeddings.json"), output["embedding_summary"])
        write_json(os.path.join(output_dir, "phase2_reasoning_embedding_vectors.json"), embedding_vectors)

    return output
