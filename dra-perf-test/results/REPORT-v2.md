# DRA ComputeDomain E2E Performance Report

## Environment
- **Machine:** 4 vCPU / 16GB RAM (AMD EPYC 7B13), GCP
- **Cluster:** kind + K8s 1.35.1 + DRA enabled
- **Scale:** 1000 fake nodes / 56 racks / 1000 ResourceSlices
- **Test scope:** 1 rack = 18 nodes

## Components
- **Controller:** Real `compute-domain-controller` binary
- **Daemon:** Real `compute-domain-daemon` binary with `--dry-run`
- **Kubelet Plugin:** Real `fake-cd-kubelet-plugin` binary (1 channel/node)
- All 3 are real compiled binaries from `k8s-dra-driver` repo

## CD Lifecycle Benchmark (plugin pre-deployed, not timed)

| Metric | Iter 1 | Iter 2 | Average |
|--------|--------|--------|---------|
| CD Create | 2440ms | 2461ms | **2450ms** |
| Daemon submit (18 pods) | 9013ms | 10226ms | **9620ms** |
| Daemon all Running | 13520ms | 17127ms | **15324ms** |
| **E2E: CD Create → Ready** | **17625ms** | **22890ms** | **~20s** |
| Teardown (18 daemon + CD) | 8091ms | 6849ms | **7470ms** |
| Total cycle | 25863ms | 29973ms | **~28s** |

### Breakdown

```
CD Create→Ready ~20s consists of:
├── CD API creation:         ~2.5s
├── Delete auto-DaemonSet:   ~1s  
├── 18 daemon pod submit:    ~10s (kubectl create overhead)
├── 18 daemon pod Running:   ~5s  (container startup)
└── Node registration→Ready: ~2s  (daemon→apiserver sync)
```

### Key Insight
The largest chunk (~10s) is `kubectl create` overhead for 18 sequential pod creates.
In production, DaemonSet handles this — pods are scheduled in parallel by the DaemonSet controller.
The actual daemon startup + registration time is only **~7s** (Running + Ready).

## Bug Fixes Required for Testing

Three issues discovered and fixed to achieve Ready status:

1. **Missing label:** Daemon pods need `resource.nvidia.com/computeDomain: <CD-UUID>` label
   - Without it, controller's CDStatusSync can't find daemon pods → overwrites status to empty

2. **DaemonSet conflict:** Controller auto-creates a DaemonSet with matching label selector
   - DaemonSet adopts/deletes manually created pods → must delete DaemonSet first

3. **Pod IP mismatch:** Daemon's `--pod-ip` must match real `pod.Status.PodIP`
   - CDStatusSync uses `pod.Status.PodIP` to match against CD status entries
   - Fix: use `fieldRef: status.podIP` env var instead of hardcoded IP

## Resource Usage (peak, during 18 daemon + 18 plugin running)

| Component | Memory | CPU |
|-----------|--------|-----|
| Control Plane | ~1.5 GB | 10-50% |
| Worker (36 pods) | ~700 MB | 25-45% |
| Host available | ~5.9 GB | |

## Scripts

- `test-e2e-rack-v3.sh --setup` — Deploy plugins (warmup)
- `test-e2e-rack-v3.sh --test N` — Run N benchmark iterations
- `test-e2e-rack-v3.sh --cleanup` — Tear down
- `test-e2e-rack-v3.sh all` — Full sequence
