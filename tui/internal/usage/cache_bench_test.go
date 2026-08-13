package usage

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// buildHistory writes fileCount JSONL files of linesPerFile assistant
// entries each into dir and returns dir. Content is identical across files
// because the cache keys on path/size/mtime, not on what was parsed.
func buildHistory(tb testing.TB, dir string, fileCount, linesPerFile int) string {
	tb.Helper()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		tb.Fatalf("mkdir %s: %v", dir, err)
	}
	body := []byte(strings.Repeat(asstLine, linesPerFile))
	for i := 0; i < fileCount; i++ {
		path := filepath.Join(dir, fmt.Sprintf("session-%04d.jsonl", i))
		if err := os.WriteFile(path, body, 0o644); err != nil {
			tb.Fatalf("write %s: %v", path, err)
		}
	}
	return dir
}

// BenchmarkAlternatingAccountScans measures the dashboard refresh pattern:
// two accounts scanned one after the other through a single shared cache,
// which is what buildAccounts does on every refresh.
//
// The cache=off arm is the no-cache baseline. The cache=on arm should stay
// roughly flat as history grows, because a refresh that changes nothing
// re-reads nothing. If per-account prune scoping regresses to a global
// sweep, the two accounts evict each other every round and cache=on
// collapses onto the cache=off numbers — that convergence, not any
// absolute figure, is the signal this benchmark exists to expose.
//
// Run with:
//
//	go test ./internal/usage -run '^$' -bench BenchmarkAlternatingAccountScans -benchmem
func BenchmarkAlternatingAccountScans(b *testing.B) {
	// 40 lines per file keeps each session small enough that walk and stat
	// cost stay visible; file count is what the history axis varies.
	const linesPerFile = 40

	for _, fileCount := range []int{20, 400} {
		root := b.TempDir()
		rootA := buildHistory(b, filepath.Join(root, "account-a", "projects"), fileCount, linesPerFile)
		rootB := buildHistory(b, filepath.Join(root, "account-b", "projects"), fileCount, linesPerFile)

		b.Run(fmt.Sprintf("files=%d/cache=off", fileCount), func(b *testing.B) {
			b.ReportAllocs()
			for b.Loop() {
				if _, err := ScanAccountSessions(rootA); err != nil {
					b.Fatalf("scan A: %v", err)
				}
				if _, err := ScanAccountSessions(rootB); err != nil {
					b.Fatalf("scan B: %v", err)
				}
			}
		})

		b.Run(fmt.Sprintf("files=%d/cache=on", fileCount), func(b *testing.B) {
			cache := NewCache()
			// Warm both trees so the loop measures steady-state refresh
			// rather than the one-time parse. b.Loop resets the timer on
			// its first call, so this setup is not charged to the result.
			for _, dir := range []string{rootA, rootB} {
				if _, err := ScanAccountSessionsWithCache(dir, cache); err != nil {
					b.Fatalf("warm %s: %v", dir, err)
				}
			}
			b.ReportAllocs()
			for b.Loop() {
				if _, err := ScanAccountSessionsWithCache(rootA, cache); err != nil {
					b.Fatalf("scan A: %v", err)
				}
				if _, err := ScanAccountSessionsWithCache(rootB, cache); err != nil {
					b.Fatalf("scan B: %v", err)
				}
			}
		})
	}
}
