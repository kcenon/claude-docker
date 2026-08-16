package config

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestUnloadableEnvRefusesToSave is the data-loss guard for #358 item 7.
//
// main.go falls back to an empty Env when LoadEnv fails, which is right for
// reading. It was also writable, and Save writes only the entries the Env
// holds -- so one `g` press against that fallback replaced a .env full of
// keys with a single GH_TOKEN line.
func TestUnloadableEnvRefusesToSave(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, ".env")
	original := "NUM_ACCOUNTS=2\nPROJECT_DIR=/home/node/project\nCLAUDE_API_KEY_A=sk-ant-secret\n"
	if err := os.WriteFile(path, []byte(original), 0o600); err != nil {
		t.Fatalf("seed: %v", err)
	}

	env := NewUnloadableEnv(path, errors.New("permission denied"))

	if env.CanPersist() {
		t.Error("CanPersist should be false for an Env that stands in for an unreadable file")
	}

	env.Set("GH_TOKEN", "gho_would_have_clobbered")
	err := env.Save()
	if err == nil {
		t.Fatal("Save must refuse")
	}
	if !strings.Contains(err.Error(), "refusing to write") {
		t.Errorf("the refusal should say what it is refusing, got: %v", err)
	}

	after, readErr := os.ReadFile(path)
	if readErr != nil {
		t.Fatalf("read back: %v", readErr)
	}
	if string(after) != original {
		t.Errorf("the file was modified despite the refusal:\nwant:\n%s\ngot:\n%s", original, after)
	}
}

// TestLoadedEnvCanPersist keeps the refusal from applying to everything.
func TestLoadedEnvCanPersist(t *testing.T) {
	path := filepath.Join(t.TempDir(), ".env")
	if err := os.WriteFile(path, []byte("NUM_ACCOUNTS=2\n"), 0o600); err != nil {
		t.Fatalf("seed: %v", err)
	}
	env, err := LoadEnv(path)
	if err != nil {
		t.Fatalf("LoadEnv: %v", err)
	}
	if !env.CanPersist() {
		t.Error("a loaded Env must be persistable")
	}
	if err := env.Save(); err != nil {
		t.Errorf("Save: %v", err)
	}
}

// TestEmptyEnvCanPersist pins that the plain empty Env -- used by every test
// and by a genuinely absent .env -- is still writable. The refusal is
// specifically about standing in for a file that exists and could not be read.
func TestEmptyEnvCanPersist(t *testing.T) {
	env := NewEmptyEnv(filepath.Join(t.TempDir(), ".env"))
	if !env.CanPersist() {
		t.Error("an empty Env must be persistable")
	}
	if err := env.Save(); err != nil {
		t.Errorf("Save: %v", err)
	}
}

// TestNilEnvCannotPersist covers the nil receiver, which CanPersist has to
// answer for because Model.env can be nil.
func TestNilEnvCannotPersist(t *testing.T) {
	var env *Env
	if env.CanPersist() {
		t.Error("a nil Env must not claim to be persistable")
	}
}
