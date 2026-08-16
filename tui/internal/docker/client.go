package docker

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"os/exec"
	"strings"
	"time"

	"github.com/kcenon/claude-docker/tui/internal/config"
)

// psTimeout bounds `docker compose ps` (#358, item 1).
//
// Every dashboard refresh blocks on this call, and an unbounded one leaves
// ListAccounts with no return path: m.refreshing never clears, so the `r` key
// is rejected by its own guard and the operator cannot recover without killing
// the process. A daemon that is starting, a socket that is not answering, or a
// context switch to an unreachable remote all reach the same state.
//
// A package-level var rather than a const so tests can shorten it. Unexported,
// so only this package can; the tests that do are not parallel.
var psTimeout = 10 * time.Second

// killGrace is how long a timed-out child gets between SIGKILL and giving up
// on its output pipes.
//
// exec.CommandContext kills the process when the context expires, but Output()
// waits for the pipes to close, and `docker exec` hands its stdout to a
// grandchild inside the container. Killing the local docker client does not
// close that pipe, so without WaitDelay the read blocks anyway and the timeout
// buys nothing.
const killGrace = 2 * time.Second

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
	base, err := BuildComposeArgs(c.projectRoot, c.env)
	if err != nil {
		return nil, err
	}
	args := append(base, "ps", "--format", "json", "--all")
	ctx, cancel := context.WithTimeout(context.Background(), psTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, "docker", args...)
	cmd.WaitDelay = killGrace
	out, err := cmd.Output()
	if err != nil {
		// Report the deadline as a deadline. Wrapping the raw "signal: killed"
		// would tell the operator their docker client crashed.
		if ctx.Err() == context.DeadlineExceeded {
			return nil, fmt.Errorf("docker compose ps timed out after %s", psTimeout)
		}
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
//
// Deliberately unbounded, unlike PS. `up -d` legitimately runs for minutes
// when it has to pull or build, and a deadline here would abort a working
// operation partway. It is also operator-initiated with a toast explaining
// the wait, where PS runs on every refresh with nothing on screen to say so.
func (c *Client) Up() error {
	base, err := BuildComposeArgs(c.projectRoot, c.env)
	if err != nil {
		return err
	}
	cmd := exec.Command("docker", append(base, "up", "-d")...)
	return cmd.Run()
}

// Down stops all services.
func (c *Client) Down() error {
	base, err := BuildComposeArgs(c.projectRoot, c.env)
	if err != nil {
		return err
	}
	cmd := exec.Command("docker", append(base, "down")...)
	return cmd.Run()
}

// The *Args methods return (bin, args, error) rather than building a command.
// The error is not decoration: the caller hands the result to tea.ExecProcess,
// so a compose prefix that could not be resolved has to stop the caller before
// a docker process is spawned. Returning args anyway and letting docker sort
// it out is what started every account on the shared mount.

// ExecArgs returns (bin, args) for running a command in a running service container.
// Used with tea.ExecProcess for interactive terminal handoff.
func (c *Client) ExecArgs(service string, cmd ...string) (string, []string, error) {
	base, err := BuildComposeArgs(c.projectRoot, c.env)
	if err != nil {
		return "", nil, err
	}
	args := append(base, "exec", service)
	args = append(args, cmd...)
	return "docker", args, nil
}

// BuildArgs returns (bin, args) for `docker compose build`.
// When noCache is true, passes --no-cache to force a full rebuild.
func (c *Client) BuildArgs(noCache bool) (string, []string, error) {
	base, err := BuildComposeArgs(c.projectRoot, c.env)
	if err != nil {
		return "", nil, err
	}
	args := append(base, "build")
	if noCache {
		args = append(args, "--no-cache")
	}
	return "docker", args, nil
}

// UpRecreateArgs returns (bin, args) for `docker compose up -d --force-recreate`.
// Used after image rebuild or .env change so containers pick up new config.
func (c *Client) UpRecreateArgs(services ...string) (string, []string, error) {
	base, err := BuildComposeArgs(c.projectRoot, c.env)
	if err != nil {
		return "", nil, err
	}
	args := append(base, "up", "-d", "--force-recreate")
	args = append(args, services...)
	return "docker", args, nil
}

// RestartArgs returns (bin, args) for restarting a single service.
// service must be a name produced by ServiceNames() (e.g. "claude-a").
func (c *Client) RestartArgs(service string) (string, []string, error) {
	base, err := BuildComposeArgs(c.projectRoot, c.env)
	if err != nil {
		return "", nil, err
	}
	return "docker", append(base, "restart", service), nil
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
	n := config.DefaultNumAccounts
	prefix := config.RuntimeClaude
	if c.env != nil {
		n = c.env.NumAccounts()
		prefix = c.env.ServicePrefix()
	}
	names := make([]string, n)
	for i := 1; i <= n; i++ {
		names[i-1] = prefix + "-" + config.IndexToLetter(i)
	}
	return names
}
