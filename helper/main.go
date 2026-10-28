package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"
)

type window struct {
	name     string
	used     float64
	resetsAt time.Time
}
type serviceUsage struct {
	name, plan string
	windows    []window
	err        error
	retry      time.Duration
}
type outputWindow struct {
	Name     string  `json:"name"`
	Used     float64 `json:"used"`
	ResetsAt int64   `json:"resetsAt"`
}
type snapshot struct {
	Name        string         `json:"name"`
	Plan        string         `json:"plan"`
	Windows     []outputWindow `json:"windows"`
	Error       string         `json:"error"`
	UpdatedAt   int64          `json:"updatedAt"`
	NextAttempt int64          `json:"nextAttempt"`
}

func merge(previous snapshot, usage serviceUsage, now time.Time, interval time.Duration) snapshot {
	previous.Name = usage.name
	previous.NextAttempt = now.Add(interval).Unix()
	if usage.err != nil {
		previous.Error = usage.err.Error()
		if usage.retry > 0 {
			previous.NextAttempt = now.Add(usage.retry).Unix()
		}
		return previous
	}
	previous.Plan = usage.plan
	previous.Error = ""
	previous.UpdatedAt = now.Unix()
	previous.Windows = []outputWindow{}
	for _, w := range usage.windows {
		reset := int64(0)
		if !w.resetsAt.IsZero() {
			reset = w.resetsAt.Unix()
		}
		previous.Windows = append(previous.Windows, outputWindow{w.name, w.used, reset})
	}
	return previous
}

func main() {
	// Finder launches do not inherit an interactive shell's PATH.
	home, _ := os.UserHomeDir()
	paths := []string{os.Getenv("PATH"), "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", filepath.Join(home, ".local/bin"), filepath.Join(home, ".nix-profile/bin"), "/run/current-system/sw/bin"}
	_ = os.Setenv("PATH", strings.Join(paths, string(os.PathListSeparator)))
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	cache := make([]snapshot, 2)
	fetchers := []func(context.Context) serviceUsage{fetchCodex, fetchClaude}
	intervals := []time.Duration{time.Minute, 5 * time.Minute}
	encoder := json.NewEncoder(os.Stdout)
	var outputMu sync.Mutex
	refresh := func() {
		var wg sync.WaitGroup
		for i, fetch := range fetchers {
			wg.Add(1)
			go func(i int, fetch func(context.Context) serviceUsage) {
				defer wg.Done()
				if time.Now().Unix() >= cache[i].NextAttempt {
					requestCtx, done := context.WithTimeout(ctx, 15*time.Second)
					usage := fetch(requestCtx)
					done()
					cache[i] = merge(cache[i], usage, time.Now(), intervals[i])
				}
				outputMu.Lock()
				_ = encoder.Encode(cache[i])
				outputMu.Unlock()
			}(i, fetch)
		}
		wg.Wait()
	}
	if len(os.Args) > 1 && os.Args[1] == "--once" {
		refresh()
		return
	}
	requests := make(chan struct{}, 1)
	go func() {
		scanner := bufio.NewScanner(os.Stdin)
		for scanner.Scan() {
			select {
			case requests <- struct{}{}:
			default:
			}
		}
		cancel()
	}()
	for {
		select {
		case <-ctx.Done():
			return
		case <-requests:
			refresh()
		}
	}
}

func windowName(minutes int, fallbackName string) string {
	if minutes <= 0 {
		return fallbackName
	}
	if minutes%1440 == 0 {
		return fmt.Sprintf("%d-day", minutes/1440)
	}
	if minutes%60 == 0 {
		return fmt.Sprintf("%d-hour", minutes/60)
	}
	return fmt.Sprintf("%d-minute", minutes)
}
func parseTime(value string) time.Time { t, _ := time.Parse(time.RFC3339Nano, value); return t }
func fallback(value, defaultValue string) string {
	if strings.TrimSpace(value) == "" {
		return defaultValue
	}
	return value
}
