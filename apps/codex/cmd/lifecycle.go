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
	"github.com/cyfr/codex/internal/apparmor"
	"github.com/cyfr/codex/internal/config"
	"github.com/cyfr/codex/internal/link"
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
// before extracting a byte. A folder the scaffold writes in that is a link
// it does not follow (scaffold.ErrLinkNotFollowed) stops it too, before a
// file is written. Any other failure is a transport failure: it
// warns on warn, and init continues with the files already present.
func scaffoldDownloadFailure(rel string, err error, warn io.Writer) error {
	if errors.Is(err, release.ErrUnverified) {
		return fmt.Errorf("the scaffold of release %s failed verification, so nothing was extracted: %w", rel, err)
	}
	if errors.Is(err, scaffold.ErrLinkNotFollowed) {
		return fmt.Errorf("%w; no scaffold file was written", err)
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
	buildsKeyVar     = "CYFR_LOCUS_BUILDS_KEY"
	corsOriginsVar   = "CYFR_CORS_ALLOWED_ORIGINS"

	// The runtime role's id when .env names none: docker-compose.yml's
	// default for both LOCUS_RUNTIME_SERVICE_ID and the entry of CYFR_LOCUS_RUNTIME_WORKERS.
	defaultServiceID = "wrk_locus"
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
// present is never rewritten, but the AppArmor profile's name, cyfr's own; a malformed root or service id, and a
// service key that does not derive from the root beside it, are refused,
// since writing around them would leave cyfr and Locus's runtime role
// unable to authenticate each other. Each key reads as its last
// assignment, as compose, the engine and every read of the CLI read it,
// and the editor writes over that one.
//
// The runtime root and the runtime role's key are one pair: with neither, both
// are minted; with the root alone, the key is derived from it for
// LOCUS_RUNTIME_SERVICE_ID (wrk_locus when .env names none). The builds
// key is minted for a fresh .env alone, so a new home builds; in a .env
// that exists, an empty or absent builds key is builds turned off, and is
// left so. The tunnel key is minted for a fresh .env alone too: a server
// keeps its private address for good, and a .env from an earlier build is
// not carried across.
func stackKeys(values map[string]string, fresh bool) (map[string]string, []envChange, error) {
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
			return nil, nil, refuseEnv("%s in .env is not the key %s derives for %s %s, so cyfr and Locus's runtime role could not authenticate each other: remove %s and run cyfr init again to derive it, or set %s to the root it was derived from.", serviceKeyVar, workerRootVar, serviceIDVar, serviceID, serviceKeyVar, workerRootVar)
		}
	}

	// The browser CORS allowlist: assigned, whatever it says stands, and
	// assigned empty it is the empty allowlist. Unassigned, the list the
	// application's own configuration sets stands, so init assigns the
	// empty allowlist itself — cyfr serves Prism, the API, /mcp and the
	// tinctures from its own origin, and behind the proxy of a browser
	// address they are still that one origin, so no browser client of
	// this stack is cross-origin. Never a wildcard.
	if _, assigned := values[corsOriginsVar]; !assigned {
		set(corsOriginsVar, "")
	}

	// The AppArmor profile the Locus services run under is cyfr's to name,
	// so it is written whatever .env held: the one built into this cyfr.
	if values[appArmorEnv] != apparmor.ProfileName {
		set(appArmorEnv, apparmor.ProfileName)
	}

	if fresh && values[buildsKeyVar] == "" {
		if err := mint(buildsKeyVar, generateHexKey); err != nil {
			return nil, nil, err
		}
	}

	// The tunnel key, minted once for a new .env: its private half and
	// pre-shared key, which only the link service reads, and its public
	// half, which names the server's private address.
	if fresh && values[link.KeyVar] == "" && values[link.PublicVar] == "" {
		key, public, err := link.Mint()
		if err != nil {
			return nil, nil, fmt.Errorf("generate %s: %w", link.KeyVar, err)
		}
		set(link.KeyVar, key)
		set(link.PublicVar, public.String())
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
	add, changes, err := stackKeys(values, false)
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
	add, changes, err := stackKeys(values, true)
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
		err = access.ReplaceFile(tmp.Name(), target)
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
// and the seccomp profiles beside them, which `cyfr update` also
// refreshes. On a dev build the tarball is a no-op, so nothing is removed
// that could not be replaced.
func forceRefetched(releaseBuild bool) []string {
	if !releaseBuild {
		return nil
	}
	return append([]string{"docker-compose.yml", "Caddyfile"}, scaffold.SeccompProfiles...)
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
	initCmd.Flags().Bool("force", false, "Re-fetch docker-compose.yml, Caddyfile, keeper.seccomp.json and container.seccomp.json even if they already exist (never replaces .env or .env.example)")
	initCmd.Flags().Bool("no-pull", false, "Do not pull the stack's images")
	rootCmd.AddCommand(initCmd)
	rootCmd.AddCommand(upCmd)
	rootCmd.AddCommand(downCmd)
}

var initCmd = &cobra.Command{
	Use:     "init",
	Short:   "Set up a new CYFR in this directory, at a terminal: its files, keys and images, ready for cyfr up",
	GroupID: "server",
	Long: `Set up a CYFR project in the current directory so you can start the self-hosted stack with "cyfr up": cyfr (the one endpoint), locus (the one Locus, whose roles run components, compile them and run stdio MCP servers) behind its egress guard locus-guard, and the proxy of its browser address, tailscale for a tailnet address and caddy for a domain.

Downloads docker-compose.yml, Caddyfile, keeper.seccomp.json and container.seccomp.json (the seccomp profiles Locus and every other service run under), .env.example, the services' own env examples and the bundled scaffold (` + strings.Join(scaffold.Guides, ", ") + `, wit/ definitions, the aqua/ soul, roles and scrolls) for this CLI's version; generates .gitignore and the data/aqua directories; writes .env from .env.example; and pulls the images the stack starts (--no-pull skips the pulls).

On Ubuntu 26.04 with AppArmor on, before it writes anything, init offers the AppArmor profile built into this cyfr where the kernel has not loaded it by its name, which carries its content (cyfr-locus- and 12 hex digits): at a terminal it shows the two commands that install and load it, asks, and runs them through one sudo, giving root the profile from cyfr itself; without one it refuses, naming the one command; declined, nothing is written. .env's CYFR_LOCUS_APPARMOR, which docker-compose.yml's security_opt reads, names it; the keeper proves at its boot that it runs under it.

On Ubuntu 26.04 LTS at a terminal, when this account cannot reach Docker, init first shows the commands that install what is missing (docker.io, docker-compose-v2 and apparmor, the running service and this account's membership of the docker group), asks, and runs them through one sudo; answered no, init installs nothing, writes nothing and exits 0. CYFR never asks for, reads or keeps a password: when sudo will ask, init first says it asks for the password you log in to this machine with, and sudo asks in its own prompt before any command runs, so a refused password changes nothing. An account outside the sudo and admin groups is told so before anything is asked, with the commands as one sudo line for whoever administers the machine, and nothing is changed; answered 1 at the screen question, it is told before anything is written, in words alone, that whoever administers the machine can add it to the sudo group. The rest of init then runs in a process that has the group, and 'cyfr up' gets the group the same way.

On macOS and Windows at a terminal, while Docker does not answer, init offers to open Docker's installer page for Docker Desktop and says what the system's prompt will be (a Mac's login password or Touch ID; Windows asking to allow the app to make changes), or, with Docker Desktop installed, says to start it; then it waits, writing nothing, until Docker answers, and goes on. Answered no, init opens and writes nothing and exits 0.

The CYFR init makes has no browser address: it is reached from this machine, at its private address, http://h-<16 letters and digits>.localhost:<CYFR_PORT>, which its tunnel key names and which it keeps whatever browser address it is given. 'cyfr access browser tailnet' reaches it from your phone and laptop too, 'cyfr access browser domain --domain <your domain>' from the internet, and 'cyfr access browser proxy --domain <your domain>' through a proxy of your own. On Ubuntu 26.04 LTS on amd64 or arm64 at a terminal, on a machine with no desktop, init asks before it writes anything whether this machine's screen shows CYFR (1, the default) or keeps its login prompt (2); the first installs what 'cyfr screen on' installs, once .env is written. With --no-interactive nothing is asked, and the screen keeps its login prompt.

.env gets the stack's keys: CYFR_SECRET_KEY_BASE, CYFR_LOCUS_BACKENDS_KEY, CYFR_SETUP_TOKEN, the runtime root CYFR_LOCUS_RUNTIME_ROOT with the LOCUS_RUNTIME_KEY derived from it for LOCUS_RUNTIME_SERVICE_ID (wrk_locus unless .env names another), and CYFR_LOCUS_BUILDS_KEY, so builds are on. A new .env also gets the tunnel key, minted once: CYFR_LINK_KEY, its private half and pre-shared key, and CYFR_LINK_PUBLIC, its public half, which names the private address; a .env from an earlier build is not given one. CYFR_SETUP_TOKEN is the key of the setup link init prints last when it writes a new .env, <CYFR address>/setup#<token>: opened once CYFR is up, it sets up CYFR's first person, who administers it, with their account, and once someone is set up it opens nothing. Without the screen, on a machine with no display, init also prints the ssh command that brings the address to another computer. It also assigns CYFR_CORS_ALLOWED_ORIGINS the empty allowlist, since cyfr serves Prism, the API, /mcp and the tinctures from its own origin and no browser client of this stack is cross-origin; an allowlist .env assigns is the one that stands.

Re-running in an existing project is safe: docker-compose.yml, Caddyfile and .env.example are kept if they already exist, and .env gains only the keys it lacks. A key already in .env is never rewritten, and neither is how CYFR is reached, which 'cyfr access' changes; a .env that does not say CYFR's browser address (no CYFR_BROWSER) is refused, and nothing is written. A service key without the root it derives from, or one that does not derive from the root beside it, is refused with a sentence naming the fix, and nothing is written. An empty or absent CYFR_LOCUS_BUILDS_KEY in an existing .env is builds turned off, and stays off. Use --force to re-fetch docker-compose.yml, Caddyfile, keeper.seccomp.json and container.seccomp.json.`,
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
		o.continuation = continued(cmd, nil)
		return runInit(ctx, o, cmd.OutOrStdout(), cmd.ErrOrStderr())
	},
}

// initOptions are cyfr init's flags. continuation is init as given, for
// the init run that continues once the requirements are installed
// (prepareMachine).
type initOptions struct {
	force, noPull bool
	continuation  continuation
	// project is the compose project's name where the caller chose it,
	// setup's work in a folder it entered; otherwise the working
	// directory's name.
	project string
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
		// The password is asked here, not before the project is written:
		// sudo's login would lapse during the image pulls between them. A
		// refusal here, of the password or of an account that has left the
		// sudo group since the question, comes after the project is
		// written, and says so.
		const notSetUp = "so the screen was not set up; CYFR is set up in this directory."
		var refused passwordRefused
		var outside outsideTheGroups
		switch screenErr = screenOn(ctx, false, out); {
		case errors.As(screenErr, &refused):
			screenErr = errors.New("The password was not accepted, " + notSetUp + " Run `cyfr screen on` here to set it up")
		case errors.As(screenErr, &outside):
			screenErr = fmt.Errorf("Your account, %s, is not in the sudo or admin group, %s Whoever administers this machine can add your account to the sudo group; then run `cyfr screen on` here", outside.account, notSetUp)
		}
	}
	initEnding(out, screen && screenErr == nil)
	return screenErr
}

// initEnding is init's last word on the new CYFR in the working directory,
// reached from this machine: its private address, the offer to reach it
// from the person's other devices, made before anyone is set up, while a
// new address signs no one out, and the next step, which on screen is the
// reboot that shows setup there, and otherwise the setup link at the
// private address, the one a server with no browser address gives out
// (sshTunnel's line beside it on a machine with no display).
func initEnding(out io.Writer, screen bool) {
	values, _ := access.ReadEnvValues(".env")
	port := existingSelection(".env").port
	address, _ := access.ResolveLink(values[link.PublicVar], port)
	fmt.Fprintln(out, "")
	fmt.Fprintf(out, "CYFR is set up in this directory, reached from this computer at %s.\n", address)
	fmt.Fprintln(out, "Want it on your phone and laptop too? Run cyfr access browser tailnet first.")
	if screen {
		fmt.Fprintln(out, "Next: cyfr up, then sudo reboot.")
		fmt.Fprintln(out, "At power-on this screen opens CYFR's setup page, which makes its first person's account with this box as its first device.")
		return
	}
	fmt.Fprintf(out, "Next: cyfr up. Then open %s to set up its first person.\n", hyperlink(out, setupLink(address, values)))
	if !hasDisplay() {
		fmt.Fprintln(out, sshTunnel(port))
	}
}

// sshTunnel is the line that brings this machine's loopback port, where a
// CYFR with no browser address answers, to another computer, whose
// browser then opens the link at the same private address, a name under
// localhost that a browser takes to its own loopback, where the tunnel
// listens.
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
// told each step it begins (the initStep* names), as the app's setup
// screen shows them.
func initProject(ctx context.Context, o initOptions, step func(name string), out, errOut io.Writer) error {
	releaseBuild := version.Version != "dev" && version.Version != ""

	// What init cannot complete is refused before anything is written: a
	// folder Docker cannot name the project after, which every start would
	// refuse, and a .env that does not say what browser address its server
	// has, whose cure is `cyfr access browser <kind>`.
	if o.project == "" {
		if err := projectNamed("."); err != nil {
			return err
		}
	}
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

	// The profile the Locus services run under is offered before anything
	// is written, so a person who declines it keeps the folder as it was.
	if err := ensureAppArmor(ctx, out, "cyfr init"); err != nil {
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
	// warns and init goes on; a release that fails verification, or a
	// folder link the scaffold does not follow, stops it
	// (scaffoldDownloadFailure).
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
		// The download takes no interrupt. One that came during it is
		// heeded here, before any key is minted.
		if ctx.Err() != nil {
			return interruption{errors.New("Interrupted before .env was written. Run it again to go on.")}
		}
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
	// profiles (cyfr, and cyfr-locus for locus and locus-guard). A release's
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
			pull := exec.CommandContext(ctx, "docker", "pull", "--quiet", img)
			pull.WaitDelay = dockerWaitDelay
			pull.Stdout = io.Discard
			pull.Stderr = errOut
			err := pull.Run()
			if ctx.Err() != nil {
				// Interrupted: cyfr up pulls what is missing.
				break
			}
			if err != nil {
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

// projectNamed refuses a folder whose name leaves docker compose none for
// the project (access.ProjectName).
func projectNamed(dir string) error {
	if access.ProjectName(dir) != "" {
		return nil
	}
	if abs, err := filepath.Abs(dir); err == nil {
		dir = abs
	}
	return fmt.Errorf("CYFR cannot be set up in %s: Docker names it after the folder, whose name needs a letter a to z or a digit. Nothing was changed. Use a folder with another name", dir)
}

// setupLink is the link that sets up the first person of the CYFR at
// address with the setup token .env's values hold: its setup page, the
// token in the fragment, which no request carries and so no server log
// records.
func setupLink(address string, values map[string]string) string {
	return address + "/setup#" + strings.TrimSpace(values[setupTokenVar])
}

// existingAccess is the kind of browser address the existing .env at path
// says its server has, refusing one naming a COMPOSE_* setting, which
// every command that runs compose refuses (compose_env_refused), and one
// without CYFR_BROWSER, with access_missing's sentence.
func existingAccess(path string) (string, error) {
	var r *access.Refusal
	if err := access.CheckEnvFile(path); errors.As(err, &r) && r.Code == "compose_env_refused" {
		return "", refusalError{r}
	}
	values, err := access.ReadEnvValues(path)
	if err != nil {
		return "", fmt.Errorf("read %s: %w", path, engineFailure(err))
	}
	current := values["CYFR_BROWSER"]
	if current == "" {
		return "", refusalError{access.Refuse("access_missing", nil)}
	}
	return current, nil
}

// localHead is the head a new server's .env starts from, with no browser
// address, its port the one values hold.
func localHead(values map[string]string) (access.Derivation, error) {
	cur := access.Current{Port: 4000}
	if text := values["CYFR_PORT"]; text != "" {
		port, err := strconv.Atoi(text)
		if err != nil {
			return access.Derivation{}, refusalError{access.Refuse("access_setting_invalid", map[string]string{"key": "CYFR_PORT", "value": text})}
		}
		cur.Port = port
	}
	d, err := access.Derive(access.Target{Browser: access.BrowserNone}, cur, nil)
	return d, engineFailure(err)
}

// selection is what init pulls and points the CLI at: the compose profiles
// a server's browser address selects and its loopback listener's port.
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
	if browser := values["CYFR_BROWSER"]; browser != "" {
		sel.profiles = access.Profiles(browser)
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
// order the services first name them, each once (locus and locus-guard
// run one image). A service with only `build:` is skipped.
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
	Use:         "up",
	Annotations: map[string]string{dockerAnnotation: "yes"},
	Short:       "Start the CYFR stack (cyfr, locus, locus-guard; the proxy of a tailnet or domain address)",
	GroupID:     "server",
	Long: `Start the CYFR stack with Docker Compose in detached mode, as .env says CYFR is reached. Requires a docker-compose.yml in the current directory (run 'cyfr init' first).

The stack is cyfr (the one endpoint: Prism, API, MCP, tinctures), locus (the one Locus: its runtime role runs components, its builds role compiles components and tinctures, and its backends role runs the stdio/npx MCP servers an athanor adds on Prism's "MCP Servers" page, each backend under a uid and a memory bound of its own; cyfr tells it what to run), locus-guard (Locus's egress guard), and the proxy of its browser address: tailscale for a tailnet address (Tailscale Serve, HTTPS at the machine's tailnet name) and caddy for a domain (TLS on :80/:443).

cyfr, locus and locus-guard always start; Locus starts its builds role when .env sets CYFR_LOCUS_BUILDS_KEY, which 'cyfr init' writes. CYFR_BROWSER in .env chooses the proxy: tailscale for tailnet and caddy for domain; none starts with none, where Prism is at the private address alone, nor with proxy, where cyfr's proxy listener is published on this machine's loopback at CYFR_PROXY_PUBLISH for your own proxy. On Linux with AppArmor on, before anything starts, cyfr up on Ubuntu 26.04 with AppArmor on, where the kernel has not loaded the profile built into this cyfr by its name, at a terminal it shows the two commands that install and load it, asks, and runs them through one sudo, giving root the profile from cyfr itself, and without one it refuses, naming the one command to run; elsewhere it leaves that to the keeper, which proves at its boot that it runs under its release's profile. cyfr up then takes the stack's lock and finishes a change an interrupted command left, then refuses a .env whose settings contradict how CYFR is reached, with the sentence the server would refuse it with, before anything starts. With a tailnet address, CYFR is served on the tailnet only once the machine's tailnet identity is the one .env names. A start that fails says why, with the server's own refusal from its log when it gave one, and exits 1. A start prints Prism's address on this computer, the private address, and its browser address when it has one; when cyfr's log says no one is set up on it yet, cyfr up then says how its first person is set up: with this machine's screen showing CYFR (the cyfr-screen service), by a reboot when the screen has not started yet, or on that screen (Ctrl+Alt+F1); otherwise by opening the setup link, from a phone or laptop with Tailscale on for a tailnet address, and with no browser address on a machine with no display through the ssh command it prints.

Exit status 3: cyfr started, but on this machine only, because the tailnet machine is not ready to serve it (not the one .env names, not joined, or HTTPS off); Serve stays closed, and the message says what to do.`,
	Example: `  cyfr up`,
	RunE: func(cmd *cobra.Command, args []string) error {
		ctx := cmd.Context()
		if ctx == nil {
			ctx = context.Background()
		}
		// Before the access settings: a missing .env reads as empty, so the
		// first refusal would blame them rather than the directory.
		if !access.HasComposeFile(".") {
			return fmt.Errorf("There is no CYFR in this directory, so nothing was started: it holds no compose file (%s). Run 'cyfr up' in CYFR's directory, the one that holds its docker-compose.yml, or 'cyfr init' here to make one", strings.Join(access.ComposeMainFiles, ", "))
		}
		return runUp(ctx, cmd.OutOrStdout())
	},
}

// runUp is `cyfr up` in the working directory.
func runUp(ctx context.Context, out io.Writer) error {
	e, err := openEngine(".")
	if err != nil {
		return engineFailure(err)
	}
	return upWith(ctx, e, out)
}

// upWith is cyfr up's start of the project e opened.
func upWith(ctx context.Context, opened stackEngine, out io.Writer) error {
	// Registry auth is per-user: the person mints and stores their push
	// tokens on CYFR's Registry page. There are no static registry
	// credentials to configure.
	if err := refuseUndeclaredRestore(); err != nil {
		return err
	}
	// Before the lock, whose recovery may start the stack.
	if err := ensureAppArmor(ctx, out, "cyfr up"); err != nil {
		return err
	}
	// The start holds the lock an update, a restore and an access change
	// hold while they stop the stack, so none of them runs inside a start,
	// nor a start inside them. An interrupt is noted, not acted on: the
	// start runs to its end under the lock, and the lock goes with it.
	e, unlock, _, err := lockedEngine(ctx, opened, "up", out)
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
	words, err := e.Words()
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
	fmt.Fprintln(out, "  Prism on this computer: "+hyperlink(out, words.Private+"/"))
	if words.Browser != "" {
		fmt.Fprintln(out, "  Prism in a browser:     "+hyperlink(out, words.Browser+"/"))
	}
	if firstStart {
		fmt.Fprintln(out, "")
		setupNext(out, head, words)
	}
	return nil
}

// setupNext is how the first person of the CYFR at head, whose words are
// words, which no one is set up on yet, is set up, said after its start:
// on this machine's own screen when the cyfr-screen service shows it, a
// reboot away when it is enabled and has not started or whether it runs
// went unread; otherwise through the setup link at the address it gives
// out, which a CYFR with no browser address on a machine with no display
// reaches through sshTunnel's line.
func setupNext(out io.Writer, head access.Head, words access.Words) {
	values, _ := access.ReadEnvValues(".env")
	opens := hyperlink(out, setupLink(words.Shared(), values))
	switch enabled, active, _ := machine.screenService(); {
	case active:
		fmt.Fprintln(out, "Setup is on this screen (Ctrl+Alt+F1).")
	case enabled:
		fmt.Fprintln(out, "Now run sudo reboot. This screen opens setup at power-on.")
	case head.Browser == access.BrowserTailnet:
		fmt.Fprintf(out, "Open %s on your phone or laptop, with Tailscale on, to set up its first person.\n", opens)
	default:
		fmt.Fprintf(out, "Open %s to set up its first person.\n", opens)
		if head.Browser == access.BrowserNone && !hasDisplay() {
			fmt.Fprintln(out, sshTunnel(head.Port))
		}
	}
}

// bootFatalMarker matches the start of the line a refused boot prints,
// whichever service and part refused (`[Cyfr] FATAL:`, `[Arca] FATAL:` for
// a database another schema built, `[Locus] FATAL:`), its sentence after
// it.
var bootFatalMarker = regexp.MustCompile(`\[[A-Z][A-Za-z.]*\] FATAL:`)

// withBootFatal is a failed start with the refusal a boot of the stack
// last logged (bootFatal).
func withBootFatal(ctx context.Context, e stackEngine, head access.Head, startErr error) error {
	if fatal := bootFatal(ctx, e, head); fatal != "" {
		return fmt.Errorf("%w\n%s", startErr, fatal)
	}
	return startErr
}

// bootFatal is the refusal a boot of the stack last logged, said for a
// failed start, read from its services' logs: a setting only the release
// reads, such as a retired name, or a database another schema built is
// refused there, and the start alone sees no more than an unhealthy
// container. It is "" when the log holds none or cannot be read.
func bootFatal(ctx context.Context, e stackEngine, head access.Head) string {
	res, err := stackLog(ctx, e, head)
	if err != nil {
		return ""
	}
	fatal := ""
	for _, line := range strings.Split(string(res.Stdout)+"\n"+string(res.Stderr), "\n") {
		if loc := bootFatalMarker.FindStringIndex(line); loc != nil {
			fatal = strings.TrimSpace(line[loc[0]:])
		}
	}
	if fatal == "" {
		return ""
	}
	return "A service refused to boot, and its log says why:\n  " + e.Redactor().Text(fatal)
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
	return setUpIn(res)
}

// setUpIn is what a cyfr log since its start, res, says of setup.
func setUpIn(res access.Result) setUp {
	log := string(res.Stdout) + "\n" + string(res.Stderr)
	if notSet := strings.LastIndex(log, notSetUpMarker); notSet >= 0 && !strings.Contains(log[notSet:], setUpMarker) {
		return setUpNone
	}
	return setUpDone
}

// upThenSetup is the next step of a CYFR that never booted: cyfr up, then
// its first person set up at the setup link link.
func upThenSetup(link string) string {
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

// stackLog is every service's last 200 log lines, read through the
// engine's compose selection and Docker runner: cyfr refuses a boot with
// `[Cyfr]` or `[Arca] FATAL:`, a Locus service with `[Locus] FATAL:`, each
// in its own container's log.
func stackLog(ctx context.Context, e stackEngine, head access.Head) (access.Result, error) {
	ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), composeRunTimeout)
	defer cancel()
	args, err := e.ComposeArgs(ctx, head, "logs", "--no-color", "--no-log-prefix", "--tail", "200")
	if err != nil {
		return access.Result{}, err
	}
	return e.Docker().Run(ctx, access.Call{Args: args, Deadline: composeRunTimeout})
}

var downCmd = &cobra.Command{
	Use:         "down",
	Annotations: map[string]string{dockerAnnotation: "yes"},
	Short:       "Stop the CYFR stack",
	GroupID:     "server",
	Long:        "Stop the CYFR stack and remove its containers, keeping its networks. Every service of the project, the proxy of a tailnet or domain address included, whatever .env selects now, is checked stopped before it reports. It takes the stack's lock first, so it never runs inside another cyfr command's start or change, and finishes a change an interrupted command left. The stack is the working directory's, started from its compose file and named after the directory, so a directory that holds no compose file is refused: nothing of a CYFR started elsewhere is stopped from here.",
	Example:     "  cyfr down",
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
	_, unlock, err := stopStack(ctx, "down", out)
	if err != nil {
		return err
	}
	unlock()
	fmt.Fprintln(out, "CYFR server stopped.")
	return nil
}

// stopStack is cyfr down's stop, for command: the stack's lock, its
// recovery, then every service stopped, removed and checked stopped, Serve
// closed first. It answers the engine and the lock's release, still held.
func stopStack(ctx context.Context, command string, out io.Writer) (stackEngine, func(), error) {
	e, unlock, _, err := openLocked(ctx, command, out)
	if err != nil {
		return nil, nil, err
	}
	if err := answerFailure(e.Stop(context.WithoutCancel(ctx), command, true)); err != nil {
		unlock()
		return nil, nil, err
	}
	return e, unlock, nil
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
