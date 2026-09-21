// Package audit emits structured, single-line JSON audit events that capture the
// complete lifecycle of an agent interaction:
//
//  1. interaction_received  -- the user prompt / system trigger that started it.
//  2. tool_query            -- each tool or data source the agent queried.
//  3. interaction_outcome   -- the AI action / final outcome.
//
// Every event carries an interaction_id so the three phases can be correlated
// into one trace. Events are written as JSON to stdout; the platform log pipeline
// (e.g. OpenShift Logging / ClusterLogForwarder) is responsible for shipping them
// to a centralized, immutable store with retention. See doc/audit-logging.md.
//
// Audit events deliberately record metadata about the response (length, hash,
// redaction counts) rather than the response text itself, to avoid persisting
// potentially sensitive payloads in the audit trail.
package audit

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"log/slog"
	"os"
)

type ctxKey int

const interactionIDKey ctxKey = iota

// logger is a dedicated JSON logger tagged so audit events are easy to select
// (`log_type=audit`) in a central log store and separable from operational logs.
var logger = slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo})).
	With("log_type", "audit", "component", "prow-analyzer")

// WithInteractionID returns a context carrying the interaction correlation ID.
func WithInteractionID(ctx context.Context, id string) context.Context {
	return context.WithValue(ctx, interactionIDKey, id)
}

// InteractionID extracts the correlation ID from ctx ("" if absent).
func InteractionID(ctx context.Context) string {
	if v, ok := ctx.Value(interactionIDKey).(string); ok {
		return v
	}
	return ""
}

// Received records the trigger that started an interaction (lifecycle event 1/3):
// who/what initiated it and the prompt/trigger content.
func Received(ctx context.Context, source, actor, channel, trigger string) {
	logger.LogAttrs(ctx, slog.LevelInfo, "interaction_received",
		slog.String("event", "interaction_received"),
		slog.String("interaction_id", InteractionID(ctx)),
		slog.String("source", source),
		slog.String("actor", actor),
		slog.String("channel", channel),
		slog.String("trigger", trigger),
	)
}

// ToolQuery records a tool or data source the agent queried to formulate its
// response (lifecycle event 2/3). Extra key/value attrs are appended.
func ToolQuery(ctx context.Context, target, operation string, attrs ...any) {
	args := []any{
		slog.String("event", "tool_query"),
		slog.String("interaction_id", InteractionID(ctx)),
		slog.String("target", target),
		slog.String("operation", operation),
	}
	args = append(args, attrs...)
	logger.Log(ctx, slog.LevelInfo, "tool_query", args...)
}

// Outcome records the AI action / final outcome that concluded an interaction
// (lifecycle event 3/3). Extra key/value attrs are appended.
func Outcome(ctx context.Context, status string, attrs ...any) {
	args := []any{
		slog.String("event", "interaction_outcome"),
		slog.String("interaction_id", InteractionID(ctx)),
		slog.String("status", status),
	}
	args = append(args, attrs...)
	logger.Log(ctx, slog.LevelInfo, "interaction_outcome", args...)
}

// Hash returns a short SHA-256 hex digest, used to fingerprint response content
// in the audit trail without storing the content itself.
func Hash(s string) string {
	sum := sha256.Sum256([]byte(s))
	return hex.EncodeToString(sum[:])[:16]
}
