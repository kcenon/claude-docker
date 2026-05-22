// Package auth provides OAuth token reading and Anthropic usage API access.
package auth

// This file is Claude-only. The usage API it wraps
// (api.anthropic.com/api/oauth/usage) is specific to Anthropic's OAuth
// flow; Codex, Gemini, and other runtimes have no equivalent endpoint.
// Callers gate it via Env.SupportsClaudeUsage so non-Claude runtimes
// degrade gracefully (the dashboard renders "--" for usage). See #271.

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"time"
)

const usageAPIURL = "https://api.anthropic.com/api/oauth/usage"

// RateLimitError is returned when the API responds with 429.
type RateLimitError struct {
	Attempts int
}

func (e *RateLimitError) Error() string {
	return fmt.Sprintf("rate limited after %d attempts", e.Attempts)
}

// OAuthCredentials holds the parsed .credentials.json structure.
type OAuthCredentials struct {
	AccessToken string `json:"accessToken"`
}

// CredentialsFile is the top-level .credentials.json structure.
type CredentialsFile struct {
	ClaudeAiOauth OAuthCredentials `json:"claudeAiOauth"`
}

// UsageAPIResponse holds the raw response from the usage API.
type UsageAPIResponse struct {
	FiveHour       *UsageBucket `json:"five_hour"`
	SevenDay       *UsageBucket `json:"seven_day"`
	SevenDayOpus   *UsageBucket `json:"seven_day_opus"`
	SevenDaySonnet *UsageBucket `json:"seven_day_sonnet"`
}

// UsageBucket is a single rate limit bucket from the API.
// Utilization is float64 because the API returns 0.0 for zero usage.
type UsageBucket struct {
	Utilization float64 `json:"utilization"`
	ResetsAt    string  `json:"resets_at"`
}

// ReadOAuthToken reads the OAuth access token from a .credentials.json file.
func ReadOAuthToken(credentialsPath string) (string, error) {
	data, err := os.ReadFile(credentialsPath)
	if err != nil {
		return "", fmt.Errorf("read credentials: %w", err)
	}

	var creds CredentialsFile
	if err := json.Unmarshal(data, &creds); err != nil {
		return "", fmt.Errorf("parse credentials: %w", err)
	}

	if creds.ClaudeAiOauth.AccessToken == "" {
		return "", fmt.Errorf("no access token in credentials")
	}

	return creds.ClaudeAiOauth.AccessToken, nil
}

// FetchUsage calls the Anthropic OAuth usage API once.
// On 429, returns *RateLimitError immediately so the caller can back off.
// The caller (TUI auto-retry loop) handles retry cadence externally.
func FetchUsage(accessToken string) (*UsageAPIResponse, error) {
	client := &http.Client{Timeout: 10 * time.Second}

	req, err := http.NewRequest("GET", usageAPIURL, nil)
	if err != nil {
		return nil, err
	}

	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("User-Agent", "claude-docker-tui/0.1.0")
	req.Header.Set("Authorization", "Bearer "+accessToken)
	req.Header.Set("anthropic-beta", "oauth-2025-04-20")

	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("usage API request: %w", err)
	}
	defer resp.Body.Close()

	body, _ := io.ReadAll(resp.Body)

	if resp.StatusCode == 429 {
		return nil, &RateLimitError{Attempts: 1}
	}

	if resp.StatusCode != 200 {
		return nil, fmt.Errorf("usage API returned %d: %s", resp.StatusCode, string(body))
	}

	var result UsageAPIResponse
	if err := json.Unmarshal(body, &result); err != nil {
		return nil, fmt.Errorf("parse usage response: %w", err)
	}

	return &result, nil
}
