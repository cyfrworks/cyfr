// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"bufio"
	"crypto/rand"
	"encoding/base64"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"time"

	"github.com/cyfr/codex/internal/config"
	"github.com/cyfr/codex/internal/prompt"
	"github.com/cyfr/codex/internal/scaffold"
	"github.com/cyfr/codex/internal/version"
	"github.com/spf13/cobra"
	"gopkg.in/yaml.v3"
)

// generateSecretKey returns a 64-byte cryptographically random key, base64url-encoded.
func generateSecretKey() (string, error) {
	b := make([]byte, 64)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return base64.URLEncoding.EncodeToString(b), nil
}

func init() {
	initCmd.Flags().Bool("force", false, "Re-fetch docker-compose.yml + Caddyfile and regenerate cyfr.yaml even if they already exist (never touches .env / .env.example)")
	rootCmd.AddCommand(initCmd)
	rootCmd.AddCommand(upCmd)
	rootCmd.AddCommand(downCmd)
}

var initCmd = &cobra.Command{
	Use:     "init",
	Short:   "Scaffold a CYFR project in the current directory",
	GroupID: "server",
	Long: `Set up a CYFR project in the current directory so you can start the self-hosted stack (cyfr + mcp-bridge, plus optional caddy) with "cyfr up".

Downloads docker-compose.yml, Caddyfile, .env.example, and the bundled scaffold (component/tincture/integration guides, wit/ definitions, aqua/ prompts) for this CLI's version; generates cyfr.yaml, .gitignore, and the data/aqua directories; and derives .env from .env.example — a fresh CYFR_SECRET_KEY_BASE is generated and you're prompted for the hostname, an allowed sign-in email, a TLS y/n choice, and (if TLS) a Let's Encrypt email. Run with --no-interactive to take the defaults silently.

Re-running in an existing project is safe: docker-compose.yml, Caddyfile, cyfr.yaml, .env, and .env.example are kept if they already exist. Use --force to re-fetch docker-compose.yml + Caddyfile and regenerate cyfr.yaml (--force never touches .env / .env.example).`,
	Example: `  cyfr init
  cyfr init --force
  cyfr up`,
	RunE: func(cmd *cobra.Command, args []string) error {
		force, _ := cmd.Flags().GetBool("force")
		releaseBuild := version.Version != "dev" && version.Version != ""

		// On --force, drop the tarball-managed deploy files so scaffold.Download
		// re-extracts them, and regenerate cyfr.yaml. .env / .env.example are
		// deliberately never removed. (On a dev build the tarball is a no-op, so
		// don't delete docker-compose.yml/Caddyfile we couldn't replace.)
		if force {
			if releaseBuild {
				_ = os.Remove("docker-compose.yml")
				_ = os.Remove("Caddyfile")
			}
			_ = os.Remove("cyfr.yaml")
		}

		// Download scaffold files (non-fatal): guides, wit/, aqua/, and the
		// deploy files (docker-compose.yml, Caddyfile, .env.example,
		// Dockerfile.node). Idempotent — existing files kept. No-op for dev
		// builds (version.Version=="dev"/"").
		if err := scaffold.Download(version.Version); err != nil {
			fmt.Fprintf(os.Stderr, "Warning: failed to download scaffold files: %v (continuing anyway)\n", err)
		}

		// Warm-pull every image referenced in docker-compose.yml (cyfr, caddy —
		// mcp-bridge is `build:`-only and has no image: line, so it's skipped).
		// Plain `docker pull` doesn't need .env to exist. Falls back to the
		// published cyfr image on a dev build (no compose).
		images := imagesFromCompose("docker-compose.yml")
		if len(images) == 0 {
			images = []string{"ghcr.io/cyfrworks/cyfr:latest"}
		}
		for _, img := range images {
			fmt.Printf("Pulling %s ...\n", img)
			pull := exec.Command("docker", "pull", img)
			pull.Stdout = os.Stdout
			pull.Stderr = os.Stderr
			if err := pull.Run(); err != nil {
				fmt.Fprintf(os.Stderr, "Warning: failed to pull %s: %v (continuing anyway)\n", img, err)
			}
		}

		composeExists := fileExists("docker-compose.yml")
		caddyfileExists := fileExists("Caddyfile")

		// Generate cyfr.yaml (project config) if absent
		cyfrConfig := `name: my-cyfr-project
port: 4000
host: localhost
database_path: ./data/cyfr.db
`
		configCreated := false
		if !fileExists("cyfr.yaml") {
			if err := os.WriteFile("cyfr.yaml", []byte(cyfrConfig), 0644); err != nil {
				return fmt.Errorf("Failed to write cyfr.yaml: %v", err)
			}
			configCreated = true
		}

		// Generate .env from the .env.example template laid down by the scaffold
		// (idempotent). If .env.example isn't present — a dev build, where the
		// scaffold download is a no-op — skip it; the dev-build notice below
		// tells the user where to get it.
		envCreated := false
		adminEmailConfigured := false
		envExampleExists := fileExists(".env.example")
		if envExampleExists && !fileExists(".env") {
			tmpl, err := os.ReadFile(".env.example")
			if err != nil {
				return fmt.Errorf("Failed to read .env.example: %v", err)
			}
			secretKey, err := generateSecretKey()
			if err != nil {
				return fmt.Errorf("Failed to generate secret key: %v", err)
			}
			bridgeToken, err := generateSecretKey()
			if err != nil {
				return fmt.Errorf("Failed to generate mcp-bridge token: %v", err)
			}

			host := "localhost"
			adminEmail := ""
			acmeEmail := ""
			tls := false
			if prompt.IsInteractive(flagNoInteractive) {
				r := bufio.NewReader(os.Stdin)
				host = ask(r, "Hostname clients use to reach this server", "localhost")
				fmt.Println("CYFR authorizes by membership — list your email as the platform admin so you can use this instance.")
				adminEmail = ask(r, "Your platform-admin email (required to access this instance; blank = no one is authorized yet)", "")
				// Default to TLS only when there's a real hostname to put a cert on.
				tlsDefault := "n"
				if host != "localhost" {
					tlsDefault = "y"
				}
				tls = strings.HasPrefix(strings.ToLower(ask(r, "Will this deploy be reachable on a public hostname with TLS via Caddy? (y/n)", tlsDefault)), "y")
				if tls {
					acmeEmail = ask(r, "Email for Let's Encrypt TLS certificates (CADDY_ACME_EMAIL)", "")
				}
			}
			adminEmailConfigured = adminEmail != ""

			if err := os.WriteFile(".env", []byte(renderEnvFile(string(tmpl), secretKey, bridgeToken, host, adminEmail, acmeEmail, tls)), 0600); err != nil {
				return fmt.Errorf("Failed to write .env: %v", err)
			}
			envCreated = true
		}

		// Ensure the mcp-bridge bind-mount target exists so the container can
		// write ./data/mcp-bridge/backends.json on first add_backend.
		_ = os.MkdirAll("data/mcp-bridge", 0755)

		// Generate .gitignore if it doesn't already exist (idempotent)
		gitignoreCreated := false
		gitignoreContent := `# CYFR project — all runtime state (every athanor's data and
# components, the database, caches) lives under data/.
/data/
.env
.env.local
.env.*.local
`
		if _, err := os.Stat(".gitignore"); os.IsNotExist(err) {
			if err := os.WriteFile(".gitignore", []byte(gitignoreContent), 0644); err != nil {
				return fmt.Errorf("Failed to write .gitignore: %v", err)
			}
			gitignoreCreated = true
		}

		// Create directories. These are the bind-mount sources in
		// docker-compose.yml, so they must exist even on a dev build where the
		// scaffold tarball is a no-op. The container's entrypoint seeds aqua/
		// from /app/aqua-defaults on first start if it's empty.
		_ = os.MkdirAll("data", 0755)
		_ = os.MkdirAll("aqua", 0755)

		// Add local context
		cfg, err := config.Load()
		if err != nil {
			cfg = &config.Config{
				CurrentContext: "local",
				Contexts:       map[string]*config.Context{},
			}
		}
		cfg.Contexts["local"] = &config.Context{URL: "http://127.0.0.1:4000"}
		cfg.CurrentContext = "local"
		_ = cfg.Save()

		fmt.Println("CYFR project initialized.")
		if releaseBuild {
			if composeExists {
				fmt.Println("  docker-compose.yml ready (cyfr + mcp-bridge; caddy via `tls` profile)")
			}
			if caddyfileExists {
				fmt.Println("  Caddyfile ready")
			}
			fmt.Println("  component-guide.md / tincture-guide.md / integration-guide.md downloaded")
			fmt.Println("  wit/ interface definitions downloaded")
			fmt.Println("  aqua/ orchestrator prompts downloaded")
		}
		if configCreated {
			fmt.Println("  cyfr.yaml created")
		} else {
			fmt.Println("  cyfr.yaml already exists (skipped).")
		}
		if envCreated {
			fmt.Println("  .env created from .env.example (contains a generated secret key + mcp-bridge token — do not commit)")
			fmt.Println("     To require the bridge token, register mcp-bridge in the PWA with header")
			fmt.Println("     `Authorization: vault:mcp_bridge_token` and store MCP_BRIDGE_TOKEN's value in a")
			fmt.Println("     Vault entry named `mcp_bridge_token`.")
		} else if fileExists(".env") {
			fmt.Println("  .env already exists (skipped).")
		}
		if gitignoreCreated {
			fmt.Println("  .gitignore created")
		} else {
			fmt.Println("  .gitignore already exists (skipped).")
		}
		fmt.Println("  data/, aqua/ created")

		if !releaseBuild {
			fmt.Println("")
			fmt.Println("⚠  dev build — docker-compose.yml, Caddyfile, .env.example and the bundled")
			fmt.Println("   scaffold (guides, wit/, aqua/) are only fetched for released")
			fmt.Println("   versions. Run the server from source with `mix phx.server`, or copy those")
			fmt.Println("   files from a repo checkout.")
		}
		if envCreated && !adminEmailConfigured {
			fmt.Println("")
			fmt.Println("⚠  CYFR_PLATFORM_ADMIN_EMAILS is unset in .env — no one is authorized to use this instance yet.")
			fmt.Println("   Set CYFR_PLATFORM_ADMIN_EMAILS=you@example.com in .env so you (the operator) can sign in.")
		}
		fmt.Println("")
		if composeExists {
			fmt.Println("Next: run 'cyfr up' to start the stack.")
			fmt.Println("  Prism:           https://<your CYFR_HOST>/  (TLS mode)  or  http://localhost:4000/  (direct)")
		} else {
			fmt.Println("Next: get docker-compose.yml + Caddyfile (a released CLI or a repo checkout), then 'cyfr up'.")
		}
		return nil
	},
}

// fileExists reports whether path exists (file or directory).
func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

// imagesFromCompose returns every `image:` value referenced by services in the
// compose file at path, in the order they appear. Build-only services (e.g.
// mcp-bridge, which has only `build:`) are skipped. Returns nil if the file
// can't be read or parsed — callers should fall back to a sensible default.
func imagesFromCompose(path string) []string {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	var root yaml.Node
	if err := yaml.Unmarshal(data, &root); err != nil || root.Kind != yaml.DocumentNode || len(root.Content) == 0 {
		return nil
	}
	services := mapValue(root.Content[0], "services")
	if services == nil || services.Kind != yaml.MappingNode {
		return nil
	}
	var images []string
	for i := 0; i+1 < len(services.Content); i += 2 {
		svc := services.Content[i+1]
		if svc.Kind != yaml.MappingNode {
			continue
		}
		if img := mapValue(svc, "image"); img != nil && img.Value != "" {
			images = append(images, img.Value)
		}
	}
	return images
}

// ask prompts on stdout and reads a line from r, returning def if the input is empty.
func ask(r *bufio.Reader, question, def string) string {
	if def != "" {
		fmt.Printf("%s [%s]: ", question, def)
	} else {
		fmt.Printf("%s: ", question)
	}
	line, _ := r.ReadString('\n')
	line = strings.TrimSpace(line)
	if line == "" {
		return def
	}
	return line
}

// renderEnvFile fills in a .env.example template: substitutes the generated
// secret key, sets MCP_BRIDGE_TOKEN (whether the template ships it commented
// or not) so the bridge boots closed, sets CYFR_HOST, sets CADDY_ACME_EMAIL
// if non-empty, flips CYFR_BEHIND_PROXY based on the TLS choice, and (if
// adminEmail is non-empty) un-comments and sets CYFR_PLATFORM_ADMIN_EMAILS.
// Everything else is left as-is. TestRenderEnvFileShippedTemplate binds this
// key set to the real .env.example — a template edit that strands a key
// fails there, not on a user's first `cyfr up`.
func renderEnvFile(template, secretKey, bridgeToken, host, adminEmail, acmeEmail string, tls bool) string {
	behindProxy := "false"
	if tls {
		behindProxy = "true"
	}
	lines := strings.Split(template, "\n")
	for i, line := range lines {
		switch {
		case strings.HasPrefix(line, "CYFR_SECRET_KEY_BASE="):
			lines[i] = "CYFR_SECRET_KEY_BASE=" + secretKey
		case strings.HasPrefix(line, "MCP_BRIDGE_TOKEN="),
			strings.HasPrefix(line, "# MCP_BRIDGE_TOKEN="):
			lines[i] = "MCP_BRIDGE_TOKEN=" + bridgeToken
		case strings.HasPrefix(line, "CYFR_HOST="):
			lines[i] = "CYFR_HOST=" + host
		case strings.HasPrefix(line, "CYFR_BEHIND_PROXY="):
			lines[i] = "CYFR_BEHIND_PROXY=" + behindProxy
		case acmeEmail != "" && strings.HasPrefix(line, "CADDY_ACME_EMAIL="):
			lines[i] = "CADDY_ACME_EMAIL=" + acmeEmail
		case adminEmail != "" && strings.HasPrefix(line, "# CYFR_PLATFORM_ADMIN_EMAILS="):
			lines[i] = "CYFR_PLATFORM_ADMIN_EMAILS=" + adminEmail
		}
	}
	return strings.Join(lines, "\n")
}

var upCmd = &cobra.Command{
	Use:     "up",
	Short:   "Start the CYFR stack (cyfr + mcp-bridge, plus caddy in TLS mode)",
	GroupID: "server",
	Long: `Start the CYFR stack with Docker Compose in detached mode. Requires a docker-compose.yml in the current directory (run 'cyfr init' first).

Always brings up cyfr (the one endpoint: Prism, API, MCP, tinctures) and mcp-bridge (HTTP MCP gateway that wraps stdio/npx MCP servers — register it from Prism's "MCP Servers" page).

When CYFR_BEHIND_PROXY=true in .env, caddy is also started (TLS profile) and fronts cyfr on :80/:443. Otherwise cyfr is reachable directly at http://localhost:4000.`,
	Example: `  cyfr up`,
	RunE: func(cmd *cobra.Command, args []string) error {
		// Registry auth is per-user: `cyfr login` (device flow) after
		// `cyfr context add`, and cyfr.run mints push tokens via the identity
		// probe. There are no static registry credentials to configure.

		// `cyfr init` writes CYFR_BEHIND_PROXY=true into .env on TLS-yes and
		// reads back to flip the caddy profile here.
		tls := envFlagTrue(".env", "CYFR_BEHIND_PROXY")
		composeArgs := []string{"compose"}
		if tls {
			composeArgs = append(composeArgs, "--profile", "tls")
		}
		composeArgs = append(composeArgs, "up", "-d")

		c := exec.Command("docker", composeArgs...)
		c.Stdout = os.Stdout
		c.Stderr = os.Stderr
		if err := c.Run(); err != nil {
			return fmt.Errorf("Failed to start: %v", err)
		}
		fmt.Println("CYFR server started.")

		// Health check wait
		cfg, err := config.Load()
		if err != nil {
			cfg = config.DefaultForLocal()
		}
		healthURL := cfg.CurrentURL() + "/api/health"

		fmt.Printf("Waiting for server at %s ...\n", cfg.CurrentURL())
		client := &http.Client{Timeout: 2 * time.Second}
		deadline := time.Now().Add(30 * time.Second)
		healthy := false
		for time.Now().Before(deadline) {
			resp, err := client.Get(healthURL)
			if err == nil {
				resp.Body.Close()
				if resp.StatusCode == http.StatusOK {
					healthy = true
					break
				}
			}
			time.Sleep(1 * time.Second)
		}

		if healthy {
			fmt.Println("Server is ready.")
			if tls {
				fmt.Println("  Prism:           https://<your CYFR_HOST>/   (via Caddy on :80/:443)")
			} else {
				fmt.Println("  Prism:           http://localhost:4000/   (direct mode)")
			}
			fmt.Println("")
			fmt.Println("Optional next steps:")
			fmt.Println("  cyfr login      authenticate this CLI")
			fmt.Println("  cyfr register   scan & register the bundled components")
			fmt.Println("  Then in Prism's \"MCP Servers\" page, click \"Setup MCP Bridge\"")
			fmt.Println("  to wire stdio/npx MCP servers (filesystem, github, …) into AQUA.")
		} else {
			fmt.Fprintf(os.Stderr, "Warning: server did not become healthy within 30s. Check 'docker compose logs'.\n")
		}
		return nil
	},
}

var downCmd = &cobra.Command{
	Use:     "down",
	Short:   "Stop the CYFR server container",
	GroupID: "server",
	Long:    "Stop the CYFR server and remove its containers via Docker Compose. Includes the tls-profile caddy service so a stack started with `cyfr up` in TLS mode is fully torn down.",
	Example: "  cyfr down",
	RunE: func(cmd *cobra.Command, args []string) error {
		// Always pass --profile tls so down considers the opt-in caddy too;
		// harmless if it isn't running.
		c := exec.Command("docker", "compose", "--profile", "tls", "down")
		c.Stdout = os.Stdout
		c.Stderr = os.Stderr
		if err := c.Run(); err != nil {
			return fmt.Errorf("Failed to stop: %v", err)
		}

		fmt.Println("CYFR server stopped.")
		return nil
	},
}

// envFlagTrue reports whether `key=` in the dotenv-style file `path` is a
// truthy value (`true`/`1`/`yes`, case-insensitive). Returns false if the
// file is unreadable or the key is absent.
func envFlagTrue(path, key string) bool {
	data, err := os.ReadFile(path)
	if err != nil {
		return false
	}
	prefix := key + "="
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "#") {
			continue
		}
		if strings.HasPrefix(line, prefix) {
			v := strings.ToLower(strings.TrimSpace(strings.TrimPrefix(line, prefix)))
			v = strings.Trim(v, `"'`)
			return v == "true" || v == "1" || v == "yes"
		}
	}
	return false
}
