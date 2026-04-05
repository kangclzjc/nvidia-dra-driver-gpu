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
	"fmt"
	"maps"
	"sync"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/tools/cache"
	"k8s.io/klog/v2"

	nvapi "sigs.k8s.io/nvidia-dra-driver-gpu/api/nvidia.com/resource/v1beta1"
	"sigs.k8s.io/nvidia-dra-driver-gpu/pkg/featuregates"
	nvinformers "sigs.k8s.io/nvidia-dra-driver-gpu/pkg/nvidia.com/informers/externalversions"
)

// ComputeDomainStatusManager watches compute domains and updates their status with
// info about the ComputeDomain daemon running on this node.
type ComputeDomainStatusManager struct {
	config        *ManagerConfig
	waitGroup     sync.WaitGroup
	cancelContext context.CancelFunc

	factory  nvinformers.SharedInformerFactory
	informer cache.SharedIndexInformer

	previousNodes      []*nvapi.ComputeDomainNode
	updatedDaemonsChan chan []*nvapi.ComputeDomainDaemonInfo

	podManager    *PodManager
	mutationCache cache.MutationCache
}

// NewComputeDomainStatusManager creates a new ComputeDomainStatusManager instance.
func NewComputeDomainStatusManager(config *ManagerConfig) *ComputeDomainStatusManager {
	m := &ComputeDomainStatusManager{
		config:             config,
		previousNodes:      []*nvapi.ComputeDomainNode{},
		updatedDaemonsChan: make(chan []*nvapi.ComputeDomainDaemonInfo),
	}

	m.factory = nvinformers.NewSharedInformerFactoryWithOptions(
		config.clientsets.Nvidia,
		informerResyncPeriod,
		// [FAKE] Don't filter by namespace/name — we'll filter by UID instead.
		// In real daemon, COMPUTE_DOMAIN_NAME/NAMESPACE come from CDI edits and
		// are always correct. In fake mode they may be wrong (set to DaemonSet
		// name/namespace). So we watch all CDs and filter in event handlers.
	)
	m.informer = m.factory.Resource().V1beta1().ComputeDomains().Informer()

	m.podManager = NewPodManager(m.config, m.updateNodeStatus)

	return m
}

// Start starts the compute domain manager.
func (m *ComputeDomainStatusManager) Start(ctx context.Context) (rerr error) {
	ctx, cancel := context.WithCancel(ctx)
	m.cancelContext = cancel

	defer func() {
		if rerr != nil {
			if err := m.Stop(); err != nil {
				klog.Errorf("error stopping ComputeDomainStatusManager: %v", err)
			}
		}
	}()

	err := m.informer.AddIndexers(cache.Indexers{
		"uid": uidIndexer[*nvapi.ComputeDomain],
	})
	if err != nil {
		return fmt.Errorf("error adding indexer for ComputeDomain UID: %w", err)
	}

	m.mutationCache = cache.NewIntegerResourceVersionMutationCache(
		klog.Background(),
		m.informer.GetStore(),
		m.informer.GetIndexer(),
		mutationCacheTTL,
		true,
	)

	_, err = m.informer.AddEventHandler(cache.ResourceEventHandlerFuncs{
		AddFunc: func(obj any) {
			m.config.workQueue.EnqueueWithKey(obj, "cd", m.onAddOrUpdate)
		},
		UpdateFunc: func(objOld, objNew any) {
			m.config.workQueue.EnqueueWithKey(objNew, "cd", m.onAddOrUpdate)
		},
	})
	if err != nil {
		return fmt.Errorf("error adding event handlers for ComputeDomain informer: %w", err)
	}

	m.waitGroup.Add(1)
	go func() {
		defer m.waitGroup.Done()
		m.factory.Start(ctx.Done())
	}()

	if !cache.WaitForCacheSync(ctx.Done(), m.informer.HasSynced) {
		return fmt.Errorf("informer cache sync for ComputeDomains failed")
	}

	if err := m.podManager.Start(ctx); err != nil {
		return fmt.Errorf("failed to start pod manager: %w", err)
	}

	return nil
}

// Stop stops the compute domain manager.
//
//nolint:contextcheck
func (m *ComputeDomainStatusManager) Stop() error {
	if err := m.podManager.Stop(); err != nil {
		klog.Errorf("Failed to stop pod manager: %v", err)
	}

	cleanupCtx, cleanupCancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cleanupCancel()

	if err := m.removeNodeFromComputeDomain(cleanupCtx); err != nil {
		klog.Errorf("Failed to remove node from ComputeDomain during shutdown: %v", err)
	}

	if m.cancelContext != nil {
		m.cancelContext()
	}

	m.waitGroup.Wait()
	return nil
}

// Get gets the ComputeDomain by UID from the mutation cache.
func (m *ComputeDomainStatusManager) Get(uid string) (*nvapi.ComputeDomain, error) {
	cds, err := getByComputeDomainUID[*nvapi.ComputeDomain](m.mutationCache, uid)
	if err != nil {
		return nil, fmt.Errorf("error retrieving ComputeDomain by UID: %w", err)
	}
	if len(cds) == 0 {
		return nil, nil
	}
	if len(cds) != 1 {
		return nil, fmt.Errorf("multiple ComputeDomains with the same UID")
	}
	return cds[0], nil
}

func (m *ComputeDomainStatusManager) onAddOrUpdate(ctx context.Context, obj any) error {
	o, ok := obj.(*nvapi.ComputeDomain)
	if !ok {
		return fmt.Errorf("failed to cast to ComputeDomain")
	}

	cd, err := m.Get(string(o.GetUID()))
	if err != nil {
		return fmt.Errorf("error getting latest ComputeDomain: %w", err)
	}
	if cd == nil {
		return nil
	}

	if string(cd.UID) != m.config.computeDomainUUID {
		klog.Warningf("ComputeDomain processed with non-matching UID (%v, %v)", cd.UID, m.config.computeDomainUUID)
		return nil
	}

	cd, err = m.syncNodeInfoToCD(ctx, cd)
	if err != nil {
		return fmt.Errorf("CD update: failed to insert/update node info in CD: %w", err)
	}
	m.maybePushNodesUpdate(cd)

	return nil
}

func (m *ComputeDomainStatusManager) syncNodeInfoToCD(ctx context.Context, cd *nvapi.ComputeDomain) (*nvapi.ComputeDomain, error) {
	var myNode *nvapi.ComputeDomainNode

	newCD := cd.DeepCopy()

	for _, node := range newCD.Status.Nodes {
		if node.Name == m.config.nodeName {
			myNode = node
			break
		}
	}

	if myNode != nil && myNode.IPAddress == m.config.podIP {
		klog.V(6).Infof("syncNodeInfoToCD noop: pod IP unchanged (%s)", m.config.podIP)
		return newCD, nil
	}

	if myNode == nil {
		nextIndex, err := m.getNextAvailableIndex(newCD.Status.Nodes)
		if err != nil {
			return nil, fmt.Errorf("error getting next available index: %w", err)
		}

		myNode = &nvapi.ComputeDomainNode{
			Name:     m.config.nodeName,
			CliqueID: m.config.cliqueID,
			Index:    nextIndex,
			Status:   nvapi.ComputeDomainStatusNotReady,
		}

		klog.Infof("CD status does not contain node name '%s' yet, try to insert myself: %v", m.config.nodeName, myNode)
		newCD.Status.Nodes = append(newCD.Status.Nodes, myNode)
	}

	myNode.IPAddress = m.config.podIP

	newCD, err := m.config.clientsets.Nvidia.ResourceV1beta1().ComputeDomains(newCD.Namespace).UpdateStatus(ctx, newCD, metav1.UpdateOptions{})
	if err != nil {
		return nil, fmt.Errorf("error updating ComputeDomain status: %w", err)
	}
	m.mutationCache.Mutation(newCD)

	klog.Infof("Successfully inserted/updated node in CD (nodeinfo: %v)", myNode)
	return newCD, nil
}

func (m *ComputeDomainStatusManager) getNextAvailableIndex(nodes []*nvapi.ComputeDomainNode) (int, error) {
	var cliqueNodes []*nvapi.ComputeDomainNode
	for _, node := range nodes {
		if node.CliqueID == m.config.cliqueID {
			cliqueNodes = append(cliqueNodes, node)
		}
	}

	usedIndices := make(map[int]bool)
	for _, node := range cliqueNodes {
		usedIndices[node.Index] = true
	}

	nextIndex := 0
	for usedIndices[nextIndex] {
		nextIndex++
	}

	if m.config.cliqueID == "" {
		return nextIndex, nil
	}

	if nextIndex < 0 || nextIndex >= m.config.maxNodesPerIMEXDomain {
		return -1, fmt.Errorf("no available indices within maxNodesPerIMEXDomain (%d) for cliqueID %s", m.config.maxNodesPerIMEXDomain, m.config.cliqueID)
	}

	return nextIndex, nil
}

func (m *ComputeDomainStatusManager) maybePushNodesUpdate(cd *nvapi.ComputeDomain) {
	if !featuregates.Enabled(featuregates.IMEXDaemonsWithDNSNames) {
		if len(cd.Status.Nodes) != cd.Spec.NumNodes {
			klog.Infof("numNodes: %d, nodes seen: %d", cd.Spec.NumNodes, len(cd.Status.Nodes))
			return
		}
	}

	newIPs := m.getIPSetForClique(cd.Status.Nodes)
	previousIPs := m.getIPSetForClique(m.previousNodes)

	if !maps.Equal(newIPs, previousIPs) {
		added, removed := previousIPs.Diff(newIPs)
		klog.V(2).Infof("IP set for clique changed.\nAdded: %v\nRemoved: %v", added, removed)
		m.previousNodes = cd.Status.Nodes
		m.updatedDaemonsChan <- m.nodesToDaemonInfos(cd.Status.Nodes)
	} else {
		klog.V(6).Infof("IP set for clique did not change")
	}
}

func (m *ComputeDomainStatusManager) nodesToDaemonInfos(nodes []*nvapi.ComputeDomainNode) []*nvapi.ComputeDomainDaemonInfo {
	daemons := make([]*nvapi.ComputeDomainDaemonInfo, len(nodes))
	for i, node := range nodes {
		daemons[i] = &nvapi.ComputeDomainDaemonInfo{
			NodeName:  node.Name,
			IPAddress: node.IPAddress,
			CliqueID:  node.CliqueID,
			Index:     node.Index,
			Status:    node.Status,
		}
	}
	return daemons
}

// GetDaemonInfoUpdateChan returns the channel that yields daemon info updates.
func (m *ComputeDomainStatusManager) GetDaemonInfoUpdateChan() chan []*nvapi.ComputeDomainDaemonInfo {
	return m.updatedDaemonsChan
}

func (m *ComputeDomainStatusManager) removeNodeFromComputeDomain(ctx context.Context) error {
	cd, err := m.Get(m.config.computeDomainUUID)
	if err != nil {
		return fmt.Errorf("error getting ComputeDomain from mutation cache: %w", err)
	}
	if cd == nil {
		klog.Infof("No ComputeDomain object found in mutation cache during cleanup")
		return nil
	}

	newCD := cd.DeepCopy()

	var updatedNodes []*nvapi.ComputeDomainNode
	for _, node := range newCD.Status.Nodes {
		if node.IPAddress != m.config.podIP {
			updatedNodes = append(updatedNodes, node)
		}
	}

	if len(updatedNodes) == len(newCD.Status.Nodes) {
		return nil
	}

	newCD.Status.Nodes = updatedNodes
	newCD, err = m.config.clientsets.Nvidia.ResourceV1beta1().ComputeDomains(newCD.Namespace).UpdateStatus(ctx, newCD, metav1.UpdateOptions{})
	if err != nil {
		return fmt.Errorf("error removing node from ComputeDomain status: %w", err)
	}
	m.mutationCache.Mutation(newCD)

	klog.Infof("Successfully removed node with IP %s from ComputeDomain %s/%s", m.config.podIP, newCD.Namespace, newCD.Name)
	return nil
}

func (m *ComputeDomainStatusManager) updateNodeStatus(ctx context.Context, ready bool) error {
	status := nvapi.ComputeDomainStatusNotReady
	if ready {
		status = nvapi.ComputeDomainStatusReady
	}

	cd, err := m.Get(m.config.computeDomainUUID)
	if err != nil {
		return fmt.Errorf("failed to get ComputeDomain: %w", err)
	}
	if cd == nil {
		return fmt.Errorf("ComputeDomain '%s/%s' not found", m.config.computeDomainName, m.config.computeDomainUUID)
	}

	newCD := cd.DeepCopy()

	var myNode *nvapi.ComputeDomainNode
	for _, n := range newCD.Status.Nodes {
		if n.Name == m.config.nodeName {
			myNode = n
			break
		}
	}
	if myNode == nil {
		return fmt.Errorf("node not yet listed in CD (waiting for insertion)")
	}

	if myNode.Status == status {
		klog.V(6).Infof("updateNodeStatus noop: status not changed (%s)", status)
		return nil
	}

	myNode.Status = status

	newCD, err = m.config.clientsets.Nvidia.ResourceV1beta1().ComputeDomains(newCD.Namespace).UpdateStatus(ctx, newCD, metav1.UpdateOptions{})
	if err != nil {
		return fmt.Errorf("error updating ComputeDomain status: %w", err)
	}
	m.mutationCache.Mutation(newCD)

	klog.Infof("Successfully updated node status in CD (new status: %s)", status)
	return nil
}

func (m *ComputeDomainStatusManager) getIPSetForClique(nodeInfos []*nvapi.ComputeDomainNode) IPSet {
	set := make(IPSet)
	for _, n := range nodeInfos {
		if n.CliqueID == m.config.cliqueID {
			set[n.IPAddress] = struct{}{}
		}
	}
	return set
}
