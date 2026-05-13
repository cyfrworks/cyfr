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
	"github.com/cyfr/codex/internal/output"
	"github.com/cyfr/codex/internal/prompt"
	"github.com/cyfr/codex/internal/scaffold"
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
	Long: `Set up a CYFR project in the current directory so you can start the self-hosted stack (cyfr + porta + mcp-bridge, plus optional caddy) with "cyfr up".

Downloads docker-compose.yml, Caddyfile, .env.example, and the bundled scaffold (component/tincture/integration guides, wit/ definitions, example components, aqua/ prompts) for this CLI's version; generates cyfr.yaml, .gitignore, and the data/components/aqua directories; and derives .env from .env.example — a fresh CYFR_SECRET_KEY_BASE is generated and you're prompted for the hostname, an allowed sign-in email, a TLS y/n choice, and (if TLS) a Let's Encrypt email. Run with --no-interactive to take the defaults silently.

Re-running in an existing project is safe: docker-compose.yml, Caddyfile, cyfr.yaml, .env, and .env.example are kept if they already exist. Use --force to re-fetch docker-compose.yml + Caddyfile and regenerate cyfr.yaml (--force never touches .env / .env.example).`,
	Example: `  cyfr init
  cyfr init --force
  cyfr up`,
	Run: func(cmd *cobra.Command, args []string) {
		force, _ := cmd.Flags().GetBool("force")
		releaseBuild := Version != "dev" && Version != ""

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

		// Download scaffold files (non-fatal): guides, wit/, components/, aqua/,
		// and the deploy files (docker-compose.yml, Caddyfile, .env.example,
		// Dockerfile.node). Idempotent — existing files kept. No-op for dev
		// builds (Version=="dev"/"").
		if err := scaffold.Download(Version); err != nil {
			fmt.Fprintf(os.Stderr, "Warning: failed to download scaffold files: %v (continuing anyway)\n", err)
		}

		// Warm-pull every image referenced in docker-compose.yml (cyfr, porta,
		// caddy — mcp-bridge is `build:`-only and has no image: line, so it's
		// skipped). Plain `docker pull` doesn't need .env to exist. Falls back
		// to our two published images on a dev build (no compose).
		images := imagesFromCompose("docker-compose.yml")
		if len(images) == 0 {
			images = []string{
				"ghcr.io/cyfrworks/cyfr:latest",
				"ghcr.io/cyfrworks/cyfr-porta:latest",
			}
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
				output.Errorf("Failed to write cyfr.yaml: %v", err)
			}
			configCreated = true
		}

		// Generate .env from the .env.example template laid down by the scaffold
		// (idempotent). If .env.example isn't present — a dev build, where the
		// scaffold download is a no-op — skip it; the dev-build notice below
		// tells the user where to get it.
		envCreated := false
		allowedUserConfigured := false
		envExampleExists := fileExists(".env.example")
		if envExampleExists && !fileExists(".env") {
			tmpl, err := os.ReadFile(".env.example")
			if err != nil {
				output.Errorf("Failed to read .env.example: %v", err)
			}
			secretKey, err := generateSecretKey()
			if err != nil {
				output.Errorf("Failed to generate secret key: %v", err)
			}

			host := "localhost"
			allowedUser := ""
			acmeEmail := ""
			tls := false
			if prompt.IsInteractive(flagNoInteractive) {
				r := bufio.NewReader(os.Stdin)
				host = ask(r, "Hostname clients use to reach this server", "localhost")
				fmt.Println("CYFR is single-user — restrict sign-in to your email so only you can log in.")
				allowedUser = ask(r, "Allowed sign-in email (strongly recommended; blank = anyone with a GitHub/Google account may sign in)", "")
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
			allowedUserConfigured = allowedUser != ""

			if err := os.WriteFile(".env", []byte(renderEnvFile(string(tmpl), secretKey, host, allowedUser, acmeEmail, tls)), 0600); err != nil {
				output.Errorf("Failed to write .env: %v", err)
			}
			envCreated = true
		}

		// Ensure the mcp-bridge bind-mount target exists so the container can
		// write ./data/mcp-bridge/backends.json on first add_backend.
		_ = os.MkdirAll("data/mcp-bridge", 0755)

		// Generate .gitignore if it doesn't already exist (idempotent)
		gitignoreCreated := false
		gitignoreContent := `# CYFR project
/data/
.env
.env.local
.env.*.local

# Component build artifacts
components/**/target/

# Pulled/published components (OCI, named publishers)
# local/ and agent/ are preserved for development
components/catalysts/*/
!components/catalysts/local/
!components/catalysts/agent/
components/reagents/*/
!components/reagents/local/
!components/reagents/agent/
components/formulas/*/
!components/formulas/local/
!components/formulas/agent/
`
		if _, err := os.Stat(".gitignore"); os.IsNotExist(err) {
			if err := os.WriteFile(".gitignore", []byte(gitignoreContent), 0644); err != nil {
				output.Errorf("Failed to write .gitignore: %v", err)
			}
			gitignoreCreated = true
		}

		// Create directories. These are the bind-mount sources in
		// docker-compose.yml, so they must exist even on a dev build where the
		// scaffold tarball is a no-op. The container's entrypoint seeds aqua/
		// from /app/aqua-defaults on first start if it's empty.
		_ = os.MkdirAll("data", 0755)
		_ = os.MkdirAll("aqua", 0755)

		// Create component type subdirs
		componentSubdirs := []string{
			"components/catalysts/local",
			"components/reagents/local",
			"components/formulas/local",
		}
		for _, dir := range componentSubdirs {
			_ = os.MkdirAll(dir, 0755)
		}

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
				fmt.Println("  docker-compose.yml ready (cyfr + porta + mcp-bridge; caddy via `tls` profile)")
			}
			if caddyfileExists {
				fmt.Println("  Caddyfile ready")
			}
			fmt.Println("  component-guide.md / tincture-guide.md / integration-guide.md downloaded")
			fmt.Println("  wit/ interface definitions downloaded")
			fmt.Println("  components/ examples + aqua/ orchestrator prompts downloaded")
		}
		if configCreated {
			fmt.Println("  cyfr.yaml created")
		} else {
			fmt.Println("  cyfr.yaml already exists (skipped).")
		}
		if envCreated {
			fmt.Println("  .env created from .env.example (contains a generated secret key — do not commit)")
		} else if fileExists(".env") {
			fmt.Println("  .env already exists (skipped).")
		}
		if gitignoreCreated {
			fmt.Println("  .gitignore created")
		} else {
			fmt.Println("  .gitignore already exists (skipped).")
		}
		fmt.Println("  data/, aqua/, components/{catalysts,reagents,formulas}/local/ created")

		if !releaseBuild {
			fmt.Println("")
			fmt.Println("⚠  dev build — docker-compose.yml, Caddyfile, .env.example and the bundled")
			fmt.Println("   scaffold (guides, wit/, components/, aqua/) are only fetched for released")
			fmt.Println("   versions. Run the server from source with `mix phx.server`, or copy those")
			fmt.Println("   files from a repo checkout.")
		}
		if envCreated && !allowedUserConfigured {
			fmt.Println("")
			fmt.Println("⚠  CYFR_ALLOWED_USER is unset in .env — anyone with a GitHub/Google account can sign in.")
			fmt.Println("   Set CYFR_ALLOWED_USER=you@example.com in .env before exposing this server.")
		}
		fmt.Println("")
		if composeExists {
			fmt.Println("Next: run 'cyfr up' to start the stack.")
			fmt.Println("  A.Q.U.A. PWA:    https://<your CYFR_HOST>/  (TLS mode)  or  http://<your CYFR_HOST>:8080/  (direct)")
			fmt.Println("  Prism dashboard: http://localhost:4001")
		} else {
			fmt.Println("Next: get docker-compose.yml + Caddyfile (a released CLI or a repo checkout), then 'cyfr up'.")
		}
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
// secret key, sets CYFR_HOST, sets CADDY_ACME_EMAIL if non-empty, flips
// CYFR_BEHIND_PROXY + CYFR_PORTA_BIND based on the TLS choice, and (if
// allowedUser is non-empty) un-comments and sets CYFR_ALLOWED_USER.
// Everything else is left as-is.
func renderEnvFile(template, secretKey, host, allowedUser, acmeEmail string, tls bool) string {
	portaBind := "0.0.0.0:8080"
	behindProxy := "false"
	if tls {
		portaBind = "127.0.0.1:8080"
		behindProxy = "true"
	}
	lines := strings.Split(template, "\n")
	for i, line := range lines {
		switch {
		case strings.HasPrefix(line, "CYFR_SECRET_KEY_BASE="):
			lines[i] = "CYFR_SECRET_KEY_BASE=" + secretKey
		case strings.HasPrefix(line, "CYFR_HOST="):
			lines[i] = "CYFR_HOST=" + host
		case strings.HasPrefix(line, "CYFR_BEHIND_PROXY="):
			lines[i] = "CYFR_BEHIND_PROXY=" + behindProxy
		case strings.HasPrefix(line, "CYFR_PORTA_BIND="):
			lines[i] = "CYFR_PORTA_BIND=" + portaBind
		case acmeEmail != "" && strings.HasPrefix(line, "CADDY_ACME_EMAIL="):
			lines[i] = "CADDY_ACME_EMAIL=" + acmeEmail
		case allowedUser != "" && strings.HasPrefix(line, "# CYFR_ALLOWED_USER="):
			lines[i] = "CYFR_ALLOWED_USER=" + allowedUser
		}
	}
	return strings.Join(lines, "\n")
}

var upCmd = &cobra.Command{
	Use:     "up",
	Short:   "Start the CYFR stack (cyfr + porta + mcp-bridge, plus caddy in TLS mode)",
	GroupID: "server",
	Long: `Start the CYFR stack with Docker Compose in detached mode. Requires a docker-compose.yml in the current directory (run 'cyfr init' first).

Always brings up cyfr (API + Prism), porta (the A.Q.U.A. PWA via vite preview on :8080), and mcp-bridge (HTTP MCP gateway that wraps stdio/npx MCP servers — register it from the PWA's "MCP Servers" page).

When CYFR_BEHIND_PROXY=true in .env, caddy is also started (TLS profile) and fronts the PWA on :80/:443. Otherwise the PWA is reachable directly at http://<CYFR_HOST>:8080.`,
	Example: `  cyfr up`,
	Run: func(cmd *cobra.Command, args []string) {
		// Registry credentials are now stored server-side in the encrypted secrets table.
		// For containerized deployments that need registry auth at startup (before login),
		// set CYFR_REGISTRY_USERNAME and CYFR_REGISTRY_PASSWORD environment variables
		// in the .env file or docker-compose.yml.

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
			output.Errorf("Failed to start: %v", err)
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
				fmt.Println("  A.Q.U.A. PWA:    https://<your CYFR_HOST>/   (via Caddy on :80/:443)")
			} else {
				fmt.Println("  A.Q.U.A. PWA:    http://<your CYFR_HOST>:8080/   (direct mode)")
			}
			fmt.Println("  Prism dashboard: http://localhost:4001")
			fmt.Println("")
			fmt.Println("Optional next steps:")
			fmt.Println("  cyfr login      authenticate this CLI")
			fmt.Println("  cyfr register   scan & register the bundled components")
			fmt.Println("  Then in the PWA's \"MCP Servers\" page, click \"Setup MCP Bridge\"")
			fmt.Println("  to wire stdio/npx MCP servers (filesystem, github, …) into AQUA.")
		} else {
			fmt.Fprintf(os.Stderr, "Warning: server did not become healthy within 30s. Check 'docker compose logs'.\n")
		}
	},
}

var downCmd = &cobra.Command{
	Use:     "down",
	Short:   "Stop the CYFR server container",
	GroupID: "server",
	Long:    "Stop the CYFR server and remove its containers via Docker Compose. Includes the tls-profile caddy service so a stack started with `cyfr up` in TLS mode is fully torn down.",
	Example: "  cyfr down",
	Run: func(cmd *cobra.Command, args []string) {
		// Always pass --profile tls so down considers the opt-in caddy too;
		// harmless if it isn't running.
		c := exec.Command("docker", "compose", "--profile", "tls", "down")
		c.Stdout = os.Stdout
		c.Stderr = os.Stderr
		if err := c.Run(); err != nil {
			output.Errorf("Failed to stop: %v", err)
		}

		fmt.Println("CYFR server stopped.")
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
