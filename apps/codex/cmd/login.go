package cmd

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/cyfr/codex/internal/config"
	"github.com/cyfr/codex/internal/output"
	"github.com/spf13/cobra"
)

func init() {
	rootCmd.AddCommand(loginCmd)
	rootCmd.AddCommand(logoutCmd)
	rootCmd.AddCommand(whoamiCmd)
}

var loginCmd = &cobra.Command{
	Use:     "login",
	Short:   "Authenticate via Device Flow",
	GroupID: "identity",
	Long:    "Start an OAuth 2.0 Device Authorization Flow via GitHub. The CLI prints a one-time code and a URL; open the URL in a browser, enter the code, and the CLI will receive a session token automatically.",
	Example: "  cyfr login",
	Run: func(cmd *cobra.Command, args []string) {
		client := newClient()

		// Initialize MCP session
		if err := client.Initialize(); err != nil {
			output.Errorf("Failed to connect: %v", err)
		}

		// Start device flow
		result, err := client.CallTool("session", map[string]any{
			"action":   "device-init",
			"provider": "github",
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
				"provider":    "github",
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
				registryToken, _ := pollResult["registry_token"].(string)
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

					// Save OCI credentials for registry.cyfr.run (requires registry JWT)
					if registryToken != "" {
						username := email
						if username == "" {
							username = "cyfr"
						}
						err := saveOCICredentials("registry.cyfr.run", username, registryToken)
						if err != nil {
							fmt.Fprintf(os.Stderr, "Error: Failed to save registry credentials: %v\n", err)
						} else {
							fmt.Println("Registry credentials saved.")
						}
					} else {
						regErr, _ := pollResult["registry_error"].(string)
						if regErr != "" {
							fmt.Fprintf(os.Stderr, "Error: Registry login failed: %s\n", regErr)
						} else {
							fmt.Fprintln(os.Stderr, "Error: Registry token not received. Run 'cyfr login' again to retry.")
						}
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
	GroupID: "identity",
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
	GroupID: "identity",
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

			// Hint if not authenticated with the registry
			if reg, ok := result["registry"].(map[string]any); ok {
				if auth, ok := reg["authenticated"].(bool); ok && !auth {
					reason, _ := reg["reason"].(string)
					switch reason {
					case "invalid_credentials":
						fmt.Fprintln(os.Stderr, "\nRegistry credentials are invalid. Run 'cyfr login' to re-authenticate.")
					case "unreachable":
						// Don't hint login if the registry is just down
					default:
						fmt.Fprintln(os.Stderr, "\nNot logged in to registry. Run 'cyfr login' to authenticate.")
					}
				}
			}
		}
	},
}

func saveOCICredentials(registry, username, password string) error {
	homeDir, err := os.UserHomeDir()
	if err != nil {
		return err
	}

	credPath := filepath.Join(homeDir, ".cyfr", "oci-credentials.json")
	var creds map[string]any

	if data, err := os.ReadFile(credPath); err == nil {
		_ = json.Unmarshal(data, &creds)
	}
	if creds == nil {
		creds = map[string]any{}
	}
	registries, ok := creds["registries"].(map[string]any)
	if !ok {
		registries = map[string]any{}
	}
	registries[registry] = map[string]any{
		"username": username,
		"password": password,
	}
	creds["registries"] = registries

	if err := os.MkdirAll(filepath.Dir(credPath), 0700); err != nil {
		return err
	}

	data, _ := json.MarshalIndent(creds, "", "  ")
	if err := os.WriteFile(credPath, data, 0600); err != nil {
		return err
	}
	return nil
}
