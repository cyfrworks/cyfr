package cmd

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"

	"github.com/cyfr/codex/internal/output"
	"github.com/spf13/cobra"
)

func init() {
	rootCmd.AddCommand(upgradeCmd)
}

var upgradeCmd = &cobra.Command{
	Use:     "upgrade",
	Short:   "Upgrade the cyfr CLI binary",
	Long:    "Upgrade the cyfr CLI binary (system-wide). Run 'cyfr update' in each project directory to pull the latest Docker image and update scaffold files.",
	GroupID: "server",
	Run: func(cmd *cobra.Command, args []string) {
		// 1. Fetch releases from GitHub and find the latest CYFR release (v* tag)
		resp, err := http.Get("https://api.github.com/repos/cyfrworks/cyfr/releases?per_page=20")
		if err != nil {
			output.Errorf("Failed to check for updates: %v", err)
		}
		defer resp.Body.Close()

		if resp.StatusCode != http.StatusOK {
			output.Errorf("GitHub API returned status %d", resp.StatusCode)
		}

		var releases []struct {
			TagName string `json:"tag_name"`
		}
		if err := json.NewDecoder(resp.Body).Decode(&releases); err != nil {
			output.Errorf("Failed to parse release info: %v", err)
		}

		// Find the latest CYFR release (v* tag)
		var latestTag string
		for _, r := range releases {
			if strings.HasPrefix(r.TagName, "v") {
				latestTag = r.TagName
				break
			}
		}
		if latestTag == "" {
			output.Errorf("No CYFR release found on GitHub")
		}

		latest := strings.TrimPrefix(latestTag, "v")

		// 2. Compare to current version — only skip CLI upgrade if already up to date
		current := strings.TrimPrefix(Version, "v")
		cliUpToDate := current == latest

		if cliUpToDate {
			fmt.Printf("CLI already up to date (v%s)\n", current)
		} else {
			fmt.Printf("Upgrading cyfr CLI from v%s to v%s...\n", current, latest)

			// 3. Check if installed via Homebrew
			brewPath, err := exec.LookPath("brew")
			brewInstall := false
			if err == nil && brewPath != "" {
				check := exec.Command("brew", "list", "cyfr")
				check.Stdout = nil
				check.Stderr = nil
				if check.Run() == nil {
					brewInstall = true
				}
			}

			if brewInstall {
				update := exec.Command("brew", "update")
				update.Stdout = os.Stdout
				update.Stderr = os.Stderr
				if err := update.Run(); err != nil {
					output.Errorf("brew update failed: %v", err)
				}

				upgrade := exec.Command("brew", "upgrade", "cyfr")
				upgrade.Stdout = os.Stdout
				upgrade.Stderr = os.Stderr
				if err := upgrade.Run(); err != nil {
					fmt.Printf("Warning: brew upgrade cyfr: %v\n", err)
				} else {
					fmt.Printf("CLI upgraded to v%s\n", latest)
				}
			} else {
				// Install to the same directory as the currently running binary
				// so upgrades don't create duplicates in different locations.
				fmt.Println("Upgrading via install script...")
				env := os.Environ()
				if selfPath, err := os.Executable(); err == nil {
					env = append(env, "CYFR_INSTALL_DIR="+filepath.Dir(selfPath))
				}
				// On Linux, `cp /tmp/cyfr /usr/local/bin/cyfr` fails with
				// "text file busy" if the destination is a binary that's
				// currently being executed — and that's exactly us. Hand off
				// via execve(2) so this Go process is gone (and its mapping
				// of /usr/local/bin/cyfr released) by the time the installer
				// runs cp. We tack on the post-install reminder via the same
				// shell command since after exec we can't print anything more.
				// Windows has no execve; fall back to cmd.Run there.
				cmdline := "curl -fsSL https://raw.githubusercontent.com/cyfrworks/cyfr/main/scripts/install.sh | sh" +
					" && printf '\\nRun '\\''cyfr update'\\'' in each project directory to pull the latest Docker images and update scaffold files.\\n'"

				if runtime.GOOS == "windows" {
					script := exec.Command("sh", "-c", cmdline)
					script.Stdout = os.Stdout
					script.Stderr = os.Stderr
					script.Env = env
					if err := script.Run(); err != nil {
						fmt.Printf("Install script failed: %v\n", err)
						fmt.Printf("Download manually from: https://github.com/cyfrworks/cyfr/releases/tag/v%s\n", latest)
					}
					return
				}

				shPath, err := exec.LookPath("sh")
				if err != nil {
					output.Errorf("sh not found in PATH: %v", err)
				}
				// syscall.Exec replaces this process; control never returns on
				// success. The installer's stdout/stderr inherit our terminal.
				if err := syscall.Exec(shPath, []string{"sh", "-c", cmdline}, env); err != nil {
					fmt.Printf("Failed to launch installer: %v\n", err)
					fmt.Printf("Download manually from: https://github.com/cyfrworks/cyfr/releases/tag/v%s\n", latest)
				}
				return
			}
		}

		fmt.Println("\nRun 'cyfr update' in each project directory to pull the latest Docker images and update scaffold files.")
	},
}
