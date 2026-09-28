package account

import (
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/kcenon/claude-docker/tui/internal/auth"
)

func sampleResponse() *auth.UsageAPIResponse {
	return &auth.UsageAPIResponse{
		FiveHour: &auth.UsageBucket{
			Utilization: 17,
			ResetsAt:    time.Now().Add(time.Hour).Format(time.RFC3339),
		},
		SevenDay: &auth.UsageBucket{
			Utilization: 63,
			ResetsAt:    time.Now().Add(48 * time.Hour).Format(time.RFC3339),
		},
	}
}

// TestLimitlineCacheIsWrittenOwnerOnly covers the permission half of #358
// item 5. The file describes an account's API usage and was 0644.
func TestLimitlineCacheIsWrittenOwnerOnly(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Unix mode bits are not meaningful against NTFS")
	}
	path := filepath.Join(t.TempDir(), "limitline-usage-cache.json")
	if err := writeLimitlineCache(path, sampleResponse()); err != nil {
		t.Fatalf("writeLimitlineCache: %v", err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatalf("stat: %v", err)
	}
	if perm := info.Mode().Perm(); perm != 0o600 {
		t.Errorf("mode = %04o, want 0600", perm)
	}
}

// TestLimitlineCacheLeavesNoTempFiles pins that the rename consumed the temp
// file. A leaked <name>.tmp-* per refresh would be the codex hooks.stale bug
// in a different directory.
func TestLimitlineCacheLeavesNoTempFiles(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "limitline-usage-cache.json")
	for i := 0; i < 3; i++ {
		if err := writeLimitlineCache(path, sampleResponse()); err != nil {
			t.Fatalf("writeLimitlineCache: %v", err)
		}
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("readdir: %v", err)
	}
	for _, e := range entries {
		if strings.Contains(e.Name(), ".tmp-") {
			t.Errorf("temp file left behind: %s", e.Name())
		}
	}
	if len(entries) != 1 {
		t.Errorf("expected exactly one file, got %d", len(entries))
	}
}

// TestWriteFileAtomicIsNeverPartiallyVisible is the atomicity claim (#358
// item 5). The host's claude-limitline tool writes the same path, so a reader
// can land between an os.WriteFile truncate and its write;
// parseLimitlineCache returns (nil, nil) for a truncated document and the
// dashboard draws "--" with nothing said about why.
//
// The payload is deliberately large. A real cache document is a few hundred
// bytes, which the kernel writes in one go, so the torn window is too small to
// observe and the same test against os.WriteFile passes -- proving nothing.
// At four megabytes the window is wide enough that a non-atomic writer is
// caught on the first round; the mutation run confirms it is.
//
// A writer and a reader run concurrently. Every read must see either nothing
// or a complete document, never a partial one.
func TestWriteFileAtomicIsNeverPartiallyVisible(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "big.json")

	// Valid JSON whose length makes the write observable.
	payload := []byte(`{"filler":"` + strings.Repeat("x", 4*1024*1024) + `"}`)

	const rounds = 20
	var wg sync.WaitGroup
	stop := make(chan struct{})
	var partial int
	var mu sync.Mutex

	wg.Add(1)
	go func() {
		defer wg.Done()
		for {
			select {
			case <-stop:
				return
			default:
			}
			data, err := os.ReadFile(path)
			if err != nil || len(data) == 0 {
				continue // not created yet
			}
			var probe map[string]any
			if err := json.Unmarshal(data, &probe); err != nil {
				mu.Lock()
				partial++
				mu.Unlock()
			}
		}
	}()

	for i := 0; i < rounds; i++ {
		if err := writeFileAtomic(path, payload); err != nil {
			t.Fatalf("writeFileAtomic: %v", err)
		}
	}
	close(stop)
	wg.Wait()

	mu.Lock()
	defer mu.Unlock()
	if partial != 0 {
		t.Errorf("%d reads saw a truncated document; the write is not atomic", partial)
	}
}

// TestLimitlineCacheIsNeverPartiallyVisible is the same check at the real
// call site and the real payload size. It cannot discriminate on its own --
// see the note above -- but it does confirm the cache writer routes through
// the atomic primitive and produces a document that parses every time.
func TestLimitlineCacheIsNeverPartiallyVisible(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "limitline-usage-cache.json")

	const rounds = 300
	var wg sync.WaitGroup
	stop := make(chan struct{})
	var partial int
	var mu sync.Mutex

	wg.Add(1)
	go func() {
		defer wg.Done()
		for {
			select {
			case <-stop:
				return
			default:
			}
			data, err := os.ReadFile(path)
			if err != nil || len(data) == 0 {
				continue // not created yet, or caught between rename calls
			}
			var probe map[string]any
			if err := json.Unmarshal(data, &probe); err != nil {
				mu.Lock()
				partial++
				mu.Unlock()
			}
		}
	}()

	for i := 0; i < rounds; i++ {
		if err := writeLimitlineCache(path, sampleResponse()); err != nil {
			t.Fatalf("writeLimitlineCache: %v", err)
		}
	}
	close(stop)
	wg.Wait()

	mu.Lock()
	defer mu.Unlock()
	if partial != 0 {
		t.Errorf("%d reads saw a truncated document; the write is not atomic", partial)
	}
}

// TestLimitlineCacheReportsAFailure covers the third part of item 5: the
// errors were discarded, so a read-only state directory produced no signal at
// all -- indistinguishable from a cache that is working.
func TestLimitlineCacheReportsAFailure(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("directory mode is not enforced the same way on Windows")
	}
	if os.Geteuid() == 0 {
		t.Skip("running as root; a read-only directory would not stop the write")
	}
	dir := t.TempDir()
	if err := os.Chmod(dir, 0o500); err != nil {
		t.Fatalf("chmod: %v", err)
	}
	t.Cleanup(func() { _ = os.Chmod(dir, 0o700) })

	err := writeLimitlineCache(filepath.Join(dir, "limitline-usage-cache.json"), sampleResponse())
	if err == nil {
		t.Fatal("a write into a read-only directory must be reported")
	}
}

// TestWriteCacheUpdatesSurfacesAFailure pins that the report reaches the
// per-account line the dashboard already renders, rather than stderr.
func TestWriteCacheUpdatesSurfacesAFailure(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("directory mode is not enforced the same way on Windows")
	}
	if os.Geteuid() == 0 {
		t.Skip("running as root; a read-only directory would not stop the write")
	}
	m := newTestManager(t, nil)

	dir := t.TempDir()
	if err := os.Chmod(dir, 0o500); err != nil {
		t.Fatalf("chmod: %v", err)
	}
	t.Cleanup(func() { _ = os.Chmod(dir, 0o700) })

	accounts := []Account{{Letter: "a", ServiceName: "claude-a", LastAPIStatus: "HTTP 200 (fresh)"}}
	m.writeCacheUpdates(accounts, map[string]apiResult{
		"a": {stateDirPath: dir, resp: sampleResponse()},
	})

	if !strings.Contains(accounts[0].LastAPIStatus, "cache write failed") {
		t.Errorf("LastAPIStatus = %q, expected it to mention the failed write", accounts[0].LastAPIStatus)
	}
}

// TestCooldownExpiry covers the in-memory replacement for .tui-api-cooldown
// and the expiry check that `r` used to skip (#358, items 5 and 10).
func TestCooldownExpiry(t *testing.T) {
	c := newAPICooldowns()

	if c.active("a") {
		t.Error("a letter that was never recorded must not be in cooldown")
	}

	c.record("a")
	if !c.active("a") {
		t.Error("a just-recorded letter must be in cooldown")
	}
	if c.active("b") {
		t.Error("the cooldown is per account")
	}

	// clearExpired must leave a live cooldown alone. This is the defect seen
	// from update.go as item 10: `r` cleared everything unconditionally, so
	// the 25s backoff after a 429 existed but any keypress skipped it and
	// re-issued the call the 429 was telling us to stop making.
	c.clearExpired()
	if !c.active("a") {
		t.Error("clearExpired must not drop a cooldown that has not expired")
	}

	// Age it past the window.
	c.mu.Lock()
	c.at["a"] = time.Now().Add(-apiCooldownDuration - time.Second)
	c.mu.Unlock()

	if c.active("a") {
		t.Error("an aged-out cooldown must not report active")
	}
	c.clearExpired()
	c.mu.Lock()
	_, present := c.at["a"]
	c.mu.Unlock()
	if present {
		t.Error("clearExpired must drop an expired entry")
	}
}

// TestClearAPICooldownsKeepsLiveEntries is the Manager-level statement of the
// same rule, since that is what the `r` handler calls.
func TestClearAPICooldownsKeepsLiveEntries(t *testing.T) {
	m := newTestManager(t, nil)
	m.cooldowns.record("a")

	m.ClearAPICooldowns()

	if !m.cooldowns.active("a") {
		t.Error("pressing r must not clear a cooldown recorded a moment ago")
	}
}

// TestCooldownIsRuntimeAgnostic covers item 11 from the other side: the file
// implementation scanned the claude state directories with a hardcoded
// RuntimeClaude, so a codex or gemini install cleared nothing. Keyed by
// letter in manager-scoped memory, there is no runtime in the path at all.
func TestCooldownIsRuntimeAgnostic(t *testing.T) {
	m := newTestManager(t, nil)
	m.cooldowns.record("a")

	m.cooldowns.mu.Lock()
	m.cooldowns.at["a"] = time.Now().Add(-apiCooldownDuration - time.Second)
	m.cooldowns.mu.Unlock()

	m.ClearAPICooldowns()

	m.cooldowns.mu.Lock()
	n := len(m.cooldowns.at)
	m.cooldowns.mu.Unlock()
	if n != 0 {
		t.Errorf("expected the expired entry to be cleared regardless of runtime, %d left", n)
	}
}
