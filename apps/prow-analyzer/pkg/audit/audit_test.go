package audit

import (
	"context"
	"testing"
)

func TestInteractionIDRoundTrip(t *testing.T) {
	ctx := WithInteractionID(context.Background(), "C123/456.789")
	if got := InteractionID(ctx); got != "C123/456.789" {
		t.Errorf("InteractionID = %q, want %q", got, "C123/456.789")
	}
}

func TestInteractionIDAbsent(t *testing.T) {
	if got := InteractionID(context.Background()); got != "" {
		t.Errorf("InteractionID on empty ctx = %q, want empty", got)
	}
}

func TestHashIsStableAndShort(t *testing.T) {
	a := Hash("some analysis text")
	b := Hash("some analysis text")
	c := Hash("different text")
	if a != b {
		t.Errorf("Hash not deterministic: %q vs %q", a, b)
	}
	if a == c {
		t.Error("Hash collision on different inputs")
	}
	if len(a) != 16 {
		t.Errorf("Hash length = %d, want 16", len(a))
	}
}

// Ensure the emit helpers do not panic with or without an interaction ID.
func TestEmittersDoNotPanic(t *testing.T) {
	ctx := WithInteractionID(context.Background(), "test-id")
	Received(ctx, "slack", "U1", "C1", "https://prow.ci.openshift.org/view/x")
	ToolQuery(ctx, "ship-help-mcp", "tools/call", "tool", "ask_persona", "persona", "ship_public")
	Outcome(ctx, "success", "duration_ms", int64(1234), "response_chars", 42)
}
