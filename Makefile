# Local helper only. Every target is offline: it never calls AWS, never touches a cluster,
# and never runs terraform apply/destroy. There is no CI; run these before you push.
SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c
PY := $(if $(wildcard presentation/.venv/bin/python),presentation/.venv/bin/python,python3)

.DEFAULT_GOAL := help
.PHONY: help fmt lint test validate deck deck-verify screenshots

help: ## Show this help
	@grep -hE '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-14s %s\n", $$1, $$2}'

fmt: ## Format Terraform files in place
	terraform -chdir=terraform fmt -recursive

lint: ## shellcheck, terraform fmt/validate, helm, kubeconform, yamllint, secret scan (needs Docker)
	bash scripts/lint.sh

test: ## Script guard tests, fill_results tests and terraform test (stubs only)
	bash scripts/tests/test_guards.sh
	python3 scripts/tests/test_confirm_pty.py
	bash scripts/tests/test_benchmark_preflight.sh
	bash scripts/tests/test_chart.sh
	python3 scripts/tests/test_fill_results.py
	terraform -chdir=terraform init -backend=false -input=false >/dev/null
	terraform -chdir=terraform test
	@rm -rf terraform/.terraform

validate: ## terraform validate and helm lint/template for ca, karpenter, automode
	terraform -chdir=terraform init -backend=false -input=false >/dev/null
	terraform -chdir=terraform validate
	@rm -rf terraform/.terraform
	@for s in ca karpenter automode; do \
		helm lint kubernetes/boutique -f kubernetes/boutique/values-common.yaml -f kubernetes/boutique/values-$$s.yaml >/dev/null && \
		helm template boutique-$$s kubernetes/boutique -f kubernetes/boutique/values-common.yaml -f kubernetes/boutique/values-$$s.yaml >/dev/null && \
		echo "helm ok: $$s"; \
	done

deck: ## Rebuild presentation/karpenter-spot-finops.pptx from script.md and results/summary.json
	$(PY) presentation/build_deck.py

deck-verify: ## Verify the deck and run its unit tests
	$(PY) presentation/verify_deck.py
	$(PY) -m unittest discover presentation/tests

screenshots: ## Regenerate docs/img/*.png from real offline commands (needs Pillow)
	$(PY) docs/make_screenshots.py
