// Package ref provides canonical component reference parsing and formatting.
//
// All component references in CYFR follow the canonical format:
//
//	namespace.name:version
//
// Examples: local.my-tool:1.0.0, cyfr.stripe:2.0.0
//
// Legacy formats are accepted for backwards compatibility:
//   - name:version → defaults namespace to "local"
//   - local:name:version → legacy colon-separated format
package ref

import (
	"fmt"
	"strings"
)

// ComponentRef represents a parsed canonical component reference.
type ComponentRef struct {
	Namespace string
	Name      string
	Version   string
}

// String returns the canonical format: namespace.name:version
func (r ComponentRef) String() string {
	return fmt.Sprintf("%s.%s:%s", r.Namespace, r.Name, r.Version)
}

// Parse parses a component reference string into a ComponentRef.
//
// Accepted formats:
//   - "namespace.name:version" (canonical)
//   - "namespace.name" (canonical, version defaults to "latest")
//   - "name:version" (legacy, namespace defaults to "local")
//   - "name" (bare, namespace "local", version "latest")
//   - "local:name:version" (legacy colon-separated)
func Parse(s string) (ComponentRef, error) {
	s = strings.TrimSpace(s)
	if s == "" {
		return ComponentRef{}, fmt.Errorf("component ref cannot be empty")
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
func Normalize(s string) (string, error) {
	r, err := Parse(s)
	if err != nil {
		return "", err
	}
	return r.String(), nil
}
