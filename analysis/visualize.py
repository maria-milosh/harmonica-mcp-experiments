from __future__ import annotations

from pathlib import Path


def _svg_header(width: int, height: int) -> str:
    return f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">'


def save_bar_chart(title: str, rows: list[dict[str, object]], label_key: str, value_key: str, output_path: str) -> None:
    width = 800
    height = 420
    margin_left = 170
    margin_bottom = 70
    margin_top = 60
    chart_width = width - margin_left - 40
    chart_height = height - margin_top - margin_bottom
    values = [float(row[value_key]) for row in rows]
    max_value = max(values) if values else 1.0
    bar_height = max(16, int(chart_height / max(1, len(rows)) * 0.6))
    gap = max(8, int(chart_height / max(1, len(rows)) * 0.35))

    parts = [
        _svg_header(width, height),
        '<style>text{font-family:Helvetica,Arial,sans-serif;fill:#1f2937}.title{font-size:22px;font-weight:700}.label{font-size:13px}.value{font-size:12px;font-weight:700}.axis{stroke:#9ca3af;stroke-width:1}.bar{fill:#2563eb}</style>',
        f'<text class="title" x="{margin_left}" y="32">{title}</text>',
        f'<line class="axis" x1="{margin_left}" y1="{height - margin_bottom}" x2="{width - 20}" y2="{height - margin_bottom}" />',
    ]

    for idx, row in enumerate(rows):
        y = margin_top + idx * (bar_height + gap)
        label = str(row[label_key])
        value = float(row[value_key])
        bar_width = 0 if max_value == 0 else (value / max_value) * chart_width
        parts.append(f'<text class="label" x="18" y="{y + bar_height - 2}">{label}</text>')
        parts.append(f'<rect class="bar" x="{margin_left}" y="{y}" width="{bar_width:.1f}" height="{bar_height}" rx="4" />')
        parts.append(f'<text class="value" x="{margin_left + bar_width + 8:.1f}" y="{y + bar_height - 2}">{value:g}</text>')

    parts.append("</svg>")
    Path(output_path).write_text("\n".join(parts), encoding="utf-8")


def save_heatmap(title: str, matrix_rows: list[dict[str, object]], labels: list[str], output_path: str) -> None:
    cell = 80
    width = 220 + len(labels) * cell
    height = 180 + len(labels) * cell
    max_value = 0
    for row in matrix_rows:
        for label in labels:
            max_value = max(max_value, int(row.get(label, 0)))

    parts = [
        _svg_header(width, height),
        '<style>text{font-family:Helvetica,Arial,sans-serif;fill:#1f2937}.title{font-size:22px;font-weight:700}.label{font-size:12px}.value{font-size:12px;font-weight:700}</style>',
        f'<text class="title" x="30" y="36">{title}</text>',
    ]

    for idx, label in enumerate(labels):
        x = 180 + idx * cell + (cell / 2)
        y = 90 + idx * cell + (cell / 2)
        parts.append(f'<text class="label" x="{x}" y="72" text-anchor="middle">{label}</text>')
        parts.append(f'<text class="label" x="158" y="{y}" text-anchor="end">{label}</text>')

    for row_idx, row in enumerate(matrix_rows):
        for col_idx, label in enumerate(labels):
            value = int(row.get(label, 0))
            intensity = 0 if max_value == 0 else value / max_value
            red = int(239 - 120 * intensity)
            green = int(246 - 130 * intensity)
            blue = int(255 - 170 * intensity)
            x = 180 + col_idx * cell
            y = 90 + row_idx * cell
            parts.append(
                f'<rect x="{x}" y="{y}" width="{cell - 4}" height="{cell - 4}" '
                f'fill="rgb({red},{green},{blue})" rx="4" />'
            )
            parts.append(f'<text class="value" x="{x + (cell / 2) - 2}" y="{y + (cell / 2) + 4}" text-anchor="middle">{value}</text>')

    parts.append("</svg>")
    Path(output_path).write_text("\n".join(parts), encoding="utf-8")


def save_grouped_bar_chart(
    title: str,
    rows: list[dict[str, object]],
    label_key: str,
    series_keys: list[str],
    series_labels: list[str],
    colors: list[str],
    output_path: str,
) -> None:
    width = 920
    height = 460
    margin_left = 110
    margin_bottom = 90
    margin_top = 70
    chart_width = width - margin_left - 50
    chart_height = height - margin_top - margin_bottom
    max_value = max(float(row[key]) for row in rows for key in series_keys) if rows else 1.0
    group_width = chart_width / max(1, len(rows))
    bar_width = min(42, group_width / max(2, len(series_keys)) - 10)

    parts = [
        _svg_header(width, height),
        '<style>text{font-family:Helvetica,Arial,sans-serif;fill:#1f2937}.title{font-size:22px;font-weight:700}.label{font-size:12px}.value{font-size:11px;font-weight:700}.axis{stroke:#9ca3af;stroke-width:1}</style>',
        f'<text class="title" x="{margin_left}" y="34">{title}</text>',
        f'<line class="axis" x1="{margin_left}" y1="{height - margin_bottom}" x2="{width - 20}" y2="{height - margin_bottom}" />',
    ]

    for idx, (series_label, color) in enumerate(zip(series_labels, colors)):
        legend_x = width - 240 + idx * 110
        parts.append(f'<rect x="{legend_x}" y="18" width="16" height="16" rx="3" fill="{color}" />')
        parts.append(f'<text class="label" x="{legend_x + 22}" y="31">{series_label}</text>')

    for row_idx, row in enumerate(rows):
        label = str(row[label_key])
        group_x = margin_left + row_idx * group_width + 20
        for series_idx, key in enumerate(series_keys):
            value = float(row[key])
            bar_height = 0 if max_value == 0 else (value / max_value) * chart_height
            x = group_x + series_idx * (bar_width + 8)
            y = height - margin_bottom - bar_height
            parts.append(
                f'<rect x="{x:.1f}" y="{y:.1f}" width="{bar_width:.1f}" height="{bar_height:.1f}" '
                f'fill="{colors[series_idx]}" rx="4" />'
            )
            parts.append(f'<text class="value" x="{x + (bar_width / 2):.1f}" y="{y - 6:.1f}" text-anchor="middle">{value:g}</text>')
        label_x = group_x + ((len(series_keys) * (bar_width + 8) - 8) / 2)
        parts.append(f'<text class="label" x="{label_x:.1f}" y="{height - 32}" text-anchor="middle">{label}</text>')

    parts.append("</svg>")
    Path(output_path).write_text("\n".join(parts), encoding="utf-8")


def save_dumbbell_chart(
    title: str,
    rows: list[dict[str, object]],
    label_key: str,
    left_key: str,
    right_key: str,
    left_label: str,
    right_label: str,
    output_path: str,
) -> None:
    width = 900
    height = 420
    margin_left = 220
    margin_top = 70
    margin_bottom = 50
    chart_width = width - margin_left - 80
    chart_height = height - margin_top - margin_bottom
    min_value = min(min(float(row[left_key]), float(row[right_key])) for row in rows) if rows else 0
    max_value = max(max(float(row[left_key]), float(row[right_key])) for row in rows) if rows else 1
    value_span = max(max_value - min_value, 1)

    def scale(value: float) -> float:
        return margin_left + ((value - min_value) / value_span) * chart_width

    parts = [
        _svg_header(width, height),
        '<style>text{font-family:Helvetica,Arial,sans-serif;fill:#1f2937}.title{font-size:22px;font-weight:700}.label{font-size:13px}.small{font-size:12px}.line{stroke:#9ca3af;stroke-width:3}.dotA{fill:#0f766e}.dotB{fill:#dc2626}</style>',
        f'<text class="title" x="{margin_left}" y="34">{title}</text>',
        f'<circle cx="{width - 210}" cy="24" r="6" class="dotA" />',
        f'<text class="small" x="{width - 196}" y="28">{left_label}</text>',
        f'<circle cx="{width - 210}" cy="44" r="6" class="dotB" />',
        f'<text class="small" x="{width - 196}" y="48">{right_label}</text>',
    ]

    for idx, row in enumerate(rows):
        y = margin_top + idx * (chart_height / max(1, len(rows)))
        label = str(row[label_key])
        left_value = float(row[left_key])
        right_value = float(row[right_key])
        left_x = scale(left_value)
        right_x = scale(right_value)
        parts.append(f'<text class="label" x="18" y="{y + 6:.1f}">{label}</text>')
        parts.append(f'<line class="line" x1="{left_x:.1f}" y1="{y:.1f}" x2="{right_x:.1f}" y2="{y:.1f}" />')
        parts.append(f'<circle class="dotA" cx="{left_x:.1f}" cy="{y:.1f}" r="7" />')
        parts.append(f'<circle class="dotB" cx="{right_x:.1f}" cy="{y:.1f}" r="7" />')
        parts.append(f'<text class="small" x="{left_x - 12:.1f}" y="{y - 10:.1f}">{left_value:.2f}</text>')
        parts.append(f'<text class="small" x="{right_x + 10:.1f}" y="{y - 10:.1f}">{right_value:.2f}</text>')

    parts.append("</svg>")
    Path(output_path).write_text("\n".join(parts), encoding="utf-8")


def save_scatter_plot(
    title: str,
    rows: list[dict[str, object]],
    x_key: str,
    y_key: str,
    category_key: str,
    output_path: str,
) -> None:
    width = 860
    height = 460
    margin_left = 90
    margin_bottom = 70
    margin_top = 70
    chart_width = width - margin_left - 40
    chart_height = height - margin_top - margin_bottom
    x_values = [float(row[x_key]) for row in rows if row.get(x_key) is not None]
    y_values = [float(row[y_key]) for row in rows if row.get(y_key) is not None]
    min_x = min(x_values) if x_values else 0.0
    max_x = max(x_values) if x_values else 1.0
    min_y = min(y_values) if y_values else 0.0
    max_y = max(y_values) if y_values else 1.0
    x_span = max(max_x - min_x, 1e-6)
    y_span = max(max_y - min_y, 1e-6)

    def scale_x(value: float) -> float:
        return margin_left + ((value - min_x) / x_span) * chart_width

    def scale_y(value: float) -> float:
        return height - margin_bottom - ((value - min_y) / y_span) * chart_height

    colors = {False: "#2563eb", True: "#dc2626", "False": "#2563eb", "True": "#dc2626"}
    labels = {False: "Stable top choice", True: "Changed top choice", "False": "Stable top choice", "True": "Changed top choice"}

    parts = [
        _svg_header(width, height),
        '<style>text{font-family:Helvetica,Arial,sans-serif;fill:#1f2937}.title{font-size:22px;font-weight:700}.label{font-size:12px}.axis{stroke:#9ca3af;stroke-width:1}.dot{opacity:0.85}</style>',
        f'<text class="title" x="{margin_left}" y="34">{title}</text>',
        f'<line class="axis" x1="{margin_left}" y1="{height - margin_bottom}" x2="{width - 20}" y2="{height - margin_bottom}" />',
        f'<line class="axis" x1="{margin_left}" y1="{margin_top}" x2="{margin_left}" y2="{height - margin_bottom}" />',
        f'<text class="label" x="{width / 2:.1f}" y="{height - 20}" text-anchor="middle">Embedding cosine similarity</text>',
        f'<text class="label" x="24" y="{height / 2:.1f}" transform="rotate(-90 24 {height / 2:.1f})" text-anchor="middle">Lexical Jaccard similarity</text>',
    ]

    for cat, color in [(False, "#2563eb"), (True, "#dc2626")]:
        offset = 0 if cat is False else 150
        parts.append(f'<circle cx="{width - 240 + offset}" cy="26" r="6" fill="{color}" />')
        parts.append(f'<text class="label" x="{width - 228 + offset}" y="30">{labels[cat]}</text>')

    for row in rows:
        if row.get(x_key) is None or row.get(y_key) is None:
            continue
        x = scale_x(float(row[x_key]))
        y = scale_y(float(row[y_key]))
        category = row.get(category_key)
        color = colors.get(category, "#4b5563")
        parts.append(f'<circle class="dot" cx="{x:.1f}" cy="{y:.1f}" r="7" fill="{color}" />')

    parts.append("</svg>")
    Path(output_path).write_text("\n".join(parts), encoding="utf-8")


def save_lollipop_comparison_chart(
    title: str,
    rows: list[dict[str, object]],
    label_key: str,
    value_key: str,
    category_key: str,
    baseline_value: float | None,
    baseline_label: str,
    output_path: str,
) -> None:
    width = 940
    height = max(420, 110 + (len(rows) * 28))
    margin_left = 180
    margin_top = 80
    margin_bottom = 50
    chart_width = width - margin_left - 40
    chart_height = height - margin_top - margin_bottom
    values = [float(row[value_key]) for row in rows if row.get(value_key) is not None]
    max_value = max(values + ([baseline_value] if baseline_value is not None else [0.0])) if values else 1.0
    max_value = max(max_value, 0.05)

    def scale_x(value: float) -> float:
        return margin_left + (value / max_value) * chart_width

    colors = {False: "#2563eb", True: "#dc2626", "False": "#2563eb", "True": "#dc2626"}
    labels = {False: "Stable top choice", True: "Changed top choice", "False": "Stable top choice", "True": "Changed top choice"}

    parts = [
        _svg_header(width, height),
        '<style>text{font-family:Helvetica,Arial,sans-serif;fill:#1f2937}.title{font-size:22px;font-weight:700}.label{font-size:12px}.small{font-size:11px}.axis{stroke:#9ca3af;stroke-width:1}.stem{stroke:#cbd5e1;stroke-width:3}.dot{stroke:#fff;stroke-width:1.5}.baseline{stroke:#d97706;stroke-width:2;stroke-dasharray:6 6}</style>',
        f'<text class="title" x="{margin_left}" y="34">{title}</text>',
        f'<line class="axis" x1="{margin_left}" y1="{height - margin_bottom}" x2="{width - 20}" y2="{height - margin_bottom}" />',
        f'<text class="label" x="{width / 2:.1f}" y="{height - 18}" text-anchor="middle">Cosine distance between initial and final reasoning embeddings</text>',
    ]

    for idx, tick in enumerate([0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6]):
        if tick > max_value:
            continue
        x = scale_x(tick)
        parts.append(f'<line class="axis" x1="{x:.1f}" y1="{margin_top - 10}" x2="{x:.1f}" y2="{height - margin_bottom}" opacity="0.25" />')
        parts.append(f'<text class="small" x="{x:.1f}" y="{height - margin_bottom + 18}" text-anchor="middle">{tick:.1f}</text>')

    if baseline_value is not None:
        baseline_x = scale_x(float(baseline_value))
        parts.append(f'<line class="baseline" x1="{baseline_x:.1f}" y1="{margin_top - 10}" x2="{baseline_x:.1f}" y2="{height - margin_bottom}" />')
        parts.append(f'<text class="small" x="{baseline_x + 8:.1f}" y="{margin_top - 18}" fill="#d97706">{baseline_label}: {baseline_value:.3f}</text>')

    for cat, color, offset in [(False, "#2563eb", 0), (True, "#dc2626", 150)]:
        parts.append(f'<circle cx="{width - 260 + offset}" cy="26" r="6" fill="{color}" />')
        parts.append(f'<text class="label" x="{width - 248 + offset}" y="30">{labels[cat]}</text>')

    for idx, row in enumerate(rows):
        if row.get(value_key) is None:
            continue
        y = margin_top + idx * (chart_height / max(1, len(rows)))
        value = float(row[value_key])
        x = scale_x(value)
        color = colors.get(row.get(category_key), "#4b5563")
        parts.append(f'<text class="label" x="18" y="{y + 4:.1f}">{row[label_key]}</text>')
        parts.append(f'<line class="stem" x1="{margin_left}" y1="{y:.1f}" x2="{x:.1f}" y2="{y:.1f}" />')
        parts.append(f'<circle class="dot" cx="{x:.1f}" cy="{y:.1f}" r="7" fill="{color}" />')
        parts.append(f'<text class="small" x="{x + 10:.1f}" y="{y + 4:.1f}">{value:.3f}</text>')

    parts.append("</svg>")
    Path(output_path).write_text("\n".join(parts), encoding="utf-8")
