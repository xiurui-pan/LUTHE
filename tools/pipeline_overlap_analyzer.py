#!/usr/bin/env python3
import argparse
import json
import math
from pathlib import Path
from typing import Dict, Iterable, List, Tuple


def _parse_line(line: str) -> Dict[str, str]:
    parts = line.strip().split()
    if not parts:
        return {}
    if parts[0].startswith("#"):
        return {}
    out: Dict[str, str] = {}
    for part in parts:
        if "=" not in part:
            continue
        key, val = part.split("=", 1)
        out[key.strip()] = val.strip()
    return out


def _to_int(value: str) -> int:
    if value.startswith("0x"):
        return int(value, 16)
    return int(value)


def _percentile(values: List[float], p: float) -> float:
    if not values:
        return float("nan")
    values = sorted(values)
    if len(values) == 1:
        return float(values[0])
    k = (len(values) - 1) * (p / 100.0)
    f = math.floor(k)
    c = math.ceil(k)
    if f == c:
        return float(values[int(k)])
    d0 = values[f] * (c - k)
    d1 = values[c] * (k - f)
    return float(d0 + d1)


def _stats(values: List[int]) -> Dict[str, float]:
    vals = [v for v in values if v >= 0]
    if not vals:
        return {"count": 0, "p50": float("nan"), "p95": float("nan"), "mean": float("nan")}
    return {
        "count": len(vals),
        "p50": _percentile([float(v) for v in vals], 50.0),
        "p95": _percentile([float(v) for v in vals], 95.0),
        "mean": float(sum(vals)) / float(len(vals)),
    }


def _load_records(paths: Iterable[Path]) -> List[Dict[str, int]]:
    records: List[Dict[str, int]] = []
    for path in paths:
        if not path.exists():
            continue
        for raw in path.read_text().splitlines():
            parsed = _parse_line(raw)
            if not parsed:
                continue
            try:
                record = {
                    "cmd_id": _to_int(parsed.get("cmd_id", "0")),
                    "mode": _to_int(parsed.get("mode", "0")),
                    "flags": _to_int(parsed.get("flags", "0")),
                    "tlwe_bytes": _to_int(parsed.get("tlwe_bytes", "0")),
                    "glwe_bytes": _to_int(parsed.get("glwe_bytes", "0")),
                    "io_in_ns": _to_int(parsed.get("io_in_ns", "-1")),
                    "compute_ns": _to_int(parsed.get("compute_ns", "-1")),
                    "io_out_ns": _to_int(parsed.get("io_out_ns", "-1")),
                    "total_ns": _to_int(parsed.get("total_ns", "-1")),
                    "error": _to_int(parsed.get("error", "0")),
                }
            except Exception:
                continue
            records.append(record)
    return records


def _summarize(records: List[Dict[str, int]]) -> Dict[str, object]:
    io_in = [r["io_in_ns"] for r in records]
    compute = [r["compute_ns"] for r in records]
    io_out = [r["io_out_ns"] for r in records]
    total = [r["total_ns"] for r in records]
    overlap = [max(r["io_in_ns"], r["compute_ns"], r["io_out_ns"]) for r in records if r["error"] == 0]

    util = []
    idle = []
    for r in records:
        if r["total_ns"] > 0 and r["compute_ns"] >= 0:
            u = float(r["compute_ns"]) / float(r["total_ns"])
            util.append(u)
            idle.append(1.0 - u)

    summary = {
        "count": len(records),
        "errors": sum(1 for r in records if r["error"] != 0),
        "io_in_ns": _stats(io_in),
        "compute_ns": _stats(compute),
        "io_out_ns": _stats(io_out),
        "total_ns": _stats(total),
        "overlap_ns": _stats(overlap),
        "utilization": _stats([int(v * 1e6) for v in util]),
        "idle_ratio": _stats([int(v * 1e6) for v in idle]),
    }
    return summary


def _fmt_ms(ns: float) -> str:
    if math.isnan(ns):
        return "nan"
    return f"{ns / 1e6:.3f}"


def _write_text(out_path: Path, label: str, summary: Dict[str, object]) -> None:
    def _stat_line(name: str, stat: Dict[str, float]) -> str:
        return f"{name:>12s}: count={stat['count']:>6d} p50_ms={_fmt_ms(stat['p50'])} p95_ms={_fmt_ms(stat['p95'])} mean_ms={_fmt_ms(stat['mean'])}"

    lines = [
        f"[summary] {label}",
        f"count={summary['count']} errors={summary['errors']}",
        _stat_line("io_in", summary["io_in_ns"]),
        _stat_line("compute", summary["compute_ns"]),
        _stat_line("io_out", summary["io_out_ns"]),
        _stat_line("total", summary["total_ns"]),
        _stat_line("overlap", summary["overlap_ns"]),
        _stat_line("utilization", summary["utilization"]),
        _stat_line("idle_ratio", summary["idle_ratio"]),
    ]
    out_path.write_text("\n".join(lines) + "\n")


def _append_csv(out_path: Path, label: str, summary: Dict[str, object]) -> None:
    header = (
        "label,count,errors,"
        "io_in_p50_ms,io_in_p95_ms,compute_p50_ms,compute_p95_ms,io_out_p50_ms,io_out_p95_ms,"
        "overlap_p50_ms,overlap_p95_ms,total_p50_ms,total_p95_ms,"
        "util_p50,util_p95,idle_p50,idle_p95\n"
    )
    if not out_path.exists():
        out_path.write_text(header)
    def _p50(stat: Dict[str, float]) -> float:
        return stat["p50"] / 1e6 if not math.isnan(stat["p50"]) else float("nan")
    def _p95(stat: Dict[str, float]) -> float:
        return stat["p95"] / 1e6 if not math.isnan(stat["p95"]) else float("nan")

    util_p50 = summary["utilization"]["p50"] / 1e6 if not math.isnan(summary["utilization"]["p50"]) else float("nan")
    util_p95 = summary["utilization"]["p95"] / 1e6 if not math.isnan(summary["utilization"]["p95"]) else float("nan")
    idle_p50 = summary["idle_ratio"]["p50"] / 1e6 if not math.isnan(summary["idle_ratio"]["p50"]) else float("nan")
    idle_p95 = summary["idle_ratio"]["p95"] / 1e6 if not math.isnan(summary["idle_ratio"]["p95"]) else float("nan")
    row = (
        f"{label},{summary['count']},{summary['errors']},"
        f"{_p50(summary['io_in_ns']):.6f},{_p95(summary['io_in_ns']):.6f},"
        f"{_p50(summary['compute_ns']):.6f},{_p95(summary['compute_ns']):.6f},"
        f"{_p50(summary['io_out_ns']):.6f},{_p95(summary['io_out_ns']):.6f},"
        f"{_p50(summary['overlap_ns']):.6f},{_p95(summary['overlap_ns']):.6f},"
        f"{_p50(summary['total_ns']):.6f},{_p95(summary['total_ns']):.6f},"
        f"{util_p50:.6f},{util_p95:.6f},{idle_p50:.6f},{idle_p95:.6f}\n"
    )
    with out_path.open("a", encoding="utf-8") as handle:
        handle.write(row)


def main() -> int:
    parser = argparse.ArgumentParser(description="Summarize pipeline overlap traces.")
    parser.add_argument("trace", nargs="+", help="pipeline_trace.log paths")
    parser.add_argument("--out", required=True, help="output directory")
    parser.add_argument("--label", default="", help="label for this summary")
    parser.add_argument("--csv", default="pipeline_summary.csv", help="CSV filename under --out")
    args = parser.parse_args()

    out_dir = Path(args.out).expanduser()
    out_dir.mkdir(parents=True, exist_ok=True)

    label = args.label.strip() or out_dir.name
    traces = [Path(p).expanduser() for p in args.trace]
    records = _load_records(traces)
    summary = _summarize(records)

    (out_dir / "pipeline_stats.json").write_text(json.dumps(summary, indent=2, sort_keys=True))
    _write_text(out_dir / "pipeline_stats.txt", label, summary)
    _append_csv(out_dir / args.csv, label, summary)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
