#!/bin/bash
# create-fake-nodes.sh - Create fake Node objects in the cluster
# Usage: ./create-fake-nodes.sh [NUM_NODES]
set -euo pipefail

NUM_NODES=${1:-18}
NODES_PER_RACK=18
CTX="kind-dra-perf"

echo "Creating ${NUM_NODES} fake nodes..."

for i in $(seq 1 "$NUM_NODES"); do
  rack=$(( (i - 1) / NODES_PER_RACK + 1 ))
  node_in_rack=$(( (i - 1) % NODES_PER_RACK + 1 ))
  node_name=$(printf "fake-rack%04d-node%02d" $rack $node_in_rack)

  # Create node
  kubectl --context "$CTX" apply -f - <<EOF >/dev/null 2>&1
apiVersion: v1
kind: Node
metadata:
  name: ${node_name}
  labels:
    node.kubernetes.io/fake: "true"
    topology.kubernetes.io/rack: "rack-$(printf '%04d' $rack)"
    kubernetes.io/os: linux
    kubernetes.io/arch: amd64
spec:
  taints:
    - key: node.kubernetes.io/fake
      effect: NoSchedule
EOF

  # Patch status to Ready
  kubectl --context "$CTX" patch node "${node_name}" --subresource=status --type=merge -p '{
    "status": {
      "conditions": [{
        "type": "Ready",
        "status": "True",
        "lastHeartbeatTime": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'",
        "lastTransitionTime": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'",
        "reason": "FakeNodeReady",
        "message": "Fake node for perf testing"
      }],
      "capacity": {
        "cpu": "128",
        "memory": "1099511627776",
        "pods": "110",
        "nvidia.com/gpu": "4"
      },
      "allocatable": {
        "cpu": "128",
        "memory": "1099511627776",
        "pods": "110",
        "nvidia.com/gpu": "4"
      },
      "nodeInfo": {
        "machineID": "'$(uuidgen 2>/dev/null || echo "fake-${node_name}")'",
        "systemUUID": "'$(uuidgen 2>/dev/null || echo "fake-${node_name}")'",
        "bootID": "'$(uuidgen 2>/dev/null || echo "fake-${node_name}")'",
        "kernelVersion": "5.15.0-fake",
        "osImage": "Fake Node",
        "containerRuntimeVersion": "containerd://1.7.0",
        "kubeletVersion": "v1.35.1",
        "kubeProxyVersion": "v1.35.1",
        "operatingSystem": "linux",
        "architecture": "amd64"
      }
    }
  }' >/dev/null 2>&1

  echo -ne "\r  Created: ${node_name} (${i}/${NUM_NODES})"
done

echo ""
total_racks=$(( (NUM_NODES + NODES_PER_RACK - 1) / NODES_PER_RACK ))
echo "Done. ${NUM_NODES} fake nodes in ${total_racks} racks."
kubectl --context "$CTX" get nodes --selector=node.kubernetes.io/fake=true --no-headers | wc -l | xargs -I{} echo "Verified: {} fake nodes in cluster"
