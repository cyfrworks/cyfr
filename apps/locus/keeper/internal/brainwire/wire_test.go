// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package brainwire

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"testing"
	"unicode/utf8"
)

type wireVectors struct {
	Version      int                 `json:"version"`
	MaxLineBytes int                 `json:"max_line_bytes"`
	MaxIDBytes   int                 `json:"max_id_bytes"`
	MaxList      int                 `json:"max_list"`
	MaxDetail    int                 `json:"max_detail_bytes"`
	Config       map[string]string   `json:"config"`
	Counts       []string            `json:"counts"`
	Accountings  []string            `json:"accountings"`
	Stops        []string            `json:"stops"`
	Phases       []string            `json:"phases"`
	Accounts     []string            `json:"accounts"`
	ErrorTypes   []string            `json:"error_types"`
	Blocks       []json.RawMessage   `json:"blocks"`
	MediaTypes   map[string][]string `json:"media_types"`
	Native       []string            `json:"native"`
	Endings      []string            `json:"endings"`
	Tools        struct {
		MaxDescription  int      `json:"max_description"`
		MaxStubArgument int      `json:"max_stub_argument"`
		MaxToolsBytes   int      `json:"max_tools_bytes"`
		Uncarried       []string `json:"uncarried"`
		Cases           []struct {
			Name              string         `json:"name"`
			Tool              map[string]any `json:"tool"`
			Description       []any          `json:"description"`
			Pad               int            `json:"pad"`
			Names             *[]string      `json:"names"`
			StubArgumentBytes int            `json:"stub_argument_bytes"`
			ToolsBytes        int            `json:"tools_bytes"`
			Carried           bool           `json:"carried"`
		} `json:"cases"`
		Lists []struct {
			Name       string `json:"name"`
			Pads       []int  `json:"pads"`
			ToolsBytes int    `json:"tools_bytes"`
			Fits       bool   `json:"fits"`
		} `json:"lists"`
	} `json:"tools"`
	Commands map[string]vector `json:"commands"`
	Events   map[string]vector `json:"events"`
	UUID     struct {
		Prefix string `json:"prefix"`
		Cases  []struct {
			ID   string `json:"id"`
			UUID string `json:"uuid"`
		} `json:"cases"`
	} `json:"uuid"`
	Read []struct {
		Name  string         `json:"name"`
		From  string         `json:"from"`
		Line  string         `json:"line"`
		Reads map[string]any `json:"reads"`
	} `json:"read"`
	Refuse []struct {
		Name      string `json:"name"`
		From      string `json:"from"`
		Line      string `json:"line"`
		LineBytes int    `json:"line_bytes"`
		Reason    string `json:"reason"`
	} `json:"refuse"`
}

type vector struct {
	Fields   []string          `json:"fields"`
	Optional []string          `json:"optional"`
	Types    map[string]string `json:"types"`
	Example  json.RawMessage   `json:"example"`
}

func loadWireVectors(t *testing.T) wireVectors {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("..", "..", "..", "..", "..", "tests", "fixtures", "brain_wire.json"))
	if err != nil {
		t.Fatal(err)
	}
	var v wireVectors
	if err := json.Unmarshal(data, &v); err != nil {
		t.Fatal(err)
	}
	return v
}

var typeNames = map[fieldType]string{
	tID: "id", tString: "string", tDetail: "detail", tCount: "count", tBoolean: "boolean", tObject: "object", tIDs: "ids",
	tStrings: "strings", tContent: "content", tTools: "tools", tConfig: "config", tCounts: "counts",
	tModels: "models", tChoices: "choices", tModelCounts: "model_counts", tPhase: "phase", tErrorType: "error_type",
	tAccounting: "accounting", tStop: "stop", tAccount: "account", tSignedIn: "signed_in", tSignedOut: "signed_out", tWhy: "why",
}

func specOf(s Spec) vector {
	types := map[string]string{}
	for name, ft := range s.types {
		types[name] = typeNames[ft]
	}
	optional := s.optional
	if optional == nil {
		optional = []string{}
	}
	return vector{Fields: s.fields, Optional: optional, Types: types}
}

func sorted(s []string) []string {
	out := append([]string{}, s...)
	sort.Strings(out)
	return out
}

func TestTheWiresBoundsAndVocabulariesAreTheVectors(t *testing.T) {
	v := loadWireVectors(t)
	if v.Version != Version || v.MaxLineBytes != MaxLineBytes || v.MaxIDBytes != MaxIDBytes || v.MaxList != MaxList ||
		v.MaxDetail != MaxDetailBytes {
		t.Fatalf("the vectors' version and bounds are %d, %d, %d, %d, %d", v.Version, v.MaxLineBytes, v.MaxIDBytes, v.MaxList, v.MaxDetail)
	}
	config := map[string]string{}
	for name, ft := range configTypes {
		config[name] = typeNames[ft]
	}
	if !reflect.DeepEqual(config, v.Config) || !reflect.DeepEqual(CountNames, v.Counts) ||
		!reflect.DeepEqual(accountings, v.Accountings) || !reflect.DeepEqual(stops, v.Stops) ||
		!reflect.DeepEqual(phases, v.Phases) || !reflect.DeepEqual(accounts, v.Accounts) || !reflect.DeepEqual(errorTypes, v.ErrorTypes) ||
		!reflect.DeepEqual(mediaTypes, v.MediaTypes) || !reflect.DeepEqual(nativeEvents, v.Native) ||
		!reflect.DeepEqual(whyCodes(), v.Endings) {
		t.Fatal("the configuration, counts, accountings, stops, phases, accounts, error types, media types, native events and endings are the vectors'")
	}
	if v.UUID.Prefix != uuidPrefix {
		t.Fatalf("the uuid's prefix is the vectors': %q", v.UUID.Prefix)
	}
	for _, c := range v.UUID.Cases {
		if got := PostUUID(c.ID); got != c.UUID {
			t.Fatalf("the uuid of %q is %s, the vectors say %s", c.ID, got, c.UUID)
		}
	}
	for _, block := range v.Blocks {
		if !BlockOK(block) {
			t.Fatalf("every block the vectors show reads: %s", block)
		}
	}
}

func TestEveryMessageIsTheVectorsAndItsExampleReads(t *testing.T) {
	v := loadWireVectors(t)
	for direction, pair := range map[string]struct {
		ours   map[string]Spec
		theirs map[string]vector
	}{"commands": {Commands, v.Commands}, "events": {Events, v.Events}} {
		if len(pair.ours) != len(pair.theirs) {
			t.Fatalf("the %s are the vectors' %d", direction, len(pair.theirs))
		}
		for name, s := range pair.ours {
			want, ok := pair.theirs[name]
			if !ok {
				t.Fatalf("the vectors name no %s %s", direction, name)
			}
			got := specOf(s)
			if !reflect.DeepEqual(got.Fields, want.Fields) || !reflect.DeepEqual(sorted(got.Optional), sorted(want.Optional)) || !reflect.DeepEqual(got.Types, want.Types) {
				t.Fatalf("%s %s is %v, the vectors' %v", direction, name, got, want)
			}
			if _, _, err := ReadLine(want.Example, pair.ours); err != nil {
				t.Fatalf("the example of %s %s reads (%v): %s", direction, name, err, want.Example)
			}
		}
	}
}

func TestTheVectorsLinesReadAsTheySay(t *testing.T) {
	v := loadWireVectors(t)
	of := map[string]map[string]Spec{"holder": Commands, "driver": Events}
	for _, c := range v.Read {
		_, members, err := ReadLine([]byte(c.Line), of[c.From])
		if err != nil {
			t.Fatalf("%s: %v", c.Name, err)
		}
		got := map[string]any{}
		for name, raw := range members {
			var value any
			_ = json.Unmarshal(raw, &value)
			got[name] = value
		}
		if !reflect.DeepEqual(got, c.Reads) {
			t.Fatalf("%s reads as %v, the vectors say %v", c.Name, got, c.Reads)
		}
	}
	reasons := map[string]error{"unreadable": ErrUnreadable, "unknown": ErrUnknown, "too_large": ErrTooLarge}
	for _, c := range v.Refuse {
		line := []byte(c.Line)
		if c.LineBytes > 0 {
			prefix := `{"t":"said","gen":0,"message":"m","text":"`
			line = []byte(prefix + strings.Repeat("x", c.LineBytes-len(prefix)-2) + `"}`)
			if len(line) != c.LineBytes {
				t.Fatalf("%s is %d bytes", c.Name, len(line))
			}
		}
		if _, _, err := ReadLine(line, of[c.From]); !errors.Is(err, reasons[c.Reason]) {
			t.Fatalf("%s is refused %s: %v", c.Name, c.Reason, err)
		}
	}
}

func TestEveryEventTheDriverWritesReadsAsTheWires(t *testing.T) {
	// encodeEvent holds an event to the wire before it is written: one it
	// does not read is never written.
	if _, err := EncodeEvent(NewEvent("own").Set("gen", 0).Set("name", "Bash").Set("phase", "running")); err == nil {
		t.Fatal("an event the wire does not read is not encoded")
	}
	line, err := EncodeEvent(NewEvent("accepted").Set("id", "p<1>&"))
	if err != nil || string(line) != `{"t":"accepted","id":"p<1>&"}` {
		t.Fatalf("an event is written in its members' order, unescaped: %s %v", line, err)
	}
}

// builtTool is a vector's tool: its description, when the vector names
// [text, times], that text so many times, and pad letters y as its
// parameters' description.
func builtTool(t *testing.T, tool map[string]any, description []any, pad int) map[string]any {
	t.Helper()
	raw, _ := json.Marshal(tool)
	built := map[string]any{}
	if err := json.Unmarshal(raw, &built); err != nil {
		t.Fatal(err)
	}
	if len(description) == 2 {
		built["description"] = strings.Repeat(description[0].(string), int(description[1].(float64)))
	}
	if pad > 0 {
		built["parameters"].(map[string]any)["description"] = strings.Repeat("y", pad)
	}
	return built
}

func TestEachToolAndListTheVectorsMeasureIsCarriedAsTheySay(t *testing.T) {
	v := loadWireVectors(t)
	if v.Tools.MaxDescription != MaxDescription || v.Tools.MaxStubArgument != MaxStubArgument ||
		v.Tools.MaxToolsBytes != MaxToolsBytes || !reflect.DeepEqual(v.Tools.Uncarried, uncarried) {
		t.Fatalf("the tools' bounds are the vectors': %+v", v.Tools)
	}
	for _, c := range v.Tools.Cases {
		raw, _ := Marshal(builtTool(t, c.Tool, c.Description, c.Pad))
		var tool Tool
		if err := json.Unmarshal(raw, &tool); err != nil {
			t.Fatal(err)
		}
		arg, err := StubArgument(tool)
		if err != nil || len(arg) != c.StubArgumentBytes {
			t.Fatalf("%s is %d bytes as the stub's argument, the vectors say %d (%v)", c.Name, len(arg), c.StubArgumentBytes, err)
		}
		if got, err := ToolsBytes([]Tool{tool}); err != nil || got != c.ToolsBytes {
			t.Fatalf("%s takes %d bytes in a list, the vectors say %d (%v)", c.Name, got, c.ToolsBytes, err)
		}
		if Carried(raw) != c.Carried {
			t.Fatalf("%s is carried: %v, the vectors say %v", c.Name, !c.Carried, c.Carried)
		}
		if c.Names != nil {
			got := namedProperties(tool.Parameters)
			if len(got) != 0 || len(*c.Names) != 0 {
				if !reflect.DeepEqual(sorted(got), sorted(*c.Names)) {
					t.Fatalf("%s names %v, the vectors say %v", c.Name, got, *c.Names)
				}
			}
		}
	}
	for _, l := range v.Tools.Lists {
		tools := make([]Tool, 0, len(l.Pads))
		for _, pad := range l.Pads {
			raw, _ := Marshal(builtTool(t, map[string]any{"name": "t", "description": "", "parameters": map[string]any{}}, nil, pad))
			var tool Tool
			if err := json.Unmarshal(raw, &tool); err != nil || !Carried(raw) {
				t.Fatalf("%s: each tool is carried (%v)", l.Name, err)
			}
			tools = append(tools, tool)
		}
		if got, err := ToolsBytes(tools); err != nil || got != l.ToolsBytes || (got <= MaxToolsBytes) != l.Fits {
			t.Fatalf("%s take %d bytes, the vectors say %d, fitting %v (%v)", l.Name, got, l.ToolsBytes, l.Fits, err)
		}
	}
}

func TestADetailIsCutBetweenCharactersToItsBound(t *testing.T) {
	short := "ls -l notes"
	if Detail(short) != short {
		t.Fatalf("a detail within its bound is the text: %q", Detail(short))
	}
	// 2047 bytes of x and a character of three: the bound falls inside it.
	text := strings.Repeat("x", MaxDetailBytes-1) + "€" + "tail"
	got := Detail(text)
	if got != strings.Repeat("x", MaxDetailBytes-1) || !utf8.ValidString(got) {
		t.Fatalf("a detail past its bound is cut before the character the bound falls in: %d bytes", len(got))
	}
	at := strings.Repeat("é", MaxDetailBytes/2)
	if Detail(at) != at || Detail(at+"x") != at {
		t.Fatal("a detail of two-byte characters at its bound is whole, and one byte past it is cut back to it")
	}
	if !utf8.ValidString(Detail("a\xffb")) {
		t.Fatal("a detail is UTF-8")
	}
	line, err := EncodeEvent(NewEvent("own").Set("gen", 0).Set("call", "c").Set("name", "edit").Set("phase", "end").Set("detail", Detail(text+text)))
	if err != nil || len(line) == 0 {
		t.Fatalf("a cut detail reads: %v", err)
	}
}

func TestACallIsTheHarnesssIdOrOneDerivedFromIt(t *testing.T) {
	cursor := "call-0734ac1a-0\nfc_ee1556ff_0"
	if CallID(cursor) != cursor {
		t.Fatal("an id the wire takes, a newline in it, is carried as written")
	}
	long := strings.Repeat("a", MaxIDBytes+1)
	if got := CallID(long); !IsID(got) || got != CallID(long) || got == CallID(long+"b") {
		t.Fatalf("an id past the wire's bound is carried as one derived from it, the same for the same id: %q", got)
	}
}

func TestADetailSaysWhatARunDoesOrDid(t *testing.T) {
	if got := InputDetail(json.RawMessage(`{"CommandLine":"ls -l","Path":"/w","toolSummary":"List"}`), "CommandLine", "Path"); got != "ls -l" {
		t.Fatalf("an input naming a command where the program puts one is its command: %q", got)
	}
	if got := InputDetail(json.RawMessage(`{"Path":"/w/a.txt","Target":"x"}`), "CommandLine", "Path"); got != "/w/a.txt" {
		t.Fatalf("else it is what the run acts on: %q", got)
	}
	if got := InputDetail(json.RawMessage(`{ "pattern": "x" }`), "CommandLine", "Path"); got != `{"pattern":"x"}` {
		t.Fatalf("any other input is its compact JSON: %q", got)
	}
	if InputDetail(json.RawMessage(`{}`), "command", "") != "" || InputDetail(nil, "command", "") != "" || InputDetail(json.RawMessage(`"x"`), "command", "") != "" {
		t.Fatal("an empty input, or none, is no detail")
	}
	got := ChangeDetail([]Change{{"/w/a.txt", "alpha\nbeta\ngamma\n", "alpha\nBETA\ngamma\n"}, {"/w/new.txt", "", "hello\n"}})
	if got != "/w/a.txt\n-beta\n+BETA\n/w/new.txt\n+hello" {
		t.Fatalf("a change is its path and the lines that differ: %q", got)
	}
	if got := ChangeDetail([]Change{{"/w/n.txt", "", "x"}}); got != "/w/n.txt\n+x" {
		t.Fatalf("a new file's change is its lines, all new: %q", got)
	}
	if got := ChangeDetail([]Change{{"/w/big.txt", "", strings.Repeat("€", MaxDetailBytes)}}); len(got) > MaxDetailBytes || !utf8.ValidString(got) {
		t.Fatalf("a change past the bound is cut between characters: %d bytes", len(got))
	}
}
