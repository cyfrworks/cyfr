package cmd

import (
	"crypto/rand"
	"encoding/base64"
	"fmt"
	"net/http"
	"os"
	"os/exec"
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
	rootCmd.AddCommand(initCmd)
	rootCmd.AddCommand(upCmd)
	rootCmd.AddCommand(downCmd)
}

var initCmd = &cobra.Command{
	Use:     "init",
	Short:   "Scaffold a CYFR project in the current directory",
	GroupID: "start",
	Long:    `Create a docker-compose.yml, cyfr.yaml, and data/components directories in the current directory so you can start a local CYFR server with "cyfr up".`,
	Example: `  cyfr init
  cyfr up`,
	Run: func(cmd *cobra.Command, args []string) {
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
    image: ghcr.io/cyfrworks/cyfr:latest
    ports:
      - "4000:4000"
    volumes:
      - ./data:/app/data
      - ./components:/app/components
    env_file:
      - .env
`
		if err := os.WriteFile("docker-compose.yml", []byte(composeContent), 0644); err != nil {
			output.Errorf("Failed to write docker-compose.yml: %v", err)
		}

		// Generate cyfr.yaml with richer config
		cyfrConfig := `name: my-cyfr-project
port: 4000
host: localhost
database_path: ./data/cyfr.db
`
		if err := os.WriteFile("cyfr.yaml", []byte(cyfrConfig), 0644); err != nil {
			output.Errorf("Failed to write cyfr.yaml: %v", err)
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
CYFR_DATABASE_PATH=/app/data/cyfr.db
CYFR_GITHUB_CLIENT_ID=Ov23lib66tiIwXkgUpwm
`, secretKey)
			if err := os.WriteFile(".env", []byte(envContent), 0600); err != nil {
				output.Errorf("Failed to write .env: %v", err)
			}
			envCreated = true
		}

		// Create directories
		_ = os.MkdirAll("data", 0755)

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
		cfg.Contexts["local"] = &config.Context{URL: "http://localhost:4000"}
		cfg.CurrentContext = "local"
		_ = cfg.Save()

		fmt.Println("CYFR project initialized.")
		fmt.Println("  docker-compose.yml created")
		fmt.Println("  cyfr.yaml created")
		if envCreated {
			fmt.Println("  .env created (contains secret key — do not commit)")
		} else {
			fmt.Println("  .env already exists (skipped)")
		}
		fmt.Println("  data/ directory created")
		fmt.Println("  components/catalysts/local/ created")
		fmt.Println("  components/reagents/local/ created")
		fmt.Println("  components/formulas/local/ created")
		if Version != "dev" && Version != "" {
			fmt.Println("  component-guide.md downloaded")
			fmt.Println("  integration-guide.md downloaded")
			fmt.Println("  wit/ interface definitions downloaded")
			fmt.Println("  components/ examples downloaded (claude, gemini, openai, list-models)")
		}
		fmt.Println("")
		fmt.Println("Next: run 'cyfr up' to start the server.")
	},
}

var upCmd = &cobra.Command{
	Use:     "up",
	Short:   "Start the CYFR server container",
	GroupID: "start",
	Long:    "Start the CYFR server using Docker Compose in detached mode. Requires a docker-compose.yml in the current directory (created by cyfr init).",
	Example: "  cyfr up",
	Run: func(cmd *cobra.Command, args []string) {
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
		} else {
			fmt.Fprintf(os.Stderr, "Warning: server did not become healthy within 30s. Check 'docker compose logs'.\n")
		}
	},
}

var downCmd = &cobra.Command{
	Use:     "down",
	Short:   "Stop the CYFR server container",
	GroupID: "start",
	Long:    "Stop the CYFR server and remove its containers via Docker Compose.",
	Example: "  cyfr down",
	Run: func(cmd *cobra.Command, args []string) {
		c := exec.Command("docker", "compose", "down")
		c.Stdout = os.Stdout
		c.Stderr = os.Stderr
		if err := c.Run(); err != nil {
			output.Errorf("Failed to stop: %v", err)
		}
		fmt.Println("CYFR server stopped.")
	},
}
