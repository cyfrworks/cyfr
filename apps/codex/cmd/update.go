package cmd

import (
	"fmt"
	"os"
	"os/exec"
	"strings"

	"github.com/cyfr/codex/internal/output"
	"github.com/cyfr/codex/internal/scaffold"
	"github.com/spf13/cobra"
	"gopkg.in/yaml.v3"
)

func init() {
	rootCmd.AddCommand(updateCmd)
}

var updateCmd = &cobra.Command{
	Use:     "update",
	Short:   "Update project scaffold files (docs, WIT definitions, aqua prompts)",
	Long:    "Update managed scaffold files (docs, WIT interface definitions, bundled aqua prompts) in the current project directory. Also ensures that docker-compose.yml has all the volume mounts and fields the cyfr server requires, adding any missing ones in place.",
	GroupID: "server",
	Example: "  cyfr update",
	Run: func(cmd *cobra.Command, args []string) {
		// Require cyfr.yaml in current directory
		if _, err := os.Stat("cyfr.yaml"); err != nil {
			output.Errorf("Not in a cyfr project directory (no cyfr.yaml found).\nRun 'cyfr init' to create a new project.")
		}

		fmt.Println("Updating project scaffold files...")

		// Pull latest Docker images for the whole stack (cyfr, plus caddy when
		// TLS mode is on) via compose so they're kept in sync. mcp-bridge
		// is built locally and skipped by `compose pull`. Non-fatal — the
		// project runs via Docker.
		if _, err := exec.LookPath("docker"); err == nil {
			fmt.Println("Pulling latest Docker images...")
			pullArgs := []string{"compose"}
			if envFlagTrue(".env", "CYFR_BEHIND_PROXY") {
				pullArgs = append(pullArgs, "--profile", "tls")
			}
			pullArgs = append(pullArgs, "pull")
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
		if err := scaffold.Update(Version); err != nil {
			output.Errorf("Failed to update scaffold files: %v", err)
		}

		fmt.Println("Scaffold files updated (component-guide.md, tincture-guide.md, integration-guide.md, wit/, aqua/).")

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
	},
}

// warnMissingStackServices prints a note if docker-compose.yml lacks the
// mcp-bridge service — i.e. it predates the bundled stack. We don't auto-add
// it: a hand-edited compose is the user's. `cyfr init --force` regenerates
// the whole file from the scaffold.
func warnMissingStackServices(path string) {
	data, err := os.ReadFile(path)
	if err != nil {
		return
	}
	var root yaml.Node
	if err := yaml.Unmarshal(data, &root); err != nil || root.Kind != yaml.DocumentNode || len(root.Content) == 0 {
		return
	}
	services := mapValue(root.Content[0], "services")
	if services == nil {
		return
	}
	var missing []string
	for _, name := range []string{"mcp-bridge"} {
		if mapValue(services, name) == nil {
			missing = append(missing, name)
		}
	}
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

// requiredPorts must appear in the cyfr service's ports list. Bound to the
// loopback interface: the Codex CLI and the browser talk to
// http://127.0.0.1:4000, but the un-TLS'd endpoint is never published to the
// internet (Caddy fronts :80/:443 and reaches cyfr over the compose network).
var requiredPorts = []string{
	"127.0.0.1:4000:4000",
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
		return nil, fmt.Errorf("docker-compose.yml is not valid YAML: %v", err)
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

	// ports — ensure :4000 is published. We match by container port
	// (any host-binding form counts), so an existing "4000:4000" isn't
	// duplicated; only a project missing the mapping entirely gets the
	// loopback-bound entry added (existing 0.0.0.0 publishes are left alone).
	for _, port := range requiredPorts {
		if ensurePublishedPort(cyfrNode, port) {
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
		return nil, fmt.Errorf("failed to re-serialize docker-compose.yml: %v", err)
	}
	if err := enc.Close(); err != nil {
		return nil, fmt.Errorf("failed to close encoder: %v", err)
	}
	if err := os.WriteFile(path, []byte(buf.String()), 0644); err != nil {
		return nil, fmt.Errorf("failed to write docker-compose.yml: %v", err)
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

// containerPort returns the container-side port of a compose `ports` entry:
// "127.0.0.1:4000:4000" → "4000", "4000:4000" → "4000", "4000" → "4000",
// "4000:4000/tcp" → "4000".
func containerPort(mapping string) string {
	if i := strings.IndexByte(mapping, '/'); i >= 0 {
		mapping = mapping[:i]
	}
	parts := strings.Split(mapping, ":")
	return parts[len(parts)-1]
}

// ensurePublishedPort makes sure the service publishes want's container port in
// some form. If no existing `ports` entry maps that container port, want is
// appended. Returns true if it was added.
func ensurePublishedPort(svc *yaml.Node, want string) bool {
	wantCP := containerPort(want)
	if seq := mapValue(svc, "ports"); seq != nil && seq.Kind == yaml.SequenceNode {
		for _, child := range seq.Content {
			if containerPort(child.Value) == wantCP {
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
