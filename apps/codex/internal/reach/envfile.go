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
	"slices"
	"strconv"
	"strings"
)

// composeKey is the first name, in byte order, of the COMPOSE_* settings
// .env names, which Docker Compose would read to choose the stack's
// files, project or profiles, or "".
func (d *dotenv) composeKey() string {
	var keys []string
	for _, st := range d.statements {
		if strings.HasPrefix(st.key, "COMPOSE_") {
			keys = append(keys, st.key)
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

// statementsOf are the statements of key, in order.
func (d *dotenv) statementsOf(key string) []statement {
	return slices.DeleteFunc(slices.Clone(d.statements), func(st statement) bool { return st.key != key })
}

// headEdit is the edit that gives .env the head keys want names: a key
// whose value is already that is left as it is written, so its spelling
// stays; a changed key is set; a key the head omits is unset.
func (d *dotenv) headEdit(want map[string]string) (set map[string]string, unset []string) {
	held := d.heldKeys()
	set = map[string]string{}
	for _, key := range headKeys() {
		value := want[key]
		mine := d.statementsOf(key)
		inherits := slices.ContainsFunc(mine, func(st statement) bool { return st.inherit })
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

// editHeadKeys is text, a .env file, with the head keys want names
// (headEdit), every other line as it was.
func editHeadKeys(text []byte, want map[string]string) ([]byte, error) {
	d, err := readDotenv(text, composeEnv)
	if err != nil {
		return nil, err
	}
	set, unset := d.headEdit(want)
	return d.edit(set, unset)
}

// EditEnv is text, a .env file, with every key of set assigned its value
// and every key of unset assigned none, read with the grammar compose
// reads .env with (readDotenv): a set key's last statement is rewritten
// and its earlier ones removed, a key it lacks is appended at the end;
// an unset key loses every statement, a bare name included. Every other
// line, a quoted value's lines across several included, is kept byte for
// byte. A value is written as compose reads it back byte for byte
// (envLine), or refused. A file compose cannot read, or one whose other
// statements the edit would change (two on one line, a bare name at its
// very end), is refused naming the line (compose_env_refused), and
// nothing is written.
func EditEnv(text []byte, set map[string]string, unset []string) ([]byte, error) {
	return editEnv(text, set, unset)
}

func editEnv(text []byte, set map[string]string, unset []string) ([]byte, error) {
	d, err := readDotenv(text, composeEnv)
	if err != nil {
		return nil, err
	}
	return d.edit(set, unset)
}

func (d *dotenv) edit(set map[string]string, unset []string) ([]byte, error) {
	drop := map[int]bool{}
	rewrite := map[int]string{}
	var appended []string
	for _, key := range slices.Sorted(maps.Keys(set)) {
		line, err := envLine(key, set[key])
		if err != nil {
			return nil, err
		}
		mine := d.statementsOf(key)
		if len(mine) == 0 {
			appended = append(appended, line)
			continue
		}
		for i, st := range mine {
			first, last := d.span(st)
			for n := first; n <= last; n++ {
				drop[n] = true
			}
			if i == len(mine)-1 {
				delete(drop, first)
				rewrite[first] = line
			}
		}
	}
	for _, key := range unset {
		if _, ok := set[key]; ok {
			continue
		}
		for _, st := range d.statementsOf(key) {
			first, last := d.span(st)
			for n := first; n <= last; n++ {
				drop[n] = true
			}
		}
	}
	// A line the edit changes holds one statement alone: another would
	// change with it.
	owners := map[int]int{}
	for _, st := range d.statements {
		first, last := d.span(st)
		for n := first; n <= last; n++ {
			owners[n]++
		}
	}
	for n := range len(d.lines) {
		if (drop[n] || rewrite[n] != "") && owners[n] > 1 {
			return nil, Refuse("compose_env_refused", map[string]string{"line": strconv.Itoa(n + 1)})
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
	text := []byte(strings.Join(out, "\n"))
	// The edit reads back as compose reads it with exactly the change
	// asked for, every other statement as it was, or nothing is written.
	names := map[string]bool{}
	for k := range set {
		names[k] = true
	}
	for _, k := range unset {
		names[k] = true
	}
	after, perr := parseDotenv(text, composeEnv)
	if at, ok := sameStatements(d.statements, after.statements, names); !ok {
		return nil, d.lineRefusal(at)
	}
	if perr != nil {
		return nil, d.lineRefusal(d.counterpart(after, perr.at, names))
	}
	for k := range names {
		want, isSet := set[k]
		got, has := after.env[k]
		mine := after.statementsOf(k)
		switch {
		case isSet && (!has || got != want || len(mine) != 1):
			return nil, unwritable(k)
		case !isSet && len(mine) != 0:
			at := d.lastStart()
			if before := d.statementsOf(k); len(before) > 0 {
				at = before[0].start
			}
			return nil, d.lineRefusal(at)
		}
	}
	return text, nil
}

// counterpart is the offset in d of the statement an edit of it, after,
// holds at offset at, the statements of names aside: the edited file
// reads them in the same order. A statement d has no counterpart of is
// said by d's last.
func (d *dotenv) counterpart(after *dotenv, at int, names map[string]bool) int {
	n := 0
	for _, st := range after.statements {
		if st.start == at {
			if names[st.key] {
				break
			}
			for _, mine := range d.statements {
				if names[mine.key] {
					continue
				}
				if n == 0 {
					return mine.start
				}
				n--
			}
			break
		}
		if !names[st.key] {
			n++
		}
	}
	return d.lastStart()
}

// lastStart is the offset of the file's last statement, 0 for none.
func (d *dotenv) lastStart() int {
	if len(d.statements) == 0 {
		return 0
	}
	return d.statements[len(d.statements)-1].start
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
	out, err := editEnv(data, set, unset)
	if err != nil {
		return err
	}
	return writeDurable(path, out, mode, nil)
}

// readEnv reads the project's .env, nil when there is none, and refuses
// one compose cannot read (compose_env_refused naming the line) or one
// that names a COMPOSE_* setting.
func (e *Engine) readEnv() (*dotenv, error) {
	data, err := os.ReadFile(e.envPath())
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	d, err := readDotenv(data, composeEnv)
	if err != nil {
		return nil, err
	}
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

// ReadEnvValues reads the .env file at path as Docker Compose reads it
// for a service that takes it as its env_file, with no environment:
// entries of its own (readDotenv): every name it assigns and its value,
// interpolated from this process's environment as compose run by cyfr
// interpolates it, the last statement of a name winning; a bare name
// takes its value from the environment, and is absent when that holds
// none. A file compose cannot read is refused naming the line.
func ReadEnvValues(path string) (map[string]string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	d, err := readDotenv(data, composeEnv)
	if err != nil {
		return nil, err
	}
	return d.values(), nil
}

// CheckEnvFile answers the refusal the engine makes of the .env file at
// path before anything starts, nil for a coherent home's: a file compose
// cannot read (compose_env_refused naming the line), a COMPOSE_* setting
// in any form (compose_env_refused, the first in byte order), then the
// boot's refusal of the head it holds, as a release reads its own .env.
func CheckEnvFile(path string) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	return checkEnv(data)
}

func checkEnv(data []byte) error {
	d, err := readDotenv(data, composeEnv)
	if err != nil {
		return err
	}
	if key := d.composeKey(); key != "" {
		return Refuse("compose_env_refused", map[string]string{"key": key})
	}
	_, err = headOf(d.values())
	return err
}
