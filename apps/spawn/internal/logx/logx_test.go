// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package logx

import (
	"bytes"
	"encoding/json"
	"testing"
)

func TestTextAndJSONLines(t *testing.T) {
	var text bytes.Buffer
	NewWriter(&text, "cyfr-spawn", false).Warn("uid %d quarantined", 20007)
	if text.String() != "[cyfr-spawn] warning: uid 20007 quarantined\n" {
		t.Fatalf("text line %q", text.String())
	}

	var js bytes.Buffer
	NewWriter(&js, "cyfr-spawn", true).Error("channel %s", "closed")
	var entry map[string]string
	if err := json.Unmarshal(js.Bytes(), &entry); err != nil {
		t.Fatal(err)
	}
	if entry["level"] != "error" || entry["message"] != "channel closed" || entry["service"] != "cyfr-spawn" || entry["timestamp"] == "" {
		t.Fatalf("json line %v", entry)
	}
}
