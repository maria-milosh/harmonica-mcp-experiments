from __future__ import annotations

import argparse
import csv
import sys
from collections import Counter
from itertools import combinations
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from phase2_change_analysis import analyze_changes
from reasoning_analysis import analyze_phase1_reasoning_embeddings, analyze_reasoning_shift
from session_descriptives import describe_phase1, describe_phase2
from utils import (
    cosine_similarity,
    ensure_dir,
    load_json,
    markdown_table,
    maybe_float,
    option_label,
    parse_pilot_config,
    write_csv,
    write_json,
)
from visualize import (
    save_bar_chart,
    save_dumbbell_chart,
    save_grouped_bar_chart,
    save_heatmap,
    save_lollipop_comparison_chart,
)
from voting_rules import compare_rules


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Analyze Harmonica phase outputs.")
    parser.add_argument("--phase1-json", default="data/responses/phase1_hst_dbf516d28d66.json")
    parser.add_argument("--phase1-extractions", default="data/responses/phase1_hst_dbf516d28d66_extractions.json")
    parser.add_argument("--phase2-json", default="data/responses/phase2_hst_f3f99c5cc524.json")
    parser.add_argument("--phase2-extractions", default="data/responses/phase2_hst_f3f99c5cc524_extractions.json")
    parser.add_argument("--config", default="example_pilot.yaml")
    parser.add_argument("--output-dir", default="analysis/output")
    parser.add_argument("--with-embeddings", action="store_true")
    return parser.parse_args()


def load_transcript_rows(path: str) -> list[dict[str, Any]]:
    payload = load_json(path)
    return payload.get("data", []) if isinstance(payload, dict) else payload


def load_extraction_rows(path: str) -> list[dict[str, Any]]:
    payload = load_json(path)
    return payload if isinstance(payload, list) else payload.get("data", [])


def load_csv_rows(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    with path.open("r", encoding="utf-8", newline="") as handle:
        return list(csv.DictReader(handle))


def avg_random_initial_distance_from_vectors(vector_rows: list[dict[str, Any]]) -> float | None:
    initial_vectors = [
        row.get("initial_embedding")
        for row in vector_rows
        if isinstance(row.get("initial_embedding"), list) and row.get("initial_embedding")
    ]
    distances = []
    for left_vec, right_vec in combinations(initial_vectors, 2):
        similarity = cosine_similarity(left_vec, right_vec)
        if similarity is not None:
            distances.append(1 - similarity)
    if not distances:
        return None
    return sum(distances) / len(distances)


def write_report(
    output_dir: Path,
    config,
    phase1_summary: dict[str, Any],
    phase1_options: list[dict[str, Any]],
    phase2_summary: dict[str, Any],
    phase2_options: list[dict[str, Any]],
    phase1_rules: dict[str, Any],
    phase2_initial_rules: dict[str, Any],
    phase2_final_rules: dict[str, Any],
    phase2_changes: dict[str, Any],
    reasoning_shift: dict[str, Any],
) -> None:
    def winner_line(rules: dict[str, Any], rule_name: str) -> str:
        row = next(item for item in rules["rules"] if item["rule"] == rule_name)
        winner = row.get("winner")
        return option_label(winner, config.option_labels) if winner else "none"

    phase1_option_rows = []
    for row in phase1_options:
        phase1_option_rows.append(
            {
                "option": option_label(row["option"], config.option_labels),
                "top votes": row["top_choice_votes"],
                "share": row["top_choice_share"],
                "mean rank": row["mean_rank"],
            }
        )

    phase2_option_rows = []
    for row in phase2_options:
        phase2_option_rows.append(
            {
                "option": option_label(row["option"], config.option_labels),
                "initial top votes": row["initial_top_votes"],
                "final top votes": row["final_top_votes"],
                "net change": row["net_top_vote_change"],
                "initial mean rank": row["initial_mean_rank"],
                "final mean rank": row["final_mean_rank"],
            }
        )

    report = f"""# Harmonica Analysis Report

## Phase 1 Overview

Phase 1 includes **{phase1_summary['participant_count']}** participants with complete rankings. Top-choice diversity is **{phase1_summary['top_choice_entropy']}** bits across **{phase1_summary['unique_full_rankings']}** unique full rankings.

Plurality winner: **{winner_line(phase1_rules, 'plurality')}**  
Borda winner: **{winner_line(phase1_rules, 'borda')}**  
IRV winner: **{winner_line(phase1_rules, 'instant_runoff')}**

{markdown_table(phase1_option_rows, ['option', 'top votes', 'share', 'mean rank'])}

## Phase 2 Overview

Phase 2 includes **{phase2_summary['participant_count']}** participants. A total of **{phase2_summary['changed_top_choice_count']}** participants changed their top choice, which is **{phase2_summary['changed_top_choice_share']}** of the cohort.

Initial plurality winner: **{winner_line(phase2_initial_rules, 'plurality')}**  
Final plurality winner: **{winner_line(phase2_final_rules, 'plurality')}**  
Final Borda winner: **{winner_line(phase2_final_rules, 'borda')}**

{markdown_table(phase2_option_rows, ['option', 'initial top votes', 'final top votes', 'net change', 'initial mean rank', 'final mean rank'])}

## Change Inside Phase 2

Average ranking footrule distance: **{phase2_changes['summary']['avg_footrule_distance']}**  
Maximum observed footrule distance: **{phase2_changes['summary']['max_footrule_distance']}**

Average lexical similarity between initial and final reasonings: **{reasoning_shift['summary']['avg_lexical_similarity']}**  
Average lexical similarity for top-choice changers: **{reasoning_shift['summary']['avg_lexical_similarity_changed_top']}**  
Average lexical similarity for stable top choices: **{reasoning_shift['summary']['avg_lexical_similarity_stable_top']}**

## Voting Rule Notes

Only voting rules that are valid with ranked-ballot data are treated as primary results here. Approval-style analysis is intentionally excluded because only rankings and top choices are observed, not direct approval ballots.
"""
    (output_dir / "report.md").write_text(report, encoding="utf-8")


def render_html_table(rows: list[dict[str, Any]], columns: list[str]) -> str:
    if not rows:
        return "<p>No data.</p>"
    head = "".join(f"<th>{column}</th>" for column in columns)
    body_rows = []
    for row in rows:
        body_rows.append("<tr>" + "".join(f"<td>{row.get(column, '')}</td>" for column in columns) + "</tr>")
    return "<table><thead><tr>" + head + "</tr></thead><tbody>" + "".join(body_rows) + "</tbody></table>"


def write_dashboard(
    output_dir: Path,
    config,
    phase1_summary: dict[str, Any],
    phase2_summary: dict[str, Any],
    phase1_rules: dict[str, Any],
    phase2_initial_rules: dict[str, Any],
    phase2_final_rules: dict[str, Any],
    phase2_changes: dict[str, Any],
    reasoning_shift: dict[str, Any],
) -> None:
    def count_list_items(value: str) -> int:
        if not value:
            return 0
        return len([item for item in value.split(", ") if item])

    def parse_theme_list(value: str) -> list[str]:
        if not value:
            return []
        return [item for item in value.split(", ") if item]

    def format_theme_list(value: str) -> str:
        if not value:
            return "None"
        parts = []
        for item in value.split(", "):
            label = item.replace("_", " ").strip()
            parts.append(label.capitalize())
        return ", ".join(parts)

    def share_text(count: int, total: int) -> str:
        return f"{count}/{total} ({round((count / total) * 100) if total else 0}%)"

    def format_change_row(row: dict[str, Any]) -> dict[str, Any]:
        initial_themes_raw = row.get("initial_themes", "")
        final_themes_raw = row.get("final_themes", "")
        if not initial_themes_raw and not final_themes_raw:
            initial_parts = [item for item in (row.get("themes_removed", "") + ", " + row.get("themes_retained", "")).split(", ") if item]
            final_parts = [item for item in (row.get("themes_added", "") + ", " + row.get("themes_retained", "")).split(", ") if item]
            initial_themes_raw = ", ".join(sorted(set(initial_parts)))
            final_themes_raw = ", ".join(sorted(set(final_parts)))
        initial_theme_set = set(parse_theme_list(initial_themes_raw))
        final_theme_set = set(parse_theme_list(final_themes_raw))
        theme_delta = len(initial_theme_set.symmetric_difference(final_theme_set))
        lexical = row.get("lexical_jaccard_similarity", 0)
        if lexical < 0.10:
            wording_label = "Large rewrite"
        elif lexical < 0.20:
            wording_label = "Noticeable rewrite"
        else:
            wording_label = "Some wording reused"
        return {
            "participant": row["user_id"],
            "top choice before": option_label(row["initial_top_choice"], config.option_labels),
            "top choice after": option_label(row["final_top_choice"], config.option_labels),
            "wording shift": wording_label,
            "themes in initial": format_theme_list(initial_themes_raw),
            "themes in final": format_theme_list(final_themes_raw),
            "theme moves": theme_delta,
        }

    def winner_map(rule_block: dict[str, Any]) -> dict[str, str]:
        mapping = {}
        for row in rule_block["rules"]:
            winner = row.get("winner")
            mapping[row["rule"]] = option_label(winner, config.option_labels) if winner else "n/a"
        return mapping

    phase1_winners = winner_map(phase1_rules)
    phase2_initial_winners = winner_map(phase2_initial_rules)
    phase2_final_winners = winner_map(phase2_final_rules)

    rule_rows = []
    for rule in ["plurality", "borda", "instant_runoff", "condorcet", "copeland", "anti_plurality"]:
        rule_rows.append(
            {
                "rule": rule,
                "phase1": phase1_winners.get(rule, "n/a"),
                "phase2_initial": phase2_initial_winners.get(rule, "n/a"),
                "phase2_final": phase2_final_winners.get(rule, "n/a"),
            }
        )

    changer_rows = [row for row in reasoning_shift["participant_rows"] if row["changed_top_choice"]]
    stable_rows = [row for row in reasoning_shift["participant_rows"] if not row["changed_top_choice"]]
    changer_rows = sorted(changer_rows, key=lambda item: item["lexical_jaccard_similarity"])
    stable_rows = sorted(stable_rows, key=lambda item: item["lexical_jaccard_similarity"])
    participant_count = phase2_changes["summary"]["participants_with_complete_pre_post"]
    top_choice_changed_count = phase2_changes["summary"]["changed_top_choice_count"]

    any_rank_change_count = sum(1 for row in phase2_changes["participant_rows"] if row["footrule_distance"] > 0)
    no_rank_change_count = participant_count - any_rank_change_count
    minor_rank_change_count = sum(1 for row in phase2_changes["participant_rows"] if row["footrule_distance"] == 2)
    major_rank_change_count = sum(1 for row in phase2_changes["participant_rows"] if row["footrule_distance"] >= 4)

    theme_change_count = sum(
        1
        for row in reasoning_shift["participant_rows"]
        if count_list_items(row.get("themes_added", "")) + count_list_items(row.get("themes_removed", "")) > 0
    )
    unchanged_theme_set_count = 0
    one_theme_change_count = 0
    two_plus_theme_change_count = 0
    for row in reasoning_shift["participant_rows"]:
        initial_themes_raw = row.get("initial_themes", "")
        final_themes_raw = row.get("final_themes", "")
        if not initial_themes_raw and not final_themes_raw:
            initial_parts = [item for item in (row.get("themes_removed", "") + ", " + row.get("themes_retained", "")).split(", ") if item]
            final_parts = [item for item in (row.get("themes_added", "") + ", " + row.get("themes_retained", "")).split(", ") if item]
            initial_themes_raw = ", ".join(sorted(set(initial_parts)))
            final_themes_raw = ", ".join(sorted(set(final_parts)))
        initial_theme_set = set(parse_theme_list(initial_themes_raw))
        final_theme_set = set(parse_theme_list(final_themes_raw))
        move_count = len(initial_theme_set.symmetric_difference(final_theme_set))
        if move_count == 0:
            unchanged_theme_set_count += 1
        elif move_count == 1:
            one_theme_change_count += 1
        else:
            two_plus_theme_change_count += 1

    final_top_counts = Counter(row["final_top_choice"] for row in phase2_changes["participant_rows"])
    initial_top_counts = Counter(row["initial_top_choice"] for row in phase2_changes["participant_rows"])
    movement_rows = []
    for row in phase2_changes["option_movement_rows"]:
        option = row["option"]
        movement_rows.append(
            {
                "option": option_label(option, config.option_labels),
                "initial top votes": initial_top_counts.get(option, 0),
                "final top votes": final_top_counts.get(option, 0),
                "net top-vote change": final_top_counts.get(option, 0) - initial_top_counts.get(option, 0),
                "participants moving it up": row["moved_up_count"],
            }
        )

    change_stages = [
        {
            "layer": "Top-choice switch",
            "count": share_text(top_choice_changed_count, participant_count),
            "what it means": "Participants changed which option they ranked first.",
        },
        {
            "layer": "Any ranking edit",
            "count": share_text(any_rank_change_count, participant_count),
            "what it means": "Participants changed at least one position somewhere in the full ranking.",
        },
        {
            "layer": "Theme rewrite",
            "count": share_text(theme_change_count, participant_count),
            "what it means": "Participants added or dropped at least one substantive theme in their rationale.",
        },
    ]

    embedding_summary = reasoning_shift.get("embedding_summary", {})
    embedding_block = ""
    reasoning_movement_copy = (
        "The lollipop chart shows each participant's own embedding distance after cross-pollination."
    )
    if embedding_summary:
        if embedding_summary.get("avg_random_initial_distance") is not None:
            reasoning_movement_copy = (
                "This technical view is now supporting evidence rather than the headline. "
                "The lollipop chart shows each participant's own embedding distance after cross-pollination, "
                "compared against the average distance between two different participants' initial reasonings."
            )
        # embedding_block = f"""
        # <div class="card">
        #   <div class="label">Avg semantic overlap</div>
        #   <div class="value">{maybe_float(embedding_summary.get('avg_embedding_similarity'), 3)}</div>
        # </div>
        # <div class="card">
        #   <div class="label">Avg semantic shift</div>
        #   <div class="value">{maybe_float(embedding_summary.get('avg_embedding_distance'), 3)}</div>
        # </div>
        # <div class="card">
        #   <div class="label">Random initial distance</div>
        #   <div class="value">{maybe_float(embedding_summary.get('avg_random_initial_distance'), 3)}</div>
        # </div>
        # """

    html = f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0"/>
  <title>Harmonica Analysis Dashboard</title>
  <link href="https://fonts.googleapis.com/css2?family=DM+Serif+Display:ital@0;1&family=DM+Mono:wght@400;500&family=DM+Sans:wght@300;400;500&display=swap" rel="stylesheet"/>
  <style>
    *, *::before, *::after {{ box-sizing: border-box; margin: 0; padding: 0; }}

    :root {{
      --bg: #0e0f0c;
      --surface: #161712;
      --border: #2a2b26;
      --accent: #c8f060;
      --accent2: #f0d060;
      --muted: #5a5c52;
      --text: #e8e9e2;
      --text-dim: #a3a49c;
    }}

    body {{
      background: var(--bg);
      color: var(--text);
      font-family: 'DM Sans', sans-serif;
      font-weight: 300;
      min-height: 100vh;
      overflow-x: hidden;
    }}

    body::before {{
      content: '';
      position: fixed;
      inset: 0;
      background:
        linear-gradient(var(--border) 1px, transparent 1px),
        linear-gradient(90deg, var(--border) 1px, transparent 1px);
      background-size: 60px 60px;
      opacity: 0.35;
      pointer-events: none;
      z-index: 0;
    }}

    .wrap {{
      position: relative;
      z-index: 1;
      max-width: 980px;
      margin: 0 auto;
      padding: 56px 28px 96px;
    }}

    header {{
      display: flex;
      align-items: baseline;
      justify-content: space-between;
      border-bottom: 1px solid var(--border);
      padding-bottom: 24px;
      margin-bottom: 28px;
    }}

    .logo {{
      font-family: 'DM Mono', monospace;
      font-size: 12px;
      color: var(--muted);
      letter-spacing: 0.12em;
      text-transform: uppercase;
    }}

    .session-tag {{
      font-family: 'DM Mono', monospace;
      font-size: 11px;
      color: var(--accent);
      background: rgba(200,240,96,0.08);
      border: 1px solid rgba(200,240,96,0.2);
      padding: 4px 10px;
      letter-spacing: 0.08em;
    }}

    .quick-nav {{
      display: flex;
      flex-wrap: wrap;
      gap: 10px;
      margin-bottom: 34px;
      position: sticky;
      top: 12px;
      z-index: 3;
      padding: 10px;
      background: rgba(14,15,12,0.92);
      border: 1px solid var(--border);
      backdrop-filter: blur(4px);
    }}

    .quick-nav a {{
      font-family: 'DM Mono', monospace;
      font-size: 11px;
      color: var(--text-dim);
      text-decoration: none;
      padding: 6px 10px;
      border: 1px solid var(--border);
      background: rgba(255,255,255,0.01);
      letter-spacing: 0.06em;
      text-transform: uppercase;
    }}

    .quick-nav a:hover {{
      color: var(--accent);
      border-color: rgba(200,240,96,0.45);
    }}

    section {{
      margin-bottom: 56px;
    }}

    .eyebrow, .section-label {{
      font-family: 'DM Mono', monospace;
      font-size: 10px;
      color: var(--muted);
      letter-spacing: 0.14em;
      text-transform: uppercase;
      margin-bottom: 16px;
    }}

    h1 {{
      font-family: 'DM Serif Display', serif;
      font-size: clamp(36px, 5vw, 58px);
      line-height: 1.08;
      margin-bottom: 14px;
    }}

    h1 em {{ color: var(--accent2); font-style: italic; }}

    h2 {{
      font-family: 'DM Serif Display', serif;
      font-size: 31px;
      line-height: 1.2;
      margin-bottom: 14px;
    }}

    h3 {{
      font-family: 'DM Serif Display', serif;
      font-size: 23px;
      line-height: 1.2;
      margin-bottom: 10px;
    }}

    p {{
      color: var(--text-dim);
      line-height: 1.65;
      font-size: 15px;
    }}

    .lede {{
      max-width: 78ch;
      font-size: 16px;
      margin-bottom: 18px;
    }}

    .panel {{
      background: var(--surface);
      border: 1px solid var(--border);
      padding: 22px;
      margin-top: 14px;
    }}

    .note-box {{
      border-left: 3px solid var(--accent);
      background: rgba(200,240,96,0.05);
      padding: 14px 16px;
      margin-top: 14px;
    }}

    .steps {{
      display: grid;
      grid-template-columns: 1fr 1fr;
      gap: 2px;
    }}

    .step {{
      background: var(--surface);
      border: 1px solid var(--border);
      padding: 24px;
      position: relative;
      overflow: hidden;
    }}

    .step::after {{
      content: attr(data-n);
      position: absolute;
      bottom: -10px;
      right: 10px;
      font-family: 'DM Serif Display', serif;
      font-size: 74px;
      color: var(--border);
      line-height: 1;
    }}

    .step-phase {{
      font-family: 'DM Mono', monospace;
      font-size: 10px;
      color: var(--accent);
      letter-spacing: 0.12em;
      text-transform: uppercase;
      margin-bottom: 8px;
    }}

    .step p {{ font-size: 14px; }}

    .step.highlight {{
      border-color: rgba(200,240,96,0.3);
      background: rgba(200,240,96,0.04);
    }}

    .charity-grid {{
      display: grid;
      grid-template-columns: 1fr;
      gap: 12px;
      margin-top: 14px;
    }}

    .charity {{
      border: 1px solid var(--border);
      background: var(--surface);
      overflow: hidden;
    }}

    .charity summary {{
      list-style: none;
      cursor: pointer;
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 14px;
      padding: 16px 18px;
      border-left: 3px solid transparent;
    }}

    .charity summary::-webkit-details-marker {{ display: none; }}

    .charity summary::after {{
      content: '+';
      font-family: 'DM Mono', monospace;
      color: var(--accent);
      font-size: 18px;
      line-height: 1;
      flex-shrink: 0;
    }}

    .charity[open] summary {{ border-left-color: var(--accent); background: rgba(200,240,96,0.03); }}
    .charity[open] summary::after {{ content: '−'; }}

    .charity-body {{
      padding: 0 18px 16px;
      border-top: 1px solid var(--border);
    }}

    .charity-body p {{ margin-top: 12px; }}

    .charity a {{
      font-family: 'DM Mono', monospace;
      font-size: 11px;
      letter-spacing: 0.08em;
      text-transform: uppercase;
      color: var(--accent2);
      text-decoration: none;
    }}

    .charity a:hover {{ color: var(--accent); }}

    .cards {{
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(190px, 1fr));
      gap: 12px;
      margin-top: 14px;
    }}

    .card {{
      background: rgba(200,240,96,0.04);
      border: 1px solid rgba(200,240,96,0.2);
      padding: 16px;
    }}

    .label {{
      font-family: 'DM Mono', monospace;
      font-size: 10px;
      letter-spacing: 0.1em;
      text-transform: uppercase;
      color: var(--muted);
      margin-bottom: 8px;
    }}

    .value {{
      font-family: 'DM Serif Display', serif;
      font-size: 29px;
      line-height: 1.2;
      color: var(--text);
    }}

    .story-grid {{
      display: grid;
      grid-template-columns: repeat(3, minmax(0, 1fr));
      gap: 12px;
      margin-top: 14px;
    }}

    .story-card {{
      background: var(--surface);
      border: 1px solid var(--border);
      padding: 18px;
    }}

    .narrative {{
      margin-top: 14px;
      padding: 14px 16px;
      border-left: 3px solid var(--accent2);
      background: rgba(240,208,96,0.06);
      color: var(--text-dim);
    }}

    .grid2 {{
      display: grid;
      grid-template-columns: repeat(2, minmax(0, 1fr));
      gap: 12px;
      margin-top: 12px;
    }}

    .figure {{
      background: var(--surface);
      border: 1px solid var(--border);
      padding: 12px;
    }}

    .figure img {{
      width: 100%;
      height: auto;
      display: block;
      border: 1px solid var(--border);
      background: #fff;
    }}

    .figure.compact {{
      max-width: 560px;
      margin: 12px auto 0;
    }}

    .caption {{
      font-size: 13px;
      color: var(--muted);
      margin-top: 8px;
      line-height: 1.5;
    }}

    table {{
      width: 100%;
      border-collapse: collapse;
      margin-top: 12px;
      border: 1px solid var(--border);
      background: rgba(255,255,255,0.01);
      font-size: 14px;
    }}

    th, td {{
      text-align: left;
      padding: 10px 11px;
      border-bottom: 1px solid var(--border);
      vertical-align: top;
    }}

    th {{
      font-family: 'DM Mono', monospace;
      font-size: 10px;
      letter-spacing: 0.08em;
      text-transform: uppercase;
      color: var(--muted);
    }}

    tr:last-child td {{ border-bottom: none; }}
    .tiny {{ font-size: 13px; }}

    @media (max-width: 760px) {{
      .wrap {{ padding: 36px 18px 80px; }}
      .steps, .story-grid, .grid2 {{ grid-template-columns: 1fr; }}
      .quick-nav {{ position: static; }}
      h1 {{ font-size: 34px; }}
    }}
  </style>
</head>
<body>
<div class="wrap">
  <header>
    <span class="logo">Synthetic Cross-Pollination</span>
    <span class="session-tag">ANALYSIS DASHBOARD</span>
  </header>

  <nav class="quick-nav">
    <a href="#overview">Overview</a>
    <a href="#charities">Charity options</a>
    <a href="#workflow">How it works</a>
    <a href="#results">Results at a glance</a>
    <a href="#deepdive">Deep dive</a>
  </nav>

  <section id="overview">
    <p class="eyebrow">Study overview</p>
    <h1>How exposure to others' reasoning changed <em>donation preferences</em></h1>
    <p class="lede">This dashboard presents results from a two-phase collective choice exercise in which participants ranked four community interventions, then some participants revised their rankings after reviewing summarized reasoning from others.</p>

    <div class="panel">
      <h3>About this study</h3>
      <p>Participants were asked to rank four possible recipients of a donation: a food pantry, a health clinic, an urban tree initiative, and an animal rescue shelter. In Phase 1, participants made their choices independently. In Phase 2, participants first submitted an initial ranking, then reviewed short summaries of how other participants were reasoning about the same trade-offs, and finally submitted a final ranking. This dashboard shows what changed after that exposure: which option won, whether participants reordered their rankings or changed the reasons they gave.</p>
      <div class="figure" style="margin-top: 12px;">
        <img src="../../structure.png" alt="Study structure diagram for two-phase ranking and exposure flow" />
      </div>
      <div class="note-box">
        <p class="tiny"><strong>Pilot note:</strong> This is a pilot with N = {participant_count} participants, so results are not generalizable and are primarily illustrative. Additional sessions are needed for stronger inference.</p>
      </div>
    </div>

    <div class="panel">
      <h3>How to read this dashboard</h3>
      <p>The results are organized around three levels of change:</p>
      <p class="tiny">Collective outcome: how voting and ranking were updated.</p>
      <p class="tiny">Condorcet-efficiency: voting rule comparisons and whether aggregated outcomes were more aligned with the Condorcet winner.</p>
      <p class="tiny">Reasoning change: whether people revised the arguments behind their choices. Participant Top-Choice Outcomes zooms in on individual-level movement.</p>
    </div>
  </section>

  <section id="charities">
    <p class="section-label">Charity options at a glance</p>
    <div class="charity-grid">
      <details class="charity" open>
        <summary><h3>Community Animal Rescue Shelter</h3></summary>
        <div class="charity-body">
          <p>A nonprofit animal rescue organization that takes in abandoned or neglected dogs and cats in New York City. The shelter provides food, medical care, behavioral support, and temporary housing while working to find permanent adoptive homes. Donations help cover veterinary treatment, shelter operations, and adoption programs that give homeless animals a chance to live in safe, long-term homes.</p>
          <a href="https://animalhaven.org/" target="_blank" rel="noopener noreferrer">Website: Animal Haven</a>
        </div>
      </details>
      <details class="charity">
        <summary><h3>Community Food Pantry Network</h3></summary>
        <div class="charity-body">
          <p>A nonprofit organization that helps address food insecurity in New York City by collecting surplus food from restaurants, farms, and grocery stores and delivering it to food pantries, soup kitchens, and community programs. Donations support food distribution, transportation, and partnerships with local organizations that provide meals and groceries to families experiencing hunger.</p>
          <a href="https://www.cityharvest.org/" target="_blank" rel="noopener noreferrer">Website: City Harvest</a>
        </div>
      </details>
      <details class="charity">
        <summary><h3>Urban Tree Initiative</h3></summary>
        <div class="charity-body">
          <p>A nonprofit that works with communities across New York City to plant and care for street trees and other urban green spaces. The organization trains volunteers and local residents to maintain trees, organizes planting projects, and promotes stewardship of the city’s urban forest. Donations help fund tree planting, maintenance programs, and environmental education for residents and youth.</p>
          <a href="https://treesny.org/" target="_blank" rel="noopener noreferrer">Website: Trees New York</a>
        </div>
      </details>
      <details class="charity">
        <summary><h3>Community Health Clinic</h3></summary>
        <div class="charity-body">
          <p>A local student-run, physician-supervised, free clinic that provides care to uninsured adults in its neighborhood. Their services are confidential and provided at no cost. The clinic serves more than 300 patients annually, with more than 1,000 visits across six medical specialties: OB/GYN; ophthalmology; physical medicine and rehabilitation/podiatry; liver/gastrointestinal; mental health; and cardiology.</p>
          <a href="https://icahn.mssm.edu/education/medical/clinical/ehhop" target="_blank" rel="noopener noreferrer">Website: East Harlem Health Outreach Partnership</a>
        </div>
      </details>
    </div>
  </section>

  <section id="workflow">
    <p class="section-label">How this process works</p>
    <div class="steps">
      <div class="step highlight" data-n="1">
        <p class="step-phase">Phase 1</p>
        <h3>Share your view</h3>
        <p>Participants rank all four options and provide short reasoning for their top choice.</p>
      </div>
      <div class="step" data-n="2">
        <p class="step-phase">Between phases</p>
        <h3>Ideas are collected</h3>
        <p>Reasoning is anonymized and neutrally rephrased to create short, attribution-free summaries.</p>
      </div>
      <div class="step" data-n="3">
        <p class="step-phase">Phase 2</p>
        <h3>Hear others' thinking</h3>
        <p>Participants review summarized peer reasoning, then submit final rankings and final rationale.</p>
      </div>
      <div class="step" data-n="4">
        <p class="step-phase">Outcome</p>
        <h3>Collective picture</h3>
        <p>We compare initial and final rankings and reasoning to measure preference movement and reframing.</p>
      </div>
    </div>
  </section>

  <section id="results">
    <p class="section-label">Results at a glance</p>
    <div class="cards">
      <div class="card">
        <div class="label">Phase 1 plurality winner</div>
        <div class="value">{phase1_winners['plurality']}</div>
      </div>
      <div class="card">
        <div class="label">Phase 2 initial plurality winner</div>
        <div class="value">{phase2_initial_winners['plurality']}</div>
      </div>
      <div class="card">
        <div class="label">Phase 2 final plurality winner</div>
        <div class="value">{phase2_final_winners['plurality']}</div>
      </div>
      <div class="card">
        <div class="label">Top-choice changers</div>
        <div class="value">{phase2_summary['changed_top_choice_count']}</div>
      </div>
      {embedding_block}
    </div>

    <div class="panel">
      <p>In phase 2 a minority changed their winner, a larger group edited the ranking, and almost everyone revised the argument they used to justify that ranking (that said, the measure of change in the argument is preliminary and perhaps too blunt, and needs a supplement).</p>
      <div class="story-grid">
        <div class="story-card">
          <div class="label">Preference outcome</div>
          <div class="value">{share_text(top_choice_changed_count, participant_count)}</div>
          <p>{no_rank_change_count} participants stayed fully put, while cross-pollination produced three outright first-place switches.</p>
        </div>
        <div class="story-card">
          <div class="label">Ranking reshuffle</div>
          <div class="value">{share_text(any_rank_change_count, participant_count)}</div>
          <p>{minor_rank_change_count} made a limited reorder and {major_rank_change_count} made a larger reshuffle across the four options.</p>
        </div>
        <div class="story-card">
          <div class="label">Rationale rewrite</div>
          <div class="value">{share_text(theme_change_count, participant_count)}</div>
          <p>{unchanged_theme_set_count} kept the same theme set, {one_theme_change_count} changed one theme, and {two_plus_theme_change_count} changed two or more themes.</p>
        </div>
      </div>
      <div class="narrative">
        Most participants did not abandon their top option, but many re-ordered lower preferences and nearly all updated the reasons they gave for those preferences. Not all changes need to be due to cross-pollination, e.g. rationale rewrites among non-changers might be due to laziness.
      </div>
    </div>
  </section>

  <section id="deepdive">
    <p class="section-label">Deep dive</p>
    <h2>Collective outcome: how votes and rankings were updated</h2>
    <div class="panel">
      <p class="tiny">Community Health Clinic gained the most from cross-pollination, while Community Food Pantry lost its initial edge. Urban Tree Initiative also picked up support, mostly as an upward ranking move rather than a broad first-place takeover.</p>
      {render_html_table(movement_rows, ['option', 'initial top votes', 'final top votes', 'net top-vote change', 'participants moving it up'])}
    </div>
    <div class="grid2">
      <div class="figure"><img src="figures/phase2_initial_vs_final_top_choice_votes.svg" alt="Phase 2 top choice grouped chart" /></div>
      <div class="figure"><img src="figures/phase2_mean_rank_shift.svg" alt="Phase 2 mean rank shift dumbbell plot" /></div>
      <div class="figure"><img src="figures/phase2_top_choice_transitions.svg" alt="Phase 2 transitions heatmap" /></div>
    </div>

    <h2 style="margin-top: 34px;">Voting rule comparison</h2>
    <div class="panel">
      <p class="tiny">Only rules that are justified by ranked ballots are treated as primary results. Approval-style rules are excluded because the study captures rankings, not direct approvals.</p>
      <p class="tiny">In phase 1, there's a lot of instability due to the tiny number of participants. We're more interested in phase 2: initially, community food pantry wins across the board, but in the final submission there's some variability with health clinic mostly prevailing.</p>
      {render_html_table(rule_rows, ['rule', 'phase1', 'phase2_initial', 'phase2_final'])}
    </div>

    <h2 style="margin-top: 34px;">Reasoning movement</h2>
    <div class="panel">
      <p class="tiny">We also zoom in on within-participant shifts in rationales. {reasoning_movement_copy}</p>
    </div>
    <div class="figure compact"><img src="figures/phase2_reasoning_shift_lollipop.svg" alt="Participant reasoning distance lollipop chart" /></div>

    <div class="panel">
      <p class="tiny">We estimate within-participant movement across popular explanatory themes: urgency, cost-effectiveness, equity, long-term effects, short-term relief, local focus, global focus, personal connection and identity, moral duty, trade-offs, uncertainty, ineffectiveness, deservingness, and salience.</p>
      <table><thead><tr><th>theme pattern</th><th>direction</th><th>reading</th></tr></thead><tbody><tr><td>Deservingness targeting</td><td>down</td><td>Largest average decline after cross-pollination.</td></tr><tr><td>Moral duty compassion</td><td>up</td><td>Largest average increase in final rationales.</td></tr><tr><td>Local community focus</td><td>slight down</td><td>Still common, but less dominant in final text.</td></tr><tr><td>Skepticism about effectiveness</td><td>slight down</td><td>Disappeared from the final text.</td></tr></tbody></table>
    </div>
    <div class="grid2">
      <div class="figure">
        <img src="r/phase2_theme_shift_dumbbell.png" alt="Theme average weights before and after cross-pollination" />
        <p class="caption">Theme-level mean weight before vs after for each rationale theme.</p>
      </div>
      <div class="figure">
        <img src="r/phase2_theme_shift_l1_lollipop.png" alt="Participant-level L1 theme shift distances" />
        <p class="caption">Participant-level L1 movement in theme composition.</p>
      </div>
    </div>

    <h2 style="margin-top: 34px;">Social choice robustness (exhaustive subgroups)</h2>
    <div class="panel">
      <p class="tiny">Across all 6,188 unique 5-person groups, plurality outcomes become modestly more aligned with the Condorcet winner after cross-pollination when a Condorcet winner exists, even as Condorcet existence itself drops slightly.</p>
      <table><thead><tr><th>estimand</th><th>after - before</th><th>interpretation</th></tr></thead><tbody><tr><td>P(outcome = Condorcet winner | Condorcet exists)</td><td>+0.0698</td><td>Plurality is more likely to pick the Condorcet winner when one exists.</td></tr><tr><td>P(outcome = Condorcet winner)</td><td>+0.0514</td><td>Net gain in Condorcet-consistent outcomes overall.</td></tr><tr><td>P(Condorcet winner exists)</td><td>-0.0296</td><td>Slightly fewer subgroups exhibit a Condorcet winner.</td></tr></tbody></table>
    </div>
    <div class="grid2">
      <div class="figure">
        <img src="r/phase2_resampling_probability_comparison.png" alt="Probability comparison before and after cross-pollination across exhaustive subgroups" />
        <p class="caption">Before/after probabilities for Condorcet-related outcomes.</p>
      </div>
      <div class="figure">
        <img src="r/phase2_resampling_delta_effects.png" alt="Delta effect estimates for exhaustive subgroup social choice metrics" />
        <p class="caption">Estimated effect sizes (after minus before) across subgroup metrics.</p>
      </div>
    </div>

    <h2 style="margin-top: 34px;">Exploratory predictors</h2>
    <div class="panel">
      <p class="tiny">These regressions are descriptive only (N = {participant_count}; {top_choice_changed_count} top-choice changers). Coefficients are standardized for comparability, and the chart should be read as correlational.</p>
      <div class="figure" style="margin-top: 10px;">
        <img src="r/phase2_regression_coefficients.png" alt="Standardized regression coefficients for top-choice change ranking distance and clinic gain" />
        <p class="caption">No predictor is statistically decisive at this sample size; duration shows the strongest directional association for ranking distance.</p>
      </div>
    </div>

    <h2 style="margin-top: 34px;">Participant top-choice outcomes</h2>
    <div class="panel">
      <h3>Participants who changed top choice</h3>
      {render_html_table([format_change_row(row) for row in changer_rows], ['participant', 'top choice before', 'top choice after', 'wording shift', 'themes in initial', 'themes in final', 'theme moves'])}
    </div>
    <div class="panel">
      <p class="tiny">Stable top-choice participants can still show substantial reasoning movement even when the headline preference remains the same.</p>
      <h3>Stable participants</h3>
      {render_html_table([format_change_row(row) for row in stable_rows[:8]], ['participant', 'top choice before', 'top choice after', 'wording shift', 'themes in initial', 'themes in final', 'theme moves'])}
    </div>
  </section>
</div>
</body>
</html>
"""
    (output_dir / "dashboard.html").write_text(html, encoding="utf-8")


def main() -> None:
    args = parse_args()
    config = parse_pilot_config(args.config)

    output_dir = ensure_dir(args.output_dir)
    figures_dir = ensure_dir(output_dir / "figures")

    phase1_transcripts = load_transcript_rows(args.phase1_json)
    phase1_extractions = load_extraction_rows(args.phase1_extractions)
    phase2_transcripts = load_transcript_rows(args.phase2_json)
    phase2_extractions = load_extraction_rows(args.phase2_extractions)

    phase1_summary, phase1_option_rows, phase1_participants = describe_phase1(
        phase1_extractions,
        phase1_transcripts,
        config.options,
    )
    phase2_summary, phase2_option_rows, phase2_participants = describe_phase2(
        phase2_extractions,
        phase2_transcripts,
        config.options,
    )

    phase1_rankings = [row["vote_ranking"] for row in phase1_extractions if row.get("vote_ranking")]
    phase2_initial_rankings = [row["initial_vote_ranking"] for row in phase2_extractions if row.get("initial_vote_ranking")]
    phase2_final_rankings = [row["final_vote_ranking"] for row in phase2_extractions if row.get("final_vote_ranking")]

    phase1_rules = compare_rules(phase1_rankings, config.options, config.option_labels)
    phase2_initial_rules = compare_rules(phase2_initial_rankings, config.options, config.option_labels)
    phase2_final_rules = compare_rules(phase2_final_rankings, config.options, config.option_labels)
    phase2_changes = analyze_changes(phase2_extractions, config.options)
    reasoning_shift = analyze_reasoning_shift(
        phase2_extractions,
        config,
        str(output_dir),
        with_embeddings=args.with_embeddings,
    )
    analyze_phase1_reasoning_embeddings(
        phase1_extractions,
        config,
        str(output_dir),
        with_embeddings=args.with_embeddings,
    )
    if "embedding_rows" not in reasoning_shift:
        existing_embedding_rows = load_csv_rows(output_dir / "phase2_reasoning_embedding_shift.csv")
        if existing_embedding_rows:
            existing_embedding_summary = {}
            embedding_summary_path = output_dir / "phase2_reasoning_embeddings.json"
            if embedding_summary_path.exists():
                existing_embedding_summary = load_json(str(embedding_summary_path))
            normalized_rows = []
            sims = []
            changed_sims = []
            stable_sims = []
            for row in existing_embedding_rows:
                similarity = float(row["embedding_cosine_similarity"]) if row.get("embedding_cosine_similarity") else None
                changed = str(row.get("changed_top_choice", "")).lower() == "true"
                normalized = {
                    "user_id": row.get("user_id"),
                    "changed_top_choice": changed,
                    "embedding_cosine_similarity": similarity,
                    "embedding_shift_intensity": float(row["embedding_shift_intensity"]) if row.get("embedding_shift_intensity") else None,
                }
                normalized_rows.append(normalized)
                if similarity is not None:
                    sims.append(similarity)
                    if changed:
                        changed_sims.append(similarity)
                    else:
                        stable_sims.append(similarity)
            reasoning_shift["embedding_rows"] = normalized_rows
            reasoning_shift["embedding_summary"] = {
                "avg_embedding_similarity": sum(sims) / len(sims) if sims else None,
                "avg_embedding_distance": (sum((1 - item) for item in sims) / len(sims)) if sims else None,
                "avg_embedding_similarity_changed_top": sum(changed_sims) / len(changed_sims) if changed_sims else None,
                "avg_embedding_similarity_stable_top": sum(stable_sims) / len(stable_sims) if stable_sims else None,
                "avg_random_initial_distance": existing_embedding_summary.get("avg_random_initial_distance"),
            }
    if "embedding_summary" in reasoning_shift and reasoning_shift["embedding_summary"].get("avg_random_initial_distance") is None:
        vectors_path = output_dir / "phase2_reasoning_embedding_vectors.json"
        if vectors_path.exists():
            vector_rows = load_json(vectors_path)
            fallback_avg = avg_random_initial_distance_from_vectors(vector_rows if isinstance(vector_rows, list) else [])
            if fallback_avg is not None:
                reasoning_shift["embedding_summary"]["avg_random_initial_distance"] = fallback_avg

    write_json(output_dir / "phase1_summary.json", phase1_summary)
    write_json(output_dir / "phase2_summary.json", phase2_summary)
    write_csv(output_dir / "phase1_option_stats.csv", phase1_option_rows)
    write_csv(output_dir / "phase2_option_stats.csv", phase2_option_rows)
    write_csv(output_dir / "phase1_participant_stats.csv", phase1_participants)
    write_csv(output_dir / "phase2_participant_stats.csv", phase2_participants)

    write_csv(output_dir / "phase1_voting_rules.csv", phase1_rules["rules"])
    write_csv(output_dir / "phase2_initial_voting_rules.csv", phase2_initial_rules["rules"])
    write_csv(output_dir / "phase2_final_voting_rules.csv", phase2_final_rules["rules"])
    write_csv(output_dir / "phase1_voting_score_table.csv", phase1_rules["score_table"])
    write_csv(output_dir / "phase2_initial_voting_score_table.csv", phase2_initial_rules["score_table"])
    write_csv(output_dir / "phase2_final_voting_score_table.csv", phase2_final_rules["score_table"])
    write_csv(output_dir / "phase2_transition_matrix.csv", phase2_changes["transition_rows"])
    write_csv(output_dir / "phase2_option_movement.csv", phase2_changes["option_movement_rows"])
    write_csv(output_dir / "phase2_participant_changes.csv", phase2_changes["participant_rows"])
    write_csv(output_dir / "phase2_reasoning_shift.csv", reasoning_shift["participant_rows"])
    write_csv(output_dir / "phase2_initial_theme_counts.csv", reasoning_shift["initial_theme_counts"])
    write_csv(output_dir / "phase2_final_theme_counts.csv", reasoning_shift["final_theme_counts"])

    if "embedding_rows" in reasoning_shift:
        write_csv(output_dir / "phase2_reasoning_embedding_shift.csv", reasoning_shift["embedding_rows"])

    save_bar_chart(
        "Phase 2 Initial Top-Choice Votes",
        [
            {"label": option_label(row["option"], config.option_labels), "value": row["initial_top_votes"]}
            for row in phase2_option_rows
        ],
        "label",
        "value",
        str(figures_dir / "phase2_initial_top_choice_votes.svg"),
    )
    save_bar_chart(
        "Phase 2 Final Top-Choice Votes",
        [
            {"label": option_label(row["option"], config.option_labels), "value": row["final_top_votes"]}
            for row in phase2_option_rows
        ],
        "label",
        "value",
        str(figures_dir / "phase2_final_top_choice_votes.svg"),
    )
    save_heatmap(
        "Phase 2 Top-Choice Transitions",
        phase2_changes["transition_rows"],
        config.options,
        str(figures_dir / "phase2_top_choice_transitions.svg"),
    )
    save_grouped_bar_chart(
        "Phase 2 Initial vs Final Top-Choice Votes",
        [
            {
                "label": option_label(row["option"], config.option_labels),
                "initial": row["initial_top_votes"],
                "final": row["final_top_votes"],
            }
            for row in phase2_option_rows
        ],
        "label",
        ["initial", "final"],
        ["Initial", "Final"],
        ["#0f766e", "#dc2626"],
        str(figures_dir / "phase2_initial_vs_final_top_choice_votes.svg"),
    )
    save_dumbbell_chart(
        "Phase 2 Mean Rank Shift By Option",
        [
            {
                "label": option_label(row["option"], config.option_labels),
                "initial_mean_rank": row["initial_mean_rank"],
                "final_mean_rank": row["final_mean_rank"],
            }
            for row in phase2_option_rows
        ],
        "label",
        "initial_mean_rank",
        "final_mean_rank",
        "Initial mean rank",
        "Final mean rank",
        str(figures_dir / "phase2_mean_rank_shift.svg"),
    )
    lollipop_rows = []
    for row in reasoning_shift.get("embedding_rows", []):
        lollipop_rows.append(
            {
                "participant": row["user_id"],
                "changed_top_choice": row["changed_top_choice"],
                "embedding_distance": row.get("embedding_shift_intensity"),
            }
        )
    lollipop_rows.sort(key=lambda item: item.get("embedding_distance") or 0, reverse=True)
    save_lollipop_comparison_chart(
        "Reasoning Shift: Participant Embedding Distance",
        lollipop_rows,
        "participant",
        "embedding_distance",
        "changed_top_choice",
        reasoning_shift.get("embedding_summary", {}).get("avg_random_initial_distance"),
        "Avg random initial distance",
        str(figures_dir / "phase2_reasoning_shift_lollipop.svg"),
    )

    write_report(
        output_dir,
        config,
        phase1_summary,
        phase1_option_rows,
        phase2_summary,
        phase2_option_rows,
        phase1_rules,
        phase2_initial_rules,
        phase2_final_rules,
        phase2_changes,
        reasoning_shift,
    )
    write_dashboard(
        output_dir,
        config,
        phase1_summary,
        phase2_summary,
        phase1_rules,
        phase2_initial_rules,
        phase2_final_rules,
        phase2_changes,
        reasoning_shift,
    )
    print(f"Wrote analysis outputs to {output_dir}")


if __name__ == "__main__":
    main()
