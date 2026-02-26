#!/usr/bin/env python3
import argparse
import math
import random
import struct
from pathlib import Path


def _read_fp64(path: Path, n: int) -> list[float]:
    data = path.read_bytes()
    if len(data) < n * 8:
        raise ValueError(f"{path}: file too short: {len(data)}B < {n*8}B")
    if len(data) % 8 != 0:
        raise ValueError(f"{path}: size not aligned to 8 bytes: {len(data)}B")
    fmt = "<" + ("d" * n)
    return list(struct.unpack(fmt, data[: n * 8]))


def _write_fp64(path: Path, values: list[float]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fmt = "<" + ("d" * len(values))
    path.write_bytes(struct.pack(fmt, *values))


def _softmax(values: list[float]) -> list[float]:
    if not values:
        return []
    max_val = max(values)
    exps = [math.exp(v - max_val) for v in values]
    s = sum(exps)
    return [e / s for e in exps]


def _quantize(values: list[float], frac_bits: int, mode: str) -> list[float]:
    if frac_bits <= 0:
        return values
    scale = 2**frac_bits
    if mode == "floor":
        return [math.floor(v * scale) / scale for v in values]
    return [round(v * scale) / scale for v in values]


def _parse_values(values_arg: str, n: int) -> list[float]:
    parts = values_arg.replace(",", " ").split()
    if len(parts) != n:
        raise ValueError(f"--values expects {n} numbers, got {len(parts)}")
    return [float(x) for x in parts]


def cmd_gen(args: argparse.Namespace) -> int:
    if args.values:
        inputs = _parse_values(args.values, args.n)
    else:
        rng = random.Random(args.seed)
        inputs = [rng.random() * 17.0 - 8.5 for _ in range(args.n)]
    refs = _softmax(inputs)
    _write_fp64(Path(args.out_input), inputs)
    _write_fp64(Path(args.out_ref), refs)

    print("[softmax] input:")
    print("  " + " ".join(f"{v:.8f}" for v in inputs))
    print("[softmax] ref:")
    print("  " + " ".join(f"{v:.8f}" for v in refs))
    return 0


def cmd_check(args: argparse.Namespace) -> int:
    inp_path = Path(args.input)
    out_path = Path(args.output)
    inputs = _read_fp64(inp_path, args.n)
    outputs = _read_fp64(out_path, args.n)
    refs = _softmax(inputs)
    ref_quant_frac_bits = int(args.ref_quant_frac_bits)
    ref_quant_mode = str(args.ref_quant_mode)
    if ref_quant_frac_bits > 0:
        refs = _quantize(refs, ref_quant_frac_bits, ref_quant_mode)
        print(
            "[softmax] ref_quant_frac_bits="
            f"{ref_quant_frac_bits} mode={ref_quant_mode} step={2**-ref_quant_frac_bits:.8e}"
        )

    head = int(args.print_head)
    if head < 0:
        head = 0
    if head > args.n:
        head = args.n
    if head > 0:
        print(f"[softmax] got(head={head}):")
        print("  " + " ".join(f"{v:.8f}" for v in outputs[:head]))
        print(f"[softmax] ref(head={head}):")
        print("  " + " ".join(f"{v:.8f}" for v in refs[:head]))

    eps_abs_1 = args.eps_abs_1
    eps_abs_2 = args.eps_abs_2
    eps_rel_1 = args.eps_rel_1
    eps_rel_2 = args.eps_rel_2

    max_abs = 0.0
    max_rel = 0.0
    warn = 0
    fail = 0
    for i in range(args.n):
        ref = refs[i]
        got = outputs[i]
        delta_abs = abs(ref - got)
        if abs(ref) > 1e-12:
            delta_rel = abs((ref - got) / ref)
        else:
            delta_rel = delta_abs
        max_abs = max(max_abs, delta_abs)
        max_rel = max(max_rel, delta_rel)

        if delta_abs > eps_abs_2 and delta_rel > eps_rel_2:
            print(
                f"[softmax][FAIL] i={i} ref={ref:.8f} got={got:.8f} "
                f"abs={delta_abs:.8e} rel={delta_rel:.8e}"
            )
            fail += 1
        elif delta_abs > eps_abs_1 and delta_rel > eps_rel_1:
            print(
                f"[softmax][WARN] i={i} ref={ref:.8f} got={got:.8f} "
                f"abs={delta_abs:.8e} rel={delta_rel:.8e}"
            )
            warn += 1

    print(
        f"[softmax] n={args.n} warn={warn} fail={fail} "
        f"max_abs={max_abs:.8e} max_rel={max_rel:.8e}"
    )
    return 0 if fail == 0 else 2


def main() -> int:
    parser = argparse.ArgumentParser(description="fp64 softmax IO helper (no numpy)")
    sub = parser.add_subparsers(dest="cmd", required=True)

    gen = sub.add_parser("gen", help="generate fp64 input + ref softmax")
    gen.add_argument("--n", type=int, default=16)
    gen.add_argument("--seed", type=int, default=0)
    gen.add_argument("--values", type=str, default="")
    gen.add_argument("--out-input", required=True)
    gen.add_argument("--out-ref", required=True)
    gen.set_defaults(func=cmd_gen)

    chk = sub.add_parser("check", help="check fp64 output against trivial softmax")
    chk.add_argument("--n", type=int, default=16)
    chk.add_argument("--input", required=True)
    chk.add_argument("--output", required=True)
    chk.add_argument("--eps-abs-1", type=float, default=1e-5)
    chk.add_argument("--eps-abs-2", type=float, default=1e-4)
    chk.add_argument("--eps-rel-1", type=float, default=1e-4)
    chk.add_argument("--eps-rel-2", type=float, default=5e-4)
    chk.add_argument(
        "--ref-quant-frac-bits",
        type=int,
        default=0,
        help="quantize reference softmax outputs to 2^-bits before compare",
    )
    chk.add_argument(
        "--ref-quant-mode",
        choices=("round", "floor"),
        default="round",
        help="quantization mode for reference softmax outputs",
    )
    chk.add_argument(
        "--print-head",
        type=int,
        default=4,
        help="print first K got/ref values for evidence (0 disables)",
    )
    chk.set_defaults(func=cmd_check)

    args = parser.parse_args()
    if args.n <= 0:
        raise ValueError("--n must be > 0")
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
