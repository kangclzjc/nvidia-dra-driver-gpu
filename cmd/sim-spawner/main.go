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

// Package main implements sim-spawner, a CLI tool that creates (or cleans up)
// N fake-compute-domain-daemon Deployments for ComputeDomain perf testing.
package main

import (
	"context"
	"fmt"
	"os"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"

	"github.com/urfave/cli/v2"
)

const maxConcurrency = 20

func main() {
	app := &cli.App{
		Name:  "sim-spawner",
		Usage: "Create or clean up simulated daemon Deployments for ComputeDomain perf tests",
		Flags: []cli.Flag{
			&cli.IntFlag{Name: "nodes", Value: 18, Usage: "Number of Deployments to create"},
			&cli.IntFlag{Name: "nodes-per-rack", Value: 18, Usage: "Nodes per rack (determines clique grouping)"},
			&cli.StringFlag{Name: "cd-uid", Required: true, Usage: "ComputeDomain UID"},
			&cli.StringFlag{Name: "cd-name", Required: true, Usage: "ComputeDomain name"},
			&cli.StringFlag{Name: "cd-namespace", Value: "default", Usage: "ComputeDomain namespace"},
			&cli.StringFlag{Name: "namespace", Value: "nvidia-dra-driver", Usage: "Namespace for Deployments"},
			&cli.StringFlag{Name: "image", Value: "fake-compute-domain-daemon:perf", Usage: "Fake daemon container image"},
			&cli.StringFlag{Name: "service-account", Value: "nvidia-dra-driver-gpu-compute-domain-daemon", Usage: "ServiceAccount name"},
			&cli.StringFlag{Name: "kubeconfig", EnvVars: []string{"KUBECONFIG"}, Usage: "Path to kubeconfig (uses in-cluster if unset)"},
			&cli.BoolFlag{Name: "cleanup", Usage: "Delete all sim-daemon Deployments instead of creating"},
		},
		Action: run,
	}

	if err := app.Run(os.Args); err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(1)
	}
}

func run(c *cli.Context) error {
	cfg, err := buildConfig(c.String("kubeconfig"))
	if err != nil {
		return fmt.Errorf("build kube config: %w", err)
	}
	clientset, err := kubernetes.NewForConfig(cfg)
	if err != nil {
		return fmt.Errorf("create clientset: %w", err)
	}

	ns := c.String("namespace")
	ctx := context.Background()

	if c.Bool("cleanup") {
		return cleanup(ctx, clientset, ns)
	}
	return create(ctx, clientset, c, ns)
}

func buildConfig(kubeconfig string) (*rest.Config, error) {
	if kubeconfig == "" {
		return rest.InClusterConfig()
	}
	return clientcmd.BuildConfigFromFlags("", kubeconfig)
}

// cleanup deletes all Deployments with label app=sim-daemon in the namespace.
func cleanup(ctx context.Context, clientset kubernetes.Interface, ns string) error {
	fmt.Println("Listing sim-daemon Deployments for cleanup...")
	list, err := clientset.AppsV1().Deployments(ns).List(ctx, metav1.ListOptions{
		LabelSelector: "app=sim-daemon",
	})
	if err != nil {
		return fmt.Errorf("list deployments: %w", err)
	}
	total := len(list.Items)
	if total == 0 {
		fmt.Println("No sim-daemon Deployments found.")
		return nil
	}
	fmt.Printf("Deleting %d sim-daemon Deployments...\n", total)

	start := time.Now()
	sem := make(chan struct{}, maxConcurrency)
	var wg sync.WaitGroup
	var deleted atomic.Int32
	var errCount atomic.Int32

	for i := range list.Items {
		name := list.Items[i].Name
		wg.Add(1)
		sem <- struct{}{}
		go func() {
			defer wg.Done()
			defer func() { <-sem }()
			if err := clientset.AppsV1().Deployments(ns).Delete(ctx, name, metav1.DeleteOptions{}); err != nil {
				fmt.Fprintf(os.Stderr, "  ✗ failed to delete %s: %v\n", name, err)
				errCount.Add(1)
				return
			}
			cur := deleted.Add(1)
			fmt.Printf("  deleted %s (%d/%d)\n", name, cur, total)
		}()
	}
	wg.Wait()

	fmt.Printf("Cleanup done: %d deleted, %d errors (took %s)\n", deleted.Load(), errCount.Load(), time.Since(start).Round(time.Millisecond))
	if errCount.Load() > 0 {
		return fmt.Errorf("%d delete(s) failed", errCount.Load())
	}
	return nil
}

// create builds and creates N Deployment objects in parallel.
func create(ctx context.Context, clientset kubernetes.Interface, c *cli.Context, ns string) error {
	numNodes := c.Int("nodes")
	nodesPerRack := c.Int("nodes-per-rack")
	cdUID := c.String("cd-uid")
	cdName := c.String("cd-name")
	cdNamespace := c.String("cd-namespace")
	image := c.String("image")
	sa := c.String("service-account")

	totalRacks := (numNodes + nodesPerRack - 1) / nodesPerRack
	fmt.Printf("Creating %d sim-daemon Deployments (%d racks, %d nodes/rack)...\n", numNodes, totalRacks, nodesPerRack)

	start := time.Now()
	sem := make(chan struct{}, maxConcurrency)
	var wg sync.WaitGroup
	var created atomic.Int32
	var errCount atomic.Int32

	for i := 0; i < numNodes; i++ {
		deploy := buildDeployment(i, nodesPerRack, ns, cdUID, cdName, cdNamespace, image, sa)
		wg.Add(1)
		sem <- struct{}{}
		go func(d *appsv1.Deployment) {
			defer wg.Done()
			defer func() { <-sem }()
			if _, err := clientset.AppsV1().Deployments(ns).Create(ctx, d, metav1.CreateOptions{}); err != nil {
				fmt.Fprintf(os.Stderr, "  ✗ failed to create %s: %v\n", d.Name, err)
				errCount.Add(1)
				return
			}
			cur := created.Add(1)
			fmt.Printf("  created %s (%d/%d)\n", d.Name, cur, numNodes)
		}(deploy)
	}
	wg.Wait()

	fmt.Printf("Done: %d created, %d errors (took %s)\n", created.Load(), errCount.Load(), time.Since(start).Round(time.Millisecond))
	if errCount.Load() > 0 {
		return fmt.Errorf("%d create(s) failed", errCount.Load())
	}
	return nil
}

func buildDeployment(index, nodesPerRack int, ns, cdUID, cdName, cdNamespace, image, sa string) *appsv1.Deployment {
	rackID := index / nodesPerRack
	simNode := fmt.Sprintf("sim-node-%04d", index)
	cliqueID := fmt.Sprintf("clique-%d", rackID)
	deployName := fmt.Sprintf("sim-daemon-%04d", index)
	replicas := int32(1)
	terminationGrace := int64(5)

	labels := map[string]string{
		"app":      "sim-daemon",
		"perf-sim": "true",
		"cd-name":  cdName,
		"rack-id":  strconv.Itoa(rackID),
		"sim-node": simNode,
	}

	return &appsv1.Deployment{
		ObjectMeta: metav1.ObjectMeta{
			Name:      deployName,
			Namespace: ns,
			Labels:    labels,
		},
		Spec: appsv1.DeploymentSpec{
			Replicas: &replicas,
			Selector: &metav1.LabelSelector{
				MatchLabels: map[string]string{
					"app":      "sim-daemon",
					"sim-node": simNode,
				},
			},
			Template: corev1.PodTemplateSpec{
				ObjectMeta: metav1.ObjectMeta{
					Labels: labels,
				},
				Spec: corev1.PodSpec{
					ServiceAccountName:            sa,
					TerminationGracePeriodSeconds: &terminationGrace,
					Containers: []corev1.Container{
						{
							Name:            "fake-daemon",
							Image:           image,
							ImagePullPolicy: corev1.PullIfNotPresent,
							Command:         []string{"fake-compute-domain-daemon", "-v", "2", "run"},
							Env: []corev1.EnvVar{
								{Name: "COMPUTE_DOMAIN_UUID", Value: cdUID},
								{Name: "COMPUTE_DOMAIN_NAME", Value: cdName},
								{Name: "COMPUTE_DOMAIN_NAMESPACE", Value: cdNamespace},
								{Name: "NODE_NAME", Value: simNode},
								{Name: "CLIQUE_ID", Value: cliqueID},
								{Name: "MAX_NODES_PER_IMEX_DOMAIN", Value: strconv.Itoa(nodesPerRack)},
								{Name: "POD_IP", ValueFrom: &corev1.EnvVarSource{
									FieldRef: &corev1.ObjectFieldSelector{FieldPath: "status.podIP"},
								}},
								{Name: "POD_UID", ValueFrom: &corev1.EnvVarSource{
									FieldRef: &corev1.ObjectFieldSelector{FieldPath: "metadata.uid"},
								}},
								{Name: "POD_NAME", ValueFrom: &corev1.EnvVarSource{
									FieldRef: &corev1.ObjectFieldSelector{FieldPath: "metadata.name"},
								}},
								{Name: "POD_NAMESPACE", ValueFrom: &corev1.EnvVarSource{
									FieldRef: &corev1.ObjectFieldSelector{FieldPath: "metadata.namespace"},
								}},
							},
						},
					},
				},
			},
		},
	}
}
