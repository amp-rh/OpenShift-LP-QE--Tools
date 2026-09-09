package handler

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/slack-go/slack"
	"github.com/slack-go/slack/slackevents"

	"github.com/RedHatQE/OpenShift-LP-QE--Tools/apps/prow-analyzer/pkg/analyzer"
)

// mockSlackClient implements a mock Slack client for testing
type mockSlackClient struct {
	postedMessages []mockPostedMessage
}

type mockPostedMessage struct {
	channel string
	options []slack.MsgOption
}

func (m *mockSlackClient) PostMessage(channel string, options ...slack.MsgOption) (string, string, error) {
	m.postedMessages = append(m.postedMessages, mockPostedMessage{
		channel: channel,
		options: options,
	})
	return "ts123", "ch123", nil
}

// mockAnalyzer implements a mock analyzer for testing
type mockAnalyzer struct {
	shouldFail bool
	delay      time.Duration
}

func (m *mockAnalyzer) AnalyzeFailure(ctx context.Context, jobURL string) (*analyzer.AnalysisResult, error) {
	if m.delay > 0 {
		time.Sleep(m.delay)
	}
	if m.shouldFail {
		return nil, context.DeadlineExceeded
	}
	return &analyzer.AnalysisResult{
		JobURL:   jobURL,
		Analysis: "Test analysis result",
		Duration: 78 * time.Second,
	}, nil
}

func TestNew(t *testing.T) {
	client := &slack.Client{}
	analyzer := analyzer.NewAnalyzer("url", "token", "template")
	channels := []string{"C123", "C456"}

	h := New(client, analyzer, channels)

	if h == nil {
		t.Fatal("Expected non-nil handler")
	}

	handler, ok := h.(*handler)
	if !ok {
		t.Fatal("Expected handler type")
	}

	if handler.client != client {
		t.Error("Client not set correctly")
	}
	if handler.analyzer != analyzer {
		t.Error("Analyzer not set correctly")
	}
	if len(handler.monitoredChannels) != 2 {
		t.Errorf("Expected 2 monitored channels, got %d", len(handler.monitoredChannels))
	}
	if !handler.monitoredChannels["C123"] || !handler.monitoredChannels["C456"] {
		t.Error("Channels not added to map correctly")
	}
}

func TestIdentifier(t *testing.T) {
	h := New(&slack.Client{}, analyzer.NewAnalyzer("", "", ""), []string{})

	if h.Identifier() != "prow-analyzer" {
		t.Errorf("Expected identifier 'prow-analyzer', got %q", h.Identifier())
	}
}

func TestHandle_NotCallbackEvent(t *testing.T) {
	h := New(&slack.Client{}, analyzer.NewAnalyzer("", "", ""), []string{"C123"})
	logger := slog.Default()

	callback := &slackevents.EventsAPIEvent{
		Type: slackevents.URLVerification,
	}

	handled, err := h.Handle(callback, logger)

	if handled {
		t.Error("Expected event not to be handled")
	}
	if err != nil {
		t.Errorf("Expected no error, got %v", err)
	}
}

func TestHandle_NotMessageEvent(t *testing.T) {
	h := New(&slack.Client{}, analyzer.NewAnalyzer("", "", ""), []string{"C123"})
	logger := slog.Default()

	callback := &slackevents.EventsAPIEvent{
		Type: slackevents.CallbackEvent,
		InnerEvent: slackevents.EventsAPIInnerEvent{
			Type: string(slackevents.AppMention),
			Data: &slackevents.AppMentionEvent{},
		},
	}

	handled, err := h.Handle(callback, logger)

	if handled {
		t.Error("Expected event not to be handled")
	}
	if err != nil {
		t.Errorf("Expected no error, got %v", err)
	}
}

func TestHandle_BotMessage(t *testing.T) {
	h := New(&slack.Client{}, analyzer.NewAnalyzer("", "", ""), []string{"C123"})
	logger := slog.Default()

	callback := &slackevents.EventsAPIEvent{
		Type: slackevents.CallbackEvent,
		InnerEvent: slackevents.EventsAPIInnerEvent{
			Type: string(slackevents.Message),
			Data: &slackevents.MessageEvent{
				BotID: "B123",
				Text:  "https://prow.ci.openshift.org/view/gs/test/job/1",
			},
		},
	}

	handled, err := h.Handle(callback, logger)

	if handled {
		t.Error("Expected bot message not to be handled")
	}
	if err != nil {
		t.Errorf("Expected no error, got %v", err)
	}
}

func TestHandle_UnmonitoredChannel(t *testing.T) {
	h := New(&slack.Client{}, analyzer.NewAnalyzer("", "", ""), []string{"C123"})
	logger := slog.Default()

	callback := &slackevents.EventsAPIEvent{
		Type: slackevents.CallbackEvent,
		InnerEvent: slackevents.EventsAPIInnerEvent{
			Type: string(slackevents.Message),
			Data: &slackevents.MessageEvent{
				Channel: "C999", // Not monitored
				Text:    "https://prow.ci.openshift.org/view/gs/test/job/1",
			},
		},
	}

	handled, err := h.Handle(callback, logger)

	if handled {
		t.Error("Expected unmonitored channel not to be handled")
	}
	if err != nil {
		t.Errorf("Expected no error, got %v", err)
	}
}

func TestHandle_NoProwURL(t *testing.T) {
	h := New(&slack.Client{}, analyzer.NewAnalyzer("", "", ""), []string{"C123"})
	logger := slog.Default()

	callback := &slackevents.EventsAPIEvent{
		Type: slackevents.CallbackEvent,
		InnerEvent: slackevents.EventsAPIInnerEvent{
			Type: string(slackevents.Message),
			Data: &slackevents.MessageEvent{
				Channel: "C123",
				Text:    "Just a regular message without a Prow URL",
			},
		},
	}

	handled, err := h.Handle(callback, logger)

	if handled {
		t.Error("Expected message without Prow URL not to be handled")
	}
	if err != nil {
		t.Errorf("Expected no error, got %v", err)
	}
}

func TestHandle_Success(t *testing.T) {
	// Create a mock Slack server that accepts posts
	messageChan := make(chan bool, 1)
	slackServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/chat.postMessage" {
			messageChan <- true
		}
		w.Write([]byte(`{"ok":true,"ts":"123"}`))
	}))
	defer slackServer.Close()

	slackClient := slack.New("test-token", slack.OptionAPIURL(slackServer.URL+"/"))
	h := New(slackClient, analyzer.NewAnalyzer("", "", ""), []string{"C123"})
	logger := slog.Default()

	callback := &slackevents.EventsAPIEvent{
		Type: slackevents.CallbackEvent,
		InnerEvent: slackevents.EventsAPIInnerEvent{
			Type: string(slackevents.Message),
			Data: &slackevents.MessageEvent{
				Channel:   "C123",
				TimeStamp: "123.456",
				Text:      "Check this: https://prow.ci.openshift.org/view/gs/test/job/1",
			},
		},
	}

	handled, err := h.Handle(callback, logger)

	if !handled {
		t.Error("Expected event to be handled")
	}
	if err != nil {
		t.Errorf("Expected no error, got %v", err)
	}

	// Wait for error message to be posted (analyzer will fail but should post error)
	select {
	case <-messageChan:
		// Success - error message was posted
	case <-time.After(2 * time.Second):
		t.Error("Timeout waiting for error message to be posted to Slack")
	}
}

// TestAnalyzeAndRespond_WithMockServer tests the async path with a real HTTP server
func TestAnalyzeAndRespond_WithMockServer(t *testing.T) {
	// Create mock MCP server
	sessionID := "test-session"
	mcpServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Method string `json:"method"`
		}
		json.NewDecoder(r.Body).Decode(&req)

		if req.Method == "initialize" {
			w.Header().Set("Mcp-Session-Id", sessionID)
			w.Write([]byte(`{"jsonrpc":"2.0","id":0}`))
		} else {
			resp := `{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"Analysis result"}]}}`
			w.Write([]byte("data: " + resp + "\n"))
		}
	}))
	defer mcpServer.Close()

	// Create mock Slack server
	messageChan := make(chan bool, 1)
	slackServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/chat.postMessage" {
			messageChan <- true
			w.Write([]byte(`{"ok":true,"ts":"123"}`))
		}
	}))
	defer slackServer.Close()

	// Create Slack client pointing to mock server
	slackClient := slack.New("test-token", slack.OptionAPIURL(slackServer.URL+"/"))

	// Create analyzer pointing to mock MCP server
	anal := analyzer.NewAnalyzer(mcpServer.URL, "test-token", "template")

	h := &handler{
		client:            slackClient,
		analyzer:          anal,
		monitoredChannels: map[string]bool{"C123": true},
		semaphore:         make(chan struct{}, 5),
	}

	event := &slackevents.MessageEvent{
		Channel:   "C123",
		TimeStamp: "123.456",
	}

	logger := slog.Default()

	// Acquire semaphore before calling analyzeAndRespond (mimics Handle behavior)
	h.semaphore <- struct{}{}
	h.analyzeAndRespond(event, "https://prow.ci.openshift.org/view/test", logger)

	// Wait for message to be posted (with timeout)
	select {
	case <-messageChan:
		// Success - message was posted
	case <-time.After(2 * time.Second):
		t.Error("Timeout waiting for Slack message to be posted")
	}
}

// TestAnalyzeAndRespond_PostError tests error path when posting fails
func TestAnalyzeAndRespond_PostError(t *testing.T) {
	// Create mock MCP server
	mcpServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Method string `json:"method"`
		}
		json.NewDecoder(r.Body).Decode(&req)

		if req.Method == "initialize" {
			w.Header().Set("Mcp-Session-Id", "test")
			w.Write([]byte(`{"jsonrpc":"2.0","id":0}`))
		} else {
			resp := `{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"Analysis"}]}}`
			w.Write([]byte("data: " + resp + "\n"))
		}
	}))
	defer mcpServer.Close()

	// Create Slack server that returns errors
	postAttemptChan := make(chan bool, 1)
	slackServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/chat.postMessage" {
			postAttemptChan <- true
			w.WriteHeader(http.StatusInternalServerError)
			w.Write([]byte(`{"ok":false,"error":"posting_error"}`))
		}
	}))
	defer slackServer.Close()

	slackClient := slack.New("test", slack.OptionAPIURL(slackServer.URL+"/"))
	anal := analyzer.NewAnalyzer(mcpServer.URL, "token", "template")

	h := &handler{
		client:            slackClient,
		analyzer:          anal,
		monitoredChannels: map[string]bool{"C123": true},
		semaphore:         make(chan struct{}, 5),
	}

	event := &slackevents.MessageEvent{
		Channel:   "C123",
		TimeStamp: "123",
	}

	logger := slog.Default()

	// Acquire semaphore before calling analyzeAndRespond (mimics Handle behavior)
	h.semaphore <- struct{}{}
	// Should not panic, just log error
	h.analyzeAndRespond(event, "https://prow.ci.openshift.org/view/test", logger)

	// Wait for post attempt (with timeout)
	select {
	case <-postAttemptChan:
		// Success - posting was attempted (though it failed as expected)
	case <-time.After(2 * time.Second):
		t.Error("Timeout waiting for Slack post attempt")
	}
}

func TestHandle_SemaphoreFull(t *testing.T) {
	postChan := make(chan bool, 1)
	slackServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/chat.postMessage" {
			postChan <- true
		}
		w.Write([]byte(`{"ok":true,"ts":"123"}`))
	}))
	defer slackServer.Close()

	slackClient := slack.New("test-token", slack.OptionAPIURL(slackServer.URL+"/"))
	h := &handler{
		client:            slackClient,
		analyzer:          analyzer.NewAnalyzer("", "", ""),
		monitoredChannels: map[string]bool{"C123": true},
		semaphore:         make(chan struct{}, 1),
	}

	// Fill the semaphore so next Handle hits the default branch
	h.semaphore <- struct{}{}

	callback := &slackevents.EventsAPIEvent{
		Type: slackevents.CallbackEvent,
		InnerEvent: slackevents.EventsAPIInnerEvent{
			Type: string(slackevents.Message),
			Data: &slackevents.MessageEvent{
				Channel:   "C123",
				TimeStamp: "100.200",
				Text:      "https://prow.ci.openshift.org/view/gs/test/job/1",
			},
		},
	}

	handled, err := h.Handle(callback, slog.Default())

	if !handled {
		t.Error("Expected event to be handled even when queue is full")
	}
	if err != nil {
		t.Errorf("Expected no error, got %v", err)
	}

	select {
	case <-postChan:
		// Queue-full message was posted
	case <-time.After(2 * time.Second):
		t.Error("Timeout waiting for queue-full message")
	}
}

func TestHandle_SemaphoreFull_PostError(t *testing.T) {
	slackServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		w.Write([]byte(`{"ok":false,"error":"server_error"}`))
	}))
	defer slackServer.Close()

	slackClient := slack.New("test-token", slack.OptionAPIURL(slackServer.URL+"/"))
	h := &handler{
		client:            slackClient,
		analyzer:          analyzer.NewAnalyzer("", "", ""),
		monitoredChannels: map[string]bool{"C123": true},
		semaphore:         make(chan struct{}, 1),
	}

	h.semaphore <- struct{}{}

	callback := &slackevents.EventsAPIEvent{
		Type: slackevents.CallbackEvent,
		InnerEvent: slackevents.EventsAPIInnerEvent{
			Type: string(slackevents.Message),
			Data: &slackevents.MessageEvent{
				Channel:   "C123",
				TimeStamp: "100.200",
				Text:      "https://prow.ci.openshift.org/view/gs/test/job/1",
			},
		},
	}

	handled, err := h.Handle(callback, slog.Default())

	if !handled {
		t.Error("Expected event to be handled")
	}
	if err != nil {
		t.Errorf("Expected no error, got %v", err)
	}
}

func TestAnalyzeAndRespond_AnalyzerFailure_PostError(t *testing.T) {
	// MCP server that fails on tools/call
	mcpServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Method string `json:"method"`
		}
		json.NewDecoder(r.Body).Decode(&req)

		if req.Method == "initialize" {
			w.Header().Set("Mcp-Session-Id", "test")
			w.Write([]byte(`{"jsonrpc":"2.0","id":0}`))
		} else {
			w.WriteHeader(http.StatusInternalServerError)
			w.Write([]byte(`internal error`))
		}
	}))
	defer mcpServer.Close()

	// Slack server that rejects posts
	slackServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		w.Write([]byte(`{"ok":false,"error":"posting_error"}`))
	}))
	defer slackServer.Close()

	slackClient := slack.New("test", slack.OptionAPIURL(slackServer.URL+"/"))
	anal := analyzer.NewAnalyzer(mcpServer.URL, "token", "template")

	h := &handler{
		client:            slackClient,
		analyzer:          anal,
		monitoredChannels: map[string]bool{"C123": true},
		semaphore:         make(chan struct{}, 5),
	}

	event := &slackevents.MessageEvent{
		Channel:   "C123",
		TimeStamp: "123",
	}

	h.semaphore <- struct{}{}
	// Should not panic; exercises error path where both analyzer and post fail
	h.analyzeAndRespond(event, "https://prow.ci.openshift.org/view/test", slog.Default())
}

// Interface compliance check
var _ PartialHandler = (*handler)(nil)
