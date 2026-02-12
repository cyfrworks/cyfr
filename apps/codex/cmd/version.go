package cmd

import (
	"fmt"

	"github.com/cyfr/codex/internal/output"
	"github.com/spf13/cobra"
)

var (
	// Set via ldflags at build time.
	Version = "dev"
	Commit  = "none"
	Date    = "unknown"
)

func init() {
	versionCmd.Flags().Bool("json", false, "Output as JSON")
	rootCmd.AddCommand(versionCmd)
}

var versionCmd = &cobra.Command{
	Use:     "version",
	Short:   "Print the cyfr CLI version",
	GroupID: "start",
	Run: func(cmd *cobra.Command, args []string) {
		jsonFlag, _ := cmd.Flags().GetBool("json")
		if jsonFlag || flagJSON {
			output.JSON(map[string]any{
				"version": Version,
				"commit":  Commit,
				"date":    Date,
			})
			return
		}
		fmt.Printf("cyfr version %s (commit: %s, built: %s)\n", Version, Commit, Date)
	},
}
