# DRA ComputeDomain Performance Test Results
# Date: 2026-04-06
# Environment: kind cluster on 4vCPU/16GB (AMD EPYC 7B13)
# K8s: v1.35.1, DRA enabled
# Scale: 1000 fake nodes, 56 racks (18 node/rack), 1000 ResourceSlices

## Test 1: Single CD Create→Ready Latency

| Iteration | Latency |
|-----------|---------|
| 1 (cold)  | 1196ms  |
| 2         | 726ms   |
| 3         | 339ms   |
| 4         | 437ms   |
| 5         | 339ms   |

**Summary: min=339ms  avg=626ms  max=1196ms**

First iteration (cold) is slower due to informer cache warming.
Warm iterations converge to ~340-440ms.

## Test 2: 56 CDs Concurrent Create (1 per rack)

- Submit all 56 CDs: **5,202ms**
- All 56 Ready: **61,242ms** (~61s)
- Progression: linear ramp-up, ~1.5 CD/s reaching Ready
- DaemonSets created: 56 ✅
- Daemon pods: 0 (expected - fake nodes have no kubelet)

## Test 3: Batch Delete 56 CDs

- Submit delete commands: **5,469ms**
- All 56 deleted (with finalizer cleanup): **80,458ms** (~80s)
- DaemonSets cleaned up: 56/56 ✅

## Test 4: Rapid Create/Delete Cycle (10 iterations)

| Cycle | Create | Delete | Total  |
|-------|--------|--------|--------|
| 1     | 499ms  | 458ms  | 957ms  |
| 2     | 693ms  | 332ms  | 1025ms |
| 3     | 880ms  | 620ms  | 1500ms |
| 4     | 501ms  | 388ms  | 889ms  |
| 5     | 587ms  | 722ms  | 1309ms |
| 6     | 500ms  | 400ms  | 900ms  |
| 7     | 796ms  | 628ms  | 1424ms |
| 8     | 475ms  | 510ms  | 985ms  |
| 9     | 844ms  | 496ms  | 1340ms |
| 10    | 926ms  | 538ms  | 1464ms |

**Summary: min=889ms  avg=1179ms  max=1500ms**

## Resource Consumption

| Component | Memory | CPU |
|-----------|--------|-----|
| Control plane (apiserver+etcd+scheduler+cm) | 1.29 GB | ~14% |
| Worker | 227 MB | <1% |
| Host total used | 9.0 GB | - |
| Host available | 6.1 GB | - |

## API Latency at Scale

| Operation | 18 nodes | 90 nodes | 200 nodes | 500 nodes | 1000 nodes |
|-----------|----------|----------|-----------|-----------|------------|
| get nodes | 173ms | 288ms | 349ms | 670ms | 1027ms |
| get resourceslices | 222ms | 245ms | 265ms | 439ms | 777ms |
| get computedomains (56 CDs) | - | - | - | - | 194ms |

## Key Findings

1. **1000 nodes on 4vCPU/16GB** - Control plane only uses 1.3GB RAM
2. **Single CD lifecycle** - ~340-500ms warm, including DaemonSet creation
3. **56 CD concurrent** - All Ready in ~61s, linear progression
4. **Delete with finalizers** - Cleanup takes ~80s for 56 CDs (heavy: finalizer removal + DaemonSet deletion + assertion)
5. **Bottleneck is controller serialization** - One reconcile at a time per work queue item
6. **No daemon pods actually run** - Fake nodes have no kubelet, so DaemonSet pods stay Pending. This tests controller reconcile only.
7. **To test daemon dry-run** - Need real nodes (or KWOK with kubelet simulation) to schedule daemon pods
