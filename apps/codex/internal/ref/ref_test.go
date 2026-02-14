package ref

import (
	"testing"
)

func TestIsTypePrefix(t *testing.T) {
	// Full names
	if !IsTypePrefix("catalyst") {
		t.Error("expected catalyst to be a type prefix")
	}
	if !IsTypePrefix("reagent") {
		t.Error("expected reagent to be a type prefix")
	}
	if !IsTypePrefix("formula") {
		t.Error("expected formula to be a type prefix")
	}
	// Shorthands
	if !IsTypePrefix("c") {
		t.Error("expected c to be a type prefix")
	}
	if !IsTypePrefix("r") {
		t.Error("expected r to be a type prefix")
	}
	if !IsTypePrefix("f") {
		t.Error("expected f to be a type prefix")
	}
	// Non-types
	if IsTypePrefix("local") {
		t.Error("expected local NOT to be a type prefix")
	}
	if IsTypePrefix("my-tool") {
		t.Error("expected my-tool NOT to be a type prefix")
	}
}
