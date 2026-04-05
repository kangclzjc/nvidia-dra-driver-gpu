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
	"cmp"
	"fmt"
	"maps"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"

	"k8s.io/klog/v2"

	nvapi "sigs.k8s.io/nvidia-dra-driver-gpu/api/nvidia.com/resource/v1beta1"
)

const (
	hostsFilePath = "/etc/hosts"
	dnsNamePrefix = "compute-domain-daemon-"
	dnsNameFormat = dnsNamePrefix + "%04d"
)

// IPToDNSNameMap holds a map of IP Addresses to DNS names.
type IPToDNSNameMap map[string]string

// DNSNameManager manages the allocation of static DNS names to IP addresses.
type DNSNameManager struct {
	sync.Mutex
	ipToDNSName           IPToDNSNameMap
	cliqueID              string
	maxNodesPerIMEXDomain int
	nodesConfigPath       string
	dryRun                bool
	hostsPath             string
}

// NewDNSNameManager creates a new DNS name manager.
func NewDNSNameManager(cliqueID string, maxNodesPerIMEXDomain int, nodesConfigPath string, dryRun bool) *DNSNameManager {
	return &DNSNameManager{
		ipToDNSName:           make(IPToDNSNameMap),
		cliqueID:              cliqueID,
		maxNodesPerIMEXDomain: maxNodesPerIMEXDomain,
		nodesConfigPath:       nodesConfigPath,
		dryRun:                dryRun,
	}
}

// UpdateDNSNameMappings updates the /etc/hosts file with any new IP to DNS name
// mappings. The boolean return value indicates whether the hosts file was
// updated or not (it must be ignored when the returned error is non-nil).
func (m *DNSNameManager) UpdateDNSNameMappings(daemons []*nvapi.ComputeDomainDaemonInfo) (bool, error) {
	m.Lock()
	defer m.Unlock()

	// Make a local ipToDNSName mappings
	ipToDNSName := make(IPToDNSNameMap)

	// Prefilter daemons to only consider those with the matching cliqueID
	var cliqueDaemons []*nvapi.ComputeDomainDaemonInfo
	for _, daemon := range daemons {
		if daemon.CliqueID == m.cliqueID {
			cliqueDaemons = append(cliqueDaemons, daemon)
		}
	}

	// Add IPs to map
	for _, daemon := range cliqueDaemons {
		// Construct the DNS name from the daemon index
		dnsName, err := m.constructDNSName(daemon)
		if err != nil {
			return false, fmt.Errorf("failed to allocate DNS name for IP %s: %w", daemon.IPAddress, err)
		}

		// Assign the IP -> DNS name mapping
		ipToDNSName[daemon.IPAddress] = dnsName
	}

	// If the existing ipToDNSName mappings are unchanged, exit early
	if maps.Equal(ipToDNSName, m.ipToDNSName) {
		return false, nil
	}

	// Otherwise, update the cached ipToDNSName mapping
	m.ipToDNSName = ipToDNSName

	// And update the hosts file with the new mapping
	return true, m.updateHostsFile()
}

// LogDNSNameMappings logs the current compute-domain-daemon mappings from memory.
func (m *DNSNameManager) LogDNSNameMappings() {
	m.Lock()
	defer m.Unlock()

	if len(m.ipToDNSName) == 0 {
		klog.Infof("Current compute-domain-daemon mappings: empty")
		return
	}

	// Sort alphabetically by DNS name (map value) -> sort ips (map keys) based
	// on their corresponding values.
	var ips []string
	for ip := range m.ipToDNSName {
		ips = append(ips, ip)
	}

	slices.SortFunc(ips, func(a, b string) int {
		return cmp.Compare(m.ipToDNSName[a], m.ipToDNSName[b])
	})

	for _, ip := range ips {
		dnsname := m.ipToDNSName[ip]
		klog.Infof("%s -> %s", dnsname, ip)
	}
}

// constructDNSName constructs a DNS name for a daemon based on its index field.
// Returns an error if the index is invalid or exceeds maxNodesPerIMEXDomain.
func (m *DNSNameManager) constructDNSName(daemon *nvapi.ComputeDomainDaemonInfo) (string, error) {
	if daemon.Index < 0 {
		return "", fmt.Errorf("daemon %s has invalid index %d", daemon.NodeName, daemon.Index)
	}
	if daemon.Index >= m.maxNodesPerIMEXDomain {
		return "", fmt.Errorf("daemon %s has invalid index %d, must be less than %d", daemon.NodeName, daemon.Index, m.maxNodesPerIMEXDomain)
	}
	dnsName := fmt.Sprintf(dnsNameFormat, daemon.Index)
	return dnsName, nil
}

// resolveHostsPath returns the path to use for hosts file updates.
// In dry-run mode or when /etc/hosts is not writable, it falls back to /tmp/hosts.
func (m *DNSNameManager) resolveHostsPath() string {
	if m.hostsPath != "" {
		return m.hostsPath
	}

	if m.dryRun {
		m.hostsPath = "/tmp/hosts"
		klog.Infof("[dry-run] Using fallback hosts path: %s", m.hostsPath)
		return m.hostsPath
	}

	// Check if /etc/hosts is writable
	f, err := os.OpenFile(hostsFilePath, os.O_WRONLY, 0644)
	if err != nil {
		m.hostsPath = "/tmp/hosts"
		klog.Warningf("/etc/hosts not writable, using fallback: %s", m.hostsPath)
		return m.hostsPath
	}
	f.Close()

	m.hostsPath = hostsFilePath
	return m.hostsPath
}

// updateHostsFile updates the hosts file with current IP to DNS name mappings.
func (m *DNSNameManager) updateHostsFile() error {
	hostsPath := m.resolveHostsPath()

	// Read hosts file (create empty if it doesn't exist in fallback mode)
	hostsContent, err := os.ReadFile(hostsPath)
	if err != nil {
		if os.IsNotExist(err) && hostsPath != hostsFilePath {
			hostsContent = []byte{}
		} else {
			return fmt.Errorf("failed to read %s: %w", hostsPath, err)
		}
	}

	// Grab any lines to preserve, skipping existing DNS name mappings
	var preservedLines []string
	for _, line := range strings.Split(string(hostsContent), "\n") {
		line = strings.TrimSpace(line)

		// Skip existing compute-domain-daemon mappings
		if strings.Contains(line, dnsNamePrefix) {
			continue
		}

		// Keep all other lines
		preservedLines = append(preservedLines, line)
	}

	// Add preserved lines
	var newHostsContent strings.Builder
	for _, line := range preservedLines {
		newHostsContent.WriteString(line)
		newHostsContent.WriteString("\n")
	}

	// Add a separator comment
	// TODO: do not write this more than once :-).
	newHostsContent.WriteString("# Compute Domain Daemon mappings\n")

	// Add new DNS name mappings
	for ip, dnsName := range m.ipToDNSName {
		_, _ = fmt.Fprintf(&newHostsContent, "%s\t%s\n", ip, dnsName)
	}

	// Write the updated hosts file
	if err := os.WriteFile(hostsPath, []byte(newHostsContent.String()), 0644); err != nil {
		return fmt.Errorf("failed to write %s: %w", hostsPath, err)
	}

	return nil
}

// WriteNodesConfig creates a static nodes config file with DNS names.
func (m *DNSNameManager) WriteNodesConfig() error {
	// Ensure the directory exists
	dir := filepath.Dir(m.nodesConfigPath)
	if err := os.MkdirAll(dir, 0755); err != nil {
		return fmt.Errorf("failed to create directory %s: %w", dir, err)
	}

	// Create or overwrite the nodesConfig file
	f, err := os.Create(m.nodesConfigPath)
	if err != nil {
		return fmt.Errorf("failed to create nodes config file: %w", err)
	}
	defer f.Close()

	// Write static DNS names
	for i := 0; i < m.maxNodesPerIMEXDomain; i++ {
		dnsName := fmt.Sprintf(dnsNameFormat, i)
		if _, err := fmt.Fprintf(f, "%s\n", dnsName); err != nil {
			return fmt.Errorf("failed to write to nodes config file: %w", err)
		}
	}

	klog.Infof("Created static nodes config file with %d DNS names using format %s", m.maxNodesPerIMEXDomain, dnsNameFormat)

	return nil
}
