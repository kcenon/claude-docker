package dashboard

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/charmbracelet/lipgloss"
	"github.com/kcenon/claude-docker/tui/internal/account"
	"github.com/kcenon/claude-docker/tui/internal/config"
	"github.com/kcenon/claude-docker/tui/internal/docker"
)

func TestStartGHAuthPerAccountWritesSelectedAccount(t *testing.T) {
	path := filepath.Join(t.TempDir(), ".env")
	content := "GH_AUTH_MODE=per-account\n" +
		"GH_USER_A=fixture-user-a\nGH_TOKEN_A=unchanged-a\n" +
		"GH_USER_B=fixture-user-b\nGH_TOKEN_B=old-b\n" +
		"GH_TOKEN=unchanged-shared\n"
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatalf("write env: %v", err)
	}
	env, err := config.LoadEnv(path)
	if err != nil {
		t.Fatalf("LoadEnv: %v", err)
	}
	client := docker.NewClient(t.TempDir(), env)
	m := New(nil, client, env, false)
	m.accounts = []account.Account{
		{Letter: "a", ServiceName: "claude-a"},
		{Letter: "b", ServiceName: "claude-b"},
	}
	m.cursor = 1

	original := hostGHToken
	t.Cleanup(func() { hostGHToken = original })
	var selected string
	hostGHToken = func(user string) (string, error) {
		selected = user
		return "new-b", nil
	}

	updated, cmd := m.startGHAuth()
	if !updated.busy || cmd == nil {
		t.Fatal("startGHAuth should enter busy state and return a command")
	}
	raw := cmd()
	msg, ok := raw.(ghAuthAppliedMsg)
	if !ok {
		t.Fatalf("message type = %T, want ghAuthAppliedMsg", raw)
	}
	if msg.err != nil || msg.recreateNeeded {
		t.Fatalf("message = %+v, want successful write without recreate", msg)
	}
	if selected != "fixture-user-b" {
		t.Errorf("selected host login = %q, want fixture-user-b", selected)
	}

	reloaded, err := config.LoadEnv(path)
	if err != nil {
		t.Fatalf("reload env: %v", err)
	}
	if got := reloaded.Get("GH_TOKEN_B"); got != "new-b" {
		t.Errorf("GH_TOKEN_B = %q, want new-b", got)
	}
	if runtime.GOOS != "windows" {
		info, statErr := os.Stat(path)
		if statErr != nil {
			t.Fatalf("stat env: %v", statErr)
		}
		if got := info.Mode().Perm(); got != 0o600 {
			t.Errorf(".env permissions = %04o, want 0600", got)
		}
	}
	for key, want := range map[string]string{
		"GH_TOKEN_A": "unchanged-a",
		"GH_TOKEN":   "unchanged-shared",
	} {
		if got := reloaded.Get(key); got != want {
			t.Errorf("%s = %q, want %q", key, got, want)
		}
	}
}

func TestStartGHAuthRejectsInvalidMode(t *testing.T) {
	path := filepath.Join(t.TempDir(), ".env")
	if err := os.WriteFile(path, []byte("GH_AUTH_MODE=unexpected\nGH_TOKEN=unchanged\n"), 0o600); err != nil {
		t.Fatalf("write env: %v", err)
	}
	env, err := config.LoadEnv(path)
	if err != nil {
		t.Fatalf("LoadEnv: %v", err)
	}
	m := New(nil, docker.NewClient(t.TempDir(), env), env, false)

	original := hostGHToken
	t.Cleanup(func() { hostGHToken = original })
	called := false
	hostGHToken = func(string) (string, error) {
		called = true
		return "must-not-be-written", nil
	}

	updated, cmd := m.startGHAuth()
	if updated.busy || cmd == nil {
		t.Fatalf("invalid mode result: busy=%v cmd=nil=%v", updated.busy, cmd == nil)
	}
	if called {
		t.Fatal("invalid mode must not read or write a GitHub token")
	}
	if !strings.Contains(updated.statusText, "GH_AUTH_MODE must be shared or per-account") {
		t.Errorf("status = %q", updated.statusText)
	}
	reloaded, err := config.LoadEnv(path)
	if err != nil {
		t.Fatalf("reload env: %v", err)
	}
	if got := reloaded.Get("GH_TOKEN"); got != "unchanged" {
		t.Errorf("GH_TOKEN = %q, want unchanged", got)
	}
}

func TestRenderGitHubLoginAndMismatch(t *testing.T) {
	accounts := []account.Account{
		{ServiceName: "claude-a", ContainerStatus: account.ContainerRunning, GHAuthOK: true, GHLogin: "actual-a"},
		{ServiceName: "claude-b", ContainerStatus: account.ContainerRunning, GHLogin: "actual-b", GHExpectedLogin: "expected-b", GHLoginMismatch: true},
	}
	view := renderAccountTable(accounts, 0, 140)
	for _, want := range []string{"GITHUB LOGIN", "actual-a", "actual-b != expected-b"} {
		if !strings.Contains(view, want) {
			t.Errorf("rendered table missing %q: %s", want, view)
		}
	}
}

func TestPadPlainAscii(t *testing.T) {
	got := padPlain("hello", 10)
	if w := lipgloss.Width(got); w != 10 {
		t.Fatalf("ascii: visual width = %d, want 10", w)
	}
}

func TestPadPlainHangul(t *testing.T) {
	// "한글" is 2 runes, each 2 columns wide -> visual width 4
	got := padPlain("한글", 10)
	if w := lipgloss.Width(got); w != 10 {
		t.Fatalf("hangul: visual width = %d, want 10", w)
	}
}

func TestPadPlainMixed(t *testing.T) {
	got := padPlain("hi 한", 10)
	if w := lipgloss.Width(got); w != 10 {
		t.Fatalf("mixed: visual width = %d, want 10", w)
	}
}

func TestPadPlainAlreadyWide(t *testing.T) {
	s := "hello world"
	got := padPlain(s, 5)
	if got != s {
		t.Fatalf("over-width: returned %q, want unchanged", got)
	}
}
