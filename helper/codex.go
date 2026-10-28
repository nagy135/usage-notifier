package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os/exec"
	"time"
)

type rpcMessage struct {
	ID     int             `json:"id"`
	Result json.RawMessage `json:"result"`
	Error  *struct {
		Code    int    `json:"code"`
		Message string `json:"message"`
	} `json:"error"`
}

type codexResponse struct {
	RateLimits struct {
		PlanType string `json:"planType"`
		Primary  *struct {
			UsedPercent        float64 `json:"usedPercent"`
			WindowDurationMins int     `json:"windowDurationMins"`
			ResetsAt           int64   `json:"resetsAt"`
		} `json:"primary"`
		Secondary *struct {
			UsedPercent        float64 `json:"usedPercent"`
			WindowDurationMins int     `json:"windowDurationMins"`
			ResetsAt           int64   `json:"resetsAt"`
		} `json:"secondary"`
	} `json:"rateLimits"`
}

func fetchCodex(ctx context.Context) serviceUsage {
	usage := serviceUsage{name: "Codex", plan: "CLI"}
	if _, err := exec.LookPath("codex"); err != nil {
		usage.err = errors.New("codex CLI was not found in PATH")
		return usage
	}

	cmd := exec.CommandContext(ctx, "codex", "app-server", "--stdio")
	stdin, err := cmd.StdinPipe()
	if err != nil {
		usage.err = fmt.Errorf("start Codex app server: %w", err)
		return usage
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		usage.err = fmt.Errorf("read Codex app server: %w", err)
		return usage
	}
	cmd.Stderr = io.Discard
	if err := cmd.Start(); err != nil {
		usage.err = fmt.Errorf("start Codex app server: %w", err)
		return usage
	}
	defer func() {
		_ = stdin.Close()
		if cmd.Process != nil {
			_ = cmd.Process.Kill()
		}
		_ = cmd.Wait()
	}()

	encoder := json.NewEncoder(stdin)
	if err := encoder.Encode(map[string]any{
		"id": 1, "method": "initialize",
		"params": map[string]any{"clientInfo": map[string]string{"name": "usage-notifier", "version": "0.1.0"}},
	}); err != nil {
		usage.err = fmt.Errorf("initialize Codex app server: %w", err)
		return usage
	}

	scanner := bufio.NewScanner(stdout)
	scanner.Buffer(make([]byte, 4096), 4*1024*1024)
	initialized := false
	for scanner.Scan() {
		var message rpcMessage
		if json.Unmarshal(scanner.Bytes(), &message) != nil || message.ID != 1 {
			continue
		}
		if message.Error != nil {
			usage.err = fmt.Errorf("Codex initialization failed: %s", message.Error.Message)
			return usage
		}
		initialized = true
		break
	}
	if err := scanner.Err(); err != nil {
		usage.err = fmt.Errorf("read Codex initialization: %w", err)
		return usage
	}
	if ctx.Err() != nil {
		usage.err = errors.New("Codex usage request timed out")
		return usage
	}

	if !initialized {
		usage.err = errors.New("Codex stopped before initialization; check codex login status")
		return usage
	}
	_ = encoder.Encode(map[string]any{"method": "initialized"})
	if err := encoder.Encode(map[string]any{"id": 2, "method": "account/rateLimits/read", "params": map[string]any{}}); err != nil {
		usage.err = fmt.Errorf("request Codex limits: %w", err)
		return usage
	}

	for scanner.Scan() {
		var message rpcMessage
		if json.Unmarshal(scanner.Bytes(), &message) != nil || message.ID != 2 {
			continue
		}
		if message.Error != nil {
			usage.err = fmt.Errorf("Codex usage request failed: %s", message.Error.Message)
			return usage
		}
		var response codexResponse
		if err := json.Unmarshal(message.Result, &response); err != nil {
			usage.err = fmt.Errorf("decode Codex usage: %w", err)
			return usage
		}
		usage.plan = fallback(response.RateLimits.PlanType, "subscription")
		if response.RateLimits.Primary != nil {
			p := response.RateLimits.Primary
			usage.windows = append(usage.windows, window{
				name: windowName(p.WindowDurationMins, "Session"), used: p.UsedPercent,
				resetsAt: time.Unix(p.ResetsAt, 0),
			})
		}
		if response.RateLimits.Secondary != nil {
			s := response.RateLimits.Secondary
			usage.windows = append(usage.windows, window{
				name: windowName(s.WindowDurationMins, "Weekly"), used: s.UsedPercent,
				resetsAt: time.Unix(s.ResetsAt, 0),
			})
		}
		if len(usage.windows) == 0 {
			usage.err = errors.New("Codex returned no active rate limits")
		}
		return usage
	}

	if ctx.Err() != nil {
		usage.err = errors.New("Codex usage request timed out")
	} else {
		usage.err = errors.New("Codex stopped before returning limits; check codex login status")
	}
	return usage
}
