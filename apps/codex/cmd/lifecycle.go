// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"bufio"
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"maps"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"sync"
	"syscall"

	"github.com/cyfr/codex/internal/config"
	"github.com/cyfr/codex/internal/reach"
	"github.com/cyfr/codex/internal/release"
	"github.com/cyfr/codex/internal/scaffold"
	"github.com/cyfr/codex/internal/version"
	"github.com/spf13/cobra"
	"gopkg.in/yaml.v3"
)

// scaffoldDownloadFailure decides what a failed scaffold download means
// for `cyfr init` of release rel. A release file that fails verification
// (release.ErrUnverified) stops init, since the scaffold carries the
// compose file naming the images `cyfr up` runs, and the scaffold refuses
// before extracting a byte. Any other failure is a transport failure: it
// warns on warn, and init continues with the files already present.
func scaffoldDownloadFailure(rel string, err error, warn io.Writer) error {
	if errors.Is(err, release.ErrUnverified) {
		return fmt.Errorf("the scaffold of release %s failed verification, so nothing was extracted: %w", rel, err)
	}
	fmt.Fprintf(warn, "Warning: failed to download scaffold files: %v (continuing anyway)\n", err)
	return nil
}

// generateSecretKey returns a 64-byte cryptographically random key, base64url-encoded.
func generateSecretKey() (string, error) {
	b := make([]byte, 64)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return base64.URLEncoding.EncodeToString(b), nil
}

// generateHexKey returns 32 cryptographically random bytes as 64
// hexadecimal digits: the one form of CYFR_LOCUS_BACKENDS_KEY,
// CYFR_LOCUS_RUNTIME_ROOT and CYFR_LOCUS_BUILDS_KEY that cyfr and each service accept.
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
	backendsKeyVar   = "CYFR_LOCUS_BACKENDS_KEY"
	workerRootVar    = "CYFR_LOCUS_RUNTIME_ROOT"
	serviceIDVar     = "LOCUS_RUNTIME_SERVICE_ID"
	serviceKeyVar    = "LOCUS_RUNTIME_KEY"
	buildsURLVar     = "CYFR_LOCUS_BUILDS_URL"
	buildsKeyVar     = "CYFR_LOCUS_BUILDS_KEY"
	corsOriginsVar   = "CYFR_CORS_ALLOWED_ORIGINS"

	// The locus-runtime service's id when .env names none: docker-compose.yml's
	// default for both LOCUS_RUNTIME_SERVICE_ID and the entry of CYFR_LOCUS_RUNTIME_WORKERS.
	defaultServiceID = "wrk_locus"
	// The compose builds service's listener (docker-compose.yml's
	// `locus-builds`, port 4100).
	defaultBuildsURL = "http://" + buildsProfile + ":4100"
)

// serviceIDPattern is the service id grammar Locus.Runtime.Credentials accepts.
var serviceIDPattern = regexp.MustCompile(`^wrk_[A-Za-z0-9_-]{1,64}$`)

// decodeHexKey is Prima.MacEnvelope.decode_root/1: exactly 64 hexadecimal
// digits, in either case, spelling 32 bytes.
func decodeHexKey(text string) ([]byte, bool) {
	if len(text) != 64 {
		return nil, false
	}
	b, err := hex.DecodeString(text)
	return b, err == nil
}

// workerKey is Prima.WorkerAuth.worker_key/2, the key of the worker service
// `serviceID`: HMAC-SHA256 keyed by the root over its label and the service
// id, one per line.
func workerKey(root []byte, serviceID string) []byte {
	mac := hmac.New(sha256.New, root)
	mac.Write([]byte("cyfr-locus/v1/runtime\n" + serviceID))
	return mac.Sum(nil)
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

// stackKeys answers the assignments that give a .env whose values are
// values the keys the stack needs and it lacks, and nothing else; the
// caller writes them through the engine's editor (reach.EditEnv). A key that is
// present is never rewritten; a malformed root or service id, and a
// service key that does not derive from the root beside it, are refused,
// since writing around them would leave cyfr and the locus-runtime
// service unable to authenticate each other. Each key reads as its last
// assignment, as compose, the engine and every read of the CLI read it,
// and the editor writes over that one.
//
// The runtime root and the locus-runtime service key are one pair: with neither, both
// are minted; with the root alone, the key is derived from it for
// LOCUS_RUNTIME_SERVICE_ID (wrk_locus when .env names none). The builds URL
// and key are one pair too, because cyfr refuses to boot with one and not
// the other: a URL gets a minted key and a key gets the compose service's
// URL. Builds are on when .env.example's URL is there; no URL and no key
// is builds turned off, whether the URL is assigned empty or absent (the
// reach head omits it when builds are off, and a switch removes its line),
// and is left so.
func stackKeys(values map[string]string) (map[string]string, []envChange, error) {
	add := map[string]string{}
	var changes []envChange
	set := func(key, value, how string) {
		add[key] = value
		changes = append(changes, envChange{key, how})
	}
	mint := func(key, how string, generate func() (string, error)) error {
		v, err := generate()
		if err != nil {
			return fmt.Errorf("generate %s: %w", key, err)
		}
		set(key, v, how)
		return nil
	}

	if values[secretKeyBaseVar] == "" {
		if err := mint(secretKeyBaseVar, "generated", generateSecretKey); err != nil {
			return nil, nil, err
		}
	}
	if values[backendsKeyVar] == "" {
		if err := mint(backendsKeyVar, "generated", generateHexKey); err != nil {
			return nil, nil, err
		}
	}

	serviceID := values[serviceIDVar]
	if serviceID == "" {
		serviceID = defaultServiceID
	} else if !serviceIDPattern.MatchString(serviceID) {
		return nil, nil, refuseEnv("%s in .env is %q, which is not `wrk_` followed by 1 to 64 letters, digits, `_` or `-`, so no key can be derived for it: fix the id (and the matching entry of CYFR_LOCUS_RUNTIME_WORKERS) and run cyfr init again.", serviceIDVar, serviceID)
	}
	rootText, serviceKeyText := values[workerRootVar], values[serviceKeyVar]
	root, rootOK := decodeHexKey(rootText)
	switch {
	case rootText != "" && !rootOK:
		return nil, nil, refuseEnv("%s in .env is not 64 hexadecimal digits, so no service key can be derived from it: replace it with `openssl rand -hex 32` and remove %s, or remove both, and run cyfr init again.", workerRootVar, serviceKeyVar)
	case rootText == "" && serviceKeyText != "":
		return nil, nil, refuseEnv("%s is set in .env but %s, the root it is derived from, is not: set %s to the root that key was derived from, or remove %s so cyfr init mints both.", serviceKeyVar, workerRootVar, workerRootVar, serviceKeyVar)
	case rootText == "":
		minted, err := generateHexKey()
		if err != nil {
			return nil, nil, fmt.Errorf("generate %s: %w", workerRootVar, err)
		}
		set(workerRootVar, minted, "generated")
		root, _ = decodeHexKey(minted)
		fallthrough
	case serviceKeyText == "":
		set(serviceKeyVar, hex.EncodeToString(workerKey(root, serviceID)), "derived for "+serviceID)
	default:
		key, keyOK := decodeHexKey(serviceKeyText)
		if !keyOK || !hmac.Equal(key, workerKey(root, serviceID)) {
			return nil, nil, refuseEnv("%s in .env is not the key %s derives for %s %s, so cyfr and the locus-runtime service could not authenticate each other: remove %s and run cyfr init again to derive it, or set %s to the root it was derived from.", serviceKeyVar, workerRootVar, serviceIDVar, serviceID, serviceKeyVar, workerRootVar)
		}
	}

	// The browser CORS allowlist: assigned, whatever it says stands, and
	// assigned empty it is the empty allowlist. Unassigned, the list the
	// application's own configuration sets stands, so init assigns the
	// empty allowlist itself — cyfr serves Prism, the API, /mcp and the
	// tinctures from its own origin, and behind the proxy of a tailnet or
	// public home they are still that one origin, so no browser client of
	// this stack is cross-origin. Never a wildcard.
	if _, assigned := values[corsOriginsVar]; !assigned {
		set(corsOriginsVar, "", "empty: no cross-origin browser client")
	}

	buildsURL, buildsKey := values[buildsURLVar], values[buildsKeyVar]
	switch {
	case buildsURL != "" && buildsKey != "":
	case buildsURL != "":
		if err := mint(buildsKeyVar, "generated", generateHexKey); err != nil {
			return nil, nil, err
		}
	case buildsKey != "":
		set(buildsURLVar, defaultBuildsURL, defaultBuildsURL)
	}

	return add, changes, nil
}

// ensureEnvFileKeys adds the stack keys the dotenv file at path lacks
// (stackKeys) through the engine's editor (reach.EditEnvFile), which keeps
// the file's mode and every other line, only when something was added. A
// refusal leaves the file as it was.
func ensureEnvFileKeys(path string) ([]envChange, error) {
	values, err := reach.ReadEnvValues(path)
	if err != nil {
		return nil, fmt.Errorf("read %s: %w", path, engineFailure(err))
	}
	add, changes, err := stackKeys(values)
	if err != nil || len(changes) == 0 {
		return nil, err
	}
	if err := reach.EditEnvFile(path, add, nil); err != nil {
		return nil, fmt.Errorf("write %s: %w", path, err)
	}
	return changes, nil
}

// newEnv is the .env init writes for a new home from the template at
// path, through the engine's editor (reach.EditEnv): the answer to init's
// email question (the operators' setting, or with no email the setup
// token), the stack's keys (stackKeys) and the local head's reach keys,
// every other line of the template kept. The template documents the
// email and the token on commented lines, which stay; their assignments
// are added at the end.
func newEnv(path, adminEmail, setupToken string) ([]byte, []envChange, reach.Derivation, error) {
	tmpl, err := os.ReadFile(path)
	if err != nil {
		return nil, nil, reach.Derivation{}, fmt.Errorf("Failed to read %s: %w", path, err)
	}
	values, err := reach.ReadEnvValues(path)
	if err != nil {
		return nil, nil, reach.Derivation{}, fmt.Errorf("Failed to read %s: %w", path, engineFailure(err))
	}
	set := map[string]string{}
	if adminEmail != "" {
		set[adminEmailVar] = adminEmail
	}
	if setupToken != "" {
		set[setupTokenVar] = setupToken
	}
	add, changes, err := stackKeys(values)
	if err != nil {
		return nil, nil, reach.Derivation{}, err
	}
	maps.Copy(set, add)
	maps.Copy(values, add)
	d, err := localHead(values)
	if err != nil {
		return nil, nil, reach.Derivation{}, err
	}
	maps.Copy(set, d.Assignments)
	text, err := reach.EditEnv(tmpl, set, d.Removals)
	if err != nil {
		return nil, nil, reach.Derivation{}, engineFailure(err)
	}
	return text, changes, d, nil
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

// forceRefetched names the deploy files `cyfr init --force` removes so the
// scaffold tarball lays them down again: docker-compose.yml, the Caddyfile
// and the keeper's seccomp profile beside them, which `cyfr update` also
// refreshes. On a dev build the tarball is a no-op, so nothing is removed
// that could not be replaced.
func forceRefetched(releaseBuild bool) []string {
	if !releaseBuild {
		return nil
	}
	return []string{"docker-compose.yml", "Caddyfile", scaffold.SeccompProfile}
}

// downloadScaffold lays the release's scaffold files down, keeping every
// file that exists; a variable so a test substitutes the download.
var downloadScaffold = scaffold.Download

// forceRemovalRefusal is init --force's refusal when files it re-fetches
// could not be removed (forceRemovalState).
func forceRemovalRefusal(unremoved, removed []string) error {
	return errors.New(forceRemovalState(unremoved, removed) + " Fix the cause and run 'cyfr init --force' again")
}

// forceRemovalState says what init --force's removals left on disk: the
// files it could not remove, kept as they were, and of the ones it
// removed, which are on disk again and which are missing because the
// download did not lay them down. Empty when it removed nothing and every
// removal held.
func forceRemovalState(unremoved, removed []string) string {
	var back, missing, parts []string
	for _, name := range removed {
		if fileExists(name) {
			back = append(back, name)
		} else {
			missing = append(missing, name)
		}
	}
	if len(unremoved) > 0 {
		parts = append(parts, fmt.Sprintf("cyfr init --force could not remove %s, so %s kept as %s and not fetched again.", joinNames(unremoved), plural(unremoved, "it is", "they are"), plural(unremoved, "it was", "they were")))
	}
	if len(back) > 0 {
		parts = append(parts, fmt.Sprintf("%s %s laid down again.", joinNames(back), plural(back, "was", "were")))
	}
	if len(missing) > 0 {
		parts = append(parts, fmt.Sprintf("%s %s removed and %s missing: the download did not lay %s down again.", joinNames(missing), plural(missing, "was", "were"), plural(missing, "is", "are"), plural(missing, "it", "them")))
	}
	return strings.Join(parts, " ")
}

// joinNames spells names as a list a person reads: "a", "a and b",
// "a, b and c".
func joinNames(names []string) string {
	if len(names) < 2 {
		return strings.Join(names, "")
	}
	return strings.Join(names[:len(names)-1], ", ") + " and " + names[len(names)-1]
}

// plural answers one for a single name and many for several.
func plural(names []string, one, many string) string {
	if len(names) == 1 {
		return one
	}
	return many
}

// refuseUndeclaredRestore refuses a start while .env bars a restore that
// has not been declared.
func refuseUndeclaredRestore() error {
	if snapshot, barred := restoreBarred(".env"); barred {
		return fmt.Errorf("A cyfr restore of %s has not been declared (%s is set in .env), so the stack must not start: the restored database would keep every credential the backup carried. Run 'cyfr restore %s' again, which puts every part back from the start and declares it", snapshot, restoreBarrier, snapshot)
	}
	return nil
}

func init() {
	initCmd.Flags().Bool("force", false, "Re-fetch docker-compose.yml, Caddyfile and keeper.seccomp.json and regenerate cyfr.yaml even if they already exist (never replaces .env or .env.example)")
	initCmd.Flags().String("reach", "", "How a new home is reached: local, tailnet or public (asked on a terminal; local otherwise)")
	addReachFlags(initCmd)
	initCmd.Flags().Bool("no-pull", false, "Do not pull the stack's images")
	rootCmd.AddCommand(initCmd)
	rootCmd.AddCommand(upCmd)
	rootCmd.AddCommand(downCmd)
}

var initCmd = &cobra.Command{
	Use:     "init",
	Short:   "Scaffold a CYFR project, choose how it is reached and mint the stack's keys into .env",
	GroupID: "server",
	Long: `Set up a CYFR project in the current directory so you can start the self-hosted stack with "cyfr up": cyfr (the one endpoint), locus-runtime (the runtime that runs components), locus-builds (the builds service), locus-backends (stdio MCP servers) and the proxy of the way the home is reached, tailscale for a tailnet home and caddy for a public one.

Downloads docker-compose.yml, Caddyfile, keeper.seccomp.json (the locus-runtime service's seccomp profile), .env.example, the services' own env examples and the bundled scaffold (configuration/component/tincture/integration guides, wit/ definitions, the aqua/ soul, roles and scrolls) for this CLI's version; generates cyfr.yaml, .gitignore, and the data/aqua directories; writes .env from .env.example; and pulls the images the stack starts (--no-pull skips the pulls).

How the home is reached is asked first: 1, your devices via Tailscale (the default); 2, a public domain via Caddy; 3, this computer only. Then your email, as the home's administrator. .env is written for this computer only, with every key; then a tailnet home joins your tailnet (the link it prints approves the machine, or --tailscale-auth-key-file joins it without one) and the stopped stack is switched to the chosen mode, as 'cyfr reach' switches it. A join that fails or is cancelled leaves the home reached from this computer only, and 'cyfr reach <mode>' changes it later. With --no-interactive nothing is asked: the home is local, unless --reach tailnet comes with --tailscale-auth-key-file, or --reach public with --domain (--acme-email optional). Given no email, init mints a setup token into .env (CYFR_SETUP_TOKEN) and 'cyfr setup link' prints the link that makes you the administrator from this machine.

.env gets the stack's keys: CYFR_SECRET_KEY_BASE, CYFR_LOCUS_BACKENDS_KEY, the runtime root CYFR_LOCUS_RUNTIME_ROOT with the LOCUS_RUNTIME_KEY derived from it for LOCUS_RUNTIME_SERVICE_ID (wrk_locus unless .env names another), and CYFR_LOCUS_BUILDS_URL=http://locus-builds:4100 with a minted CYFR_LOCUS_BUILDS_KEY, so builds are on. It also assigns CYFR_CORS_ALLOWED_ORIGINS the empty allowlist, since cyfr serves Prism, the API, /mcp and the tinctures from its own origin and no browser client of this stack is cross-origin; an allowlist .env assigns is the one that stands.

Re-running in an existing project is safe: docker-compose.yml, Caddyfile, cyfr.yaml and .env.example are kept if they already exist, and .env gains only the keys it lacks. A key already in .env is never rewritten, and neither is how the home is reached, which 'cyfr reach' changes; a .env that does not say how its home is reached (no CYFR_REACH) is refused, and nothing is written. A service key without the root it derives from, or one that does not derive from the root beside it, is refused with a sentence naming the fix, and nothing is written. No builds URL and no builds key is builds turned off, and stays off. Use --force to re-fetch docker-compose.yml, Caddyfile and keeper.seccomp.json and regenerate cyfr.yaml.`,
	Example: `  cyfr init
  cyfr init --no-interactive --reach public --domain cyfr.example.com
  cyfr init --force
  cyfr up`,
	RunE: func(cmd *cobra.Command, args []string) error {
		ctx := cmd.Context()
		if ctx == nil {
			ctx = context.Background()
		}
		o := initOptions{reachOptions: reachFlags(cmd)}
		o.force, _ = cmd.Flags().GetBool("force")
		o.noPull, _ = cmd.Flags().GetBool("no-pull")
		o.mode, _ = cmd.Flags().GetString("reach")
		return runInit(ctx, o, cmd.OutOrStdout(), cmd.ErrOrStderr())
	},
}

// initOptions are cyfr init's flags; mode is --reach, empty when it is not
// given.
type initOptions struct {
	reachOptions
	force, noPull bool
	mode          string
}

// reachChoice is the mode init applies to a new home, with its inputs.
type reachChoice struct {
	reachOptions
	mode string
}

// runInit is `cyfr init` in the working directory.
func runInit(ctx context.Context, o initOptions, out, errOut io.Writer) error {
	releaseBuild := version.Version != "dev" && version.Version != ""

	// What init cannot complete is refused before anything is written: a
	// .env that does not say how its home is reached, whose cure is
	// `cyfr reach <mode>`, and reach flags that make no home.
	envExisted := fileExists(".env")
	if envExisted {
		if err := refuseExistingReach(".env", o); err != nil {
			return err
		}
	}
	if err := checkInitReach(o); err != nil {
		return err
	}
	key, err := readAuthKey(o.keyFile)
	if err != nil {
		return err
	}

	// An existing .env gains the keys it lacks before anything else
	// happens, so a .env init refuses leaves the whole project as it was.
	var envChanges []envChange
	if envExisted {
		changes, err := ensureEnvFileKeys(".env")
		if err != nil {
			return err
		}
		envChanges = changes
	}

	// On --force, drop the tarball's deploy files so scaffold.Download
	// re-extracts them, and regenerate cyfr.yaml. .env / .env.example are
	// deliberately never removed. A file that cannot be removed would be
	// kept as it is by the download, which skips an existing file, so
	// init refuses after the download, naming what is on disk then.
	var removed, unremoved []string
	if o.force {
		for _, name := range append(forceRefetched(releaseBuild), "cyfr.yaml") {
			switch err := os.Remove(name); {
			case err == nil:
				removed = append(removed, name)
			case !errors.Is(err, fs.ErrNotExist):
				unremoved = append(unremoved, fmt.Sprintf("%s (%v)", name, err))
			}
		}
	}

	// Download scaffold files: guides, wit/, aqua/, and the deploy
	// files (docker-compose.yml, Caddyfile, .env.example and the
	// services' env examples). Idempotent — existing files kept. No-op
	// for dev builds (version.Version=="dev"/""). A download that fails
	// warns and init goes on; a release that fails verification stops
	// it (scaffoldDownloadFailure).
	if err := downloadScaffold(version.Version); err != nil {
		if stop := scaffoldDownloadFailure(version.Version, err, errOut); stop != nil {
			// What --force removed is named here too: the refusal
			// extracts nothing, so it is missing until init runs again.
			if state := forceRemovalState(unremoved, removed); state != "" {
				return fmt.Errorf("%w.\n%s Fix the cause and run 'cyfr init --force' again", stop, state)
			}
			return stop
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
			return fmt.Errorf("Failed to write cyfr.yaml: %w", err)
		}
		configCreated = true
	}
	if len(unremoved) > 0 {
		return forceRemovalRefusal(unremoved, removed)
	}

	// Generate .env from the .env.example template laid down by the
	// scaffold, for this computer only, with the stack's keys minted into
	// it. If .env.example isn't present — a dev build, where the scaffold
	// download is a no-op — skip it; the dev-build notice below tells the
	// user where to get it.
	envCreated := false
	tokenMinted := false
	sel := existingSelection(".env")
	choice := reachChoice{mode: reach.ModeLocal}
	var head reach.Head
	if fileExists(".env.example") && !envExisted {
		r := bufio.NewReader(askInput)
		interactive := askTerminal()
		choice = chooseReach(o, interactive, r, out)
		adminEmail := ""
		if interactive {
			fmt.Fprintln(out, "CYFR authorizes by membership: your email makes you this home's administrator.")
			adminEmail = ask(r, out, "Your email (blank: set the administrator up from this machine with `cyfr setup link`)", "")
		}
		// No operator email: the first-run setup claims the home through
		// the link `cyfr setup link` prints, whose capability this is.
		token := ""
		if adminEmail == "" {
			if token, err = generateHexKey(); err != nil {
				return fmt.Errorf("generate %s: %w", setupTokenVar, err)
			}
			tokenMinted = true
		}
		text, changes, d, err := newEnv(".env.example", adminEmail, token)
		if err != nil {
			return err
		}
		if err := writeFileAtomic(".env", text, 0600); err != nil {
			return fmt.Errorf("Failed to write .env: %w", err)
		}
		envCreated = true
		envChanges = changes
		head = d.Head
		sel = selection{profiles: head.Profiles, port: head.Port}
	}

	// Generate .gitignore if it doesn't already exist (idempotent), before
	// the engine makes .cyfr/.
	gitignoreCreated := false
	if _, err := os.Stat(".gitignore"); os.IsNotExist(err) {
		if err := os.WriteFile(".gitignore", []byte(projectGitignore), 0644); err != nil {
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

	// The mode the home was asked for, applied as a switch of its stopped
	// stack; a refusal or a join that ends without the machine leaves it
	// local, and init reports that last.
	var reachErr error
	switch {
	case envCreated && choice.mode != reach.ModeLocal:
		applied, err := applyInitReach(ctx, choice, key, o.hostname != "" || o.keyFile != "", out)
		local := startedLocally{}
		switch {
		case errors.As(err, &local):
			head, reachErr = applied, err
			sel = selection{profiles: head.Profiles, port: head.Port}
		case err != nil:
			reachErr = fmt.Errorf("%w\nThis home is set up to be reached from this computer only; `cyfr reach %s` changes that", err, choice.mode)
		default:
			head = applied
			sel = selection{profiles: head.Profiles, port: head.Port}
		}
	case !envCreated && !envExisted && o.mode != "":
		reachErr = fmt.Errorf("--reach %s was not applied: there is no .env.example to write .env from", o.mode)
	}

	// Warm-pull the images docker-compose.yml starts with the head's
	// profiles (cyfr, and cyfr-locus for locus-runtime and locus-backends,
	// the same image serving locus-builds with builds on, and the proxy
	// of a tailnet or public home). A release's compose names each as
	// <repository>:<version>@<digest>, and `docker pull` of such a
	// reference pulls by the digest, so the warm pull fetches exactly the
	// images the verified scaffold names. Falls back to the published cyfr
	// image on a dev build (no compose). The pulls run outside the lock
	// and change nothing of the stack, so they are no call of the engine.
	if !o.noPull {
		images := imagesFromCompose("docker-compose.yml", sel.profiles)
		if len(images) == 0 {
			images = []string{"ghcr.io/cyfrworks/cyfr:latest"}
		}
		for _, img := range images {
			fmt.Fprintf(out, "Pulling %s ...\n", img)
			pull := exec.Command("docker", "pull", img)
			pull.Stdout = out
			pull.Stderr = errOut
			if err := pull.Run(); err != nil {
				fmt.Fprintf(errOut, "Warning: failed to pull %s: %v (continuing anyway)\n", img, err)
			}
		}
	}

	// Add local context: the loopback listener the CLI talks to.
	cfg, err := config.Load()
	if err != nil {
		cfg = &config.Config{
			CurrentContext: "local",
			Contexts:       map[string]*config.Context{},
		}
	}
	cfg.Contexts["local"] = &config.Context{URL: "http://127.0.0.1:" + strconv.Itoa(sel.port)}
	cfg.CurrentContext = "local"
	if err := cfg.Save(); err != nil {
		fmt.Fprintf(errOut, "warning: could not save CLI config: %v\n", err)
	}

	fmt.Fprintln(out, "CYFR project initialized.")
	if releaseBuild {
		if composeExists {
			fmt.Fprintln(out, "  docker-compose.yml ready (cyfr, locus-runtime, locus-builds, locus-backends; tailscale for a tailnet home, caddy for a public one)")
		}
		if caddyfileExists {
			fmt.Fprintln(out, "  Caddyfile ready")
		}
		fmt.Fprintf(out, "  %s downloaded\n", strings.Join(scaffold.Guides, " / "))
		fmt.Fprintln(out, "  wit/ interface definitions downloaded")
		fmt.Fprintln(out, "  aqua/ soul, roles and scrolls downloaded")
	}
	if configCreated {
		fmt.Fprintln(out, "  cyfr.yaml created")
	} else {
		fmt.Fprintln(out, "  cyfr.yaml already exists (skipped).")
	}
	switch {
	case envCreated:
		fmt.Fprintf(out, "  .env created from .env.example with %s — do not commit\n", describeChanges(envChanges))
	case len(envChanges) > 0:
		fmt.Fprintf(out, "  .env: added %s; nothing else changed\n", describeChanges(envChanges))
	case envExisted:
		fmt.Fprintln(out, "  .env already has every key the stack needs (unchanged).")
	}
	if slices.Contains(sel.profiles, buildsProfile) {
		fmt.Fprintln(out, "  builds are on: `cyfr up` starts locus-builds (README.md, \"Builds\", says how to turn them off)")
	}
	if gitignoreCreated {
		fmt.Fprintln(out, "  .gitignore created")
	} else {
		fmt.Fprintln(out, "  .gitignore already exists (skipped).")
	}
	fmt.Fprintln(out, "  data/, aqua/ created")
	if envCreated {
		fmt.Fprintln(out, "  This home is reached as:")
		for _, line := range reach.Describe(head).Sentences() {
			fmt.Fprintln(out, "    "+line)
		}
	}

	if !releaseBuild {
		fmt.Fprintln(out, "")
		fmt.Fprintln(out, "⚠  dev build — docker-compose.yml, Caddyfile, .env.example and the bundled")
		fmt.Fprintln(out, "   scaffold (guides, wit/, aqua/) are only fetched for released")
		fmt.Fprintln(out, "   versions. Run the server from source with `mix phx.server`, or copy those")
		fmt.Fprintln(out, "   files from a repo checkout.")
	}
	if tokenMinted {
		fmt.Fprintln(out, "")
		fmt.Fprintln(out, "No email was given, so .env holds a setup token (CYFR_SETUP_TOKEN) and no administrator yet.")
		fmt.Fprintln(out, "  After `cyfr up`, run `cyfr setup link` and open the link it prints on this machine to become this home's administrator.")
	}
	fmt.Fprintln(out, "")
	if composeExists {
		fmt.Fprintln(out, "Next: run 'cyfr up' to start the stack.")
	} else {
		fmt.Fprintln(out, "Next: get docker-compose.yml + Caddyfile (a released CLI or a repo checkout), then 'cyfr up'.")
	}
	if envCreated {
		fmt.Fprintln(out, "  Prism:           "+reach.Describe(head).Address+"/")
	} else {
		fmt.Fprintln(out, "  `cyfr reach status` shows how this home is reached.")
	}
	return reachErr
}

// refuseExistingReach refuses an existing .env init does not complete: one
// naming a COMPOSE_* setting, which every command that runs compose
// refuses (compose_env_refused), one without CYFR_REACH, with
// reach_missing's sentence, and reach flags, since init chooses how a new
// home is reached and `cyfr reach` changes an existing one's. A --reach
// naming the mode .env holds is no change and passes.
func refuseExistingReach(path string, o initOptions) error {
	var r *reach.Refusal
	if err := reach.CheckEnvFile(path); errors.As(err, &r) && r.Code == "compose_env_refused" {
		return refusalError{r}
	}
	values, err := reach.ReadEnvValues(path)
	if err != nil {
		return fmt.Errorf("read %s: %w", path, engineFailure(err))
	}
	current := values["CYFR_REACH"]
	if current == "" {
		return refusalError{reach.Refuse("reach_missing", nil)}
	}
	if (o.mode != "" && o.mode != current) || o.domain != "" || o.acmeEmail != "" || o.keyFile != "" || o.hostname != "" {
		return fmt.Errorf(".env says this home is reached as %s, and cyfr init leaves how an existing home is reached alone. Nothing was changed. Run `cyfr reach <mode>` to change it", current)
	}
	return nil
}

// checkInitReach refuses reach flags that make no home before anything is
// written: a mode outside the three, an option without --reach or for
// another mode, and a domain or email Derive refuses.
func checkInitReach(o initOptions) error {
	switch o.mode {
	case "":
		if o.domain != "" || o.acmeEmail != "" || o.keyFile != "" || o.hostname != "" {
			return errors.New("--domain, --acme-email, --tailscale-auth-key-file and --hostname say how a new home is reached only beside --reach: --reach public with a domain and an email, --reach tailnet with a key file and a name. Nothing was changed")
		}
		return nil
	case reach.ModeLocal, reach.ModeTailnet, reach.ModePublic:
	default:
		return fmt.Errorf("--reach takes local, tailnet or public; %q is none of them. Nothing was changed", o.mode)
	}
	if err := checkTailnetOptions(o.mode, o.reachOptions); err != nil {
		return err
	}
	if o.mode == reach.ModePublic && o.domain == "" {
		// Asked on a terminal; local otherwise (chooseReach).
		return nil
	}
	return checkTarget(reach.Target{Mode: o.mode, Domain: o.domain, ACMEEmail: o.acmeEmail})
}

// checkTarget refuses a target Derive refuses for its own inputs: an
// option outside its mode, a domain or an email that is not one. The port
// and the builds URL are the template's here, and the tailnet machine a
// stand-in, since only the target's own inputs are checked.
func checkTarget(t reach.Target) error {
	_, err := reach.Derive(t, reach.Current{Port: 4000}, &reach.Join{Name: "cyfr.tailnet.ts.net", NodeID: "nCheck"})
	return engineFailure(err)
}

// chooseReach decides the mode of a new home. On a terminal the reach
// question comes first, unless --reach answers it, then what the mode
// needs that its flags do not give: a tailnet machine's name, a public
// domain and its certificate email. Without one the home is local unless
// --reach tailnet comes with --tailscale-auth-key-file or --reach public
// with --domain.
func chooseReach(o initOptions, interactive bool, r *bufio.Reader, out io.Writer) reachChoice {
	c := reachChoice{reachOptions: o.reachOptions, mode: o.mode}
	if !interactive {
		switch {
		case c.mode == reach.ModeTailnet && c.keyFile == "":
			fmt.Fprintln(out, "--reach tailnet joins a tailnet with no one to approve the machine only with --tailscale-auth-key-file, so this home is reached from this computer only; `cyfr reach tailnet` joins it later.")
			c.mode = reach.ModeLocal
		case c.mode == reach.ModePublic && c.domain == "":
			fmt.Fprintln(out, "--reach public needs --domain, so this home is reached from this computer only; `cyfr reach public --domain <your domain>` changes that.")
			c.mode = reach.ModeLocal
		case c.mode == "":
			c.mode = reach.ModeLocal
		}
		return c
	}
	if c.mode == "" {
		fmt.Fprintln(out, "How will you reach this home?")
		fmt.Fprintln(out, "  1. My devices, via Tailscale (recommended)")
		fmt.Fprintln(out, "  2. A public domain, via Caddy")
		fmt.Fprintln(out, "  3. This computer only")
		for c.mode == "" {
			answer, more := askLine(r, out, "Choose 1, 2 or 3", "1")
			switch {
			case answer == "1":
				c.mode = reach.ModeTailnet
			case answer == "2":
				c.mode = reach.ModePublic
			case answer == "3":
				c.mode = reach.ModeLocal
			case !more:
				// The end of the input is no answer, least of all
				// consent to join a tailnet: the home is local, as
				// --no-interactive leaves it.
				fmt.Fprintln(out, "No answer was read, so this home is reached from this computer only; `cyfr reach tailnet` or `cyfr reach public --domain <your domain>` changes that.")
				c.mode = reach.ModeLocal
			default:
				fmt.Fprintln(out, "Answer 1, 2 or 3.")
			}
		}
	}
	switch c.mode {
	case reach.ModeTailnet:
		if c.hostname == "" {
			fmt.Fprintln(out, "This machine's name on your tailnet is part of the home's address, and certificate names are public: anyone can read it in the certificate logs.")
			c.hostname = ask(r, out, "Machine name", "cyfr")
		}
	case reach.ModePublic:
		for c.domain == "" {
			answer, more := askLine(r, out, "The domain this home is reached at (its DNS names this machine)", "")
			if err := checkTarget(reach.Target{Mode: c.mode, Domain: answer}); answer != "" && err != nil {
				fmt.Fprintln(out, err)
			} else {
				c.domain = answer
			}
			if c.domain == "" && !more {
				fmt.Fprintln(out, "No domain was given, so this home is reached from this computer only; `cyfr reach public --domain <your domain>` changes that.")
				c.mode = reach.ModeLocal
				return c
			}
		}
		for asking := c.acmeEmail == ""; asking; {
			answer, more := askLine(r, out, "Email for the certificate authority's notices (blank for none)", "")
			err := checkTarget(reach.Target{Mode: c.mode, Domain: c.domain, ACMEEmail: answer})
			if answer == "" || err == nil {
				c.acmeEmail = answer
				break
			}
			fmt.Fprintln(out, err)
			asking = more
		}
	}
	return c
}

// applyInitReach applies the mode chosen for a new home as an engine
// switch of its stopped stack, the tailnet joined first for tailnet, and
// answers the head it switched to. Any failure leaves the home as .env
// holds it, local.
func applyInitReach(ctx context.Context, c reachChoice, key []byte, optionsGiven bool, out io.Writer) (reach.Head, error) {
	id, err := newRequestID()
	if err != nil {
		return reach.Head{}, err
	}
	e, unlock, _, err := openLocked(ctx, "init", out)
	if err != nil {
		return reach.Head{}, err
	}
	defer unlock()
	target := reach.Target{Mode: c.mode, Domain: c.domain, ACMEEmail: c.acmeEmail}
	p, join, err := previewTarget(ctx, e, target, id, c.reachOptions, key, out, joinChoice{optionsGiven: optionsGiven})
	if err != nil {
		return reach.Head{}, err
	}
	rec, err := e.Switch(context.WithoutCancel(ctx), reach.SwitchRequest{
		ID: id, Target: target, JoinID: join.id, OldDigest: p.OldDigest, NewDigest: p.NewDigest,
		Content: requestContent(target, c.reachOptions, key),
	})
	head := p.New
	if rec.FinalHead != nil {
		head = *rec.FinalHead
	}
	// A switch that started the home on this machine alone made the
	// change; its head is .env's, and its failure says what is left.
	if err := answerFailure(rec, err); err != nil {
		if local := (startedLocally{}); errors.As(err, &local) {
			return head, err
		}
		return reach.Head{}, err
	}
	return head, nil
}

// localHead is the head a new home's .env starts from, reached from this
// computer only, its port and builds URL the ones values hold.
func localHead(values map[string]string) (reach.Derivation, error) {
	cur := reach.Current{Port: 4000}
	if text := values["CYFR_PORT"]; text != "" {
		port, err := strconv.Atoi(text)
		if err != nil {
			return reach.Derivation{}, refusalError{reach.Refuse("reach_setting_invalid", map[string]string{"key": "CYFR_PORT", "value": text})}
		}
		cur.Port = port
	}
	cur.BuildsURL = values[buildsURLVar]
	d, err := reach.Derive(reach.Target{Mode: reach.ModeLocal}, cur, nil)
	return d, engineFailure(err)
}

// selection is what init pulls and points the CLI at: the compose profiles
// a home's reach selects and its loopback listener's port.
type selection struct {
	profiles []string
	port     int
}

// existingSelection is the selection of the .env at path as it stands, the
// port 4000 where it names none that reads.
func existingSelection(path string) selection {
	sel := selection{port: 4000}
	values, err := reach.ReadEnvValues(path)
	if err != nil {
		return sel
	}
	if mode := values["CYFR_REACH"]; mode != "" {
		sel.profiles = reach.Profiles(mode, values[buildsURLVar])
	}
	if text := values["CYFR_PORT"]; text != "" {
		if port, err := strconv.Atoi(text); err == nil && port >= 1 && port <= 65535 {
			sel.port = port
		}
	}
	return sel
}

// projectGitignore is the .gitignore `cyfr init` writes into a project that
// has none: the runtime state under data/, the snapshots `cyfr update`
// takes under backups/ (each holds the keyring and the database), the
// reach engine's state under .cyfr/ and the environment files.
const projectGitignore = `# CYFR project — all runtime state (every athanor's data and
# components, the database, caches) lives under data/.
/data/
# Snapshots cyfr update takes: each holds the keyring and the database.
/backups/
# How the home is reached, as cyfr keeps it: the stack's lock, the change
# in flight, its receipts and the tailnet's serve configuration.
/.cyfr/
.env
.env.local
.env.*.local
# .env's replacement while it is written, which only a write the process
# died inside leaves: it holds .env's secrets.
..env.tmp-*
`

// fileExists reports whether path exists (file or directory).
func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

// imagesFromCompose returns every `image:` value referenced by the services
// of the compose file at path that start with the given profiles active: a
// service with no `profiles:`, or one naming any of them. Images are in the
// order the services first name them, each once (locus-builds and
// locus-backends run one image). A service with only `build:` is skipped.
// Returns nil if the file can't be read or parsed — callers should fall
// back to a sensible default.
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
		if img := mapValue(svc, "image"); img != nil && img.Value != "" && !slices.Contains(images, img.Value) {
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

// ask prompts on out and reads a line from r, answering def for an empty
// line and "" for the end of the input (askLine).
func ask(r *bufio.Reader, out io.Writer, question, def string) string {
	answer, _ := askLine(r, out, question, def)
	return answer
}

// askLine is ask, and whether the input may hold another line: false at
// its end, where asking again reads nothing. The default answers an empty
// line; the end of the input with nothing on its line is no answer, "".
func askLine(r *bufio.Reader, out io.Writer, question, def string) (string, bool) {
	if def != "" {
		fmt.Fprintf(out, "%s [%s]: ", question, def)
	} else {
		fmt.Fprintf(out, "%s: ", question)
	}
	line, err := r.ReadString('\n')
	line = strings.TrimSpace(line)
	switch {
	case line == "" && err != nil:
		return "", false
	case line == "":
		return def, true
	}
	return line, err == nil
}

var upCmd = &cobra.Command{
	Use:     "up",
	Short:   "Start the CYFR stack (cyfr, locus-runtime, locus-builds, locus-backends; the proxy of a tailnet or public home)",
	GroupID: "server",
	Long: `Start the CYFR stack with Docker Compose in detached mode, as .env says the home is reached. Requires a docker-compose.yml in the current directory (run 'cyfr init' first).

The stack is cyfr (the one endpoint: Prism, API, MCP, tinctures), locus-runtime (the runtime that runs components), locus-builds (the builds service that compiles components and tinctures), locus-backends (the backends service that runs the stdio/npx MCP servers an athanor adds on Prism's "MCP Servers" page, each backend under a uid and a memory bound of its own; cyfr tells it what to run), and the proxy of the way the home is reached: tailscale for a tailnet home (Tailscale Serve, HTTPS at the machine's tailnet name) and caddy for a public one (TLS on :80/:443).

cyfr, locus-runtime and locus-backends always start. locus-builds starts when CYFR_LOCUS_BUILDS_URL in .env names it (http://locus-builds:4100, which 'cyfr init' writes). CYFR_REACH in .env chooses the proxy: none for local, where Prism is at http://localhost:<CYFR_PORT>, tailscale for tailnet and caddy for public. cyfr up first takes the stack's lock and finishes a change an interrupted command left, then refuses a .env whose settings contradict how the home is reached, with the sentence the server would refuse it with, before anything starts. A tailnet home is served on the tailnet only once the machine's tailnet identity is the one .env names. A start that fails says why, with the server's own refusal from its log when it gave one, and exits 1.

Exit status 3: cyfr started, but on this machine only, because the tailnet machine is not ready to serve it (not the one .env names, not joined, or HTTPS off); Serve stays closed, and the message says what to do.`,
	Example: `  cyfr up`,
	RunE: func(cmd *cobra.Command, args []string) error {
		ctx := cmd.Context()
		if ctx == nil {
			ctx = context.Background()
		}
		return runUp(ctx, cmd.OutOrStdout())
	},
}

// runUp is `cyfr up` in the working directory.
func runUp(ctx context.Context, out io.Writer) error {
	// Registry auth is per-user: `cyfr login` (device flow) after
	// `cyfr context add`, and cyfr.run mints push tokens via the identity
	// probe. There are no static registry credentials to configure.
	if err := refuseUndeclaredRestore(); err != nil {
		return err
	}
	// The start holds the lock an update, a restore and a reach change
	// hold while they stop the stack, so none of them runs inside a start,
	// nor a start inside them. An interrupt is noted, not acted on: the
	// start runs to its end under the lock, and the lock goes with it.
	e, unlock, _, err := openLocked(ctx, "up", out)
	if err != nil {
		return err
	}
	interrupts := make(chan os.Signal, 1)
	signal.Notify(interrupts, os.Interrupt, syscall.SIGTERM, syscall.SIGHUP)
	release := sync.OnceFunc(func() {
		signal.Stop(interrupts)
		unlock()
	})
	defer release()
	// Asked again under the lock: a restore raises the bar only while
	// it holds the lock, so the answer now stands until the start ends.
	if err := refuseUndeclaredRestore(); err != nil {
		return err
	}
	// .env's own coherence first, the boot's sentence for what it
	// contradicts, then the stack as compose resolves it: both before
	// anything starts.
	head, err := e.Head()
	if err != nil {
		return engineFailure(err)
	}
	if err := e.CheckStack(ctx); err != nil {
		return engineFailure(err)
	}
	// A home started on this machine alone runs, and its sentence is the
	// whole answer; any other failed start may be the boot's refusal.
	startErr := answerFailure(e.Start(context.WithoutCancel(ctx), "up"))
	if local := (startedLocally{}); startErr != nil && !errors.As(startErr, &local) {
		startErr = withBootFatal(ctx, e, head, startErr)
	}
	release()
	select {
	case <-interrupts:
		return errors.New("cyfr up was interrupted; the start ran to its end and the lock is released. Run `cyfr reach status` to see what runs")
	default:
	}
	if startErr != nil {
		return startErr
	}
	fmt.Fprintln(out, "CYFR server started.")
	fmt.Fprintln(out, "  Prism:           "+reach.Describe(head).Address+"/")
	fmt.Fprintln(out, "")
	fmt.Fprintln(out, "Optional next steps:")
	fmt.Fprintln(out, "  cyfr login      authenticate this CLI")
	fmt.Fprintln(out, "  Then in Prism's \"MCP Servers\" page, click \"Add stdio server\"")
	fmt.Fprintln(out, "  to run stdio/npx MCP servers (filesystem, github, …) for AQUA.")
	return nil
}

// bootFatalMarker begins the line a refused boot prints, its sentence
// after it.
const bootFatalMarker = "[Cyfr] FATAL:"

// withBootFatal is a failed start with the refusal cyfr's boot last logged,
// read from the cyfr service's log under the lock: a setting only the
// release reads, such as a retired name, is refused there, and the start
// alone sees no more than an unhealthy container.
func withBootFatal(ctx context.Context, e stackEngine, head reach.Head, startErr error) error {
	ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), composeRunTimeout)
	defer cancel()
	args, err := e.ComposeArgs(ctx, head, "logs", "--no-color", "--no-log-prefix", "--tail", "200", "cyfr")
	if err != nil {
		return startErr
	}
	res, err := e.Docker().Run(ctx, reach.Call{Args: args, Deadline: composeRunTimeout})
	if err != nil {
		return startErr
	}
	fatal := ""
	for _, line := range strings.Split(string(res.Stdout)+"\n"+string(res.Stderr), "\n") {
		if i := strings.Index(line, bootFatalMarker); i >= 0 {
			fatal = strings.TrimSpace(line[i:])
		}
	}
	if fatal == "" {
		return startErr
	}
	return fmt.Errorf("%w\ncyfr refused to boot, and its log says why:\n  %s", startErr, e.Redactor().Text(fatal))
}

var downCmd = &cobra.Command{
	Use:     "down",
	Short:   "Stop the CYFR stack",
	GroupID: "server",
	Long:    "Stop the CYFR stack and remove its containers: every service of the project, the proxy of a tailnet or public home and locus-builds included, whatever .env selects now, checked stopped before it reports. It takes the stack's lock first, so it never runs inside another cyfr command's start or change, and finishes a change an interrupted command left.",
	Example: "  cyfr down",
	RunE: func(cmd *cobra.Command, args []string) error {
		ctx := cmd.Context()
		if ctx == nil {
			ctx = context.Background()
		}
		return runDown(ctx, cmd.OutOrStdout())
	},
}

// runDown is `cyfr down` in the working directory: every service of the
// project stopped, removed and checked stopped, under the lock.
func runDown(ctx context.Context, out io.Writer) error {
	e, unlock, _, err := openLocked(ctx, "down", out)
	if err != nil {
		return err
	}
	defer unlock()
	if err := answerFailure(e.Stop(context.WithoutCancel(ctx), "down", true)); err != nil {
		return err
	}
	fmt.Fprintln(out, "CYFR server stopped.")
	return nil
}

// restoreBarred reports whether the dotenv file at path sets
// restoreBarrier non-empty, as compose gives it to the cyfr service's
// entrypoint (its last assignment), and the snapshot it names.
func restoreBarred(path string) (string, bool) {
	values, err := reach.ReadEnvValues(path)
	if err != nil {
		return "", false
	}
	snapshot := values[restoreBarrier]
	return snapshot, snapshot != ""
}
