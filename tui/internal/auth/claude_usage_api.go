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
	"strings"
	"time"
	"unicode"
	"unicode/utf8"
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
	return fetchUsageFrom(usageAPIURL, accessToken)
}

// fetchUsageFrom is FetchUsage with the endpoint as a parameter, so tests can
// point it at an httptest server. Splitting the URL out this way keeps
// usageAPIURL a const; the alternative -- making it a mutable package var --
// would let any future code in this package repoint the production endpoint.
func fetchUsageFrom(endpoint, accessToken string) (*UsageAPIResponse, error) {
	client := &http.Client{Timeout: 10 * time.Second}

	req, err := http.NewRequest("GET", endpoint, nil)
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

	// 429 is decided by the status alone, so the body is never read for it.
	if resp.StatusCode == 429 {
		return nil, &RateLimitError{Attempts: 1}
	}

	// Bounded read. A valid usage response is well under a kilobyte; anything
	// larger is a proxy's HTML error page or a captive portal, and the whole of
	// it used to become the error string, which reaches a.LastAPIStatus and is
	// drawn per account in the table (#358, item 3).
	body, readErr := io.ReadAll(io.LimitReader(resp.Body, maxUsageBodyBytes))
	if readErr != nil {
		// Previously discarded, so a truncated body went on to json.Unmarshal
		// and resurfaced as "parse usage response" -- a decoding complaint
		// about what was actually a connection that dropped mid-read.
		return nil, fmt.Errorf("read usage response: %w", readErr)
	}

	if resp.StatusCode != 200 {
		return nil, fmt.Errorf("usage API returned %d: %s",
			resp.StatusCode, summarizeBody(body))
	}

	var result UsageAPIResponse
	if err := json.Unmarshal(body, &result); err != nil {
		return nil, fmt.Errorf("parse usage response: %w", err)
	}

	return &result, nil
}

// maxUsageBodyBytes caps what FetchUsage will read from the response.
const maxUsageBodyBytes = 64 * 1024

// maxErrorBodyRunes caps how much of a non-200 body reaches the error string.
const maxErrorBodyRunes = 200

// summarizeBody reduces a response body to something that fits one table cell:
// newlines, tabs and other control characters collapse to spaces, runs of
// whitespace collapse to one, and the result is truncated with an ellipsis.
//
// The destination is a.LastAPIStatus, which view.go renders per account. A raw
// HTML error page there does not just look bad -- its newlines break the table
// apart, and --json output carrying literal control characters is not valid
// JSON for anything downstream to parse.
func summarizeBody(body []byte) string {
	if len(body) == 0 {
		return "(empty body)"
	}

	var b strings.Builder
	b.Grow(len(body))
	lastWasSpace := false
	for _, r := range string(body) {
		if r == utf8.RuneError {
			r = '?'
		}
		if unicode.IsSpace(r) || unicode.IsControl(r) {
			if !lastWasSpace {
				b.WriteByte(' ')
				lastWasSpace = true
			}
			continue
		}
		b.WriteRune(r)
		lastWasSpace = false
	}

	out := strings.TrimSpace(b.String())
	if out == "" {
		return "(no printable content)"
	}
	runes := []rune(out)
	if len(runes) > maxErrorBodyRunes {
		return string(runes[:maxErrorBodyRunes]) + "..."
	}
	return out
}
