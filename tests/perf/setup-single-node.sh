#!/usr/bin/env bash
# Copyright The Kubernetes Authors
# SPDX-License-Identifier: Apache-2.0
#
# setup-single-node.sh — Sets up ComputeDomain perf testing on an existing
# K8s cluster (single-node or multi-node) using simulated daemon Deployments
# instead of per-node DaemonSets. The cluster must have DRA feature gates
# enabled. This script does NOT create or manage the cluster itself.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
SIM_NODES=18              # Default: 1 rack
SIM_NODES_PER_RACK=18     # GB200 NVL72: 18 nodes/rack
DRIVER_NAMESPACE="nvidia-dra-driver"
IMAGE_REPO=""             # Empty = local images (imagePullPolicy: IfNotPresent)
CONTROLLER_IMAGE="nvidia-dra-driver-gpu:perf"
FAKE_DAEMON_IMAGE="fake-compute-domain-daemon:perf"
FAKE_PLUGIN_IMAGE="fake-cd-kubelet-plugin:perf"
SKIP_BUILD=false

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --sim-nodes)       SIM_NODES="$2";            shift 2 ;;
        --nodes-per-rack)  SIM_NODES_PER_RACK="$2";   shift 2 ;;
        --namespace)       DRIVER_NAMESPACE="$2";      shift 2 ;;
        --image-repo)      IMAGE_REPO="$2";            shift 2 ;;
        --controller-image) CONTROLLER_IMAGE="$2";     shift 2 ;;
        --daemon-image)    FAKE_DAEMON_IMAGE="$2";     shift 2 ;;
        --plugin-image)    FAKE_PLUGIN_IMAGE="$2";     shift 2 ;;
        --skip-build)      SKIP_BUILD=true;            shift ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Sets up an existing K8s cluster for ComputeDomain single-node simulation."
            echo ""
            echo "Options:"
            echo "  --sim-nodes N         Number of simulated nodes (default: 18, i.e. 1 rack)"
            echo "  --nodes-per-rack M    Nodes per rack (default: 18)"
            echo "  --namespace NS        Driver namespace (default: nvidia-dra-driver)"
            echo "  --image-repo PREFIX   Image repository prefix (default: empty, use local)"
            echo "  --controller-image    Controller image (default: nvidia-dra-driver-gpu:perf)"
            echo "  --daemon-image        Fake daemon image (default: fake-compute-domain-daemon:perf)"
            echo "  --plugin-image        Fake plugin image (default: fake-cd-kubelet-plugin:perf)"
            echo "  --skip-build          Skip building container images"
            exit 0
            ;;
        *) log_error "Unknown argument: $1"; exit 1 ;;
    esac
done

# Prefix images with repo if specified
if [[ -n "${IMAGE_REPO}" ]]; then
    CONTROLLER_IMAGE="${IMAGE_REPO}/${CONTROLLER_IMAGE}"
    FAKE_DAEMON_IMAGE="${IMAGE_REPO}/${FAKE_DAEMON_IMAGE}"
    FAKE_PLUGIN_IMAGE="${IMAGE_REPO}/${FAKE_PLUGIN_IMAGE}"
fi

IMAGE_PULL_POLICY="IfNotPresent"
if [[ -n "${IMAGE_REPO}" ]]; then
    IMAGE_PULL_POLICY="Always"
fi

NUM_RACKS=$(( (SIM_NODES + SIM_NODES_PER_RACK - 1) / SIM_NODES_PER_RACK ))

log_info "========================================="
log_info "Single-node simulation setup"
log_info "  Simulated nodes:     ${SIM_NODES}"
log_info "  Nodes per rack:      ${SIM_NODES_PER_RACK}"
log_info "  Simulated racks:     ${NUM_RACKS}"
log_info "  Namespace:           ${DRIVER_NAMESPACE}"
log_info "  Image pull policy:   ${IMAGE_PULL_POLICY}"
log_info "========================================="

# ---------------------------------------------------------------------------
# 1. Check DRA API availability
# ---------------------------------------------------------------------------
log_info "Checking K8s cluster DRA API availability"

if ! kubectl cluster-info &>/dev/null; then
    log_error "Cannot connect to K8s cluster. Ensure kubectl is configured."
    exit 1
fi

if ! kubectl api-resources 2>/dev/null | grep -q "resource.k8s.io"; then
    log_error "DRA API (resource.k8s.io) not available. Ensure DynamicResourceAllocation feature gate is enabled."
    exit 1
fi

log_info "DRA API (resource.k8s.io) is available"

# ---------------------------------------------------------------------------
# 2. Install CRDs
# ---------------------------------------------------------------------------
log_info "Installing ComputeDomain CRDs"
kubectl apply -f "${REPO_ROOT}/deployments/helm/nvidia-dra-driver-gpu/crds/"
kubectl wait --for=condition=Established crd/computedomains.resource.nvidia.com --timeout=30s
kubectl wait --for=condition=Established crd/computedomaincliques.resource.nvidia.com --timeout=30s 2>/dev/null || true

# ---------------------------------------------------------------------------
# 3. Build images (unless --skip-build)
# ---------------------------------------------------------------------------
if [[ "${SKIP_BUILD}" != "true" ]] && [[ -z "${IMAGE_REPO}" ]]; then
    log_info "Building fake-compute-domain-daemon image"
    docker build -t "${FAKE_DAEMON_IMAGE}" \
        -f "${REPO_ROOT}/cmd/fake-compute-domain-daemon/Dockerfile" \
        "${REPO_ROOT}"

    log_info "Building fake-cd-kubelet-plugin image"
    docker build -t "${FAKE_PLUGIN_IMAGE}" \
        -f "${REPO_ROOT}/cmd/fake-cd-kubelet-plugin/Dockerfile" \
        "${REPO_ROOT}"

    log_info "Building compute-domain-controller image"
    if [[ -f "${REPO_ROOT}/Dockerfile" ]]; then
        docker build -t "${CONTROLLER_IMAGE}" -f "${REPO_ROOT}/Dockerfile" "${REPO_ROOT}" || {
            log_info "Main Dockerfile build failed — attempting go build for controller"
            TMPDIR_IMG="$(mktemp -d)"
            (
                cd "${REPO_ROOT}"
                CGO_ENABLED=0 GOOS=linux go build -o "${TMPDIR_IMG}/compute-domain-controller" \
                    ./cmd/compute-domain-controller/ 2>/dev/null || true
            )
            if [[ -f "${TMPDIR_IMG}/compute-domain-controller" ]]; then
                cat > "${TMPDIR_IMG}/Dockerfile" <<'DEOF'
FROM gcr.io/distroless/static:nonroot
COPY compute-domain-controller /usr/bin/compute-domain-controller
USER 65534:65534
ENTRYPOINT ["compute-domain-controller"]
DEOF
                docker build -t "${CONTROLLER_IMAGE}" "${TMPDIR_IMG}"
            fi
            rm -rf "${TMPDIR_IMG}"
        }
    else
        TMPDIR_IMG="$(mktemp -d)"
        (
            cd "${REPO_ROOT}"
            CGO_ENABLED=0 GOOS=linux go build -o "${TMPDIR_IMG}/compute-domain-controller" \
                ./cmd/compute-domain-controller/
        )
        cat > "${TMPDIR_IMG}/Dockerfile" <<'DEOF'
FROM gcr.io/distroless/static:nonroot
COPY compute-domain-controller /usr/bin/compute-domain-controller
USER 65534:65534
ENTRYPOINT ["compute-domain-controller"]
DEOF
        docker build -t "${CONTROLLER_IMAGE}" "${TMPDIR_IMG}"
        rm -rf "${TMPDIR_IMG}"
    fi
fi

# ---------------------------------------------------------------------------
# 4. Create namespace and RBAC
# ---------------------------------------------------------------------------
log_info "Creating namespace ${DRIVER_NAMESPACE}"
kubectl create namespace "${DRIVER_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# Service accounts and RBAC for controller
cat <<EOF | kubectl apply -f -
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: nvidia-dra-driver-gpu-controller
  namespace: ${DRIVER_NAMESPACE}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: nvidia-dra-driver-gpu-controller
rules:
- apiGroups: ["resource.nvidia.com"]
  resources: ["computedomains"]
  verbs: ["get", "list", "watch", "update"]
- apiGroups: ["resource.nvidia.com"]
  resources: ["computedomains/status"]
  verbs: ["update"]
- apiGroups: ["resource.nvidia.com"]
  resources: ["computedomaincliques"]
  verbs: ["get", "list", "watch", "create", "update", "delete"]
- apiGroups: ["resource.k8s.io"]
  resources: ["resourceclaimtemplates"]
  verbs: ["get", "list", "watch", "create", "update", "delete"]
- apiGroups: ["resource.k8s.io"]
  resources: ["resourceslices"]
  verbs: ["get", "list", "watch", "create", "update", "delete"]
- apiGroups: ["coordination.k8s.io"]
  resources: ["leases"]
  verbs: ["get", "create", "update"]
- apiGroups: [""]
  resources: ["nodes"]
  verbs: ["get", "list", "watch", "update"]
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "watch", "create", "update", "delete"]
- apiGroups: ["apps"]
  resources: ["daemonsets"]
  verbs: ["get", "list", "watch", "create", "update", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: nvidia-dra-driver-gpu-controller
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: nvidia-dra-driver-gpu-controller
subjects:
- kind: ServiceAccount
  name: nvidia-dra-driver-gpu-controller
  namespace: ${DRIVER_NAMESPACE}
EOF

# RBAC for kubelet plugin
cat <<EOF | kubectl apply -f -
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: nvidia-dra-driver-gpu-kubeletplugin
  namespace: ${DRIVER_NAMESPACE}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: nvidia-dra-driver-gpu-kubeletplugin
rules:
- apiGroups: ["resource.nvidia.com"]
  resources: ["computedomains"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["resource.k8s.io"]
  resources: ["resourceclaims"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["resource.k8s.io"]
  resources: ["resourceslices"]
  verbs: ["get", "list", "watch", "create", "update", "delete"]
- apiGroups: [""]
  resources: ["nodes"]
  verbs: ["get", "list", "watch", "update"]
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: nvidia-dra-driver-gpu-kubeletplugin
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: nvidia-dra-driver-gpu-kubeletplugin
subjects:
- kind: ServiceAccount
  name: nvidia-dra-driver-gpu-kubeletplugin
  namespace: ${DRIVER_NAMESPACE}
EOF

# RBAC for compute-domain-daemon pods (created as sim-daemon Deployments)
cat <<EOF | kubectl apply -f -
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: nvidia-dra-driver-gpu-compute-domain-daemon
  namespace: ${DRIVER_NAMESPACE}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: nvidia-dra-driver-gpu-compute-domain-daemon
rules:
- apiGroups: ["resource.nvidia.com"]
  resources: ["computedomains"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["resource.nvidia.com"]
  resources: ["computedomains/status"]
  verbs: ["update"]
- apiGroups: ["resource.nvidia.com"]
  resources: ["computedomaincliques"]
  verbs: ["get", "list", "watch", "create", "update"]
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "watch", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: nvidia-dra-driver-gpu-compute-domain-daemon
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: nvidia-dra-driver-gpu-compute-domain-daemon
subjects:
- kind: ServiceAccount
  name: nvidia-dra-driver-gpu-compute-domain-daemon
  namespace: ${DRIVER_NAMESPACE}
EOF

# ---------------------------------------------------------------------------
# 5. Create DeviceClasses
# ---------------------------------------------------------------------------
log_info "Creating DeviceClasses"

cat <<EOF | kubectl apply -f -
---
apiVersion: resource.k8s.io/v1beta1
kind: DeviceClass
metadata:
  name: compute-domain-daemon.nvidia.com
spec:
  selectors:
  - cel:
      expression: "device.driver == 'compute-domain.nvidia.com' && device.attributes['compute-domain.nvidia.com'].type == 'daemon'"
---
apiVersion: resource.k8s.io/v1beta1
kind: DeviceClass
metadata:
  name: compute-domain-default-channel.nvidia.com
spec:
  selectors:
  - cel:
      expression: "device.driver == 'compute-domain.nvidia.com' && device.attributes['compute-domain.nvidia.com'].type == 'channel' && device.attributes['compute-domain.nvidia.com'].id == 0"
EOF

# ---------------------------------------------------------------------------
# 6. Deploy fake-cd-kubelet-plugin DaemonSet
# ---------------------------------------------------------------------------
log_info "Deploying fake-cd-kubelet-plugin DaemonSet (num-channels=${SIM_NODES})"

cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: fake-cd-kubelet-plugin
  namespace: ${DRIVER_NAMESPACE}
  labels:
    app: fake-cd-kubelet-plugin
spec:
  selector:
    matchLabels:
      app: fake-cd-kubelet-plugin
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: "100%"
  template:
    metadata:
      labels:
        app: fake-cd-kubelet-plugin
    spec:
      serviceAccountName: nvidia-dra-driver-gpu-kubeletplugin
      tolerations:
      - operator: Exists
      containers:
      - name: fake-cd-kubelet-plugin
        image: ${FAKE_PLUGIN_IMAGE}
        imagePullPolicy: ${IMAGE_PULL_POLICY}
        args:
        - --node-name=\$(NODE_NAME)
        - --num-channels=${SIM_NODES}
        - --prepare-delay=50ms
        env:
        - name: NODE_NAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
        securityContext:
          privileged: true
        volumeMounts:
        - name: plugins-registry
          mountPath: /var/lib/kubelet/plugins_registry
        - name: plugins
          mountPath: /var/lib/kubelet/plugins
          mountPropagation: Bidirectional
      volumes:
      - name: plugins-registry
        hostPath:
          path: /var/lib/kubelet/plugins_registry
      - name: plugins
        hostPath:
          path: /var/lib/kubelet/plugins
EOF

# ---------------------------------------------------------------------------
# 7. Deploy controller
# ---------------------------------------------------------------------------
log_info "Deploying compute-domain-controller"

cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nvidia-dra-driver-gpu-controller
  namespace: ${DRIVER_NAMESPACE}
  labels:
    nvidia-dra-driver-gpu-component: controller
spec:
  replicas: 1
  selector:
    matchLabels:
      nvidia-dra-driver-gpu-component: controller
  template:
    metadata:
      labels:
        nvidia-dra-driver-gpu-component: controller
    spec:
      serviceAccountName: nvidia-dra-driver-gpu-controller
      tolerations:
      - operator: Exists
      containers:
      - name: compute-domain
        image: ${CONTROLLER_IMAGE}
        imagePullPolicy: ${IMAGE_PULL_POLICY}
        command: ["compute-domain-controller", "-v", "4"]
        env:
        - name: LOG_VERBOSITY
          value: "4"
        - name: LOG_VERBOSITY_CD_DAEMON
          value: "4"
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        - name: NAMESPACE
          valueFrom:
            fieldRef:
              fieldPath: metadata.namespace
        - name: IMAGE_NAME
          value: "${FAKE_DAEMON_IMAGE}"
        - name: NVIDIA_VISIBLE_DEVICES
          value: void
        - name: NVIDIA_DRIVER_ROOT
          value: "/"
        - name: CDI_ROOT
          value: "/var/run/cdi"
        - name: IMEX_DAEMON_PATH
          value: "/usr/bin/fake-compute-domain-daemon"
EOF

# ---------------------------------------------------------------------------
# 8. Wait for components to be ready
# ---------------------------------------------------------------------------
log_info "Waiting for controller deployment to be ready"
kubectl rollout status deployment/nvidia-dra-driver-gpu-controller \
    -n "${DRIVER_NAMESPACE}" --timeout=120s

log_info "Waiting for fake-cd-kubelet-plugin DaemonSet to be ready"
kubectl rollout status daemonset/fake-cd-kubelet-plugin \
    -n "${DRIVER_NAMESPACE}" --timeout=120s

PLUGIN_PODS="$(kubectl get pods -n "${DRIVER_NAMESPACE}" -l app=fake-cd-kubelet-plugin \
    --field-selector=status.phase=Running --no-headers | wc -l)"
log_info "Running fake kubelet plugin pods: ${PLUGIN_PODS}"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
log_info "========================================="
log_info "Single-node simulation setup complete"
log_info "  Simulated nodes:     ${SIM_NODES}"
log_info "  Nodes per rack:      ${SIM_NODES_PER_RACK}"
log_info "  Simulated racks:     ${NUM_RACKS}"
log_info "  Controller:          Running"
log_info "  Kubelet plugins:     ${PLUGIN_PODS}"
log_info "  Driver namespace:    ${DRIVER_NAMESPACE}"
log_info "  Perf test NS:        ${NAMESPACE}"
log_info "========================================="
log_info ""
log_info "Run single-rack test:  ./test-single-node-rack.sh"
log_info "Run multi-rack test:   ./test-single-node-multi-rack.sh --racks 3"
