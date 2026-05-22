package config

import (
	_ "embed"
	"encoding/json"
	"fmt"
	"sort"
)

// runtimesJSON is the embedded runtime registry. It must live inside this
// package tree because go:embed cannot reach files outside the embedding
// package. The shell layers read the same file via PROJECT_ROOT. See #267.
//
//go:embed runtimes.json
var runtimesJSON []byte

// RuntimeSpec holds every runtime-specific value for one agent runtime.
// The JSON tags mirror the flat field names in runtimes.json so the bash
// awk fallback and PowerShell readers stay simple.
type RuntimeSpec struct {
	Binary               string `json:"binary"`
	DisplayName          string `json:"displayName"`
	ServicePrefix        string `json:"servicePrefix"`
	StateDir             string `json:"stateDir"`
	ContainerHome        string `json:"containerHome"`
	HostConfigMount      string `json:"hostConfigMount"`
	ContainerConfigMount string `json:"containerConfigMount"`
	ConfigDirEnv         string `json:"configDirEnv"`
	ConfigDirEnvValue    string `json:"configDirEnvValue"`
	ConfigSourceEnv      string `json:"configSourceEnv"`
	APIKeyVarPrefix      string `json:"apiKeyVarPrefix"`
	SDKAPIKeyVar         string `json:"sdkApiKeyVar"`
	BuildArg             string `json:"buildArg"`
	InstallMethod        string `json:"installMethod"`
	SkipPermissionsFlag  string `json:"skipPermissionsFlag"`
	ConfigFormat         string `json:"configFormat"`
	BootstrapModule      string `json:"bootstrapModule"`
	ExtraEnv             string `json:"extraEnv"`
	ExtraRunArgs         string `json:"extraRunArgs"`
	SupportsUsage        bool   `json:"supportsUsage"`
	MountsAgentsSkills   bool   `json:"mountsAgentsSkills"`
	CredentialFiles      string `json:"credentialFiles"`
	OAuthCredentialFile  string `json:"oauthCredentialFile"`
}

// runtimeRegistry is the parsed representation of runtimes.json.
type runtimeRegistry struct {
	Runtimes map[string]RuntimeSpec `json:"runtimes"`
}

// registry holds the parsed registry, populated once by init().
var registry runtimeRegistry

// init parses the embedded registry. A parse failure is a build defect —
// runtimes.json is checked into the package — so it panics rather than
// returning an error no caller could recover from.
func init() {
	if err := json.Unmarshal(runtimesJSON, &registry); err != nil {
		panic(fmt.Sprintf("config: parse embedded runtimes.json: %v", err))
	}
}

// LookupRuntime returns the RuntimeSpec for the named runtime. The second
// return value is false if the runtime is not in the registry.
func LookupRuntime(name string) (RuntimeSpec, bool) {
	spec, ok := registry.Runtimes[name]
	return spec, ok
}

// KnownRuntimes returns the registered runtime names in sorted order.
func KnownRuntimes() []string {
	names := make([]string, 0, len(registry.Runtimes))
	for name := range registry.Runtimes {
		names = append(names, name)
	}
	sort.Strings(names)
	return names
}
