package cmd

import (
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
	"github.com/cyfr/codex/internal/scaffold"
	"github.com/spf13/cobra"
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
	initCmd.Flags().Bool("force", false, "Overwrite docker-compose.yml and cyfr.yaml even if they already exist")
	initCmd.Flags().Bool("remote", false, "Generate VPS-ready deployment with Caddy reverse proxy and automatic TLS")
	initCmd.Flags().String("domain", "", "Domain name for TLS certificate (used with --remote)")
	rootCmd.AddCommand(initCmd)
	rootCmd.AddCommand(upCmd)
	rootCmd.AddCommand(downCmd)
}

var initCmd = &cobra.Command{
	Use:     "init",
	Short:   "Scaffold a CYFR project in the current directory",
	GroupID: "server",
	Long: `Create a docker-compose.yml, cyfr.yaml, and data/components directories in the current directory so you can start a local CYFR server with "cyfr up".

Use --remote to generate a VPS-ready deployment with Caddy reverse proxy and automatic TLS.

Re-running in an existing project is safe: docker-compose.yml, cyfr.yaml, and .env are
skipped if they already exist. Use --force to overwrite docker-compose.yml and cyfr.yaml.`,
	Example: `  cyfr init
  cyfr init --force
  cyfr init --remote
  cyfr init --remote --domain cyfr.example.com
  cyfr up`,
	Run: func(cmd *cobra.Command, args []string) {
		remote, _ := cmd.Flags().GetBool("remote")
		if remote {
			runRemoteInit(cmd)
			return
		}

		force, _ := cmd.Flags().GetBool("force")

		// Pull Docker image (non-fatal)
		fmt.Println("Pulling CYFR server image...")
		pull := exec.Command("docker", "pull", "ghcr.io/cyfrworks/cyfr:latest")
		pull.Stdout = os.Stdout
		pull.Stderr = os.Stderr
		if err := pull.Run(); err != nil {
			fmt.Fprintf(os.Stderr, "Warning: failed to pull image: %v (continuing anyway)\n", err)
		}

		// Download scaffold files (non-fatal)
		if err := scaffold.Download(Version); err != nil {
			fmt.Fprintf(os.Stderr, "Warning: failed to download scaffold files: %v (continuing anyway)\n", err)
		}

		// Generate docker-compose.yml
		composeContent := `services:
  cyfr:
    container_name: cyfr
    image: ghcr.io/cyfrworks/cyfr:latest
    ports:
      - "4000:4000"
      - "4001:4001"
    volumes:
      - ./data:/app/data
      - ./components:/app/components
      - ./aqua:/app/aqua
    env_file:
      - .env
    extra_hosts:
      - "host.docker.internal:host-gateway"
`
		composeCreated := false
		if _, err := os.Stat("docker-compose.yml"); os.IsNotExist(err) || force {
			if err := os.WriteFile("docker-compose.yml", []byte(composeContent), 0644); err != nil {
				output.Errorf("Failed to write docker-compose.yml: %v", err)
			}
			composeCreated = true
		}

		// Generate cyfr.yaml with richer config
		cyfrConfig := `name: my-cyfr-project
port: 4000
host: localhost
database_path: ./data/cyfr.db
`
		configCreated := false
		if _, err := os.Stat("cyfr.yaml"); os.IsNotExist(err) || force {
			if err := os.WriteFile("cyfr.yaml", []byte(cyfrConfig), 0644); err != nil {
				output.Errorf("Failed to write cyfr.yaml: %v", err)
			}
			configCreated = true
		}

		// Generate .env if it doesn't already exist (idempotent)
		envCreated := false
		if _, err := os.Stat(".env"); os.IsNotExist(err) {
			secretKey, err := generateSecretKey()
			if err != nil {
				output.Errorf("Failed to generate secret key: %v", err)
			}
			envContent := fmt.Sprintf(`CYFR_SECRET_KEY_BASE=%s
CYFR_PORT=4000
CYFR_HOST=0.0.0.0
CYFR_COMPONENTS_PATH=/app/components
CYFR_GITHUB_CLIENT_ID=Ov23lib66tiIwXkgUpwm
`, secretKey)
			if err := os.WriteFile(".env", []byte(envContent), 0600); err != nil {
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
docker-compose.override.yml

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

		// Create directories
		_ = os.MkdirAll("data", 0755)

		// Ensure aqua/ exists so the bind mount in docker-compose.yml has a
		// source directory even in dev mode (Version=="dev") where the
		// scaffold tarball is a no-op. The container's entrypoint seeds the
		// directory from /app/aqua-defaults on first start if empty.
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
		if composeCreated {
			fmt.Println("  docker-compose.yml created")
		} else {
			fmt.Println("  docker-compose.yml already exists (skipped).")
		}
		if configCreated {
			fmt.Println("  cyfr.yaml created")
		} else {
			fmt.Println("  cyfr.yaml already exists (skipped).")
		}
		if envCreated {
			fmt.Println("  .env created (contains secret key — do not commit)")
		} else {
			fmt.Println("  .env already exists (skipped).")
			secretKey, err := generateSecretKey()
			if err != nil {
				output.Errorf("Failed to generate secret key: %v", err)
			}
			fmt.Println("  Here's a generated secret key you can use for CYFR_SECRET_KEY_BASE:")
			fmt.Println("")
			fmt.Printf("    CYFR_SECRET_KEY_BASE=%s\n", secretKey)
			fmt.Println("")
			fmt.Println("  Add or update this in your .env if needed.")
		}
		if gitignoreCreated {
			fmt.Println("  .gitignore created")
		} else {
			fmt.Println("  .gitignore already exists (skipped).")
		}
		fmt.Println("  data/ directory created")
		fmt.Println("  aqua/ directory created")
		fmt.Println("  components/catalysts/local/ created")
		fmt.Println("  components/reagents/local/ created")
		fmt.Println("  components/formulas/local/ created")
		if Version != "dev" && Version != "" {
			fmt.Println("  component-guide.md downloaded")
			fmt.Println("  integration-guide.md downloaded")
			fmt.Println("  wit/ interface definitions downloaded")
			fmt.Println("  components/ examples downloaded (claude, gemini, openai, list-models)")
			fmt.Println("  aqua/ orchestrator manifest + prompts downloaded")
		}
		fmt.Println("")
		fmt.Println("Next: run 'cyfr up' to start the server.")
		fmt.Println("  Dashboard will be available at http://localhost:4001")
	},
}

var upCmd = &cobra.Command{
	Use:     "up",
	Short:   "Start the CYFR server container",
	GroupID: "server",
	Long:    "Start the CYFR server using Docker Compose in detached mode. Requires a docker-compose.yml in the current directory (created by cyfr init).",
	Example: "  cyfr up",
	Run: func(cmd *cobra.Command, args []string) {
		// Registry credentials are now stored server-side in the encrypted secrets table.
		// For containerized deployments that need registry auth at startup (before login),
		// set CYFR_REGISTRY_USERNAME and CYFR_REGISTRY_PASSWORD environment variables
		// in the .env file or docker-compose.yml.

		c := exec.Command("docker", "compose", "up", "-d")
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
			fmt.Println("  Dashboard: http://localhost:4001")
		} else {
			fmt.Fprintf(os.Stderr, "Warning: server did not become healthy within 30s. Check 'docker compose logs'.\n")
		}
	},
}

var downCmd = &cobra.Command{
	Use:     "down",
	Short:   "Stop the CYFR server container",
	GroupID: "server",
	Long:    "Stop the CYFR server and remove its containers via Docker Compose.",
	Example: "  cyfr down",
	Run: func(cmd *cobra.Command, args []string) {
		c := exec.Command("docker", "compose", "down")
		c.Stdout = os.Stdout
		c.Stderr = os.Stderr
		if err := c.Run(); err != nil {
			output.Errorf("Failed to stop: %v", err)
		}

		// Clean up auto-generated override file
		if data, err := os.ReadFile("docker-compose.override.yml"); err == nil {
			if strings.HasPrefix(string(data), "# Auto-generated by cyfr up") {
				_ = os.Remove("docker-compose.override.yml")
			}
		}

		fmt.Println("CYFR server stopped.")
	},
}
