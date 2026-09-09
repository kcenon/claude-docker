// This disposable process adapter exercises the real TUI terminal handoff.
// It never talks to Docker or a provider; native builds also work with ConPTY.
package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

func main() {
	root := os.Getenv("TERMINAL_FIXTURE_ROOT")
	if root == "" {
		os.Exit(90)
	}
	var spec struct{ Binary, ServicePrefix string }
	content, err := os.ReadFile(filepath.Join(root, "spec.json"))
	if err != nil || json.Unmarshal(content, &spec) != nil {
		os.Exit(91)
	}
	args := os.Args[1:]
	if len(args) > 0 && args[0] == "exec" {
		fmt.Println("fixture-user")
		return
	}
	for i := 0; i < len(args); i++ {
		if args[i] == "-f" {
			i++
			if i == len(args) || filepath.Clean(filepath.Dir(args[i])) != filepath.Clean(root) {
				os.Exit(92)
			}
			continue
		}
		switch args[i] {
		case "ps":
			fmt.Printf(`[{"Service":%q,"State":"running"},{"Service":%q,"State":"running"}]`, spec.ServicePrefix+"-a", spec.ServicePrefix+"-b")
			return
		case "exec":
			if i+2 >= len(args) || args[i+2] != spec.Binary {
				os.Exit(93)
			}
			service := args[i+1]
			if os.Getenv("TERMINAL_WRONG_ACCOUNT") == "1" {
				service = spec.ServicePrefix + "-b"
			}
			if service != spec.ServicePrefix+"-a" && service != spec.ServicePrefix+"-b" {
				os.Exit(94)
			}
			if err := os.WriteFile(filepath.Join(root, "attached"), []byte(service+" "+spec.Binary), 0600); err != nil {
				os.Exit(95)
			}
			fmt.Println(spec.Binary + " READY")
			input := bufio.NewScanner(os.Stdin)
			for input.Scan() {
				if strings.TrimSpace(input.Text()) == "/exit" {
					if os.Getenv("TERMINAL_CHILD_FAIL") == "1" {
						os.Exit(17)
					}
					return
				}
			}
			os.Exit(96)
		}
	}
	os.Exit(97)
}
