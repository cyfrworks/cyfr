package cmd

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"strings"

	"github.com/cyfr/codex/internal/output"
	"github.com/cyfr/codex/internal/scaffold"
	"github.com/spf13/cobra"
)

func init() {
	rootCmd.AddCommand(upgradeCmd)
}

var upgradeCmd = &cobra.Command{
	Use:     "upgrade",
	Short:   "Upgrade cyfr to the latest version",
	GroupID: "start",
	Run: func(cmd *cobra.Command, args []string) {
		// 1. Fetch latest release tag from GitHub
		resp, err := http.Get("https://api.github.com/repos/cyfrworks/cyfr/releases/latest")
		if err != nil {
			output.Errorf("Failed to check for updates: %v", err)
		}
		defer resp.Body.Close()

		if resp.StatusCode != http.StatusOK {
			output.Errorf("GitHub API returned status %d", resp.StatusCode)
		}

		var release struct {
			TagName string `json:"tag_name"`
		}
		if err := json.NewDecoder(resp.Body).Decode(&release); err != nil {
			output.Errorf("Failed to parse release info: %v", err)
		}

		latest := strings.TrimPrefix(release.TagName, "v")

		// 2. Compare to current version
		current := strings.TrimPrefix(Version, "v")
		if current == latest {
			fmt.Printf("Already up to date (v%s)\n", current)
			return
		}

		fmt.Printf("Upgrading cyfr from v%s to v%s...\n", current, latest)

		// 3. Check if installed via Homebrew
		brewPath, err := exec.LookPath("brew")
		brewInstall := false
		if err == nil && brewPath != "" {
			check := exec.Command("brew", "list", "--cask", "cyfr")
			check.Stdout = nil
			check.Stderr = nil
			if check.Run() == nil {
				brewInstall = true
			}
		}

		if brewInstall {
			// 4a. Homebrew upgrade path
			update := exec.Command("brew", "update")
			update.Stdout = os.Stdout
			update.Stderr = os.Stderr
			if err := update.Run(); err != nil {
				output.Errorf("brew update failed: %v", err)
			}

			upgrade := exec.Command("brew", "upgrade", "--cask", "cyfr")
			upgrade.Stdout = os.Stdout
			upgrade.Stderr = os.Stderr
			if err := upgrade.Run(); err != nil {
				output.Errorf("brew upgrade failed: %v", err)
			}

			fmt.Printf("Successfully upgraded cyfr to v%s\n", latest)
		} else {
			// 4b. Manual download instructions
			fmt.Println("cyfr was not installed via Homebrew.")
			fmt.Printf("Download the latest release from: https://github.com/cyfrworks/cyfr/releases/tag/v%s\n", latest)
		}

		// 5. Pull latest Docker image (non-fatal)
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
		} else {
			fmt.Println("Docker not found on PATH, skipping image pull.")
		}

		// 6. Update scaffold files if in a project directory (non-fatal)
		if _, err := os.Stat("cyfr.yaml"); err == nil {
			fmt.Println("Updating scaffold files...")
			if err := scaffold.Update(latest); err != nil {
				fmt.Printf("Warning: failed to update scaffold files: %v\n", err)
			} else {
				fmt.Println("Scaffold files updated.")
			}
		} else {
			fmt.Println("Not in a cyfr project directory (no cyfr.yaml found), skipping scaffold update.")
		}
	},
}
