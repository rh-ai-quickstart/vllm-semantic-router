.DEFAULT_GOAL := help

HELM_CHART    := deploy/helm/vllm-semantic-router
HELM_RELEASE  := vllm-semantic-router
HELM_NS       ?= vllm-semantic-router-qs

REGISTRY      ?= quay.io
ORG           ?= <your-org>
CHAT_UI_IMAGE ?= $(REGISTRY)/$(ORG)/vllm-semantic-router-chat-ui
API_IMAGE     ?= $(REGISTRY)/$(ORG)/vllm-semantic-router-api

help:
	@echo "Targets: build-push, test, eval, benchmark, benchmark-results, deploy, deploy-gpu, deploy-cpu, undeploy"
	@echo "Required vars: REGISTRY, ORG, HELM_NS, HF_TOKEN (export before deploying)"

_require-org:
	@test "$(ORG)" != "<your-org>" || \
	  (echo "Error: ORG is not set. Usage: make $@ REGISTRY=quay.io ORG=<your-org>"; exit 1)

build-push: _require-org
	podman build --platform=linux/amd64 \
	  -t $(CHAT_UI_IMAGE):latest \
	  -f packages/chat-ui/Containerfile .
	podman build --platform=linux/amd64 \
	  -t $(API_IMAGE):latest \
	  -f packages/api/Containerfile packages/api
	podman push $(CHAT_UI_IMAGE):latest
	podman push $(API_IMAGE):latest

test:
	uv run --project packages/api --extra test pytest packages/api/tests/unit/ -v
	uv run --project packages/ingestion --extra test pytest packages/ingestion/tests/ -v
	pnpm --filter chat-ui test

eval:
	uv run eval/eval.py $(ARGS)

benchmark: _require-org
	oc delete job $(HELM_RELEASE)-benchmark -n $(HELM_NS) --ignore-not-found
	helm upgrade --install $(HELM_RELEASE) $(HELM_CHART) -n $(HELM_NS) \
	  --set benchmark.enabled=true \
	  --set chatUI.image.repository=$(CHAT_UI_IMAGE) \
	  --set api.image.repository=$(API_IMAGE) \
	  --set semanticRouter.hfToken=$(HF_TOKEN) \
	  --set llm-service-research.secret.hf_token=$(HF_TOKEN) \
	  --set llm-service-rag.secret.hf_token=$(HF_TOKEN) \
	  --set llm-service-general.secret.hf_token=$(HF_TOKEN) \
	  $(HELM_FLAGS)
	@echo "Waiting for benchmark job to complete (up to 30m)..."
	oc wait -n $(HELM_NS) job/$(HELM_RELEASE)-benchmark \
	  --for=condition=complete --timeout=30m
	$(eval BENCH_FAILED := $(shell oc get job -n $(HELM_NS) $(HELM_RELEASE)-benchmark \
	  -o jsonpath='{.status.failed}'))
	@test -z "$(BENCH_FAILED)" || test "$(BENCH_FAILED)" = "0" || \
	  (echo "Benchmark job reported $(BENCH_FAILED) failure(s)"; exit 1)

benchmark-results:
	$(eval BENCH_POD := $(shell oc get pod -n $(HELM_NS) \
	  -l job-name=$(HELM_RELEASE)-benchmark \
	  -o jsonpath='{.items[0].metadata.name}'))
	@test -n "$(BENCH_POD)" || (echo "No benchmark pod found. Run 'make benchmark' first."; exit 1)
	mkdir -p benchmark-results
	oc cp -n $(HELM_NS) $(BENCH_POD):/results ./benchmark-results/
	@echo "Results saved to ./benchmark-results/"

deploy: deploy-gpu

deploy-gpu: _require-org
	helm dependency update $(HELM_CHART)
	helm upgrade --install $(HELM_RELEASE) $(HELM_CHART) -n $(HELM_NS) \
	  --set chatUI.image.repository=$(CHAT_UI_IMAGE) \
	  --set api.image.repository=$(API_IMAGE) \
	  --set semanticRouter.hfToken=$(HF_TOKEN) \
	  --set llm-service-research.secret.hf_token=$(HF_TOKEN) \
	  --set llm-service-rag.secret.hf_token=$(HF_TOKEN) \
	  --set llm-service-general.secret.hf_token=$(HF_TOKEN) \
	  $(HELM_FLAGS)

deploy-cpu: _require-org
	helm dependency update $(HELM_CHART)
	helm upgrade --install $(HELM_RELEASE) $(HELM_CHART) -n $(HELM_NS) \
	  -f $(HELM_CHART)/values-general-cpu.yaml \
	  --set chatUI.image.repository=$(CHAT_UI_IMAGE) \
	  --set api.image.repository=$(API_IMAGE) \
	  --set semanticRouter.hfToken=$(HF_TOKEN) \
	  --set llm-service-research.secret.hf_token=$(HF_TOKEN) \
	  --set llm-service-rag.secret.hf_token=$(HF_TOKEN) \
	  --set llm-service-general.secret.hf_token=$(HF_TOKEN) \
	  $(HELM_FLAGS)

undeploy:
	helm uninstall $(HELM_RELEASE) -n $(HELM_NS)
