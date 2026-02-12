package cmd

import (
	"fmt"
	"time"

	"github.com/cyfr/codex/internal/config"
	"github.com/cyfr/codex/internal/output"
	"github.com/spf13/cobra"
)

func init() {
	loginCmd.Flags().String("provider", "github", "OAuth provider (github, google)")
	rootCmd.AddCommand(loginCmd)
	rootCmd.AddCommand(logoutCmd)
	rootCmd.AddCommand(whoamiCmd)
}

var loginCmd = &cobra.Command{
	Use:     "login",
	Short:   "Authenticate via Device Flow",
	GroupID: "start",
	Long:    "Start an OAuth 2.0 Device Authorization Flow. The CLI prints a one-time code and a URL; open the URL in a browser, enter the code, and the CLI will receive a session token automatically.",
	Example: `  cyfr login
  cyfr login --provider google`,
	Run: func(cmd *cobra.Command, args []string) {
		client := newClient()
		provider, _ := cmd.Flags().GetString("provider")

		// Initialize MCP session
		if err := client.Initialize(); err != nil {
			output.Errorf("Failed to connect: %v", err)
		}
		saveSessionID(client)

		// Start device flow
		result, err := client.CallTool("session", map[string]any{
			"action":   "device-init",
			"provider": provider,
		})
		if err != nil {
			output.Errorf("Failed to start login: %v", err)
		}

		// Show user code and verification URL
		userCode, _ := result["user_code"].(string)
		verifyURL, _ := result["verification_uri"].(string)
		deviceCode, _ := result["device_code"].(string)
		interval, _ := result["interval"].(float64)
		if interval < 5 {
			interval = 5
		}

		fmt.Printf("Open %s and enter code: %s\n", verifyURL, userCode)
		fmt.Println("Waiting for authorization...")

		// Poll for completion
		for {
			time.Sleep(time.Duration(interval) * time.Second)

			pollResult, err := client.CallTool("session", map[string]any{
				"action":      "device-poll",
				"device_code": deviceCode,
				"provider":    provider,
			})
			if err != nil {
				// Network errors etc — keep trying
				continue
			}

			status, _ := pollResult["status"].(string)
			switch status {
			case "complete":
				// Save session ID from the auth response
				sessionID, _ := pollResult["session_id"].(string)
				cfg, _ := config.Load()
				if cfg.Current() != nil {
					if sessionID != "" {
						cfg.Current().SessionID = sessionID
					} else if client.SessionID != "" {
						cfg.Current().SessionID = client.SessionID
					}
					_ = cfg.Save()
				}

				if user, ok := pollResult["user"].(map[string]any); ok {
					email, _ := user["email"].(string)
					if email != "" {
						fmt.Printf("Logged in as %s\n", email)
					} else {
						fmt.Println("Logged in successfully!")
					}
				} else {
					fmt.Println("Logged in successfully!")
				}
				if flagJSON {
					output.JSON(pollResult)
				}
				return

			case "expired":
				output.Error("Device code expired. Run 'cyfr login' again.")

			case "denied":
				output.Error("Authorization denied.")

			default:
				// "pending" or unknown — keep polling
				continue
			}
		}
	},
}

var logoutCmd = &cobra.Command{
	Use:     "logout",
	Short:   "End current session",
	GroupID: "start",
	Long:    "Invalidate the current session on the server and remove the cached session token from local config.",
	Example: "  cyfr logout",
	Run: func(cmd *cobra.Command, args []string) {
		client := newClient()

		// Clear saved session locally first — even if the server call fails
		// (e.g. session already expired), the user still wants local cleanup.
		cfg, _ := config.Load()
		if cfg.Current() != nil {
			cfg.Current().SessionID = ""
			_ = cfg.Save()
		}

		result, err := client.CallTool("session", map[string]any{
			"action": "logout",
		})
		if err != nil {
			// Session was already gone on the server — that's fine
			if flagJSON {
				output.JSON(map[string]any{"status": "logged_out"})
			} else {
				fmt.Println("Logged out successfully.")
			}
			return
		}

		if flagJSON {
			output.JSON(result)
		} else {
			fmt.Println("Logged out successfully.")
		}
	},
}

var whoamiCmd = &cobra.Command{
	Use:     "whoami",
	Short:   "Show current identity",
	GroupID: "start",
	Long:    "Display the user, email, and provider associated with the current session.",
	Example: `  cyfr whoami
  cyfr whoami --json`,
	Run: func(cmd *cobra.Command, args []string) {
		client := newClient()

		result, err := client.CallTool("session", map[string]any{
			"action": "whoami",
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
