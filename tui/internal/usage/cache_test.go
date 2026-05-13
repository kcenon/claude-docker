package usage

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

const asstLine = `{"type":"assistant","timestamp":"2026-01-01T00:00:00Z","message":{"model":"sonnet","usage":{"input_tokens":1,"output_tokens":2,"cache_creation_input_tokens":3,"cache_read_input_tokens":4}}}` + "\n"

// writeJSONL is a helper that writes a single-line JSONL file containing
// one assistant entry and returns its absolute path.
func writeJSONL(t *testing.T, dir, name string) string {
	t.Helper()
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, []byte(asstLine), 0o644); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
	return path
}

// TestCacheReusesUnchangedFiles verifies that a second scan with the
// same cache reuses parsed sessions for unchanged files (size+mtime
// match), so parseSessionFile is not invoked again.
func TestCacheReusesUnchangedFiles(t *testing.T) {
	root := t.TempDir()
	proj := filepath.Join(root, "project-a")
	if err := os.MkdirAll(proj, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	writeJSONL(t, proj, "a.jsonl")
	writeJSONL(t, proj, "b.jsonl")

	cache := NewCache()
	first, err := ScanAccountSessionsWithCache(root, cache)
	if err != nil {
		t.Fatalf("first scan: %v", err)
	}
	if len(first) != 2 {
		t.Fatalf("first scan len = %d, want 2", len(first))
	}
	if cache.Len() != 2 {
		t.Errorf("cache.Len after first scan = %d, want 2", cache.Len())
	}

	// Capture a stable identity reference to the cached Session value.
	// On reuse the cache returns the same Entries slice by value, but the
	// underlying array header should be identical because we round-trip
	// the stored cacheEntry.
	firstByPath := make(map[string]*SessionEntry, len(first))
	for i := range first {
		if len(first[i].Entries) > 0 {
			firstByPath[first[i].Path] = &first[i].Entries[0]
		}
	}

	second, err := ScanAccountSessionsWithCache(root, cache)
	if err != nil {
		t.Fatalf("second scan: %v", err)
	}
	if len(second) != 2 {
		t.Fatalf("second scan len = %d, want 2", len(second))
	}
	for i := range second {
		ent0, ok := firstByPath[second[i].Path]
		if !ok {
			t.Errorf("second scan returned unexpected path %q", second[i].Path)
			continue
		}
		if len(second[i].Entries) == 0 {
			t.Errorf("second scan: %q has no entries", second[i].Path)
			continue
		}
		// Reused entry slice should point at the same underlying array as
		// the first scan; if it had been reparsed we would have a new slice.
		if &second[i].Entries[0] != ent0 {
			t.Errorf("second scan: %q was reparsed (entry slice differs)", second[i].Path)
		}
	}
}

// TestCacheReparsesOnMtimeChange verifies that when a file's mtime
// changes, the cache discards the stale entry and reparses.
func TestCacheReparsesOnMtimeChange(t *testing.T) {
	root := t.TempDir()
	proj := filepath.Join(root, "project-a")
	if err := os.MkdirAll(proj, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	path := writeJSONL(t, proj, "a.jsonl")

	cache := NewCache()
	if _, err := ScanAccountSessionsWithCache(root, cache); err != nil {
		t.Fatalf("first scan: %v", err)
	}

	// Capture the cached entry slice header for later identity comparison.
	firstSessions, _ := ScanAccountSessionsWithCache(root, cache)
	var firstEntryPtr *SessionEntry
	for i := range firstSessions {
		if firstSessions[i].Path == path && len(firstSessions[i].Entries) > 0 {
			firstEntryPtr = &firstSessions[i].Entries[0]
			break
		}
	}
	if firstEntryPtr == nil {
		t.Fatalf("did not find cached entry for %q", path)
	}

	// Bump mtime forward by one second to invalidate the fingerprint.
	future := time.Now().Add(2 * time.Second)
	if err := os.Chtimes(path, future, future); err != nil {
		t.Fatalf("chtimes: %v", err)
	}

	third, err := ScanAccountSessionsWithCache(root, cache)
	if err != nil {
		t.Fatalf("third scan: %v", err)
	}
	for i := range third {
		if third[i].Path != path {
			continue
		}
		if len(third[i].Entries) == 0 {
			t.Fatalf("reparsed session has no entries")
		}
		if &third[i].Entries[0] == firstEntryPtr {
			t.Errorf("entry slice was reused despite mtime change; want reparse")
		}
	}
}

// TestCacheReparsesOnSizeChange verifies that appending to a file (size
// change) invalidates the cached entry even if mtime resolution would
// not differ.
func TestCacheReparsesOnSizeChange(t *testing.T) {
	root := t.TempDir()
	proj := filepath.Join(root, "project-a")
	if err := os.MkdirAll(proj, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	path := writeJSONL(t, proj, "a.jsonl")

	cache := NewCache()
	first, err := ScanAccountSessionsWithCache(root, cache)
	if err != nil {
		t.Fatalf("first scan: %v", err)
	}
	if got := len(first[0].Entries); got != 1 {
		t.Fatalf("first scan entries = %d, want 1", got)
	}

	// Append a second assistant line so file size changes.
	f, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		t.Fatalf("open append: %v", err)
	}
	if _, err := f.WriteString(asstLine); err != nil {
		t.Fatalf("append: %v", err)
	}
	f.Close()

	second, err := ScanAccountSessionsWithCache(root, cache)
	if err != nil {
		t.Fatalf("second scan: %v", err)
	}
	if got := len(second[0].Entries); got != 2 {
		t.Errorf("second scan entries = %d, want 2 (size change should trigger reparse)", got)
	}
}

// TestCachePrunesDeletedFiles verifies that a file removed between
// scans is dropped from the cache so memory does not grow unbounded.
func TestCachePrunesDeletedFiles(t *testing.T) {
	root := t.TempDir()
	proj := filepath.Join(root, "project-a")
	if err := os.MkdirAll(proj, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	pathA := writeJSONL(t, proj, "a.jsonl")
	writeJSONL(t, proj, "b.jsonl")

	cache := NewCache()
	if _, err := ScanAccountSessionsWithCache(root, cache); err != nil {
		t.Fatalf("first scan: %v", err)
	}
	if cache.Len() != 2 {
		t.Fatalf("cache.Len after first scan = %d, want 2", cache.Len())
	}

	if err := os.Remove(pathA); err != nil {
		t.Fatalf("remove: %v", err)
	}
	if _, err := ScanAccountSessionsWithCache(root, cache); err != nil {
		t.Fatalf("second scan: %v", err)
	}
	if cache.Len() != 1 {
		t.Errorf("cache.Len after delete = %d, want 1 (deleted file should be pruned)", cache.Len())
	}
}

// TestNilCacheParsesEveryTime guarantees the wrapper without a cache
// still works (preserves existing ScanAccountSessions behavior).
func TestNilCacheParsesEveryTime(t *testing.T) {
	root := t.TempDir()
	proj := filepath.Join(root, "project-a")
	if err := os.MkdirAll(proj, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	writeJSONL(t, proj, "a.jsonl")

	first, err := ScanAccountSessions(root)
	if err != nil {
		t.Fatalf("first scan: %v", err)
	}
	second, err := ScanAccountSessions(root)
	if err != nil {
		t.Fatalf("second scan: %v", err)
	}
	if len(first) != 1 || len(second) != 1 {
		t.Fatalf("scan lens = %d, %d; want 1, 1", len(first), len(second))
	}
	if len(first[0].Entries) == 0 || len(second[0].Entries) == 0 {
		t.Fatalf("scans produced empty entries")
	}
	// Without a shared cache the two slices must come from independent parses.
	if &first[0].Entries[0] == &second[0].Entries[0] {
		t.Errorf("nil-cache scans reused entry slice; want independent parses")
	}
}

// TestCacheMissingDirReturnsNil verifies that a missing projects dir
// is not an error and pruning still empties the cache so callers that
// switch state directories do not leak stale entries.
func TestCacheMissingDirReturnsNil(t *testing.T) {
	cache := NewCache()
	// Pre-seed cache so prune has something to do.
	cache.put("/non/existent/seed.jsonl", 1, 2, Session{Path: "/non/existent/seed.jsonl"})
	if cache.Len() != 1 {
		t.Fatalf("seed Len = %d, want 1", cache.Len())
	}

	got, err := ScanAccountSessionsWithCache(filepath.Join(t.TempDir(), "does-not-exist"), cache)
	if err != nil {
		t.Fatalf("scan missing dir: err = %v, want nil", err)
	}
	if got != nil {
		t.Errorf("scan missing dir sessions = %v, want nil", got)
	}
	if cache.Len() != 0 {
		t.Errorf("cache.Len after missing-dir scan = %d, want 0", cache.Len())
	}
}
