// Package config provides .env parsing and state directory discovery.
package config

import (
	"bufio"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"sync"
)

const (
	// DefaultNumAccounts matches the compose generator fallback.
	DefaultNumAccounts = 2
	RuntimeClaude      = "claude"
	RuntimeCodex       = "codex"
	RuntimeGemini      = "gemini"
	GHAuthShared       = "shared"
	GHAuthPerAccount   = "per-account"

	// Isolation modes name the workspace trust boundary a set of accounts
	// runs under. Kept in lockstep with scripts/lib/isolation.sh and the
	// PowerShell port in scripts/ClaudeDocker.psm1; tests/test_isolation_modes.sh
	// asserts the three layers accept and refuse the same values.
	IsolationShared   = "shared"
	IsolationWorktree = "worktree"
	IsolationIsolated = "isolated"
)

// Env holds parsed .env configuration with order-preserving entries.
//
// One *Env is created in main and shared for the process' lifetime, and
// bubbletea runs every Cmd on its own goroutine. So `entries` and `index` are
// reached from at least three goroutines at once: the event loop renders
// through Get on every message, the refresh Cmd reads NUM_ACCOUNTS and
// AGENT_RUNTIME, and the gh-auth Cmd writes the token key.
//
// Unsynchronized, the write's append branch against a concurrent read is
// `fatal error: concurrent map read and map write` -- a runtime fatal, not a
// panic, so bubbletea's recoverFromPanic never runs and the terminal is left
// in altscreen with a raw stack dump.
//
// Moving the write onto the event loop would not be enough: the refresh Cmd
// still reads from its own goroutine, so the collision would move rather than
// go away. The lock covers every reader, present and future.
type Env struct {
	mu      sync.RWMutex
	path    string
	entries []entry
	index   map[string]int // key -> entries[i]
	// loadErr is non-nil when this Env stands in for a .env that could not be
	// read. Reads answer with defaults; Save refuses. See NewUnloadableEnv.
	loadErr error
}

type entry struct {
	key   string
	value string
	raw   string // original line (for comments/blanks)
}

// LoadEnv parses a .env file, preserving comments and blank lines.
func LoadEnv(path string) (*Env, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("open env file: %w", err)
	}
	defer f.Close()

	e := &Env{path: path, index: make(map[string]int)}
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := scanner.Text()
		trimmed := strings.TrimSpace(line)
		if trimmed == "" || strings.HasPrefix(trimmed, "#") {
			e.entries = append(e.entries, entry{raw: line})
			continue
		}
		idx := strings.Index(trimmed, "=")
		if idx <= 0 {
			e.entries = append(e.entries, entry{raw: line})
			continue
		}
		key := strings.TrimSpace(trimmed[:idx])
		val := parseEnvValue(trimmed[idx+1:])
		e.index[key] = len(e.entries)
		e.entries = append(e.entries, entry{key: key, value: val, raw: line})
	}
	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("scan env: %w", err)
	}
	return e, nil
}

// quotedEnvValue matches a fully quoted value with an optional trailing
// comment: "a # b", 'a b', or "bar"  # note. Group 1 is the content.
var quotedEnvValue = regexp.MustCompile(`^"(.*)"(\s+#.*)?$|^'(.*)'(\s+#.*)?$`)

// inlineEnvComment matches a comment introduced by whitespace-then-hash. A
// bare `#` with no space before it is data: FOO=a#b is the value a#b.
var inlineEnvComment = regexp.MustCompile(`\s+#.*$`)

// parseEnvValue normalizes the text after `KEY=` the way parse_env_value in
// scripts/lib/parse_env.sh does (#356, row 9).
//
// This reader used to do `strings.TrimSpace` then `strings.Trim(val, "\"'")`,
// which differs from the shells in four ways, each of them reachable:
//
//   - No inline-comment handling at all. `NUM_ACCOUNTS=4  # four` produced
//     "4  # four", so Atoi failed and NumAccounts silently returned the
//     default of 2 while both generators read 4. `GH_USER_A=alice  # main`
//     was handed to `gh auth token --user` with the comment attached.
//   - `strings.Trim` is a *cutset* trim, not a paired-quote strip, so
//     `"unclosed` lost its lone leading quote where the shells keep it.
//   - Leading whitespace after `=` was trimmed here and kept by the shells.
//   - `"bar"  # note` kept the closing quote and the comment.
//
// The quote check runs before the comment strip, which is a change on the
// shell side too: with the old order a `#` inside a quoted value started a
// comment, so set_env_value wrote FOO="a # b" and every reader returned `"a`.
// Writer and reader in the same file disagreed. Now all three agree, and the
// round trip is lossless for that value.
//
// Still lossy for an embedded double quote: the wrapper is stripped without
// unescaping, so `say "hi" now` round-trips as `say \"hi\" now`. All three
// implementations agree on that, and set_env_value's own comment documents it.
func parseEnvValue(raw string) string {
	val := strings.TrimRight(raw, " \t\r\n\v\f")

	if m := quotedEnvValue.FindStringSubmatch(val); m != nil {
		// Alternation: group 1 for the double-quoted branch, group 3 for the
		// single-quoted one. Exactly one branch participates in a match.
		if m[1] != "" || strings.HasPrefix(val, `"`) {
			return m[1]
		}
		return m[3]
	}

	val = inlineEnvComment.ReplaceAllString(val, "")
	return strings.TrimRight(val, " \t\r\n\v\f")
}

// NewEmptyEnv returns a fresh empty Env with the given path.
func NewEmptyEnv(path string) *Env {
	return &Env{path: path, index: make(map[string]int)}
}

// NewUnloadableEnv returns an Env that answers reads with their defaults but
// refuses to Save (#358, item 7).
//
// main.go falls back to an empty Env when LoadEnv fails, which is right for
// reading -- the dashboard should still start and show what it can. It is
// wrong for writing: the file on disk may be perfectly good and merely
// unreadable by this process, and Save writes only the entries the Env holds.
// A `g` press against that empty Env would replace the user's whole .env with
// a single token line, silently destroying every key in it.
//
// The refusal lives in Save rather than at each caller so a future writer
// cannot miss it.
func NewUnloadableEnv(path string, cause error) *Env {
	return &Env{path: path, index: make(map[string]int), loadErr: cause}
}

// CanPersist reports whether Save can write this Env. False when the file
// could not be read, so callers can refuse before doing work whose only
// outcome would be a failed write.
func (e *Env) CanPersist() bool {
	if e == nil {
		return false
	}
	e.mu.RLock()
	defer e.mu.RUnlock()
	return e.loadErr == nil
}

// Get returns the value of a key, or empty string if not set.
func (e *Env) Get(key string) string {
	e.mu.RLock()
	defer e.mu.RUnlock()
	if i, ok := e.index[key]; ok {
		return e.entries[i].value
	}
	return ""
}

// Set updates or appends a key=value entry.
//
// The append branch is the one that matters: it writes the map. It used to be
// a one-time event, because the only caller wrote the fixed key GH_TOKEN and
// every press after the first took the in-place update branch. Per-account
// auth made the key GH_TOKEN_<LETTER>, so every account's first gh-auth press
// appends -- and .env.example ships all three token keys commented out, which
// LoadEnv does not index, so even shared mode appends on the first press.
func (e *Env) Set(key, value string) {
	e.mu.Lock()
	defer e.mu.Unlock()
	if i, ok := e.index[key]; ok {
		e.entries[i].key = key
		e.entries[i].value = value
		e.entries[i].raw = key + "=" + value
		return
	}
	e.index[key] = len(e.entries)
	e.entries = append(e.entries, entry{key: key, value: value, raw: key + "=" + value})
}

// Save writes the env file back to disk, preserving order/comments.
// Uses atomic rename + 0600 permissions because the file holds secrets.
func (e *Env) Save() error {
	// Snapshot under the read lock, then write without holding it. The write
	// includes a temp file, a rename and -- on Windows -- an icacls exec;
	// holding the lock across that would stall every render for as long as
	// the slowest of them.
	e.mu.RLock()
	path := e.path
	loadErr := e.loadErr
	snapshot := make([]entry, len(e.entries))
	copy(snapshot, e.entries)
	e.mu.RUnlock()

	// Refuse rather than replace a file we could not read. Save writes only
	// the entries this Env holds, and an Env standing in for an unreadable
	// .env holds none of the user's (#358, item 7).
	if loadErr != nil {
		return fmt.Errorf("refusing to write %s: it could not be read (%v), "+
			"so writing would discard whatever it contains", path, loadErr)
	}

	if path == "" {
		return fmt.Errorf("env path not set")
	}
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0755); err != nil {
		return fmt.Errorf("mkdir: %w", err)
	}
	tmp, err := os.CreateTemp(dir, ".env.tmp-*")
	if err != nil {
		return fmt.Errorf("create tmp: %w", err)
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName)

	w := bufio.NewWriter(tmp)
	for _, ent := range snapshot {
		if ent.key != "" {
			if _, err := fmt.Fprintf(w, "%s=%s\n", ent.key, formatEnvValue(ent.value)); err != nil {
				tmp.Close()
				return fmt.Errorf("write: %w", err)
			}
		} else {
			if _, err := fmt.Fprintln(w, ent.raw); err != nil {
				tmp.Close()
				return fmt.Errorf("write: %w", err)
			}
		}
	}
	if err := w.Flush(); err != nil {
		tmp.Close()
		return fmt.Errorf("flush: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("close: %w", err)
	}
	if err := os.Chmod(tmpName, 0600); err != nil {
		return fmt.Errorf("chmod: %w", err)
	}
	if err := os.Rename(tmpName, path); err != nil {
		return fmt.Errorf("rename: %w", err)
	}
	if err := hardenSecretFile(path); err != nil {
		return err
	}
	return nil
}

// formatEnvValue restores the quoting LoadEnv strips, so a value survives the
// round trip through this writer and back out through any of the three
// readers (#358, item 8).
//
// LoadEnv strips surrounding quotes at env.go:87 and Save used to write the
// bare value back, so `FOO="a # b"` became `FOO=a # b`. The Go reader would
// still return `a # b`, but parse_env.sh strips an inline comment introduced
// by whitespace-then-hash, so bash -- which is what every container actually
// gets its environment from -- read `a`. Pressing `g` was enough to truncate
// an unrelated value.
//
// The rule is set_env_value's, verbatim (scripts/lib/parse_env.sh:128-137):
// quote when the value contains whitespace or '#', or begins with a quote
// character; escape embedded double quotes inside the wrapper. Matching it
// exactly is the point -- the two writers target the same file, and a value
// written by one is read back by the other.
//
// Not lossless for a value containing a double quote, and deliberately so:
// the readers strip the wrapper without unescaping, so `say "hi"` reads back
// as `say \"hi\"`. All three implementations agree on that, and changing it
// means changing all three in lockstep, which is #356's SSOT work.
func formatEnvValue(value string) string {
	needsQuote := strings.ContainsAny(value, " \t\n\r\v\f#")
	if !needsQuote && value != "" && (value[0] == '"' || value[0] == '\'') {
		needsQuote = true
	}
	if !needsQuote {
		return value
	}
	return `"` + strings.ReplaceAll(value, `"`, `\"`) + `"`
}

// hardenSecretFile preserves the Unix 0600 contract and applies the Windows
// ACL equivalent after the atomic rename. Command arguments are passed as an
// argv slice so user/path values are never shell-evaluated.
func hardenSecretFile(path string) error {
	if err := os.Chmod(path, 0600); err != nil {
		return fmt.Errorf("chmod env file: %w", err)
	}
	if runtime.GOOS != "windows" {
		return nil
	}
	user := os.Getenv("USERNAME")
	if user == "" {
		return fmt.Errorf("restrict env ACL: USERNAME is not set")
	}
	if err := exec.Command("icacls", path, "/inheritance:r", "/grant:r", user+":(M)").Run(); err != nil {
		return fmt.Errorf("restrict env ACL: %w", err)
	}
	return nil
}

// NumAccounts returns the NUM_ACCOUNTS value from .env (default 2).
func (e *Env) NumAccounts() int {
	v := e.Get("NUM_ACCOUNTS")
	if v == "" {
		return DefaultNumAccounts
	}
	n, err := strconv.Atoi(v)
	if err != nil || n < 1 {
		return DefaultNumAccounts
	}
	return n
}

// AgentRuntime returns the selected agent runtime. Claude is the default.
// Only runtimes present in the embedded registry are honored; any other
// value (including an empty one) falls back to Claude.
func (e *Env) AgentRuntime() string {
	if e == nil {
		return RuntimeClaude
	}
	v := strings.ToLower(strings.TrimSpace(e.Get("AGENT_RUNTIME")))
	if _, ok := LookupRuntime(v); ok {
		return v
	}
	return RuntimeClaude
}

// RuntimeSpec returns the registry entry for the selected agent runtime.
// AgentRuntime guarantees the name is registered, so the lookup always
// succeeds.
func (e *Env) RuntimeSpec() RuntimeSpec {
	spec, _ := LookupRuntime(e.AgentRuntime())
	return spec
}

// ServicePrefix returns the docker compose service prefix for the runtime.
func (e *Env) ServicePrefix() string {
	return e.RuntimeSpec().ServicePrefix
}

// StateDirName returns the host-side state directory name for the runtime.
func (e *Env) StateDirName() string {
	return StateDirNameForRuntime(e.AgentRuntime())
}

// RuntimeBinary returns the executable used inside the container.
func (e *Env) RuntimeBinary() string {
	return e.RuntimeSpec().Binary
}

// SkipPermissionsFlag returns the runtime-specific unsafe permission bypass flag.
func (e *Env) SkipPermissionsFlag() string {
	return e.RuntimeSpec().SkipPermissionsFlag
}

// RuntimeCommandArgs returns the command used to attach to the selected agent.
func (e *Env) RuntimeCommandArgs(skipPermissions bool) []string {
	spec := e.RuntimeSpec()
	args := []string{spec.Binary}
	args = append(args, strings.Fields(spec.ExtraRunArgs)...)
	if skipPermissions {
		args = append(args, spec.SkipPermissionsFlag)
	}
	return args
}

// SupportsClaudeUsage reports whether Claude-specific usage integrations apply.
func (e *Env) SupportsClaudeUsage() bool {
	return e.RuntimeSpec().SupportsUsage
}

// APIKey returns the per-account provider API key if set.
func (e *Env) APIKey(letter string) string {
	if e == nil {
		return ""
	}
	return e.Get(e.RuntimeSpec().APIKeyVarPrefix + strings.ToUpper(letter))
}

// GitHubAuthMode returns the normalized configured mode. An omitted mode uses
// the backward-compatible shared default; invalid explicit values are retained
// so mutating callers can reject them instead of falling back silently.
func (e *Env) GitHubAuthMode() string {
	if e == nil {
		return GHAuthShared
	}
	mode := strings.ToLower(strings.TrimSpace(e.Get("GH_AUTH_MODE")))
	if mode == "" {
		return GHAuthShared
	}
	return mode
}

// GHUser returns the expected GitHub login for an account in per-account mode.
func (e *Env) GHUser(letter string) string {
	if e == nil || e.GitHubAuthMode() != GHAuthPerAccount {
		return ""
	}
	return e.Get("GH_USER_" + strings.ToUpper(letter))
}

// GHTokenKey returns the host .env key updated by the TUI for an account.
func (e *Env) GHTokenKey(letter string) string {
	if e == nil {
		return "GH_TOKEN"
	}
	switch e.GitHubAuthMode() {
	case GHAuthPerAccount:
		return "GH_TOKEN_" + strings.ToUpper(letter)
	case GHAuthShared:
		return "GH_TOKEN"
	default:
		return ""
	}
}

// HasWorktrees returns true if PROJECT_DIR_A is set (worktree mode).
func (e *Env) HasWorktrees() bool {
	return e.Get("PROJECT_DIR_A") != ""
}

// IsolationMode returns the configured workspace trust boundary.
//
// Resolution mirrors resolve_isolation_mode in scripts/lib/isolation.sh: an
// explicit ISOLATION_MODE wins; otherwise a configured PROJECT_DIR_A means
// worktree, because that is how Tier B installations predating the key were
// set up and how the compose overlay used to be selected; otherwise shared.
//
// An invalid explicit value is returned verbatim rather than replaced with a
// default, the same contract GitHubAuthMode uses: callers that act on the mode
// reject it, and a display caller can name what was actually configured.
func (e *Env) IsolationMode() string {
	if e == nil {
		return IsolationShared
	}
	if mode := strings.ToLower(strings.TrimSpace(e.Get("ISOLATION_MODE"))); mode != "" {
		return mode
	}
	if e.HasWorktrees() {
		return IsolationWorktree
	}
	return IsolationShared
}

// UnusedWorkspaceWarnings reports per-account workspace paths that are
// configured but that the resolved mode does not consume.
//
// Mirrors warn_unused_workspace_paths in scripts/lib/isolation.sh, including
// checking both families rather than stopping at the first: a user who tried
// isolated, went back to worktree, and left the clone paths behind should be
// told the clones are now inert. This reports a surprise and decides nothing,
// which is why it returns messages rather than an error -- the case it exists
// for is a stale PROJECT_DIR_A under ISOLATION_MODE=isolated, where the paths
// are ignored but the configuration reads as though they are not.
func (e *Env) UnusedWorkspaceWarnings() []string {
	if e == nil {
		return nil
	}
	mode := e.IsolationMode()
	var out []string
	if mode != IsolationWorktree && e.Get("PROJECT_DIR_A") != "" {
		out = append(out, "PROJECT_DIR_A is set, but ISOLATION_MODE="+mode+
			" ignores per-account worktree paths")
	}
	if mode != IsolationIsolated && e.Get("ISOLATED_WORKSPACE_A") != "" {
		out = append(out, "ISOLATED_WORKSPACE_A is set, but ISOLATION_MODE="+mode+
			" ignores per-account clone paths")
	}
	return out
}

// IsolationModeKnown reports whether a mode name is part of the contract.
func IsolationModeKnown(mode string) bool {
	switch mode {
	case IsolationShared, IsolationWorktree, IsolationIsolated:
		return true
	}
	return false
}

// IsolationModeSummary returns a one-line description of the trust boundary a
// mode provides. Wording is kept in step with isolation_mode_summary in
// scripts/lib/isolation.sh so the CLI and the dashboard say the same thing.
func IsolationModeSummary(mode string) string {
	switch mode {
	case IsolationShared:
		return "all accounts share one read-write project mount; appropriate only for mutually trusted accounts"
	case IsolationWorktree:
		return "each account mounts only its own worktree; git metadata stays shared, so this is a concurrency tier, not a security boundary"
	case IsolationIsolated:
		return "each account gets an independent clone with its own git metadata and state; no shared project mount and no shared host configuration"
	default:
		return "unrecognized mode; claude-docker refuses to start rather than fall back to a weaker boundary"
	}
}

// IsolationModeTagline returns a short form of the summary for width-limited
// surfaces such as the dashboard banner. It is a separate string rather than a
// truncation of IsolationModeSummary because truncating would cut the worktree
// disclaimer, which is the part a reader most needs.
func IsolationModeTagline(mode string) string {
	switch mode {
	case IsolationShared:
		return "one read-write project mount shared by every account"
	case IsolationWorktree:
		return "own worktree per account; git metadata shared, not a security boundary"
	case IsolationIsolated:
		return "independent clone per account; own git metadata, no shared host config"
	default:
		return "unrecognized; claude-docker refuses to start"
	}
}

// IndexToLetter converts a 1-based account index to its Excel-style
// letter name: 1 -> "a", 26 -> "z", 27 -> "aa", 52 -> "az", 702 -> "zz".
// Values 1-26 are bit-for-bit identical to the previous single-letter impl.
// Returns "" for non-positive input. Upper bound is 702 (zz) to match the
// bash/PowerShell generators; larger values also return "".
func IndexToLetter(i int) string {
	if i < 1 || i > 702 {
		return ""
	}
	var buf []byte
	for i > 0 {
		rem := (i - 1) % 26
		buf = append([]byte{byte('a' + rem)}, buf...)
		i = (i - 1) / 26
	}
	return string(buf)
}

// LetterToIndex converts an Excel-style letter name back to its 1-based
// account index: "a" -> 1, "z" -> 26, "aa" -> 27, "zz" -> 702. Returns 0
// for empty input or any non-lowercase-letter character.
func LetterToIndex(s string) int {
	if len(s) == 0 {
		return 0
	}
	n := 0
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c < 'a' || c > 'z' {
			return 0
		}
		n = n*26 + int(c-'a') + 1
	}
	return n
}
