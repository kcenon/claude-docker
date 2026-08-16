package config

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// quotingCases are the inputs that separate the writers. Each `want` is the
// exact byte sequence set_env_value writes for the same value; the last test
// in this file proves that claim rather than asserting it.
var quotingCases = []struct {
	name  string
	value string
	want  string
}{
	{"plain", "abc", "abc"},
	{"empty", "", ""},
	{"space", "a b", `"a b"`},
	{"tab", "a\tb", "\"a\tb\""},
	{"hash with no space", "a#b", `"a#b"`},
	{"space then hash", "a # b", `"a # b"`},
	{"trailing hash", "abc #", `"abc #"`},
	{"leading double quote", `"abc`, `"\"abc"`},
	{"leading single quote", "'abc", `"'abc"`},
	{"embedded double quote", `say "hi" now`, `"say \"hi\" now"`},
	{"token, nothing special", "gho_abc123", "gho_abc123"},
	{"path", "/home/node/project", "/home/node/project"},
}

// TestFormatEnvValue pins the quoting Save restores (#358, item 8).
//
// LoadEnv strips surrounding quotes, and Save used to write the bare value
// back, so `FOO="a # b"` was rewritten as `FOO=a # b` by any press of `g` --
// which rewrites the whole file, not just the key it changed.
func TestFormatEnvValue(t *testing.T) {
	for _, tc := range quotingCases {
		t.Run(tc.name, func(t *testing.T) {
			if got := formatEnvValue(tc.value); got != tc.want {
				t.Errorf("formatEnvValue(%q) = %q, want %q", tc.value, got, tc.want)
			}
		})
	}
}

// TestSaveRewritesAValueUnchanged is the `g`-press scenario end to end: load a
// .env that already contains a quoted value, change an unrelated key, save,
// and require the original line to come back byte for byte.
func TestSaveRewritesAValueUnchanged(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, ".env")
	original := "# a comment\n" +
		"NUM_ACCOUNTS=2\n" +
		"NOTE=\"a # b\"\n" +
		"\n" +
		"PROJECT_DIR=/home/node/project\n"
	if err := os.WriteFile(path, []byte(original), 0o600); err != nil {
		t.Fatalf("seed: %v", err)
	}

	env, err := LoadEnv(path)
	if err != nil {
		t.Fatalf("LoadEnv: %v", err)
	}
	env.Set("GH_TOKEN", "gho_written_by_g")
	if err := env.Save(); err != nil {
		t.Fatalf("Save: %v", err)
	}

	after, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read back: %v", err)
	}
	got := string(after)

	if !strings.Contains(got, "NOTE=\"a # b\"\n") {
		t.Errorf("the quoted value did not survive:\n%s", got)
	}
	if strings.Contains(got, "NOTE=a # b\n") {
		t.Errorf("the value was written unquoted, which truncates it for bash:\n%s", got)
	}
	if !strings.Contains(got, "GH_TOKEN=gho_written_by_g\n") {
		t.Errorf("the new key is missing:\n%s", got)
	}
	if !strings.Contains(got, "# a comment\n") {
		t.Errorf("comments should be preserved:\n%s", got)
	}
	// A token has nothing special in it and must not acquire quotes: the
	// container reads GH_TOKEN through compose, and a literal quote in the
	// value would be part of the token.
	if strings.Contains(got, `GH_TOKEN="`) {
		t.Errorf("an ordinary value must not be quoted:\n%s", got)
	}
}

// TestFormatEnvValueMatchesSetEnvValue is the cross-implementation assertion:
// the bytes this writer produces are the bytes scripts/lib/parse_env.sh's
// set_env_value produces, for the same input.
//
// The two writers target the same file. Asserting the Go side against a table
// I wrote would only prove I am consistent with myself; running the shell
// function is what makes the table a claim about the other implementation.
//
// NOTE ON THE READER: this pins the *writers*. The bash reader currently
// mis-parses what the bash writer produces here, because parse_env_value
// strips an inline comment before it unquotes -- so `FOO="a # b"` reads back
// as `"a`, quote included. That predates both writers, affects the shell path
// with no TUI involved, and fixing it means moving parse_env_value,
// load_env_file, Read-EnvFile and LoadEnv in lockstep, which is the ".env
// value parsing" child of #356. What this PR guarantees is narrower and still
// worth having: pressing `g` no longer changes such a line at all.
func TestFormatEnvValueMatchesSetEnvValue(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("needs a POSIX shell to source parse_env.sh")
	}
	bash, err := exec.LookPath("bash")
	if err != nil {
		t.Skip("bash not available")
	}
	// tui/internal/config -> repo root
	repoRoot, err := filepath.Abs(filepath.Join("..", "..", ".."))
	if err != nil {
		t.Fatalf("resolve repo root: %v", err)
	}
	lib := filepath.Join(repoRoot, "scripts", "lib", "parse_env.sh")
	if _, err := os.Stat(lib); err != nil {
		t.Skipf("parse_env.sh not found at %s", lib)
	}

	for _, tc := range quotingCases {
		t.Run(tc.name, func(t *testing.T) {
			out := filepath.Join(t.TempDir(), ".env")
			script := ". \"$1\"; set_env_value \"$2\" FOO \"$3\""
			cmd := exec.Command(bash, "-c", script, "bash", lib, out, tc.value)
			if b, err := cmd.CombinedOutput(); err != nil {
				t.Fatalf("set_env_value: %v\n%s", err, b)
			}
			data, err := os.ReadFile(out)
			if err != nil {
				t.Fatalf("read: %v", err)
			}
			shellLine := strings.TrimRight(string(data), "\n")
			goLine := "FOO=" + formatEnvValue(tc.value)
			if shellLine != goLine {
				t.Errorf("writers disagree for %q:\n  shell: %s\n  go:    %s",
					tc.value, shellLine, goLine)
			}
		})
	}
}
