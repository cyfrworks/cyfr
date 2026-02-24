package cmd

import (
	"fmt"
	"os"
	"strings"

	"github.com/cyfr/codex/internal/output"
	"github.com/cyfr/codex/internal/prompt"
	"github.com/spf13/cobra"
)

func init() {
	rootCmd.AddCommand(secretCmd)
	secretCmd.AddCommand(secretSetCmd)
	secretCmd.AddCommand(secretGetCmd)
	secretCmd.AddCommand(secretDeleteCmd)
	secretCmd.AddCommand(secretListCmd)
	secretCmd.AddCommand(secretGrantCmd)
	secretCmd.AddCommand(secretRevokeCmd)
}

var secretCmd = &cobra.Command{
	Use:     "secret",
	Short:   "Manage encrypted secrets",
	GroupID: "security",
	Long:    "Store, retrieve, and share secrets that are encrypted at rest with AES-256-GCM. Components must be explicitly granted access before they can read a secret.",
}

var secretSetCmd = &cobra.Command{
	Use:   "set [name=value]",
	Short: "Store a secret",
	Long:  "Create or update an encrypted secret. The value is encrypted server-side before storage. Run without arguments for interactive input with masked value.",
	Example: `  cyfr secret set DATABASE_URL=postgres://localhost/mydb
  cyfr secret set API_KEY=sk-abc123`,
	Args: cobra.RangeArgs(0, 1),
	Run: func(cmd *cobra.Command, args []string) {
		var name, value string

		switch {
		case len(args) >= 1:
			parts := strings.SplitN(args[0], "=", 2)
			if len(parts) != 2 {
				output.Error("Usage: cyfr secret set NAME=VALUE")
			}
			name = parts[0]
			value = parts[1]
		case prompt.IsInteractive(flagNoInteractive):
			var err error
			name, err = prompt.InputText("Secret name", "MY_API_KEY")
			if err != nil {
				if prompt.IsAborted(err) {
					os.Exit(130)
				}
				output.Errorf("Prompt failed: %v", err)
			}
			if name == "" {
				output.Error("Secret name cannot be empty.")
			}
			value, err = prompt.InputSecret("Secret value", "")
			if err != nil {
				if prompt.IsAborted(err) {
					os.Exit(130)
				}
				output.Errorf("Prompt failed: %v", err)
			}
			if value == "" {
				output.Error("Secret value cannot be empty.")
			}
		default:
			output.Error("Usage: cyfr secret set NAME=VALUE")
		}

		client := newClient()
		result, err := client.CallTool("secret", map[string]any{
			"action": "set",
			"name":   name,
			"value":  value,
		})
		if err != nil {
			output.Errorf("Failed: %v", err)
		}
		if flagJSON {
			output.JSON(result)
		} else {
			fmt.Printf("Secret '%s' stored.\n", name)
		}
	},
}

var secretGetCmd = &cobra.Command{
	Use:     "get [name]",
	Short:   "Retrieve a secret (masked)",
	Long:    "Fetch a secret's metadata and masked value from the server. Run without arguments for interactive selection.",
	Example: "  cyfr secret get DATABASE_URL",
	Args:    cobra.RangeArgs(0, 1),
	Run: func(cmd *cobra.Command, args []string) {
		var name string

		switch {
		case len(args) >= 1:
			name = args[0]
		case prompt.IsInteractive(flagNoInteractive):
			client := newClient()
			opts, err := prompt.FetchSecrets(client)
			if err != nil {
				handleToolError(err)
			}
			if len(opts) == 0 {
				output.Error("No secrets found. Create one with 'cyfr secret set NAME=VALUE'.")
			}
			selected, err := prompt.SelectOne("Select a secret", opts)
			if err != nil {
				if prompt.IsAborted(err) {
					os.Exit(130)
				}
				output.Errorf("Prompt failed: %v", err)
			}
			name = selected
		default:
			output.Error("Usage: cyfr secret get <name>")
		}

		client := newClient()
		result, err := client.CallTool("secret", map[string]any{
			"action": "get",
			"name":   name,
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

var secretDeleteCmd = &cobra.Command{
	Use:     "delete [name]",
	Short:   "Delete a secret",
	Long:    "Permanently remove a secret and revoke all component grants. Run without arguments for interactive selection.",
	Example: "  cyfr secret delete DATABASE_URL",
	Args:    cobra.RangeArgs(0, 1),
	Run: func(cmd *cobra.Command, args []string) {
		var name string

		switch {
		case len(args) >= 1:
			name = args[0]
		case prompt.IsInteractive(flagNoInteractive):
			client := newClient()
			opts, err := prompt.FetchSecrets(client)
			if err != nil {
				handleToolError(err)
			}
			if len(opts) == 0 {
				output.Error("No secrets found. Create one with 'cyfr secret set NAME=VALUE'.")
			}
			selected, err := prompt.SelectOne("Select a secret to delete", opts)
			if err != nil {
				if prompt.IsAborted(err) {
					os.Exit(130)
				}
				output.Errorf("Prompt failed: %v", err)
			}
			confirmed, err := prompt.Confirm(fmt.Sprintf("Delete secret '%s'?", selected))
			if err != nil {
				if prompt.IsAborted(err) {
					os.Exit(130)
				}
				output.Errorf("Prompt failed: %v", err)
			}
			if !confirmed {
				fmt.Println("Cancelled.")
				return
			}
			name = selected
		default:
			output.Error("Usage: cyfr secret delete <name>")
		}

		client := newClient()
		result, err := client.CallTool("secret", map[string]any{
			"action": "delete",
			"name":   name,
		})
		if err != nil {
			output.Errorf("Failed: %v", err)
		}
		if flagJSON {
			output.JSON(result)
		} else {
			fmt.Printf("Secret '%s' deleted.\n", name)
		}
	},
}

var secretListCmd = &cobra.Command{
	Use:     "list",
	Short:   "List all secrets",
	Long:    "List all stored secret names and their metadata without revealing values.",
	Example: "  cyfr secret list",
	Run: func(cmd *cobra.Command, args []string) {
		client := newClient()
		result, err := client.CallTool("secret", map[string]any{
			"action": "list",
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

var secretGrantCmd = &cobra.Command{
	Use:   "grant [type] [component] [name]",
	Short: "Grant component access to a secret",
	Long: `Allow a component to read the named secret at execution time.
Omit the version to apply to all registered versions. Run without arguments
for interactive selection — already-granted secrets are pre-selected, and
deselecting a secret revokes access.`,
	Example: `  cyfr secret grant c:local.claude ANTHROPIC_API_KEY          (all versions)
  cyfr secret grant c:local.claude:0.1.0 ANTHROPIC_API_KEY    (specific version only)
  cyfr secret grant c local.claude ANTHROPIC_API_KEY`,
	Args: cobra.RangeArgs(0, 3),
	Run: func(cmd *cobra.Command, args []string) {
		args = joinTypeShorthand(args)
		var components []string
		var secretNames []string

		client := newClient()

		switch {
		case len(args) >= 2:
			components = resolveAllVersions(client, args[0])
			secretNames = []string{args[1]}
		case prompt.IsInteractive(flagNoInteractive):
			// Select component
			compOpts, err := prompt.FetchComponents(client)
			if err != nil {
				handleToolError(err)
			}
			if len(compOpts) == 0 {
				output.Error("No components found. Register one first.")
			}
			comp, err := prompt.SelectOne("Select a component", compOpts)
			if err != nil {
				if prompt.IsAborted(err) {
					os.Exit(130)
				}
				output.Errorf("Prompt failed: %v", err)
			}
			components = []string{comp}

			// Fetch all secrets and which are already granted
			secretOpts, err := prompt.FetchSecrets(client)
			if err != nil {
				handleToolError(err)
			}
			if len(secretOpts) == 0 {
				output.Error("No secrets found. Create one with 'cyfr secret set NAME=VALUE'.")
			}
			granted, _ := prompt.FetchGrantedSecrets(client, comp)
			selected, err := prompt.SelectMany("Select secrets to grant", secretOpts, granted...)
			if err != nil {
				if prompt.IsAborted(err) {
					os.Exit(130)
				}
				output.Errorf("Prompt failed: %v", err)
			}

			// Diff: grant newly selected, revoke deselected
			selectedSet := make(map[string]bool, len(selected))
			for _, s := range selected {
				selectedSet[s] = true
			}
			grantedSet := make(map[string]bool, len(granted))
			for _, g := range granted {
				grantedSet[g] = true
			}

			// Grant secrets that are selected but weren't previously granted
			for _, name := range selected {
				if grantedSet[name] {
					continue
				}
				secretNames = append(secretNames, name)
			}

			// Revoke secrets that were granted but are now deselected
			var toRevoke []string
			for _, name := range granted {
				if !selectedSet[name] {
					toRevoke = append(toRevoke, name)
				}
			}

			for _, name := range toRevoke {
				_, err := client.CallTool("secret", map[string]any{
					"action":        "revoke",
					"component_ref": comp,
					"name":          name,
				})
				if err != nil {
					output.Errorf("Failed: %v", err)
				}
				if flagJSON {
					// skip text output in JSON mode; grant results below cover it
				} else {
					fmt.Printf("Revoked '%s' access to secret '%s'.\n", comp, name)
				}
			}

			if len(secretNames) == 0 && len(toRevoke) == 0 {
				fmt.Println("No changes.")
				return
			}
			if len(secretNames) == 0 {
				return
			}
		default:
			output.Error("Usage: cyfr secret grant <component> <secret_name>")
		}

		for _, component := range components {
			for _, name := range secretNames {
				result, err := client.CallTool("secret", map[string]any{
					"action":        "grant",
					"component_ref": component,
					"name":          name,
				})
				if err != nil {
					output.Errorf("Failed: %v", err)
				}
				if flagJSON {
					output.JSON(result)
				} else {
					fmt.Printf("Granted '%s' access to secret '%s'.\n", component, name)
				}
			}
		}
		if !flagJSON && len(components) > 1 {
			fmt.Fprintf(os.Stderr, "\nApplied to %d versions.\n", len(components))
		}
	},
}

var secretRevokeCmd = &cobra.Command{
	Use:   "revoke [type] [component] [name]",
	Short: "Revoke component access to a secret",
	Long: `Remove a component's ability to read the named secret.
Omit the version to revoke across all registered versions. Run without
arguments for interactive selection.`,
	Example: `  cyfr secret revoke c:local.claude ANTHROPIC_API_KEY          (all versions)
  cyfr secret revoke c:local.claude:0.1.0 ANTHROPIC_API_KEY    (specific version only)
  cyfr secret revoke c local.claude ANTHROPIC_API_KEY`,
	Args: cobra.RangeArgs(0, 3),
	Run: func(cmd *cobra.Command, args []string) {
		args = joinTypeShorthand(args)
		var components []string
		var secretNames []string

		client := newClient()

		switch {
		case len(args) >= 2:
			components = resolveAllVersions(client, args[0])
			secretNames = []string{args[1]}
		case prompt.IsInteractive(flagNoInteractive):
			// Select component
			compOpts, err := prompt.FetchComponents(client)
			if err != nil {
				handleToolError(err)
			}
			if len(compOpts) == 0 {
				output.Error("No components found.")
			}
			comp, err := prompt.SelectOne("Select a component", compOpts)
			if err != nil {
				if prompt.IsAborted(err) {
					os.Exit(130)
				}
				output.Errorf("Prompt failed: %v", err)
			}
			components = []string{comp}

			// Multi-select secrets to revoke
			secretOpts, err := prompt.FetchSecrets(client)
			if err != nil {
				handleToolError(err)
			}
			if len(secretOpts) == 0 {
				output.Error("No secrets found.")
			}
			selected, err := prompt.SelectMany("Select secrets to revoke", secretOpts)
			if err != nil {
				if prompt.IsAborted(err) {
					os.Exit(130)
				}
				output.Errorf("Prompt failed: %v", err)
			}
			if len(selected) == 0 {
				fmt.Println("No secrets selected.")
				return
			}
			secretNames = selected
		default:
			output.Error("Usage: cyfr secret revoke <component> <secret_name>")
		}

		for _, component := range components {
			for _, name := range secretNames {
				result, err := client.CallTool("secret", map[string]any{
					"action":        "revoke",
					"component_ref": component,
					"name":          name,
				})
				if err != nil {
					output.Errorf("Failed: %v", err)
				}
				if flagJSON {
					output.JSON(result)
				} else {
					fmt.Printf("Revoked '%s' access to secret '%s'.\n", component, name)
				}
			}
		}
		if !flagJSON && len(components) > 1 {
			fmt.Fprintf(os.Stderr, "\nApplied to %d versions.\n", len(components))
		}
	},
}
