// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"context"
	"fmt"
	"strings"

	"github.com/cyfr/codex/internal/output"
	"github.com/cyfr/codex/internal/prompt"
	"github.com/spf13/cobra"
)

func init() {
	aquaResetCmd.Flags().Bool("all", false,
		"Also delete the roles and scrolls the estate made, so exactly the shipped set remains")

	rootCmd.AddCommand(aquaCmd)
	aquaCmd.AddCommand(aquaListCmd)
	aquaCmd.AddCommand(aquaGetCmd)
	aquaCmd.AddCommand(aquaStatusCmd)
	aquaCmd.AddCommand(aquaResetCmd)
	aquaCmd.AddCommand(aquaSkillsCmd)
	aquaSkillsCmd.AddCommand(aquaSkillsListCmd)
	aquaSkillsCmd.AddCommand(aquaSkillsGetCmd)
}

var aquaCmd = &cobra.Command{
	Use:     "aqua",
	Short:   "The estate's AQUA — its soul, roles and scrolls",
	GroupID: "admin",
	Long: `The estate has one assistant, AQUA. This command manages what it is made of:

  the soul      aqua.md — who AQUA is (name "aqua"); edited, never created or deleted
  the roles     the roles AQUA clones into, one file each
  the scrolls   what AQUA has learned — aqua/skills/<name>/SKILL.md
  the guides    the read-only documentation guides

"list" shows all of it; "get" reads the soul, a role or a guide; "skills" reads
the scrolls; "status" says which files are shipped, edited or yours; "reset"
reverts edited copies of shipped files (and, with --all, deletes what the estate
made so only the shipped set remains).`,
}

var aquaListCmd = &cobra.Command{
	Use:   "list",
	Short: "List the soul, roles, guides and scrolls",
	Long:  "List everything the estate's AQUA is made of: the soul, its roles and the guides, then the scrolls it has learned.",
	Example: `  cyfr aqua list
  cyfr aqua list --json`,
	Args: cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		client := newClient()
		result, err := client.CallTool(cmd.Context(), "aqua", map[string]any{
			"action": "list",
		})
		if err != nil {
			return handleToolError(err)
		}
		scrolls, err := client.CallTool(cmd.Context(), "aqua", map[string]any{
			"action": "skill_list",
		})
		result = withScrolls(result, scrolls, err)

		if flagJSON {
			output.JSON(result)
			return nil
		}
		renderAquaList(result)
		return nil
	},
}

var aquaGetCmd = &cobra.Command{
	Use:   "get [name]",
	Short: "Display the soul, a role or a guide",
	Long:  "Retrieve and display the soul (name aqua), one of its roles, or a guide by name. Run without arguments for interactive selection. Scrolls are read with `cyfr aqua skills get`.",
	Example: `  cyfr aqua get aqua
  cyfr aqua get component-guide
  cyfr aqua get aqua_builder --json`,
	Args: cobra.RangeArgs(0, 1),
	RunE: func(cmd *cobra.Command, args []string) error {
		name, err := pickTarget(cmd.Context(), args, selector{
			Title: "Select the soul, a role or a guide",
			Empty: "Nothing to show.",
			Usage: "Usage: cyfr aqua get <name>",
			Fetch: func(ctx context.Context) ([]prompt.Option, error) {
				return prompt.FetchGuides(ctx, newClient())
			},
		})
		if err != nil || name == "" {
			return err
		}

		client := newClient()
		result, err := client.CallTool(cmd.Context(), "aqua", map[string]any{
			"action": "get",
			"name":   name,
		})
		if err != nil {
			return handleToolError(err)
		}
		if flagJSON {
			output.JSON(result)
		} else {
			fmt.Println(result["content"])
		}
		return nil
	},
}

var aquaStatusCmd = &cobra.Command{
	Use:   "status",
	Short: "Which files are shipped, edited or yours",
	Long: `Show every file in the estate's aqua tree and where it comes from:

  bundled   as shipped with the server
  edited    a shipped file the estate changed — "reset" reverts it
  yours     a role or scroll the estate made — "reset --all" deletes it`,
	Example: `  cyfr aqua status
  cyfr aqua status --json`,
	Args: cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		result, err := newClient().CallTool(cmd.Context(), "aqua", map[string]any{
			"action": "status",
		})
		if err != nil {
			return handleToolError(err)
		}
		if flagJSON {
			output.JSON(result)
			return nil
		}
		renderAquaStatus(result)
		return nil
	},
}

var aquaResetCmd = &cobra.Command{
	Use:   "reset",
	Short: "Revert edited copies of shipped files",
	Long: "Revert every shipped file the estate edited — the soul, shipped roles and shipped scrolls — to as shipped. " +
		"Roles and scrolls the estate made are kept unless --all, which deletes them too so exactly the shipped set remains.",
	Example: `  cyfr aqua reset
  cyfr aqua reset --all`,
	Args: cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		all, _ := cmd.Flags().GetBool("all")

		// Deleting what the estate made is the irreversible half: it asks
		// when there is someone to ask. A plain reset only reverts to
		// shipped and runs straight through.
		if all && prompt.IsInteractive(flagNoInteractive) {
			confirmed, err := prompt.Confirm(
				"Revert every edited file AND delete the roles and scrolls the estate made? This cannot be undone.")
			if err != nil {
				if prompt.IsAborted(err) {
					return prompt.ErrAborted
				}
				return fmt.Errorf("Prompt failed: %w", err)
			}
			if !confirmed {
				fmt.Println("Cancelled.")
				return nil
			}
		}

		toolArgs := map[string]any{"action": "reset"}
		if all {
			toolArgs["all"] = true
		}
		result, err := newClient().CallTool(cmd.Context(), "aqua", toolArgs)
		if err != nil {
			return handleToolError(err, "Reset failed")
		}
		if flagJSON {
			output.JSON(result)
			return nil
		}
		renderAquaReset(result, all)
		return nil
	},
}

var aquaSkillsCmd = &cobra.Command{
	Use:   "skills",
	Short: "The scrolls AQUA has learned",
	Long: "Read the scrolls — the procedures the estate's AQUA has learned, one aqua/skills/<name>/SKILL.md each. " +
		"Run bare (or with list) for the index, get for one scroll's body.",
	Example: `  cyfr aqua skills
  cyfr aqua skills get release-notes`,
	Args: cobra.NoArgs,
	RunE: runAquaSkillsList,
}

var aquaSkillsListCmd = &cobra.Command{
	Use:   "list",
	Short: "List the scrolls",
	Example: `  cyfr aqua skills list
  cyfr aqua skills list --json`,
	Args: cobra.NoArgs,
	RunE: runAquaSkillsList,
}

func runAquaSkillsList(cmd *cobra.Command, args []string) error {
	result, err := newClient().CallTool(cmd.Context(), "aqua", map[string]any{
		"action": "skill_list",
	})
	if err != nil {
		return handleToolError(err)
	}
	if flagJSON {
		output.JSON(result)
		return nil
	}
	renderScrollList(result)
	return nil
}

var aquaSkillsGetCmd = &cobra.Command{
	Use:   "get [name]",
	Short: "Display a scroll",
	Long:  "Retrieve and display one scroll by name — its description, then its body. Run without arguments for interactive selection.",
	Example: `  cyfr aqua skills get release-notes
  cyfr aqua skills get release-notes --json`,
	Args: cobra.RangeArgs(0, 1),
	RunE: func(cmd *cobra.Command, args []string) error {
		name, err := pickTarget(cmd.Context(), args, selector{
			Title: "Select a scroll",
			Empty: "No scrolls yet.",
			Usage: "Usage: cyfr aqua skills get <name>",
			Fetch: func(ctx context.Context) ([]prompt.Option, error) {
				return prompt.FetchScrolls(ctx, newClient())
			},
		})
		if err != nil || name == "" {
			return err
		}

		result, err := newClient().CallTool(cmd.Context(), "aqua", map[string]any{
			"action": "skill_get",
			"name":   name,
		})
		if err != nil {
			return handleToolError(err)
		}
		if flagJSON {
			output.JSON(result)
			return nil
		}
		renderScroll(result)
		return nil
	},
}

// withScrolls folds the second call of a listing into the first so one
// listing goes out, on the wire too: the scrolls ride the soul/roles/guides
// result under their own wire key — or, when that call failed, its error
// does, so the soul, roles and guides still show and the JSON says what
// is missing.
func withScrolls(result, scrolls map[string]any, err error) map[string]any {
	if err != nil {
		result["skills_error"] = err.Error()
		return result
	}
	result["skills"] = scrolls["skills"]
	return result
}

// --- rendering ---

// renderAquaList prints the soul, the roles and the guides — the list
// result's "guides", soul first — in sections, then the scrolls under
// "skills" (or the one line saying why there are none to show). One name
// column across every section, so the eye reads it as one listing.
func renderAquaList(result map[string]any) {
	guides := mapsOf(result["guides"])
	scrolls := mapsOf(result["skills"])

	width := 0
	for _, m := range guides {
		width = max(width, len(str(m["name"])))
	}
	for _, m := range scrolls {
		width = max(width, len(str(m["name"])))
	}

	sections := []struct{ heading, kind string }{
		{"Soul", "soul"},
		{"Roles", "role"},
		{"Guides", "doc"},
	}
	for _, s := range sections {
		fmt.Println(s.heading)
		n := 0
		for _, m := range guides {
			if str(m["type"]) != s.kind {
				continue
			}
			printAquaRow(width, m)
			n++
		}
		if n == 0 {
			fmt.Println("  none")
		}
	}

	if reason := str(result["skills_error"]); reason != "" {
		fmt.Printf("Scrolls: unavailable (%s)\n", reason)
		return
	}
	fmt.Println("Scrolls")
	if len(scrolls) == 0 {
		fmt.Println("  none yet")
	}
	for _, m := range scrolls {
		printAquaRow(width, m)
	}
}

// printAquaRow prints one named entry: the name, then its title and
// description joined by a dash — the title left out when it only repeats
// the name (a scroll's usually does).
func printAquaRow(width int, m map[string]any) {
	name := str(m["name"])
	title := str(m["title"])
	description := str(m["description"])

	var about string
	switch {
	case title != "" && title != name && description != "":
		about = title + " — " + description
	case title != "" && title != name:
		about = title
	default:
		about = description
	}
	fmt.Printf("  %-*s  %s\n", width, name, about)
}

// aquaStateLabel puts the wire provenance into the words the CLI uses:
// bundled stays, bundled_modified is "edited", user is "yours".
func aquaStateLabel(state string) string {
	switch state {
	case "bundled_modified":
		return "edited"
	case "user":
		return "yours"
	}
	return state
}

// renderAquaStatus prints one line per file with where it comes from.
func renderAquaStatus(result map[string]any) {
	files := mapsOf(result["files"])
	if len(files) == 0 {
		fmt.Println("No files.")
		return
	}
	rows := make([]map[string]string, 0, len(files))
	for _, f := range files {
		rows = append(rows, map[string]string{
			"PATH":  str(f["path"]),
			"STATE": aquaStateLabel(str(f["state"])),
		})
	}
	output.Table([]string{"PATH", "STATE"}, rows)
}

// renderAquaReset prints what a reset reverted and what it kept. With
// --all the server folds the roles and scrolls it deleted into the same
// "reverted" list, so the heading says so.
func renderAquaReset(result map[string]any, all bool) {
	reverted := stringsOf(result["reverted"])
	kept := stringsOf(result["kept"])

	switch {
	case len(reverted) == 0 && all:
		fmt.Println("Nothing to revert or delete — exactly the shipped set is here, as shipped.")
	case len(reverted) == 0:
		fmt.Println("Nothing to revert — every shipped file is as shipped.")
	case all:
		fmt.Println("Reverted or deleted:")
	default:
		fmt.Println("Reverted to shipped:")
	}
	for _, p := range reverted {
		fmt.Println("  " + p)
	}
	if len(kept) > 0 {
		fmt.Println("Kept (yours — `cyfr aqua reset --all` deletes them too):")
		for _, p := range kept {
			fmt.Println("  " + p)
		}
	}
}

// renderScrollList prints the scroll index: name and the one line each
// scroll shows.
func renderScrollList(result map[string]any) {
	scrolls := mapsOf(result["skills"])
	if len(scrolls) == 0 {
		fmt.Println("No scrolls yet — AQUA learns one at aqua/skills/<name>/SKILL.md.")
		return
	}
	rows := make([]map[string]string, 0, len(scrolls))
	for _, s := range scrolls {
		rows = append(rows, map[string]string{
			"NAME":        str(s["name"]),
			"DESCRIPTION": str(s["description"]),
		})
	}
	output.Table([]string{"NAME", "DESCRIPTION"}, rows)
}

// renderScroll prints one scroll: its name and description, the files
// that ride beside its SKILL.md when there are any, then the body.
func renderScroll(result map[string]any) {
	name := str(result["name"])
	if description := str(result["description"]); description != "" {
		fmt.Printf("%s — %s\n", name, description)
	} else {
		fmt.Println(name)
	}
	if resources := stringsOf(result["resources"]); len(resources) > 0 {
		fmt.Printf("Resources: %s\n", strings.Join(resources, ", "))
	}
	fmt.Println()
	fmt.Println(str(result["content"]))
}

// mapsOf reads a wire array of objects, skipping anything that is not one.
func mapsOf(value any) []map[string]any {
	items, _ := value.([]any)
	out := make([]map[string]any, 0, len(items))
	for _, item := range items {
		if m, ok := item.(map[string]any); ok {
			out = append(out, m)
		}
	}
	return out
}

// stringsOf reads a wire array of strings, skipping anything that is not one.
func stringsOf(value any) []string {
	items, _ := value.([]any)
	out := make([]string, 0, len(items))
	for _, item := range items {
		if s, ok := item.(string); ok {
			out = append(out, s)
		}
	}
	return out
}
