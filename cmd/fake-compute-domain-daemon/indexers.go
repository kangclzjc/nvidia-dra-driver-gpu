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
	"fmt"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/tools/cache"
)

func uidIndexer[T metav1.ObjectMetaAccessor](obj any) ([]string, error) {
	d, ok := obj.(T)
	if !ok {
		return nil, fmt.Errorf("expected a %T but got %T", *new(T), obj)
	}
	return []string{string(d.GetObjectMeta().GetUID())}, nil
}

// getByComputeDomainUID retrieves objects by UID using the mutation cache.
func getByComputeDomainUID[T any](mutationCache cache.MutationCache, uid string) ([]T, error) {
	objs, err := mutationCache.ByIndex("uid", uid)
	if err != nil {
		return nil, fmt.Errorf("error retrieving objects by UID: %w", err)
	}

	var result []T
	for _, obj := range objs {
		if t, ok := obj.(T); ok {
			result = append(result, t)
		}
	}
	return result, nil
}
