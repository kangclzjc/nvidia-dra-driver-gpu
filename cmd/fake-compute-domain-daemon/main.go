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

// Package main implements a fake compute-domain-daemon that replicates all
// Kubernetes API interactions of the real compute-domain-daemon but skips
// hardware dependencies (IMEX daemon, CDI edits, GPU detection). It is
// intended for large-scale performance testing in environments without
// NVIDIA GPU hardware.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"math/rand/v2"
	"os"
	"os/signal"
	"strings"
	"sync"
	"syscall"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/klog/v2"

	"github.com/urfave/cli/v2"

	nvapi "sigs.k8s.io/nvidia-dra-driver-gpu/api/nvidia.com/resource/v1beta1"
	"sigs.k8s.io/nvidia-dra-driver-gpu/pkg/featuregates"
	pkgflags "sigs.k8s.io/nvidia-dra-driver-gpu/pkg/flags"
)

// Flags holds all CLI flag values for the fake daemon.
type Flags struct {
	cliqueID               string
	computeDomainUUID      string
	computeDomainName      string
	computeDomainNamespace string
	nodeName               string
	podIP                  string
	podUID                 string
	podName                string
	podNamespace           string
	maxNodesPerIMEXDomain  int
	klogVerbosity          int

	// Simulation parameters
	startupDelay   time.Duration
	readyDelay     time.Duration
	dnsSettleDelay time.Duration
	failureRate    float64
}

func main() {
	if err := newApp().Run(os.Args); err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}
}

func newApp() *cli.App {
	loggingConfig := pkgflags.NewLoggingConfig()
	featureGateConfig := pkgflags.NewFeatureGateConfig()
	flags := &Flags{}

	wrapper := func(ctx context.Context, f func(ctx context.Context, cancel context.CancelFunc, flags *Flags) error) error {
		ctx, cancel := context.WithCancel(ctx)
		defer cancel()

		sigChan := make(chan os.Signal, 1)
		signal.Notify(sigChan, syscall.SIGTERM)
		go func() {
			<-sigChan
			klog.Infof("Received SIGTERM, initiate shutdown")
			cancel()
		}()

		return f(ctx, cancel, flags)
	}

	cliFlags := []cli.Flag{
		// --- Flags identical to the real daemon ---
		&cli.StringFlag{
			Name:        "cliqueid",
			Usage:       "The clique ID for this node.",
			EnvVars:     []string{"CLIQUE_ID"},
			Destination: &flags.cliqueID,
		},
		&cli.StringFlag{
			Name:        "compute-domain-uuid",
			Usage:       "The UUID of the ComputeDomain to manage.",
			EnvVars:     []string{"COMPUTE_DOMAIN_UUID"},
			Destination: &flags.computeDomainUUID,
		},
		&cli.StringFlag{
			Name:        "compute-domain-name",
			Usage:       "The name of the ComputeDomain to manage.",
			EnvVars:     []string{"COMPUTE_DOMAIN_NAME"},
			Destination: &flags.computeDomainName,
		},
		&cli.StringFlag{
			Name:        "compute-domain-namespace",
			Usage:       "The namespace of the ComputeDomain to manage.",
			Value:       "default",
			EnvVars:     []string{"COMPUTE_DOMAIN_NAMESPACE"},
			Destination: &flags.computeDomainNamespace,
		},
		&cli.StringFlag{
			Name:        "node-name",
			Usage:       "The name of this Kubernetes node.",
			EnvVars:     []string{"NODE_NAME"},
			Destination: &flags.nodeName,
		},
		&cli.StringFlag{
			Name:        "pod-ip",
			Usage:       "The IP address of this pod.",
			EnvVars:     []string{"POD_IP"},
			Destination: &flags.podIP,
		},
		&cli.StringFlag{
			Name:        "pod-uid",
			Usage:       "The UID of this pod.",
			EnvVars:     []string{"POD_UID"},
			Destination: &flags.podUID,
		},
		&cli.StringFlag{
			Name:        "pod-name",
			Usage:       "The name of this pod.",
			EnvVars:     []string{"POD_NAME"},
			Destination: &flags.podName,
		},
		&cli.StringFlag{
			Name:        "pod-namespace",
			Usage:       "The namespace of this pod.",
			EnvVars:     []string{"POD_NAMESPACE"},
			Destination: &flags.podNamespace,
		},
		&cli.IntFlag{
			Name:        "max-nodes-per-imex-domain",
			Usage:       "The maximum number of possible nodes per IMEX domain",
			EnvVars:     []string{"MAX_NODES_PER_IMEX_DOMAIN"},
			Destination: &flags.maxNodesPerIMEXDomain,
		},
		// --- Simulation-specific flags ---
		&cli.DurationFlag{
			Name:        "startup-delay",
			Usage:       "Simulated IMEX daemon startup delay",
			Value:       2 * time.Second,
			EnvVars:     []string{"FAKE_STARTUP_DELAY"},
			Destination: &flags.startupDelay,
		},
		&cli.DurationFlag{
			Name:        "ready-delay",
			Usage:       "Delay after registration before marking Ready",
			Value:       1 * time.Second,
			EnvVars:     []string{"FAKE_READY_DELAY"},
			Destination: &flags.readyDelay,
		},
		&cli.DurationFlag{
			Name:        "dns-settle-delay",
			Usage:       "Simulated delay after DNS negotiation completes (mimics IMEX reconnection)",
			Value:       500 * time.Millisecond,
			EnvVars:     []string{"FAKE_DNS_SETTLE_DELAY"},
			Destination: &flags.dnsSettleDelay,
		},
		&cli.Float64Flag{
			Name:        "failure-rate",
			Usage:       "Probability of simulated random failure (0.0-1.0)",
			Value:       0,
			EnvVars:     []string{"FAKE_FAILURE_RATE"},
			Destination: &flags.failureRate,
		},
	}
	cliFlags = append(cliFlags, featureGateConfig.Flags()...)
	cliFlags = append(cliFlags, loggingConfig.Flags()...)

	app := &cli.App{
		Name:  "fake-compute-domain-daemon",
		Usage: "Fake compute-domain-daemon for performance testing without GPU hardware.",
		Flags: cliFlags,
		Before: func(c *cli.Context) error {
			err := loggingConfig.Apply()
			flags.klogVerbosity = int(loggingConfig.Config.Verbosity)
			pkgflags.LogStartupConfig(flags, loggingConfig)
			return err
		},
		Commands: []*cli.Command{
			{
				Name:  "run",
				Usage: "Run the fake compute domain daemon",
				Action: func(c *cli.Context) error {
					return wrapper(c.Context, run)
				},
			},
			{
				Name:  "check",
				Usage: "Fake readiness check (always succeeds)",
				Action: func(c *cli.Context) error {
					return wrapper(c.Context, check)
				},
			},
		},
	}

	return app
}

// run is the main entry point for the fake daemon. It performs all K8s API
// operations identical to the real daemon but replaces IMEX process management
// with configurable simulated delays.
func run(ctx context.Context, cancel context.CancelFunc, flags *Flags) error {
	// The real daemon checks for COMPUTE_DOMAIN_UUID to verify CDI edits.
	// For fake mode, we allow it to be empty (no CDI required) but still
	// need it for the controller. If empty, generate a placeholder.
	if flags.computeDomainUUID == "" {
		return fmt.Errorf("compute-domain-uuid is required (set via --compute-domain-uuid or COMPUTE_DOMAIN_UUID env)")
	}

	// Validate feature gate dependencies (same as real daemon)
	if err := featuregates.ValidateFeatureGates(); err != nil {
		return fmt.Errorf("feature gate validation failed: %w", err)
	}

	// Create clientsets for Kubernetes API access
	kubeConfig := &pkgflags.KubeClientConfig{}
	clientsets, err := kubeConfig.NewClientSets()
	if err != nil {
		return fmt.Errorf("failed to create client sets: %w", err)
	}

	// Add compute domain clique label to this pod (same as real daemon)
	if err := addComputeDomainCliqueLabel(ctx, clientsets, flags); err != nil {
		return fmt.Errorf("failed to add compute domain clique label to pod: %w", err)
	}

	// [FAKE] Resolve CD name/namespace from UID if not correctly set.
	// In real deployments, COMPUTE_DOMAIN_NAME and COMPUTE_DOMAIN_NAMESPACE
	// are injected via CDI container edits by the kubelet plugin. In our fake
	// setup they may be set to the DaemonSet name/namespace instead. Detect
	// this and resolve by searching for the CD by UID across all namespaces.
	if strings.Contains(flags.computeDomainName, "computedomain-daemon-") || flags.computeDomainName == "" {
		klog.Infof("[fake] Resolving CD name/namespace from UID %s", flags.computeDomainUUID)
		cdList, err := clientsets.Nvidia.ResourceV1beta1().ComputeDomains("").List(ctx, metav1.ListOptions{})
		if err != nil {
			return fmt.Errorf("failed to list ComputeDomains: %w", err)
		}
		for _, cd := range cdList.Items {
			if string(cd.UID) == flags.computeDomainUUID {
				flags.computeDomainName = cd.Name
				flags.computeDomainNamespace = cd.Namespace
				klog.Infof("[fake] Resolved CD: %s/%s", cd.Namespace, cd.Name)
				break
			}
		}
		if strings.Contains(flags.computeDomainName, "computedomain-daemon-") {
			return fmt.Errorf("could not resolve ComputeDomain with UID %s", flags.computeDomainUUID)
		}
	}

	// When cliqueID is empty, skip starting the controller and IMEX daemon
	// management entirely (same behavior as real daemon).
	if flags.cliqueID == "" {
		klog.Infof("no cliqueID: skipping controller and IMEX daemon management")
		<-ctx.Done()
		klog.Infof("Exiting")
		return nil
	}

	// Simulate IMEX startup delay
	klog.Infof("[fake] Simulating IMEX daemon startup delay: %v", flags.startupDelay)
	select {
	case <-ctx.Done():
		return nil
	case <-time.After(flags.startupDelay):
	}

	// Check for simulated failure during startup
	if flags.failureRate > 0 && rand.Float64() < flags.failureRate {
		return fmt.Errorf("[fake] simulated startup failure (failure-rate=%.2f)", flags.failureRate)
	}

	config := &ControllerConfig{
		clientsets:             clientsets,
		cliqueID:               flags.cliqueID,
		computeDomainUUID:      flags.computeDomainUUID,
		computeDomainName:      flags.computeDomainName,
		computeDomainNamespace: flags.computeDomainNamespace,
		nodeName:               flags.nodeName,
		podIP:                  flags.podIP,
		podUID:                 flags.podUID,
		podName:                flags.podName,
		podNamespace:           flags.podNamespace,
		maxNodesPerIMEXDomain:  flags.maxNodesPerIMEXDomain,
	}

	// Create controller (same as real daemon — dispatches to CDClique or
	// CDStatus manager based on feature gate).
	controller, err := NewController(config)
	if err != nil {
		return fmt.Errorf("error creating controller: %w", err)
	}

	var wg sync.WaitGroup

	// Start controller in goroutine (same as real daemon).
	wg.Add(1)
	go func() {
		defer wg.Done()
		if err := controller.Run(ctx); err != nil {
			klog.Errorf("controller failed, initiate shutdown: %s", err)
			cancel()
		}
		klog.Infof("Terminated: controller task")
	}()

	// Start fake IMEX daemon update loop in goroutine.
	// Instead of managing a real IMEX process, this just consumes the
	// daemon info updates from the controller and logs them.
	wg.Add(1)
	go func() {
		defer wg.Done()
		if err := fakeIMEXDaemonUpdateLoop(ctx, controller, flags); err != nil {
			klog.Errorf("[fake] IMEXDaemonUpdateLoop failed, initiate shutdown: %s", err)
			cancel()
		}
		klog.Infof("Terminated: fake IMEX daemon update task")
	}()

	wg.Wait()

	klog.Infof("Exiting")
	return nil
}

// fakeIMEXDaemonUpdateLoop replaces the real IMEX daemon update loops
// (IMEXDaemonUpdateLoopWithIPs / IMEXDaemonUpdateLoopWithDNSNames).
// It consumes daemon info updates from the controller and logs them,
// simulating the IMEX daemon behavior with configurable delays.
//
// Flow: wait for all daemons in the clique to register → simulate DNS
// name mapping → dns-settle-delay → ready-delay → continue.
func fakeIMEXDaemonUpdateLoop(ctx context.Context, controller *Controller, flags *Flags) error {
	dnsNegotiated := false
	maxSeenDaemons := 0

	for {
		klog.V(1).Infof("[fake] Wait for updated ComputeDomainDaemonInfo list")
		select {
		case <-ctx.Done():
			klog.Infof("[fake] shutdown: stop fakeIMEXDaemonUpdateLoop")
			return nil
		case daemons := <-controller.GetDaemonInfoUpdateChan():
			klog.Infof("[fake] Received daemon info update with %d daemons:", len(daemons))
			for _, d := range daemons {
				klog.Infof("[fake]   node=%s ip=%s clique=%s index=%d status=%s",
					d.NodeName, d.IPAddress, d.CliqueID, d.Index, d.Status)
			}

			// Check for simulated random failure on updates
			if flags.failureRate > 0 && rand.Float64() < flags.failureRate {
				klog.Warningf("[fake] Simulated random failure during daemon update")
				return fmt.Errorf("[fake] simulated failure during daemon update (failure-rate=%.2f)", flags.failureRate)
			}

			// --- DNS negotiation simulation ---
			// Wait until all daemons in the same clique have registered
			// before simulating DNS name mapping.
			if !dnsNegotiated {
				cliqueDaemons := filterByClique(daemons, flags.cliqueID)
				if len(cliqueDaemons) > maxSeenDaemons {
					maxSeenDaemons = len(cliqueDaemons)
				}
				expected := flags.maxNodesPerIMEXDomain
				klog.Infof("[fake] DNS negotiation: %d/%d daemons registered in clique %q (max seen: %d)",
					len(cliqueDaemons), expected, flags.cliqueID, maxSeenDaemons)

				// Use max ever seen — once all daemons registered (even briefly),
				// trigger DNS negotiation. This matches real behavior where DNS
				// is triggered on first complete set, not requiring sustained stability.
				if maxSeenDaemons < expected {
					klog.V(1).Infof("[fake] Waiting for more daemons to register before DNS negotiation...")
					continue
				}

				// All daemons registered — simulate DNS name generation
				klog.Infof("[fake] All %d daemons registered in clique %q, simulating DNS name mapping", expected, flags.cliqueID)
				cliqueName := fmt.Sprintf("%s.%s", flags.computeDomainUUID, flags.cliqueID)
				for _, d := range cliqueDaemons {
					dnsName := fmt.Sprintf("compute-domain-daemon-%04d.%s", d.Index, cliqueName)
					klog.Infof("[fake] DNS mapping: %s -> %s (node=%s)", dnsName, d.IPAddress, d.NodeName)
				}

				// Simulate DNS settle delay (IMEX daemon reconnection time)
				if flags.dnsSettleDelay > 0 {
					klog.Infof("[fake] Simulating DNS settle delay: %v", flags.dnsSettleDelay)
					select {
					case <-ctx.Done():
						return nil
					case <-time.After(flags.dnsSettleDelay):
					}
				}

				dnsNegotiated = true
				klog.Infof("[fake] DNS negotiation complete for clique %q", flags.cliqueID)
			}

			// Simulate ready delay (as if IMEX daemon is processing)
			if flags.readyDelay > 0 {
				klog.V(1).Infof("[fake] Simulating ready delay: %v", flags.readyDelay)
				select {
				case <-ctx.Done():
					return nil
				case <-time.After(flags.readyDelay):
				}
			}

			klog.Infof("[fake] IMEX daemon simulation complete for this update cycle")
		}
	}
}

// filterByClique returns only daemons matching the given cliqueID.
func filterByClique(daemons []*nvapi.ComputeDomainDaemonInfo, cliqueID string) []*nvapi.ComputeDomainDaemonInfo {
	var result []*nvapi.ComputeDomainDaemonInfo
	for _, d := range daemons {
		if d.CliqueID == cliqueID {
			result = append(result, d)
		}
	}
	return result
}

// check is the fake readiness check. It always succeeds since there is no
// real IMEX daemon to probe.
func check(ctx context.Context, cancel context.CancelFunc, flags *Flags) error {
	if flags.cliqueID == "" {
		fmt.Println("check succeeded (noop, clique ID is empty)")
		return nil
	}
	fmt.Println("check succeeded (fake daemon, always ready)")
	return nil
}

// addComputeDomainCliqueLabel adds the compute domain clique label to this daemon pod.
// This is identical to the real daemon's implementation.
func addComputeDomainCliqueLabel(ctx context.Context, clientsets pkgflags.ClientSets, flags *Flags) error {
	patch := map[string]any{
		"metadata": map[string]any{
			"labels": map[string]string{
				computeDomainCliqueLabelKey: flags.cliqueID,
			},
		},
	}

	patchBytes, err := json.Marshal(patch)
	if err != nil {
		return fmt.Errorf("failed to marshal patch: %w", err)
	}

	_, err = clientsets.Core.CoreV1().Pods(flags.podNamespace).Patch(
		ctx,
		flags.podName,
		types.MergePatchType,
		patchBytes,
		metav1.PatchOptions{},
	)
	if err != nil {
		return fmt.Errorf("failed to patch pod: %w", err)
	}

	return nil
}

// getIPSet is a helper used by the fake daemon update loop to compare IP sets.
func getIPSet(daemons []*nvapi.ComputeDomainDaemonInfo) IPSet {
	set := make(IPSet)
	for _, d := range daemons {
		set[d.IPAddress] = struct{}{}
	}
	return set
}
