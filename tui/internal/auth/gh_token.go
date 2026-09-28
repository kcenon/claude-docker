package auth

import (
	"bytes"
	"context"
	"fmt"
	"os/exec"
	"strings"
	"time"
)

// ghTimeout bounds both host `gh` invocations (#358, item 2).
//
// `gh auth status` contacts github.com, and both calls may consult an OS
// credential store -- macOS Keychain and Windows Credential Manager can each
// block on a UI prompt that never appears when the dashboard owns the
// terminal. startGHAuth sets m.busy before dispatching and update.go rejects
// every key while it is set, so a hang here leaves the dashboard responding
// only to quit, with nothing on screen explaining why.
//
// A package-level var rather than a const so tests can shorten it. Unexported,
// so only this package can; the tests that do are not parallel.
var ghTimeout = 15 * time.Second

// ghKillGrace is the window between killing a timed-out `gh` and abandoning
// its output pipes, so a child that outlives the kill cannot hold Run() or
// Output() open past the deadline.
const ghKillGrace = 2 * time.Second

// HostGHToken returns the GitHub token from the host's gh CLI. A non-empty
// user selects that stored github.com account explicitly without changing the
// active host account. An empty user preserves the legacy active-account flow.
//
// Both invocations are bounded; a deadline is reported as a timeout rather
// than as an authentication failure, because the two call for different fixes.
func HostGHToken(user string) (string, error) {
	if _, err := exec.LookPath("gh"); err != nil {
		return "", fmt.Errorf("gh CLI not found on host (install via https://cli.github.com)")
	}

	if user == "" {
		var stderr bytes.Buffer
		ctx, cancel := context.WithTimeout(context.Background(), ghTimeout)
		defer cancel()
		check := exec.CommandContext(ctx, "gh", "auth", "status")
		check.WaitDelay = ghKillGrace
		check.Stderr = &stderr
		if err := check.Run(); err != nil {
			if ctx.Err() == context.DeadlineExceeded {
				return "", fmt.Errorf("gh auth status timed out after %s", ghTimeout)
			}
			msg := strings.TrimSpace(stderr.String())
			if msg == "" {
				msg = err.Error()
			}
			return "", fmt.Errorf("gh not authenticated: %s", msg)
		}
	}

	tokenCtx, tokenCancel := context.WithTimeout(context.Background(), ghTimeout)
	defer tokenCancel()
	args := ghTokenArgs(user)
	tokenCmd := exec.CommandContext(tokenCtx, "gh", args...)
	tokenCmd.WaitDelay = ghKillGrace
	out, err := tokenCmd.Output()
	if err != nil {
		if tokenCtx.Err() == context.DeadlineExceeded {
			return "", fmt.Errorf("gh auth token timed out after %s", ghTimeout)
		}
		return "", fmt.Errorf("gh auth token: %w", err)
	}
	token := strings.TrimSpace(string(out))
	if token == "" {
		return "", fmt.Errorf("gh returned empty token")
	}
	return token, nil
}

func ghTokenArgs(user string) []string {
	args := []string{"auth", "token"}
	if user != "" {
		args = append(args, "--hostname", "github.com", "--user", user)
	}
	return args
}
