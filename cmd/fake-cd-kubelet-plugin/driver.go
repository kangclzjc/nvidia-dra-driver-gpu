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
	"encoding/json"
	"fmt"
	"math/rand"
	"os"
	"path/filepath"
	"sync"
	"time"

	resourceapi "k8s.io/api/resource/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/util/runtime"
	coreclientset "k8s.io/client-go/kubernetes"
	"k8s.io/dynamic-resource-allocation/kubeletplugin"
	"k8s.io/dynamic-resource-allocation/resourceslice"
	"k8s.io/klog/v2"
	"k8s.io/utils/ptr"

	cdispec "tags.cncf.io/container-device-interface/specs-go"
)

const (
	ComputeDomainChannelType = "channel"
	ComputeDomainDaemonType  = "daemon"
	cdiVendor                = "k8s." + DriverName
)

type driver struct {
	client       coreclientset.Interface
	pluginhelper *kubeletplugin.Helper
	config       *Config
	rng          *rand.Rand

	mu             sync.Mutex
	preparedClaims map[types.UID][]kubeletplugin.Device
}

func NewDriver(ctx context.Context, config *Config) (*driver, error) {
	d := &driver{
		client:         config.clientsets.Core,
		config:         config,
		rng:            rand.New(rand.NewSource(time.Now().UnixNano())),
		preparedClaims: make(map[types.UID][]kubeletplugin.Device),
	}

	helper, err := kubeletplugin.Start(
		ctx,
		d,
		kubeletplugin.KubeClient(d.client),
		kubeletplugin.NodeName(config.flags.nodeName),
		kubeletplugin.DriverName(DriverName),
		kubeletplugin.Serialize(false),
		kubeletplugin.RegistrarDirectoryPath(config.flags.kubeletRegistrarDirectoryPath),
		kubeletplugin.PluginDataDirectoryPath(config.DriverPluginPath()),
	)
	if err != nil {
		return nil, fmt.Errorf("error starting kubelet plugin: %w", err)
	}
	d.pluginhelper = helper

	// Build fake devices.
	devices := buildFakeDevices(config.flags.numChannels)

	// K8s limits each ResourceSlice to 128 devices max.
	// Split devices into multiple slices.
	const maxDevicesPerSlice = 128
	var slices []resourceslice.Slice
	for i := 0; i < len(devices); i += maxDevicesPerSlice {
		end := i + maxDevicesPerSlice
		if end > len(devices) {
			end = len(devices)
		}
		slices = append(slices, resourceslice.Slice{Devices: devices[i:end]})
	}

	resources := resourceslice.DriverResources{
		Pools: map[string]resourceslice.Pool{
			config.flags.nodeName: {
				Slices: slices,
			},
		},
	}

	if err := helper.PublishResources(ctx, resources); err != nil {
		return nil, fmt.Errorf("error publishing resources: %w", err)
	}

	klog.Infof("Published %d fake devices (%d channels + 1 daemon) across %d slices", len(devices), config.flags.numChannels, len(slices))
	return d, nil
}

// buildFakeDevices creates the full set of fake devices: 1 daemon + N channels.
// Attributes match the real compute-domain-kubelet-plugin.
func buildFakeDevices(numChannels int) []resourceapi.Device {
	devices := make([]resourceapi.Device, 0, numChannels+1)

	// Daemon device (id=0)
	devices = append(devices, resourceapi.Device{
		Name: fmt.Sprintf("%s-%d", ComputeDomainDaemonType, 0),
		Attributes: map[resourceapi.QualifiedName]resourceapi.DeviceAttribute{
			"type": {StringValue: ptr.To(ComputeDomainDaemonType)},
			"id":   {IntValue: ptr.To(int64(0))},
		},
	})

	// Channel devices (id=0..numChannels-1)
	for i := 0; i < numChannels; i++ {
		devices = append(devices, resourceapi.Device{
			Name: fmt.Sprintf("%s-%d", ComputeDomainChannelType, i),
			Attributes: map[resourceapi.QualifiedName]resourceapi.DeviceAttribute{
				"type": {StringValue: ptr.To(ComputeDomainChannelType)},
				"id":   {IntValue: ptr.To(int64(i))},
			},
		})
	}

	return devices
}

func (d *driver) Shutdown() {
	if d == nil {
		return
	}
	d.pluginhelper.Stop()
	klog.Infof("driver shut down")
}

// shouldFail returns true with probability failureRate.
func (d *driver) shouldFail() bool {
	if d.config.flags.failureRate <= 0 {
		return false
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.rng.Float64() < d.config.flags.failureRate
}

func (d *driver) PrepareResourceClaims(ctx context.Context, claims []*resourceapi.ResourceClaim) (map[types.UID]kubeletplugin.PrepareResult, error) {
	klog.V(6).Infof("PrepareResourceClaims called with %d claim(s)", len(claims))
	results := make(map[types.UID]kubeletplugin.PrepareResult, len(claims))

	for _, claim := range claims {
		// Inject artificial delay.
		if d.config.flags.prepareDelay > 0 {
			select {
			case <-ctx.Done():
				results[claim.UID] = kubeletplugin.PrepareResult{
					Err: ctx.Err(),
				}
				continue
			case <-time.After(d.config.flags.prepareDelay):
			}
		}

		// Inject random failure.
		if d.shouldFail() {
			results[claim.UID] = kubeletplugin.PrepareResult{
				Err: fmt.Errorf("fake injected failure for claim %s", claim.UID),
			}
			klog.V(2).Infof("Injected failure for claim %s/%s", claim.Namespace, claim.Name)
			continue
		}

		if claim.Status.Allocation == nil {
			results[claim.UID] = kubeletplugin.PrepareResult{
				Err: fmt.Errorf("no allocation set in ResourceClaim %s/%s", claim.Namespace, claim.Name),
			}
			continue
		}

		// Build fake prepared devices from the allocation results.
		var devices []kubeletplugin.Device
		for _, result := range claim.Status.Allocation.Devices.Results {
			if result.Driver != DriverName {
				continue
			}

			// Determine the ComputeDomain UUID: use CLI flag if set, otherwise derive from claim UID.
			cdUID := d.config.flags.cdUID
			if cdUID == "" {
				cdUID = string(claim.UID)
			}

			// Write a CDI spec file for this device.
			cdiDeviceID := fmt.Sprintf("%s/%s=%s", cdiVendor, "fake", result.Device)
			if err := d.writeCDISpec(cdUID, result.Device, claim); err != nil {
				klog.Errorf("Failed to write CDI spec for device %s: %v", result.Device, err)
				// Non-fatal: continue with the device even if CDI spec write fails.
			}

			device := kubeletplugin.Device{
				Requests:     []string{result.Request},
				PoolName:     result.Pool,
				DeviceName:   result.Device,
				CDIDeviceIDs: []string{cdiDeviceID},
			}
			devices = append(devices, device)
		}

		d.mu.Lock()
		d.preparedClaims[claim.UID] = devices
		d.mu.Unlock()

		results[claim.UID] = kubeletplugin.PrepareResult{Devices: devices}
		klog.V(4).Infof("Prepared claim %s/%s (%s): %d device(s)", claim.Namespace, claim.Name, claim.UID, len(devices))
	}

	return results, nil
}

func (d *driver) UnprepareResourceClaims(ctx context.Context, claimRefs []kubeletplugin.NamespacedObject) (map[types.UID]error, error) {
	klog.V(6).Infof("UnprepareResourceClaims called with %d claim(s)", len(claimRefs))
	results := make(map[types.UID]error, len(claimRefs))

	for _, ref := range claimRefs {
		// Inject random failure.
		if d.shouldFail() {
			results[ref.UID] = fmt.Errorf("fake injected failure for claim %s", ref.UID)
			klog.V(2).Infof("Injected failure for unprepare claim %s", ref.String())
			continue
		}

		d.mu.Lock()
		delete(d.preparedClaims, ref.UID)
		d.mu.Unlock()

		// Clean up CDI spec files for this claim.
		d.removeCDISpecs(ref.UID)

		results[ref.UID] = nil
		klog.V(4).Infof("Unprepared claim %s", ref.String())
	}

	return results, nil
}

func (d *driver) HandleError(ctx context.Context, err error, msg string) {
	runtime.HandleErrorWithContext(ctx, err, msg)
}

// writeCDISpec creates a CDI spec file for a device with ComputeDomain environment
// variables and mount points, mimicking the real compute-domain-kubelet-plugin.
func (d *driver) writeCDISpec(cdUID string, deviceName string, claim *resourceapi.ResourceClaim) error {
	cdiDir := d.config.flags.cdiDir
	if err := os.MkdirAll(cdiDir, 0755); err != nil {
		return fmt.Errorf("failed to create CDI dir %s: %w", cdiDir, err)
	}

	cdName := d.config.flags.cdName
	cdNamespace := d.config.flags.cdNamespace

	// Determine a clique ID from the device name if possible.
	// For daemon devices, clique is "0"; for channels, derive from the claim.
	cliqueID := "0"

	// Create the host-side imexd directory for mounts.
	imexdHostPath := fmt.Sprintf("/tmp/imexd/%s", cdUID)
	if err := os.MkdirAll(imexdHostPath, 0755); err != nil {
		klog.Warningf("Failed to create imexd host path %s: %v", imexdHostPath, err)
	}

	spec := &cdispec.Spec{
		Version: "0.6.0",
		Kind:    cdiVendor,
		Devices: []cdispec.Device{
			{
				Name: deviceName,
				ContainerEdits: cdispec.ContainerEdits{
					Env: []string{
						fmt.Sprintf("COMPUTE_DOMAIN_UUID=%s", cdUID),
						fmt.Sprintf("COMPUTE_DOMAIN_NAME=%s", cdName),
						fmt.Sprintf("COMPUTE_DOMAIN_NAMESPACE=%s", cdNamespace),
						fmt.Sprintf("CLIQUE_ID=%s", cliqueID),
					},
					Mounts: []*cdispec.Mount{
						{
							HostPath:      imexdHostPath,
							ContainerPath: "/imexd",
							Options:       []string{"rw", "nosuid", "nodev", "bind"},
						},
					},
				},
			},
		},
	}

	specBytes, err := json.MarshalIndent(spec, "", "  ")
	if err != nil {
		return fmt.Errorf("failed to marshal CDI spec: %w", err)
	}

	// Use claim UID + device name for a unique filename.
	specFileName := fmt.Sprintf("fake-cd-%s-%s.json", claim.UID, deviceName)
	specPath := filepath.Join(cdiDir, specFileName)

	if err := os.WriteFile(specPath, specBytes, 0644); err != nil {
		return fmt.Errorf("failed to write CDI spec file %s: %w", specPath, err)
	}

	klog.V(4).Infof("Wrote CDI spec: %s (cdUID=%s, device=%s)", specPath, cdUID, deviceName)
	return nil
}

// removeCDISpecs removes CDI spec files associated with a claim UID.
func (d *driver) removeCDISpecs(claimUID types.UID) {
	cdiDir := d.config.flags.cdiDir
	pattern := filepath.Join(cdiDir, fmt.Sprintf("fake-cd-%s-*.json", claimUID))
	matches, err := filepath.Glob(pattern)
	if err != nil {
		klog.Warningf("Failed to glob CDI specs for claim %s: %v", claimUID, err)
		return
	}
	for _, path := range matches {
		if err := os.Remove(path); err != nil {
			klog.Warningf("Failed to remove CDI spec %s: %v", path, err)
		} else {
			klog.V(4).Infof("Removed CDI spec: %s", path)
		}
	}
}
