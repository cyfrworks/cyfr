// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package logx

import (
	"bytes"
	"encoding/json"
	"strconv"
	"strings"
	"testing"
)

func TestTextAndJSONLines(t *testing.T) {
	var text bytes.Buffer
	NewWriter(&text, "cyfr-locus", false).Warn("uid %d quarantined", 20007)
	if text.String() != "[cyfr-locus] warning: uid 20007 quarantined\n" {
		t.Fatalf("text line %q", text.String())
	}

	var js bytes.Buffer
	NewWriter(&js, "cyfr-locus", true).Error("channel %s", "closed")
	var entry map[string]string
	if err := json.Unmarshal(js.Bytes(), &entry); err != nil {
		t.Fatal(err)
	}
	if entry["level"] != "error" || entry["message"] != "channel closed" || entry["service"] != "cyfr-locus" || entry["timestamp"] == "" {
		t.Fatalf("json line %v", entry)
	}
}

// An untrusted word is quoted, so it cannot end a line or forge another,
// and cut to its bound.
func TestAnUntrustedWordIsQuotedAndCut(t *testing.T) {
	forged := "no_room\n[cyfr-locus] error: another person's VM ended"
	if got := Untrusted(forged); strings.ContainsAny(got, "\n\r") || got != strconv.Quote(forged) {
		t.Fatalf("Untrusted(%q) = %q", forged, got)
	}
	long := strings.Repeat("x", 1<<20)
	if got := Untrusted(long); len(got) > UntrustedMax+40 || !strings.HasSuffix(got, "(cut at 64 bytes)") {
		t.Fatalf("a long word is carried as %d bytes: %.80q", len(got), got)
	}
}
