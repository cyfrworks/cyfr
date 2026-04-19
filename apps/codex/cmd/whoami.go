package cmd

import (
	"fmt"
	"os"

	"github.com/cyfr/codex/internal/output"
	"github.com/spf13/cobra"
)

// whoamiCmd composes output from two MCP actions post auth-refactor:
//
//   - `session.whoami` — local cyfr identity (user_id, email, provider, display_name).
//   - `registry.whoami` — cyfr.run identity (authenticated, personal_namespace,
//     memberships). Lives under the Compendium registry tool because the
//     auth sliver (Sanctum) is intentionally Compendium-free after the
//     refactor (see auth_refactor.md §"Whoami split").
//
// Failures on the registry call are soft — they print a warning but don't
// abort, so users who are logged in to cyfr locally but have no push tokens
// (e.g. first login before probe) still see their local identity.
var whoamiCmd = &cobra.Command{
	Use:     "whoami",
	Short:   "Show current identity",
	GroupID: "identity",
	Long: `Display the user, email, provider, and cyfr.run registry identity
associated with the current session.

Composes the local identity (` + "`session.whoami`" + `) with the registry
identity (` + "`registry.whoami`" + `) — the auth sliver was split in the
auth refactor so push-token state now lives under the Compendium registry
tool. Both actions are called; partial results are surfaced if one fails.`,
	Example: `  cyfr whoami
  cyfr whoami --json`,
	Run: func(cmd *cobra.Command, args []string) {
		client := newClient()

		session, sessionErr := client.CallTool("session", map[string]any{
			"action": "whoami",
		})
		if sessionErr != nil {
			handleToolError(sessionErr)
		}

		registry, registryErr := client.CallTool("registry", map[string]any{
			"action": "whoami",
		})
		// Don't abort on registry errors — the local identity is still useful.

		composed := composeWhoami(session, registry, registryErr)

		if flagJSON {
			output.JSON(composed)
			return
		}

		renderWhoami(composed, registryErr)
	},
}

// composeWhoami merges the two-action responses into a single shape so the
// JSON output is stable and --json consumers see both halves in one payload.
// Exported for registry.go's `registry whoami` which composes differently.
func composeWhoami(session, registry map[string]any, registryErr error) map[string]any {
	out := map[string]any{
		"session": session,
	}

	if registry != nil {
		out["registry"] = registry
	}

	if registryErr != nil {
		out["registry_error"] = registryErr.Error()
	}

	return out
}

// renderWhoami prints the non-JSON human form. Layout:
//
//	user_id:        github|https://github.com|12345
//	email:          alice@example.com
//	provider:       github
//	display_name:   @github:12345
//
//	registry:       registry.cyfr.run
//	  authenticated:  true
//	  personal:       alice
//	  memberships:    stripe.com (admin), acme.com (member)
//
// The registry block is omitted when `registry.whoami` failed; a single-line
// hint tells the user to run `cyfr login` if the local-identity side
// indicates they're logged in but the registry side is unreachable.
func renderWhoami(composed map[string]any, registryErr error) {
	session, _ := composed["session"].(map[string]any)

	fmt.Println("Local identity:")
	printField("  user_id", session["user_id"])
	printField("  email", session["email"])
	printField("  provider", session["provider"])
	printField("  display_name", session["display_name"])

	registry, hasRegistry := composed["registry"].(map[string]any)
	fmt.Println()

	if !hasRegistry || registry == nil {
		fmt.Println("Registry identity: unavailable")
		if registryErr != nil {
			fmt.Fprintf(os.Stderr, "  (registry.whoami failed: %v)\n", registryErr)
			fmt.Fprintln(os.Stderr, "  Run `cyfr login` to re-authenticate if you see this persistently.")
		}
		return
	}

	fmt.Println("Registry identity:")

	authenticated, _ := registry["authenticated"].(bool)
	if !authenticated {
		fmt.Println("  authenticated:  false")
		fmt.Fprintln(os.Stderr,
			"  Not logged in to cyfr.run. Run `cyfr login` to claim a personal "+
				"namespace and provision push tokens.")
		return
	}

	fmt.Println("  authenticated:  true")

	if personal, ok := registry["personal_namespace"].(map[string]any); ok && personal != nil {
		if slug, _ := personal["slug"].(string); slug != "" {
			fmt.Printf("  personal:       %s\n", slug)
		}
	}

	if memberships, ok := registry["memberships"].([]any); ok && len(memberships) > 0 {
		fmt.Print("  memberships:    ")
		for i, m := range memberships {
			entry, _ := m.(map[string]any)
			slug, _ := entry["slug"].(string)
			role, _ := entry["role"].(string)
			if i > 0 {
				fmt.Print(", ")
			}
			if role == "" {
				fmt.Print(slug)
			} else {
				fmt.Printf("%s (%s)", slug, role)
			}
		}
		fmt.Println()
	}
}

func printField(label string, v any) {
	s, ok := v.(string)
	if !ok || s == "" {
		return
	}
	fmt.Printf("%s: %s\n", label, s)
}
