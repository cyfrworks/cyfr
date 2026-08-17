package cmd

import "testing"

func TestParseSettings(t *testing.T) {
	settings, err := parseSettings([]string{"aqua.answer_mode=all", "theme=dark", "aqua.name="})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	aqua, ok := settings["aqua"].(map[string]any)
	if !ok {
		t.Fatalf("aqua should be a nested map, got %#v", settings["aqua"])
	}
	if aqua["answer_mode"] != "all" {
		t.Errorf("answer_mode = %#v", aqua["answer_mode"])
	}
	if v, present := aqua["name"]; !present || v != nil {
		t.Errorf("an empty value should be a nil (delete), got %#v present=%v", v, present)
	}
	if settings["theme"] != "dark" {
		t.Errorf("theme = %#v", settings["theme"])
	}
	if _, err := parseSettings([]string{"novalue"}); err == nil {
		t.Errorf("a pair without = must be refused")
	}
}
