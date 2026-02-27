package cmd

import (
	"fmt"
	"os"
	"os/exec"

	"github.com/cyfr/codex/internal/output"
	"github.com/cyfr/codex/internal/scaffold"
	"github.com/spf13/cobra"
)

func init() {
	rootCmd.AddCommand(updateCmd)
}

var updateCmd = &cobra.Command{
	Use:     "update",
	Short:   "Update project scaffold files (docs, WIT definitions)",
	Long:    "Update managed scaffold files (docs, WIT interface definitions) in the current project directory. Does not touch user config (cyfr.yaml, docker-compose.yml, .env) or components.",
	GroupID: "server",
	Example: "  cyfr update",
	Run: func(cmd *cobra.Command, args []string) {
		// Require cyfr.yaml in current directory
		if _, err := os.Stat("cyfr.yaml"); err != nil {
			output.Errorf("Not in a cyfr project directory (no cyfr.yaml found).\nRun 'cyfr init' to create a new project.")
		}

		fmt.Println("Updating project scaffold files...")

		// Pull latest Docker image (non-fatal, since the project runs via Docker)
		if _, err := exec.LookPath("docker"); err == nil {
			fmt.Println("Pulling latest Docker image...")
			pull := exec.Command("docker", "pull", "ghcr.io/cyfrworks/cyfr:latest")
			pull.Stdout = os.Stdout
			pull.Stderr = os.Stderr
			if err := pull.Run(); err != nil {
				fmt.Printf("Warning: failed to pull Docker image: %v\n", err)
			} else {
				fmt.Println("Docker image updated.")
			}
		}

		// Update scaffold files
		if err := scaffold.Update(Version); err != nil {
			output.Errorf("Failed to update scaffold files: %v", err)
		}

		fmt.Println("Scaffold files updated (component-guide.md, integration-guide.md, wit/).")
	},
}
