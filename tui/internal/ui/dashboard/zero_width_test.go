package dashboard

import (
	"errors"
	"path/filepath"
	"strings"
	"testing"

	"github.com/kcenon/claude-docker/tui/internal/account"
	"github.com/kcenon/claude-docker/tui/internal/config"
)

// TestRuleWidth states the clamp directly (#358, item 4). 76 is the width of
// the six header columns and 4 is the indent on each side, so the interesting
// values are the ones where width-4 goes negative.
func TestRuleWidth(t *testing.T) {
	cases := []struct {
		width int
		want  int
	}{
		{0, 0},   // never sized: strings.Repeat panicked on -4
		{1, 0},   // still negative
		{4, 0},   // exactly the margin
		{5, 1},   // first positive
		{40, 36}, // narrow terminal, rule shrinks with it
		{80, 76}, // the cap
		{200, 76},
		{-10, 0}, // defensive: a width no caller should produce
	}
	for _, tc := range cases {
		if got := ruleWidth(tc.width); got != tc.want {
			t.Errorf("ruleWidth(%d) = %d, want %d", tc.width, got, tc.want)
		}
	}
}

// TestViewAtZeroWidthDoesNotPanic is the acceptance criterion: View() with
// accounts loaded and no SetSize must return.
//
// The path is real, not theoretical. bubbletea v1.3.10 returns early from
// checkResize when p.ttyOutput is nil (tty.go:121-125), so a non-TTY stdout --
// `claude-docker-tui | tee log.txt` -- never delivers a WindowSizeMsg and the
// model keeps the zero width it was constructed with.
//
// render_test.go used to work around this with a pre-emptive SetSize before
// starting the program, with a comment saying why; that workaround is gone.
func TestViewAtZeroWidthDoesNotPanic(t *testing.T) {
	env := config.NewEmptyEnv(filepath.Join(t.TempDir(), ".env"))

	m := New(nil, nil, env, false)
	m.loading = false
	m.accounts = []account.Account{
		{Letter: "a", ServiceName: "claude-a", ContainerStatus: account.ContainerRunning, ContainerID: "abc"},
		{Letter: "b", ServiceName: "claude-b"},
	}

	if m.width != 0 {
		t.Fatalf("precondition: width should be 0, got %d", m.width)
	}

	out := m.View() // panicked here before the clamp
	if !strings.Contains(out, "claude-a") {
		t.Errorf("the table should still render its rows at width 0:\n%s", out)
	}
}

// TestViewAtZeroWidthWithStatusDetail exercises the branch that also draws the
// per-account API status lines, since those are appended after the table.
func TestViewAtZeroWidthWithStatusDetail(t *testing.T) {
	env := config.NewEmptyEnv(filepath.Join(t.TempDir(), ".env"))

	m := New(nil, nil, env, false)
	m.loading = false
	m.refreshing = true
	m.accounts = []account.Account{
		{Letter: "a", ServiceName: "claude-a", APIRateLimited: true, LastAPIStatus: "HTTP 429 (rate limited)"},
	}

	out := m.View()
	if !strings.Contains(out, "HTTP 429") {
		t.Errorf("expected the API status line:\n%s", out)
	}
}

// TestRefreshCompletionClearsRefreshing is the second half of the item 1
// acceptance criterion: once ListAccounts returns, the dashboard has to be
// usable again. The timeout makes the message arrive; this is what the
// message does when it does.
func TestRefreshCompletionClearsRefreshing(t *testing.T) {
	env := config.NewEmptyEnv(filepath.Join(t.TempDir(), ".env"))

	m := New(nil, nil, env, false)
	m.refreshing = true
	m.loading = true

	m, _ = m.Update(accountsLoadedMsg{
		accounts: []account.Account{{Letter: "a", ServiceName: "claude-a"}},
	})

	if m.refreshing {
		t.Error("refreshing should clear when the load completes")
	}
	if m.loading {
		t.Error("loading should clear when the load completes")
	}
}

// TestErrorFromRefreshReachesTheModel guards the degradation path the timeout
// opened up: PS now returns a deadline error instead of hanging, and that
// error has to be visible rather than swallowed into an empty table.
func TestErrorFromRefreshReachesTheModel(t *testing.T) {
	env := config.NewEmptyEnv(filepath.Join(t.TempDir(), ".env"))

	m := New(nil, nil, env, false)
	m.loading = true

	m, _ = m.Update(accountsLoadedMsg{err: errors.New("docker compose ps timed out after 10s")})

	out := m.View()
	if !strings.Contains(out, "timed out") {
		t.Errorf("the deadline should reach the screen:\n%s", out)
	}
}
