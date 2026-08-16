package docker

import (
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"testing"

	"github.com/kcenon/claude-docker/tui/internal/config"
)

// containsArg returns true if want appears anywhere in args.
func containsArg(args []string, want string) bool {
	for _, a := range args {
		if a == want {
			return true
		}
	}
	return false
}

// writeFile creates an empty file at path so the file-existence check passes.
func writeFile(t *testing.T, path string) {
	t.Helper()
	if err := os.WriteFile(path, []byte{}, 0o644); err != nil {
		t.Fatalf("WriteFile(%q): %v", path, err)
	}
}

// mustArgs fails the test if BuildComposeArgs returns an error. Used by the
// cases whose subject is the argument list rather than the refusal.
func mustArgs(t *testing.T, root string, env *config.Env) []string {
	t.Helper()
	args, err := BuildComposeArgs(root, env)
	if err != nil {
		t.Fatalf("BuildComposeArgs: unexpected error: %v", err)
	}
	return args
}

// modeEnv returns an Env configured with ISOLATION_MODE and any extra keys.
func modeEnv(mode string, kv ...string) *config.Env {
	env := config.NewEmptyEnv("/tmp/.env")
	if mode != "" {
		env.Set("ISOLATION_MODE", mode)
	}
	for i := 0; i+1 < len(kv); i += 2 {
		env.Set(kv[i], kv[i+1])
	}
	return env
}

// TestBuildComposeArgs verifies the base compose file is always present and
// that the Linux overlay and worktree overlay are added under the right
// conditions when the corresponding files exist on disk. CI runs on Linux so
// the Linux branch always fires there; we still assert the OS-conditional
// logic explicitly so the test passes on macOS/Windows local runs too.
func TestBuildComposeArgs(t *testing.T) {
	root := t.TempDir()
	baseFile := filepath.Join(root, "docker-compose.yml")
	linuxFile := filepath.Join(root, "docker-compose.linux.yml")
	worktreeFile := filepath.Join(root, "docker-compose.worktree.yml")
	isolatedFile := filepath.Join(root, "docker-compose.isolated.yml")

	// Pre-create the overlay files so the file-existence checks pass for the
	// scenarios that exercise the "overlay should be added" path. The base
	// compose path itself is not stat'd by BuildComposeArgs; it is always
	// included regardless of whether the file exists on disk, matching the
	// canonical bash implementation.
	writeFile(t, linuxFile)
	writeFile(t, worktreeFile)
	writeFile(t, isolatedFile)

	t.Run("base only nil env", func(t *testing.T) {
		args := mustArgs(t, root, nil)
		if len(args) == 0 || args[0] != "compose" {
			t.Fatalf("args = %v, want first element %q", args, "compose")
		}
		if !containsArg(args, baseFile) {
			t.Errorf("missing base compose file %q in %v", baseFile, args)
		}
		if containsArg(args, worktreeFile) {
			t.Errorf("worktree file should not be present without PROJECT_DIR_A")
		}
	})

	t.Run("os specific overlay", func(t *testing.T) {
		args := mustArgs(t, root, nil)
		hasLinux := containsArg(args, linuxFile)
		if runtime.GOOS == "linux" && !hasLinux {
			t.Errorf("linux: expected %q in args %v", linuxFile, args)
		}
		if runtime.GOOS != "linux" && hasLinux {
			t.Errorf("%s: %q should not be present", runtime.GOOS, linuxFile)
		}
	})

	// PROJECT_DIR_A with no explicit mode is how Tier B installations
	// predating the ISOLATION_MODE key are configured. IsolationMode() infers
	// worktree from it, so switching selection to the mode must not move them.
	t.Run("worktree overlay added when PROJECT_DIR_A set", func(t *testing.T) {
		args := mustArgs(t, root, modeEnv("", "PROJECT_DIR_A", "/some/path"))
		if !containsArg(args, worktreeFile) {
			t.Errorf("worktree file %q missing in %v", worktreeFile, args)
		}
	})

	t.Run("shared selects no mode overlay", func(t *testing.T) {
		args := mustArgs(t, root, modeEnv(config.IsolationShared))
		if containsArg(args, worktreeFile) || containsArg(args, isolatedFile) {
			t.Errorf("shared must select no mode overlay (args=%v)", args)
		}
	})

	// The defect this test exists for: ISOLATION_MODE was never read, so an
	// isolated install started on the base stack -- with the base's shared
	// read-write /project mount restored, because the overlay's `volumes:
	// !override` never got applied.
	t.Run("isolated selects the isolated overlay", func(t *testing.T) {
		args := mustArgs(t, root, modeEnv(config.IsolationIsolated))
		if !containsArg(args, isolatedFile) {
			t.Errorf("isolated overlay %q missing in %v", isolatedFile, args)
		}
		if containsArg(args, worktreeFile) {
			t.Errorf("isolated must not select the worktree overlay (args=%v)", args)
		}
	})

	// A stale PROJECT_DIR_A left over from a worktree install must not drag an
	// isolated configuration back onto the worktree overlay. Before the fix
	// this selected the wrong overlay rather than none.
	t.Run("stale PROJECT_DIR_A under isolated selects isolated", func(t *testing.T) {
		env := modeEnv(config.IsolationIsolated, "PROJECT_DIR_A", "/stale/worktree")
		args := mustArgs(t, root, env)
		if !containsArg(args, isolatedFile) {
			t.Errorf("isolated overlay %q missing in %v", isolatedFile, args)
		}
		if containsArg(args, worktreeFile) {
			t.Errorf("stale PROJECT_DIR_A must not select the worktree overlay (args=%v)", args)
		}
		warnings := env.UnusedWorkspaceWarnings()
		if len(warnings) != 1 || !strings.Contains(warnings[0], "PROJECT_DIR_A") {
			t.Errorf("expected one PROJECT_DIR_A warning, got %v", warnings)
		}
	})
}

// TestBuildComposeArgs_FileMissing separates the two file-existence rules,
// which are not the same rule in the canonical bash implementation:
//
//   - The Linux overlay is genuinely "add when present"
//     (scripts/lib/build-compose-cmd.sh:45).
//   - A mode overlay that is missing is an error and build_compose_cmd returns
//     non-zero (:74-78), because omitting it leaves every account on the base
//     stack's shared mount.
//
// This test previously asserted the second case fell back silently and
// described that as matching bash. It did not.
func TestBuildComposeArgs_FileMissing(t *testing.T) {
	root := t.TempDir()
	baseFile := filepath.Join(root, "docker-compose.yml")
	linuxFile := filepath.Join(root, "docker-compose.linux.yml")
	// Deliberately do NOT create any overlay. The base file is also absent;
	// the bash canonical version does not stat the base file either, so
	// neither does the Go port: the base path is unconditionally included.

	t.Run("linux overlay omitted when file missing", func(t *testing.T) {
		args := mustArgs(t, root, nil)
		if !containsArg(args, baseFile) {
			t.Errorf("base file %q should always be present in %v", baseFile, args)
		}
		if containsArg(args, linuxFile) {
			t.Errorf("linux overlay %q must be omitted when file does not exist (args=%v)", linuxFile, args)
		}
	})

	for _, tc := range []struct {
		name string
		env  *config.Env
		want string
	}{
		{"worktree", modeEnv("", "PROJECT_DIR_A", "/some/path"), "docker-compose.worktree.yml"},
		{"isolated", modeEnv(config.IsolationIsolated), "docker-compose.isolated.yml"},
	} {
		t.Run(tc.name+" overlay missing is an error", func(t *testing.T) {
			args, err := BuildComposeArgs(root, tc.env)
			if err == nil {
				t.Fatalf("expected an error for a missing %s overlay, got args=%v", tc.name, args)
			}
			if args != nil {
				t.Errorf("args must be nil on error, got %v", args)
			}
			// The message has to name the file, because regenerating it is
			// the fix and the user cannot act on "compose failed".
			if !strings.Contains(err.Error(), tc.want) {
				t.Errorf("error %q does not name %q", err.Error(), tc.want)
			}
		})
	}
}

// TestBuildComposeArgs_UnknownMode pins the refusal that gives
// config.IsolationModeKnown's contract a non-test consumer. An unrecognized
// mode used to start on the base stack with no diagnostic at all.
func TestBuildComposeArgs_UnknownMode(t *testing.T) {
	root := t.TempDir()
	writeFile(t, filepath.Join(root, "docker-compose.worktree.yml"))
	writeFile(t, filepath.Join(root, "docker-compose.isolated.yml"))

	for _, mode := range []string{"bogus", "per-account", "none", "worktrees"} {
		t.Run(mode, func(t *testing.T) {
			args, err := BuildComposeArgs(root, modeEnv(mode))
			if err == nil {
				t.Fatalf("ISOLATION_MODE=%s must be refused, got args=%v", mode, args)
			}
			if !strings.Contains(err.Error(), mode) {
				t.Errorf("error %q does not name the configured mode %q", err.Error(), mode)
			}
		})
	}

	// Case folding happens in IsolationMode(), matching resolve_isolation_mode
	// and Get-IsolationMode -- a mixed-case value is a spelling of a valid
	// mode, not an unknown one. Asserted here so a future tightening of the
	// refusal cannot silently start rejecting configurations the two shell
	// layers accept.
	t.Run("mixed case is a valid spelling, not an unknown mode", func(t *testing.T) {
		args, err := BuildComposeArgs(root, modeEnv("IsoLated"))
		if err != nil {
			t.Fatalf("mixed-case isolated must resolve: %v", err)
		}
		if !containsArg(args, filepath.Join(root, "docker-compose.isolated.yml")) {
			t.Errorf("isolated overlay missing in %v", args)
		}
	})
}

// TestOverlayTableMatchesBash reads the `case` block in build_compose_cmd and
// compares it against the Go table.
//
// The two implementations drifted precisely because nothing connected them:
// the isolated arm was added to bash in #335 and the Go side kept selecting
// from PROJECT_DIR_A. A comment pointing at the other file would not have
// caught that, so the bash source is parsed instead.
func TestOverlayTableMatchesBash(t *testing.T) {
	path := filepath.Join("..", "..", "..", "scripts", "lib", "build-compose-cmd.sh")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}

	// Matches e.g. `        worktree) overlay="docker-compose.worktree.yml" ;;`
	arm := regexp.MustCompile(`(?m)^\s*([A-Za-z*]+)\)\s*overlay="([^"]*)"`)
	matches := arm.FindAllStringSubmatch(string(data), -1)
	if len(matches) == 0 {
		t.Fatalf("no `overlay=` case arms found in %s; the parser or the script changed shape", path)
	}

	bash := map[string]string{}
	for _, m := range matches {
		bash[m[1]] = m[2]
	}
	// The `*` arm is bash's default and corresponds to every Go mode mapping
	// to an empty overlay; it has no name to compare against.
	if got, ok := bash["*"]; !ok || got != "" {
		t.Errorf("bash default arm = %q (present=%v), want an empty overlay", got, ok)
	}
	delete(bash, "*")

	for mode, want := range bash {
		got, ok := modeOverlay[mode]
		if !ok {
			t.Errorf("bash selects %q for mode %q, but the Go table has no such mode", want, mode)
			continue
		}
		if got != want {
			t.Errorf("mode %q: Go selects %q, bash selects %q", mode, got, want)
		}
	}
	for mode, overlay := range modeOverlay {
		if overlay == "" {
			continue // falls into bash's `*` arm
		}
		if _, ok := bash[mode]; !ok {
			t.Errorf("Go selects %q for mode %q, but bash has no arm for it", overlay, mode)
		}
	}
}

// TestExecArgs verifies the binary is "docker", the compose plumbing comes
// before "exec", "exec" precedes the service name, and user-supplied
// command tokens follow the service name in order.
func TestExecArgs(t *testing.T) {
	c := NewClient("/tmp/proj", nil)
	bin, args, err := c.ExecArgs("claude-a", "bash", "-lc", "ls")
	if err != nil {
		t.Fatalf("ExecArgs: %v", err)
	}

	if bin != "docker" {
		t.Errorf("bin = %q, want %q", bin, "docker")
	}

	// Locate "exec" — service must follow immediately after.
	execIdx := -1
	for i, a := range args {
		if a == "exec" {
			execIdx = i
			break
		}
	}
	if execIdx < 0 {
		t.Fatalf("args missing %q: %v", "exec", args)
	}
	if execIdx+1 >= len(args) || args[execIdx+1] != "claude-a" {
		t.Errorf("expected service name immediately after exec; got args=%v", args)
	}

	// User command tokens follow the service name in the original order.
	want := []string{"bash", "-lc", "ls"}
	for i, w := range want {
		idx := execIdx + 2 + i
		if idx >= len(args) || args[idx] != w {
			t.Errorf("args[%d] = %q, want %q (full args=%v)", idx, args[idx], w, args)
		}
	}
}

func TestServiceNames_CodexRuntime(t *testing.T) {
	env := config.NewEmptyEnv(filepath.Join(t.TempDir(), ".env"))
	env.Set("AGENT_RUNTIME", "codex")
	env.Set("NUM_ACCOUNTS", "2")
	c := NewClient("/tmp/proj", env)

	got := c.ServiceNames()
	want := []string{"codex-a", "codex-b"}
	if len(got) != len(want) {
		t.Fatalf("ServiceNames len = %d, want %d (%v)", len(got), len(want), got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("ServiceNames[%d] = %q, want %q", i, got[i], want[i])
		}
	}
}

func TestServiceNames_DefaultMatchesGenerator(t *testing.T) {
	env := config.NewEmptyEnv(filepath.Join(t.TempDir(), ".env"))
	c := NewClient("/tmp/proj", env)

	got := c.ServiceNames()
	want := []string{"claude-a", "claude-b"}
	if len(got) != len(want) {
		t.Fatalf("ServiceNames len = %d, want %d (%v)", len(got), len(want), got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("ServiceNames[%d] = %q, want %q", i, got[i], want[i])
		}
	}
}

// TestBuildArgs verifies the binary is "docker", "build" is always present,
// and "--no-cache" is added only when noCache is true.
func TestBuildArgs(t *testing.T) {
	c := NewClient("/tmp/proj", nil)

	cases := []struct {
		name    string
		noCache bool
		want    bool // expect --no-cache flag
	}{
		{"with cache", false, false},
		{"no cache", true, true},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			bin, args, err := c.BuildArgs(tc.noCache)
			if err != nil {
				t.Fatalf("BuildArgs: %v", err)
			}
			if bin != "docker" {
				t.Errorf("bin = %q, want %q", bin, "docker")
			}
			joined := strings.Join(args, " ")
			if !strings.Contains(joined, "build") {
				t.Errorf("args missing %q: %v", "build", args)
			}
			has := false
			for _, a := range args {
				if a == "--no-cache" {
					has = true
					break
				}
			}
			if has != tc.want {
				t.Errorf("--no-cache present=%v, want %v (args=%v)", has, tc.want, args)
			}
		})
	}
}

// TestUpRecreateArgs verifies the recreate variant emits "up", "-d", and
// "--force-recreate" so containers pick up new env/image content.
func TestUpRecreateArgs(t *testing.T) {
	c := NewClient("/tmp/proj", nil)
	bin, args, err := c.UpRecreateArgs()
	if err != nil {
		t.Fatalf("UpRecreateArgs: %v", err)
	}

	if bin != "docker" {
		t.Errorf("bin = %q, want %q", bin, "docker")
	}
	for _, want := range []string{"up", "-d", "--force-recreate"} {
		found := false
		for _, a := range args {
			if a == want {
				found = true
				break
			}
		}
		if !found {
			t.Errorf("args missing %q: %v", want, args)
		}
	}
}

func TestUpRecreateArgsSelectedService(t *testing.T) {
	c := NewClient("/tmp/proj", nil)
	_, args, err := c.UpRecreateArgs("claude-b")
	if err != nil {
		t.Fatalf("UpRecreateArgs: %v", err)
	}
	if got := args[len(args)-1]; got != "claude-b" {
		t.Errorf("last arg = %q, want claude-b (args=%v)", got, args)
	}
}

// TestClientPathsCarryIsolatedOverlay covers the seven client.go entry points
// the dashboard reaches. Six of them create or replace containers, and none
// sits behind a confirmation, so it is not enough for BuildComposeArgs alone
// to be right -- every caller has to route through it.
//
// The three that shell out (PS, Up, Down) are asserted only on the refusal
// path. That is deliberate and not a gap in coverage: the refusal is the case
// with a security consequence, and asserting it also proves the short-circuit
// happens before exec.Command, since a spawned docker would fail with some
// other message.
func TestClientPathsCarryIsolatedOverlay(t *testing.T) {
	root := t.TempDir()
	isolatedFile := filepath.Join(root, "docker-compose.isolated.yml")
	writeFile(t, isolatedFile)
	c := NewClient(root, modeEnv(config.IsolationIsolated))

	argsCases := map[string]func() (string, []string, error){
		"ExecArgs":       func() (string, []string, error) { return c.ExecArgs("claude-a", "bash") },
		"BuildArgs":      func() (string, []string, error) { return c.BuildArgs(false) },
		"UpRecreateArgs": func() (string, []string, error) { return c.UpRecreateArgs() },
		"RestartArgs":    func() (string, []string, error) { return c.RestartArgs("claude-a") },
	}
	for name, call := range argsCases {
		t.Run(name+" selects the isolated overlay", func(t *testing.T) {
			_, args, err := call()
			if err != nil {
				t.Fatalf("%s: %v", name, err)
			}
			if !containsArg(args, isolatedFile) {
				t.Errorf("%s: isolated overlay %q missing in %v", name, isolatedFile, args)
			}
		})
	}

	// Same client, overlay removed: nothing may proceed.
	if err := os.Remove(isolatedFile); err != nil {
		t.Fatalf("Remove: %v", err)
	}
	for name, call := range argsCases {
		t.Run(name+" refuses a missing overlay", func(t *testing.T) {
			_, args, err := call()
			if err == nil {
				t.Fatalf("%s: expected a refusal, got args=%v", name, args)
			}
		})
	}

	execCases := map[string]func() error{
		"PS":   func() error { _, err := c.PS(); return err },
		"Up":   c.Up,
		"Down": c.Down,
	}
	for name, call := range execCases {
		t.Run(name+" refuses a missing overlay before spawning docker", func(t *testing.T) {
			err := call()
			if err == nil {
				t.Fatalf("%s: expected a refusal", name)
			}
			if !strings.Contains(err.Error(), "docker-compose.isolated.yml") {
				t.Errorf("%s: error %q is not the compose refusal; docker may have been spawned",
					name, err.Error())
			}
		})
	}
}

// execTail returns the argv tokens after "exec" — the service name followed by
// the command. The compose plumbing before "exec" varies with the host (linux
// overlay) and .env (worktree overlay), so attach assertions must not depend on
// its length.
func execTail(t *testing.T, args []string) []string {
	t.Helper()
	for i, a := range args {
		if a == "exec" {
			return args[i+1:]
		}
	}
	t.Fatalf("args missing %q: %v", "exec", args)
	return nil
}

// TestServiceNames_GeminiRuntime covers the "lists" half of Epic #267 AC3 #3
// (#289): the dashboard derives account service names from the registry
// servicePrefix, so a gemini session enumerates gemini-a/gemini-b rather than
// falling back to claude-*.
func TestServiceNames_GeminiRuntime(t *testing.T) {
	env := config.NewEmptyEnv(filepath.Join(t.TempDir(), ".env"))
	env.Set("AGENT_RUNTIME", "gemini")
	env.Set("NUM_ACCOUNTS", "2")
	c := NewClient("/tmp/proj", env)

	got := c.ServiceNames()
	want := []string{"gemini-a", "gemini-b"}
	if len(got) != len(want) {
		t.Fatalf("ServiceNames len = %d, want %d (%v)", len(got), len(want), got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("ServiceNames[%d] = %q, want %q", i, got[i], want[i])
		}
	}
}

// TestExecArgs_GeminiAttach covers the "attaches" half of AC3 #3 by composing
// the two calls the dashboard makes together (ui/dashboard/update.go):
// ExecArgs(account service, env.RuntimeCommandArgs(skipPermissions)...). The
// resulting argv must match what `claude-docker gemini` produces on the shell
// side — the CLI equivalence is pinned by tests/test_agent_attach_argv.sh.
func TestExecArgs_GeminiAttach(t *testing.T) {
	env := config.NewEmptyEnv(filepath.Join(t.TempDir(), ".env"))
	env.Set("AGENT_RUNTIME", "gemini")
	env.Set("NUM_ACCOUNTS", "1")
	c := NewClient("/tmp/proj", env)

	cases := []struct {
		name            string
		skipPermissions bool
		want            []string
	}{
		{"plain attach", false, []string{"gemini-a", "gemini"}},
		{"skip permissions", true, []string{"gemini-a", "gemini", "--yolo"}},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			bin, args, err := c.ExecArgs("gemini-a", env.RuntimeCommandArgs(tc.skipPermissions)...)
			if err != nil {
				t.Fatalf("ExecArgs: %v", err)
			}
			if bin != "docker" {
				t.Errorf("bin = %q, want %q", bin, "docker")
			}
			got := execTail(t, args)
			if len(got) != len(tc.want) {
				t.Fatalf("exec tail = %v, want %v", got, tc.want)
			}
			for i := range tc.want {
				if got[i] != tc.want[i] {
					t.Errorf("exec tail[%d] = %q, want %q (full args=%v)", i, got[i], tc.want[i], args)
				}
			}
		})
	}
}
