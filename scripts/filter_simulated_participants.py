#!/usr/bin/env python3
"""Remove simulated participants from a Harmonica transcript JSON file.

Simulated participants are identified by participant_name starting with "Sim ".
The input file is rewritten in place by default.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


def is_simulated(participant: dict[str, Any]) -> bool:
    name = participant.get("participant_name")
    return isinstance(name, str) and name.startswith("Sim ")


def filter_participants(payload: Any) -> tuple[Any, int, int]:
    if isinstance(payload, dict):
        if isinstance(payload.get("data"), list):
            participants = payload["data"]
            kept = [p for p in participants if not (isinstance(p, dict) and is_simulated(p))]
            payload["data"] = kept
            return payload, len(participants), len(kept)
        if isinstance(payload.get("participants"), list):
            participants = payload["participants"]
            kept = [p for p in participants if not (isinstance(p, dict) and is_simulated(p))]
            payload["participants"] = kept
            return payload, len(participants), len(kept)

    if isinstance(payload, list):
        participants = payload
        kept = [p for p in participants if not (isinstance(p, dict) and is_simulated(p))]
        return kept, len(participants), len(kept)

    raise ValueError("Unsupported JSON shape: expected object with 'data'/'participants' or a top-level list.")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description='Delete participants whose "participant_name" starts with "Sim ".'
    )
    parser.add_argument("input", type=Path, help="Path to transcript JSON file.")
    parser.add_argument(
        "--output",
        type=Path,
        help="Optional output path. If omitted, rewrites input file in place.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    in_path: Path = args.input
    out_path: Path = args.output if args.output else in_path

    with in_path.open("r", encoding="utf-8") as f:
        payload = json.load(f)

    filtered_payload, total_count, kept_count = filter_participants(payload)
    removed_count = total_count - kept_count

    with out_path.open("w", encoding="utf-8") as f:
        json.dump(filtered_payload, f, indent=2, ensure_ascii=False)
        f.write("\n")

    print(f"Input: {in_path}")
    print(f"Output: {out_path}")
    print(f"Participants: {total_count} total, {removed_count} removed, {kept_count} kept")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
