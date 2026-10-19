// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package reach

import (
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"gopkg.in/yaml.v3"
)

// The engine's tests that skip without Docker or Docker Compose are
// exactly the ones Codex CI's test job requires to run and pass, so a
// test that stops running there, or one that never did, fails here.
func TestDockerTestsAreTheOnesCIRequires(t *testing.T) {
	sources, err := filepath.Glob("*_test.go")
	if err != nil {
		t.Fatal(err)
	}
	var calling []string
	fset := token.NewFileSet()
	for _, name := range sources {
		file, err := parser.ParseFile(fset, name, nil, 0)
		if err != nil {
			t.Fatal(err)
		}
		for _, decl := range file.Decls {
			fn, ok := decl.(*ast.FuncDecl)
			if !ok || fn.Body == nil || !strings.HasPrefix(fn.Name.Name, "Test") {
				continue
			}
			ast.Inspect(fn.Body, func(node ast.Node) bool {
				if call, ok := node.(*ast.CallExpr); ok {
					if ident, ok := call.Fun.(*ast.Ident); ok && (ident.Name == "requireCompose" || ident.Name == "requireDocker") {
						calling = append(calling, fn.Name.Name)
						return false
					}
				}
				return true
			})
		}
	}
	slices.Sort(calling)
	calling = slices.Compact(calling)

	data, err := os.ReadFile(filepath.Join("..", "..", "..", "..", ".github", "workflows", "codex-ci.yml"))
	if err != nil {
		t.Fatal(err)
	}
	var workflow struct {
		Jobs map[string]struct {
			Steps []struct {
				Env map[string]string `yaml:"env"`
			} `yaml:"steps"`
		} `yaml:"jobs"`
	}
	if err := yaml.Unmarshal(data, &workflow); err != nil {
		t.Fatal(err)
	}
	var required []string
	for _, step := range workflow.Jobs["test"].Steps {
		required = append(required, strings.Fields(step.Env["REACH_DOCKER_TESTS"])...)
	}
	slices.Sort(required)
	if len(calling) == 0 || !slices.Equal(calling, required) {
		t.Errorf("the engine's tests that call requireDocker or requireCompose are %v; codex-ci.yml's test job requires %v", calling, required)
	}
}
