package usage

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

// TestAllTimeOptions verifies the all-time option set has no time bound,
// so AggregateSessions counts every entry regardless of timestamp.
func TestAllTimeOptions(t *testing.T) {
	opts := AllTimeOptions()
	if opts.Since != nil {
		t.Errorf("AllTimeOptions().Since = %v, want nil", opts.Since)
	}
}

// TestDailyOptions is gone with DailyOptions itself (#358, item 13). It
// asserted the machine-local midnight the body computed, not the KST midnight
// the doc comment promised -- so it agreed with the code and could never have
// reported the discrepancy.

// makeEntry builds a SessionEntry with the supplied token counts and timestamp.
func makeEntry(input, output, cacheCreate, cacheRead int64, ts string) SessionEntry {
	var e SessionEntry
	e.Type = "assistant"
	e.Timestamp = ts
	e.Message.Usage.InputTokens = input
	e.Message.Usage.OutputTokens = output
	e.Message.Usage.CacheCreationInputTokens = cacheCreate
	e.Message.Usage.CacheReadInputTokens = cacheRead
	return e
}

// TestAggregateSessions covers empty input, a single session, multiple
// sessions, and the time-based filter via AggregateOptions.Since.
func TestAggregateSessions(t *testing.T) {
	now := time.Now().UTC()
	old := now.Add(-48 * time.Hour).Format(time.RFC3339)
	recent := now.Format(time.RFC3339)
	since := now.Add(-1 * time.Hour)

	cases := []struct {
		name     string
		sessions []Session
		opts     AggregateOptions
		want     TokenTotals
	}{
		{
			name:     "empty input",
			sessions: nil,
			opts:     AllTimeOptions(),
			want:     TokenTotals{},
		},
		{
			name: "single session, all-time",
			sessions: []Session{
				{Entries: []SessionEntry{
					makeEntry(10, 20, 30, 40, recent),
				}},
			},
			opts: AllTimeOptions(),
			want: TokenTotals{InputTokens: 10, OutputTokens: 20, CacheCreationInputTokens: 30, CacheReadInputTokens: 40},
		},
		{
			name: "multiple sessions sum",
			sessions: []Session{
				{Entries: []SessionEntry{
					makeEntry(1, 2, 3, 4, recent),
					makeEntry(10, 20, 30, 40, recent),
				}},
				{Entries: []SessionEntry{
					makeEntry(100, 200, 300, 400, recent),
				}},
			},
			opts: AllTimeOptions(),
			want: TokenTotals{InputTokens: 111, OutputTokens: 222, CacheCreationInputTokens: 333, CacheReadInputTokens: 444},
		},
		{
			name: "since filter excludes old entries",
			sessions: []Session{
				{Entries: []SessionEntry{
					makeEntry(1000, 1000, 1000, 1000, old),
					makeEntry(5, 5, 5, 5, recent),
				}},
			},
			opts: AggregateOptions{Since: &since},
			want: TokenTotals{InputTokens: 5, OutputTokens: 5, CacheCreationInputTokens: 5, CacheReadInputTokens: 5},
		},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := AggregateSessions(c.sessions, c.opts)
			if got != c.want {
				t.Errorf("AggregateSessions = %+v, want %+v", got, c.want)
			}
		})
	}
}

// TestCountFilteredSessions verifies that a session is counted at most once
// regardless of how many entries it contains, and that the Since filter
// excludes sessions whose every entry is older than the cutoff.
func TestCountFilteredSessions(t *testing.T) {
	now := time.Now().UTC()
	old := now.Add(-48 * time.Hour).Format(time.RFC3339)
	recent := now.Format(time.RFC3339)
	since := now.Add(-1 * time.Hour)

	sessions := []Session{
		// Session 1: only old entries — excluded by Since filter
		{Entries: []SessionEntry{makeEntry(1, 1, 1, 1, old)}},
		// Session 2: at least one recent entry — counted once
		{Entries: []SessionEntry{
			makeEntry(1, 1, 1, 1, old),
			makeEntry(2, 2, 2, 2, recent),
		}},
		// Session 3: entirely recent — counted once
		{Entries: []SessionEntry{makeEntry(3, 3, 3, 3, recent)}},
	}

	if n := CountFilteredSessions(sessions, AllTimeOptions()); n != 3 {
		t.Errorf("all-time: CountFilteredSessions = %d, want 3", n)
	}
	if n := CountFilteredSessions(sessions, AggregateOptions{Since: &since}); n != 2 {
		t.Errorf("since filter: CountFilteredSessions = %d, want 2", n)
	}
	if n := CountFilteredSessions(nil, AllTimeOptions()); n != 0 {
		t.Errorf("empty input: CountFilteredSessions = %d, want 0", n)
	}
}

// TestScanAccountSessions writes a few JSONL files (and some non-JSONL
// noise) into a t.TempDir, then verifies ScanAccountSessions returns the
// expected number of sessions and skips non-.jsonl files. A missing
// projects directory must NOT be an error — the function returns nil.
func TestScanAccountSessions(t *testing.T) {
	// Missing directory: no error, no sessions.
	missing := filepath.Join(t.TempDir(), "does-not-exist")
	got, err := ScanAccountSessions(missing)
	if err != nil {
		t.Fatalf("ScanAccountSessions(missing): err = %v, want nil", err)
	}
	if got != nil {
		t.Errorf("ScanAccountSessions(missing) = %v, want nil", got)
	}

	// Real directory tree with two .jsonl files in nested dirs and one
	// non-.jsonl file that must be skipped.
	root := t.TempDir()
	projA := filepath.Join(root, "project-a")
	projB := filepath.Join(root, "project-b")
	for _, d := range []string{projA, projB} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatalf("mkdir %s: %v", d, err)
		}
	}

	// One assistant entry per file; parser keeps only type="assistant".
	asst := `{"type":"assistant","timestamp":"2026-01-01T00:00:00Z","message":{"model":"sonnet","usage":{"input_tokens":1,"output_tokens":2,"cache_creation_input_tokens":3,"cache_read_input_tokens":4}}}` + "\n"
	user := `{"type":"user","timestamp":"2026-01-01T00:00:00Z"}` + "\n"

	files := map[string]string{
		filepath.Join(projA, "session-1.jsonl"): asst + user,
		filepath.Join(projB, "session-2.jsonl"): asst,
		filepath.Join(projB, "ignored.txt"):     "not jsonl",
	}
	for path, content := range files {
		if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
			t.Fatalf("write %s: %v", path, err)
		}
	}

	sessions, err := ScanAccountSessions(root)
	if err != nil {
		t.Fatalf("ScanAccountSessions: %v", err)
	}
	if len(sessions) != 2 {
		t.Fatalf("len(sessions) = %d, want 2", len(sessions))
	}
	totalEntries := 0
	for _, s := range sessions {
		totalEntries += len(s.Entries)
	}
	// Only assistant entries are kept by the parser; 2 files * 1 assistant = 2.
	if totalEntries != 2 {
		t.Errorf("total assistant entries = %d, want 2", totalEntries)
	}
}
