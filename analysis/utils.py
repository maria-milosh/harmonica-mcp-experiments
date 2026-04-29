from __future__ import annotations

import csv
import json
import math
import os
from collections import Counter
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any


DEFAULT_OPTIONS = [
    "animal_rescue",
    "food_pantry",
    "urban_tree",
    "community_clinic",
]

DEFAULT_OPTION_LABELS = {
    "animal_rescue": "Community Animal Rescue Shelter",
    "food_pantry": "Community Food Pantry Network",
    "urban_tree": "Urban Tree Initiative",
    "community_clinic": "Community Health Clinic",
}


@dataclass
class AnalysisConfig:
    options: list[str]
    option_labels: dict[str, str]
    embedding_model: str


def parse_pilot_config(config_path: str | None) -> AnalysisConfig:
    if not config_path:
        return AnalysisConfig(DEFAULT_OPTIONS[:], dict(DEFAULT_OPTION_LABELS), "text-embedding-3-small")

    path = Path(config_path)
    if not path.exists():
        return AnalysisConfig(DEFAULT_OPTIONS[:], dict(DEFAULT_OPTION_LABELS), "text-embedding-3-small")

    options: list[str] = []
    labels: dict[str, str] = {}
    embedding_model = "text-embedding-3-small"

    in_topic = False
    in_options = False
    in_labels = False
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.rstrip()
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        indent = len(line) - len(line.lstrip(" "))

        if stripped == "topic:":
            in_topic = True
            in_options = False
            in_labels = False
            continue

        if indent == 0 and stripped != "topic:":
            in_topic = False
            in_options = False
            in_labels = False

        if in_topic and stripped == "options:":
            in_options = True
            in_labels = False
            continue

        if in_topic and stripped == "option_labels:":
            in_options = False
            in_labels = True
            continue

        if in_topic and in_options and stripped.startswith("- "):
            options.append(stripped[2:].strip().strip('"').strip("'"))
            continue

        if in_topic and in_labels and ":" in stripped:
            key, value = stripped.split(":", 1)
            labels[key.strip()] = value.strip().strip('"').strip("'")
            continue

        if stripped.startswith("embedding_model:"):
            embedding_model = stripped.split(":", 1)[1].strip().strip('"').strip("'")

    return AnalysisConfig(
        options=options or DEFAULT_OPTIONS[:],
        option_labels=labels or dict(DEFAULT_OPTION_LABELS),
        embedding_model=embedding_model,
    )


def load_json(path: str | Path) -> Any:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def ensure_dir(path: str | Path) -> Path:
    out = Path(path)
    out.mkdir(parents=True, exist_ok=True)
    return out


def write_json(path: str | Path, data: Any) -> None:
    Path(path).write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")


def write_csv(path: str | Path, rows: list[dict[str, Any]], fieldnames: list[str] | None = None) -> None:
    if not rows:
        Path(path).write_text("", encoding="utf-8")
        return
    if fieldnames:
        keys = fieldnames
    else:
        seen = []
        seen_set = set()
        for row in rows:
            for key in row.keys():
                if key not in seen_set:
                    seen.append(key)
                    seen_set.add(key)
        keys = seen
    with Path(path).open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=keys)
        writer.writeheader()
        writer.writerows(rows)


def parse_timestamp(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def word_count(text: str | None) -> int:
    if not text:
        return 0
    return len([part for part in str(text).split() if part.strip()])


def safe_mean(values: list[float | int]) -> float | None:
    if not values:
        return None
    return sum(values) / len(values)


def median(values: list[float | int]) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    mid = len(ordered) // 2
    if len(ordered) % 2:
        return float(ordered[mid])
    return (ordered[mid - 1] + ordered[mid]) / 2


def entropy_from_counts(counts: dict[str, int]) -> float:
    total = sum(counts.values())
    if total <= 0:
        return 0.0
    score = 0.0
    for count in counts.values():
        p = count / total
        if p > 0:
            score -= p * math.log(p, 2)
    return score


def ranking_positions(ranking: list[str], options: list[str]) -> dict[str, int]:
    positions = {option: len(options) for option in options}
    for idx, option in enumerate(ranking):
        positions[option] = idx + 1
    return positions


def assistant_question_count(messages: list[dict[str, Any]]) -> int:
    return sum(
        message.get("role") == "assistant" and str(message.get("content", "")).count("?")
        for message in messages
    )


def redirect_count(messages: list[dict[str, Any]]) -> int:
    patterns = [
        "need to work within",
        "for this study",
        "could you provide your complete ranking",
        "i need to ask you",
        "let me refocus",
    ]
    total = 0
    for message in messages:
        if message.get("role") != "assistant":
            continue
        content = str(message.get("content", "")).lower()
        if any(pattern in content for pattern in patterns):
            total += 1
    return total


def transcript_metrics(messages: list[dict[str, Any]]) -> dict[str, Any]:
    user_messages = [msg for msg in messages if msg.get("role") == "user"]
    assistant_messages = [msg for msg in messages if msg.get("role") == "assistant"]
    timestamps = [parse_timestamp(msg.get("created_at")) for msg in messages]
    timestamps = [item for item in timestamps if item is not None]
    duration_minutes = None
    if len(timestamps) >= 2:
        duration_minutes = (max(timestamps) - min(timestamps)).total_seconds() / 60.0

    return {
        "message_count": len(messages),
        "user_message_count": len(user_messages),
        "assistant_message_count": len(assistant_messages),
        "user_word_count": sum(word_count(msg.get("content")) for msg in user_messages),
        "assistant_word_count": sum(word_count(msg.get("content")) for msg in assistant_messages),
        "assistant_question_count": assistant_question_count(messages),
        "assistant_redirect_count": redirect_count(messages),
        "duration_minutes": duration_minutes,
    }


def first_choice_counts(rankings: list[list[str]]) -> Counter:
    counts: Counter = Counter()
    for ranking in rankings:
        if ranking:
            counts[ranking[0]] += 1
    return counts


def mean_ranks(rankings: list[list[str]], options: list[str]) -> dict[str, float | None]:
    per_option: dict[str, list[int]] = {option: [] for option in options}
    for ranking in rankings:
        positions = ranking_positions(ranking, options)
        for option, position in positions.items():
            per_option[option].append(position)
    return {option: safe_mean(values) for option, values in per_option.items()}


def markdown_table(rows: list[dict[str, Any]], columns: list[str]) -> str:
    if not rows:
        return "_No data._"
    header = "| " + " | ".join(columns) + " |"
    divider = "| " + " | ".join("---" for _ in columns) + " |"
    body = []
    for row in rows:
        body.append("| " + " | ".join(str(row.get(column, "")) for column in columns) + " |")
    return "\n".join([header, divider, *body])


def cosine_similarity(a: list[float], b: list[float]) -> float | None:
    if not a or not b or len(a) != len(b):
        return None
    dot = sum(x * y for x, y in zip(a, b))
    norm_a = math.sqrt(sum(x * x for x in a))
    norm_b = math.sqrt(sum(y * y for y in b))
    if norm_a == 0 or norm_b == 0:
        return None
    return dot / (norm_a * norm_b)


def jaccard_similarity(text_a: str, text_b: str) -> float:
    tokens_a = {token.lower().strip(".,!?;:()[]\"'") for token in text_a.split() if token.strip()}
    tokens_b = {token.lower().strip(".,!?;:()[]\"'") for token in text_b.split() if token.strip()}
    tokens_a.discard("")
    tokens_b.discard("")
    if not tokens_a and not tokens_b:
        return 1.0
    union = tokens_a | tokens_b
    if not union:
        return 0.0
    return len(tokens_a & tokens_b) / len(union)


def maybe_float(value: float | None, digits: int = 3) -> str:
    if value is None:
        return "n/a"
    return f"{value:.{digits}f}"


def option_label(option: str, option_labels: dict[str, str]) -> str:
    return option_labels.get(option, option)


def env_flag(name: str) -> bool:
    return os.environ.get(name, "").strip().lower() in {"1", "true", "yes", "on"}
