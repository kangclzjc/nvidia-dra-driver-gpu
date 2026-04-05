/*
Copyright The Kubernetes Authors

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    https://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

// Package main implements a daemon-simulator that runs N goroutines in a
// single process, each simulating one fake-compute-domain-daemon's CDClique
// registration behavior. This eliminates Deployment creation overhead from
// ComputeDomain performance benchmarks.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"math/rand/v2"
	"os"
	"os/signal"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"
	"k8s.io/klog/v2"

	"github.com/urfave/cli/v2"

	nvapi "sigs.k8s.io/nvidia-dra-driver-gpu/api/nvidia.com/resource/v1beta1"
	"sigs.k8s.io/nvidia-dra-driver-gpu/internal/info"
	nvclientset "sigs.k8s.io/nvidia-dra-driver-gpu/pkg/nvidia.com/clientset/versioned"
)

const (
	// Label keys matching the real daemon.
	computeDomainLabelKey       = "resource.nvidia.com/computeDomain"
	computeDomainCliqueLabelKey = "resource.nvidia.com/computeDomain.cliqueID"
)

// Flags holds all CLI flag values.
type Flags struct {
	nodes         int
	nodesPerRack  int
	cdUID         string
	cdName        string
	cdNamespace   string
	namespace     string
	startupJitter time.Duration
	readyDelay    time.Duration
	timeout       time.Duration
	kubeconfig    string
	kubeAPIQPS    float64
	kubeAPIBurst  int
}

// Result is the JSON output written to stdout on completion.
type Result struct {
	TotalNodes   int           `json:"totalNodes"`
	TotalCliques int           `json:"totalCliques"`
	TotalTime    Duration      `json:"totalTime"`
	Racks        []RackResult  `json:"racks"`
	AllReady     bool          `json:"allReady"`
}

// RackResult holds per-rack timing information.
type RackResult struct {
	RackID          int      `json:"rackId"`
	CliqueName      string   `json:"cliqueName"`
	Nodes           int      `json:"nodes"`
	RegisterTime    Duration `json:"registerTime"`
	ReadyTime       Duration `json:"readyTime"`
}

// Duration wraps time.Duration for human-readable JSON output.
type Duration struct {
	time.Duration
}

func (d Duration) MarshalJSON() ([]byte, error) {
	return json.Marshal(d.Duration.String())
}

func main() {
	if err := newApp().Run(os.Args); err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}
}

func newApp() *cli.App {
	flags := &Flags{}

	return &cli.App{
		Name:    "daemon-simulator",
		Usage:   "Simulate N compute-domain-daemons in a single process for CDClique registration benchmarks.",
		Version: info.GetVersionString(),
		Flags: []cli.Flag{
			&cli.IntFlag{
				Name:        "nodes",
				Usage:       "Total number of simulated daemon nodes.",
				Value:       18,
				Destination: &flags.nodes,
			},
			&cli.IntFlag{
				Name:        "nodes-per-rack",
				Usage:       "Number of nodes per rack (determines clique grouping).",
				Value:       18,
				Destination: &flags.nodesPerRack,
			},
			&cli.StringFlag{
				Name:        "cd-uid",
				Usage:       "ComputeDomain UID (required).",
				Required:    true,
				Destination: &flags.cdUID,
			},
			&cli.StringFlag{
				Name:        "cd-name",
				Usage:       "ComputeDomain name (required).",
				Required:    true,
				Destination: &flags.cdName,
			},
			&cli.StringFlag{
				Name:        "cd-namespace",
				Usage:       "ComputeDomain namespace.",
				Value:       "default",
				Destination: &flags.cdNamespace,
			},
			&cli.StringFlag{
				Name:        "namespace",
				Usage:       "Namespace where CDClique CRs are created (daemon namespace).",
				Value:       "nvidia-dra-driver",
				Destination: &flags.namespace,
			},
			&cli.DurationFlag{
				Name:        "startup-jitter",
				Usage:       "Maximum random delay before each goroutine starts registration.",
				Value:       2 * time.Second,
				Destination: &flags.startupJitter,
			},
			&cli.DurationFlag{
				Name:        "ready-delay",
				Usage:       "Delay after successful registration before marking Ready.",
				Value:       1 * time.Second,
				Destination: &flags.readyDelay,
			},
			&cli.DurationFlag{
				Name:        "timeout",
				Usage:       "Global timeout for the entire simulation.",
				Value:       5 * time.Minute,
				Destination: &flags.timeout,
			},
			&cli.StringFlag{
				Name:        "kubeconfig",
				Usage:       "Path to kubeconfig file. Uses in-cluster config if not set.",
				EnvVars:     []string{"KUBECONFIG"},
				Destination: &flags.kubeconfig,
			},
			&cli.Float64Flag{
				Name:        "kube-api-qps",
				Usage:       "QPS for Kubernetes API requests.",
				Value:       50,
				Destination: &flags.kubeAPIQPS,
			},
			&cli.IntFlag{
				Name:        "kube-api-burst",
				Usage:       "Burst for Kubernetes API requests.",
				Value:       100,
				Destination: &flags.kubeAPIBurst,
			},
		},
		Action: func(c *cli.Context) error {
			return runSimulation(c.Context, flags)
		},
	}
}

func newKubeConfig(flags *Flags) (*rest.Config, error) {
	var cfg *rest.Config
	var err error

	if flags.kubeconfig == "" {
		cfg, err = rest.InClusterConfig()
		if err != nil {
			return nil, fmt.Errorf("in-cluster config: %w", err)
		}
	} else {
		cfg, err = clientcmd.BuildConfigFromFlags("", flags.kubeconfig)
		if err != nil {
			return nil, fmt.Errorf("kubeconfig: %w", err)
		}
	}

	cfg.QPS = float32(flags.kubeAPIQPS)
	cfg.Burst = flags.kubeAPIBurst
	return cfg, nil
}

func runSimulation(parentCtx context.Context, flags *Flags) error {
	ctx, cancel := context.WithTimeout(parentCtx, flags.timeout)
	defer cancel()

	// Handle SIGTERM gracefully.
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGTERM, syscall.SIGINT)
	go func() {
		<-sigChan
		klog.Infof("Received signal, shutting down")
		cancel()
	}()

	restConfig, err := newKubeConfig(flags)
	if err != nil {
		return fmt.Errorf("failed to create kube config: %w", err)
	}

	nvClient, err := nvclientset.NewForConfig(restConfig)
	if err != nil {
		return fmt.Errorf("failed to create nvidia clientset: %w", err)
	}

	// Calculate rack/clique distribution.
	numRacks := (flags.nodes + flags.nodesPerRack - 1) / flags.nodesPerRack

	klog.Infof("Starting daemon-simulator: nodes=%d, nodesPerRack=%d, racks=%d, cd=%s/%s (uid=%s)",
		flags.nodes, flags.nodesPerRack, numRacks, flags.cdNamespace, flags.cdName, flags.cdUID)

	// Shared progress counters.
	var registered atomic.Int64
	var ready atomic.Int64
	var cliquesCreated atomic.Int64

	// Per-rack timing: first registration time and last ready time.
	type rackTiming struct {
		mu            sync.Mutex
		firstRegStart time.Time
		lastRegEnd    time.Time
		lastReadyEnd  time.Time
		nodeCount     int
	}
	rackTimings := make([]*rackTiming, numRacks)
	for i := range rackTimings {
		rackTimings[i] = &rackTiming{}
	}

	startTime := time.Now()

	// Start progress reporter.
	progressDone := make(chan struct{})
	go func() {
		defer close(progressDone)
		ticker := time.NewTicker(1 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				r := registered.Load()
				rd := ready.Load()
				c := cliquesCreated.Load()
				elapsed := time.Since(startTime).Round(time.Millisecond)
				fmt.Fprintf(os.Stderr, "[%s] registered: %d/%d, ready: %d/%d, cliques: %d\n",
					elapsed, r, flags.nodes, rd, flags.nodes, c)
				if rd == int64(flags.nodes) {
					return
				}
			}
		}
	}()

	// Use sync.Once per clique to avoid redundant creation.
	cliqueOnce := make([]sync.Once, numRacks)

	var wg sync.WaitGroup

	for nodeID := 0; nodeID < flags.nodes; nodeID++ {
		wg.Add(1)
		go func(nodeID int) {
			defer wg.Done()

			rackID := nodeID / flags.nodesPerRack
			cliqueID := fmt.Sprintf("clique-%d", rackID)
			cliqueName := fmt.Sprintf("%s.%s", flags.cdUID, cliqueID)
			nodeName := fmt.Sprintf("sim-node-%d", nodeID)
			podIP := fmt.Sprintf("10.%d.%d.%d", rackID, (nodeID/256)%256, nodeID%256)

			rt := rackTimings[rackID]
			rt.mu.Lock()
			rt.nodeCount++
			rt.mu.Unlock()

			// 1. Random startup jitter.
			if flags.startupJitter > 0 {
				jitter := time.Duration(rand.Int64N(int64(flags.startupJitter)))
				select {
				case <-ctx.Done():
					return
				case <-time.After(jitter):
				}
			}

			regStart := time.Now()
			rt.mu.Lock()
			if rt.firstRegStart.IsZero() || regStart.Before(rt.firstRegStart) {
				rt.firstRegStart = regStart
			}
			rt.mu.Unlock()

			// 2. Ensure CDClique CR exists (one goroutine per rack creates it).
			cliqueOnce[rackID].Do(func() {
				if err := ensureCliqueExists(ctx, nvClient, flags, cliqueName, cliqueID); err != nil {
					klog.Errorf("node %d: failed to create clique %s: %v", nodeID, cliqueName, err)
					return
				}
				cliquesCreated.Add(1)
				klog.Infof("node %d: created clique %s", nodeID, cliqueName)
			})

			// 3. Register self into CDClique with conflict retry (exponential backoff).
			var regErr error
			for attempt := 0; attempt < 60; attempt++ {
				regErr = registerDaemon(ctx, nvClient, flags, cliqueName, nodeName, podIP, cliqueID, nodeID)
				if regErr == nil {
					break
				}
				klog.Errorf("node %d: registration failed (attempt %d): %v", nodeID, attempt, regErr)
				// Exponential backoff with jitter: 100ms → 200ms → 400ms → ... → 6s max
				backoff := time.Duration(100<<uint(min(attempt, 6))) * time.Millisecond
				jitter := time.Duration(rand.N(int64(backoff / 2)))
				select {
				case <-ctx.Done():
					return
				case <-time.After(backoff + jitter):
				}
			}
			if regErr != nil {
				klog.Errorf("node %d: registration gave up after retries: %v", nodeID, regErr)
				return
			}
			registered.Add(1)

			regEnd := time.Now()
			rt.mu.Lock()
			if regEnd.After(rt.lastRegEnd) {
				rt.lastRegEnd = regEnd
			}
			rt.mu.Unlock()

			klog.Infof("node %d: registered in clique %s", nodeID, cliqueName)

			// 4. Wait ready-delay then mark Ready.
			select {
			case <-ctx.Done():
				return
			case <-time.After(flags.readyDelay):
			}

			if err := markReady(ctx, nvClient, flags, cliqueName, nodeName); err != nil {
				// Retry markReady a few times
				for retry := 0; retry < 10; retry++ {
					klog.Errorf("node %d: failed to mark ready (attempt %d): %v", nodeID, retry, err)
					select {
					case <-ctx.Done():
						return
					case <-time.After(time.Duration(200*(retry+1)) * time.Millisecond):
					}
					err = markReady(ctx, nvClient, flags, cliqueName, nodeName)
					if err == nil {
						break
					}
				}
				if err != nil {
					klog.Errorf("node %d: gave up marking ready: %v", nodeID, err)
					return
				}
				return
			}
			ready.Add(1)

			readyEnd := time.Now()
			rt.mu.Lock()
			if readyEnd.After(rt.lastReadyEnd) {
				rt.lastReadyEnd = readyEnd
			}
			rt.mu.Unlock()

			klog.Infof("node %d: ready", nodeID)
		}(nodeID)
	}

	wg.Wait()
	<-progressDone

	totalTime := time.Since(startTime)

	// Print final progress line.
	fmt.Fprintf(os.Stderr, "\n=== Simulation Complete ===\n")
	fmt.Fprintf(os.Stderr, "Total: %d nodes, %d cliques, %s\n\n",
		registered.Load(), cliquesCreated.Load(), totalTime.Round(time.Millisecond))

	// Build per-rack results.
	rackResults := make([]RackResult, numRacks)
	for i := 0; i < numRacks; i++ {
		rt := rackTimings[i]
		cliqueName := fmt.Sprintf("%s.clique-%d", flags.cdUID, i)
		var regTime, readyTime time.Duration
		if !rt.lastRegEnd.IsZero() && !rt.firstRegStart.IsZero() {
			regTime = rt.lastRegEnd.Sub(rt.firstRegStart)
		}
		if !rt.lastReadyEnd.IsZero() && !rt.firstRegStart.IsZero() {
			readyTime = rt.lastReadyEnd.Sub(rt.firstRegStart)
		}
		rackResults[i] = RackResult{
			RackID:       i,
			CliqueName:   cliqueName,
			Nodes:        rt.nodeCount,
			RegisterTime: Duration{regTime},
			ReadyTime:    Duration{readyTime},
		}
		fmt.Fprintf(os.Stderr, "  Rack %d (%s): %d nodes, register=%s, ready=%s\n",
			i, cliqueName, rt.nodeCount,
			regTime.Round(time.Millisecond),
			readyTime.Round(time.Millisecond))
	}

	result := Result{
		TotalNodes:   int(registered.Load()),
		TotalCliques: int(cliquesCreated.Load()),
		TotalTime:    Duration{totalTime},
		Racks:        rackResults,
		AllReady:     ready.Load() == int64(flags.nodes),
	}

	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	if err := enc.Encode(result); err != nil {
		return fmt.Errorf("failed to encode result JSON: %w", err)
	}

	if !result.AllReady {
		return fmt.Errorf("not all nodes became ready: %d/%d", ready.Load(), flags.nodes)
	}

	return nil
}

// ensureCliqueExists creates the CDClique CR if it does not already exist.
func ensureCliqueExists(ctx context.Context, client nvclientset.Interface, flags *Flags, cliqueName, cliqueID string) error {
	_, err := client.ResourceV1beta1().ComputeDomainCliques(flags.namespace).Get(ctx, cliqueName, metav1.GetOptions{})
	if err == nil {
		return nil // already exists
	}

	newClique := &nvapi.ComputeDomainClique{
		ObjectMeta: metav1.ObjectMeta{
			Name:      cliqueName,
			Namespace: flags.namespace,
			Labels: map[string]string{
				computeDomainLabelKey:       flags.cdUID,
				computeDomainCliqueLabelKey: cliqueID,
			},
			OwnerReferences: []metav1.OwnerReference{
				{
					APIVersion: nvapi.SchemeGroupVersion.String(),
					Kind:       "ComputeDomain",
					Name:       flags.cdName,
					UID:        types.UID(flags.cdUID),
				},
			},
		},
	}

	_, err = client.ResourceV1beta1().ComputeDomainCliques(flags.namespace).Create(ctx, newClique, metav1.CreateOptions{})
	if err != nil {
		// Ignore AlreadyExists (another goroutine may have won the race).
		if isAlreadyExists(err) {
			return nil
		}
		return fmt.Errorf("create CDClique %s: %w", cliqueName, err)
	}
	return nil
}

// registerDaemon reads the CDClique, appends this daemon's info, and writes it
// back. On conflict, it retries with exponential backoff (5ms-6s, 0.5 jitter)
// matching the real daemon's rate limiter.
func registerDaemon(ctx context.Context, client nvclientset.Interface, flags *Flags, cliqueName, nodeName, podIP, cliqueID string, nodeID int) error {
	backoff := 5 * time.Millisecond
	maxBackoff := 6 * time.Second

	for {
		clique, err := client.ResourceV1beta1().ComputeDomainCliques(flags.namespace).Get(ctx, cliqueName, metav1.GetOptions{})
		if err != nil {
			return fmt.Errorf("get CDClique %s: %w", cliqueName, err)
		}

		// Check if already registered.
		for _, d := range clique.Daemons {
			if d.NodeName == nodeName {
				// Already registered (possibly from a retry after a successful write
				// where the response was lost). Nothing to do.
				return nil
			}
		}

		// Find next available index.
		nextIndex := getNextAvailableIndex(clique.Daemons)

		newClique := clique.DeepCopy()
		newClique.Daemons = append(newClique.Daemons, &nvapi.ComputeDomainDaemonInfo{
			NodeName:  nodeName,
			IPAddress: podIP,
			CliqueID:  cliqueID,
			Index:     nextIndex,
			Status:    nvapi.ComputeDomainStatusNotReady,
		})

		// Ensure OwnerReference is present.
		ensureOwnerReference(newClique, flags)

		_, err = client.ResourceV1beta1().ComputeDomainCliques(flags.namespace).Update(ctx, newClique, metav1.UpdateOptions{})
		if err == nil {
			return nil
		}

		if !isConflict(err) {
			return fmt.Errorf("update CDClique %s: %w", cliqueName, err)
		}

		// Conflict: retry with exponential backoff + jitter.
		jitter := time.Duration(float64(backoff) * (0.5 + rand.Float64()*0.5))
		klog.V(2).Infof("node %d: conflict on CDClique %s, retrying in %v", nodeID, cliqueName, jitter)

		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(jitter):
		}

		backoff *= 2
		if backoff > maxBackoff {
			backoff = maxBackoff
		}
	}
}

// markReady updates this daemon's status to Ready in the CDClique.
func markReady(ctx context.Context, client nvclientset.Interface, flags *Flags, cliqueName, nodeName string) error {
	backoff := 5 * time.Millisecond
	maxBackoff := 6 * time.Second

	for {
		clique, err := client.ResourceV1beta1().ComputeDomainCliques(flags.namespace).Get(ctx, cliqueName, metav1.GetOptions{})
		if err != nil {
			return fmt.Errorf("get CDClique %s: %w", cliqueName, err)
		}

		newClique := clique.DeepCopy()
		found := false
		for _, d := range newClique.Daemons {
			if d.NodeName == nodeName {
				if d.Status == nvapi.ComputeDomainStatusReady {
					return nil // already ready
				}
				d.Status = nvapi.ComputeDomainStatusReady
				found = true
				break
			}
		}

		if !found {
			return fmt.Errorf("daemon %s not found in CDClique %s", nodeName, cliqueName)
		}

		_, err = client.ResourceV1beta1().ComputeDomainCliques(flags.namespace).Update(ctx, newClique, metav1.UpdateOptions{})
		if err == nil {
			return nil
		}

		if !isConflict(err) {
			return fmt.Errorf("update CDClique %s: %w", cliqueName, err)
		}

		jitter := time.Duration(float64(backoff) * (0.5 + rand.Float64()*0.5))
		klog.V(2).Infof("node %s: conflict marking ready in %s, retrying in %v", nodeName, cliqueName, jitter)

		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(jitter):
		}

		backoff *= 2
		if backoff > maxBackoff {
			backoff = maxBackoff
		}
	}
}

// getNextAvailableIndex finds the lowest unused index among existing daemons.
func getNextAvailableIndex(daemons []*nvapi.ComputeDomainDaemonInfo) int {
	used := make(map[int]bool, len(daemons))
	for _, d := range daemons {
		used[d.Index] = true
	}
	idx := 0
	for used[idx] {
		idx++
	}
	return idx
}

// ensureOwnerReference adds a ComputeDomain OwnerReference if not already present.
func ensureOwnerReference(clique *nvapi.ComputeDomainClique, flags *Flags) {
	for _, ref := range clique.OwnerReferences {
		if string(ref.UID) == flags.cdUID {
			return
		}
	}
	clique.OwnerReferences = append(clique.OwnerReferences, metav1.OwnerReference{
		APIVersion: nvapi.SchemeGroupVersion.String(),
		Kind:       "ComputeDomain",
		Name:       flags.cdName,
		UID:        types.UID(flags.cdUID),
	})
}

// isConflict checks for HTTP 409 Conflict errors.
func isConflict(err error) bool {
	if err == nil {
		return false
	}
	// Use k8s.io/apimachinery errors.
	type statusError interface {
		Status() metav1.Status
	}
	if se, ok := err.(statusError); ok {
		return se.Status().Code == 409
	}
	return false
}

// isAlreadyExists checks for HTTP 409 AlreadyExists errors.
func isAlreadyExists(err error) bool {
	if err == nil {
		return false
	}
	type statusError interface {
		Status() metav1.Status
	}
	if se, ok := err.(statusError); ok {
		return se.Status().Reason == metav1.StatusReasonAlreadyExists
	}
	return false
}
