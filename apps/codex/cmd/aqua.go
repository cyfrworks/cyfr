// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"context"
	"fmt"
	"github.com/cyfr/codex/internal/ops"
	"strings"

	"github.com/cyfr/codex/internal/output"
	"github.com/cyfr/codex/internal/prompt"
	"github.com/spf13/cobra"
)

func init() {

	rootCmd.AddCommand(aquaCmd)
	aquaCmd.AddCommand(aquaListCmd)
	aquaCmd.AddCommand(aquaGetCmd)
	aquaCmd.AddCommand(aquaStatusCmd)
	aquaCmd.AddCommand(aquaSkillsCmd)
	aquaSkillsCmd.AddCommand(aquaSkillsListCmd)
	aquaSkillsCmd.AddCommand(aquaSkillsGetCmd)
}

var aquaCmd = &cobra.Command{
	Use:     "aqua",
	Short:   "The athanor's Aqua — its soul, rules, crew and scrolls",
	GroupID: "admin",
	Long: `The athanor has one assistant, Aqua. This command manages what it is made of:

  the soul      aqua.md — who Aqua is (name "aqua"); edited, never created or deleted
  the rules     aqua/rules.md — the athanor's rules, read by Aqua and every crew member
                before each turn; edited in Files, never deleted
  the crew      who Aqua hands jobs to, each on a brain of its own — aqua/crew/<name>.md
  the scrolls   how a job is done, for Aqua and its crew — kept in packs, aqua/scrolls/<pack>/
  the guides    the read-only documentation guides

"list" shows all of it but the rules; "get" reads the soul, a crew member or a guide;
"skills" reads the scrolls; "status" says which files are shipped, edited or yours.
Aqua's page in CYFR restores the shipped set.`,
}

var aquaListCmd = &cobra.Command{
	Use:   "list",
	Short: "List the soul, crew, guides and scrolls",
	Long:  "List the soul, its crew and the guides, then the scrolls Aqua has learned; the rules file is edited in Files and not listed here.",
	Example: `  cyfr aqua list
  cyfr aqua list --json`,
	Args: cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		client := newClient()
		result, err := client.CallTool(cmd.Context(), ops.Aqua, ops.AquaListArgs{})
		if err != nil {
			return handleToolError(err)
		}
		scrolls, err := client.CallTool(cmd.Context(), ops.Aqua, ops.AquaSkillListArgs{})
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
	Short: "Display the soul, a crew member or a guide",
	Long:  "Retrieve and display the soul (name aqua), one of its crew, or a guide by name. Run without arguments for interactive selection. Scrolls are read with `cyfr aqua skills get`.",
	Example: `  cyfr aqua get aqua
  cyfr aqua get component-guide
  cyfr aqua get tincture-guide --json`,
	Args: cobra.RangeArgs(0, 1),
	RunE: func(cmd *cobra.Command, args []string) error {
		name, err := pickTarget(cmd.Context(), args, selector{
			Title: "Select the soul, a crew member or a guide",
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
		result, err := client.CallTool(cmd.Context(), ops.Aqua, ops.AquaGetArgs{Name: name})
		if err != nil {
			return handleToolError(err)
		}
		if flagJSON {
			output.JSON(result)
		} else {
			renderAquaAgent(result)
		}
		return nil
	},
}

var aquaStatusCmd = &cobra.Command{
	Use:   "status",
	Short: "Which files are shipped, edited or yours",
	Long: `Show every file in the athanor's aqua tree and where it comes from:

  bundled   as shipped with the server
  edited    a shipped file the athanor changed
  yours     a crew member the athanor made

Aqua's page in CYFR restores the shipped set.`,
	Example: `  cyfr aqua status
  cyfr aqua status --json`,
	Args: cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		result, err := newClient().CallTool(cmd.Context(), ops.Aqua, ops.AquaStatusArgs{})
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

var aquaSkillsCmd = &cobra.Command{
	Use:   "skills",
	Short: "The scrolls Aqua has learned",
	Long: "Read the scrolls — the procedures the athanor's Aqua keeps in packs, each named by its pack and its name (mine:release-notes). " +
		"Run bare (or with list) for the index, get for one scroll's body.",
	Example: `  cyfr aqua skills
  cyfr aqua skills get mine:release-notes`,
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
	result, err := newClient().CallTool(cmd.Context(), ops.Aqua, ops.AquaSkillListArgs{})
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
	Long:  "Retrieve and display one scroll by its full name, its pack and its name — its description, then its body. Run without arguments for interactive selection.",
	Example: `  cyfr aqua skills get mine:release-notes
  cyfr aqua skills get mine:release-notes --json`,
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

		result, err := newClient().CallTool(cmd.Context(), ops.Aqua, ops.AquaSkillGetArgs{Name: name})
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
// listing goes out, on the wire too: the scrolls ride the soul/crew/guides
// result under their own wire key — or, when that call failed, its error
// does, so the soul, crew and guides still show and the JSON says what
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

// renderAquaList prints the soul, the crew and the guides — the list
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
		{"Crew", "crew"},
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

// renderAquaAgent prints what get answered: the soul's prompt or a
// guide's text, or, for a crew member, which has no prompt, its line and
// what not to hand it.
func renderAquaAgent(result map[string]any) {
	if content, ok := result["content"]; ok {
		fmt.Println(content)
		return
	}
	printAquaRow(len(str(result["name"])), result)
	if avoid := str(result["avoid"]); avoid != "" {
		fmt.Printf("  Avoid: %s\n", avoid)
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

// renderScrollList prints the scroll index: name and the one line each
// scroll shows.
func renderScrollList(result map[string]any) {
	scrolls := mapsOf(result["skills"])
	if len(scrolls) == 0 {
		fmt.Println("No scrolls in the packs switched on — keep packs on the Aqua page's Scrolls.")
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
