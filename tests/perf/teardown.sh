#!/usr/bin/env bash
# Copyright The Kubernetes Authors
# SPDX-License-Identifier: Apache-2.0
#
# teardown.sh — Remove the kind cluster created for perf testing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

CLUSTER_NAME="${1:-cd-perf-test}"

log_info "Tearing down kind cluster '${CLUSTER_NAME}'"

if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
    kind delete cluster --name "${CLUSTER_NAME}"
    log_info "Cluster '${CLUSTER_NAME}' deleted"
else
    log_info "Cluster '${CLUSTER_NAME}' does not exist — nothing to do"
fi

log_info "Teardown complete"
