package cmd

import (
	"encoding/json"
	"fmt"
	"os"

	"github.com/cyfr/codex/internal/output"
	"github.com/cyfr/codex/internal/prompt"

	"github.com/spf13/cobra"
)

func init() {
	scheduleCreateCmd.Flags().String("name", "", "Schedule name")
	scheduleCreateCmd.Flags().String("cron", "", "Cron expression (e.g. '*/5 * * * *')")
	scheduleCreateCmd.Flags().String("ref", "", "Component reference")
	scheduleCreateCmd.Flags().String("input", "", "JSON input for execution")

	scheduleCmd.AddCommand(scheduleCreateCmd)
	scheduleCmd.AddCommand(scheduleListCmd)
	scheduleCmd.AddCommand(schedulePauseCmd)
	scheduleCmd.AddCommand(scheduleResumeCmd)
	scheduleCmd.AddCommand(scheduleDeleteCmd)

	rootCmd.AddCommand(scheduleCmd)
}

var scheduleCmd = &cobra.Command{
	Use:     "schedule",
	Short:   "Manage recurring component schedules",
	GroupID: "component",
	Long:    `Create, list, pause, resume, and delete recurring cron schedules for WASM component execution.`,
}

var scheduleCreateCmd = &cobra.Command{
	Use:   "create",
	Short: "Create a new cron schedule [interactive]",
	Example: `  cyfr schedule create --name daily-report --cron "0 9 * * *" --ref "catalyst:local.reporter:1.0.0"
  cyfr schedule create --name processor --cron "*/5 * * * *" --ref "reagent:local.proc:1.0.0" --input '{"key":"value"}'
  cyfr schedule create  # interactive mode`,
	Run: func(cmd *cobra.Command, args []string) {
		client := newClient()

		name, _ := cmd.Flags().GetString("name")
		cron, _ := cmd.Flags().GetString("cron")
		refStr, _ := cmd.Flags().GetString("ref")
		inputStr, _ := cmd.Flags().GetString("input")

		// Interactive mode if flags not provided
		if name == "" || cron == "" || refStr == "" {
			if !prompt.IsInteractive(flagNoInteractive) {
				output.Error("Usage: cyfr schedule create --name <name> --cron '<expr>' --ref <reference>")
				return
			}

			if name == "" {
				var err error
				name, err = prompt.InputText("Schedule name", "my-schedule")
				if err != nil {
					if prompt.IsAborted(err) {
						os.Exit(130)
					}
					output.Errorf("Prompt failed: %v", err)
				}
			}

			if cron == "" {
				var err error
				cron, err = prompt.InputText("Cron expression", "*/5 * * * *")
				if err != nil {
					if prompt.IsAborted(err) {
						os.Exit(130)
					}
					output.Errorf("Prompt failed: %v", err)
				}
			}

			if refStr == "" {
				compOpts, err := prompt.FetchComponents(client)
				if err != nil {
					handleToolError(err)
				}
				if len(compOpts) == 0 {
					output.Error("No components found. Register one first.")
					return
				}
				refStr, err = prompt.SelectOne("Select a component", compOpts)
				if err != nil {
					if prompt.IsAborted(err) {
						os.Exit(130)
					}
					output.Errorf("Prompt failed: %v", err)
				}
			}
		}

		toolArgs := map[string]any{
			"action":          "create",
			"name":            name,
			"cron_expression": cron,
			"reference":       refStr,
		}

		if inputStr != "" {
			var inputMap map[string]any
			if err := json.Unmarshal([]byte(inputStr), &inputMap); err != nil {
				output.Errorf("Invalid JSON input: %v", err)
			}
			toolArgs["input"] = inputMap
		}

		result, err := client.CallTool("schedule", toolArgs)
		if err != nil {
			handleToolError(err)
		}

		if flagJSON {
			output.JSON(result)
		} else {
			fmt.Println("Schedule created.")
			output.KeyValue(result)
		}
	},
}

var scheduleListCmd = &cobra.Command{
	Use:   "list",
	Short: "List cron schedules",
	Run: func(cmd *cobra.Command, args []string) {
		client := newClient()

		result, err := client.CallTool("schedule", map[string]any{
			"action": "list",
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

var schedulePauseCmd = &cobra.Command{
	Use:   "pause <id|name>",
	Short: "Pause a cron schedule",
	Args:  cobra.ExactArgs(1),
	Run: func(cmd *cobra.Command, args []string) {
		client := newClient()

		result, err := client.CallTool("schedule", map[string]any{
			"action":      "pause",
			"schedule_id": args[0],
		})
		if err != nil {
			handleToolError(err)
		}

		if flagJSON {
			output.JSON(result)
		} else {
			fmt.Println("Schedule paused.")
			output.KeyValue(result)
		}
	},
}

var scheduleResumeCmd = &cobra.Command{
	Use:   "resume <id|name>",
	Short: "Resume a paused cron schedule",
	Args:  cobra.ExactArgs(1),
	Run: func(cmd *cobra.Command, args []string) {
		client := newClient()

		result, err := client.CallTool("schedule", map[string]any{
			"action":      "resume",
			"schedule_id": args[0],
		})
		if err != nil {
			handleToolError(err)
		}

		if flagJSON {
			output.JSON(result)
		} else {
			fmt.Println("Schedule resumed.")
			output.KeyValue(result)
		}
	},
}

var scheduleDeleteCmd = &cobra.Command{
	Use:   "delete <id|name>",
	Short: "Delete a cron schedule",
	Args:  cobra.ExactArgs(1),
	Run: func(cmd *cobra.Command, args []string) {
		client := newClient()

		result, err := client.CallTool("schedule", map[string]any{
			"action":      "delete",
			"schedule_id": args[0],
		})
		if err != nil {
			handleToolError(err)
		}

		if flagJSON {
			output.JSON(result)
		} else {
			fmt.Println("Schedule deleted.")
			_ = result
		}
	},
}
