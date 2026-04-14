// Package config provides .env parsing and state directory discovery.
package config

import (
	"bufio"
	"fmt"
	"os"
	"strconv"
	"strings"
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

// APIKey returns CLAUDE_API_KEY_<LETTER> if set.
func (e *Env) APIKey(letter string) string {
	return e.Get("CLAUDE_API_KEY_" + strings.ToUpper(letter))
}

// HasWorktrees returns true if PROJECT_DIR_A is set (worktree mode).
func (e *Env) HasWorktrees() bool {
	return e.Get("PROJECT_DIR_A") != ""
}

// IndexToLetter converts 1 -> "a", 2 -> "b", etc.
func IndexToLetter(i int) string {
	if i < 1 || i > 26 {
		return ""
	}
	return string(rune('a' + i - 1))
}

// LetterToIndex converts "a" -> 1, "b" -> 2.
func LetterToIndex(s string) int {
	if len(s) != 1 {
		return 0
	}
	c := s[0]
	if c < 'a' || c > 'z' {
		return 0
	}
	return int(c-'a') + 1
}
