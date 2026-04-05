#!/usr/bin/env bash
# Copyright The Kubernetes Authors
# SPDX-License-Identifier: Apache-2.0
#
# setup-kind-dryrun.sh — Creates a kind cluster for ComputeDomain perf testing
# using the real compute-domain-daemon in --dry-run mode (no IMEX hardware).
# Installs CRDs, builds real daemon + fake plugin + controller images,
# deploys controller and patches DaemonSet template for dry-run daemons.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---------------------------------------------------------------------------
# Defaults — GB200 NVL72: 18 nodes per rack
# ---------------------------------------------------------------------------
CLUSTER_NAME="cd-dryrun-test"
NUM_NODES=18   # Default: 1 full rack
CONTROLLER_REPLICAS=1
DRYRUN_DAEMON_IMAGE="compute-domain-daemon:dryrun"
FAKE_PLUGIN_IMAGE="fake-cd-kubelet-plugin:perf"
CONTROLLER_IMAGE="nvidia-dra-driver-gpu:perf"
DRIVER_NAMESPACE="nvidia-dra-driver"
DRYRUN_VERSION="v25.12.0"

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --nodes)           NUM_NODES="$2";           shift 2 ;;
        --cluster-name)    CLUSTER_NAME="$2";        shift 2 ;;
        --namespace)       DRIVER_NAMESPACE="$2";    shift 2 ;;
        --version)         DRYRUN_VERSION="$2";      shift 2 ;;
        -h|--help)
            echo "Usage: $0 [--nodes N] [--cluster-name NAME] [--namespace NS] [--version VER]"
            echo ""
            echo "Creates a kind cluster for dry-run daemon perf testing."
            echo ""
            echo "Options:"
            echo "  --nodes N          Number of worker nodes (default: 18, i.e. 1 rack)"
            echo "  --cluster-name N   Kind cluster name (default: cd-dryrun-test)"
            echo "  --namespace NS     Driver namespace (default: nvidia-dra-driver)"
            echo "  --version VER      Daemon version to inject (default: v25.12.0)"
            exit 0
            ;;
        *) log_error "Unknown argument: $1"; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# 1. Generate kind configuration
# ---------------------------------------------------------------------------
log_info "Generating kind config with ${NUM_NODES} worker nodes"

KIND_CONFIG="$(mktemp /tmp/kind-config-dryrun-XXXXXX.yaml)"
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
# 3. Fix inotify limits (kind nodes may have low defaults)
# ---------------------------------------------------------------------------
log_info "Fixing inotify limits on kind nodes"
for node in $(kind get nodes --name "${CLUSTER_NAME}" 2>/dev/null); do
    docker exec "${node}" sysctl -w fs.inotify.max_user_watches=524288 2>/dev/null || true
    docker exec "${node}" sysctl -w fs.inotify.max_user_instances=512 2>/dev/null || true
done

# ---------------------------------------------------------------------------
# 4. Install CRDs
# ---------------------------------------------------------------------------
log_info "Installing ComputeDomain CRDs"
kubectl apply -f "${REPO_ROOT}/deployments/helm/nvidia-dra-driver-gpu/crds/"
kubectl wait --for=condition=Established crd/computedomains.resource.nvidia.com --timeout=30s
kubectl wait --for=condition=Established crd/computedomaincliques.resource.nvidia.com --timeout=30s 2>/dev/null || true

# ---------------------------------------------------------------------------
# 5. Build REAL compute-domain-daemon image (with --dry-run support)
# ---------------------------------------------------------------------------
log_info "Building real compute-domain-daemon image (version=${DRYRUN_VERSION})"

TMPDIR_DAEMON="$(mktemp -d)"
(
    cd "${REPO_ROOT}"
    CGO_ENABLED=0 GOOS=linux go build \
        -mod=vendor \
        -ldflags="-s -w -X sigs.k8s.io/nvidia-dra-driver-gpu/internal/info.version=${DRYRUN_VERSION}" \
        -o "${TMPDIR_DAEMON}/compute-domain-daemon" \
        ./cmd/compute-domain-daemon/
)

cat > "${TMPDIR_DAEMON}/Dockerfile" <<'DEOF'
FROM gcr.io/distroless/static:nonroot
COPY compute-domain-daemon /usr/bin/compute-domain-daemon
USER 65534:65534
ENTRYPOINT ["compute-domain-daemon"]
DEOF
docker build -t "${DRYRUN_DAEMON_IMAGE}" "${TMPDIR_DAEMON}"
rm -rf "${TMPDIR_DAEMON}"
log_info "Built ${DRYRUN_DAEMON_IMAGE}"

# ---------------------------------------------------------------------------
# 6. Build fake-cd-kubelet-plugin image
# ---------------------------------------------------------------------------
log_info "Building fake-cd-kubelet-plugin image"
docker build -t "${FAKE_PLUGIN_IMAGE}" \
    -f "${REPO_ROOT}/cmd/fake-cd-kubelet-plugin/Dockerfile" \
    "${REPO_ROOT}"

# ---------------------------------------------------------------------------
# 7. Build controller image
# ---------------------------------------------------------------------------
log_info "Building compute-domain-controller image"

TMPDIR_CTRL="$(mktemp -d)"
(
    cd "${REPO_ROOT}"
    CGO_ENABLED=0 GOOS=linux go build \
        -mod=vendor \
        -ldflags="-s -w" \
        -o "${TMPDIR_CTRL}/compute-domain-controller" \
        ./cmd/compute-domain-controller/
)

cat > "${TMPDIR_CTRL}/Dockerfile" <<'DEOF'
FROM gcr.io/distroless/static:nonroot
COPY compute-domain-controller /usr/bin/compute-domain-controller
USER 65534:65534
ENTRYPOINT ["compute-domain-controller"]
DEOF
docker build -t "${CONTROLLER_IMAGE}" "${TMPDIR_CTRL}"
rm -rf "${TMPDIR_CTRL}"

# ---------------------------------------------------------------------------
# 8. Load images into kind
# ---------------------------------------------------------------------------
log_info "Loading images into kind cluster"
kind load docker-image "${DRYRUN_DAEMON_IMAGE}" --name "${CLUSTER_NAME}"
kind load docker-image "${FAKE_PLUGIN_IMAGE}" --name "${CLUSTER_NAME}"
kind load docker-image "${CONTROLLER_IMAGE}" --name "${CLUSTER_NAME}"

# ---------------------------------------------------------------------------
# 9. Create namespace and RBAC
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
- apiGroups: [""]
  resources: ["configmaps"]
  verbs: ["get", "list", "watch", "create", "update", "patch"]
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
# 10. Create DeviceClasses
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
# 11. Deploy fake-cd-kubelet-plugin DaemonSet on workers
# ---------------------------------------------------------------------------
log_info "Deploying fake-cd-kubelet-plugin DaemonSet (--num-channels=1)"

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
        - --num-channels=1
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
# 12. Create CDI specs on each worker node (legacy compatibility)
# ---------------------------------------------------------------------------
log_info "Creating CDI spec directories on worker nodes"
WORKER_NODES=($(kubectl get nodes --no-headers -o custom-columns=NAME:.metadata.name \
    -l '!node-role.kubernetes.io/control-plane' | sort))

for node in "${WORKER_NODES[@]}"; do
    # Create CDI spec dir inside the kind node container
    docker exec "${node}" mkdir -p /var/run/cdi 2>/dev/null || true
    log_info "  Created /var/run/cdi on ${node}"
done

# ---------------------------------------------------------------------------
# 13. Deploy controller (no --dry-run-daemons; sim-spawner will create Deployments)
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
          value: "${DRYRUN_DAEMON_IMAGE}"
        - name: NVIDIA_VISIBLE_DEVICES
          value: void
        - name: NVIDIA_DRIVER_ROOT
          value: "/"
        - name: CDI_ROOT
          value: "/var/run/cdi"
        - name: IMEX_DAEMON_PATH
          value: "/usr/bin/compute-domain-daemon"
EOF

# ---------------------------------------------------------------------------
# 14. Patch DaemonSet template ConfigMap for dry-run daemons
# ---------------------------------------------------------------------------
log_info "Patching DaemonSet template ConfigMap for dry-run daemon mode"

# Create a ConfigMap with the dry-run daemon DaemonSet template override.
# The controller uses this template when creating DaemonSets for ComputeDomains.
# Key difference: command uses real daemon binary with --dry-run flag.
cat <<'EOF' | kubectl apply -n "${DRIVER_NAMESPACE}" -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: cd-daemon-template-override
  namespace: nvidia-dra-driver
  labels:
    app: cd-daemon-template
data:
  daemon-command: |
    ["compute-domain-daemon", "-v", "$(LOG_VERBOSITY)", "--dry-run", "run"]
  liveness-command: |
    ["compute-domain-daemon", "--dry-run", "check"]
  readiness-command: |
    ["compute-domain-daemon", "--dry-run", "check"]
EOF

# ---------------------------------------------------------------------------
# 15. Label worker nodes with GB200 NVL72 rack topology
# ---------------------------------------------------------------------------
log_info "Labeling worker nodes with GB200 NVL72 rack topology (${NODES_PER_RACK} nodes/rack)"

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
# 16. Wait for all components to be ready
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
log_info "Dry-run kind cluster '${CLUSTER_NAME}' is ready"
log_info "  Worker nodes:       ${NUM_NODES}"
log_info "  GB200 topology:     ${NODES_PER_RACK} nodes/rack, ${GPUS_PER_NODE} GPUs/node"
log_info "  Simulated racks:    $(( (NUM_NODES + NODES_PER_RACK - 1) / NODES_PER_RACK ))"
log_info "  Controller:         Running"
log_info "  Kubelet plugins:    ${PLUGIN_PODS}"
log_info "  Daemon image:       ${DRYRUN_DAEMON_IMAGE} (real, --dry-run)"
log_info "  Daemon version:     ${DRYRUN_VERSION}"
log_info "  Namespace:          ${DRIVER_NAMESPACE}"
log_info "  Perf test NS:       ${NAMESPACE}"
log_info "========================================="
log_info "Run dry-run tests with:"
log_info "  ./test-dryrun-rack.sh --mode kind"
log_info "  ./test-dryrun-rack.sh --mode sim"
log_info "  ./test-dryrun-e2e.sh"
