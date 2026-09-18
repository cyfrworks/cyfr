// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package protocol

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/cyfr/spawn/internal/frame"
)

type frameVector struct {
	Stream     byte   `json:"stream"`
	PayloadHex string `json:"payload_hex"`
	EncodedHex string `json:"encoded_hex"`
}

type vectors struct {
	Frames          []frameVector     `json:"frames"`
	ControlFrames   []frameVector     `json:"control_frames"`
	ValidRequests   []json.RawMessage `json:"valid_requests"`
	InvalidRequests []struct {
		Why     string          `json:"why"`
		Code    string          `json:"code"`
		ID      string          `json:"id"`
		SpawnID string          `json:"spawn_id"`
		Request json.RawMessage `json:"request"`
	} `json:"invalid_requests"`
	Replies []json.RawMessage `json:"replies"`
}

func loadVectors(t *testing.T) vectors {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("..", "..", "..", "..", "tests", "fixtures", "spawn_protocol.json"))
	if err != nil {
		t.Fatal(err)
	}
	var v vectors
	if err := json.Unmarshal(data, &v); err != nil {
		t.Fatal(err)
	}
	return v
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
	for _, f := range append(v.Frames, v.ControlFrames...) {
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

func TestSharedValidRequestsParse(t *testing.T) {
	for _, raw := range loadVectors(t).ValidRequests {
		if _, err := ParseRequest(raw); err != nil {
			t.Errorf("%s: refused: %v", raw, err)
		}
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
	built := []any{
		NewSpawned("7", "00112233445566778899aabbccddeeff", 20007, 41),
		NewError("8", "", CodeCapacity),
		NewError("", "00112233445566778899aabbccddeeff", CodeUnknownSpawn),
		NewExited("00112233445566778899aabbccddeeff", &code, nil),
		NewExited("00112233445566778899aabbccddeeff", nil, &signal),
		NewReleased("00112233445566778899aabbccddeeff"),
		NewPoolReply("9", "backends", 32, 30, 1),
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

func TestSpawnRequestFieldsAreDecoded(t *testing.T) {
	req, err := ParseRequest(loadVectors(t).ValidRequests[1])
	if err != nil {
		t.Fatal(err)
	}
	if req.Pool != "backends" || !reflect.DeepEqual(req.Argv, []string{"node", "probe.mjs"}) || req.Attach.Path != "/run/cyfr-bridge/attach.sock" {
		t.Fatalf("request %+v", req)
	}
	if got := req.Rlimits.Resolve(); got != (Limits{Nofile: 256, Nproc: 32, Core: 0, Fsize: 1 << 20}) {
		t.Fatalf("limits %+v", got)
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
			if req.Pool != "runner" || req.Env["OPUS_ROLE"] != "runner" {
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

func TestRlimitsDefaultToTheCeilings(t *testing.T) {
	var none *Rlimits
	if none.Resolve() != Ceilings {
		t.Fatal("absent rlimits do not resolve to the ceilings")
	}
	if Ceilings != (Limits{Nofile: 1024, Nproc: 128, Core: 0, Fsize: 256 << 20}) {
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
		`{"v":1,"type":"pool","id":"1","pool":"backends"} {"v":1}`,
		`{"v":1,"type":"spawn","id":"1","pool":"backends","argv":"secret-value"}`,
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
	line := `{"v":1,"type":"spawn","id":"1","pool":"backends","argv":["x"],"env":{"TOKEN":"secret-value\u0000"},"attach":{"path":"/run/a.sock","token":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"}}`
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
	for _, name := range []string{"HOME", "TMPDIR", "CYFR_KEY", "MCP_BRIDGE_PORT", "1ABC", "", "A-B"} {
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
