// Command envprobe prints one value as config.LoadEnv reads it.
//
// It exists for tests/test_parse_env_equivalence.sh, which compares the three
// .env readers -- bash parse_env_value, PowerShell Get-EnvValue, and this one
// -- against each other. internal/ packages cannot be imported from outside
// the module, so a shell harness has no way to reach LoadEnv without a command
// inside it.
//
// Deliberately not a debug flag on the TUI binary: this has to print exactly
// the value and nothing else, and it must keep working when the dashboard is
// mid-refactor.
//
//	go run ./cmd/envprobe <env-file> <key>
//
// Prints the value with no trailing newline, so the caller compares bytes.
// A file that cannot be read prints nothing and exits 1.
package main

import (
	"fmt"
	"os"

	"github.com/kcenon/claude-docker/tui/internal/config"
)

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintln(os.Stderr, "usage: envprobe <env-file> <key>")
		os.Exit(2)
	}

	env, err := config.LoadEnv(os.Args[1])
	if err != nil {
		fmt.Fprintf(os.Stderr, "envprobe: %v\n", err)
		os.Exit(1)
	}

	fmt.Print(env.Get(os.Args[2]))
}
