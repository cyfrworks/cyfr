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

// randomToken returns n random bytes, base64url-encoded (no padding).
func randomToken(n int) (string, error) {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(b), nil
}

func init() {
	initCmd.Flags().Bool("force", false, "Re-fetch docker-compose.yml + Caddyfile and regenerate cyfr.yaml even if they already exist (never touches .env / .env.example)")
	upCmd.Flags().Bool("no-browser", false, "Don't start the remote browser stack (neko + mcp-bridge); core only (cyfr + web + caddy)")
	upCmd.Flags().Bool("no-mcp-bridge", false, "Don't start mcp-bridge (neko stays); has no effect if --no-browser is also set")
	rootCmd.AddCommand(initCmd)
	rootCmd.AddCommand(upCmd)
	rootCmd.AddCommand(downCmd)
}

var initCmd = &cobra.Command{
	Use:     "init",
	Short:   "Scaffold a CYFR project in the current directory",
	GroupID: "server",
	Long: `Set up a CYFR project in the current directory so you can start the self-hosted stack (cyfr + web + caddy) with "cyfr up".

Downloads docker-compose.yml, Caddyfile, .env.example, and the bundled scaffold (component/tincture/integration guides, wit/ definitions, example components, aqua/ prompts) for this CLI's version; generates cyfr.yaml, .gitignore, and the data/components/aqua directories; and derives .env from .env.example — a fresh CYFR_SECRET_KEY_BASE is generated and you're prompted for the hostname, an allowed sign-in email, and (for a real hostname) a Let's Encrypt email. Run with --no-interactive to take the defaults silently.

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
		// mcp-bridge.json, Dockerfile.node). Idempotent — existing files kept.
		// No-op for dev builds (Version=="dev"/"").
		if err := scaffold.Download(Version); err != nil {
			fmt.Fprintf(os.Stderr, "Warning: failed to download scaffold files: %v (continuing anyway)\n", err)
		}

		// Warm-pull every image referenced in docker-compose.yml (cyfr, web,
		// caddy, neko — mcp-bridge is `build:`-only and has no image: line, so
		// it's skipped). Plain `docker pull` doesn't need .env to exist, unlike
		// `docker compose pull` which would try to interpolate ${NEKO_PASSWORD}.
		// Falls back to our two published images on a dev build (no compose).
		images := imagesFromCompose("docker-compose.yml")
		if len(images) == 0 {
			images = []string{
				"ghcr.io/cyfrworks/cyfr:latest",
				"ghcr.io/cyfrworks/cyfr-web:latest",
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
			// Always replace the .env.example placeholder NEKO_PASSWORD=changeme
			// with a real random one so `cyfr up` (which enables the browser
			// profile by default) starts cleanly without a manual edit.
			nekoPassword, err := randomToken(24)
			if err != nil {
				output.Errorf("Failed to generate NEKO_PASSWORD: %v", err)
			}

			host := "localhost"
			allowedUser := ""
			acmeEmail := ""
			if prompt.IsInteractive(flagNoInteractive) {
				r := bufio.NewReader(os.Stdin)
				host = ask(r, "Hostname clients use to reach this server", "localhost")
				fmt.Println("CYFR is single-user — restrict sign-in to your email so only you can log in.")
				allowedUser = ask(r, "Allowed sign-in email (strongly recommended; blank = anyone with a GitHub/Google account may sign in)", "")
				if host != "localhost" {
					acmeEmail = ask(r, "Email for Let's Encrypt TLS certificates (CADDY_ACME_EMAIL)", "")
				}
			}
			allowedUserConfigured = allowedUser != ""

			if err := os.WriteFile(".env", []byte(renderEnvFile(string(tmpl), secretKey, host, allowedUser, acmeEmail, nekoPassword)), 0600); err != nil {
				output.Errorf("Failed to write .env: %v", err)
			}
			envCreated = true
		}

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
				fmt.Println("  docker-compose.yml ready (cyfr + web + caddy)")
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
			fmt.Println("  A.Q.U.A. PWA:    http(s)://<your CYFR_HOST>/   (Caddy serves :80/:443)")
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
// secret key, sets CYFR_HOST, sets CADDY_ACME_EMAIL if non-empty, replaces
// NEKO_PASSWORD if non-empty, and (if allowedUser is non-empty) un-comments
// and sets CYFR_ALLOWED_USER. Everything else is left as-is.
func renderEnvFile(template, secretKey, host, allowedUser, acmeEmail, nekoPassword string) string {
	lines := strings.Split(template, "\n")
	for i, line := range lines {
		switch {
		case strings.HasPrefix(line, "CYFR_SECRET_KEY_BASE="):
			lines[i] = "CYFR_SECRET_KEY_BASE=" + secretKey
		case strings.HasPrefix(line, "CYFR_HOST="):
			lines[i] = "CYFR_HOST=" + host
		case acmeEmail != "" && strings.HasPrefix(line, "CADDY_ACME_EMAIL="):
			lines[i] = "CADDY_ACME_EMAIL=" + acmeEmail
		case nekoPassword != "" && strings.HasPrefix(line, "NEKO_PASSWORD="):
			lines[i] = "NEKO_PASSWORD=" + nekoPassword
		case allowedUser != "" && strings.HasPrefix(line, "# CYFR_ALLOWED_USER="):
			lines[i] = "CYFR_ALLOWED_USER=" + allowedUser
		}
	}
	return strings.Join(lines, "\n")
}

var upCmd = &cobra.Command{
	Use:     "up",
	Short:   "Start the CYFR stack (cyfr + web + caddy + neko + mcp-bridge)",
	GroupID: "server",
	Long: `Start the CYFR stack with Docker Compose in detached mode. Requires a docker-compose.yml in the current directory (run 'cyfr init' first).

By default this brings up everything: cyfr (API + Prism), web (A.Q.U.A. PWA), caddy (TLS + reverse proxy), neko (the remote browser at /browse), and mcp-bridge (HTTP wrappers around stdio MCP servers, e.g. chrome-devtools-mcp). Use --no-browser to skip neko + mcp-bridge, or --no-mcp-bridge to keep neko and skip just the bridge.

Note for the remote browser: open the WebRTC media ports on your firewall (default ${NEKO_EPR:-59000-59100}/udp + ${NEKO_TCPMUX:-59999}/tcp) and set NEKO_NAT1TO1 to your VPS public IP if CYFR_HOST doesn't resolve to it.`,
	Example: `  cyfr up
  cyfr up --no-browser
  cyfr up --no-mcp-bridge`,
	Run: func(cmd *cobra.Command, args []string) {
		noBrowser, _ := cmd.Flags().GetBool("no-browser")
		noMcpBridge, _ := cmd.Flags().GetBool("no-mcp-bridge")

		// Registry credentials are now stored server-side in the encrypted secrets table.
		// For containerized deployments that need registry auth at startup (before login),
		// set CYFR_REGISTRY_USERNAME and CYFR_REGISTRY_PASSWORD environment variables
		// in the .env file or docker-compose.yml.

		// Build the docker compose argv:
		//   default                   → docker compose --profile browser up -d
		//   --no-browser              → docker compose up -d
		//   --no-mcp-bridge           → docker compose --profile browser up -d cyfr web caddy neko
		//   --no-browser --no-mcp-bridge → same as --no-browser
		composeArgs := []string{"compose"}
		if !noBrowser {
			composeArgs = append(composeArgs, "--profile", "browser")
		}
		composeArgs = append(composeArgs, "up", "-d")
		if !noBrowser && noMcpBridge {
			composeArgs = append(composeArgs, "cyfr", "web", "caddy", "neko")
		}

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
			fmt.Println("  A.Q.U.A. PWA:    http(s)://<your CYFR_HOST>/   (via Caddy on :80/:443)")
			fmt.Println("  Prism dashboard: http://localhost:4001")
			if !noBrowser {
				fmt.Println("  Remote Browser:  http(s)://<your CYFR_HOST>/browse")
				fmt.Println("                   (sign in with NEKO_PASSWORD from .env;")
				fmt.Println("                   open the WebRTC ports on the host firewall if you haven't)")
			}
			fmt.Println("")
			fmt.Println("Optional next steps:")
			fmt.Println("  cyfr login      authenticate this CLI")
			fmt.Println("  cyfr register   scan & register the bundled components")
		} else {
			fmt.Fprintf(os.Stderr, "Warning: server did not become healthy within 30s. Check 'docker compose logs'.\n")
		}
	},
}

var downCmd = &cobra.Command{
	Use:     "down",
	Short:   "Stop the CYFR server container",
	GroupID: "server",
	Long:    "Stop the CYFR server and remove its containers via Docker Compose. Includes the browser-profile services (neko, mcp-bridge) so a stack started with `cyfr up` (which enables them by default) is fully torn down.",
	Example: "  cyfr down",
	Run: func(cmd *cobra.Command, args []string) {
		// Pass --profile browser so down considers the opt-in services too;
		// harmless if they aren't running.
		c := exec.Command("docker", "compose", "--profile", "browser", "down")
		c.Stdout = os.Stdout
		c.Stderr = os.Stderr
		if err := c.Run(); err != nil {
			output.Errorf("Failed to stop: %v", err)
		}

		fmt.Println("CYFR server stopped.")
	},
}
