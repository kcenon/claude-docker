package auth

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

// writeGHShim installs an executable named `gh` on PATH for this test.
func writeGHShim(t *testing.T, body string) {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("PATH shim needs a POSIX shell; the TUI's CI runs on Linux")
	}
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "gh"), []byte(body), 0o755); err != nil {
		t.Fatalf("write shim: %v", err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
}

func withShortGHTimeout(t *testing.T) {
	t.Helper()
	restore := ghTimeout
	ghTimeout = 300 * time.Millisecond
	t.Cleanup(func() { ghTimeout = restore })
}

// TestHostGHTokenTimesOutOnAuthStatus covers gh_token.go:20 (#358, item 2).
//
// startGHAuth sets m.busy before dispatching this, and update.go rejects every
// key while busy is set, so an unbounded hang here leaves the dashboard
// answering only to quit.
func TestHostGHTokenTimesOutOnAuthStatus(t *testing.T) {
	writeGHShim(t, "#!/bin/sh\nsleep 300\n")
	withShortGHTimeout(t)

	done := make(chan error, 1)
	go func() {
		_, err := HostGHToken("")
		done <- err
	}()

	select {
	case err := <-done:
		if err == nil {
			t.Fatal("expected an error from a gh that never exits")
		}
		if !strings.Contains(err.Error(), "timed out") {
			t.Errorf("a deadline should not be reported as an auth failure, got: %v", err)
		}
	case <-time.After(30 * time.Second):
		t.Fatal("HostGHToken never returned")
	}
}

// TestHostGHTokenTimesOutOnTokenFetch covers gh_token.go:32. A non-empty user
// skips the `auth status` probe, so this reaches the second call site with the
// first one never running.
func TestHostGHTokenTimesOutOnTokenFetch(t *testing.T) {
	writeGHShim(t, "#!/bin/sh\nsleep 300\n")
	withShortGHTimeout(t)

	done := make(chan error, 1)
	go func() {
		_, err := HostGHToken("someuser")
		done <- err
	}()

	select {
	case err := <-done:
		if err == nil {
			t.Fatal("expected an error from a gh that never exits")
		}
		if !strings.Contains(err.Error(), "auth token timed out") {
			t.Errorf("error should name the token fetch, got: %v", err)
		}
	case <-time.After(30 * time.Second):
		t.Fatal("HostGHToken never returned")
	}
}

// TestHostGHTokenSucceedsAgainstAPromptGH keeps the two timeout tests from
// passing by way of a gh that can never work.
func TestHostGHTokenSucceedsAgainstAPromptGH(t *testing.T) {
	writeGHShim(t, "#!/bin/sh\ncase \"$1\" in\n  \"auth\")\n    case \"$2\" in\n      \"status\") exit 0 ;;\n      \"token\") echo gho_testtoken ;;\n    esac ;;\nesac\n")

	token, err := HostGHToken("")
	if err != nil {
		t.Fatalf("HostGHToken: %v", err)
	}
	if token != "gho_testtoken" {
		t.Errorf("token = %q, want gho_testtoken", token)
	}
}

// TestHostGHTokenReportsAuthFailureAsAuthFailure pins the other side of the
// distinction: a gh that exits non-zero quickly is not a timeout.
func TestHostGHTokenReportsAuthFailureAsAuthFailure(t *testing.T) {
	writeGHShim(t, "#!/bin/sh\necho 'not logged in' >&2\nexit 1\n")

	_, err := HostGHToken("")
	if err == nil {
		t.Fatal("expected an error")
	}
	if strings.Contains(err.Error(), "timed out") {
		t.Errorf("a fast failure must not be reported as a timeout, got: %v", err)
	}
	if !strings.Contains(err.Error(), "not authenticated") {
		t.Errorf("error should name the auth failure, got: %v", err)
	}
}
