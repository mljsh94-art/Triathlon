#!/usr/bin/env python3
"""Generate static HTML performance dashboard."""

from __future__ import annotations

import argparse
import html
import importlib.util
import json
import os
import sys
from pathlib import Path

_SCRIPT_DIR = Path(__file__).resolve().parent
if str(_SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(_SCRIPT_DIR))
from profile_schema import (  # noqa: E402
    PROFILE_BENCHMARKS,
    bench_commits,
    bench_cpi,
    bench_cycles,
    bench_ipc,
    bench_predict,
    bench_stall_detail,
    bench_stall_section_total,
    bench_stall_total,
    top_stall_categories,
)
from render_summary_html import (  # noqa: E402
    format_predict_dashboard_lines,
    fmt_part_total,
    write_summary_html_for_run,
)

BENCHMARKS = PROFILE_BENCHMARKS


def load_compare_module(script_dir: Path):
    mod_path = script_dir / "compare_summary.py"
    spec = importlib.util.spec_from_file_location("compare_summary", mod_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {mod_path}")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def load_summary(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def resolve_summary_path(profile_root: Path, run: dict) -> Path | None:
    run_id = run.get("run_id", "?")
    run_dir = Path(run.get("run_dir", profile_root / run_id))
    for candidate in (run_dir / "summary.json", profile_root / run_id / "summary.json"):
        if candidate.exists():
            return candidate
    return None


def href_from_dashboard(profile_root: Path, target: Path) -> str:
    dashboard_dir = profile_root / "dashboard"
    return os.path.relpath(target, dashboard_dir).replace("\\", "/")


def profile_root_label(profile_root: Path, npc_home: Path) -> str:
    try:
        rel = profile_root.resolve().relative_to(npc_home.resolve())
        return f"npc/{rel.as_posix()}"
    except ValueError:
        return profile_root.as_posix()


def compare_with_baseline(script_dir: Path, baseline_dir: Path, run_dir: Path) -> dict | None:
    base_summary = baseline_dir / "summary.json"
    cur_summary = run_dir / "summary.json"
    if not base_summary.exists() or not cur_summary.exists():
        return None
    mod = load_compare_module(script_dir)
    return mod.compare_summary_files(base_summary, cur_summary)


def render_dashboard(profile_root: Path, script_dir: Path, npc_home: Path | None = None) -> str:
    if npc_home is None:
        npc_home = script_dir.parent.parent
    index_path = profile_root / "index.json"
    if not index_path.exists():
        index = {"baseline_run_id": "baseline", "runs": []}
    else:
        index = json.loads(index_path.read_text(encoding="utf-8"))

    baseline_id = index.get("baseline_run_id", "baseline")
    baseline_dir = profile_root / baseline_id
    runs = index.get("runs", [])

    labels = [r.get("display_name") or r.get("run_id", "?") for r in runs]
    core_ipc = [r.get("ipc", {}).get("coremark", 0) for r in runs]
    micro_ipc = [r.get("ipc", {}).get("microbench", 0) for r in runs]
    core_cycles = [r.get("cycles", {}).get("coremark", 0) for r in runs]
    micro_cycles = [r.get("cycles", {}).get("microbench", 0) for r in runs]

    run_rows: list[str] = []
    detail_sections: list[str] = []

    for run in reversed(runs):
        run_id = run.get("run_id", "?")
        display_name = run.get("display_name") or run_id
        run_dir = Path(run.get("run_dir", profile_root / run_id))
        if not run_dir.is_dir():
            run_dir = profile_root / run_id
        compare = compare_with_baseline(script_dir, baseline_dir, run_dir)
        status = compare["status"] if compare else "n/a"
        status_class = {"pass": "ok", "warn": "warn", "fail": "fail"}.get(status, "na")

        failures = compare.get("failures", []) if compare else []
        warnings = compare.get("warnings", []) if compare else []
        alerts = failures + warnings
        alert_html = "<br>".join(html.escape(a) for a in alerts) if alerts else "-"

        run_label = display_name if display_name == run_id else f"{display_name} ({run_id})"
        ipc_cells = "".join(
            f"<td>{run.get('ipc', {}).get(bench, 0):.4f}</td>" for bench in BENCHMARKS
        )
        run_rows.append(
            f"<tr><td>{html.escape(run_label)}</td>"
            f"<td>{html.escape(str(run.get('git_sha') or '-'))}</td>"
            f"<td>{html.escape(str(run.get('created_at') or '-'))}</td>"
            f"<td class='{status_class}'>{html.escape(status)}</td>"
            f"{ipc_cells}"
            f"<td>{alert_html}</td></tr>"
        )

        summary_path = resolve_summary_path(profile_root, run)
        if summary_path is None:
            continue
        report_path = summary_path.parent / "summary.html"
        report_href = href_from_dashboard(profile_root, report_path)
        summary = load_summary(summary_path)
        bench_blocks: list[str] = []
        for bench in BENCHMARKS:
            if bench not in summary:
                continue
            b = summary[bench]
            stall_total = bench_stall_total(b) or 1
            top_stalls = top_stall_categories(b, limit=3)
            stall_lines = [
                f"{key}: {fmt_part_total(int(val), stall_total)} ({pct:.1f}%)"
                for key, val, pct in top_stalls
            ]
            decode_detail = bench_stall_detail(b, "decode_blocked")
            decode_total = bench_stall_section_total(b, "decode_blocked") or sum(
                float(v) for v in decode_detail.values()
            ) or 1
            decode_top = sorted(decode_detail.items(), key=lambda kv: float(kv[1]), reverse=True)[:2]
            decode_line = ", ".join(
                f"{k}={fmt_part_total(v, decode_total)}" for k, v in decode_top
            ) if decode_top else "-"
            predict = bench_predict(b)
            miss_line, acc_line = format_predict_dashboard_lines(predict)
            bench_blocks.append(
                f"<div class='bench-block'><h4>{html.escape(bench)}</h4>"
                f"<p><b>KPI:</b> IPC={bench_ipc(b):.4f} CPI={bench_cpi(b):.4f} "
                f"cycles={bench_cycles(b)} commits={bench_commits(b)}</p>"
                f"<p><b>Top stall:</b> {html.escape(' | '.join(stall_lines) or '-')}</p>"
                f"<p><b>Decode blocked top:</b> {html.escape(decode_line)}</p>"
                f"<p><b>Predict miss:</b> {html.escape(miss_line)}</p>"
                f"<p><b>Direction acc (commit):</b> {html.escape(acc_line)}</p></div>"
            )
        detail_sections.append(
            f"<section class='detail'><h3>{html.escape(run_label)}</h3>"
            f"{''.join(bench_blocks)}"
            f"<p><a href='{html.escape(report_href)}'>查看完整报告 →</a></p>"
            f"</section>"
        )

    template_path = script_dir / "dashboard_template.html"
    template = template_path.read_text(encoding="utf-8")
    return (
        template.replace("{{PROFILE_ROOT}}", html.escape(profile_root_label(profile_root, npc_home)))
        .replace("{{RUN_COUNT}}", str(len(runs)))
        .replace("{{BASELINE_ID}}", html.escape(baseline_id))
        .replace("{{LABELS_JSON}}", json.dumps(labels))
        .replace("{{CORE_IPC_JSON}}", json.dumps(core_ipc))
        .replace("{{MICRO_IPC_JSON}}", json.dumps(micro_ipc))
        .replace("{{CORE_CYCLES_JSON}}", json.dumps(core_cycles))
        .replace("{{MICRO_CYCLES_JSON}}", json.dumps(micro_cycles))
        .replace("{{RUN_TABLE_ROWS}}", "\n".join(run_rows))
        .replace("{{DETAIL_SECTIONS}}", "\n".join(detail_sections))
    )


def write_all_summary_pages(profile_root: Path, index: dict) -> None:
    for run in index.get("runs", []):
        run_id = run.get("run_id", "?")
        summary_path = resolve_summary_path(profile_root, run)
        if summary_path is None:
            continue
        report_path = write_summary_html_for_run(summary_path.parent, run_id)
        if report_path is not None:
            print(f"[dashboard] wrote {report_path}")


def main() -> int:
    ap = argparse.ArgumentParser(description="Build static profile dashboard HTML")
    ap.add_argument("--profile-root", default=None)
    ap.add_argument("--out", default=None)
    args = ap.parse_args()

    script_dir = Path(__file__).resolve().parent
    npc_home = script_dir.parent.parent
    profile_root = Path(args.profile_root) if args.profile_root else npc_home / "profile"
    out_dir = profile_root / "dashboard"
    out_path = Path(args.out) if args.out else out_dir / "index.html"

    index_path = profile_root / "index.json"
    if index_path.exists():
        index = json.loads(index_path.read_text(encoding="utf-8"))
    else:
        index = {"runs": []}
    write_all_summary_pages(profile_root, index)

    html_doc = render_dashboard(profile_root, script_dir)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(html_doc, encoding="utf-8")
    print(f"[dashboard] wrote {out_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
