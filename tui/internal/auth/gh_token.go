package auth

import (
	"bytes"
	"fmt"
	"os/exec"
	"strings"
)

// HostGHToken returns the GitHub token from the host's gh CLI. A non-empty
// user selects that stored github.com account explicitly without changing the
// active host account. An empty user preserves the legacy active-account flow.
func HostGHToken(user string) (string, error) {
	if _, err := exec.LookPath("gh"); err != nil {
		return "", fmt.Errorf("gh CLI not found on host (install via https://cli.github.com)")
	}

	if user == "" {
		var stderr bytes.Buffer
		check := exec.Command("gh", "auth", "status")
		check.Stderr = &stderr
		if err := check.Run(); err != nil {
			msg := strings.TrimSpace(stderr.String())
			if msg == "" {
				msg = err.Error()
			}
			return "", fmt.Errorf("gh not authenticated: %s", msg)
		}
	}

	args := ghTokenArgs(user)
	out, err := exec.Command("gh", args...).Output()
	if err != nil {
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
