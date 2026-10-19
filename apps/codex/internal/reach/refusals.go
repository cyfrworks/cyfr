// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package reach

import (
	"maps"
	"slices"
	"strings"
)

// refusalRow is one code's class and its sentence variants
// (refusals_gen.go).
type refusalRow struct {
	Class    string
	Variants []refusalVariant
}

// refusalVariant is a sentence for the payloads whose keys are exactly
// Fixed's and Slots', with Fixed's values: Template with each slot's value
// in place of `{slot}`.
type refusalVariant struct {
	Fixed    map[string]string
	Slots    []string
	Template string
}

// Refuse is the refusal code answers with payload, its class the row's:
// the engine's and `cyfr up`'s rows (refusals_gen.go), else the boot's.
func Refuse(code string, payload map[string]string) *Refusal {
	r := refuse(code, payload)
	if row, ok := refusalRows[code]; ok {
		r.Class = row.Class
	}
	return r
}

// Message is the sentence the CLI prints for r, word for word the one
// Prima.Refusal holds for the same code and payload: an engine row from
// its generated template, a boot refusal as the release says it. A payload
// no variant takes reads as the code.
func (r *Refusal) Message() string {
	row, ok := refusalRows[r.Code]
	if !ok {
		return r.Sentence()
	}
	for _, v := range row.Variants {
		if text, ok := v.render(r.Payload); ok {
			return text
		}
	}
	return r.Code
}

func (v refusalVariant) render(payload map[string]string) (string, bool) {
	keys := slices.Sorted(maps.Keys(payload))
	want := slices.Sorted(slices.Values(append(slices.Collect(maps.Keys(v.Fixed)), v.Slots...)))
	if !slices.Equal(keys, want) {
		return "", false
	}
	for k, value := range v.Fixed {
		if payload[k] != value {
			return "", false
		}
	}
	pairs := make([]string, 0, 2*len(v.Slots))
	for _, slot := range v.Slots {
		pairs = append(pairs, "{"+slot+"}", payload[slot])
	}
	return strings.NewReplacer(pairs...).Replace(v.Template), true
}
