// Package usage provides JSONL session parsing and token aggregation.
package usage

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"sync"
)

// SessionEntry is a single assistant message with usage info.
type SessionEntry struct {
	Type    string `json:"type"`
	Message struct {
		Model string `json:"model"`
		Usage struct {
			InputTokens              int64 `json:"input_tokens"`
			OutputTokens             int64 `json:"output_tokens"`
			CacheCreationInputTokens int64 `json:"cache_creation_input_tokens"`
			CacheReadInputTokens     int64 `json:"cache_read_input_tokens"`
		} `json:"usage"`
	} `json:"message"`
	Timestamp string `json:"timestamp"`
	SessionID string `json:"sessionId"`
}

// Session represents a single JSONL session file with parsed entries.
type Session struct {
	Path    string
	Entries []SessionEntry
}

// cacheEntry records a previously parsed session along with the file
// fingerprint used to decide whether re-parsing is needed.
type cacheEntry struct {
	size    int64
	modUnix int64 // mtime in unix nanoseconds
	session Session
}

// Cache memoizes parsed session files by path. A cached entry is reused
// when both file size and mtime match the entry on disk. The zero value
// is unusable; call NewCache.
//
// Cache is safe for concurrent use. Across refreshes the same Cache
// instance should be reused so unchanged JSONL files are not reparsed.
type Cache struct {
	mu      sync.Mutex
	entries map[string]cacheEntry
}

// NewCache creates an empty session-parse cache.
func NewCache() *Cache {
	return &Cache{entries: make(map[string]cacheEntry)}
}

// get returns the cached session for path when its fingerprint matches
// size and modUnix. Returns ok=false otherwise.
func (c *Cache) get(path string, size, modUnix int64) (Session, bool) {
	if c == nil {
		return Session{}, false
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	e, ok := c.entries[path]
	if !ok || e.size != size || e.modUnix != modUnix {
		return Session{}, false
	}
	return e.session, true
}

// put records a parsed session for path with its fingerprint.
func (c *Cache) put(path string, size, modUnix int64, s Session) {
	if c == nil {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	c.entries[path] = cacheEntry{size: size, modUnix: modUnix, session: s}
}

// prune removes cache entries whose paths are not present in seen. This
// drops entries for files that have been deleted or moved out of the
// projects tree, keeping cache memory bounded by current state.
func (c *Cache) prune(seen map[string]struct{}) {
	if c == nil {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	for path := range c.entries {
		if _, ok := seen[path]; !ok {
			delete(c.entries, path)
		}
	}
}

// Len returns the number of cached entries. Intended for tests and
// diagnostics; never used in hot paths.
func (c *Cache) Len() int {
	if c == nil {
		return 0
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	return len(c.entries)
}

// ScanAccountSessions walks the projects dir and parses all .jsonl files.
// This is a convenience wrapper around ScanAccountSessionsWithCache with
// no cache; every call reparses every file. Hot paths (TUI refresh)
// should use ScanAccountSessionsWithCache with a long-lived cache instead.
func ScanAccountSessions(projectsDir string) ([]Session, error) {
	return ScanAccountSessionsWithCache(projectsDir, nil)
}

// ScanAccountSessionsWithCache walks the projects dir and returns parsed
// sessions for every .jsonl file. When cache is non-nil, files whose
// path, size, and mtime match a cached entry are returned from the
// cache without re-reading the file. After the scan, cache entries for
// files no longer present on disk are pruned.
func ScanAccountSessionsWithCache(projectsDir string, cache *Cache) ([]Session, error) {
	var sessions []Session
	if _, err := os.Stat(projectsDir); err != nil {
		if os.IsNotExist(err) {
			// Even with a missing dir we should prune anything still in
			// the cache that pointed under this tree, otherwise switching
			// away from a state dir would leak entries. Callers that share
			// one cache across multiple projects dirs handle this via the
			// per-call seen set returned to prune below.
			if cache != nil {
				cache.prune(map[string]struct{}{})
			}
			return nil, nil
		}
		return nil, err
	}

	seen := make(map[string]struct{})

	err := filepath.WalkDir(projectsDir, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil // skip errors, continue walking
		}
		if d.IsDir() {
			return nil
		}
		if !strings.HasSuffix(path, ".jsonl") {
			return nil
		}

		info, infoErr := d.Info()
		if infoErr != nil {
			// Fall back to a stat-less parse; never cache without a fingerprint.
			s, parseErr := parseSessionFile(path)
			if parseErr != nil {
				return nil
			}
			sessions = append(sessions, s)
			seen[path] = struct{}{}
			return nil
		}

		size := info.Size()
		modUnix := info.ModTime().UnixNano()
		seen[path] = struct{}{}

		if cached, ok := cache.get(path, size, modUnix); ok {
			sessions = append(sessions, cached)
			return nil
		}

		s, parseErr := parseSessionFile(path)
		if parseErr != nil {
			return nil // skip unparseable files
		}
		cache.put(path, size, modUnix, s)
		sessions = append(sessions, s)
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("walk projects dir: %w", err)
	}

	cache.prune(seen)
	return sessions, nil
}

func parseSessionFile(path string) (Session, error) {
	f, err := os.Open(path)
	if err != nil {
		return Session{}, err
	}
	defer f.Close()

	s := Session{Path: path}
	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 1024*1024), 10*1024*1024) // 10MB max line
	for scanner.Scan() {
		line := scanner.Bytes()
		var entry SessionEntry
		if err := json.Unmarshal(line, &entry); err != nil {
			continue
		}
		if entry.Type != "assistant" {
			continue
		}
		s.Entries = append(s.Entries, entry)
	}
	return s, scanner.Err()
}
