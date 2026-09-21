// Package analyzer provides test failure analysis using ship-help MCP
package analyzer

import (
	"bufio"
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/RedHatQE/OpenShift-LP-QE--Tools/apps/prow-analyzer/pkg/audit"
)

// Disclaimer is the mandatory Red Hat AI agent usage notice. It must be shown to
// users prior to or at the point of first interaction and remain persistent and
// easily visible throughout the session. Because this bot's UI is Slack messages
// and each reply is a discrete interaction, the notice is prepended to every
// message the bot posts (analysis results, errors, and queue-full replies).
const Disclaimer = "⚠️ *You are about to interact with a Red Hat AI agent.* " +
	"This agent uses AI technology to assist you by responding to queries, generating content, or performing tasks. " +
	"By proceeding, you acknowledge that all AI agent outputs are intended for internal use only and must be reviewed prior to use."

// ReviewNotice is the mandatory, persistent reminder shown on every message so
// it is always visible in the UI regardless of the message's outcome.
const ReviewNotice = "⚠️ Always review AI-generated output prior to use"

// WithDisclaimer wraps a message with the mandatory Red Hat AI agent notice
// (prepended, at the point of interaction) and the persistent review notice
// (appended), so both remain visible on every message the bot posts.
func WithDisclaimer(message string) string {
	return Disclaimer + "\n\n" + message + "\n\n" + ReviewNotice
}

// AILabel is the persistent, easily-visible marker applied to all AI-generated
// output (analyses, summaries, insights) at the point of delivery. It is placed
// both at the top and the bottom of every analysis result so it remains visible
// regardless of how much content is between them.
const AILabel = "🤖 AI-generated"

// HTTPDoer interface allows mocking of HTTP client
type HTTPDoer interface {
	Do(req *http.Request) (*http.Response, error)
}

// Analyzer provides test failure analysis using ship-help MCP
type Analyzer struct {
	mcpURL      string
	token       string
	client      HTTPDoer
	template    string
	sessionID   string // MCP session ID
	sessionMtx  sync.Mutex
	initMtx     sync.Mutex
	initialized bool
	insecureTLS bool
	jsonMarshal func(v interface{}) ([]byte, error)
	newRequest  func(ctx context.Context, method, url string, body io.Reader) (*http.Request, error)
}

// defaultMCPTimeout is the HTTP client timeout for ship-help MCP requests. It
// caps the ENTIRE request, including reading the streamed SSE response body, so
// it must exceed the longest analysis. Upgrade-interop jobs can take >10 min, so
// the default is 20 min. Override with MCP_TIMEOUT_SECONDS (see MCPTimeout).
const defaultMCPTimeout = 1200 * time.Second

// MCPTimeout returns the ship-help MCP HTTP client timeout. It reads
// MCP_TIMEOUT_SECONDS (a positive integer number of seconds) and falls back to
// defaultMCPTimeout when the var is unset, empty, or invalid. It is exported so
// callers can size behavior (e.g. the handler's dedup window) to outlast the
// longest an analysis may run.
func MCPTimeout() time.Duration {
	if v := os.Getenv("MCP_TIMEOUT_SECONDS"); v != "" {
		if secs, err := strconv.Atoi(v); err == nil && secs > 0 {
			return time.Duration(secs) * time.Second
		}
	}
	return defaultMCPTimeout
}

// AnalyzerOption configures optional Analyzer behavior. Existing callers that
// pass only the required arguments keep working unchanged.
type AnalyzerOption func(*Analyzer)

// WithHTTPClient overrides the HTTP client (HTTPDoer) used for both MCP and Prow
// requests. It is primarily useful for tests and for supplying a custom
// transport.
func WithHTTPClient(c HTTPDoer) AnalyzerOption {
	return func(a *Analyzer) { a.client = c }
}

// WithInsecureSkipVerify controls whether the default HTTP client skips TLS
// certificate verification. It overrides the TLS_INSECURE_SKIP_VERIFY env var
// default and lets callers (e.g. the bot's --tls-insecure flag) drive the
// setting explicitly. It has no effect when WithHTTPClient supplies a client.
func WithInsecureSkipVerify(insecure bool) AnalyzerOption {
	return func(a *Analyzer) { a.insecureTLS = insecure }
}

// NewAnalyzer creates a new Analyzer instance
func NewAnalyzer(mcpURL, token, promptTemplate string, opts ...AnalyzerOption) *Analyzer {
	a := &Analyzer{
		mcpURL:      mcpURL,
		token:       token,
		template:    promptTemplate,
		jsonMarshal: json.Marshal,
		newRequest:  http.NewRequestWithContext,
		insecureTLS: os.Getenv("TLS_INSECURE_SKIP_VERIFY") == "true",
	}
	for _, opt := range opts {
		opt(a)
	}
	if a.client == nil {
		httpClient := &http.Client{
			Timeout: MCPTimeout(),
		}
		if a.insecureTLS {
			httpClient.Transport = &http.Transport{
				TLSClientConfig: &tls.Config{InsecureSkipVerify: true}, //nolint:gosec // user-opted via env var/flag
			}
		}
		a.client = httpClient
	}
	return a
}

// MCPRequest represents an MCP JSON-RPC request
type MCPRequest struct {
	JSONRPC string      `json:"jsonrpc"`
	ID      int         `json:"id"`
	Method  string      `json:"method"`
	Params  interface{} `json:"params"`
}

// ToolCallParams represents parameters for calling an MCP tool
type ToolCallParams struct {
	Name      string                 `json:"name"`
	Arguments map[string]interface{} `json:"arguments"`
}

// MCPResponse represents an MCP JSON-RPC response
type MCPResponse struct {
	JSONRPC string `json:"jsonrpc"`
	ID      int    `json:"id"`
	Result  struct {
		Content []struct {
			Type string `json:"type"`
			Text string `json:"text"`
		} `json:"content"`
	} `json:"result"`
	Error *struct {
		Code    int    `json:"code"`
		Message string `json:"message"`
	} `json:"error,omitempty"`
}

// AnalysisResult contains the result of a failure analysis
type AnalysisResult struct {
	JobURL   string
	Analysis string
	Duration time.Duration
	Error    error
	Timings  AnalysisTimings
}

// AnalysisTimings captures where wall-clock time is spent within a single
// analysis, so slow requests can be attributed to the right subsystem.
type AnalysisTimings struct {
	SessionInit time.Duration // MCP "initialize" round-trip(s); 0 when the session was already established
	Marshal     time.Duration // JSON marshalling of the tools/call request
	MCPRequest  time.Duration // MCP tools/call HTTP round-trip up to response headers (time-to-first-byte)
	SSERead     time.Duration // reading the SSE response body (includes model generation/streaming time)
	Parse       time.Duration // JSON unmarshalling of the MCP response payload
	Total       time.Duration // end-to-end AnalyzeFailure duration
}

// AnalyzeFailure analyzes a Prow CI job failure using ship-help MCP
func (a *Analyzer) AnalyzeFailure(ctx context.Context, jobURL string) (*AnalysisResult, error) {
	startTime := time.Now()

	sessionStart := time.Now()
	if err := a.ensureSession(ctx); err != nil {
		return nil, err
	}
	sessionInit := time.Since(sessionStart)

	result, err := a.doAnalysis(ctx, jobURL, startTime)
	if err == nil || !isSessionNotFound(err) {
		attachSessionInit(result, sessionInit)
		logTimings(jobURL, result, err)
		return result, err
	}

	// Session expired on the server — re-initialize and retry once
	fmt.Printf("PROW-ANALYZER TIMING: session expired after %s, re-initializing and retrying (url=%s)\n",
		sessionInit.Round(time.Millisecond), jobURL)
	a.invalidateSession()
	retryStart := time.Now()
	if err := a.ensureSession(ctx); err != nil {
		return nil, err
	}
	sessionInit += time.Since(retryStart)

	result, err = a.doAnalysis(ctx, jobURL, startTime)
	attachSessionInit(result, sessionInit)
	logTimings(jobURL, result, err)
	return result, err
}

// attachSessionInit records session-establishment time on the result, if any.
func attachSessionInit(result *AnalysisResult, sessionInit time.Duration) {
	if result != nil {
		result.Timings.SessionInit = sessionInit
	}
}

// logTimings emits a single structured line attributing an analysis's wall-clock
// time to each subsystem (MCP session, request dispatch, streaming, parsing).
func logTimings(jobURL string, result *AnalysisResult, err error) {
	if result == nil {
		fmt.Printf("PROW-ANALYZER TIMING: url=%s FAILED err=%v\n", jobURL, err)
		return
	}
	t := result.Timings
	fmt.Printf("PROW-ANALYZER TIMING: url=%s total=%s sessionInit=%s marshal=%s mcpRequest=%s sseRead=%s parse=%s\n",
		jobURL,
		t.Total.Round(time.Millisecond),
		t.SessionInit.Round(time.Millisecond),
		t.Marshal.Round(time.Millisecond),
		t.MCPRequest.Round(time.Millisecond),
		t.SSERead.Round(time.Millisecond),
		t.Parse.Round(time.Millisecond),
	)
}

func (a *Analyzer) ensureSession(ctx context.Context) error {
	a.initMtx.Lock()
	defer a.initMtx.Unlock()
	if !a.initialized {
		if err := a.initializeSession(ctx); err != nil {
			return fmt.Errorf("initialize session: %w", err)
		}
		a.initialized = true
	}
	return nil
}

func (a *Analyzer) invalidateSession() {
	a.initMtx.Lock()
	a.initialized = false
	a.initMtx.Unlock()
}

func isSessionNotFound(err error) bool {
	return err != nil && strings.Contains(err.Error(), "Session not found")
}

func (a *Analyzer) doAnalysis(ctx context.Context, jobURL string, startTime time.Time) (*AnalysisResult, error) {
	// Build prompt using the configured template
	prompt := strings.ReplaceAll(a.template, "{job_url}", jobURL)

	// Call ship-help MCP tools/call method
	reqBody := MCPRequest{
		JSONRPC: "2.0",
		ID:      1,
		Method:  "tools/call",
		Params: map[string]interface{}{
			"name": "ask_persona",
			"arguments": map[string]interface{}{
				"question": prompt,
			},
		},
	}

	// Audit the tool/data-source query (lifecycle event 2/3): the agent is about
	// to query the ship-help persona, which in turn reads the backend data sources.
	audit.ToolQuery(ctx, "ship-help-mcp", "tools/call",
		"tool", "ask_persona",
		"persona", personaFromURL(a.mcpURL),
	)

	marshalStart := time.Now()
	jsonData, err := a.jsonMarshal(reqBody)
	if err != nil {
		return nil, fmt.Errorf("marshal request: %w", err)
	}
	marshalDur := time.Since(marshalStart)

	req, err := a.newRequest(ctx, "POST", a.mcpURL, bytes.NewBuffer(jsonData))
	if err != nil {
		return nil, fmt.Errorf("create request: %w", err)
	}

	req.Header.Set("Authorization", "Bearer "+a.token)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json, text/event-stream")

	a.sessionMtx.Lock()
	sessionID := a.sessionID
	a.sessionMtx.Unlock()
	req.Header.Set("Mcp-Session-Id", sessionID)

	// client.Do returns once the response headers arrive; for an SSE stream the
	// model's generation time is spent later, while reading the body below.
	reqStart := time.Now()
	resp, err := a.client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("send request: %w", err)
	}
	defer resp.Body.Close()
	mcpRequestDur := time.Since(reqStart)

	// Check HTTP status code before reading body
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("HTTP %d: %s", resp.StatusCode, string(body))
	}

	// Read SSE stream line by line, skipping pings and comments
	sseStart := time.Now()
	sseData, err := readSSEData(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("read SSE stream: %w", err)
	}
	sseReadDur := time.Since(sseStart)

	// Parse MCP response
	parseStart := time.Now()
	var mcpResp MCPResponse
	if err := json.Unmarshal([]byte(sseData), &mcpResp); err != nil {
		return nil, fmt.Errorf("parse response: %w", err)
	}
	parseDur := time.Since(parseStart)

	// Check for errors
	if mcpResp.Error != nil {
		return nil, fmt.Errorf("MCP error %d: %s", mcpResp.Error.Code, mcpResp.Error.Message)
	}

	// Extract analysis text
	if len(mcpResp.Result.Content) == 0 {
		return nil, fmt.Errorf("no content in response")
	}

	analysis := mcpResp.Result.Content[0].Text

	return &AnalysisResult{
		JobURL:   jobURL,
		Analysis: analysis,
		Duration: time.Since(startTime),
		Timings: AnalysisTimings{
			Marshal:    marshalDur,
			MCPRequest: mcpRequestDur,
			SSERead:    sseReadDur,
			Parse:      parseDur,
			Total:      time.Since(startTime),
		},
	}, nil
}

var prowURLPattern = regexp.MustCompile(
	`(https://(?:` +
		`prow\.ci\.openshift\.org/(?:view/gs/|\?pr=)|` +
		`deck-internal-ci\.apps\.ci\.l2s4\.p1\.openshiftapps\.com/` +
		// Stops at Slack (`<url|label>`) and Markdown (`[label](url)`) delimiters; `\s` covers whitespace-terminated URLs; and `\.?` covers the normal period-terminated sentence.
		`)[^|\s)>]+)\.?`,
)

// ExtractProwURL extracts a Prow job URL from a message
func ExtractProwURL(text string) string {
	match := prowURLPattern.FindStringSubmatch(text)
	if match == nil {
		return ""
	}
	return strings.TrimRight(match[1], ".")
}

// ContainsProwURL checks if a message contains a Prow URL
func ContainsProwURL(text string) bool {
	return ExtractProwURL(text) != ""
}

// JobOutcome describes the known result of a Prow job.
type JobOutcome int

const (
	// OutcomeUnknown means the result could not be determined (e.g. a PR-dashboard
	// or deck-internal URL that has no derivable build path, a job still running,
	// a missing finished.json, or a network/parse error). Callers should treat
	// this as "analyze anyway" so the failure-analysis path fails safe.
	OutcomeUnknown JobOutcome = iota
	// OutcomePassed means Prow reported the job succeeded.
	OutcomePassed
	// OutcomeFailed means Prow reported the job did not succeed.
	OutcomeFailed
)

// finishedJSONURL converts a Prow job "view" URL (".../view/gs/<bucket>/<path>",
// or the older ".../view/gcs/...") into the GCS URL of that build's
// finished.json. It returns "" when the URL is not a view-of-storage URL (e.g.
// a "?pr=" dashboard link), because no single build result can be derived.
func finishedJSONURL(viewURL string) string {
	for _, marker := range []string{"/view/gs/", "/view/gcs/"} {
		if i := strings.Index(viewURL, marker); i >= 0 {
			path := strings.Trim(viewURL[i+len(marker):], "/")
			if path == "" {
				return ""
			}
			return "https://storage.googleapis.com/" + path + "/finished.json"
		}
	}
	return ""
}

// JobOutcomeFor fetches Prow's finished.json for a job view URL and reports the
// job's outcome. It returns OutcomeUnknown (never an error) whenever the result
// cannot be established, so callers can fail safe by analyzing anyway.
func (a *Analyzer) JobOutcomeFor(ctx context.Context, viewURL string) JobOutcome {
	fj := finishedJSONURL(viewURL)
	if fj == "" {
		return OutcomeUnknown
	}

	req, err := a.newRequest(ctx, http.MethodGet, fj, nil)
	if err != nil {
		return OutcomeUnknown
	}
	resp, err := a.client.Do(req)
	if err != nil {
		return OutcomeUnknown
	}
	defer resp.Body.Close()

	// A missing finished.json (404) typically means the job is still running or
	// the build path is not a leaf build — either way the outcome is unknown.
	if resp.StatusCode != http.StatusOK {
		return OutcomeUnknown
	}

	// Prow's finished.json carries a boolean "passed" and/or a "result" string
	// ("SUCCESS", "FAILURE", "ABORTED", ...). Prefer the explicit boolean.
	var finished struct {
		Passed *bool  `json:"passed"`
		Result string `json:"result"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&finished); err != nil {
		return OutcomeUnknown
	}

	switch {
	case finished.Passed != nil:
		if *finished.Passed {
			return OutcomePassed
		}
		return OutcomeFailed
	case strings.EqualFold(finished.Result, "SUCCESS"):
		return OutcomePassed
	case finished.Result != "":
		return OutcomeFailed
	default:
		return OutcomeUnknown
	}
}

// personaFromURL returns the ship-help persona segment from an MCP URL of the
// form ".../personas/<persona>/mcp", or "unknown" if it cannot be determined.
// Used to tag audit events with the persona actually queried.
func personaFromURL(u string) string {
	const marker = "/personas/"
	i := strings.Index(u, marker)
	if i < 0 {
		return "unknown"
	}
	rest := u[i+len(marker):]
	if j := strings.Index(rest, "/"); j >= 0 {
		return rest[:j]
	}
	if rest == "" {
		return "unknown"
	}
	return rest
}

// FormatSlackResponse formats the analysis for Slack using Block Kit
// Returns a simple text message since we're posting in a thread
func FormatSlackResponse(result *AnalysisResult) string {
	// Guard against nil result to prevent panic
	if result == nil {
		return WithDisclaimer("❌ Error: Unable to format analysis (nil result)")
	}

	// Format as markdown text for thread reply. The AI-generated label brackets
	// the analysis (header + footer) so it stays visible at the point of delivery.
	return WithDisclaimer(fmt.Sprintf("%s · 🔍 *Prow Analyzer Analysis*\n\n%s\n\n_%s • Analysis completed in %.1fs • Powered by ship-help MCP_",
		AILabel,
		result.Analysis,
		AILabel,
		result.Duration.Seconds(),
	))
}

// initializeSession initializes an MCP session and stores the session ID
func (a *Analyzer) initializeSession(ctx context.Context) error {
	// Create initialize request with required MCP protocol params
	reqBody := MCPRequest{
		JSONRPC: "2.0",
		ID:      0,
		Method:  "initialize",
		Params: map[string]interface{}{
			"protocolVersion": "2024-11-05",
			"capabilities":    map[string]interface{}{},
			"clientInfo": map[string]interface{}{
				"name":    "prow-analyzer",
				"version": "1.0",
			},
		},
	}

	// Audit the tool/data-source query (lifecycle event 2/3): MCP session setup.
	audit.ToolQuery(ctx, "ship-help-mcp", "initialize",
		"persona", personaFromURL(a.mcpURL),
	)

	jsonData, err := a.jsonMarshal(reqBody)
	if err != nil {
		return fmt.Errorf("marshal init request: %w", err)
	}

	req, err := a.newRequest(ctx, "POST", a.mcpURL, bytes.NewBuffer(jsonData))
	if err != nil {
		return fmt.Errorf("create init request: %w", err)
	}

	req.Header.Set("Authorization", "Bearer "+a.token)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json, text/event-stream")

	initStart := time.Now()
	resp, err := a.client.Do(req)
	if err != nil {
		return fmt.Errorf("send init request: %w", err)
	}

	body, err := io.ReadAll(resp.Body)
	resp.Body.Close()
	fmt.Printf("PROW-ANALYZER TIMING: MCP session initialize round-trip=%s\n",
		time.Since(initStart).Round(time.Millisecond))
	if err != nil {
		return fmt.Errorf("read response: %w", err)
	}

	// Check HTTP status code first
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("init request failed (HTTP %d): %s", resp.StatusCode, string(body))
	}

	// Extract session ID from response header
	sessionID := resp.Header.Get("Mcp-Session-Id")
	if sessionID == "" {
		return fmt.Errorf("no session ID in response (HTTP %d): %s", resp.StatusCode, string(body))
	}

	a.sessionMtx.Lock()
	a.sessionID = sessionID
	a.sessionMtx.Unlock()
	return nil
}

// readSSEData reads an SSE stream line by line, skipping comment/ping lines,
// and returns the first "data:" payload containing JSON.
func readSSEData(r io.Reader) (string, error) {
	scanner := bufio.NewScanner(r)
	scanner.Buffer(make([]byte, 0, 1024*1024), 10*1024*1024)
	lineCount := 0
	for scanner.Scan() {
		line := scanner.Text()
		lineCount++
		// Skip empty lines
		if line == "" {
			continue
		}
		// Log SSE comments/pings for debugging
		if strings.HasPrefix(line, ":") {
			fmt.Printf("PROW-ANALYZER SSE: ping received (line %d)\n", lineCount)
			continue
		}
		if data, found := strings.CutPrefix(line, "data:"); found {
			data = strings.TrimSpace(data)
			fmt.Printf("PROW-ANALYZER SSE: data line received (line %d, %d bytes, starts=%q)\n", lineCount, len(data), data[:min(len(data), 40)])
			if len(data) > 0 {
				return data, nil
			}
		} else {
			fmt.Printf("PROW-ANALYZER SSE: other line received (line %d): %s\n", lineCount, line)
		}
	}
	if err := scanner.Err(); err != nil {
		return "", fmt.Errorf("reading stream: %w", err)
	}
	return "", fmt.Errorf("no JSON data found in SSE stream (read %d lines)", lineCount)
}
