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

package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"github.com/urfave/cli/v2"

	"k8s.io/component-base/logs"
	"k8s.io/klog/v2"

	pkgflags "sigs.k8s.io/nvidia-dra-driver-gpu/pkg/flags"
)

const (
	DriverName = "compute-domain.nvidia.com"
)

// Flags holds all configurable CLI flags for the fake plugin.
type Flags struct {
	kubeClientConfig pkgflags.KubeClientConfig

	nodeName                      string
	numChannels                   int
	prepareDelay                  time.Duration
	failureRate                   float64
	kubeletRegistrarDirectoryPath string
	kubeletPluginsDirectoryPath   string
	cdUID                         string
	cdName                        string
	cdNamespace                   string
	cdiDir                        string
}

// Config wraps Flags and kube clientsets.
type Config struct {
	flags      *Flags
	clientsets pkgflags.ClientSets
}

func (c Config) DriverPluginPath() string {
	return filepath.Join(c.flags.kubeletPluginsDirectoryPath, DriverName)
}

func main() {
	if err := newApp().Run(os.Args); err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}
}

func newApp() *cli.App {
	loggingConfig := pkgflags.NewLoggingConfig()
	flags := &Flags{}

	cliFlags := []cli.Flag{
		&cli.StringFlag{
			Name:        "node-name",
			Usage:       "The name of the node to be worked on.",
			Required:    true,
			Destination: &flags.nodeName,
			EnvVars:     []string{"NODE_NAME"},
		},
		&cli.IntFlag{
			Name:        "num-channels",
			Usage:       "Number of fake IMEX channel devices to publish.",
			Value:       2048,
			Destination: &flags.numChannels,
			EnvVars:     []string{"NUM_CHANNELS"},
		},
		&cli.DurationFlag{
			Name:        "prepare-delay",
			Usage:       "Artificial delay injected into PrepareResourceClaims.",
			Value:       100 * time.Millisecond,
			Destination: &flags.prepareDelay,
			EnvVars:     []string{"PREPARE_DELAY"},
		},
		&cli.Float64Flag{
			Name:        "failure-rate",
			Usage:       "Probability [0,1] that a Prepare/Unprepare call fails.",
			Value:       0,
			Destination: &flags.failureRate,
			EnvVars:     []string{"FAILURE_RATE"},
		},
		&cli.StringFlag{
			Name:        "kubelet-registrar-directory-path",
			Usage:       "Absolute path to the directory where kubelet stores plugin registrations.",
			Value:       "/var/lib/kubelet/plugins_registry",
			Destination: &flags.kubeletRegistrarDirectoryPath,
			EnvVars:     []string{"KUBELET_REGISTRAR_DIRECTORY_PATH"},
		},
		&cli.StringFlag{
			Name:        "kubelet-plugins-directory-path",
			Usage:       "Absolute path to the directory where kubelet stores plugin data.",
			Value:       "/var/lib/kubelet/plugins",
			Destination: &flags.kubeletPluginsDirectoryPath,
			EnvVars:     []string{"KUBELET_PLUGINS_DIRECTORY_PATH"},
		},
		&cli.StringFlag{
			Name:        "cd-uid",
			Usage:       "ComputeDomain UID to inject into CDI specs. If empty, claim UID is used.",
			Destination: &flags.cdUID,
			EnvVars:     []string{"COMPUTE_DOMAIN_UUID"},
		},
		&cli.StringFlag{
			Name:        "cd-name",
			Usage:       "ComputeDomain name to inject into CDI specs.",
			Value:       "fake-compute-domain",
			Destination: &flags.cdName,
			EnvVars:     []string{"COMPUTE_DOMAIN_NAME"},
		},
		&cli.StringFlag{
			Name:        "cd-namespace",
			Usage:       "ComputeDomain namespace to inject into CDI specs.",
			Value:       "default",
			Destination: &flags.cdNamespace,
			EnvVars:     []string{"COMPUTE_DOMAIN_NAMESPACE"},
		},
		&cli.StringFlag{
			Name:        "cdi-dir",
			Usage:       "Directory for CDI spec files.",
			Value:       "/etc/cdi",
			Destination: &flags.cdiDir,
			EnvVars:     []string{"CDI_DIR"},
		},
	}
	cliFlags = append(cliFlags, flags.kubeClientConfig.Flags()...)
	cliFlags = append(cliFlags, loggingConfig.Flags()...)

	app := &cli.App{
		Name:            "fake-cd-kubelet-plugin",
		Usage:           "Fake compute-domain kubelet plugin for DRA performance testing without real NVIDIA hardware.",
		ArgsUsage:       " ",
		HideHelpCommand: true,
		Flags:           cliFlags,
		Before: func(c *cli.Context) error {
			if c.Args().Len() > 0 {
				return fmt.Errorf("arguments not supported: %v", c.Args().Slice())
			}
			return loggingConfig.Apply()
		},
		Action: func(c *cli.Context) error {
			clientSets, err := flags.kubeClientConfig.NewClientSets()
			if err != nil {
				return fmt.Errorf("create client: %w", err)
			}

			config := &Config{
				flags:      flags,
				clientsets: clientSets,
			}

			return RunPlugin(c.Context, config)
		},
		After: func(c *cli.Context) error {
			klog.Infof("shutdown")
			logs.FlushLogs()
			return nil
		},
	}

	// Remove the -v alias for the version flag so as to not conflict with -v for klog.
	f, ok := cli.VersionFlag.(*cli.BoolFlag)
	if ok {
		f.Aliases = nil
	}

	return app
}

// RunPlugin initializes and runs the fake compute domain kubelet plugin.
func RunPlugin(ctx context.Context, config *Config) error {
	// Create the plugin directory
	if err := os.MkdirAll(config.DriverPluginPath(), 0750); err != nil {
		return fmt.Errorf("error creating plugin directory: %w", err)
	}

	ctx, cancel := signal.NotifyContext(ctx, syscall.SIGHUP, syscall.SIGINT, syscall.SIGTERM, syscall.SIGQUIT)
	defer cancel()

	driver, err := NewDriver(ctx, config)
	if err != nil {
		return fmt.Errorf("error creating driver: %w", err)
	}

	klog.Infof("fake-cd-kubelet-plugin running: node=%s channels=%d prepareDelay=%v failureRate=%.2f",
		config.flags.nodeName, config.flags.numChannels, config.flags.prepareDelay, config.flags.failureRate)

	<-ctx.Done()
	if err := ctx.Err(); err != nil && !errors.Is(err, context.Canceled) {
		klog.Errorf("error from context: %v", err)
	}

	driver.Shutdown()
	return nil
}
