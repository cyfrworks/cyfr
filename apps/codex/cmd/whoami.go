package cmd

import (
	"fmt"
	"os"

	"github.com/cyfr/codex/internal/output"
	"github.com/spf13/cobra"
)

// whoamiCmd composes output from two MCP actions post auth-refactor:
//
//   - `session.whoami` — local cyfr identity (user_id, email, provider).
//   - `registry.whoami` — cyfr.run identity (authenticated, personal_namespace,
//     memberships). Lives under the Compendium registry tool because the
//     auth sliver (Sanctum) is intentionally Compendium-free.
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
identity (` + "`registry.whoami`" + `). The two actions are split so the
auth sliver stays registry-free; push-token state lives under the Compendium
registry tool. Both actions are called; partial results are surfaced if one
fails.`,
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

// renderWhoami prints a flat, labelled property list. The CYFR user line is
// the primary handle — the cyfr.run personal-namespace slug when claimed, or
// a parenthetical status when not. Provider / Email / User ID follow,
// memberships render as a single line when present.
//
// Five states drive the `CYFR User:` line:
//
//   - claimed:       `moonmoon`
//   - unclaimed:     `(no personal namespace claimed)`
//   - reg. unauth:   `(not logged in to cyfr.run)`
//   - reg. offline:  `(registry.cyfr.run unreachable)`
//   - signed out:    skipped; output is just `Not signed in.`
//
// The pipe-delimited `User ID` is kept at the bottom for support/grep but no
// longer tucked under a separate "details:" block — per user feedback it's
// cleaner as one continuous list.
func renderWhoami(composed map[string]any, registryErr error) {
	session, _ := composed["session"].(map[string]any)
	registry, hasRegistry := composed["registry"].(map[string]any)

	userID, _ := session["user_id"].(string)
	email, _ := session["email"].(string)
	provider, _ := session["provider"].(string)

	// Signed out (no local identity at all).
	if userID == "" {
		fmt.Println("Not signed in.")
		fmt.Fprintln(os.Stderr, "Run `cyfr login` to authenticate.")
		return
	}

	authenticated, _ := registry["authenticated"].(bool)
	personal := personalSlug(registry)

	// CYFR User line — primary identity.
	var cyfrUser string
	var hint string
	switch {
	case hasRegistry && authenticated && personal != "":
		cyfrUser = personal
	case hasRegistry && authenticated:
		cyfrUser = "(no personal namespace claimed)"
		hint = "Run `cyfr login` to claim your personal namespace."
	case hasRegistry:
		cyfrUser = "(not logged in to cyfr.run)"
		hint = "Run `cyfr login` to claim a personal namespace and provision push tokens."
	default:
		cyfrUser = "(registry.cyfr.run unreachable)"
	}

	fmt.Printf("CYFR User: %s\n", cyfrUser)
	if provider != "" {
		fmt.Printf("Provider: %s\n", prettyProvider(provider))
	}
	if email != "" {
		fmt.Printf("Email: %s\n", email)
	}

	if hasRegistry {
		if memberships, ok := registry["memberships"].([]any); ok && len(memberships) > 0 {
			fmt.Print("Memberships: ")
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

	fmt.Printf("User ID: %s\n", userID)

	if hint != "" {
		fmt.Fprintln(os.Stderr, hint)
	}
	if !hasRegistry && registryErr != nil {
		fmt.Fprintf(os.Stderr, "(registry.whoami failed: %v)\n", registryErr)
	}
}

// prettyProvider renders the machine-name provider as a user-facing label.
func prettyProvider(p string) string {
	switch p {
	case "github":
		return "GitHub"
	case "google":
		return "Google"
	case "oidcc":
		return "OIDC"
	case "":
		return "unknown"
	default:
		return p
	}
}

// personalSlug extracts the personal-namespace slug from the registry response,
// returning "" when absent. Handles both the map shape from the authoritative
// response and a nil entry under the same key.
func personalSlug(registry map[string]any) string {
	if registry == nil {
		return ""
	}
	personal, ok := registry["personal_namespace"].(map[string]any)
	if !ok || personal == nil {
		return ""
	}
	slug, _ := personal["slug"].(string)
	return slug
}
