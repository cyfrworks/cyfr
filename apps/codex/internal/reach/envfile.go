// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package reach

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io/fs"
	"os"
	"slices"
	"strings"
)

// dotenv is a .env file held as its lines, read as Docker Compose reads
// it: an optional `export `, a name, `=` or `:`, and a value, quoted or
// bare, a quoted value running across lines until its closing quote; a
// bare name takes its value from the environment; the last assignment of
// a name wins. Writing it back changes only the lines of the names it
// sets, so every other line is kept byte for byte.
type dotenv struct {
	lines   []string
	entries []envEntry
}

// envEntry is one assignment: its name, its value as compose reads it,
// whether it inherits the environment's value, and the lines it spans.
type envEntry struct {
	key, value  string
	inherit     bool
	first, last int
}

func parseDotenv(data []byte) *dotenv {
	d := &dotenv{lines: strings.Split(string(data), "\n")}
	for i := 0; i < len(d.lines); i++ {
		entry, ok := d.entryAt(i)
		if ok {
			d.entries = append(d.entries, entry)
			i = entry.last
		}
	}
	return d
}

// entryAt reads the assignment starting on line i, if one does.
func (d *dotenv) entryAt(i int) (envEntry, bool) {
	line := strings.TrimLeft(d.lines[i], " \t")
	if line == "" || line[0] == '#' {
		return envEntry{}, false
	}
	if rest, ok := strings.CutPrefix(line, "export"); ok && rest != "" && (rest[0] == ' ' || rest[0] == '\t') {
		line = strings.TrimLeft(rest, " \t")
	}
	end := strings.IndexAny(line, "=:")
	if end < 0 {
		key := strings.TrimRight(strings.TrimRight(line, "\r"), " \t")
		if key == "" || strings.ContainsAny(key, " \t#") {
			return envEntry{}, false
		}
		return envEntry{key: key, inherit: true, first: i, last: i}, true
	}
	key := strings.TrimRight(line[:end], " \t")
	if key == "" || strings.ContainsAny(key, " \t") {
		return envEntry{}, false
	}
	raw := strings.TrimLeft(line[end+1:], " \t")
	entry := envEntry{key: key, first: i, last: i}
	if raw != "" && (raw[0] == '"' || raw[0] == '\'') {
		quote := raw[0]
		text := raw[1:]
		for j := i; ; {
			if k := closingQuote(text, quote); k >= 0 {
				entry.value += text[:k]
				entry.last = j
				break
			}
			entry.value += text + "\n"
			if j++; j >= len(d.lines) {
				// No closing quote: the value is the rest of the line,
				// as compose reads an unterminated one.
				entry.value = strings.TrimRight(raw[1:], "\r")
				entry.last = i
				break
			}
			text = d.lines[j]
		}
		if quote == '"' {
			entry.value = unescapeDouble(entry.value)
		}
		return entry, true
	}
	raw = strings.TrimRight(raw, "\r")
	if k := strings.Index(raw, " #"); k >= 0 {
		raw = raw[:k]
	}
	if k := strings.Index(raw, "\t#"); k >= 0 {
		raw = raw[:k]
	}
	entry.value = strings.TrimSpace(raw)
	return entry, true
}

// closingQuote is the index of the first unescaped quote in text, or -1.
func closingQuote(text string, quote byte) int {
	for k := 0; k < len(text); k++ {
		switch {
		case quote == '"' && text[k] == '\\':
			k++
		case text[k] == quote:
			return k
		}
	}
	return -1
}

func unescapeDouble(s string) string {
	return strings.NewReplacer(`\n`, "\n", `\r`, "\r", `\t`, "\t", `\"`, `"`, `\\`, `\`).Replace(s)
}

// values are the names .env assigns and their values, the last
// assignment of each winning; an inheriting name maps to "".
func (d *dotenv) values() map[string]string {
	m := map[string]string{}
	for _, entry := range d.entries {
		m[entry.key] = entry.value
	}
	return m
}

func (d *dotenv) bytes() []byte { return []byte(strings.Join(d.lines, "\n")) }

// composeKey is the first name, in byte order, of the COMPOSE_* settings
// .env names, which Docker Compose would read to choose the stack's
// files, project or profiles, or "".
func (d *dotenv) composeKey() string {
	var keys []string
	for _, entry := range d.entries {
		if strings.HasPrefix(entry.key, "COMPOSE_") {
			keys = append(keys, entry.key)
		}
	}
	slices.Sort(keys)
	if len(keys) == 0 {
		return ""
	}
	return keys[0]
}

// headKeys are the reach keys .env holds for a head, the ones a switch
// writes; envKeys (derive.go) derives their values.
func headKeys() []string {
	keys := make([]string, len(envKeys))
	for i, k := range envKeys {
		keys[i] = k.name
	}
	return keys
}

// keysOf are the values head h writes for every head key, "" for one it
// removes.
func keysOf(h Head) map[string]string {
	m := map[string]string{}
	for _, k := range envKeys {
		m[k.name] = k.value(h)
	}
	return m
}

// heldKeys are the values .env holds now for every head key, "" for one
// it does not assign.
func (d *dotenv) heldKeys() map[string]string {
	values := d.values()
	m := map[string]string{}
	for _, key := range headKeys() {
		m[key] = values[key]
	}
	return m
}

// insertOrder is where a head key .env lacks is written: right after the
// CYFR_REACH line, in this order.
var insertOrder = []string{"CYFR_REACH", "CYFR_HOST", "CYFR_PUBLIC_URL", "CYFR_TAILNET_NODE_ID", "CADDY_ACME_EMAIL", "CYFR_PORT", "CYFR_LOCUS_BUILDS_URL"}

// withKeys is .env with every head key set to want's value: a key whose
// value is already that is left as it is written; a changed key is
// written on its first assignment's lines and loses every other
// assignment; a removed key loses every assignment; a key .env lacks goes
// after the CYFR_REACH line. Every other line is kept byte for byte.
func (d *dotenv) withKeys(want map[string]string) []byte {
	held := d.heldKeys()
	type edit struct {
		first, last int
		text        []string
	}
	var edits []edit
	var missing []string
	for _, key := range insertOrder {
		value := want[key]
		mine := slices.DeleteFunc(slices.Clone(d.entries), func(e envEntry) bool { return e.key != key })
		inherits := slices.ContainsFunc(mine, func(e envEntry) bool { return e.inherit })
		if held[key] == value && !inherits && (value == "" || len(mine) > 0) {
			continue
		}
		if len(mine) == 0 {
			if value != "" {
				missing = append(missing, key+"="+value)
			}
			continue
		}
		for i, entry := range mine {
			e := edit{first: entry.first, last: entry.last}
			if i == 0 && value != "" {
				e.text = []string{key + "=" + value}
			}
			edits = append(edits, e)
		}
	}
	slices.SortFunc(edits, func(a, b edit) int { return a.first - b.first })

	reach := -1
	for _, entry := range d.entries {
		if entry.key == "CYFR_REACH" {
			reach = entry.last
			break
		}
	}
	var out []string
	next := 0
	insert := func() {
		out = append(out, missing...)
		missing = nil
	}
	for i := 0; i < len(d.lines); i++ {
		if next < len(edits) && edits[next].first == i {
			e := edits[next]
			out = append(out, e.text...)
			if e.last >= reach && e.first <= reach && len(e.text) > 0 {
				insert()
			}
			i = e.last
			next++
			continue
		}
		out = append(out, d.lines[i])
		if i == reach {
			insert()
		}
	}
	if len(missing) > 0 {
		// No CYFR_REACH line: the keys go at the end, before the final
		// newline when the file ends in one.
		if n := len(out); n > 0 && out[n-1] == "" {
			out = append(slices.Concat(out[:n-1], missing), "")
		} else {
			out = append(out, missing...)
			out = append(out, "")
		}
	}
	return []byte(strings.Join(out, "\n"))
}

// readEnv reads the project's .env, nil when there is none, and refuses
// one that names a COMPOSE_* setting.
func (e *Engine) readEnv() (*dotenv, error) {
	data, err := os.ReadFile(e.envPath())
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	d := parseDotenv(data)
	if key := d.composeKey(); key != "" {
		return nil, Refuse("compose_env_refused", map[string]string{"key": key})
	}
	return d, nil
}

func (e *Engine) envPath() string { return e.dir + string(os.PathSeparator) + ".env" }

// envMode is the mode .env is written back with: its own, else 0600.
func (e *Engine) envMode() os.FileMode {
	if info, err := os.Stat(e.envPath()); err == nil {
		return info.Mode().Perm()
	}
	return 0o600
}

func sha256Hex(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}
