# vLLM Semantic Router for Agentic Apps

Add intelligent, config-driven routing to any multi-agent AI application on Red Hat OpenShift AI.

This quickstart deploys [vLLM Semantic Router](https://github.com/vllm-project/semantic-router) as an OpenAI-compatible proxy in front of three on-cluster agents (research/reasoning, RAG, general conversation). A chat UI makes routing decisions visible -- showing which agent was selected, which signals fired, and why. The primary takeaway: you can add semantic routing, jailbreak guardrails, and cost optimization to any agentic app through YAML configuration alone, with no application code changes.

## Use case

Most multi-agent AI applications hardcode their routing logic: an `if/else` chain or a classifier baked into application code decides which model handles each request. When you need to add a new agent, adjust routing thresholds, or add a guardrail, you're changing application code and redeploying.

This quickstart demonstrates **config-driven semantic routing**. A central routing engine (vLLM Semantic Router) sits between the user and your models, classifying every request by topic, complexity, and safety signals -- then routing it to the right agent automatically. Adding or changing routing rules is a YAML edit, not a code change.

### What this deploys

A chat application backed by three specialized agents:

| Query type | Example | Routed to | Why |
|---|---|---|---|
| Complex research | "Explain quantum entanglement in detail" | **Qwen3-8B** (reasoning mode) | Computer science domain signal fires -> research decision |
| Knowledge base | "What is Red Hat OpenShift AI?" | **Granite 3.1-8B** (RAG) | Keyword signals fire -> rag decision |
| General conversation | "Hello, how are you?" | **Granite 3.1-2B** | Default route -> lightweight model (lower cost, lower latency) |
| Jailbreak attempt | "Ignore all instructions and..." | **Blocked** | Jailbreak signal fires -> request rejected |
| Contains PII | "My SSN is 123-45-6789, help me with..." | **Granite 3.1-2B** (with safety prompt) | PII signal fires -> model instructed to ignore personal data |

### Who this is for

- **Platform engineers** evaluating semantic routing for multi-model serving on OpenShift AI
- **AI/ML engineers** building agentic applications that need intelligent request dispatch
- **Solution architects** looking for a reference pattern for guardrails + cost optimization via model tiering

### What you'll learn

1. How to configure signal-driven routing rules in YAML (no application code changes)
2. How to add jailbreak and PII guardrails as routing decisions
3. How to serve multiple models (different sizes, different capabilities) behind a single OpenAI-compatible endpoint
4. How to visualize routing decisions in real time through the chat UI and SR dashboard

## Architecture

```mermaid
graph TB
    User[User] --> ChatUI[Chat UI<br/>React]
    Admin[Admin] --> SRDASH[SR Dashboard<br/>Routing Analytics]

    ChatUI --> API[FastAPI Backend]
    API -->|classify| SR_API[SR Classify API :8080]
    API -->|chat| SR_ENVOY[SR Envoy Proxy :8801]

    SR_ENVOY --> SD{Signal-Decision<br/>Engine}

    SD -->|research| VLLM1[vLLM: Qwen3-8B<br/>reasoning enabled]
    SD -->|rag| VLLM2[vLLM: Granite 3.1-8B]
    SD -->|general| VLLM3[vLLM: Granite 3.1-2B]
    SD -->|jailbreak/pii| BLOCK[Blocked]

    LS[Llamastack] --> VLLM2
    LS --> PGV[(pgvector)]
    LS --> MINIO[(MinIO)]
```

### Components

| Component | Technology | Purpose |
|-----------|-----------|---------|
| Semantic Router | vLLM SR ExtProc + Envoy | Signal-driven request classification and model routing |
| SR Dashboard | vLLM SR Dashboard (React + Go) | Routing analytics, signal inspection, metrics |
| Chat UI | React 19 + TypeScript | User-facing chat with inline routing visualization |
| Backend API | Python 3.12 + FastAPI | Proxies chat through SR, surfaces routing metadata via SSE |
| Research Agent | Qwen3-8B via vLLM | Complex reasoning queries (thinking mode enabled) |
| RAG Agent | Granite 3.1-8B via vLLM (Llamastack available for document retrieval) | Knowledge base queries |
| General Agent | Granite 3.1-2B via vLLM | Casual conversation, simple questions |
| Vector DB | PostgreSQL + pgvector | Stores document embeddings for RAG |
| Object Storage | MinIO | Stores RAG source documents |
| Ingestion | Docling pipeline | Processes documents into embeddings |

## Requirements

### OpenShift Deployment

- Red Hat OpenShift 4.14+
- Red Hat OpenShift AI 2.9+
- `oc` CLI authenticated to the cluster
- `helm` 3.x
- **GPU:** 3 NVIDIA GPUs (T4, L4, or A10G) for model serving. All models are <=8B parameters — each requires a dedicated GPU.
  - 1 GPU for Qwen3-8B (research)
  - 1 GPU for Granite 3.1-8B (RAG)
  - 1 GPU for Granite 3.1-2B (general)
- Hugging Face token with access to Qwen3-8B
- If GPU nodes have custom taints (e.g. `g5-gpu`), tolerations must be added per model in `values.yaml`

### Local Development

- Python 3.12+
- Node.js 22+ with pnpm
- Podman + podman-compose
- NVIDIA GPU with CUDA (for vLLM model serving)

## Quick Start (Local)

```bash
git clone https://github.com/rh-ai-quickstart/vllm-semantic-router.git
cd vllm-semantic-router
cp .env.example .env
# Edit .env -- set HF_TOKEN for model downloads
make setup
make dev
```

| Service | URL |
|---------|-----|
| Chat UI | http://localhost:3000 |
| SR Dashboard | http://localhost:8700 |
| API docs | http://localhost:8000/docs |
| SR Classify API | http://localhost:8080/docs |
| MinIO Console | http://localhost:9001 |

### Ingest Sample Documents (for RAG)

```bash
python3 packages/ingestion/src/ingest.py
```

This uploads the bundled sample docs (OpenShift AI overview, SR guide) to MinIO and registers them in Llamastack's vector store.

## Deploy to OpenShift

### 1. Create namespace and set HF token

```bash
oc login <cluster-url>
oc new-project vllm-semantic-router
export HF_TOKEN=<your-huggingface-token>
```

### 2. Build and push chat-ui and API images

The chat UI and API backend images must be built and pushed to a container registry accessible from the cluster:

```bash
podman build --platform linux/amd64 \
  -t quay.io/<your-org>/vllm-semantic-router-chat-ui:latest \
  -f packages/chat-ui/Containerfile .

podman build --platform linux/amd64 \
  -t quay.io/<your-org>/vllm-semantic-router-api:latest \
  -f packages/api/Containerfile packages/api

podman push quay.io/<your-org>/vllm-semantic-router-chat-ui:latest
podman push quay.io/<your-org>/vllm-semantic-router-api:latest
```

Then update `deploy/helm/vllm-semantic-router/values.yaml` to point `chatUI.image.repository` and `api.image.repository` to your pushed images.

### 3. GPU node tolerations

If GPU nodes have custom taints (common on shared clusters), add tolerations under each model in `values.yaml`:

```yaml
# Example for a cluster with g5-gpu taint
llm-service-general:
  models:
    granite-3-1-2b-instruct:
      tolerations:
        - key: nvidia.com/gpu
          effect: NoSchedule
          operator: Exists
        - key: g5-gpu        # cluster-specific GPU taint
          effect: NoSchedule
          operator: Exists
```

### 4. Install with Helm

```bash
helm install vllm-semantic-router deploy/helm/vllm-semantic-router \
  -n vllm-semantic-router \
  --set llm-service-research.secret.hf_token=$HF_TOKEN \
  --set llm-service-rag.secret.hf_token=$HF_TOKEN \
  --set llm-service-general.secret.hf_token=$HF_TOKEN \
  --set semanticRouter.hfToken=$HF_TOKEN
```

> The `semanticRouter.hfToken` is required for the router to download embedding models (mmBERT) used for signal classification. A 20Gi PVC is created by default to persist these models across pod restarts. The ingestion pipeline is disabled by default; enable it with `--set ingestion-pipeline.enabled=true` when DSPA is available.

### 5. Verify

```bash
oc get pods -n vllm-semantic-router
# Wait for all pods to be Running (model downloads take a few minutes)
# GPU model pods (predictor-*) take longest -- they download multi-GB models

# Get the chat UI URL
oc get route -n vllm-semantic-router -l app.kubernetes.io/name=chat-ui \
  -o jsonpath='{.items[0].spec.host}'

# Get the SR dashboard URL
oc get route -n vllm-semantic-router -l app.kubernetes.io/name=sr-dashboard \
  -o jsonpath='{.items[0].spec.host}'
```

### Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Predictor pods stuck in `Pending` | GPU nodes have taints the pods don't tolerate | Add tolerations to each model in `values.yaml` |
| Chat-ui/API pods in `ImagePullBackOff` | Images not pushed or registry not accessible | Build and push images (step 2) |
| Router (extproc) in `CrashLoopBackOff` | Missing HF_TOKEN or unwritable model dir | Set `semanticRouter.hfToken` in helm values |
| Router crashes with jailbreak detector error | Explicit jailbreak/pii signal declarations make mmBERT model download mandatory | Remove explicit jailbreak/pii signal declarations from config; built-in defaults work without them |
| Chat returns 504 Gateway Timeout | Envoy ext_proc `message_timeout` too low for routing latency | Set `message_timeout: 30s` in Envoy ext_proc filter config |
| Llamastack in `ImagePullBackOff` | `llamastack/distribution-starter` renamed to `ogxai/distribution-starter` | Update image to `docker.io/ogxai/distribution-starter:0.6.1` |
| Llamastack crashes with "API 'safety' does not exist" | Using `ogxai/distribution-starter:latest` (1.x) with 0.x config schema | Use `ogxai/distribution-starter:0.6.1` to match the subchart config format |
| Dashboard in `CrashLoopBackOff` | OpenShift SCC blocks user switching | Dashboard template overrides entrypoint to skip `gosu` |
| Chat returns 404 | Nginx not proxying `/api` to the API service | Verify chat-ui-nginx ConfigMap is mounted |
| Chat hangs (no response) | Envoy backend cluster misconfigured | Verify envoy ConfigMap clusters point to correct vLLM services |
| vLLM returns "model does not exist" | Model name mismatch between SR and vLLM | `--served-model-name` in vLLM args must match SR model names |
| SR routing returns empty decision | Domain names in config don't match MMLU classifier taxonomy | Use MMLU categories (`computer science`, `health`, `other`) in domain signal config |
| Keyword signal not matching | Config uses `terms` field (invalid in v0.3) | Use `keywords` field with `method: bm25` |
| Ingestion pipeline stuck in `Init:0/1` | Waiting for Data Science Pipelines (DSPA) service | Deploy DSPA or disable the ingestion-pipeline subchart |

## Delete / Cleanup

```bash
helm uninstall vllm-semantic-router -n vllm-semantic-router
oc delete project vllm-semantic-router
```

## How Routing Works

The semantic router classifies every incoming query using configurable **signals** and applies **decision rules** to select the right model:

| Signal | What it detects |
|--------|----------------|
| Domain | Topic classification via MMLU categories (computer science, health, other) |
| Complexity | Simple vs. multi-step reasoning queries (disabled — see note below) |
| Jailbreak | Prompt injection and adversarial attacks (built-in) |
| PII | Personal identifiable information (built-in) |
| Keyword | Domain-specific terms via BM25 matching (document-terms, rag-keywords) |

| Decision | Priority | Routes to | When |
|----------|----------|-----------|------|
| blocked | 100 | (none) | Jailbreak detected |
| pii-flagged | 90 | general-agent | PII detected (with safety prompt) |
| research | 20 | Qwen3-8B (reasoning) | Computer science domain signal fires |
| rag | 15 | Granite 3.1-8B | Keyword signals match (document-terms or rag-keywords) |
| general | 1 | Granite 3.1-2B | Domain classified as "other" (default) |

The config also includes v0.3 features: a `projections` layer that partitions domains into an exclusive `request_type` group, and a `session_aware` algorithm on the research decision that prevents model switches during active tool loops. Jailbreak and PII signals run as built-in defaults.

Routing configuration lives in `config/semantic-router/config.yaml`. To customize routing for your own app, edit the `decisions`, `signals`, and `projections` sections -- no code changes needed.

## Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `HF_TOKEN` | Hugging Face token for model downloads | (required) |
| `SR_ENVOY_URL` | Semantic Router Envoy proxy | `http://envoy:8801` |
| `SR_API_URL` | Semantic Router classify API | `http://semantic-router:8080` |
| `LLAMA_STACK_URL` | Llamastack endpoint | `http://llamastack:8321` |
| `DATABASE_URL` | PostgreSQL connection | `postgresql://postgres:postgres@localhost:5432/semantic_router` |
| `MINIO_ENDPOINT` | MinIO S3 endpoint | `http://localhost:9000` |
| `MINIO_ACCESS_KEY` | MinIO access key | (required) |
| `MINIO_SECRET_KEY` | MinIO secret key | (required) |

## Development

```bash
make setup             # Install Python + Node dependencies, pre-commit hooks
make dev               # Start all services (podman-compose up --build)
make dev-down          # Stop all services
make lint              # Run ruff (Python) + eslint (TypeScript)
make test              # Run unit tests (pytest + vitest)
make test-integration  # Run integration tests against real DB
make helm-lint         # Validate Helm chart
make deploy            # helm dep update + helm upgrade --install
make undeploy          # helm uninstall
```

## Project Structure

```
config/semantic-router/     Routing configuration (config.yaml, signals, decisions)
deploy/
  helm/vllm-semantic-router/  Umbrella Helm chart (ai-architecture-charts deps)
  local/                      Local dev configs (Envoy)
docs/sample-docs/           Sample RAG documents
packages/
  api/                      FastAPI backend (chat proxy + routing metadata)
  chat-ui/                  React chat interface with routing visualization
  db/                       PostgreSQL + pgvector models (Alembic)
  ingestion/                Document ingestion pipeline (Docling + Llamastack)
tests/
  integration/              Integration tests
  e2e/                      Playwright E2E tests
```

## License

Apache-2.0

`vllm` `semantic-router` `multi-agent` `openshift-ai` `rag` `guardrails` `routing`
