package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestIndexToLetter(t *testing.T) {
	cases := []struct {
		in   int
		want string
	}{
		{1, "a"},
		{2, "b"},
		{26, "z"},
		{27, "aa"},
		{28, "ab"},
		{52, "az"},
		{53, "ba"},
		{702, "zz"},
		{0, ""},
		{-1, ""},
		{703, ""},
	}
	for _, c := range cases {
		if got := IndexToLetter(c.in); got != c.want {
			t.Errorf("IndexToLetter(%d) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestLetterToIndex(t *testing.T) {
	cases := []struct {
		in   string
		want int
	}{
		{"a", 1},
		{"b", 2},
		{"z", 26},
		{"aa", 27},
		{"ab", 28},
		{"az", 52},
		{"ba", 53},
		{"zz", 702},
		{"", 0},
		{"A", 0},
		{"a1", 0},
		{"_", 0},
	}
	for _, c := range cases {
		if got := LetterToIndex(c.in); got != c.want {
			t.Errorf("LetterToIndex(%q) = %d, want %d", c.in, got, c.want)
		}
	}
}

func TestIndexLetterRoundTrip(t *testing.T) {
	// Verify IndexToLetter and LetterToIndex are mutual inverses across
	// the full supported range. Prevents drift if either is changed.
	for i := 1; i <= 702; i++ {
		letter := IndexToLetter(i)
		back := LetterToIndex(letter)
		if back != i {
			t.Fatalf("round-trip failed at %d: letter=%q back=%d", i, letter, back)
		}
	}
}

// writeTempEnv creates a temp file with the given content and returns its
// absolute path. Files are removed by t.TempDir at the end of the test.
func writeTempEnv(t *testing.T, content string) string {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, ".env")
	if err := os.WriteFile(path, []byte(content), 0644); err != nil {
		t.Fatalf("write temp env: %v", err)
	}
	return path
}

func TestLoadEnv_Basic(t *testing.T) {
	path := writeTempEnv(t, "NUM_ACCOUNTS=2\nIMAGE_TAG=latest\n")
	e, err := LoadEnv(path)
	if err != nil {
		t.Fatalf("LoadEnv: %v", err)
	}
	if v := e.Get("NUM_ACCOUNTS"); v != "2" {
		t.Errorf("NUM_ACCOUNTS = %q, want %q", v, "2")
	}
	if v := e.Get("IMAGE_TAG"); v != "latest" {
		t.Errorf("IMAGE_TAG = %q, want %q", v, "latest")
	}
	if n := e.NumAccounts(); n != 2 {
		t.Errorf("NumAccounts() = %d, want 2", n)
	}
}

func TestLoadEnv_CommentsAndBlanks(t *testing.T) {
	path := writeTempEnv(t,
		"# comment\n"+
			"\n"+
			"NUM_ACCOUNTS=5\n"+
			"# another\n"+
			"GH_TOKEN=abc\n")
	e, err := LoadEnv(path)
	if err != nil {
		t.Fatalf("LoadEnv: %v", err)
	}
	if v := e.Get("NUM_ACCOUNTS"); v != "5" {
		t.Errorf("NUM_ACCOUNTS = %q", v)
	}
	if v := e.Get("GH_TOKEN"); v != "abc" {
		t.Errorf("GH_TOKEN = %q", v)
	}
}

func TestLoadEnv_QuotedValues(t *testing.T) {
	path := writeTempEnv(t,
		"DOUBLE=\"hello world\"\n"+
			"SINGLE='single quoted'\n"+
			"PLAIN=no-quotes\n")
	e, err := LoadEnv(path)
	if err != nil {
		t.Fatalf("LoadEnv: %v", err)
	}
	if v := e.Get("DOUBLE"); v != "hello world" {
		t.Errorf("DOUBLE = %q", v)
	}
	if v := e.Get("SINGLE"); v != "single quoted" {
		t.Errorf("SINGLE = %q", v)
	}
	if v := e.Get("PLAIN"); v != "no-quotes" {
		t.Errorf("PLAIN = %q", v)
	}
}

func TestLoadEnv_MissingFile(t *testing.T) {
	_, err := LoadEnv(filepath.Join(t.TempDir(), "does-not-exist.env"))
	if err == nil {
		t.Fatal("expected error for missing file")
	}
}

func TestLoadEnv_ValuesWithEquals(t *testing.T) {
	// strings.Index on the first "=" is what LoadEnv uses; values containing
	// additional "=" characters must survive.
	path := writeTempEnv(t, "TOKEN=foo=bar=baz\n")
	e, err := LoadEnv(path)
	if err != nil {
		t.Fatalf("LoadEnv: %v", err)
	}
	if v := e.Get("TOKEN"); v != "foo=bar=baz" {
		t.Errorf("TOKEN = %q, want %q", v, "foo=bar=baz")
	}
}

func TestNewEmptyEnv_SetGetSave(t *testing.T) {
	path := filepath.Join(t.TempDir(), ".env")
	e := NewEmptyEnv(path)

	e.Set("NUM_ACCOUNTS", "4")
	e.Set("IMAGE_TAG", "test")
	e.Set("NUM_ACCOUNTS", "7") // update existing

	if v := e.Get("NUM_ACCOUNTS"); v != "7" {
		t.Errorf("after update, NUM_ACCOUNTS = %q, want %q", v, "7")
	}

	if err := e.Save(); err != nil {
		t.Fatalf("Save: %v", err)
	}

	// Re-load and verify persistence.
	loaded, err := LoadEnv(path)
	if err != nil {
		t.Fatalf("LoadEnv after Save: %v", err)
	}
	if v := loaded.Get("NUM_ACCOUNTS"); v != "7" {
		t.Errorf("persisted NUM_ACCOUNTS = %q, want 7", v)
	}
	if v := loaded.Get("IMAGE_TAG"); v != "test" {
		t.Errorf("persisted IMAGE_TAG = %q, want test", v)
	}
}

func TestNumAccounts_Fallback(t *testing.T) {
	// Missing key, non-numeric, and negative all fall back to the
	// generator default (2).
	cases := []struct {
		content string
		want    int
	}{
		{"", 2},
		{"NUM_ACCOUNTS=abc\n", 2},
		{"NUM_ACCOUNTS=-3\n", 2},
		{"NUM_ACCOUNTS=4\n", 4},
	}
	for _, c := range cases {
		path := writeTempEnv(t, c.content)
		e, err := LoadEnv(path)
		if err != nil {
			t.Fatalf("LoadEnv(%q): %v", c.content, err)
		}
		if got := e.NumAccounts(); got != c.want {
			t.Errorf("content=%q: NumAccounts() = %d, want %d", c.content, got, c.want)
		}
	}
}

func TestAPIKey_CaseInsensitiveLetter(t *testing.T) {
	path := writeTempEnv(t, "CLAUDE_API_KEY_A=sk-a\nCLAUDE_API_KEY_AA=sk-aa\n")
	e, err := LoadEnv(path)
	if err != nil {
		t.Fatalf("LoadEnv: %v", err)
	}
	if v := e.APIKey("a"); v != "sk-a" {
		t.Errorf("APIKey(a) = %q", v)
	}
	if v := e.APIKey("aa"); v != "sk-aa" {
		t.Errorf("APIKey(aa) = %q", v)
	}
	// Missing letter returns empty.
	if v := e.APIKey("z"); v != "" {
		t.Errorf("APIKey(z) missing should be empty, got %q", v)
	}
}

func TestGitHubPerAccountConfiguration(t *testing.T) {
	path := writeTempEnv(t,
		"GH_AUTH_MODE=per-account\n"+
			"GH_USER_A=fixture-user-a\n"+
			"GH_TOKEN_A=fixture-token-a\n"+
			"GH_USER_AA=fixture-user-aa\n")
	e, err := LoadEnv(path)
	if err != nil {
		t.Fatalf("LoadEnv: %v", err)
	}
	if got := e.GitHubAuthMode(); got != GHAuthPerAccount {
		t.Errorf("GitHubAuthMode = %q, want %q", got, GHAuthPerAccount)
	}
	if got := e.GHUser("a"); got != "fixture-user-a" {
		t.Errorf("GHUser(a) = %q", got)
	}
	if got := e.GHUser("aa"); got != "fixture-user-aa" {
		t.Errorf("GHUser(aa) = %q", got)
	}
	if got := e.GHTokenKey("aa"); got != "GH_TOKEN_AA" {
		t.Errorf("GHTokenKey(aa) = %q", got)
	}

	shared := NewEmptyEnv(filepath.Join(t.TempDir(), ".env"))
	if got := shared.GitHubAuthMode(); got != GHAuthShared {
		t.Errorf("default GitHubAuthMode = %q, want %q", got, GHAuthShared)
	}
	if got := shared.GHTokenKey("a"); got != "GH_TOKEN" {
		t.Errorf("shared GHTokenKey(a) = %q", got)
	}

	invalidPath := writeTempEnv(t, "GH_AUTH_MODE=unexpected\n")
	invalid, err := LoadEnv(invalidPath)
	if err != nil {
		t.Fatalf("LoadEnv invalid mode: %v", err)
	}
	if got := invalid.GitHubAuthMode(); got != "unexpected" {
		t.Errorf("invalid GitHubAuthMode = %q, want unexpected", got)
	}
	if got := invalid.GHTokenKey("a"); got != "" {
		t.Errorf("invalid-mode GHTokenKey(a) = %q, want empty", got)
	}
}

func TestAgentRuntime_DefaultAndCodex(t *testing.T) {
	cases := []struct {
		content string
		want    string
	}{
		{"", RuntimeClaude},
		{"AGENT_RUNTIME=claude\n", RuntimeClaude},
		{"AGENT_RUNTIME=codex\n", RuntimeCodex},
		{"AGENT_RUNTIME=invalid\n", RuntimeClaude},
	}
	for _, c := range cases {
		path := writeTempEnv(t, c.content)
		e, err := LoadEnv(path)
		if err != nil {
			t.Fatalf("LoadEnv(%q): %v", c.content, err)
		}
		if got := e.AgentRuntime(); got != c.want {
			t.Errorf("content=%q: AgentRuntime() = %q, want %q", c.content, got, c.want)
		}
	}
}

func TestCodexRuntimeAPIKeyAndCommandArgs(t *testing.T) {
	path := writeTempEnv(t, "AGENT_RUNTIME=codex\nCODEX_API_KEY_A=sk-openai\nCLAUDE_API_KEY_A=sk-ant\n")
	e, err := LoadEnv(path)
	if err != nil {
		t.Fatalf("LoadEnv: %v", err)
	}
	if got := e.APIKey("a"); got != "sk-openai" {
		t.Errorf("APIKey(a) = %q, want codex key", got)
	}
	if got := e.StateDirName(); got != ".codex-state" {
		t.Errorf("StateDirName() = %q, want .codex-state", got)
	}
	wantArgs := []string{"codex", "-c", `cli_auth_credentials_store="file"`, "--dangerously-bypass-approvals-and-sandbox"}
	gotArgs := e.RuntimeCommandArgs(true)
	if len(gotArgs) != len(wantArgs) {
		t.Fatalf("RuntimeCommandArgs len = %d, want %d (%v)", len(gotArgs), len(wantArgs), gotArgs)
	}
	for i := range wantArgs {
		if gotArgs[i] != wantArgs[i] {
			t.Errorf("RuntimeCommandArgs[%d] = %q, want %q", i, gotArgs[i], wantArgs[i])
		}
	}
}

// TestGeminiRuntimeAPIKeyAndCommandArgs is the gemini counterpart of the codex
// case above: every value the TUI needs to list and attach a gemini account
// must come from the registry, not from a claude-shaped default. It covers the
// non-interactive half of Epic #267 AC3 #3 (#289) — the command the dashboard
// hands to `docker compose exec`, which no live smoke test can observe because
// an attach needs a TTY and a credential.
func TestGeminiRuntimeAPIKeyAndCommandArgs(t *testing.T) {
	// The claude key is present but must be ignored: key selection follows
	// the registry apiKeyVarPrefix, not the historical CLAUDE_ default.
	path := writeTempEnv(t, "AGENT_RUNTIME=gemini\nGEMINI_API_KEY_A=gm-key\nCLAUDE_API_KEY_A=sk-ant\n")
	e, err := LoadEnv(path)
	if err != nil {
		t.Fatalf("LoadEnv: %v", err)
	}
	if got := e.APIKey("a"); got != "gm-key" {
		t.Errorf("APIKey(a) = %q, want gemini key", got)
	}
	// The state dir the dashboard scans for accounts — the #287 / #288 fix.
	if got := e.StateDirName(); got != ".gemini-state" {
		t.Errorf("StateDirName() = %q, want .gemini-state", got)
	}
	// Gemini has no Claude-style OAuth usage endpoint; usage must stay off so
	// the dashboard degrades instead of querying api.anthropic.com.
	if e.SupportsClaudeUsage() {
		t.Error("SupportsClaudeUsage() = true, want false for gemini")
	}

	// Gemini's registry entry has an empty extraRunArgs, so the attach argv is
	// the bare binary plus, on request, its own skip-permissions flag (--yolo).
	// A claude-shaped fallback would emit --dangerously-skip-permissions here,
	// which the gemini CLI does not accept.
	cases := []struct {
		skipPermissions bool
		want            []string
	}{
		{false, []string{"gemini"}},
		{true, []string{"gemini", "--yolo"}},
	}
	for _, c := range cases {
		gotArgs := e.RuntimeCommandArgs(c.skipPermissions)
		if len(gotArgs) != len(c.want) {
			t.Fatalf("RuntimeCommandArgs(%v) len = %d, want %d (%v)",
				c.skipPermissions, len(gotArgs), len(c.want), gotArgs)
		}
		for i := range c.want {
			if gotArgs[i] != c.want[i] {
				t.Errorf("RuntimeCommandArgs(%v)[%d] = %q, want %q",
					c.skipPermissions, i, gotArgs[i], c.want[i])
			}
		}
	}
}

// TestIsolationMode_Resolution pins the resolution order the shell layers use
// (scripts/lib/isolation.sh). The legacy case is the one most easily broken by
// adding an explicit key: installations predating ISOLATION_MODE configured
// Tier B by setting PROJECT_DIR_A alone, and losing the inference would move
// every one of them onto the shared mount without saying so.
func TestIsolationMode_Resolution(t *testing.T) {
	cases := []struct {
		name    string
		content string
		want    string
	}{
		{"default", "NUM_ACCOUNTS=2\n", IsolationShared},
		{"legacy inference", "PROJECT_DIR_A=/tmp/wt-a\n", IsolationWorktree},
		{"explicit worktree", "ISOLATION_MODE=worktree\nPROJECT_DIR_A=/tmp/wt-a\n", IsolationWorktree},
		{"explicit shared outranks inference", "ISOLATION_MODE=shared\nPROJECT_DIR_A=/tmp/wt-a\n", IsolationShared},
		{"case and space insensitive", "ISOLATION_MODE=  WorkTree  \n", IsolationWorktree},
		{"isolated is reported as configured", "ISOLATION_MODE=isolated\n", IsolationIsolated},
		// An invalid value is returned verbatim so a caller can name what was
		// configured when it refuses it, matching GitHubAuthMode.
		{"invalid value retained", "ISOLATION_MODE=bogus\n", "bogus"},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			e, err := LoadEnv(writeTempEnv(t, c.content))
			if err != nil {
				t.Fatalf("LoadEnv: %v", err)
			}
			if got := e.IsolationMode(); got != c.want {
				t.Errorf("IsolationMode() = %q, want %q", got, c.want)
			}
		})
	}

	var nilEnv *Env
	if got := nilEnv.IsolationMode(); got != IsolationShared {
		t.Errorf("nil Env IsolationMode() = %q, want %q", got, IsolationShared)
	}
}

func TestIsolationModeKnown(t *testing.T) {
	for _, mode := range []string{IsolationShared, IsolationWorktree, IsolationIsolated} {
		if !IsolationModeKnown(mode) {
			t.Errorf("IsolationModeKnown(%q) = false, want true", mode)
		}
	}
	for _, mode := range []string{"", "bogus", "Shared", "per-account"} {
		if IsolationModeKnown(mode) {
			t.Errorf("IsolationModeKnown(%q) = true, want false", mode)
		}
	}
}

// The worktree summary must keep saying git metadata is shared. That sentence
// is the one place a user is told the tier is not an adversarial boundary, and
// the issue makes stating it an acceptance criterion.
func TestIsolationModeSummary(t *testing.T) {
	if s := IsolationModeSummary(IsolationWorktree); !strings.Contains(s, "not a security boundary") {
		t.Errorf("worktree summary lost its security disclaimer: %q", s)
	}
	if s := IsolationModeSummary(IsolationIsolated); !strings.Contains(s, "not implemented") {
		t.Errorf("isolated summary does not say it is unimplemented: %q", s)
	}
	if s := IsolationModeSummary("bogus"); !strings.Contains(s, "refuses to start") {
		t.Errorf("unknown-mode summary does not describe the refusal: %q", s)
	}
}

// The tagline is the dashboard's copy of the same warning. It exists so the
// worktree disclaimer survives a narrow terminal, which means the disclaimer
// has to actually be in it -- a shortened string that dropped the qualifier
// would defeat the reason the shorter string exists.
func TestIsolationModeTagline(t *testing.T) {
	if s := IsolationModeTagline(IsolationWorktree); !strings.Contains(s, "not a security boundary") {
		t.Errorf("worktree tagline lost its security disclaimer: %q", s)
	}
	if s := IsolationModeTagline(IsolationIsolated); !strings.Contains(s, "refuses to start") {
		t.Errorf("isolated tagline does not warn it will not start: %q", s)
	}
	for _, mode := range []string{IsolationShared, IsolationWorktree, IsolationIsolated, "bogus"} {
		if len(IsolationModeTagline(mode)) > len(IsolationModeSummary(mode)) {
			t.Errorf("tagline for %q is not shorter than its summary", mode)
		}
	}
}
