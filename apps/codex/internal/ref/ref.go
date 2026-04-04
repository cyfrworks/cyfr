// Package ref provides component type prefix detection, expansion, and
// lightweight CLI-side ref parsing.
//
// Component types in CYFR: catalyst, reagent, formula, tincture.
// Shorthand prefixes: c, r, f, t.
//
// Full parsing and validation of component references is handled server-side
// by Sanctum.ComponentRef (Elixir). The CLI uses [ParseRef] for detecting
// whether a version is present so it can prompt the user when one is missing.
package ref

import (
	"strconv"
	"strings"
)

// validTypes is the set of recognized component types.
var validTypes = map[string]bool{
	"catalyst": true,
	"reagent":  true,
	"formula":  true,
	"tincture": true,
}

// typeShorthands maps single-char shorthands to full type names.
var typeShorthands = map[string]string{
	"c": "catalyst",
	"r": "reagent",
	"f": "formula",
	"t": "tincture",
}

// IsTypePrefix returns true if s is a known type name or shorthand.
func IsTypePrefix(s string) bool {
	if validTypes[s] {
		return true
	}
	_, ok := typeShorthands[s]
	return ok
}

// ExpandType expands a type shorthand to its full name.
// If s is already a full type name or unknown, it is returned as-is.
func ExpandType(s string) string {
	if full, ok := typeShorthands[s]; ok {
		return full
	}
	return s
}

// ParsedRef holds the decomposed parts of a component reference string.
type ParsedRef struct {
	Type       string
	Namespace  string
	Name       string
	Version    string
	HasVersion bool
}

// ParseRef splits a component reference string into its constituent parts.
// It recognises typed refs (c:local.name:1.0.0), canonical refs
// (local.name:1.0.0), bare names (name), and the @ version separator.
// HasVersion is false when the input contained no version segment.
func ParseRef(s string) ParsedRef {
	s = strings.TrimSpace(s)
	if s == "" {
		return ParsedRef{}
	}

	// Normalize @ version separator to colon.
	if strings.Contains(s, "@") {
		s = strings.Replace(s, "@", ":", 1)
	}

	var p ParsedRef

	// Detect type prefix: the segment before the first colon must not
	// contain a dot and must be a recognised type/shorthand.
	if idx := strings.Index(s, ":"); idx >= 0 {
		first := s[:idx]
		if !strings.Contains(first, ".") && IsTypePrefix(first) {
			p.Type = first
			s = s[idx+1:]
		}
	}

	// Remainder is one of:
	//   namespace.name:version   (dot before first colon)
	//   namespace.name           (dot, no colon)
	//   name:version             (colon but no dot before it)
	//   name                     (neither)
	firstColon := strings.Index(s, ":")
	firstDot := strings.Index(s, ".")

	if firstDot >= 0 && (firstColon < 0 || firstDot < firstColon) {
		// Dot appears before first colon → namespace.name(:version)?
		p.Namespace = s[:firstDot]
		rest := s[firstDot+1:]
		if colonIdx := strings.Index(rest, ":"); colonIdx >= 0 {
			p.Name = rest[:colonIdx]
			p.Version = rest[colonIdx+1:]
			p.HasVersion = true
		} else {
			p.Name = rest
		}
	} else if firstColon >= 0 {
		// No dot before colon → name:version
		p.Name = s[:firstColon]
		p.Version = s[firstColon+1:]
		p.HasVersion = true
	} else {
		p.Name = s
	}

	return p
}

// CompareVersions compares two dot-separated version strings numerically.
// Returns -1 if a < b, 0 if a == b, +1 if a > b.
// Non-numeric segments are compared lexicographically.
func CompareVersions(a, b string) int {
	as := strings.Split(a, ".")
	bs := strings.Split(b, ".")
	max := len(as)
	if len(bs) > max {
		max = len(bs)
	}
	for i := 0; i < max; i++ {
		var ai, bi string
		if i < len(as) {
			ai = as[i]
		}
		if i < len(bs) {
			bi = bs[i]
		}
		an, aerr := strconv.Atoi(ai)
		bn, berr := strconv.Atoi(bi)
		if aerr == nil && berr == nil {
			if an < bn {
				return -1
			}
			if an > bn {
				return 1
			}
		} else {
			if ai < bi {
				return -1
			}
			if ai > bi {
				return 1
			}
		}
	}
	return 0
}

// HasTypePrefix reports whether the parsed ref had an explicit type prefix.
func (p ParsedRef) HasTypePrefix() bool {
	return p.Type != ""
}

// NameRef returns the name-level ref string (without version).
// When the namespace is empty (bare name like "claude"), it defaults to "local"
// so the output matches canonical server format (e.g. "catalyst:local.claude").
func (p ParsedRef) NameRef() string {
	var b strings.Builder
	if p.Type != "" {
		b.WriteString(p.Type)
		b.WriteByte(':')
	}
	ns := p.Namespace
	if ns == "" {
		ns = "local"
	}
	b.WriteString(ns)
	b.WriteByte('.')
	b.WriteString(p.Name)
	return b.String()
}

// WithVersion returns the ref string rebuilt with the given version.
// When the namespace is empty (bare name like "claude"), it defaults to "local"
// so the output matches canonical server format (e.g. "catalyst:local.claude:0.1.0").
func (p ParsedRef) WithVersion(v string) string {
	var b strings.Builder
	if p.Type != "" {
		b.WriteString(p.Type)
		b.WriteByte(':')
	}
	ns := p.Namespace
	if ns == "" {
		ns = "local"
	}
	b.WriteString(ns)
	b.WriteByte('.')
	b.WriteString(p.Name)
	b.WriteByte(':')
	b.WriteString(v)
	return b.String()
}
