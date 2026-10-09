#!/usr/bin/env python3
"""Helm post-renderer for CPU Operator-aware KServe InferenceServices."""

import os
import sys
from pathlib import Path
import yaml

NODE = os.environ.get("CPU_OPERATOR_NODE", "").strip()

TARGETS = {
    "qwen3-8b",
    "granite-3-1-8b-instruct",
    "granite-3-1-2b-instruct",
}
DISABLE_ISTIO = os.environ.get("CPU_OPERATOR_DISABLE_ISTIO", "1") == "1"

docs = list(yaml.safe_load_all(sys.stdin))
for doc in docs:
    if not isinstance(doc, dict):
        continue
    if doc.get("kind") != "InferenceService":
        continue
    name = ((doc.get("metadata") or {}).get("name") or "")
    if name not in TARGETS:
        continue

    metadata = doc.setdefault("metadata", {})
    annotations = metadata.setdefault("annotations", {})
    if NODE and DISABLE_ISTIO:
        annotations["sidecar.istio.io/inject"] = "false"
        annotations["sidecar.istio.io/rewriteAppHTTPProbers"] = "false"

    predictor = doc.setdefault("spec", {}).setdefault("predictor", {})
    if NODE:
        # Single-worker profile has no spare GPU/CPU for a surge replica.
        predictor["deploymentStrategy"] = {
            "type": "RollingUpdate",
            "rollingUpdate": {"maxSurge": 0, "maxUnavailable": 1},
        }
        selector = predictor.setdefault("nodeSelector", {})
        selector["kubernetes.io/hostname"] = NODE
        selector["cpu.example.com/placement-ready"] = "true"
        selector["cpu.example.com/node-class"] = "mixed-cpu-amx-gpu"

# llm-service 0.5.9 uses fixed names across aliases. Collapse identical
# resources, but never silently choose between conflicting definitions.
namespace = os.environ.get("TARGET_NAMESPACE", "vllm-semantic-router")
def identity(doc):
    meta = doc.get("metadata") or {}
    return (doc.get("apiVersion"), doc.get("kind"),
            meta.get("namespace") or namespace, meta.get("name"))

unique = {}
for doc in docs:
    if not isinstance(doc, dict):
        continue
    key = identity(doc)
    if key in unique and unique[key] != doc:
        raise SystemExit(f"Conflicting duplicate Helm resource: {key}")
    unique[key] = doc

# The dependency's lookup guards suppress these objects on an upgrade.
# Retain only objects already tracked by this release, so Helm does not
# delete them merely because lookup found them in the cluster.
previous = os.environ.get("CPU_OPERATOR_PREVIOUS_MANIFEST", "")
if previous:
    for doc in yaml.safe_load_all(Path(previous).read_text()):
        if not isinstance(doc, dict):
            continue
        key = identity(doc)
        if (doc.get("kind"), (doc.get("metadata") or {}).get("name")) not in {
            ("Secret", "huggingface-secret"),
            ("ConfigMap", "vllm-chat-templates"),
        }:
            continue
        if key not in unique:
            if doc.get("kind") == "Secret" and os.environ.get("HF_TOKEN"):
                import base64
                doc.setdefault("data", {})["HF_TOKEN"] = base64.b64encode(
                    os.environ["HF_TOKEN"].encode()).decode()
            unique[key] = doc

yaml.safe_dump_all(unique.values(), sys.stdout, sort_keys=False, explicit_start=True)
