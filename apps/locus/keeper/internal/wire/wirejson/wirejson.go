// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Package wirejson reads JSON as Prima's reader (Jason) reads it and
// writes it as Prima's writer writes it, byte for byte, for every wire of
// the packages under internal/wire. encoding/json differs from both:
// it keeps the last of a member given twice, replaces bytes that are no
// UTF-8 with U+FFFD rather than refusing them, and always escapes U+2028
// and U+2029, writing control characters in lowercase hexadecimal.
//
// Read reads one value:
//   - an object is a map, and a member given twice is its first;
//   - a string is UTF-8, refused when its bytes are not, when it holds a
//     raw control character or when an escape names half a surrogate pair;
//   - a number is its text (Number), an integer when it has no fraction or
//     exponent, "-0" among them; an integer of more than 1,024 characters
//     and a number past a double's range are no JSON, one below it reads;
//   - whitespace is space, tab, line feed and carriage return, before and
//     after the value; nothing else may follow it;
//   - a document nested deeper than MaxDepth arrays and objects is refused
//     before it is parsed (ErrTooDeep).
//
// Read bounds the depth it parses to; the size of what it reads is its
// caller's bound, set before the bytes are read (a body's, at most
// Prima.HostAPI.max_body_bytes/0). A refusal names no byte of what it
// refused, so nothing a peer sent reaches an error or a log through it.
package wirejson

import (
	"errors"
	"sort"
	"strconv"
	"strings"
	"unicode/utf16"
	"unicode/utf8"
)

// MaxDepth is the deepest nesting of arrays and objects a document is
// read to, as the runner's reader bounds it. No document of a wire comes
// near it.
const MaxDepth = 4096

// maxIntegerText is the longest integer Prima's reader reads, its sign
// included.
const maxIntegerText = 1024

// MaxSafeInteger is 2^53 − 1, the largest integer every JSON reader holds
// exactly: the domain of every integer field of the worker protocol.
const MaxSafeInteger = 1<<53 - 1

var (
	// ErrMalformed is a document that is not one JSON value as Prima
	// reads one.
	ErrMalformed = errors.New("malformed")
	// ErrTooDeep is a document nested deeper than MaxDepth.
	ErrTooDeep = errors.New("too_deep")
	// ErrUnwritable is a value Write does not write as Prima would: text
	// that is no UTF-8, a map of more than 32 members, whose order Prima's
	// writer does not fix, or a type of no JSON value.
	ErrUnwritable = errors.New("unwritable")
)

// Number is a number as its document spells it.
type Number string

// Integer is whether the number is an integer: no fraction, no exponent.
func (n Number) Integer() bool {
	for i := 0; i < len(n); i++ {
		switch n[i] {
		case '.', 'e', 'E':
			return false
		}
	}
	return true
}

// Uint is the integer v is when it is an integer from 0 to max; ok is false
// for any other value, a float or a negative integer included.
func Uint(v any, max uint64) (n uint64, ok bool) {
	num, isNum := v.(Number)
	if !isNum || !num.Integer() {
		return 0, false
	}
	text := string(num)
	if text == "-0" {
		return 0, true
	}
	if text[0] == '-' || len(text) > 20 {
		return 0, false
	}
	n, err := strconv.ParseUint(text, 10, 64)
	if err != nil || n > max {
		return 0, false
	}
	return n, true
}

// IsInteger is whether v is an integer of any size or sign.
func IsInteger(v any) bool {
	n, ok := v.(Number)
	return ok && n.Integer()
}

// Depth is the deepest nesting of arrays and objects in data outside
// strings, counted without recursion. A string runs from an unescaped
// quote to the next, as the parser reads one, so every level the parser
// would enter is counted.
func Depth(data []byte) int {
	level, deepest := 0, 0
	inString, escaped := false, false
	for _, b := range data {
		if inString {
			switch {
			case escaped:
				escaped = false
			case b == '\\':
				escaped = true
			case b == '"':
				inString = false
			}
			continue
		}
		switch b {
		case '"':
			inString = true
		case '[', '{':
			level++
			if level > deepest {
				deepest = level
			}
		case ']', '}':
			if level > 0 {
				level--
			}
		}
	}
	return deepest
}

// Read reads the one JSON value data spells: nil, a bool, a string, a
// Number, a []any or a map[string]any.
func Read(data []byte) (any, error) {
	if Depth(data) > MaxDepth {
		return nil, ErrTooDeep
	}
	p := parser{data: data}
	p.space()
	v, ok := p.value()
	if !ok {
		return nil, ErrMalformed
	}
	p.space()
	if p.at != len(p.data) {
		return nil, ErrMalformed
	}
	return v, nil
}

// Object reads data as one JSON object.
func Object(data []byte) (map[string]any, error) {
	v, err := Read(data)
	if err != nil {
		return nil, err
	}
	o, ok := v.(map[string]any)
	if !ok {
		return nil, ErrMalformed
	}
	return o, nil
}

type parser struct {
	data []byte
	at   int
}

func (p *parser) space() {
	for p.at < len(p.data) {
		switch p.data[p.at] {
		case ' ', '\t', '\n', '\r':
			p.at++
		default:
			return
		}
	}
}

func (p *parser) literal(word string) bool {
	if len(p.data)-p.at < len(word) || string(p.data[p.at:p.at+len(word)]) != word {
		return false
	}
	p.at += len(word)
	return true
}

func (p *parser) value() (any, bool) {
	if p.at >= len(p.data) {
		return nil, false
	}
	switch c := p.data[p.at]; {
	case c == '{':
		return p.object()
	case c == '[':
		return p.array()
	case c == '"':
		s, ok := p.str()
		return s, ok
	case c == 't':
		return true, p.literal("true")
	case c == 'f':
		return false, p.literal("false")
	case c == 'n':
		return nil, p.literal("null")
	case c == '-' || (c >= '0' && c <= '9'):
		return p.number()
	}
	return nil, false
}

func (p *parser) object() (any, bool) {
	p.at++
	members := map[string]any{}
	p.space()
	if p.at < len(p.data) && p.data[p.at] == '}' {
		p.at++
		return members, true
	}
	for {
		p.space()
		if p.at >= len(p.data) || p.data[p.at] != '"' {
			return nil, false
		}
		name, ok := p.str()
		if !ok {
			return nil, false
		}
		p.space()
		if p.at >= len(p.data) || p.data[p.at] != ':' {
			return nil, false
		}
		p.at++
		p.space()
		v, ok := p.value()
		if !ok {
			return nil, false
		}
		if _, given := members[name]; !given {
			members[name] = v
		}
		p.space()
		if p.at >= len(p.data) {
			return nil, false
		}
		switch p.data[p.at] {
		case ',':
			p.at++
		case '}':
			p.at++
			return members, true
		default:
			return nil, false
		}
	}
}

func (p *parser) array() (any, bool) {
	p.at++
	items := []any{}
	p.space()
	if p.at < len(p.data) && p.data[p.at] == ']' {
		p.at++
		return items, true
	}
	for {
		p.space()
		v, ok := p.value()
		if !ok {
			return nil, false
		}
		items = append(items, v)
		p.space()
		if p.at >= len(p.data) {
			return nil, false
		}
		switch p.data[p.at] {
		case ',':
			p.at++
		case ']':
			p.at++
			return items, true
		default:
			return nil, false
		}
	}
}

func digit(c byte) bool { return c >= '0' && c <= '9' }

func (p *parser) number() (any, bool) {
	start := p.at
	if p.data[p.at] == '-' {
		p.at++
	}
	switch {
	case p.at < len(p.data) && p.data[p.at] == '0':
		p.at++
	case p.at < len(p.data) && p.data[p.at] >= '1' && p.data[p.at] <= '9':
		for p.at < len(p.data) && digit(p.data[p.at]) {
			p.at++
		}
	default:
		return nil, false
	}
	float := false
	if p.at < len(p.data) && p.data[p.at] == '.' {
		float = true
		p.at++
		if p.at >= len(p.data) || !digit(p.data[p.at]) {
			return nil, false
		}
		for p.at < len(p.data) && digit(p.data[p.at]) {
			p.at++
		}
	}
	if p.at < len(p.data) && (p.data[p.at] == 'e' || p.data[p.at] == 'E') {
		float = true
		p.at++
		if p.at < len(p.data) && (p.data[p.at] == '+' || p.data[p.at] == '-') {
			p.at++
		}
		if p.at >= len(p.data) || !digit(p.data[p.at]) {
			return nil, false
		}
		for p.at < len(p.data) && digit(p.data[p.at]) {
			p.at++
		}
	}
	text := string(p.data[start:p.at])
	if !float {
		return Number(text), len(text) <= maxIntegerText
	}
	if _, err := strconv.ParseFloat(text, 64); err != nil {
		return nil, false
	}
	return Number(text), true
}

func hexValue(b []byte) (rune, bool) {
	var r rune
	for _, c := range b {
		r <<= 4
		switch {
		case c >= '0' && c <= '9':
			r |= rune(c - '0')
		case c >= 'a' && c <= 'f':
			r |= rune(c-'a') + 10
		case c >= 'A' && c <= 'F':
			r |= rune(c-'A') + 10
		default:
			return 0, false
		}
	}
	return r, true
}

func (p *parser) escapeU() (rune, bool) {
	// p.at is at the 'u' of `\u`.
	if len(p.data)-p.at < 5 {
		return 0, false
	}
	r, ok := hexValue(p.data[p.at+1 : p.at+5])
	if !ok {
		return 0, false
	}
	p.at += 5
	return r, true
}

func (p *parser) str() (string, bool) {
	p.at++
	var out []byte
	runStart := p.at
	for p.at < len(p.data) {
		c := p.data[p.at]
		switch {
		case c == '"':
			out = append(out, p.data[runStart:p.at]...)
			p.at++
			return string(out), true
		case c < 0x20:
			return "", false
		case c == '\\':
			out = append(out, p.data[runStart:p.at]...)
			p.at++
			if p.at >= len(p.data) {
				return "", false
			}
			switch p.data[p.at] {
			case '"', '\\', '/':
				out = append(out, p.data[p.at])
				p.at++
			case 'b':
				out = append(out, '\b')
				p.at++
			case 'f':
				out = append(out, '\f')
				p.at++
			case 'n':
				out = append(out, '\n')
				p.at++
			case 'r':
				out = append(out, '\r')
				p.at++
			case 't':
				out = append(out, '\t')
				p.at++
			case 'u':
				r, ok := p.escapeU()
				if !ok {
					return "", false
				}
				switch {
				case r >= 0xD800 && r <= 0xDBFF:
					if len(p.data)-p.at < 2 || p.data[p.at] != '\\' || p.data[p.at+1] != 'u' {
						return "", false
					}
					p.at++
					low, ok := p.escapeU()
					if !ok || low < 0xDC00 || low > 0xDFFF {
						return "", false
					}
					r = utf16.DecodeRune(r, low)
				case r >= 0xDC00 && r <= 0xDFFF:
					return "", false
				}
				out = utf8.AppendRune(out, r)
			default:
				return "", false
			}
			runStart = p.at
		case c < utf8.RuneSelf:
			p.at++
		default:
			r, size := utf8.DecodeRune(p.data[p.at:])
			if r == utf8.RuneError && size <= 1 {
				return "", false
			}
			p.at += size
		}
	}
	return "", false
}

// Member is one member of an object Write writes in its order.
type Member struct {
	Name  string
	Value any
}

// Ordered is an object Write writes with its members in this order, as
// Prima writes a Jason.OrderedObject.
type Ordered []Member

// Write writes v as Prima's writer writes it: nil, a bool, a string, an
// integer of any Go integer type, a Number that is an integer as Jason
// writes one (no leading zero, no minus before a zero, no fraction or
// exponent), a []any or []string, an Ordered, or a map[string]any of at
// most 32 members, which Prima writes in the order of their names' bytes.
// Strings are written as Jason writes them: " and \ escaped, backspace,
// tab, line feed, form feed and carriage return as their two-character
// escapes, every other control character as \u00XX in uppercase
// hexadecimal, and every other character as itself.
//
// Anything else is ErrUnwritable: a float, which Jason writes in a form of
// its own (1e2 as 100.0, 1.50 as 1.5); text that is no UTF-8; and a map
// of more than 32 members, which Jason writes in the order of Erlang's map
// of that size, by its keys' hashes, that no other writer spells. A worker
// service writes only values it made, all of them integers and maps far
// smaller; a document it carries it passes on as the bytes it received.
func Write(v any) ([]byte, error) {
	w := writer{}
	if !w.value(v) {
		return nil, ErrUnwritable
	}
	return w.buf, nil
}

type writer struct{ buf []byte }

func (w *writer) value(v any) bool {
	switch v := v.(type) {
	case nil:
		w.buf = append(w.buf, "null"...)
	case bool:
		w.buf = strconv.AppendBool(w.buf, v)
	case string:
		return w.str(v)
	case int:
		w.buf = strconv.AppendInt(w.buf, int64(v), 10)
	case int64:
		w.buf = strconv.AppendInt(w.buf, v, 10)
	case uint64:
		w.buf = strconv.AppendUint(w.buf, v, 10)
	case uint32:
		w.buf = strconv.AppendUint(w.buf, uint64(v), 10)
	case Number:
		if !canonicalInteger(string(v)) {
			return false
		}
		w.buf = append(w.buf, v...)
	case []any:
		w.buf = append(w.buf, '[')
		for i, item := range v {
			if i > 0 {
				w.buf = append(w.buf, ',')
			}
			if !w.value(item) {
				return false
			}
		}
		w.buf = append(w.buf, ']')
	case []string:
		w.buf = append(w.buf, '[')
		for i, item := range v {
			if i > 0 {
				w.buf = append(w.buf, ',')
			}
			if !w.str(item) {
				return false
			}
		}
		w.buf = append(w.buf, ']')
	case Ordered:
		return w.members(v)
	case map[string]any:
		if len(v) > 32 {
			return false
		}
		names := make([]string, 0, len(v))
		for name := range v {
			names = append(names, name)
		}
		sort.Strings(names)
		members := make(Ordered, len(names))
		for i, name := range names {
			members[i] = Member{name, v[name]}
		}
		return w.members(members)
	default:
		return false
	}
	return true
}

// canonicalInteger is whether text is an integer as Jason writes one:
// decimal digits without a leading zero, a minus before any but 0, and
// at most 1,024 characters, which is what Jason reads.
func canonicalInteger(text string) bool {
	digits := strings.TrimPrefix(text, "-")
	if digits == "" || len(text) > maxIntegerText || (digits[0] == '0' && (len(digits) > 1 || len(text) > 1)) {
		return false
	}
	for i := 0; i < len(digits); i++ {
		if !digit(digits[i]) {
			return false
		}
	}
	return true
}

func (w *writer) members(members Ordered) bool {
	w.buf = append(w.buf, '{')
	for i, m := range members {
		if i > 0 {
			w.buf = append(w.buf, ',')
		}
		if !w.str(m.Name) {
			return false
		}
		w.buf = append(w.buf, ':')
		if !w.value(m.Value) {
			return false
		}
	}
	w.buf = append(w.buf, '}')
	return true
}

const upperHex = "0123456789ABCDEF"

func (w *writer) str(s string) bool {
	if !utf8.ValidString(s) {
		return false
	}
	w.buf = append(w.buf, '"')
	start := 0
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c >= 0x20 && c != '"' && c != '\\' {
			continue
		}
		w.buf = append(w.buf, s[start:i]...)
		switch c {
		case '"':
			w.buf = append(w.buf, '\\', '"')
		case '\\':
			w.buf = append(w.buf, '\\', '\\')
		case '\b':
			w.buf = append(w.buf, '\\', 'b')
		case '\t':
			w.buf = append(w.buf, '\\', 't')
		case '\n':
			w.buf = append(w.buf, '\\', 'n')
		case '\f':
			w.buf = append(w.buf, '\\', 'f')
		case '\r':
			w.buf = append(w.buf, '\\', 'r')
		default:
			w.buf = append(w.buf, '\\', 'u', '0', '0', upperHex[c>>4], upperHex[c&0xF])
		}
		start = i + 1
	}
	w.buf = append(w.buf, s[start:]...)
	w.buf = append(w.buf, '"')
	return true
}
