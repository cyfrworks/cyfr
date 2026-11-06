// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Package account is the command line's side of a person's account: the
// identity log (cyfr-identity/v2, Prima.Identity), the recovery code
// (Prima.RecoveryCode), sign-in requests and a device's answers
// (Prima.SignIn), registry requests (Prima.RegistryRequest) and the
// directory's and the registry's HTTP. Each shape is held to its vector
// file under tests/fixtures, as Prima holds it.
package account

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"regexp"
	"slices"
	"strconv"
	"unicode/utf16"
)

// maxSafe is the largest integer JCS takes: beyond 2^53 an ECMAScript
// number cannot hold it exactly, so another side could not round-trip it.
const maxSafe = 1<<53 - 1

var integer = regexp.MustCompile(`^-?(0|[1-9][0-9]*)$`)

// JCSError is a value outside JCS's domain, as Prima.JCS refuses it: a
// float, a null, an integer out of range or a type JSON has not. Field is
// the top-level key whose value holds it, "" for the value itself.
type JCSError struct{ Field string }

func (e *JCSError) Error() string { return "not canonical JSON at " + strconv.Quote(e.Field) }

// JCS is the RFC 8785 encoding of a decoded JSON value over Prima.JCS's
// domain: strings, integers of at most 2^53-1 (json.Number, int, int64 or
// an integral float64), booleans, arrays and string-keyed objects. Keys
// sort by UTF-16 code units and strings are escaped as ECMAScript's
// JSON.stringify escapes them, with no whitespace. A null or a fraction is
// refused.
func JCS(v any) ([]byte, error) {
	var buf bytes.Buffer
	if err := encode(&buf, v, ""); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

func encode(buf *bytes.Buffer, v any, field string) error {
	refuse := &JCSError{Field: field}
	switch x := v.(type) {
	case bool:
		buf.WriteString(strconv.FormatBool(x))
	case string:
		writeString(buf, x)
	case json.Number:
		if !integer.MatchString(x.String()) {
			return refuse
		}
		n, err := strconv.ParseInt(x.String(), 10, 64)
		if err != nil || n > maxSafe || n < -maxSafe {
			return refuse
		}
		buf.WriteString(strconv.FormatInt(n, 10))
	case int:
		if int64(x) > maxSafe || int64(x) < -maxSafe {
			return refuse
		}
		buf.WriteString(strconv.Itoa(x))
	case int64:
		if x > maxSafe || x < -maxSafe {
			return refuse
		}
		buf.WriteString(strconv.FormatInt(x, 10))
	case float64:
		if x != math.Trunc(x) || math.Abs(x) > maxSafe {
			return refuse
		}
		buf.WriteString(strconv.FormatInt(int64(x), 10))
	case []any:
		buf.WriteByte('[')
		for i, e := range x {
			if i > 0 {
				buf.WriteByte(',')
			}
			if err := encode(buf, e, field); err != nil {
				return err
			}
		}
		buf.WriteByte(']')
	case []string:
		return encode(buf, toAny(x), field)
	case map[string]any:
		keys := make([]string, 0, len(x))
		for k := range x {
			keys = append(keys, k)
		}
		slices.SortFunc(keys, func(a, b string) int {
			return slices.Compare(utf16.Encode([]rune(a)), utf16.Encode([]rune(b)))
		})
		buf.WriteByte('{')
		for i, k := range keys {
			if i > 0 {
				buf.WriteByte(',')
			}
			writeString(buf, k)
			buf.WriteByte(':')
			inner := field
			if inner == "" {
				inner = k
			}
			if err := encode(buf, x[k], inner); err != nil {
				return err
			}
		}
		buf.WriteByte('}')
	default:
		return refuse
	}
	return nil
}

func toAny(s []string) []any {
	out := make([]any, len(s))
	for i, v := range s {
		out[i] = v
	}
	return out
}

func writeString(buf *bytes.Buffer, s string) {
	buf.WriteByte('"')
	for _, r := range s {
		switch r {
		case '"':
			buf.WriteString(`\"`)
		case '\\':
			buf.WriteString(`\\`)
		case '\b':
			buf.WriteString(`\b`)
		case '\f':
			buf.WriteString(`\f`)
		case '\n':
			buf.WriteString(`\n`)
		case '\r':
			buf.WriteString(`\r`)
		case '\t':
			buf.WriteString(`\t`)
		default:
			if r < 0x20 {
				fmt.Fprintf(buf, `\u%04x`, r)
			} else {
				buf.WriteRune(r)
			}
		}
	}
	buf.WriteByte('"')
}

// Decode reads one JSON value with its numbers as json.Number, so JCS
// reproduces them as they were sent. Anything after the value is refused.
func Decode(raw []byte) (any, error) {
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	var v any
	if err := dec.Decode(&v); err != nil {
		return nil, err
	}
	if dec.More() {
		return nil, errors.New("more than one JSON value")
	}
	return v, nil
}

// B64 is unpadded base64url.
func B64(raw []byte) string { return base64.RawURLEncoding.EncodeToString(raw) }

// UnB64 decodes unpadded base64url of min to max bytes in its one
// spelling: padding, stray trailing bits and any other length are refused.
func UnB64(v any, min, max int) ([]byte, bool) {
	s, ok := v.(string)
	if !ok {
		return nil, false
	}
	raw, err := base64.RawURLEncoding.DecodeString(s)
	if err != nil || len(raw) < min || len(raw) > max || B64(raw) != s {
		return nil, false
	}
	return raw, true
}

// ms is whether v is a timestamp: an integer of 0 to 2^53-1.
func ms(v any) (int64, bool) {
	n, ok := v.(json.Number)
	if !ok || !integer.MatchString(n.String()) {
		return 0, false
	}
	i, err := strconv.ParseInt(n.String(), 10, 64)
	return i, err == nil && i >= 0 && i <= maxSafe
}

// clone is a shallow copy of m without the keys named.
func clone(m map[string]any, without ...string) map[string]any {
	out := make(map[string]any, len(m))
	for k, v := range m {
		if !slices.Contains(without, k) {
			out[k] = v
		}
	}
	return out
}
