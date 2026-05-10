package cmd

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"

	"github.com/cyfr/codex/internal/output"
	"github.com/cyfr/codex/internal/prompt"
	"github.com/spf13/cobra"
)

func init() {
	rootCmd.AddCommand(mcpCmd)
	mcpCmd.AddCommand(mcpAddCmd)
	mcpCmd.AddCommand(mcpRemoveCmd)
	mcpCmd.AddCommand(mcpListCmd)
	mcpCmd.AddCommand(mcpGetCmd)
	mcpCmd.AddCommand(mcpTestCmd)
	mcpCmd.AddCommand(mcpEnableCmd)
	mcpCmd.AddCommand(mcpDisableCmd)
	mcpCmd.AddCommand(mcpRefreshCmd)

}

var mcpCmd = &cobra.Command{
	Use:     "mcp",
	Short:   "Manage external MCP server connections",
	GroupID: "admin",
	Long: `Connect to external MCP servers (Notion, GitHub, custom servers) via the
standard MCP protocol. External server tools appear alongside built-in
tools in tools/list as server_name:tool_name.

Config uses the same JSON format as mcp.json entries. Header values
can reference stored secrets with the secret: prefix.`,
}

var mcpAddCmd = &cobra.Command{
	Use:   "add <name> <config-json>",
	Short: "Add an external MCP server",
	Long: `Register and connect to an external MCP server. Config is a JSON object
in the same format as an mcp.json server entry. The server is initialized
immediately and its tools are discovered.

Header values can reference stored secrets with the secret: prefix.`,
	Example: `  cyfr mcp add notion '{"url":"https://mcp.notion.com/mcp","headers":{"Authorization":"secret:NOTION_KEY"}}'
  cyfr mcp add github '{"url":"https://api.githubcopilot.com/mcp/"}'`,
	Args: cobra.RangeArgs(0, 2),
	Run: func(cmd *cobra.Command, args []string) {
		var name string
		var config map[string]any

		switch {
		case len(args) >= 2:
			name = args[0]
			if err := json.Unmarshal([]byte(args[1]), &config); err != nil {
				output.Errorf("Invalid JSON config: %v", err)
			}
		case len(args) == 1:
			// Could be just a name (interactive config) or just JSON
			name = args[0]
			if prompt.IsInteractive(flagNoInteractive) {
				configStr, err := prompt.InputText("Config JSON", `{"url":"https://"}`)
				if err != nil {
					if prompt.IsAborted(err) {
						os.Exit(130)
					}
					output.Errorf("Prompt failed: %v", err)
				}
				if err := json.Unmarshal([]byte(configStr), &config); err != nil {
					output.Errorf("Invalid JSON config: %v", err)
				}
			} else {
				output.Error("Usage: cyfr mcp add <name> '<config-json>'")
			}
		case prompt.IsInteractive(flagNoInteractive):
			var err error
			name, err = prompt.InputText("Server name", "notion")
			if err != nil {
				if prompt.IsAborted(err) {
					os.Exit(130)
				}
				output.Errorf("Prompt failed: %v", err)
			}
			configStr, err := prompt.InputText("Config JSON", `{"url":"https://"}`)
			if err != nil {
				if prompt.IsAborted(err) {
					os.Exit(130)
				}
				output.Errorf("Prompt failed: %v", err)
			}
			if err := json.Unmarshal([]byte(configStr), &config); err != nil {
				output.Errorf("Invalid JSON config: %v", err)
			}
		default:
			output.Error("Usage: cyfr mcp add <name> '<config-json>'")
		}

		if config == nil {
			output.Error("Config JSON is required.")
		}
		if _, ok := config["url"]; !ok {
			output.Error("Config must include a \"url\" field.")
		}

		client := newClient()
		result, err := client.CallTool("mcp_servers", map[string]any{
			"action": "create",
			"name":   name,
			"config": config,
		})
		if err != nil {
			handleToolError(err)
		}
		if flagJSON {
			output.JSON(result)
		} else {
			status := "unknown"
			if s, ok := result["status"]; ok {
				status = fmt.Sprintf("%v", s)
			}
			toolCount := 0
			if tc, ok := result["tools_discovered"]; ok {
				if n, ok := tc.(float64); ok {
					toolCount = int(n)
				}
			}
			fmt.Printf("Server '%s' added (%s, %d tools discovered).\n", name, status, toolCount)
			if names, ok := result["tool_names"]; ok {
				if list, ok := names.([]any); ok && len(list) > 0 {
					strs := make([]string, len(list))
					for i, v := range list {
						strs[i] = fmt.Sprintf("%v", v)
					}
					fmt.Printf("  Tools: %s\n", strings.Join(strs, ", "))
				}
			}
		}
	},
}

var mcpRemoveCmd = &cobra.Command{
	Use:     "remove <name>",
	Aliases: []string{"rm", "delete"},
	Short:   "Remove an external MCP server",
	Long:    "Remove an external MCP server configuration and disconnect. Its tools will no longer appear in tools/list.",
	Example: "  cyfr mcp remove notion",
	Args:    cobra.RangeArgs(0, 1),
	Run: func(cmd *cobra.Command, args []string) {
		var name string

		switch {
		case len(args) >= 1:
			name = args[0]
		case prompt.IsInteractive(flagNoInteractive):
			name = selectServer("Select a server to remove")
		default:
			output.Error("Usage: cyfr mcp remove <name>")
		}

		client := newClient()
		result, err := client.CallTool("mcp_servers", map[string]any{
			"action": "delete",
			"name":   name,
		})
		if err != nil {
			handleToolError(err)
		}
		if flagJSON {
			output.JSON(result)
		} else {
			fmt.Printf("Server '%s' removed.\n", name)
		}
	},
}

var mcpListCmd = &cobra.Command{
	Use:     "list",
	Aliases: []string{"ls"},
	Short:   "List configured MCP servers",
	Example: "  cyfr mcp list",
	Run: func(cmd *cobra.Command, args []string) {
		client := newClient()
		result, err := client.CallTool("mcp_servers", map[string]any{
			"action": "list",
		})
		if err != nil {
			handleToolError(err)
		}
		if flagJSON {
			output.JSON(result)
		} else {
			servers, ok := result["servers"].([]any)
			if !ok || len(servers) == 0 {
				fmt.Println("No MCP servers configured.")
				return
			}
			for _, s := range servers {
				srv, ok := s.(map[string]any)
				if !ok {
					continue
				}
				enabled := "enabled"
				if e, ok := srv["enabled"]; ok {
					if b, ok := e.(bool); ok && !b {
						enabled = "disabled"
					}
				}
				fmt.Printf("  %-20s %-10s %-10s %v tools\n",
					srv["name"], srv["status"], enabled, srv["tool_count"])
			}
		}
	},
}

var mcpGetCmd = &cobra.Command{
	Use:     "get <name>",
	Short:   "Get details of an MCP server",
	Long:    "Show detailed information about an external MCP server, including its configuration, status, and discovered tools.",
	Example: "  cyfr mcp get notion",
	Args:    cobra.RangeArgs(0, 1),
	Run: func(cmd *cobra.Command, args []string) {
		var name string

		switch {
		case len(args) >= 1:
			name = args[0]
		case prompt.IsInteractive(flagNoInteractive):
			name = selectServer("Select a server")
		default:
			output.Error("Usage: cyfr mcp get <name>")
		}

		client := newClient()
		result, err := client.CallTool("mcp_servers", map[string]any{
			"action": "get",
			"name":   name,
		})
		if err != nil {
			handleToolError(err)
		}
		if flagJSON {
			output.JSON(result)
		} else {
			output.KeyValue(result)
		}
	},
}

var mcpTestCmd = &cobra.Command{
	Use:     "test <name>",
	Short:   "Test connection to an MCP server",
	Long:    "Re-initialize the connection to an MCP server and report success/failure with capabilities.",
	Example: "  cyfr mcp test notion",
	Args:    cobra.RangeArgs(0, 1),
	Run: func(cmd *cobra.Command, args []string) {
		var name string

		switch {
		case len(args) >= 1:
			name = args[0]
		case prompt.IsInteractive(flagNoInteractive):
			name = selectServer("Select a server to test")
		default:
			output.Error("Usage: cyfr mcp test <name>")
		}

		client := newClient()
		result, err := client.CallTool("mcp_servers", map[string]any{
			"action": "test",
			"name":   name,
		})
		if err != nil {
			handleToolError(err)
		}
		if flagJSON {
			output.JSON(result)
		} else {
			output.KeyValue(result)
		}
	},
}

var mcpEnableCmd = &cobra.Command{
	Use:     "enable <name>",
	Short:   "Enable a disabled MCP server",
	Example: "  cyfr mcp enable notion",
	Args:    cobra.ExactArgs(1),
	Run: func(cmd *cobra.Command, args []string) {
		client := newClient()
		result, err := client.CallTool("mcp_servers", map[string]any{
			"action": "enable",
			"name":   args[0],
		})
		if err != nil {
			handleToolError(err)
		}
		if flagJSON {
			output.JSON(result)
		} else {
			fmt.Printf("Server '%s' enabled.\n", args[0])
		}
	},
}

var mcpDisableCmd = &cobra.Command{
	Use:     "disable <name>",
	Short:   "Disable an MCP server without removing it",
	Example: "  cyfr mcp disable notion",
	Args:    cobra.ExactArgs(1),
	Run: func(cmd *cobra.Command, args []string) {
		client := newClient()
		result, err := client.CallTool("mcp_servers", map[string]any{
			"action": "disable",
			"name":   args[0],
		})
		if err != nil {
			handleToolError(err)
		}
		if flagJSON {
			output.JSON(result)
		} else {
			fmt.Printf("Server '%s' disabled.\n", args[0])
		}
	},
}

var mcpRefreshCmd = &cobra.Command{
	Use:   "refresh [name]",
	Short: "Re-discover tools from MCP servers",
	Long:  "Re-initialize and re-discover tools from one or all external MCP servers.",
	Example: `  cyfr mcp refresh          # refresh all
  cyfr mcp refresh notion   # refresh one`,
	Args: cobra.RangeArgs(0, 1),
	Run: func(cmd *cobra.Command, args []string) {
		toolArgs := map[string]any{
			"action": "refresh",
		}
		if len(args) >= 1 {
			toolArgs["name"] = args[0]
		}

		client := newClient()
		result, err := client.CallTool("mcp_servers", toolArgs)
		if err != nil {
			handleToolError(err)
		}
		if flagJSON {
			output.JSON(result)
		} else {
			if refreshed, ok := result["refreshed"]; ok {
				if list, ok := refreshed.([]any); ok {
					strs := make([]string, len(list))
					for i, v := range list {
						strs[i] = fmt.Sprintf("%v", v)
					}
					fmt.Printf("Refreshed: %s\n", strings.Join(strs, ", "))
				}
			}
			if failed, ok := result["failed"]; ok {
				if list, ok := failed.([]any); ok && len(list) > 0 {
					b, _ := json.MarshalIndent(list, "", "  ")
					fmt.Printf("Failed:\n%s\n", string(b))
				}
			}
		}
	},
}

// selectServer fetches the server list and prompts the user to choose one.
func selectServer(label string) string {
	client := newClient()
	result, err := client.CallTool("mcp_servers", map[string]any{
		"action": "list",
	})
	if err != nil {
		handleToolError(err)
	}

	servers, ok := result["servers"].([]any)
	if !ok || len(servers) == 0 {
		output.Error("No MCP servers configured.")
	}

	opts := make([]prompt.Option, 0, len(servers))
	for _, s := range servers {
		if srv, ok := s.(map[string]any); ok {
			if name, ok := srv["name"].(string); ok {
				status := ""
				if st, ok := srv["status"].(string); ok {
					status = st
				}
				opts = append(opts, prompt.Option{
					Label: fmt.Sprintf("%s (%s)", name, status),
					Value: name,
				})
			}
		}
	}

	selected, err := prompt.SelectOne(label, opts)
	if err != nil {
		if prompt.IsAborted(err) {
			os.Exit(130)
		}
		output.Errorf("Prompt failed: %v", err)
	}
	return selected
}
