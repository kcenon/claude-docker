package docker

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/kcenon/claude-docker/tui/internal/config"
)

// writeShim puts an executable script named `name` in a fresh directory and
// prepends that directory to PATH for the duration of the test.
//
// A shim is used rather than a mock because the defect is in how the process
// is launched, not in what is done with its output: only a real child that
// really does not exit can show that the deadline reaches it.
func writeShim(t *testing.T, name, body string) {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("PATH shim needs a POSIX shell; the TUI's CI runs on Linux")
	}
	dir := t.TempDir()
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, []byte(body), 0o755); err != nil {
		t.Fatalf("write shim: %v", err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
}

// TestPSTimesOutOnAHangingDocker pins issue #358 item 1 for the PS call site.
//
// Before the fix this test would not fail -- it would hang until `go test`
// killed the whole package after its 10-minute default timeout, which is the
// dashboard's symptom in miniature.
func TestPSTimesOutOnAHangingDocker(t *testing.T) {
	writeShim(t, "docker", "#!/bin/sh\nsleep 300\n")

	restore := psTimeout
	psTimeout = 300 * time.Millisecond
	defer func() { psTimeout = restore }()

	env := config.NewEmptyEnv(filepath.Join(t.TempDir(), ".env"))
	client := NewClient(t.TempDir(), env)

	done := make(chan error, 1)
	start := time.Now()
	go func() {
		_, err := client.PS()
		done <- err
	}()

	select {
	case err := <-done:
		elapsed := time.Since(start)
		if err == nil {
			t.Fatal("PS returned nil error against a docker that never exits")
		}
		if !strings.Contains(err.Error(), "timed out") {
			t.Errorf("error should name the deadline, got: %v", err)
		}
		// Generous: the assertion is "bounded", not "bounded precisely". The
		// bound that matters is that it is not 300 seconds.
		if elapsed > 10*time.Second {
			t.Errorf("PS took %s, expected roughly %s", elapsed, psTimeout)
		}
	case <-time.After(30 * time.Second):
		t.Fatal("PS never returned; the deadline did not reach the child")
	}
}

// TestPSSucceedsAgainstAPromptDocker keeps the timeout from passing by
// rejecting everything: a docker that answers is still parsed normally.
func TestPSSucceedsAgainstAPromptDocker(t *testing.T) {
	writeShim(t, "docker",
		"#!/bin/sh\n"+
			`echo '{"ID":"abc123","Service":"claude-a","State":"running","Status":"Up 2 hours"}'`+"\n")

	env := config.NewEmptyEnv(filepath.Join(t.TempDir(), ".env"))
	client := NewClient(t.TempDir(), env)

	infos, err := client.PS()
	if err != nil {
		t.Fatalf("PS: %v", err)
	}
	if len(infos) != 1 || infos[0].Service != "claude-a" || infos[0].State != "running" {
		t.Fatalf("unexpected parse: %+v", infos)
	}
}
