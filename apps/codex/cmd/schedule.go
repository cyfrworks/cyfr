// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"encoding/json"
	"errors"
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

	scheduleGetCmd.Flags().Bool("json", false, "") // inherits from root but explicit for clarity
	scheduleGetCmd.Flags().MarkHidden("json")

	scheduleUpdateCmd.Flags().String("name", "", "New schedule name")
	scheduleUpdateCmd.Flags().String("cron", "", "New cron expression")
	scheduleUpdateCmd.Flags().String("ref", "", "New component reference")
	scheduleUpdateCmd.Flags().String("input", "", "New JSON input")

	scheduleCmd.AddCommand(scheduleCreateCmd)
	scheduleCmd.AddCommand(scheduleListCmd)
	scheduleCmd.AddCommand(scheduleGetCmd)
	scheduleCmd.AddCommand(scheduleUpdateCmd)
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
	Example: `  cyfr schedule create --name daily-report --cron "0 9 * * *" --ref "catalyst:local.reporter"
  cyfr schedule create --name processor --cron "*/5 * * * *" --ref "reagent:local.proc" --input '{"key":"value"}'
  cyfr schedule create --name pinned --cron "0 * * * *" --ref "catalyst:local.reporter:1.0.0"
  cyfr schedule create  # interactive mode`,
	RunE: func(cmd *cobra.Command, args []string) error {
		client := newClient()

		name, _ := cmd.Flags().GetString("name")
		cron, _ := cmd.Flags().GetString("cron")
		refStr, _ := cmd.Flags().GetString("ref")
		inputStr, _ := cmd.Flags().GetString("input")

		// Interactive mode if flags not provided
		if name == "" || cron == "" || refStr == "" {
			if !prompt.IsInteractive(flagNoInteractive) {
				return errors.New("Usage: cyfr schedule create --name <name> --cron '<expr>' --ref <reference>")
			}

			if name == "" {
				var err error
				name, err = prompt.InputText("Schedule name", "my-schedule")
				if err != nil {
					if prompt.IsAborted(err) {
						os.Exit(130)
					}
					return fmt.Errorf("Prompt failed: %v", err)
				}
			}

			if cron == "" {
				var err error
				cron, err = prompt.InputText("Cron expression", "*/5 * * * *")
				if err != nil {
					if prompt.IsAborted(err) {
						os.Exit(130)
					}
					return fmt.Errorf("Prompt failed: %v", err)
				}
			}

			if refStr == "" {
				compOpts, err := prompt.FetchComponents(cmd.Context(), client)
				if err != nil {
					return handleToolError(err)
				}
				if len(compOpts) == 0 {
					return errors.New("No components found. Register one first.")
				}
				refStr, err = prompt.SelectOne("Select a component", compOpts)
				if err != nil {
					if prompt.IsAborted(err) {
						os.Exit(130)
					}
					return fmt.Errorf("Prompt failed: %v", err)
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
				return fmt.Errorf("Invalid JSON input: %v", err)
			}
			toolArgs["input"] = inputMap
		}

		result, err := client.CallTool(cmd.Context(), "schedule", toolArgs)
		if err != nil {
			return handleToolError(err)
		}

		if flagJSON {
			output.JSON(result)
		} else {
			fmt.Println("Schedule created.")
			output.KeyValue(result)
		}
		return nil
	},
}

var scheduleListCmd = &cobra.Command{
	Use:   "list",
	Short: "List cron schedules",
	RunE: func(cmd *cobra.Command, args []string) error {
		client := newClient()

		result, err := client.CallTool(cmd.Context(), "schedule", map[string]any{
			"action": "list",
		})
		if err != nil {
			return handleToolError(err)
		}

		if flagJSON {
			output.JSON(result)
		} else {
			output.KeyValue(result)
		}
		return nil
	},
}

var scheduleGetCmd = &cobra.Command{
	Use:   "get <id|name>",
	Short: "Show schedule details",
	Example: `  cyfr schedule get my-schedule
  cyfr schedule get 550e8400-e29b-41d4-a716-446655440000`,
	Args: cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		client := newClient()

		result, err := client.CallTool(cmd.Context(), "schedule", map[string]any{
			"action":      "get",
			"schedule_id": args[0],
		})
		if err != nil {
			return handleToolError(err)
		}

		if flagJSON {
			output.JSON(result)
		} else {
			output.KeyValue(result)
		}
		return nil
	},
}

var scheduleUpdateCmd = &cobra.Command{
	Use:   "update <id|name>",
	Short: "Update a cron schedule",
	Long:  "Update one or more fields of an existing schedule. Only explicitly set flags are sent.",
	Example: `  cyfr schedule update my-schedule --cron "0 */2 * * *"
  cyfr schedule update my-schedule --ref "catalyst:local.reporter" --name new-name
  cyfr schedule update my-schedule --input '{"key":"new-value"}'`,
	Args: cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		client := newClient()

		toolArgs := map[string]any{
			"action":      "update",
			"schedule_id": args[0],
		}

		if cmd.Flags().Changed("name") {
			v, _ := cmd.Flags().GetString("name")
			toolArgs["name"] = v
		}
		if cmd.Flags().Changed("cron") {
			v, _ := cmd.Flags().GetString("cron")
			toolArgs["cron_expression"] = v
		}
		if cmd.Flags().Changed("ref") {
			v, _ := cmd.Flags().GetString("ref")
			toolArgs["reference"] = v
		}
		if cmd.Flags().Changed("input") {
			inputStr, _ := cmd.Flags().GetString("input")
			var inputMap map[string]any
			if err := json.Unmarshal([]byte(inputStr), &inputMap); err != nil {
				return fmt.Errorf("Invalid JSON input: %v", err)
			}
			toolArgs["input"] = inputMap
		}

		result, err := client.CallTool(cmd.Context(), "schedule", toolArgs)
		if err != nil {
			return handleToolError(err)
		}

		if flagJSON {
			output.JSON(result)
		} else {
			fmt.Println("Schedule updated.")
			output.KeyValue(result)
		}
		return nil
	},
}

var schedulePauseCmd = &cobra.Command{
	Use:   "pause <id|name>",
	Short: "Pause a cron schedule",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		client := newClient()

		result, err := client.CallTool(cmd.Context(), "schedule", map[string]any{
			"action":      "pause",
			"schedule_id": args[0],
		})
		if err != nil {
			return handleToolError(err)
		}

		if flagJSON {
			output.JSON(result)
		} else {
			fmt.Println("Schedule paused.")
			output.KeyValue(result)
		}
		return nil
	},
}

var scheduleResumeCmd = &cobra.Command{
	Use:   "resume <id|name>",
	Short: "Resume a paused cron schedule",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		client := newClient()

		result, err := client.CallTool(cmd.Context(), "schedule", map[string]any{
			"action":      "resume",
			"schedule_id": args[0],
		})
		if err != nil {
			return handleToolError(err)
		}

		if flagJSON {
			output.JSON(result)
		} else {
			fmt.Println("Schedule resumed.")
			output.KeyValue(result)
		}
		return nil
	},
}

var scheduleDeleteCmd = &cobra.Command{
	Use:   "delete <id|name>",
	Short: "Delete a cron schedule",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		client := newClient()

		result, err := client.CallTool(cmd.Context(), "schedule", map[string]any{
			"action":      "delete",
			"schedule_id": args[0],
		})
		if err != nil {
			return handleToolError(err)
		}

		if flagJSON {
			output.JSON(result)
		} else {
			fmt.Println("Schedule deleted.")
			_ = result
		}
		return nil
	},
}
