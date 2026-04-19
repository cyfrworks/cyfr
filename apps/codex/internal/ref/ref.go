// Package ref provides component type prefix detection, expansion, and
// lightweight CLI-side ref parsing.
//
// Component types in CYFR: catalyst, reagent, formula, tincture.
// Shorthand prefixes: c, r, f, t.
//
// Full parsing and validation of component references is handled server-side
// by Sanctum.ComponentRef (Elixir). The CLI uses [ParseRef] for splitting a
// raw input into parts (e.g. to detect whether a version is present) and
// [Validate] to enforce the three-shape namespace model on user-facing
// inputs before sending them to the server.
//
// # Parser invariants (post auth-refactor)
//
// The '@' character is INVALID anywhere in a ref — there is no "@alice"
// shorthand for personal namespaces. Personal slugs are bare ("alice"),
// publishers use dots ("stripe.com"). The pre-refactor parser silently
// converted '@' → ':' (as if '@' were a version separator) which masked
// invalid input from users and let malicious lockfile entries bypass
// validation. The new parser surfaces '@' explicitly via [Validate].
//
// Splits use LAST occurrence semantics:
//   - Version is after the LAST ':' (so a publisher like "stripe.com.api"
//     doesn't eat the ":version" with a greedy first-colon split).
//   - Namespace/name split on the LAST '.' in the pre-version segment (so
//     multi-label publishers like "api.stripe.com.widget" parse as
//     namespace="api.stripe.com", name="widget").
//
// The type prefix detector uses FIRST colon because "c:local.foo:0.1.0"
// always has the type in the leading short segment.
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

// reservedSlugs mirrors the seeded reserved list on cyfr.run and the
// @reserved_slugs attribute in Sanctum.ComponentRef. Additions here should
// be kept in sync with both.
var reservedSlugs = map[string]bool{
	"local": true,
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
var versionRegex = regexp.MustCompile(`^\d+\.\d+\.\d+(-[a-zA-Z0-9.-]+)?(\+[a-zA-Z0-9.-]+)?$`)

// NamespaceKind distinguishes the three syntactic shapes a namespace can take.
// Classification order (matches cyfr.run gateway + Sanctum.ComponentRef):
// publisher-if-dot → reserved-if-seeded → personal-else.
type NamespaceKind int

const (
	KindPersonal NamespaceKind = iota
	KindPublisher
	KindReserved
)

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
// use [ParseAndValidate] or call [Validate] on the result.
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

// ParseAndValidate parses s and then validates the parts against the
// three-shape namespace model, name rules, and version rules. Returns an
// error describing the first validation failure.
//
// User-facing inputs (CLI positional args, flags that carry a ref) should
// use ParseAndValidate so invalid input is rejected at the client before
// round-tripping to the server.
func ParseAndValidate(s string) (ParsedRef, error) {
	p := ParseRef(s)
	if err := Validate(p); err != nil {
		return ParsedRef{}, err
	}
	return p, nil
}

// Validate enforces the same rules as Sanctum.ComponentRef on cyfr. It
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

	// Defense in depth — '@' in any segment is invalid. Personal slugs are
	// bare (e.g. "alice"); publishers use dots (e.g. "stripe.com"). The
	// pre-refactor parser converted '@' → ':' silently; we now reject.
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

// ClassifyNamespace returns the syntactic shape of ns (publisher, reserved,
// or personal). Dispatch order: publisher-if-dot → reserved-if-seeded →
// personal-else.
func ClassifyNamespace(ns string) NamespaceKind {
	if strings.Contains(ns, ".") {
		return KindPublisher
	}
	if reservedSlugs[ns] {
		return KindReserved
	}
	return KindPersonal
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
