"""Unit tests for eval.py — pure logic only, no live SR required."""

from __future__ import annotations

import importlib.util
from pathlib import Path

import httpx
import pytest

# eval.py is a standalone script; load it by path to avoid shadowing the builtin.
_spec = importlib.util.spec_from_file_location(
    "_eval", Path(__file__).parent.parent / "eval.py"
)
_eval_module = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_eval_module)

EvalCase = _eval_module.EvalCase
EvalResult = _eval_module.EvalResult
compute_metrics = _eval_module.compute_metrics
latency_percentiles = _eval_module.latency_percentiles
parse_matched_signals = _eval_module.parse_matched_signals
load_dataset = _eval_module.load_dataset


def _result(
    case_id: str, expected: str, predicted: str | None, latency_ms: float = 100.0
) -> EvalResult:
    return EvalResult(
        case_id=case_id,
        input="test input",
        expected_decision=expected,
        predicted_decision=predicted,
        predicted_model=None,
        confidence=None,
        matched_signals=None,
        latency_ms=latency_ms,
        correct=(predicted == expected),
    )


class TestComputeMetrics:
    def test_perfect_accuracy(self):
        decisions = ["a", "b"]
        results = [_result("1", "a", "a"), _result("2", "b", "b")]
        per_decision, confusion = compute_metrics(results, decisions)
        assert per_decision["a"].precision == 1.0
        assert per_decision["a"].recall == 1.0
        assert per_decision["a"].f1 == 1.0
        assert confusion["a"]["a"] == 1
        assert confusion["b"]["b"] == 1

    def test_all_misclassified(self):
        decisions = ["a", "b"]
        results = [_result("1", "a", "b"), _result("2", "b", "a")]
        per_decision, confusion = compute_metrics(results, decisions)
        assert per_decision["a"].precision == 0.0
        assert per_decision["a"].recall == 0.0
        assert per_decision["b"].f1 == 0.0
        assert confusion["a"]["b"] == 1
        assert confusion["b"]["a"] == 1

    def test_none_prediction_tracked_as_none_label(self):
        decisions = ["a"]
        results = [_result("1", "a", None)]
        per_decision, confusion = compute_metrics(results, decisions)
        assert per_decision["a"].recall == 0.0
        assert confusion["a"].get("(none)", 0) == 1

    def test_zero_support_class_has_zero_precision(self):
        decisions = ["a", "b"]
        results = [_result("1", "a", "a")]
        per_decision, _ = compute_metrics(results, decisions)
        assert per_decision["b"].precision == 0.0
        assert per_decision["b"].support == 0

    def test_partial_accuracy(self):
        decisions = ["general", "research"]
        results = [
            _result("1", "general", "general"),
            _result("2", "research", "general"),
            _result("3", "research", "research"),
        ]
        per_decision, _ = compute_metrics(results, decisions)
        assert per_decision["research"].recall == pytest.approx(0.5, abs=0.01)


class TestLatencyPercentiles:
    def test_empty_results(self):
        p50, p95, p99 = latency_percentiles([])
        assert p50 == 0.0 and p95 == 0.0 and p99 == 0.0

    def test_single_result_returns_same_for_all_percentiles(self):
        results = [_result("1", "a", "a", latency_ms=250.0)]
        p50, p95, p99 = latency_percentiles(results)
        assert p50 == p95 == p99 == 250.0

    def test_percentiles_ordered(self):
        results = [
            _result(str(i), "a", "a", latency_ms=float(i * 10)) for i in range(1, 21)
        ]
        p50, p95, p99 = latency_percentiles(results)
        assert p50 <= p95 <= p99

    def test_uniform_latencies(self):
        results = [_result(str(i), "a", "a", latency_ms=100.0) for i in range(5)]
        p50, p95, p99 = latency_percentiles(results)
        assert p50 == 100.0 and p95 == 100.0 and p99 == 100.0


class TestParseMatchedSignals:
    def test_single_signal(self):
        headers = httpx.Headers([("x-vsr-matched-domain", "computer science")])
        result = parse_matched_signals(headers)
        assert result == {"domain": ["computer science"]}

    def test_multi_value_signal(self):
        headers = httpx.Headers([("x-vsr-matched-keyword", "openshift,kubernetes")])
        result = parse_matched_signals(headers)
        assert result["keyword"] == ["openshift", "kubernetes"]

    def test_empty_value_excluded(self):
        headers = httpx.Headers([("x-vsr-matched-domain", "")])
        result = parse_matched_signals(headers)
        assert result is None

    def test_non_signal_headers_ignored(self):
        headers = httpx.Headers(
            [("content-type", "application/json"), ("x-request-id", "abc")]
        )
        result = parse_matched_signals(headers)
        assert result is None

    def test_multiple_signal_types(self):
        headers = httpx.Headers(
            [
                ("x-vsr-matched-domain", "health"),
                ("x-vsr-matched-keyword", "openshift"),
            ]
        )
        result = parse_matched_signals(headers)
        assert set(result.keys()) == {"domain", "keyword"}


class TestLoadDataset:
    def test_valid_yaml(self, tmp_path):
        dataset = tmp_path / "dataset.yaml"
        dataset.write_text(
            "cases:\n"
            "  - id: t1\n"
            "    input: hello\n"
            "    expected_decision: general\n"
        )
        cases = load_dataset(dataset)
        assert len(cases) == 1
        assert cases[0].id == "t1"
        assert cases[0].expected_decision == "general"

    def test_optional_description_field(self, tmp_path):
        dataset = tmp_path / "dataset.yaml"
        dataset.write_text(
            "cases:\n"
            "  - id: t1\n"
            "    input: hello\n"
            "    expected_decision: general\n"
            "    description: test case\n"
        )
        cases = load_dataset(dataset)
        assert cases[0].description == "test case"

    def test_missing_cases_key_exits(self, tmp_path):
        dataset = tmp_path / "bad.yaml"
        dataset.write_text("decisions: []\n")
        with pytest.raises(SystemExit):
            load_dataset(dataset)

    def test_empty_file_exits(self, tmp_path):
        dataset = tmp_path / "empty.yaml"
        dataset.write_text("")
        with pytest.raises(SystemExit):
            load_dataset(dataset)
