// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package reach

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io/fs"
	"maps"
	"os"
	"path/filepath"
	"regexp"
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

// headEdit is the edit that gives .env the head keys want names: a key
// whose value is already that is left as it is written, so its spelling
// stays; a changed key is set; a key the head omits is unset.
func (d *dotenv) headEdit(want map[string]string) (set map[string]string, unset []string) {
	held := d.heldKeys()
	set = map[string]string{}
	for _, key := range headKeys() {
		value := want[key]
		mine := slices.DeleteFunc(slices.Clone(d.entries), func(e envEntry) bool { return e.key != key })
		inherits := slices.ContainsFunc(mine, func(e envEntry) bool { return e.inherit })
		switch {
		case held[key] == value && !inherits && (value == "" || len(mine) > 0):
		case value == "":
			unset = append(unset, key)
		default:
			set[key] = value
		}
	}
	return set, unset
}

// EditEnv is text, a .env file, with every key of set assigned its value
// and every key of unset assigned none, read with the grammar the engine
// and compose read .env with: a set key's last assignment is rewritten
// and its earlier ones removed, a key it lacks is appended at the end; an
// unset key loses every assignment, an inheriting bare name included.
// Every other line, a quoted value's lines across several included, is
// kept byte for byte. A value that does not read back bare is quoted.
func EditEnv(text []byte, set map[string]string, unset []string) []byte {
	d := parseDotenv(text)
	drop := map[int]bool{}
	rewrite := map[int]string{}
	var appended []string
	for _, key := range slices.Sorted(maps.Keys(set)) {
		mine := slices.DeleteFunc(slices.Clone(d.entries), func(e envEntry) bool { return e.key != key })
		if len(mine) == 0 {
			appended = append(appended, envLine(key, set[key]))
			continue
		}
		for i, entry := range mine {
			for line := entry.first; line <= entry.last; line++ {
				drop[line] = true
			}
			if i == len(mine)-1 {
				delete(drop, entry.first)
				rewrite[entry.first] = envLine(key, set[key])
			}
		}
	}
	for _, key := range unset {
		if _, ok := set[key]; ok {
			continue
		}
		for _, entry := range d.entries {
			if entry.key == key {
				for line := entry.first; line <= entry.last; line++ {
					drop[line] = true
				}
			}
		}
	}
	var out []string
	for i, line := range d.lines {
		switch {
		case rewrite[i] != "":
			out = append(out, rewrite[i])
		case !drop[i]:
			out = append(out, line)
		}
	}
	if len(appended) > 0 {
		if n := len(out); n > 0 && out[n-1] == "" {
			out = append(slices.Concat(out[:n-1], appended), "")
		} else if n == 0 || n == 1 && out[0] == "" {
			out = append(appended, "")
		} else {
			out = append(slices.Concat(out, appended), "")
		}
	}
	return []byte(strings.Join(out, "\n"))
}

// EditEnvFile applies EditEnv to the .env file at path (the file a link
// there names), none read as empty, and writes the result durably,
// keeping the file's mode: 0600 for a new one.
func EditEnvFile(path string, set map[string]string, unset []string) error {
	if target, err := filepath.EvalSymlinks(path); err == nil {
		path = target
	}
	data, err := os.ReadFile(path)
	if err != nil && !errors.Is(err, fs.ErrNotExist) {
		return err
	}
	mode := os.FileMode(0o600)
	if info, err := os.Stat(path); err == nil {
		mode = info.Mode().Perm()
	}
	return writeDurable(path, EditEnv(data, set, unset), mode, nil)
}

// bareValue is a value that reads back as written with no quotes.
var bareValue = regexp.MustCompile(`^[A-Za-z0-9_./:@%+=,~^-]*$`)

// envLine is key's assignment of value, quoted where a bare value would
// not read back the same: in single quotes, read literally, unless the
// value holds one or a line break; then in double quotes, escaped.
func envLine(key, value string) string {
	switch {
	case bareValue.MatchString(value):
		return key + "=" + value
	case !strings.ContainsAny(value, "'\n\r"):
		return key + "='" + value + "'"
	}
	return key + `="` + strings.NewReplacer(`\`, `\\`, `"`, `\"`, "\n", `\n`, "\r", `\r`).Replace(value) + `"`
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

// ReadEnvValues reads the .env file at path as Docker Compose and the
// engine read it: `NAME=value`, `export NAME=value` and `NAME: value`,
// quoted values as compose unquotes them, the last assignment of a name
// winning. A bare NAME, which compose fills from its environment, reads
// as "".
func ReadEnvValues(path string) (map[string]string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return parseDotenv(data).values(), nil
}

// CheckEnvFile answers the refusal the engine makes of the .env file at
// path before anything starts, nil for a coherent home's: a COMPOSE_*
// setting in any form (compose_env_refused, the first in byte order),
// then the boot's refusal of the head it holds, as a release reads its
// own .env.
func CheckEnvFile(path string) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	d := parseDotenv(data)
	if key := d.composeKey(); key != "" {
		return Refuse("compose_env_refused", map[string]string{"key": key})
	}
	_, err = headOf(d.values())
	return err
}
