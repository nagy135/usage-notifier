package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"
)

const (
	claudeMinRefresh     = 5 * time.Minute
	claudeDefaultBackoff = 15 * time.Minute
)

type claudeCredentials struct {
	ClaudeAIOAuth struct {
		AccessToken      string `json:"accessToken"`
		SubscriptionType string `json:"subscriptionType"`
	} `json:"claudeAiOauth"`
}

type claudeResponse struct {
	FiveHour *struct {
		Utilization float64 `json:"utilization"`
		ResetsAt    string  `json:"resets_at"`
	} `json:"five_hour"`
	SevenDay *struct {
		Utilization float64 `json:"utilization"`
		ResetsAt    string  `json:"resets_at"`
	} `json:"seven_day"`
	Limits []struct {
		Kind     string  `json:"kind"`
		Percent  float64 `json:"percent"`
		ResetsAt string  `json:"resets_at"`
		Scope    *struct {
			Model *struct {
				DisplayName string `json:"display_name"`
			} `json:"model"`
		} `json:"scope"`
	} `json:"limits"`
}

func fetchClaude(ctx context.Context) serviceUsage {

	usage := serviceUsage{name: "Claude", plan: "subscription"}
	credentials, err := readClaudeCredentials(ctx)
	if err != nil {
		usage.err = err
		usage.retry = time.Minute
		return usage
	}
	usage.plan = fallback(credentials.ClaudeAIOAuth.SubscriptionType, "subscription")

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, "https://api.anthropic.com/api/oauth/usage", nil)
	if err != nil {
		usage.err = fmt.Errorf("create Claude usage request: %w", err)
		return usage
	}
	req.Header.Set("Authorization", "Bearer "+credentials.ClaudeAIOAuth.AccessToken)
	req.Header.Set("anthropic-beta", "oauth-2025-04-20")
	req.Header.Set("User-Agent", "usage-notifier/1.0")

	response, err := http.DefaultClient.Do(req)
	if err != nil {
		usage.err = errors.New("Could not reach Claude; check your connection")
		usage.retry = time.Minute
		return usage
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		message := fmt.Sprintf("Claude returned HTTP %d", response.StatusCode)
		usage.retry = time.Minute
		if response.StatusCode == http.StatusUnauthorized || response.StatusCode == http.StatusForbidden {
			message = "Claude login needs attention; run claude auth login"
		}
		if response.StatusCode == http.StatusTooManyRequests {
			message = "Claude is rate limiting requests; waiting to retry"
			usage.retry = retryAfter(response.Header.Get("Retry-After"))
		}
		usage.err = errors.New(message)
		return usage
	}

	var payload claudeResponse
	if err := json.NewDecoder(response.Body).Decode(&payload); err != nil {
		usage.err = fmt.Errorf("decode Claude usage: %w", err)
		return usage
	}
	usage.windows = claudeWindows(payload)
	if len(usage.windows) == 0 {
		usage.err = errors.New("Claude returned no active rate limits")
		return usage
	}
	return usage
}

func claudeWindows(payload claudeResponse) []window {
	windows := make([]window, 0, len(payload.Limits))
	for _, limit := range payload.Limits {
		name := ""
		switch limit.Kind {
		case "session":
			name = "5-hour"
		case "weekly_all":
			name = "7-day · All models"
		case "weekly_scoped":
			if limit.Scope != nil && limit.Scope.Model != nil && limit.Scope.Model.DisplayName != "" {
				name = "7-day · " + limit.Scope.Model.DisplayName
			}
		}
		if name != "" {
			windows = append(windows, window{name: name, used: limit.Percent, resetsAt: parseTime(limit.ResetsAt)})
		}
	}
	if len(windows) > 0 {
		return windows
	}
	if payload.FiveHour != nil {
		windows = append(windows, window{name: "5-hour", used: payload.FiveHour.Utilization, resetsAt: parseTime(payload.FiveHour.ResetsAt)})
	}
	if payload.SevenDay != nil {
		windows = append(windows, window{name: "7-day · All models", used: payload.SevenDay.Utilization, resetsAt: parseTime(payload.SevenDay.ResetsAt)})
	}
	return windows
}

func retryAfter(value string) time.Duration {
	if seconds, err := strconv.Atoi(strings.TrimSpace(value)); err == nil && seconds > 0 {
		return time.Duration(seconds) * time.Second
	}
	if at, err := http.ParseTime(value); err == nil {
		if wait := time.Until(at); wait > 0 {
			return wait
		}
	}
	return claudeDefaultBackoff
}

func readClaudeCredentials(ctx context.Context) (claudeCredentials, error) {
	var credentials claudeCredentials
	var data []byte
	var err error

	if runtime.GOOS == "darwin" {
		data, err = exec.CommandContext(ctx, "security", "find-generic-password", "-s", "Claude Code-credentials", "-w").Output()
		if err == nil {
			if decodeErr := json.Unmarshal(data, &credentials); decodeErr == nil && credentials.ClaudeAIOAuth.AccessToken != "" {
				return credentials, nil
			}
		}
	}

	configDir := os.Getenv("CLAUDE_CONFIG_DIR")
	if configDir == "" {
		home, homeErr := os.UserHomeDir()
		if homeErr != nil {
			return credentials, fmt.Errorf("locate Claude credentials: %w", homeErr)
		}
		configDir = filepath.Join(home, ".claude")
	}
	data, err = os.ReadFile(filepath.Join(configDir, ".credentials.json"))
	if err != nil {
		return credentials, errors.New("Claude credentials not found; run `claude auth login`")
	}
	if err := json.Unmarshal(data, &credentials); err != nil {
		return credentials, fmt.Errorf("decode Claude credentials: %w", err)
	}
	if credentials.ClaudeAIOAuth.AccessToken == "" {
		return credentials, errors.New("Claude OAuth token not found; run `claude auth login`")
	}
	return credentials, nil
}
