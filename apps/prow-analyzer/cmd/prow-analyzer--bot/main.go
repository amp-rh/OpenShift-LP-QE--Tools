package main

import (
	"flag"
	"fmt"
	"log"
	"log/slog"
	"os"
	"strconv"
	"strings"

	"github.com/slack-go/slack"
	"github.com/slack-go/slack/slackevents"
	"github.com/slack-go/slack/socketmode"

	"github.com/RedHatQE/OpenShift-LP-QE--Tools/apps/prow-analyzer/pkg/analyzer"
	"github.com/RedHatQE/OpenShift-LP-QE--Tools/apps/prow-analyzer/pkg/slack/handler"
)

// envBool reads a boolean environment variable, returning def when the variable
// is unset, empty, or not a valid boolean (as understood by strconv.ParseBool).
func envBool(key string, def bool) bool {
	if v := os.Getenv(key); v != "" {
		if b, err := strconv.ParseBool(v); err == nil {
			return b
		}
	}
	return def
}

func main() {
	var (
		slackToken  = flag.String("slack-token", os.Getenv("SLACK_BOT_TOKEN"), "Slack bot token")
		appToken    = flag.String("app-token", os.Getenv("SLACK_APP_TOKEN"), "Slack app token (for socket mode)")
		mcpURL      = flag.String("mcp-url", os.Getenv("SHIP_HELP_MCP_URL"), "Ship-help MCP URL")
		mcpToken    = flag.String("mcp-token", os.Getenv("SHIP_HELP_MCP_TOKEN"), "Ship-help MCP token")
		channels    = flag.String("channels", os.Getenv("MONITORED_CHANNELS"), "Comma-separated list of channel IDs to monitor")
		allowedBots = flag.String("allowed-bots", os.Getenv("ALLOWED_BOT_IDS"), "Comma-separated list of bot IDs (B...) whose Prow URLs should be analyzed")
		prompt      = flag.String("prompt", "Analyze this Prow CI failure in detail. Provide: (1) Root cause, (2) Related Jira issues, (3) Recurring pattern analysis, (4) Recommended actions. URL: {job_url}", "Analysis prompt template")
		slackDebug  = flag.Bool("slack-debug", envBool("SLACK_DEBUG", false), "Enable verbose Slack SDK and Socket Mode debug logging (or set SLACK_DEBUG)")
		tlsInsecure = flag.Bool("tls-insecure", envBool("TLS_INSECURE_SKIP_VERIFY", false), "Skip TLS certificate verification for MCP/Prow HTTP requests (or set TLS_INSECURE_SKIP_VERIFY)")
	)

	flag.Parse()

	// Validate required flags
	if *slackToken == "" {
		slog.Error("--slack-token is required (or set SLACK_BOT_TOKEN)")
		os.Exit(1)
	}
	if *appToken == "" {
		slog.Error("--app-token is required (or set SLACK_APP_TOKEN)")
		os.Exit(1)
	}
	if *mcpURL == "" || *mcpToken == "" {
		slog.Error("Both --mcp-url and --mcp-token are required (or set SHIP_HELP_MCP_URL and SHIP_HELP_MCP_TOKEN)")
		os.Exit(1)
	}

	// Parse monitored channels. This is optional: when empty, the bot monitors
	// every channel it is a member of, so inviting it to a channel is enough.
	var monitoredChannels []string
	if *channels != "" {
		for _, ch := range strings.Split(*channels, ",") {
			if ch = strings.TrimSpace(ch); ch != "" {
				monitoredChannels = append(monitoredChannels, ch)
			}
		}
	}

	// Parse allow-listed bot IDs. When set, Prow URLs posted by these bots (e.g.
	// chai-bot) are analyzed too; the bot always ignores its own messages.
	var allowedBotIDs []string
	if *allowedBots != "" {
		for _, id := range strings.Split(*allowedBots, ",") {
			if id = strings.TrimSpace(id); id != "" {
				allowedBotIDs = append(allowedBotIDs, id)
			}
		}
	}

	slog.Info("Starting prow-analyzer-bot")
	if len(monitoredChannels) == 0 {
		slog.Info("No channels configured; monitoring all channels the bot is a member of")
	} else {
		slog.Info("Monitoring channels", "channels", monitoredChannels)
	}
	if len(allowedBotIDs) > 0 {
		slog.Info("Analyzing Prow URLs from allow-listed bots", "botIDs", allowedBotIDs)
	}

	// Create Slack client with debug logging
	slackClient := slack.New(
		*slackToken,
		slack.OptionAppLevelToken(*appToken),
		slack.OptionDebug(*slackDebug),
		slack.OptionLog(log.New(os.Stdout, "slack: ", log.Lshortfile|log.LstdFlags)),
	)

	// Determine this bot's own bot ID so its own messages are never analyzed
	// (loop prevention), even when bot allow-listing is enabled.
	handlerOpts := []handler.Option{handler.WithAllowedBotIDs(allowedBotIDs)}
	if authResp, err := slackClient.AuthTest(); err != nil {
		slog.Warn("AuthTest failed; self bot ID unknown (own messages still ignored via allow-list)", "error", err)
	} else {
		handlerOpts = append(handlerOpts, handler.WithSelfBotID(authResp.BotID))
	}

	// Create analyzer
	a := analyzer.NewAnalyzer(*mcpURL, *mcpToken, *prompt, analyzer.WithInsecureSkipVerify(*tlsInsecure))

	// Create handler
	h := handler.New(slackClient, a, monitoredChannels, handlerOpts...)

	// Create socket mode client with debug logging
	socketClient := socketmode.New(
		slackClient,
		socketmode.OptionDebug(*slackDebug),
		socketmode.OptionLog(log.New(os.Stdout, "socketmode: ", log.Lshortfile|log.LstdFlags)),
	)

	// Handle events
	go func() {
		for evt := range socketClient.Events {
			slog.Info("Received socket mode event", "type", evt.Type)
			switch evt.Type {
			case socketmode.EventTypeConnecting:
				slog.Info("Connecting to Slack...")
			case socketmode.EventTypeConnected:
				slog.Info("Connected to Slack")
			case socketmode.EventTypeConnectionError:
				slog.Error("Connection error", "data", evt.Data)
			case socketmode.EventTypeEventsAPI:
				eventsAPIEvent, ok := evt.Data.(slackevents.EventsAPIEvent)
				if !ok {
					slog.Warn("Ignored event", "event", evt)
					continue
				}

				socketClient.Ack(*evt.Request)

				logger := slog.With("type", eventsAPIEvent.Type)
				handled, err := h.Handle(&eventsAPIEvent, logger)
				if err != nil {
					logger.Error("Failed to handle event", "error", err)
				} else if handled {
					logger.Info("Event handled")
				}
			default:
				slog.Info("Unhandled event type", "type", evt.Type)
			}
		}
	}()

	fmt.Println("Prow analyzer bot is running...")
	if err := socketClient.Run(); err != nil {
		slog.Error("Socket mode error", "error", err)
		os.Exit(1)
	}
}
