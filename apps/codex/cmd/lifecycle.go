// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"bufio"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
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

// generateHexKey returns 32 cryptographically random bytes as 64
// hexadecimal digits: the one form of CYFR_MCP_BRIDGE_KEY, CYFR_WORKER_KEY
// and CYFR_LOCUS_BUILDS_KEY that cyfr and each service accept.
func generateHexKey() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

// The stack's keys and the settings they pair with, as .env names them.
const (
	secretKeyBaseVar = "CYFR_SECRET_KEY_BASE"
	bridgeKeyVar     = "CYFR_MCP_BRIDGE_KEY"
	workerRootVar    = "CYFR_WORKER_KEY"
	serviceIDVar     = "OPUS_SERVICE_ID"
	serviceKeyVar    = "OPUS_SERVICE_KEY"
	buildsURLVar     = "CYFR_LOCUS_BUILDS_URL"
	buildsKeyVar     = "CYFR_LOCUS_BUILDS_KEY"

	// The opus service's id when .env names none: docker-compose.yml's
	// default for both OPUS_SERVICE_ID and the entry of CYFR_WORKERS.
	defaultServiceID = "wrk_opus"
	// The compose builds service's listener (docker-compose.yml's
	// `locus-builds`, port 4100).
	defaultBuildsURL = "http://" + buildsProfile + ":4100"
)

// stackVars are the .env settings cyfr init mints or reads to mint. Each is
// read from exactly one assignment, so what init reads is what compose and
// cyfr read.
var stackVars = []string{
	secretKeyBaseVar, bridgeKeyVar, workerRootVar, serviceIDVar, serviceKeyVar, buildsURLVar, buildsKeyVar,
}

// serviceIDPattern is the service id grammar Opus.Credentials accepts.
var serviceIDPattern = regexp.MustCompile(`^wrk_[A-Za-z0-9_-]{1,64}$`)

// decodeHexKey is Cyfr.MacEnvelope.decode_root/1: exactly 64 hexadecimal
// digits, in either case, spelling 32 bytes.
func decodeHexKey(text string) ([]byte, bool) {
	if len(text) != 64 {
		return nil, false
	}
	b, err := hex.DecodeString(text)
	return b, err == nil
}

// workerKey is Cyfr.WorkerAuth.worker_key/2, the key of the worker service
// `serviceID`: HMAC-SHA256 keyed by the root over its label and the service
// id, one per line.
func workerKey(root []byte, serviceID string) []byte {
	mac := hmac.New(sha256.New, root)
	mac.Write([]byte("cyfr-worker/v1/worker\n" + serviceID))
	return mac.Sum(nil)
}

// envFile is a dotenv file held as its lines, so a key init adds lands on
// the line that documents it and every other line is kept byte for byte.
type envFile struct {
	lines []string
}

func parseEnvFile(text string) *envFile {
	return &envFile{lines: strings.Split(text, "\n")}
}

func (f *envFile) String() string {
	return strings.Join(f.lines, "\n")
}

// assignments returns the indexes of the uncommented `key=` lines.
func (f *envFile) assignments(key string) []int {
	var found []int
	for i, line := range f.lines {
		if strings.HasPrefix(strings.TrimLeft(line, " \t"), key+"=") {
			found = append(found, i)
		}
	}
	return found
}

// value returns key's value as compose's dotenv reader takes it: trimmed,
// unquoted, an unquoted value ending at an inline ` #` comment. assigned
// reports whether an uncommented assignment exists, even an empty one.
func (f *envFile) value(key string) (value string, assigned bool) {
	lines := f.assignments(key)
	if len(lines) == 0 {
		return "", false
	}
	raw := strings.TrimSpace(strings.SplitN(strings.TrimLeft(f.lines[lines[0]], " \t"), "=", 2)[1])
	if len(raw) >= 2 && (raw[0] == '"' || raw[0] == '\'') {
		if end := strings.IndexByte(raw[1:], raw[0]); end >= 0 {
			return raw[1 : end+1], true
		}
	}
	if i := strings.Index(raw, " #"); i >= 0 {
		raw = raw[:i]
	}
	return strings.TrimSpace(raw), true
}

// set writes `key=value` on key's assignment line, else on its first
// commented example line (`# key=…`), else on a line appended at the end.
func (f *envFile) set(key, value string) {
	line := key + "=" + value
	if found := f.assignments(key); len(found) > 0 {
		f.lines[found[0]] = line
		return
	}
	for i, l := range f.lines {
		if rest, ok := strings.CutPrefix(strings.TrimLeft(l, " \t"), "#"); ok &&
			strings.HasPrefix(strings.TrimLeft(rest, " \t"), key+"=") {
			f.lines[i] = line
			return
		}
	}
	if n := len(f.lines); n > 0 && f.lines[n-1] == "" {
		f.lines = append(f.lines[:n-1], line, "")
	} else {
		f.lines = append(f.lines, line, "")
	}
}

// envChange names a setting cyfr init wrote into .env, and how it came by
// its value. It never carries the value.
type envChange struct {
	key, how string
}

// refuseEnv is the error for a .env init will not complete: a sentence
// naming the mismatch and the fix. Nothing is written.
func refuseEnv(format string, args ...any) error {
	return fmt.Errorf(format+" .env is unchanged.", args...)
}

// ensureStackKeys adds to a dotenv text the keys the stack needs and it
// lacks, and nothing else. A key that is present is never rewritten; a
// setting assigned twice, a malformed root or service id, and a service key
// that does not derive from the root beside it are refused, since writing
// around them would leave cyfr and the opus service unable to
// authenticate each other.
//
// The worker root and the opus service key are one pair: with neither, both
// are minted; with the root alone, the key is derived from it for
// OPUS_SERVICE_ID (wrk_opus when .env names none). Builds are on by
// default, and the builds URL and key are one pair too, because cyfr
// refuses to boot with one and not the other: a URL gets a minted key, a
// key gets the compose service's URL, neither gets both. A URL assigned
// empty with no key is builds turned off, and is left so.
func ensureStackKeys(text string) (string, []envChange, error) {
	f := parseEnvFile(text)
	for _, key := range stackVars {
		if found := f.assignments(key); len(found) > 1 {
			return "", nil, refuseEnv("%s is assigned on %d lines of .env, and compose and cyfr read only one of them: keep one line and run cyfr init again.", key, len(found))
		}
	}

	var changes []envChange
	mint := func(key, how string, generate func() (string, error)) error {
		v, err := generate()
		if err != nil {
			return fmt.Errorf("generate %s: %w", key, err)
		}
		f.set(key, v)
		changes = append(changes, envChange{key, how})
		return nil
	}

	if v, _ := f.value(secretKeyBaseVar); v == "" {
		if err := mint(secretKeyBaseVar, "generated", generateSecretKey); err != nil {
			return "", nil, err
		}
	}
	if v, _ := f.value(bridgeKeyVar); v == "" {
		if err := mint(bridgeKeyVar, "generated", generateHexKey); err != nil {
			return "", nil, err
		}
	}

	serviceID, _ := f.value(serviceIDVar)
	if serviceID == "" {
		serviceID = defaultServiceID
	} else if !serviceIDPattern.MatchString(serviceID) {
		return "", nil, refuseEnv("%s in .env is %q, which is not `wrk_` followed by 1 to 64 letters, digits, `_` or `-`, so no key can be derived for it: fix the id (and the matching entry of CYFR_WORKERS) and run cyfr init again.", serviceIDVar, serviceID)
	}
	rootText, _ := f.value(workerRootVar)
	serviceKeyText, _ := f.value(serviceKeyVar)
	root, rootOK := decodeHexKey(rootText)
	switch {
	case rootText != "" && !rootOK:
		return "", nil, refuseEnv("%s in .env is not 64 hexadecimal digits, so no service key can be derived from it: replace it with `openssl rand -hex 32` and remove %s, or remove both, and run cyfr init again.", workerRootVar, serviceKeyVar)
	case rootText == "" && serviceKeyText != "":
		return "", nil, refuseEnv("%s is set in .env but %s, the root it is derived from, is not: set %s to the root that key was derived from, or remove %s so cyfr init mints both.", serviceKeyVar, workerRootVar, workerRootVar, serviceKeyVar)
	case rootText == "":
		minted, err := generateHexKey()
		if err != nil {
			return "", nil, fmt.Errorf("generate %s: %w", workerRootVar, err)
		}
		f.set(workerRootVar, minted)
		changes = append(changes, envChange{workerRootVar, "generated"})
		root, _ = decodeHexKey(minted)
		fallthrough
	case serviceKeyText == "":
		f.set(serviceKeyVar, hex.EncodeToString(workerKey(root, serviceID)))
		changes = append(changes, envChange{serviceKeyVar, "derived for " + serviceID})
	default:
		key, keyOK := decodeHexKey(serviceKeyText)
		if !keyOK || !hmac.Equal(key, workerKey(root, serviceID)) {
			return "", nil, refuseEnv("%s in .env is not the key %s derives for %s %s, so cyfr and the opus service could not authenticate each other: remove %s and run cyfr init again to derive it, or set %s to the root it was derived from.", serviceKeyVar, workerRootVar, serviceIDVar, serviceID, serviceKeyVar, workerRootVar)
		}
	}

	buildsURL, urlAssigned := f.value(buildsURLVar)
	buildsKey, _ := f.value(buildsKeyVar)
	switch {
	case buildsURL != "" && buildsKey != "":
	case buildsURL != "":
		if err := mint(buildsKeyVar, "generated", generateHexKey); err != nil {
			return "", nil, err
		}
	case buildsKey != "":
		f.set(buildsURLVar, defaultBuildsURL)
		changes = append(changes, envChange{buildsURLVar, defaultBuildsURL})
	case urlAssigned:
		// Assigned empty with no key: the operator turned builds off.
	default:
		f.set(buildsURLVar, defaultBuildsURL)
		changes = append(changes, envChange{buildsURLVar, defaultBuildsURL})
		if err := mint(buildsKeyVar, "generated", generateHexKey); err != nil {
			return "", nil, err
		}
	}

	return f.String(), changes, nil
}

// ensureEnvFileKeys adds the stack keys the dotenv file at path lacks
// (ensureStackKeys) and writes it back whole, keeping its mode, only when
// something was added. A refusal leaves the file as it was.
func ensureEnvFileKeys(path string) ([]envChange, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read %s: %w", path, err)
	}
	text, changes, err := ensureStackKeys(string(data))
	if err != nil || len(changes) == 0 {
		return nil, err
	}
	mode := os.FileMode(0600)
	if info, err := os.Stat(path); err == nil {
		mode = info.Mode().Perm()
	}
	if err := writeFileAtomic(path, []byte(text), mode); err != nil {
		return nil, err
	}
	return changes, nil
}

// writeFileAtomic replaces the file at path (through a symlink, the file it
// names) with data by renaming a complete temporary file over it, so a
// failed write never leaves a .env holding part of its keys.
func writeFileAtomic(path string, data []byte, mode os.FileMode) error {
	target := path
	if resolved, err := filepath.EvalSymlinks(path); err == nil {
		target = resolved
	}
	tmp, err := os.CreateTemp(filepath.Dir(target), "."+filepath.Base(target)+".tmp-*")
	if err != nil {
		return fmt.Errorf("write %s: %w", path, err)
	}
	defer os.Remove(tmp.Name())
	err = errors.Join(tmp.Chmod(mode), writeAll(tmp, data), tmp.Sync(), tmp.Close())
	if err == nil {
		err = os.Rename(tmp.Name(), target)
	}
	if err != nil {
		return fmt.Errorf("write %s: %w", path, err)
	}
	return nil
}

func writeAll(f *os.File, data []byte) error {
	_, err := f.Write(data)
	return err
}

// describeChanges renders the settings init wrote, without their values.
func describeChanges(changes []envChange) string {
	parts := make([]string, len(changes))
	for i, c := range changes {
		parts[i] = c.key + " (" + c.how + ")"
	}
	return strings.Join(parts, ", ")
}

func init() {
	initCmd.Flags().Bool("force", false, "Re-fetch docker-compose.yml + Caddyfile and regenerate cyfr.yaml even if they already exist (never replaces .env or .env.example)")
	rootCmd.AddCommand(initCmd)
	rootCmd.AddCommand(upCmd)
	rootCmd.AddCommand(downCmd)
}

var initCmd = &cobra.Command{
	Use:     "init",
	Short:   "Scaffold a CYFR project and mint the stack's keys into .env",
	GroupID: "server",
	Long: `Set up a CYFR project in the current directory so you can start the self-hosted stack with "cyfr up": cyfr (the one endpoint), opus (the execution worker), locus-builds (the builds service), mcp-bridge (stdio MCP servers) and, in TLS mode, caddy.

Downloads docker-compose.yml, Caddyfile, .env.example, the services' own env examples and the bundled scaffold (component/tincture/integration guides, wit/ definitions, the aqua/ soul, roles and scrolls) for this CLI's version; generates cyfr.yaml, .gitignore, and the data/aqua directories; writes .env from .env.example, prompting for the hostname, an allowed sign-in email, a TLS y/n choice, and (if TLS) a Let's Encrypt email; and pulls the images the stack starts. Run with --no-interactive to take the defaults silently.

.env gets the stack's keys: CYFR_SECRET_KEY_BASE, CYFR_MCP_BRIDGE_KEY, the worker root CYFR_WORKER_KEY with the OPUS_SERVICE_KEY derived from it for OPUS_SERVICE_ID (wrk_opus unless .env names another), and CYFR_LOCUS_BUILDS_URL=http://locus-builds:4100 with a minted CYFR_LOCUS_BUILDS_KEY, so builds are on.

Re-running in an existing project is safe: docker-compose.yml, Caddyfile, cyfr.yaml and .env.example are kept if they already exist, and .env gains only the keys it lacks. A key already in .env is never rewritten. A service key without the root it derives from, or one that does not derive from the root beside it, is refused with a sentence naming the fix, and nothing is written. A builds URL set empty with no key is builds turned off, and stays off. Use --force to re-fetch docker-compose.yml + Caddyfile and regenerate cyfr.yaml.`,
	Example: `  cyfr init
  cyfr init --force
  cyfr up`,
	RunE: func(cmd *cobra.Command, args []string) error {
		force, _ := cmd.Flags().GetBool("force")
		releaseBuild := version.Version != "dev" && version.Version != ""

		// An existing .env gains the keys it lacks before anything else
		// happens, so a .env init refuses leaves the whole project as it was.
		envExisted := fileExists(".env")
		var envChanges []envChange
		if envExisted {
			changes, err := ensureEnvFileKeys(".env")
			if err != nil {
				return err
			}
			envChanges = changes
		}

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
				return fmt.Errorf("Failed to write cyfr.yaml: %w", err)
			}
			configCreated = true
		}

		// Generate .env from the .env.example template laid down by the scaffold,
		// with the stack's keys minted into it. If .env.example isn't present —
		// a dev build, where the scaffold download is a no-op — skip it; the
		// dev-build notice below tells the user where to get it.
		envCreated := false
		adminEmailConfigured := false
		envExampleExists := fileExists(".env.example")
		if envExampleExists && !envExisted {
			tmpl, err := os.ReadFile(".env.example")
			if err != nil {
				return fmt.Errorf("Failed to read .env.example: %w", err)
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

			text, changes, err := ensureStackKeys(renderEnvFile(string(tmpl), host, adminEmail, acmeEmail, tls))
			if err != nil {
				return err
			}
			if err := writeFileAtomic(".env", []byte(text), 0600); err != nil {
				return fmt.Errorf("Failed to write .env: %w", err)
			}
			envCreated = true
			envChanges = changes
		}

		// Warm-pull the images docker-compose.yml starts with this project's
		// profiles, read from the .env just written (cyfr and opus, plus
		// locus-builds with builds on and caddy in TLS mode — mcp-bridge is
		// `build:`-only). Falls back to the published cyfr image on a dev
		// build (no compose).
		images := imagesFromCompose("docker-compose.yml", composeProfiles(".env"))
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
				return fmt.Errorf("Failed to write .gitignore: %w", err)
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
		if err := cfg.Save(); err != nil {
			fmt.Fprintf(os.Stderr, "warning: could not save CLI config: %v\n", err)
		}

		fmt.Println("CYFR project initialized.")
		if releaseBuild {
			if composeExists {
				fmt.Println("  docker-compose.yml ready (cyfr, opus, locus-builds, mcp-bridge; caddy via the `tls` profile)")
			}
			if caddyfileExists {
				fmt.Println("  Caddyfile ready")
			}
			fmt.Println("  component-guide.md / tincture-guide.md / integration-guide.md downloaded")
			fmt.Println("  wit/ interface definitions downloaded")
			fmt.Println("  aqua/ soul, roles and scrolls downloaded")
		}
		if configCreated {
			fmt.Println("  cyfr.yaml created")
		} else {
			fmt.Println("  cyfr.yaml already exists (skipped).")
		}
		switch {
		case envCreated:
			fmt.Printf("  .env created from .env.example with %s — do not commit\n", describeChanges(envChanges))
		case len(envChanges) > 0:
			fmt.Printf("  .env: added %s; nothing else changed\n", describeChanges(envChanges))
		case envExisted:
			fmt.Println("  .env already has every key the stack needs (unchanged).")
		}
		if slices.Contains(composeProfiles(".env"), buildsProfile) {
			fmt.Println("  builds are on: `cyfr up` starts locus-builds (README.md, \"Builds\", says how to turn them off)")
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

// imagesFromCompose returns every `image:` value referenced by the services
// of the compose file at path that start with the given profiles active: a
// service with no `profiles:`, or one naming any of them. Images are in the
// order the services appear. Build-only services (e.g. mcp-bridge, which has
// only `build:`) are skipped. Returns nil if the file can't be read or parsed
// — callers should fall back to a sensible default.
func imagesFromCompose(path string, profiles []string) []string {
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
		if svc.Kind != yaml.MappingNode || !startsWith(svc, profiles) {
			continue
		}
		if img := mapValue(svc, "image"); img != nil && img.Value != "" {
			images = append(images, img.Value)
		}
	}
	return images
}

// startsWith reports whether a compose service starts when the given
// profiles are active: it names no profile, or one of them.
func startsWith(svc *yaml.Node, profiles []string) bool {
	named := mapValue(svc, "profiles")
	if named == nil {
		return true
	}
	for _, p := range named.Content {
		if slices.Contains(profiles, p.Value) {
			return true
		}
	}
	return false
}

// buildsProfile is the compose profile, and the host, of the Locus builds
// service (docker-compose.yml's `locus-builds`).
const buildsProfile = "locus-builds"

// composeProfiles returns the Docker Compose profiles the project in the
// current directory runs with, read from the dotenv file at envPath: `tls`
// when CYFR_BEHIND_PROXY is true (Caddy fronts cyfr), and `locus-builds`
// when CYFR_LOCUS_BUILDS_URL names the compose builds service (host
// `locus-builds`). Every command that starts, stops or pulls the stack
// passes them.
func composeProfiles(envPath string) []string {
	var profiles []string
	if envFlagTrue(envPath, "CYFR_BEHIND_PROXY") {
		profiles = append(profiles, "tls")
	}
	if raw, ok := envValue(envPath, "CYFR_LOCUS_BUILDS_URL"); ok {
		if u, err := url.Parse(raw); err == nil && u.Hostname() == buildsProfile {
			profiles = append(profiles, buildsProfile)
		}
	}
	return profiles
}

// profileArgs renders profiles as `docker compose` arguments.
func profileArgs(profiles []string) []string {
	var args []string
	for _, p := range profiles {
		args = append(args, "--profile", p)
	}
	return args
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

// renderEnvFile fills in a .env.example template with the answers to init's
// prompts: sets CYFR_HOST, sets CADDY_ACME_EMAIL if non-empty, flips
// CYFR_BEHIND_PROXY based on the TLS choice, and (if adminEmail is
// non-empty) un-comments and sets CYFR_PLATFORM_ADMIN_EMAILS. Everything
// else is left as-is; the keys are ensureStackKeys'.
// TestRenderEnvFileShippedTemplate binds this key set, and the keys, to the
// real .env.example — a template edit that strands a key fails there, not
// on a user's first `cyfr up`.
func renderEnvFile(template, host, adminEmail, acmeEmail string, tls bool) string {
	behindProxy := "false"
	if tls {
		behindProxy = "true"
	}
	lines := strings.Split(template, "\n")
	for i, line := range lines {
		switch {
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
	Short:   "Start the CYFR stack (cyfr, opus, locus-builds, mcp-bridge; caddy in TLS mode)",
	GroupID: "server",
	Long: `Start the CYFR stack with Docker Compose in detached mode. Requires a docker-compose.yml in the current directory (run 'cyfr init' first).

The stack is five services: cyfr (the one endpoint: Prism, API, MCP, tinctures), opus (the execution worker that runs components), locus-builds (the builds service that compiles components and tinctures), mcp-bridge (runs the stdio/npx MCP servers an athanor adds on Prism's "MCP Servers" page, each backend under a uid of its own; cyfr tells it what to run) and caddy (TLS and reverse proxy).

cyfr, opus and mcp-bridge always start. locus-builds starts when CYFR_LOCUS_BUILDS_URL in .env names it (http://locus-builds:4100, which 'cyfr init' writes; --profile locus-builds). caddy starts when CYFR_BEHIND_PROXY=true in .env (--profile tls) and fronts cyfr on :80/:443; otherwise cyfr is reachable directly at http://localhost:4000.`,
	Example: `  cyfr up`,
	RunE: func(cmd *cobra.Command, args []string) error {
		// Registry auth is per-user: `cyfr login` (device flow) after
		// `cyfr context add`, and cyfr.run mints push tokens via the identity
		// probe. There are no static registry credentials to configure.

		// `cyfr init` writes CYFR_BEHIND_PROXY=true into .env on TLS-yes;
		// .env's settings select the caddy and locus-builds profiles here.
		profiles := composeProfiles(".env")
		tls := slices.Contains(profiles, "tls")
		composeArgs := append(append([]string{"compose"}, profileArgs(profiles)...), "up", "-d")

		c := exec.Command("docker", composeArgs...)
		c.Stdout = os.Stdout
		c.Stderr = os.Stderr
		if err := c.Run(); err != nil {
			return fmt.Errorf("Failed to start: %w", err)
		}
		fmt.Println("CYFR server started.")

		// Health check wait. Readiness, not liveness: /api/health answers 200
		// the moment the endpoint is up, long before the DB, cache and
		// registries are — the same distinction the Docker HEALTHCHECK draws.
		cfg, err := config.Load()
		if err != nil {
			cfg = config.DefaultForLocal()
		}
		healthURL := cfg.CurrentURL() + "/api/health/ready"

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
			fmt.Println("  Then in Prism's \"MCP Servers\" page, click \"Add stdio server\"")
			fmt.Println("  to run stdio/npx MCP servers (filesystem, github, …) for AQUA.")
		} else {
			fmt.Fprintf(os.Stderr, "Warning: server did not become healthy within 30s. Check 'docker compose logs'.\n")
		}
		return nil
	},
}

var downCmd = &cobra.Command{
	Use:     "down",
	Short:   "Stop the CYFR stack",
	GroupID: "server",
	Long:    "Stop the CYFR stack and remove its containers via Docker Compose: cyfr, opus, mcp-bridge, and the profile services locus-builds (--profile locus-builds) and caddy (--profile tls), so a stack started with `cyfr up` with either is fully torn down.",
	Example: "  cyfr down",
	RunE: func(cmd *cobra.Command, args []string) error {
		// Every profile, so down considers the opt-in services too; harmless
		// for one that isn't running.
		c := exec.Command("docker", "compose", "--profile", "tls", "--profile", buildsProfile, "down")
		c.Stdout = os.Stdout
		c.Stderr = os.Stderr
		if err := c.Run(); err != nil {
			return fmt.Errorf("Failed to stop: %w", err)
		}

		fmt.Println("CYFR server stopped.")
		return nil
	},
}

// envFlagTrue reports whether `key=` in the dotenv-style file `path` is a
// truthy value (`true`/`1`/`yes`, case-insensitive). Returns false if the
// file is unreadable or the key is absent.
func envFlagTrue(path, key string) bool {
	v, _ := envValue(path, key)
	v = strings.ToLower(v)
	return v == "true" || v == "1" || v == "yes"
}

// envValue returns the value of the first uncommented `key=` line in the
// dotenv-style file `path`, trimmed and unquoted, and whether one was found
// with a non-empty value.
func envValue(path, key string) (string, bool) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", false
	}
	prefix := key + "="
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, prefix) {
			v := strings.Trim(strings.TrimSpace(strings.TrimPrefix(line, prefix)), `"'`)
			return v, v != ""
		}
	}
	return "", false
}
