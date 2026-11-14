// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"

	"github.com/spf13/cobra"
	"gopkg.in/yaml.v3"
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

// composeDefault is a compose limit's default: the value itself, or the
// default of the one ${NAME:-default} it reads.
var composeDefault = regexp.MustCompile(`^(?:\$\{[A-Z_]+:-([^}]+)\}|(.+))$`)

// The README's sizing names the shipped compose file's default limits, so
// a change to a default changes the sentence.
func TestReadmeSizingIsTheComposeLimits(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join(packageDir, "..", "..", "..", "docker-compose.yml"))
	if err != nil {
		t.Fatal(err)
	}
	var compose struct {
		Services map[string]struct {
			Deploy struct {
				Resources struct {
					Limits struct {
						Memory string `yaml:"memory"`
						CPUs   string `yaml:"cpus"`
					} `yaml:"limits"`
				} `yaml:"resources"`
			} `yaml:"deploy"`
		} `yaml:"services"`
	}
	if err := yaml.Unmarshal(raw, &compose); err != nil {
		t.Fatal(err)
	}
	limit := func(service, value string) int {
		t.Helper()
		m := composeDefault.FindStringSubmatch(value)
		number := strings.TrimSuffix(m[1]+m[2], "G")
		n, err := strconv.Atoi(number)
		if err != nil {
			t.Fatalf("%s's limit %q is not whole gigabytes or cores", service, value)
		}
		return n
	}
	memory := map[string]int{}
	cpus := map[string]int{}
	total := 0
	for _, service := range []string{"cyfr", "locus-runtime", "locus-builds", "locus-backends"} {
		limits := compose.Services[service].Deploy.Resources.Limits
		memory[service] = limit(service, limits.Memory)
		total += memory[service]
		if service != "locus-backends" {
			cpus[service] = limit(service, limits.CPUs)
		}
	}
	readme, err := os.ReadFile(filepath.Join(packageDir, "..", "..", "..", "README.md"))
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{
		fmt.Sprintf("which add up to about %d GB (cyfr %d GB, `locus-runtime` %d GB, `locus-builds` %d GB, `locus-backends` %d GB)",
			total, memory["cyfr"], memory["locus-runtime"], memory["locus-builds"], memory["locus-backends"]),
		fmt.Sprintf("Their processor limits are %d cores for cyfr, %d for `locus-runtime` and %d for `locus-builds`",
			cpus["cyfr"], cpus["locus-runtime"], cpus["locus-builds"]),
	} {
		if !strings.Contains(string(readme), want) {
			t.Errorf("README.md's sizing does not say %q", want)
		}
	}
}
