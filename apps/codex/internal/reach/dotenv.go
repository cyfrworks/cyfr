// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package reach

import (
	"maps"
	"os"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"
)

// The dotenv grammar Docker Compose reads .env with: compose-go's dotenv
// and template packages (v2.9.1, the release Docker Compose 2.40 builds
// on), reproduced rule for rule, quirks included, because the engine
// edits the file compose reads and must read every line as compose does.
// A statement starts at the first byte that is not space, line break or
// a comment line; `export` and space may lead it; its name runs to `=`,
// `:` or a line break (a bare name, which takes its value from the
// environment) over letters, digits, `_.-[]` and skipped space; a value
// in quotes runs to its closing quote, across lines, a backslash keeping
// itself and the byte after it but taking the quote it escapes as that
// quote alone; a double-quoted value then expands \a \b \c \f \n \r \t \v
// \$ \" \\ and \0 octal escapes and is interpolated; any other value runs
// to the line's end, is cut at ` #` and trimmed, and is interpolated.
// What follows a closing quote on its line starts the next statement.

// dotenvSpace is space within a line, as the grammar skips it: every
// space but the line break.
func dotenvSpace(r rune) bool {
	switch r {
	case '\t', '\v', '\f', '\r', ' ', 0x85, 0xA0:
		return true
	}
	return false
}

var (
	dotenvExport = regexp.MustCompile(`^export\s+`)
	dotenvEscape = regexp.MustCompile(`(\\(?:[abcfnrtv$"\\]|0\d{0,3}))`)
	// dotenvTemplate is compose's interpolation pattern: $$, $NAME,
	// ${NAME} with an optional operator and the rest, and ${ followed by
	// anything else, which is invalid.
	dotenvTemplate = regexp.MustCompile(`\$(?i:(?P<escaped>\$)|(?P<named>[_a-z][_a-z0-9]*)|{(?:(?P<braced>[_a-z][_a-z0-9]*(?::?[-+?](.*))?)}|(?P<invalid>)))`)
)

const utf8BOM = "\uFEFF"

// statement is one statement of a .env file: its name; whether it is a
// bare name; its value's quote (0 for none) and text after the quote's
// own escapes; and where it is, from its first byte (`export` included)
// to the end of its value, a closing quote included, its line's text
// after a bare value included.
type statement struct {
	key        string
	inherit    bool
	quote      byte
	text       string
	start, end int
	// raw is the value as written, from its first byte to the end of
	// the statement.
	raw string
}

// dotenvError is where the grammar stops reading: the byte offset of the
// statement it cannot read.
type dotenvError struct{ at int }

func (e *dotenvError) Error() string {
	return "reach: .env does not read at byte " + strconv.Itoa(e.at)
}

// scanDotenv reads the statements of src, stopping at the first it cannot
// read. With lenient it reads on from the next line instead, as the
// redactor reads a malformed file, and answers the first error too.
func scanDotenv(src string, lenient bool, broken func(at int, line string)) ([]statement, error) {
	var out []statement
	var first error
	cut := strings.TrimPrefix(src, utf8BOM)
	offset := func(s string) int { return len(src) - len(s) }
	fail := func(at int) bool {
		if first == nil {
			first = &dotenvError{at: at}
		}
		if !lenient {
			return false
		}
		line, rest, _ := strings.Cut(src[at:], "\n")
		if broken != nil {
			broken(at, line)
		}
		cut = rest
		return true
	}
	for {
		cut = statementStart(cut)
		if cut == "" {
			return out, first
		}
		st := statement{start: offset(cut)}
		key, rest, inherit, ok := keyName(cut)
		if !ok || strings.Contains(key, " ") {
			if !fail(st.start) {
				return out, first
			}
			continue
		}
		st.key, st.inherit = key, inherit
		if inherit {
			// The name's line break ends it.
			st.end = strings.IndexByte(src[st.start:], '\n') + st.start
			out = append(out, st)
			cut = rest
			continue
		}
		valueAt := offset(rest)
		quote, text, n, ok := valueText(rest)
		if !ok {
			if !fail(st.start) {
				return out, first
			}
			continue
		}
		st.quote, st.text, st.end = quote, text, valueAt+n
		st.raw = src[valueAt:st.end]
		out = append(out, st)
		cut = src[st.end:]
		if quote == 0 && st.end < len(src) {
			// A bare value's line break is its own.
			cut = src[st.end+1:]
		}
	}
}

// statementStart skips space, line breaks and comment lines.
func statementStart(src string) string {
	for {
		pos := strings.IndexFunc(src, func(r rune) bool { return !unicode.IsSpace(r) })
		if pos < 0 {
			return ""
		}
		src = src[pos:]
		if src[0] != '#' {
			return src
		}
		pos = strings.IndexByte(src, '\n')
		if pos < 0 {
			return ""
		}
		src = src[pos:]
	}
}

// keyName reads a statement's name: its rest, from the value's first
// byte that is not space, and whether a line break ended it (a bare
// name). A name that runs to the end of the text is no name: the text is
// the value of the name "".
func keyName(src string) (key, rest string, inherit, ok bool) {
	if dotenvExport.MatchString(src) {
		src = strings.TrimLeftFunc(strings.TrimPrefix(src, "export"), dotenvSpace)
	}
	offset := 0
loop:
	for i, r := range src {
		if dotenvSpace(r) {
			continue
		}
		switch r {
		case '=', ':', '\n':
			key, offset, inherit = src[:i], i+1, r == '\n'
			break loop
		case '_', '.', '-', '[', ']':
		default:
			if unicode.IsLetter(r) || unicode.IsNumber(r) {
				continue
			}
			return "", "", false, false
		}
	}
	return strings.TrimRightFunc(key, unicode.IsSpace), strings.TrimLeftFunc(src[offset:], dotenvSpace), inherit, true
}

// valueText reads a value at the start of src: its quote, its text after
// the quote's escapes (a bare value's cut at ` #` and trimmed), and the
// bytes it takes, up to its closing quote or its line's break. ok is
// false for a quote that never closes.
func valueText(src string) (quote byte, text string, n int, ok bool) {
	if src != "" && (src[0] == '"' || src[0] == '\'') {
		quote = src[0]
		escaped := false
		var chars []byte
		for i := 1; i < len(src); i++ {
			c := src[i]
			switch {
			case c != quote && !escaped && c == '\\':
				escaped = true
			case c != quote:
				if escaped {
					escaped = false
					chars = append(chars, '\\')
				}
				chars = append(chars, c)
			case escaped:
				escaped = false
				chars = append(chars, c)
			default:
				return quote, string(chars), i + 1, true
			}
		}
		return 0, "", 0, false
	}
	n = strings.IndexByte(src, '\n')
	if n < 0 {
		n = len(src)
	}
	text, _, _ = strings.Cut(src[:n], " #")
	return 0, strings.TrimRightFunc(text, unicode.IsSpace), n, true
}

// value is the statement's value as compose reads it, interpolated
// through lookup.
func (st statement) value(lookup func(string) (string, bool)) (string, error) {
	switch st.quote {
	case '\'':
		return st.text, nil
	case '"':
		return substitute(expandEscapes(st.text), lookup)
	}
	return substitute(st.text, lookup)
}

func expandEscapes(s string) string {
	return dotenvEscape.ReplaceAllStringFunc(s, func(m string) string {
		if m == `\$` {
			return "$$"
		}
		if strings.HasPrefix(m, `\0`) {
			m = strings.Replace(m, `\0`, `\`, 1)
		}
		v, _, _, err := strconv.UnquoteChar(m, '"')
		if err != nil {
			return m
		}
		return string(v)
	})
}

// templateError is an interpolation compose refuses: an invalid ${, or a
// required variable unset.
type templateError struct{}

func (templateError) Error() string { return "reach: an interpolation compose refuses" }

// substitute interpolates s as compose's template.Substitute does, the
// first error answered after every match is replaced.
func substitute(s string, lookup func(string) (string, bool)) (string, error) {
	var first error
	out := dotenvTemplate.ReplaceAllStringFunc(s, func(m string) string {
		v, _, err := replaceTemplate(m, lookup)
		if err != nil && first == nil {
			first = err
		}
		return v
	})
	return out, first
}

// replaceTemplate is one match's replacement: its operator is chosen from
// the whole match, which the pattern's greedy tail may have carried past
// the brace that closes it; what follows that brace is interpolated on
// its own.
func replaceTemplate(m string, lookup func(string) (string, bool)) (string, bool, error) {
	op := templateOperator(m)
	rest := ""
	if i := closingBrace(m); i > -1 {
		rest, m = m[i+1:], m[:i+1]
	}
	sub := dotenvTemplate.FindStringSubmatch(m)
	group := func(name string) string {
		if sub == nil {
			return ""
		}
		return sub[dotenvTemplate.SubexpIndex(name)]
	}
	if escaped := group("escaped"); escaped != "" {
		return escaped, true, nil
	}
	name, braced := group("named"), false
	if name == "" {
		name, braced = group("braced"), true
	}
	if name == "" {
		return "", false, templateError{}
	}
	if braced {
		value, applied, err := applyOperator(op, name, lookup)
		if err != nil {
			return "", false, err
		}
		if applied {
			nested, err := substitute(rest, lookup)
			if err != nil {
				return "", false, err
			}
			return value + nested, true, nil
		}
	}
	value, ok := lookup(name)
	return value, ok, nil
}

// templateOperators are compose's operators, in the order it lists them.
var templateOperators = []string{":?", "?", ":-", "-", ":+", "+"}

// templateOperator is the operator that appears first in m, the earlier
// of the list on a tie, "" for none.
func templateOperator(m string) string {
	best, at := "", -1
	for _, op := range templateOperators {
		if i := strings.Index(m, op); i >= 0 && (at < 0 || i < at) {
			best, at = op, i
		}
	}
	return best
}

func closingBrace(s string) int {
	open := 0
	for i := 0; i < len(s); i++ {
		if s[i] == '}' {
			open--
			if open == 0 {
				return i
			}
		}
		if s[i] == '{' {
			open++
			i++
		}
	}
	return -1
}

// applyOperator applies op to sub, NAME then op then its word; applied is
// false when sub does not hold op.
func applyOperator(op, sub string, lookup func(string) (string, bool)) (string, bool, error) {
	if op == "" || !strings.Contains(sub, op) {
		return "", false, nil
	}
	name, word, _ := strings.Cut(sub, op)
	word, err := substitute(word, lookup)
	if err != nil {
		return "", false, err
	}
	value, set := lookup(name)
	switch op {
	case ":?":
		if !set || value == "" {
			return "", true, templateError{}
		}
	case "?":
		if !set {
			return "", true, templateError{}
		}
	case ":-":
		if !set || value == "" {
			return word, true, nil
		}
	case "-":
		if !set {
			return word, true, nil
		}
	case ":+":
		if set && value != "" {
			return word, true, nil
		}
	case "+":
		if set {
			return word, true, nil
		}
	}
	return value, true, nil
}

// composeEnv is the environment the engine runs compose with: cyfr's,
// every COMPOSE_* variable removed (sanitizedEnv).
func composeEnv(name string) (string, bool) {
	if strings.HasPrefix(strings.ToUpper(name), "COMPOSE_") {
		return "", false
	}
	return os.LookupEnv(name)
}

// dotenv is a .env file read as Docker Compose reads it, held as its
// lines, its statements and the values compose gives a service that
// takes it as its env_file.
type dotenv struct {
	text       string
	lines      []string
	statements []statement
	env        map[string]string
}

// readDotenv reads data as compose reads .env, interpolating from env,
// the environment compose runs with. Compose reads it twice: first as the
// project's environment, each value interpolated from env, then from the
// names read before it; then as the service's env_file, each value
// interpolated from the project's environment (env over the first read)
// and then from the names read before it, a bare name taking the
// project's value. A statement compose cannot read is refused naming its
// line (compose_env_refused), never its text.
func readDotenv(data []byte, env func(string) (string, bool)) (*dotenv, error) {
	d, err := parseDotenv(data, env)
	if err != nil {
		return nil, d.lineRefusal(err.at)
	}
	return d, nil
}

// parseDotenv is readDotenv's read: the statements read, all of them
// unless the error is where one could not be read, and the error.
func parseDotenv(data []byte, env func(string) (string, bool)) (*dotenv, *dotenvError) {
	d := &dotenv{text: string(data), lines: strings.Split(string(data), "\n"), env: map[string]string{}}
	stmts, err := scanDotenv(d.text, false, nil)
	d.statements = stmts
	if err != nil {
		return d, err.(*dotenvError)
	}
	project := map[string]string{}
	first := func(k string) (string, bool) {
		if v, ok := env(k); ok {
			return v, true
		}
		v, ok := project[k]
		return v, ok
	}
	for _, st := range stmts {
		if st.inherit {
			if v, ok := first(st.key); ok {
				project[st.key] = v
			}
			continue
		}
		v, err := st.value(first)
		if err != nil {
			return d, &dotenvError{at: st.start}
		}
		project[st.key] = v
	}
	second := func(k string) (string, bool) {
		if v, ok := first(k); ok {
			return v, true
		}
		v, ok := d.env[k]
		return v, ok
	}
	for _, st := range stmts {
		if st.inherit {
			if v, ok := first(st.key); ok {
				d.env[st.key] = v
			}
			continue
		}
		v, err := st.value(second)
		if err != nil {
			return d, &dotenvError{at: st.start}
		}
		d.env[st.key] = v
	}
	return d, nil
}

// lineOf is the 1-based line of byte offset at.
func (d *dotenv) lineOf(at int) int { return strings.Count(d.text[:at], "\n") + 1 }

// lineRefusal refuses the .env line holding byte at.
func (d *dotenv) lineRefusal(at int) *Refusal {
	return Refuse("compose_env_refused", map[string]string{"line": strconv.Itoa(d.lineOf(at))})
}

// values are the names .env gives the service and their values, the last
// assignment of each winning; a bare name the environment does not set is
// absent.
func (d *dotenv) values() map[string]string { return maps.Clone(d.env) }

// lines of a statement, 0-based, first to last.
func (d *dotenv) span(st statement) (first, last int) {
	last = st.end - 1
	if last < st.start {
		last = st.start
	}
	return d.lineOf(st.start) - 1, d.lineOf(last) - 1
}

// bareValue is a value that reads back as written with no quotes.
var bareValue = regexp.MustCompile(`^[A-Za-z0-9_./:@%+=,~^-]*$`)

// envLine is key's assignment of value, as compose reads it back byte for
// byte: bare where a bare value reads the same, else in single quotes,
// which compose reads literally, each quote escaped. A value single
// quotes cannot carry, an odd run of backslashes before a quote or at the
// end, which would escape the quote after it, is refused.
func envLine(key, value string) (string, error) {
	line, quote := key+"="+value, byte(0)
	if !bareValue.MatchString(value) {
		run := 0
		for i := 0; i <= len(value); i++ {
			if i < len(value) && value[i] == '\\' {
				run++
				continue
			}
			if run%2 == 1 && (i == len(value) || value[i] == '\'') {
				return "", unwritable(key)
			}
			run = 0
		}
		line, quote = key+"='"+strings.ReplaceAll(value, "'", `\'`)+"'", '\''
	}
	// What compose reads back is the value itself, or nothing is written.
	if st, err := scanDotenv(line, false, nil); err != nil || len(st) != 1 || st[0].key != key || st[0].inherit || st[0].quote != quote || st[0].text != value {
		return "", unwritable(key)
	}
	return line, nil
}

// unwritable refuses to write key's value, which no line compose reads
// back as written carries; it names the key, never the value.
func unwritable(key string) error {
	return &unwritableError{key: key}
}

type unwritableError struct{ key string }

func (e *unwritableError) Error() string {
	return "reach: the value of " + e.key + " cannot be written to .env so that Docker Compose reads it back as it is (a backslash at its end, or before a quote, escapes what follows it). Nothing was written"
}

// sameStatements reports whether two reads hold the same statements, but
// those of names, which an edit changes, in the same order with the same
// text; where they do not, the offset in a of the first that differs (its
// last statement's end when b holds more).
func sameStatements(a, b []statement, names map[string]bool) (int, bool) {
	keep := func(s []statement) []statement {
		return slices.DeleteFunc(slices.Clone(s), func(st statement) bool { return names[st.key] })
	}
	ka, kb := keep(a), keep(b)
	for i := range ka {
		if i >= len(kb) || ka[i].key != kb[i].key || ka[i].inherit != kb[i].inherit || ka[i].quote != kb[i].quote || ka[i].text != kb[i].text {
			return ka[i].start, false
		}
	}
	if len(kb) > len(ka) {
		if len(a) == 0 {
			return 0, false
		}
		return a[len(a)-1].start, false
	}
	return 0, true
}

// runes is the length of s in characters.
func runes(s string) int { return utf8.RuneCountInString(s) }
