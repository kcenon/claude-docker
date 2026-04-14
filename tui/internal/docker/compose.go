// Package docker provides a thin shell-out wrapper around `docker compose`.
package docker

import (
	"path/filepath"
	"runtime"

	"github.com/kcenon/claude-docker/tui/internal/config"
)

// BuildComposeArgs replicates the overlay logic from scripts/claude-docker.
// Adds docker-compose.linux.yml on Linux, docker-compose.worktree.yml when PROJECT_DIR_A is set.
func BuildComposeArgs(projectRoot string, env *config.Env) []string {
	args := []string{"compose", "-f", filepath.Join(projectRoot, "docker-compose.yml")}
	if runtime.GOOS == "linux" {
		args = append(args, "-f", filepath.Join(projectRoot, "docker-compose.linux.yml"))
	}
	if env != nil && env.HasWorktrees() {
		args = append(args, "-f", filepath.Join(projectRoot, "docker-compose.worktree.yml"))
	}
	return args
}
