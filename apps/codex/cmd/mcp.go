// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"context"
	"encoding/json"
	"fmt"
	"github.com/cyfr/codex/internal/ops"
	"strings"

	"github.com/cyfr/codex/internal/output"
	"github.com/cyfr/codex/internal/prompt"
	"github.com/spf13/cobra"
)

func init() {
	rootCmd.AddCommand(mcpCmd)
	mcpCmd.AddCommand(mcpRemoveCmd)
	mcpCmd.AddCommand(mcpListCmd)
	mcpCmd.AddCommand(mcpGetCmd)
	mcpCmd.AddCommand(mcpTestCmd)
	mcpCmd.AddCommand(mcpEnableCmd)
	mcpCmd.AddCommand(mcpDisableCmd)
	mcpCmd.AddCommand(mcpRefreshCmd)
	mcpCmd.AddCommand(mcpRestartCmd)

}

var mcpCmd = &cobra.Command{
	Use:     "mcp",
	Short:   "Manage programs and tool servers",
	GroupID: "admin",
	Long: `List, test, enable, disable, refresh, restart and remove the tool servers
elsewhere (Notion, GitHub, custom servers) and the programs CYFR runs. A tool
server's and an MCP program's tools appear alongside built-in tools in
tools/list as server_name:tool_name. Add one, or change its definition, on
CYFR's Programs page.`,
}

var mcpRemoveCmd = &cobra.Command{
	Use:     "remove <name>",
	Aliases: []string{"rm", "delete"},
	Short:   "Remove a program or a tool server",
	Long:    "Remove a program or a tool server and stop it. Its tools no longer appear in tools/list.",
	Example: "  cyfr mcp remove notion",
	Args:    cobra.RangeArgs(0, 1),
	RunE: func(cmd *cobra.Command, args []string) error {
		name, err := pickTarget(cmd.Context(), args, selector{
			Title: "Select a server to remove",
			Empty: "No MCP servers configured.",
			Usage: "Usage: cyfr mcp remove <name>",
			Fetch: fetchServerOptions,
		})
		if err != nil || name == "" {
			return err
		}

		client := newClient()
		result, err := client.CallTool(cmd.Context(), ops.McpServers, ops.McpServersDeleteArgs{Name: name})
		if err != nil {
			return handleToolError(err)
		}
		if flagJSON {
			output.JSON(result)
		} else {
			fmt.Printf("Server '%s' removed.\n", name)
		}
		return nil
	},
}

var mcpListCmd = &cobra.Command{
	Use:     "list",
	Aliases: []string{"ls"},
	Short:   "List the programs and tool servers",
	Example: "  cyfr mcp list",
	RunE: func(cmd *cobra.Command, args []string) error {
		client := newClient()
		result, err := client.CallTool(cmd.Context(), ops.McpServers, ops.McpServersListArgs{})
		if err != nil {
			return handleToolError(err)
		}
		if flagJSON {
			output.JSON(result)
		} else {
			servers, ok := result["servers"].([]any)
			if !ok || len(servers) == 0 {
				fmt.Println("No MCP servers configured.")
				return nil
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
		return nil
	},
}

var mcpGetCmd = &cobra.Command{
	Use:     "get <name>",
	Short:   "Get details of a program or a tool server",
	Long:    "Show a program or a tool server: its configuration, status and discovered tools.",
	Example: "  cyfr mcp get notion",
	Args:    cobra.RangeArgs(0, 1),
	RunE: func(cmd *cobra.Command, args []string) error {
		name, err := pickTarget(cmd.Context(), args, selector{
			Title: "Select a server",
			Empty: "No MCP servers configured.",
			Usage: "Usage: cyfr mcp get <name>",
			Fetch: fetchServerOptions,
		})
		if err != nil || name == "" {
			return err
		}

		client := newClient()
		result, err := client.CallTool(cmd.Context(), ops.McpServers, ops.McpServersGetArgs{Name: name})
		if err != nil {
			return handleToolError(err)
		}
		return renderResult(result)
	},
}

var mcpTestCmd = &cobra.Command{
	Use:     "test <name>",
	Short:   "Test connection to an MCP server",
	Long:    "Re-initialize the connection to an MCP server and report success/failure with capabilities.",
	Example: "  cyfr mcp test notion",
	Args:    cobra.RangeArgs(0, 1),
	RunE: func(cmd *cobra.Command, args []string) error {
		name, err := pickTarget(cmd.Context(), args, selector{
			Title: "Select a server to test",
			Empty: "No MCP servers configured.",
			Usage: "Usage: cyfr mcp test <name>",
			Fetch: fetchServerOptions,
		})
		if err != nil || name == "" {
			return err
		}

		client := newClient()
		result, err := client.CallTool(cmd.Context(), ops.McpServers, ops.McpServersTestArgs{Name: name})
		if err != nil {
			return handleToolError(err)
		}
		return renderResult(result)
	},
}

var mcpEnableCmd = &cobra.Command{
	Use:     "enable <name>",
	Short:   "Enable a disabled program or tool server",
	Example: "  cyfr mcp enable notion",
	Args:    cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		client := newClient()
		result, err := client.CallTool(cmd.Context(), ops.McpServers, ops.McpServersEnableArgs{Name: args[0]})
		if err != nil {
			return handleToolError(err)
		}
		if flagJSON {
			output.JSON(result)
		} else {
			fmt.Printf("Server '%s' enabled.\n", args[0])
		}
		return nil
	},
}

var mcpDisableCmd = &cobra.Command{
	Use:     "disable <name>",
	Short:   "Disable a program or a tool server without removing it",
	Example: "  cyfr mcp disable notion",
	Args:    cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		client := newClient()
		result, err := client.CallTool(cmd.Context(), ops.McpServers, ops.McpServersDisableArgs{Name: args[0]})
		if err != nil {
			return handleToolError(err)
		}
		if flagJSON {
			output.JSON(result)
		} else {
			fmt.Printf("Server '%s' disabled.\n", args[0])
		}
		return nil
	},
}

var mcpRefreshCmd = &cobra.Command{
	Use:   "refresh [name]",
	Short: "Re-discover the tools of tool servers and MCP programs",
	Long:  "Re-initialize and re-discover tools from one or all external MCP servers.",
	Example: `  cyfr mcp refresh          # refresh all
  cyfr mcp refresh notion   # refresh one`,
	Args: cobra.RangeArgs(0, 1),
	RunE: func(cmd *cobra.Command, args []string) error {
		toolArgs := ops.McpServersRefreshArgs{}
		if len(args) >= 1 {
			toolArgs.Name = ops.Value(args[0])
		}

		client := newClient()
		result, err := client.CallTool(cmd.Context(), ops.McpServers, toolArgs)
		if err != nil {
			return handleToolError(err)
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
		return nil
	},
}

var mcpRestartCmd = &cobra.Command{
	Use:     "restart <name>",
	Short:   "Restart a program's backends",
	Long:    "Release a program's backends on the backends service and start them again at the server's next epoch.",
	Example: "  cyfr mcp restart gh",
	Args:    cobra.RangeArgs(0, 1),
	RunE: func(cmd *cobra.Command, args []string) error {
		name, err := pickTarget(cmd.Context(), args, selector{
			Title: "Select a server to restart",
			Empty: "No MCP servers configured.",
			Usage: "Usage: cyfr mcp restart <name>",
			Fetch: fetchServerOptions,
		})
		if err != nil || name == "" {
			return err
		}

		client := newClient()
		result, err := client.CallTool(cmd.Context(), ops.McpServers, ops.McpServersRestartArgs{Name: name})
		if err != nil {
			return handleToolError(err)
		}
		if flagJSON {
			output.JSON(result)
		} else {
			fmt.Printf("Server '%s' restarted (%v, epoch %v).\n", name, result["status"], result["epoch"])
		}
		return nil
	},
}

// fetchServerOptions lists the configured MCP servers as picker options,
// labelling each with its status.
func fetchServerOptions(ctx context.Context) ([]prompt.Option, error) {
	client := newClient()
	result, err := client.CallTool(ctx, ops.McpServers, ops.McpServersListArgs{})
	if err != nil {
		return nil, err
	}

	servers, _ := result["servers"].([]any)
	opts := make([]prompt.Option, 0, len(servers))
	for _, s := range servers {
		if srv, ok := s.(map[string]any); ok {
			if name, ok := srv["name"].(string); ok {
				status, _ := srv["status"].(string)
				opts = append(opts, prompt.Option{
					Label: fmt.Sprintf("%s (%s)", name, status),
					Value: name,
				})
			}
		}
	}
	return opts, nil
}
