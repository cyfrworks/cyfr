// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/spf13/cobra"
)

// The README's CLI Reference tables are a derived view of the command
// tree: every command a row names is registered, word by word, and every
// command `cyfr --help` lists has a row.
var readmeCommand = regexp.MustCompile("`(cyfr [^`]*)`")

func TestReadmeCLITablesAreTheCommandTree(t *testing.T) {
	rows := readmeCLIRows(t)
	if len(rows) == 0 {
		t.Fatal("README.md's CLI Reference has no command rows")
	}

	named := map[string]bool{}
	for _, row := range rows {
		for _, match := range readmeCommand.FindAllStringSubmatch(row, -1) {
			top, problems := walkReadmeCommand(match[1])
			for _, problem := range problems {
				t.Errorf("README.md's CLI Reference row %q: %s", match[1], problem)
			}
			if top != "" {
				named[top] = true
			}
		}
	}

	for _, c := range rootCmd.Commands() {
		if !c.IsAvailableCommand() || c.Name() == "help" || c.Name() == "completion" {
			continue
		}
		if !named[c.Name()] {
			t.Errorf("`cyfr %s` (%s) has no row in README.md's CLI Reference", c.Name(), c.Short)
		}
	}
}

// The first cell of every table row in the "## CLI Reference" section.
func readmeCLIRows(t *testing.T) []string {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "README.md"))
	if err != nil {
		t.Fatalf("read README.md: %v", err)
	}

	var rows []string
	inside := false
	for _, line := range strings.Split(string(raw), "\n") {
		switch {
		case strings.HasPrefix(line, "## "):
			inside = strings.TrimSpace(line) == "## CLI Reference"
		case inside && strings.HasPrefix(line, "|"):
			cells := strings.Split(line, "|")
			if len(cells) > 1 {
				rows = append(rows, cells[1])
			}
		}
	}
	return rows
}

// Walks `cyfr …` down the tree: each word names a subcommand of the one
// before it while that one has subcommands; a slash list names several,
// each of which must exist, and ends the path; an argument placeholder, a
// quoted argument or a command with no subcommands ends it too. Answers
// the top-level command named and what did not match.
func walkReadmeCommand(text string) (string, []string) {
	words := strings.Fields(text)[1:]
	var problems []string
	top := ""
	current := rootCmd

	for i, word := range words {
		if strings.ContainsAny(word[:1], "<[{'\"-") || !current.HasSubCommands() {
			break
		}

		alternatives := strings.Split(word, "/")
		var next *cobra.Command
		for _, alternative := range alternatives {
			sub := subcommand(current, alternative)
			if sub == nil {
				problems = append(problems, "`"+current.CommandPath()+"` has no subcommand `"+alternative+"`")
				continue
			}
			next = sub
		}

		if i == 0 && len(alternatives) == 1 && next != nil {
			top = next.Name()
		}
		if len(alternatives) > 1 || next == nil {
			break
		}
		current = next
	}

	if len(words) == 0 {
		problems = append(problems, "names no command")
	}
	return top, problems
}

func subcommand(parent *cobra.Command, name string) *cobra.Command {
	for _, c := range parent.Commands() {
		if c.Name() == name || c.HasAlias(name) {
			return c
		}
	}
	return nil
}
