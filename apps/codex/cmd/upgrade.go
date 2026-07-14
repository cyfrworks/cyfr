package cmd

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"

	"github.com/cyfr/codex/internal/output"
	"github.com/cyfr/codex/internal/release"
	"github.com/spf13/cobra"
)

func init() {
	rootCmd.AddCommand(upgradeCmd)
}

var upgradeCmd = &cobra.Command{
	Use:     "upgrade",
	Short:   "Upgrade the CYFR Codex binary",
	Long:    "Upgrade the CYFR Codex binary (system-wide). Run 'cyfr update' in each project directory to pull the latest Docker image and update scaffold files.",
	GroupID: "server",
	Run: func(cmd *cobra.Command, args []string) {
		// Find the latest published CYFR release (bare-semver version).
		latest, err := release.Latest(context.Background())
		if err != nil {
			output.Errorf("Failed to check for updates: %v", err)
		}

		// Compare to the current version — only upgrade if not already current.
		current := strings.TrimPrefix(Version, "v")
		cliUpToDate := current == latest

		if cliUpToDate {
			fmt.Printf("CYFR Codex already up to date (%s)\n", current)
		} else {
			fmt.Printf("Upgrading CYFR Codex from %s to %s...\n", current, latest)

			// Check if installed via the Homebrew cask (--cask avoids the same-name formula->cask ambiguity)
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
				update := exec.Command("brew", "update")
				update.Stdout = os.Stdout
				update.Stderr = os.Stderr
				if err := update.Run(); err != nil {
					output.Errorf("brew update failed: %v", err)
				}

				upgrade := exec.Command("brew", "upgrade", "--cask", "cyfr")
				upgrade.Stdout = os.Stdout
				upgrade.Stderr = os.Stderr
				upgradeErr := upgrade.Run()

				// `brew upgrade` exits 0 even when it changes nothing (e.g. the cask
				// is wedged mid formula->cask migration and stays on the old version),
				// so verify the actually-installed version, not the exit code.
				switch installed := installedCaskVersion(); {
				case upgradeErr != nil:
					fmt.Printf("Warning: brew upgrade --cask cyfr: %v\n", upgradeErr)
				case installed == latest:
					fmt.Printf("CYFR Codex upgraded to %s\n", latest)
				case installed != "":
					fmt.Printf("Warning: brew exited cleanly but cyfr is still %s (expected %s).\n", installed, latest)
					fmt.Println("  Try `brew update-reset` then `cyfr upgrade` again, or reinstall with `brew uninstall --cask cyfr && brew install --cask cyfr`.")
				default:
					fmt.Println("Warning: could not verify the installed cyfr version; check with `brew list --cask --versions cyfr`.")
				}
			} else {
				// Install to the same directory as the currently running binary
				// so upgrades don't create duplicates in different locations.
				fmt.Println("Upgrading via install script...")
				env := os.Environ()
				if selfPath, err := os.Executable(); err == nil {
					env = append(env, "CYFR_INSTALL_DIR="+filepath.Dir(selfPath))
				}
				// Install exactly the release we resolved, not whatever the
				// installer would re-resolve as latest in the meantime.
				env = append(env, "CYFR_VERSION="+latest)
				// Fetch the installer pinned to the resolved release — first the
				// release asset, falling back to the immutable git-tag raw URL
				// (older releases predate the install.sh asset). Piping main-branch
				// HEAD would let a repo compromise on main alter the installer for
				// every upgrader without a release ever being cut.
				installerURL := fmt.Sprintf("https://github.com/cyfrworks/cyfr/releases/download/%s/install.sh", latest)
				fallbackURL := fmt.Sprintf("https://raw.githubusercontent.com/cyfrworks/cyfr/%s/scripts/install.sh", latest)
				// On Linux, `cp /tmp/cyfr /usr/local/bin/cyfr` fails with
				// "text file busy" if the destination is a binary that's
				// currently being executed — and that's exactly us. Hand off
				// via execve(2) so this Go process is gone (and its mapping
				// of /usr/local/bin/cyfr released) by the time the installer
				// runs cp. We tack on the post-install reminder via the same
				// shell command since after exec we can't print anything more.
				// Windows has no execve; fall back to cmd.Run there.
				cmdline := fmt.Sprintf("{ curl -fsSL %s || curl -fsSL %s; } | sh", installerURL, fallbackURL) +
					" && printf '\\nRun '\\''cyfr update'\\'' in each project directory to pull the latest Docker images and update scaffold files.\\n'"

				if runtime.GOOS == "windows" {
					script := exec.Command("sh", "-c", cmdline)
					script.Stdout = os.Stdout
					script.Stderr = os.Stderr
					script.Env = env
					if err := script.Run(); err != nil {
						fmt.Printf("Install script failed: %v\n", err)
						fmt.Printf("Download manually from: https://github.com/cyfrworks/cyfr/releases/tag/%s\n", latest)
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
					fmt.Printf("Download manually from: https://github.com/cyfrworks/cyfr/releases/tag/%s\n", latest)
				}
				return
			}
		}

		fmt.Println("\nRun 'cyfr update' in each project directory to pull the latest Docker images and update scaffold files.")
	},
}

// installedCaskVersion returns the version Homebrew reports for the cyfr cask
// (e.g. "0.5.2"), or "" if it can't be determined. `brew list --cask --versions
// cyfr` prints a line like "cyfr 0.5.2".
func installedCaskVersion() string {
	out, err := exec.Command("brew", "list", "--cask", "--versions", "cyfr").Output()
	if err != nil {
		return ""
	}
	fields := strings.Fields(strings.TrimSpace(string(out)))
	if len(fields) < 2 {
		return ""
	}
	return strings.TrimPrefix(fields[len(fields)-1], "v")
}
