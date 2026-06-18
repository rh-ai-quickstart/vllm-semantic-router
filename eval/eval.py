#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12"
# dependencies = [
#   "httpx>=0.27",
#   "pydantic>=2.0",
#   "pyyaml>=6.0",
#   "tabulate>=0.9",
# ]
# ///
"""Evaluate semantic router routing accuracy against a live deployment.

Sends each query to the SR's built-in HTTP listener and reads the
x-vsr-selected-decision response header to determine the routing outcome.
"""

from __future__ import annotations

import argparse
import json
import statistics
import sys
import time
from pathlib import Path

import httpx
import yaml
from pydantic import BaseModel
from tabulate import tabulate


# ── Schemas ──────────────────────────────────────────────────────────────────

class EvalCase(BaseModel):
    id: str
    input: str
    expected_decision: str
    description: str | None = None


class EvalResult(BaseModel):
    case_id: str
    input: str
    expected_decision: str
    predicted_decision: str | None
    predicted_model: str | None
    confidence: float | None
    matched_signals: dict[str, list[str]] | None
    latency_ms: float
    correct: bool
    error: str | None = None


class ClassMetrics(BaseModel):
    precision: float
    recall: float
    f1: float
    support: int


class EvalReport(BaseModel):
    timestamp: str
    router_url: str
    dataset_path: str
    total_cases: int
    correct: int
    accuracy: float
    per_decision: dict[str, ClassMetrics]
    confusion_matrix: dict[str, dict[str, int]]
    latency_p50_ms: float
    latency_p95_ms: float
    latency_p99_ms: float
    results: list[EvalResult]


# ── Dataset ──────────────────────────────────────────────────────────────────

def load_dataset(path: Path) -> list[EvalCase]:
    with open(path) as f:
        data = yaml.safe_load(f)
    if not data or "cases" not in data:
        print(f"Error: {path} must contain a top-level 'cases' list.", file=sys.stderr)
        sys.exit(1)
    return [EvalCase(**c) for c in data["cases"]]


# ── Evaluation ───────────────────────────────────────────────────────────────

def parse_matched_signals(headers: httpx.Headers) -> dict[str, list[str]] | None:
    """Extract matched signals from x-vsr-matched-* response headers."""
    signals: dict[str, list[str]] = {}
    for key, value in headers.items():
        if key.startswith("x-vsr-matched-") and value:
            signal_type = key.removeprefix("x-vsr-matched-")
            signals[signal_type] = [v.strip() for v in value.split(",")]
    return signals or None


def evaluate_case(client: httpx.Client, router_url: str, case: EvalCase) -> EvalResult:
    start = time.perf_counter()
    try:
        resp = client.post(
            f"{router_url}/v1/chat/completions",
            json={
                "model": "auto",
                "messages": [{"role": "user", "content": case.input}],
                "max_tokens": 1,
                "stream": False,
            },
        )
        resp.raise_for_status()
    except httpx.HTTPStatusError as exc:
        elapsed = (time.perf_counter() - start) * 1000
        return EvalResult(
            case_id=case.id, input=case.input,
            expected_decision=case.expected_decision,
            predicted_decision="blocked" if exc.response.status_code in (403, 503) else None,
            predicted_model=None, confidence=None, matched_signals=None,
            latency_ms=elapsed, correct=(case.expected_decision == "blocked"),
            error=f"HTTP {exc.response.status_code}",
        )
    except httpx.RequestError as exc:
        elapsed = (time.perf_counter() - start) * 1000
        return EvalResult(
            case_id=case.id, input=case.input,
            expected_decision=case.expected_decision,
            predicted_decision=None, predicted_model=None,
            confidence=None, matched_signals=None,
            latency_ms=elapsed, correct=False, error=str(exc),
        )

    elapsed = (time.perf_counter() - start) * 1000

    predicted_decision = resp.headers.get("x-vsr-selected-decision")
    predicted_model = resp.headers.get("x-vsr-selected-model")
    confidence_str = resp.headers.get("x-vsr-selected-confidence")
    confidence = float(confidence_str) if confidence_str else None
    matched_signals = parse_matched_signals(resp.headers)

    return EvalResult(
        case_id=case.id,
        input=case.input,
        expected_decision=case.expected_decision,
        predicted_decision=predicted_decision,
        predicted_model=predicted_model,
        confidence=confidence,
        matched_signals=matched_signals,
        latency_ms=elapsed,
        correct=(predicted_decision == case.expected_decision),
    )


# ── Metrics ──────────────────────────────────────────────────────────────────

def compute_metrics(
    results: list[EvalResult], decisions: list[str]
) -> tuple[dict[str, ClassMetrics], dict[str, dict[str, int]]]:
    all_predictions = {r.predicted_decision or "(none)" for r in results}
    all_labels = sorted(set(decisions) | all_predictions)

    confusion: dict[str, dict[str, int]] = {
        exp: {pred: 0 for pred in all_labels} for exp in decisions
    }
    for r in results:
        exp = r.expected_decision
        pred = r.predicted_decision or "(none)"
        if exp in confusion:
            confusion[exp][pred] = confusion[exp].get(pred, 0) + 1

    per_decision: dict[str, ClassMetrics] = {}
    for decision in decisions:
        tp = confusion[decision].get(decision, 0)
        fp = sum(confusion[other].get(decision, 0) for other in decisions if other != decision)
        fn = sum(v for k, v in confusion[decision].items() if k != decision)
        support = sum(confusion[decision].values())

        precision = tp / (tp + fp) if (tp + fp) > 0 else 0.0
        recall = tp / (tp + fn) if (tp + fn) > 0 else 0.0
        f1 = (2 * precision * recall / (precision + recall)) if (precision + recall) > 0 else 0.0

        per_decision[decision] = ClassMetrics(
            precision=round(precision, 4),
            recall=round(recall, 4),
            f1=round(f1, 4),
            support=support,
        )

    return per_decision, confusion


def latency_percentiles(results: list[EvalResult]) -> tuple[float, float, float]:
    latencies = sorted(r.latency_ms for r in results)
    if not latencies:
        return 0.0, 0.0, 0.0
    p50 = statistics.median(latencies)
    quantiles = statistics.quantiles(latencies, n=100, method="inclusive")
    p95 = quantiles[94] if len(quantiles) > 94 else latencies[-1]
    p99 = quantiles[98] if len(quantiles) > 98 else latencies[-1]
    return round(p50, 1), round(p95, 1), round(p99, 1)


# ── Reporting ────────────────────────────────────────────────────────────────

def print_report(report: EvalReport) -> None:
    decisions = list(report.per_decision.keys())

    print()
    print("=" * 60)
    print("  Semantic Router Evaluation Report")
    print("=" * 60)
    print()

    print(f"  Accuracy: {report.correct}/{report.total_cases} ({report.accuracy:.1%})")
    print(f"  Latency:  p50={report.latency_p50_ms:.0f}ms  p95={report.latency_p95_ms:.0f}ms  p99={report.latency_p99_ms:.0f}ms")
    print()

    rows = []
    for d in decisions:
        m = report.per_decision[d]
        rows.append([d, f"{m.precision:.2f}", f"{m.recall:.2f}", f"{m.f1:.2f}", m.support])
    print(tabulate(
        rows,
        headers=["Decision", "Precision", "Recall", "F1", "Support"],
        tablefmt="simple_outline",
    ))
    print()

    cm_labels = sorted(
        set(decisions)
        | {pred for row in report.confusion_matrix.values() for pred, cnt in row.items() if cnt > 0}
    )
    header = ["expected \\ predicted"] + cm_labels
    cm_rows = []
    for exp in decisions:
        row = [exp] + [report.confusion_matrix[exp].get(pred, 0) for pred in cm_labels]
        cm_rows.append(row)
    print(tabulate(cm_rows, headers=header, tablefmt="simple_outline"))
    print()

    errors = [r for r in report.results if not r.correct]
    if errors:
        print(f"  Misclassified ({len(errors)}):")
        for r in errors:
            model_info = f"  model={r.predicted_model}" if r.predicted_model else ""
            print(f"    [{r.case_id}] expected={r.expected_decision}  predicted={r.predicted_decision}{model_info}")
            print(f"      query: {r.input[:80]}{'...' if len(r.input) > 80 else ''}")
            if r.error:
                print(f"      error: {r.error}")
        print()

    print("=" * 60)
    print()


def save_json(report: EvalReport, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w") as f:
        json.dump(report.model_dump(), f, indent=2)
    print(f"  Results saved to: {path}")
    print()


# ── Main ─────────────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(description="Evaluate semantic router routing accuracy")
    parser.add_argument("--url", default="http://localhost:8899", help="SR built-in listener URL (default: http://localhost:8899)")
    parser.add_argument("--dataset", default=None, help="Path to dataset YAML (default: eval/dataset.yaml next to this script)")
    parser.add_argument("--output", default=None, help="Path for JSON results (default: eval/results.json next to this script)")
    parser.add_argument("--pass-threshold", type=float, default=0.8, help="Minimum accuracy to exit 0 (default: 0.8)")
    args = parser.parse_args()

    script_dir = Path(__file__).resolve().parent
    dataset_path = Path(args.dataset) if args.dataset else script_dir / "dataset.yaml"
    output_path = Path(args.output) if args.output else script_dir / "results.json"

    cases = load_dataset(dataset_path)
    decisions = sorted({c.expected_decision for c in cases})

    print(f"\n  Evaluating {len(cases)} cases against {args.url}")
    print(f"  Decisions: {', '.join(decisions)}\n")

    client = httpx.Client(timeout=30.0)

    # Health check
    try:
        client.get(f"{args.url}/health", timeout=5.0)
    except httpx.RequestError:
        print(f"Error: cannot reach {args.url}/health — is the semantic router running?", file=sys.stderr)
        sys.exit(1)

    results: list[EvalResult] = []
    for i, case in enumerate(cases, 1):
        print(f"  [{i}/{len(cases)}] {case.id}", end="", flush=True)
        result = evaluate_case(client, args.url, case)
        mark = "ok" if result.correct else "FAIL"
        model_tag = f" [{result.predicted_model}]" if result.predicted_model else ""
        print(f"  ... {mark}{model_tag}  ({result.latency_ms:.0f}ms)")
        results.append(result)

    client.close()

    correct = sum(1 for r in results if r.correct)
    accuracy = correct / len(results) if results else 0.0
    per_decision, confusion = compute_metrics(results, decisions)
    p50, p95, p99 = latency_percentiles(results)

    report = EvalReport(
        timestamp=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        router_url=args.url,
        dataset_path=str(dataset_path),
        total_cases=len(results),
        correct=correct,
        accuracy=round(accuracy, 4),
        per_decision=per_decision,
        confusion_matrix=confusion,
        latency_p50_ms=p50,
        latency_p95_ms=p95,
        latency_p99_ms=p99,
        results=results,
    )

    print_report(report)
    save_json(report, output_path)

    sys.exit(0 if accuracy >= args.pass_threshold else 1)


if __name__ == "__main__":
    main()
