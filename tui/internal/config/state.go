package config

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// StateDir represents a single account's state directory.
type StateDir struct {
	Letter string // e.g., "a"
	Path   string // e.g., ~/.claude-state/account-a
}

// CredentialsPath returns the path to .credentials.json in this state dir.
func (s StateDir) CredentialsPath() string {
	return filepath.Join(s.Path, ".credentials.json")
}

// LimitlineCachePath returns the path to the limitline usage cache.
func (s StateDir) LimitlineCachePath() string {
	return filepath.Join(s.Path, "limitline-usage-cache.json")
}

// ProjectsDir returns the path to the projects directory.
func (s StateDir) ProjectsDir() string {
	return filepath.Join(s.Path, "projects")
}

// HasCredentials returns true if .credentials.json exists.
func (s StateDir) HasCredentials() bool {
	_, err := os.Stat(s.CredentialsPath())
	return err == nil
}

// HasLimitlineCache returns true if limitline-usage-cache.json exists.
func (s StateDir) HasLimitlineCache() bool {
	_, err := os.Stat(s.LimitlineCachePath())
	return err == nil
}

// DiscoverStateDirs finds all account state directories under ~/.claude-state/.
func DiscoverStateDirs() ([]StateDir, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil, fmt.Errorf("resolve home dir: %w", err)
	}
	return DiscoverStateDirsAt(filepath.Join(home, ".claude-state"))
}

// DiscoverStateDirsAt finds account state directories under the given base path.
func DiscoverStateDirsAt(basePath string) ([]StateDir, error) {
	entries, err := os.ReadDir(basePath)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, fmt.Errorf("read state dir: %w", err)
	}

	var dirs []StateDir
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		name := e.Name()
		if !strings.HasPrefix(name, "account-") {
			continue
		}
		letter := strings.TrimPrefix(name, "account-")
		if len(letter) != 1 || letter[0] < 'a' || letter[0] > 'z' {
			continue
		}
		dirs = append(dirs, StateDir{
			Letter: letter,
			Path:   filepath.Join(basePath, name),
		})
	}

	sort.Slice(dirs, func(i, j int) bool {
		return dirs[i].Letter < dirs[j].Letter
	})

	return dirs, nil
}
