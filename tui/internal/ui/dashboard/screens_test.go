package dashboard

import (
	"errors"
	"path/filepath"
	"strings"
	"testing"

	"github.com/kcenon/claude-docker/tui/internal/account"
	"github.com/kcenon/claude-docker/tui/internal/config"
)

func plainView(m Model) string {
	return ansiEscape.ReplaceAllString(m.View(), "")
}

// TestThreeDistinctScreens covers #358 item 9.
//
// ListAccounts returned a nil error unconditionally, so Model.err had no
// writer anywhere and view.go's error branch was unreachable code. The
// consequence on screen: a docker daemon that is down rendered exactly like
// an install whose containers had simply never been created. The two want
// opposite responses -- `u` fixes the second and cannot touch the first.
func TestThreeDistinctScreens(t *testing.T) {
	env := config.NewEmptyEnv(filepath.Join(t.TempDir(), ".env"))
	accounts := []account.Account{
		{Letter: "a", ServiceName: "claude-a"},
		{Letter: "b", ServiceName: "claude-b"},
	}
	dockerDown := errors.New("container status unavailable: docker compose ps: exec: \"docker\": not found")

	t.Run("docker down with nothing to show", func(t *testing.T) {
		m := New(nil, nil, env, false)
		m.loading = false
		m.err = dockerDown
		m.SetSize(120, 40)

		got := plainView(m)
		if !strings.Contains(got, "Error:") {
			t.Errorf("expected the error screen:\n%s", got)
		}
		if !strings.Contains(got, "docker") {
			t.Errorf("the error should name what failed:\n%s", got)
		}
		if strings.Contains(got, "No accounts configured") {
			t.Errorf("a docker failure must not read as an empty install:\n%s", got)
		}
	})

	t.Run("no accounts and docker is fine", func(t *testing.T) {
		m := New(nil, nil, env, false)
		m.loading = false
		m.SetSize(120, 40)

		got := plainView(m)
		if !strings.Contains(got, "No accounts configured") {
			t.Errorf("expected the empty-install screen:\n%s", got)
		}
		if strings.Contains(got, "Error:") {
			t.Errorf("an empty install is not an error:\n%s", got)
		}
	})

	t.Run("accounts discovered but docker is down", func(t *testing.T) {
		m := New(nil, nil, env, false)
		m.loading = false
		m.err = dockerDown
		m.accounts = accounts
		m.SetSize(120, 40)

		got := plainView(m)
		// The table wins: the accounts came from the state directories and
		// are worth showing even with an unknown container column.
		if !strings.Contains(got, "claude-a") || !strings.Contains(got, "SERVICE") {
			t.Errorf("the table should still render:\n%s", got)
		}
		// ...but the reason every STATUS cell reads "--" has to be on screen,
		// or this is the indistinguishable case again.
		if !strings.Contains(got, "Warning:") || !strings.Contains(got, "docker") {
			t.Errorf("the degradation should be named above the table:\n%s", got)
		}
		if strings.Contains(got, "Press [r] to retry") {
			t.Errorf("the full-screen error should not replace a usable table:\n%s", got)
		}
	})

	t.Run("everything fine", func(t *testing.T) {
		m := New(nil, nil, env, false)
		m.loading = false
		m.accounts = accounts
		m.SetSize(120, 40)

		got := plainView(m)
		if strings.Contains(got, "Warning:") || strings.Contains(got, "Error:") {
			t.Errorf("a healthy dashboard should say neither:\n%s", got)
		}
		if !strings.Contains(got, "claude-b") {
			t.Errorf("the table should render:\n%s", got)
		}
	})
}

// TestBannerReportsAClampedAccountCount covers #358 item 12's "with a visible
// message" half. The shell generators clamp silently; the dashboard clamping
// silently is what would leave it disagreeing with the number in .env with
// nothing to explain the difference.
func TestBannerReportsAClampedAccountCount(t *testing.T) {
	env := config.NewEmptyEnv(filepath.Join(t.TempDir(), ".env"))
	env.Set("NUM_ACCOUNTS", "1000")

	got := ansiEscape.ReplaceAllString(renderIsolationBanner(env), "")
	if !strings.Contains(got, "NUM_ACCOUNTS=1000") {
		t.Errorf("the banner should quote the configured value:\n%s", got)
	}
	if !strings.Contains(got, "702") {
		t.Errorf("the banner should name the cap:\n%s", got)
	}
}

// TestBannerSaysNothingAboutAUsableAccountCount keeps the warning from being
// permanent furniture.
func TestBannerSaysNothingAboutAUsableAccountCount(t *testing.T) {
	env := config.NewEmptyEnv(filepath.Join(t.TempDir(), ".env"))
	env.Set("NUM_ACCOUNTS", "4")

	got := ansiEscape.ReplaceAllString(renderIsolationBanner(env), "")
	if strings.Contains(got, "NUM_ACCOUNTS") {
		t.Errorf("a usable count should produce no warning:\n%s", got)
	}
}
