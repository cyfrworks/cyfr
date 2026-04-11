package cmd

import (
	"fmt"
	"os"
	"os/exec"
	"strings"

	"github.com/cyfr/codex/internal/config"
	"github.com/cyfr/codex/internal/output"
	"github.com/cyfr/codex/internal/prompt"
	"github.com/cyfr/codex/internal/scaffold"
	"github.com/spf13/cobra"
)

const remoteComposeTemplate = `services:
  cyfr:
    container_name: cyfr
    image: ghcr.io/cyfrworks/cyfr:latest
    volumes:
      - ./data:/app/data
      - ./components:/app/components
      - ./aqua:/app/aqua
    env_file:
      - .env
    networks:
      - cyfr-net
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:4000/api/health"]
      interval: 10s
      timeout: 3s
      start_period: 15s
      retries: 3

  caddy:
    image: caddy:2-alpine
    ports:
      - "80:80"
      - "443:443"
      - "443:443/udp"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    restart: unless-stopped
    networks:
      - cyfr-net
    depends_on:
      cyfr:
        condition: service_healthy

networks:
  cyfr-net:

volumes:
  caddy_data:
  caddy_config:
`

func collectDomain(cmd *cobra.Command) string {
	domain, _ := cmd.Flags().GetString("domain")

	// Strip protocol scheme if user included it
	domain = strings.TrimPrefix(domain, "https://")
	domain = strings.TrimPrefix(domain, "http://")
	domain = strings.TrimRight(domain, "/")

	if domain != "" {
		return domain
	}

	if prompt.IsInteractive(flagNoInteractive) {
		val, err := prompt.InputText("Domain name", "cyfr.example.com")
		if err != nil {
			if prompt.IsAborted(err) {
				os.Exit(130)
			}
			output.Errorf("Prompt failed: %v", err)
		}
		val = strings.TrimPrefix(val, "https://")
		val = strings.TrimPrefix(val, "http://")
		val = strings.TrimRight(val, "/")
		if val == "" {
			output.Error("Domain is required for remote init")
		}
		return val
	}

	output.Error("--domain is required for remote init (or run interactively)")
	return "" // unreachable
}

func runRemoteInit(cmd *cobra.Command) {
	force, _ := cmd.Flags().GetBool("force")
	domain := collectDomain(cmd)

	// Pull Docker images (non-fatal)
	fmt.Println("Pulling Docker images...")
	for _, img := range []string{"ghcr.io/cyfrworks/cyfr:latest", "caddy:2-alpine"} {
		pull := exec.Command("docker", "pull", img)
		pull.Stdout = os.Stdout
		pull.Stderr = os.Stderr
		if err := pull.Run(); err != nil {
			fmt.Fprintf(os.Stderr, "Warning: failed to pull %s: %v (continuing anyway)\n", img, err)
		}
	}

	// Download scaffold files (non-fatal)
	if err := scaffold.Download(Version); err != nil {
		fmt.Fprintf(os.Stderr, "Warning: failed to download scaffold files: %v (continuing anyway)\n", err)
	}

	// Generate Caddyfile
	caddyfileCreated := false
	caddyfileContent := fmt.Sprintf("%s {\n    reverse_proxy cyfr:4000\n}\n", domain)
	if _, err := os.Stat("Caddyfile"); os.IsNotExist(err) || force {
		if err := os.WriteFile("Caddyfile", []byte(caddyfileContent), 0644); err != nil {
			output.Errorf("Failed to write Caddyfile: %v", err)
		}
		caddyfileCreated = true
	}

	// Generate docker-compose.yml
	composeCreated := false
	if _, err := os.Stat("docker-compose.yml"); os.IsNotExist(err) || force {
		if err := os.WriteFile("docker-compose.yml", []byte(remoteComposeTemplate), 0644); err != nil {
			output.Errorf("Failed to write docker-compose.yml: %v", err)
		}
		composeCreated = true
	}

	// Generate cyfr.yaml
	cyfrConfig := fmt.Sprintf("name: my-cyfr-project\nport: 4000\nhost: %s\ndatabase_path: ./data/cyfr.db\n", domain)
	configCreated := false
	if _, err := os.Stat("cyfr.yaml"); os.IsNotExist(err) || force {
		if err := os.WriteFile("cyfr.yaml", []byte(cyfrConfig), 0644); err != nil {
			output.Errorf("Failed to write cyfr.yaml: %v", err)
		}
		configCreated = true
	}

	// Generate .env (never overwritten, even with --force)
	envCreated := false
	if _, err := os.Stat(".env"); os.IsNotExist(err) {
		secretKey, err := generateSecretKey()
		if err != nil {
			output.Errorf("Failed to generate secret key: %v", err)
		}
		envContent := fmt.Sprintf("CYFR_SECRET_KEY_BASE=%s\nCYFR_PORT=4000\nCYFR_HOST=%s\nCYFR_COMPONENTS_PATH=/app/components\nCYFR_GITHUB_CLIENT_ID=Ov23lib66tiIwXkgUpwm\n", secretKey, domain)
		if err := os.WriteFile(".env", []byte(envContent), 0600); err != nil {
			output.Errorf("Failed to write .env: %v", err)
		}
		envCreated = true
	}

	// Generate .gitignore (same as local)
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

	// Create directories (same as local)
	_ = os.MkdirAll("data", 0755)
	_ = os.MkdirAll("aqua", 0755)
	componentSubdirs := []string{
		"components/catalysts/local",
		"components/reagents/local",
		"components/formulas/local",
	}
	for _, dir := range componentSubdirs {
		_ = os.MkdirAll(dir, 0755)
	}

	// Add local context (same as local init — health checks use localhost)
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

	// Print summary
	fmt.Println("CYFR remote deployment initialized.")
	if caddyfileCreated {
		fmt.Printf("  Caddyfile created (domain: %s)\n", domain)
	} else {
		fmt.Println("  Caddyfile already exists (skipped).")
	}
	if composeCreated {
		fmt.Println("  docker-compose.yml created (with Caddy reverse proxy)")
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
		fmt.Println("  tincture-guide.md downloaded")
		fmt.Println("  integration-guide.md downloaded")
		fmt.Println("  wit/ interface definitions downloaded")
		fmt.Println("  components/ examples downloaded (claude, gemini, openai, list-models)")
		fmt.Println("  aqua/ orchestrator manifest + prompts downloaded")
	}
	fmt.Println("")
	fmt.Println("Next steps:")
	fmt.Printf("  1. Ensure DNS for %s points to this server\n", domain)
	fmt.Println("  2. Run 'cyfr up' to start (Caddy will auto-provision TLS)")
	fmt.Println("")
	fmt.Println("Connect from Porta:")
	fmt.Printf("  Set cyfrUrl to \"https://%s\" in ~/.cyfr/porta.json\n", domain)
}
