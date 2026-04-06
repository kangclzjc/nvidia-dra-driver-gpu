#!/bin/bash
# create-resource-slices.sh - Create fake ResourceSlice objects for each fake node
# Uses resource.k8s.io/v1 schema (K8s 1.35+)
set -euo pipefail

NUM_NODES=${1:-18}
NODES_PER_RACK=18
CTX="kind-dra-perf"
DRIVER_NAME="nvidia.com"

echo "Creating ResourceSlices for ${NUM_NODES} fake nodes..."

for i in $(seq 1 "$NUM_NODES"); do
  rack=$(( (i - 1) / NODES_PER_RACK + 1 ))
  node_in_rack=$(( (i - 1) % NODES_PER_RACK + 1 ))
  node_name=$(printf "fake-rack%04d-node%02d" $rack $node_in_rack)
  rack_label=$(printf "rack-%04d" $rack)

  kubectl --context "$CTX" apply -f - <<EOF >/dev/null 2>&1
apiVersion: resource.k8s.io/v1
kind: ResourceSlice
metadata:
  name: ${node_name}-gpus
spec:
  driver: ${DRIVER_NAME}
  pool:
    name: ${node_name}
    generation: 1
    resourceSliceCount: 1
  nodeName: ${node_name}
  devices:
    - name: gpu-0
      attributes:
        gpuIndex:
          int: 0
        gpuModel:
          string: "NVIDIA-B200"
        rack:
          string: "${rack_label}"
      capacity:
        memory:
          value: "80Gi"
    - name: gpu-1
      attributes:
        gpuIndex:
          int: 1
        gpuModel:
          string: "NVIDIA-B200"
        rack:
          string: "${rack_label}"
      capacity:
        memory:
          value: "80Gi"
    - name: gpu-2
      attributes:
        gpuIndex:
          int: 2
        gpuModel:
          string: "NVIDIA-B200"
        rack:
          string: "${rack_label}"
      capacity:
        memory:
          value: "80Gi"
    - name: gpu-3
      attributes:
        gpuIndex:
          int: 3
        gpuModel:
          string: "NVIDIA-B200"
        rack:
          string: "${rack_label}"
      capacity:
        memory:
          value: "80Gi"
    - name: daemon
      attributes:
        deviceType:
          string: "daemon"
        rack:
          string: "${rack_label}"
EOF

  if [ $? -ne 0 ]; then
    echo "ERROR creating ResourceSlice for ${node_name}"
    # Debug: try with verbose
    kubectl --context "$CTX" apply -f - <<EOF 2>&1
apiVersion: resource.k8s.io/v1
kind: ResourceSlice
metadata:
  name: ${node_name}-gpus
spec:
  driver: ${DRIVER_NAME}
  pool:
    name: ${node_name}
    generation: 1
    resourceSliceCount: 1
  nodeName: ${node_name}
  devices:
    - name: gpu-0
      attributes:
        gpuIndex:
          int: 0
EOF
    exit 1
  fi

  echo -ne "\r  Created ResourceSlice: ${node_name} (${i}/${NUM_NODES})"
done

echo ""
echo "Done."
kubectl --context "$CTX" get resourceslices --no-headers 2>/dev/null | wc -l | xargs -I{} echo "Verified: {} ResourceSlices in cluster"
