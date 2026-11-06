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
	"os/user"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"sync"
	"syscall"

	"github.com/cyfr/codex/internal/access"
	"github.com/cyfr/codex/internal/config"
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
// lowercase hexadecimal digits: the one form of CYFR_LOCUS_BACKENDS_KEY,
// CYFR_LOCUS_RUNTIME_ROOT and CYFR_LOCUS_BUILDS_KEY that cyfr and each service accept,
// and of CYFR_SETUP_TOKEN, which cyfr takes in lowercase alone.
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
	setupTokenVar    = "CYFR_SETUP_TOKEN"
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

// envChange names a setting cyfr init wrote into .env. It never carries
// the value.
type envChange struct {
	key string
}

// refuseEnv is the error for a .env init will not complete: a sentence
// naming the mismatch and the fix. Nothing is written.
func refuseEnv(format string, args ...any) error {
	return fmt.Errorf(format+" .env is unchanged.", args...)
}

// stackKeys answers the assignments that give a .env whose values are
// values the keys the stack needs and it lacks, and nothing else; the
// caller writes them through the engine's editor (access.EditEnv). A key that is
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
// access head omits it when builds are off, and a switch removes its line),
// and is left so.
func stackKeys(values map[string]string) (map[string]string, []envChange, error) {
	add := map[string]string{}
	var changes []envChange
	set := func(key, value string) {
		add[key] = value
		changes = append(changes, envChange{key})
	}
	mint := func(key string, generate func() (string, error)) error {
		v, err := generate()
		if err != nil {
			return fmt.Errorf("generate %s: %w", key, err)
		}
		set(key, v)
		return nil
	}

	if values[secretKeyBaseVar] == "" {
		if err := mint(secretKeyBaseVar, generateSecretKey); err != nil {
			return nil, nil, err
		}
	}
	if values[backendsKeyVar] == "" {
		if err := mint(backendsKeyVar, generateHexKey); err != nil {
			return nil, nil, err
		}
	}
	if values[setupTokenVar] == "" {
		if err := mint(setupTokenVar, generateHexKey); err != nil {
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
		set(workerRootVar, minted)
		root, _ = decodeHexKey(minted)
		fallthrough
	case serviceKeyText == "":
		set(serviceKeyVar, hex.EncodeToString(workerKey(root, serviceID)))
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
		set(corsOriginsVar, "")
	}

	buildsURL, buildsKey := values[buildsURLVar], values[buildsKeyVar]
	switch {
	case buildsURL != "" && buildsKey != "":
	case buildsURL != "":
		if err := mint(buildsKeyVar, generateHexKey); err != nil {
			return nil, nil, err
		}
	case buildsKey != "":
		set(buildsURLVar, defaultBuildsURL)
	}

	return add, changes, nil
}

// ensureEnvFileKeys adds the stack keys the dotenv file at path lacks
// (stackKeys) through the engine's editor (access.EditEnvFile), which keeps
// the file's mode and every other line, only when something was added. A
// refusal leaves the file as it was.
func ensureEnvFileKeys(path string) ([]envChange, error) {
	values, err := access.ReadEnvValues(path)
	if err != nil {
		return nil, fmt.Errorf("read %s: %w", path, engineFailure(err))
	}
	add, changes, err := stackKeys(values)
	if err != nil || len(changes) == 0 {
		return nil, err
	}
	if err := access.EditEnvFile(path, add, nil); err != nil {
		return nil, fmt.Errorf("write %s: %w", path, err)
	}
	return changes, nil
}

// newEnv is the .env init writes for a new home from the template at
// path, through the engine's editor (access.EditEnv): the stack's keys
// (stackKeys) and the local head's access settings, every other line of the
// template kept.
func newEnv(path string) ([]byte, []envChange, access.Derivation, error) {
	tmpl, err := os.ReadFile(path)
	if err != nil {
		return nil, nil, access.Derivation{}, fmt.Errorf("Failed to read %s: %w", path, err)
	}
	values, err := access.ReadEnvValues(path)
	if err != nil {
		return nil, nil, access.Derivation{}, fmt.Errorf("Failed to read %s: %w", path, engineFailure(err))
	}
	set := map[string]string{}
	add, changes, err := stackKeys(values)
	if err != nil {
		return nil, nil, access.Derivation{}, err
	}
	maps.Copy(set, add)
	maps.Copy(values, add)
	d, err := localHead(values)
	if err != nil {
		return nil, nil, access.Derivation{}, err
	}
	maps.Copy(set, d.Assignments)
	text, err := access.EditEnv(tmpl, set, d.Removals)
	if err != nil {
		return nil, nil, access.Derivation{}, engineFailure(err)
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

// describeChanges names the settings init wrote, without their values.
func describeChanges(changes []envChange) string {
	parts := make([]string, len(changes))
	for i, c := range changes {
		parts[i] = c.key
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
	initCmd.Flags().Bool("force", false, "Re-fetch docker-compose.yml, Caddyfile and keeper.seccomp.json even if they already exist (never replaces .env or .env.example)")
	initCmd.Flags().Bool("no-pull", false, "Do not pull the stack's images")
	rootCmd.AddCommand(initCmd)
	rootCmd.AddCommand(upCmd)
	rootCmd.AddCommand(downCmd)
}

var initCmd = &cobra.Command{
	Use:     "init",
	Short:   "Set up a new CYFR in this directory, at a terminal: its files, keys and images, ready for cyfr up",
	GroupID: "server",
	Long: `Set up a CYFR project in the current directory so you can start the self-hosted stack with "cyfr up": cyfr (the one endpoint), locus-runtime (the runtime that runs components), locus-builds (the builds service), locus-backends (stdio MCP servers) and the proxy of the way CYFR is reached, tailscale for tailnet access and caddy for public access.

Downloads docker-compose.yml, Caddyfile, keeper.seccomp.json (the locus-runtime service's seccomp profile), .env.example, the services' own env examples and the bundled scaffold (` + strings.Join(scaffold.Guides, ", ") + `, wit/ definitions, the aqua/ soul, roles and scrolls) for this CLI's version; generates .gitignore and the data/aqua directories; writes .env from .env.example; and pulls the images the stack starts (--no-pull skips the pulls).

On Ubuntu 26.04 LTS at a terminal, when this account cannot reach Docker, init first shows the commands that install what is missing (docker.io, docker-compose-v2 and apparmor, the running service and this account's membership of the docker group), asks, and runs them through one sudo; answered no, init installs nothing, writes nothing and exits 0. The rest of init then runs in a process that has the group, and 'cyfr up' gets the group the same way.

The CYFR init makes is reached from this machine, at http://localhost:<CYFR_PORT>. 'cyfr access tailnet' reaches it from your phone and laptop too, and 'cyfr access public --domain <your domain>' from the internet. On Ubuntu 26.04 LTS on amd64 at a terminal, on a machine with no desktop, init asks before it writes anything whether this machine's screen shows CYFR (1, the default) or keeps its login prompt (2); the first installs what 'cyfr screen on' installs, once .env is written. With --no-interactive nothing is asked, and the screen keeps its login prompt.

.env gets the stack's keys: CYFR_SECRET_KEY_BASE, CYFR_LOCUS_BACKENDS_KEY, CYFR_SETUP_TOKEN, the runtime root CYFR_LOCUS_RUNTIME_ROOT with the LOCUS_RUNTIME_KEY derived from it for LOCUS_RUNTIME_SERVICE_ID (wrk_locus unless .env names another), and CYFR_LOCUS_BUILDS_URL=http://locus-builds:4100 with a minted CYFR_LOCUS_BUILDS_KEY, so builds are on. CYFR_SETUP_TOKEN is the key of the setup link init prints last when it writes a new .env, <CYFR address>/setup#<token>: opened once CYFR is up, it sets up CYFR's first person, who administers it, with a passkey, and after a change of address it lets the administrator back in. 'cyfr login --setup' in this directory sets up the first person at this terminal instead, with this command line as their device; a headless CYFR (CYFR_HEADLESS=on) serves no page, so there it is the only way. Without the screen, on a machine with no display, init also prints the ssh command that brings the address to another computer. It also assigns CYFR_CORS_ALLOWED_ORIGINS the empty allowlist, since cyfr serves Prism, the API, /mcp and the tinctures from its own origin and no browser client of this stack is cross-origin; an allowlist .env assigns is the one that stands.

Re-running in an existing project is safe: docker-compose.yml, Caddyfile and .env.example are kept if they already exist, and .env gains only the keys it lacks. A key already in .env is never rewritten, and neither is how CYFR is reached, which 'cyfr access' changes; a .env that does not say how CYFR is reached (no CYFR_ACCESS) is refused, and nothing is written. A service key without the root it derives from, or one that does not derive from the root beside it, is refused with a sentence naming the fix, and nothing is written. No builds URL and no builds key is builds turned off, and stays off. Use --force to re-fetch docker-compose.yml, Caddyfile and keeper.seccomp.json.`,
	Example: `  cyfr init
  cyfr init --no-interactive --no-pull
  cyfr init --force
  cyfr up`,
	RunE: func(cmd *cobra.Command, args []string) error {
		ctx := cmd.Context()
		if ctx == nil {
			ctx = context.Background()
		}
		var o initOptions
		o.force, _ = cmd.Flags().GetBool("force")
		o.noPull, _ = cmd.Flags().GetBool("no-pull")
		o.continuation = continuationArgs(cmd)
		return runInit(ctx, o, cmd.OutOrStdout(), cmd.ErrOrStderr())
	},
}

// initOptions are cyfr init's flags. continuation is the flags given, for
// the init run that continues once the requirements are installed
// (prepareMachine).
type initOptions struct {
	force, noPull bool
	continuation  []string
}

// The steps a run of init begins, as initProject's step is told them.
const (
	initStepFiles    = "files"
	initStepSettings = "settings"
	initStepImages   = "images"
)

// runInit is `cyfr init` in the working directory, asking on the terminal:
// the machine's missing requirements first (prepareMachine), then, for a
// new project, whether this machine's screen shows CYFR, then the project,
// unless the run continued in a process of its own. The screen is asked
// for before anything is written, so an interrupt at its question leaves
// the directory as it was, and installed once .env is.
func runInit(ctx context.Context, o initOptions, out, errOut io.Writer) error {
	switch continued, err := prepareMachine(ctx, o.continuation, out, errOut); {
	case err != nil:
		return err
	case continued:
		return nil
	}
	fresh := !fileExists(".env")
	screen := false
	if fresh {
		var err error
		if screen, err = askScreen(ctx, out); err != nil {
			return err
		}
	}
	if err := initProject(ctx, o, nil, out, errOut); err != nil {
		return err
	}
	if !fresh || !fileExists(".env") {
		if fileExists("docker-compose.yml") {
			fmt.Fprintln(out, "Next: cyfr up.")
		} else {
			fmt.Fprintln(out, "Next: get docker-compose.yml + Caddyfile (a released CLI or a repo checkout), then 'cyfr up'.")
		}
		return nil
	}
	var screenErr error
	if screen {
		screenErr = screenOn(ctx, false, out)
	}
	initEnding(out, screen && screenErr == nil)
	return screenErr
}

// initEnding is init's last word on the new CYFR in the working directory,
// reached from this machine: its address, the offer to reach it from the
// person's other devices, made before anyone is set up since passkeys
// belong to the address, and the next step, which on screen is the reboot
// that shows setup there, and otherwise the setup link or cyfr login
// --setup at this terminal (sshTunnel's line beside them on a machine
// with no display). A headless CYFR serves no setup page.
func initEnding(out io.Writer, screen bool) {
	values, _ := access.ReadEnvValues(".env")
	port := existingSelection(".env").port
	address := access.Describe(access.Head{Mode: access.ModeLocal, Port: port}).Address
	fmt.Fprintln(out, "")
	fmt.Fprintf(out, "CYFR is set up in this directory, reached from this computer at %s.\n", address)
	fmt.Fprintln(out, "Want it on your phone and laptop too? Run cyfr access tailnet first.")
	if headless(values) {
		fmt.Fprintln(out, "CYFR is headless: after 'cyfr up', its first person runs 'cyfr login --setup' in this directory.")
		return
	}
	if screen {
		fmt.Fprintln(out, "Next: cyfr up, then sudo reboot.")
		fmt.Fprintln(out, "At power-on this screen opens CYFR's setup page, which sets up its first person with a passkey.")
		return
	}
	fmt.Fprintf(out, "Next: cyfr up. Then open %s to set up its first person, or run cyfr login --setup here.\n", hyperlink(out, setupLink(address, values)))
	if !hasDisplay() {
		fmt.Fprintln(out, sshTunnel(port))
	}
}

// sshTunnel is the line that brings this machine's loopback port, where a
// local CYFR answers, to another computer, whose browser then opens the
// link at the same localhost address, the one its passkeys belong to.
func sshTunnel(port int) string {
	account := ""
	if u, err := user.Current(); err == nil {
		account = u.Username
	}
	host, _ := os.Hostname()
	p := strconv.Itoa(port)
	return "From another computer: ssh -L " + p + ":127.0.0.1:" + p + " " + account + "@" + host + ", then open the link there."
}

// initProject is cyfr init in the working directory; step, when set, is
// told each step it begins (the initStep* names), as the setup pages show
// them.
func initProject(ctx context.Context, o initOptions, step func(name string), out, errOut io.Writer) error {
	releaseBuild := version.Version != "dev" && version.Version != ""

	// What init cannot complete is refused before anything is written: a
	// .env that does not say how its home is reached, whose cure is
	// `cyfr access <mode>`.
	envExisted := fileExists(".env")
	if envExisted {
		if _, err := existingAccess(".env"); err != nil {
			return err
		}
	}
	begin := func(name string) {
		if step != nil {
			step(name)
		}
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
	// re-extracts them. .env / .env.example are deliberately never
	// removed. A file that cannot be removed would be kept as it is by the
	// download, which skips an existing file, so init refuses after the
	// download, naming what is on disk then.
	var removed, unremoved []string
	if o.force {
		for _, name := range forceRefetched(releaseBuild) {
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
	begin(initStepFiles)
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

	if len(unremoved) > 0 {
		return forceRemovalRefusal(unremoved, removed)
	}

	// Generate .env from the .env.example template laid down by the
	// scaffold, for this computer only, with the stack's keys minted into
	// it. If .env.example isn't present — a dev build, where the scaffold
	// download is a no-op — skip it; the dev-build notice below tells the
	// user where to get it.
	sel := existingSelection(".env")
	if !envExisted && fileExists(".env.example") {
		begin(initStepSettings)
		text, _, d, err := newEnv(".env.example")
		if err != nil {
			return err
		}
		if err := writeFileAtomic(".env", text, 0600); err != nil {
			return fmt.Errorf("Failed to write .env: %w", err)
		}
		sel = selection{profiles: d.Head.Profiles, port: d.Head.Port}
	}

	// Generate .gitignore if it doesn't already exist (idempotent), before
	// the engine makes .cyfr/.
	if _, err := os.Stat(".gitignore"); os.IsNotExist(err) {
		if err := os.WriteFile(".gitignore", []byte(projectGitignore), 0644); err != nil {
			return fmt.Errorf("Failed to write .gitignore: %w", err)
		}
	}

	// Create directories. These are the bind-mount sources in
	// docker-compose.yml, so they must exist even on a dev build where the
	// scaffold tarball is a no-op. The container's entrypoint seeds aqua/
	// from /app/aqua-defaults on first start if it's empty.
	_ = os.MkdirAll("data", 0755)
	_ = scaffold.MakeDir("aqua")

	// Warm-pull the images docker-compose.yml starts with the head's
	// profiles (cyfr, and cyfr-locus for locus-runtime and locus-backends,
	// the same image serving locus-builds with builds on). A release's
	// compose names each as <repository>:<version>@<digest>, and `docker
	// pull` of such a reference pulls by the digest, so the warm pull
	// fetches exactly the images the verified scaffold names. Falls back to the published cyfr
	// image on a dev build (no compose). The pulls run outside the lock
	// and change nothing of the stack, so they are no call of the engine.
	// Each is one line: docker's quiet pull prints only the reference it
	// pulled, which the line names already, and its failures.
	if !o.noPull {
		begin(initStepImages)
		images := imagesFromCompose("docker-compose.yml", sel.profiles)
		if len(images) == 0 {
			images = []string{"ghcr.io/cyfrworks/cyfr:latest"}
		}
		for _, img := range images {
			fmt.Fprintf(out, "Pulling %s ...\n", img)
			pull := exec.Command("docker", "pull", "--quiet", img)
			pull.Stdout = io.Discard
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

	// The files and keys are in the directory and .env; what init says of
	// them is what it added to an existing .env, the one change a re-run
	// makes.
	if len(envChanges) > 0 {
		fmt.Fprintf(out, "Added to .env: %s.\n", describeChanges(envChanges))
	}

	if !releaseBuild {
		fmt.Fprintln(out, "")
		fmt.Fprintln(out, "⚠  dev build — docker-compose.yml, Caddyfile, .env.example and the bundled")
		fmt.Fprintln(out, "   scaffold (guides, wit/, aqua/) are only fetched for released")
		fmt.Fprintln(out, "   versions. Copy those files from a repo checkout, or run the server from")
		fmt.Fprintln(out, "   the checkout itself as CONTRIBUTING.md's \"Running from source\" says.")
	}
	return nil
}

// headlessVar is the switch that makes CYFR headless: the API and /mcp,
// and no browser page.
const headlessVar = "CYFR_HEADLESS"

// headless reports whether .env's values make CYFR headless, CYFR_HEADLESS
// read as the server's switch reads it (Prima.EnvValue.switch): `on`, white
// space around it aside.
func headless(values map[string]string) bool {
	return strings.TrimSpace(values[headlessVar]) == "on"
}

// setupLink is the link that sets up the first person of the CYFR at
// address with the setup token .env's values hold: its setup page, the
// token in the fragment, which no request carries and so no server log
// records.
func setupLink(address string, values map[string]string) string {
	return address + "/setup#" + strings.TrimSpace(values[setupTokenVar])
}

// existingAccess is the mode the existing .env at path says its home is
// reached as, refusing one naming a COMPOSE_* setting, which every command
// that runs compose refuses (compose_env_refused), and one without
// CYFR_ACCESS, with access_missing's sentence.
func existingAccess(path string) (string, error) {
	var r *access.Refusal
	if err := access.CheckEnvFile(path); errors.As(err, &r) && r.Code == "compose_env_refused" {
		return "", refusalError{r}
	}
	values, err := access.ReadEnvValues(path)
	if err != nil {
		return "", fmt.Errorf("read %s: %w", path, engineFailure(err))
	}
	current := values["CYFR_ACCESS"]
	if current == "" {
		return "", refusalError{access.Refuse("access_missing", nil)}
	}
	return current, nil
}

// localHead is the head a new home's .env starts from, reached from this
// computer only, its port and builds URL the ones values hold.
func localHead(values map[string]string) (access.Derivation, error) {
	cur := access.Current{Port: 4000}
	if text := values["CYFR_PORT"]; text != "" {
		port, err := strconv.Atoi(text)
		if err != nil {
			return access.Derivation{}, refusalError{access.Refuse("access_setting_invalid", map[string]string{"key": "CYFR_PORT", "value": text})}
		}
		cur.Port = port
	}
	cur.BuildsURL = values[buildsURLVar]
	d, err := access.Derive(access.Target{Mode: access.ModeLocal}, cur, nil)
	return d, engineFailure(err)
}

// selection is what init pulls and points the CLI at: the compose profiles
// a home's access mode selects and its loopback listener's port.
type selection struct {
	profiles []string
	port     int
}

// existingSelection is the selection of the .env at path as it stands, the
// port 4000 where it names none that reads.
func existingSelection(path string) selection {
	sel := selection{port: 4000}
	values, err := access.ReadEnvValues(path)
	if err != nil {
		return sel
	}
	if mode := values["CYFR_ACCESS"]; mode != "" {
		sel.profiles = access.Profiles(mode, values[buildsURLVar])
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
// access engine's state under .cyfr/ and the environment files.
const projectGitignore = `# CYFR project — all runtime state (every athanor's data and
# components, the database, caches) lives under data/.
/data/
# Snapshots cyfr update takes: each holds the keyring and the database.
/backups/
# How CYFR is reached, as cyfr keeps it: the stack's lock, the change
# in flight, its receipts and the tailnet's serve configuration.
/.cyfr/
.env
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
// line and "" for the end of the input (askLine), or ctx's error once ctx
// ends before a line arrives.
func ask(ctx context.Context, r *bufio.Reader, out io.Writer, question, def string) (string, error) {
	answer, _, err := askLine(ctx, r, out, question, def)
	return answer, err
}

// askLine is ask, and whether the input may hold another line: false at
// its end, where asking again reads nothing. The default answers an empty
// line; the end of the input with nothing on its line is no answer, "".
// Main's handler catches Ctrl-C, so a read of the terminal never ends on
// it, nor can it be cancelled: the read runs in a goroutine of its own,
// which the process's exit ends, and the question ends with ctx.
func askLine(ctx context.Context, r *bufio.Reader, out io.Writer, question, def string) (string, bool, error) {
	askQuestion(out, question, def)
	type line struct {
		answer string
		more   bool
	}
	answered := make(chan line, 1)
	go func() {
		answer, more := readAnswer(r, def)
		answered <- line{answer, more}
	}()
	select {
	case l := <-answered:
		return l.answer, l.more, nil
	case <-ctx.Done():
		fmt.Fprintln(out)
		return "", false, ctx.Err()
	}
}

func askQuestion(out io.Writer, question, def string) {
	if def != "" {
		fmt.Fprintf(out, "%s [%s]: ", question, def)
	} else {
		fmt.Fprintf(out, "%s: ", question)
	}
}

// readAnswer reads askLine's answer from r.
func readAnswer(r *bufio.Reader, def string) (string, bool) {
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
	Short:   "Start the CYFR stack (cyfr, locus-runtime, locus-builds, locus-backends; the proxy of tailnet or public access)",
	GroupID: "server",
	Long: `Start the CYFR stack with Docker Compose in detached mode, as .env says CYFR is reached. Requires a docker-compose.yml in the current directory (run 'cyfr init' first).

The stack is cyfr (the one endpoint: Prism, API, MCP, tinctures), locus-runtime (the runtime that runs components), locus-builds (the builds service that compiles components and tinctures), locus-backends (the backends service that runs the stdio/npx MCP servers an athanor adds on Prism's "MCP Servers" page, each backend under a uid and a memory bound of its own; cyfr tells it what to run), and the proxy of the way CYFR is reached: tailscale for tailnet access (Tailscale Serve, HTTPS at the machine's tailnet name) and caddy for public access (TLS on :80/:443).

cyfr, locus-runtime and locus-backends always start. locus-builds starts when CYFR_LOCUS_BUILDS_URL in .env names it (http://locus-builds:4100, which 'cyfr init' writes). CYFR_ACCESS in .env chooses the proxy: none for local, where Prism is at http://localhost:<CYFR_PORT>, tailscale for tailnet and caddy for public. cyfr up first takes the stack's lock and finishes a change an interrupted command left, then refuses a .env whose settings contradict how CYFR is reached, with the sentence the server would refuse it with, before anything starts. With tailnet access, CYFR is served on the tailnet only once the machine's tailnet identity is the one .env names. A start that fails says why, with the server's own refusal from its log when it gave one, and exits 1. A start prints Prism's address; when cyfr's log says no one is set up on it yet, cyfr up then says how its first person is set up: with this machine's screen showing CYFR (the cyfr-screen service), by a reboot when the screen has not started yet, or on that screen (Ctrl+Alt+F1); otherwise by opening the setup link, from a phone or laptop with Tailscale on for tailnet access, and for local access on a machine with no display through the ssh command it prints, or by 'cyfr login --setup' in this directory, at this terminal. A headless CYFR (CYFR_HEADLESS=on) serves no setup page, so there 'cyfr login --setup' is the only way.

Exit status 3: cyfr started, but on this machine only, because the tailnet machine is not ready to serve it (not the one .env names, not joined, or HTTPS off); Serve stays closed, and the message says what to do.`,
	Example: `  cyfr up`,
	RunE: func(cmd *cobra.Command, args []string) error {
		ctx := cmd.Context()
		if ctx == nil {
			ctx = context.Background()
		}
		if continued, err := upWithGroup(continuationArgs(cmd), cmd.OutOrStdout(), cmd.ErrOrStderr()); continued || err != nil {
			return err
		}
		return runUp(ctx, cmd.OutOrStdout())
	},
}

// runUp is `cyfr up` in the working directory.
func runUp(ctx context.Context, out io.Writer) error {
	// Registry auth is per-user: the server signs each registry request
	// with the person's identity key, and `cyfr registry sync` mints and
	// stores their push tokens. There are no static registry credentials to
	// configure.
	if err := refuseUndeclaredRestore(); err != nil {
		return err
	}
	// The start holds the lock an update, a restore and an access change
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
	firstStart := startErr == nil && readSetUp(ctx, e, head) == setUpNone
	release()
	select {
	case <-interrupts:
		return errors.New("cyfr up was interrupted; the start ran to its end and the lock is released. Run `cyfr access status` to see what runs")
	default:
	}
	if startErr != nil {
		return startErr
	}
	fmt.Fprintln(out, "CYFR server started.")
	fmt.Fprintln(out, "  Prism:           "+hyperlink(out, access.Describe(head).Address+"/"))
	if firstStart {
		fmt.Fprintln(out, "")
		setupNext(out, head)
	}
	return nil
}

// setupNext is how the first person of the CYFR at head, which no one is
// set up on yet, is set up, said after its start: on this machine's own
// screen when the cyfr-screen service shows it, a reboot away when it is
// enabled and has not started; otherwise through the setup link, which a
// local CYFR on a machine with no display reaches through sshTunnel's
// line, or cyfr login --setup at this terminal. A headless CYFR serves no
// setup page.
func setupNext(out io.Writer, head access.Head) {
	values, _ := access.ReadEnvValues(".env")
	if headless(values) {
		fmt.Fprintln(out, "Run cyfr login --setup here to set up its first person.")
		return
	}
	link := hyperlink(out, setupLink(access.Describe(head).Address, values))
	switch enabled, active := machine.screenService(); {
	case active:
		fmt.Fprintln(out, "Setup is on this screen (Ctrl+Alt+F1).")
	case enabled:
		fmt.Fprintln(out, "Now run sudo reboot. This screen opens setup at power-on.")
	case head.Mode == access.ModeTailnet:
		fmt.Fprintf(out, "Open %s on your phone or laptop, with Tailscale on, to set up its first person, or run cyfr login --setup here.\n", link)
	default:
		fmt.Fprintf(out, "Open %s to set up its first person, or run cyfr login --setup here.\n", link)
		if head.Mode == access.ModeLocal && !hasDisplay() {
			fmt.Fprintln(out, sshTunnel(head.Port))
		}
	}
}

// bootFatalMarker begins the line a refused boot prints, its sentence
// after it.
const bootFatalMarker = "[Cyfr] FATAL:"

// withBootFatal is a failed start with the refusal cyfr's boot last logged,
// read from the cyfr service's log under the lock: a setting only the
// release reads, such as a retired name, is refused there, and the start
// alone sees no more than an unhealthy container.
func withBootFatal(ctx context.Context, e stackEngine, head access.Head, startErr error) error {
	res, err := cyfrLog(ctx, e, head)
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

// notSetUpMarker begins the line the boot of a CYFR with no person yet
// logs (Cyfr.Application.not_set_up_marker/0); setUpMarker begins the line
// CYFR logs once it gains its first person
// (Arca.InstallationClaims.set_up_marker/0), after which the boot's line no
// longer stands.
const (
	notSetUpMarker = "[Cyfr] Not set up:"
	setUpMarker    = "[Cyfr] Set up:"
)

// setUp is what the cyfr service's log since its current start says of
// whether anyone is set up on the CYFR in the working directory.
type setUp int

const (
	// setUpUnknown: cyfr runs, and its log could not be read.
	setUpUnknown setUp = iota
	// setUpStopped: no cyfr runs, so there is no log of this start.
	setUpStopped
	// setUpNone: the boot's not-set-up line, and no set-up line after it.
	setUpNone
	// setUpDone: a set-up line, or a log since the start that holds
	// neither, since the boot logs its line only when no one exists.
	setUpDone
)

// readSetUp reads setUp for the CYFR at head from the cyfr service's log
// since its current start, under the lock.
func readSetUp(ctx context.Context, e stackEngine, head access.Head) setUp {
	res, err := cyfrLogSinceStart(ctx, e, head)
	switch {
	case errors.Is(err, errNoCyfrRunning):
		return setUpStopped
	case err != nil || res.ExitCode != 0:
		return setUpUnknown
	}
	log := string(res.Stdout) + "\n" + string(res.Stderr)
	if notSet := strings.LastIndex(log, notSetUpMarker); notSet >= 0 && !strings.Contains(log[notSet:], setUpMarker) {
		return setUpNone
	}
	return setUpDone
}

// upThenSetup is the next step of a CYFR that never booted, with .env's
// values: cyfr up, then its first person set up at the setup link link,
// or at this terminal for a headless CYFR, which serves no setup page.
func upThenSetup(values map[string]string, link string) string {
	if headless(values) {
		return "Next: cyfr up. Then run cyfr login --setup here to set up its first person."
	}
	return "Next: cyfr up. Then open " + link + " to set up its first person."
}

// neverBooted reports whether the CYFR in the working directory has never
// booted: .env leaves its database where the compose file puts it, the
// SQLite file data/cyfr.db (CYFR_DATABASE, CYFR_DATA_PATH and
// CYFR_DATABASE_PATH unassigned), and its first boot has not made that
// file. A container is no witness, since cyfr down removes them all.
func neverBooted() bool {
	values, err := access.ReadEnvValues(".env")
	if err != nil {
		return false
	}
	for _, name := range []string{"CYFR_DATABASE", "CYFR_DATA_PATH", "CYFR_DATABASE_PATH"} {
		if _, assigned := values[name]; assigned {
			return false
		}
	}
	_, err = os.Lstat(filepath.Join("data", "cyfr.db"))
	return errors.Is(err, fs.ErrNotExist)
}

// errNoCyfrRunning is cyfrLogSinceStart's answer when no cyfr container
// runs.
var errNoCyfrRunning = errors.New("no cyfr container runs")

// cyfrLogSinceStart is the cyfr service's log since its container's
// current start (its StartedAt), so a notice an earlier boot logged is
// never read as this one's.
func cyfrLogSinceStart(ctx context.Context, e stackEngine, head access.Head) (access.Result, error) {
	ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), composeRunTimeout)
	defer cancel()
	run := func(args []string) (string, error) {
		res, err := e.Docker().Run(ctx, access.Call{Args: args, Deadline: composeRunTimeout})
		if err == nil && res.ExitCode != 0 {
			err = fmt.Errorf("docker %s exited %d", args[0], res.ExitCode)
		}
		return strings.TrimSpace(string(res.Stdout)), err
	}
	args, err := e.ComposeArgs(ctx, head, "ps", "-q", "cyfr")
	if err != nil {
		return access.Result{}, err
	}
	id, err := run(args)
	switch {
	case err == nil && id == "":
		return access.Result{}, errNoCyfrRunning
	case err != nil || strings.ContainsAny(id, " \n"):
		return access.Result{}, errors.New("no one cyfr container to read")
	}
	started, err := run([]string{"inspect", "--format", "{{.State.StartedAt}}", id})
	if err != nil || started == "" {
		return access.Result{}, errors.New("the cyfr container's start is not known")
	}
	if args, err = e.ComposeArgs(ctx, head, "logs", "--no-color", "--no-log-prefix", "--since", started, "cyfr"); err != nil {
		return access.Result{}, err
	}
	return e.Docker().Run(ctx, access.Call{Args: args, Deadline: composeRunTimeout})
}

// cyfrLog is the cyfr service's last 200 log lines, read through the
// engine's compose selection and Docker runner.
func cyfrLog(ctx context.Context, e stackEngine, head access.Head) (access.Result, error) {
	ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), composeRunTimeout)
	defer cancel()
	args, err := e.ComposeArgs(ctx, head, "logs", "--no-color", "--no-log-prefix", "--tail", "200", "cyfr")
	if err != nil {
		return access.Result{}, err
	}
	return e.Docker().Run(ctx, access.Call{Args: args, Deadline: composeRunTimeout})
}

var downCmd = &cobra.Command{
	Use:     "down",
	Short:   "Stop the CYFR stack",
	GroupID: "server",
	Long:    "Stop the CYFR stack and remove its containers, keeping its networks. Every service of the project, the proxy of tailnet or public access and locus-builds included, whatever .env selects now, is checked stopped before it reports. It takes the stack's lock first, so it never runs inside another cyfr command's start or change, and finishes a change an interrupted command left. The stack is the working directory's, started from its compose file and named after the directory, so a directory that holds no compose file is refused: nothing of a CYFR started elsewhere is stopped from here.",
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
// project stopped, removed and checked stopped, under the lock. The
// engine starts the stack from the directory's compose file and names it
// after the directory, and finds nothing of a home started in another,
// so a directory that holds no compose file (access.HasComposeFile) is
// refused before the lock with nothing stopped, rather than a stop of
// nothing reported as "stopped". A home `cyfr init` wrote and a source
// checkout `cyfr up` started without it both hold one; a directory that
// holds two, which a start refuses to choose between, is stopped, since
// the stop reaches the project's containers by their label.
func runDown(ctx context.Context, out io.Writer) error {
	if !access.HasComposeFile(".") {
		return fmt.Errorf("There is no stack in this directory, so nothing was stopped: it holds no compose file (%s). Run 'cyfr down' in CYFR's directory, the one that holds its docker-compose.yml", strings.Join(access.ComposeMainFiles, ", "))
	}
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
	values, err := access.ReadEnvValues(path)
	if err != nil {
		return "", false
	}
	snapshot := values[restoreBarrier]
	return snapshot, snapshot != ""
}
