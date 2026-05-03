// Package docker provides a thin shell-out wrapper around `docker compose`.
package docker

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"runtime"

	"github.com/kcenon/claude-docker/tui/internal/config"
)

// fileExists reports whether path resolves to an existing file or directory.
// Errors other than ErrNotExist (permission denied, etc.) are treated as
// "exists" so that the caller does not silently skip an overlay that the
// user actually placed on disk.
func fileExists(path string) bool {
	if _, err := os.Stat(path); err != nil {
		return !errors.Is(err, fs.ErrNotExist)
	}
	return true
}

// BuildComposeArgs replicates the overlay logic from scripts/claude-docker.
// Adds docker-compose.linux.yml on Linux only when the file exists, and
// docker-compose.worktree.yml when PROJECT_DIR_A is set and the worktree
// override file exists. The file-existence checks match the canonical bash
// implementation in scripts/lib/build-compose-cmd.sh.
func BuildComposeArgs(projectRoot string, env *config.Env) []string {
	args := []string{"compose", "-f", filepath.Join(projectRoot, "docker-compose.yml")}
	if runtime.GOOS == "linux" {
		linuxOverlay := filepath.Join(projectRoot, "docker-compose.linux.yml")
		if fileExists(linuxOverlay) {
			args = append(args, "-f", linuxOverlay)
		}
	}
	if env != nil && env.HasWorktrees() {
		worktreeOverlay := filepath.Join(projectRoot, "docker-compose.worktree.yml")
		if fileExists(worktreeOverlay) {
			args = append(args, "-f", worktreeOverlay)
		}
	}
	return args
}
