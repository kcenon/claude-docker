package auth

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestRateLimitErrorError verifies the formatter embeds the attempt count.
// Run as a sub-test set so the formatting holds across realistic counts.
func TestRateLimitErrorError(t *testing.T) {
	cases := []struct {
		attempts int
		want     string
	}{
		{1, "rate limited after 1 attempts"},
		{3, "rate limited after 3 attempts"},
		{0, "rate limited after 0 attempts"},
	}
	for _, c := range cases {
		err := &RateLimitError{Attempts: c.attempts}
		if got := err.Error(); got != c.want {
			t.Errorf("attempts=%d: Error() = %q, want %q", c.attempts, got, c.want)
		}
	}
}

func TestGHTokenArgsSelectsNamedAccount(t *testing.T) {
	cases := []struct {
		user string
		want []string
	}{
		{"", []string{"auth", "token"}},
		{"fixture-user-b", []string{"auth", "token", "--hostname", "github.com", "--user", "fixture-user-b"}},
	}
	for _, tc := range cases {
		got := ghTokenArgs(tc.user)
		if len(got) != len(tc.want) {
			t.Fatalf("ghTokenArgs(%q) = %v, want %v", tc.user, got, tc.want)
		}
		for i := range tc.want {
			if got[i] != tc.want[i] {
				t.Errorf("ghTokenArgs(%q)[%d] = %q, want %q", tc.user, i, got[i], tc.want[i])
			}
		}
	}
}

// TestReadOAuthTokenSuccess writes a valid .credentials.json into a temp
// dir and verifies ReadOAuthToken returns the embedded access token.
func TestReadOAuthTokenSuccess(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, ".credentials.json")
	content := `{"claudeAiOauth":{"accessToken":"sk-test-token-abc123"}}`
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatalf("write credentials: %v", err)
	}

	tok, err := ReadOAuthToken(path)
	if err != nil {
		t.Fatalf("ReadOAuthToken: %v", err)
	}
	if tok != "sk-test-token-abc123" {
		t.Errorf("token = %q, want %q", tok, "sk-test-token-abc123")
	}
}

// TestReadOAuthTokenMissingFile verifies a clear error is returned when the
// credentials file does not exist.
func TestReadOAuthTokenMissingFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "does-not-exist.json")
	tok, err := ReadOAuthToken(path)
	if err == nil {
		t.Fatalf("ReadOAuthToken(missing): err = nil, want non-nil")
	}
	if tok != "" {
		t.Errorf("token = %q, want empty on error", tok)
	}
	// Error must mention the read failure to help diagnostics.
	if !strings.Contains(err.Error(), "read credentials") {
		t.Errorf("error %q should mention %q", err.Error(), "read credentials")
	}
}

// TestReadOAuthTokenEmptyToken verifies a syntactically valid credentials
// file with an empty accessToken is rejected with a clear error.
//
// Note on coverage: FetchUsage's URL (usage_api.go:13) is a package-level
// const rather than a configurable variable, so an httptest.NewServer
// cannot be substituted at test time without modifying source code (out
// of scope for this purely-additive PR). Once a stable seam is added,
// FetchUsage rate-limit handling should grow a dedicated test.
func TestReadOAuthTokenEmptyToken(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, ".credentials.json")
	content := `{"claudeAiOauth":{"accessToken":""}}`
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatalf("write credentials: %v", err)
	}

	tok, err := ReadOAuthToken(path)
	if err == nil {
		t.Fatalf("ReadOAuthToken(empty token): err = nil, want non-nil")
	}
	if tok != "" {
		t.Errorf("token = %q, want empty", tok)
	}
	if !strings.Contains(err.Error(), "no access token") {
		t.Errorf("error %q should mention %q", err.Error(), "no access token")
	}
}
