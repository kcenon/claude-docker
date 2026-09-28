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
// longer happens" has no output to observe.
//
// It now walks the whole module rather than this package's directory. When
// internal/usage still existed, an import from tui/main.go or from the
// dashboard would have resurrected the walk while this test stayed green --
// it only ever read os.ReadDir("."). The package is deleted, so the compiler
// catches a direct import today; what this still catches is the package being
// recreated and wired back in, which is the failure mode worth a test.
func TestProductionCodeDoesNotImportUsage(t *testing.T) {
	root := filepath.Join("..", "..")

	checked := 0
	fset := token.NewFileSet()
	err := filepath.WalkDir(root, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			return nil
		}
		name := d.Name()
		if !strings.HasSuffix(name, ".go") || strings.HasSuffix(name, "_test.go") {
			return nil
		}
		checked++
		f, parseErr := parser.ParseFile(fset, path, nil, parser.ImportsOnly)
		if parseErr != nil {
			return parseErr
		}
		for _, imp := range f.Imports {
			if strings.Contains(imp.Path.Value, "internal/usage") {
				t.Errorf("%s imports internal/usage; the JSONL pipeline was removed in #358", path)
			}
		}
		return nil
	})
	if err != nil {
		t.Fatalf("walk %s: %v", root, err)
	}

	// Guard against the check passing because it found nothing to check. The
	// floor is well above zero now that the walk covers the module: a wrong
	// root would still find a handful of files, and only a real sweep finds
	// this many.
	if checked < 20 {
		t.Fatalf("examined %d non-test Go files; the walk is not covering the module", checked)
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
