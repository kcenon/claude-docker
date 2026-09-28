package account

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/kcenon/claude-docker/tui/internal/config"
	"github.com/kcenon/claude-docker/tui/internal/docker"
)

type benchmarkContainers struct{}

func (benchmarkContainers) PS() ([]docker.ContainerInfo, error) { return nil, nil }

// BenchmarkListAccounts measures the actual dashboard refresh orchestrator.
// Docker is mocked as stopped and credentials are absent, so no provider or
// host authentication API participates. Projects history is irrelevant to the
// current product; current limitline data is read and varies independently.
func BenchmarkListAccounts(b *testing.B) {
	for _, accounts := range []int{1, 2, 4} {
		for _, histories := range []int{10, 10000} {
			for _, cacheBytes := range []int{256, 65536} {
				b.Run(fmt.Sprintf("accounts=%d/history=%d/cache=%d", accounts, histories, cacheBytes), func(b *testing.B) {
					home := b.TempDir()
					b.Setenv("HOME", home)
					b.Setenv("USERPROFILE", home)
					env := config.NewEmptyEnv(filepath.Join(home, ".env"))
					env.Set("NUM_ACCOUNTS", fmt.Sprint(accounts))
					for i := 1; i <= accounts; i++ {
						letter := config.IndexToLetter(i)
						dir := filepath.Join(home, ".claude-state", "account-"+letter)
						projects := filepath.Join(dir, "projects", "synthetic")
						if err := os.MkdirAll(projects, 0700); err != nil {
							b.Fatal(err)
						}
						for j := 0; j < histories; j++ {
							if err := os.WriteFile(filepath.Join(projects, fmt.Sprintf("session-%05d.jsonl", j)), []byte("{\"type\":\"fixture\"}\n"), 0600); err != nil {
								b.Fatal(err)
							}
						}
						state := config.StateDir{Path: dir}
						cache := fmt.Sprintf(`{"usage":{"fiveHour":{"percentUsed":%d,"resetAt":%q},"sevenDay":{"percentUsed":%d,"resetAt":%q}},"fixture_padding":"%s"}`, i*10, time.Now().Add(24*time.Hour).UTC().Format(time.RFC3339), i*5, time.Now().Add(24*time.Hour).UTC().Format(time.RFC3339), strings.Repeat("x", cacheBytes))
						if err := os.WriteFile(state.LimitlineCachePath(), []byte(cache), 0600); err != nil {
							b.Fatal(err)
						}
					}
					manager := NewManager(env, benchmarkContainers{})
					b.ReportAllocs()
					b.ResetTimer()
					for i := 0; i < b.N; i++ {
						got, err := manager.ListAccounts()
						if err != nil || len(got) != accounts {
							b.Fatalf("accounts=%d err=%v", len(got), err)
						}
						if got[0].FiveHourUsage == nil {
							b.Fatal("benchmark did not read current limitline data")
						}
					}
				})
			}
		}
	}
}
