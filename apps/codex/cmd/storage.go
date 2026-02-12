package cmd

import (
	"strings"

	"github.com/cyfr/codex/internal/output"
	"github.com/spf13/cobra"
)

func init() {
	rootCmd.AddCommand(storageCmd)
	storageCmd.AddCommand(storageListCmd)
	storageCmd.AddCommand(storageReadCmd)
	storageCmd.AddCommand(storageWriteCmd)
	storageCmd.AddCommand(storageDeleteCmd)
	storageCmd.AddCommand(storageRetentionCmd)
	storageRetentionCmd.Flags().Bool("get", false, "Get retention policy")
	storageRetentionCmd.Flags().Bool("set", false, "Set retention policy")
	storageRetentionCmd.Flags().Bool("cleanup", false, "Run retention cleanup")
}

var storageCmd = &cobra.Command{
	Use:     "storage",
	Short:   "Manage file storage",
	GroupID: "storage",
	Long:    "Read, write, list, and delete files in the CYFR sandboxed file store. Includes retention policy management for automatic cleanup.",
}

var storageListCmd = &cobra.Command{
	Use:     "list <path>",
	Short:   "List files",
	Long:    "List files and directories under the given path.",
	Example: "  cyfr storage list /data/outputs",
	Args:    cobra.ExactArgs(1),
	Run: func(cmd *cobra.Command, args []string) {
		client := newClient()
		result, err := client.CallTool("storage", map[string]any{
			"action": "list",
			"path":   args[0],
		})
		if err != nil {
			output.Errorf("Failed: %v", err)
		}
		if flagJSON {
			output.JSON(result)
		} else {
			output.KeyValue(result)
		}
	},
}

var storageReadCmd = &cobra.Command{
	Use:     "read <path>",
	Short:   "Read a file",
	Long:    "Read and display the contents of a file from storage.",
	Example: "  cyfr storage read /data/outputs/result.json",
	Args:    cobra.ExactArgs(1),
	Run: func(cmd *cobra.Command, args []string) {
		client := newClient()
		result, err := client.CallTool("storage", map[string]any{
			"action": "read",
			"path":   args[0],
		})
		if err != nil {
			output.Errorf("Failed: %v", err)
		}
		if flagJSON {
			output.JSON(result)
		} else {
			output.KeyValue(result)
		}
	},
}

var storageWriteCmd = &cobra.Command{
	Use:     "write <path> <data>",
	Short:   "Write a file",
	Long:    "Write data to a file in storage, creating it if it does not exist.",
	Example: "  cyfr storage write /data/config.txt \"key=value\"",
	Args:    cobra.MinimumNArgs(2),
	Run: func(cmd *cobra.Command, args []string) {
		client := newClient()
		result, err := client.CallTool("storage", map[string]any{
			"action": "write",
			"path":   args[0],
			"data":   strings.Join(args[1:], " "),
		})
		if err != nil {
			output.Errorf("Failed: %v", err)
		}
		if flagJSON {
			output.JSON(result)
		} else {
			output.KeyValue(result)
		}
	},
}

var storageDeleteCmd = &cobra.Command{
	Use:     "delete <path>",
	Short:   "Delete a file",
	Long:    "Permanently remove a file from storage.",
	Example: "  cyfr storage delete /data/outputs/old-result.json",
	Args:    cobra.ExactArgs(1),
	Run: func(cmd *cobra.Command, args []string) {
		client := newClient()
		result, err := client.CallTool("storage", map[string]any{
			"action": "delete",
			"path":   args[0],
		})
		if err != nil {
			output.Errorf("Failed: %v", err)
		}
		if flagJSON {
			output.JSON(result)
		} else {
			output.KeyValue(result)
		}
	},
}

var storageRetentionCmd = &cobra.Command{
	Use:   "retention",
	Short: "Manage retention policies",
	Long:  "Get or set the file retention policy, or trigger a manual cleanup of expired files.",
	Example: `  cyfr storage retention --get
  cyfr storage retention --set
  cyfr storage retention --cleanup`,
	Run: func(cmd *cobra.Command, args []string) {
		client := newClient()

		action := "retention"
		toolArgs := map[string]any{"action": action}

		if get, _ := cmd.Flags().GetBool("get"); get {
			toolArgs["sub_action"] = "get"
		} else if set, _ := cmd.Flags().GetBool("set"); set {
			toolArgs["sub_action"] = "set"
		} else if cleanup, _ := cmd.Flags().GetBool("cleanup"); cleanup {
			toolArgs["sub_action"] = "cleanup"
		}

		result, err := client.CallTool("storage", toolArgs)
		if err != nil {
			output.Errorf("Failed: %v", err)
		}
		if flagJSON {
			output.JSON(result)
		} else {
			output.KeyValue(result)
		}
	},
}
