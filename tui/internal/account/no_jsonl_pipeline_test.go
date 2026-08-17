package account

import (
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/kcenon/claude-docker/tui/internal/config"
	"github.com/kcenon/claude-docker/tui/internal/docker"
)

// TestProductionCodeDoesNotImportUsage pins the removal in #358 item 14.
//
// Account.Tokens was written on every refresh and read only by HasUsageData,
// which had no caller: the "fallback when limitline is unavailable" the field
// documented was never implemented. Filling it walked
// ~/.claude-state/account-*/projects/**.jsonl on every dashboard refresh and
// every --json invocation, for a value nothing rendered.
//
// A structural assertion rather than a behavioral one, because "this work no
// longer happens" has no output to observe. Test files are excluded on
// purpose: internal/usage keeps its own tests and its benchmark, which
// docs/PERFORMANCE.md is written about. What must not come back is the
// production call path.
func TestProductionCodeDoesNotImportUsage(t *testing.T) {
	entries, err := os.ReadDir(".")
	if err != nil {
		t.Fatalf("readdir: %v", err)
	}

	checked := 0
	fset := token.NewFileSet()
	for _, e := range entries {
		name := e.Name()
		if e.IsDir() || !strings.HasSuffix(name, ".go") || strings.HasSuffix(name, "_test.go") {
			continue
		}
		checked++
		f, err := parser.ParseFile(fset, name, nil, parser.ImportsOnly)
		if err != nil {
			t.Fatalf("parse %s: %v", name, err)
		}
		for _, imp := range f.Imports {
			if strings.Contains(imp.Path.Value, "internal/usage") {
				t.Errorf("%s imports internal/usage; the JSONL pipeline was removed in #358", name)
			}
		}
	}

	// Guard against the check passing because it found nothing to check.
	if checked == 0 {
		t.Fatal("no non-test Go files were examined")
	}
}

// TestAccountHasNoTokensField is the compile-time half, expressed as a
// runtime assertion so it reads as a test rather than as a build error.
//
// Constructing an Account with the removed field would not compile, so what
// is asserted here is the observable consequence: a listing produces accounts
// whose only usage data comes from limitline, and nothing walks a projects
// tree to fill anything else in.
func TestListAccountsDoesNotReadProjectsTrees(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	// A state directory with a projects tree that would be walked by the old
	// pipeline. The file is not valid JSONL; the old parser tolerated that
	// per-file, so this is not what would have failed -- the point is that
	// nothing opens it at all now.
	stateDir := filepath.Join(home, ".claude-state", "account-a")
	projects := filepath.Join(stateDir, "projects", "some-project")
	if err := os.MkdirAll(projects, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	sentinel := filepath.Join(projects, "session.jsonl")
	if err := os.WriteFile(sentinel, []byte("not json at all\n"), 0o600); err != nil {
		t.Fatalf("write: %v", err)
	}

	env := config.NewEmptyEnv(filepath.Join(t.TempDir(), ".env"))
	env.Set("NUM_ACCOUNTS", "1")
	m := NewManager(env, docker.NewClient(t.TempDir(), env))

	accounts, _ := m.ListAccounts()
	if len(accounts) != 1 {
		t.Fatalf("expected 1 account, got %d", len(accounts))
	}
	// Usage stays nil without a limitline cache, which is the same "--" the
	// table drew before: removing the pipeline changed no rendered output.
	if accounts[0].FiveHourUsage != nil || accounts[0].SevenDayUsage != nil {
		t.Errorf("usage should be nil with no limitline cache: %+v", accounts[0])
	}
}
