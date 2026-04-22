package account

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/kcenon/claude-docker/tui/internal/config"
)

// TestServiceNameGeneration_AllTiers verifies the 1-based index → service-name
// mapping for every tier in NUM_ACCOUNTS' supported range. Values 1-26 stay
// on single letters; 27+ transitions into Excel-style double letters so
// service names remain unique.
func TestServiceNameGeneration_AllTiers(t *testing.T) {
	cases := []struct {
		index   int
		service string
	}{
		{1, "claude-a"},
		{2, "claude-b"},
		{5, "claude-e"},
		{26, "claude-z"},
		{27, "claude-aa"}, // exactly the transition boundary (per #178)
		{30, "claude-ad"},
		{52, "claude-az"},
		{53, "claude-ba"},
		{702, "claude-zz"},
	}
	for _, c := range cases {
		letter := config.IndexToLetter(c.index)
		if got := "claude-" + letter; got != c.service {
			t.Errorf("index=%d: got %q, want %q", c.index, got, c.service)
		}
	}
}

// TestDiscoverStateDirs_EmptyDir confirms an absent base path is not an
// error — first-run installs should see "no accounts yet".
func TestDiscoverStateDirs_EmptyDir(t *testing.T) {
	base := filepath.Join(t.TempDir(), "missing")
	dirs, err := config.DiscoverStateDirsAt(base)
	if err != nil {
		t.Fatalf("DiscoverStateDirsAt on missing path: %v", err)
	}
	if len(dirs) != 0 {
		t.Errorf("expected 0 dirs, got %d", len(dirs))
	}
}

// TestDiscoverStateDirs_SingleAndDoubleLetters exercises a state base that
// contains a, b, aa, ab, zz and some noise (irrelevant directories, files).
// The discovery must filter noise, accept Excel-style names, and sort by
// 1-based index so the caller sees claude-a..z before claude-aa onward.
func TestDiscoverStateDirs_SingleAndDoubleLetters(t *testing.T) {
	base := t.TempDir()
	mustMkdir := func(name string) {
		t.Helper()
		if err := os.Mkdir(filepath.Join(base, name), 0755); err != nil {
			t.Fatalf("mkdir %s: %v", name, err)
		}
	}
	mustMkdir("account-a")
	mustMkdir("account-b")
	mustMkdir("account-aa") // Excel-style double letter
	mustMkdir("account-ab")
	mustMkdir("account-zz")
	mustMkdir("account-INVALID") // uppercase: rejected
	mustMkdir("account-1")       // digit: rejected
	mustMkdir("account-")        // empty suffix: rejected
	mustMkdir("unrelated")       // no "account-" prefix: rejected

	// A regular file (not a directory) with a valid-looking name must also
	// be ignored; DiscoverStateDirsAt iterates DirEntry.IsDir only.
	if err := os.WriteFile(filepath.Join(base, "account-c"), []byte("x"), 0644); err != nil {
		t.Fatalf("write file: %v", err)
	}

	dirs, err := config.DiscoverStateDirsAt(base)
	if err != nil {
		t.Fatalf("DiscoverStateDirsAt: %v", err)
	}

	want := []string{"a", "b", "aa", "ab", "zz"}
	if len(dirs) != len(want) {
		t.Fatalf("got %d dirs (%v), want %d (%v)", len(dirs), letters(dirs), len(want), want)
	}
	for i, w := range want {
		if dirs[i].Letter != w {
			t.Errorf("dirs[%d].Letter = %q, want %q (full list: %v)", i, dirs[i].Letter, w, letters(dirs))
		}
		wantPath := filepath.Join(base, "account-"+w)
		if dirs[i].Path != wantPath {
			t.Errorf("dirs[%d].Path = %q, want %q", i, dirs[i].Path, wantPath)
		}
	}
}

// TestDiscoverStateDirs_SortOrder_IndexNotLexical guards against a
// regression where Sort by lexical Letter would place "aa" between "a"
// and "b" — confusing for end users whose accounts run in index order.
func TestDiscoverStateDirs_SortOrder_IndexNotLexical(t *testing.T) {
	base := t.TempDir()
	for _, n := range []string{"account-aa", "account-a", "account-b"} {
		if err := os.Mkdir(filepath.Join(base, n), 0755); err != nil {
			t.Fatalf("mkdir: %v", err)
		}
	}
	dirs, err := config.DiscoverStateDirsAt(base)
	if err != nil {
		t.Fatalf("DiscoverStateDirsAt: %v", err)
	}
	got := letters(dirs)
	want := []string{"a", "b", "aa"} // a=1, b=2, aa=27
	if len(got) != len(want) {
		t.Fatalf("got %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("order wrong: got %v, want %v", got, want)
		}
	}
}

// TestStateDir_PathHelpers pins the helper method outputs. Intentionally
// light — the actual filesystem operations are tested in integration tests.
// filepath.Join is used for expected values so the assertions are OS-agnostic
// (Windows uses "\", POSIX uses "/").
func TestStateDir_PathHelpers(t *testing.T) {
	base := filepath.Join(string(filepath.Separator)+"tmp", "state", "account-a")
	sd := config.StateDir{Letter: "a", Path: base}
	if got, want := sd.CredentialsPath(), filepath.Join(base, ".credentials.json"); got != want {
		t.Errorf("CredentialsPath = %q, want %q", got, want)
	}
	if got, want := sd.LimitlineCachePath(), filepath.Join(base, "limitline-usage-cache.json"); got != want {
		t.Errorf("LimitlineCachePath = %q, want %q", got, want)
	}
	if got, want := sd.ProjectsDir(), filepath.Join(base, "projects"); got != want {
		t.Errorf("ProjectsDir = %q, want %q", got, want)
	}
	if sd.HasCredentials() {
		t.Error("HasCredentials should be false for non-existent path")
	}
	if sd.HasLimitlineCache() {
		t.Error("HasLimitlineCache should be false for non-existent path")
	}
}

// letters extracts the Letter field from a slice of StateDirs — test-only
// helper used by multiple assertions above.
func letters(dirs []config.StateDir) []string {
	out := make([]string, len(dirs))
	for i, d := range dirs {
		out[i] = d.Letter
	}
	return out
}
