// Package ref provides component type prefix detection and expansion.
//
// Component types in CYFR: catalyst, reagent, formula.
// Shorthand prefixes: c, r, f.
//
// Parsing and validation of full component references is handled server-side
// by Sanctum.ComponentRef (Elixir). The CLI only needs type prefix awareness
// for input normalization (e.g., joining "c local.claude" → "c:local.claude").
package ref

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
