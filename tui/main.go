package main

import (
	"encoding/json"
	"fmt"
	"io"
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
		// Read-only fallback. The dashboard still starts and shows what it
		// can, but Save refuses: writing an Env that holds none of the user's
		// keys would replace the file rather than update it (#358, item 7).
		fmt.Fprintf(os.Stderr, "warning: cannot load .env: %v\n", err)
		fmt.Fprintf(os.Stderr, "warning: gh-auth is disabled until it loads\n")
		env = config.NewUnloadableEnv(envPath, err)
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

// projectMarkers are the paths a directory must contain to be this project's
// root (#358, item 7).
//
// docker-compose.yml alone is not a marker -- it is one of the most common
// filenames on a developer's disk. resolveProjectRoot walks up from the
// executable and then from the cwd, so running the TUI from inside any
// unrelated compose project claimed that project as the root. That is not only
// a wrong dashboard: `g` writes a GitHub token into `<root>/.env`, and an
// unrelated directory has no reason to be gitignoring it.
//
// scripts/claude-docker is the disambiguator. It ships with the repository,
// it is the entry point every documented workflow uses, and it is not a name
// another project is likely to have next to a compose file.
var projectMarkers = []string{
	"docker-compose.yml",
	filepath.Join("scripts", "claude-docker"),
}

func isProjectRoot(dir string) bool {
	for _, marker := range projectMarkers {
		if _, err := os.Stat(filepath.Join(dir, marker)); err != nil {
			return false
		}
	}
	return true
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

	return writeJSONReport(os.Stdout, projectRoot, env.AgentRuntime(), accounts)
}

// jsonReport is the --json document (#358, item 6).
//
// It exists because the previous implementation hand-assembled the same
// document with fmt.Printf and %q. %q is Go quoting, not JSON quoting: they
// agree on the common cases and diverge on the ones that matter here. A
// LastAPIStatus carrying a control character -- which it can, since it is
// built from an upstream error string -- is emitted by %q as \x00, which is
// not a JSON escape, so the output stops being parseable. The struct also
// removes the hand-tracked trailing comma and the "null" string literals.
type jsonReport struct {
	ProjectRoot string        `json:"project_root"`
	Runtime     string        `json:"runtime"`
	NumAccounts int           `json:"num_accounts"`
	Accounts    []jsonAccount `json:"accounts"`
}

// jsonAccount keeps the field names and the omission rules of the original
// output, so existing consumers see the same document.
type jsonAccount struct {
	Service        string `json:"service"`
	State          string `json:"state"`
	Auth           string `json:"auth"`
	FiveHour       *int   `json:"5h"`
	SevenDay       *int   `json:"7d"`
	APIRateLimited bool   `json:"api_rate_limited,omitempty"`
	LastAPIStatus  string `json:"last_api_status,omitempty"`
}

func writeJSONReport(w io.Writer, projectRoot, runtime string, accounts []account.Account) error {
	report := jsonReport{
		ProjectRoot: projectRoot,
		Runtime:     runtime,
		NumAccounts: len(accounts),
		// Never nil: an install with no accounts should emit [], not null.
		Accounts: make([]jsonAccount, 0, len(accounts)),
	}

	for _, a := range accounts {
		ja := jsonAccount{
			Service:        a.ServiceName,
			State:          a.ContainerStatus.String(),
			Auth:           a.AuthType.String(),
			APIRateLimited: a.APIRateLimited,
			LastAPIStatus:  a.LastAPIStatus,
		}
		if a.FiveHourUsage != nil {
			v := a.FiveHourUsage.PercentUsed
			ja.FiveHour = &v
		}
		if a.SevenDayUsage != nil {
			v := a.SevenDayUsage.PercentUsed
			ja.SevenDay = &v
		}
		report.Accounts = append(report.Accounts, ja)
	}

	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	return enc.Encode(report)
}
