// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package limits

import (
	"encoding/json"
	"strconv"
	"testing"

	"github.com/cyfr/locus/keeper/internal/wire/wirejson"
	"github.com/cyfr/locus/keeper/internal/wire/wiretest"
)

// wireSections are the sections of tests/fixtures/authority_wire.json this test reads.
type wireSections struct {
	Version   json.RawMessage `json:"version"`
	Durations json.RawMessage `json:"durations"`
}

func wireVectors(t *testing.T) wireSections {
	t.Helper()
	var s wireSections
	wiretest.Load(t, "authority_wire.json", &s)
	return s
}

// Every duration reads to the milliseconds Prima.Limits.parse_duration/1
// answers, the vector's own number compared as written, or is refused
// with Prima; one past an int64, which Go does not hold, is the marked
// difference and refused here.
func TestEveryDurationReadsAsPrimaReadsIt(t *testing.T) {
	top := wireVectors(t)
	if string(top.Version) != "1" {
		t.Fatalf("the vector file's version %s", top.Version)
	}
	marked := 0
	for _, raw := range wiretest.Cases(t, top.Durations, 40) {
		var c struct {
			Text string          `json:"text"`
			Ms   json.RawMessage `json:"ms"`
			Go   *struct {
				Ms json.RawMessage `json:"ms"`
			} `json:"go"`
		}
		wiretest.Decode(t, raw, &c, []string{"text", "ms"}, "ms")
		want := c.Ms
		if c.Go != nil {
			marked++
			if string(c.Ms) == "null" || string(c.Go.Ms) != "null" {
				t.Fatalf("%q: a go marker is a duration Prima reads that Go refuses: %s", c.Text, raw)
			}
			want = c.Go.Ms
		}
		ms, ok := Duration(c.Text)
		switch {
		case string(want) == "null":
			if ok {
				t.Errorf("%q reads as %d; refused", c.Text, ms)
			}
		case !ok || strconv.FormatInt(ms, 10) != string(want):
			t.Errorf("%q reads as %d, %v; want %s", c.Text, ms, ok, want)
		}
	}
	if marked == 0 {
		t.Error("no duration is marked past an int64")
	}
	if _, err := Read(wirejson.Number("1")); err == nil {
		t.Error("a number is no limits")
	}
}

// A node's limits read a duration of any size, as Prima does: its grammar
// and sign decide.
func TestATimeoutOfAnySizeReads(t *testing.T) {
	limits := map[string]any{
		"timeout": "99999999999999999999h", "batch_timeout": "-0", "max_memory_bytes": wirejson.Number("1"),
		"max_request_size": wirejson.Number("1"), "max_response_size": wirejson.Number("1"),
		"max_concurrent_tasks": wirejson.Number("1"),
		"rate_limit":           map[string]any{"requests": wirejson.Number("1"), "window": "1m"},
	}
	if _, err := Read(limits); err != nil {
		t.Errorf("refused: %v", err)
	}
	for field, bad := range map[string]string{"timeout": "-1s", "batch_timeout": "1x"} {
		changed := map[string]any{}
		for k, v := range limits {
			changed[k] = v
		}
		changed[field] = bad
		if _, err := Read(changed); err == nil {
			t.Errorf("%s %q read", field, bad)
		}
	}
}
