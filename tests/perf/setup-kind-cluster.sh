#!/usr/bin/env bash
# Copyright The Kubernetes Authors
# SPDX-License-Identifier: Apache-2.0
#
# setup-kind-cluster.sh — Creates a kind cluster for ComputeDomain perf testing.
# Installs CRDs, builds & loads fake images, deploys controller and fake plugins.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---------------------------------------------------------------------------
# Defaults — GB200 NVL72: 18 nodes per rack, default cluster = 2 racks
# ---------------------------------------------------------------------------
CLUSTER_NAME="cd-perf-test"
NUM_NODES=6   # Default for 4vCPU/16GB machines. Use --nodes 18 for 1 full rack, 36 for 2 racks.
CONTROLLER_REPLICAS=1
FAKE_DAEMON_IMAGE="fake-compute-domain-daemon:perf"
FAKE_PLUGIN_IMAGE="fake-cd-kubelet-plugin:perf"
CONTROLLER_IMAGE="nvidia-dra-driver-gpu:perf"
DRIVER_NAMESPACE="nvidia-dra-driver"

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --nodes)           NUM_NODES="$2";           shift 2 ;;
        --cluster-name)    CLUSTER_NAME="$2";        shift 2 ;;
        --controller-image) CONTROLLER_IMAGE="$2";   shift 2 ;;
        --namespace)       DRIVER_NAMESPACE="$2";    shift 2 ;;
        -h|--help)
            echo "Usage: $0 [--nodes N] [--cluster-name NAME] [--namespace NS]"
            exit 0
            ;;
        *) log_error "Unknown argument: $1"; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# 1. Generate kind configuration
# ---------------------------------------------------------------------------
log_info "Generating kind config with ${NUM_NODES} worker nodes"

KIND_CONFIG="$(mktemp /tmp/kind-config-XXXXXX.yaml)"
trap "rm -f ${KIND_CONFIG}" EXIT

cat > "${KIND_CONFIG}" <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
featureGates:
  DynamicResourceAllocation: true
runtimeConfig:
  "resource.k8s.io/v1beta1": "true"
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: ClusterConfiguration
    apiServer:
      extraArgs:
        runtime-config: "resource.k8s.io/v1beta1=true"
    scheduler:
      extraArgs:
        v: "2"
    controllerManager:
      extraArgs:
        v: "2"
EOF

for (( i=1; i<=NUM_NODES; i++ )); do
    cat >> "${KIND_CONFIG}" <<EOF
- role: worker
  kubeadmConfigPatches:
  - |
    kind: JoinConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        v: "2"
EOF
done

# ---------------------------------------------------------------------------
# 2. Create the kind cluster
# ---------------------------------------------------------------------------
log_info "Creating kind cluster '${CLUSTER_NAME}'"
if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
    log_info "Cluster '${CLUSTER_NAME}' already exists — deleting first"
    kind delete cluster --name "${CLUSTER_NAME}"
fi

kind create cluster --name "${CLUSTER_NAME}" --config "${KIND_CONFIG}" --wait 120s
kubectl cluster-info --context "kind-${CLUSTER_NAME}"

# ---------------------------------------------------------------------------
# 3. Install CRDs
# ---------------------------------------------------------------------------
log_info "Installing ComputeDomain CRDs"
kubectl apply -f "${REPO_ROOT}/deployments/helm/nvidia-dra-driver-gpu/crds/"
kubectl wait --for=condition=Established crd/computedomains.resource.nvidia.com --timeout=30s

# ---------------------------------------------------------------------------
# 4. Build fake images
# ---------------------------------------------------------------------------
log_info "Building fake-compute-domain-daemon image"
docker build -t "${FAKE_DAEMON_IMAGE}" \
    -f "${REPO_ROOT}/cmd/fake-compute-domain-daemon/Dockerfile" \
    "${REPO_ROOT}"

log_info "Building fake-cd-kubelet-plugin image"
docker build -t "${FAKE_PLUGIN_IMAGE}" \
    -f "${REPO_ROOT}/cmd/fake-cd-kubelet-plugin/Dockerfile" \
    "${REPO_ROOT}"

# ---------------------------------------------------------------------------
# 5. Build controller image (or use existing)
# ---------------------------------------------------------------------------
log_info "Building compute-domain-controller image"
if [[ -f "${REPO_ROOT}/Dockerfile" ]]; then
    docker build -t "${CONTROLLER_IMAGE}" -f "${REPO_ROOT}/Dockerfile" "${REPO_ROOT}" || {
        log_info "Main Dockerfile build failed — attempting go build for controller"
        # Fallback: build a minimal controller image
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
    log_info "No Dockerfile at repo root; building controller from Go source"
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

# ---------------------------------------------------------------------------
# 6. Load images into kind
# ---------------------------------------------------------------------------
log_info "Loading images into kind cluster"
kind load docker-image "${FAKE_DAEMON_IMAGE}" --name "${CLUSTER_NAME}"
kind load docker-image "${FAKE_PLUGIN_IMAGE}" --name "${CLUSTER_NAME}"
kind load docker-image "${CONTROLLER_IMAGE}" --name "${CLUSTER_NAME}"

# ---------------------------------------------------------------------------
# 7. Create namespace and RBAC
# ---------------------------------------------------------------------------
log_info "Creating namespace ${DRIVER_NAMESPACE}"
kubectl create namespace "${DRIVER_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# Create service accounts and RBAC for controller
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

# Create service accounts and RBAC for kubelet plugin
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

# RBAC for compute-domain-daemon pods (created dynamically by controller)
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
# 8. Deploy controller
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
  replicas: ${CONTROLLER_REPLICAS}
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
      - key: node-role.kubernetes.io/control-plane
        operator: Exists
        effect: NoSchedule
      - key: node-role.kubernetes.io/master
        operator: Exists
        effect: NoSchedule
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: node-role.kubernetes.io/control-plane
                operator: Exists
      containers:
      - name: compute-domain
        image: ${CONTROLLER_IMAGE}
        imagePullPolicy: Never
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
# 9. Deploy fake-cd-kubelet-plugin DaemonSet on workers
# ---------------------------------------------------------------------------
log_info "Deploying fake-cd-kubelet-plugin DaemonSet"

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
      containers:
      - name: fake-cd-kubelet-plugin
        image: ${FAKE_PLUGIN_IMAGE}
        imagePullPolicy: Never
        args:
        - --node-name=\$(NODE_NAME)
        - --num-channels=2048
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
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: node-role.kubernetes.io/control-plane
                operator: DoesNotExist
EOF

# ---------------------------------------------------------------------------
# 10. Label worker nodes with GB200 NVL72 rack topology
# ---------------------------------------------------------------------------
log_info "Labeling worker nodes with GB200 NVL72 rack topology (${NODES_PER_RACK} nodes/rack)"

WORKER_NODES=($(kubectl get nodes --no-headers -o custom-columns=NAME:.metadata.name \
    -l '!node-role.kubernetes.io/control-plane' | sort))

for idx in "${!WORKER_NODES[@]}"; do
    node="${WORKER_NODES[$idx]}"
    rack_id=$(( idx / NODES_PER_RACK ))
    node_in_rack=$(( idx % NODES_PER_RACK ))
    kubectl label node "${node}" \
        nvidia.com/gpu.product=NVIDIA-GB200-NVL72 \
        nvidia.com/topology.rack="rack-$(printf '%04d' ${rack_id})" \
        nvidia.com/topology.node-in-rack="$(printf '%02d' ${node_in_rack})" \
        nvidia.com/gpu.count="${GPUS_PER_NODE}" \
        --overwrite
    log_info "  ${node} → rack-$(printf '%04d' ${rack_id}), node ${node_in_rack}/${NODES_PER_RACK}, ${GPUS_PER_NODE} GPUs"
done

# ---------------------------------------------------------------------------
# 11. Wait for all components to be ready
# ---------------------------------------------------------------------------
log_info "Waiting for controller deployment to be ready"
kubectl rollout status deployment/nvidia-dra-driver-gpu-controller \
    -n "${DRIVER_NAMESPACE}" --timeout=120s

log_info "Waiting for fake-cd-kubelet-plugin DaemonSet to be ready"
kubectl rollout status daemonset/fake-cd-kubelet-plugin \
    -n "${DRIVER_NAMESPACE}" --timeout=120s

# Verify expected number of plugin pods
PLUGIN_PODS="$(kubectl get pods -n "${DRIVER_NAMESPACE}" -l app=fake-cd-kubelet-plugin \
    --field-selector=status.phase=Running --no-headers | wc -l)"
log_info "Running fake kubelet plugin pods: ${PLUGIN_PODS} (expected: ${NUM_NODES})"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
log_info "========================================="
log_info "Kind cluster '${CLUSTER_NAME}' is ready"
log_info "  Worker nodes:       ${NUM_NODES}"
log_info "  GB200 topology:     ${NODES_PER_RACK} nodes/rack, ${GPUS_PER_NODE} GPUs/node"
log_info "  Simulated racks:    $(( (NUM_NODES + NODES_PER_RACK - 1) / NODES_PER_RACK ))"
log_info "  Controller:         Running"
log_info "  Kubelet plugins:    ${PLUGIN_PODS}"
log_info "  Namespace:          ${DRIVER_NAMESPACE}"
log_info "  Perf test NS:       ${NAMESPACE}"
log_info "========================================="
log_info "Run perf tests with: cd ${SCRIPT_DIR} && ./run-all.sh"
