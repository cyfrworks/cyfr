package scaffold

import "testing"

// TestIsManaged pins down which scaffold entries `cyfr update` is allowed to
// overwrite. Managed = the docs, the WIT definitions, and the bundled aqua
// prompts. Everything the user owns — config, the compose/proxy files, the
// aqua agent manifest, .env — must NOT be managed, or `cyfr update` would
// clobber them.
func TestIsManaged(t *testing.T) {
	managed := []string{
		"component-guide.md",
		"tincture-guide.md",
		"integration-guide.md",
		"wit",
		"wit/cyfr/oauth/token.wit",
		"aqua/aqua.md",
		"aqua/aqua_builder.md",
		"aqua/aqua_web.md",
	}
	for _, p := range managed {
		if !isManaged(p) {
			t.Errorf("expected %q to be managed (overwritten on update)", p)
		}
	}

	notManaged := []string{
		"docker-compose.yml",
		"Caddyfile",
		".env",
		".env.example",
		"mcp-bridge.json",
		"Dockerfile.node",
		"cyfr.yaml",
		"aqua/agent.json",
		"aqua/aqua_custom.md", // user-created prompt
		"components/catalysts/local/foo/cyfr-manifest.json",
	}
	for _, p := range notManaged {
		if isManaged(p) {
			t.Errorf("expected %q NOT to be managed (must be preserved on update)", p)
		}
	}
}
