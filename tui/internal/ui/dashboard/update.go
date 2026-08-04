package dashboard

import (
	"os/exec"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

// Update handles messages.
func (m Model) Update(msg tea.Msg) (Model, tea.Cmd) {
	switch msg := msg.(type) {
	case accountsLoadedMsg:
		m.loading = false
		m.refreshing = false
		m.accounts = msg.accounts
		m.err = msg.err
		m.lastRefreshAt = time.Now()
		// If any account is rate-limited, set next retry deadline and start a single 1s tick chain
		if m.hasRateLimitedAccounts() {
			m.nextRetryAt = m.lastRefreshAt.Add(30 * time.Second)
			// Only start a new tick if no chain is currently running
			if !m.tickActive {
				m.tickActive = true
				return m, tea.Tick(time.Second, func(time.Time) tea.Msg {
					return uiTickMsg{}
				})
			}
			return m, nil
		}
		m.nextRetryAt = time.Time{}
		m.tickActive = false
		return m, nil

	case uiTickMsg:
		// If refresh is in-flight, just reschedule without doing anything
		if m.refreshing {
			return m, tea.Tick(time.Second, func(time.Time) tea.Msg {
				return uiTickMsg{}
			})
		}
		// If nextRetryAt has arrived, trigger refresh once
		if !m.nextRetryAt.IsZero() && !time.Now().Before(m.nextRetryAt) {
			m.retryCount++
			m.refreshing = true
			m.nextRetryAt = time.Time{} // clear until refresh completes
			m.manager.ClearAPICooldowns()
			return m, tea.Batch(
				m.Refresh(),
				tea.Tick(time.Second, func(time.Time) tea.Msg {
					return uiTickMsg{}
				}),
			)
		}
		// Still counting down: keep ticking
		if !m.nextRetryAt.IsZero() {
			return m, tea.Tick(time.Second, func(time.Time) tea.Msg {
				return uiTickMsg{}
			})
		}
		// Done — stop the tick chain
		m.tickActive = false
		return m, nil

	case sessionFinishedMsg:
		// After an attached agent session ends, refresh account list.
		return m, m.Refresh()

	case dockerOpDoneMsg:
		m.busy = false
		switch msg.kind {
		case opUp:
			m = m.toast(opResultText("Up", msg.err), levelOf(msg.err))
		case opDown:
			m = m.toast(opResultText("Down", msg.err), levelOf(msg.err))
		case opBuild:
			m = m.toast(opResultText("Build", msg.err), levelOf(msg.err))
		case opBuildNoCache:
			m = m.toast(opResultText("Rebuild (no-cache)", msg.err), levelOf(msg.err))
		case opRestart:
			m = m.toast(opResultText("Restart", msg.err), levelOf(msg.err))
		case opUpdateBuild:
			if msg.err != nil {
				m = m.toast(opResultText("Update (build)", msg.err), statusErr)
				return m, m.toastExpireCmd()
			}
			// Chain into recreate stage.
			m.busy = true
			bin, args := m.client.UpRecreateArgs()
			cmd := exec.Command(bin, args...)
			return m, tea.ExecProcess(cmd, func(err error) tea.Msg {
				return dockerOpDoneMsg{kind: opUpdateRecreate, err: err}
			})
		case opUpdateRecreate:
			m = m.toast(opResultText("Update", msg.err), levelOf(msg.err))
		case opGHAuthRecreate:
			m = m.toast(opResultText("GitHub auth + recreate", msg.err), levelOf(msg.err))
		}
		return m, tea.Batch(m.Refresh(), m.toastExpireCmd())

	case ghAuthAppliedMsg:
		if msg.err != nil {
			m.busy = false
			m = m.toast("gh-auth: "+msg.err.Error(), statusErr)
			return m, m.toastExpireCmd()
		}
		if !msg.recreateNeeded {
			m.busy = false
			m = m.toast("GitHub token written for "+msg.label+" (container not running)", statusOK)
			return m, tea.Batch(m.Refresh(), m.toastExpireCmd())
		}
		// Containers are running — recreate them so the new GH_TOKEN takes effect.
		bin, args := m.client.UpRecreateArgs(msg.services...)
		cmd := exec.Command(bin, args...)
		return m, tea.ExecProcess(cmd, func(err error) tea.Msg {
			return dockerOpDoneMsg{kind: opGHAuthRecreate, err: err}
		})

	case statusExpiredMsg:
		if !m.statusExpiry.IsZero() && !time.Now().Before(m.statusExpiry) {
			m.statusText = ""
			m.statusExpiry = time.Time{}
		}
		return m, nil

	case tea.KeyMsg:
		// When a background/blocking op is in flight, ignore everything except quit.
		if m.busy {
			return m, nil
		}
		// Help overlay is modal: any key other than quit closes it.
		if m.showHelp {
			m.showHelp = false
			return m, nil
		}

		switch msg.String() {
		case "j", "down":
			if m.cursor < len(m.accounts)-1 {
				m.cursor++
			}
		case "k", "up":
			if m.cursor > 0 {
				m.cursor--
			}
		case "enter", "c":
			// Attach to selected account's agent session.
			if m.cursor < len(m.accounts) {
				acct := m.accounts[m.cursor]
				if acct.IsRunning() {
					bin, args := m.client.ExecArgs(acct.ServiceName, m.env.RuntimeCommandArgs(m.skipPermissions)...)
					cmd := exec.Command(bin, args...)
					return m, tea.ExecProcess(cmd, func(err error) tea.Msg {
						return sessionFinishedMsg{err: err}
					})
				}
			}
		case "u":
			m.busy = true
			m = m.toast("Starting containers (docker compose up -d)...", statusInfo)
			client := m.client
			return m, func() tea.Msg {
				err := client.Up()
				return dockerOpDoneMsg{kind: opUp, err: err}
			}
		case "d":
			m.busy = true
			m = m.toast("Stopping containers (docker compose down)...", statusInfo)
			client := m.client
			return m, func() tea.Msg {
				err := client.Down()
				return dockerOpDoneMsg{kind: opDown, err: err}
			}
		case "r":
			if m.refreshing {
				return m, nil // already refreshing, ignore
			}
			m.manager.ClearAPICooldowns()
			m.refreshing = true
			m.retryCount++ // manual refresh counts as a retry
			return m, m.Refresh()

		case "b":
			m.busy = true
			bin, args := m.client.BuildArgs(false)
			cmd := exec.Command(bin, args...)
			return m, tea.ExecProcess(cmd, func(err error) tea.Msg {
				return dockerOpDoneMsg{kind: opBuild, err: err}
			})

		case "B":
			m.busy = true
			bin, args := m.client.BuildArgs(true)
			cmd := exec.Command(bin, args...)
			return m, tea.ExecProcess(cmd, func(err error) tea.Msg {
				return dockerOpDoneMsg{kind: opBuildNoCache, err: err}
			})

		case "U":
			// Two-stage chain: build --no-cache → up -d --force-recreate.
			m.busy = true
			bin, args := m.client.BuildArgs(true)
			cmd := exec.Command(bin, args...)
			return m, tea.ExecProcess(cmd, func(err error) tea.Msg {
				return dockerOpDoneMsg{kind: opUpdateBuild, err: err}
			})

		case "R":
			if m.cursor >= len(m.accounts) {
				return m, nil
			}
			svc := m.accounts[m.cursor].ServiceName
			m.busy = true
			bin, args := m.client.RestartArgs(svc)
			cmd := exec.Command(bin, args...)
			return m, tea.ExecProcess(cmd, func(err error) tea.Msg {
				return dockerOpDoneMsg{kind: opRestart, err: err}
			})

		case "p":
			m.skipPermissions = !m.skipPermissions
			flag := m.env.SkipPermissionsFlag()
			if m.skipPermissions {
				m = m.toast(flag+" ON", statusInfo)
			} else {
				m = m.toast(flag+" OFF", statusInfo)
			}
			return m, m.toastExpireCmd()

		case "g":
			return m.startGHAuth()

		case "?":
			m.showHelp = true
			return m, nil
		}
	}

	return m, nil
}
