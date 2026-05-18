package main

import (
	"fmt"
	"os"
	"path/filepath"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/kcenon/claude-docker/tui/internal/account"
	"github.com/kcenon/claude-docker/tui/internal/config"
	"github.com/kcenon/claude-docker/tui/internal/docker"
	"github.com/kcenon/claude-docker/tui/internal/ui"
)

var version = "dev"

func main() {
	skipPermissions := false
	var filteredArgs []string
	for _, arg := range os.Args[1:] {
		switch arg {
		case "--dangerously-skip-permissions", "--dangerously-bypass-approvals-and-sandbox":
			skipPermissions = true
		default:
			filteredArgs = append(filteredArgs, arg)
		}
	}

	if len(filteredArgs) > 0 && (filteredArgs[0] == "--version" || filteredArgs[0] == "-v") {
		fmt.Printf("claude-docker-tui %s\n", version)
		os.Exit(0)
	}

	if len(filteredArgs) > 0 && filteredArgs[0] == "--json" {
		if err := runJSON(); err != nil {
			fmt.Fprintf(os.Stderr, "error: %v\n", err)
			os.Exit(1)
		}
		return
	}

	projectRoot, err := resolveProjectRoot()
	if err != nil {
		fmt.Fprintf(os.Stderr, "error: cannot find claude-docker project root: %v\n", err)
		os.Exit(1)
	}

	envPath := filepath.Join(projectRoot, ".env")
	env, err := config.LoadEnv(envPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "warning: cannot load .env: %v\n", err)
		env = config.NewEmptyEnv(envPath)
	}

	composeClient := docker.NewClient(projectRoot, env)

	app := ui.NewApp(version, projectRoot, env, composeClient, skipPermissions)
	p := tea.NewProgram(app, tea.WithAltScreen())
	if _, err := p.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(1)
	}
}

// resolveProjectRoot finds the claude-docker project root.
// It walks up from the executable location or CWD looking for docker-compose.yml.
func resolveProjectRoot() (string, error) {
	exe, err := os.Executable()
	if err == nil {
		candidate := filepath.Dir(filepath.Dir(exe))
		if isProjectRoot(candidate) {
			return candidate, nil
		}
	}

	cwd, err := os.Getwd()
	if err == nil {
		if isProjectRoot(cwd) {
			return cwd, nil
		}
		parent := filepath.Dir(cwd)
		if isProjectRoot(parent) {
			return parent, nil
		}
	}

	if cwd != "" {
		dir := cwd
		for {
			if isProjectRoot(dir) {
				return dir, nil
			}
			parent := filepath.Dir(dir)
			if parent == dir {
				break
			}
			dir = parent
		}
	}

	return "", fmt.Errorf("docker-compose.yml not found in any parent directory")
}

func isProjectRoot(dir string) bool {
	_, err := os.Stat(filepath.Join(dir, "docker-compose.yml"))
	return err == nil
}

func runJSON() error {
	projectRoot, err := resolveProjectRoot()
	if err != nil {
		return err
	}

	env, err := config.LoadEnv(filepath.Join(projectRoot, ".env"))
	if err != nil {
		return fmt.Errorf("cannot load .env: %w", err)
	}

	client := docker.NewClient(projectRoot, env)
	mgr := account.NewManager(env, client)

	accounts, err := mgr.ListAccounts()
	if err != nil {
		return fmt.Errorf("cannot list accounts: %w", err)
	}

	fmt.Printf("{\n")
	fmt.Printf("  \"project_root\": %q,\n", projectRoot)
	fmt.Printf("  \"runtime\": %q,\n", env.AgentRuntime())
	fmt.Printf("  \"num_accounts\": %d,\n", len(accounts))
	fmt.Printf("  \"accounts\": [\n")
	for i, a := range accounts {
		comma := ","
		if i == len(accounts)-1 {
			comma = ""
		}
		fiveH := "null"
		sevenD := "null"
		if a.FiveHourUsage != nil {
			fiveH = fmt.Sprintf("%d", a.FiveHourUsage.PercentUsed)
		}
		if a.SevenDayUsage != nil {
			sevenD = fmt.Sprintf("%d", a.SevenDayUsage.PercentUsed)
		}
		rateLimited := ""
		if a.APIRateLimited {
			rateLimited = ", \"api_rate_limited\": true"
		}
		lastStatus := ""
		if a.LastAPIStatus != "" {
			lastStatus = fmt.Sprintf(", \"last_api_status\": %q", a.LastAPIStatus)
		}
		fmt.Printf("    {\"service\": %q, \"state\": %q, \"auth\": %q, \"5h\": %s, \"7d\": %s%s%s}%s\n",
			a.ServiceName, a.ContainerStatus, a.AuthType, fiveH, sevenD, rateLimited, lastStatus, comma)
	}
	fmt.Printf("  ]\n")
	fmt.Printf("}\n")
	return nil
}
