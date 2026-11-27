// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package limits

import (
	"bytes"
	"encoding/json"
	"math/big"
	"os"
	"path/filepath"
	"testing"

	"github.com/cyfr/locus/keeper/internal/wire/wirejson"
)

type vectors struct {
	Version   int `json:"version"`
	Durations []struct {
		Text string      `json:"text"`
		Ms   json.Number `json:"ms"`
	} `json:"durations"`
}

// Every duration reads as Prima.Limits.parse_duration/1 reads it, its
// milliseconds held to the horizon on either side.
func TestEveryDurationReadsAsPrimaReadsIt(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("..", "..", "..", "..", "..", "..", "tests", "fixtures", "authority_wire.json"))
	if err != nil {
		t.Fatal(err)
	}
	var v vectors
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.UseNumber()
	if err := dec.Decode(&v); err != nil || v.Version != 1 || len(v.Durations) < 30 {
		t.Fatalf("the vector file: %v, %d durations", err, len(v.Durations))
	}
	horizon := big.NewInt(Horizon)
	for _, c := range v.Durations {
		ms, ok := Duration(c.Text)
		if c.Ms == "" {
			if ok {
				t.Errorf("%q reads as %d; Prima refuses it", c.Text, ms)
			}
			continue
		}
		want, _ := new(big.Int).SetString(string(c.Ms), 10)
		if want.CmpAbs(horizon) > 0 {
			want.Mul(big.NewInt(int64(want.Sign())), horizon)
		}
		if !ok || big.NewInt(ms).Cmp(want) != 0 {
			t.Errorf("%q reads as %d, %v; want %s", c.Text, ms, ok, want)
		}
	}
	if _, err := Read(wirejson.Number("1")); err == nil {
		t.Error("a number is no limits")
	}
}
