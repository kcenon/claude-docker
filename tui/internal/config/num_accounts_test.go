package config

import (
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

func envWith(t *testing.T, key, value string) *Env {
	t.Helper()
	e := NewEmptyEnv(filepath.Join(t.TempDir(), ".env"))
	if value != "" {
		e.Set(key, value)
	}
	return e
}

// TestNumAccountsBounds covers #358 item 12. The lower bound existed; the
// upper one did not, and IndexToLetter returns "" above MaxAccounts -- so
// every account past 702 got an empty letter and therefore the *same* service
// name, `<prefix>-`, in a dashboard whose primary action is "attach to the
// selected one".
func TestNumAccountsBounds(t *testing.T) {
	cases := []struct {
		name        string
		value       string
		want        int
		wantWarning string // substring, "" means no warning
	}{
		{"unset uses the default", "", DefaultNumAccounts, ""},
		{"one", "1", 1, ""},
		{"ordinary", "4", 4, ""},
		{"exactly the cap", "702", MaxAccounts, ""},
		{"above the cap", "1000", MaxAccounts, "exceeds"},
		{"far above the cap", "999999", MaxAccounts, "exceeds"},
		{"zero", "0", DefaultNumAccounts, "below 1"},
		{"negative", "-3", DefaultNumAccounts, "below 1"},
		{"not a number", "many", DefaultNumAccounts, "not a number"},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			e := envWith(t, "NUM_ACCOUNTS", tc.value)

			if got := e.NumAccounts(); got != tc.want {
				t.Errorf("NumAccounts() = %d, want %d", got, tc.want)
			}

			warning := e.NumAccountsWarning()
			if tc.wantWarning == "" {
				if warning != "" {
					t.Errorf("unexpected warning: %q", warning)
				}
				return
			}
			if !strings.Contains(warning, tc.wantWarning) {
				t.Errorf("warning = %q, want it to mention %q", warning, tc.wantWarning)
			}
		})
	}
}

// TestEveryAccountIndexHasADistinctLetter is the consequence the bound
// protects: within the clamped range no two accounts collide, and one past it
// would.
func TestEveryAccountIndexHasADistinctLetter(t *testing.T) {
	e := envWith(t, "NUM_ACCOUNTS", strconv.Itoa(MaxAccounts+50))
	n := e.NumAccounts()

	seen := make(map[string]int, n)
	for i := 1; i <= n; i++ {
		letter := IndexToLetter(i)
		if letter == "" {
			t.Fatalf("index %d has no letter, but NumAccounts allowed it", i)
		}
		if prev, dup := seen[letter]; dup {
			t.Fatalf("indexes %d and %d both map to %q", prev, i, letter)
		}
		seen[letter] = i
	}

	// And the first index past the clamp is exactly the one that would break.
	if IndexToLetter(MaxAccounts+1) != "" {
		t.Errorf("IndexToLetter(%d) should be empty; the clamp exists because it is",
			MaxAccounts+1)
	}
}

// TestNilEnvIsUniformlySafe covers #358 item 15.
//
// Model.env can be nil, and seven of nineteen methods guarded for it. Because
// the other twelve were all built on Get -- which was not one of the seven --
// a nil Env panicked on almost everything while looking as though the case
// had been handled. Every method is called here; the test failing means a
// panic, and the assertions check the documented defaults.
func TestNilEnvIsUniformlySafe(t *testing.T) {
	var e *Env

	if got := e.Get("ANYTHING"); got != "" {
		t.Errorf("Get = %q, want empty", got)
	}
	e.Set("KEY", "value") // must not panic
	if err := e.Save(); err == nil {
		t.Error("Save on a nil Env must report an error rather than claim success")
	}
	if got := e.NumAccounts(); got != DefaultNumAccounts {
		t.Errorf("NumAccounts = %d, want %d", got, DefaultNumAccounts)
	}
	if got := e.NumAccountsWarning(); got != "" {
		t.Errorf("NumAccountsWarning = %q, want empty", got)
	}
	if got := e.AgentRuntime(); got != RuntimeClaude {
		t.Errorf("AgentRuntime = %q, want %q", got, RuntimeClaude)
	}
	if got := e.IsolationMode(); got != IsolationShared {
		t.Errorf("IsolationMode = %q, want %q", got, IsolationShared)
	}
	if got := e.GitHubAuthMode(); got != GHAuthShared {
		t.Errorf("GitHubAuthMode = %q, want %q", got, GHAuthShared)
	}

	// The remaining accessors: no defaults worth pinning individually, but
	// each one must return rather than panic.
	_ = e.RuntimeSpec()
	_ = e.ServicePrefix()
	_ = e.StateDirName()
	_ = e.RuntimeBinary()
	_ = e.SkipPermissionsFlag()
	_ = e.RuntimeCommandArgs(true)
	_ = e.SupportsClaudeUsage()
	_ = e.APIKey("a")
	_ = e.GHUser("a")
	_ = e.GHTokenKey("a")
	_ = e.HasWorktrees()
	_ = e.UnusedWorkspaceWarnings()
}
