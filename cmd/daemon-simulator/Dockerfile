# Copyright The Kubernetes Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Build stage
FROM golang:1.25 AS builder

WORKDIR /build

# Copy go module files first for layer caching
COPY go.mod go.sum ./
RUN go mod download

# Copy the entire project (needed for internal packages)
COPY . .

ARG VERSION=v25.12.0

# Build the daemon-simulator binary
RUN CGO_ENABLED=0 GOOS=linux go build \
    -ldflags="-s -w -X sigs.k8s.io/nvidia-dra-driver-gpu/internal/info.version=${VERSION}" \
    -o /daemon-simulator \
    ./cmd/daemon-simulator/

# Runtime stage — minimal distroless image
FROM gcr.io/distroless/static:nonroot

COPY --from=builder /daemon-simulator /usr/bin/daemon-simulator

USER 65534:65534

ENTRYPOINT ["daemon-simulator"]
