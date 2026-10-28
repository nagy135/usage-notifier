package main

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestClaudeResponseFormats(t *testing.T) {
	for _, test := range []struct {
		name, body string
		names      []string
		used       []float64
	}{
		{"scoped", `{"limits":[{"kind":"session","percent":36,"resets_at":"2026-07-14T17:30:00.123Z"},{"kind":"weekly_all","percent":23},{"kind":"weekly_scoped","percent":42,"scope":{"model":{"display_name":"Fable"}}}]}`, []string{"5-hour", "7-day · All models", "7-day · Fable"}, []float64{36, 23, 42}},
		{"legacy", `{"five_hour":{"utilization":36,"resets_at":null},"seven_day":{"utilization":23}}`, []string{"5-hour", "7-day · All models"}, []float64{36, 23}},
		{"empty", `{"five_hour":null,"seven_day":null}`, nil, nil},
	} {
		t.Run(test.name, func(t *testing.T) {
			var response claudeResponse
			if err := json.Unmarshal([]byte(test.body), &response); err != nil {
				t.Fatal(err)
			}
			windows := claudeWindows(response)
			if len(windows) != len(test.names) {
				t.Fatalf("got %d windows", len(windows))
			}
			for i, w := range windows {
				if w.name != test.names[i] || w.used != test.used[i] {
					t.Fatalf("unexpected window: %+v", w)
				}
			}
		})
	}
}

func TestCachePreservesLastSuccessAndRecovers(t *testing.T) {
	now := time.Unix(1700000000, 0)
	good := serviceUsage{name: "Claude", plan: "team", windows: []window{{name: "5-hour", used: 32}}}
	first := merge(snapshot{}, good, now, 5*time.Minute)
	failed := merge(first, serviceUsage{name: "Claude", err: errors.New("rate limited"), retry: 15 * time.Minute}, now.Add(time.Minute), 5*time.Minute)
	if failed.UpdatedAt != first.UpdatedAt || failed.Windows[0].Used != 32 || failed.Error == "" || failed.NextAttempt != now.Add(16*time.Minute).Unix() {
		t.Fatalf("lost cache/backoff: %+v", failed)
	}
	if first.Windows[0].ResetsAt != 0 {
		t.Fatal("unknown reset must stay unknown")
	}
	good.windows[0].used = 45
	recovered := merge(failed, good, now.Add(16*time.Minute), 5*time.Minute)
	if recovered.Error != "" || recovered.Windows[0].Used != 45 || recovered.UpdatedAt == first.UpdatedAt {
		t.Fatalf("did not recover: %+v", recovered)
	}
}

func TestRetryAfter(t *testing.T) {
	if retryAfter("120") != 2*time.Minute || retryAfter("invalid") != 15*time.Minute || retryAfter("-1") != 15*time.Minute {
		t.Fatal("bad retry interval")
	}
	duration := retryAfter(time.Now().Add(5 * time.Minute).UTC().Format(http.TimeFormat))
	if duration < 299*time.Second || duration > 300*time.Second {
		t.Fatalf("HTTP date: %v", duration)
	}
}

func fakeCodex(t *testing.T, script string) {
	t.Helper()
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "codex"), []byte("#!/bin/sh\n"+script), 0700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir)
}

func TestCodexHandshakeAndOptionalWindow(t *testing.T) {
	fakeCodex(t, `read -r init
case "$init" in *initialize*) ;; *) exit 1 ;; esac
printf '%s\n' '{"method":"noise"}' '{"id":1,"result":{}}'
read -r ready
read -r request
case "$ready$request" in *initialized*account/rateLimits/read*) ;; *) exit 1 ;; esac
printf '%s\n' '{"id":2,"result":{"rateLimits":{"planType":"pro","primary":null,"secondary":{"usedPercent":3,"windowDurationMins":10080,"resetsAt":1790850219}}}}'
`)
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	usage := fetchCodex(ctx)
	if usage.err != nil || usage.plan != "pro" || len(usage.windows) != 1 || usage.windows[0].name != "7-day" || usage.windows[0].used != 3 {
		t.Fatalf("unexpected result: %+v", usage)
	}
}

func TestCodexEarlyExitAndTimeout(t *testing.T) {
	t.Run("early exit", func(t *testing.T) {
		fakeCodex(t, "exit 0\n")
		usage := fetchCodex(context.Background())
		if usage.err == nil || !strings.Contains(usage.err.Error(), "initialization") {
			t.Fatalf("expected initialization error: %+v", usage)
		}
	})
	t.Run("timeout", func(t *testing.T) {
		fakeCodex(t, "read -r init\nread -r more\n")
		ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
		defer cancel()
		usage := fetchCodex(ctx)
		if usage.err == nil || !strings.Contains(usage.err.Error(), "timed out") {
			t.Fatalf("expected timeout: %+v", usage)
		}
	})
}
