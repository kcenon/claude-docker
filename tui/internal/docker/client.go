package docker

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os/exec"
	"strings"

	"github.com/kcenon/claude-docker/tui/internal/config"
)

// Client wraps docker compose invocations.
type Client struct {
	projectRoot string
	env         *config.Env
}

// NewClient creates a docker compose client.
func NewClient(projectRoot string, env *config.Env) *Client {
	return &Client{projectRoot: projectRoot, env: env}
}

// ContainerInfo mirrors the subset of `docker compose ps --format json` we care about.
type ContainerInfo struct {
	ID      string `json:"ID"`
	Service string `json:"Service"`
	State   string `json:"State"`
	Status  string `json:"Status"`
	Name    string `json:"Name"`
}

// PS returns the list of containers for this compose project.
func (c *Client) PS() ([]ContainerInfo, error) {
	args := append(BuildComposeArgs(c.projectRoot, c.env), "ps", "--format", "json", "--all")
	cmd := exec.Command("docker", args...)
	out, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("docker compose ps: %w", err)
	}
	return parseComposePS(string(out))
}

// parseComposePS handles both JSON array and newline-delimited JSON output formats.
func parseComposePS(out string) ([]ContainerInfo, error) {
	out = strings.TrimSpace(out)
	if out == "" {
		return nil, nil
	}
	// Try JSON array first
	if strings.HasPrefix(out, "[") {
		var arr []ContainerInfo
		if err := json.Unmarshal([]byte(out), &arr); err == nil {
			return arr, nil
		}
	}
	// Newline-delimited JSON
	var infos []ContainerInfo
	scanner := bufio.NewScanner(strings.NewReader(out))
	scanner.Buffer(make([]byte, 1024*1024), 1024*1024)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		var ci ContainerInfo
		if err := json.Unmarshal([]byte(line), &ci); err != nil {
			continue
		}
		infos = append(infos, ci)
	}
	return infos, scanner.Err()
}

// Up starts all services detached.
func (c *Client) Up() error {
	args := append(BuildComposeArgs(c.projectRoot, c.env), "up", "-d")
	cmd := exec.Command("docker", args...)
	return cmd.Run()
}

// Down stops all services.
func (c *Client) Down() error {
	args := append(BuildComposeArgs(c.projectRoot, c.env), "down")
	cmd := exec.Command("docker", args...)
	return cmd.Run()
}

// ExecArgs returns (bin, args) for running a command in a running service container.
// Used with tea.ExecProcess for interactive terminal handoff.
func (c *Client) ExecArgs(service string, cmd ...string) (string, []string) {
	args := append(BuildComposeArgs(c.projectRoot, c.env), "exec", service)
	args = append(args, cmd...)
	return "docker", args
}

// BuildArgs returns (bin, args) for `docker compose build`.
// When noCache is true, passes --no-cache to force a full rebuild.
func (c *Client) BuildArgs(noCache bool) (string, []string) {
	args := append(BuildComposeArgs(c.projectRoot, c.env), "build")
	if noCache {
		args = append(args, "--no-cache")
	}
	return "docker", args
}

// UpRecreateArgs returns (bin, args) for `docker compose up -d --force-recreate`.
// Used after image rebuild or .env change so containers pick up new config.
func (c *Client) UpRecreateArgs() (string, []string) {
	args := append(BuildComposeArgs(c.projectRoot, c.env), "up", "-d", "--force-recreate")
	return "docker", args
}

// RestartArgs returns (bin, args) for restarting a single service.
// service must be a name produced by ServiceNames() (e.g. "claude-a").
func (c *Client) RestartArgs(service string) (string, []string) {
	args := append(BuildComposeArgs(c.projectRoot, c.env), "restart", service)
	return "docker", args
}

// HasRunningContainers returns true if any compose service is currently up.
// Used by gh-auth flow to decide whether a recreate is needed.
func (c *Client) HasRunningContainers() bool {
	infos, err := c.PS()
	if err != nil {
		return false
	}
	for _, ci := range infos {
		if strings.EqualFold(ci.State, "running") {
			return true
		}
	}
	return false
}

// ServiceNames returns the expected service names based on NUM_ACCOUNTS.
func (c *Client) ServiceNames() []string {
	n := 1
	if c.env != nil {
		n = c.env.NumAccounts()
	}
	names := make([]string, n)
	for i := 1; i <= n; i++ {
		names[i-1] = "claude-" + config.IndexToLetter(i)
	}
	return names
}
