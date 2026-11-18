// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Package brainwire is the brain wire, version 2, a driver's side, for
// every brain driver (cmd/cyfr-claude-code, cmd/cyfr-codex):
// tests/fixtures/brain_wire.json defines it (its "comment") and binds this
// package and the holder (Opus.Brain.Wire) to the same lines. Commands come
// from the holder on standard input, events go to it on standard output,
// one JSON object per line, each read strictly. Beside the wire it holds
// what every driver does the same way: a line reader with its bound, the
// harness's process, the loop that serves the wire (serve.go), and the
// terminal on which a driver runs its harness unchanged.
package brainwire

import (
	"bytes"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"unicode/utf8"
)

const (
	Version      = 2
	MaxLineBytes = 1 << 20
	MaxIDBytes   = 256
	MaxList      = 1000
	// uuidPrefix starts what a post's uuid is derived from.
	uuidPrefix = "cyfr-brain-post\x00"
)

var (
	ErrUnreadable = errors.New("unreadable")
	ErrUnknown    = errors.New("unknown")
	ErrTooLarge   = errors.New("too_large")
)

type fieldType int

const (
	tID fieldType = iota
	tString
	tCount
	tBoolean
	tObject
	tIDs
	tStrings
	tContent
	tTools
	tConfig
	tCounts
	tModels
	tModelCounts
	tPhase
	tErrorType
	tAccounting
	tStop
)

// Spec is one message: the members it always carries, those it may, and
// the type of each.
type Spec struct {
	fields   []string
	optional []string
	types    map[string]fieldType
}

var configTypes = map[string]fieldType{
	"model":           tString,
	"effort":          tString,
	"permission_mode": tString,
	"harness_tools":   tStrings,
	"read_only":       tBoolean,
}

// CountNames are the four counts of a model's usage, in the wire's order.
var CountNames = []string{"input_tokens", "output_tokens", "cache_read_tokens", "cache_write_tokens"}
var accountings = []string{"complete", "partial", "unavailable"}
var stops = []string{"end_turn", "limit", "error"}
var phases = []string{"start", "end"}
var errorTypes = []string{"invalid_request", "authentication", "rate_limited", "overloaded", "provider_error", "unknown_model"}
var mediaTypes = map[string][]string{
	"image":    {"image/jpeg", "image/png", "image/gif", "image/webp"},
	"document": {"application/pdf"},
}
var nativeEvents = []string{"text", "said", "own", "ask", "usage", "idle", "error"}

// Commands are the messages the holder writes.
var Commands = map[string]Spec{
	"start": {[]string{"t", "gen", "config"}, []string{"session", "system", "pending", "tools"},
		map[string]fieldType{"gen": tCount, "config": tConfig, "session": tID, "system": tString, "pending": tIDs, "tools": tTools}},
	"work": {[]string{"t", "id", "work", "tools"}, nil,
		map[string]fieldType{"id": tID, "work": tID, "tools": tTools}},
	"post": {[]string{"t", "id", "work", "content"}, []string{"context"},
		map[string]fieldType{"id": tID, "work": tID, "content": tContent, "context": tContent}},
	"answer": {[]string{"t", "id", "ask", "content", "is_error"}, nil,
		map[string]fieldType{"id": tID, "ask": tID, "content": tString, "is_error": tBoolean}},
	"models": {[]string{"t", "id"}, nil, map[string]fieldType{"id": tID}},
	"forget": {[]string{"t", "id", "session"}, nil, map[string]fieldType{"id": tID, "session": tID}},
}

// Events are the messages a driver writes.
var Events = map[string]Spec{
	"hello": {[]string{"t", "v", "driver", "boot"}, nil,
		map[string]fieldType{"v": tCount, "driver": tID, "boot": tID}},
	"started": {[]string{"t", "session", "fresh", "held"}, nil,
		map[string]fieldType{"session": tID, "fresh": tBoolean, "held": tIDs}},
	"gone":     {[]string{"t"}, nil, map[string]fieldType{}},
	"accepted": {[]string{"t", "id"}, nil, map[string]fieldType{"id": tID}},
	"refused":  {[]string{"t", "id", "reason"}, nil, map[string]fieldType{"id": tID, "reason": tString}},
	"text": {[]string{"t", "gen", "message", "delta"}, []string{"work"},
		map[string]fieldType{"gen": tCount, "work": tID, "message": tID, "delta": tString}},
	"said": {[]string{"t", "gen", "message", "text"}, []string{"work"},
		map[string]fieldType{"gen": tCount, "work": tID, "message": tID, "text": tString}},
	"own": {[]string{"t", "gen", "name", "phase"}, []string{"work"},
		map[string]fieldType{"gen": tCount, "work": tID, "name": tString, "phase": tPhase}},
	"ask": {[]string{"t", "gen", "ask", "name", "arguments"}, []string{"work"},
		map[string]fieldType{"gen": tCount, "work": tID, "ask": tID, "name": tString, "arguments": tObject}},
	"usage": {[]string{"t", "gen", "accounting"}, []string{"work", "result", "total", "models"},
		map[string]fieldType{"gen": tCount, "work": tID, "result": tID, "total": tID, "accounting": tAccounting, "models": tModelCounts}},
	"idle": {[]string{"t", "gen", "answered", "stop"}, []string{"work"},
		map[string]fieldType{"gen": tCount, "work": tID, "answered": tIDs, "stop": tStop}},
	"error": {[]string{"t", "gen", "type", "message"}, []string{"work"},
		map[string]fieldType{"gen": tCount, "work": tID, "type": tErrorType, "message": tString}},
	"models": {[]string{"t", "id", "models", "efforts"}, nil,
		map[string]fieldType{"id": tID, "models": tModels, "efforts": tStrings}},
	"forgot": {[]string{"t", "id", "session"}, nil, map[string]fieldType{"id": tID, "session": tID}},
}

// ReadLine reads one line as a message of `messages`: its members raw,
// once it holds exactly its message's members, each of its type.
func ReadLine(line []byte, messages map[string]Spec) (string, map[string]json.RawMessage, error) {
	if len(line) > MaxLineBytes {
		return "", nil, ErrTooLarge
	}
	if !utf8.Valid(line) {
		return "", nil, ErrUnreadable
	}
	var members map[string]json.RawMessage
	if err := StrictUnmarshal(line, &members); err != nil || members == nil {
		return "", nil, ErrUnreadable
	}
	var t string
	if raw, ok := members["t"]; !ok || json.Unmarshal(raw, &t) != nil {
		return "", nil, ErrUnreadable
	}
	s, ok := messages[t]
	if !ok {
		return t, nil, ErrUnknown
	}
	if !messageOK(t, members, s) {
		return t, nil, ErrUnreadable
	}
	return t, members, nil
}

// StrictUnmarshal decodes one JSON value and nothing after it: the line
// must end, white space apart, where the value does. Whatever follows it,
// a stray `]` or `}` that does not read as a value included, refuses the
// line.
func StrictUnmarshal(data []byte, v any) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	if err := decoder.Decode(v); err != nil {
		return err
	}
	var rest json.RawMessage
	if err := decoder.Decode(&rest); err != io.EOF {
		return ErrUnreadable
	}
	return nil
}

// Str is a member a read message holds as a string, or "".
func Str(members map[string]json.RawMessage, name string) string {
	var s string
	_ = json.Unmarshal(members[name], &s)
	return s
}

func messageOK(t string, members map[string]json.RawMessage, s Spec) bool {
	for _, field := range s.fields {
		if _, ok := members[field]; !ok {
			return false
		}
	}
	for name, raw := range members {
		if name == "t" {
			continue
		}
		ft, ok := s.types[name]
		if !ok || !ofType(ft, raw) {
			return false
		}
	}
	if t == "usage" {
		_, result := members["result"]
		_, total := members["total"]
		_, models := members["models"]
		return result != total && models != OneOf(members["accounting"], []string{"unavailable"})
	}
	return true
}

func ofType(ft fieldType, raw json.RawMessage) bool {
	switch ft {
	case tID:
		var s string
		return json.Unmarshal(raw, &s) == nil && IsID(s) && isString(raw)
	case tString:
		var s string
		return isString(raw) && json.Unmarshal(raw, &s) == nil
	case tCount:
		return IsCount(raw)
	case tBoolean:
		var b bool
		return (string(raw) == "true" || string(raw) == "false") && json.Unmarshal(raw, &b) == nil
	case tObject:
		var m map[string]json.RawMessage
		return json.Unmarshal(raw, &m) == nil && m != nil
	case tIDs:
		return listOf(raw, func(r json.RawMessage) bool { return ofType(tID, r) })
	case tStrings:
		return listOf(raw, func(r json.RawMessage) bool { return ofType(tString, r) })
	case tContent:
		return listOf(raw, BlockOK)
	case tTools:
		return listOf(raw, toolOK)
	case tModels:
		return listOf(raw, modelOK)
	case tModelCounts:
		return listOf(raw, modelCountsOK)
	case tConfig:
		var m map[string]json.RawMessage
		if json.Unmarshal(raw, &m) != nil || m == nil {
			return false
		}
		for name, value := range m {
			ct, ok := configTypes[name]
			if !ok || !ofType(ct, value) {
				return false
			}
		}
		return true
	case tCounts:
		var m map[string]json.RawMessage
		if json.Unmarshal(raw, &m) != nil || len(m) != len(CountNames) {
			return false
		}
		for _, name := range CountNames {
			value, ok := m[name]
			if !ok || !IsCount(value) {
				return false
			}
		}
		return true
	case tPhase:
		return OneOf(raw, phases)
	case tErrorType:
		return OneOf(raw, errorTypes)
	case tAccounting:
		return OneOf(raw, accountings)
	case tStop:
		return OneOf(raw, stops)
	}
	return false
}

// IsID is an id the wire takes: a non-empty string of at most
// MaxIDBytes bytes.
func IsID(s string) bool { return s != "" && len(s) <= MaxIDBytes }

func isString(raw json.RawMessage) bool { return len(raw) > 0 && raw[0] == '"' }

// IsCount is a whole number from 0, written as JSON writes one.
func IsCount(raw json.RawMessage) bool {
	if len(raw) == 0 || len(raw) > 20 {
		return false
	}
	for i, c := range raw {
		if c < '0' || c > '9' || (i == 0 && c == '0' && len(raw) > 1) {
			return false
		}
	}
	var n uint64
	return json.Unmarshal(raw, &n) == nil
}

// OneOf is a JSON string that is one of `allowed`.
func OneOf(raw json.RawMessage, allowed []string) bool {
	var s string
	if !isString(raw) || json.Unmarshal(raw, &s) != nil {
		return false
	}
	for _, a := range allowed {
		if s == a {
			return true
		}
	}
	return false
}

func listOf(raw json.RawMessage, entryOK func(json.RawMessage) bool) bool {
	if len(raw) == 0 || raw[0] != '[' {
		return false
	}
	var entries []json.RawMessage
	if json.Unmarshal(raw, &entries) != nil || len(entries) > MaxList {
		return false
	}
	for _, entry := range entries {
		if !entryOK(entry) {
			return false
		}
	}
	return true
}

func objectOf(raw json.RawMessage, keys ...string) (map[string]json.RawMessage, bool) {
	var m map[string]json.RawMessage
	if json.Unmarshal(raw, &m) != nil || m == nil || len(m) != len(keys) {
		return nil, false
	}
	for _, key := range keys {
		if _, ok := m[key]; !ok {
			return nil, false
		}
	}
	return m, true
}

// BlockOK is one content block the wire takes: text, or an image or a
// document of a media type it names.
func BlockOK(raw json.RawMessage) bool {
	if m, ok := objectOf(raw, "type", "text"); ok {
		return OneOf(m["type"], []string{"text"}) && ofType(tString, m["text"])
	}
	m, ok := objectOf(raw, "type", "media_type", "data")
	if !ok {
		return false
	}
	var kind string
	if json.Unmarshal(m["type"], &kind) != nil {
		return false
	}
	allowed, known := mediaTypes[kind]
	return known && OneOf(m["media_type"], allowed) && ofType(tString, m["data"])
}

func toolOK(raw json.RawMessage) bool {
	m, ok := objectOf(raw, "name", "description", "parameters")
	if !ok {
		return false
	}
	var name string
	return ofType(tString, m["name"]) && json.Unmarshal(m["name"], &name) == nil &&
		len(name) >= 1 && len(name) <= 128 && ofType(tString, m["description"]) && ofType(tObject, m["parameters"])
}

func modelOK(raw json.RawMessage) bool {
	m, ok := objectOf(raw, "id", "name")
	return ok && ofType(tID, m["id"]) && ofType(tString, m["name"])
}

func modelCountsOK(raw json.RawMessage) bool {
	m, ok := objectOf(raw, "model", "counts")
	return ok && ofType(tID, m["model"]) && ofType(tCounts, m["counts"])
}

// Block is one content block of a read command.
type Block struct {
	Type      string `json:"type"`
	Text      string `json:"text"`
	MediaType string `json:"media_type"`
	Data      string `json:"data"`
}

// Tool is one of CYFR's tools a read command names.
type Tool struct {
	Name        string          `json:"name"`
	Description string          `json:"description"`
	Parameters  json.RawMessage `json:"parameters"`
}

// Config is a start's configuration: absent members are the harness's
// defaults, and an absent ReadOnly is false.
type Config struct {
	Model          string    `json:"model"`
	Effort         string    `json:"effort"`
	PermissionMode string    `json:"permission_mode"`
	HarnessTools   *[]string `json:"harness_tools"`
	ReadOnly       bool      `json:"read_only"`
}

// ModelCounts are one model's counts in a `usage` event.
type ModelCounts struct {
	Model  string            `json:"model"`
	Counts map[string]uint64 `json:"counts"`
}

// Event is one event as a driver writes it: its members in order, `t`
// first.
type Event struct {
	members []member
}

type member struct {
	name  string
	value any
}

// NewEvent is an event of type t with no other member yet.
func NewEvent(t string) *Event { return &Event{members: []member{{"t", t}}} }

// Set sets a member.
func (e *Event) Set(name string, value any) *Event {
	e.members = append(e.members, member{name, value})
	return e
}

// SetOptional sets an optional member when it has a value.
func (e *Event) SetOptional(name, value string) *Event {
	if value != "" {
		e.Set(name, value)
	}
	return e
}

func (e *Event) MarshalJSON() ([]byte, error) {
	var b bytes.Buffer
	b.WriteByte('{')
	for i, m := range e.members {
		if i > 0 {
			b.WriteByte(',')
		}
		name, _ := json.Marshal(m.name)
		value, err := Marshal(m.value)
		if err != nil {
			return nil, err
		}
		b.Write(name)
		b.WriteByte(':')
		b.Write(value)
	}
	b.WriteByte('}')
	return b.Bytes(), nil
}

// Marshal writes JSON as the wire reads it: without HTML escaping, so a
// line's text is the text.
func Marshal(v any) ([]byte, error) {
	var b bytes.Buffer
	encoder := json.NewEncoder(&b)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(v); err != nil {
		return nil, err
	}
	return bytes.TrimRight(b.Bytes(), "\n"), nil
}

// EncodeEvent is the line an event is written as, once it reads as an
// event of the wire.
func EncodeEvent(e *Event) ([]byte, error) {
	line, err := Marshal(e)
	if err != nil {
		return nil, err
	}
	if _, _, err := ReadLine(line, Events); err != nil {
		return nil, fmt.Errorf("an event the wire does not read: %w", err)
	}
	return line, nil
}

// PostUUID is the uuid a post's input to the harness carries, derived
// from the post's id (the vector file's `uuid`).
func PostUUID(id string) string {
	sum := sha256.Sum256([]byte(uuidPrefix + id))
	return uuidForm(sum[:16])
}

// NewUUID is a random uuid, version 4.
func NewUUID() string {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return uuidForm(b)
}

func uuidForm(b []byte) string {
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	h := hex.EncodeToString(b)
	return h[0:8] + "-" + h[8:12] + "-" + h[12:16] + "-" + h[16:20] + "-" + h[20:32]
}

// RandomHex is n random bytes in hex: a driver process's boot.
func RandomHex(n int) string {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b)
}

// IsUUID is a uuid in lowercase 8-4-4-4-12 form, as both harnesses name
// their sessions.
func IsUUID(s string) bool {
	if len(s) != 36 {
		return false
	}
	for i, c := range s {
		switch i {
		case 8, 13, 18, 23:
			if c != '-' {
				return false
			}
		default:
			if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
				return false
			}
		}
	}
	return true
}
