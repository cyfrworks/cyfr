// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
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

// A credential row says whose entry it binds, where it goes, whether the
// component holds it and how long it stands, in the CLI's words.
func TestRenderPreview_SaysWhereACredentialGoesAndForHowLong(t *testing.T) {
	v := loadPreviewVectors(t)
	var out bytes.Buffer
	renderPreview(&out, v.Preview)
	text := out.String()

	for _, want := range []string{
		"source: own (an entry of this athanor)",
		"source: instance (an entry this instance offers)",
		"source: provided (the publisher's public configuration)",
		"goes to: https://api.weather.example",
		"goes to: https://tiles.maps.example, methods GET, paths /v1/tiles",
		"goes to: https://*.weather.example port 8443, methods GET, POST, paths /v2",
		"attached by CYFR: the component never holds the value",
		"disclosed: the component reads the value itself",
		"lifetime: until revoked",
		"lifetime: until 2026-10-04T13:00:00Z",
		"lifetime: one run",
		"weather-api lent by reagent:local.weather to reagent:local.geo, as the account 'Geo account'",
		"binding: reagent:local.weather|reagent:local.geo|name:Geo account",
		"provider: weather.example",
		"suggested",
	} {
		if !strings.Contains(text, want) {
			t.Errorf("missing %q in\n%s", want, text)
		}
	}
	if strings.Contains(text, "choose which entry to use") {
		t.Errorf("no row of the vectors asks for a choice:\n%s", text)
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
		"weather-api for reagent:local.weather's own calls",
		"weather-api lent by reagent:local.weather to reagent:local.geo",
		"maps lent by reagent:local.weather to reagent:local.maps for its tiles need, the key bound on its 'shared-maps' profile",
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

// emptyOrigins empties the --origin flag: cobra keeps a flag's values,
// and appends to them, across runs of one process.
func emptyOrigins() {
	flag := profileGrantCmd.Flags().Lookup("origin")
	_ = flag.Value.(interface{ Replace([]string) error }).Replace(nil)
	flag.Changed = false
}

// runGrant runs `cyfr profile grant` against srv with an empty --origin
// flag, emptied again after.
func runGrant(t *testing.T, srv *cliServer, args ...string) string {
	t.Helper()
	onTerminal(t, false)
	emptyOrigins()
	t.Cleanup(emptyOrigins)

	out, err := runCLI(t, srv, append([]string{"profile", "grant", "f:local.daily-report", "--no-interactive"}, args...)...)
	if err != nil {
		t.Fatalf("cyfr profile grant failed: %v\n%s", err, out)
	}
	return out
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

// expected is how a value of a row reads in the rendering.
func expected(row map[string]any, field string, value any) []string {
	switch {
	case field == "edge" && value == "@ingress":
		return []string{str(row["node"]) + "'s own calls"}
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
	case field == "source":
		return []string{"source: " + str(value)}
	case field == "disclosed" && value == true:
		return []string{"the component reads the value itself"}
	case field == "disclosed":
		return []string{"the component never holds the value"}
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
