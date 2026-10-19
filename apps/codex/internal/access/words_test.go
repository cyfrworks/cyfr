// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package access

import (
	"reflect"
	"strings"
	"testing"
)

func TestWordsVectors(t *testing.T) {
	for _, v := range readVectors(t).Words {
		got := Describe(v.Head).Sentences()
		if !reflect.DeepEqual(got, v.Sentences) {
			t.Errorf("%s: words\n got %q\nwant %q", v.Head.Digest(), got, v.Sentences)
		}
		for _, s := range got {
			for _, term := range []string{"profile", "compose", "caddy", "tailscale_", "CYFR_", "node_id", "<", "%"} {
				if strings.Contains(s, term) {
					t.Errorf("%q names %q", s, term)
				}
			}
		}
	}
}

// A refusal's sentence carries its payload's values and no unfilled part.
func TestSentenceFillsEveryPart(t *testing.T) {
	for _, v := range readVectors(t).Boot {
		if v.Refusal == nil {
			continue
		}
		s := (&Refusal{Code: v.Refusal.Code, Payload: v.Refusal.Payload}).Sentence()
		if s == v.Refusal.Code || strings.Contains(s, "``") || strings.Contains(s, "map[") {
			t.Errorf("%s: %q", v.Name, s)
		}
		for _, value := range v.Refusal.Payload {
			if !strings.Contains(s, value) {
				t.Errorf("%s: %q does not name %q", v.Name, s, value)
			}
		}
	}
}
