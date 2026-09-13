# ShiftBoard developer commands.
# Everything CI does, you can run locally with the same command.

SHELL := /bin/bash
ENV   ?= dev
TAG   ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo local)
ACR   ?=

.DEFAULT_GOAL := help

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	  awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-24s\033[0m %s\n", $$1, $$2}'

# ------------------------------------------------------------------ quality
test: test-api test-worker test-web ## Run every test suite

test-api: ## shift-api unit tests with coverage gate
	cd services/shift-api && python -m pytest

test-worker: ## roster-worker unit tests with coverage gate
	cd services/roster-worker && python -m pytest

test-web: ## frontend tests
	cd services/web && npm run test

lint: ## Lint everything
	cd services/shift-api && ruff check app tests migrations
	cd services/roster-worker && ruff check worker tests
	cd services/web && npx tsc -b
	helm lint charts/shift-api charts/roster-worker charts/web \
	  --set image.repository=x.azurecr.io/y --set image.tag=t \
	  --set config.database.host=h --set config.serviceBus.namespace=n \
	  --set serviceAccount.clientId=c
	terraform -chdir=infra/envs/$(ENV) fmt -check -recursive ../..

security: ## Static security scans
	cd infra/envs/$(ENV) && checkov -d .
	cd services/shift-api && bandit -r app -q
	cd services/roster-worker && bandit -r worker -q

# ------------------------------------------------------------- manifest gate
render: ## Render all charts to build/rendered.yaml
	@mkdir -p build
	@for c in shift-api roster-worker web; do \
	  helm template shiftboard charts/$$c --namespace shiftboard \
	    --set image.repository=example.azurecr.io/shiftboard/$$c \
	    --set image.tag=$(TAG) \
	    --set config.database.host=sql.database.windows.net \
	    --set config.serviceBus.namespace=sb \
	    --set serviceAccount.clientId=00000000-0000-0000-0000-000000000000 ; \
	  echo "---" ; \
	done > build/rendered.yaml
	@echo "wrote build/rendered.yaml"

audit: render ## Fail the build on any pod security regression
	python policy/audit_manifests.py build/rendered.yaml

# -------------------------------------------------------------- infrastructure
tf-init: ## terraform init for $(ENV)
	terraform -chdir=infra/envs/$(ENV) init

tf-plan: ## terraform plan for $(ENV)
	terraform -chdir=infra/envs/$(ENV) plan -out=tfplan

tf-apply: ## terraform apply the saved plan for $(ENV)
	terraform -chdir=infra/envs/$(ENV) apply tfplan

tf-destroy: ## Tear down $(ENV) completely
	terraform -chdir=infra/envs/$(ENV) destroy

preflight: ## Check prerequisites before applying
	./scripts/preflight.sh

# -------------------------------------------------------------------- images
build: ## Build all three images locally
	docker build -t shiftboard/shift-api:$(TAG) \
	  --build-arg GIT_SHA=$(TAG) services/shift-api
	docker build -t shiftboard/roster-worker:$(TAG) \
	  --build-arg GIT_SHA=$(TAG) services/roster-worker
	docker build -t shiftboard/web:$(TAG) \
	  --build-arg GIT_SHA=$(TAG) services/web

push: ## Build and push to ACR (requires ACR=<name>.azurecr.io)
	@test -n "$(ACR)" || (echo "set ACR=<registry>.azurecr.io"; exit 1)
	az acr login --name $(firstword $(subst ., ,$(ACR)))
	for s in shift-api roster-worker web; do \
	  docker build -t $(ACR)/shiftboard/$$s:$(TAG) \
	    --build-arg GIT_SHA=$(TAG) services/$$s && \
	  docker push $(ACR)/shiftboard/$$s:$(TAG) ; \
	done

scan: ## Trivy scan the built images, fail on HIGH/CRITICAL
	for s in shift-api roster-worker web; do \
	  trivy image --exit-code 1 --severity HIGH,CRITICAL \
	    --ignore-unfixed shiftboard/$$s:$(TAG) ; \
	done

# --------------------------------------------------------------------- deploy
values: ## Render gitops values from terraform outputs
	@test -n "$(ACR)" || (echo "set ACR=<registry>.azurecr.io"; exit 1)
	./scripts/render-values.sh $(ENV) $(ACR) $(TAG)

creds: ## Fetch kubeconfig for $(ENV)
	az aks get-credentials \
	  -g $$(terraform -chdir=infra/envs/$(ENV) output -raw resource_group_name) \
	  -n $$(terraform -chdir=infra/envs/$(ENV) output -raw aks_cluster_name) \
	  --overwrite-existing

status: ## Show what is actually running
	kubectl -n shiftboard get pods,svc,hpa,ingress
	kubectl -n argocd get applications

logs-api: ## Tail shift-api logs
	kubectl -n shiftboard logs -l app.kubernetes.io/name=shift-api -f --tail=50

logs-worker: ## Tail roster-worker logs
	kubectl -n shiftboard logs -l app.kubernetes.io/name=roster-worker -f --tail=50

clean: ## Remove local build artefacts
	rm -rf build services/*/junit.xml services/*/coverage.xml services/*/.coverage
	rm -rf services/web/dist services/web/node_modules
	find . -type d -name __pycache__ -prune -exec rm -rf {} +
	find . -type d -name .pytest_cache -prune -exec rm -rf {} +

.PHONY: help test test-api test-worker test-web lint security render audit \
        tf-init tf-plan tf-apply tf-destroy preflight build push scan values \
        creds status logs-api logs-worker clean
