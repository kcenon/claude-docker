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

// DailyOptions returns options for today's entries (KST local).
func DailyOptions() AggregateOptions {
	now := time.Now()
	start := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, now.Location())
	return AggregateOptions{Since: &start}
}

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
