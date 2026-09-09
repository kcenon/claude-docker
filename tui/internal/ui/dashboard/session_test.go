package dashboard

import (
	"errors"
	"strings"
	"testing"
)

func TestFailedAttachRemainsVisibleAfterTerminalReturn(t *testing.T) {
	m, cmd := (Model{}).Update(sessionFinishedMsg{err: errors.New("exit status 17")})
	if !strings.Contains(m.statusText, "Attach failed: exit status 17") || m.statusLevel != statusErr {
		t.Fatalf("failed attach disappeared on dashboard return: %q", m.statusText)
	}
	if cmd == nil {
		t.Fatal("dashboard refresh and toast expiration were not scheduled")
	}
}
