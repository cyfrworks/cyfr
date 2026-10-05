// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/cyfr/codex/internal/mcp"
	"github.com/cyfr/codex/internal/ops"
	"github.com/cyfr/codex/internal/output"
	"github.com/cyfr/codex/internal/prompt"
	"github.com/spf13/cobra"
)

func init() {
	profileGrantCmd.Flags().StringSlice("entry", nil,
		"Bind a need of the app: need[|account]=id[:lifetime] (repeatable). An id beginning "+
			"ine_ is an instance entry, any other an entry of the athanor; |account names an "+
			"account beside the need's default; the lifetime is standing (the default), 5m, 1h, "+
			"session or once")
	profileGrantCmd.Flags().StringSlice("selection", nil,
		"Fill a dependency's credential: dep[|account]=id[:lifetime] (repeatable). An id "+
			"beginning vlt_ or ine_ names an entry, anything else the label of the dependency's "+
			"profile that lends its key; |account names an account beside the edge's default, "+
			"which names an entry; the lifetime is as --entry's")
	profileGrantCmd.Flags().Bool("get-head-only", false,
		"Narrow each catalyst whose network ask names other methods to its GET and HEAD")
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
	Long: "Walks plan → preview → commit. You see each credential the app and its " +
		"dependencies need and what can meet it, then approve exactly what was rendered.\n\n" +
		"A required need the plan suggests an entry for is bound to it unless --entry " +
		"(or --selection, for a dependency) names another; an optional need is bound only " +
		"when named. Where several entries can meet a required need and none is suggested, " +
		"an interactive grant asks and a non-interactive one is refused until the need is " +
		"named. A binding stands until revoked unless its flag names 5m, 1h, " +
		sessionLifetimeHelp + " or once (one run). A flag naming need|account or " +
		"dep|account binds a named account beside that edge's default, an entry, and names " +
		"that account's slot alone. A re-grant keeps each binding the grant holds, its entry " +
		"and its lifetime, unless a flag names its slot; one whose time has passed is asked " +
		"for again, and refused without a terminal until a flag names it.\n\n" +
		"The grant admits the runs --origin names. With no --origin, a first grant " +
		"admits interactive alone and a re-grant keeps the origins the grant " +
		"already admits, so an agent, a script, a schedule or a webhook runs the " +
		"component only under a grant that names its origin.",
	Example: `  cyfr profile grant c:moonmoon69.gmail
  cyfr profile grant f:local.daily-report --entry @ingress=vlt_abc123
  cyfr profile grant c:local.model --entry api_key=ine_abc123:1h
  cyfr profile grant f:local.report --selection reagent:local.db=vlt_def456:once
  cyfr profile grant f:local.report --selection 'reagent:local.db|Supabase 2=vlt_def789'
  cyfr profile grant f:local.daily-report --origin interactive --origin schedule`,
	Args: cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		client := newClient()
		ref := args[0]

		entries, _ := cmd.Flags().GetStringSlice("entry")
		selections, _ := cmd.Flags().GetStringSlice("selection")
		getHeadOnly, _ := cmd.Flags().GetBool("get-head-only")

		// A flag the walk could never send is refused before anything is
		// asked of the home.
		if err := checkSlotFlags(entries, selections); err != nil {
			return err
		}

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

		if !flagJSON {
			renderPlanNeeds(os.Stdout, plan)
		}

		// The session's end is read once, and only when a binding asks to
		// live as long as the session.
		var session *sessionEnd
		endOfSession := func() (time.Time, bool, error) {
			if session == nil {
				end, ok, err := whoamiSessionEnd(cmd.Context(), client)
				if err != nil {
					return time.Time{}, false, err
				}
				session = &sessionEnd{at: end, ok: ok}
			}
			return session.at, session.ok, nil
		}

		note := func(string) {}
		if !flagJSON {
			note = func(line string) { fmt.Println(line) }
		}

		decided, err := collectDecisions(plan,
			grantFlags{entries: entries, selections: selections, getHeadOnly: getHeadOnly},
			grantChooser{
				interactive: !flagJSON && prompt.IsInteractive(flagNoInteractive),
				ask:         askForChoice,
				now:         time.Now(),
				sessionEnd:  endOfSession,
				note:        note,
			})
		if err != nil {
			if prompt.IsAborted(err) {
				return prompt.ErrAborted
			}
			return err
		}

		decisions := ops.ProfilePreviewArgsDecisions{
			Ref: ops.Value(ref), Bindings: ops.Value(decided.bindings), Origins: ops.Value(admitted)}
		if len(decided.selections) > 0 {
			decisions.Selections = ops.Value(decided.selections)
		}
		if len(decided.subset) > 0 {
			decisions.Subset = ops.Value(decided.subset)
		}

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

		// The commit carries exactly the decisions previewed: the two
		// operations' decision records are distinct types of one wire shape,
		// so they cross as their JSON, each until-lifetime as it was computed.
		commitDecisions, err := commitDecisionsOf(decisions)
		if err != nil {
			return err
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
			Decisions: commitDecisions, PlanToken: planToken, Proof: proof, CommitDigest: digest,
			ExpectedConsentRevision: revision})
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

// commitDecisionsOf is the preview's decisions as the commit takes them.
func commitDecisionsOf(decisions ops.ProfilePreviewArgsDecisions) (ops.ProfileCommitArgsDecisions, error) {
	var commit ops.ProfileCommitArgsDecisions
	raw, err := json.Marshal(decisions)
	if err == nil {
		err = json.Unmarshal(raw, &commit)
	}
	if err != nil {
		return commit, fmt.Errorf("invalid grant decisions: %w", err)
	}
	return commit, nil
}

// ---------------------------------------------------------------------------
// The decisions a grant makes
// ---------------------------------------------------------------------------

// lifetimeChoices are the five a binding may live by, in the order they
// are offered: until revoked, five minutes, one hour, until the time the
// session is now due to end (at most 24 hours on), and one run.
var lifetimeChoices = []string{"standing", "5m", "1h", "session", "once"}

// sessionHorizon is the furthest an until-lifetime may reach: the home
// refuses one more than 24 hours after its commit.
const sessionHorizon = 24 * time.Hour

type sessionEnd struct {
	at time.Time
	ok bool
}

// grantFlags are the choices the command line names.
type grantFlags struct {
	entries     []string
	selections  []string
	getHeadOnly bool
}

// grantChooser is how the walk decides what no flag names: whether it may
// ask, how it asks, the clock an until-lifetime is computed from, the
// session's end, and where it says what it narrowed or left unbound.
type grantChooser struct {
	interactive bool
	ask         func(title string, options []prompt.Option) (string, error)
	now         time.Time
	sessionEnd  func() (time.Time, bool, error)
	note        func(string)
}

// grantDecisions are the bindings, selections and narrowing a grant sends,
// to its preview and, the same, to its commit.
type grantDecisions struct {
	bindings   []ops.ProfilePreviewArgsDecisionsBindingsItem
	selections []ops.ProfilePreviewArgsDecisionsSelectionsItem
	subset     map[string]ops.ProfilePreviewArgsDecisionsSubsetItem
}

// askForChoice asks the person to pick one option.
var askForChoice = prompt.SelectOne

// whoamiSessionEnd is when the command line's session ends, from its own
// session.whoami: false when its credential is no session (an API key).
func whoamiSessionEnd(ctx context.Context, client *mcp.Client) (time.Time, bool, error) {
	who, err := client.CallTool(ctx, ops.Session, ops.SessionWhoamiArgs{})
	if err != nil {
		return time.Time{}, false, handleToolError(err)
	}
	return sessionEndOf(who)
}

// sessionEndOf reads session.whoami's session_expires_at.
func sessionEndOf(who map[string]any) (time.Time, bool, error) {
	raw, _ := who["session_expires_at"].(string)
	if raw == "" {
		return time.Time{}, false, nil
	}
	end, err := time.Parse(time.RFC3339Nano, raw)
	if err != nil {
		return time.Time{}, false, fmt.Errorf("the home answered an unreadable session end %q", raw)
	}
	return end, true, nil
}

// slotFlag is one --entry or --selection: the need or the dependency it
// names, the account it names beside that edge's default ("" for the
// default itself), the id or label it binds and the lifetime choice.
type slotFlag struct {
	target  string
	account string
	value   string
	choice  string
}

// parseSlotFlag reads target[|account]=value[:lifetime]. The value is what
// follows the last =, so an account name may hold = and :; the account is
// what follows the target's first |, which no account name holds. A named
// account names an entry, never a lender's label.
func parseSlotFlag(flag, pair string) (slotFlag, error) {
	what := "need"
	if flag == "--selection" {
		what = "dep"
	}
	at := strings.LastIndex(pair, "=")
	if at < 0 {
		return slotFlag{}, fmt.Errorf("%s expects %s[|account]=id[:lifetime], got %q", flag, what, pair)
	}
	target, account, named := strings.Cut(pair[:at], "|")
	if target == "" || pair[at+1:] == "" {
		return slotFlag{}, fmt.Errorf("%s expects %s[|account]=id[:lifetime], got %q", flag, what, pair)
	}
	if named && !validAccountName(account) {
		return slotFlag{}, fmt.Errorf("%s %q names the account %q, which is not 1 to 128 bytes of "+
			"text without a | or a control character", flag, pair, account)
	}
	value, choice, err := splitLifetime(flag, pair[at+1:])
	if err != nil {
		return slotFlag{}, err
	}
	if named && flag == "--selection" && selectionChoice(value).label {
		return slotFlag{}, fmt.Errorf("%s %q names the account %s by a profile's label; a named "+
			"account names an entry, an id beginning vlt_ or ine_", flag, pair, account)
	}
	return slotFlag{target: target, account: account, value: value, choice: choice}, nil
}

// checkSlotFlags refuses any --entry or --selection the walk could never
// send, before anything is asked of the home.
func checkSlotFlags(entries, selections []string) error {
	for _, pair := range entries {
		if _, err := parseSlotFlag("--entry", pair); err != nil {
			return err
		}
	}
	for _, pair := range selections {
		if _, err := parseSlotFlag("--selection", pair); err != nil {
			return err
		}
	}
	return nil
}

// validAccountName is the home's account-name rule: 1 to 128 bytes of
// text, no | (which a binding key reserves) and no control character.
func validAccountName(name string) bool {
	if len(name) < 1 || len(name) > 128 || !utf8.ValidString(name) || strings.Contains(name, "|") {
		return false
	}
	for _, r := range name {
		if r < 0x20 || r == 0x7f {
			return false
		}
	}
	return true
}

// slotKey names one slot of an edge: its default ("" account), or an
// account by its key, as the home compares account names.
func slotKey(target, account string) string {
	return target + "\x00" + accountNameKey(account)
}

// accountNameKey is the form two account names share when they name one
// account: the home's rule (Prima.Authority.Blob.account_name_key/1),
// Unicode's full lowercase mapping without context or a language's
// tailoring. Per rune, every code point maps as unicode.ToLower maps it
// but U+0130 (İ), whose full mapping is "i" and a combining dot above;
// tests/fixtures/account_names.json pins the rule on both sides. The tables
// are the toolchain's (unicode.Version), which go.mod pins to the home's
// Unicode version. A CLI built on other tables may still send two
// spellings of one account as two, and the home refuses that grant naming
// both: the home decides which names are one account.
func accountNameKey(name string) string {
	var b strings.Builder
	b.Grow(len(name))
	for _, r := range name {
		if r == '\u0130' {
			b.WriteString("i\u0307")
			continue
		}
		b.WriteRune(unicode.ToLower(r))
	}
	return b.String()
}

// splitLifetime reads value[:lifetime]: the value, and the lifetime it
// names, standing when it names none.
func splitLifetime(flag, value string) (string, string, error) {
	at := strings.LastIndex(value, ":")
	if at < 0 {
		return value, "standing", nil
	}
	id, choice := value[:at], value[at+1:]
	for _, known := range lifetimeChoices {
		if choice == known && id != "" {
			return id, choice, nil
		}
	}
	return "", "", fmt.Errorf("%s %q names the lifetime %q; a lifetime is %s",
		flag, value, choice, strings.Join(lifetimeChoices, ", "))
}

// What "session" binds, in the words the help and the refusal use: until a
// time fixed when the grant is made, at most 24 hours on, named by that
// time and never by what might end a session, since an until is fixed once
// committed.
const (
	sessionLifetimeHelp = "session (until the time your session is now due to end, at most " +
		"24 hours on, fixed when you grant)"
	sessionLifetimeRefusal = "the session lifetime lasts until the time this command line's " +
		"session is now due to end, at most 24 hours on, and this credential is no session " +
		"(an API key), so it has no such time: choose standing, 5m, 1h or once"
)

// lifetimeOf is the lifetime a choice sends, computed once, when the
// command line decides, so the preview and the commit carry the same
// until. "session" is the time the session is now due to end at, at most
// 24 hours on, and is said by that time.
func lifetimeOf(choice string, chooser grantChooser) (string, string, error) {
	until := func(at time.Time) string { return at.UTC().Truncate(time.Second).Format(time.RFC3339) }
	switch choice {
	case "standing", "once":
		return choice, "", nil
	case "5m":
		return "until", until(chooser.now.Add(5 * time.Minute)), nil
	case "1h":
		return "until", until(chooser.now.Add(time.Hour)), nil
	case "session":
		end, ok, err := chooser.sessionEnd()
		if err != nil {
			return "", "", err
		}
		if !ok {
			return "", "", errors.New(sessionLifetimeRefusal)
		}
		if limit := chooser.now.Add(sessionHorizon); end.After(limit) {
			end = limit
		}
		if chooser.note != nil {
			chooser.note("This session: until " + until(end) + ".")
		}
		return "until", until(end), nil
	}
	return "", "", fmt.Errorf("a lifetime is %s, not %q", strings.Join(lifetimeChoices, ", "), choice)
}

// idChoice is what a binding or selection names: an entry of the athanor,
// an instance entry, or (a selection only) a lending profile's label.
type idChoice struct {
	value    string
	instance bool
	label    bool
}

func entryChoice(id string) idChoice {
	return idChoice{value: id, instance: strings.HasPrefix(id, "ine_")}
}

func selectionChoice(value string) idChoice {
	switch {
	case strings.HasPrefix(value, "ine_"):
		return idChoice{value: value, instance: true}
	case strings.HasPrefix(value, "vlt_"):
		return idChoice{value: value}
	default:
		return idChoice{value: value, label: true}
	}
}

func bindingItem(need string, id idChoice, kind, until string) ops.ProfilePreviewArgsDecisionsBindingsItem {
	item := ops.ProfilePreviewArgsDecisionsBindingsItem{Need: ops.Value(need)}
	if id.instance {
		item.InstanceEntryId = ops.Value(id.value)
	} else {
		item.EntryId = ops.Value(id.value)
	}
	lifetime := ops.ProfilePreviewArgsDecisionsBindingsItemLifetime{Kind: kind}
	if until != "" {
		lifetime.Until = ops.Value(until)
	}
	item.Lifetime = ops.Value(lifetime)
	return item
}

func selectionItem(row depRow, need string, id idChoice, kind, until string) ops.ProfilePreviewArgsDecisionsSelectionsItem {
	item := ops.ProfilePreviewArgsDecisionsSelectionsItem{Dep: row.dep}
	if row.from != "" {
		item.From = ops.Value(row.from)
	}
	switch {
	case id.label:
		item.Label = ops.Value(id.value)
	case id.instance:
		item.InstanceEntryId = ops.Value(id.value)
	default:
		item.EntryId = ops.Value(id.value)
	}
	if need != "" && !id.label {
		item.Need = ops.Value(need)
	}
	lifetime := ops.ProfilePreviewArgsDecisionsSelectionsItemLifetime{Kind: kind}
	if until != "" {
		lifetime.Until = ops.Value(until)
	}
	item.Lifetime = ops.Value(lifetime)
	return item
}

// needRow is one credential need of the plan, the app's or a dependency's.
type needRow struct {
	name           string
	kind           string
	provider       string
	reason         string
	required       bool
	source         string
	choiceRequired bool
	suggested      *idChoice
	candidates     []map[string]any
	newerShipped   string
	destination    any
}

// declared is a need the manifest declares as a credential, unlike the
// undeclared slot of a manifest that declares no needs.
func (n needRow) declared() bool {
	switch n.kind {
	case "api_key", "oauth", "bundle":
		return true
	}
	return false
}

func readNeed(raw any) (needRow, bool) {
	m, ok := raw.(map[string]any)
	if !ok {
		return needRow{}, false
	}
	row := needRow{
		name:           str(m["need"]),
		kind:           str(m["kind"]),
		provider:       str(m["provider"]),
		reason:         str(m["reason"]),
		required:       m["required"] == true,
		source:         str(m["source"]),
		choiceRequired: m["choice_required"] == true,
		newerShipped:   str(m["newer_shipped"]),
		destination:    m["destination"],
	}
	if suggested, ok := m["suggested"].(map[string]any); ok {
		if id := str(suggested["entry_id"]); id != "" {
			row.suggested = &idChoice{value: id}
		} else if id := str(suggested["instance_entry_id"]); id != "" {
			row.suggested = &idChoice{value: id, instance: true}
		}
	}
	for _, c := range asList(m["candidates"]) {
		if candidate, ok := c.(map[string]any); ok {
			row.candidates = append(row.candidates, candidate)
		}
	}
	return row, true
}

// depRow is one dependency edge of the plan whose dependency declares a
// credential need: who calls it, its needs and the profiles that lend.
type depRow struct {
	from    string
	dep     string
	needs   []needRow
	lenders []map[string]any
}

func readDeps(plan map[string]any) []depRow {
	var rows []depRow
	for _, raw := range asList(plan["dependency_needs"]) {
		m, ok := raw.(map[string]any)
		if !ok {
			continue
		}
		row := depRow{from: str(m["from"]), dep: str(m["dep"])}
		for _, n := range asList(m["needs"]) {
			if need, ok := readNeed(n); ok {
				row.needs = append(row.needs, need)
			}
		}
		for _, l := range asList(m["candidates"]) {
			if lender, ok := l.(map[string]any); ok {
				row.lenders = append(row.lenders, lender)
			}
		}
		rows = append(rows, row)
	}
	return rows
}

// provided is whether the calling app's configuration fills the edge,
// which then holds no other credential.
func (d depRow) provided() bool {
	for _, need := range d.needs {
		if need.source == "provided" {
			return true
		}
	}
	return false
}

func asList(value any) []any {
	list, _ := value.([]any)
	return list
}

// headBinding is one binding the profile's head holds (the plan's
// head_bindings): where it sits, what it binds and how long it lives.
type headBinding struct {
	node  string
	edge  string
	name  string
	id    idChoice
	kind  string
	until string
}

// namedNeed is the dependency's need a binding's edge names, if it names
// one (`<dep>|<need>`).
func (h headBinding) namedNeed() string {
	_, need, _ := strings.Cut(h.edge, "|")
	return need
}

func readHeads(plan map[string]any) []headBinding {
	var heads []headBinding
	for _, raw := range asList(plan["head_bindings"]) {
		m, ok := raw.(map[string]any)
		if !ok {
			continue
		}
		node, edge, name, ok := parseBindingKey(str(m["binding_key"]))
		if !ok {
			continue
		}
		head := headBinding{node: node, edge: edge, name: name}
		switch {
		case str(m["entry_id"]) != "":
			head.id = idChoice{value: str(m["entry_id"])}
		case str(m["instance_entry_id"]) != "":
			head.id = idChoice{value: str(m["instance_entry_id"]), instance: true}
		case str(m["label"]) != "":
			head.id = idChoice{value: str(m["label"]), label: true}
		default:
			continue
		}
		lifetime, _ := m["lifetime"].(map[string]any)
		head.kind, head.until = str(lifetime["kind"]), str(lifetime["until"])
		heads = append(heads, head)
	}
	return heads
}

// parseBindingKey reads `<node>|<edge key>|<slot>`: the slot is `default`
// for the unnamed binding or `name:<name>`, and neither a node nor a name
// holds a `|`.
func parseBindingKey(key string) (node, edge, name string, ok bool) {
	first, last := strings.Index(key, "|"), strings.LastIndex(key, "|")
	if first < 0 || last <= first {
		return "", "", "", false
	}
	node, edge = key[:first], key[first+1:last]
	switch slot := key[last+1:]; {
	case slot == "default":
		return node, edge, "", true
	case strings.HasPrefix(slot, "name:") && len(slot) > len("name:"):
		return node, edge, strings.TrimPrefix(slot, "name:"), true
	}
	return "", "", "", false
}

// headOnEdge is the head's binding of a dependency edge's default.
func headOnEdge(heads []headBinding, row depRow) (headBinding, bool) {
	for _, head := range headsOnEdge(heads, row) {
		if head.name == "" {
			return head, true
		}
	}
	return headBinding{}, false
}

// headsOnEdge are the head's bindings of a dependency edge: its default
// and each account named beside it.
func headsOnEdge(heads []headBinding, row depRow) []headBinding {
	var on []headBinding
	for _, head := range heads {
		dep, _, _ := strings.Cut(head.edge, "|")
		if head.node == row.from && dep == row.dep {
			on = append(on, head)
		}
	}
	return on
}

// replacedNote says that a grant for another need replaces the app's
// bindings of need held: its default, when held, and each account by
// name. The app's own calls carry one need's credentials.
func replacedNote(need string, held []headBinding) string {
	var parts []string
	for _, head := range held {
		if head.name == "" {
			parts = append(parts, "its default")
		}
	}
	for _, head := range held {
		if head.name != "" {
			parts = append(parts, fmt.Sprintf("the account '%s'", head.name))
		}
	}
	return fmt.Sprintf("This grant replaces the app's bindings of %s: %s; its own calls carry "+
		"one need's credentials.", need, joinAnd(parts))
}

// joinAnd joins parts as a sentence lists them: "a", "a and b",
// "a, b and c".
func joinAnd(parts []string) string {
	if len(parts) <= 1 {
		return strings.Join(parts, "")
	}
	return strings.Join(parts[:len(parts)-1], ", ") + " and " + parts[len(parts)-1]
}

// headNeed is the need a head binding's entry is for: the one whose
// candidates hold it, or the only need there is; none when it cannot be
// told, or when the binding names a lender, which no need of the app's own
// calls takes.
func headNeed(needs []needRow, id idChoice) string {
	if id.label {
		return ""
	}
	var holding []string
	for _, need := range needs {
		for _, c := range need.candidates {
			if str(c["entry_id"]) == id.value || str(c["instance_entry_id"]) == id.value {
				holding = append(holding, need.name)
				break
			}
		}
	}
	switch {
	case len(holding) == 1:
		return holding[0]
	case len(needs) == 1:
		return needs[0].name
	}
	return ""
}

// edgeNeed is the dependency's need a head binding on its edge is for, and
// whether it can be told: none to name where the dependency declares one
// need or a lender lends; else the need the edge names, or the one need
// whose candidates hold the entry.
func edgeNeed(row depRow, head headBinding) (string, bool) {
	if head.id.label || len(row.needs) <= 1 {
		return "", true
	}
	if named := head.namedNeed(); named != "" {
		for _, need := range row.needs {
			if need.name == named {
				return named, true
			}
		}
		return "", false
	}
	need := headNeed(row.needs, head.id)
	return need, need != ""
}

// headLifetime is the lifetime a head binding reopens with: as it stands,
// an until kept while it is ahead. One whose time has passed is asked for
// again where the grant may ask, and refused otherwise, naming what it
// binds and the flag that names its lifetime.
func headLifetime(head headBinding, chooser grantChooser, what, flag string) (string, string, error) {
	switch head.kind {
	case "standing", "once":
		return head.kind, "", nil
	case "until":
		at, err := time.Parse(time.RFC3339Nano, head.until)
		if err == nil && at.After(chooser.now) {
			return "until", head.until, nil
		}
		if !chooser.interactive {
			return "", "", fmt.Errorf("%s was granted until %s, which has passed: name how long "+
				"it lives with %s", what, head.until, flag)
		}
		options := make([]prompt.Option, 0, len(lifetimeChoices))
		for _, choice := range lifetimeChoices {
			options = append(options, prompt.Option{Label: choice, Value: choice})
		}
		choice, err := chooser.ask(fmt.Sprintf("%s was granted until %s, which has passed: "+
			"how long should it live now?", what, head.until), options)
		if err != nil {
			return "", "", err
		}
		return lifetimeOf(choice, chooser)
	}
	return "", "", fmt.Errorf("%s holds a lifetime this command line cannot read (%q): name "+
		"how long it lives with %s", what, head.kind, flag)
}

// collectDecisions decides each credential the grant binds and the
// narrowing it asks for. What a flag names is sent as named, and a flag
// names its slot alone: an edge's default (a flag naming no account) or
// one named account. A slot no flag names takes what it takes with no
// flags: the profile's head binding there, its entry and lifetime, never
// wider, else the plan's suggestion. An edge the head binds anything on
// takes no suggestion, and a binding whose need cannot be told is left
// unbound and said. A flag naming a need of the app other than the one the
// head binds replaces every binding of the app's own calls, since that
// edge carries one need's credentials. A suggestion is the plan's for the
// need a flag names, or else for the first required declared need that
// has one, since a dependency's edge, too, carries one credential; an
// optional need and the undeclared slot of a manifest declaring no needs
// are bound only when named or chosen. Where a required need has several
// candidates and no suggestion, an interactive grant asks and any other is
// refused, naming the need.
func collectDecisions(plan map[string]any, flags grantFlags, chooser grantChooser) (grantDecisions, error) {
	var decided grantDecisions

	bindings, err := sourceBindings(plan, flags.entries, chooser)
	if err != nil {
		return decided, err
	}
	decided.bindings = bindings

	selections, err := dependencySelections(plan, flags.selections, chooser)
	if err != nil {
		return decided, err
	}
	decided.selections = selections

	if flags.getHeadOnly {
		decided.subset = getHeadOnlySubset(plan, chooser.note)
	}
	return decided, nil
}

func sourceBindings(plan map[string]any, flags []string, chooser grantChooser) ([]ops.ProfilePreviewArgsDecisionsBindingsItem, error) {
	bindings := []ops.ProfilePreviewArgsDecisionsBindingsItem{}

	named := map[string]bool{}
	flagNeeds := map[string]bool{}
	flagNeed := ""
	for _, pair := range flags {
		f, err := parseSlotFlag("--entry", pair)
		if err != nil {
			return nil, err
		}
		kind, until, err := lifetimeOf(f.choice, chooser)
		if err != nil {
			return nil, err
		}
		item := bindingItem(f.target, entryChoice(f.value), kind, until)
		if f.account != "" {
			item.Name = ops.Value(f.account)
		}
		bindings = append(bindings, item)
		named[slotKey(f.target, f.account)] = true
		flagNeeds[f.target] = true
		flagNeed = f.target
	}
	// Flags naming two needs fill one edge twice, which the home refuses:
	// nothing is added beside them.
	if len(flagNeeds) > 1 {
		return bindings, nil
	}

	var needs []needRow
	for _, raw := range asList(plan["needs"]) {
		if need, ok := readNeed(raw); ok {
			needs = append(needs, need)
		}
	}

	// A re-grant reopens on what the head binds on the app's own calls, its
	// entry and lifetime, never wider, in each slot no flag names: no
	// suggestion is added beside it. A flag naming another need than the
	// head's replaces it whole, and says so.
	var held []headBinding
	for _, head := range readHeads(plan) {
		if head.node == str(plan["source_ref"]) && head.edge == "@ingress" {
			held = append(held, head)
		}
	}
	for _, head := range held {
		if need := headNeed(needs, head.id); flagNeed != "" && need != "" && need != flagNeed {
			chooser.note(replacedNote(need, held))
			held = nil
			break
		}
	}
	if len(held) > 0 {
		for _, head := range held {
			need := headNeed(needs, head.id)
			if need == "" {
				chooser.note(fmt.Sprintf("The grant's binding of %s is left unbound: no need of "+
					"the app can be told for it. Name it with --entry <need>=%s to bind it.",
					head.id.value, head.id.value))
				continue
			}
			if named[slotKey(need, head.name)] {
				continue
			}
			what, flag := fmt.Sprintf("need %s", need), fmt.Sprintf("--entry %s=<id>:<lifetime>", need)
			if head.name != "" {
				what = fmt.Sprintf("need %s's account '%s'", need, head.name)
				flag = fmt.Sprintf("--entry '%s|%s=<id>:<lifetime>'", need, head.name)
			}
			kind, until, err := headLifetime(head, chooser, what, flag)
			if err != nil {
				return nil, err
			}
			item := bindingItem(need, head.id, kind, until)
			if head.name != "" {
				item.Name = ops.Value(head.name)
			}
			bindings = append(bindings, item)
		}
		return bindings, nil
	}

	// The default of the need the flags name, unless a flag names it: its
	// suggestion, as with no flags.
	if flagNeed != "" {
		if named[slotKey(flagNeed, "")] {
			return bindings, nil
		}
		for _, need := range needs {
			if need.name != flagNeed {
				continue
			}
			chosen, err := chooseFor(need, nil, chooser,
				fmt.Sprintf("--entry %s=<id>", need.name), fmt.Sprintf("need %s", need.name))
			if err != nil {
				return nil, err
			}
			if chosen != nil {
				bindings = append(bindings, bindingItem(need.name, *chosen, "standing", ""))
			}
		}
		return bindings, nil
	}

	for i, need := range needs {
		chosen, err := chooseFor(need, nil, chooser,
			fmt.Sprintf("--entry %s=<id>", need.name), fmt.Sprintf("need %s", need.name))
		if err != nil {
			return nil, err
		}
		if chosen == nil {
			continue
		}
		bindings = append(bindings, bindingItem(need.name, *chosen, "standing", ""))
		for _, rest := range needs[i+1:] {
			if rest.declared() && rest.required {
				chooser.note(fmt.Sprintf("Need %s is left unbound: the app's own calls carry one "+
					"need's credentials, %s's. Name it with --entry to bind it instead.",
					rest.name, need.name))
			}
		}
		break
	}
	return bindings, nil
}

// chooseFor is the entry a need no flag names is bound to, if any: its
// suggestion when it is a required declared need; the person's choice
// when several can meet it, none is suggested and the grant may ask.
func chooseFor(need needRow, lenders []map[string]any, chooser grantChooser, flag, what string) (*idChoice, error) {
	if need.source == "provided" {
		return nil, nil
	}
	if need.declared() && need.required && need.suggested != nil {
		return need.suggested, nil
	}
	if !need.choiceRequired {
		return nil, nil
	}
	if !chooser.interactive {
		if need.declared() && need.required {
			return nil, fmt.Errorf("%s can be met by several entries and none is suggested: "+
				"name the one to use with %s", what, flag)
		}
		return nil, nil
	}
	return askEntry(need, lenders, chooser)
}

func askEntry(need needRow, lenders []map[string]any, chooser grantChooser) (*idChoice, error) {
	options := []prompt.Option{{Label: "No entry", Value: ""}}
	for _, c := range need.candidates {
		label := str(c["name"]) + ", " + sourceWords(str(c["source"]), "")
		if destination, ok := c["destination"].(map[string]any); ok {
			label += ", sent only to " + destinationLabel(destination)
		}
		if id := str(c["entry_id"]); id != "" {
			options = append(options, prompt.Option{Label: label, Value: "vlt:" + id})
		} else if id := str(c["instance_entry_id"]); id != "" {
			options = append(options, prompt.Option{Label: label, Value: "ine:" + id})
		}
	}
	for _, l := range lenders {
		options = append(options, prompt.Option{
			Label: fmt.Sprintf("%s, through the dependency's '%s' profile", str(l["entry_name"]), str(l["label"])),
			Value: "label:" + str(l["label"])})
	}

	title := need.reason
	if title == "" {
		title = fmt.Sprintf("Vault entry for %s", need.name)
	}
	value, err := chooser.ask(title, options)
	if err != nil {
		return nil, err
	}
	kind, id, _ := strings.Cut(value, ":")
	switch kind {
	case "vlt":
		return &idChoice{value: id}, nil
	case "ine":
		return &idChoice{value: id, instance: true}, nil
	case "label":
		return &idChoice{value: id, label: true}, nil
	}
	return nil, nil
}

func dependencySelections(plan map[string]any, flags []string, chooser grantChooser) ([]ops.ProfilePreviewArgsDecisionsSelectionsItem, error) {
	rows := readDeps(plan)
	selections := []ops.ProfilePreviewArgsDecisionsSelectionsItem{}
	named := map[string]bool{}

	for _, pair := range flags {
		f, err := parseSlotFlag("--selection", pair)
		if err != nil {
			return nil, err
		}
		kind, until, err := lifetimeOf(f.choice, chooser)
		if err != nil {
			return nil, err
		}
		id := selectionChoice(f.value)
		named[slotKey(f.target, f.account)] = true

		// Every node of the closure that calls the dependency takes it.
		matched := false
		for _, row := range rows {
			if row.dep != f.target {
				continue
			}
			matched = true
			need, err := selectedNeed(row, id)
			if err != nil {
				return nil, err
			}
			selections = append(selections, accountItem(selectionItem(row, need, id, kind, until), f.account))
		}
		if !matched {
			selections = append(selections,
				accountItem(selectionItem(depRow{dep: f.target}, "", id, kind, until), f.account))
		}
	}

	heads := readHeads(plan)
	for _, row := range rows {
		if row.provided() {
			continue
		}

		if !named[slotKey(row.dep, "")] {
			chosen, err := edgeDefault(row, heads, chooser)
			if err != nil {
				return nil, err
			}
			selections = append(selections, chosen...)
		}

		// Each account the head names on the edge, in the slot no flag
		// names, reopens on what the head binds, never wider.
		for _, head := range headsOnEdge(heads, row) {
			if head.name == "" || named[slotKey(row.dep, head.name)] {
				continue
			}
			need, told := edgeNeed(row, head)
			if !told {
				chooser.note(fmt.Sprintf("The grant's account '%s' of %s is left unbound: no need "+
					"of %s can be told for it. Name it with --selection '%s|%s=%s' to bind it.",
					head.name, row.dep, row.dep, row.dep, head.name, head.id.value))
				continue
			}
			kind, until, err := headLifetime(head, chooser,
				fmt.Sprintf("%s's account '%s'", row.dep, head.name),
				fmt.Sprintf("--selection '%s|%s=<id>:<lifetime>'", row.dep, head.name))
			if err != nil {
				return nil, err
			}
			selections = append(selections, accountItem(selectionItem(row, need, head.id, kind, until), head.name))
		}
	}
	return selections, nil
}

// accountItem is a selection riding under the account name it names, if
// any, beside its edge's default.
func accountItem(item ops.ProfilePreviewArgsDecisionsSelectionsItem, account string) ops.ProfilePreviewArgsDecisionsSelectionsItem {
	if account != "" {
		item.Name = ops.Value(account)
	}
	return item
}

// edgeDefault is the default of a dependency's edge no flag names: what the
// head binds there, never wider, with no suggestion in the place of a
// binding left unbound; else the plan's suggestion for its first required
// need that has one, since the edge carries one credential.
func edgeDefault(row depRow, heads []headBinding, chooser grantChooser) ([]ops.ProfilePreviewArgsDecisionsSelectionsItem, error) {
	if head, ok := headOnEdge(heads, row); ok {
		need, told := edgeNeed(row, head)
		if !told {
			chooser.note(fmt.Sprintf("The grant's binding of %s for %s is left unbound: no "+
				"need of %s can be told for it. Name it with --selection %s=%s to bind it.",
				head.id.value, row.dep, row.dep, row.dep, head.id.value))
			return nil, nil
		}
		what := fmt.Sprintf("%s's credential", row.dep)
		if need != "" {
			what = fmt.Sprintf("%s's need %s", row.dep, need)
		}
		kind, until, err := headLifetime(head, chooser, what,
			fmt.Sprintf("--selection %s=<id>:<lifetime>", row.dep))
		if err != nil {
			return nil, err
		}
		return []ops.ProfilePreviewArgsDecisionsSelectionsItem{selectionItem(row, need, head.id, kind, until)}, nil
	}

	for i, need := range row.needs {
		chosen, err := chooseFor(need, row.lenders, chooser,
			fmt.Sprintf("--selection %s=<id>", row.dep), fmt.Sprintf("%s's need %s", row.dep, need.name))
		if err != nil {
			return nil, err
		}
		if chosen == nil {
			continue
		}
		name := ""
		if len(row.needs) > 1 {
			name = need.name
		}
		for _, rest := range row.needs[i+1:] {
			if rest.required {
				chooser.note(fmt.Sprintf("%s's need %s is left unbound: its edge carries one "+
					"credential, %s's. Name it with --selection to fill it instead.",
					row.dep, rest.name, need.name))
			}
		}
		return []ops.ProfilePreviewArgsDecisionsSelectionsItem{selectionItem(row, name, *chosen, "standing", "")}, nil
	}
	return nil, nil
}

// selectedNeed is the need of the dependency an entry selection is for:
// none to name when the dependency declares one credential need or a
// label lends; otherwise the one need whose candidates hold the entry.
func selectedNeed(row depRow, id idChoice) (string, error) {
	if id.label || len(row.needs) <= 1 {
		return "", nil
	}
	var holding, names []string
	for _, need := range row.needs {
		names = append(names, need.name)
		for _, c := range need.candidates {
			if str(c["entry_id"]) == id.value || str(c["instance_entry_id"]) == id.value {
				holding = append(holding, need.name)
				break
			}
		}
	}
	if len(holding) == 1 {
		return holding[0], nil
	}
	which := "none of them"
	if len(holding) > 1 {
		which = "several of them (" + strings.Join(holding, ", ") + ")"
	}
	return "", fmt.Errorf("%s declares the credential needs %s, and %s can meet %s: the "+
		"command line cannot tell which need it is for", row.dep, strings.Join(names, ", "),
		id.value, which)
}

// getHeadOnlySubset narrows each catalyst whose network ask names methods
// beside GET and HEAD to the GET and HEAD it asks for, said by those
// methods: a GET can still disclose, so the narrowing claims no more.
func getHeadOnlySubset(plan map[string]any, note func(string)) map[string]ops.ProfilePreviewArgsDecisionsSubsetItem {
	subset := map[string]ops.ProfilePreviewArgsDecisionsSubsetItem{}
	for _, raw := range asList(plan["rows"]) {
		row, ok := raw.(map[string]any)
		if !ok || str(row["kind"]) != "egress" || !strings.HasPrefix(str(row["node"]), "catalyst:") {
			continue
		}
		values, _ := row["values"].(map[string]any)
		asked := stringList(values["methods"])
		kept := getAndHead(asked)
		if len(kept) == 0 || len(kept) == len(asked) {
			continue
		}
		node := str(row["node"])
		subset[node] = ops.ProfilePreviewArgsDecisionsSubsetItem{
			Egress: ops.Value(ops.ProfilePreviewArgsDecisionsSubsetItemEgress{Methods: ops.Value(kept)})}
		note(fmt.Sprintf("%s: %s (it asks for %s)", node, methodsOnlyLabel(kept), strings.Join(asked, ", ")))
	}
	return subset
}

// getAndHead is the GET and HEAD a method ask names, in that order.
func getAndHead(asked []string) []string {
	var kept []string
	for _, method := range []string{"GET", "HEAD"} {
		for _, a := range asked {
			if strings.EqualFold(a, method) {
				kept = append(kept, method)
				break
			}
		}
	}
	return kept
}

// methodsOnlyLabel names a narrowing by the methods it keeps.
func methodsOnlyLabel(methods []string) string {
	return strings.Join(methods, " and ") + " only"
}

// renderPlanNeeds draws each credential need of the app and of its
// dependencies, and what can meet it, before anything is previewed.
func renderPlanNeeds(w io.Writer, plan map[string]any) {
	source := str(plan["source_ref"])
	var lines []string
	declared := false

	for _, raw := range asList(plan["needs"]) {
		need, ok := readNeed(raw)
		if !ok {
			continue
		}
		if need.declared() {
			declared = true
		}
		lines = append(lines, needLines(source, source, need, nil)...)
	}
	for _, row := range readDeps(plan) {
		for _, need := range row.needs {
			declared = true
			lines = append(lines, needLines(row.dep, row.from, need, row.lenders)...)
		}
	}

	fmt.Fprintln(w, "Vault entries:")
	if !declared {
		fmt.Fprintln(w, "  This app asks for no credentials.")
	}
	for _, line := range lines {
		fmt.Fprintln(w, line)
	}
	fmt.Fprintln(w)
}

// needLines is one need as the plan answers it: what it is, and what can
// meet it — the suggestion, the entries to choose from, the profiles that
// lend, or the publisher's configuration.
func needLines(component, from string, need needRow, lenders []map[string]any) []string {
	head := fmt.Sprintf("  %s: %s", component, need.name)
	if need.declared() {
		optional := ""
		if !need.required {
			optional = ", optional"
		}
		head += fmt.Sprintf(" (%s for %s%s)", need.kind, need.provider, optional)
	} else {
		head += " (any entry it reads itself, optional)"
	}
	if need.reason != "" {
		head += " — " + need.reason
	}
	lines := []string{head}

	if need.source == "provided" {
		line := "    " + sourceWords("provided", from)
		if destination, ok := need.destination.(map[string]any); ok {
			line += ", sent only to " + destinationLabel(destination)
		}
		return append(lines, line)
	}

	switch {
	case need.suggested != nil:
		for _, c := range need.candidates {
			if str(c["entry_id"]) == need.suggested.value || str(c["instance_entry_id"]) == need.suggested.value {
				lines = append(lines, "    suggested: "+str(c["name"])+", "+sourceWords(str(c["source"]), ""))
			}
		}
	case need.choiceRequired:
		var names []string
		for _, c := range need.candidates {
			names = append(names, str(c["name"]))
		}
		lines = append(lines, "    choose one of: "+strings.Join(names, ", "))
	case len(need.candidates) == 0 && len(lenders) == 0:
		lines = append(lines, "    no entry can meet it yet: create one first")
	}
	for _, l := range lenders {
		lines = append(lines, fmt.Sprintf("    or %s, through its '%s' profile", str(l["entry_name"]), str(l["label"])))
	}
	if need.newerShipped != "" {
		lines = append(lines, fmt.Sprintf("    it reads the value itself; to update it: cyfr component pull %s:%s",
			component, need.newerShipped))
	}
	return lines
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
// each binding of the head the grant removes, and the origins the grant
// admits. A kind it does not know is still drawn, with its values as the
// home sent them: no row is hidden.
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

	if removed := asList(preview["removed"]); len(removed) > 0 {
		fmt.Fprintln(w, "\n  What this grant removes")
		for _, raw := range removed {
			if item, ok := raw.(map[string]any); ok {
				fmt.Fprintf(w, "    %s\n", removalLine(item))
			}
		}
	}

	if origins := joinStrings(preview["origins"]); origins != "" {
		fmt.Fprintf(w, "\n  Admits runs started: %s\n", origins)
	}

	fmt.Fprint(w, "\n  Vault entries are sealed at rest. A component never holds a vault entry's value\n"+
		"  unless its row says the value is disclosed to it.\n\n")
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
		lines := []string{credentialSentence(node, values),
			"lifetime: " + lifetimeLabel(values["lifetime"]),
			"fields: " + listOr(values["fields"], "none"),
			"scopes: " + listOr(values["scopes"], "none")}
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

// removalLine is one binding of the head the grant removes: the need it
// was bound for (on a dependency's edge, of which dependency and from
// which node), its account or the default, and its entry by name, else by
// its id or the label of the profile that lent it.
func removalLine(item map[string]any) string {
	need := str(item["need"])
	var what string
	if edge := str(item["edge"]); edge == "@ingress" {
		what = need
		if what == "" {
			what = "a binding of this app's calls"
		}
	} else {
		dep, _, _ := strings.Cut(edge, "|")
		if need == "" {
			need = "a binding"
		}
		what = fmt.Sprintf("%s of %s from %s", need, dep, str(item["node"]))
	}

	slot := "default"
	if connection := str(item["connection"]); connection != "" {
		slot = fmt.Sprintf("account '%s'", connection)
	}

	var entry string
	switch {
	case str(item["name"]) != "":
		entry = str(item["name"])
	case str(item["entry_id"]) != "":
		entry = str(item["entry_id"])
	case str(item["instance_entry_id"]) != "":
		entry = str(item["instance_entry_id"])
	default:
		entry = fmt.Sprintf("the key its '%s' profile lent", str(item["via"]))
	}
	return fmt.Sprintf("Removes %s %s: %s", what, slot, entry)
}

// credentialSentence is one binding in one sentence: the app or the
// dependency that uses it, the entry and whose it is, the account it is,
// where it may go and whether the component holds the value.
func credentialSentence(node string, values map[string]any) string {
	name := str(values["name"])
	source := sourceWords(str(values["source"]), node)

	var sentence string
	if edge := str(values["edge"]); edge == "@ingress" {
		sentence = fmt.Sprintf("%s uses %s, %s, for its own calls", node, name, source)
	} else {
		dep, need, _ := strings.Cut(edge, "|")
		sentence = fmt.Sprintf("%s uses %s, %s", dep, name, source)
		if label := str(values["label"]); label != "" {
			sentence = fmt.Sprintf("%s will use %s, %s, through its '%s' profile", dep, name, source, label)
		}
		sentence += ", from " + node
		if need != "" {
			sentence += " for its " + need + " need"
		}
	}
	if connection := str(values["connection"]); connection != "" {
		sentence += fmt.Sprintf(", as the account '%s'", connection)
	}

	sentence += ": "
	if provider := str(values["provider"]); provider != "" {
		sentence += "a " + provider + " account, "
	}
	sentence += "sent only to " + destinationLabel(values["destination"]) + ". " +
		disclosureLabel(values["disclosed"])
	return sentence
}

// sourceWords says whose credential a binding is: the athanor's own entry,
// an entry the instance offers, or the public configuration the
// publisher of node ships.
func sourceWords(source, node string) string {
	switch source {
	case "own":
		return "an entry of this athanor"
	case "instance":
		return "provided by this instance"
	case "provided":
		return "provided by " + publisherOf(node, "its publisher") + ", the app's public configuration"
	default:
		return source
	}
}

// publisherOf is the namespace that publishes the component node names.
func publisherOf(node, otherwise string) string {
	_, rest, ok := strings.Cut(node, ":")
	if !ok {
		return otherwise
	}
	if namespace, _, ok := strings.Cut(rest, "."); ok && namespace != "" {
		return namespace
	}
	return otherwise
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

// disclosureLabel says whether the component holds the value: a value not
// disclosed to it is one CYFR attaches to the requests bound for the
// entry's destination, and the component never holds it.
func disclosureLabel(disclosed any) string {
	if disclosed == true {
		return "The component reads the value itself."
	}
	return "CYFR attaches the value and the component never holds it."
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
