package usage

import "time"

// TokenTotals aggregates token counts across sessions.
type TokenTotals struct {
	InputTokens              int64
	OutputTokens             int64
	CacheCreationInputTokens int64
	CacheReadInputTokens     int64
}

// AggregateOptions controls filtering when aggregating.
type AggregateOptions struct {
	Since *time.Time // if set, only entries at or after this time are counted
}

// AllTimeOptions returns options that include all entries.
func AllTimeOptions() AggregateOptions {
	return AggregateOptions{}
}

// DailyOptions was removed in #358 (item 13). Its doc comment promised
// "today's entries (KST local)" while the body used time.Now().Location(),
// the machine-local zone -- so on any host not set to Asia/Seoul it silently
// selected a different day than it claimed. It had no caller outside its own
// test, so there was nothing to make correct: a KST-fixed version would have
// been dead code that merely told the truth.

// AggregateSessions sums token usage across all entries matching options.
func AggregateSessions(sessions []Session, opts AggregateOptions) TokenTotals {
	var totals TokenTotals
	for _, s := range sessions {
		for _, e := range s.Entries {
			if !matchesOptions(e, opts) {
				continue
			}
			totals.InputTokens += e.Message.Usage.InputTokens
			totals.OutputTokens += e.Message.Usage.OutputTokens
			totals.CacheCreationInputTokens += e.Message.Usage.CacheCreationInputTokens
			totals.CacheReadInputTokens += e.Message.Usage.CacheReadInputTokens
		}
	}
	return totals
}

// CountFilteredSessions returns the number of sessions that have at least one matching entry.
func CountFilteredSessions(sessions []Session, opts AggregateOptions) int {
	count := 0
	for _, s := range sessions {
		for _, e := range s.Entries {
			if matchesOptions(e, opts) {
				count++
				break
			}
		}
	}
	return count
}

func matchesOptions(e SessionEntry, opts AggregateOptions) bool {
	if opts.Since != nil {
		if e.Timestamp == "" {
			return false
		}
		ts, err := time.Parse(time.RFC3339, e.Timestamp)
		if err != nil {
			return false
		}
		if ts.Before(*opts.Since) {
			return false
		}
	}
	return true
}
