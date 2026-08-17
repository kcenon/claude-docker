package account

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// The retry loop is here for a Windows-only failure, so a test that could only
// run on Windows would leave it unexercised in CI. These inject the rename
// instead, which pins the decision the loop makes -- retry this error, do not
// retry that one -- on every platform.

// A sharing violation surfaces as a permission error; that classification is
// what the loop gates on, and it was measured before the gate was written.
func TestRenameRetriesUntilThePermissionErrorClears(t *testing.T) {
	remaining := 5
	calls := 0
	err := renameRetryingSharingViolation(func() error {
		calls++
		if remaining > 0 {
			remaining--
			return &os.LinkError{Op: "rename", Err: fs.ErrPermission}
		}
		return nil
	})
	if err != nil {
		t.Fatalf("renameRetryingSharingViolation: %v, want nil once the error clears", err)
	}
	if calls != 6 {
		t.Errorf("rename called %d times, want 6 (five denials then a success)", calls)
	}
}

// A rename that succeeds outright must not pay for the retry machinery.
func TestRenameDoesNotRetryOnSuccess(t *testing.T) {
	calls := 0
	start := time.Now()
	if err := renameRetryingSharingViolation(func() error { calls++; return nil }); err != nil {
		t.Fatalf("err = %v, want nil", err)
	}
	if calls != 1 {
		t.Errorf("rename called %d times, want 1", calls)
	}
	if elapsed := time.Since(start); elapsed > renameRetryPause {
		t.Errorf("a successful rename slept for %v; the retry path should not be entered", elapsed)
	}
}

// The point of gating on the error rather than retrying everything: an error
// no amount of waiting can fix has to come back immediately, and unchanged.
func TestRenameDoesNotRetryOtherErrors(t *testing.T) {
	sentinel := errors.New("cross-device link")
	calls := 0
	start := time.Now()
	err := renameRetryingSharingViolation(func() error { calls++; return sentinel })
	if !errors.Is(err, sentinel) {
		t.Errorf("err = %v, want the original error unwrapped to sentinel", err)
	}
	if calls != 1 {
		t.Errorf("rename called %d times, want 1", calls)
	}
	if elapsed := time.Since(start); elapsed > renameRetryPause {
		t.Errorf("a non-retryable error slept for %v", elapsed)
	}
}

// An error that never clears must still terminate, and the message has to say
// that retrying happened -- otherwise it reads exactly like a single failed
// attempt and a momentary collision cannot be told from a file that is
// permanently unwritable.
func TestRenameGivesUpAndSaysSo(t *testing.T) {
	calls := 0
	start := time.Now()
	err := renameRetryingSharingViolation(func() error {
		calls++
		return &os.LinkError{Op: "rename", Err: fs.ErrPermission}
	})
	elapsed := time.Since(start)

	if err == nil {
		t.Fatal("err = nil, want a failure after the budget is spent")
	}
	if !errors.Is(err, fs.ErrPermission) {
		t.Errorf("err = %v, want it to still unwrap to a permission error", err)
	}
	if got := err.Error(); !strings.Contains(got, "retrying") {
		t.Errorf("err = %q, want it to mention that retrying happened", got)
	}
	if elapsed < renameRetryBudget {
		t.Errorf("gave up after %v, before the %v budget", elapsed, renameRetryBudget)
	}
	if elapsed > renameRetryBudget*2 {
		t.Errorf("took %v, far past the %v budget", elapsed, renameRetryBudget)
	}
	if calls < 2 {
		t.Errorf("rename called %d times; the loop did not run", calls)
	}
}

// The primitive still has to work end to end, with the real os.Rename behind
// it: the injected tests above would pass against a loop that was never wired
// into writeFileAtomic.
func TestWriteFileAtomicStillWritesThroughTheRetryPath(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "state.json")
	want := []byte(`{"ok":true}`)

	if err := writeFileAtomic(path, want); err != nil {
		t.Fatalf("writeFileAtomic: %v", err)
	}
	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read back: %v", err)
	}
	if string(got) != string(want) {
		t.Errorf("content = %q, want %q", got, want)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatalf("stat: %v", err)
	}
	// 0600 on POSIX; Windows reports 0666 for a writable file and the mode
	// bits are not the thing under test there.
	if perm := info.Mode().Perm(); perm&0o077 != 0 && !windowsPerms(perm) {
		t.Errorf("mode = %o, want owner-only", perm)
	}
	// No temp file may survive a successful write.
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("readdir: %v", err)
	}
	if len(entries) != 1 {
		names := make([]string, 0, len(entries))
		for _, e := range entries {
			names = append(names, e.Name())
		}
		t.Errorf("directory holds %v, want only state.json", names)
	}
}

// Windows does not model POSIX permission bits; os.Stat reports 0666 for any
// writable file regardless of the chmod that preceded it.
func windowsPerms(p fs.FileMode) bool { return p == 0o666 }
