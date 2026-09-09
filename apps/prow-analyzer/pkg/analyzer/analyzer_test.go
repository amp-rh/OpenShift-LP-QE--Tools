package analyzer

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestNewAnalyzer(t *testing.T) {
	mcpURL := "https://example.com/mcp"
	token := "test-token"
	template := "Analyze {job_url}"

	analyzer := NewAnalyzer(mcpURL, token, template)

	if analyzer.mcpURL != mcpURL {
		t.Errorf("Expected mcpURL %s, got %s", mcpURL, analyzer.mcpURL)
	}
	if analyzer.token != token {
		t.Errorf("Expected token %s, got %s", token, analyzer.token)
	}
	if analyzer.template != template {
		t.Errorf("Expected template %s, got %s", template, analyzer.template)
	}
	if analyzer.client == nil {
		t.Error("Expected client to be initialized")
	}
	// Verify client is *http.Client with correct timeout
	httpClient, ok := analyzer.client.(*http.Client)
	if !ok {
		t.Error("Expected client to be *http.Client")
	} else if httpClient.Timeout != 240*time.Second {
		t.Errorf("Expected timeout 240s, got %v", httpClient.Timeout)
	}
	// Verify injected functions
	if analyzer.jsonMarshal == nil {
		t.Error("Expected jsonMarshal to be initialized")
	}
	if analyzer.newRequest == nil {
		t.Error("Expected newRequest to be initialized")
	}
}

func TestExtractProwURL(t *testing.T) {
	tests := []struct {
		name     string
		input    string
		expected string
	}{
		{
			name:     "plain URL",
			input:    "Check this: https://prow.ci.openshift.org/view/gs/test-platform-results/logs/job/123",
			expected: "https://prow.ci.openshift.org/view/gs/test-platform-results/logs/job/123",
		},
		{
			name:     "Slack formatted URL",
			input:    "<https://prow.ci.openshift.org/view/gs/test-platform-results/logs/job/456>",
			expected: "https://prow.ci.openshift.org/view/gs/test-platform-results/logs/job/456",
		},
		{
			name:     "URL with trailing punctuation",
			input:    "Failed: https://prow.ci.openshift.org/view/gs/test-platform-results/logs/job/789)",
			expected: "https://prow.ci.openshift.org/view/gs/test-platform-results/logs/job/789",
		},
		{
			name:     "Slack link with label",
			input:    "Check <https://prow.ci.openshift.org/view/gs/test-platform-results/logs/job/abc|this link>",
			expected: "https://prow.ci.openshift.org/view/gs/test-platform-results/logs/job/abc",
		},
		{
			name:     "no URL",
			input:    "No Prow URL here",
			expected: "",
		},
		{
			name:     "deck-internal URL",
			input:    "https://deck-internal-ci.apps.ci.l2s4.p1.openshiftapps.com/view/job/123",
			expected: "https://deck-internal-ci.apps.ci.l2s4.p1.openshiftapps.com/view/job/123",
		},
		{
			name:     "prow PR URL",
			input:    "https://prow.ci.openshift.org/?pr=12345",
			expected: "https://prow.ci.openshift.org/?pr=12345",
		},
		{
			name:     "multiple trailing punctuation",
			input:    "URL: https://prow.ci.openshift.org/view/gs/test/job/1>.",
			expected: "https://prow.ci.openshift.org/view/gs/test/job/1",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := ExtractProwURL(tt.input)
			if result != tt.expected {
				t.Errorf("Expected %q, got %q", tt.expected, result)
			}
		})
	}
}

func TestContainsProwURL(t *testing.T) {
	tests := []struct {
		name     string
		input    string
		expected bool
	}{
		{
			name:     "contains URL",
			input:    "Check https://prow.ci.openshift.org/view/gs/test/job/1",
			expected: true,
		},
		{
			name:     "no URL",
			input:    "Just some text",
			expected: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := ContainsProwURL(tt.input)
			if result != tt.expected {
				t.Errorf("Expected %v, got %v", tt.expected, result)
			}
		})
	}
}

func TestFormatSlackResponse(t *testing.T) {
	t.Run("valid result", func(t *testing.T) {
		result := &AnalysisResult{
			JobURL:   "https://prow.ci.openshift.org/view/gs/test/job/1",
			Analysis: "Root cause: test failure",
			Duration: 78600 * time.Millisecond,
		}

		response := FormatSlackResponse(result)

		if !strings.Contains(response, "🔍 *Prow Analyzer Analysis*") {
			t.Error("Expected header in response")
		}
		if !strings.Contains(response, "Root cause: test failure") {
			t.Error("Expected analysis in response")
		}
		if !strings.Contains(response, "78.6s") {
			t.Error("Expected duration in response")
		}
		if !strings.Contains(response, "Powered by ship-help MCP") {
			t.Error("Expected footer in response")
		}
	})

	t.Run("nil result", func(t *testing.T) {
		response := FormatSlackResponse(nil)
		if !strings.Contains(response, "❌ Error") {
			t.Error("Expected error message for nil result")
		}
	})
}

func TestParseSSEMessage(t *testing.T) {
	tests := []struct {
		name     string
		input    string
		expected string
	}{
		{
			name:     "valid SSE",
			input:    "event: message\ndata: {\"result\":\"success\"}\n\n",
			expected: "{\"result\":\"success\"}",
		},
		{
			name:     "no data line",
			input:    "event: message\n\n",
			expected: "",
		},
		{
			name:     "multiple lines",
			input:    "event: message\nid: 1\ndata: test\n\n",
			expected: "test",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := parseSSEMessage(tt.input)
			if result != tt.expected {
				t.Errorf("Expected %q, got %q", tt.expected, result)
			}
		})
	}
}

func TestAnalyzeFailure_InitializeSession(t *testing.T) {
	sessionID := "test-session-123"
	analysisText := "Test analysis result"

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "POST" {
			t.Errorf("Expected POST, got %s", r.Method)
		}

		// Check authorization header
		authHeader := r.Header.Get("Authorization")
		if authHeader != "Bearer test-token" {
			t.Errorf("Expected Bearer token, got %s", authHeader)
		}

		// Parse request body
		var req MCPRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			t.Fatalf("Failed to decode request: %v", err)
		}

		// Handle initialize vs tools/call
		if req.Method == "initialize" {
			// Return session ID
			w.Header().Set("Mcp-Session-Id", sessionID)
			resp := MCPResponse{
				JSONRPC: "2.0",
				ID:      req.ID,
			}
			json.NewEncoder(w).Encode(resp)
		} else if req.Method == "tools/call" {
			// Return analysis
			w.Header().Set("Content-Type", "text/event-stream")
			resp := MCPResponse{
				JSONRPC: "2.0",
				ID:      req.ID,
			}
			resp.Result.Content = []struct {
				Type string `json:"type"`
				Text string `json:"text"`
			}{
				{Type: "text", Text: analysisText},
			}
			jsonData, _ := json.Marshal(resp)
			w.Write([]byte("event: message\ndata: " + string(jsonData) + "\n\n"))
		}
	}))
	defer server.Close()

	analyzer := NewAnalyzer(server.URL, "test-token", "Analyze {job_url}")
	ctx := context.Background()

	result, err := analyzer.AnalyzeFailure(ctx, "https://prow.ci.openshift.org/view/test")
	if err != nil {
		t.Fatalf("AnalyzeFailure failed: %v", err)
	}

	if result.Analysis != analysisText {
		t.Errorf("Expected analysis %q, got %q", analysisText, result.Analysis)
	}
	if result.JobURL != "https://prow.ci.openshift.org/view/test" {
		t.Errorf("Expected job URL, got %q", result.JobURL)
	}
	if result.Duration == 0 {
		t.Error("Expected non-zero duration")
	}
}

func TestAnalyzeFailure_SessionReuse(t *testing.T) {
	callCount := 0
	sessionID := "reuse-session"

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req MCPRequest
		json.NewDecoder(r.Body).Decode(&req)

		if req.Method == "initialize" {
			callCount++
			w.Header().Set("Mcp-Session-Id", sessionID)
			json.NewEncoder(w).Encode(MCPResponse{JSONRPC: "2.0", ID: req.ID})
		} else {
			resp := MCPResponse{JSONRPC: "2.0", ID: req.ID}
			resp.Result.Content = []struct {
				Type string `json:"type"`
				Text string `json:"text"`
			}{{Type: "text", Text: "analysis"}}
			jsonData, _ := json.Marshal(resp)
			w.Write([]byte("data: " + string(jsonData) + "\n"))
		}
	}))
	defer server.Close()

	analyzer := NewAnalyzer(server.URL, "token", "template")
	ctx := context.Background()

	// First call - should initialize
	_, err := analyzer.AnalyzeFailure(ctx, "url1")
	if err != nil {
		t.Fatalf("First AnalyzeFailure failed: %v", err)
	}

	// Second call - should reuse session
	_, err = analyzer.AnalyzeFailure(ctx, "url2")
	if err != nil {
		t.Fatalf("Second AnalyzeFailure failed: %v", err)
	}

	if callCount != 1 {
		t.Errorf("Expected 1 initialize call, got %d", callCount)
	}
}

func TestAnalyzeFailure_Errors(t *testing.T) {
	t.Run("initialize error - no session ID", func(t *testing.T) {
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			// Don't set session ID header
			json.NewEncoder(w).Encode(MCPResponse{})
		}))
		defer server.Close()

		analyzer := NewAnalyzer(server.URL, "token", "template")
		_, err := analyzer.AnalyzeFailure(context.Background(), "url")

		if err == nil || !strings.Contains(err.Error(), "no session ID") {
			t.Errorf("Expected session ID error, got: %v", err)
		}
	})

	t.Run("MCP error response", func(t *testing.T) {
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			var req MCPRequest
			json.NewDecoder(r.Body).Decode(&req)

			if req.Method == "initialize" {
				w.Header().Set("Mcp-Session-Id", "test")
				json.NewEncoder(w).Encode(MCPResponse{})
			} else {
				resp := MCPResponse{
					JSONRPC: "2.0",
					ID:      req.ID,
					Error: &struct {
						Code    int    `json:"code"`
						Message string `json:"message"`
					}{Code: -32600, Message: "Invalid request"},
				}
				jsonData, _ := json.Marshal(resp)
				w.Write([]byte("data: " + string(jsonData) + "\n"))
			}
		}))
		defer server.Close()

		analyzer := NewAnalyzer(server.URL, "token", "template")
		_, err := analyzer.AnalyzeFailure(context.Background(), "url")

		if err == nil || !strings.Contains(err.Error(), "MCP error") {
			t.Errorf("Expected MCP error, got: %v", err)
		}
	})

	t.Run("HTTP error status", func(t *testing.T) {
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			var req MCPRequest
			json.NewDecoder(r.Body).Decode(&req)

			if req.Method == "initialize" {
				w.Header().Set("Mcp-Session-Id", "test")
				json.NewEncoder(w).Encode(MCPResponse{})
			} else {
				w.WriteHeader(http.StatusInternalServerError)
				w.Write([]byte("Server error"))
			}
		}))
		defer server.Close()

		analyzer := NewAnalyzer(server.URL, "token", "template")
		_, err := analyzer.AnalyzeFailure(context.Background(), "url")

		if err == nil || !strings.Contains(err.Error(), "HTTP 500") {
			t.Errorf("Expected HTTP error, got: %v", err)
		}
	})

	t.Run("no content in response", func(t *testing.T) {
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			var req MCPRequest
			json.NewDecoder(r.Body).Decode(&req)

			if req.Method == "initialize" {
				w.Header().Set("Mcp-Session-Id", "test")
				json.NewEncoder(w).Encode(MCPResponse{})
			} else {
				resp := MCPResponse{JSONRPC: "2.0", ID: req.ID}
				// Empty content
				jsonData, _ := json.Marshal(resp)
				w.Write([]byte("data: " + string(jsonData) + "\n"))
			}
		}))
		defer server.Close()

		analyzer := NewAnalyzer(server.URL, "token", "template")
		_, err := analyzer.AnalyzeFailure(context.Background(), "url")

		if err == nil || !strings.Contains(err.Error(), "no content") {
			t.Errorf("Expected no content error, got: %v", err)
		}
	})

	t.Run("empty SSE response", func(t *testing.T) {
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			var req MCPRequest
			json.NewDecoder(r.Body).Decode(&req)

			if req.Method == "initialize" {
				w.Header().Set("Mcp-Session-Id", "test")
				json.NewEncoder(w).Encode(MCPResponse{})
			} else {
				// No SSE data line
				w.Write([]byte("event: message\n\n"))
			}
		}))
		defer server.Close()

		analyzer := NewAnalyzer(server.URL, "token", "template")
		_, err := analyzer.AnalyzeFailure(context.Background(), "url")

		if err == nil || !strings.Contains(err.Error(), "no JSON data") {
			t.Errorf("Expected SSE parse error, got: %v", err)
		}
	})

	t.Run("context canceled", func(t *testing.T) {
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			time.Sleep(100 * time.Millisecond)
		}))
		defer server.Close()

		analyzer := NewAnalyzer(server.URL, "token", "template")
		ctx, cancel := context.WithCancel(context.Background())
		cancel() // Cancel immediately

		_, err := analyzer.AnalyzeFailure(ctx, "url")
		if err == nil {
			t.Error("Expected context canceled error")
		}
	})

	t.Run("invalid JSON in SSE", func(t *testing.T) {
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			var req MCPRequest
			json.NewDecoder(r.Body).Decode(&req)

			if req.Method == "initialize" {
				w.Header().Set("Mcp-Session-Id", "test")
				json.NewEncoder(w).Encode(MCPResponse{})
			} else {
				// Invalid JSON in data field
				w.Write([]byte("data: {invalid json\n"))
			}
		}))
		defer server.Close()

		analyzer := NewAnalyzer(server.URL, "token", "template")
		_, err := analyzer.AnalyzeFailure(context.Background(), "url")

		if err == nil || !strings.Contains(err.Error(), "parse response") {
			t.Errorf("Expected JSON parse error, got: %v", err)
		}
	})

	t.Run("init HTTP error 500", func(t *testing.T) {
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.WriteHeader(http.StatusInternalServerError)
			w.Write([]byte("Init failed"))
		}))
		defer server.Close()

		analyzer := NewAnalyzer(server.URL, "token", "template")
		_, err := analyzer.AnalyzeFailure(context.Background(), "url")

		if err == nil || !strings.Contains(err.Error(), "init request failed") {
			t.Errorf("Expected init request failed error, got: %v", err)
		}
	})
}

// TestErrorInjection tests unreachable error paths using dependency injection
func TestErrorInjection(t *testing.T) {
	t.Run("json.Marshal error in AnalyzeFailure", func(t *testing.T) {
		// Mock client that succeeds for initialize
		mockClient := &mockHTTPClient{
			doFunc: func(req *http.Request) (*http.Response, error) {
				resp := &http.Response{
					StatusCode: 200,
					Body:       io.NopCloser(strings.NewReader(`{"jsonrpc":"2.0","id":0}`)),
					Header:     make(http.Header),
				}
				resp.Header.Set("Mcp-Session-Id", "test-session")
				return resp, nil
			},
		}

		analyzer := &Analyzer{
			mcpURL:      "http://test.com",
			token:       "token",
			client:      mockClient,
			template:    "template",
			sessionID:   "already-initialized", // Pre-initialize to skip initializeSession
			jsonMarshal: mockJSONMarshalError,  // Inject failing marshaler
			newRequest:  http.NewRequestWithContext,
		}
		analyzer.initialized = true // Mark initialization as complete

		_, err := analyzer.AnalyzeFailure(context.Background(), "url")
		if err == nil || !strings.Contains(err.Error(), "marshal request") {
			t.Errorf("Expected 'marshal request' error, got: %v", err)
		}
	})

	t.Run("http.NewRequestWithContext error in AnalyzeFailure", func(t *testing.T) {
		mockClient := &mockHTTPClient{
			doFunc: func(req *http.Request) (*http.Response, error) {
				resp := &http.Response{
					StatusCode: 200,
					Body:       io.NopCloser(strings.NewReader(`{"jsonrpc":"2.0","id":0}`)),
					Header:     make(http.Header),
				}
				resp.Header.Set("Mcp-Session-Id", "test-session")
				return resp, nil
			},
		}

		analyzer := &Analyzer{
			mcpURL:      "http://test.com",
			token:       "token",
			client:      mockClient,
			template:    "template",
			sessionID:   "already-initialized", // Pre-initialize to skip initializeSession
			jsonMarshal: json.Marshal,
			newRequest:  mockNewRequestError, // Inject failing request builder
		}
		analyzer.initialized = true // Mark initialization as complete

		_, err := analyzer.AnalyzeFailure(context.Background(), "url")
		if err == nil || !strings.Contains(err.Error(), "create request") {
			t.Errorf("Expected 'create request' error, got: %v", err)
		}
	})

	t.Run("json.Marshal error in initializeSession", func(t *testing.T) {
		analyzer := &Analyzer{
			mcpURL:      "http://test.com",
			token:       "token",
			client:      &mockHTTPClient{},
			template:    "template",
			jsonMarshal: mockJSONMarshalError, // Inject failing marshaler
			newRequest:  http.NewRequestWithContext,
		}

		_, err := analyzer.AnalyzeFailure(context.Background(), "url")
		if err == nil || !strings.Contains(err.Error(), "marshal init request") {
			t.Errorf("Expected 'marshal init request' error, got: %v", err)
		}
	})

	t.Run("http.NewRequestWithContext error in initializeSession", func(t *testing.T) {
		analyzer := &Analyzer{
			mcpURL:      "http://test.com",
			token:       "token",
			client:      &mockHTTPClient{},
			template:    "template",
			jsonMarshal: json.Marshal,
			newRequest:  mockNewRequestError, // Inject failing request builder
		}

		_, err := analyzer.AnalyzeFailure(context.Background(), "url")
		if err == nil || !strings.Contains(err.Error(), "create init request") {
			t.Errorf("Expected 'create init request' error, got: %v", err)
		}
	})

	t.Run("io.ReadAll error in initializeSession", func(t *testing.T) {
		mockClient := &mockHTTPClient{
			doFunc: func(req *http.Request) (*http.Response, error) {
				return &http.Response{
					StatusCode: 200,
					Body:       &errorReader{},
					Header:     make(http.Header),
				}, nil
			},
		}

		analyzer := &Analyzer{
			mcpURL:      "http://test.com",
			token:       "token",
			client:      mockClient,
			template:    "template",
			jsonMarshal: json.Marshal,
			newRequest:  http.NewRequestWithContext,
		}

		_, err := analyzer.AnalyzeFailure(context.Background(), "url")
		if err == nil || !strings.Contains(err.Error(), "read response") {
			t.Errorf("Expected 'read response' error from initializeSession, got: %v", err)
		}
	})

	t.Run("io.ReadAll error in AnalyzeFailure", func(t *testing.T) {
		mockClient := &mockHTTPClient{
			doFunc: func(req *http.Request) (*http.Response, error) {
				return &http.Response{
					StatusCode: 200,
					Body:       &errorReader{}, // Body that fails on Read
					Header:     make(http.Header),
				}, nil
			},
		}

		analyzer := &Analyzer{
			mcpURL:      "http://test.com",
			token:       "token",
			client:      mockClient,
			template:    "template",
			sessionID:   "already-initialized",
			jsonMarshal: json.Marshal,
			newRequest:  http.NewRequestWithContext,
		}
		analyzer.initialized = true // Mark initialization as complete

		_, err := analyzer.AnalyzeFailure(context.Background(), "url")
		if err == nil || !strings.Contains(err.Error(), "read response") {
			t.Errorf("Expected 'read response' error, got: %v", err)
		}
	})

	t.Run("client.Do error in AnalyzeFailure", func(t *testing.T) {
		mockClient := &mockHTTPClient{
			doFunc: func(req *http.Request) (*http.Response, error) {
				return nil, errors.New("mock client.Do error")
			},
		}

		analyzer := &Analyzer{
			mcpURL:      "http://test.com",
			token:       "token",
			client:      mockClient,
			template:    "template",
			sessionID:   "already-initialized",
			jsonMarshal: json.Marshal,
			newRequest:  http.NewRequestWithContext,
		}
		analyzer.initialized = true // Mark initialization as complete

		_, err := analyzer.AnalyzeFailure(context.Background(), "url")
		if err == nil || !strings.Contains(err.Error(), "send request") {
			t.Errorf("Expected 'send request' error, got: %v", err)
		}
	})

	t.Run("initialization failure is retryable", func(t *testing.T) {
		callCount := 0
		mockClient := &mockHTTPClient{
			doFunc: func(req *http.Request) (*http.Response, error) {
				callCount++
				if callCount == 1 {
					// First call fails
					return nil, errors.New("temporary network error")
				}
				// Second call succeeds
				resp := &http.Response{
					StatusCode: 200,
					Body:       io.NopCloser(strings.NewReader(`{"jsonrpc":"2.0","id":0}`)),
					Header:     make(http.Header),
				}
				resp.Header.Set("Mcp-Session-Id", "session-123")
				return resp, nil
			},
		}

		analyzer := &Analyzer{
			mcpURL:      "http://test.com",
			token:       "token",
			client:      mockClient,
			template:    "template",
			jsonMarshal: json.Marshal,
			newRequest:  http.NewRequestWithContext,
		}

		// First call should fail
		_, err := analyzer.AnalyzeFailure(context.Background(), "url")
		if err == nil || !strings.Contains(err.Error(), "temporary network error") {
			t.Errorf("Expected temporary network error, got: %v", err)
		}

		// Second call should retry initialization (would be skipped if failure were cached)
		_, _ = analyzer.AnalyzeFailure(context.Background(), "url")
		if callCount < 2 {
			t.Errorf("Expected retry to trigger another HTTP call, got %d total calls", callCount)
		}
	})
}
