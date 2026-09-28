package dashboard

import (
	"bytes"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/exp/teatest"
	"github.com/kcenon/claude-docker/tui/internal/account"
	"github.com/kcenon/claude-docker/tui/internal/config"
	"github.com/kcenon/claude-docker/tui/internal/docker"
	"github.com/muesli/termenv"
)

// renderTermWidth/renderTermHeight pin the simulated terminal. The account
// table needs 86 columns for its six fixed-width cells, so a narrower
// terminal would let bubbletea's renderer truncate the row and turn a
// rendering assertion into a width assertion.
const (
	renderTermWidth  = 120
	renderTermHeight = 40
)

// ansiEscape matches the CSI sequences bubbletea's renderer interleaves
// between frame lines (cursor movement, line erase, cursor visibility).
// Stripping them is what makes a per-row assertion possible: the payload
// text of a row is contiguous, but the line boundaries around it are not.
var ansiEscape = regexp.MustCompile(`\x1b\[[0-9;?]*[a-zA-Z]`)

// geminiRenderCases describes the account state directories staged under the
// temporary HOME, and what each one must produce on screen. Gemini has
// supportsUsage=false in the runtime registry, so detectAuthType treats the
// OAuth credential as opaque login state: present -> "Login", absent -> "--".
// Both variants are staged so the AUTH column is exercised in each direction
// rather than only in its zero value.
var geminiRenderCases = []struct {
	letter        string
	withOAuthFile bool
	wantService   string
	wantAuthCell  string
}{
	{letter: "a", withOAuthFile: true, wantService: "gemini-a", wantAuthCell: "Login"},
	{letter: "b", withOAuthFile: false, wantService: "gemini-b", wantAuthCell: "--"},
}

// TestRenderIsolationBannerWarnsAboutUnusedPaths pins the banner's report of
// per-account paths the active mode ignores.
//
// The shell layers print this on every invocation
// (warn_unused_workspace_paths, Write-UnusedWorkspacePathWarning); the TUI had
// no equivalent, so the one configuration where the mode and the paths
// disagree -- a stale PROJECT_DIR_A left behind by a move to isolated -- read
// as if the worktrees were still mounted. Asserted on the stripped frame
// because the colour is styling, not content.
func TestRenderIsolationBannerWarnsAboutUnusedPaths(t *testing.T) {
	cases := []struct {
		name    string
		env     map[string]string
		want    []string
		notWant []string
	}{
		{
			name: "isolated with a stale worktree path",
			env:  map[string]string{"ISOLATION_MODE": "isolated", "PROJECT_DIR_A": "/stale/wt"},
			want: []string{"Isolation: isolated", "PROJECT_DIR_A is set"},
		},
		{
			name:    "worktree consumes its own paths",
			env:     map[string]string{"ISOLATION_MODE": "worktree", "PROJECT_DIR_A": "/wt/a"},
			want:    []string{"Isolation: worktree"},
			notWant: []string{"Warning:"},
		},
		{
			name:    "worktree with leftover clone paths",
			env:     map[string]string{"ISOLATION_MODE": "worktree", "PROJECT_DIR_A": "/wt/a", "ISOLATED_WORKSPACE_A": "/old/clone"},
			want:    []string{"ISOLATED_WORKSPACE_A is set"},
			notWant: []string{"PROJECT_DIR_A is set"},
		},
		{
			name:    "shared with nothing configured",
			env:     map[string]string{},
			want:    []string{"Isolation: shared"},
			notWant: []string{"Warning:"},
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			env := config.NewEmptyEnv(filepath.Join(t.TempDir(), ".env"))
			for k, v := range tc.env {
				env.Set(k, v)
			}
			got := ansiEscape.ReplaceAllString(renderIsolationBanner(env), "")
			for _, w := range tc.want {
				if !strings.Contains(got, w) {
					t.Errorf("banner missing %q:\n%s", w, got)
				}
			}
			for _, w := range tc.notWant {
				if strings.Contains(got, w) {
					t.Errorf("banner should not contain %q:\n%s", w, got)
				}
			}
		})
	}
}

// TestDashboardRendersGeminiAccounts drives the dashboard through a simulated
// terminal and asserts that gemini accounts discovered from
// $HOME/.gemini-state/account-* actually reach the rendered frame. This is the
// automated form of the "accounts are listed on the TUI screen" check that was
// previously only verifiable by a human looking at the dashboard.
//
// The test is hermetic despite the model shelling out to docker, because every
// enrichment path is inert for gemini:
//   - Manager.fetchContainerStatus discards the `docker compose ps` error and
//     degrades to an empty map, so pointing the client at a directory with no
//     compose file yields "no containers" rather than a failure.
//   - Manager.enrichAPIUsage returns before any HTTP call when the runtime does
//     not support Claude usage, which is the case for gemini.
//   - Manager.enrichGHAuth is a no-op unless a container is running.
//
// Assertions are substring/structural rather than a golden frame: the point is
// that the accounts reach the screen, and a golden frame would fail on any
// future layout edit without saying anything about that.
func TestDashboardRendersGeminiAccounts(t *testing.T) {
	forceASCIIColorProfile(t)

	home := stageGeminiStateDirs(t)
	// config.userHomeDir prefers $HOME and only falls back to
	// os.UserHomeDir(), so setting HOME redirects state-dir discovery on
	// Linux and Windows alike -- USERPROFILE is never consulted while HOME
	// is non-empty. t.Setenv restores the previous value on cleanup.
	t.Setenv("HOME", home)

	env := loadGeminiEnv(t)
	// A project root with no docker-compose.yml: `docker compose ps` fails
	// immediately instead of reaching a daemon, which is the degraded path
	// the manager is expected to tolerate.
	client := docker.NewClient(t.TempDir(), env)
	mgr := account.NewManager(env, client)

	model := New(mgr, client, env, false)
	// No pre-emptive SetSize. It used to be applied here as well as on the
	// WindowSizeMsg teatest sends, because that message races the initial load
	// command and renderAccountTable panicked on a zero width if accounts
	// arrived first -- a live bug neutralized inside the test. ruleWidth
	// clamps at the call site now, and TestViewAtZeroWidthDoesNotPanic covers
	// the case directly.
	tm := teatest.NewTestModel(t, testApp{dash: model},
		teatest.WithInitialTermSize(renderTermWidth, renderTermHeight))

	// WaitFor polls the output stream instead of sleeping a fixed amount, so
	// the test is bounded by how fast the frame arrives rather than by a
	// guess. The accumulated bytes are captured here because WaitFor consumes
	// the reader and does not hand them back.
	var rendered []byte
	teatest.WaitFor(t, tm.Output(), func(bts []byte) bool {
		for _, c := range geminiRenderCases {
			if !bytes.Contains(bts, []byte(c.wantService)) {
				return false
			}
		}
		rendered = append([]byte(nil), bts...)
		return true
	}, teatest.WithCheckInterval(50*time.Millisecond), teatest.WithDuration(15*time.Second))

	// Quit through the same key the application binds, then bound the wait so
	// a model that never terminates fails the test instead of hanging CI.
	tm.Send(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("q")})
	tm.WaitFinished(t, teatest.WithFinalTimeout(10*time.Second))

	plain := ansiEscape.ReplaceAllString(string(rendered), "")

	// The table header proves the account-table branch of View ran, rather
	// than the loading, error, or empty-state branch.
	if !strings.Contains(plain, "SERVICE") {
		t.Errorf("rendered output is missing the account table header:\n%s", plain)
	}
	if strings.Contains(plain, "No accounts configured") {
		t.Errorf("rendered output fell back to the empty state:\n%s", plain)
	}

	for _, c := range geminiRenderCases {
		cells := findRenderedRow(plain, c.wantService)
		if cells == nil {
			t.Errorf("no rendered row contains service %q:\n%s", c.wantService, plain)
			continue
		}
		// cells[0] is the service name, so AUTH -- the third column after
		// SERVICE and STATUS -- is cells[2]. Indexing by column order rather
		// than by character offset keeps the assertion meaningful without
		// pinning the column widths a future layout edit may change.
		const authCellIndex = 2
		if len(cells) <= authCellIndex {
			t.Errorf("service %q: rendered row has only %d cells (%q), want at least %d",
				c.wantService, len(cells), cells, authCellIndex+1)
			continue
		}
		if cells[authCellIndex] != c.wantAuthCell {
			t.Errorf("service %q: AUTH cell = %q, want %q (row cells: %q)",
				c.wantService, cells[authCellIndex], c.wantAuthCell, cells)
		}
	}
}

// testApp adapts the dashboard into a tea.Model for teatest.
//
// Model.Update returns the concrete Model rather than tea.Model, so the
// dashboard is not a tea.Model on its own; internal/ui.App is what runs it in
// a Program. This adapter reproduces only the two things App layers on top of
// the dashboard -- forwarding the terminal size and translating the quit keys
// -- so the frames asserted above come from the real View and Update path with
// nothing else in between.
type testApp struct {
	dash Model
}

func (a testApp) Init() tea.Cmd { return a.dash.Init() }

func (a testApp) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		a.dash.SetSize(msg.Width, msg.Height-4) // reserve space for header, as App does
	case tea.KeyMsg:
		switch msg.String() {
		case "q", "ctrl+c":
			return a, tea.Quit
		}
	}
	var cmd tea.Cmd
	a.dash, cmd = a.dash.Update(msg)
	return a, cmd
}

func (a testApp) View() string { return a.dash.View() }

// stageGeminiStateDirs builds a temporary HOME holding the gemini state
// directories described by geminiRenderCases, and returns the HOME path. The
// directory name and the credential file name are read from the runtime
// registry rather than hard-coded, so the fixture follows the registry if the
// gemini entry ever changes.
func stageGeminiStateDirs(t *testing.T) string {
	t.Helper()
	spec, ok := config.LookupRuntime(config.RuntimeGemini)
	if !ok {
		t.Fatalf("gemini is not registered in the runtime registry")
	}

	home := t.TempDir()
	base := filepath.Join(home, spec.StateDir)
	for _, c := range geminiRenderCases {
		dir := filepath.Join(base, "account-"+c.letter)
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatalf("mkdir %s: %v", dir, err)
		}
		if !c.withOAuthFile {
			continue
		}
		cred := filepath.Join(dir, spec.OAuthCredentialFile)
		if err := os.WriteFile(cred, []byte(`{"access_token":"test"}`), 0o600); err != nil {
			t.Fatalf("write %s: %v", cred, err)
		}
	}
	return home
}

// loadGeminiEnv writes and parses a .env selecting the gemini runtime with one
// account per staged state directory.
func loadGeminiEnv(t *testing.T) *config.Env {
	t.Helper()
	path := filepath.Join(t.TempDir(), ".env")
	content := "AGENT_RUNTIME=gemini\nNUM_ACCOUNTS=2\n"
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatalf("write env: %v", err)
	}
	env, err := config.LoadEnv(path)
	if err != nil {
		t.Fatalf("LoadEnv: %v", err)
	}
	if env.AgentRuntime() != config.RuntimeGemini {
		t.Fatalf("AgentRuntime = %q, want %q", env.AgentRuntime(), config.RuntimeGemini)
	}
	return env
}

// forceASCIIColorProfile pins lipgloss's default renderer to the ASCII profile
// so the frames carry no color escapes whatever terminal the suite runs under.
// The renderer is process-global, so the previous profile is restored on
// cleanup rather than left pinned for the rest of the package.
func forceASCIIColorProfile(t *testing.T) {
	t.Helper()
	prev := lipgloss.ColorProfile()
	lipgloss.SetColorProfile(termenv.Ascii)
	t.Cleanup(func() { lipgloss.SetColorProfile(prev) })
}

// findRenderedRow locates the account row for service in the stripped output
// and returns its cells, starting at the service name so the caller can index
// by column. Returns nil when no row carries the service name.
//
// Cells are split on whitespace runs rather than sliced at fixed offsets: the
// table pads every cell to a fixed width, and a rendered cell never contains a
// space, so the split recovers the columns without depending on their widths.
// The cursor marker ">" that prefixes the selected row is dropped by starting
// at the service name.
//
// Rows are found by scanning every line of the accumulated stream rather than
// only the final frame, because the renderer emits several frames before the
// accounts settle and separates them with bare carriage returns.
func findRenderedRow(plain, service string) []string {
	lines := strings.FieldsFunc(plain, func(r rune) bool { return r == '\n' || r == '\r' })
	for _, line := range lines {
		cells := strings.Fields(line)
		for i, cell := range cells {
			if cell == service {
				return cells[i:]
			}
		}
	}
	return nil
}
