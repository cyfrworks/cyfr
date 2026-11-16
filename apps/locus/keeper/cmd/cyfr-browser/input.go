// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package main

import (
	"bytes"
	"encoding/json"
	"math"
	"unicode/utf8"
)

// maxInputEvents bounds the events of one `input` message.
const maxInputEvents = 64

// inputEvent is one event of the person's, as tests/fixtures/browser_frames.json's
// `input` defines it: a mouse button or move, a wheel, or a key, its place a
// fraction of the image the person sees.
type inputEvent struct {
	K      string  `json:"k"`
	Type   string  `json:"type"`
	X      float64 `json:"x"`
	Y      float64 `json:"y"`
	Button string  `json:"button"`
	Clicks int     `json:"clicks"`
	DX     float64 `json:"dx"`
	DY     float64 `json:"dy"`
	Key    string  `json:"key"`
	Code   string  `json:"code"`
	Text   string  `json:"text"`
	VK     int     `json:"vk"`
	Mods   int     `json:"mods"`
}

// The fields each kind of event holds, exactly.
var inputFields = map[string][]string{
	"mouse": {"k", "type", "x", "y", "button", "clicks", "mods"},
	"wheel": {"k", "x", "y", "dx", "dy", "mods"},
	"key":   {"k", "type", "key", "code", "text", "vk", "mods"},
}

// parseInput reads an `input` message's events: all of them, or none when
// any is not an event the vector file accepts, or there are more than
// maxInputEvents.
func parseInput(raw json.RawMessage) ([]inputEvent, bool) {
	var items []json.RawMessage
	if json.Unmarshal(raw, &items) != nil || len(items) == 0 || len(items) > maxInputEvents {
		return nil, false
	}
	events := make([]inputEvent, len(items))
	for i, item := range items {
		ev, ok := parseEvent(item)
		if !ok {
			return nil, false
		}
		events[i] = ev
	}
	return events, true
}

func parseEvent(raw json.RawMessage) (inputEvent, bool) {
	var fields map[string]json.RawMessage
	if json.Unmarshal(raw, &fields) != nil {
		return inputEvent{}, false
	}
	var kind string
	if json.Unmarshal(fields["k"], &kind) != nil {
		return inputEvent{}, false
	}
	want, known := inputFields[kind]
	if !known || len(fields) != len(want) {
		return inputEvent{}, false
	}
	for _, name := range want {
		if _, ok := fields[name]; !ok {
			return inputEvent{}, false
		}
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	var ev inputEvent
	if decoder.Decode(&ev) != nil {
		return inputEvent{}, false
	}
	// Numbers that must be whole are: 1.5 decodes into no int field.
	fraction := func(v float64) bool { return v >= 0 && v <= 1 && !math.IsNaN(v) }
	delta := func(v float64) bool { return v >= -10000 && v <= 10000 }
	mods := ev.Mods >= 0 && ev.Mods <= 15
	switch kind {
	case "mouse":
		buttons := map[string]bool{"none": true, "left": true, "middle": true, "right": true}
		types := map[string]bool{"down": true, "up": true, "move": true}
		return ev, types[ev.Type] && fraction(ev.X) && fraction(ev.Y) && buttons[ev.Button] &&
			ev.Clicks >= 0 && ev.Clicks <= 3 && mods
	case "wheel":
		return ev, fraction(ev.X) && fraction(ev.Y) && delta(ev.DX) && delta(ev.DY) && mods
	default:
		return ev, (ev.Type == "down" || ev.Type == "up") && len(ev.Key) >= 1 && len(ev.Key) <= 32 &&
			utf8.ValidString(ev.Key) && codeName(ev.Code) && len(ev.Text) <= 16 && utf8.ValidString(ev.Text) &&
			ev.VK >= 0 && ev.VK <= 255 && mods
	}
}

// codeName says whether a key's code is a physical key's name: at most 32
// ASCII letters and digits, or none.
func codeName(code string) bool {
	if len(code) > 32 {
		return false
	}
	for _, c := range code {
		if !(c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' || c >= '0' && c <= '9') {
			return false
		}
	}
	return true
}

// cdpInput is one Input command.
type cdpInput struct {
	method string
	params map[string]any
}

// call is the event as Chrome takes it, its place mapped onto a window
// of width by height CSS pixels.
func (ev inputEvent) call(width, height float64) cdpInput {
	switch ev.K {
	case "mouse":
		kinds := map[string]string{"down": "mousePressed", "up": "mouseReleased", "move": "mouseMoved"}
		return cdpInput{"Input.dispatchMouseEvent", map[string]any{
			"type": kinds[ev.Type], "x": ev.X * width, "y": ev.Y * height, "button": ev.Button,
			"clickCount": ev.Clicks, "modifiers": ev.Mods,
		}}
	case "wheel":
		return cdpInput{"Input.dispatchMouseEvent", map[string]any{
			"type": "mouseWheel", "x": ev.X * width, "y": ev.Y * height, "deltaX": ev.DX, "deltaY": ev.DY,
			"modifiers": ev.Mods,
		}}
	default:
		params := map[string]any{"key": ev.Key, "code": ev.Code, "windowsVirtualKeyCode": ev.VK, "modifiers": ev.Mods}
		switch {
		case ev.Type == "up":
			params["type"] = "keyUp"
		case ev.Text != "":
			params["type"], params["text"] = "keyDown", ev.Text
		default:
			params["type"] = "rawKeyDown"
		}
		return cdpInput{"Input.dispatchKeyEvent", params}
	}
}
