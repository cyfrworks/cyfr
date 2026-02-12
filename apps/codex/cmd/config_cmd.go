package cmd

import (
	"encoding/json"
	"fmt"

	"github.com/cyfr/codex/internal/output"
	"github.com/spf13/cobra"
)

func init() {
	rootCmd.AddCommand(configCmd)
	configCmd.AddCommand(configSetCmd)
	configCmd.AddCommand(configShowCmd)
}

var configCmd = &cobra.Command{
	Use:     "config",
	Short:   "Manage component configuration",
	GroupID: "governance",
	Long:    "Set and view per-component key/value configuration. Unlike policies (which enforce constraints), config provides runtime settings that the component reads at startup.",
}

var configSetCmd = &cobra.Command{
	Use:     "set <component_ref> <key> <value>",
	Short:   "Set a config value",
	Long:    "Create or update a configuration key for a component.",
	Example: `  cyfr config set acme.sentiment:1.0.0 model gpt-4
  cyfr config set acme.sentiment:1.0.0 timeout 30`,
	Args: cobra.ExactArgs(3),
	Run: func(cmd *cobra.Command, args []string) {
		componentRef := normalizeComponentRef(args[0])
		key := args[1]
		value := args[2]

		client := newClient()
		result, err := client.CallTool("config", map[string]any{
			"action":        "set",
			"component_ref": componentRef,
			"key":           key,
			"value":         value,
		})
		if err != nil {
			output.Errorf("Failed: %v", err)
		}
		if flagJSON {
			output.JSON(result)
		} else {
			fmt.Printf("Config '%s' set for %s.\n", key, componentRef)
		}
	},
}

var configShowCmd = &cobra.Command{
	Use:     "show <component_ref>",
	Short:   "Show all config for a component",
	Long:    "Display every configuration key/value pair for a component.",
	Example: "  cyfr config show acme.sentiment:1.0.0",
	Args:    cobra.ExactArgs(1),
	Run: func(cmd *cobra.Command, args []string) {
		componentRef := normalizeComponentRef(args[0])
		client := newClient()
		result, err := client.CallTool("config", map[string]any{
			"action":        "get_all",
			"component_ref": componentRef,
		})
		if err != nil {
			output.Errorf("Failed: %v", err)
		}
		if flagJSON {
			output.JSON(result)
		} else {
			if config, ok := result["config"]; ok {
				configJSON, _ := json.MarshalIndent(config, "", "  ")
				fmt.Printf("Config for %s:\n%s\n", componentRef, string(configJSON))
			} else {
				output.KeyValue(result)
			}
		}
	},
}
