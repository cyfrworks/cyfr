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

		// Pull latest Docker image (non-fatal, since the project runs via Docker)
		if _, err := exec.LookPath("docker"); err == nil {
			fmt.Println("Pulling latest Docker image...")
			pull := exec.Command("docker", "pull", "ghcr.io/cyfrworks/cyfr:latest")
			pull.Stdout = os.Stdout
			pull.Stderr = os.Stderr
			if err := pull.Run(); err != nil {
				fmt.Printf("Warning: failed to pull Docker image: %v\n", err)
			} else {
				fmt.Println("Docker image updated.")
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
		// additional services, etc.) are preserved. Porta-specific bridge
		// fields (e.g. extra_hosts for the MCP gateway) are NOT managed here —
		// porta writes those into a docker-compose.override.yml itself.
		if added, err := ensureCyfrComposeFields("docker-compose.yml"); err != nil {
			fmt.Fprintf(os.Stderr, "\nNote: %v\n", err)
			fmt.Fprintln(os.Stderr, "Run 'cyfr init --force' to regenerate docker-compose.yml from scratch.")
		} else if len(added) > 0 {
			fmt.Printf("Added missing fields to docker-compose.yml: %v\n", added)
		}
	},
}

// requiredVolumes maps a host path to its container mount path. Each entry
// must appear in the cyfr service's volumes list.
var requiredVolumes = []string{
	"./data:/app/data",
	"./components:/app/components",
	"./aqua:/app/aqua",
}

// requiredPorts must appear in the cyfr service's ports list.
var requiredPorts = []string{
	"4000:4000",
	"4001:4001",
}

// requiredEnvFiles must appear in the cyfr service's env_file list.
var requiredEnvFiles = []string{
	".env",
}

// ensureCyfrComposeFields parses docker-compose.yml, locates the cyfr service,
// and ensures all required fields are present. Missing volumes, ports,
// env_file entries, and container_name are added. Existing user content
// (env vars, networks, labels, custom additions) is preserved. Porta-specific
// bridge fields (extra_hosts for the MCP gateway) are intentionally NOT
// managed here — porta owns those via its own docker-compose.override.yml.
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

	// container_name: cyfr — needed for `docker inspect cyfr` from Porta.
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

	// ports — ensure standard ports are present.
	for _, port := range requiredPorts {
		if ensureSequenceItem(cyfrNode, "ports", port) {
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
