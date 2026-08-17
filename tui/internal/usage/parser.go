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
	// Truncated is set when the scanner stopped before the end of the file.
	// The entries above are still the ones it decoded; the totals derived
	// from them are a floor, not the file's real total. Callers that report
	// usage should say so rather than present a short count as exact.
	Truncated bool
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

// pruneScope removes cache entries under root whose paths are not present
// in seen. This drops entries for files that have been deleted or moved
// out of that projects tree, keeping cache memory bounded by current state.
//
// Entries outside root are deliberately left alone. One Cache is shared by
// every account in a dashboard refresh, but a scan only ever builds a seen
// set for its own projects tree, so sweeping the whole map here would make
// every sibling account collateral damage of scanning one account. Roots
// that stop being scanned entirely are released by RetainRoots instead.
func (c *Cache) pruneScope(root string, seen map[string]struct{}) {
	if c == nil {
		return
	}
	prefix := rootPrefix(root)
	c.mu.Lock()
	defer c.mu.Unlock()
	for path := range c.entries {
		if !strings.HasPrefix(path, prefix) {
			continue
		}
		if _, ok := seen[path]; !ok {
			delete(c.entries, path)
		}
	}
}

// RetainRoots drops every cache entry that does not live under one of the
// given roots. Callers that scan a set of projects directories per refresh
// call this once afterwards with the roots they actually scanned, so an
// account that has gone away releases its sessions; scoped pruning alone
// would keep them for the process lifetime because nothing scans that tree
// any more. Passing no roots empties the cache.
func (c *Cache) RetainRoots(roots []string) {
	if c == nil {
		return
	}
	prefixes := make([]string, 0, len(roots))
	for _, root := range roots {
		prefixes = append(prefixes, rootPrefix(root))
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	for path := range c.entries {
		keep := false
		for _, prefix := range prefixes {
			if strings.HasPrefix(path, prefix) {
				keep = true
				break
			}
		}
		if !keep {
			delete(c.entries, path)
		}
	}
}

// rootPrefix returns root cleaned and terminated with a separator. The
// trailing separator is what stops a prefix test from matching a sibling
// whose name merely starts with the root: ".../projects" must not capture
// ".../projects-archive/x.jsonl". Cached paths come from filepath.Join
// during the walk, so they are already in this cleaned form.
func rootPrefix(root string) string {
	return filepath.Clean(root) + string(filepath.Separator)
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
// cache without re-reading the file. After the scan, cache entries under
// projectsDir for files no longer present on disk are pruned; entries
// belonging to other projects directories are left untouched so one cache
// can serve several accounts.
func ScanAccountSessionsWithCache(projectsDir string, cache *Cache) ([]Session, error) {
	var sessions []Session
	if _, err := os.Stat(projectsDir); err != nil {
		if os.IsNotExist(err) {
			// A tree that has disappeared has no live files, so everything
			// cached under it is stale. Scope the sweep to that tree only:
			// the caller may be mid-way through a refresh whose remaining
			// accounts still have valid entries in this same cache.
			cache.pruneScope(projectsDir, nil)
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
			// Same partial-result rule as the cached path below, minus the
			// caching, which has no fingerprint to key on here.
			s, parseErr := parseSessionFile(path)
			if parseErr != nil {
				s.Truncated = true
				if len(s.Entries) == 0 {
					return nil
				}
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
			// A scanner error is not the same thing as an unparseable file,
			// and this treated them the same: it dropped the whole session
			// and skipped the cache (#358, item 14).
			//
			// parseSessionFile returns the entries it decoded before the
			// failure alongside the error, and the usual cause -- one JSONL
			// line past the 10 MB scanner limit -- leaves every other line in
			// the file intact. Everything before the long line was thrown
			// away for the sake of the one line after it.
			//
			// Skipping the cache made it permanent rather than momentary:
			// nothing recorded that the file had been looked at, so the next
			// scan re-read it from the start and failed on the same line, at
			// the same cost, forever. Caching under the (size, mtime)
			// fingerprint is safe -- editing the file changes the fingerprint
			// and forces a re-read.
			s.Truncated = true
			if len(s.Entries) == 0 {
				// Nothing decoded at all: not worth a cache entry, and there
				// is no partial result to keep.
				return nil
			}
		}
		cache.put(path, size, modUnix, s)
		sessions = append(sessions, s)
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("walk projects dir: %w", err)
	}

	cache.pruneScope(projectsDir, seen)
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
