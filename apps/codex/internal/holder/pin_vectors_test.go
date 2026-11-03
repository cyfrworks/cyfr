// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package holder

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// pinVectors is tests/fixtures/device_pin.json as the holder reads it:
// the suite, RFC 9497 Appendix A.1.1's OPRF-mode vectors and the elements
// a home refuses.
type pinVectors struct {
	Suite struct {
		Name         string `json:"name"`
		Mode         int    `json:"mode"`
		ElementBytes int    `json:"element_bytes"`
		OutputBytes  int    `json:"output_bytes"`
	} `json:"suite"`
	RFC9497 struct {
		SkS     string `json:"sk_s"`
		Vectors []struct {
			Blind, Input, Output string
			Blinded              string `json:"blinded_element"`
			Evaluated            string `json:"evaluation_element"`
		} `json:"vectors"`
	} `json:"rfc9497"`
	Elements struct {
		Refused []struct {
			Name    string `json:"name"`
			Blinded string `json:"blinded"`
		} `json:"refused"`
	} `json:"elements"`
}

func readPINVectors(t *testing.T) pinVectors {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "..", "tests", "fixtures", "device_pin.json"))
	if err != nil {
		t.Fatal(err)
	}
	var v pinVectors
	if err := json.Unmarshal(raw, &v); err != nil {
		t.Fatal(err)
	}
	return v
}

type rfcVector struct {
	key, input, blind, blinded, evaluated, output []byte
}

// rfc9497Vectors is the fixture's RFC 9497 section, decoded.
func rfc9497Vectors(t *testing.T) []rfcVector {
	t.Helper()
	v := readPINVectors(t)
	if v.Suite.Name != pinSuite.Identifier() || v.Suite.Mode != 0 || v.Suite.ElementBytes != ElementSize || v.Suite.OutputBytes != 64 {
		t.Fatalf("the fixture's suite %+v is not the holder's %s", v.Suite, pinSuite.Identifier())
	}
	if len(v.RFC9497.Vectors) == 0 {
		t.Fatal("the fixture holds no RFC 9497 vectors")
	}
	key := hexBytes(t, v.RFC9497.SkS)
	var out []rfcVector
	for _, c := range v.RFC9497.Vectors {
		out = append(out, rfcVector{key: key, input: hexBytes(t, c.Input), blind: hexBytes(t, c.Blind),
			blinded: hexBytes(t, c.Blinded), evaluated: hexBytes(t, c.Evaluated), output: hexBytes(t, c.Output)})
	}
	return out
}
