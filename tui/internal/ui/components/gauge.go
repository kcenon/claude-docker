// Package components provides reusable TUI widgets.
package components

import (
	"fmt"
	"time"

	"github.com/charmbracelet/lipgloss"
)

// parseResetTime parses reset timestamps in formats used by the Anthropic usage API.
// Handles RFC3339, RFC3339Nano, microsecond fractions, and +00:00 timezone offsets.
func parseResetTime(s string) (time.Time, error) {
	for _, layout := range []string{
		time.RFC3339Nano,
		time.RFC3339,
		"2006-01-02T15:04:05.999999Z07:00",
		"2006-01-02T15:04:05.000Z",
	} {
		if t, err := time.Parse(layout, s); err == nil {
			return t, nil
		}
	}
	return time.Time{}, fmt.Errorf("unparseable reset time: %s", s)
}

// FormatResetIn returns a compact relative time like "2h30m", "6d3h", "45m".
// Returns "now" if the reset time has passed, "--" if the timestamp is invalid.
func FormatResetIn(resetAt string) string {
	if resetAt == "" {
		return "--"
	}
	t, err := parseResetTime(resetAt)
	if err != nil {
		return "--"
	}
	d := time.Until(t)
	if d <= 0 {
		return "now"
	}
	days := int(d.Hours()) / 24
	hours := int(d.Hours()) % 24
	minutes := int(d.Minutes()) % 60
	switch {
	case days > 0:
		if hours > 0 {
			return fmt.Sprintf("%dd%dh", days, hours)
		}
		return fmt.Sprintf("%dd", days)
	case hours > 0:
		if minutes > 0 {
			return fmt.Sprintf("%dh%dm", hours, minutes)
		}
		return fmt.Sprintf("%dh", hours)
	default:
		return fmt.Sprintf("%dm", minutes)
	}
}

// RenderMiniGauge creates a compact gauge bar with percentage.
func RenderMiniGauge(percent int, width int) string {
	if percent < 0 {
		percent = 0
	}
	if percent > 100 {
		percent = 100
	}
	if width < 3 {
		width = 8
	}

	filled := width * percent / 100
	if filled > width {
		filled = width
	}

	bar := ""
	for i := 0; i < filled; i++ {
		bar += "█"
	}
	for i := filled; i < width; i++ {
		bar += "░"
	}

	color := lipgloss.Color("#22C55E") // green
	if percent >= 80 {
		color = lipgloss.Color("#EF4444") // red
	} else if percent >= 50 {
		color = lipgloss.Color("#EAB308") // yellow
	}

	return lipgloss.NewStyle().Foreground(color).Render(bar) +
		lipgloss.NewStyle().Foreground(lipgloss.Color("#6B7280")).Render(fmt.Sprintf(" %d%%", percent))
}
