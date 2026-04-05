# Copyright The Kubernetes Authors
# SPDX-License-Identifier: Apache-2.0
#
# Makefile for ComputeDomain performance tests.

SHELL := /bin/bash
.DEFAULT_GOAL := help

PERF_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
CLUSTER_NAME ?= cd-perf-test
NUM_NODES ?= 10
NAMESPACE ?= default
SIM_NODES ?= 18
NODES_PER_RACK ?= 18
RACKS ?= 3
SCALE_RACKS ?= 1 3 5 10

export PERF_NAMESPACE ?= $(NAMESPACE)

# ---------------------------------------------------------------------------
# Targets
# ---------------------------------------------------------------------------

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

.PHONY: setup
setup: ## Create kind cluster and deploy all components
	@bash $(PERF_DIR)/setup-kind-cluster.sh \
		--nodes $(NUM_NODES) \
		--cluster-name $(CLUSTER_NAME)

.PHONY: test-all
test-all: ## Run all performance tests
	@bash $(PERF_DIR)/run-all.sh

.PHONY: test-single-cd
test-single-cd: ## Run single CD with 2000 pods test
	@bash $(PERF_DIR)/test-single-cd-2000-pods.sh

.PHONY: test-multi-cd
test-multi-cd: ## Run 50 independent CDs test
	@bash $(PERF_DIR)/test-multi-cd.sh

.PHONY: test-failover
test-failover: ## Run CD failover/recovery test
	@bash $(PERF_DIR)/test-cd-failover.sh

.PHONY: test-lifecycle
test-lifecycle: ## Run CD lifecycle (create→ready→delete) test
	@bash $(PERF_DIR)/test-cd-lifecycle.sh

.PHONY: test-scale
test-scale: ## Run CD scalability test (10→50→100→200 CDs)
	@bash $(PERF_DIR)/test-cd-scale.sh

.PHONY: teardown
teardown: ## Delete the kind cluster
	@bash $(PERF_DIR)/teardown.sh $(CLUSTER_NAME)

.PHONY: report
report: ## Display test results summary
	@echo "=== ComputeDomain Performance Test Results ==="
	@echo ""
	@if [ -f $(PERF_DIR)/results/summary.json ]; then \
		echo "Suite Summary:"; \
		python3 -m json.tool $(PERF_DIR)/results/summary.json 2>/dev/null || \
			cat $(PERF_DIR)/results/summary.json; \
		echo ""; \
	else \
		echo "No summary.json found. Run 'make test-all' first."; \
	fi
	@echo "--- Individual Test Results ---"
	@for f in $(PERF_DIR)/results/*.json; do \
		if [ -f "$$f" ] && [ "$$(basename $$f)" != "summary.json" ]; then \
			echo ""; \
			echo ">> $$(basename $$f):"; \
			python3 -m json.tool "$$f" 2>/dev/null || cat "$$f"; \
		fi; \
	done

.PHONY: clean-results
clean-results: ## Remove all result files
	@rm -rf $(PERF_DIR)/results/*.json $(PERF_DIR)/results/*.prom
	@echo "Results cleaned"

.PHONY: clean
clean: teardown clean-results ## Teardown cluster and clean results

# ---------------------------------------------------------------------------
# Single-node simulation targets
# ---------------------------------------------------------------------------

.PHONY: setup-single-node
setup-single-node: ## Set up existing cluster for single-node simulation
	@bash $(PERF_DIR)/setup-single-node.sh \
		--sim-nodes $(SIM_NODES) \
		--nodes-per-rack $(NODES_PER_RACK)

.PHONY: test-single-rack
test-single-rack: ## Single-node mode: 1 rack (18 nodes) test
	@bash $(PERF_DIR)/test-single-node-rack.sh \
		--sim-nodes $(SIM_NODES) \
		--nodes-per-rack $(NODES_PER_RACK)

.PHONY: test-multi-rack
test-multi-rack: ## Single-node mode: multi-rack test (default: 3 racks)
	@bash $(PERF_DIR)/test-single-node-multi-rack.sh \
		--racks $(RACKS) \
		--nodes-per-rack $(NODES_PER_RACK)

.PHONY: test-scale-racks
test-scale-racks: ## Scale test: run multi-rack for each value in SCALE_RACKS
	@for r in $(SCALE_RACKS); do \
		echo ""; \
		echo "========================================"; \
		echo "  Scale test: $$r rack(s)"; \
		echo "========================================"; \
		bash $(PERF_DIR)/test-single-node-multi-rack.sh \
			--racks $$r \
			--nodes-per-rack $(NODES_PER_RACK) \
			--cd-name "perf-scale-$${r}r" || { echo "FAILED at $$r racks"; break; }; \
	done
	@echo ""
	@echo "Scale test complete. Results in $(PERF_DIR)/results/"

# ---------------------------------------------------------------------------
# Dry-run daemon targets (real compute-domain-daemon with --dry-run)
# ---------------------------------------------------------------------------

DRYRUN_CLUSTER_NAME ?= cd-dryrun-test
DRYRUN_NODES ?= 18

.PHONY: setup-dryrun
setup-dryrun: ## Set up kind cluster with dry-run daemon mode
	@bash $(PERF_DIR)/setup-kind-dryrun.sh \
		--nodes $(DRYRUN_NODES) \
		--cluster-name $(DRYRUN_CLUSTER_NAME)

.PHONY: test-dryrun-rack
test-dryrun-rack: ## Dry-run mode: rack test (default: sim mode, 1 rack)
	@bash $(PERF_DIR)/test-dryrun-rack.sh \
		--racks $(RACKS) \
		--nodes-per-rack $(NODES_PER_RACK) \
		--mode sim

.PHONY: test-dryrun-e2e test-dryrun-endtoend
test-dryrun-endtoend: ## Dry-run mode: full E2E (CD, daemon, CDClique, workload pods)
	@bash $(PERF_DIR)/test-dryrun-e2e.sh \
		--racks $(RACKS) \
		--pods-per-rack $(NODES_PER_RACK) \
		--mode sim
test-dryrun-e2e: test-dryrun-endtoend

.PHONY: test-dryrun-sim-rack
test-dryrun-sim-rack: ## Dry-run mode: sim-spawner multi-rack test (default: 4 racks)
	@bash $(PERF_DIR)/test-dryrun-rack.sh \
		--racks $(RACKS) \
		--nodes-per-rack $(NODES_PER_RACK) \
		--mode sim

.PHONY: teardown-dryrun
teardown-dryrun: ## Delete the dry-run kind cluster
	@bash $(PERF_DIR)/teardown.sh $(DRYRUN_CLUSTER_NAME)
