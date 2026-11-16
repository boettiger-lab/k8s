# Armada scheduler with one patch: the submit check treats resources held by pods that Armada does not manage
# (vLLM models on the GB10s) as available, so a job that fits once they finish stays queued instead of being
# rejected at submission. See submitcheck-non-armada.patch and boettiger-lab/k8s#188.
#
# The binary is built as upstream builds it (.goreleaser.yml: CGO off, ReleaseVersion set) and replaces
# /app/scheduler in the official image, which keeps its config files, user and entrypoint.
ARG ARMADA_VERSION=0.22.16

FROM golang:1.27.1 AS build
ARG ARMADA_VERSION
RUN git clone --depth 1 --branch v${ARMADA_VERSION} https://github.com/armadaproject/armada.git /src
WORKDIR /src
COPY submitcheck-non-armada.patch /tmp/
RUN git apply /tmp/submitcheck-non-armada.patch \
 && go test ./internal/scheduler/ -run TestSubmitChecker \
 && CGO_ENABLED=0 go build \
      -ldflags "-X github.com/armadaproject/armada/internal/common/build.ReleaseVersion=${ARMADA_VERSION}-nonarmada" \
      -o /scheduler ./cmd/scheduler

FROM gresearch/armada-scheduler:${ARMADA_VERSION}
COPY --from=build /scheduler /app/scheduler
