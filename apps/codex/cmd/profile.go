// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"encoding/json"
	"fmt"
	"io"
	"math"
	"os"
	"strings"

	"github.com/cyfr/codex/internal/ops"
	"github.com/cyfr/codex/internal/output"
	"github.com/cyfr/codex/internal/prompt"
	"github.com/spf13/cobra"
)

func init() {
	profileGrantCmd.Flags().StringSlice("entry", nil,
		"Bind a need to a vault entry non-interactively: need=entry_id (repeatable)")
	profileGrantCmd.Flags().StringSlice("origin", nil,
		"An origin the grant admits: interactive, programmatic, schedule or webhook "+
			"(repeatable). Absent, a re-grant keeps the grant's origins and a first "+
			"grant admits interactive alone")

	profileCmd.AddCommand(profileGrantCmd)
	profileCmd.AddCommand(profileListCmd)
	profileCmd.AddCommand(profileRevokeCmd)
	rootCmd.AddCommand(profileCmd)
}

var profileCmd = &cobra.Command{
	Use:     "profile",
	Short:   "Grant, inspect and revoke app profiles",
	GroupID: "security",
	Long: "A profile is a component you granted: which vault entries it may use, " +
		"what it may reach, recorded as an immutable consent revision.\n\n" +
		"Nothing is granted outside this walk — plan shows what would be " +
		"granted, preview renders exactly what you are approving, and commit " +
		"records it.",
}

var profileListCmd = &cobra.Command{
	Use:   "list <reference>",
	Short: "List a component's profiles",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		client := newClient()

		result, err := client.CallTool(cmd.Context(), ops.Profile, ops.ProfileListArgs{Ref: args[0]})
		if err != nil {
			return handleToolError(err)
		}

		if flagJSON {
			output.JSON(result)
			return nil
		}

		profiles, _ := result["profiles"].([]any)
		if len(profiles) == 0 {
			fmt.Println("No profiles — this component has never been granted.")
			return nil
		}

		for _, entry := range profiles {
			p, ok := entry.(map[string]any)
			if !ok {
				continue
			}

			rev := "none"
			if r, ok := p["head_revision"].(float64); ok {
				rev = fmt.Sprintf("%.0f", r)
			}

			fmt.Printf("%-38s %-8s %-12s consent rev %s\n",
				str(p["id"]), str(p["kind"]), str(p["status"]), rev)
		}
		return nil
	},
}

var profileRevokeCmd = &cobra.Command{
	Use:   "revoke <profile-id>",
	Short: "Revoke a profile",
	Long:  "Revocation takes effect on the next run. Executions already running complete.",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		client := newClient()

		result, err := client.CallTool(cmd.Context(), ops.Profile, ops.ProfileRevokeArgs{ProfileId: args[0]})
		if err != nil {
			return handleToolError(err)
		}

		if flagJSON {
			output.JSON(result)
			return nil
		}

		output.Success(fmt.Sprintf("Revoked %s. Takes effect on the next run.", args[0]))
		return nil
	},
}

var profileGrantCmd = &cobra.Command{
	Use:   "grant <reference>",
	Short: "Grant a component the vault entries it needs [interactive]",
	Long: "Walks plan → preview → commit. You see what would be granted, pick " +
		"a vault entry for each need, then approve exactly what was rendered.\n\n" +
		"The grant admits the runs --origin names. With no --origin, a first grant " +
		"admits interactive alone and a re-grant keeps the origins the grant " +
		"already admits, so an agent, a script, a schedule or a webhook runs the " +
		"component only under a grant that names its origin.",
	Example: `  cyfr profile grant c:moonmoon69.gmail
  cyfr profile grant f:local.daily-report --entry @ingress=vlt_abc123
  cyfr profile grant f:local.daily-report --origin interactive --origin schedule`,
	Args: cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		client := newClient()
		ref := args[0]

		plan, err := client.CallTool(cmd.Context(), ops.Profile, ops.ProfilePlanArgs{Ref: ref})
		if err != nil {
			return handleToolError(err)
		}

		// A closure that does not resolve has nothing to preview or commit:
		// say what is missing instead of drawing the source alone as the ask.
		if missing, unresolved := unresolvedPlan(plan); unresolved {
			return fmt.Errorf("%s cannot be granted yet: %s", ref, missing)
		}

		named, _ := cmd.Flags().GetStringSlice("origin")
		admitted, kept := grantOrigins(named, plan)
		if kept && !flagJSON {
			fmt.Printf("Keeping the origins this grant admits: %s (name --origin to change them)\n",
				strings.Join(admitted, ", "))
		}

		bindings, err := collectBindings(cmd, plan)
		if err != nil {
			if prompt.IsAborted(err) {
				return prompt.ErrAborted
			}
			return err
		}

		decisions := ops.ProfilePreviewArgsDecisions{
			Ref: ops.Value(ref), Bindings: ops.Value(bindings), Origins: ops.Value(admitted)}

		preview, err := client.CallTool(cmd.Context(), ops.Profile, ops.ProfilePreviewArgs{Decisions: decisions})
		if err != nil {
			return handleToolError(err)
		}

		if !flagJSON {
			renderPreview(os.Stdout, preview)
		}

		if !flagJSON && prompt.IsInteractive(flagNoInteractive) {
			ok, cerr := prompt.Confirm("Grant these permissions?")
			if cerr != nil || !ok {
				fmt.Println("Not granted.")
				return nil
			}
		}

		commitBindings := make([]ops.ProfileCommitArgsDecisionsBindingsItem, len(bindings))
		for i, binding := range bindings {
			commitBindings[i] = ops.ProfileCommitArgsDecisionsBindingsItem{
				Need: binding.Need, EntryId: binding.EntryId, InstanceEntryId: binding.InstanceEntryId,
				Name: binding.Name, Renew: binding.Renew, Fields: binding.Fields, Scopes: binding.Scopes}
			// The two operations' lifetime records are distinct types of one
			// wire shape; a supplied lifetime crosses as its JSON.
			if !binding.Lifetime.IsZero() {
				lifetime, err := json.Marshal(binding.Lifetime)
				if err == nil {
					err = json.Unmarshal(lifetime, &commitBindings[i].Lifetime)
				}
				if err != nil {
					return fmt.Errorf("invalid binding lifetime: %w", err)
				}
			}
		}
		planToken, tokenOK := plan["plan_token"].(string)
		proof, proofOK := preview["proof"].(string)
		digest, digestOK := preview["commit_digest"].(string)
		rawRevision, revisionOK := plan["expected_consent_revision"]
		if !tokenOK || !proofOK || !digestOK || !revisionOK {
			return fmt.Errorf("server returned an incomplete consent preview")
		}
		revisionJSON, err := json.Marshal(rawRevision)
		if err != nil {
			return fmt.Errorf("invalid consent revision: %w", err)
		}
		var revision *int
		if err := json.Unmarshal(revisionJSON, &revision); err != nil {
			return fmt.Errorf("invalid consent revision: %w", err)
		}
		result, err := client.CallTool(cmd.Context(), ops.Profile, ops.ProfileCommitArgs{
			Decisions: ops.ProfileCommitArgsDecisions{
				Ref: ops.Value(ref), Bindings: ops.Value(commitBindings), Origins: ops.Value(admitted)},
			PlanToken: planToken, Proof: proof, CommitDigest: digest, ExpectedConsentRevision: revision})
		if err != nil {
			return handleToolError(err)
		}

		if flagJSON {
			output.JSON(result)
			return nil
		}

		output.Success(fmt.Sprintf("Granted. Consent rev %s.", str(result["revision"])))
		return nil
	},
}

// One vault entry per need: from --entry need=entry_id flags, or asked for
// interactively. A need left unbound
// is a deliberate choice — an app can be granted with no credentials at all.
func collectBindings(cmd *cobra.Command, plan map[string]any) ([]ops.ProfilePreviewArgsDecisionsBindingsItem, error) {
	preset := map[string]string{}

	flags, _ := cmd.Flags().GetStringSlice("entry")
	for _, pair := range flags {
		parts := strings.SplitN(pair, "=", 2)
		if len(parts) != 2 {
			return nil, fmt.Errorf("--entry expects need=entry_id, got %q", pair)
		}
		preset[parts[0]] = parts[1]
	}

	needs, _ := plan["needs"].([]any)
	candidates, _ := plan["candidates"].([]any)
	bindings := []ops.ProfilePreviewArgsDecisionsBindingsItem{}

	for _, entry := range needs {
		need, ok := entry.(map[string]any)
		if !ok {
			continue
		}

		name := str(need["need"])

		if entryID, given := preset[name]; given {
			bindings = append(bindings, ops.ProfilePreviewArgsDecisionsBindingsItem{Need: ops.Value(name), EntryId: ops.Value(entryID)})
			continue
		}

		if flagJSON || !prompt.IsInteractive(flagNoInteractive) {
			continue
		}

		entryID, err := askForEntry(need, candidates)
		if err != nil {
			return nil, err
		}
		if entryID != "" {
			bindings = append(bindings, ops.ProfilePreviewArgsDecisionsBindingsItem{Need: ops.Value(name), EntryId: ops.Value(entryID)})
		}
	}

	return bindings, nil
}

func askForEntry(need map[string]any, candidates []any) (string, error) {
	if len(candidates) == 0 {
		fmt.Println("No vault entries yet — create one first, or grant without one.")
		return "", nil
	}

	options := []prompt.Option{{Label: "No entry", Value: ""}}
	for _, entry := range candidates {
		c, ok := entry.(map[string]any)
		if !ok {
			continue
		}

		label := str(c["name"])
		if fields := joinStrings(c["field_names"]); fields != "" {
			label = fmt.Sprintf("%s (gets: %s)", label, fields)
		}

		options = append(options, prompt.Option{Label: label, Value: str(c["id"])})
	}

	title := str(need["reason"])
	if title == "" {
		title = fmt.Sprintf("Vault entry for %s", str(need["need"]))
	}

	return prompt.SelectOne(title, options)
}

// grantOrigins is what a grant admits, and whether it is the head's kept:
// the origins --origin names, each once; with none named, the origins the
// profile's head admits (the plan's head_origins), so a re-grant never
// quietly drops one; and interactive alone on a first grant.
func grantOrigins(named []string, plan map[string]any) ([]string, bool) {
	if len(named) == 0 {
		if head := stringList(plan["head_origins"]); len(head) > 0 {
			return head, true
		}
		return []string{"interactive"}, false
	}
	seen := map[string]bool{}
	origins := make([]string, 0, len(named))
	for _, origin := range named {
		if !seen[origin] {
			seen[origin] = true
			origins = append(origins, origin)
		}
	}
	return origins, false
}

// stringList is a JSON array of strings, nil for anything else.
func stringList(value any) []string {
	items, ok := value.([]any)
	if !ok {
		return nil
	}
	list := make([]string, 0, len(items))
	for _, item := range items {
		s, ok := item.(string)
		if !ok {
			return nil
		}
		list = append(list, s)
	}
	return list
}

// unresolvedPlan says what keeps a plan's closure from resolving: the ref
// it names as missing, or the reason when it names none.
func unresolvedPlan(plan map[string]any) (string, bool) {
	unresolved, ok := plan["unresolved"].(map[string]any)
	if !ok {
		return "", false
	}
	missing := str(unresolved["missing"])
	switch {
	case missing != "" && str(unresolved["reason"]) == "missing_release_digest":
		return missing + " has no release digest; publish it again", true
	case missing != "":
		return missing + " is missing: it is not installed, or its dependencies cannot be read", true
	default:
		return "its dependencies cannot be resolved (" + str(unresolved["reason"]) + ")", true
	}
}

// previewKinds is Prima.ConsentPreview's kinds, in its order
// (tests/fixtures/consent_preview.json holds them).
var previewKinds = []string{
	"credential", "egress", "storage", "tools", "tool_servers",
	"limits", "frame", "streams", "cards", "system_actions",
}

var kindHeadings = map[string]string{
	"credential":     "Vault entries it receives",
	"egress":         "Network",
	"storage":        "Files",
	"tools":          "Tools",
	"tool_servers":   "Tool servers",
	"limits":         "Limits",
	"frame":          "Its frame",
	"streams":        "Streams it listens to",
	"cards":          "Cards it shares with the desktop",
	"system_actions": "System actions it may call",
}

// renderPreview draws a Prima.ConsentPreview's typed rows in the terminal,
// grouped by kind in its own words, every value each row carries shown,
// and the origins the grant admits. A kind it does not know is still
// drawn, with its values as the home sent them: no row is hidden.
func renderPreview(w io.Writer, preview map[string]any) {
	fmt.Fprintln(w, "You are approving:")

	byKind := map[string][]map[string]any{}
	order := append([]string{}, previewKinds...)
	rows, _ := preview["rows"].([]any)
	for _, raw := range rows {
		row, ok := raw.(map[string]any)
		if !ok {
			continue
		}
		kind := str(row["kind"])
		if _, known := kindHeadings[kind]; !known && len(byKind[kind]) == 0 {
			order = append(order, kind)
		}
		byKind[kind] = append(byKind[kind], row)
	}

	if len(rows) == 0 {
		fmt.Fprintln(w, "  Nothing beyond its own limits.")
	}

	for _, kind := range order {
		if len(byKind[kind]) == 0 {
			continue
		}
		heading, ok := kindHeadings[kind]
		if !ok {
			heading = kind
		}
		fmt.Fprintf(w, "\n  %s\n", heading)
		for _, row := range byKind[kind] {
			for i, line := range describeRow(row) {
				indent := "    "
				if i > 0 {
					indent = "      "
				}
				fmt.Fprintf(w, "%s%s\n", indent, line)
			}
		}
	}

	if origins := joinStrings(preview["origins"]); origins != "" {
		fmt.Fprintf(w, "\n  Admits runs started: %s\n", origins)
	}

	fmt.Fprint(w, "\n  Vault entries are sealed at rest; CYFR attaches a credential to a component's requests,\n"+
		"  and a component holds a field's value only where the row says it is disclosed.\n\n")
}

// describeRow is one row in the CLI's words, its first line naming it.
func describeRow(row map[string]any) []string {
	values, _ := row["values"].(map[string]any)
	node := str(row["node"])
	narrowed := ""
	if row["narrowed"] == true {
		narrowed = " (narrowed by you)"
	}

	switch str(row["kind"]) {
	case "credential":
		head := str(values["name"]) + " " + edgeLabel(node, str(values["edge"]))
		if label := str(values["label"]); label != "" {
			head += fmt.Sprintf(", the key bound on its '%s' profile", label)
		}
		if connection := str(values["connection"]); connection != "" {
			head += fmt.Sprintf(", as the account '%s'", connection)
		}
		lines := []string{head, "source: " + sourceLabel(str(values["source"]))}
		if provider := str(values["provider"]); provider != "" {
			lines = append(lines, "provider: "+provider)
		}
		lines = append(lines,
			"goes to: "+destinationLabel(values["destination"]),
			disclosureLabel(values["disclosed"]),
			"lifetime: "+lifetimeLabel(values["lifetime"]),
			"fields: "+listOr(values["fields"], "none"),
			"scopes: "+listOr(values["scopes"], "none"))
		if values["suggested"] == true {
			lines = append(lines, "suggested")
		}
		if values["choice_required"] == true {
			lines = append(lines, "choose which entry to use")
		}
		return append(lines, "binding: "+str(values["binding_key"]))

	case "egress":
		return []string{node + narrowed,
			"talks to: " + listOr(values["domains"], "none"),
			"methods: " + listOr(values["methods"], "none"),
			"schemes: " + listOr(values["schemes"], "none"),
			"PRIVATE NETWORKS: " + listOr(values["private_ips"], "none")}

	case "storage":
		return []string{node + narrowed,
			"paths: " + listOr(values["paths"], "none"),
			"actions: " + listOr(values["actions"], "none")}

	case "tools":
		if joinStrings(values["tools"]) == "*" {
			return []string{node + narrowed, "every tool of the catalog (*)"}
		}
		return []string{node + narrowed, "tools: " + listOr(values["tools"], "none")}

	case "tool_servers":
		return []string{node,
			str(values["name"]) + " " + str(values["digest"]),
			"its tools matching: " + listOr(values["tool_patterns"], "none")}

	case "limits":
		lines := []string{node + narrowed}
		for _, field := range []string{"timeout", "batch_timeout", "max_memory_bytes",
			"max_request_size", "max_response_size", "max_concurrent_tasks"} {
			if value, ok := values[field]; ok {
				lines = append(lines, fmt.Sprintf("%s: %s", field, num(value)))
			}
		}
		if rate, ok := values["rate_limit"].(map[string]any); ok {
			lines = append(lines,
				fmt.Sprintf("rate_limit: %s per %s", num(rate["requests"]), str(rate["window"])))
		}
		return lines

	case "frame":
		placement := str(values["placement"])
		if placement == "" {
			placement = "where the shell places it"
		}
		background := "stops when hidden"
		if values["background"] == true {
			background = "keeps running in the background when hidden"
		}
		return []string{node,
			"may use: " + listOr(values["capabilities"], "no extra capability"),
			"placed: " + placement,
			background}

	case "streams":
		return []string{node, str(values["name"]) + " " + subjectLabel(values["subject"])}

	case "cards":
		if component := str(values["component"]); component != "" {
			args, _ := json.Marshal(values["args"])
			return []string{node, fmt.Sprintf("%s, from %s of %s with %s",
				str(values["name"]), str(values["operation"]), component, args)}
		}
		return []string{node, str(values["name"]) + ", static, from no component"}

	case "system_actions":
		return []string{node, "actions: " + listOr(values["actions"], "none")}

	default:
		raw, _ := json.Marshal(values)
		return []string{fmt.Sprintf("%s %s: %s", str(row["kind"]), node, raw)}
	}
}

// sourceLabel says whose credential a row binds: the athanor's own entry,
// an entry the instance offers, or the publisher's provided configuration.
func sourceLabel(source string) string {
	switch source {
	case "own":
		return "own (an entry of this athanor)"
	case "instance":
		return "instance (an entry this instance offers)"
	case "provided":
		return "provided (the publisher's public configuration)"
	default:
		return source
	}
}

// destinationLabel spells where a credential may go: its scheme, hosts and
// port, and the methods and path prefixes it is limited to, when it is.
func destinationLabel(value any) string {
	destination, _ := value.(map[string]any)
	label := str(destination["scheme"]) + "://" + listOr(destination["hosts"], "no host")
	if port, ok := destination["port"]; ok {
		label += " port " + num(port)
	}
	if methods := joinStrings(destination["methods"]); methods != "" {
		label += ", methods " + methods
	}
	if paths := joinStrings(destination["paths"]); paths != "" {
		label += ", paths " + paths
	}
	return label
}

func disclosureLabel(disclosed any) string {
	if disclosed == true {
		return "disclosed: the component reads the value itself"
	}
	return "attached by CYFR: the component never holds the value"
}

// lifetimeLabel spells how long a binding stands.
func lifetimeLabel(value any) string {
	lifetime, _ := value.(map[string]any)
	switch str(lifetime["kind"]) {
	case "standing":
		return "until revoked"
	case "until":
		return "until " + str(lifetime["until"])
	case "once":
		return "one run"
	default:
		return str(lifetime["kind"])
	}
}

// edgeLabel names the edge a credential rides: its node's own key, or the
// key it lends a dependency on that edge.
func edgeLabel(node, edge string) string {
	if edge == "@ingress" {
		return "for " + node + "'s own calls"
	}
	dep, need, named := strings.Cut(edge, "|")
	if named {
		return fmt.Sprintf("lent by %s to %s for its %s need", node, dep, need)
	}
	return fmt.Sprintf("lent by %s to %s", node, dep)
}

func subjectLabel(subject any) string {
	switch s := str(subject); s {
	case "":
		return "for its own subject"
	case "*":
		return "for any subject"
	default:
		return "for " + s
	}
}

func listOr(value any, none string) string {
	if joined := joinStrings(value); joined != "" {
		return joined
	}
	return none
}

// num spells a JSON number as written: a whole number never in exponent form.
func num(value any) string {
	if f, ok := value.(float64); ok && f == math.Trunc(f) && math.Abs(f) < 1e15 {
		return fmt.Sprintf("%.0f", f)
	}
	return str(value)
}

func str(value any) string {
	if value == nil {
		return ""
	}
	return fmt.Sprintf("%v", value)
}

func joinStrings(value any) string {
	list, ok := value.([]any)
	if !ok {
		return ""
	}

	parts := make([]string, 0, len(list))
	for _, item := range list {
		parts = append(parts, str(item))
	}

	return strings.Join(parts, ", ")
}
