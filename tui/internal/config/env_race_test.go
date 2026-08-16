package config

import (
	"fmt"
	"path/filepath"
	"sync"
	"testing"
)

// TestEnvConcurrentSetGet drives the collision the TUI hits in normal use
// (issue #351).
//
// One *Env is created in main and shared for the process' lifetime, and
// bubbletea runs every Cmd on its own goroutine. The gh-auth Cmd calls Set
// while the event loop renders through Get and the refresh Cmd reads
// NUM_ACCOUNTS -- three goroutines on one map.
//
// Each Set here uses a *new* key so it takes the append branch, which is the
// one that writes the map. That is not an artificial choice: per-account auth
// made the key GH_TOKEN_<LETTER>, so every account's first gh-auth press
// appends, and .env.example ships the token keys commented out, which LoadEnv
// does not index -- so even shared mode appends on the first press.
//
// Unsynchronized this is `fatal error: concurrent map read and map write`, not
// a recoverable panic: bubbletea's recoverFromPanic never runs, so the process
// dies with a raw stack dump and leaves the terminal in altscreen.
//
// This test only means something under `go test -race`, which the go-test CI
// job now passes. Without it a scheduling accident can let the run pass.
func TestEnvConcurrentSetGet(t *testing.T) {
	env := NewEmptyEnv(filepath.Join(t.TempDir(), ".env"))
	env.Set("NUM_ACCOUNTS", "2")
	env.Set("AGENT_RUNTIME", "claude")

	const iterations = 200
	var wg sync.WaitGroup

	// The gh-auth Cmd: a new token key per account.
	wg.Add(1)
	go func() {
		defer wg.Done()
		for i := 0; i < iterations; i++ {
			env.Set(fmt.Sprintf("GH_TOKEN_%d", i), "placeholder-not-a-token")
		}
	}()

	// The event loop: renderIsolationBanner and App.View on every message.
	wg.Add(1)
	go func() {
		defer wg.Done()
		for i := 0; i < iterations; i++ {
			_ = env.IsolationMode()
			_ = env.Get("PROJECT_DIR_A")
		}
	}()

	// The refresh Cmd: ListAccounts, on a third goroutine.
	wg.Add(1)
	go func() {
		defer wg.Done()
		for i := 0; i < iterations; i++ {
			_ = env.NumAccounts()
			_ = env.AgentRuntime()
		}
	}()

	wg.Wait()

	// The lock has to preserve the data, not just the memory model.
	if got := env.Get("NUM_ACCOUNTS"); got != "2" {
		t.Errorf("NUM_ACCOUNTS = %q after concurrent writes, want %q", got, "2")
	}
	for i := 0; i < iterations; i++ {
		key := fmt.Sprintf("GH_TOKEN_%d", i)
		if got := env.Get(key); got != "placeholder-not-a-token" {
			t.Fatalf("%s = %q, want the written value; an append was lost", key, got)
		}
	}
}

// TestEnvConcurrentSaveAndGet covers the other direction: Save snapshots the
// entries and then writes to disk without holding the lock, so a reader must
// not be blocked by the write and must not observe a torn slice.
func TestEnvConcurrentSaveAndGet(t *testing.T) {
	env := NewEmptyEnv(filepath.Join(t.TempDir(), ".env"))
	env.Set("NUM_ACCOUNTS", "2")

	const iterations = 50
	var wg sync.WaitGroup

	wg.Add(1)
	go func() {
		defer wg.Done()
		for i := 0; i < iterations; i++ {
			if err := env.Save(); err != nil {
				t.Errorf("Save: %v", err)
				return
			}
		}
	}()

	wg.Add(1)
	go func() {
		defer wg.Done()
		for i := 0; i < iterations; i++ {
			env.Set(fmt.Sprintf("GH_TOKEN_%d", i), "placeholder-not-a-token")
			_ = env.Get("NUM_ACCOUNTS")
		}
	}()

	wg.Wait()
}
