// Package ref provides canonical component reference parsing and formatting.
//
// All component references in CYFR follow the canonical format:
//
//	type:namespace.name:version
//
// Examples: catalyst:local.claude:0.1.0, c:local.claude:0.1.0
//
// The type prefix is required for normalization. Parse still accepts untyped
// refs for internal use and migration.
//
// Legacy formats are accepted by Parse for backwards compatibility:
//   - namespace.name:version → type defaults to ""
//   - name:version → defaults namespace to "local"
//   - local:name:version → legacy colon-separated format
package ref

import (
	"fmt"
	"strings"
)

// ComponentRef represents a parsed canonical component reference.
type ComponentRef struct {
	Type      string
	Namespace string
	Name      string
	Version   string
}

// String returns the canonical format.
// When Type is non-empty: type:namespace.name:version
// When Type is empty: namespace.name:version
func (r ComponentRef) String() string {
	base := fmt.Sprintf("%s.%s:%s", r.Namespace, r.Name, r.Version)
	if r.Type != "" {
		return r.Type + ":" + base
	}
	return base
}

// validTypes is the set of recognized component types.
var validTypes = map[string]bool{
	"catalyst": true,
	"reagent":  true,
	"formula":  true,
}

// typeShorthands maps single-char shorthands to full type names.
var typeShorthands = map[string]string{
	"c": "catalyst",
	"r": "reagent",
	"f": "formula",
}

// IsTypePrefix returns true if s is a known type name or shorthand.
func IsTypePrefix(s string) bool {
	if validTypes[s] {
		return true
	}
	_, ok := typeShorthands[s]
	return ok
}

// ExpandTypeShorthand expands a shorthand to its full type name.
// If already a full name or unknown, returns as-is.
func ExpandTypeShorthand(s string) string {
	if full, ok := typeShorthands[s]; ok {
		return full
	}
	return s
}

// Parse parses a component reference string into a ComponentRef.
//
// Accepted formats:
//   - "type:namespace.name:version" (typed canonical, e.g. "catalyst:local.claude:0.1.0")
//   - "c:namespace.name:version" (shorthand type)
//   - "namespace.name:version" (canonical, type defaults to "")
//   - "namespace.name" (canonical, version defaults to "latest")
//   - "name:version" (legacy, namespace defaults to "local")
//   - "name" (bare, namespace "local", version "latest")
//   - "local:name:version" (legacy colon-separated)
func Parse(s string) (ComponentRef, error) {
	s = strings.TrimSpace(s)
	if s == "" {
		return ComponentRef{}, fmt.Errorf("component ref cannot be empty")
	}

	// Check for typed ref: first colon-segment is a known type with no dots
	if colonIdx := strings.Index(s, ":"); colonIdx >= 0 {
		firstPart := s[:colonIdx]
		if !strings.Contains(firstPart, ".") && IsTypePrefix(firstPart) {
			remainder := s[colonIdx+1:]
			parsed, err := Parse(remainder)
			if err != nil {
				return ComponentRef{}, err
			}
			parsed.Type = ExpandTypeShorthand(firstPart)
			return parsed, nil
		}
	}

	// Legacy colon-separated: "local:name:version" (exactly 3 colon-separated parts,
	// no dot before first colon)
	parts := strings.SplitN(s, ":", 3)
	if len(parts) == 3 && parts[0] != "" && parts[1] != "" && parts[2] != "" &&
		!strings.Contains(parts[0], ".") {
		return ComponentRef{
			Namespace: parts[0],
			Name:      parts[1],
			Version:   parts[2],
		}, nil
	}

	// Check if there's a dot before the first colon (canonical format)
	colonIdx := strings.Index(s, ":")
	dotIdx := strings.Index(s, ".")

	if dotIdx >= 0 && (colonIdx < 0 || dotIdx < colonIdx) {
		// Canonical: namespace.name:version or namespace.name
		dotParts := strings.SplitN(s, ".", 2)
		if len(dotParts) != 2 || dotParts[1] == "" {
			return ComponentRef{}, fmt.Errorf("invalid component ref format: %s", s)
		}
		namespace := dotParts[0]
		rest := dotParts[1]

		colonParts := strings.SplitN(rest, ":", 2)
		name := colonParts[0]
		version := "latest"
		if len(colonParts) == 2 && colonParts[1] != "" {
			version = colonParts[1]
		}

		return ComponentRef{
			Namespace: namespace,
			Name:      name,
			Version:   version,
		}, nil
	}

	// Legacy: "name:version"
	if colonIdx >= 0 {
		colonParts := strings.SplitN(s, ":", 2)
		if colonParts[0] != "" && colonParts[1] != "" {
			return ComponentRef{
				Namespace: "local",
				Name:      colonParts[0],
				Version:   colonParts[1],
			}, nil
		}
		return ComponentRef{}, fmt.Errorf("invalid component ref format: %s", s)
	}

	// Bare name
	return ComponentRef{
		Namespace: "local",
		Name:      s,
		Version:   "latest",
	}, nil
}

// Normalize parses a component reference and returns its canonical string.
// The type prefix is required — untyped refs are rejected with a helpful error.
func Normalize(s string) (string, error) {
	r, err := Parse(s)
	if err != nil {
		return "", err
	}
	if r.Type == "" {
		return "", fmt.Errorf("component ref must include a type prefix (e.g., catalyst:%s). Valid types: catalyst (c), reagent (r), formula (f)", strings.TrimSpace(s))
	}
	return r.String(), nil
}
