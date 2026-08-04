package docker

import (
	"os"
	"path/filepath"
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

	// Pre-create the overlay files so the file-existence checks pass for the
	// scenarios that exercise the "overlay should be added" path. The base
	// compose path itself is not stat'd by BuildComposeArgs; it is always
	// included regardless of whether the file exists on disk, matching the
	// canonical bash implementation.
	writeFile(t, linuxFile)
	writeFile(t, worktreeFile)

	t.Run("base only nil env", func(t *testing.T) {
		args := BuildComposeArgs(root, nil)
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
		args := BuildComposeArgs(root, nil)
		hasLinux := containsArg(args, linuxFile)
		if runtime.GOOS == "linux" && !hasLinux {
			t.Errorf("linux: expected %q in args %v", linuxFile, args)
		}
		if runtime.GOOS != "linux" && hasLinux {
			t.Errorf("%s: %q should not be present", runtime.GOOS, linuxFile)
		}
	})

	t.Run("worktree overlay added when PROJECT_DIR_A set", func(t *testing.T) {
		env := config.NewEmptyEnv("/tmp/.env")
		env.Set("PROJECT_DIR_A", "/some/path")
		args := BuildComposeArgs(root, env)
		if !containsArg(args, worktreeFile) {
			t.Errorf("worktree file %q missing in %v", worktreeFile, args)
		}
	})
}

// TestBuildComposeArgs_FileMissing verifies the file-existence check: when
// an overlay file is not present on disk, BuildComposeArgs must omit the
// corresponding `-f` argument even if the host conditions (Linux / worktree
// env) would otherwise select it. This matches the canonical bash logic
// in scripts/lib/build-compose-cmd.sh.
func TestBuildComposeArgs_FileMissing(t *testing.T) {
	root := t.TempDir()
	baseFile := filepath.Join(root, "docker-compose.yml")
	linuxFile := filepath.Join(root, "docker-compose.linux.yml")
	worktreeFile := filepath.Join(root, "docker-compose.worktree.yml")
	// Deliberately do NOT create linuxFile or worktreeFile — only the empty
	// temp dir exists. The base file is also absent; the bash canonical
	// version does not stat the base file either, so neither does the Go
	// port: the base path is unconditionally included.

	t.Run("linux overlay omitted when file missing", func(t *testing.T) {
		args := BuildComposeArgs(root, nil)
		if !containsArg(args, baseFile) {
			t.Errorf("base file %q should always be present in %v", baseFile, args)
		}
		if containsArg(args, linuxFile) {
			t.Errorf("linux overlay %q must be omitted when file does not exist (args=%v)", linuxFile, args)
		}
	})

	t.Run("worktree overlay omitted when file missing even with PROJECT_DIR_A", func(t *testing.T) {
		env := config.NewEmptyEnv(filepath.Join(root, ".env"))
		env.Set("PROJECT_DIR_A", "/some/path")
		args := BuildComposeArgs(root, env)
		if containsArg(args, worktreeFile) {
			t.Errorf("worktree overlay %q must be omitted when file does not exist (args=%v)", worktreeFile, args)
		}
	})
}

// TestExecArgs verifies the binary is "docker", the compose plumbing comes
// before "exec", "exec" precedes the service name, and user-supplied
// command tokens follow the service name in order.
func TestExecArgs(t *testing.T) {
	c := NewClient("/tmp/proj", nil)
	bin, args := c.ExecArgs("claude-a", "bash", "-lc", "ls")

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
			bin, args := c.BuildArgs(tc.noCache)
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
	bin, args := c.UpRecreateArgs()

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
	_, args := c.UpRecreateArgs("claude-b")
	if got := args[len(args)-1]; got != "claude-b" {
		t.Errorf("last arg = %q, want claude-b (args=%v)", got, args)
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
			bin, args := c.ExecArgs("gemini-a", env.RuntimeCommandArgs(tc.skipPermissions)...)
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
