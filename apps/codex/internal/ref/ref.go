// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Package ref parses and validates CLI component references.
// Types are catalyst, reagent, formula and tincture, with shorthands c, r, f and t.
// Cyfr.ComponentRef performs full server validation.
//
// ParseRef splits the type at the first colon, version at the last colon,
// and namespace/name at the last dot. Validate rejects @ anywhere in a ref;
// personal namespaces are bare slugs and publisher namespaces may contain dots.
package ref

import (
	"fmt"
	"regexp"
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

// personalSlugRegex matches GitHub-style bare slugs (personal + reserved).
// 1–39 chars, lowercase alphanumerics with single-hyphen separators.
// No leading/trailing/consecutive hyphens.
var personalSlugRegex = regexp.MustCompile(`^[a-z0-9]+(-[a-z0-9]+)*$`)

// publisherLabelRegex matches a single DNS label per RFC 1035: 1–63 chars,
// lowercase alphanumeric + hyphens, cannot start or end with a hyphen.
var publisherLabelRegex = regexp.MustCompile(`^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$`)

const (
	personalSlugMaxLen  = 39
	publisherSlugMaxLen = 253
	nameMaxLen          = 64
)

// nameRegex matches component names (1–64 chars lowercase alphanumerics with
// hyphens, no leading/trailing hyphen).
var nameRegex = regexp.MustCompile(`^[a-z0-9]([a-z0-9-]{0,62}[a-z0-9])?$`)
var singleCharNameRegex = regexp.MustCompile(`^[a-z0-9]$`)

// versionRegex matches semver with optional pre-release and build metadata.
// Strict semver (semver.org), byte-identical to Cyfr.ComponentRef's
// @version_regex — the cross-language drift test pins the spelling.
var versionRegex = regexp.MustCompile(`^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(-(0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*)(\.(0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*))*)?(\+[0-9a-zA-Z-]+(\.[0-9a-zA-Z-]+)*)?$`)

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
// It recognises typed refs (c:local.name:1.0.0) and canonical refs
// (local.name:1.0.0) and bare names. HasVersion is false when the input
// contained no version segment.
//
// ParseRef does NOT validate — it's a pure shape extractor. For strict
// validation (reject '@', enforce three-shape namespace rules, check semver)
// call [Validate] on the result.
func ParseRef(s string) ParsedRef {
	s = strings.TrimSpace(s)
	if s == "" {
		return ParsedRef{}
	}

	var p ParsedRef

	// Detect type prefix: the segment before the FIRST colon must not
	// contain a dot and must be a recognised type/shorthand. First-colon
	// here is intentional — the type prefix is always the leading short
	// token (e.g. "c:" or "catalyst:").
	if idx := strings.Index(s, ":"); idx >= 0 {
		first := s[:idx]
		if !strings.Contains(first, ".") && IsTypePrefix(first) {
			p.Type = first
			s = s[idx+1:]
		}
	}

	// Remainder is "namespace.name[:version]" or "name[:version]".
	//
	// Use LAST ':' for the version split so a publisher like
	// "stripe.com.api:0.1.0-beta.1" doesn't split on the first colon and
	// mangle the prerelease. Then use LAST '.' for namespace/name so
	// multi-label publishers like "api.stripe.com.widget" pick namespace
	// "api.stripe.com" and name "widget".
	nsName := s
	if colonIdx := strings.LastIndex(s, ":"); colonIdx >= 0 {
		nsName = s[:colonIdx]
		version := s[colonIdx+1:]
		if version != "" {
			p.Version = version
			p.HasVersion = true
		}
	}

	if dotIdx := strings.LastIndex(nsName, "."); dotIdx >= 0 {
		p.Namespace = nsName[:dotIdx]
		p.Name = nsName[dotIdx+1:]
	} else {
		p.Name = nsName
	}

	return p
}

// Validate enforces the same rules as Cyfr.ComponentRef on cyfr. It
// returns nil on success or a descriptive error on failure. The first
// failure short-circuits the rest of the checks.
//
// Validation covers:
//   - No '@' anywhere in namespace, name, or version.
//   - Namespace matches one of the three shapes (personal/publisher/reserved).
//   - Name is 1–64 lowercase alphanumerics with hyphens (no leading/trailing).
//   - Version (when present) is valid semver.
//
// A missing Type is NOT a validation error — many CLI code paths accept
// typeless refs and infer the type elsewhere. Callers that require a type
// should check [ParsedRef.HasTypePrefix] separately.
func Validate(p ParsedRef) error {
	if p.Name == "" {
		return fmt.Errorf("invalid ref: name is required")
	}

	// Reject @ in every segment; personal namespaces are bare slugs.
	for _, field := range []string{p.Namespace, p.Name, p.Version} {
		if strings.Contains(field, "@") {
			return fmt.Errorf(
				"invalid ref: '@' is not permitted (personal slugs are bare, " +
					"publishers use dots)")
		}
	}

	if p.Namespace != "" {
		if err := ValidateNamespace(p.Namespace); err != nil {
			return err
		}
	}

	if err := validateName(p.Name); err != nil {
		return err
	}

	if p.HasVersion {
		if !versionRegex.MatchString(p.Version) {
			return fmt.Errorf("invalid version %q: must be semver (e.g. 1.2.3, 1.2.3-rc.1, 1.2.3+build)",
				p.Version)
		}
	}

	return nil
}

// ValidateNamespace checks that ns satisfies the three-shape model. Empty
// is NOT accepted — callers that want to permit a missing namespace (e.g.
// bare name refs like "widget") should skip calling this.
func ValidateNamespace(ns string) error {
	if ns == "" {
		return fmt.Errorf("namespace cannot be empty")
	}
	if strings.Contains(ns, "@") {
		return fmt.Errorf(
			"namespace must not contain '@' — personal slugs are bare (e.g. " +
				"'alice'); publishers require a dot (e.g. 'stripe.com')")
	}
	if strings.Contains(ns, ".") {
		return validatePublisherSlug(ns)
	}
	// Bare slug — personal and reserved share the same regex.
	return validatePersonalSlug(ns)
}

func validatePersonalSlug(ns string) error {
	if len(ns) > personalSlugMaxLen {
		return fmt.Errorf("personal namespace %q exceeds %d characters (GitHub-style)",
			ns, personalSlugMaxLen)
	}
	if !personalSlugRegex.MatchString(ns) {
		return fmt.Errorf(
			"personal namespace %q must match /^[a-z0-9]+(-[a-z0-9]+)*$/ "+
				"(lowercase letters, digits, single hyphens; no leading/trailing/"+
				"consecutive hyphens)", ns)
	}
	return nil
}

func validatePublisherSlug(ns string) error {
	switch {
	case len(ns) > publisherSlugMaxLen:
		return fmt.Errorf("publisher namespace must be at most %d characters (RFC 1035)",
			publisherSlugMaxLen)
	case strings.HasPrefix(ns, "."):
		return fmt.Errorf("publisher namespace %q must not have a leading dot", ns)
	case strings.HasSuffix(ns, "."):
		return fmt.Errorf("publisher namespace %q must not have a trailing dot", ns)
	case strings.Contains(ns, ".."):
		return fmt.Errorf("publisher namespace %q must not have empty labels", ns)
	case strings.Contains(ns, ":"):
		return fmt.Errorf("publisher namespace %q must not have a port suffix", ns)
	case ns == "localhost":
		return fmt.Errorf("'localhost' is not a valid publisher namespace")
	case looksLikeIPv4(ns):
		return fmt.Errorf("publisher namespace %q must not be an IP address (use a DNS hostname)",
			ns)
	}

	for _, label := range strings.Split(ns, ".") {
		if !publisherLabelRegex.MatchString(label) {
			return fmt.Errorf(
				"invalid publisher label %q in %q — must match RFC 1035 (1–63 "+
					"chars, lowercase alphanumeric + hyphens, no leading/trailing "+
					"hyphen). Use punycode for internationalized domains.",
				label, ns)
		}
	}
	return nil
}

func looksLikeIPv4(ns string) bool {
	parts := strings.Split(ns, ".")
	if len(parts) != 4 {
		return false
	}
	for _, p := range parts {
		if len(p) == 0 {
			return false
		}
		for _, c := range p {
			if c < '0' || c > '9' {
				return false
			}
		}
	}
	return true
}

func validateName(name string) error {
	n := len(name)
	switch {
	case n < 1:
		return fmt.Errorf("name cannot be empty")
	case n > nameMaxLen:
		return fmt.Errorf("name %q exceeds %d characters", name, nameMaxLen)
	case n == 1:
		if !singleCharNameRegex.MatchString(name) {
			return fmt.Errorf("name %q must be lowercase alphanumeric", name)
		}
	default:
		if !nameRegex.MatchString(name) {
			return fmt.Errorf(
				"name %q must be lowercase alphanumeric with hyphens, "+
					"cannot start or end with a hyphen", name)
		}
	}
	return nil
}

// CompareVersions uses semver precedence, ignoring build metadata.
// A valid version sorts above an invalid one; two invalid versions compare
// bytewise. Ordering matches the server's Compendium.Semver.compare/2.
func CompareVersions(a, b string) int {
	av, aok := parseSemver(a)
	bv, bok := parseSemver(b)
	switch {
	case aok && !bok:
		return 1
	case !aok && bok:
		return -1
	case !aok && !bok:
		return strings.Compare(a, b)
	}
	for i := 0; i < 3; i++ {
		if av.core[i] != bv.core[i] {
			if av.core[i] < bv.core[i] {
				return -1
			}
			return 1
		}
	}
	switch {
	case len(av.pre) == 0 && len(bv.pre) == 0:
		return 0
	case len(av.pre) == 0:
		return 1
	case len(bv.pre) == 0:
		return -1
	}
	max := len(av.pre)
	if len(bv.pre) > max {
		max = len(bv.pre)
	}
	for i := 0; i < max; i++ {
		if i >= len(av.pre) {
			return -1 // fewer identifiers ranks lower
		}
		if i >= len(bv.pre) {
			return 1
		}
		if c := comparePreIdent(av.pre[i], bv.pre[i]); c != 0 {
			return c
		}
	}
	return 0
}

type semverParts struct {
	core [3]int
	pre  []string
}

func parseSemver(s string) (semverParts, bool) {
	var v semverParts
	if !versionRegex.MatchString(s) {
		return v, false
	}
	if plus := strings.IndexByte(s, '+'); plus >= 0 {
		s = s[:plus]
	}
	core := s
	if dash := strings.IndexByte(s, '-'); dash >= 0 {
		core = s[:dash]
		v.pre = strings.Split(s[dash+1:], ".")
	}
	parts := strings.Split(core, ".")
	for i := 0; i < 3; i++ {
		n, err := strconv.Atoi(parts[i])
		if err != nil {
			return v, false
		}
		v.core[i] = n
	}
	return v, true
}

func comparePreIdent(a, b string) int {
	an, aerr := strconv.Atoi(a)
	bn, berr := strconv.Atoi(b)
	switch {
	case aerr == nil && berr == nil:
		if an < bn {
			return -1
		}
		if an > bn {
			return 1
		}
		return 0
	case aerr == nil:
		return -1 // numeric identifiers rank below alphanumeric
	case berr == nil:
		return 1
	default:
		return strings.Compare(a, b)
	}
}

// HasTypePrefix reports whether the parsed ref had an explicit type prefix.
func (p ParsedRef) HasTypePrefix() bool {
	return p.Type != ""
}

// NameRef returns a name-level reference without a version.
// An empty namespace defaults to "local" and type shorthands expand,
// e.g. "c:claude" becomes "catalyst:local.claude".
func (p ParsedRef) NameRef() string {
	var b strings.Builder
	if p.Type != "" {
		b.WriteString(ExpandType(p.Type))
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
// When the namespace is empty (bare name like "claude"), it defaults to "local",
// and a shorthand type expands so the output matches canonical server format
// (e.g. "catalyst:local.claude:0.1.0").
func (p ParsedRef) WithVersion(v string) string {
	var b strings.Builder
	if p.Type != "" {
		b.WriteString(ExpandType(p.Type))
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
