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
	Letter string // e.g., "a" or "aa"
	Path   string // e.g., ~/.claude-state/account-a or -account-aa
}

// isValidAccountLetter reports whether s is a non-empty lowercase letter
// sequence that round-trips through LetterToIndex / IndexToLetter.
func isValidAccountLetter(s string) bool {
	if len(s) == 0 {
		return false
	}
	for i := 0; i < len(s); i++ {
		if s[i] < 'a' || s[i] > 'z' {
			return false
		}
	}
	return LetterToIndex(s) > 0 && LetterToIndex(s) <= 702
}

// CredentialsPath returns the path to .credentials.json in this state dir.
func (s StateDir) CredentialsPath() string {
	return filepath.Join(s.Path, ".credentials.json")
}

// CodexAuthPath returns the path to Codex auth.json in this state dir.
func (s StateDir) CodexAuthPath() string {
	return filepath.Join(s.Path, "auth.json")
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

// HasCodexAuth returns true if Codex auth.json exists.
func (s StateDir) HasCodexAuth() bool {
	_, err := os.Stat(s.CodexAuthPath())
	return err == nil
}

// OAuthCredentialPath returns the path to the runtime's OAuth credential
// file (e.g. .credentials.json for Claude, auth.json for Codex) inside
// this state dir, sourced from the runtime registry.
func (s StateDir) OAuthCredentialPath(spec RuntimeSpec) string {
	return filepath.Join(s.Path, spec.OAuthCredentialFile)
}

// HasAnyCredential reports whether any of the runtime's credential files
// exist in this state dir. The registry's credentialFiles entry is a
// space-separated list, so each candidate is checked in turn.
func (s StateDir) HasAnyCredential(spec RuntimeSpec) bool {
	for _, name := range strings.Fields(spec.CredentialFiles) {
		if _, err := os.Stat(filepath.Join(s.Path, name)); err == nil {
			return true
		}
	}
	return false
}

// HasLimitlineCache returns true if limitline-usage-cache.json exists.
func (s StateDir) HasLimitlineCache() bool {
	_, err := os.Stat(s.LimitlineCachePath())
	return err == nil
}

// DiscoverStateDirs finds all account state directories under ~/.claude-state/.
func DiscoverStateDirs() ([]StateDir, error) {
	return DiscoverStateDirsForRuntime(RuntimeClaude)
}

// StateDirNameForRuntime returns the host-side state directory name.
func StateDirNameForRuntime(runtime string) string {
	if runtime == RuntimeCodex {
		return ".codex-state"
	}
	return ".claude-state"
}

// DiscoverStateDirsForRuntime finds all account state directories for runtime.
func DiscoverStateDirsForRuntime(runtime string) ([]StateDir, error) {
	home, err := userHomeDir()
	if err != nil {
		return nil, fmt.Errorf("resolve home dir: %w", err)
	}
	return DiscoverStateDirsAt(filepath.Join(home, StateDirNameForRuntime(runtime)))
}

func userHomeDir() (string, error) {
	if home := os.Getenv("HOME"); home != "" {
		return home, nil
	}
	return os.UserHomeDir()
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
		// Accept Excel-style letters (a-z, aa-zz) so state directories for
		// NUM_ACCOUNTS > 26 are discovered.
		if !isValidAccountLetter(letter) {
			continue
		}
		dirs = append(dirs, StateDir{
			Letter: letter,
			Path:   filepath.Join(basePath, name),
		})
	}

	// Sort by the 1-based account index so the caller sees a, b, ..., z,
	// aa, ab, ..., rather than the lexical order which would interleave
	// "aa" between "a" and "b".
	sort.Slice(dirs, func(i, j int) bool {
		return LetterToIndex(dirs[i].Letter) < LetterToIndex(dirs[j].Letter)
	})

	return dirs, nil
}
