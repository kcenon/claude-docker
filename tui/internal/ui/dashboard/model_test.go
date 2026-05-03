package dashboard

import (
	"testing"

	"github.com/charmbracelet/lipgloss"
)

func TestPadPlainAscii(t *testing.T) {
	got := padPlain("hello", 10)
	if w := lipgloss.Width(got); w != 10 {
		t.Fatalf("ascii: visual width = %d, want 10", w)
	}
}

func TestPadPlainHangul(t *testing.T) {
	// "한글" is 2 runes, each 2 columns wide -> visual width 4
	got := padPlain("한글", 10)
	if w := lipgloss.Width(got); w != 10 {
		t.Fatalf("hangul: visual width = %d, want 10", w)
	}
}

func TestPadPlainMixed(t *testing.T) {
	got := padPlain("hi 한", 10)
	if w := lipgloss.Width(got); w != 10 {
		t.Fatalf("mixed: visual width = %d, want 10", w)
	}
}

func TestPadPlainAlreadyWide(t *testing.T) {
	s := "hello world"
	got := padPlain(s, 5)
	if got != s {
		t.Fatalf("over-width: returned %q, want unchanged", got)
	}
}
