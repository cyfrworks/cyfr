// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package main

import (
	"encoding/json"
	"fmt"
	"regexp"
	"sort"
	"strconv"
	"strings"

	"github.com/cyfr/locus/keeper/internal/brainwire"
)

// The Agent Client Protocol, version 1, as the driver speaks it on the
// program's standard input and output: JSON-RPC 2.0, one message a line.
// The driver sends `initialize`, `session/new`, `session/resume`,
// `session/load`, `session/set_config_option`, `session/prompt` and
// `session/close`, and the `session/cancel` notification. It answers the
// program's `session/request_permission` with an allow, and every other
// request of the program's with method-not-found (-32601). It reads
// `session/update` notifications, and drops each kind it does not use.

const protocolVersion = 1

func request(id int, method string, params any) []byte {
	line, _ := brainwire.Marshal(map[string]any{"jsonrpc": "2.0", "id": id, "method": method, "params": params})
	return line
}

func notification(method string, params any) []byte {
	line, _ := brainwire.Marshal(map[string]any{"jsonrpc": "2.0", "method": method, "params": params})
	return line
}

func answerLine(id json.RawMessage, result any) []byte {
	line, _ := brainwire.Marshal(map[string]any{"jsonrpc": "2.0", "id": id, "result": result})
	return line
}

func refuseLine(id json.RawMessage, method string) []byte {
	line, _ := brainwire.Marshal(map[string]any{"jsonrpc": "2.0", "id": id,
		"error": map[string]any{"code": -32601, "message": "CYFR does not answer " + method}})
	return line
}

// initializeParams advertise no file system and no terminal: the program
// uses its own tools in its own folder.
func initializeParams() map[string]any {
	return map[string]any{
		"protocolVersion": protocolVersion,
		"clientCapabilities": map[string]any{
			"fs":       map[string]any{"readTextFile": false, "writeTextFile": false},
			"terminal": false,
		},
		"clientInfo": map[string]any{"name": "cyfr", "title": "CYFR", "version": "1"},
	}
}

type rpcError struct {
	Code    int             `json:"code"`
	Message string          `json:"message"`
	Data    json.RawMessage `json:"data"`
}

// rpc is one line of the program's, as far as the driver reads it: an
// answer to a request of the driver's (an id, no method), a request of the
// program's (an id and a method) or a notification (a method alone).
type rpc struct {
	ID     json.RawMessage `json:"id"`
	Method string          `json:"method"`
	Params json.RawMessage `json:"params"`
	Result json.RawMessage `json:"result"`
	Error  *rpcError       `json:"error"`
}

// idKey is a JSON-RPC id as the driver keys its requests: a number's
// digits, or a string's content.
func idKey(raw json.RawMessage) string {
	var s string
	if json.Unmarshal(raw, &s) == nil {
		return s
	}
	return string(raw)
}

// initialized is what the driver reads of initialize's answer.
type initialized struct {
	ProtocolVersion json.RawMessage `json:"protocolVersion"`
	Capabilities    json.RawMessage `json:"agentCapabilities"`
	Info            struct {
		Version string `json:"version"`
	} `json:"agentInfo"`
}

type agentCapabilities struct {
	LoadSession bool `json:"loadSession"`
	Prompt      struct {
		Image           bool `json:"image"`
		EmbeddedContext bool `json:"embeddedContext"`
	} `json:"promptCapabilities"`
	Session struct {
		Resume json.RawMessage `json:"resume"`
	} `json:"sessionCapabilities"`
}

var versionForm = regexp.MustCompile(`^(\d+)\.(\d+)\.(\d+)`)

// qualify is why the program's initialize answer does not qualify it under
// p, or "": protocol 1, at least the profile's version where it names one,
// and a load of a session, with a resume where the profile goes on by one.
// The words are the driver's, for its standard error.
func qualify(p *profile, answer initialized, caps agentCapabilities) string {
	if string(answer.ProtocolVersion) != strconv.Itoa(protocolVersion) {
		return fmt.Sprintf("%s answered ACP protocol version %s, not %d, the one CYFR speaks", p.title, answer.ProtocolVersion, protocolVersion)
	}
	if p.minVersion != [3]int{} {
		minimum := fmt.Sprintf("%d.%d.%d", p.minVersion[0], p.minVersion[1], p.minVersion[2])
		parts := versionForm.FindStringSubmatch(answer.Info.Version)
		if parts == nil {
			return fmt.Sprintf("%s named no version CYFR reads; CYFR drives %s or later", p.title, minimum)
		}
		for i := 0; i < 3; i++ {
			n, _ := strconv.Atoi(parts[i+1])
			if n != p.minVersion[i] {
				if n < p.minVersion[i] {
					return fmt.Sprintf("%s %s is older than %s, the first CYFR drives; update it", p.title, parts[0], minimum)
				}
				break
			}
		}
	}
	resumes := len(caps.Session.Resume) != 0 && string(caps.Session.Resume) != "null"
	switch {
	case p.resumeNotFound == nil && !caps.LoadSession:
		return fmt.Sprintf("%s does not offer to load a session, which CYFR needs to go on with one", p.title)
	case p.resumeNotFound != nil && (!caps.LoadSession || !resumes):
		return fmt.Sprintf("%s does not offer both to resume and to load a session, which CYFR needs to go on with one", p.title)
	}
	return ""
}

// configOption is one of a session's config options, its choices flat.
type configOption struct {
	ID       string `json:"id"`
	Category string `json:"category"`
	Current  string `json:"currentValue"`
	Options  []struct {
		Value   string `json:"value"`
		Name    string `json:"name"`
		Options []struct {
			Value string `json:"value"`
			Name  string `json:"name"`
		} `json:"options"`
	} `json:"options"`
}

type choice struct{ value, name string }

// choices are the option's values, a group's flattened in place.
func (o *configOption) choices() []choice {
	var out []choice
	for _, entry := range o.Options {
		if entry.Value != "" {
			out = append(out, choice{entry.Value, entry.Name})
		}
		for _, grouped := range entry.Options {
			out = append(out, choice{grouped.Value, grouped.Name})
		}
	}
	return out
}

func (o *configOption) offers(value string) bool {
	for _, c := range o.choices() {
		if c.value == value {
			return true
		}
	}
	return false
}

// sessionAnswer is what the driver reads of a session/new, resume or load
// answer: the session, its config options and its model variants.
type sessionAnswer struct {
	SessionID string         `json:"sessionId"`
	Options   []configOption `json:"configOptions"`
	Models    struct {
		Available []struct {
			ID string `json:"modelId"`
		} `json:"availableModels"`
		Current string `json:"currentModelId"`
	} `json:"models"`
}

// option is the session's config option of `category`, or nil.
func option(options []configOption, category string) *configOption {
	for i := range options {
		if options[i].Category == category {
			return &options[i]
		}
	}
	return nil
}

// listedModels are the session's models, as its `model` option offers
// them, each with its efforts: those `efforts` names for it where the
// profile reads them by selecting the model, and otherwise those of the
// session's `thought_level` option the program has a variant of, a
// variant being an available model named `<model>-<effort>`, as Antigravity
// names them.
func listedModels(answer sessionAnswer, efforts map[string][]string) []brainwire.Model {
	models := []brainwire.Model{}
	model := option(answer.Options, "model")
	if model == nil {
		return models
	}
	variants := map[string]bool{}
	for _, m := range answer.Models.Available {
		variants[m.ID] = true
	}
	var levels []choice
	if effort := option(answer.Options, "thought_level"); effort != nil {
		levels = effort.choices()
	}
	for _, c := range model.choices() {
		listed := []string{}
		if efforts != nil {
			listed = append(listed, efforts[c.value]...)
		} else {
			for _, level := range levels {
				if variants[c.value+"-"+level.value] {
					listed = append(listed, level.value)
				}
			}
		}
		models = brainwire.AppendModel(models, c.value, c.name, listed)
	}
	return models
}

// unsetEffort is the value of an effort option that names no effort of its
// own, which is never listed as one.
const unsetEffort = "default"

// selectedEfforts are the efforts a session's `thought_level` option offers
// for the model it has now.
func selectedEfforts(options []configOption) []string {
	out := []string{}
	if o := option(options, "thought_level"); o != nil {
		for _, c := range o.choices() {
			if c.value != unsetEffort {
				out = append(out, c.value)
			}
		}
	}
	return out
}

// promptContent is a post's blocks as an ACP prompt's content: text; an
// image where the program takes one; a document as an embedded resource
// where it takes one; and in place of any other block, one line of text
// naming the file's type, so the post is written with the rest.
func promptContent(blocks []brainwire.Block, caps agentCapabilities, title string) []any {
	out := make([]any, 0, len(blocks))
	for i, b := range blocks {
		switch {
		case b.Type == "text":
			out = append(out, textBlock(b.Text))
		case b.Type == "image" && caps.Prompt.Image:
			out = append(out, map[string]any{"type": "image", "mimeType": b.MediaType, "data": b.Data})
		case b.Type == "document" && caps.Prompt.EmbeddedContext:
			out = append(out, map[string]any{"type": "resource", "resource": map[string]any{
				"uri": fmt.Sprintf("cyfr://attachment/%d", i+1), "mimeType": b.MediaType, "blob": b.Data}})
		default:
			out = append(out, textBlock(fmt.Sprintf("A file of type %s was attached; %s does not take it, so it is not handed over.", b.MediaType, title)))
		}
	}
	return out
}

func textBlock(text string) map[string]any { return map[string]any{"type": "text", "text": text} }

// promptUsage reads a prompt answer's usage under the session's model, each
// of the wire's counts the sum of the profile's names for it: no usage is
// "unavailable", never zeros; a count that does not read, or a model the
// wire cannot name, is "partial" naming no model's counts; and counts that
// read take the profile's accounting. A count the profile names nothing
// for is one the program does not report: 0, under an accounting that
// says the counts may be short.
func promptUsage(raw json.RawMessage, model string, p *profile) (string, []brainwire.ModelCounts) {
	var usage map[string]json.RawMessage
	if len(raw) == 0 || json.Unmarshal(raw, &usage) != nil || usage == nil {
		return "unavailable", nil
	}
	names := make([]string, 0, len(p.counts))
	for name := range p.counts {
		names = append(names, name)
	}
	sort.Strings(names)
	counts := map[string]uint64{}
	for _, name := range names {
		var sum uint64
		for _, field := range p.counts[name] {
			var n uint64
			value := usage[field]
			if !brainwire.IsCount(value) || json.Unmarshal(value, &n) != nil || sum+n < sum {
				return "partial", []brainwire.ModelCounts{}
			}
			sum += n
		}
		counts[name] = sum
	}
	if !brainwire.IsID(model) {
		return "partial", []brainwire.ModelCounts{}
	}
	return p.counted, []brainwire.ModelCounts{{Model: model, Counts: counts}}
}

// errorKind is the wire's type for a prompt's JSON-RPC error: the
// profile's signed-out code is the account's; a message naming an
// exhausted resource, a quota or a rate limit is a limit's; any other is
// the provider's. Only the failed prompt's own error is read so.
func errorKind(p *profile, e *rpcError) string {
	lower := strings.ToLower(e.Message)
	switch {
	case e.Code == p.signedOut:
		return "authentication"
	case strings.Contains(lower, "resource_exhausted") || strings.Contains(lower, "quota") || strings.Contains(lower, "rate limit"):
		return "rate_limited"
	}
	return "provider_error"
}

// errorSentence is the driver's own words for an error of the program's:
// its words may name its account or its endpoint, so they never leave the
// box.
func errorSentence(p *profile, kind string) string {
	switch kind {
	case "authentication":
		if p.refusedSentence != "" {
			return p.refusedSentence
		}
		return p.title + "'s sign-in was refused; sign it in again on the program's terminal."
	case "rate_limited":
		return p.title + " reported a usage or rate limit; " + brainwire.UntilWords(0) + "."
	case "invalid_request":
		return p.title + " refused to go on with the request."
	}
	return p.title + " reported an error of its provider."
}

// strayStopSentence says a turn ended in a way CYFR did not ask for: a
// cancel no Stop sent, or a stop reason ACP does not name.
func strayStopSentence(p *profile) string {
	return p.title + " ended its turn in a way CYFR did not ask for."
}

// allowOption is the answer to a permission question: its allow_once
// option, or allow_always where that is the only allow, and a cancelled
// outcome where it offers no allow.
func allowOption(params json.RawMessage) map[string]any {
	var q struct {
		Options []struct {
			ID   string `json:"optionId"`
			Kind string `json:"kind"`
		} `json:"options"`
	}
	_ = json.Unmarshal(params, &q)
	chosen := ""
	for _, o := range q.Options {
		if o.Kind == "allow_once" {
			chosen = o.ID
			break
		}
		if o.Kind == "allow_always" && chosen == "" {
			chosen = o.ID
		}
	}
	if chosen == "" {
		return map[string]any{"outcome": map[string]any{"outcome": "cancelled"}}
	}
	return map[string]any{"outcome": map[string]any{"outcome": "selected", "optionId": chosen}}
}
