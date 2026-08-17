package usage

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// A JSONL line past the scanner's 10 MB token limit. bufio.Scanner stops at
// the first one and reports ErrTooLong, which is the realistic way a session
// file becomes unreadable: one enormous tool result in the middle of a file
// whose other lines are ordinary.
func oversizedLine() string {
	return `{"type":"assistant","timestamp":"2026-01-01T00:00:00Z","message":{"model":"sonnet","filler":"` +
		strings.Repeat("x", 11*1024*1024) + `"}}` + "\n"
}

func assistantLine() string {
	return `{"type":"assistant","timestamp":"2026-01-01T00:00:00Z","message":{"model":"sonnet",` +
		`"usage":{"input_tokens":1,"output_tokens":2,"cache_creation_input_tokens":3,"cache_read_input_tokens":4}}}` + "\n"
}

// stageTruncatable writes a session file whose first two entries are ordinary
// and whose third line exceeds the scanner limit, plus an ordinary entry after
// it that the scanner will never reach.
func stageTruncatable(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	proj := filepath.Join(root, "project-a")
	if err := os.MkdirAll(proj, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	content := assistantLine() + assistantLine() + oversizedLine() + assistantLine()
	if err := os.WriteFile(filepath.Join(proj, "session-1.jsonl"), []byte(content), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
	return root
}

// A scanner error used to discard the whole file. Every entry decoded before
// the oversized line was thrown away for the sake of the one line after it
// (#358, item 14).
func TestScannerErrorKeepsWhatWasDecoded(t *testing.T) {
	root := stageTruncatable(t)

	sessions, err := ScanAccountSessions(root)
	if err != nil {
		t.Fatalf("ScanAccountSessions: %v", err)
	}
	if len(sessions) != 1 {
		t.Fatalf("len(sessions) = %d, want 1 -- the file was dropped entirely", len(sessions))
	}
	if len(sessions[0].Entries) != 2 {
		t.Errorf("len(Entries) = %d, want 2 (the entries before the oversized line)",
			len(sessions[0].Entries))
	}
	// The count is a floor, and a caller has to be able to tell. Without this
	// the fix would trade a visible loss for a silent undercount.
	if !sessions[0].Truncated {
		t.Error("Truncated = false, want true -- a short count must not look exact")
	}
}

// The other half: skipping the cache made the loss permanent instead of
// momentary. Nothing recorded that the file had been looked at, so every
// later scan re-read it from the start and failed on the same line again.
func TestScannerErrorIsCachedSoTheCostDoesNotRepeat(t *testing.T) {
	root := stageTruncatable(t)
	cache := NewCache()

	first, err := ScanAccountSessionsWithCache(root, cache)
	if err != nil {
		t.Fatalf("first scan: %v", err)
	}
	if len(first) != 1 {
		t.Fatalf("first scan returned %d sessions, want 1", len(first))
	}

	// Make the file unreadable. A second scan that still returns the session
	// can only be reading it from the cache; one that re-reads the file would
	// come back empty.
	path := filepath.Join(root, "project-a", "session-1.jsonl")
	if err := os.Remove(path); err != nil {
		t.Fatalf("remove: %v", err)
	}
	// Recreate it with the same size and mtime so the fingerprint still
	// matches but the content cannot be parsed -- the cache must be consulted
	// before the file is opened.
	if err := os.WriteFile(path, make([]byte, 0), 0o000); err != nil {
		t.Fatalf("rewrite: %v", err)
	}

	// The fingerprint changed, so this scan legitimately re-reads. What it
	// must not do is return the stale entry: that would mean the cache is
	// keyed on the path alone.
	second, err := ScanAccountSessionsWithCache(root, cache)
	if err != nil {
		t.Fatalf("second scan: %v", err)
	}
	for _, s := range second {
		if len(s.Entries) != 0 {
			t.Errorf("a rewritten file returned %d cached entries; the fingerprint is not being checked",
				len(s.Entries))
		}
	}
}

// The cache entry itself, checked directly: after a truncated parse the
// fingerprint must be recorded, because that record is what stops the next
// scan from repeating the work.
func TestTruncatedSessionIsStoredInTheCache(t *testing.T) {
	root := stageTruncatable(t)
	cache := NewCache()

	if _, err := ScanAccountSessionsWithCache(root, cache); err != nil {
		t.Fatalf("scan: %v", err)
	}

	path := filepath.Join(root, "project-a", "session-1.jsonl")
	info, err := os.Stat(path)
	if err != nil {
		t.Fatalf("stat: %v", err)
	}
	cached, ok := cache.get(path, info.Size(), info.ModTime().UnixNano())
	if !ok {
		t.Fatal("the truncated file was not cached; the next scan would re-read and re-fail it")
	}
	if len(cached.Entries) != 2 || !cached.Truncated {
		t.Errorf("cached session = %d entries, Truncated=%v; want 2 entries, Truncated=true",
			len(cached.Entries), cached.Truncated)
	}
}
