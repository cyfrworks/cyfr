// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package ops

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestGeneratedArgumentsSupplyActionAndKeepZero(t *testing.T) {
	args := RetentionSetArgs{Settings: RetentionSetArgsSettings{Executions: Value(0)}}
	encoded, err := json.Marshal(args)
	if err != nil {
		t.Fatal(err)
	}
	if string(encoded) != `{"action":"set","settings":{"executions":0}}` {
		t.Fatalf("unexpected request: %s", encoded)
	}
	encoded, err = json.Marshal(ProfileCommitArgs{ExpectedConsentRevision: nil})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(encoded), `"expected_consent_revision":null`) {
		t.Fatalf("required null disappeared: %s", encoded)
	}
}

// Suspend names its turn only when the caller read one; recover always
// names it, because recovery has no "whatever is there now". The
// generated presence follows those declarations: an omitted optional
// disappears, a required one is always sent.
func TestGeneratedTurnArgumentsFollowTheDeclaredPresence(t *testing.T) {
	encoded, err := json.Marshal(TurnSuspendArgs{Reason: Value("stepping away")})
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(encoded), `"turn"`) {
		t.Fatalf("an unnamed turn was sent anyway: %s", encoded)
	}
	if !strings.Contains(string(encoded), `"action":"suspend"`) ||
		!strings.Contains(string(encoded), `"reason":"stepping away"`) {
		t.Fatalf("unexpected request: %s", encoded)
	}

	encoded, err = json.Marshal(TurnRecoverArgs{Thread: "thr_1", Turn: "trn_1"})
	if err != nil {
		t.Fatal(err)
	}
	if string(encoded) != `{"action":"recover","thread":"thr_1","turn":"trn_1"}` {
		t.Fatalf("unexpected request: %s", encoded)
	}

	for _, action := range Actions[Turn] {
		if action != TurnSuspend && action != TurnRecover {
			t.Fatalf("unexpected turn action: %s", action)
		}
	}
}

func TestGeneratedNestedRecordRejectsUnknownAndInvalidPresence(t *testing.T) {
	for _, raw := range []string{
		`{"unknown":1}`,
		`{"Console":true}`,
		`{"console":null}`,
		`{"headers":{"Authorization":null}}`,
		`{"tool_patterns":[null]}`,
		`{"backends":null}`,
		`{"backends":[{"name":"test"}]}`,
		`{"backends":[{"name":"test","command":null}]}`,
		`{"backends":[{"name":"test","command":"run","extra":true}]}`,
	} {
		var config McpServersCreateArgsConfig
		if err := json.Unmarshal([]byte(raw), &config); err == nil {
			t.Fatalf("accepted %s", raw)
		}
	}
	var config McpServersCreateArgsConfig
	raw := `{"console":false,"backends":[{"name":"test","command":"run","env":{"MODE":""}}]}`
	if err := json.Unmarshal([]byte(raw), &config); err != nil {
		t.Fatal(err)
	}
	encoded, err := json.Marshal(config)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(encoded), `"console":false`) || !strings.Contains(string(encoded), `"MODE":""`) {
		t.Fatalf("values were lost: %s", encoded)
	}
}
