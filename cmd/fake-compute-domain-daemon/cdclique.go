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
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/tools/cache"
	"k8s.io/klog/v2"

	nvapi "sigs.k8s.io/nvidia-dra-driver-gpu/api/nvidia.com/resource/v1beta1"
	nvinformers "sigs.k8s.io/nvidia-dra-driver-gpu/pkg/nvidia.com/informers/externalversions"
)

// ComputeDomainCliqueManager watches ComputeDomainClique objects and updates them with
// info about the ComputeDomain daemon running on this node.
type ComputeDomainCliqueManager struct {
	config        *ManagerConfig
	waitGroup     sync.WaitGroup
	cancelContext context.CancelFunc

	factory  nvinformers.SharedInformerFactory
	informer cache.SharedIndexInformer

	previousDaemons    []*nvapi.ComputeDomainDaemonInfo
	updatedDaemonsChan chan []*nvapi.ComputeDomainDaemonInfo

	podManager    *PodManager
	mutationCache cache.MutationCache
}

// NewComputeDomainCliqueManager creates a new ComputeDomainCliqueManager instance.
func NewComputeDomainCliqueManager(config *ManagerConfig) *ComputeDomainCliqueManager {
	m := &ComputeDomainCliqueManager{
		config:             config,
		previousDaemons:    []*nvapi.ComputeDomainDaemonInfo{},
		updatedDaemonsChan: make(chan []*nvapi.ComputeDomainDaemonInfo),
	}

	m.factory = nvinformers.NewSharedInformerFactoryWithOptions(
		config.clientsets.Nvidia,
		informerResyncPeriod,
		nvinformers.WithNamespace(config.podNamespace),
		nvinformers.WithTweakListOptions(func(opts *metav1.ListOptions) {
			opts.FieldSelector = fmt.Sprintf("metadata.name=%s", m.cliqueName())
		}),
	)
	m.informer = m.factory.Resource().V1beta1().ComputeDomainCliques().Informer()

	m.podManager = NewPodManager(m.config, m.updateDaemonStatus)

	return m
}

// Start starts the CDClique manager.
func (m *ComputeDomainCliqueManager) Start(ctx context.Context) (rerr error) {
	ctx, cancel := context.WithCancel(ctx)
	m.cancelContext = cancel

	defer func() {
		if rerr != nil {
			if err := m.Stop(); err != nil {
				klog.Errorf("error stopping ComputeDomainCliqueManager: %v", err)
			}
		}
	}()

	m.mutationCache = cache.NewIntegerResourceVersionMutationCache(
		klog.Background(),
		m.informer.GetStore(),
		m.informer.GetIndexer(),
		mutationCacheTTL,
		true,
	)

	_, err := m.informer.AddEventHandler(cache.ResourceEventHandlerFuncs{
		AddFunc: func(obj any) {
			m.config.workQueue.EnqueueWithKey(obj, "cdclique", m.onAddOrUpdate)
		},
		UpdateFunc: func(objOld, objNew any) {
			m.config.workQueue.EnqueueWithKey(objNew, "cdclique", m.onAddOrUpdate)
		},
	})
	if err != nil {
		return fmt.Errorf("error adding event handlers for ComputeDomainClique informer: %w", err)
	}

	ensureCliqueExists := func(ctx context.Context, _ any) error {
		return m.ensureCliqueExists(ctx)
	}
	m.config.workQueue.EnqueueRawWithKey(nil, "cdclique", ensureCliqueExists)

	m.waitGroup.Add(1)
	go func() {
		defer m.waitGroup.Done()
		m.factory.Start(ctx.Done())
	}()

	if !cache.WaitForCacheSync(ctx.Done(), m.informer.HasSynced) {
		return fmt.Errorf("informer cache sync for ComputeDomainCliques failed")
	}

	if err := m.podManager.Start(ctx); err != nil {
		return fmt.Errorf("failed to start pod manager: %w", err)
	}

	return nil
}

// Stop stops the CDClique manager.
//
//nolint:contextcheck
func (m *ComputeDomainCliqueManager) Stop() error {
	if err := m.podManager.Stop(); err != nil {
		klog.Errorf("Failed to stop pod manager: %v", err)
	}

	cleanupCtx, cleanupCancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cleanupCancel()

	if err := m.removeDaemonInfoFromClique(cleanupCtx); err != nil {
		klog.Errorf("Failed to remove daemon info from CDClique during shutdown: %v", err)
	}

	if m.cancelContext != nil {
		m.cancelContext()
	}

	m.waitGroup.Wait()
	return nil
}

// GetDaemonInfoUpdateChan returns the channel that yields daemon info updates.
func (m *ComputeDomainCliqueManager) GetDaemonInfoUpdateChan() chan []*nvapi.ComputeDomainDaemonInfo {
	return m.updatedDaemonsChan
}

func (m *ComputeDomainCliqueManager) cliqueName() string {
	return fmt.Sprintf("%s.%s", m.config.computeDomainUUID, m.config.cliqueID)
}

func (m *ComputeDomainCliqueManager) getClique() (*nvapi.ComputeDomainClique, error) {
	key := fmt.Sprintf("%s/%s", m.config.podNamespace, m.cliqueName())
	obj, exists, err := m.mutationCache.GetByKey(key)
	if err != nil {
		return nil, fmt.Errorf("error retrieving ComputeDomainClique: %w", err)
	}
	if !exists {
		return nil, nil
	}
	clique, ok := obj.(*nvapi.ComputeDomainClique)
	if !ok {
		return nil, fmt.Errorf("unexpected object type in cache")
	}
	return clique, nil
}

func (m *ComputeDomainCliqueManager) ensureCliqueExists(ctx context.Context) error {
	clique, err := m.getClique()
	if err != nil {
		return fmt.Errorf("failed to get CDClique '%s': %w", m.cliqueName(), err)
	}
	if clique != nil {
		klog.Infof("CDClique '%s' already exists", m.cliqueName())
		return nil
	}

	newClique := &nvapi.ComputeDomainClique{
		ObjectMeta: metav1.ObjectMeta{
			Name:      m.cliqueName(),
			Namespace: m.config.podNamespace,
			Labels: map[string]string{
				computeDomainLabelKey:       m.config.computeDomainUUID,
				computeDomainCliqueLabelKey: m.config.cliqueID,
			},
		},
	}
	m.ensureOwnerReference(newClique)

	createdClique, err := m.config.clientsets.Nvidia.ResourceV1beta1().ComputeDomainCliques(m.config.podNamespace).Create(ctx, newClique, metav1.CreateOptions{})
	if err != nil {
		return fmt.Errorf("failed to create CDClique '%s': %w", m.cliqueName(), err)
	}
	m.mutationCache.Mutation(createdClique)

	klog.Infof("Successfully created CDClique '%s'", m.cliqueName())
	return nil
}

func (m *ComputeDomainCliqueManager) onAddOrUpdate(ctx context.Context, obj any) error {
	o, ok := obj.(*nvapi.ComputeDomainClique)
	if !ok {
		return fmt.Errorf("failed to cast to ComputeDomainClique")
	}

	if o.Name != m.cliqueName() {
		return nil
	}

	clique, err := m.getClique()
	if err != nil {
		return fmt.Errorf("failed to get CDClique: %w", err)
	}
	if clique == nil {
		return nil
	}

	if clique.Labels[computeDomainLabelKey] != m.config.computeDomainUUID {
		klog.Warningf("CDClique processed with non-matching ComputeDomain UID (%v, %v)", clique.Labels[computeDomainLabelKey], m.config.computeDomainUUID)
		return nil
	}

	clique, err = m.syncDaemonInfoToClique(ctx, clique)
	if err != nil {
		return fmt.Errorf("CDClique update: failed to insert/update daemon info: %w", err)
	}
	m.maybePushDaemonsUpdate(clique)

	return nil
}

func (m *ComputeDomainCliqueManager) syncDaemonInfoToClique(ctx context.Context, clique *nvapi.ComputeDomainClique) (*nvapi.ComputeDomainClique, error) {
	var myDaemon *nvapi.ComputeDomainDaemonInfo

	newClique := clique.DeepCopy()

	for _, d := range newClique.Daemons {
		if d.NodeName == m.config.nodeName {
			myDaemon = d
			break
		}
	}

	if myDaemon != nil && myDaemon.IPAddress == m.config.podIP {
		klog.V(6).Infof("syncDaemonInfoToClique noop: pod IP unchanged (%s)", m.config.podIP)
		return newClique, nil
	}

	if myDaemon == nil {
		nextIndex, err := m.getNextAvailableIndex(newClique.Daemons)
		if err != nil {
			return nil, fmt.Errorf("error getting next available index: %w", err)
		}

		myDaemon = &nvapi.ComputeDomainDaemonInfo{
			NodeName: m.config.nodeName,
			CliqueID: m.config.cliqueID,
			Index:    nextIndex,
			Status:   nvapi.ComputeDomainStatusNotReady,
		}

		klog.Infof("CDClique does not contain node name '%s' yet, try to insert myself: %v", m.config.nodeName, myDaemon)
		newClique.Daemons = append(newClique.Daemons, myDaemon)
	}

	myDaemon.IPAddress = m.config.podIP

	m.ensureOwnerReference(newClique)

	newClique, err := m.config.clientsets.Nvidia.ResourceV1beta1().ComputeDomainCliques(m.config.podNamespace).Update(ctx, newClique, metav1.UpdateOptions{})
	if err != nil {
		return nil, fmt.Errorf("error updating CDClique: %w", err)
	}
	m.mutationCache.Mutation(newClique)

	klog.Infof("Successfully inserted/updated daemon info in CDClique %s (myDaemon: %v)", m.cliqueName(), myDaemon)
	return newClique, nil
}

func (m *ComputeDomainCliqueManager) getNextAvailableIndex(daemons []*nvapi.ComputeDomainDaemonInfo) (int, error) {
	usedIndices := make(map[int]bool)

	for _, d := range daemons {
		usedIndices[d.Index] = true
	}

	nextIndex := 0
	for usedIndices[nextIndex] {
		nextIndex++
	}

	if nextIndex < 0 || nextIndex >= m.config.maxNodesPerIMEXDomain {
		return -1, fmt.Errorf("no available indices within maxNodesPerIMEXDomain (%d)", m.config.maxNodesPerIMEXDomain)
	}

	return nextIndex, nil
}

func (m *ComputeDomainCliqueManager) removeDaemonInfoFromClique(ctx context.Context) error {
	clique, err := m.getClique()
	if err != nil {
		return fmt.Errorf("failed to get CDClique: %w", err)
	}
	if clique == nil {
		return nil
	}

	newClique := clique.DeepCopy()
	var newDaemons []*nvapi.ComputeDomainDaemonInfo
	for _, d := range newClique.Daemons {
		if d.IPAddress != m.config.podIP {
			newDaemons = append(newDaemons, d)
		}
	}
	newClique.Daemons = newDaemons

	newClique, err = m.config.clientsets.Nvidia.ResourceV1beta1().ComputeDomainCliques(m.config.podNamespace).Update(ctx, newClique, metav1.UpdateOptions{})
	if err != nil {
		return fmt.Errorf("error updating CDClique: %w", err)
	}
	m.mutationCache.Mutation(newClique)

	klog.Infof("Successfully removed daemon with IP %s from CDClique %s (from ComputeDomain %s/%s)", m.config.podIP, m.cliqueName(), m.config.computeDomainNamespace, m.config.computeDomainName)
	return nil
}

func (m *ComputeDomainCliqueManager) maybePushDaemonsUpdate(clique *nvapi.ComputeDomainClique) {
	newIPs := m.getIPSet(clique.Daemons)
	previousIPs := m.getIPSet(m.previousDaemons)

	if !maps.Equal(newIPs, previousIPs) {
		added, removed := previousIPs.Diff(newIPs)
		klog.V(2).Infof("IP set for clique changed.\nAdded: %v\nRemoved: %v", added, removed)
		m.previousDaemons = clique.Daemons
		m.updatedDaemonsChan <- clique.Daemons
	} else {
		klog.V(6).Infof("IP set for clique did not change")
	}
}

func (m *ComputeDomainCliqueManager) updateDaemonStatus(ctx context.Context, ready bool) error {
	status := nvapi.ComputeDomainStatusNotReady
	if ready {
		status = nvapi.ComputeDomainStatusReady
	}

	clique, err := m.getClique()
	if err != nil {
		return fmt.Errorf("failed to get CDClique: %w", err)
	}
	if clique == nil {
		return fmt.Errorf("CDClique '%s' not found", m.cliqueName())
	}

	newClique := clique.DeepCopy()

	var myDaemon *nvapi.ComputeDomainDaemonInfo
	for _, d := range newClique.Daemons {
		if d.NodeName == m.config.nodeName {
			myDaemon = d
			break
		}
	}
	if myDaemon == nil {
		return fmt.Errorf("daemon info not yet listed in CDClique (waiting for insertion)")
	}

	if myDaemon.Status == status {
		klog.V(6).Infof("updateDaemonStatus noop: status not changed (%s)", status)
		return nil
	}

	myDaemon.Status = status

	newClique, err = m.config.clientsets.Nvidia.ResourceV1beta1().ComputeDomainCliques(m.config.podNamespace).Update(ctx, newClique, metav1.UpdateOptions{})
	if err != nil {
		return fmt.Errorf("error updating CDClique: %w", err)
	}
	m.mutationCache.Mutation(newClique)

	klog.Infof("Successfully updated daemon info status in CDClique (new status: %s)", status)
	return nil
}

func (m *ComputeDomainCliqueManager) ensureOwnerReference(clique *nvapi.ComputeDomainClique) {
	for _, ref := range clique.OwnerReferences {
		if string(ref.UID) == m.config.podUID {
			return
		}
	}
	clique.OwnerReferences = append(clique.OwnerReferences, metav1.OwnerReference{
		APIVersion: "v1",
		Kind:       "Pod",
		Name:       m.config.podName,
		UID:        types.UID(m.config.podUID),
	})
}

func (m *ComputeDomainCliqueManager) getIPSet(daemons []*nvapi.ComputeDomainDaemonInfo) IPSet {
	set := make(IPSet)
	for _, d := range daemons {
		set[d.IPAddress] = struct{}{}
	}
	return set
}
