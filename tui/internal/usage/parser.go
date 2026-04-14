// Package usage provides JSONL session parsing and token aggregation.
package usage

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

// SessionEntry is a single assistant message with usage info.
type SessionEntry struct {
	Type    string `json:"type"`
	Message struct {
		Model string `json:"model"`
		Usage struct {
			InputTokens              int64 `json:"input_tokens"`
			OutputTokens             int64 `json:"output_tokens"`
			CacheCreationInputTokens int64 `json:"cache_creation_input_tokens"`
			CacheReadInputTokens     int64 `json:"cache_read_input_tokens"`
		} `json:"usage"`
	} `json:"message"`
	Timestamp string `json:"timestamp"`
	SessionID string `json:"sessionId"`
}

// Session represents a single JSONL session file with parsed entries.
type Session struct {
	Path    string
	Entries []SessionEntry
}

// ScanAccountSessions walks the projects dir and parses all .jsonl files.
func ScanAccountSessions(projectsDir string) ([]Session, error) {
	var sessions []Session
	if _, err := os.Stat(projectsDir); err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}

	err := filepath.WalkDir(projectsDir, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil // skip errors, continue walking
		}
		if d.IsDir() {
			return nil
		}
		if !strings.HasSuffix(path, ".jsonl") {
			return nil
		}
		s, err := parseSessionFile(path)
		if err != nil {
			return nil // skip unparseable files
		}
		sessions = append(sessions, s)
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("walk projects dir: %w", err)
	}
	return sessions, nil
}

func parseSessionFile(path string) (Session, error) {
	f, err := os.Open(path)
	if err != nil {
		return Session{}, err
	}
	defer f.Close()

	s := Session{Path: path}
	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 1024*1024), 10*1024*1024) // 10MB max line
	for scanner.Scan() {
		line := scanner.Bytes()
		var entry SessionEntry
		if err := json.Unmarshal(line, &entry); err != nil {
			continue
		}
		if entry.Type != "assistant" {
			continue
		}
		s.Entries = append(s.Entries, entry)
	}
	return s, scanner.Err()
}
