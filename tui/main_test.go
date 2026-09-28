package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"github.com/kcenon/claude-docker/tui/internal/account"
)

// TestIsProjectRootRequiresMoreThanACompseFile covers #358 item 7.
//
// resolveProjectRoot walks up from the executable and then from the cwd, so
// with docker-compose.yml as the only marker, running the TUI anywhere inside
// an unrelated compose project claimed that project as the root -- and `g`
// writes a GitHub token into <root>/.env, which an unrelated directory has no
// reason to be gitignoring.
func TestIsProjectRootRequiresMoreThanAComposeFile(t *testing.T) {
	t.Run("an unrelated compose project is rejected", func(t *testing.T) {
		dir := t.TempDir()
		writeFile(t, filepath.Join(dir, "docker-compose.yml"), "services: {}\n")

		if isProjectRoot(dir) {
			t.Error("a directory holding only docker-compose.yml must not be the project root")
		}
	})

	t.Run("scripts/claude-docker alone is not enough either", func(t *testing.T) {
		dir := t.TempDir()
		if err := os.MkdirAll(filepath.Join(dir, "scripts"), 0o755); err != nil {
			t.Fatalf("mkdir: %v", err)
		}
		writeFile(t, filepath.Join(dir, "scripts", "claude-docker"), "#!/usr/bin/env bash\n")

		if isProjectRoot(dir) {
			t.Error("the compose file is still required")
		}
	})

	t.Run("both markers present", func(t *testing.T) {
		dir := t.TempDir()
		writeFile(t, filepath.Join(dir, "docker-compose.yml"), "services: {}\n")
		if err := os.MkdirAll(filepath.Join(dir, "scripts"), 0o755); err != nil {
			t.Fatalf("mkdir: %v", err)
		}
		writeFile(t, filepath.Join(dir, "scripts", "claude-docker"), "#!/usr/bin/env bash\n")

		if !isProjectRoot(dir) {
			t.Error("a real checkout must be recognized")
		}
	})

	t.Run("the repository this test lives in", func(t *testing.T) {
		// The strongest available check that the markers were not chosen to
		// fit the test: the actual checkout has to satisfy them.
		root, err := filepath.Abs("..")
		if err != nil {
			t.Fatalf("abs: %v", err)
		}
		if !isProjectRoot(root) {
			t.Errorf("the claude-docker checkout at %s is not recognized as a project root", root)
		}
	})
}

func writeFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
}

// TestWriteJSONReportIsValidJSON covers #358 item 6.
//
// runJSON hand-assembled the document with fmt.Printf and %q. %q is Go
// quoting: a control character becomes \x00, which is not a JSON escape, so
// the whole document stops parsing. LastAPIStatus is built from an upstream
// error string, so it can carry one.
func TestWriteJSONReportIsValidJSON(t *testing.T) {
	pct := func(v int) *account.UsageBucket { return &account.UsageBucket{PercentUsed: v} }

	accounts := []account.Account{
		{
			ServiceName:     "claude-a",
			ContainerStatus: account.ContainerRunning,
			AuthType:        account.AuthOAuth,
			FiveHourUsage:   pct(42),
			SevenDayUsage:   pct(7),
		},
		{
			ServiceName:     "claude-b",
			ContainerStatus: account.ContainerNotCreated,
			AuthType:        account.AuthNone,
			APIRateLimited:  true,
			// The hostile case: a NUL, a bell, a newline, a tab, a quote and a
			// backslash, all of which reached this field verbatim before.
			LastAPIStatus: "err: \x00bad\x07\nresponse\t\"quoted\" C:\\path",
		},
	}

	var buf bytes.Buffer
	if err := writeJSONReport(&buf, "/home/node/claude-docker", "claude", accounts); err != nil {
		t.Fatalf("writeJSONReport: %v", err)
	}

	var back map[string]any
	if err := json.Unmarshal(buf.Bytes(), &back); err != nil {
		t.Fatalf("output is not valid JSON: %v\n%s", err, buf.String())
	}

	if back["project_root"] != "/home/node/claude-docker" {
		t.Errorf("project_root = %v", back["project_root"])
	}
	if back["runtime"] != "claude" {
		t.Errorf("runtime = %v", back["runtime"])
	}
	if back["num_accounts"] != float64(2) {
		t.Errorf("num_accounts = %v", back["num_accounts"])
	}

	list, ok := back["accounts"].([]any)
	if !ok || len(list) != 2 {
		t.Fatalf("accounts = %v", back["accounts"])
	}

	first, _ := list[0].(map[string]any)
	if first["service"] != "claude-a" || first["state"] != "running" || first["auth"] != "OAuth" {
		t.Errorf("first account = %v", first)
	}
	if first["5h"] != float64(42) || first["7d"] != float64(7) {
		t.Errorf("usage fields = %v / %v", first["5h"], first["7d"])
	}
	// omitempty: an account that is not rate-limited says nothing about it,
	// which is what the previous output did too.
	if _, present := first["api_rate_limited"]; present {
		t.Error("api_rate_limited should be omitted when false")
	}

	second, _ := list[1].(map[string]any)
	if second["api_rate_limited"] != true {
		t.Errorf("api_rate_limited = %v", second["api_rate_limited"])
	}
	// The control characters survive as data rather than breaking the syntax.
	if second["last_api_status"] != accounts[1].LastAPIStatus {
		t.Errorf("last_api_status did not round-trip:\n want %q\n got  %v",
			accounts[1].LastAPIStatus, second["last_api_status"])
	}
	// A missing usage bucket is JSON null, not the string "null".
	if second["5h"] != nil {
		t.Errorf("5h = %v, want null", second["5h"])
	}
}

// TestGoQuotingIsNotJSONQuoting demonstrates the premise the item-6 fix rests
// on, rather than leaving it as an assertion in a comment.
//
// %q produces a Go string literal. For the printable ASCII that dominates
// real values it is byte-identical to a JSON string, which is why the
// hand-assembled output worked for years. It diverges on exactly the input
// that reaches LastAPIStatus from an upstream error: \x00 is a valid Go escape
// and not a valid JSON one.
func TestGoQuotingIsNotJSONQuoting(t *testing.T) {
	const hostile = "err: \x00bad"

	goQuoted := []byte(`{"x": ` + fmt.Sprintf("%q", hostile) + `}`)
	var sink map[string]any
	if err := json.Unmarshal(goQuoted, &sink); err == nil {
		t.Fatalf("premise is wrong: %%q output parsed as JSON: %s", goQuoted)
	}

	// The encoder handles the same string.
	encoded, err := json.Marshal(map[string]string{"x": hostile})
	if err != nil {
		t.Fatalf("Marshal: %v", err)
	}
	if err := json.Unmarshal(encoded, &sink); err != nil {
		t.Fatalf("encoder output does not parse: %v", err)
	}
	if sink["x"] != hostile {
		t.Errorf("round trip changed the value: %q", sink["x"])
	}
}

// TestWriteJSONReportEmptyAccounts pins that no accounts yields [] rather than
// null, so a consumer can iterate without a nil check.
func TestWriteJSONReportEmptyAccounts(t *testing.T) {
	var buf bytes.Buffer
	if err := writeJSONReport(&buf, "/root", "codex", nil); err != nil {
		t.Fatalf("writeJSONReport: %v", err)
	}
	if !bytes.Contains(buf.Bytes(), []byte(`"accounts": []`)) {
		t.Errorf("expected an empty array:\n%s", buf.String())
	}
	var back map[string]any
	if err := json.Unmarshal(buf.Bytes(), &back); err != nil {
		t.Fatalf("not valid JSON: %v", err)
	}
}
