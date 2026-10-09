// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/cyfr/codex/internal/scaffold"
	"github.com/cyfr/codex/internal/version"
	"github.com/spf13/cobra"
	"gopkg.in/yaml.v3"
)

func init() {
	rootCmd.AddCommand(updateCmd)
}

var updateCmd = &cobra.Command{
	Use:     "update",
	Short:   "Update project scaffold files (docs, WIT definitions, aqua prompts)",
	Long:    "Update managed scaffold files (docs, WIT interface definitions, bundled aqua prompts) in the current project directory and pull the stack's images. Also ensures that docker-compose.yml has all the volume mounts and fields the cyfr server requires, adding any missing ones in place, and notes a service of the bundled stack (locus-runtime, locus-builds, locus-backends) that it lacks.",
	GroupID: "server",
	Example: "  cyfr update",
	RunE: func(cmd *cobra.Command, args []string) error {
		// Require cyfr.yaml in current directory
		if _, err := os.Stat("cyfr.yaml"); err != nil {
			return errors.New("Not in a cyfr project directory (no cyfr.yaml found).\nRun 'cyfr init' to create a new project.")
		}

		fmt.Println("Updating project scaffold files...")

		// Pull latest Docker images for the whole stack (cyfr, locus-runtime and
		// locus-backends, plus caddy when TLS mode is on and locus-builds
		// when .env points builds at it) via compose so they're kept in
		// sync. Non-fatal — the project runs via Docker.
		if _, err := exec.LookPath("docker"); err == nil {
			fmt.Println("Pulling latest Docker images...")
			pullArgs := append(append([]string{"compose"}, profileArgs(composeProfiles(".env"))...), "pull")
			pull := exec.Command("docker", pullArgs...)
			pull.Stdout = os.Stdout
			pull.Stderr = os.Stderr
			if err := pull.Run(); err != nil {
				fmt.Printf("Warning: failed to pull Docker images: %v\n", err)
			} else {
				fmt.Println("Docker images updated.")
			}
		}

		// Update scaffold files
		if err := scaffold.Update(version.Version); err != nil {
			return fmt.Errorf("Failed to update scaffold files: %w", err)
		}

		fmt.Printf("Scaffold files updated (%s, wit/, aqua/).\n", strings.Join(scaffold.Guides, ", "))

		// Ensure docker-compose.yml has all the cyfr-server fields. Auto-adds
		// any missing volume mounts, container_name, env_file, and ports under
		// the cyfr service. User customizations (env vars, networks, labels,
		// additional services, etc.) are preserved.
		if added, err := ensureCyfrComposeFields("docker-compose.yml"); err != nil {
			fmt.Fprintf(os.Stderr, "\nNote: %v\n", err)
			fmt.Fprintln(os.Stderr, "Run 'cyfr init --force' to regenerate docker-compose.yml from scratch.")
		} else if len(added) > 0 {
			fmt.Printf("Added missing fields to docker-compose.yml: %v\n", added)
		}
		warnMissingStackServices("docker-compose.yml")
		return nil
	},
}

// bundledServices are the services of the bundled stack besides cyfr, whose
// fields ensureCyfrComposeFields keeps; caddy is the TLS profile's and
// optional to a project that never runs one.
var bundledServices = []string{"locus-runtime", "locus-builds", "locus-backends"}

// missingStackServices returns the bundled services the compose file at
// path lacks, in bundledServices' order; nil when it has them all or cannot
// be read as a compose file.
func missingStackServices(path string) []string {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	var root yaml.Node
	if err := yaml.Unmarshal(data, &root); err != nil || root.Kind != yaml.DocumentNode || len(root.Content) == 0 {
		return nil
	}
	services := mapValue(root.Content[0], "services")
	if services == nil {
		return nil
	}
	var missing []string
	for _, name := range bundledServices {
		if mapValue(services, name) == nil {
			missing = append(missing, name)
		}
	}
	return missing
}

// warnMissingStackServices prints a note if docker-compose.yml lacks a
// service of the bundled stack — i.e. it predates the stack. We don't
// auto-add one: a hand-edited compose is the user's. `cyfr init --force`
// regenerates the whole file from the scaffold.
func warnMissingStackServices(path string) {
	missing := missingStackServices(path)
	if len(missing) == 0 {
		return
	}
	fmt.Printf("\nNote: docker-compose.yml has no %s service — this project predates the bundled\n", strings.Join(missing, " or "))
	fmt.Println("stack. Run 'cyfr init --force' to regenerate docker-compose.yml,")
	fmt.Println("or copy the missing services from a repo checkout.")
}

// requiredVolumes maps a host path to its container mount path. Each entry
// must appear in the cyfr service's volumes list.
var requiredVolumes = []string{
	"./data:/app/data",
	"./aqua:/app/seed/aqua",
}

// requiredPorts must appear in the cyfr service's ports list, each spelled as
// the shipped docker-compose.yml spells it. Bound to the loopback interface:
// the Codex CLI and the browser talk to http://127.0.0.1:${CYFR_PORT:-4000},
// but the un-TLS'd endpoint is never published to the internet (Caddy fronts
// :80/:443 and reaches cyfr over the compose network).
var requiredPorts = []string{
	"127.0.0.1:${CYFR_PORT:-4000}:${CYFR_PORT:-4000}",
}

// requiredEnvFiles must appear in the cyfr service's env_file list.
var requiredEnvFiles = []string{
	".env",
}

// ensureCyfrComposeFields parses docker-compose.yml, locates the cyfr service,
// and ensures all required fields are present. Missing volumes, ports,
// env_file entries, and container_name are added. Existing user content
// (env vars, networks, labels, custom additions) is preserved.
//
// Returns a list of human-readable descriptions of what was added (empty if
// nothing was missing). Returns an error if the file can't be parsed as YAML
// or if no cyfr service can be found.
func ensureCyfrComposeFields(path string) ([]string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("docker-compose.yml not found")
	}

	var root yaml.Node
	if err := yaml.Unmarshal(data, &root); err != nil {
		return nil, fmt.Errorf("docker-compose.yml is not valid YAML: %w", err)
	}
	if root.Kind != yaml.DocumentNode || len(root.Content) == 0 {
		return nil, fmt.Errorf("docker-compose.yml is empty")
	}

	doc := root.Content[0]
	if doc.Kind != yaml.MappingNode {
		return nil, fmt.Errorf("docker-compose.yml top level is not a mapping")
	}

	servicesNode := mapValue(doc, "services")
	if servicesNode == nil || servicesNode.Kind != yaml.MappingNode {
		return nil, fmt.Errorf("docker-compose.yml has no `services:` section")
	}

	// Find the cyfr service. We look for a service literally named `cyfr`
	// first; if not present, fall back to the first service whose
	// `container_name` is `cyfr` (some users rename the service key).
	cyfrNode := mapValue(servicesNode, "cyfr")
	if cyfrNode == nil {
		for i := 0; i < len(servicesNode.Content); i += 2 {
			if i+1 >= len(servicesNode.Content) {
				break
			}
			svc := servicesNode.Content[i+1]
			if svc.Kind != yaml.MappingNode {
				continue
			}
			if cn := mapValue(svc, "container_name"); cn != nil && cn.Value == "cyfr" {
				cyfrNode = svc
				break
			}
		}
	}
	if cyfrNode == nil || cyfrNode.Kind != yaml.MappingNode {
		return nil, fmt.Errorf("docker-compose.yml has no `cyfr` service (looked for `services.cyfr` and `container_name: cyfr`)")
	}

	var added []string

	// container_name: cyfr — stable name for `docker compose` / `docker logs cyfr`.
	if cn := mapValue(cyfrNode, "container_name"); cn == nil {
		setMapValue(cyfrNode, "container_name", &yaml.Node{
			Kind:  yaml.ScalarNode,
			Tag:   "!!str",
			Value: "cyfr",
		})
		added = append(added, "container_name: cyfr")
	}

	// volumes — ensure each required mount is present.
	for _, mount := range requiredVolumes {
		if ensureSequenceItem(cyfrNode, "volumes", mount) {
			added = append(added, "volumes: "+mount)
		}
	}

	// ports — ensure the cyfr listener's port is published. We match by
	// container port and protocol as compose reads them, its variables taken
	// from the environment and the project's .env (any host-binding form
	// counts), so an existing "4000:4000" isn't duplicated; only a project
	// publishing no tcp mapping of that port, a udp-only one included, gets
	// the loopback-bound entry added (existing 0.0.0.0 publishes are left
	// alone).
	lookup := composeEnv(filepath.Join(filepath.Dir(path), ".env"))
	for _, port := range requiredPorts {
		if ensurePublishedPort(cyfrNode, port, lookup) {
			added = append(added, "ports: "+port)
		}
	}

	// env_file — ensure .env is referenced.
	for _, ef := range requiredEnvFiles {
		if ensureSequenceItem(cyfrNode, "env_file", ef) {
			added = append(added, "env_file: "+ef)
		}
	}

	if len(added) == 0 {
		return nil, nil
	}

	// Re-serialize with 2-space indentation to match the cyfr init template
	// (yaml.v3 defaults to 4 spaces, which would surprise users on update).
	var buf strings.Builder
	enc := yaml.NewEncoder(&buf)
	enc.SetIndent(2)
	if err := enc.Encode(&root); err != nil {
		return nil, fmt.Errorf("failed to re-serialize docker-compose.yml: %w", err)
	}
	if err := enc.Close(); err != nil {
		return nil, fmt.Errorf("failed to close encoder: %w", err)
	}
	if err := os.WriteFile(path, []byte(buf.String()), 0644); err != nil {
		return nil, fmt.Errorf("failed to write docker-compose.yml: %w", err)
	}
	return added, nil
}

// mapValue returns the value node for the given key in a mapping node, or
// nil if the key is absent or the node isn't a mapping.
func mapValue(m *yaml.Node, key string) *yaml.Node {
	if m == nil || m.Kind != yaml.MappingNode {
		return nil
	}
	for i := 0; i < len(m.Content); i += 2 {
		if i+1 >= len(m.Content) {
			break
		}
		k := m.Content[i]
		if k.Value == key {
			return m.Content[i+1]
		}
	}
	return nil
}

// setMapValue sets a key in a mapping node, replacing it if present or
// appending it if absent.
func setMapValue(m *yaml.Node, key string, value *yaml.Node) {
	if m == nil || m.Kind != yaml.MappingNode {
		return
	}
	for i := 0; i < len(m.Content); i += 2 {
		if i+1 >= len(m.Content) {
			break
		}
		if m.Content[i].Value == key {
			m.Content[i+1] = value
			return
		}
	}
	m.Content = append(m.Content,
		&yaml.Node{Kind: yaml.ScalarNode, Tag: "!!str", Value: key},
		value,
	)
}

// composeEnv returns the lookup compose expands docker-compose.yml's
// variables with: the process environment, then the dotenv file at envPath.
func composeEnv(envPath string) func(string) (string, bool) {
	dotenv := parseEnvFile("")
	if data, err := os.ReadFile(envPath); err == nil {
		dotenv = parseEnvFile(string(data))
	}
	return func(name string) (string, bool) {
		if value, ok := os.LookupEnv(name); ok {
			return value, true
		}
		return dotenv.value(name)
	}
}

// interpolate expands s's variables as compose does, each value taken from
// lookup: `$$` is a literal `$`; `$VAR` and `${VAR}` are VAR's value, empty
// when unset; `${VAR:-word}` is word when VAR is unset or empty and
// `${VAR-word}` when it is unset; `${VAR:+word}` is word when VAR is set and
// non-empty and `${VAR+word}` when it is set, else empty; `${VAR:?err}` and
// `${VAR?err}` refuse where `:-` and `-` would take the word. A word may hold
// variables itself. ok is false where compose refuses the text.
func interpolate(s string, lookup func(string) (string, bool)) (string, bool) {
	var out strings.Builder
	for i := 0; i < len(s); i++ {
		if s[i] != '$' || i+1 == len(s) {
			out.WriteByte(s[i])
			continue
		}
		switch next := s[i+1]; {
		case next == '$':
			out.WriteByte('$')
			i++
		case next == '{':
			end := closingBrace(s, i+1)
			if end < 0 {
				return "", false
			}
			value, ok := substitute(s[i+2:end], lookup)
			if !ok {
				return "", false
			}
			out.WriteString(value)
			i = end
		case isNameByte(next, true):
			end := i + 2
			for end < len(s) && isNameByte(s[end], false) {
				end++
			}
			value, _ := lookup(s[i+1 : end])
			out.WriteString(value)
			i = end - 1
		default:
			out.WriteByte('$')
		}
	}
	return out.String(), true
}

// substitute expands the body of one `${…}`.
func substitute(body string, lookup func(string) (string, bool)) (string, bool) {
	n := 0
	for n < len(body) && isNameByte(body[n], n == 0) {
		n++
	}
	if n == 0 {
		return "", false
	}
	value, set := lookup(body[:n])
	op := body[n:]
	if op == "" {
		return value, true
	}
	colon := op[0] == ':'
	if colon {
		op = op[1:]
	}
	if op == "" {
		return "", false
	}
	word := op[1:]
	present := set && (!colon || value != "")
	switch op[0] {
	case '-':
		if present {
			return value, true
		}
		return interpolate(word, lookup)
	case '+':
		if present {
			return interpolate(word, lookup)
		}
		return "", true
	case '?':
		return value, present
	}
	return "", false
}

// closingBrace returns the index of the brace closing the one at open,
// counting the braces between; -1 when it is unclosed.
func closingBrace(s string, open int) int {
	depth := 0
	for i := open; i < len(s); i++ {
		switch s[i] {
		case '{':
			depth++
		case '}':
			if depth--; depth == 0 {
				return i
			}
		}
	}
	return -1
}

// isNameByte reports whether b may stand in a variable's name, first when it
// would begin it.
func isNameByte(b byte, first bool) bool {
	return b == '_' || 'a' <= b && b <= 'z' || 'A' <= b && b <= 'Z' || !first && '0' <= b && b <= '9'
}

// portSpec is the container side of a compose `ports` entry: the ports first
// through last, and the protocol.
type portSpec struct {
	first, last uint64
	protocol    string
}

// publishes reports whether p publishes want's first port under its protocol.
func (p portSpec) publishes(want portSpec) bool {
	return p.protocol == want.protocol && p.first <= want.first && want.first <= p.last
}

// publishedPort reads the container side of a compose `ports` entry as
// compose does, after expanding its variables with lookup: the short syntax
// `[[host_ip:]host_port:]container_port[/protocol]`, either port a single
// port or a range and an IPv6 host_ip holding colons of its own, or the long
// syntax's mapping, its `target` and `protocol`. An alias entry reads as the
// entry it names. The protocol defaults to tcp. ok is false when the entry's
// container port does not read as one.
func publishedPort(entry *yaml.Node, lookup func(string) (string, bool)) (portSpec, bool) {
	if entry.Kind == yaml.AliasNode {
		entry = entry.Alias
	}
	var target, protocol string
	switch entry.Kind {
	case yaml.ScalarNode:
		mapping, ok := interpolate(entry.Value, lookup)
		if !ok {
			return portSpec{}, false
		}
		target, protocol, _ = strings.Cut(mapping[strings.LastIndexByte(mapping, ':')+1:], "/")
	case yaml.MappingNode:
		node := mapValue(entry, "target")
		if node == nil || node.Kind != yaml.ScalarNode {
			return portSpec{}, false
		}
		var ok bool
		if target, ok = interpolate(node.Value, lookup); !ok {
			return portSpec{}, false
		}
		if node := mapValue(entry, "protocol"); node != nil {
			if node.Kind != yaml.ScalarNode {
				return portSpec{}, false
			}
			if protocol, ok = interpolate(node.Value, lookup); !ok {
				return portSpec{}, false
			}
		}
	default:
		return portSpec{}, false
	}
	low, high, isRange := strings.Cut(target, "-")
	first, err := strconv.ParseUint(low, 10, 16)
	if err != nil {
		return portSpec{}, false
	}
	last := first
	if isRange {
		if last, err = strconv.ParseUint(high, 10, 16); err != nil || last < first {
			return portSpec{}, false
		}
	}
	if protocol = strings.ToLower(protocol); protocol == "" {
		protocol = "tcp"
	}
	return portSpec{first, last, protocol}, true
}

// ensurePublishedPort makes sure the service publishes want's container port
// under want's protocol in some form, every entry and want read with lookup.
// If no existing `ports` entry publishes it, want is appended. An entry whose
// container port does not read leaves the list as it is, since it may be the
// port itself, and so does a want that does not read. Returns true if want
// was added.
func ensurePublishedPort(svc *yaml.Node, want string, lookup func(string) (string, bool)) bool {
	wantSpec, ok := publishedPort(&yaml.Node{Kind: yaml.ScalarNode, Value: want}, lookup)
	if !ok {
		return false
	}
	if seq := mapValue(svc, "ports"); seq != nil && seq.Kind == yaml.SequenceNode {
		for _, child := range seq.Content {
			if spec, ok := publishedPort(child, lookup); !ok || spec.publishes(wantSpec) {
				return false
			}
		}
	}
	return ensureSequenceItem(svc, "ports", want)
}

// ensureSequenceItem makes sure that the sequence at parent[key] contains
// the given scalar item. If the sequence doesn't exist, it's created. If the
// item is already present (by string equality), nothing changes. Returns
// true if the item was added.
func ensureSequenceItem(parent *yaml.Node, key, item string) bool {
	seq := mapValue(parent, key)
	if seq == nil {
		// Create the sequence with the item as its only element.
		setMapValue(parent, key, &yaml.Node{
			Kind: yaml.SequenceNode,
			Content: []*yaml.Node{
				{Kind: yaml.ScalarNode, Tag: "!!str", Value: item},
			},
		})
		return true
	}
	if seq.Kind != yaml.SequenceNode {
		return false
	}
	for _, child := range seq.Content {
		if child.Value == item {
			return false
		}
	}
	seq.Content = append(seq.Content, &yaml.Node{
		Kind:  yaml.ScalarNode,
		Tag:   "!!str",
		Value: item,
	})
	return true
}
