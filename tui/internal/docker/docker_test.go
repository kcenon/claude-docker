package docker

import (
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/kcenon/claude-docker/tui/internal/config"
)

// TestBuildComposeArgs verifies the base compose file is always present and
// that the Linux overlay and worktree overlay are added under the right
// conditions. CI runs on Linux so the Linux branch always fires there;
// we still assert the OS-conditional logic explicitly so the test passes
// on macOS/Windows local runs too.
func TestBuildComposeArgs(t *testing.T) {
	root := "/tmp/proj"
	baseFile := filepath.Join(root, "docker-compose.yml")
	linuxFile := filepath.Join(root, "docker-compose.linux.yml")
	worktreeFile := filepath.Join(root, "docker-compose.worktree.yml")

	containsArg := func(args []string, want string) bool {
		for _, a := range args {
			if a == want {
				return true
			}
		}
		return false
	}

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
