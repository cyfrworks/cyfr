// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"testing"
)

// The warnings a stdio server's definition carries, as mcp_servers create
// and update answer them.
const (
	mcpWarningOne = "Backend 'github' expands GITHUB_TOKEN, a vault-bound env name, in its command: " +
		"the value is placed on the command line, where every process on the backends service, " +
		"other athanors' backends included, can read it; the safe route is to let the program " +
		"read it from its environment."
	mcpWarningTwo = "Backend 'search' expands SEARCH_KEY, a vault-bound env name, in its command: " +
		"the value is placed on the command line, where every process on the backends service, " +
		"other athanors' backends included, can read it; the safe route is to let the program " +
		"read it from its environment."
)

const mcpStdioConfig = `{"transport":"stdio","backends":[{"name":"github",` +
	`"command":"npx server --token $GITHUB_TOKEN","env":{"GITHUB_TOKEN":"vault:gh-token"}}]}`

// `cyfr mcp add` prints each warning the create answered after its
// confirmation, one per line, and nothing more when the list is empty.
func TestMcpAdd_PrintsEachWarning(t *testing.T) {
	onTerminal(t, false)

	for _, tc := range []struct {
		name     string
		warnings string
		want     string
	}{
		{
			"two warnings", `["` + mcpWarningOne + `","` + mcpWarningTwo + `"]`,
			"Server 'gh' added (ready, 1 tools discovered).\n" +
				"  Tools: github__search\n" +
				"  Warning: " + mcpWarningOne + "\n" +
				"  Warning: " + mcpWarningTwo + "\n",
		},
		{
			"no warning", `[]`,
			"Server 'gh' added (ready, 1 tools discovered).\n  Tools: github__search\n",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			srv := newCLIServer(t, "", `{"name":"gh","status":"ready","tools_discovered":1,`+
				`"tool_names":["github__search"],"epoch":1,"warnings":`+tc.warnings+`}`)

			out, err := runCLI(t, srv, "mcp", "add", "gh", mcpStdioConfig)
			if err != nil {
				t.Fatalf("cyfr mcp add failed: %v\n%s", err, out)
			}
			if name, args := srv.call(0); name != "mcp_servers" || args["action"] != "create" || args["name"] != "gh" {
				t.Errorf("expected mcp_servers.create of gh, got %s %v", name, args)
			}
			if out != tc.want {
				t.Errorf("the output is\n%q\nwant\n%q", out, tc.want)
			}
		})
	}
}

// `cyfr mcp update` prints each warning the update answered after its
// confirmation, one per line, and nothing more when the list is empty.
func TestMcpUpdate_PrintsEachWarning(t *testing.T) {
	onTerminal(t, false)

	for _, tc := range []struct {
		name     string
		warnings string
		want     string
	}{
		{
			"one warning", `["` + mcpWarningOne + `"]`,
			"Server 'gh' updated (ready).\n  Warning: " + mcpWarningOne + "\n",
		},
		{
			"no warning", `[]`,
			"Server 'gh' updated (ready).\n",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			srv := newCLIServer(t, "", `{"name":"gh","status":"ready","epoch":4,"warnings":`+tc.warnings+`}`)

			out, err := runCLI(t, srv, "mcp", "update", "gh", "--epoch", "3", mcpStdioConfig)
			if err != nil {
				t.Fatalf("cyfr mcp update failed: %v\n%s", err, out)
			}
			if name, args := srv.call(0); name != "mcp_servers" || args["action"] != "update" ||
				args["name"] != "gh" || args["epoch"] != float64(3) {
				t.Errorf("expected mcp_servers.update of gh at epoch 3, got %s %v", name, args)
			}
			if out != tc.want {
				t.Errorf("the output is\n%q\nwant\n%q", out, tc.want)
			}
		})
	}
}
