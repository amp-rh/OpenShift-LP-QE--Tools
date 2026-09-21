FROM registry.ci.openshift.org/ocp/builder:rhel-9-golang-1.25-openshift-4.22 AS builder
WORKDIR /go/src/github.com/oramraz/prow-analyzer
# Build context is apps/prow-analyzer/ when called from image/container/prow-analyzer/Makefile
COPY . .
RUN go mod vendor && \
    go build -o /prow-analyzer--cli ./cmd/prow-analyzer--cli && \
    go build -o /prow-analyzer--bot ./cmd/prow-analyzer--bot

FROM registry.ci.openshift.org/ocp/4.22:base-rhel9
COPY --from=builder /prow-analyzer--cli /usr/bin/prow-analyzer--cli
COPY --from=builder /prow-analyzer--bot /usr/bin/prow-analyzer--bot
USER 1000:1000
ENTRYPOINT ["/usr/bin/prow-analyzer--bot"]
