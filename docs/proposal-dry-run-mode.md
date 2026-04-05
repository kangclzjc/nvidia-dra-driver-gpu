# Proposal: `--dry-run` Mode for compute-domain-daemon

**Authors:** @kang  
**Status:** Draft  
**Component:** compute-domain-daemon, compute-domain-controller  
**Scope:** Medium — New capability behind existing binaries, no new feature gate  

## Problem Statement

Performance testing of the ComputeDomain subsystem at scale (1000+ nodes) currently requires either:

1. **Real GB200 hardware** — expensive, limited availability
2. **A separate `fake-compute-domain-daemon` binary** — duplicates ~2000 lines of daemon code, diverges over time, requires separate build/image pipeline

Neither approach is sustainable. The fake daemon approach has already demonstrated code drift issues: CDClique registration, DNS negotiation, and readiness logic had to be manually re-implemented, introducing subtle behavioral differences from the real daemon.

### Specific pain points

- **Code duplication**: `fake-compute-domain-daemon` copies `cdclique.go`, `cdstatus.go`, `controller.go`, `podmanager.go`, `common.go` from the real daemon
- **Maintenance burden**: Any change to the real daemon's registration or DNS logic must be manually ported to the fake daemon
- **Behavioral divergence**: During testing, multiple bugs were discovered that only existed in the fake daemon, not the real one (namespace resolution, informer scope, feature gate version handling)
- **Build complexity**: Performance tests require building 4 separate images instead of 3

## Proposed Solution

Add a `--dry-run` flag to the existing `compute-domain-daemon` binary that skips all NVIDIA hardware dependencies while preserving all Kubernetes API operations.

### Design Principles

1. **Zero code duplication** — dry-run uses the same code paths as normal mode
2. **Zero impact on normal mode** — all changes behind `if flags.dryRun` guards
3. **Minimal surface area** — only 2 source files modified (main.go, dnsnames.go)
4. **Future-proof** — orthogonal to upcoming pre-provisioned DaemonSet mode

### What `--dry-run` preserves (identical to normal mode)

- CDClique CR creation and daemon registration (`cdclique.go`)
- ComputeDomain status updates (`cdstatus.go`)
- Controller work queue and reconciliation (`controller.go`)
- Pod label management (`addComputeDomainCliqueLabel`)
- DNS name negotiation and `/etc/hosts` updates (`dnsnames.go`)
- Readiness probe responses (`check` subcommand)

### What `--dry-run` skips

- `nvidia-imex` process startup and lifecycle management
- `ProcessManager` watchdog
- IMEX config file rendering (`/imexd/imexd.cfg`)
- CDI container edits validation (allows `COMPUTE_DOMAIN_UUID` via env var)

## Implementation Details

### CLI interface

```
compute-domain-daemon --dry-run run
compute-domain-daemon --dry-run check
```

| Flag | Env Var | Type | Default | Description |
|------|---------|------|---------|-------------|
| `--dry-run` | `DRY_RUN` | bool | `false` | Skip IMEX hardware dependencies |

### Files modified

| File | Changes |
|------|---------|
| `cmd/compute-domain-daemon/main.go` | Add `--dry-run` flag; conditional IMEX skip in `run()`; new `dryRunIMEXDaemonUpdateLoop()`; immediate success in `check()` |
| `cmd/compute-domain-daemon/dnsnames.go` | Add `dryRun` param to `NewDNSNameManager`; `/etc/hosts` fallback to `/tmp/hosts` when not writable |
| `templates/compute-domain-daemon.tmpl.yaml` | Conditional `--dry-run` in command via `{{- if .DryRun }}` |
| `cmd/compute-domain-controller/daemonset.go` | Add `DryRun bool` to template data; new `--dry-run-daemons` controller flag |

### Files NOT modified

`controller.go`, `cdclique.go`, `cdstatus.go`, `common.go`, `process.go`, `podmanager.go` — all pure Kubernetes API operations with no hardware dependency.

### Behavior matrix

| Component | Normal | `--dry-run` |
|-----------|--------|-------------|
| CDClique registration | ✅ | ✅ |
| DNS negotiation | ✅ | ✅ (writes to `/tmp/hosts` if `/etc/hosts` not writable) |
| Pod label updates | ✅ | ✅ |
| Controller reconciliation | ✅ | ✅ |
| IMEX config write | ✅ | ❌ skipped |
| `nvidia-imex` process | ✅ | ❌ skipped |
| ProcessManager watchdog | ✅ | ❌ skipped |
| `check` subcommand | Runs `nvidia-imex-ctl -q` | Returns success immediately |

### Controller integration

The controller gains a `--dry-run-daemons` flag (env: `DRY_RUN_DAEMONS`). When enabled, the DaemonSet template is rendered with `--dry-run` in the daemon command line. This is the only change needed for the controller — all DaemonSet creation, CDClique management, and status synchronization logic remains unchanged.

## Alternatives Considered

### 1. Separate `fake-compute-domain-daemon` binary (current approach)

**Pros:** No changes to production code  
**Cons:** Code duplication, maintenance burden, behavioral divergence, additional build target  
**Verdict:** Not sustainable at scale

### 2. Mock at the `ProcessManager` level

**Pros:** Smaller change (only mock the process manager)  
**Cons:** Doesn't address CDI validation check, IMEX config write, or `/etc/hosts` writability  
**Verdict:** Insufficient

### 3. KWOK-based simulation

**Pros:** No daemon code changes needed  
**Cons:** KWOK nodes don't run kubelet → no DRA plugin → no ResourceClaim allocation → no CDClique registration (daemon code doesn't execute)  
**Verdict:** Cannot test daemon registration or DNS negotiation

## Performance Testing Results

Using the fake daemon approach (which `--dry-run` would replace), we collected the following data on a 4-core/16GB machine with kind:

### CDClique Registration (no DNS wait, CDCliques feature gate enabled)

| Scale | Pod startup | CDClique registration | Total |
|-------|------------|----------------------|-------|
| 1 rack (18 nodes) | 5s | 13s | ~20s |
| 2 racks (36 nodes) | 8s | 20s | ~32s |
| 4 racks (72 nodes) | 14s | 24s | ~63s |

### Bugs discovered during testing

1. **CD Status write contention (non-CDClique path):** Controller's 2s sync overwrites daemon-written node entries using stale informer cache. Multi-node ComputeDomains may never reach Ready state.

2. **CDClique `cleanupClique()` unconditional overwrite:** Even when no stale entries need removal, the controller rewrites the entire `daemons` array from informer cache, overwriting daemon-written `status=Ready` fields. Fix: skip write when `len(removedNodes) == 0`.

## Future Extensions

### Pre-provisioned DaemonSet mode

`--dry-run` is orthogonal to a planned mode where DaemonSets are created ahead of ComputeDomains. Combined usage: `--dry-run --pre-start` enables hardware-free testing of pre-provisioned daemon lifecycle.

### Simulation parameters

Optional dry-run sub-flags for advanced testing scenarios:

```
--dry-run-startup-delay    Simulate IMEX startup time (default: 0)
--dry-run-ready-delay      Delay before marking Ready (default: 0)
--dry-run-failure-rate     Random failure injection (default: 0)
```

## Backward Compatibility

- `--dry-run` defaults to `false` — zero behavioral change when not specified
- `NewDNSNameManager` signature adds `dryRun bool` parameter (internal API only, single call site)
- DaemonSet template renders identically when `DryRun=false`
- No API changes, no new CRDs, no new feature gates
