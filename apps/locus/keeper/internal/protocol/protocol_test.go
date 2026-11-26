// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package protocol

import (
	"bytes"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"testing"

	"github.com/cyfr/locus/keeper/internal/admission"
	"github.com/cyfr/locus/keeper/internal/frame"
)

type frameVector struct {
	Stream     byte   `json:"stream"`
	PayloadHex string `json:"payload_hex"`
	EncodedHex string `json:"encoded_hex"`
}

type vectors struct {
	ReservedEnvPrefixes []string `json:"reserved_env_prefixes"`
	ReservedEnv         []string `json:"reserved_env"`
	Signals             []string `json:"signals"`
	Bounds              struct {
		MaxFramePayloadBytes int `json:"max_frame_payload_bytes"`
		MaxLineBytes         int `json:"max_line_bytes"`
	} `json:"bounds"`
	RequestBounds map[string]uint64 `json:"request_bounds"`
	Rlimits       map[string]struct {
		Least uint64 `json:"least"`
		Most  uint64 `json:"most"`
	} `json:"rlimits"`
	KeptUnbounded   []string          `json:"kept_unbounded_rlimits"`
	Frames          []frameVector     `json:"frames"`
	ControlFrames   []frameVector     `json:"control_frames"`
	RelayFrames     []frameVector     `json:"relay_frames"`
	ValidRequests   []json.RawMessage `json:"valid_requests"`
	InvalidRequests []struct {
		Why     string          `json:"why"`
		Code    string          `json:"code"`
		ID      string          `json:"id"`
		SpawnID string          `json:"spawn_id"`
		Request json.RawMessage `json:"request"`
	} `json:"invalid_requests"`
	Replies       []json.RawMessage `json:"replies"`
	HomeRequests  []json.RawMessage `json:"home_requests"`
	HomeReplies   []json.RawMessage `json:"home_replies"`
	PacksRequests []json.RawMessage `json:"packs_requests"`
	PacksReplies  []json.RawMessage `json:"packs_replies"`
}

func loadVectors(t *testing.T) vectors {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("..", "..", "..", "..", "..", "tests", "fixtures", "keeper_protocol.json"))
	if err != nil {
		t.Fatal(err)
	}
	var v vectors
	if err := json.Unmarshal(data, &v); err != nil {
		t.Fatal(err)
	}
	return v
}

// The frame and line bounds are each side's own constants; the vectors pin
// both sides to the same numbers.
func TestSharedBounds(t *testing.T) {
	v := loadVectors(t)
	if v.Bounds.MaxFramePayloadBytes != frame.MaxPayload {
		t.Fatalf("frame.MaxPayload is %d, the vectors pin %d", frame.MaxPayload, v.Bounds.MaxFramePayloadBytes)
	}
	if v.Bounds.MaxLineBytes != MaxLineBytes {
		t.Fatalf("MaxLineBytes is %d, the vectors pin %d", MaxLineBytes, v.Bounds.MaxLineBytes)
	}
}

func TestSharedFrameVectors(t *testing.T) {
	scratch := make([]byte, frame.MaxPayload)
	v := loadVectors(t)
	if len(v.ControlFrames) == 0 {
		t.Fatal("no control frame vectors")
	}
	for _, f := range v.ControlFrames {
		if f.Stream != frame.StreamControl {
			t.Fatalf("control frame vector on stream %d, want %d", f.Stream, frame.StreamControl)
		}
	}
	if len(v.RelayFrames) == 0 {
		t.Fatal("no relay frame vectors")
	}
	for _, f := range v.RelayFrames {
		if f.Stream != frame.StreamRelay {
			t.Fatalf("relay frame vector on stream %d, want %d", f.Stream, frame.StreamRelay)
		}
	}
	for _, f := range append(append(v.Frames, v.ControlFrames...), v.RelayFrames...) {
		payload, _ := hex.DecodeString(f.PayloadHex)
		encoded, err := frame.Append(nil, f.Stream, payload)
		if err != nil {
			t.Fatal(err)
		}
		if got := hex.EncodeToString(encoded); got != f.EncodedHex {
			t.Errorf("stream %d: encoded %s, want %s", f.Stream, got, f.EncodedHex)
		}
		stream, decoded, err := frame.Read(bytes.NewReader(encoded), scratch)
		if err != nil || stream != f.Stream || !bytes.Equal(decoded, payload) {
			t.Errorf("stream %d: decoded %d %x %v", f.Stream, stream, decoded, err)
		}
	}
}

// The request ceilings, the signals, the reserved names and the rlimits
// are each side's own; the vectors pin both sides to the same ones.
func TestSharedRequestBounds(t *testing.T) {
	v := loadVectors(t)
	want := map[string]uint64{
		"max_args":              MaxArgs,
		"max_env":               MaxEnv,
		"max_value_bytes":       MaxValueBytes,
		"max_spec_bytes":        MaxSpecBytes,
		"max_grace_ms":          MaxGraceMs,
		"max_socket_path_bytes": MaxSocketPath,
		"max_home_bytes":        MaxHomeBytes,
		"max_athanor_bytes":     MaxAthanorBytes,
		"max_hosts":             MaxHosts,
		"max_pty_size":          MaxPtySize,
		"max_pack_part_bytes":   MaxPackPartBytes,
		"max_pack_seq":          MaxPackSeq,
	}
	if !reflect.DeepEqual(v.RequestBounds, want) {
		t.Fatalf("the request bounds are %v, the vectors pin %v", want, v.RequestBounds)
	}
	if !reflect.DeepEqual(Signals, v.Signals) {
		t.Fatalf("Signals = %q, the vectors say %q", Signals, v.Signals)
	}
	if !reflect.DeepEqual(ReservedEnv, v.ReservedEnv) {
		t.Fatalf("ReservedEnv = %q, the vectors say %q", ReservedEnv, v.ReservedEnv)
	}
	limits := map[string][2]uint64{
		"nofile": {Floors.Nofile, Ceilings.Nofile},
		"nproc":  {Floors.Nproc, Ceilings.Nproc},
		"core":   {Floors.Core, Ceilings.Core},
		"fsize":  {Floors.Fsize, Ceilings.Fsize},
	}
	if len(v.Rlimits) != len(limits) {
		t.Fatalf("the vectors pin the rlimits %v, the keeper has %v", v.Rlimits, limits)
	}
	for name, r := range v.Rlimits {
		if got, ok := limits[name]; !ok || got != [2]uint64{r.Least, r.Most} {
			t.Fatalf("rlimits.%s is %v here, the vectors pin %d..%d", name, got, r.Least, r.Most)
		}
	}
	if !slices.Equal(v.KeptUnbounded, KeptUnbounded) {
		t.Fatalf("KeptUnbounded = %q, the vectors say %q", KeptUnbounded, v.KeptUnbounded)
	}
}

func TestReservedEnvPrefixesAreTheSharedList(t *testing.T) {
	shared := loadVectors(t).ReservedEnvPrefixes
	if len(shared) == 0 {
		t.Fatal("no reserved_env_prefixes in the vectors")
	}
	if !reflect.DeepEqual(ReservedEnvPrefixes, shared) {
		t.Fatalf("ReservedEnvPrefixes = %q, the vectors say %q", ReservedEnvPrefixes, shared)
	}
	// A spawn can never name the channel variable its client is given.
	if err := ValidateEnvName(ChannelEnv); err == nil {
		t.Fatalf("%s is not reserved", ChannelEnv)
	}
}

func TestSharedValidRequestsParse(t *testing.T) {
	for _, raw := range loadVectors(t).ValidRequests {
		if _, err := ParseRequest(raw); err != nil {
			t.Errorf("%s: refused: %v", raw, err)
		}
	}
}

// The keeper accepts every home request as valid: a kept spawn, a pty
// spawn, the four home requests and a home list with and without after.
func TestSharedHomeRequestsParse(t *testing.T) {
	requests := loadVectors(t).HomeRequests
	types := map[string]int{}
	for _, raw := range requests {
		req, err := ParseRequest(raw)
		if err != nil {
			t.Errorf("%s: refused: %v", raw, err)
			continue
		}
		types[req.Type]++
	}
	want := map[string]int{TypeSpawn: 2, TypeHomeMake: 1, TypeHomeMeasure: 1, TypeHomeRetire: 1, TypeHomeReset: 1, TypeHomeList: 2}
	if !reflect.DeepEqual(types, want) {
		t.Fatalf("vectors: request types %v, want %v", types, want)
	}
}

// A kept spawn's home fields and a spawn's pty size are decoded; a spawn
// that names scratch and no pty is today's spawn.
func TestHomeFieldsAreDecoded(t *testing.T) {
	v := loadVectors(t)
	kept, err := ParseRequest(v.HomeRequests[0])
	if err != nil {
		t.Fatal(err)
	}
	if kept.HomeMode != HomeKept || kept.Home != "0f1e2d3c4b5a69788796a5b4c3d2e1f0" ||
		kept.HomeMaxBytes == nil || *kept.HomeMaxBytes != 1<<30 || kept.Pty != nil {
		t.Fatalf("kept spawn decoded to %+v", kept)
	}
	pty, err := ParseRequest(v.HomeRequests[1])
	if err != nil {
		t.Fatal(err)
	}
	if pty.Pty == nil || pty.Pty.Rows == nil || *pty.Pty.Rows != 40 || pty.Pty.Cols == nil || *pty.Pty.Cols != 120 || pty.HomeMode != "" {
		t.Fatalf("pty spawn decoded to %+v", pty)
	}
	home, err := ParseRequest(v.HomeRequests[2])
	if err != nil {
		t.Fatal(err)
	}
	if home.Type != TypeHomeMake || home.ID != "22" || home.Home != kept.Home {
		t.Fatalf("home_make decoded to %+v", home)
	}
	list, err := ParseRequest(v.HomeRequests[7])
	if err != nil {
		t.Fatal(err)
	}
	if list.Type != TypeHomeList || list.ID != "27" || list.After.ID() != kept.Home {
		t.Fatalf("home_list decoded to %+v", list)
	}
	var scratch int
	for _, raw := range v.ValidRequests {
		req, err := ParseRequest(raw)
		if err != nil {
			t.Fatal(err)
		}
		if req.HomeMode == HomeScratch && req.Pty == nil {
			scratch++
		}
	}
	if scratch == 0 {
		t.Fatal("no valid spawn names home_mode scratch and no pty")
	}
}

// The home requests carry only their own members, and a kept home's id
// holds its grammar at both ends.
func TestHomeRequestBounds(t *testing.T) {
	longest := strings.Repeat("a", 64)
	for _, c := range []struct {
		line string
		ok   bool
	}{
		{`{"v":8,"type":"home_retire","id":"1","home":"vlt_a-1"}`, true},
		{`{"v":8,"type":"home_reset","id":"1","home":"` + longest + `"}`, true},
		{`{"v":8,"type":"home_reset","id":"1","home":"` + longest + `a"}`, false},
		{`{"v":8,"type":"home_retire","id":"1","home":"_a"}`, false},
		{`{"v":8,"type":"home_retire","id":"1","home":"a.b"}`, false},
		{`{"v":8,"type":"home_retire","id":"1","home":""}`, false},
		{`{"v":8,"type":"home_retire","id":"1"}`, false},
		{`{"v":8,"type":"home_retire","id":"1","home":"k","pool":"backends"}`, false},
		{`{"v":8,"type":"home_retire","id":"1","home":"k","home_mode":"kept"}`, false},
		{`{"v":8,"type":"home_retire","id":"1","home":"k","uid":1}`, false},
		{`{"v":8,"type":"home_make","home":"k"}`, false},
		{`{"v":8,"type":"home_list","id":"1"}`, true},
		{`{"v":8,"type":"home_list","id":"1","after":"k"}`, true},
		{`{"v":8,"type":"home_list","id":"1","after":""}`, false},
		{`{"v":8,"type":"home_list","id":"1","after":"k","home":"k"}`, false},
		{`{"v":8,"type":"pool","id":"1","pool":"backends","home":"k"}`, false},
		{`{"v":8,"type":"pool","id":"1","pool":"backends","pty":{"rows":24,"cols":80}}`, false},
	} {
		req, err := ParseRequest([]byte(c.line))
		if c.ok != (err == nil) {
			t.Errorf("%s: request %+v, refusal %+v", c.line, req, err)
		}
	}
	spawn := `{"v":8,"type":"spawn","id":"1","place":"pl-1","pool":"backends","argv":["x"],"attach":{"path":"/run/a.sock","token":"` + strings.Repeat("a", 64) + `"}`
	for _, c := range []struct {
		fields string
		ok     bool
	}{
		{``, true},
		{`,"home_mode":"scratch"`, true},
		{`,"pty":{"rows":1,"cols":1000}`, true},
		{`,"pty":{"rows":1000,"cols":1}`, true},
		{`,"pty":{}`, false},
		{`,"pty":{"rows":-1,"cols":80}`, false},
		{`,"home_mode":"kept","home":"k","home_max_bytes":1125899906842624`, true},
		{`,"home_mode":"kept","home":"k","home_max_bytes":1125899906842625`, false},
		{`,"home_mode":"kept","home":"/var/lib/locus/kept/k"`, false},
		{`,"home_mode":"kept"`, false},
		{`,"home_mode":"scratch","home":"k"`, false},
		{`,"home_mode":"scratch","home_max_bytes":1`, false},
	} {
		req, err := ParseRequest([]byte(spawn + c.fields + "}"))
		if c.ok != (err == nil) {
			t.Errorf("spawn with %s: request %+v, refusal %+v", c.fields, req, err)
		}
	}
}

// A full page of the longest kept home ids fits one frame's payload.
func TestAPageOfHomesFitsAFrame(t *testing.T) {
	ids := make([]string, MaxHomeListIDs)
	for i := range ids {
		ids[i] = strings.Repeat("a", 60) + fmt.Sprintf("%04d", i)
	}
	line, err := Encode(NewHomes(strings.Repeat("i", 64), ids, ids[len(ids)-1]))
	if err != nil {
		t.Fatal(err)
	}
	if len(line) > frame.MaxPayload {
		t.Fatalf("a full page of homes is %d bytes, past a frame's %d", len(line), frame.MaxPayload)
	}
	if empty, _ := Encode(NewHomes("1", nil, "")); string(empty) != `{"v":8,"type":"homes","id":"1","ids":[]}`+"\n" {
		t.Fatalf("an empty page is %s", empty)
	}
}

func TestSharedInvalidRequestsAreRefusedWithTheirCode(t *testing.T) {
	for _, c := range loadVectors(t).InvalidRequests {
		_, err := ParseRequest(c.Request)
		if err == nil {
			t.Errorf("%s: accepted", c.Why)
			continue
		}
		reply := err.Reply()
		if reply.Code != c.Code || reply.ID != c.ID || reply.SpawnID != c.SpawnID {
			t.Errorf("%s: reply %+v, want code %s id %q spawn_id %q", c.Why, reply, c.Code, c.ID, c.SpawnID)
		}
	}
}

func TestSharedRepliesMatchTheEncoders(t *testing.T) {
	code, signal := 1, "SIGKILL"
	atCap, byMachine, byEither := MemoryCap, MemoryMachine, MemoryEither
	built := []any{
		NewSpawned("7", "00112233445566778899aabbccddeeff", 20007, 41),
		NewError("8", "", CodeCapacity),
		NewError("8", "00112233445566778899aabbccddeeff", CodeExecFailed),
		NewError("", "00112233445566778899aabbccddeeff", CodeUnknownSpawn),
		NewExited("00112233445566778899aabbccddeeff", &code, nil, nil),
		NewExited("00112233445566778899aabbccddeeff", nil, &signal, nil),
		NewReleased("00112233445566778899aabbccddeeff"),
		NewPoolReply("9", "backends", 32, 30, 1),
		NewExited("00112233445566778899aabbccddeeff", nil, &signal, &atCap),
		NewError("12", "", CodeMemoryUnavailable),
		NewError("31", "", CodeHostsUnresolved),
		NewError("31", "", CodeGuardUnavailable),
		NewExited("00112233445566778899aabbccddeeff", nil, &signal, &byMachine),
		NewPlaced("pl-1", 384<<20),
		NewAssigned("as-1"),
		NewMeasured("26", Whose{Kind: KindBuild, Athanor: "family@example"}, Reading{Bytes: 1 << 20}, 3),
		NewError("pl-1", "", CodeBadRequest),
		NewMeasured("25", Whose{Kind: KindProgram, Athanor: "ath_01a09fee-2c3d-7e4f-8a5b-6c7d8e9f0a1b", Subject: "mcp_01a09fee-2c3d-7e4f-8a5b-6c7d8e9f0a1c"}, Reading{Bytes: 256 << 20}, 412),
		NewMeasured("25", Whose{Kind: KindWarm}, Reading{Bytes: 192 << 20, Lesser: true}, 0),
		NewReported("rp-1", Report{Boot: "5f0c3a9e1b7d4c2a8e6f0b3d5a7c9e1f", Budget: 5888 << 20, Work: 4832 << 20, Floor: 164 << 20, Used: 640 << 20,
			Counters: []Counter{
				{Rev: 7, Day: "2026-11-27", Athanor: "ath_01a09fee-2c3d-7e4f-8a5b-6c7d8e9f0a1b", Kind: KindProgram, Subject: "mcp_01a09fee-2c3d-7e4f-8a5b-6c7d8e9f0a1c",
					Bytes: 256 << 20, MiBMs: 512_000, MeasuredMs: 2000, PeakBytes: 288 << 20, Machine: 1},
				{Rev: 9, Day: "2026-11-26", Athanor: "ath_01a09fee-2c3d-7e4f-8a5b-6c7d8e9f0a1b", Kind: KindTerminal, Subject: "mcp_01a09fee-2c3d-7e4f-8a5b-6c7d8e9f0a1c", Cap: 1},
			},
			Next: 9}),
		NewReported("rp-2", Report{Boot: "5f0c3a9e1b7d4c2a8e6f0b3d5a7c9e1f",
			Counters: []Counter{{Rev: 1, Day: "2026-11-27", Kind: KindWarm, Bytes: 192 << 20, MiBMs: 384, MeasuredMs: 2, PeakBytes: 192 << 20}}}),
		NewReported("rp-3", Report{Boot: "5f0c3a9e1b7d4c2a8e6f0b3d5a7c9e1f", Budget: 5888 << 20, Work: 4832 << 20}),
		NewError("25", "", CodeUnmeasured),
		NewExited("00112233445566778899aabbccddeeff", nil, &signal, &byEither),
		NewPlaced("pl-5", 2416<<20),
		NewNoMemory("pl-3", Held{Need: 800 << 20, Free: 256 << 20,
			Mine:   []Holding{{Kind: KindProgram, Subject: "mcp_one", Bytes: 384 << 20}, {Kind: KindRun, Bytes: 144 << 20}},
			Others: 1536 << 20}),
		NewNoMemory("pl-4", Held{Need: 800 << 20}),
		NewGiveWay("pl-2"),
	}
	want := loadVectors(t).Replies
	if len(want) != len(built) {
		t.Fatalf("%d vectors for %d encoders", len(want), len(built))
	}
	for i, reply := range built {
		line, err := Encode(reply)
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.HasSuffix(line, []byte("\n")) || bytes.Count(line, []byte("\n")) != 1 {
			t.Fatalf("reply %d is not one line: %q", i, line)
		}
		var got, expected map[string]any
		_ = json.Unmarshal(line, &got)
		_ = json.Unmarshal(want[i], &expected)
		if !reflect.DeepEqual(got, expected) {
			t.Errorf("reply %d = %s, want %s", i, line, want[i])
		}
	}
}

// A report's after is a whole number, decoded as its rev, and a
// home_list's a string, decoded as its id: neither takes the other's.
func TestAReportsAfterIsARev(t *testing.T) {
	var revs []uint64
	for _, raw := range loadVectors(t).ValidRequests {
		req, err := ParseRequest(raw)
		if err != nil {
			t.Fatal(err)
		}
		if req.Type != TypeReport {
			continue
		}
		rev, ok := req.After.Rev()
		if !ok || req.After.ID() != "" {
			t.Fatalf("a report's after decoded to %+v", req.After)
		}
		revs = append(revs, rev)
	}
	if !slices.Equal(revs, []uint64{0, MaxRev}) {
		t.Fatalf("the vectors' reports are after %v", revs)
	}
	for _, line := range []string{
		`{"v":8,"type":"report","id":"r","after":1.0}`,
		`{"v":8,"type":"report","id":"r","after":1e3}`,
		`{"v":8,"type":"report","id":"r","after":true}`,
		`{"v":8,"type":"report","id":"r","after":null}`,
		`{"v":8,"type":"home_list","id":"r","after":{"id":"k"}}`,
	} {
		if _, err := ParseRequest([]byte(line)); err == nil || err.Reply() != NewError("r", "", CodeBadRequest) {
			t.Errorf("%s: refusal %+v", line, err)
		}
	}
}

// A full page of counters of the longest athanors and subjects, every
// number at its most, fits one line of the channel.
func TestAPageOfCountersFitsALine(t *testing.T) {
	most := ^uint64(0)
	page := make([]Counter, admission.ReportCounters)
	for i := range page {
		page[i] = Counter{Rev: MaxRev, Day: "2026-11-27", Athanor: strings.Repeat("a", 256), Kind: KindTerminal, Subject: strings.Repeat("s", 64),
			Bytes: most, MiBMs: most, MeasuredMs: most, PeakBytes: most, Cap: most, Machine: most, Either: most}
	}
	line, err := Encode(NewReported(strings.Repeat("i", 64), Report{Boot: strings.Repeat("b", 32), Budget: most, Work: most, Floor: most,
		Used: most, Counters: page, Next: MaxRev}))
	if err != nil {
		t.Fatal(err)
	}
	if len(line) > MaxLineBytes {
		t.Fatalf("a full page of counters is %d bytes, past a line's %d", len(line), MaxLineBytes)
	}
}

// The keeper accepts every packs request: a hold, a put's first and last
// parts, their parts decoded, and a kept spawn naming its generation.
func TestSharedPacksRequestsParse(t *testing.T) {
	var parts [][]byte
	var spawn *Request
	for _, raw := range loadVectors(t).PacksRequests {
		req, err := ParseRequest(raw)
		if err != nil {
			t.Fatalf("%s: refused: %v", raw, err)
		}
		switch req.Type {
		case TypePacksPut:
			parts = append(parts, req.Part())
		case TypeSpawn:
			spawn = req
		}
	}
	if len(parts) != 2 || string(parts[0]) != "hello" || len(parts[1]) != 0 {
		t.Fatalf("parts %q", parts)
	}
	if spawn == nil || spawn.Packs == nil || spawn.Packs.Digest != "sha256:"+strings.Repeat("0123456789abcdef", 4) {
		t.Fatalf("the spawn's packs: %+v", spawn)
	}
}

func TestSharedPacksRepliesMatchTheEncoders(t *testing.T) {
	built := []any{
		NewPacksReply("40", PacksHeld),
		NewPacksReply("40", PacksMissing),
		NewPacksReply("41", PacksTaken),
		NewPacksReply("42", PacksHeld),
		NewError("42", "", CodePacksRefused),
		NewError("40", "", CodeUnavailable),
		NewError("41", "", CodePacksBusy),
	}
	want := loadVectors(t).PacksReplies
	if len(want) != len(built) {
		t.Fatalf("%d vectors for %d encoders", len(want), len(built))
	}
	for i, reply := range built {
		line, err := Encode(reply)
		if err != nil {
			t.Fatal(err)
		}
		var got, expected map[string]any
		_ = json.Unmarshal(line, &got)
		_ = json.Unmarshal(want[i], &expected)
		if !reflect.DeepEqual(got, expected) {
			t.Errorf("packs reply %d = %s, want %s", i, line, want[i])
		}
	}
}

// A put's largest part, in base64, fits one line with room for the rest
// of the request.
func TestAPacksPutsLargestPartFitsALine(t *testing.T) {
	data := base64.StdEncoding.EncodeToString(make([]byte, MaxPackPartBytes))
	line := `{"v":8,"type":"packs_put","id":"` + strings.Repeat("i", 64) + `","athanor":"` + strings.Repeat("a", 256) +
		`","lifetime":"` + strings.Repeat("l", 128) + `","digest":"sha256:` + strings.Repeat("0", 64) + `","seq":65536,"last":true,"data":"` + data + `"}`
	if len(line) > MaxLineBytes {
		t.Fatalf("the largest put is %d bytes, past a line's %d", len(line), MaxLineBytes)
	}
	req, err := ParseRequest([]byte(line))
	if err != nil || len(req.Part()) != MaxPackPartBytes {
		t.Fatalf("%v", err)
	}
	over := base64.StdEncoding.EncodeToString(make([]byte, MaxPackPartBytes+1))
	if _, err := ParseRequest([]byte(strings.Replace(line, data, over, 1))); err == nil {
		t.Fatal("a part past the bound parsed")
	}
}

func TestSharedHomeRepliesMatchTheEncoders(t *testing.T) {
	built := []any{
		NewHomeMade("22", 40001),
		NewHomeMeasured("23", 1<<20),
		NewHomeRetired("24"),
		NewError("20", "", CodeHomeOverCap),
		NewError("21", "", CodeUIDBusy),
		NewHomeMeasured("23", 0),
		NewError("23", "", CodeHomeAbsent),
		NewError("22", "", CodeUnavailable),
		NewHomeMade("25", 40001),
		NewHomes("26", []string{"0f1e2d3c4b5a69788796a5b4c3d2e1f0", "vlt_a"}, "vlt_a"),
		NewHomes("27", nil, ""),
	}
	want := loadVectors(t).HomeReplies
	if len(want) != len(built) {
		t.Fatalf("%d vectors for %d encoders", len(want), len(built))
	}
	for i, reply := range built {
		line, err := Encode(reply)
		if err != nil {
			t.Fatal(err)
		}
		var got, expected map[string]any
		_ = json.Unmarshal(line, &got)
		_ = json.Unmarshal(want[i], &expected)
		if !reflect.DeepEqual(got, expected) {
			t.Errorf("home reply %d = %s, want %s", i, line, want[i])
		}
	}
}

func TestSpawnRequestFieldsAreDecoded(t *testing.T) {
	req, err := ParseRequest(loadVectors(t).ValidRequests[1])
	if err != nil {
		t.Fatal(err)
	}
	if req.Pool != "backends" || !reflect.DeepEqual(req.Argv, []string{"node", "probe.mjs"}) || req.Attach.Path != "/run/locus/attach.sock" {
		t.Fatalf("request %+v", req)
	}
	if got := req.Rlimits.Resolve(); got != (Limits{Nofile: 256, Nproc: 32, Core: 0, Fsize: 1 << 20}) {
		t.Fatalf("limits %+v", got)
	}
}

// A resize names its spawn and the terminal's new size.
func TestResizeIsDecoded(t *testing.T) {
	var resizes int
	for _, raw := range loadVectors(t).ValidRequests {
		req, err := ParseRequest(raw)
		if err != nil {
			t.Fatal(err)
		}
		if req.Type != TypeResize {
			continue
		}
		resizes++
		if req.SpawnID != "00112233445566778899aabbccddeeff" || req.Rows == nil || *req.Rows != 50 || req.Cols == nil || *req.Cols != 132 {
			t.Fatalf("resize decoded to %+v", req)
		}
	}
	if resizes != 1 {
		t.Fatalf("%d valid resizes in the vectors, want 1", resizes)
	}
}

func TestControlIsDecodedAndDefaultsToNone(t *testing.T) {
	v := loadVectors(t)
	var withControl, without, plain int
	for _, raw := range v.ValidRequests {
		req, err := ParseRequest(raw)
		if err != nil {
			t.Fatal(err)
		}
		if req.Type != TypeSpawn {
			continue
		}
		switch {
		case req.Control:
			withControl++
			if req.Pool != "runner" || req.Env["RUNTIME_ROLE"] != "runner" {
				t.Fatalf("the runner vector decoded to %+v", req)
			}
		case bytes.Contains(raw, []byte(`"control"`)):
			without++
		default:
			plain++
		}
	}
	if withControl == 0 || without == 0 || plain == 0 {
		t.Fatalf("vectors: %d with control, %d with control false, %d without the field", withControl, without, plain)
	}
}

// A spawn names no bound of its own, whatever its pool: the keeper sets
// its memory and processors by its place's kind, so one naming either is
// refused, and a session's place carries its athanor's ceiling.
func TestASpawnNamesNoBound(t *testing.T) {
	for _, pool := range []string{"build", "backends", "runner"} {
		for member, value := range map[string]any{"memory_bytes": 1 << 30, "cpu_quota": 100_000} {
			message := map[string]any{
				"v": Version, "type": TypeSpawn, "id": "bound-check", "place": "pl-1", "pool": pool,
				"argv": []string{"true"}, "env": map[string]string{}, member: value,
				"attach": Attach{Path: "/run/a.sock", Token: strings.Repeat("a", 64)},
			}
			line, err := json.Marshal(message)
			if err != nil {
				t.Fatal(err)
			}
			req, refused := ParseRequest(line)
			// An unknown member is refused before any id is read.
			if req != nil || refused == nil || refused.Reply() != NewError("", "", CodeBadRequest) {
				t.Errorf("%s spawn naming %s: request %+v, refusal %+v", pool, member, req, refused)
			}
		}
	}
	req, refused := ParseRequest([]byte(`{"v":8,"type":"place","id":"pl-5","kind":"terminal","athanor":"ath_one","athanor_max_bytes":2147483648}`))
	if refused != nil || req.AthanorMax == nil || *req.AthanorMax != 2<<30 {
		t.Fatalf("a session's place with its athanor's ceiling: %+v, %+v", req, refused)
	}
}

func TestAKeptSpawnTakesNoFileSizeLimitUnlessItAsks(t *testing.T) {
	var none *Rlimits
	kept := none.ResolveKept()
	if kept.Fsize != Unlimited || kept.Nofile != Ceilings.Nofile || kept.Nproc != Ceilings.Nproc {
		t.Fatalf("a kept spawn's defaults %+v", kept)
	}
	fsize := uint64(1 << 20)
	if got := (&Rlimits{Fsize: &fsize}).ResolveKept(); got.Fsize != 1<<20 {
		t.Fatalf("a kept spawn's own fsize is %d", got.Fsize)
	}
	nproc := uint64(8)
	if got := (&Rlimits{Nproc: &nproc}).ResolveKept(); got.Fsize != Unlimited || got.Nproc != 8 {
		t.Fatalf("a kept spawn lowering nproc alone: %+v", got)
	}
	if none.Resolve().Fsize != Ceilings.Fsize {
		t.Fatal("a scratch spawn lost its file-size ceiling")
	}
}

func TestRlimitsDefaultToTheCeilings(t *testing.T) {
	var none *Rlimits
	if none.Resolve() != Ceilings {
		t.Fatal("absent rlimits do not resolve to the ceilings")
	}
	if Ceilings != (Limits{Nofile: 1024, Nproc: 1024, Core: 0, Fsize: 256 << 20}) {
		t.Fatalf("ceilings %+v", Ceilings)
	}
	nproc := uint64(8)
	if got := (&Rlimits{Nproc: &nproc}).Resolve(); got.Nproc != 8 || got.Nofile != 1024 {
		t.Fatalf("partial override %+v", got)
	}
}

func TestMalformedJSONIsRefusedWithoutEchoingInput(t *testing.T) {
	for _, line := range []string{
		`not json`,
		`{"v":8,"type":"pool","id":"1","pool":"backends"} {"v":2}`,
		`{"v":8,"type":"spawn","id":"1","pool":"backends","argv":"secret-value"}`,
		`[]`,
		``,
	} {
		_, err := ParseRequest([]byte(line))
		if err == nil {
			t.Errorf("%q accepted", line)
			continue
		}
		if err.Code != CodeBadRequest {
			t.Errorf("%q: code %s", line, err.Code)
		}
		if strings.Contains(err.Detail, "secret-value") {
			t.Errorf("%q: detail echoes the input: %s", line, err.Detail)
		}
	}
}

func TestEnvValueNeverAppearsInARefusal(t *testing.T) {
	line := `{"v":8,"type":"spawn","id":"1","pool":"backends","argv":["x"],"env":{"TOKEN":"secret-value\u0000"},"memory_bytes":536870912,"attach":{"path":"/run/a.sock","token":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"}}`
	_, err := ParseRequest([]byte(line))
	if err == nil {
		t.Fatal("a NUL in an env value was accepted")
	}
	if strings.Contains(err.Detail, "secret-value") {
		t.Fatalf("detail echoes the value: %s", err.Detail)
	}
}

func TestValidateCommandBounds(t *testing.T) {
	if err := ValidateCommand(make([]string, MaxArgs+1), nil); err == nil {
		t.Error("too many arguments accepted")
	}
	if err := ValidateCommand([]string{""}, nil); err == nil {
		t.Error("empty argv[0] accepted")
	}
	env := map[string]string{}
	for i := 0; i <= MaxEnv; i++ {
		env["V"+strings.Repeat("A", i%100)+string(rune('A'+i%26))+hex.EncodeToString([]byte{byte(i)})] = "x"
	}
	if err := ValidateCommand([]string{"x"}, env); err == nil {
		t.Error("too many variables accepted")
	}
	big := map[string]string{}
	for i := 0; i < 9; i++ {
		big["BIG_"+string(rune('A'+i))] = strings.Repeat("x", MaxValueBytes)
	}
	if err := ValidateCommand([]string{"x"}, big); err == nil {
		t.Error("a command above MaxSpecBytes was accepted")
	}
	if err := ValidateCommand([]string{"x"}, map[string]string{"V": strings.Repeat("x", MaxValueBytes+1)}); err == nil {
		t.Error("an oversize value was accepted")
	}
	for _, name := range []string{"HOME", "TMPDIR", "CYFR_KEY", "LOCUS_BACKENDS_PORT", "1ABC", "", "A-B"} {
		if err := ValidateEnvName(name); err == nil {
			t.Errorf("env name %q accepted", name)
		}
	}
	for _, name := range []string{"GITHUB_TOKEN", "NODE_ENV", "_x", "lower"} {
		if err := ValidateEnvName(name); err != nil {
			t.Errorf("env name %q refused: %v", name, err)
		}
	}
}

func TestLineReaderSplitsAndDiscardsOversizeLines(t *testing.T) {
	long := strings.Repeat("x", MaxLineBytes+1)
	input := "first\n" + long + "\nsecond\n" + strings.Repeat("y", MaxLineBytes) + "\npartial"
	lr := NewLineReader(strings.NewReader(input))

	line, tooLong, err := lr.Next()
	if err != nil || tooLong || string(line) != "first" {
		t.Fatalf("first: %q %v %v", line, tooLong, err)
	}
	line, tooLong, err = lr.Next()
	if err != nil || !tooLong || line != nil {
		t.Fatalf("oversize: %d bytes %v %v", len(line), tooLong, err)
	}
	line, tooLong, err = lr.Next()
	if err != nil || tooLong || string(line) != "second" {
		t.Fatalf("second: %q %v %v", line, tooLong, err)
	}
	line, tooLong, err = lr.Next()
	if err != nil || tooLong || len(line) != MaxLineBytes {
		t.Fatalf("a line of exactly the maximum: %d %v %v", len(line), tooLong, err)
	}
	if _, _, err := lr.Next(); !errors.Is(err, io.EOF) {
		t.Fatalf("end: %v", err)
	}
}
