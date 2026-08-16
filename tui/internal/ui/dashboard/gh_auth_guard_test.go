package dashboard

import (
	"errors"
	"path/filepath"
	"strings"
	"testing"

	"github.com/kcenon/claude-docker/tui/internal/account"
	"github.com/kcenon/claude-docker/tui/internal/config"
	"github.com/kcenon/claude-docker/tui/internal/docker"
)

// TestGHAuthRefusesWhenEnvCannotPersist covers #358 item 7's second half.
//
// main.go falls back to an Env that holds none of the user's keys when .env
// cannot be read. Pressing `g` against that used to fetch a live GitHub token
// and then hand it to Save, which wrote the fallback's single entry over the
// whole file.
//
// The refusal is checked before the token is fetched, so hostGHToken is
// stubbed to fail the test if it is reached at all.
func TestGHAuthRefusesWhenEnvCannotPersist(t *testing.T) {
	called := false
	restore := hostGHToken
	hostGHToken = func(user string) (string, error) {
		called = true
		return "gho_should_never_be_fetched", nil
	}
	defer func() { hostGHToken = restore }()

	env := config.NewUnloadableEnv(filepath.Join(t.TempDir(), ".env"), errors.New("permission denied"))
	m := New(nil, nil, env, false)
	m.loading = false
	m.accounts = []account.Account{{Letter: "a", ServiceName: "claude-a"}}

	m, _ = m.startGHAuth()

	if called {
		t.Error("a token must not be fetched for a write that cannot happen")
	}
	if m.busy {
		t.Error("the model must not be left busy after refusing")
	}
	if !strings.Contains(m.statusText, "could not be read") {
		t.Errorf("the toast should explain why, got %q", m.statusText)
	}
	if m.statusLevel != statusErr {
		t.Errorf("statusLevel = %v, want statusErr", m.statusLevel)
	}
}

// TestGHAuthProceedsWithALoadedEnv keeps the guard from refusing everything.
func TestGHAuthProceedsWithALoadedEnv(t *testing.T) {
	called := false
	restore := hostGHToken
	hostGHToken = func(user string) (string, error) {
		called = true
		return "gho_testtoken", nil
	}
	defer func() { hostGHToken = restore }()

	env := config.NewEmptyEnv(filepath.Join(t.TempDir(), ".env"))
	// A real client pointed at a directory with no compose file: the command
	// below asks it whether any container is running, and `docker compose ps`
	// fails immediately instead of reaching a daemon. Same degraded path
	// render_test.go relies on.
	client := docker.NewClient(t.TempDir(), env)
	m := New(nil, client, env, false)
	m.loading = false
	m.accounts = []account.Account{{Letter: "a", ServiceName: "claude-a"}}

	m, cmd := m.startGHAuth()
	if cmd == nil {
		t.Fatal("expected a command for a loadable .env")
	}
	if !m.busy {
		t.Error("the model should be busy while gh-auth runs")
	}

	// Running the returned command is what performs the fetch and the write.
	msg := cmd()
	if !called {
		t.Error("the token should have been fetched")
	}
	applied, ok := msg.(ghAuthAppliedMsg)
	if !ok {
		t.Fatalf("unexpected message type %T", msg)
	}
	if applied.err != nil {
		t.Errorf("gh-auth reported: %v", applied.err)
	}
	if got := env.Get("GH_TOKEN"); got != "gho_testtoken" {
		t.Errorf("GH_TOKEN = %q, want the fetched token", got)
	}
}
