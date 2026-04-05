# Dockerfile for fake-cd-kubelet-plugin
# Lightweight multi-stage build — no NVIDIA dependencies needed.

FROM golang:1.25 AS build

WORKDIR /build
COPY go.mod go.sum ./
COPY vendor/ vendor/
COPY cmd/ cmd/
COPY api/ api/
COPY internal/ internal/
COPY pkg/ pkg/

ARG TARGETARCH
RUN CGO_ENABLED=0 GOOS=linux GOARCH=${TARGETARCH} \
    go build -mod=vendor -o /fake-cd-kubelet-plugin \
    ./cmd/fake-cd-kubelet-plugin

FROM gcr.io/distroless/static:nonroot
COPY --from=build /fake-cd-kubelet-plugin /usr/bin/fake-cd-kubelet-plugin
ENTRYPOINT ["/usr/bin/fake-cd-kubelet-plugin"]
