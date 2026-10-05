// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
	"unicode"

	"github.com/cyfr/codex/internal/prompt"
)

// previewVectors is the part of tests/fixtures/consent_preview.json the CLI
// renders: the kinds in their order and the preview holding a row of every
// kind, one entry lent on two edges and one stream under two subjects
// among them.
type previewVectors struct {
	Kinds   []string       `json:"kinds"`
	Preview map[string]any `json:"preview"`
}

func loadPreviewVectors(t *testing.T) previewVectors {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "tests", "fixtures", "consent_preview.json"))
	if err != nil {
		t.Fatalf("read vectors: %v", err)
	}
	var v previewVectors
	if err := json.Unmarshal(raw, &v); err != nil {
		t.Fatalf("decode vectors: %v", err)
	}
	return v
}

// The CLI knows every kind the preview names, in the preview's order.
func TestRenderPreview_KnowsEveryKind(t *testing.T) {
	v := loadPreviewVectors(t)
	if !reflect.DeepEqual(v.Kinds, previewKinds) {
		t.Fatalf("the CLI's kinds %v are not the preview's %v", previewKinds, v.Kinds)
	}
	for _, kind := range v.Kinds {
		if kindHeadings[kind] == "" {
			t.Errorf("kind %q has no heading", kind)
		}
	}
}

// Every row of every kind is drawn, each of its values shown: a value is
// shown as the row holds it, or in the CLI's words where it names a
// relation rather than a resource.
func TestRenderPreview_ShowsEveryRowValue(t *testing.T) {
	v := loadPreviewVectors(t)
	var out bytes.Buffer
	renderPreview(&out, v.Preview)
	text := out.String()

	rows, _ := v.Preview["rows"].([]any)
	seen := map[string]bool{}
	for _, raw := range rows {
		row := raw.(map[string]any)
		kind := str(row["kind"])
		seen[kind] = true
		values := row["values"].(map[string]any)

		if !strings.Contains(text, kindHeadings[kind]) {
			t.Errorf("no heading for %s", kind)
		}
		if row["narrowed"] == true && !strings.Contains(text, str(row["node"])+" (narrowed by you)") {
			t.Errorf("the narrowed %s row of %s is not marked", kind, row["node"])
		}

		for field, value := range values {
			for _, want := range expected(row, field, value) {
				if !strings.Contains(text, want) {
					t.Errorf("%s row of %s: %s value %q missing from\n%s", kind, row["node"], field, want, text)
				}
			}
		}
	}

	for _, kind := range v.Kinds {
		if !seen[kind] {
			t.Errorf("the vectors' preview holds no %s row", kind)
		}
	}

	// The admitted origins are the preview's top-level list, not a row.
	for _, origin := range v.Preview["origins"].([]any) {
		if !strings.Contains(text, "Admits runs started:") || !strings.Contains(text, str(origin)) {
			t.Errorf("origin %v missing from\n%s", origin, text)
		}
	}
}

// A credential row is one sentence: the app or the dependency that uses
// it, the entry and whose it is (or the publisher's configuration), the
// account, where it may go and whether the component holds the value;
// then how long it stands. A value the component is not disclosed is one
// CYFR attaches and the component never holds, and its row says so; a
// disclosed one's row never does.
func TestRenderPreview_SaysWhereACredentialGoesAndForHowLong(t *testing.T) {
	v := loadPreviewVectors(t)
	var out bytes.Buffer
	renderPreview(&out, v.Preview)
	text := out.String()

	for _, want := range []string{
		"reagent:local.weather uses weather-api, an entry of this athanor, for its own calls: " +
			"a weather.example account, sent only to https://api.weather.example. " +
			"CYFR attaches the value and the component never holds it.",
		"reagent:local.maps will use maps, an entry of this athanor, through its 'shared-maps' " +
			"profile, from reagent:local.weather for its tiles need: sent only to " +
			"https://tiles.maps.example, methods GET, paths /v1/tiles. The component reads the value itself.",
		"reagent:local.geo uses weather-api, provided by this instance, from reagent:local.weather, " +
			"as the account 'Geo account': a weather.example account, sent only to " +
			"https://*.weather.example port 8443, methods GET, POST, paths /v2. " +
			"CYFR attaches the value and the component never holds it.",
		"reagent:local.maps uses maps public key, provided by local, the app's public configuration, " +
			"from reagent:local.weather for its geocode need: sent only to https://geo.maps.example, " +
			"paths /geocode. The component reads the value itself.",
		"lifetime: until revoked",
		"lifetime: until 2026-10-04T13:00:00Z",
		"lifetime: one run",
		"binding: reagent:local.weather|reagent:local.geo|name:Geo account",
		"suggested",
	} {
		if !strings.Contains(text, want) {
			t.Errorf("missing %q in\n%s", want, text)
		}
	}
	if strings.Contains(text, "choose which entry to use") {
		t.Errorf("no row of the vectors asks for a choice:\n%s", text)
	}
	// The attach claim is each attach-only row's, and no disclosed row's: the
	// vectors hold two of each.
	attached := "CYFR attaches the value and the component never holds it."
	if got := strings.Count(text, attached); got != 2 {
		t.Errorf("%q said %d times, want once per attach-only row (2):\n%s", attached, got, text)
	}
	if got := strings.Count(text, "The component never holds the value."); got != 0 {
		t.Errorf("an attach-only row says the component never holds the value without "+
			"saying CYFR attaches it, %d times:\n%s", got, text)
	}
	lower := strings.ToLower(text)
	for _, claim := range []string{"attached by cyfr", "read only", "read-only"} {
		if strings.Contains(lower, claim) {
			t.Errorf("the rendering says %q:\n%s", claim, text)
		}
	}
}

// Each binding of the head the grant removes is a line of its own, before
// the person is asked to confirm: the need it was bound for (or that it
// cannot be told, and on a dependency's edge, which), its account or the
// default, and its entry by name, else by its id or its lender's label.
func TestRenderPreview_ListsWhatTheGrantRemoves(t *testing.T) {
	v := loadPreviewVectors(t)
	removed := asList(v.Preview["removed"])
	if len(removed) == 0 {
		t.Fatalf("the vectors' preview removes nothing")
	}
	var out bytes.Buffer
	renderPreview(&out, v.Preview)
	text := out.String()

	want := []string{
		"What this grant removes",
		"    Removes api_key default: weather-old\n",
		"    Removes api_key account 'Work': weather-work\n",
		"    Removes a binding of reagent:local.geo from reagent:local.weather account 'Old geo': ine_old_geo\n",
		"    Removes a binding of reagent:local.maps from reagent:local.weather default: " +
			"the key its 'old-maps' profile lent\n",
	}
	for _, line := range want {
		if !strings.Contains(text, line) {
			t.Errorf("missing %q in\n%s", line, text)
		}
	}
	if got := strings.Count(text, "    Removes "); got != len(removed) {
		t.Errorf("%d removal lines, want one per removal (%d):\n%s", got, len(removed), text)
	}
	if strings.Index(text, "What this grant removes") > strings.Index(text, "Admits runs started:") {
		t.Errorf("the removals are not listed with what is approved:\n%s", text)
	}

	// A preview that removes nothing lists nothing.
	empty := map[string]any{}
	for key, value := range v.Preview {
		empty[key] = value
	}
	empty["removed"] = []any{}
	out.Reset()
	renderPreview(&out, empty)
	if strings.Contains(out.String(), "What this grant removes") {
		t.Errorf("a preview removing nothing lists removals:\n%s", out.String())
	}
}

// One entry lent on two edges, and one stream under two subjects, are two
// lines each, never folded into one.
func TestRenderPreview_KeepsRowsApartByEdgeAndSubject(t *testing.T) {
	v := loadPreviewVectors(t)
	var out bytes.Buffer
	renderPreview(&out, v.Preview)
	text := out.String()

	for _, want := range []string{
		"reagent:local.weather uses weather-api, an entry of this athanor, for its own calls",
		"reagent:local.geo uses weather-api, provided by this instance, from reagent:local.weather",
		"reagent:local.maps will use maps, an entry of this athanor, through its 'shared-maps' profile, from reagent:local.weather for its tiles need",
		"executions.deltas for any subject",
		"executions.deltas for exe_1",
		"threads.messages for its own subject",
		"every tool of the catalog (*)",
	} {
		if !strings.Contains(text, want) {
			t.Errorf("missing %q in\n%s", want, text)
		}
	}
}

// Every row names the node it is for, so in a closure of several
// components the person sees which one each row is for: the tool server,
// stream and card rows as much as the rest.
func TestRenderPreview_EveryRowNamesItsNode(t *testing.T) {
	v := loadPreviewVectors(t)
	seen := map[string]bool{}
	for _, raw := range v.Preview["rows"].([]any) {
		row := raw.(map[string]any)
		seen[str(row["kind"])] = true
		if lines := strings.Join(describeRow(row), "\n"); !strings.Contains(lines, str(row["node"])) {
			t.Errorf("a %s row does not name its node %s:\n%s", row["kind"], row["node"], lines)
		}
	}
	for _, kind := range []string{"tool_servers", "streams", "cards"} {
		if !seen[kind] {
			t.Errorf("the vectors hold no %s row", kind)
		}
	}
}

// A kind the CLI does not know is drawn with its values, never hidden.
func TestRenderPreview_DrawsAnUnknownKind(t *testing.T) {
	var out bytes.Buffer
	renderPreview(&out, map[string]any{
		"rows": []any{map[string]any{
			"kind": "badge", "node": "tincture:local.x", "narrowed": false,
			"values": map[string]any{"name": "gold"},
		}},
		"origins": []any{"interactive"},
	})
	if !strings.Contains(out.String(), `badge tincture:local.x: {"name":"gold"}`) {
		t.Errorf("an unknown kind was hidden:\n%s", out.String())
	}
}

// With no --origin a first grant admits interactive alone and a re-grant
// keeps the head's origins; --origin names the origins it admits, each
// once, over both.
func TestGrantOrigins(t *testing.T) {
	first := map[string]any{"head_origins": nil}
	regrant := map[string]any{"head_origins": []any{"interactive", "schedule"}}

	if got, kept := grantOrigins(nil, first); !reflect.DeepEqual(got, []string{"interactive"}) || kept {
		t.Errorf("first grant, no --origin: got %v (kept %v), want interactive alone", got, kept)
	}
	if got, kept := grantOrigins(nil, regrant); !reflect.DeepEqual(got, []string{"interactive", "schedule"}) || !kept {
		t.Errorf("re-grant, no --origin: got %v (kept %v), want the head's", got, kept)
	}

	named := []string{"interactive", "webhook", "webhook", "programmatic"}
	for _, plan := range []map[string]any{first, regrant} {
		got, kept := grantOrigins(named, plan)
		if want := []string{"interactive", "webhook", "programmatic"}; !reflect.DeepEqual(got, want) || kept {
			t.Errorf("--origin over %v: got %v (kept %v), want %v", plan, got, kept, want)
		}
	}

	flag := profileGrantCmd.Flags().Lookup("origin")
	if flag == nil || flag.DefValue != "[]" {
		t.Fatalf("grant has no --origin flag defaulting to none: %+v", flag)
	}
}

// grantAnswers are the home's answers to one grant walk: the plan, with the
// head's origins when there is a head, the preview and the commit.
func grantAnswers(headOrigins string) []string {
	return []string{
		`{"plan_token":"pt","expected_consent_revision":1,"needs":[],"candidates":[],` +
			`"unresolved":null,"head_origins":` + headOrigins + `}`,
		`{"v":1,"rows":[],"origins":["interactive"],"proof":"pf","expected_consent_revision":1,` +
			`"commit_digest":"sha256:0000000000000000000000000000000000000000000000000000000000000000"}`,
		`{"profile_id":"prof_1","revision":2}`,
	}
}

// emptyGrantFlags empties the grant's flags: cobra keeps a flag's values,
// and appends to them, across runs of one process.
func emptyGrantFlags() {
	for _, name := range []string{"origin", "entry", "selection"} {
		flag := profileGrantCmd.Flags().Lookup(name)
		_ = flag.Value.(interface{ Replace([]string) error }).Replace(nil)
		flag.Changed = false
	}
	flag := profileGrantCmd.Flags().Lookup("get-head-only")
	_ = flag.Value.Set("false")
	flag.Changed = false
}

// runGrant runs `cyfr profile grant` against srv with empty grant flags,
// emptied again after.
func runGrant(t *testing.T, srv *cliServer, args ...string) string {
	t.Helper()
	out, err := tryGrant(t, srv, args...)
	if err != nil {
		t.Fatalf("cyfr profile grant failed: %v\n%s", err, out)
	}
	return out
}

// tryGrant is runGrant answering the command's own error.
func tryGrant(t *testing.T, srv *cliServer, args ...string) (string, error) {
	t.Helper()
	onTerminal(t, false)
	emptyGrantFlags()
	t.Cleanup(emptyGrantFlags)

	return runCLI(t, srv, append([]string{"profile", "grant", "f:local.daily-report", "--no-interactive"}, args...)...)
}

// The origins the preview (call 1) and the commit (call 2) were sent.
func sentOrigins(t *testing.T, srv *cliServer) [2][]string {
	t.Helper()
	var sent [2][]string
	for i, call := range []int{1, 2} {
		_, args := srv.call(call)
		decisions, _ := args["decisions"].(map[string]any)
		sent[i] = stringList(decisions["origins"])
	}
	return sent
}

func TestProfileGrant_ReGrantKeepsTheHeadsOrigins(t *testing.T) {
	srv := newCLIServer(t, "profile.commit", grantAnswers(`["interactive","schedule"]`)...)
	out := runGrant(t, srv)

	want := []string{"interactive", "schedule"}
	if sent := sentOrigins(t, srv); !reflect.DeepEqual(sent, [2][]string{want, want}) {
		t.Errorf("a re-grant with no --origin sent %v, want the head's %v to preview and commit", sent, want)
	}
	if !strings.Contains(out, "Keeping the origins this grant admits: interactive, schedule") {
		t.Errorf("the kept origins are not said:\n%s", out)
	}
}

func TestProfileGrant_FirstGrantAdmitsInteractiveAlone(t *testing.T) {
	srv := newCLIServer(t, "profile.commit", grantAnswers(`null`)...)
	out := runGrant(t, srv)

	want := []string{"interactive"}
	if sent := sentOrigins(t, srv); !reflect.DeepEqual(sent, [2][]string{want, want}) {
		t.Errorf("a first grant with no --origin sent %v, want interactive alone", sent)
	}
	if strings.Contains(out, "Keeping") {
		t.Errorf("a first grant keeps no origins:\n%s", out)
	}
}

func TestProfileGrant_OriginOverridesTheHead(t *testing.T) {
	for _, head := range []string{`null`, `["interactive","schedule"]`} {
		srv := newCLIServer(t, "profile.commit", grantAnswers(head)...)
		out := runGrant(t, srv, "--origin", "programmatic", "--origin", "webhook")

		want := []string{"programmatic", "webhook"}
		if sent := sentOrigins(t, srv); !reflect.DeepEqual(sent, [2][]string{want, want}) {
			t.Errorf("head %s: --origin sent %v, want exactly %v", head, sent, want)
		}
		if strings.Contains(out, "Keeping") {
			t.Errorf("head %s: --origin keeps nothing of the head:\n%s", head, out)
		}
	}
}

// ---------------------------------------------------------------------------
// The credentials a grant binds
// ---------------------------------------------------------------------------

// planWith is a plan answer holding the needs and dependency rows given,
// as JSON text the home answers.
func planWith(needs, deps, rows string) string {
	return `{"plan_token":"pt","expected_consent_revision":0,"source_ref":"f:local.daily-report",` +
		`"needs":` + needs + `,"dependency_needs":` + deps + `,"rows":` + rows + `,` +
		`"candidates":[],"unresolved":null,"head_origins":null}`
}

const previewAnswer = `{"v":1,"rows":[],"origins":["interactive"],"proof":"pf",` +
	`"commit_digest":"sha256:0000000000000000000000000000000000000000000000000000000000000000"}`

const commitAnswer = `{"profile_id":"prof_1","revision":1}`

// need is one row of a plan's needs as JSON text.
func need(name, kind string, required bool, suggested string, choiceRequired bool, candidates ...string) string {
	row := map[string]any{
		"need": name, "reason": "to reach " + name, "required": required,
		"choice_required": choiceRequired, "candidates": []any{}, "suggested": nil,
	}
	if kind != "" {
		row["kind"] = kind
		row["provider"] = "openai.com"
		row["type"] = kind + ":openai.com"
	}
	if suggested != "" {
		key := "entry_id"
		if strings.HasPrefix(suggested, "ine_") {
			key = "instance_entry_id"
		}
		row["suggested"] = map[string]any{key: suggested}
	}
	var list []any
	for _, id := range candidates {
		key, source := "entry_id", "own"
		if strings.HasPrefix(id, "ine_") {
			key, source = "instance_entry_id", "instance"
		}
		list = append(list, map[string]any{key: id, "name": "entry " + id, "source": source,
			"destination": map[string]any{"hosts": []any{"api.openai.com"}, "scheme": "https"}})
	}
	if list != nil {
		row["candidates"] = list
	}
	raw, _ := json.Marshal(row)
	return string(raw)
}

func list(items ...string) string { return "[" + strings.Join(items, ",") + "]" }

// sentDecisions are the decisions the preview (call previewAt) and the
// commit after it were sent.
func sentDecisions(t *testing.T, srv *cliServer, previewAt int) (map[string]any, map[string]any) {
	t.Helper()
	_, preview := srv.call(previewAt)
	_, commit := srv.call(previewAt + 1)
	p, _ := preview["decisions"].(map[string]any)
	c, _ := commit["decisions"].(map[string]any)
	return p, c
}

func asMaps(t *testing.T, value any) []map[string]any {
	t.Helper()
	var maps []map[string]any
	for _, item := range asList(value) {
		m, ok := item.(map[string]any)
		if !ok {
			t.Fatalf("not a record: %#v", item)
		}
		maps = append(maps, m)
	}
	return maps
}

func TestLifetimes_FiveChoicesStandingWhenNoneIsNamed(t *testing.T) {
	now := time.Date(2026, 10, 4, 13, 0, 30, 0, time.UTC)
	session := time.Date(2026, 10, 4, 18, 0, 0, 0, time.UTC)
	chooser := grantChooser{now: now, sessionEnd: func() (time.Time, bool, error) { return session, true, nil }}

	for value, want := range map[string][3]string{
		"vlt_1":          {"vlt_1", "standing", ""},
		"vlt_1:standing": {"vlt_1", "standing", ""},
		"vlt_1:once":     {"vlt_1", "once", ""},
		"vlt_1:5m":       {"vlt_1", "until", "2026-10-04T13:05:30Z"},
		"vlt_1:1h":       {"vlt_1", "until", "2026-10-04T14:00:30Z"},
		"vlt_1:session":  {"vlt_1", "until", "2026-10-04T18:00:00Z"},
	} {
		id, choice, err := splitLifetime("--entry", value)
		if err != nil {
			t.Fatalf("%s: %v", value, err)
		}
		kind, until, err := lifetimeOf(choice, chooser)
		if err != nil {
			t.Fatalf("%s: %v", value, err)
		}
		if got := [3]string{id, kind, until}; got != want {
			t.Errorf("%s: got %v, want %v", value, got, want)
		}
	}

	for _, bad := range []string{"vlt_1:forever", "vlt_1:1d", ":once"} {
		if _, _, err := splitLifetime("--entry", bad); err == nil ||
			!strings.Contains(err.Error(), "standing, 5m, 1h, session, once") {
			t.Errorf("%s: want a refusal naming the five lifetimes, got %v", bad, err)
		}
	}
}

// "session" is the earlier of the session's end and 24 hours on; with no
// session behind the command line it is refused, naming the four others.
func TestLifetimes_SessionIsHeldTo24HoursAndNeedsASession(t *testing.T) {
	now := time.Date(2026, 10, 4, 13, 0, 0, 0, time.UTC)
	far := grantChooser{now: now, sessionEnd: func() (time.Time, bool, error) {
		return now.Add(720 * time.Hour), true, nil
	}}
	if kind, until, err := lifetimeOf("session", far); err != nil || kind != "until" ||
		until != "2026-10-05T13:00:00Z" {
		t.Errorf("a session ending in 30 days: got %s %s %v, want until 24 hours on", kind, until, err)
	}

	none := grantChooser{now: now, sessionEnd: func() (time.Time, bool, error) { return time.Time{}, false, nil }}
	_, _, err := lifetimeOf("session", none)
	if err == nil || !strings.Contains(err.Error(), "choose standing, 5m, 1h or once") {
		t.Errorf("no session: got %v", err)
	}

	if end, ok, err := sessionEndOf(map[string]any{"session_expires_at": nil}); ok || err != nil || !end.IsZero() {
		t.Errorf("an API key's whoami read as a session end: %v %v %v", end, ok, err)
	}
	if end, ok, err := sessionEndOf(map[string]any{"session_expires_at": "2026-11-03T13:00:00.123456Z"}); !ok ||
		err != nil || end.Format(time.RFC3339) != "2026-11-03T13:00:00Z" {
		t.Errorf("a session's whoami: %v %v %v", end, ok, err)
	}
}

// --entry names its id, an instance entry by its ine_ prefix, and its
// lifetime; with none named the binding stands. The commit carries the
// decisions the preview was sent, the until computed once.
func TestProfileGrant_EntryFlagsBindWithTheirLifetimes(t *testing.T) {
	plan := planWith(list(need("api_key", "api_key", true, "vlt_suggested", false, "vlt_suggested", "ine_7")), `[]`, `[]`)
	srv := newCLIServer(t, "profile.commit", plan, previewAnswer, commitAnswer)
	runGrant(t, srv, "--entry", "api_key=ine_7:1h", "--entry", "api_key=vlt_named")

	preview, commit := sentDecisions(t, srv, 1)
	if !reflect.DeepEqual(preview["bindings"], commit["bindings"]) {
		t.Errorf("the commit's bindings %v are not the preview's %v", commit["bindings"], preview["bindings"])
	}
	bindings := asMaps(t, preview["bindings"])
	if len(bindings) != 2 {
		t.Fatalf("want the two named bindings, got %v", bindings)
	}

	first, second := bindings[0], bindings[1]
	lifetime, _ := first["lifetime"].(map[string]any)
	until, err := time.Parse(time.RFC3339, str(lifetime["until"]))
	if first["instance_entry_id"] != "ine_7" || first["entry_id"] != nil || lifetime["kind"] != "until" ||
		err != nil || until.Sub(time.Now()) > time.Hour || until.Sub(time.Now()) < 55*time.Minute {
		t.Errorf("--entry api_key=ine_7:1h sent %v", first)
	}
	if second["entry_id"] != "vlt_named" || !reflect.DeepEqual(second["lifetime"], map[string]any{"kind": "standing"}) {
		t.Errorf("--entry api_key=vlt_named sent %v, want it standing", second)
	}
}

// A need no flag names: a required declared need's suggestion is bound; an
// optional one's is not, nor the undeclared slot of a manifest declaring
// no needs.
func TestProfileGrant_ASuggestionBindsARequiredDeclaredNeedAlone(t *testing.T) {
	cases := []struct {
		name string
		plan string
		want []string
	}{
		{"required", planWith(list(need("api_key", "api_key", true, "vlt_s", false, "vlt_s")), `[]`, `[]`), []string{"vlt_s"}},
		{"optional", planWith(list(need("api_key", "api_key", false, "vlt_s", false, "vlt_s")), `[]`, `[]`), nil},
		{"undeclared", planWith(list(need("@ingress", "", false, "vlt_s", false, "vlt_s")), `[]`, `[]`), nil},
		{"instance", planWith(list(need("api_key", "api_key", true, "ine_s", false, "ine_s")), `[]`, `[]`), []string{"ine_s"}},
	}
	for _, c := range cases {
		srv := newCLIServer(t, "profile.commit", c.plan, previewAnswer, commitAnswer)
		out := runGrant(t, srv)

		preview, _ := sentDecisions(t, srv, 1)
		var got []string
		for _, b := range asMaps(t, preview["bindings"]) {
			got = append(got, str(b["entry_id"])+str(b["instance_entry_id"]))
			if !reflect.DeepEqual(b["lifetime"], map[string]any{"kind": "standing"}) {
				t.Errorf("%s: a suggestion is bound standing, got %v", c.name, b)
			}
		}
		if !reflect.DeepEqual(got, c.want) {
			t.Errorf("%s: bound %v, want %v\n%s", c.name, got, c.want, out)
		}
	}
}

// Where several entries meet a required need and none is suggested, a
// non-interactive grant is refused naming the need, before any preview.
func TestProfileGrant_AChoiceIsRefusedWhenItCannotBeAsked(t *testing.T) {
	plan := planWith(list(need("api_key", "api_key", true, "", true, "vlt_a", "vlt_b")), `[]`, `[]`)
	srv := newCLIServer(t, "profile.commit", plan, previewAnswer, commitAnswer)
	out, err := tryGrant(t, srv)

	if err == nil || !strings.Contains(err.Error(), "need api_key") ||
		!strings.Contains(err.Error(), "--entry api_key=<id>") {
		t.Fatalf("want a refusal naming the need, got %v\n%s", err, out)
	}
	if srv.count() != 1 {
		t.Errorf("a refused grant previewed: %d calls", srv.count())
	}

	// Named, it is bound.
	srv = newCLIServer(t, "profile.commit", plan, previewAnswer, commitAnswer)
	runGrant(t, srv, "--entry", "api_key=vlt_b")
	preview, _ := sentDecisions(t, srv, 1)
	if b := asMaps(t, preview["bindings"]); len(b) != 1 || b[0]["entry_id"] != "vlt_b" {
		t.Errorf("--entry api_key=vlt_b sent %v", b)
	}
}

// An interactive grant asks only where a choice is required, offering the
// need's candidates and no entry; nowhere else.
func TestCollectDecisions_AsksOnlyWhereAChoiceIsRequired(t *testing.T) {
	var plan map[string]any
	raw := planWith(list(
		need("api_key", "api_key", true, "", true, "vlt_a", "ine_b"),
	), list(`{"from":"f:local.daily-report","dep":"reagent:local.db","candidates":[`+
		`{"label":"work","entry_name":"work key","fields":["KEY"],"scopes":[]}],"needs":`+
		list(need("db", "api_key", true, "vlt_db", false, "vlt_db"))+`}`), `[]`)
	if err := json.Unmarshal([]byte(raw), &plan); err != nil {
		t.Fatal(err)
	}

	var asked []string
	chooser := grantChooser{
		interactive: true,
		now:         time.Now(),
		note:        func(string) {},
		ask: func(title string, options []prompt.Option) (string, error) {
			asked = append(asked, title)
			var values []string
			for _, o := range options {
				values = append(values, o.Value)
			}
			if !reflect.DeepEqual(values, []string{"", "vlt:vlt_a", "ine:ine_b"}) {
				t.Errorf("offered %v", values)
			}
			return "ine:ine_b", nil
		},
	}
	decided, err := collectDecisions(plan, grantFlags{}, chooser)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(asked, []string{"to reach api_key"}) {
		t.Errorf("asked %v, want the one need with a choice", asked)
	}
	if len(decided.bindings) != 1 || decided.bindings[0].InstanceEntryId.IsZero() {
		t.Errorf("the chosen instance entry is not bound: %+v", decided.bindings)
	}
	if len(decided.selections) != 1 || decided.selections[0].EntryId.IsZero() {
		t.Errorf("the dependency's suggestion is not selected: %+v", decided.selections)
	}
}

// --selection fills a dependency's edge from the plan's row: an entry by
// its prefix, a lender by its label, the need named when the dependency
// declares several, with its lifetime; a dependency's required need no
// flag names takes its suggestion.
func TestProfileGrant_SelectionsNameTheirEntryOrLenderAndNeed(t *testing.T) {
	db := `{"from":"f:local.daily-report","dep":"reagent:local.db","candidates":[],"needs":` +
		list(need("read", "api_key", true, "vlt_r", false, "vlt_r", "vlt_both"), need("write", "api_key", false, "", false, "vlt_w", "vlt_both")) + `}`
	maps := `{"from":"f:local.daily-report","dep":"reagent:local.maps","candidates":[],"needs":` +
		list(need("tiles", "api_key", true, "ine_t", false, "ine_t")) + `}`
	plan := planWith(`[]`, list(db, maps), `[]`)

	srv := newCLIServer(t, "profile.commit", plan, previewAnswer, commitAnswer)
	runGrant(t, srv, "--selection", "reagent:local.db=vlt_w:once")
	preview, commit := sentDecisions(t, srv, 1)
	if !reflect.DeepEqual(preview["selections"], commit["selections"]) {
		t.Errorf("the commit's selections %v are not the preview's %v", commit["selections"], preview["selections"])
	}
	want := []map[string]any{
		{"dep": "reagent:local.db", "from": "f:local.daily-report", "entry_id": "vlt_w", "need": "write",
			"lifetime": map[string]any{"kind": "once"}},
		{"dep": "reagent:local.maps", "from": "f:local.daily-report", "instance_entry_id": "ine_t",
			"lifetime": map[string]any{"kind": "standing"}},
	}
	if got := asMaps(t, preview["selections"]); !reflect.DeepEqual(got, want) {
		t.Errorf("sent %v\nwant %v", got, want)
	}

	srv = newCLIServer(t, "profile.commit", plan, previewAnswer, commitAnswer)
	runGrant(t, srv, "--selection", "reagent:local.maps=work")
	preview, _ = sentDecisions(t, srv, 1)
	got := asMaps(t, preview["selections"])
	// What a flag names first, then each edge no flag names.
	if len(got) != 2 || got[0]["label"] != "work" || got[0]["need"] != nil ||
		got[1]["entry_id"] != "vlt_r" || got[1]["need"] != "read" {
		t.Errorf("a label selection and the db's suggestion: sent %v", got)
	}

	for _, unknown := range []string{"vlt_nowhere", "vlt_both"} {
		srv = newCLIServer(t, "profile.commit", plan, previewAnswer, commitAnswer)
		_, err := tryGrant(t, srv, "--selection", "reagent:local.db="+unknown)
		if err == nil || !strings.Contains(err.Error(), "read, write") {
			t.Errorf("%s: want a refusal listing the needs, got %v", unknown, err)
		}
	}
}

// --get-head-only narrows each catalyst asking for other methods to its
// GET and HEAD, said by its methods and never as read-only.
func TestProfileGrant_GetHeadOnlyNarrowsACatalystsMethods(t *testing.T) {
	rows := list(
		`{"kind":"egress","node":"catalyst:local.mail","narrowed":false,"values":{"domains":["a.example"],"methods":["GET","POST","DELETE"],"schemes":["https"],"private_ips":[]}}`,
		`{"kind":"egress","node":"catalyst:local.feed","narrowed":false,"values":{"domains":["b.example"],"methods":["GET","HEAD"],"schemes":["https"],"private_ips":[]}}`,
		`{"kind":"egress","node":"reagent:local.parse","narrowed":false,"values":{"domains":["c.example"],"methods":["GET","PUT"],"schemes":["https"],"private_ips":[]}}`,
		`{"kind":"egress","node":"catalyst:local.post","narrowed":false,"values":{"domains":["d.example"],"methods":["POST"],"schemes":["https"],"private_ips":[]}}`,
	)
	plan := planWith(`[]`, `[]`, rows)

	srv := newCLIServer(t, "profile.commit", plan, previewAnswer, commitAnswer)
	out := runGrant(t, srv, "--get-head-only")
	preview, commit := sentDecisions(t, srv, 1)

	want := map[string]any{"catalyst:local.mail": map[string]any{"egress": map[string]any{"methods": []any{"GET"}}}}
	if !reflect.DeepEqual(preview["subset"], want) || !reflect.DeepEqual(commit["subset"], want) {
		t.Errorf("sent %v and %v, want %v", preview["subset"], commit["subset"], want)
	}
	if !strings.Contains(out, "catalyst:local.mail: GET only (it asks for GET, POST, DELETE)") {
		t.Errorf("the narrowing is not said by its methods:\n%s", out)
	}
	if lower := strings.ToLower(out); strings.Contains(lower, "read only") || strings.Contains(lower, "read-only") {
		t.Errorf("a narrowing is called read-only:\n%s", out)
	}
	if got := methodsOnlyLabel([]string{"GET", "HEAD"}); got != "GET and HEAD only" {
		t.Errorf("label %q", got)
	}

	// Without the flag, nothing is narrowed.
	srv = newCLIServer(t, "profile.commit", plan, previewAnswer, commitAnswer)
	runGrant(t, srv)
	if preview, _ := sentDecisions(t, srv, 1); preview["subset"] != nil {
		t.Errorf("an unflagged grant narrowed %v", preview["subset"])
	}
}

// The session lifetime reads the command line's own whoami once, after the
// plan, and holds the until to it; a credential that is no session is
// refused before any preview.
func TestProfileGrant_SessionLifetimeReadsWhoami(t *testing.T) {
	plan := planWith(list(need("api_key", "api_key", true, "", false, "vlt_a")), `[]`, `[]`)
	end := time.Now().Add(3 * time.Hour).UTC().Truncate(time.Second)
	who := fmt.Sprintf(`{"user_id":"u","session_expires_at":%q}`, end.Format(time.RFC3339Nano))

	srv := newCLIServer(t, "profile.commit", plan, who, previewAnswer, commitAnswer)
	runGrant(t, srv, "--entry", "api_key=vlt_a:session")
	if name, args := srv.call(1); name != "session" || args["action"] != "whoami" {
		t.Fatalf("call 1 is %s %v, want session.whoami", name, args)
	}
	preview, _ := sentDecisions(t, srv, 2)
	b := asMaps(t, preview["bindings"])
	if len(b) != 1 || !reflect.DeepEqual(b[0]["lifetime"], map[string]any{"kind": "until", "until": end.Format(time.RFC3339)}) {
		t.Errorf("sent %v, want until the session's end %s", b, end)
	}

	srv = newCLIServer(t, "profile.commit", plan, `{"user_id":"u","session_expires_at":null}`, previewAnswer, commitAnswer)
	_, err := tryGrant(t, srv, "--entry", "api_key=vlt_a:session")
	if err == nil || !strings.Contains(err.Error(), "choose standing, 5m, 1h or once") {
		t.Errorf("an API key's session lifetime: got %v", err)
	}
	if srv.count() != 2 {
		t.Errorf("a refused session lifetime made %d calls, want the plan and whoami", srv.count())
	}
}

// The plan's needs are drawn before the preview: each need, what the plan
// suggests, a choice to make, the publisher's configuration, the update a
// disclose-only need may take; and "This app asks for no credentials"
// only when neither the app nor a dependency declares one.
func TestRenderPlanNeeds(t *testing.T) {
	var plan map[string]any
	newer := strings.Replace(need("model", "api_key", true, "", false), `"need"`, `"newer_shipped":"1.4.0","need"`, 1)
	provided := `{"need":"geo","kind":"api_key","provider":"maps.example","required":true,"source":"provided",` +
		`"destination":{"hosts":["geo.maps.example"],"scheme":"https"},"candidates":[],"suggested":null,"choice_required":false}`
	raw := planWith(list(need("api_key", "api_key", true, "vlt_a", false, "vlt_a"), newer),
		list(`{"from":"f:local.daily-report","dep":"reagent:local.maps","candidates":[],"needs":`+list(provided)+`}`), `[]`)
	if err := json.Unmarshal([]byte(raw), &plan); err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	renderPlanNeeds(&out, plan)
	text := out.String()

	for _, want := range []string{
		"f:local.daily-report: api_key (api_key for openai.com) — to reach api_key",
		"suggested: entry vlt_a, an entry of this athanor",
		"no entry can meet it yet",
		"cyfr component pull f:local.daily-report:1.4.0",
		"reagent:local.maps: geo (api_key for maps.example)",
		"provided by local, the app's public configuration, sent only to https://geo.maps.example",
	} {
		if !strings.Contains(text, want) {
			t.Errorf("missing %q in\n%s", want, text)
		}
	}
	if strings.Contains(text, "asks for no credentials") {
		t.Errorf("an app with declared needs says it asks for none:\n%s", text)
	}

	out.Reset()
	if err := json.Unmarshal([]byte(planWith(list(need("@ingress", "", false, "", false)), `[]`, `[]`)), &plan); err != nil {
		t.Fatal(err)
	}
	renderPlanNeeds(&out, plan)
	if !strings.Contains(out.String(), "This app asks for no credentials.") {
		t.Errorf("an app declaring no need:\n%s", out.String())
	}
}

// A plan whose closure is unresolved names what is missing; a resolved one
// is not refused.
func TestUnresolvedPlan(t *testing.T) {
	if _, unresolved := unresolvedPlan(map[string]any{"unresolved": nil}); unresolved {
		t.Error("a resolved plan read as unresolved")
	}

	missing, unresolved := unresolvedPlan(map[string]any{"unresolved": map[string]any{
		"reason": "unresolvable_dependency", "missing": "reagent:local.absent",
	}})
	if !unresolved || !strings.Contains(missing, "reagent:local.absent is missing") {
		t.Errorf("got %q, %v", missing, unresolved)
	}

	missing, _ = unresolvedPlan(map[string]any{"unresolved": map[string]any{
		"reason": "missing_release_digest", "missing": "reagent:local.legacy",
	}})
	if !strings.Contains(missing, "reagent:local.legacy has no release digest") {
		t.Errorf("got %q", missing)
	}

	missing, _ = unresolvedPlan(map[string]any{"unresolved": map[string]any{"reason": "depth_exceeded"}})
	if !strings.Contains(missing, "depth_exceeded") {
		t.Errorf("got %q", missing)
	}
}

// ---------------------------------------------------------------------------
// The session lifetime's words, and a re-grant
// ---------------------------------------------------------------------------

// The help and the refusal of an API key's session lifetime name the time
// a session binding ends, at most 24 hours on, and never that a session's
// end or a sign-out ends it: an until is fixed once committed.
func TestProfileGrant_SessionCopyNamesTheTimeItEnds(t *testing.T) {
	help := "session (until the time your session is now due to end, at most 24 hours on, " +
		"fixed when you grant)"
	if !strings.Contains(profileGrantCmd.Long, help) {
		t.Errorf("the help does not say %q:\n%s", help, profileGrantCmd.Long)
	}

	none := grantChooser{now: time.Now(), sessionEnd: func() (time.Time, bool, error) { return time.Time{}, false, nil }}
	_, _, err := lifetimeOf("session", none)
	refusal := "the session lifetime lasts until the time this command line's session is now " +
		"due to end, at most 24 hours on, and this credential is no session (an API key), so it " +
		"has no such time: choose standing, 5m, 1h or once"
	if err == nil || err.Error() != refusal {
		t.Errorf("an API key's session lifetime: got %v, want %q", err, refusal)
	}

	for _, text := range []string{profileGrantCmd.Long, refusal} {
		lower := strings.ToLower(text)
		for _, claim := range []string{"session ends", "session does", "sign out", "sign-out",
			"signing out", "until your session"} {
			if strings.Contains(lower, claim) {
				t.Errorf("%q says %q", text, claim)
			}
		}
	}
}

const regrantApp = "f:local.daily-report"

// withHeads is a plan answer whose profile's head holds the bindings given.
func withHeads(plan, heads string) string {
	return strings.Replace(plan, `"head_origins":null`,
		`"head_origins":["interactive"],"head_bindings":`+heads, 1)
}

// headJSON is one of a plan's head_bindings as JSON text: its key, what it
// binds (an entry by its vlt_ or ine_ prefix, else a lender's label) and
// its lifetime.
func headJSON(key, binds, kind, until string) string {
	lifetime := map[string]any{"kind": kind, "until": nil}
	if until != "" {
		lifetime["until"] = until
	}
	row := map[string]any{"binding_key": key, "lifetime": lifetime, "consumed": kind == "once"}
	switch {
	case strings.HasPrefix(binds, "vlt_"):
		row["entry_id"] = binds
	case strings.HasPrefix(binds, "ine_"):
		row["instance_entry_id"] = binds
	default:
		row["label"] = binds
	}
	raw, _ := json.Marshal(row)
	return string(raw)
}

func depJSON(dep, lenders string, needs ...string) string {
	return `{"from":"` + regrantApp + `","dep":"` + dep + `","candidates":` + lenders +
		`,"needs":` + list(needs...) + `}`
}

const workLender = `[{"label":"work","entry_name":"work key","fields":["KEY"],"scopes":[]}]`

// A re-grant no flag names reopens on what the head binds, never wider:
// each binding of the app's own calls, a named account's included, and
// each dependency's edge keep their entry, lender and lifetime, an until
// still ahead its own time, and no suggestion is bound beside them.
func TestProfileGrant_ReGrantReopensOnWhatTheHeadBinds(t *testing.T) {
	ahead := time.Now().Add(2 * time.Hour).UTC().Truncate(time.Second).Format(time.RFC3339)
	plan := withHeads(planWith(
		list(need("api_key", "api_key", true, "vlt_s", false, "vlt_s", "vlt_h")),
		list(
			depJSON("reagent:local.db", workLender, need("db", "api_key", true, "vlt_db", false, "vlt_db")),
			depJSON("reagent:local.maps", `[]`, need("tiles", "api_key", true, "ine_t", false, "ine_t", "ine_old")),
		), `[]`),
		list(
			headJSON(regrantApp+"|@ingress|default", "vlt_h", "once", ""),
			headJSON(regrantApp+"|@ingress|name:later", "vlt_h", "until", ahead),
			headJSON(regrantApp+"|reagent:local.db|default", "work", "standing", ""),
			headJSON(regrantApp+"|reagent:local.maps|default", "ine_old", "until", ahead),
		))

	srv := newCLIServer(t, "profile.commit", plan, previewAnswer, commitAnswer)
	out := runGrant(t, srv)
	preview, commit := sentDecisions(t, srv, 1)

	wantBindings := []map[string]any{
		{"need": "api_key", "entry_id": "vlt_h", "lifetime": map[string]any{"kind": "once"}},
		{"need": "api_key", "entry_id": "vlt_h", "name": "later",
			"lifetime": map[string]any{"kind": "until", "until": ahead}},
	}
	wantSelections := []map[string]any{
		{"dep": "reagent:local.db", "from": regrantApp, "label": "work",
			"lifetime": map[string]any{"kind": "standing"}},
		{"dep": "reagent:local.maps", "from": regrantApp, "instance_entry_id": "ine_old",
			"lifetime": map[string]any{"kind": "until", "until": ahead}},
	}
	for name, sent := range map[string]map[string]any{"preview": preview, "commit": commit} {
		if got := asMaps(t, sent["bindings"]); !reflect.DeepEqual(got, wantBindings) {
			t.Errorf("the %s's bindings: sent %v\nwant %v\n%s", name, got, wantBindings, out)
		}
		if got := asMaps(t, sent["selections"]); !reflect.DeepEqual(got, wantSelections) {
			t.Errorf("the %s's selections: sent %v\nwant %v\n%s", name, got, wantSelections, out)
		}
	}
}

// A head binding whose until has passed is no decision the command line
// makes alone: without a terminal it is refused before any preview,
// naming the need or the dependency and the flag that names its lifetime.
// Named, it is bound as the flag says.
func TestProfileGrant_APassedUntilIsRefusedNamingWhatItBindsAndTheFlag(t *testing.T) {
	passed := time.Now().Add(-time.Hour).UTC().Truncate(time.Second).Format(time.RFC3339)

	plan := withHeads(planWith(
		list(need("api_key", "api_key", true, "vlt_s", false, "vlt_s", "vlt_h")), `[]`, `[]`),
		list(headJSON(regrantApp+"|@ingress|default", "vlt_h", "until", passed)))

	srv := newCLIServer(t, "profile.commit", plan, previewAnswer, commitAnswer)
	out, err := tryGrant(t, srv)
	if err == nil || !strings.Contains(err.Error(), "need api_key was granted until "+passed) ||
		!strings.Contains(err.Error(), "has passed") ||
		!strings.Contains(err.Error(), "--entry api_key=<id>:<lifetime>") {
		t.Fatalf("want a refusal naming the need and the flag, got %v\n%s", err, out)
	}
	if srv.count() != 1 {
		t.Errorf("a refused re-grant previewed: %d calls", srv.count())
	}

	srv = newCLIServer(t, "profile.commit", plan, previewAnswer, commitAnswer)
	runGrant(t, srv, "--entry", "api_key=vlt_h:1h")
	preview, _ := sentDecisions(t, srv, 1)
	b := asMaps(t, preview["bindings"])
	if lifetime, _ := b[0]["lifetime"].(map[string]any); len(b) != 1 || b[0]["entry_id"] != "vlt_h" ||
		lifetime["kind"] != "until" || lifetime["until"] == passed {
		t.Errorf("--entry api_key=vlt_h:1h sent %v", b)
	}

	// A dependency's edge: the dependency and its flag are named.
	plan = withHeads(planWith(`[]`, list(
		depJSON("reagent:local.db", `[]`, need("db", "api_key", true, "vlt_db", false, "vlt_db"))), `[]`),
		list(headJSON(regrantApp+"|reagent:local.db|default", "vlt_db", "until", passed)))

	srv = newCLIServer(t, "profile.commit", plan, previewAnswer, commitAnswer)
	_, err = tryGrant(t, srv)
	if err == nil || !strings.Contains(err.Error(), "reagent:local.db's credential was granted until") ||
		!strings.Contains(err.Error(), "--selection reagent:local.db=<id>:<lifetime>") {
		t.Errorf("want a refusal naming the dependency and the flag, got %v", err)
	}
	if srv.count() != 1 {
		t.Errorf("a refused re-grant previewed: %d calls", srv.count())
	}
}

// An interactive re-grant asks how long a binding whose until has passed
// lives now, offering the five lifetimes, and binds the head's entry so.
func TestCollectDecisions_AsksHowLongAPassedUntilLivesNow(t *testing.T) {
	now := time.Date(2026, 10, 4, 13, 0, 0, 0, time.UTC)
	var plan map[string]any
	raw := withHeads(planWith(
		list(need("api_key", "api_key", true, "vlt_s", false, "vlt_s", "vlt_h")), `[]`, `[]`),
		list(headJSON(regrantApp+"|@ingress|default", "vlt_h", "until", "2026-10-04T12:00:00Z")))
	if err := json.Unmarshal([]byte(raw), &plan); err != nil {
		t.Fatal(err)
	}

	var asked []string
	chooser := grantChooser{
		interactive: true,
		now:         now,
		note:        func(string) {},
		ask: func(title string, options []prompt.Option) (string, error) {
			asked = append(asked, title)
			var values []string
			for _, o := range options {
				values = append(values, o.Value)
			}
			if !reflect.DeepEqual(values, lifetimeChoices) {
				t.Errorf("offered %v, want the five lifetimes", values)
			}
			return "1h", nil
		},
	}
	decided, err := collectDecisions(plan, grantFlags{}, chooser)
	if err != nil {
		t.Fatal(err)
	}
	if len(asked) != 1 || !strings.Contains(asked[0], "need api_key was granted until 2026-10-04T12:00:00Z") {
		t.Errorf("asked %v", asked)
	}
	sent, _ := json.Marshal(decided.bindings)
	want := `[{"entry_id":"vlt_h","lifetime":{"kind":"until","until":"2026-10-04T14:00:00Z"},"need":"api_key"}]`
	var got, expect any
	_ = json.Unmarshal(sent, &got)
	_ = json.Unmarshal([]byte(want), &expect)
	if !reflect.DeepEqual(got, expect) {
		t.Errorf("bound %s, want %s", sent, want)
	}
}

// A flag names its slot alone: the need's or the dependency's default, or
// one named account. The head's other bindings carry; a flag naming a need
// other than the head's own-call need replaces every binding of the app's
// own calls, since that edge carries one need's credentials; and an edge
// no flag names reopens on the head.
func TestProfileGrant_AFlagReplacesTheHeadBindingOfItsSlotAlone(t *testing.T) {
	ahead := time.Now().Add(2 * time.Hour).UTC().Truncate(time.Second).Format(time.RFC3339)
	plan := withHeads(planWith(
		list(
			need("api_key", "api_key", true, "vlt_s", false, "vlt_s", "vlt_h"),
			need("other", "api_key", false, "", false, "vlt_o"),
		),
		list(depJSON("reagent:local.db", workLender, need("db", "api_key", true, "vlt_db", false, "vlt_db", "vlt_x"))),
		`[]`),
		list(
			headJSON(regrantApp+"|@ingress|default", "vlt_h", "once", ""),
			headJSON(regrantApp+"|@ingress|name:later", "vlt_h", "until", ahead),
			headJSON(regrantApp+"|reagent:local.db|default", "vlt_db", "standing", ""),
			headJSON(regrantApp+"|reagent:local.db|name:Work", "vlt_x", "once", ""),
		))

	once := map[string]any{"kind": "once"}
	standing := map[string]any{"kind": "standing"}
	headDefault := map[string]any{"need": "api_key", "entry_id": "vlt_h", "lifetime": once}
	headLater := map[string]any{"need": "api_key", "entry_id": "vlt_h", "name": "later",
		"lifetime": map[string]any{"kind": "until", "until": ahead}}
	edgeDefault := map[string]any{"dep": "reagent:local.db", "from": regrantApp, "entry_id": "vlt_db",
		"lifetime": standing}
	edgeWork := map[string]any{"dep": "reagent:local.db", "from": regrantApp, "entry_id": "vlt_x",
		"name": "Work", "lifetime": once}

	cases := []struct {
		name       string
		args       []string
		bindings   []map[string]any
		selections []map[string]any
	}{
		{"the default of the app's own calls", []string{"--entry", "api_key=vlt_s"},
			[]map[string]any{{"need": "api_key", "entry_id": "vlt_s", "lifetime": standing}, headLater},
			[]map[string]any{edgeDefault, edgeWork}},
		{"a named account of the app's own calls", []string{"--entry", "api_key|later=vlt_s:once"},
			[]map[string]any{{"need": "api_key", "entry_id": "vlt_s", "name": "later", "lifetime": once}, headDefault},
			[]map[string]any{edgeDefault, edgeWork}},
		{"another need of the app's own calls", []string{"--entry", "other=vlt_o"},
			[]map[string]any{{"need": "other", "entry_id": "vlt_o", "lifetime": standing}},
			[]map[string]any{edgeDefault, edgeWork}},
		{"a dependency's named account", []string{"--selection", "reagent:local.db|work=vlt_db:once"},
			[]map[string]any{headDefault, headLater},
			[]map[string]any{{"dep": "reagent:local.db", "from": regrantApp, "entry_id": "vlt_db",
				"name": "work", "lifetime": once}, edgeDefault}},
		{"a dependency's default", []string{"--selection", "reagent:local.db=vlt_x:once"},
			[]map[string]any{headDefault, headLater},
			[]map[string]any{{"dep": "reagent:local.db", "from": regrantApp, "entry_id": "vlt_x",
				"lifetime": once}, edgeWork}},
	}
	for _, c := range cases {
		srv := newCLIServer(t, "profile.commit", plan, previewAnswer, commitAnswer)
		out := runGrant(t, srv, c.args...)
		preview, commit := sentDecisions(t, srv, 1)
		if !reflect.DeepEqual(preview, commit) {
			t.Errorf("%s: the commit's decisions %v are not the preview's %v", c.name, commit, preview)
		}
		if got := asMaps(t, preview["bindings"]); !reflect.DeepEqual(got, c.bindings) {
			t.Errorf("%s: bindings sent %v\nwant %v\n%s", c.name, got, c.bindings, out)
		}
		if got := asMaps(t, preview["selections"]); !reflect.DeepEqual(got, c.selections) {
			t.Errorf("%s: selections sent %v\nwant %v\n%s", c.name, got, c.selections, out)
		}
	}
}

// A value splits at its last =: what follows is the id and its lifetime,
// what precedes the need or the dependency, and after its first | the
// account it names, which may hold = and :. A slot no flag names takes
// what it takes with no flags, so a named account on a first grant binds
// the suggested default beside it.
func TestProfileGrant_AFlagNamesAnAccountAfterItsNeedOrDependency(t *testing.T) {
	plan := planWith(
		list(need("api_key", "api_key", true, "vlt_s", false, "vlt_s", "vlt_abc")),
		list(depJSON("reagent:local.db", `[]`, need("db", "api_key", true, "vlt_db", false, "vlt_db", "vlt_def"))),
		`[]`)

	srv := newCLIServer(t, "profile.commit", plan, previewAnswer, commitAnswer)
	out := runGrant(t, srv, "--entry", "api_key|a=b:c=vlt_abc:1h",
		"--selection", "reagent:local.db|Supabase 2=vlt_def")
	preview, commit := sentDecisions(t, srv, 1)
	if !reflect.DeepEqual(preview, commit) {
		t.Errorf("the commit's decisions %v are not the preview's %v", commit, preview)
	}

	bindings := asMaps(t, preview["bindings"])
	if len(bindings) != 2 {
		t.Fatalf("want the named account and the suggested default, got %v\n%s", bindings, out)
	}
	named := bindings[0]
	lifetime, _ := named["lifetime"].(map[string]any)
	until, err := time.Parse(time.RFC3339, str(lifetime["until"]))
	if named["need"] != "api_key" || named["name"] != "a=b:c" || named["entry_id"] != "vlt_abc" ||
		lifetime["kind"] != "until" || err != nil || time.Until(until) > time.Hour ||
		time.Until(until) < 55*time.Minute {
		t.Errorf("--entry 'api_key|a=b:c=vlt_abc:1h' sent %v", named)
	}
	if want := (map[string]any{"need": "api_key", "entry_id": "vlt_s",
		"lifetime": map[string]any{"kind": "standing"}}); !reflect.DeepEqual(bindings[1], want) {
		t.Errorf("the default beside it: sent %v, want the suggestion %v", bindings[1], want)
	}

	if got, want := asMaps(t, preview["selections"]), []map[string]any{
		{"dep": "reagent:local.db", "from": regrantApp, "entry_id": "vlt_def", "name": "Supabase 2",
			"lifetime": map[string]any{"kind": "standing"}},
		{"dep": "reagent:local.db", "from": regrantApp, "entry_id": "vlt_db",
			"lifetime": map[string]any{"kind": "standing"}},
	}; !reflect.DeepEqual(got, want) {
		t.Errorf("selections sent %v\nwant %v", got, want)
	}
}

// Where no default can be found for a named account's need, the account
// is sent alone and the home refuses it, naming the need: the command
// line binds no default nobody chose.
func TestProfileGrant_ANamedFlagWithNoDefaultToFindIsSentAlone(t *testing.T) {
	plan := planWith(list(need("api_key", "api_key", true, "", false)), `[]`, `[]`)
	srv := newCLIServer(t, "profile.commit", plan, previewAnswer, commitAnswer)
	runGrant(t, srv, "--entry", "api_key|Work=vlt_x")
	preview, _ := sentDecisions(t, srv, 1)
	if got, want := asMaps(t, preview["bindings"]), []map[string]any{
		{"need": "api_key", "entry_id": "vlt_x", "name": "Work", "lifetime": map[string]any{"kind": "standing"}},
	}; !reflect.DeepEqual(got, want) {
		t.Errorf("sent %v, want the named account alone %v", got, want)
	}
}

// A named account names an entry, never a lender's label, under a name the
// binding key can carry; each refusal names the flag, before any call.
func TestProfileGrant_ANamedFlagNamesAnEntryUnderAValidName(t *testing.T) {
	cases := []struct {
		args []string
		want []string
	}{
		{[]string{"--selection", "reagent:local.db|Work=work"},
			[]string{"--selection", "the account Work by a profile's label", "names an entry"}},
		{[]string{"--entry", "api_key|=vlt_x"}, []string{"--entry", "1 to 128 bytes"}},
		{[]string{"--entry", "api_key|a|b=vlt_x"}, []string{"--entry", `"a|b"`, "1 to 128 bytes"}},
		{[]string{"--selection", "reagent:local.db|" + strings.Repeat("x", 129) + "=vlt_x"},
			[]string{"--selection", "1 to 128 bytes"}},
		{[]string{"--entry", "api_key|tab\there=vlt_x"}, []string{"--entry", "control character"}},
	}
	for _, c := range cases {
		srv := newCLIServer(t, "profile.commit", planWith(`[]`, `[]`, `[]`), previewAnswer, commitAnswer)
		out, err := tryGrant(t, srv, c.args...)
		if err == nil {
			t.Errorf("%v was accepted:\n%s", c.args, out)
			continue
		}
		for _, want := range c.want {
			if !strings.Contains(err.Error(), want) {
				t.Errorf("%v: refusal %q does not say %q", c.args, err, want)
			}
		}
		if srv.count() != 0 {
			t.Errorf("%v: refused after %d calls", c.args, srv.count())
		}
	}
}

// A named account whose until has passed is no decision the command line
// makes alone: without a terminal it is refused before any preview,
// naming the account and the flag that grants it again.
func TestProfileGrant_ANamedAccountsPassedUntilNamesTheAccountAndItsFlag(t *testing.T) {
	passed := time.Now().Add(-time.Hour).UTC().Truncate(time.Second).Format(time.RFC3339)

	plan := withHeads(planWith(
		list(need("api_key", "api_key", true, "vlt_h", false, "vlt_h", "vlt_w")), `[]`, `[]`),
		list(
			headJSON(regrantApp+"|@ingress|default", "vlt_h", "standing", ""),
			headJSON(regrantApp+"|@ingress|name:Work", "vlt_w", "until", passed),
		))

	srv := newCLIServer(t, "profile.commit", plan, previewAnswer, commitAnswer)
	_, err := tryGrant(t, srv)
	if err == nil || !strings.Contains(err.Error(), "need api_key's account 'Work' was granted until "+passed) ||
		!strings.Contains(err.Error(), "--entry 'api_key|Work=<id>:<lifetime>'") {
		t.Fatalf("want a refusal naming the account and its flag, got %v", err)
	}
	if srv.count() != 1 {
		t.Errorf("a refused re-grant previewed: %d calls", srv.count())
	}

	// Its flag grants it again; the default carries.
	srv = newCLIServer(t, "profile.commit", plan, previewAnswer, commitAnswer)
	runGrant(t, srv, "--entry", "api_key|Work=vlt_w:once")
	preview, _ := sentDecisions(t, srv, 1)
	if got, want := asMaps(t, preview["bindings"]), []map[string]any{
		{"need": "api_key", "entry_id": "vlt_w", "name": "Work", "lifetime": map[string]any{"kind": "once"}},
		{"need": "api_key", "entry_id": "vlt_h", "lifetime": map[string]any{"kind": "standing"}},
	}; !reflect.DeepEqual(got, want) {
		t.Errorf("sent %v\nwant %v", got, want)
	}

	// A dependency's named account.
	plan = withHeads(planWith(`[]`, list(
		depJSON("reagent:local.db", `[]`, need("db", "api_key", true, "vlt_db", false, "vlt_db", "vlt_dw"))), `[]`),
		list(
			headJSON(regrantApp+"|reagent:local.db|default", "vlt_db", "standing", ""),
			headJSON(regrantApp+"|reagent:local.db|name:Work", "vlt_dw", "until", passed),
		))

	srv = newCLIServer(t, "profile.commit", plan, previewAnswer, commitAnswer)
	_, err = tryGrant(t, srv)
	if err == nil || !strings.Contains(err.Error(), "reagent:local.db's account 'Work' was granted until "+passed) ||
		!strings.Contains(err.Error(), "--selection 'reagent:local.db|Work=<id>:<lifetime>'") {
		t.Errorf("want a refusal naming the dependency's account and its flag, got %v", err)
	}
	if srv.count() != 1 {
		t.Errorf("a refused re-grant previewed: %d calls", srv.count())
	}
}

// An interactive re-grant asks how long a named account whose until has
// passed lives now, naming the account, and binds its entry so beside the
// default it carries.
func TestCollectDecisions_AsksHowLongANamedAccountsPassedUntilLivesNow(t *testing.T) {
	now := time.Date(2026, 10, 4, 13, 0, 0, 0, time.UTC)
	var plan map[string]any
	raw := withHeads(planWith(`[]`, list(
		depJSON("reagent:local.db", `[]`, need("db", "api_key", true, "vlt_db", false, "vlt_db", "vlt_dw"))), `[]`),
		list(
			headJSON(regrantApp+"|reagent:local.db|default", "vlt_db", "standing", ""),
			headJSON(regrantApp+"|reagent:local.db|name:Work", "vlt_dw", "until", "2026-10-04T12:00:00Z"),
		))
	if err := json.Unmarshal([]byte(raw), &plan); err != nil {
		t.Fatal(err)
	}

	var asked []string
	chooser := grantChooser{
		interactive: true,
		now:         now,
		note:        func(string) {},
		ask: func(title string, options []prompt.Option) (string, error) {
			asked = append(asked, title)
			return "1h", nil
		},
	}
	decided, err := collectDecisions(plan, grantFlags{}, chooser)
	if err != nil {
		t.Fatal(err)
	}
	if len(asked) != 1 ||
		!strings.Contains(asked[0], "reagent:local.db's account 'Work' was granted until 2026-10-04T12:00:00Z") {
		t.Errorf("asked %v", asked)
	}
	sent, _ := json.Marshal(decided.selections)
	want := `[{"dep":"reagent:local.db","from":"` + regrantApp + `","entry_id":"vlt_db","lifetime":{"kind":"standing"}},` +
		`{"dep":"reagent:local.db","from":"` + regrantApp + `","entry_id":"vlt_dw","name":"Work",` +
		`"lifetime":{"kind":"until","until":"2026-10-04T14:00:00Z"}}]`
	var got, expect any
	_ = json.Unmarshal(sent, &got)
	_ = json.Unmarshal([]byte(want), &expect)
	if !reflect.DeepEqual(got, expect) {
		t.Errorf("selected %s, want %s", sent, want)
	}
}

// A head binding whose need cannot be told (its entry is no need's
// candidate and there are several) is left unbound, with no suggestion in
// its place, and the command line says the flag that binds it.
func TestProfileGrant_AHeadBindingWhoseNeedCannotBeToldIsLeftUnbound(t *testing.T) {
	plan := withHeads(planWith(list(
		need("api_key", "api_key", true, "vlt_s", false, "vlt_s"),
		need("other", "api_key", false, "", false, "vlt_o"),
	), `[]`, `[]`), list(headJSON(regrantApp+"|@ingress|default", "vlt_gone", "standing", "")))

	srv := newCLIServer(t, "profile.commit", plan, previewAnswer, commitAnswer)
	out := runGrant(t, srv)
	preview, _ := sentDecisions(t, srv, 1)
	if got := asMaps(t, preview["bindings"]); len(got) != 0 {
		t.Errorf("bound %v, want nothing", got)
	}
	if !strings.Contains(out, "left unbound") || !strings.Contains(out, "--entry <need>=vlt_gone") {
		t.Errorf("the unbound binding is not said:\n%s", out)
	}

	// A dependency declaring several needs, on an edge naming none.
	plan = withHeads(planWith(`[]`, list(depJSON("reagent:local.db", `[]`,
		need("read", "api_key", true, "vlt_r", false, "vlt_r"),
		need("write", "api_key", false, "", false, "vlt_w"))), `[]`),
		list(headJSON(regrantApp+"|reagent:local.db|default", "vlt_gone", "standing", "")))

	srv = newCLIServer(t, "profile.commit", plan, previewAnswer, commitAnswer)
	out = runGrant(t, srv)
	preview, _ = sentDecisions(t, srv, 1)
	if got := asMaps(t, preview["selections"]); len(got) != 0 {
		t.Errorf("selected %v, want nothing", got)
	}
	if !strings.Contains(out, "--selection reagent:local.db=vlt_gone") {
		t.Errorf("the unbound edge is not said:\n%s", out)
	}
}

// A flag naming another need than the head's own-call need replaces every
// binding the app's own calls held, since they carry one need's
// credentials: the grant says so, naming the need, its default and each
// account, and the preview's removals are printed, all before the person
// is asked to confirm.
func TestProfileGrant_AGrantForAnotherNeedSaysWhatItReplacesAndRemoves(t *testing.T) {
	plan := withHeads(planWith(list(
		need("api_key", "api_key", true, "vlt_a", false, "vlt_a", "vlt_c"),
		need("other_key", "api_key", false, "", false, "vlt_d", "vlt_b"),
	), `[]`, `[]`), list(
		headJSON(regrantApp+"|@ingress|default", "vlt_a", "standing", ""),
		headJSON(regrantApp+"|@ingress|name:Work", "vlt_c", "standing", ""),
	))

	removedItem := func(slot, id, name string) map[string]any {
		item := map[string]any{"binding_key": regrantApp + "|@ingress|" + slot, "node": regrantApp,
			"edge": "@ingress", "need": "api_key", "entry_id": id, "name": name, "source": "own"}
		if account, ok := strings.CutPrefix(slot, "name:"); ok {
			item["connection"] = account
		}
		return item
	}
	removed, _ := json.Marshal([]any{
		removedItem("default", "vlt_a", "key a"),
		removedItem("name:Work", "vlt_c", "key c"),
	})
	preview := strings.Replace(previewAnswer, `"rows":[]`, `"rows":[],"removed":`+string(removed), 1)

	srv := newCLIServer(t, "profile.commit", plan, preview, commitAnswer)
	out := runGrant(t, srv, "--entry", "other_key=vlt_d", "--entry", "other_key|Work=vlt_b")

	sent, _ := sentDecisions(t, srv, 1)
	wantBindings := []map[string]any{
		{"need": "other_key", "entry_id": "vlt_d", "lifetime": map[string]any{"kind": "standing"}},
		{"need": "other_key", "entry_id": "vlt_b", "name": "Work",
			"lifetime": map[string]any{"kind": "standing"}},
	}
	if got := asMaps(t, sent["bindings"]); !reflect.DeepEqual(got, wantBindings) {
		t.Errorf("bindings sent %v\nwant %v\n%s", got, wantBindings, out)
	}

	note := "This grant replaces the app's bindings of api_key: its default and the account " +
		"'Work'; its own calls carry one need's credentials."
	lines := []string{
		note,
		"You are approving:",
		"Removes api_key default: key a",
		"Removes api_key account 'Work': key c",
		"Granted.",
	}
	at := -1
	for _, line := range lines {
		i := strings.Index(out, line)
		if i < 0 {
			t.Fatalf("missing %q in\n%s", line, out)
		}
		if i < at {
			t.Errorf("%q is not after what comes before it:\n%s", line, out)
		}
		at = i
	}
}

// The note names the default when it is held, and each account.
func TestReplacedNote_NamesTheDefaultAndEachAccount(t *testing.T) {
	cases := []struct {
		held []headBinding
		want string
	}{
		{[]headBinding{{}}, "its default"},
		{[]headBinding{{}, {name: "A"}, {name: "B"}}, "its default, the account 'A' and the account 'B'"},
		{[]headBinding{{name: "A"}}, "the account 'A'"},
	}
	for _, c := range cases {
		want := "This grant replaces the app's bindings of api_key: " + c.want +
			"; its own calls carry one need's credentials."
		if got := replacedNote("api_key", c.held); got != want {
			t.Errorf("got %q\nwant %q", got, want)
		}
	}
}

// expected is how a value of a row reads in the rendering.
func expected(row map[string]any, field string, value any) []string {
	switch {
	case field == "edge" && value == "@ingress":
		return []string{str(row["node"]) + " uses", "for its own calls"}
	case field == "edge":
		dep, need, _ := strings.Cut(str(value), "|")
		return []string{dep, need}
	case field == "subject" && value == "*":
		return []string{"any subject"}
	case field == "tools" && joinStrings(value) == "*":
		return []string{"every tool of the catalog (*)"}
	case field == "background" && value == true:
		return []string{"keeps running in the background"}
	case field == "background":
		return []string{"stops when hidden"}
	case field == "args":
		args, _ := json.Marshal(value)
		return []string{string(args)}
	case field == "rate_limit":
		rate := value.(map[string]any)
		return []string{num(rate["requests"]) + " per " + str(rate["window"])}
	case field == "destination":
		destination := value.(map[string]any)
		wants := []string{str(destination["scheme"]) + "://"}
		for _, key := range []string{"hosts", "methods", "paths"} {
			if list, ok := destination[key].([]any); ok {
				for _, item := range list {
					wants = append(wants, str(item))
				}
			}
		}
		if port, ok := destination["port"]; ok {
			wants = append(wants, "port "+num(port))
		}
		return wants
	case field == "lifetime":
		lifetime := value.(map[string]any)
		switch str(lifetime["kind"]) {
		case "standing":
			return []string{"until revoked"}
		case "until":
			return []string{"until " + str(lifetime["until"])}
		default:
			return []string{"one run"}
		}
	case field == "source" && value == "own":
		return []string{"an entry of this athanor"}
	case field == "source" && value == "instance":
		return []string{"provided by this instance"}
	case field == "source" && value == "provided":
		return []string{"provided by " + publisherOf(str(row["node"]), "")}
	case field == "label":
		return []string{"through its '" + str(value) + "' profile"}
	case field == "provider":
		return []string{"a " + str(value) + " account"}
	case field == "disclosed" && value == true:
		return []string{"The component reads the value itself."}
	case field == "disclosed":
		return []string{"CYFR attaches the value and the component never holds it."}
	case field == "suggested" && value == true:
		return []string{"suggested"}
	case field == "choice_required" && value == true:
		return []string{"choose which entry to use"}
	case field == "suggested" || field == "choice_required":
		return nil
	case field == "binding_key":
		return []string{"binding: " + str(value)}
	case field == "connection":
		return []string{"as the account '" + str(value) + "'"}
	}

	switch typed := value.(type) {
	case []any:
		wants := make([]string, 0, len(typed))
		for _, item := range typed {
			wants = append(wants, str(item))
		}
		return wants
	case float64:
		return []string{field + ": " + num(typed)}
	default:
		return []string{str(typed)}
	}
}

// accountNameVectors is tests/fixtures/account_names.json: the Unicode
// version its keys are folded on, each name's key, and pairs of names that
// are, or are not, one account.
type accountNameVectors struct {
	Unicode string `json:"unicode"`
	Keys    []struct {
		Name string `json:"name"`
		Key  string `json:"key"`
	} `json:"keys"`
	Same      [][2]string `json:"same"`
	Different [][2]string `json:"different"`
}

// The CLI folds account names as the home does: on the Unicode tables the
// shared vector names (the toolchain's, which go.mod pins), every key and
// pair of it, which Prima.Authority.Blob's test reads too, through the slot
// a flag's account names.
func TestAccountNameKey_MatchesTheHome(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "tests", "fixtures", "account_names.json"))
	if err != nil {
		t.Fatalf("read vectors: %v", err)
	}
	var v accountNameVectors
	if err := json.Unmarshal(raw, &v); err != nil {
		t.Fatalf("decode vectors: %v", err)
	}
	if len(v.Keys) == 0 || len(v.Same) == 0 || len(v.Different) == 0 {
		t.Fatalf("the vector holds no cases: %+v", v)
	}
	if unicode.Version != v.Unicode {
		t.Errorf("the CLI folds on Unicode %s, the vector on %s", unicode.Version, v.Unicode)
	}
	for _, c := range v.Keys {
		got := strings.TrimPrefix(slotKey("dep", c.Name), slotKey("dep", ""))
		if got != c.Key {
			t.Errorf("the slot of %q keys it %q (%U), want %q (%U)", c.Name, got, []rune(got), c.Key, []rune(c.Key))
		}
	}
	for _, pair := range v.Same {
		if slotKey("dep", pair[0]) != slotKey("dep", pair[1]) {
			t.Errorf("%q and %q are one account, but their slots differ", pair[0], pair[1])
		}
	}
	for _, pair := range v.Different {
		if slotKey("dep", pair[0]) == slotKey("dep", pair[1]) {
			t.Errorf("%q and %q are two accounts, but share a slot", pair[0], pair[1])
		}
	}
}

// A listed profile's head reads as what the home answered of it: its
// revision when it was read, none when the profile has no head, and a
// damaged or unreadable head as such, never as none. A home that answers
// no head_state reads by its revision, as it always did.
func TestProfileList_SaysWhatStandsInPlaceOfAHead(t *testing.T) {
	srv := newCLIServer(t, "", `{"profiles":[`+
		`{"id":"prof_present","kind":"owner","status":"active","head_state":"present","head_revision":3},`+
		`{"id":"prof_missing","kind":"owner","status":"active","head_state":"missing","head_revision":null},`+
		`{"id":"prof_damaged","kind":"owner","status":"active","head_state":"damaged","head_revision":null},`+
		`{"id":"prof_unavailable","kind":"owner","status":"active","head_state":"unavailable","head_revision":null},`+
		`{"id":"prof_older","kind":"owner","status":"active","head_revision":null},`+
		`{"id":"prof_older_read","kind":"owner","status":"active","head_revision":2}]}`)

	out, err := runCLI(t, srv, "profile", "list", "reagent:local.listed")
	if err != nil {
		t.Fatalf("cyfr profile list failed: %v\n%s", err, out)
	}

	want := map[string]string{
		"prof_present":     "consent rev 3",
		"prof_missing":     "consent rev none",
		"prof_damaged":     "consent damaged",
		"prof_unavailable": "consent unavailable — try again",
		"prof_older":       "consent rev none",
		"prof_older_read":  "consent rev 2",
	}

	lines := strings.Split(strings.TrimSpace(out), "\n")
	if len(lines) != len(want) {
		t.Fatalf("listed %d profiles, want %d:\n%s", len(lines), len(want), out)
	}
	for _, line := range lines {
		id := strings.Fields(line)[0]
		head, ok := want[id]
		if !ok {
			t.Errorf("listed a profile the home did not answer: %q", line)
			continue
		}
		if !strings.HasSuffix(line, " "+head) {
			t.Errorf("%s reads %q, want its head as %q", id, line, head)
		}
	}
}
