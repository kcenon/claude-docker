// Package docker provides a thin shell-out wrapper around `docker compose`.
package docker

import (
	"errors"
	"fmt"
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

// modeOverlay maps a resolved isolation mode to the compose overlay it selects.
// An empty string means the mode adds no overlay.
//
// This is one half of a contract whose other half is the `case` block in
// build_compose_cmd (scripts/lib/build-compose-cmd.sh). A mode added to one
// side and not the other is what put this table out of step in the first
// place, so TestOverlayTableMatchesBash reads that `case` and compares it
// against this map rather than trusting a comment to keep them aligned.
var modeOverlay = map[string]string{
	config.IsolationShared:   "",
	config.IsolationWorktree: "docker-compose.worktree.yml",
	config.IsolationIsolated: "docker-compose.isolated.yml",
}

// BuildComposeArgs builds the `docker compose -f ...` prefix for the TUI,
// following the same rules as build_compose_cmd in
// scripts/lib/build-compose-cmd.sh:
//
//  1. docker-compose.yml is always included, and is not stat'd.
//  2. docker-compose.linux.yml is added on Linux when the file exists. This
//     one is genuinely "add when present" in bash too.
//  3. The overlay named by the resolved ISOLATION_MODE is added. A mode that
//     names an overlay which is not on disk is an error, not a silent
//     omission -- dropping it would leave every account on the base stack's
//     shared read-write /project mount, which is the exact fallback these
//     modes exist to prevent. An unrecognized mode is likewise an error.
//
// Selection keys off env.IsolationMode(), not env.HasWorktrees(). Those agree
// for a Tier B install predating the ISOLATION_MODE key, because
// IsolationMode() still infers worktree from PROJECT_DIR_A; they disagree for
// every isolated install, where the old branch picked the worktree overlay or
// none at all.
func BuildComposeArgs(projectRoot string, env *config.Env) ([]string, error) {
	args := []string{"compose", "-f", filepath.Join(projectRoot, "docker-compose.yml")}
	if runtime.GOOS == "linux" {
		linuxOverlay := filepath.Join(projectRoot, "docker-compose.linux.yml")
		if fileExists(linuxOverlay) {
			args = append(args, "-f", linuxOverlay)
		}
	}

	// IsolationMode has a nil-receiver guard and answers "shared", which is
	// the right answer for a TUI that could not load .env at all.
	mode := env.IsolationMode()
	overlay, known := modeOverlay[mode]
	if !known {
		return nil, fmt.Errorf(
			"ISOLATION_MODE=%s is not one of shared, worktree, isolated; "+
				"refusing to start on a weaker boundary than the one configured", mode)
	}
	if overlay == "" {
		return args, nil
	}

	overlayPath := filepath.Join(projectRoot, overlay)
	if !fileExists(overlayPath) {
		return nil, fmt.Errorf(
			"ISOLATION_MODE=%s but %s is missing; "+
				"regenerate it with scripts/generate-compose.sh before starting containers",
			mode, overlay)
	}
	return append(args, "-f", overlayPath), nil
}
