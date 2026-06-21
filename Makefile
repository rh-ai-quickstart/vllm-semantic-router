.DEFAULT_GOAL := help

help:
	@echo "Targets: setup, dev, lint, test, test-integration, test-e2e, eval, deploy, undeploy"

setup:
	pnpm install
	pip install -e "packages/api[test]" -e "packages/db" -e "packages/ingestion[test]"
	pre-commit install

dev:
	podman-compose up --build

dev-down:
	podman-compose down

lint:
	ruff check packages/api/ packages/db/ packages/ingestion/
	ruff format --check packages/api/ packages/db/ packages/ingestion/
	pnpm --filter chat-ui lint

test:
	pytest packages/api/tests/unit/ -v
	pytest packages/ingestion/tests/ -v
	pnpm --filter chat-ui test

test-integration:
	podman-compose -f compose.yml up -d pgvector
	pytest tests/integration/ -v
	podman-compose down

test-e2e:
	pnpm exec playwright test

eval:
	uv run eval/eval.py $(ARGS)

helm-lint:
	helm lint deploy/helm/vllm-semantic-router/

deploy:
	helm dependency update deploy/helm/vllm-semantic-router
	helm upgrade --install vllm-semantic-router deploy/helm/vllm-semantic-router

undeploy:
	helm uninstall vllm-semantic-router
