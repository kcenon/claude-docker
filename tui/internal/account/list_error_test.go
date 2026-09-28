package account

import (
	"path/filepath"
	"strings"
	"testing"

	"github.com/kcenon/claude-docker/tui/internal/config"
	"github.com/kcenon/claude-docker/tui/internal/docker"
)

// TestListAccountsReportsADockerFailure covers #358 item 9 at the source.
//
// ListAccounts' only return was `return accounts, nil`, so Model.err had no
// writer and view.go's error branch was dead. The accounts still come back
// alongside the error: they were discovered from the state directories and do
// not depend on docker, so a caller that can show a partial view should.
func TestListAccountsReportsADockerFailure(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	env := config.NewEmptyEnv(filepath.Join(t.TempDir(), ".env"))
	env.Set("NUM_ACCOUNTS", "2")
	// A project root with no compose file: `docker compose ps` fails at once
	// rather than reaching a daemon.
	m := NewManager(env, docker.NewClient(t.TempDir(), env))

	accounts, err := m.ListAccounts()

	if err == nil {
		t.Fatal("a docker failure must be reported, not swallowed")
	}
	if !strings.Contains(err.Error(), "container status unavailable") {
		t.Errorf("the error should say what is missing, got: %v", err)
	}
	if len(accounts) != 2 {
		t.Errorf("accounts should still be returned alongside the error, got %d", len(accounts))
	}
	for _, a := range accounts {
		if a.ContainerStatus != ContainerNotCreated {
			t.Errorf("%s: status should be unknown, got %v", a.ServiceName, a.ContainerStatus)
		}
	}
}
