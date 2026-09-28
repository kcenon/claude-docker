package account

import (
	"context"
	"os"
	"path/filepath"
	"runtime"
	"testing"
	"time"

	"github.com/kcenon/claude-docker/tui/internal/config"
	"github.com/kcenon/claude-docker/tui/internal/docker"
)

// dockerShim installs an executable named `docker` on PATH that answers
// `compose ... ps` with one running container and hangs forever on `exec`.
//
// That split is the point. A shim that hangs on everything never reaches
// enrichGHAuth, because with no container reported running there is nothing to
// check the login of -- so it would exercise the PS deadline a second time
// instead of the `docker exec` one.
func dockerShim(t *testing.T) {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("PATH shim needs a POSIX shell; the TUI's CI runs on Linux")
	}
	body := "#!/bin/sh\n" +
		"for a in \"$@\"; do\n" +
		"  if [ \"$a\" = \"exec\" ]; then sleep 300; fi\n" +
		"done\n" +
		`echo '{"ID":"abc123","Service":"claude-a","State":"running","Status":"Up"}'` + "\n"

	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "docker"), []byte(body), 0o755); err != nil {
		t.Fatalf("write shim: %v", err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
}

// TestListAccountsReturnsWhenGHAuthHangs is the acceptance criterion for
// #358 item 1: a child that never exits must not take ListAccounts with it.
//
// Before the fix, the goroutine at manager_helpers.go:157 never returned,
// enrichAccounts' wg.Wait() blocked forever, and ListAccounts never returned.
// The dashboard consequence is that m.loading or m.refreshing stays true and
// `r` is rejected by its own guard, so the operator has no way back. This test
// would not have failed against that code -- it would have hung until the
// package timeout, which is the same symptom.
func TestListAccountsReturnsWhenGHAuthHangs(t *testing.T) {
	dockerShim(t)

	restore := ghAuthTimeout
	ghAuthTimeout = 500 * time.Millisecond
	defer func() { ghAuthTimeout = restore }()

	env := config.NewEmptyEnv(filepath.Join(t.TempDir(), ".env"))
	env.Set("NUM_ACCOUNTS", "1")
	// Point state discovery at an empty HOME so the developer's real
	// ~/.claude-state cannot make this test depend on their machine.
	t.Setenv("HOME", t.TempDir())

	mgr := NewManager(env, docker.NewClient(t.TempDir(), env))

	type result struct {
		accounts []Account
		err      error
	}
	done := make(chan result, 1)
	start := time.Now()
	go func() {
		a, err := mgr.ListAccounts()
		done <- result{a, err}
	}()

	select {
	case r := <-done:
		elapsed := time.Since(start)
		if elapsed > 20*time.Second {
			t.Errorf("ListAccounts took %s; the deadline did not bound it", elapsed)
		}
		if r.err != nil {
			t.Fatalf("ListAccounts: %v", r.err)
		}
		if len(r.accounts) != 1 {
			t.Fatalf("expected 1 account, got %d", len(r.accounts))
		}
		// The container is reported running, so the check ran and timed out.
		// A timeout degrades the same way a failure does.
		a := r.accounts[0]
		if a.ContainerStatus != ContainerRunning {
			t.Fatalf("shim should have reported the container running, got %v", a.ContainerStatus)
		}
		if a.GHAuthOK {
			t.Error("a timed-out gh check must not report the login as verified")
		}
		if a.GHLogin != "" {
			t.Errorf("a timed-out gh check must not invent a login, got %q", a.GHLogin)
		}
	case <-time.After(60 * time.Second):
		t.Fatal("ListAccounts never returned; the whole dashboard would be stuck here")
	}
}

// TestGHAuthResultTreatsTimeoutLikeAnyFailure states the degradation contract
// directly, without a subprocess: ghAuthResult is what turns the error into
// display state, and it must not distinguish a deadline from a refusal.
func TestGHAuthResultTreatsTimeoutLikeAnyFailure(t *testing.T) {
	login, ok, mismatch := ghAuthResult(nil, context.DeadlineExceeded, "someone")
	if login != "" || ok || mismatch {
		t.Errorf("got (%q, %v, %v), want (\"\", false, false)", login, ok, mismatch)
	}
}
