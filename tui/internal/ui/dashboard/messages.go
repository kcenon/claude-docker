package dashboard

import (
	"github.com/kcenon/claude-docker/tui/internal/account"
)

type accountsLoadedMsg struct {
	accounts []account.Account
	err      error
}

type sessionFinishedMsg struct{ err error }

type uiTickMsg struct{} // 1-second tick drives both countdown display AND scheduled retry

// dockerOpDoneMsg arrives after a tea.ExecProcess handoff returns.
// kind lets the reducer decide whether to chain to the next stage
// (e.g. build → recreate during `U` update).
type dockerOpDoneMsg struct {
	kind opKind
	err  error
}

// ghAuthAppliedMsg is emitted after the gh-token write step completes.
// recreateNeeded = true triggers a follow-up `up -d --force-recreate` handoff.
type ghAuthAppliedMsg struct {
	err            error
	recreateNeeded bool
}

// statusExpiredMsg clears any stale toast once its TTL has passed.
type statusExpiredMsg struct{}
