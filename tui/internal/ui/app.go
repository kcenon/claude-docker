// Package ui provides the top-level TUI application.
package ui

import (
	"fmt"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/kcenon/claude-docker/tui/internal/account"
	"github.com/kcenon/claude-docker/tui/internal/config"
	"github.com/kcenon/claude-docker/tui/internal/docker"
	"github.com/kcenon/claude-docker/tui/internal/ui/dashboard"
)

// App is the top-level bubbletea model.
type App struct {
	version     string
	projectRoot string
	env         *config.Env
	client      *docker.Client
	manager     *account.Manager
	dashboard   dashboard.Model
	width       int
	height      int
}

// NewApp creates the application model.
func NewApp(version, projectRoot string, env *config.Env, client *docker.Client, skipPermissions bool) App {
	mgr := account.NewManager(env, client)
	return App{
		version:     version,
		projectRoot: projectRoot,
		env:         env,
		client:      client,
		manager:     mgr,
		dashboard:   dashboard.New(mgr, client, env, skipPermissions),
	}
}

// Init starts the application.
func (a App) Init() tea.Cmd {
	return a.dashboard.Init()
}

// Update handles messages.
func (a App) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		a.width = msg.Width
		a.height = msg.Height
		a.dashboard.SetSize(msg.Width, msg.Height-4) // reserve space for header
		var cmd tea.Cmd
		a.dashboard, cmd = a.dashboard.Update(msg)
		return a, cmd
	case tea.KeyMsg:
		switch msg.String() {
		case "q", "ctrl+c":
			return a, tea.Quit
		}
	}

	var cmd tea.Cmd
	a.dashboard, cmd = a.dashboard.Update(msg)
	return a, cmd
}

// View renders the application.
func (a App) View() string {
	var b strings.Builder

	// Header: use actual loaded account count (auto-detected from state dirs)
	count := a.dashboard.AccountCount()
	if count == 0 {
		count = a.env.NumAccounts()
	}
	title := lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("#06B6D4")).
		Render(fmt.Sprintf(" claude-docker %s", a.version))
	summary := lipgloss.NewStyle().Foreground(lipgloss.Color("#6B7280")).
		Render(fmt.Sprintf("  %s  %d accounts", a.env.AgentRuntime(), count))
	b.WriteString(title + summary + "\n\n")

	// Dashboard
	b.WriteString(a.dashboard.View())
	b.WriteString("\n\n")

	// Footer
	footer := lipgloss.NewStyle().Foreground(lipgloss.Color("#6B7280")).
		Render("  [q] Quit")
	b.WriteString(footer)

	return b.String()
}
