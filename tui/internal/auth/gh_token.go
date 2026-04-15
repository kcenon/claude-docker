package auth

import (
	"bytes"
	"fmt"
	"os/exec"
	"strings"
)

// HostGHToken returns the GitHub token from the host's gh CLI.
// Two-step verification (status → token) gives clearer error messages
// than relying on `gh auth token` exit codes alone.
func HostGHToken() (string, error) {
	if _, err := exec.LookPath("gh"); err != nil {
		return "", fmt.Errorf("gh CLI not found on host (install via https://cli.github.com)")
	}

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

	out, err := exec.Command("gh", "auth", "token").Output()
	if err != nil {
		return "", fmt.Errorf("gh auth token: %w", err)
	}
	token := strings.TrimSpace(string(out))
	if token == "" {
		return "", fmt.Errorf("gh returned empty token")
	}
	return token, nil
}
