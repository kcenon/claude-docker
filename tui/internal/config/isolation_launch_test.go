package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestIsolatedLaunchDoesNotBypassRuntimeSandbox(t *testing.T) {
	for _, runtime := range []string{"claude", "codex", "gemini"} {
		env := NewEmptyEnv(filepath.Join(t.TempDir(), ".env"))
		env.Set("AGENT_RUNTIME", runtime)
		env.Set("ISOLATION_MODE", "isolated")
		err := env.ValidateRuntimeCommandArgs(true)
		if runtime == "codex" {
			if err == nil {
				t.Fatal("combined sandbox bypass accepted")
			}
			if strings.Contains(strings.Join(env.RuntimeCommandArgs(true), " "), "bypass-approvals-and-sandbox") {
				t.Fatal("unsafe flag survived argv validation")
			}
		} else if err != nil {
			t.Fatal(err)
		}
		env.Set("ISOLATION_MODE", "shared")
		if err := env.ValidateRuntimeCommandArgs(true); err != nil {
			t.Fatal(err)
		}
	}
}

func TestLifecycleLockBlocksEnvReadAndWrite(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, ".env")
	if err := os.WriteFile(path, []byte("NUM_ACCOUNTS=2\n"), 0600); err != nil {
		t.Fatal(err)
	}
	env, err := LoadEnv(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(root, ".claude-docker-lifecycle"), 0700); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadEnv(path); err == nil {
		t.Fatal("read during publication accepted")
	}
	env.Set("NUM_ACCOUNTS", "4")
	if err := env.Save(); err == nil {
		t.Fatal("write during publication accepted")
	}
	got, err := os.ReadFile(path)
	if err != nil || string(got) != "NUM_ACCOUNTS=2\n" {
		t.Fatal("locked env changed")
	}
}

func TestEnvSaveRefusesChangesMadeSinceLoad(t *testing.T) {
	path := filepath.Join(t.TempDir(), ".env")
	if err := os.WriteFile(path, []byte("NUM_ACCOUNTS=2\n"), 0600); err != nil {
		t.Fatal(err)
	}
	env, err := LoadEnv(path)
	if err != nil {
		t.Fatal(err)
	}
	// A completed CLI scale can precede a later save from an open dashboard.
	newContent := "NUM_ACCOUNTS=3\n"
	if err := os.WriteFile(path, []byte(newContent), 0600); err != nil {
		t.Fatal(err)
	}
	env.Set("GH_TOKEN_A", "placeholder")
	if err := env.Save(); err == nil {
		t.Fatal("stale dashboard state overwrote a completed configuration change")
	}
	if got, err := os.ReadFile(path); err != nil || string(got) != newContent {
		t.Fatal("new configuration was not preserved")
	}
}
