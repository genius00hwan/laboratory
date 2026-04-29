#!/usr/bin/env python3

from __future__ import annotations

import argparse
import csv
import json
import math
import statistics
import subprocess
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
PIPELINE_BINARY = PROJECT_ROOT / "build-local" / "custom_event_pipeline"
LOAD_FACTORS = {"near_sat": 0.9, "overload": 1.2}
CSV_FIELDS = [
    "track",
    "case",
    "variant",
    "topology",
    "shared_queue",
    "dispatch_queue",
    "policy",
    "wait_strategy",
    "load",
    "run_index",
    "rate",
    "duration_ms",
    "warmup_ms",
    "ingress_threads",
    "worker_threads",
    "ingress_queue_capacity",
    "worker_queue_capacity",
    "service_ns",
    "jitter_ns",
    "tps_completed",
    "avg_us",
    "p95_us",
    "p99_us",
    "generated",
    "accepted",
    "completed",
    "dropped",
    "dropped_ingress",
    "dropped_dispatch",
    "worker_completed_min",
    "worker_completed_max",
    "worker_completed_avg",
    "worker_completed_stddev",
    "worker_imbalance_pct",
    "ingress_push_attempts",
    "ingress_push_success",
    "ingress_push_fail",
    "ingress_pop_success",
    "ingress_spin_count",
    "ingress_yield_count",
    "ingress_park_count",
    "ingress_full_hits",
    "ingress_empty_hits",
    "ingress_max_observed_depth",
    "worker_push_attempts",
    "worker_push_success",
    "worker_push_fail",
    "worker_pop_success",
    "worker_spin_count",
    "worker_yield_count",
    "worker_park_count",
    "worker_full_hits",
    "worker_empty_hits",
    "worker_max_observed_depth",
    "samples",
]


@dataclass(frozen=True)
class Phase4Case:
    track: str
    case: str
    variant: str
    topology: str
    shared_queue: str
    dispatch_queue: str
    policy: str
    load: str
    wait_strategy: str
    ingress_threads: int
    worker_threads: int
    ingress_queue_capacity: int
    worker_queue_capacity: int
    service_ns: int
    jitter_ns: int


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run the reduced Phase 4 benchmark matrix.")
    parser.add_argument("--track", choices=("shared", "local", "strategy", "all"), default="all")
    parser.add_argument("--output-dir", help="Directory for outputs.")
    parser.add_argument("--pipeline-binary", default=str(PIPELINE_BINARY))
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--duration-ms", type=int, default=2000)
    parser.add_argument("--warmup-ms", type=int, default=300)
    parser.add_argument("--peak-runs", type=int, default=2)
    parser.add_argument("--shared-finalist", choices=("split_lock", "mpmc_ring"), default="split_lock")
    parser.add_argument(
        "--local-finalist",
        choices=("dispatch_local_spsc", "direct_local_spsc"),
        default="direct_local_spsc",
    )
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--smoke", action="store_true")
    return parser.parse_args()


def output_dir(explicit: str | None) -> Path:
    if explicit:
        return Path(explicit).resolve()
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    return PROJECT_ROOT / "out" / "phase4" / timestamp


def parse_value(raw: str):
    try:
        if any(ch in raw for ch in (".", "e", "E")):
            return float(raw)
        return int(raw)
    except ValueError:
        return raw


def parse_metrics(stdout: str) -> dict[str, object]:
    result: dict[str, object] = {}
    for line in stdout.strip().splitlines():
        for token in line.strip().split():
            if "=" not in token:
                continue
            key, value = token.split("=", 1)
            result[key] = parse_value(value)
    return result


def run_cmd(cmd: list[str], dry_run: bool) -> dict[str, object]:
    if dry_run:
        print(" ".join(cmd))
        return {}
    completed = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if completed.returncode != 0:
        raise RuntimeError(
            f"command failed\ncmd={' '.join(cmd)}\nstdout:\n{completed.stdout}\nstderr:\n{completed.stderr}"
        )
    return parse_metrics(completed.stdout)


def median(values: list[float]) -> float:
    return float(statistics.median(values))


def floor_to_1000(value: float) -> float:
    floored = math.floor(value / 1000.0) * 1000.0
    return max(floored, 1000.0)


def build_pipeline_cmd(binary: Path, case: Phase4Case, duration_ms: int, warmup_ms: int, rate: float) -> list[str]:
    return [
        str(binary),
        "--topology",
        case.topology,
        "--shared-queue",
        case.shared_queue,
        "--dispatch-queue",
        case.dispatch_queue,
        "--ingress",
        str(case.ingress_threads),
        "--workers",
        str(case.worker_threads),
        "--duration-ms",
        str(duration_ms),
        "--warmup-ms",
        str(warmup_ms),
        "--capacity",
        str(case.ingress_queue_capacity),
        "--worker-capacity",
        str(case.worker_queue_capacity),
        "--rate",
        f"{rate:.2f}",
        "--policy",
        case.policy,
        "--wait-strategy",
        case.wait_strategy,
        "--service-ns",
        str(case.service_ns),
        "--jitter-ns",
        str(case.jitter_ns),
    ]


def calibration_case(variant: str) -> Phase4Case:
    if variant == "shared_split_lock":
        return Phase4Case(
            track="shared",
            case="calibration_peak",
            variant=variant,
            topology="shared",
            shared_queue="split_lock",
            dispatch_queue="split_lock",
            policy="drop",
            load="peak",
            wait_strategy="default",
            ingress_threads=4,
            worker_threads=4,
            ingress_queue_capacity=256,
            worker_queue_capacity=64,
            service_ns=0,
            jitter_ns=0,
        )
    if variant == "shared_mpmc_ring":
        return Phase4Case(
            track="shared",
            case="calibration_peak",
            variant=variant,
            topology="shared",
            shared_queue="mpmc_ring",
            dispatch_queue="mpmc_ring",
            policy="drop",
            load="peak",
            wait_strategy="default",
            ingress_threads=4,
            worker_threads=4,
            ingress_queue_capacity=256,
            worker_queue_capacity=64,
            service_ns=0,
            jitter_ns=0,
        )
    if variant == "dispatch_local_spsc":
        return Phase4Case(
            track="local",
            case="calibration_peak",
            variant=variant,
            topology="dispatch_local_spsc",
            shared_queue="split_lock",
            dispatch_queue="split_lock",
            policy="drop",
            load="peak",
            wait_strategy="default",
            ingress_threads=4,
            worker_threads=4,
            ingress_queue_capacity=256,
            worker_queue_capacity=64,
            service_ns=0,
            jitter_ns=0,
        )
    if variant == "direct_local_spsc":
        return Phase4Case(
            track="local",
            case="calibration_peak",
            variant=variant,
            topology="direct_local_spsc",
            shared_queue="split_lock",
            dispatch_queue="split_lock",
            policy="drop",
            load="peak",
            wait_strategy="default",
            ingress_threads=4,
            worker_threads=4,
            ingress_queue_capacity=256,
            worker_queue_capacity=64,
            service_ns=0,
            jitter_ns=0,
        )
    raise ValueError(f"unknown calibration variant: {variant}")


def calibrate_rate(binary: Path, variants: list[str], duration_ms: int, warmup_ms: int, peak_runs: int, dry_run: bool) -> float:
    peaks: list[float] = []
    for variant in variants:
        case = calibration_case(variant)
        samples: list[float] = []
        for _ in range(peak_runs):
            metrics = run_cmd(build_pipeline_cmd(binary, case, duration_ms, warmup_ms, 0.0), dry_run)
            if not dry_run:
                samples.append(float(metrics["tps_completed"]))
        if not dry_run:
            peaks.append(median(samples))
    return 0.0 if dry_run else floor_to_1000(0.7 * min(peaks))


def shared_cases() -> list[Phase4Case]:
    cases: list[Phase4Case] = []
    for queue, variant in (("split_lock", "shared_split_lock"), ("mpmc_ring", "shared_mpmc_ring")):
        cases.append(
            Phase4Case(
                track="shared",
                case="block_near_sat",
                variant=variant,
                topology="shared",
                shared_queue=queue,
                dispatch_queue=queue,
                policy="block",
                load="near_sat",
                wait_strategy="default",
                ingress_threads=4,
                worker_threads=4,
                ingress_queue_capacity=256,
                worker_queue_capacity=64,
                service_ns=10_000,
                jitter_ns=0,
            )
        )
        cases.append(
            Phase4Case(
                track="shared",
                case="overload_drop",
                variant=variant,
                topology="shared",
                shared_queue=queue,
                dispatch_queue=queue,
                policy="drop",
                load="overload",
                wait_strategy="default",
                ingress_threads=4,
                worker_threads=4,
                ingress_queue_capacity=256,
                worker_queue_capacity=64,
                service_ns=10_000,
                jitter_ns=10_000,
            )
        )
    return cases


def local_cases() -> list[Phase4Case]:
    cases: list[Phase4Case] = []
    for topology in ("dispatch_local_spsc", "direct_local_spsc"):
        cases.append(
            Phase4Case(
                track="local",
                case="block_near_sat",
                variant=topology,
                topology=topology,
                shared_queue="split_lock",
                dispatch_queue="split_lock",
                policy="block",
                load="near_sat",
                wait_strategy="default",
                ingress_threads=4,
                worker_threads=4,
                ingress_queue_capacity=256,
                worker_queue_capacity=64,
                service_ns=10_000,
                jitter_ns=0,
            )
        )
        cases.append(
            Phase4Case(
                track="local",
                case="overload_drop",
                variant=topology,
                topology=topology,
                shared_queue="split_lock",
                dispatch_queue="split_lock",
                policy="drop",
                load="overload",
                wait_strategy="default",
                ingress_threads=4,
                worker_threads=4,
                ingress_queue_capacity=256,
                worker_queue_capacity=64,
                service_ns=10_000,
                jitter_ns=10_000,
            )
        )
    return cases


def strategy_cases(shared_finalist: str, local_finalist: str) -> list[Phase4Case]:
    shared_variant = f"shared_{shared_finalist}"
    shared_queue = shared_finalist
    local_topology = local_finalist
    return [
        Phase4Case(
            track="strategy",
            case="block_near_sat",
            variant=shared_variant,
            topology="shared",
            shared_queue=shared_queue,
            dispatch_queue=shared_queue,
            policy="block",
            load="near_sat",
            wait_strategy="default",
            ingress_threads=4,
            worker_threads=4,
            ingress_queue_capacity=256,
            worker_queue_capacity=64,
            service_ns=10_000,
            jitter_ns=0,
        ),
        Phase4Case(
            track="strategy",
            case="block_near_sat",
            variant=local_topology,
            topology=local_topology,
            shared_queue="split_lock",
            dispatch_queue="split_lock",
            policy="block",
            load="near_sat",
            wait_strategy="default",
            ingress_threads=4,
            worker_threads=4,
            ingress_queue_capacity=256,
            worker_queue_capacity=64,
            service_ns=10_000,
            jitter_ns=0,
        ),
        Phase4Case(
            track="strategy",
            case="overload_drop",
            variant=shared_variant,
            topology="shared",
            shared_queue=shared_queue,
            dispatch_queue=shared_queue,
            policy="drop",
            load="overload",
            wait_strategy="default",
            ingress_threads=4,
            worker_threads=4,
            ingress_queue_capacity=256,
            worker_queue_capacity=64,
            service_ns=10_000,
            jitter_ns=10_000,
        ),
        Phase4Case(
            track="strategy",
            case="overload_drop",
            variant=local_topology,
            topology=local_topology,
            shared_queue="split_lock",
            dispatch_queue="split_lock",
            policy="drop",
            load="overload",
            wait_strategy="default",
            ingress_threads=4,
            worker_threads=4,
            ingress_queue_capacity=256,
            worker_queue_capacity=64,
            service_ns=10_000,
            jitter_ns=10_000,
        ),
    ]


def case_rate(base_rate: float, case: Phase4Case) -> float:
    if case.load == "peak":
        return 0.0
    return base_rate * LOAD_FACTORS[case.load]


def write_csv(path: Path, records: list[dict[str, object]]) -> None:
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=CSV_FIELDS)
        writer.writeheader()
        for record in records:
            writer.writerow({field: record.get(field, "") for field in CSV_FIELDS})


def write_manifest(path: Path, manifest: dict[str, object]) -> None:
    path.write_text(json.dumps(manifest, indent=2), encoding="utf-8")


def write_summary(path: Path, records: list[dict[str, object]], tracks: list[str], manifest: dict[str, object]) -> None:
    lines: list[str] = []
    lines.append("# Phase 4 Reduced Matrix")
    lines.append("")
    lines.append("핵심 해석 규칙:")
    lines.append("- shared family는 `shared_split_lock` vs `shared_mpmc_ring`만 본다")
    lines.append("- local family는 `dispatch_local_spsc` vs `direct_local_spsc`만 본다")
    lines.append("- `spsc`는 primitive 이름으로 읽지 않고 topology 이름으로만 읽는다")
    lines.append("- strategy track은 finalist 비교이며, family winner 확정 전에는 잠정 비교다")
    lines.append("- `direct_local_spsc`의 high fan-in direct route matrix는 아직 미구현이다")
    lines.append("")
    lines.append("선택된 finalist:")
    lines.append(f"- shared finalist: `{manifest['shared_finalist']}`")
    lines.append(f"- local finalist: `{manifest['local_finalist']}`")
    lines.append("")

    for track in tracks:
        track_rows = [row for row in records if row["track"] == track]
        lines.append(f"## {track}")
        lines.append("")
        if not track_rows:
            lines.append("실행 데이터 없음")
            lines.append("")
            continue
        lines.append("| case | variant | policy | load | tps_completed | p99_us | dropped | imbalance_pct |")
        lines.append("| --- | --- | --- | --- | ---: | ---: | ---: | ---: |")
        for row in track_rows:
            lines.append(
                f"| {row['case']} | {row['variant']} | {row['policy']} | {row['load']} | "
                f"{row.get('tps_completed', 0)} | {row.get('p99_us', 0)} | "
                f"{row.get('dropped', 0)} | {row.get('worker_imbalance_pct', 0)} |"
            )
        lines.append("")

    path.write_text("\n".join(lines), encoding="utf-8")


def main() -> int:
    args = parse_args()

    pipeline_binary = Path(args.pipeline_binary).resolve()
    if not pipeline_binary.exists():
        raise SystemExit(f"pipeline binary not found: {pipeline_binary}")

    duration_ms = 500 if args.smoke else args.duration_ms
    warmup_ms = 0 if args.smoke else args.warmup_ms
    peak_runs = 1 if args.smoke else args.peak_runs
    runs = 1 if args.smoke else args.runs

    tracks = ["shared", "local", "strategy"] if args.track == "all" else [args.track]
    out_dir = output_dir(args.output_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    shared_base_rate = calibrate_rate(
        pipeline_binary,
        ["shared_split_lock", "shared_mpmc_ring"],
        duration_ms,
        warmup_ms,
        peak_runs,
        args.dry_run,
    )
    local_base_rate = calibrate_rate(
        pipeline_binary,
        ["dispatch_local_spsc", "direct_local_spsc"],
        duration_ms,
        warmup_ms,
        peak_runs,
        args.dry_run,
    )
    strategy_base_rate = 0.0 if args.dry_run else min(shared_base_rate, local_base_rate)

    manifest: dict[str, object] = {
        "tracks": tracks,
        "pipeline_binary": str(pipeline_binary),
        "shared_finalist": args.shared_finalist,
        "local_finalist": args.local_finalist,
        "shared_base_rate": shared_base_rate,
        "local_base_rate": local_base_rate,
        "strategy_base_rate": strategy_base_rate,
        "interpretation_guards": [
            "GlobalLockQueue is historical only and removed from the core Phase 4 matrix.",
            "SpscRingQueue appears only inside named local topologies.",
            "Shared family and local family must be read separately before strategy comparison.",
            "direct_local_spsc currently models fixed ingress-to-worker affinity, not a full route matrix.",
        ],
    }

    records: list[dict[str, object]] = []
    case_lists: dict[str, list[Phase4Case]] = {
        "shared": shared_cases(),
        "local": local_cases(),
        "strategy": strategy_cases(args.shared_finalist, args.local_finalist),
    }
    base_rates = {
        "shared": shared_base_rate,
        "local": local_base_rate,
        "strategy": strategy_base_rate,
    }

    for track in tracks:
        for case in case_lists[track]:
            rate = case_rate(base_rates[track], case)
            for run_index in range(1, runs + 1):
                metrics = run_cmd(build_pipeline_cmd(pipeline_binary, case, duration_ms, warmup_ms, rate), args.dry_run)
                record = {
                    "track": track,
                    "case": case.case,
                    "variant": case.variant,
                    "topology": case.topology,
                    "shared_queue": case.shared_queue,
                    "dispatch_queue": case.dispatch_queue,
                    "policy": case.policy,
                    "wait_strategy": case.wait_strategy,
                    "load": case.load,
                    "run_index": run_index,
                    "rate": rate,
                    "duration_ms": duration_ms,
                    "warmup_ms": warmup_ms,
                    "ingress_threads": case.ingress_threads,
                    "worker_threads": case.worker_threads,
                    "ingress_queue_capacity": case.ingress_queue_capacity,
                    "worker_queue_capacity": case.worker_queue_capacity,
                    "service_ns": case.service_ns,
                    "jitter_ns": case.jitter_ns,
                    **metrics,
                }
                records.append(record)

    write_csv(out_dir / "raw_results.csv", records)
    write_manifest(out_dir / "manifest.json", manifest)
    write_summary(out_dir / "summary.md", records, tracks, manifest)
    print(out_dir)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
