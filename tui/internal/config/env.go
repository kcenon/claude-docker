// Package config provides .env parsing and state directory discovery.
package config

import (
	"bufio"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
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
type Env struct {
	path    string
	entries []entry
	index   map[string]int // key -> entries[i]
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
		val := strings.TrimSpace(trimmed[idx+1:])
		val = strings.Trim(val, `"'`)
		e.index[key] = len(e.entries)
		e.entries = append(e.entries, entry{key: key, value: val, raw: line})
	}
	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("scan env: %w", err)
	}
	return e, nil
}

// NewEmptyEnv returns a fresh empty Env with the given path.
func NewEmptyEnv(path string) *Env {
	return &Env{path: path, index: make(map[string]int)}
}

// Get returns the value of a key, or empty string if not set.
func (e *Env) Get(key string) string {
	if i, ok := e.index[key]; ok {
		return e.entries[i].value
	}
	return ""
}

// Set updates or appends a key=value entry.
func (e *Env) Set(key, value string) {
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
	if e.path == "" {
		return fmt.Errorf("env path not set")
	}
	dir := filepath.Dir(e.path)
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
	for _, ent := range e.entries {
		if ent.key != "" {
			if _, err := fmt.Fprintf(w, "%s=%s\n", ent.key, ent.value); err != nil {
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
	if err := os.Rename(tmpName, e.path); err != nil {
		return fmt.Errorf("rename: %w", err)
	}
	if err := hardenSecretFile(e.path); err != nil {
		return err
	}
	return nil
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
