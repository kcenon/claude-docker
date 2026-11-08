package ui

import (
	"os"
	"path/filepath"
	"runtime"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/kcenon/claude-docker/tui/internal/config"
	"github.com/kcenon/claude-docker/tui/internal/docker"
)

func TestQuitDrainsAnActiveRefreshAndReleasesItsLock(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Docker shim requires a POSIX shell")
	}
	root := t.TempDir()
	bin := t.TempDir()
	release := filepath.Join(root, "release-docker")
	shim := "#!/bin/sh\nwhile [ ! -f \"$QUIT_RELEASE\" ]; do sleep 0.01; done\nprintf '[]\\n'\n"
	if err := os.WriteFile(filepath.Join(bin, "docker"), []byte(shim), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("QUIT_RELEASE", release)
	env := config.NewEmptyEnv(filepath.Join(root, ".env"))
	client := docker.NewClient(root, env)
	app := NewApp("test", root, env, client, false)
	done := make(chan struct{})
	go func() {
		defer close(done)
		_, _ = client.PS()
	}()
	defer func() {
		_ = os.WriteFile(release, nil, 0o600)
		select {
		case <-done:
		case <-time.After(5 * time.Second):
			t.Error("refresh child did not stop")
		}
	}()
	lock := filepath.Join(root, ".claude-docker-lifecycle")
	deadline := time.Now().Add(5 * time.Second)
	for {
		if _, err := os.Stat(filepath.Join(lock, "owner.json")); err == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("refresh never acquired its lifecycle lock")
		}
		time.Sleep(time.Millisecond)
	}
	_, quit := app.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'q'}})
	if quit == nil {
		t.Fatal("quit command missing")
	}
	if _, err := os.Stat(lock); !os.IsNotExist(err) {
		t.Error("q left the refresh lifecycle lock behind")
	}
}
