// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package main

import (
	"bytes"
	"encoding/json"
	"io"
	"net"
	"strings"
	"testing"

	"github.com/cyfr/locus/keeper/internal/brainwire"
	"github.com/cyfr/locus/keeper/internal/toolsock"
)

// A call of one of CYFR's own tools is never an own row and never carries
// a detail, whether the socket took it, refused it or never saw it: it is
// told by what the call is, the server it names being the one CYFR's took
// in the session, as each program shows a call of CYFR's (Antigravity by
// its tool's name, `mcp_<server>_<tool>`, or its call_mcp_tool's
// ServerName; Cursor by its providerIdentifier). Here the gate refuses
// arguments past one line, the program reports the call failed, and
// nothing of the arguments the gate withheld reaches the wire (review
// #1865).
func TestACallOfCYFRsIsNoOwnRowWhateverTheGateDid(t *testing.T) {
	arguments := `{"payload":"GATE-CANARY` + strings.Repeat("x", brainwire.MaxLineBytes) + `"}`
	for _, c := range []struct {
		name    string
		p       *profile
		updates []string
	}{
		{"antigravity's server tool", antigravity, []string{
			`{"sessionUpdate":"tool_call","toolCallId":"c1","name":"mcp_cyfr_files","kind":"other","title":"Run mcp_cyfr_files","status":"in_progress","rawInput":` +
				strings.TrimSuffix(arguments, "}") + `,"toolSummary":"Read it"}}`}},
		{"antigravity's call_mcp_tool", antigravity, []string{
			`{"sessionUpdate":"tool_call","toolCallId":"c1","name":"call_mcp_tool","kind":"execute","title":"MCP Tool files","status":"in_progress","rawInput":{"ServerName":"cyfr","ToolName":"files","Arguments":` + arguments + `}}`}},
		{"cursor's server call", cursor, []string{
			`{"sessionUpdate":"tool_call","toolCallId":"c1\nfc_1","title":"MCP: tool","kind":"other","status":"pending","rawInput":{}}`,
			`{"sessionUpdate":"tool_call_update","toolCallId":"c1\nfc_1","title":"cyfr: files","rawInput":{"providerIdentifier":"cyfr","toolName":"files","args":` + arguments + `}}`,
			`{"sessionUpdate":"tool_call_update","toolCallId":"c1\nfc_1","status":"in_progress"}`}},
	} {
		for _, gate := range []string{"refused", "unseen"} {
			t.Run(c.name+", "+gate, func(t *testing.T) {
				var wire bytes.Buffer
				d := newDriver(c.p, nil, brainwire.NewConn("test", &wire, io.Discard), t.TempDir())
				d.h, d.session, d.server, d.turn = &brainwire.Process{}, "ses", "cyfr", &nativeTurn{work: "trn_1"}
				d.sock = &toolSocket{held: map[string]net.Conn{}}
				update := func(u string) {
					t.Helper()
					line := `{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"ses","update":` + strings.ReplaceAll(u, "\n", `\n`) + `}}`
					if err := d.Line([]byte(line)); err != nil {
						t.Fatal(err)
					}
				}
				for _, u := range c.updates {
					update(u)
				}
				if gate == "refused" {
					peer, server := net.Pipe()
					answered := make(chan []byte, 1)
					go func() { raw, _ := io.ReadAll(peer); answered <- raw }()
					err := d.socketRequest(d.sock, server, toolsock.Request{Op: "call", Name: "files", Arguments: json.RawMessage(arguments)})
					server.Close()
					if answer := <-answered; err != nil || !bytes.Contains(answer, []byte("past what CYFR takes")) {
						t.Fatalf("the gate refuses the call: %s %v", answer, err)
					}
				}
				id := "c1"
				if c.p == cursor {
					id = "c1\nfc_1"
				}
				failed, _ := json.Marshal(map[string]any{"sessionUpdate": "tool_call_update", "toolCallId": id, "status": "failed"})
				update(string(failed))
				if err := d.flushOwn(); err != nil {
					t.Fatal(err)
				}
				if strings.Contains(wire.String(), "GATE-CANARY") || strings.Contains(wire.String(), `"t":"own"`) {
					t.Fatalf("a call of CYFR's is no own row, and nothing of its arguments reaches the wire: %.300s", wire.String())
				}
			})
		}
	}
}

// One call gets one start and one end, ever: Antigravity can leave a call
// pending at a turn's end and complete it in the next prompt (S1 F1 on the
// account path), and the turn's end has ended it already (review #1865).
func TestACallLeftPendingAtATurnsEndIsShownOnce(t *testing.T) {
	s := startDriver(t)
	startFresh(s, map[string]any{})
	postText(s, "stp_1", "trn_1", "pendingcall")
	first := ofType(s.until("idle"), "own")
	postText(s, "stp_2", "trn_2", "pendingdone")
	second := s.until("idle")
	if len(first) != 2 || first[0]["phase"] != "start" || first[1]["phase"] != "end" || first[0]["call"] != "call_pending" ||
		len(ofType(second, "own")) != 0 || saidOf(second) != "I will target PostgreSQL." {
		t.Fatalf("the call is shown once, ended at the first turn's end, and its late updates emit nothing: %v then %v", first, second)
	}
}
