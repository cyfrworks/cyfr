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

// The dotenv grammar Docker Compose reads .env with, as compose-go v2.9.1
// (the release Docker Compose 2.40 builds on) defines it in its dotenv
// and template packages, quirks included: the engine edits the file
// compose reads and must read every line as compose does. It is written
// here from that grammar as stated below, and
// TestReadEnvValuesReadsAsRealComposeDoes holds it to the installed
// compose.
//
// A statement starts at the first byte that is not space, line break or
// a comment line; `export` and space may lead it; its name runs to `=`,
// `:` or a line break (a bare name, which takes its value from the
// environment) over letters, digits, `_.-[]` and skipped space; a value
// in quotes runs to its closing quote, across lines, a backslash keeping
// itself and the byte after it but taking the quote it escapes as that
// quote alone; a double-quoted value then expands its escapes
// (expandEscapes) and is interpolated (substitute); any other value runs
// to the line's end, is cut at ` #` and trimmed, and is interpolated.
// What follows a closing quote on its line starts the next statement.

// dotenvSpace is space within a line, as the grammar skips it: the
// Latin-1 white space but the line break.
func dotenvSpace(r rune) bool {
	return r < 0x100 && r != '\n' && unicode.IsSpace(r)
}

// cutExport is src without a leading `export` that a tab, line break, form
// feed, carriage return or space follows, nor the space after it on its
// line; src itself when it has none.
func cutExport(src string) string {
	rest, ok := strings.CutPrefix(src, "export")
	if !ok || rest == "" || !strings.ContainsRune("\t\n\f\r ", rune(rest[0])) {
		return src
	}
	return strings.TrimLeftFunc(rest, dotenvSpace)
}

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
		cut = nextStatement(cut)
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

// nextStatement is src from its next statement on, past space, line
// breaks and comment lines; "" when none is left.
func nextStatement(src string) string {
	for {
		src = strings.TrimLeftFunc(src, unicode.IsSpace)
		if !strings.HasPrefix(src, "#") {
			return src
		}
		_, after, found := strings.Cut(src, "\n")
		if !found {
			return ""
		}
		src = after
	}
}

// keyName reads a statement's name, after any leading `export`: the
// characters a name may hold and space, which the name drops at its end,
// up to `=`, `:` or a line break, which makes it a bare name. It answers
// the rest from the value's first byte that is not space; ok is false for
// a character no name holds. A name with no separator after it is no
// name: the text is the value of the name "".
func keyName(src string) (key, rest string, inherit, ok bool) {
	src = cutExport(src)
	end := strings.IndexFunc(src, func(r rune) bool { return r == '=' || r == ':' || r == '\n' })
	head := src
	if end >= 0 {
		head = src[:end]
	}
	if strings.ContainsFunc(head, func(r rune) bool { return !dotenvSpace(r) && !keyRune(r) }) {
		return "", "", false, false
	}
	if end < 0 {
		return "", strings.TrimLeftFunc(src, dotenvSpace), false, true
	}
	return strings.TrimRightFunc(head, unicode.IsSpace), strings.TrimLeftFunc(src[end+1:], dotenvSpace), src[end] == '\n', true
}

// keyRune is a character a name may hold: a letter, a digit, `_`, `.`,
// `-`, `[` or `]`.
func keyRune(r rune) bool {
	return unicode.IsLetter(r) || unicode.IsNumber(r) || strings.ContainsRune("_.-[]", r)
}

// valueText reads a value at the start of src: its quote, its text after
// the quote's escapes (a bare value's cut at ` #` and trimmed), and the
// bytes it takes, up to its closing quote or its line's break. ok is
// false for a quote that never closes.
func valueText(src string) (quote byte, text string, n int, ok bool) {
	if src == "" || src[0] != '"' && src[0] != '\'' {
		n = strings.IndexByte(src, '\n')
		if n < 0 {
			n = len(src)
		}
		text, _, _ = strings.Cut(src[:n], " #")
		return 0, strings.TrimRightFunc(text, unicode.IsSpace), n, true
	}
	quote = src[0]
	var b strings.Builder
	for i := 1; i < len(src); i++ {
		switch {
		case src[i] == quote:
			return quote, b.String(), i + 1, true
		case src[i] == '\\' && i+1 < len(src) && src[i+1] == quote:
			// A backslash takes the quote after it as that quote alone,
			b.WriteByte(quote)
			i++
		case src[i] == '\\' && i+1 < len(src):
			// and keeps itself and any other byte after it.
			b.WriteString(src[i : i+2])
			i++
		default:
			b.WriteByte(src[i])
		}
	}
	return 0, "", 0, false
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

// expandEscapes expands a double-quoted value's escapes: \a \b \f \n \r
// \t \v \" and \\ are the characters they name; \$ becomes $$, a dollar
// the interpolation keeps; \0 with up to three digits after it is the
// character those digits name in octal when they are three octal digits
// worth at most 255, and otherwise a backslash and those digits, the 0
// dropped; \c and a backslash before anything else stay as written.
func expandEscapes(s string) string {
	named := map[byte]string{'a': "\a", 'b': "\b", 'f': "\f", 'n': "\n", 'r': "\r", 't': "\t", 'v': "\v", '"': `"`, '\\': `\`, '$': "$$", 'c': `\c`}
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		if s[i] != '\\' || i+1 == len(s) {
			b.WriteByte(s[i])
			continue
		}
		if text, ok := named[s[i+1]]; ok {
			b.WriteString(text)
			i++
			continue
		}
		if s[i+1] != '0' {
			b.WriteByte('\\')
			continue
		}
		digits := s[i+2 : i+2]
		for j := i + 2; j < len(s) && j < i+5 && s[j] >= '0' && s[j] <= '9'; j++ {
			digits = s[i+2 : j+1]
		}
		if n, err := strconv.ParseUint(digits, 8, 16); err == nil && len(digits) == 3 && n <= 255 {
			b.WriteRune(rune(n))
		} else {
			b.WriteString(`\` + digits)
		}
		i += 1 + len(digits)
	}
	return b.String()
}

// templateError is an interpolation compose refuses: an invalid ${, or a
// required variable unset.
type templateError struct{}

func (templateError) Error() string { return "reach: an interpolation compose refuses" }

// The interpolation grammar, read from left to right: `$$`; `$` and a
// name (an ASCII letter or `_`, then letters, digits and `_`, the letters
// read without case under Unicode simple case folding, so a character
// whose folding reaches an ASCII letter is one: the long s for s, the
// Kelvin sign for k);
// `${`, a name and `}`; `${`, a name, an operator (`:?` `?` `:-` `-` `:+`
// `+`) and everything up to the last `}` before the line ends; and `${`
// followed by anything else, which is invalid. A `$` that starts none of
// them is a dollar.

func nameStart(r rune) bool {
	if r == '_' {
		return true
	}
	for f := r; ; {
		if f >= 'a' && f <= 'z' || f >= 'A' && f <= 'Z' {
			return true
		}
		if f = unicode.SimpleFold(f); f == r {
			return false
		}
	}
}

// nameLen is the length in bytes of the name at the start of s, 0 for
// none.
func nameLen(s string) int {
	n := 0
	for i, r := range s {
		if !nameStart(r) && (i == 0 || r < '0' || r > '9') {
			break
		}
		n = i + utf8.RuneLen(r)
	}
	return n
}

// operatorLen is the length of the operator at the start of s, 0 for
// none.
func operatorLen(s string) int {
	switch {
	case len(s) > 1 && s[0] == ':' && strings.IndexByte("-+?", s[1]) >= 0:
		return 2
	case s != "" && strings.IndexByte("-+?", s[0]) >= 0:
		return 1
	}
	return 0
}

// bracedLen is the length of the braced interpolation at the start of
// s, which begins `${`, or 0 when it is not one.
func bracedLen(s string) int {
	name := nameLen(s[2:])
	if name == 0 {
		return 0
	}
	at := 2 + name
	if op := operatorLen(s[at:]); op > 0 {
		line := s[at+op:]
		if end := strings.IndexByte(line, '\n'); end >= 0 {
			line = line[:end]
		}
		if last := strings.LastIndexByte(line, '}'); last >= 0 {
			return at + op + last + 1
		}
	}
	if at < len(s) && s[at] == '}' {
		return at + 1
	}
	return 0
}

// interpolationLen is the length of the interpolation at the start of s,
// 0 when a dollar there starts none.
func interpolationLen(s string) int {
	if len(s) < 2 || s[0] != '$' {
		return 0
	}
	switch {
	case s[1] == '$':
		return 2
	case s[1] == '{':
		if n := bracedLen(s); n > 0 {
			return n
		}
		return 2
	}
	if n := nameLen(s[1:]); n > 0 {
		return 1 + n
	}
	return 0
}

// substitute interpolates s, every interpolation replaced, the first
// error answered once all are.
func substitute(s string, lookup func(string) (string, bool)) (string, error) {
	var b strings.Builder
	var first error
	for i := 0; i < len(s); {
		n := interpolationLen(s[i:])
		if n == 0 {
			b.WriteByte(s[i])
			i++
			continue
		}
		v, err := interpolated(s[i:i+n], lookup)
		if err != nil && first == nil {
			first = err
		}
		b.WriteString(v)
		i += n
	}
	return b.String(), first
}

// interpolated is one interpolation's value. Its operator is the first in
// the whole of it, which may run past the brace that closes it; that
// brace is the one closing the first `{` (closingBrace), and what follows
// it is interpolated on its own after the operator is applied.
func interpolated(m string, lookup func(string) (string, bool)) (string, error) {
	if m == "$$" {
		return "$", nil
	}
	op := firstOperator(m)
	rest := ""
	if i := closingBrace(m); i > -1 {
		m, rest = m[:i+1], m[i+1:]
	}
	if m[1] != '{' {
		v, _ := lookup(m[1:])
		return v, nil
	}
	n := bracedLen(m)
	if n == 0 {
		return "", templateError{}
	}
	inside := m[2 : n-1]
	value, applied, err := applyOperator(op, inside, lookup)
	switch {
	case err != nil:
		return "", err
	case applied:
		nested, err := substitute(rest, lookup)
		if err != nil {
			return "", err
		}
		return value + nested, nil
	}
	v, _ := lookup(inside)
	return v, nil
}

// firstOperator is the operator that starts earliest in m, "" for none.
func firstOperator(m string) string {
	for i := range len(m) {
		if n := operatorLen(m[i:]); n > 0 {
			return m[i : i+n]
		}
	}
	return ""
}

// closingBrace is the index of the `}` that closes s's first `{`,
// counting each `{` up, which also passes over the byte after it, and
// each `}` down; -1 when none does.
func closingBrace(s string) int {
	depth := 0
	for i := 0; i < len(s); i++ {
		switch s[i] {
		case '}':
			if depth--; depth == 0 {
				return i
			}
		case '{':
			depth++
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
