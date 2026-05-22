// Package config provides .env parsing and state directory discovery.
package config

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

const (
	RuntimeClaude = "claude"
	RuntimeCodex  = "codex"
	RuntimeGemini = "gemini"
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
	return nil
}

// NumAccounts returns the NUM_ACCOUNTS value from .env (default 1).
func (e *Env) NumAccounts() int {
	v := e.Get("NUM_ACCOUNTS")
	if v == "" {
		return 1
	}
	n, err := strconv.Atoi(v)
	if err != nil || n < 1 {
		return 1
	}
	return n
}

// AgentRuntime returns the selected agent runtime. Claude is the default.
func (e *Env) AgentRuntime() string {
	if e == nil {
		return RuntimeClaude
	}
	v := strings.ToLower(strings.TrimSpace(e.Get("AGENT_RUNTIME")))
	switch v {
	case RuntimeCodex:
		return RuntimeCodex
	default:
		return RuntimeClaude
	}
}

// ServicePrefix returns the docker compose service prefix for the runtime.
func (e *Env) ServicePrefix() string {
	return e.AgentRuntime()
}

// StateDirName returns the host-side state directory name for the runtime.
func (e *Env) StateDirName() string {
	return StateDirNameForRuntime(e.AgentRuntime())
}

// RuntimeBinary returns the executable used inside the container.
func (e *Env) RuntimeBinary() string {
	return e.AgentRuntime()
}

// SkipPermissionsFlag returns the runtime-specific unsafe permission bypass flag.
func (e *Env) SkipPermissionsFlag() string {
	if e.AgentRuntime() == RuntimeCodex {
		return "--dangerously-bypass-approvals-and-sandbox"
	}
	return "--dangerously-skip-permissions"
}

// RuntimeCommandArgs returns the command used to attach to the selected agent.
func (e *Env) RuntimeCommandArgs(skipPermissions bool) []string {
	args := []string{e.RuntimeBinary()}
	if e.AgentRuntime() == RuntimeCodex {
		args = append(args, "-c", `cli_auth_credentials_store="file"`)
	}
	if skipPermissions {
		args = append(args, e.SkipPermissionsFlag())
	}
	return args
}

// SupportsClaudeUsage reports whether Claude-specific usage integrations apply.
func (e *Env) SupportsClaudeUsage() bool {
	return e.AgentRuntime() == RuntimeClaude
}

// APIKey returns the per-account provider API key if set.
func (e *Env) APIKey(letter string) string {
	if e == nil {
		return ""
	}
	prefix := "CLAUDE_API_KEY_"
	if e.AgentRuntime() == RuntimeCodex {
		prefix = "CODEX_API_KEY_"
	}
	return e.Get(prefix + strings.ToUpper(letter))
}

// HasWorktrees returns true if PROJECT_DIR_A is set (worktree mode).
func (e *Env) HasWorktrees() bool {
	return e.Get("PROJECT_DIR_A") != ""
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
