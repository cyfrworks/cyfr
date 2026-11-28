// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"bufio"
	"bytes"
	"cmp"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"iter"
	"maps"
	"net/url"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"reflect"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/cyfr/codex/internal/access"
	"github.com/cyfr/codex/internal/apparmor"
	"github.com/cyfr/codex/internal/release"
	"github.com/cyfr/codex/internal/scaffold"
	"github.com/cyfr/codex/internal/version"
	"github.com/spf13/cobra"
	"gopkg.in/yaml.v3"
)

func init() {
	updateCmd.Flags().String("version", "", "Install exactly this release, a pre-release or an older release included, instead of the newest one")
	updateCmd.Flags().Bool("yes", false, "Update CYFR without asking to confirm it")
	// The release the program step installed, which the new program it
	// hands over to checks it is (updateProgram).
	updateCmd.Flags().String("continue-as", "", "")
	_ = updateCmd.Flags().MarkHidden("continue-as")
	// The CYFR app's Update CYFR page (cmd/app_window.go): --offer prints
	// the change to the CYFR in the directory as JSON and makes none;
	// --confirmed makes the change only where what it reads is still what
	// the offer read (confirmation), in place of --yes. Each touches this
	// CYFR alone, at --version, this program's release.
	updateCmd.Flags().Bool("offer", false, "")
	_ = updateCmd.Flags().MarkHidden("offer")
	updateCmd.Flags().String("confirmed", "", "")
	_ = updateCmd.Flags().MarkHidden("confirmed")
	rootCmd.AddCommand(updateCmd)
}

var updateCmd = &cobra.Command{
	Use:         "update",
	Annotations: map[string]string{dockerAnnotation: "yes"},
	Short:       "Update this cyfr to the newest release, then the CYFR in this directory to it",
	Long: `Update this program to the newest release, then the CYFR in the current directory to the program's release, in one command.

The program: when the newest release is newer than this one, cyfr update installs it. The newest is the newest published release that is not a pre-release and, while none is published, the newest pre-release. A Homebrew cask install is updated through brew. Where the CYFR app is installed, whichever cyfr runs this, the app is updated by its own installer: its installer for this machine is downloaded and verified against the release's checksums.txt signed by the release workflow for that tag, then the elevation it needs is asked for, then the running app is closed (on the box's own screen, the screen's service is stopped), then the system's installer replaces it (apt for the DEB, the whole signed app for macOS, Windows Installer for the MSI), then the release its own cyfr answers is checked, and the app is opened again as it was. A cyfr installed any other way replaces its own file, once the release's archive for this platform verifies the same way; both downloads verify before anything changes. A refusal at any step leaves the app working at its release and the CYFR in the directory untouched. It then goes on as the new program. --version names the exact release to install instead, a pre-release or an older release included; a Homebrew install takes only its tap's release. A development build is not replaced. In a directory that holds no compose file the update stops here.

The CYFR in the directory: first, at a terminal or with --yes, where .env names at CYFR_LOCUS_KVM or CYFR_LOCUS_TUN a device this machine does not have, cyfr update empties both and says so, before anything else and whatever it is then answered or refused, since every start of the stack refuses such a line; taking the devices away removes nothing. Then, after steps 1 and 2 below, cyfr update shows what changes and asks to make the change (--yes makes it without asking; with no terminal and no --yes it shows the change and makes none; answered no, it changes nothing and exits 0). A CYFR whose docker-compose.yml names this release already is not switched again, with no stop and no snapshot: its devices are written to .env as step 6 writes them, said first as step 2 says them, and where that first gives the Locus services both devices the update shows it and asks first, as it asks of a change; its stack is started as 'cyfr up' starts it and waited for whole, as step 6 waits, so an update run again after one whose services did not come up waits again; and a CYFR on a newer release than this cyfr, by its compose file's tags or by the release its cyfr reports (steps 3 and 4), is refused before the snapshot, since its database may not run under older code. A CYFR whose database another schema built is refused before the question and before the stack's lock, so the refusal changes nothing (step 2): a release runs only on a database its own schema built, the schema fingerprint its manifest carries, and there is no upgrade path between schemas. The change is one ceremony that changes nothing until the old stack is stopped and a snapshot of it is taken:

1. Fetch the release's signed manifest (release.json) and verify it; a manifest that does not verify, one without a schema fingerprint (any release's before the fingerprint was carried), or no network access to it, refuses.
2. Read docker-compose.yml, which the release's own replaces at the switch (step 6). It must hold the bundled stack: a service named cyfr and a service, under any name, whose image is ghcr.io/cyfrworks/cyfr-locus; one without either refuses, naming 'cyfr init --force'. The offer names each managed image that changes, by its repository, and each image line that names no managed image (ghcr.io/cyfrworks/cyfr, ghcr.io/cyfrworks/cyfr-locus, the bundled Caddy or the bundled Tailscale), which the release's file does not keep, and, where this machine has both devices and .env does not name both (step 6), that the first start that runs each person's programs in a computer of their own removes the folder each program keeps, with its sign-in, or, where .env names both and this machine no longer has them, that a program whose folder was made in a person's own computer does not start until it has them again. Then read the schema fingerprint and the release of the cyfr that runs this CYFR, through the running cyfr or, when cyfr is stopped, offline in a one-off container of its image that mounts nothing, skips its entrypoint, has no network and never pulls, and refuse a fingerprint other than the manifest's, a release newer than this one or an answer that does not read. Then compare docker-compose.yml with the one that release shipped, read from its verified scaffold, the image lines aside: a file you changed is said before anything stops, its differing lines (at most 12, no value of an environment line), that going on writes the release's file and the snapshot keeps yours, and, in a sentence of its own, each managed service whose volumes differ, since the stack would start without the data the folders you mount there hold. The update then asks 'Replace docker-compose.yml with release <version>'s and update this CYFR?', the answer defaulting to no; --yes does not answer it, and with no terminal to ask on the update refuses with the same words. Nothing of your file is merged into the release's.
3. While the stack still runs: read its configuration, naming the storage root it snapshots, fetch and verify the release's scaffold files (guides, WIT definitions, the seccomp profiles, the shipped Aqua prompts, its .env.example and its docker-compose.yml) without writing them, pull every image the release's docker-compose.yml manages by the manifest's digest, then read the cluster's roster, refusing a running cyfr on a newer release than this one and refusing while a server outside this stack holds a live slot on another release than this one (a host of the cluster already updated stays). A restore that has not finished (CYFR_RESTORE_INCOMPLETE in .env) refuses. Then, on Ubuntu 26.04 with AppArmor on, where the kernel has not loaded the AppArmor profile built into this cyfr, by its name, which carries its content, offer it as 'cyfr init' does, before anything is changed: declined, the stack runs on as it was.
4. Cancel a tailnet join that waits for approval, then stop every service, timing each, and re-read the roster offline until no slot of another release than this one is live (at most one lease); one still live, or an image on a newer release than this one, restarts the old stack and refuses.
5. Snapshot the database, the local storage root, every scaffold file the release manages as it stands, the keyring, .env and docker-compose.yml as it stands into backups/<UTC timestamp>/, snapshot.json last.
6. Write the release's scaffold files and change .env by the .env.example the release this CYFR ran shipped and this release's, both read from the releases' verified scaffolds (the install's own .env.example is the one 'cyfr init' laid down, which no update replaces): remove each setting the old one shipped that the new one no longer declares, the names said (a setting the old .env.example never shipped is yours and stays); set each line that holds the old one's shipped value, where the new one ships another, to the new value, the names and values said; and name, leaving them as you set them, the lines that name as a host a service of the old release's docker-compose.yml that this release's does not run, in any form (a URL, a host and port, a list of them or of id=URL items), by key, line in .env as the update leaves it and the service named, never the value, with the edit that puts in that service's place the host this release's shipped value for the name names (set or commented in its .env.example), in the line or in its URL, keeping the rest of the line, or the advice to name a service it runs, and that CYFR cannot reach that host until each such line is changed and 'cyfr up' is run. A setting assigned more than once is yours: none of its lines changes, and it is named with its lines. No other value you set changes, and a CYFR on no release version changes none. Then write the release's docker-compose.yml in place of the project's, its managed image lines pinned to <image>:<version>@<digest> (Caddy and Tailscale keep their tags), and say once that the file it replaced, with any edits of yours, is the snapshot's compose part; a failure of any puts the scaffold files and .env back from the snapshot and starts the old stack again under its own file. Then name the release's AppArmor profile in .env (CYFR_LOCUS_APPARMOR) and write there the devices a person's computer of their own runs through as this machine had them when the update began, the ones its offer showed (CYFR_LOCUS_KVM and CYFR_LOCUS_TUN: /dev/kvm and /dev/net/tun where it has both, both empty where it lacks either), which the snapshot holds as it stood, and start the stack as every cyfr start runs, waiting for cyfr's health, then, under the head that start read, for every service of the stack it started, within one deadline 150 s on: healthy where it has a health check, running where it has none. A failure from here leaves the stack stopped and prints the services that did not come up with 'docker compose logs <service>', the refusal a service's boot logged, its '[Name] FATAL:' line, the snapshot and the restore command; old code never starts over migrated data. Once the stack is up, the profile .env named before is taken off the machine, through the sudo login the offer asked for, or its removal command is printed.

The update holds the stack's lock from before its first docker call to its end, after finishing a change an interrupted command left; every docker call it makes runs under that lock. Exit status 3: the update is done and the new release started, but on this machine only, because the tailnet machine is not ready to serve it (not the one .env names, not joined, or HTTPS off); the message says what to do. An interrupt before the stop changes nothing. From the stop until the switch, the running step finishes and the update ends as that step's failure would; an update killed in that time leaves the start of the old stack to the next cyfr command that takes the lock, which says so. Once the switch begins, the switch and the start run to their end, so the stack is never left half-switched; an interrupt then is reported, not acted on.`,
	GroupID: "server",
	Example: "  cyfr update\n  cyfr update --yes\n  cyfr update --version 0.6.0-alpha.1",
	RunE: func(cmd *cobra.Command, args []string) error {
		var o updateOptions
		o.version, _ = cmd.Flags().GetString("version")
		o.yes, _ = cmd.Flags().GetBool("yes")
		o.continueAs, _ = cmd.Flags().GetString("continue-as")
		o.offer, _ = cmd.Flags().GetBool("offer")
		o.confirmed, _ = cmd.Flags().GetString("confirmed")
		o.noInteractive = flagNoInteractive
		return runUpdate(cmd.Context(), cmd.OutOrStdout(), cmd.ErrOrStderr(), o)
	},
}

// The release's manifest and the scaffold files, each a package variable so
// tests substitute them; production calls the verified release fetch and
// the checksum-verified scaffold fetch. Only a build tagged releaseproof
// (release_proof.go) points them elsewhere.
var (
	fetchManifest = release.FetchManifest
	fetchScaffold = fetchVerifiedScaffold
	// updateNow names the snapshot directory and stamps snapshot.json.
	updateNow = time.Now
	// liveSlotsWindow bounds the offline re-read, measured from the end of
	// the stop step: one lease (15 s), within which a member killed past its
	// grace lets its row lapse, and 5 s of slack. liveSlotsPoll spaces the
	// attempts after the first.
	liveSlotsWindow = 20 * time.Second
	liveSlotsPoll   = time.Second
	// stackHealthWindow bounds the wait for every service of the started
	// stack, measured from cyfr's health: the shipped compose file's
	// slowest health check to call a service unhealthy, start_period and
	// retries × (interval + timeout), is tailscale's 20 s + 3 × 35 s, and
	// 25 s of slack (TestStackHealthWindowCoversTheShippedHealthChecks).
	// stackHealthPoll spaces the reads.
	stackHealthWindow = 150 * time.Second
	stackHealthPoll   = time.Second
)

const (
	// rosterExpr reads the running cell's live slots through its own node,
	// beside that node's name, so a slot of another node is a member outside
	// this stack.
	rosterExpr = `{:ok, rows} = Arca.ControlPlane.roster(); IO.puts("CYFR_ROSTER=" <> JSON.encode!(%{self: Atom.to_string(node()), release: Prima.Version.current(), slots: Enum.map(rows, fn r -> %{node: r.node, owner: r.owner, release: r.release, lease_until: DateTime.to_iso8601(r.lease_until)} end)}))`
	// liveSlotsExpr reads the live slots offline, in a container of the old
	// image with nothing of the stack running; Cyfr.Release.live_slots/0
	// raises on any error, so an answer is a read.
	liveSlotsExpr = `IO.puts("CYFR_LIVE_SLOTS=" <> JSON.encode!(%{release: Prima.Version.current(), slots: Cyfr.Release.live_slots()}))`
	// schemaExpr reads the schema fingerprint of the cyfr code that runs
	// this CYFR's database, through the running node or offline in a
	// container of its image, and that code's release; a cyfr boots only on
	// a database its own fingerprint built, so the code's answer is the
	// database's.
	schemaExpr = `IO.puts("CYFR_SCHEMA=" <> Arca.SchemaFingerprint.current()); IO.puts("CYFR_RELEASE=" <> Prima.Version.current())`

	// pgProbeMajor is the major of the client image the server's major is
	// read with (pgClientImages); the dump and the restore then run in the
	// server's own major.
	pgProbeMajor = 18
	// pgURLVariable is the shell variable a postgres container reads the
	// database URL into from its standard input, so the URL is on no argv
	// and in no environment outside the container's shell.
	pgURLVariable = "CYFR_UPDATE_PG_URL"

	pullTimeout       = 30 * time.Minute
	composeRunTimeout = 2 * time.Minute
	stopTimeout       = 10 * time.Minute
	dumpTimeout       = 60 * time.Minute
	// startHealth bounds the wait for cyfr's health in an update's and a
	// restore's start: a release's migrations run in that start.
	startHealth = 900 * time.Second

	// appWorkdir is the cyfr image's WORKDIR, against which the server
	// expands a relative path setting.
	appWorkdir = "/app"
)

// fetchVerifiedScaffold is the release's scaffold verified against its
// signed checksums.txt (scaffold.Fetch).
func fetchVerifiedScaffold(version string) (scaffoldRelease, error) {
	r, err := scaffold.Fetch(version)
	if err != nil {
		return nil, err
	}
	return r, nil
}

// stopOrder is the order the stop step stops services in: the proxies
// first, then cyfr, then locus before the guard whose network namespace it
// shares. A running service it does not name is stopped with the rest
// after them, so a stack of other names stops whole.
var stopOrder = []string{"caddy", "tailscale", "cyfr", "locus", "locus-guard"}

// managedRepositories are the repositories the release's manifest carries a
// digest for, normalized as Docker normalizes a reference.
var managedRepositories = []string{release.RepoCyfr, release.RepoCyfrLocus, release.RepoCaddy, release.RepoTailscale}

var manifestDigest = regexp.MustCompile(`^sha256:[0-9a-f]{64}$`)

// pgClientImages are the PostgreSQL client images the update and the
// restore run, given the database URL on the host's network, by the server
// major each serves: every one pinned by digest, never a tag a registry
// may move, and a server major not named here is refused before anything
// changes (errPostgresMajorUnpinned). They are the supported PostgreSQL
// majors' current releases, 18 the one CI's PostgreSQL service runs;
// TestPostgresClientImagesArePinned holds the table to that shape and to
// CI's service image.
var pgClientImages = map[int]string{
	14: "postgres:14.24@sha256:14bfab572eec6abf65892e1db7c3ba8d41b2a2855c1b143664907d6e146eb6e1",
	15: "postgres:15.19@sha256:c961aa287d8698297cb26cdfadfbe9fd2cbaf77e53cfffe9636e8d8a1e4d842c",
	16: "postgres:16.15@sha256:ca0bd484cb98bf4b24eb1010e73fb3fcbd6714d240fbc1a10eea5b7dbecb641d",
	17: "postgres:17.11@sha256:2d2b8998d31037bf721cfdf764d76ba74171b4fab3431b7f72c27c56ddbdf9e3",
	18: "postgres:18.6@sha256:74935e72241653ca55e0414067e6d8763aceb8a810eb51b452253ec3dcfc4336",
}

// errPostgresMajorUnpinned is the refusal of a PostgreSQL server whose
// major no pinned client image serves.
type errPostgresMajorUnpinned struct{ major int }

func (e errPostgresMajorUnpinned) Error() string {
	majors := slices.Sorted(maps.Keys(pgClientImages))
	names := make([]string, len(majors))
	for i, m := range majors {
		names[i] = strconv.Itoa(m)
	}
	return fmt.Sprintf("the PostgreSQL server is version %d, and this cyfr pins a client image for PostgreSQL %s only; a cyfr release that pins one for %d is needed ('cyfr update')", e.major, strings.Join(names, ", "), e.major)
}

// pgClientImage is the pinned client image of the server major `major`.
func pgClientImage(major int) (string, error) {
	if image, ok := pgClientImages[major]; ok {
		return image, nil
	}
	return "", errPostgresMajorUnpinned{major}
}

// stackLacks names what of the bundled stack a compose file's services
// lack: a service named cyfr, and a service, under any name, whose image is
// the managed Locus repository as written; none when it has both. Other
// names are the release's own file's to choose.
func stackLacks(services *yaml.Node) []string {
	var lacks []string
	if mapValue(services, "cyfr") == nil {
		lacks = append(lacks, "a service named cyfr")
	}
	for i := 1; i < len(services.Content); i += 2 {
		node := serviceImage(services.Content[i], 0)
		if node == nil || node.Kind != yaml.ScalarNode {
			continue
		}
		if repository, _, _ := splitImageReference(node.Value); repository != "" && normalizeRepository(repository) == release.RepoCyfrLocus {
			return lacks
		}
	}
	return append(lacks, "a service running "+release.RepoCyfrLocus)
}

// errUpdateInterrupted is the refusal of an update a signal ended before
// anything stopped; once the compose file is read, the refusal says what
// it is now (composeAsRead).
var errUpdateInterrupted = errors.New("cyfr update was interrupted before anything stopped; it changed nothing and the running stack was not touched")

// runUpdate is `cyfr update` in the working directory: the program step
// (updateProgram), which hands the rest over to the program it installs,
// then, in a directory that holds a compose file, the home step
// (runHomeUpdate). The compose file is the mark of a home, the one
// `cyfr down` reads (access.HasComposeFile): the stack is started from it,
// whether `cyfr init` wrote it or a source checkout holds it. The program
// a handover starts is told the release it must be (o.continueAs) and
// skips the program step.
func runUpdate(ctx context.Context, out, errOut io.Writer, o updateOptions) error {
	if ctx == nil {
		ctx = context.Background()
	}
	switch {
	case o.offer || o.confirmed != "":
		// The CYFR app's second yes, and its offer, are the stack's alone,
		// at this program's release: the program and the app are never
		// touched. The confirmed change holds cyfr update's lock to its
		// end, so the app reads that an update runs from that lock alone
		// (windowUpdateRuns).
		if o.version != version.Version {
			return fmt.Errorf("This cyfr is release %s, not release %s, which the CYFR app's Update CYFR named; nothing was changed. Open Update CYFR in the app again", version.Version, o.version)
		}
		if o.confirmed != "" {
			unlock, err := lockUpdate()
			if err != nil {
				return err
			}
			defer unlock()
		}
	case o.continueAs == "":
		finished, err := updateProgram(ctx, out, o)
		if err != nil && ctx.Err() == nil {
			// A refusal of the program step leaves no device setting the
			// stack refuses to start with (emptyStrayDevices), as the home
			// step's own refusals do; an interrupt changes nothing.
			if _, emptyErr := emptyStrayDevices(out, o, machineDevices()); emptyErr != nil {
				return errors.Join(err, emptyErr)
			}
		}
		if finished || err != nil {
			return err
		}
	case o.continueAs != version.Version:
		self, _ := selfExecutable()
		return fmt.Errorf("The cyfr at %s is %s, not release %s that cyfr update installed; your CYFR was not touched. Run 'cyfr update' again", self, version.Version, o.continueAs)
	}
	// The CYFR app's first yes updates the app alone, wherever it runs:
	// its run is the one whose output is the update's record
	// (beginWindowUpdate), and its second yes, the stack's, is confirmed.
	if o.confirmed == "" && !o.offer && writesTheRecord(out) {
		fmt.Fprintf(out, "The CYFR app is release %s; Update CYFR offers your CYFR's own update, where this computer has one, now that the app has opened again.\n", version.Version)
		return nil
	}
	if !access.HasComposeFile(".") {
		fmt.Fprintf(out, "There is no CYFR in this directory, so the update ends with the program: it holds no compose file (%s). To update a CYFR, run 'cyfr update' in its directory, the one that holds its docker-compose.yml.\n", strings.Join(access.ComposeMainFiles, ", "))
		return nil
	}
	return runHomeUpdate(ctx, out, errOut, o)
}

// runHomeUpdate is `cyfr update`'s home step in the working directory: the
// manifest verified and the compose file planned, both read-only, then the
// offer (updater.offer), then the ceremony under the stack's lock. ctx is
// cancelled by SIGINT, SIGTERM or SIGHUP (Main's signal context): before
// the stop step the cancellation aborts the update with nothing changed;
// from the stop step on, every step runs under a context detached from it,
// and until the switch the update ends after the running step as that
// step's failure would. The switch and the start are one step that is
// never cut short: an interrupt during it is reported once the start has
// answered.
func runHomeUpdate(ctx context.Context, out, errOut io.Writer, o updateOptions) error {
	// The machine's devices are read once, for the whole update. Before
	// any refusal and before the question, a device setting the stack would
	// be refused with is emptied, and said (emptyStrayDevices).
	have := machineDevices()
	emptied, err := emptyStrayDevices(out, o, have)
	if err != nil {
		return err
	}
	v := version.Version
	if !release.IsVersion(v) {
		return errors.New("This cyfr is a development build, which has no signed release to install; run 'cyfr update' with a released cyfr")
	}
	u := &updater{ctx: ctx, command: "update", version: v, out: out, errOut: errOut, devices: have, emptied: emptied}
	if err := u.fetchManifest(); err != nil {
		return err
	}
	plan, err := planCompose("docker-compose.yml", u.manifest, u.version)
	if err != nil {
		return err
	}
	u.compose = plan
	if _, err := exec.LookPath("docker"); err != nil {
		return errors.New("cyfr update needs docker on PATH to update the stack; nothing was changed")
	}
	if o.offer {
		return u.showChange()
	}
	if plan.onRelease() {
		// Only an update gives the Locus services the devices first, and it
		// asks first, as an offered update does; the CYFR app's confirmed
		// change is made only as its offer read it.
		on, _ := u.devicesTurn()
		if on || o.confirmed != "" {
			if done, err := u.offer(o.yes, o.confirmed); done || err != nil {
				return err
			}
		}
		return u.upOnRelease(on)
	}
	if done, err := u.offer(o.yes, o.confirmed); done || err != nil {
		return err
	}

	// The lock an up, a restore and an access change hold too, taken before
	// any docker call and held to the update's end, so no start runs while
	// the stack is stopped for its snapshot. A change an interrupted
	// command left is finished first; one recovery could not finish leaves
	// the stack in no known state, and the update does nothing.
	e, unlock, receipts, err := openLocked(ctx, "update", out)
	if err != nil {
		return err
	}
	defer unlock()
	if err := refuseUnfinished(receipts); err != nil {
		return err
	}
	// The change confirmed is the one shown: a compose file another
	// command rewrote before the lock is planned afresh by a new update.
	if now, err := os.ReadFile(plan.path); err != nil || !bytes.Equal(now, plan.original) {
		return errors.New("docker-compose.yml changed after cyfr update showed what it changes; nothing was changed. Run 'cyfr update' again")
	}
	head, err := e.Head()
	if err != nil {
		return engineFailure(err)
	}
	u.engine, u.head = e, head
	return u.run()
}

// upOnRelease is the update of a home whose compose file names this
// release's digests already: nothing to switch, no stop and no snapshot,
// but its devices are written as this machine has them (u.devices) and its
// stack is started as 'cyfr up' starts it and waited for whole (up), so an
// update run again after one whose services did not come up waits again.
// offered says the offer said what it does, the devices it first gives
// among it (change); otherwise it is said here, and where the devices go,
// that too.
func (u *updater) upOnRelease(offered bool) error {
	if !offered {
		fmt.Fprintf(u.out, "This CYFR is on release %s already, so there is nothing to switch; cyfr update starts it and waits for every service of its stack.\n", u.version)
		if _, off := u.devicesTurn(); off {
			fmt.Fprintln(u.out, devicesGone("update"))
		}
	}
	if err := refuseUndeclaredRestore(); err != nil {
		return err
	}
	if err := ensureAppArmor(u.ctx, u.out, "cyfr update"); err != nil {
		return err
	}
	e, unlock, receipts, err := openLocked(u.ctx, "update", u.out)
	if err != nil {
		return err
	}
	defer unlock()
	if err := refuseUnfinished(receipts); err != nil {
		return err
	}
	// The devices are this machine's as the update read them (u.devices),
	// written under the stack's lock, as the switch writes them.
	if values, err := access.ReadEnvValues(".env"); err == nil {
		if set := deviceEdits(values, u.devices); len(set) > 0 {
			if err := access.EditEnvFile(".env", set, nil); err != nil {
				return fmt.Errorf("Writing this machine's devices in .env failed (%v); nothing was started", err)
			}
		}
	}
	head, err := e.Head()
	if err != nil {
		return engineFailure(err)
	}
	u.engine, u.head = e, head
	if err := u.up(); err != nil {
		return fmt.Errorf("Release %s did not come up (%v); the stack is left as it started. 'cyfr restore backups/<timestamp>' puts back a snapshot an earlier update took", u.version, err)
	}
	fmt.Fprintf(u.out, "Release %s is up.\n", u.version)
	return u.servedLocally
}

// scaffoldRelease is a release's scaffold fetched and verified, nothing of
// it written (scaffold.Release).
type scaffoldRelease interface {
	Managed() []string
	Check() error
	Write(overwriteManaged bool) error
	File(name string) ([]byte, bool)
}

// updater carries one update's state from step to step.
type updater struct {
	ctx context.Context
	// command is the command the reads and the snapshot run for, update or
	// backup, as their refusals name it.
	command     string
	version     string
	out, errOut io.Writer
	// engine holds the stack's lock and runs every docker call of the
	// update; head is .env's access head, whose selection every compose
	// call of the update runs with, own beside it.
	engine stackEngine
	head   access.Head
	// own are the profiles of the stack's running services that no access
	// mode selects, as an older release ran its builds under a profile
	// .env's head no longer names, learnt from the stack itself
	// (listRunning); beside are those services. Until the compose file in
	// place changes, every compose call runs under the head and own, and a
	// start starts beside again after the head's services.
	own, beside []string
	// redaction is the engine's redaction pass for what the update says of
	// its docker calls (access.Redactor): .env's values, and the values held
	// from the effective environment, written only into the snapshot.
	redaction *access.Redactor

	manifest *release.Manifest
	compose  *composePlan
	config   *stackConfig
	running  []string
	// stopTimes are the stop step's durations, in the order stopped.
	stopTimes []serviceStop
	// oldRelease is the old stack's version, as its image answers it.
	oldRelease string
	// leaving is the release the schema read's cyfr answers before the
	// offer, and left its verified scaffold, whose docker-compose.yml tells
	// a person's changes apart (composeEdits) and whose .env.example planEnv
	// reads when the stopped image answers the same release.
	leaving  string
	left     scaffoldRelease
	snapshot string
	// scaffold is the release's scaffold, written only after the snapshot
	// holds every file of it that it manages.
	scaffold scaffoldRelease
	// retired are the settings .env loses at the switch, defaults the
	// lines that held the old release's shipped value and take the new
	// one's, stale the lines the person set that name a service the
	// release no longer runs and twice the names assigned more than once
	// that either would have changed, both reported and left (planEnv);
	// envChanged is
	// whether the switch changed .env, so a revert puts .env back from the
	// snapshot.
	retired    []string
	defaults   map[string]string
	stale      []staleLine
	twice      []twiceLine
	envChanged bool
	// oldAppArmor is the AppArmor profile .env named before the switch,
	// which the machine loses once the release runs (retireAppArmor).
	oldAppArmor string
	// devices are the device settings the update writes, as this machine
	// gave them when the update began (machineDevices): the ones its offer
	// shows and its confirmation holds, never read again at the write.
	devices map[string]string
	// emptied says the update emptied device settings this machine does
	// not have before it asked anything (emptyStrayDevices), so an update
	// that ends unmade changed that and nothing else.
	emptied bool
	// offlineEnv are the settings each offline eval sets in its one-off
	// container: a restore's lifts its own bar (restoreBarrier).
	offlineEnv []string
	// servedLocally is the new release's start that left the home on this
	// machine alone (startedLocally), reported once the update is.
	servedLocally error
}

type serviceStop struct {
	service string
	took    time.Duration
}

// run is the ceremony, from the pre-stop reads to the report, under the
// stack's lock, with the manifest and the compose plan in hand.
func (u *updater) run() error {
	// Every step before the stop runs under ctx and changes no deployment
	// state, so an interrupt or a failure here leaves the stack running on
	// the compose file and the scaffold files as they were.
	steps := []func() error{u.readConfig, u.placeDatabase, u.probePostgres, u.fetchScaffold, u.pull, u.readRoster}
	for _, step := range steps {
		if err := step(); err != nil {
			if u.ctx.Err() != nil {
				return fmt.Errorf("%w; %s", errUpdateInterrupted, u.composeAsRead())
			}
			return err
		}
		if u.ctx.Err() != nil {
			return fmt.Errorf("%w; %s", errUpdateInterrupted, u.composeAsRead())
		}
	}

	// The release's profile is offered before anything is changed, so a
	// person who declines it keeps the running stack and its release; sudo's
	// login, once asked, is kept for the removal of the profile it replaces.
	held, err := offerAppArmor(u.ctx, u.out, "cyfr update")
	if held {
		defer machine.forget()
	}
	if err != nil {
		return err
	}
	// A join waiting for approval would enrol the machine while the stack
	// is down for the update, so it is cancelled first.
	if err := u.engine.CancelWaitingJoin(u.ctx); err != nil {
		return fmt.Errorf("cyfr update could not cancel the tailnet join waiting for approval (%v); the running stack was not touched, and %s", engineFailure(err), u.composeAsRead())
	}
	// A running stack's stop is recorded first, so an update killed before
	// the switch leaves the next cyfr command the start it owes. Every exit
	// of the update itself closes the hold: a start of the old stack does,
	// and an exit that leaves the stack stopped on purpose releases it.
	if len(u.running) > 0 {
		if err := u.engine.Hold("update"); err != nil {
			return fmt.Errorf("cyfr update could not record that it stops the running stack (%v); the running stack was not touched, and %s", engineFailure(err), u.composeAsRead())
		}
	}

	// From here on every child runs detached from ctx: the running step
	// finishes, and an interrupt ends the update at the next boundary.
	if err := u.stop(); err != nil {
		return u.restartOld(err)
	}
	if u.ctx.Err() != nil {
		return u.restartOld(errors.New("cyfr update was interrupted during the stop"))
	}
	if err := u.rereadOffline(); err != nil {
		return u.restartOld(err)
	}
	if u.ctx.Err() != nil {
		return u.restartOld(errors.New("cyfr update was interrupted during the offline roster read"))
	}
	if err := u.planEnv(); err != nil {
		return u.restartOld(err)
	}
	if err := u.takeSnapshot(u.oldRelease, u.scaffold.Managed()); err != nil {
		where := "no snapshot directory was made"
		if u.snapshot != "" {
			where = "the partial snapshot is " + u.snapshot
		}
		if unreleased := u.leaveStopped(); unreleased != "" {
			return fmt.Errorf("The snapshot failed: %v.\n%s; %s; %s. Fix the cause and run 'cyfr update' again", u.redactor().Text(err.Error()), unreleased, u.composeAsRead(), where)
		}
		return fmt.Errorf("The snapshot failed: %v.\nThe stack is left stopped and %s; %s. Fix the cause and run 'cyfr update' again, or start the old stack with 'cyfr up'", u.redactor().Text(err.Error()), u.composeAsRead(), where)
	}
	if u.ctx.Err() != nil {
		return u.restartOld(fmt.Errorf("cyfr update was interrupted during the snapshot (complete at %s)", u.snapshot))
	}
	newCompose, _ := u.scaffold.File("docker-compose.yml")
	if err := u.removeContainers(newCompose, "release "+u.version); err != nil {
		return u.restartOld(err)
	}
	if err := u.removeNetworks(newCompose, "release "+u.version); err != nil {
		return u.restartOld(err)
	}
	// From the switch on the old stack never starts over a database the
	// new release may have migrated, so no recovery may start it: the hold
	// is released first.
	if err := u.engine.Release(); err != nil {
		return u.restartOld(fmt.Errorf("cyfr update could not release its record of the stop (%v)", engineFailure(err)))
	}
	// The scaffold files and the compose file are written only now, with
	// the snapshot holding both as they stood; a failure puts the scaffold
	// files back, so the old stack starts again under its own.
	if err := u.writeScaffold(); err != nil {
		return u.revertScaffold(err)
	}
	if err := u.switchCompose(); err != nil {
		return u.revertScaffold(err)
	}
	// From the switch every compose call is the new release's, under the
	// head alone: the old stack's own profiles leave with it.
	u.own, u.beside = nil, nil
	if err := u.up(); err != nil {
		return u.stopAfterSwitch(err)
	}
	retireAppArmor(u.out, u.oldAppArmor)
	u.report()
	if u.ctx.Err() != nil {
		fmt.Fprintln(u.out, "An interrupt arrived during the switch; the switch and the start ran to their end, so the stack is not left half-switched.")
	}
	return u.servedLocally
}

// fetchManifest fetches and verifies the release's manifest; any failure
// refuses before a docker call.
func (u *updater) fetchManifest() error {
	fmt.Fprintf(u.out, "Verifying the manifest of release %s...\n", u.version)
	m, err := fetchManifest(u.ctx, u.version)
	switch {
	case u.ctx.Err() != nil:
		return errUpdateInterrupted
	case errors.Is(err, release.ErrUnverified):
		return fmt.Errorf("The manifest of release %s did not verify (%v); nothing was changed", u.version, err)
	case err != nil:
		return fmt.Errorf("cyfr update needs network access to release %s's manifest: %v; nothing was changed", u.version, err)
	case m == nil || m.Version != u.version:
		return fmt.Errorf("The manifest of release %s did not verify (it names another version); nothing was changed", u.version)
	}
	for _, repo := range managedRepositories {
		if digest, _ := m.Digest(repo); !manifestDigest.MatchString(digest) {
			return fmt.Errorf("The manifest of release %s did not verify (no sha256 digest for %s); nothing was changed", u.version, repo)
		}
	}
	u.manifest = m
	return nil
}

// change is what the update changes, as offer shows it, read-only: none
// is the sentence for a home whose compose file names this release's
// digests on every managed line already; a home on a newer release than
// this cyfr is refused, since the update would start older code over a
// database the newer release migrated, and so are an .env every start
// refuses and a database another schema built. edits is what is said of
// a compose file the person changed (composeEdits), apart from text,
// since the update asks of it apart.
func (u *updater) change() (text, edits, none string, err error) {
	plan := u.compose
	on, off := u.devicesTurn()
	if plan.onRelease() {
		// The devices this update would first give are the one change to
		// such a home, asked as any change is; with none, only --offer
		// reads this: the run itself starts and waits on such a home with
		// no question (upOnRelease).
		if on {
			return fmt.Sprintf("This CYFR is on release %s already, so there is nothing to switch; cyfr update writes this machine's devices to .env, starts it and waits for every service of its stack.\n%s\n", u.version, devicesSignInAgain), "", "", nil
		}
		return "", "", fmt.Sprintf("This CYFR is on release %s already, so there is nothing to update; 'cyfr up' starts it if it is stopped.", u.version), nil
	}
	from := plan.homeRelease()
	if err := u.refuseNewer(from, "is on"); err != nil {
		return "", "", "", fmt.Errorf("%w. Nothing was changed", err)
	}
	// .env is refused as every start refuses it before its first docker
	// call, the schema read's included.
	if fileExists(".env") {
		if err := access.CheckEnvFile(".env"); err != nil {
			return "", "", "", engineFailure(err)
		}
	}
	if err := u.readSchema(); err != nil {
		return "", "", "", err
	}
	if err := u.refuseNewer(u.leaving, "runs"); err != nil {
		return "", "", "", fmt.Errorf("%w. Nothing was changed", err)
	}
	if edits, err = u.composeEdits(); err != nil {
		return "", "", "", err
	}

	var b strings.Builder
	if from != "" {
		fmt.Fprintf(&b, "\nThis CYFR is on release %s; this cyfr is release %s.\n", from, u.version)
	} else {
		fmt.Fprintf(&b, "\nThis CYFR's docker-compose.yml names no release (%s); this cyfr is release %s.\n", plan.cyfrImage(), u.version)
	}
	fmt.Fprintf(&b, "Updating it stops the stack, snapshots it into backups/, replaces docker-compose.yml with release %s's own, the snapshot keeping this one with any edits you made to it, and starts it. Its images change:\n", u.version)
	for _, change := range imageChanges(plan.managed) {
		fmt.Fprintf(&b, "  %s\n", change)
	}
	if len(plan.overrides) > 0 {
		fmt.Fprintf(&b, "Image lines cyfr update does not manage, which release %s's docker-compose.yml does not keep:\n", u.version)
		for _, line := range plan.overrides {
			fmt.Fprintf(&b, "  %s: %s\n", line.service, line.value)
		}
	}
	switch {
	case on:
		fmt.Fprintln(&b, devicesSignInAgain)
	case off:
		fmt.Fprintln(&b, devicesGone("update"))
	}
	fmt.Fprintf(&b, "Before it stops anything it checks that this CYFR's database was built from release %s's schema, since there is no upgrade path between schemas; once it has started the release, only the snapshot takes CYFR back. Read the release notes first: %s/tag/%s\n", u.version, releasesPage, u.version)
	return b.String(), edits, "", nil
}

// confirmation is what --confirmed names: the digest of the folder, the
// exact release, the compose file's bytes and the devices, .env's and this
// machine's (u.devices), as this update read them for the change it shows.
// A run confirmed with it makes the change only where it reads the same
// itself, so the change made is worked out from what the person was shown,
// a changed compose file's differences and the devices it gives or takes
// among it.
func (u *updater) confirmation() (string, error) {
	folder, err := os.Getwd()
	if err != nil {
		return "", fmt.Errorf("cyfr update could not tell which folder it runs in (%v); nothing was changed", err)
	}
	values, _ := access.ReadEnvValues(".env")
	parts := [][]byte{[]byte(folder), []byte(u.version), u.compose.original}
	for _, d := range vmDevices {
		parts = append(parts, []byte(values[d.env]), []byte(u.devices[d.env]))
	}
	h := sha256.New()
	for _, part := range parts {
		fmt.Fprintf(h, "%d\n", len(part))
		h.Write(part)
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

// shownChange is --offer's answer, its output's last line, in JSON: the
// change and its confirmation, or the sentence for a home with nothing to
// update.
type shownChange struct {
	Change       string `json:"change,omitempty"`
	Confirmation string `json:"confirmation,omitempty"`
	Current      string `json:"current,omitempty"`
	// OnRelease says the change is to a CYFR on this release already,
	// which switches nothing: its devices alone (change).
	OnRelease bool `json:"on_release,omitempty"`
}

// showChange prints the change as --offer answers it, making none, a
// changed compose file's differences in it; a refusal is its error, as
// the update's own would be.
func (u *updater) showChange() error {
	text, edits, none, err := u.change()
	if err != nil {
		return err
	}
	shown := shownChange{Change: text + edits, Current: none, OnRelease: none == "" && u.compose.onRelease()}
	if none == "" {
		if shown.Confirmation, err = u.confirmation(); err != nil {
			return err
		}
	}
	return json.NewEncoder(u.out).Encode(shown)
}

// changedSinceOffer refuses a change the CYFR app confirmed that is not the
// one its offer read.
const changedSinceOffer = "What updating this CYFR changes is not the change the CYFR app showed, so nothing was changed. Open Update CYFR in the app again to see the change as it is now"

// offer shows what the update changes and asks to make it, answering done
// when the update ends here (change): a change not confirmed is not made.
// yes makes the change without asking, but for a compose file the person
// changed (composeEdits), which is asked at a terminal or refused;
// confirmed, the confirmation the CYFR app's page showed the change with,
// its compose differences among it, makes it only where this update read
// what that offer read, so the change made is the one the person saw and
// answered there; with no terminal to ask on and neither, the change is
// shown and not made.
func (u *updater) offer(yes bool, confirmed string) (bool, error) {
	text, edits, none, err := u.change()
	if none != "" && confirmed != "" {
		// The CYFR app offers only a change: one confirmed where there is
		// none to make now is not the one it showed.
		return true, errors.New(changedSinceOffer)
	}
	if none != "" {
		fmt.Fprintln(u.out, none)
		return true, nil
	}
	if err != nil {
		return true, err
	}
	fmt.Fprint(u.out, text)
	if confirmed != "" {
		read, err := u.confirmation()
		if err != nil {
			return true, err
		}
		if read != confirmed {
			return true, errors.New(changedSinceOffer)
		}
		return false, nil
	}
	question := "Update this CYFR? (yes/no)"
	if edits != "" {
		// --yes answers the update, never the loss of a person's own
		// compose file: that is asked at a terminal or refused.
		fmt.Fprint(u.out, edits)
		if !askTerminal() {
			return true, fmt.Errorf("%s: docker-compose.yml is not the file release %s shipped, and there is no terminal to ask on whether to replace it; --yes does not answer this question. Run 'cyfr update' at a terminal", u.nothingChanged(), u.leaving)
		}
		question = fmt.Sprintf("Replace docker-compose.yml with release %s's and update this CYFR? (yes/no)", u.version)
	} else if yes {
		return false, nil
	}
	if !askTerminal() {
		return true, fmt.Errorf("%s: there is no terminal to confirm the update on. Run it again with --yes to make it, or at a terminal", u.nothingChanged())
	}
	// The question ends with an interrupt as the steps before the stop do,
	// and exits as an interrupted question does.
	a, err := ask(u.ctx, bufio.NewReader(askInput), u.out, question, "no")
	if err != nil {
		return true, interruption{errUpdateInterrupted}
	}
	if a = strings.ToLower(a); a != "yes" && a != "y" {
		if u.compose.onRelease() {
			fmt.Fprintf(u.out, "%s. Run cyfr update again when you want each person's programs in a computer of their own.\n", u.nothingChanged())
		} else {
			fmt.Fprintf(u.out, "%s. Run cyfr update again when you want this release.\n", u.nothingChanged())
		}
		return true, nil
	}
	return false, nil
}

// composeEditsShown bounds the differing lines composeEdits shows.
const composeEditsShown = 12

// composeEdits answers what the update says before it asks of a compose
// file that is not the one the release being left (u.leaving) shipped,
// its image lines aside: the lines that differ, bounded and with no
// environment value, that going on writes the release's file and the
// snapshot keeps the person's, and a sentence of its own when a managed
// service's volumes differ, since the release's file mounts only its own.
// "" when the file is the release's own. The release's file is its
// verified scaffold's, fetched and kept (u.left), which changes nothing.
func (u *updater) composeEdits() (string, error) {
	going := fmt.Sprintf("Going on writes release %s's docker-compose.yml in its place; the snapshot keeps yours, with your changes, for you to carry over by hand.\n", u.version)
	if !release.IsVersion(u.leaving) {
		return fmt.Sprintf("cyfr update cannot tell whether docker-compose.yml is the file a release shipped: the cyfr that runs this CYFR answers %q, which is no release.\n", u.leaving) + going, nil
	}
	left, err := fetchScaffold(u.leaving)
	if err != nil {
		return "", fmt.Errorf("cyfr update could not fetch the scaffold files of release %s, whose docker-compose.yml tells your changes to it apart (%v); nothing was stopped or changed", u.leaving, err)
	}
	shipped, ok := left.File("docker-compose.yml")
	if !ok {
		return "", fmt.Errorf("Release %s's scaffold carries no docker-compose.yml to tell your changes to it apart; nothing was stopped or changed", u.leaving)
	}
	u.left = left
	differ := composeDifference(shipped, u.compose.original)
	if len(differ) == 0 {
		return "", nil
	}
	var b strings.Builder
	fmt.Fprintf(&b, "docker-compose.yml is not the file release %s shipped: these lines differ, image lines aside (- the release's, + yours):\n", u.leaving)
	for i, line := range differ {
		if i == composeEditsShown {
			fmt.Fprintf(&b, "  … and %d more\n", len(differ)-i)
			break
		}
		fmt.Fprintf(&b, "  %s\n", line)
	}
	b.WriteString(going)
	if services := volumesDiffer(shipped, u.compose.original); len(services) > 0 {
		fmt.Fprintf(&b, "The differences change the volumes of %s: release %s's file mounts only its own, so the stack would start without the data the folders you mount there hold.\n", strings.Join(services, ", "), u.version)
	}
	return b.String(), nil
}

// composeImage is a compose file's image line, whose value composeDifference
// sets aside.
var composeImage = regexp.MustCompile(`^(\s*(?:-\s+)?image:).*$`)

// composeDifference answers the lines that differ between the release's
// compose file and the person's, image values aside, in order, the
// release's prefixed "- " and the person's "+ ", each environment value
// masked (maskEnvironment).
func composeDifference(shipped, mine []byte) []string {
	a, b := strings.Split(string(shipped), "\n"), strings.Split(string(mine), "\n")
	// Each line's key is read once: the table below compares every line of
	// one file with every line of the other.
	keys := func(lines []string) []string {
		out := make([]string, len(lines))
		for i, line := range lines {
			out[i] = composeImage.ReplaceAllString(line, "$1")
		}
		return out
	}
	ka, kb := keys(a), keys(b)
	if slices.Equal(ka, kb) {
		return nil
	}
	ma, mb := maskEnvironment(a), maskEnvironment(b)
	// The longest common subsequence of the lines, from the ends.
	lcs := make([][]int32, len(a)+1)
	for i := range lcs {
		lcs[i] = make([]int32, len(b)+1)
	}
	for i := len(a) - 1; i >= 0; i-- {
		for j := len(b) - 1; j >= 0; j-- {
			if ka[i] == kb[j] {
				lcs[i][j] = lcs[i+1][j+1] + 1
			} else {
				lcs[i][j] = max(lcs[i+1][j], lcs[i][j+1])
			}
		}
	}
	var out []string
	i, j := 0, 0
	for i < len(a) || j < len(b) {
		switch {
		case i < len(a) && j < len(b) && ka[i] == kb[j]:
			i, j = i+1, j+1
		case j < len(b) && (i == len(a) || lcs[i][j+1] >= lcs[i+1][j]):
			out = append(out, "+ "+mb[j])
			j++
		default:
			out = append(out, "- "+ma[i])
			i++
		}
	}
	return out
}

// envEntry is an environment line's name and the separator before its
// value: `- NAME=`, `NAME:`, `NAME=`.
var envEntry = regexp.MustCompile(`^(\s*(?:-\s+)?["']?[A-Za-z_][A-Za-z0-9_.-]*["']?\s*[=:])`)

// maskEnvironment answers lines with every value of an environment
// setting replaced by "…": each line of an `environment:` block, by its
// indentation, and an inline `environment:` mapping or list whole.
func maskEnvironment(lines []string) []string {
	out := slices.Clone(lines)
	block := -1
	for i, line := range lines {
		trimmed := strings.TrimSpace(line)
		indent := len(line) - len(strings.TrimLeft(line, " \t"))
		if block >= 0 {
			if trimmed == "" || strings.HasPrefix(trimmed, "#") {
				continue
			}
			if indent > block {
				if m := envEntry.FindString(line); m != "" {
					out[i] = m + "…"
				} else {
					out[i] = line[:indent] + "…"
				}
				continue
			}
			block = -1
		}
		if rest, ok := strings.CutPrefix(trimmed, "environment:"); ok {
			if strings.TrimSpace(rest) == "" {
				block = indent
			} else {
				out[i] = line[:indent] + "environment: …"
			}
		}
	}
	return out
}

// volumesDiffer answers the services of the person's compose file whose
// volumes, merge keys resolved, are not the release's: each a service the
// release's file ships or one whose image is managed.
func volumesDiffer(shipped, mine []byte) []string {
	services := func(data []byte) map[string]any {
		var doc struct {
			Services map[string]any `yaml:"services"`
		}
		_ = yaml.Unmarshal(data, &doc)
		return doc.Services
	}
	release, own := services(shipped), services(mine)
	field := func(svc any, key string) any {
		m, _ := svc.(map[string]any)
		return m[key]
	}
	var differ []string
	for name, svc := range own {
		image, _ := field(svc, "image").(string)
		repository, _, _ := splitImageReference(image)
		_, shipsIt := release[name]
		if !shipsIt && !slices.Contains(managedRepositories, normalizeRepository(repository)) {
			continue
		}
		if !reflect.DeepEqual(field(svc, "volumes"), field(release[name], "volumes")) {
			differ = append(differ, name)
		}
	}
	slices.Sort(differ)
	return differ
}

// refuseNewer refuses a home on release home, newer than this cyfr's:
// cyfr update never moves a home to an older release, since the older code
// would start over a database the newer one may have migrated. The compose
// file's tags (the offer), the running cyfr's roster and the image's own
// answer offline each say the release; how words the sentence ("is on",
// "runs"). A home release that is no release version is not compared.
func (u *updater) refuseNewer(home, how string) error {
	if !release.IsNewer(home, u.version) {
		return nil
	}
	return fmt.Errorf("This CYFR %s release %s, newer than this cyfr's %s, and cyfr update never moves a CYFR to an older release: the older code would start over a database %s may have migrated. To keep %s, run 'cyfr update' with a cyfr of %s or later; to go back to %s, restore a snapshot taken on it with 'cyfr restore backups/<timestamp>'", how, home, u.version, home, home, home, u.version)
}

// shortDigest shortens an image reference's sha256 digest to its first 12
// hex digits, for reading.
func shortDigest(ref string) string {
	if i := strings.Index(ref, "@sha256:"); i >= 0 && len(ref) > i+8+12 {
		return ref[:i+8+12] + "…"
	}
	return ref
}

// imageChanges answers each change of a managed image the switch makes, by
// image: its repository as the file writes it, then its reference before
// and after, each change once, in the order the file first names it. No
// service is named: the release's file may run the images under other
// names.
func imageChanges(managed []imageLine) []string {
	var changes []string
	for _, line := range managed {
		if line.value == line.replacement {
			continue
		}
		beside := func(ref string) string {
			return shortDigest(strings.TrimPrefix(strings.TrimPrefix(ref, line.repository), ":"))
		}
		change := line.repository + ": " + beside(line.value) + " → " + beside(line.replacement)
		if !slices.Contains(changes, change) {
			changes = append(changes, change)
		}
	}
	return changes
}

// ---- the compose file ------------------------------------------------------

// imageLine is one service's image as docker-compose.yml writes it.
type imageLine struct {
	service string
	value   string
	// node is the scalar holding the value, which an alias shares.
	node *yaml.Node
	// repository and tag as written, without the digest.
	repository, tag string
	// replacement is a managed line's new value.
	replacement string
}

// composePlan is the person's compose file as read, which the offer reads
// and the snapshot holds, and the release's own file the switch writes in
// its place.
type composePlan struct {
	path     string
	original []byte
	// managed are the person's managed image lines, each with the value the
	// release pins it to, and overrides the person's other image lines,
	// which the release's file does not keep.
	managed   []imageLine
	overrides []imageLine
	// release is the release's docker-compose.yml with its managed image
	// lines pinned to the manifest's digests, and pulls those images, each
	// repository as written once (pinRelease).
	release []byte
	pulls   []string
}

// planCompose reads the person's compose file and refuses one that lacks
// the bundled stack (stackLacks) before any docker call.
func planCompose(path string, m *release.Manifest, ver string) (*composePlan, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("cyfr update could not read %s (%v); nothing was changed. Run 'cyfr init --force' to regenerate it (.env is kept)", path, err)
	}
	var root yaml.Node
	if err := yaml.Unmarshal(data, &root); err != nil {
		return nil, fmt.Errorf("%s is not valid YAML (%v); nothing was changed", path, err)
	}
	if root.Kind != yaml.DocumentNode || len(root.Content) == 0 || mapValue(root.Content[0], "services") == nil {
		return nil, fmt.Errorf("%s has no services; nothing was changed. Run 'cyfr init --force' to regenerate it (.env is kept)", path)
	}
	services := mapValue(root.Content[0], "services")
	if services.Kind != yaml.MappingNode {
		return nil, fmt.Errorf("%s's services are not a mapping; nothing was changed", path)
	}
	if lacks := stackLacks(services); len(lacks) > 0 {
		return nil, fmt.Errorf("docker-compose.yml lacks the bundled stack's %s, so this project predates the stack; nothing was changed.\nRun 'cyfr init --force' to regenerate docker-compose.yml (.env is kept), then 'cyfr update' again.", strings.Join(lacks, " and "))
	}
	plan := &composePlan{path: path, original: data}
	plan.managed, plan.overrides, _ = imageLines(services, m, ver)
	return plan, nil
}

// imageLines reads a compose file's image lines: managed, each with the
// value the release pins it to, cyfr and cyfr-locus at the version and the
// manifest's digest, the bundled Caddy and Tailscale at their own tags and
// the digest; every other line an override; and the managed images to
// pull, each repository as written once, by the manifest's digest.
func imageLines(services *yaml.Node, m *release.Manifest, ver string) (managed, overrides []imageLine, pulls []string) {
	for i := 0; i+1 < len(services.Content); i += 2 {
		name, svc := services.Content[i].Value, services.Content[i+1]
		node := serviceImage(svc, 0)
		if node == nil {
			continue
		}
		line := imageLine{service: name, value: node.Value, node: node}
		if node.Kind != yaml.ScalarNode || strings.Contains(node.Value, "$") {
			overrides = append(overrides, line)
			continue
		}
		line.repository, line.tag, _ = splitImageReference(node.Value)
		repo := normalizeRepository(line.repository)
		if line.repository == "" || !slices.Contains(managedRepositories, repo) {
			overrides = append(overrides, line)
			continue
		}
		want, _ := m.Digest(repo)
		switch repo {
		case release.RepoCaddy, release.RepoTailscale:
			line.replacement = line.repository
			if line.tag != "" {
				line.replacement += ":" + line.tag
			}
			line.replacement += "@" + want
		default:
			line.replacement = line.repository + ":" + ver + "@" + want
		}
		managed = append(managed, line)
		if pull := line.repository + "@" + want; !slices.Contains(pulls, pull) {
			pulls = append(pulls, pull)
		}
	}
	return managed, overrides, pulls
}

// pinRelease answers the release's docker-compose.yml with every managed
// image line rewritten in place to the value imageLines pins it to, every
// other byte as the release ships it, and the images to pull.
func pinRelease(data []byte, m *release.Manifest, ver string) ([]byte, []string, error) {
	var root yaml.Node
	if err := yaml.Unmarshal(data, &root); err != nil {
		return nil, nil, err
	}
	if root.Kind != yaml.DocumentNode || len(root.Content) == 0 {
		return nil, nil, errors.New("it is empty")
	}
	services := mapValue(root.Content[0], "services")
	if services == nil || services.Kind != yaml.MappingNode {
		return nil, nil, errors.New("it has no services")
	}
	managed, _, pulls := imageLines(services, m, ver)
	type edit struct {
		start, end int
		text       string
	}
	var edits []edit
	rewritten := map[*yaml.Node]bool{}
	lines := lineStarts(data)
	for _, line := range managed {
		if rewritten[line.node] {
			continue
		}
		rewritten[line.node] = true
		start, end, err := scalarSpan(data, lines, line.node)
		if err != nil {
			return nil, nil, fmt.Errorf("%s's image on line %d: %v", line.service, line.node.Line, err)
		}
		edits = append(edits, edit{start, end, renderScalar(line.replacement, line.node.Style)})
	}
	slices.SortFunc(edits, func(a, b edit) int { return b.start - a.start })
	out := slices.Clone(data)
	for _, e := range edits {
		out = slices.Concat(out[:e.start], []byte(e.text), out[e.end:])
	}
	if err := checkRewrite(out, managed); err != nil {
		return nil, nil, err
	}
	return out, pulls, nil
}

// onRelease reports whether every managed image line names the release's
// digest already, as a switch to it wrote them.
func (p *composePlan) onRelease() bool {
	for _, line := range p.managed {
		if line.value != line.replacement {
			return false
		}
	}
	return len(p.managed) > 0
}

// homeRelease answers the release the compose file's managed image lines
// run CYFR at (sharedRelease).
func (p *composePlan) homeRelease() string {
	return sharedRelease(func(yield func(string, string) bool) {
		for _, line := range p.managed {
			if !yield(line.repository, line.tag) {
				return
			}
		}
	})
}

// sharedRelease is the release a compose file runs CYFR at, given its
// images as repository and tag: the one tag its cyfr images share where
// it is a release version, else "".
func sharedRelease(images iter.Seq2[string, string]) string {
	found := ""
	for repository, tag := range images {
		if normalizeRepository(repository) != release.RepoCyfr {
			continue
		}
		if !release.IsVersion(tag) || found != "" && tag != found {
			return ""
		}
		found = tag
	}
	return found
}

// cyfrImage answers the cyfr service's image as written, or the first
// managed line's when no service is named cyfr.
// serviceImage answers the image line of service as written, managed or
// an override, "" when the compose file names none.
func (p *composePlan) serviceImage(service string) string {
	for _, line := range append(slices.Clone(p.managed), p.overrides...) {
		if line.service == service {
			return line.value
		}
	}
	return ""
}

func (p *composePlan) cyfrImage() string {
	for _, line := range p.managed {
		if line.service == "cyfr" {
			return line.value
		}
	}
	if len(p.managed) > 0 {
		return p.managed[0].value
	}
	return "no managed image"
}

// serviceImage answers the node holding a service's image: its own `image`
// key, else one a merge key brings in, an alias resolved to the node it
// names. depth bounds a merge cycle.
func serviceImage(svc *yaml.Node, depth int) *yaml.Node {
	if svc != nil && svc.Kind == yaml.AliasNode {
		svc = svc.Alias
	}
	if svc == nil || svc.Kind != yaml.MappingNode || depth > 16 {
		return nil
	}
	if node := mapValue(svc, "image"); node != nil {
		if node.Kind == yaml.AliasNode {
			node = node.Alias
		}
		return node
	}
	merge := mapValue(svc, "<<")
	if merge == nil {
		return nil
	}
	sources := []*yaml.Node{merge}
	if merge.Kind == yaml.SequenceNode {
		sources = merge.Content
	}
	for _, source := range sources {
		if node := serviceImage(source, depth+1); node != nil {
			return node
		}
	}
	return nil
}

// splitImageReference splits an image reference into its repository as
// written, its tag and its digest, each empty when absent.
func splitImageReference(ref string) (repository, tag, digest string) {
	if i := strings.IndexByte(ref, '@'); i >= 0 {
		ref, digest = ref[:i], ref[i+1:]
	}
	if i := strings.LastIndexByte(ref, ':'); i > strings.LastIndexByte(ref, '/') {
		ref, tag = ref[:i], ref[i+1:]
	}
	return ref, tag, digest
}

// normalizeRepository spells a repository as Docker resolves it: a first
// component that is no registry host (no `.` or `:`, not `localhost`, all
// lower case) puts it on docker.io, and a docker.io repository of one
// component is under library/.
func normalizeRepository(repository string) string {
	host, rest, found := strings.Cut(repository, "/")
	if !found || !strings.ContainsAny(host, ".:") && host != "localhost" && strings.ToLower(host) == host {
		host, rest = "docker.io", repository
	}
	if host == "index.docker.io" {
		host = "docker.io"
	}
	if host == "docker.io" && !strings.Contains(rest, "/") {
		rest = "library/" + rest
	}
	return host + "/" + rest
}

// lineStarts answers the byte offset each line of data starts at.
func lineStarts(data []byte) []int {
	starts := []int{0}
	for i, b := range data {
		if b == '\n' {
			starts = append(starts, i+1)
		}
	}
	return starts
}

// scalarSpan answers the bytes of data that spell node: from its position
// (yaml.v3 counts columns in characters), past an anchor or a tag, to the
// end of the scalar as its style writes it. A scalar it cannot find there
// exactly as one line is refused.
func scalarSpan(data []byte, lines []int, node *yaml.Node) (int, int, error) {
	if node.Line < 1 || node.Line > len(lines) || node.Column < 1 {
		return 0, 0, errors.New("no position")
	}
	i := lines[node.Line-1]
	for n := 1; n < node.Column; n++ {
		if i >= len(data) || data[i] == '\n' {
			return 0, 0, errors.New("position past the line")
		}
		_, size := utf8.DecodeRune(data[i:])
		i += size
	}
	for i < len(data) && (data[i] == '&' || data[i] == '!') {
		for i < len(data) && data[i] != ' ' && data[i] != '\t' && data[i] != '\n' {
			i++
		}
		for i < len(data) && (data[i] == ' ' || data[i] == '\t') {
			i++
		}
	}
	var spelled string
	switch node.Style &^ yaml.TaggedStyle {
	case 0:
		spelled = node.Value
	case yaml.SingleQuotedStyle:
		spelled = "'" + strings.ReplaceAll(node.Value, "'", "''") + "'"
	case yaml.DoubleQuotedStyle:
		if strings.ContainsAny(node.Value, `"\`) {
			return 0, 0, errors.New("an escaped double-quoted scalar")
		}
		spelled = `"` + node.Value + `"`
	default:
		return 0, 0, errors.New("a block scalar")
	}
	end := i + len(spelled)
	if strings.Contains(spelled, "\n") || end > len(data) || string(data[i:end]) != spelled {
		return 0, 0, errors.New("the scalar is not spelled on one line as it reads")
	}
	if end < len(data) && !strings.ContainsRune(" \t\r\n,]}#", rune(data[end])) {
		return 0, 0, errors.New("the scalar does not end where it reads")
	}
	return i, end, nil
}

// renderScalar spells value in the style the line it replaces used.
func renderScalar(value string, style yaml.Style) string {
	switch style &^ yaml.TaggedStyle {
	case yaml.SingleQuotedStyle:
		return "'" + value + "'"
	case yaml.DoubleQuotedStyle:
		return `"` + value + `"`
	}
	return value
}

// checkRewrite reads the rewritten file back and refuses it unless every
// managed service's image reads as its replacement.
func checkRewrite(data []byte, managed []imageLine) error {
	var root yaml.Node
	if err := yaml.Unmarshal(data, &root); err != nil {
		return err
	}
	services := mapValue(root.Content[0], "services")
	for _, line := range managed {
		node := serviceImage(mapValue(services, line.service), 0)
		if node == nil || node.Value != line.replacement {
			return fmt.Errorf("%s's image does not read back as %s", line.service, line.replacement)
		}
	}
	return nil
}

// ---- docker ------------------------------------------------------------------

// offlineEval answers the compose arguments that run expr through
// `bin/cyfr eval` in a one-off cyfr container with nothing of the stack
// running, each of offlineEnv set in it.
func (u *updater) offlineEval(ctx context.Context, expr string) ([]string, error) {
	args := []string{"run", "--rm", "--no-deps", "-T"}
	for _, setting := range u.offlineEnv {
		args = append(args, "-e", setting)
	}
	return u.composeArgs(ctx, append(args, "cyfr", "bin/cyfr", "eval", expr)...)
}

// composeArgs answers the arguments of the compose command args under the
// update's head and the stack's own profiles (own): the engine's complete
// selection of project, files, directory and profiles
// (access.Engine.ComposeArgs).
func (u *updater) composeArgs(ctx context.Context, args ...string) ([]string, error) {
	h := u.head
	if len(u.own) > 0 {
		h.Profiles = slices.Concat(h.Profiles, u.own)
	}
	return u.engine.ComposeArgs(ctx, h, args...)
}

// docker runs one docker call through the engine's runner under ctx, held
// to ctx's deadline, stdin on its standard input, its stdout into stdout
// (cyfr's own when nil) and its stderr into cyfr's, what reaches cyfr's
// own streams redacted a line at a time.
func (u *updater) docker(ctx context.Context, stdin io.Reader, stdout io.Writer, args ...string) error {
	return u.dockerRemoving(ctx, "", stdin, stdout, args...)
}

// dockerRemoving is docker for a call whose container, named remove, must
// not outlive it (access.Call.RemoveOnEnd); "" for none.
func (u *updater) dockerRemoving(ctx context.Context, remove string, stdin io.Reader, stdout io.Writer, args ...string) error {
	errOut := u.redactor().Writer(u.errOut)
	defer errOut.Flush()
	switch {
	case stdout != nil:
	case sameWriter(u.out, u.errOut):
		// One writer behind both, as exec gives a child's two streams one.
		stdout = errOut
	default:
		out := u.redactor().Writer(u.out)
		defer out.Flush()
		stdout = out
	}
	res, err := u.engine.Docker().Run(ctx, access.Call{Args: args, Deadline: callDeadline(ctx), Stdin: stdin, Stdout: stdout, Stderr: errOut, RemoveOnEnd: remove})
	return callFailure(u.redactor(), res, err)
}

// sameWriter reports whether a and b are one writer, as os/exec asks of a
// child's streams; writers it cannot compare are two.
func sameWriter(a, b io.Writer) (same bool) {
	defer func() { recover() }()
	return a == b
}

// composeDocker runs the compose command args under the update's head as
// docker does.
func (u *updater) composeDocker(ctx context.Context, args ...string) error {
	full, err := u.composeArgs(ctx, args...)
	if err != nil {
		return err
	}
	return u.docker(ctx, nil, nil, full...)
}

// dockerOutput runs docker as docker does and answers its stdout; its
// stderr is echoed after the run, redacted.
func (u *updater) dockerOutput(ctx context.Context, stdin io.Reader, args ...string) (string, error) {
	res, err := u.engine.Docker().Run(ctx, access.Call{Args: args, Deadline: callDeadline(ctx), Stdin: stdin})
	if len(res.Stderr) > 0 {
		io.WriteString(u.errOut, u.redactor().Text(string(res.Stderr)))
	}
	return string(res.Stdout), callFailure(u.redactor(), res, err)
}

// composeOutput runs the compose command args under the update's head as
// dockerOutput does.
func (u *updater) composeOutput(ctx context.Context, args ...string) (string, error) {
	full, err := u.composeArgs(ctx, args...)
	if err != nil {
		return "", err
	}
	return u.dockerOutput(ctx, nil, full...)
}

// callDeadline is the deadline a docker call is held to, the one its step's
// context carries: the engine's watchdog ends the call there even when
// cyfr itself is gone.
func callDeadline(ctx context.Context) time.Duration {
	if deadline, ok := ctx.Deadline(); ok {
		return time.Until(deadline)
	}
	return composeRunTimeout
}

// callFailure is a docker call's failure: the runner's error, redacted, or
// the exit status the call ended with.
func callFailure(redactor *access.Redactor, res access.Result, err error) error {
	if err != nil {
		return redactor.Err(err)
	}
	if res.ExitCode != 0 {
		return fmt.Errorf("exit status %d", res.ExitCode)
	}
	return nil
}

// pgURLInput is the standard input a postgres container's shell reads the
// database URL from (pgURLVariable), one line before anything the call
// itself reads.
func pgURLInput(url string) io.Reader {
	return strings.NewReader(url + "\n")
}

// pgReadURL begins a postgres container's shell script: the URL read from
// standard input into pgURLVariable.
const pgReadURL = `IFS= read -r ` + pgURLVariable + ` && `

// redactor is the update's redaction pass, the engine's own for the
// project, taken from the engine at first use.
func (u *updater) redactor() *access.Redactor {
	if u.redaction == nil {
		if u.engine != nil {
			u.redaction = u.engine.Redactor()
		} else {
			u.redaction = access.NewRedactor(".")
		}
	}
	return u.redaction
}

// detached answers a context for a step from the stop on: free of the
// interrupt, bounded by timeout.
func (u *updater) detached(timeout time.Duration) (context.Context, context.CancelFunc) {
	return context.WithTimeout(context.WithoutCancel(u.ctx), timeout)
}

// ---- preflight ----------------------------------------------------------------

// stackConfig is what the snapshot needs from cyfr's effective environment.
type stackConfig struct {
	adapter string // sqlite | postgres
	// image is the image the cyfr service runs and mounts every mount of
	// the service as resolved, through which a snapshot reads the storage
	// as the server sees it (readThroughStack): dbPath is the SQLite
	// database's container path, dbReal that path with its links
	// resolved (placeDatabase), dataPath the storage root's; state are
	// the container paths at which the mounts show the access engine's
	// state, which no snapshot holds.
	image                    string
	mounts                   []composeMount
	dbPath, dbReal, dataPath string
	state                    []string
	// pgURL is CYFR_DATABASE_URL; pgMajor the server's major version.
	pgURL   string
	pgMajor int
	storage string // local | s3
	// keyring is the snapshot's keyring file, dotenv lines.
	keyring string
}

// storageMount is one bind making up the storage root: rel is where it
// sits under the root (empty for the root itself), and host its resolved
// host path.
type storageMount struct {
	rel  string
	host string
}

// composeConfig is the part of `docker compose config --format json` the
// update reads.
type composeConfig struct {
	Services map[string]composeService `json:"services"`
	// Volumes, Secrets and Configs are the top-level declarations a
	// service's mounts name: a volume's name in the engine, and a secret's
	// or a config's file.
	Volumes map[string]struct {
		Name string `json:"name"`
	} `json:"volumes"`
	Secrets map[string]composeSource `json:"secrets"`
	Configs map[string]composeSource `json:"configs"`
}

// composeSource is a top-level secret or config: the file it is.
type composeSource struct {
	File string `json:"file"`
}

// resolve answers mounts as docker mounts them: a named volume by its
// name in the engine, an anonymous one as an empty tmpfs over its place,
// a secret or a config from a file as a bind of that file. A secret or a config compose makes from no file is left out: no
// snapshot reads it, since no SQLite database or storage root lies on
// anything but a bind (readConfig).
func (config composeConfig) resolve(mounts []composeMount) []composeMount {
	var out []composeMount
	for _, m := range mounts {
		switch m.Type {
		case "volume":
			if m.Source == "" {
				// An anonymous volume is the service's own, which docker
				// mounts read only for no one else: an empty read-only
				// tmpfs covers its place as it does.
				m = composeMount{Type: "tmpfs", Target: m.Target}
				break
			}
			if v, ok := config.Volumes[m.Source]; ok && v.Name != "" {
				m.Source = v.Name
			}
		case "secret", "config":
			declared := config.Secrets
			if m.Type == "config" {
				declared = config.Configs
			}
			file := declared[m.Source].File
			if file == "" {
				continue
			}
			m = composeMount{Type: "bind", Source: file, Target: m.Target}
		}
		out = append(out, m)
	}
	return out
}

// composeService is a service as `docker compose config --format json`
// writes it: its profiles, its environment, and every key that mounts
// something into its filesystem.
type composeService struct {
	Profiles    []string           `json:"profiles"`
	Image       string             `json:"image"`
	Environment map[string]*string `json:"environment"`
	Volumes     []composeMount     `json:"volumes"`
	// Tmpfs is a path or a list of them, each with its options after `:`.
	Tmpfs       json.RawMessage `json:"tmpfs"`
	Secrets     []composeFile   `json:"secrets"`
	Configs     []composeFile   `json:"configs"`
	VolumesFrom []string        `json:"volumes_from"`
}

// composeMount is one mount into a service's filesystem.
type composeMount struct {
	Type   string `json:"type"`
	Source string `json:"source"`
	Target string `json:"target"`
}

// composeFile is a secret or a config mounted into a service.
type composeFile struct {
	Source string `json:"source"`
	Target string `json:"target"`
}

// mounts answers every mount compose makes into svc: its volumes of every
// type, its tmpfs paths, and its secrets and configs at their targets.
// Another service's volumes (volumes_from) are not among them, since what
// those put where is not in the configuration: each caller refuses them
// first.
func (svc composeService) mounts() ([]composeMount, error) {
	mounts := slices.Clone(svc.Volumes)
	var tmpfs []string
	if len(svc.Tmpfs) > 0 && string(svc.Tmpfs) != "null" {
		var one string
		if err := json.Unmarshal(svc.Tmpfs, &one); err == nil {
			tmpfs = []string{one}
		} else if err := json.Unmarshal(svc.Tmpfs, &tmpfs); err != nil {
			return nil, errors.New("the cyfr service's tmpfs did not read; nothing was changed")
		}
	}
	for _, entry := range tmpfs {
		target, _, _ := strings.Cut(entry, ":")
		mounts = append(mounts, composeMount{Type: "tmpfs", Target: target})
	}
	for _, secret := range svc.Secrets {
		target := cmp.Or(secret.Target, secret.Source)
		if !path.IsAbs(target) {
			target = path.Join("/run/secrets", target)
		}
		mounts = append(mounts, composeMount{Type: "secret", Source: secret.Source, Target: target})
	}
	for _, config := range svc.Configs {
		target := cmp.Or(config.Target, config.Source)
		if !path.IsAbs(target) {
			target = "/" + target
		}
		mounts = append(mounts, composeMount{Type: "config", Source: config.Source, Target: target})
	}
	return mounts, nil
}

// readConfig reads cyfr's effective environment and mounts from compose and
// derives what the snapshot copies, refusing a setting it cannot snapshot.
func (u *updater) readConfig() error {
	ctx, cancel := context.WithTimeout(u.ctx, composeRunTimeout)
	defer cancel()
	raw, err := u.composeOutput(ctx, "config", "--format", "json")
	if err != nil {
		return fmt.Errorf("docker compose could not read the stack's configuration (%v); nothing was changed", err)
	}
	var config composeConfig
	if err := json.Unmarshal([]byte(raw), &config); err != nil {
		return errors.New("docker compose's configuration did not read as JSON; nothing was changed")
	}
	cyfr, ok := config.Services["cyfr"]
	if !ok {
		return errors.New("the stack's configuration has no cyfr service; nothing was changed")
	}
	if len(cyfr.VolumesFrom) > 0 {
		return fmt.Errorf("the cyfr service mounts the volumes of %s (volumes_from), which cyfr %s cannot place, so it cannot snapshot the storage root; nothing was changed", strings.Join(cyfr.VolumesFrom, ", "), u.command)
	}
	mounts, err := cyfr.mounts()
	if err != nil {
		return err
	}
	env := func(name string) string { return serviceSetting(cyfr.Environment, name) }
	if snapshot := env(restoreBarrier); snapshot != "" {
		return fmt.Errorf("A cyfr restore of %s has not finished (%s is set in .env), so CYFR may hold the snapshot's data undeclared; run 'cyfr restore %s' again before cyfr %s; nothing was changed", snapshot, restoreBarrier, snapshot, u.command)
	}
	containerToHost := func(p string) (string, bool) { return mountedHost(mounts, p) }
	c := &stackConfig{image: cyfr.Image, mounts: config.resolve(mounts)}
	// nestedMounts answers every mount whose target lies strictly under the
	// container path root, shallower first, refusing one that is not a bind:
	// its bytes are no host directory the snapshot can copy.
	nestedMounts := func(root string) ([]storageMount, error) {
		var nested []storageMount
		for _, n := range mountsUnder(mounts, root) {
			v, target := n.mount, path.Clean(n.mount.Target)
			if v.Type != "bind" || v.Source == "" {
				return nil, fmt.Errorf("The storage root %s has a %s mount at %s, which cyfr %s cannot snapshot; nothing was changed", root, v.Type, target, u.command)
			}
			nested = append(nested, storageMount{rel: n.rel, host: resolvedOr(v.Source)})
		}
		sortByDepth(nested)
		return nested, nil
	}
	settingPath := func(name, fallback string) (string, error) {
		value, ok := settingPathIn(cyfr.Environment, name, fallback)
		if !ok {
			return "", fmt.Errorf("%s is set but blank; nothing was changed", name)
		}
		return value, nil
	}

	dataPath, err := settingPath("CYFR_DATA_PATH", "data")
	if err != nil {
		return err
	}
	switch adapter := strings.ToLower(env("CYFR_DATABASE")); adapter {
	case "", "sqlite":
		c.adapter = "sqlite"
		dbPath, err := settingPath("CYFR_DATABASE_PATH", path.Join(dataPath, "cyfr.db"))
		if err != nil {
			return err
		}
		if _, ok := containerToHost(dbPath); !ok {
			return fmt.Errorf("The SQLite database %s is on no bind mount of the cyfr service, so cyfr %s cannot snapshot it; nothing was changed", dbPath, u.command)
		}
		c.dbPath = dbPath
	case "postgres":
		c.adapter = "postgres"
		if c.pgURL = env("CYFR_DATABASE_URL"); c.pgURL == "" {
			return fmt.Errorf("CYFR_DATABASE=postgres without CYFR_DATABASE_URL: cyfr %s has no database to snapshot; nothing was changed", u.command)
		}
		if strings.ContainsAny(c.pgURL, "\r\n") {
			return errors.New("CYFR_DATABASE_URL holds a line break, which no database URL holds; nothing was changed")
		}
		u.redactor().Hold(c.pgURL)
		if parsed, err := url.Parse(c.pgURL); err == nil && parsed.User != nil {
			if password, ok := parsed.User.Password(); ok {
				u.redactor().Hold(password)
			}
		}
	default:
		return fmt.Errorf("CYFR_DATABASE=%s is neither sqlite nor postgres; nothing was changed", adapter)
	}
	switch storage := strings.ToLower(env("CYFR_STORAGE")); storage {
	case "", "local":
		c.storage = "local"
		host, ok := containerToHost(dataPath)
		if !ok {
			return fmt.Errorf("The storage root %s is on no bind mount of the cyfr service, so cyfr %s cannot snapshot it; nothing was changed", dataPath, u.command)
		}
		c.dataPath = dataPath
		nested, err := nestedMounts(dataPath)
		if err != nil {
			return err
		}
		fmt.Fprintf(u.out, "Storage root %s is %s on the host.\n", dataPath, resolvedOr(host))
		for _, n := range nested {
			fmt.Fprintf(u.out, "  %s is %s on the host.\n", path.Join(dataPath, n.rel), n.host)
		}
	case "s3":
		c.storage = "s3"
	default:
		return fmt.Errorf("CYFR_STORAGE=%s is neither local nor s3; nothing was changed", storage)
	}

	// The keyring file is a dotenv file written by the engine's editor, so
	// access.ReadEnvValues reads each value back exactly.
	keyring := map[string]string{}
	for _, name := range keyringSettings {
		raw := cyfr.Environment[name]
		if raw == nil || strings.TrimSpace(*raw) == "" {
			continue
		}
		u.redactor().Hold(*raw)
		keyring[name] = *raw
	}
	if len(keyring) == 0 {
		return errors.New("Neither CYFR_CRYPTO_KEYRING nor CYFR_SECRET_KEY_BASE is set for cyfr, so a snapshot would hold no key to its data; nothing was changed")
	}
	keyringText, err := access.EditEnv(nil, keyring, nil)
	if err != nil {
		return engineFailure(err)
	}
	c.keyring = string(keyringText)
	if f, err := os.Open(".env"); err != nil {
		return fmt.Errorf("cyfr %s cannot read .env (%v), which the snapshot copies; nothing was changed", u.command, err)
	} else {
		f.Close()
	}
	if c.image == "" && (c.adapter == "sqlite" || c.storage == "local") {
		return fmt.Errorf("the cyfr service names no image, through which cyfr %s reads its storage; nothing was changed", u.command)
	}
	if project, err := os.Getwd(); err == nil {
		c.state = stateIn(c.mounts, resolvedOr(filepath.Join(project, ".cyfr")))
	}
	u.config = c
	return nil
}

// keyringSettings are the settings holding the keys to a cell's data, which
// the snapshot's keyring file carries.
var keyringSettings = []string{"CYFR_CRYPTO_KEYRING", "CYFR_SECRET_KEY_BASE"}

// s3OutsideSnapshot is the stated limit of a snapshot of a cell whose store
// is S3.
const s3OutsideSnapshot = "The object store (S3) is outside the snapshot; it relies on the bucket's own versioning."

// serviceSetting answers a service's environment setting, trimmed; empty
// when unset.
func serviceSetting(environment map[string]*string, name string) string {
	if value := environment[name]; value != nil {
		return strings.TrimSpace(*value)
	}
	return ""
}

// settingPathIn answers the container path a path setting names, fallback
// when it is unset, a relative one against the image's WORKDIR; ok is false
// for a setting that is set but blank.
func settingPathIn(environment map[string]*string, name, fallback string) (string, bool) {
	value := fallback
	if raw := environment[name]; raw != nil {
		if value = strings.TrimSpace(*raw); value == "" {
			return "", false
		}
	}
	if !path.IsAbs(value) {
		value = path.Join(appWorkdir, value)
	}
	return path.Clean(value), true
}

// mountedHost maps a container path through the mount whose target is its
// longest prefix, which is the one cyfr sees the path through; ok is false
// unless that mount is a bind.
func mountedHost(mounts []composeMount, p string) (string, bool) {
	m, rel, ok := holdingMount(mounts, p)
	if !ok {
		return "", false
	}
	return filepath.Join(m.Source, filepath.FromSlash(rel)), true
}

// holdingMount answers the bind cyfr sees the container path p through,
// the mount whose target is its longest prefix, and where p lies under its
// target; ok is false unless that mount is a bind.
func holdingMount(mounts []composeMount, p string) (composeMount, string, bool) {
	best, bind := -1, false
	var held composeMount
	var under string
	for _, v := range mounts {
		target := path.Clean(v.Target)
		rel, ok := strings.CutPrefix(p, target)
		if !ok || rel != "" && !strings.HasPrefix(rel, "/") && target != "/" {
			continue
		}
		switch isBind := v.Type == "bind" && v.Source != ""; {
		case len(target) > best:
			best, bind, held, under = len(target), isBind, v, rel
		case len(target) == best && !isBind:
			// Two mounts at one target: which one cyfr sees is not
			// the configuration's to say, so the path is not mapped.
			bind = false
		}
	}
	return held, under, best >= 0 && bind
}

// nestedMount is a mount whose target lies under a container path, rel
// being where under it.
type nestedMount struct {
	rel   string
	mount composeMount
}

// mountsUnder answers every mount whose target lies strictly under the
// container path root, in the configuration's order.
func mountsUnder(mounts []composeMount, root string) []nestedMount {
	var nested []nestedMount
	for _, v := range mounts {
		rel, ok := strings.CutPrefix(path.Clean(v.Target), strings.TrimSuffix(root, "/")+"/")
		if ok && rel != "" {
			nested = append(nested, nestedMount{rel: rel, mount: v})
		}
	}
	return nested
}

// sortByDepth orders storage mounts shallower before deeper, keeping the
// order of mounts of one depth.
func sortByDepth(mounts []storageMount) {
	slices.SortStableFunc(mounts, func(a, b storageMount) int {
		return strings.Count(a.rel, "/") - strings.Count(b.rel, "/")
	})
}

// probePostgres reads the PostgreSQL server's major version, which names
// the dump's image; the URL reaches the container on its standard input.
func (u *updater) probePostgres() error {
	if u.config.adapter != "postgres" {
		return nil
	}
	ctx, cancel := context.WithTimeout(u.ctx, composeRunTimeout)
	defer cancel()
	major, err := u.serverMajor(ctx)
	if errors.Is(err, errServerVersion) {
		return errors.New("the PostgreSQL server's version did not read as a number; nothing was changed")
	}
	if err != nil {
		return fmt.Errorf("cyfr %s could not reach the PostgreSQL server at CYFR_DATABASE_URL to read its version (%v); nothing was changed", u.command, err)
	}
	if _, err := pgClientImage(major); err != nil {
		return fmt.Errorf("cyfr %s refuses: %w; nothing was changed", u.command, err)
	}
	u.config.pgMajor = major
	return nil
}

// errServerVersion is serverMajor's answer when the server answered a
// version that does not read.
var errServerVersion = errors.New("the server's version does not read")

// serverMajor reads the major version of the PostgreSQL server at the
// configured URL through a postgres client container, the URL reaching it
// on its standard input.
func (u *updater) serverMajor(ctx context.Context) (int, error) {
	answer, err := u.dockerOutput(ctx, pgURLInput(u.config.pgURL),
		"run", "--rm", "-i", "--network", "host", pgClientImages[pgProbeMajor],
		"sh", "-c", pgReadURL+`exec psql "$`+pgURLVariable+`" -tAc "SHOW server_version_num"`)
	if err != nil {
		return 0, err
	}
	num, err := strconv.Atoi(strings.TrimSpace(answer))
	if err != nil || num < 10000 {
		return 0, errServerVersion
	}
	return num / 10000, nil
}

// pgImage is the dump's image, the pinned client of the server's own
// major, which the probe has refused unless pgClientImages names it.
func (u *updater) pgImage() string { return pgClientImages[u.config.pgMajor] }

// pull fetches every managed image by the manifest's digest, and the dump's
// image, before anything stops: a failure leaves the deployment as it was.
func (u *updater) pull() error {
	refs := slices.Clone(u.compose.pulls)
	if u.config.adapter == "postgres" {
		refs = append(refs, u.pgImage())
	}
	for _, ref := range refs {
		fmt.Fprintf(u.out, "Pulling %s...\n", ref)
		ctx, cancel := context.WithTimeout(u.ctx, pullTimeout)
		err := u.docker(ctx, nil, nil, "pull", ref)
		cancel()
		if err != nil {
			return fmt.Errorf("docker pull %s failed (%v); the running stack was not touched, and %s", ref, err, u.composeAsRead())
		}
		if u.ctx.Err() != nil {
			return errUpdateInterrupted
		}
	}
	return nil
}

// fetchScaffold fetches the release's scaffold, whose checksums the
// scaffold fetch verifies itself, and refuses a folder it writes in that is
// a link it does not follow (scaffold.ErrLinkNotFollowed) and a
// managed path that is there as something other than a regular file, which
// the snapshot cannot hold; both before the stack stops. It pins the
// release's docker-compose.yml, whose images the pull fetches and which
// the switch writes (pinRelease).
func (u *updater) fetchScaffold() error {
	r, err := fetchScaffold(u.version)
	if err != nil {
		return fmt.Errorf("Failed to fetch the scaffold files (%v); the running stack was not touched, and %s", err, u.composeAsRead())
	}
	if err := r.Check(); err != nil {
		return fmt.Errorf("%v; nothing was changed", err)
	}
	for _, name := range r.Managed() {
		if info, err := os.Lstat(name); err == nil && !info.Mode().IsRegular() {
			return fmt.Errorf("%s, a scaffold file cyfr update replaces, is not a regular file, so the snapshot cannot hold it; nothing was changed", name)
		}
	}
	compose, ok := r.File("docker-compose.yml")
	if !ok {
		return fmt.Errorf("Release %s's scaffold carries no docker-compose.yml; the running stack was not touched, and %s", u.version, u.composeAsRead())
	}
	pinned, pulls, err := pinRelease(compose, u.manifest, u.version)
	if err != nil {
		return fmt.Errorf("Release %s's docker-compose.yml could not be pinned to its manifest (%v); the running stack was not touched, and %s", u.version, err, u.composeAsRead())
	}
	u.scaffold, u.compose.release, u.compose.pulls = r, pinned, pulls
	return nil
}

// writeScaffold writes the release's scaffold files over the project's,
// then removes from .env the settings the release retired (planEnv).
func (u *updater) writeScaffold() error {
	if err := u.scaffold.Write(true); err != nil {
		return fmt.Errorf("Writing the scaffold files failed (%v)", err)
	}
	fmt.Fprintf(u.out, "Scaffold files updated (%s, wit/, aqua/).\n", strings.Join(scaffold.Guides, ", "))
	// The release's compose file names its profile through .env, which the
	// snapshot holds as it stood, for a revert to put back.
	held, err := access.ReadEnvValues(".env")
	if err != nil {
		return fmt.Errorf("Reading .env failed (%v)", err)
	}
	if u.oldAppArmor = held[appArmorEnv]; u.oldAppArmor != apparmor.ProfileName {
		u.envChanged = true
		if err := access.EditEnvFile(".env", map[string]string{appArmorEnv: apparmor.ProfileName}, nil); err != nil {
			return fmt.Errorf("Naming release %s's AppArmor profile in .env failed (%v)", u.version, err)
		}
	}
	// It names the devices as this machine had them when the update read
	// them (u.devices), which the snapshot holds as they stood too.
	if set := deviceEdits(held, u.devices); len(set) > 0 {
		u.envChanged = true
		if err := access.EditEnvFile(".env", set, nil); err != nil {
			return fmt.Errorf("Writing this machine's devices in .env failed (%v)", err)
		}
	}
	if len(u.retired) > 0 || len(u.defaults) > 0 {
		u.envChanged = true
		if err := access.EditEnvFile(".env", u.defaults, u.retired); err != nil {
			return fmt.Errorf("Changing the settings release %s ships in .env failed (%v)", u.version, err)
		}
	}
	if len(u.retired) > 0 {
		fmt.Fprintf(u.out, "Removed from .env the settings release %s shipped and release %s no longer reads: %s.\n",
			u.oldRelease, u.version, strings.Join(u.retired, ", "))
	}
	if len(u.defaults) > 0 {
		var set []string
		for _, name := range slices.Sorted(maps.Keys(u.defaults)) {
			set = append(set, name+"="+u.defaults[name])
		}
		fmt.Fprintf(u.out, "Set in .env to release %s's shipped values the settings that held release %s's: %s.\n",
			u.version, u.oldRelease, strings.Join(set, ", "))
	}
	if len(u.stale) == 0 && len(u.twice) == 0 {
		return nil
	}
	// The lines are said as .env holds them now: a line the edit removed
	// moves every line after it.
	text, err := os.ReadFile(".env")
	if err != nil {
		return fmt.Errorf("Reading .env failed (%v)", err)
	}
	lines, err := access.EnvLines(text)
	if err != nil {
		return fmt.Errorf("Reading .env failed (%v)", err)
	}
	if len(u.stale) > 0 {
		fmt.Fprintf(u.out, "These .env settings name a service release %s's docker-compose.yml no longer runs, and cyfr update left them as you set them:\n", u.version)
		var reached []string
		for _, line := range u.stale {
			at := lines[line.name][len(lines[line.name])-1]
			switch {
			case line.put != "" && line.url:
				fmt.Fprintf(u.out, "  %s, line %d, names %s: put %s in place of %s in its URL, keeping the rest of the line as it is\n", line.name, at, line.host, line.put, line.host)
			case line.put != "":
				fmt.Fprintf(u.out, "  %s, line %d, names %s: put %s in place of %s in that line, keeping the rest of it as it is\n", line.name, at, line.host, line.put, line.host)
			default:
				fmt.Fprintf(u.out, "  %s, line %d, names %s: name a service release %s's docker-compose.yml runs there\n", line.name, at, line.host, u.version)
			}
			if line.put != "" && !slices.Contains(reached, line.put) {
				reached = append(reached, line.put)
			}
		}
		if len(reached) > 0 {
			fmt.Fprintf(u.out, "Until each of these lines is changed so and 'cyfr up' is run, CYFR cannot reach %s.\n", strings.Join(reached, ", "))
		} else {
			fmt.Fprintln(u.out, "Until each of these lines names a service that runs and 'cyfr up' is run, CYFR reaches nothing through it.")
		}
	}
	if len(u.twice) > 0 {
		fmt.Fprintln(u.out, "These .env settings are assigned more than once, so they are yours and cyfr update changed none of their lines:")
		for _, line := range u.twice {
			numbers := make([]string, len(lines[line.name]))
			for i, n := range lines[line.name] {
				numbers[i] = strconv.Itoa(n)
			}
			at := strings.Join(numbers[:len(numbers)-1], ", ") + " and " + numbers[len(numbers)-1]
			if line.retired {
				fmt.Fprintf(u.out, "  %s, lines %s: release %s no longer reads it, so remove every line of it\n", line.name, at, u.version)
			} else {
				fmt.Fprintf(u.out, "  %s, lines %s: release %s ships %s=%s\n", line.name, at, u.version, line.name, line.write)
			}
		}
	}
	return nil
}

// envName is a setting's name as a .env.example declares it, set or
// commented out: a person may set a commented one.
var envName = regexp.MustCompile(`(?m)^[ \t]*#?[ \t]*(?:export[ \t]+)?([A-Za-z_][A-Za-z0-9_]*)=`)

// commentedExample is a .env.example's commented assignment, the
// assignment itself after the comment's mark.
var commentedExample = regexp.MustCompile(`(?m)^[ \t]*#[ \t]*((?:export[ \t]+)?[A-Za-z_][A-Za-z0-9_]*=.*)$`)

// commentedValues answers the values a .env.example's commented
// assignments would set, each read as the line alone would be once
// uncommented; a line that does not read so is prose and gives none.
func commentedValues(example []byte) map[string]string {
	values := map[string]string{}
	for _, m := range commentedExample.FindAllSubmatch(example, -1) {
		line, err := access.EnvValues([]byte(string(m[1]) + "\n"))
		if err != nil {
			continue
		}
		for name, value := range line {
			values[name] = value
		}
	}
	return values
}

func envNames(example []byte) map[string]bool {
	names := map[string]bool{}
	for _, m := range envName.FindAllSubmatch(example, -1) {
		names[string(m[1])] = true
	}
	return names
}

// planEnv plans .env's change at the switch from the .env.example the
// release this CYFR runs shipped and the new release's, both read from the
// releases' scaffolds, which their signed checksums verify. The install's
// own .env.example is no witness: `cyfr init` laid it down and no update
// replaces it (scaffold.IsManaged), so after one update it is not the
// release being left's. A CYFR on no release version, or on this one,
// gets no change. The two releases' compose files name the services a
// line may still name.
//
//   - A setting the old .env.example declared, set or commented, that the
//     new one no longer declares is removed, since the new server refuses
//     to boot on a name it does not read; a name the old .env.example never
//     shipped is the person's, kept whatever its value.
//   - A line holding exactly the value the old .env.example shipped, where
//     the new one ships another, is the release's and takes the new value;
//     a commented line ships no value.
//   - Any other line that names, as a host, a service of the old
//     release's docker-compose.yml that the new one does not run is the
//     person's: it is left, and reported with what to write there, the
//     new .env.example's value for it, set or commented.
//   - A name assigned more than once is the person's: none of its lines
//     changes, and one the rules above would change is reported.
func (u *updater) planEnv() error {
	if !release.IsVersion(u.oldRelease) || u.oldRelease == u.version {
		return nil
	}
	shipped := u.left
	if u.oldRelease != u.leaving || shipped == nil {
		var err error
		if shipped, err = fetchScaffold(u.oldRelease); err != nil {
			return fmt.Errorf("cyfr update could not fetch the scaffold files of release %s, which name the settings it shipped in .env.example (%v)", u.oldRelease, err)
		}
	}
	oldCompose, _ := shipped.File("docker-compose.yml")
	newCompose, _ := u.scaffold.File("docker-compose.yml")
	old, oldOK := shipped.File(".env.example")
	now, nowOK := u.scaffold.File(".env.example")
	if !oldOK || !nowOK {
		return nil
	}
	text, err := os.ReadFile(".env")
	if err != nil {
		return fmt.Errorf("cyfr update could not read .env (%v)", err)
	}
	held, err := access.EnvValues(text)
	if err != nil {
		return fmt.Errorf("cyfr update could not read .env (%v)", err)
	}
	lines, err := access.EnvLines(text)
	if err != nil {
		return fmt.Errorf("cyfr update could not read .env (%v)", err)
	}
	oldValues, err := access.EnvValues(old)
	if err != nil {
		return fmt.Errorf("release %s's .env.example did not read (%v)", u.oldRelease, err)
	}
	newValues, err := access.EnvValues(now)
	if err != nil {
		return fmt.Errorf("release %s's .env.example did not read (%v)", u.version, err)
	}
	declared := envNames(now)
	commented := commentedValues(now)
	gone := retiredNames(oldCompose, newCompose, "services")
	shippedOld := envNames(old)
	for _, name := range slices.Sorted(maps.Keys(held)) {
		value, at := held[name], lines[name]
		retired := shippedOld[name] && !declared[name]
		next, ships := newValues[name]
		shippedValue, shippedOK := oldValues[name]
		defaulted := shippedOK && value == shippedValue && ships && next != value
		if len(at) > 1 {
			// A name assigned more than once is the person's: the edit
			// would remove every line but its last.
			if retired || defaulted {
				u.twice = append(u.twice, twiceLine{name: name, retired: retired, write: next})
			}
			continue
		}
		switch {
		case retired:
			u.retired = append(u.retired, name)
			continue
		case defaulted:
			if u.defaults == nil {
				u.defaults = map[string]string{}
			}
			u.defaults[name] = next
			continue
		case shippedOK && value == shippedValue:
			continue
		}
		for _, host := range hostsIn(value) {
			if gone[host] {
				write, ships := newValues[name]
				if !ships {
					write = commented[name]
				}
				line := staleLine{name: name, host: host}
				if hosts := hostsIn(write); len(hosts) > 0 {
					line.put = hosts[0]
				}
				for _, item := range strings.FieldsFunc(value, func(r rune) bool { return r == ',' || r == ' ' || r == '\t' }) {
					if slices.Contains(hostsIn(item), host) && strings.Contains(item, "://") {
						line.url = true
					}
				}
				u.stale = append(u.stale, line)
				break
			}
		}
	}
	return nil
}

// staleLine is a .env line the person set that names a service the
// release no longer runs: its name, the service it names, the host the new
// release's shipped value for the name names in its place ("" when it
// ships none), and whether the line names the service in a URL, so the
// edit is said in a URL's terms. Its value is never said: a line that
// names a host may carry a credential.
type staleLine struct {
	name string
	host string
	put  string
	url  bool
}

// twiceLine is a name .env assigns more than once, which the update would
// otherwise have removed (retired) or set to the new release's shipped
// value (write), and leaves as the person wrote it.
type twiceLine struct {
	name    string
	retired bool
	write   string
}

// retiredNames answers the entries of a top-level section of the compose
// file old (its services) that the compose file now does not have, by
// name; none when either does not read.
func retiredNames(old, now []byte, section string) map[string]bool {
	names := func(data []byte) map[string]bool {
		var root yaml.Node
		if yaml.Unmarshal(data, &root) != nil || root.Kind != yaml.DocumentNode || len(root.Content) == 0 {
			return nil
		}
		entries := mapValue(root.Content[0], section)
		if entries == nil || entries.Kind != yaml.MappingNode {
			return nil
		}
		out := map[string]bool{}
		for i := 0; i < len(entries.Content); i += 2 {
			out[entries.Content[i].Value] = true
		}
		return out
	}
	before, after := names(old), names(now)
	if before == nil || after == nil {
		return nil
	}
	gone := map[string]bool{}
	for name := range before {
		if !after[name] {
			gone[name] = true
		}
	}
	return gone
}

// usedNetworks answers the networks the compose file data uses, by name:
// its top-level networks and default, which compose makes for every
// service that names no network, each service of a file without a networks
// key among them; nil when data does not read as a compose file.
func usedNetworks(data []byte) map[string]bool {
	var root yaml.Node
	if yaml.Unmarshal(data, &root) != nil || root.Kind != yaml.DocumentNode || len(root.Content) == 0 || root.Content[0].Kind != yaml.MappingNode {
		return nil
	}
	used := map[string]bool{"default": true}
	if entries := mapValue(root.Content[0], "networks"); entries != nil && entries.Kind == yaml.MappingNode {
		for i := 0; i < len(entries.Content); i += 2 {
			used[entries.Content[i].Value] = true
		}
	}
	return used
}

// declaredServices are the services the compose file data declares, by
// name; nil when data does not read as a compose file.
func declaredServices(data []byte) map[string]bool {
	var root yaml.Node
	if yaml.Unmarshal(data, &root) != nil || root.Kind != yaml.DocumentNode || len(root.Content) == 0 || root.Content[0].Kind != yaml.MappingNode {
		return nil
	}
	declared := map[string]bool{}
	if entries := mapValue(root.Content[0], "services"); entries != nil && entries.Kind == yaml.MappingNode {
		for i := 0; i < len(entries.Content); i += 2 {
			declared[entries.Content[i].Value] = true
		}
	}
	return declared
}

// removeContainers removes, with the stack stopped and before anything
// starts under the compose file to, each container of this compose
// project, listed by its compose labels and so never another project's,
// whose service to does not declare (declaredServices): a container that
// shares another's network namespace is on no network of its own, so the
// networks' removal (removeNetworks) never finds it. which names to in what
// is said. A to that does not read removes nothing.
func (u *updater) removeContainers(to []byte, which string) error {
	declared := declaredServices(to)
	if declared == nil {
		return nil
	}
	ctx, cancel := u.detached(stopTimeout)
	defer cancel()
	project := access.ProjectName(".")
	listed, err := u.dockerOutput(ctx, nil, "ps", "-a", "--no-trunc", "--format", `{{.ID}} {{.Label "com.docker.compose.service"}}`, "--filter", "label=com.docker.compose.project="+project)
	if err != nil {
		return fmt.Errorf("cyfr %s could not list this project's containers (%v)", u.command, err)
	}
	var ids, services []string
	for _, line := range strings.Split(listed, "\n") {
		if fields := strings.Fields(line); len(fields) == 2 && !declared[fields[1]] {
			ids = append(ids, fields[0])
			if !slices.Contains(services, fields[1]) {
				services = append(services, fields[1])
			}
		}
	}
	if len(ids) == 0 {
		return nil
	}
	slices.Sort(services)
	if _, err := u.dockerOutput(ctx, nil, append([]string{"rm"}, ids...)...); err != nil {
		return fmt.Errorf("cyfr %s could not remove this project's containers of %s, which %s does not run (%v)", u.command, strings.Join(services, ", "), which, err)
	}
	fmt.Fprintf(u.out, "Removed this project's containers of services %s does not run: %s.\n", which, strings.Join(services, ", "))
	return nil
}

// removeNetworks removes, with the stack stopped and before anything
// starts under the compose file to, each network of this compose project,
// listed by its compose labels and so never another project's, that to
// does not use (usedNetworks), since one may hold an address range a
// network of to takes; which names to in what is said. Each goes as its
// project's containers on it, stopped, which the next start makes again,
// then the network itself. A container of another project on it refuses,
// naming both, and nothing of that network is removed. A to that does not
// read removes nothing.
func (u *updater) removeNetworks(to []byte, which string) error {
	used := usedNetworks(to)
	if used == nil {
		return nil
	}
	ctx, cancel := u.detached(stopTimeout)
	defer cancel()
	project := access.ProjectName(".")
	listed, err := u.dockerOutput(ctx, nil, "network", "ls", "--format", `{{.ID}} {{.Label "com.docker.compose.network"}}`, "--filter", "label=com.docker.compose.project="+project)
	if err != nil {
		return fmt.Errorf("cyfr %s could not list this project's networks (%v)", u.command, err)
	}
	unused := map[string][]string{}
	for _, line := range strings.Split(listed, "\n") {
		if fields := strings.Fields(line); len(fields) == 2 && !used[fields[1]] {
			unused[fields[1]] = append(unused[fields[1]], fields[0])
		}
	}
	if len(unused) == 0 {
		return nil
	}
	names := slices.Sorted(maps.Keys(unused))
	failed := func(name string, why any) error {
		return fmt.Errorf("cyfr %s could not remove the network %s, which %s does not use (%v)", u.command, name, which, why)
	}
	for _, name := range names {
		for _, id := range unused[name] {
			attached, err := u.dockerOutput(ctx, nil, "ps", "-a", "-q", "--no-trunc", "--filter", "network="+id, "--filter", "label=com.docker.compose.project="+project)
			if err != nil {
				return failed(name, err)
			}
			all, err := u.dockerOutput(ctx, nil, "ps", "-a", "-q", "--no-trunc", "--filter", "network="+id)
			if err != nil {
				return failed(name, err)
			}
			for _, c := range strings.Fields(all) {
				if !slices.Contains(strings.Fields(attached), c) {
					return failed(name, "container "+shortID(c)+" of another Compose project is attached to it")
				}
			}
			if ours := strings.Fields(attached); len(ours) > 0 {
				if _, err := u.dockerOutput(ctx, nil, append([]string{"rm"}, ours...)...); err != nil {
					return failed(name, err)
				}
			}
			if _, err := u.dockerOutput(ctx, nil, "network", "rm", id); err != nil {
				return failed(name, err)
			}
		}
	}
	fmt.Fprintf(u.out, "Removed this project's networks %s does not use: %s.\n", which, strings.Join(names, ", "))
	return nil
}

// shortID is a container id as docker ps shows it, its first 12 digits.
func shortID(id string) string {
	return id[:min(len(id), 12)]
}

// hostsIn answers the hosts a setting's value names in any form it takes:
// each of its comma- or space-separated items, an `id=` before it set
// aside (a list of named URLs), read as [scheme://][userinfo@]host[:port]
// and whatever path, query or fragment follows.
func hostsIn(value string) []string {
	var hosts []string
	for _, item := range strings.FieldsFunc(value, func(r rune) bool { return r == ',' || r == ' ' || r == '\t' }) {
		if id, rest, ok := strings.Cut(item, "="); ok && envID.MatchString(id) {
			item = rest
		}
		if _, rest, ok := strings.Cut(item, "://"); ok {
			item = rest
		}
		if i := strings.IndexAny(item, "/?#"); i >= 0 {
			item = item[:i]
		}
		if i := strings.LastIndexByte(item, '@'); i >= 0 {
			item = item[i+1:]
		}
		host := item
		if strings.HasPrefix(host, "[") {
			host, _, _ = strings.Cut(host[1:], "]")
		} else {
			host, _, _ = strings.Cut(host, ":")
		}
		if host != "" {
			hosts = append(hosts, host)
		}
	}
	return hosts
}

// envID is the id of an `id=URL` item.
var envID = regexp.MustCompile(`^[A-Za-z0-9_.-]+$`)

// revertScaffold puts the scaffold files back from the snapshot after a
// failure before the start, then starts the old stack as restartOld does;
// scaffold files it cannot put back leave the stack stopped, since the old
// stack must not start under the new release's files.
func (u *updater) revertScaffold(reason error) error {
	if u.envChanged {
		data, err := os.ReadFile(filepath.Join(u.snapshot, ".env"))
		if err == nil {
			err = writeFileAtomic(".env", data, 0600)
		}
		if err != nil {
			return fmt.Errorf("%v.\n.env could not be put back from the snapshot (%v), so the stack is left stopped; restore the snapshot with:\n  cyfr restore %s", u.redactor().Text(reason.Error()), err, u.snapshot)
		}
	}
	if err := putScaffoldBack(u.snapshot, u.scaffold.Managed()); err != nil {
		return fmt.Errorf("%v.\nThe scaffold files could not be put back from the snapshot (%v), so the stack is left stopped; restore the snapshot with:\n  cyfr restore %s", u.redactor().Text(reason.Error()), err, u.snapshot)
	}
	return u.restartOld(fmt.Errorf("%v; the scaffold files were put back from the snapshot %s", reason, u.snapshot))
}

// readSchema reads the schema fingerprint of the cyfr that runs this
// CYFR and refuses one other than the release's: the release runs only on
// a database its own schema built, and there is no upgrade path between
// schemas. An answer that cannot be read refuses too, never reads as a
// match.
//
// It runs before the offer, the lock and everything the lock brings: the
// lock's state files, the recovery of an interrupted change (which can
// stop and start the stack) and the materialized configuration. So a
// refused update changes nothing at all, and the read itself is made so
// it changes nothing: plain docker calls outside the engine, finding the
// running cyfr by its compose labels, or, while it is stopped, a one-off
// container of its image that mounts nothing, skips the entrypoint's
// seeding and ownership steps, has no network and never pulls.
//
// The fingerprint read is the code's, not the one the database records:
// the two are one because a cyfr boots only on a database its own schema
// built (Arca.SchemaFingerprint.verify!/0 at every boot). They differ only
// for a CYFR whose image already does not boot on its database, which an
// update cannot make worse: its start fails, and stopAfterSwitch prints
// the boot's FATAL line.
func (u *updater) readSchema() error {
	ctx, cancel := context.WithTimeout(u.ctx, composeRunTimeout)
	defer cancel()
	output, err := readRunningSchema(ctx, u.compose.serviceImage("cyfr"))
	var schema string
	if err == nil {
		schema, err = markedLine(output, "CYFR_SCHEMA=")
	}
	if err == nil && !schemaFingerprint.MatchString(schema) {
		err = fmt.Errorf("the answer %q is not a schema fingerprint", schema)
	}
	if err != nil {
		// What docker says passes the engine's redaction, .env's values
		// blanked, before it is said: a diagnostic can quote them. The
		// engine opens under the lock, after this read.
		redaction := access.NewRedactor(".")
		if u.engine != nil {
			redaction = u.engine.Redactor()
		}
		err = redaction.Err(err)
		return fmt.Errorf("cyfr update could not read which schema this CYFR's database was built from (%v), and release %s runs only on a database built from its own schema; nothing was stopped or changed. Fix the cause and run 'cyfr update' again", err, u.version)
	}
	if schema != u.manifest.SchemaFingerprint {
		return fmt.Errorf("This CYFR's database was built from schema %s, and release %s runs only on a database built from schema %s: there is no upgrade path between them, so nothing was stopped or changed.\nTo start over on release %s, keeping nothing of this CYFR: run 'cyfr uninstall' here, then delete this directory by hand (with sudo: CYFR's container owns data/) and remove the volumes it names, then install release %s with: %s | CYFR_VERSION=%s sh", shortFingerprint(schema), u.version, shortFingerprint(u.manifest.SchemaFingerprint), u.version, u.version, installScript, u.version)
	}
	if u.leaving, err = markedLine(output, "CYFR_RELEASE="); err != nil {
		return fmt.Errorf("cyfr update could not read which release runs this CYFR (%v); nothing was stopped or changed. Fix the cause and run 'cyfr update' again", err)
	}
	return nil
}

// readRunningSchema answers schemaExpr's output from this directory's
// cyfr: through its running container, found by the compose project's
// labels, or, with none running, offline from image, the image its compose
// file names.
func readRunningSchema(ctx context.Context, image string) (string, error) {
	project := access.ProjectName(".")
	ids, err := schemaDocker(ctx, nil, "ps", "-q", "--filter", "label=com.docker.compose.project="+project, "--filter", "label=com.docker.compose.service=cyfr", "--filter", "status=running")
	if err != nil {
		return "", err
	}
	var output string
	switch running := strings.Fields(ids); {
	case len(running) > 1:
		return "", fmt.Errorf("%d cyfr containers of this directory run", len(running))
	case len(running) == 1:
		output, err = schemaDocker(ctx, nil, "exec", running[0], "bin/cyfr", "rpc", schemaExpr)
	case image == "":
		return "", errors.New("docker-compose.yml names no image for cyfr")
	default:
		// The release's runtime configuration needs a browser address and a
		// key base to load; the key is a throwaway, given through the
		// environment so it is on no argv.
		key := make([]byte, 48)
		if _, err := rand.Read(key); err != nil {
			return "", err
		}
		// The container is named, so it is removed by its name however the
		// read ends: a cancelled or timed-out docker client leaves the
		// container running. Its own timeout bounds it when cyfr dies
		// before it can remove it.
		name := schemaContainerName()
		defer removeSchemaContainer(name)
		output, err = schemaDocker(ctx, []string{"CYFR_SECRET_KEY_BASE=" + hex.EncodeToString(key)},
			"run", "--rm", "--name", name, "--pull", "never", "--network", "none", "--read-only", "--user", "app",
			"--entrypoint", "/usr/bin/timeout", "-e", "CYFR_BROWSER=none", "-e", "CYFR_SECRET_KEY_BASE",
			image, schemaReadLife, "/app/bin/cyfr", "eval", schemaExpr)
	}
	return output, err
}

// schemaReadLife bounds the offline read's container from inside, in
// seconds, within composeRunTimeout, the read's own bound.
const schemaReadLife = "90"

// schemaContainerName names one offline read's container; a variable so
// a test names it.
var schemaContainerName = func() string {
	b := make([]byte, 6)
	_, _ = rand.Read(b)
	return "cyfr-schema-read-" + hex.EncodeToString(b)
}

// removeSchemaContainer removes the offline read's container by name, on
// a context of its own so a cancelled read still removes it. One already
// gone, as --rm leaves a read that ended, is no failure.
func removeSchemaContainer(name string) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	_, _ = schemaDocker(ctx, nil, "rm", "-f", name)
}

// schemaDocker runs one docker call of the schema read with env added to
// its environment, answering its standard output; a failure carries
// docker's own last line. A variable so a test stands in for it.
var schemaDocker = func(ctx context.Context, env []string, args ...string) (string, error) {
	cmd := exec.CommandContext(ctx, "docker", args...)
	access.OwnProcessGroup(cmd)
	cmd.Env = append(os.Environ(), env...)
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	if err := cmd.Run(); err != nil {
		lines := strings.Split(strings.TrimSpace(stderr.String()), "\n")
		return "", fmt.Errorf("docker %s failed: %v: %s", args[0], err, lines[len(lines)-1])
	}
	return stdout.String(), nil
}

// schemaFingerprint is a schema fingerprint as Arca records it.
var schemaFingerprint = regexp.MustCompile(`^[0-9a-f]{64}$`)

// shortFingerprint shortens a schema fingerprint to its first 12 hex
// digits, for reading.
func shortFingerprint(fingerprint string) string {
	if len(fingerprint) > 12 {
		return fingerprint[:12] + "…"
	}
	return fingerprint
}

// rosterSlot is one live slot as the roster and the offline read answer it.
type rosterSlot struct {
	Node       string  `json:"node"`
	Owner      *string `json:"owner"`
	Release    string  `json:"release"`
	LeaseUntil string  `json:"lease_until"`
}

// markedLine answers the payload of the one line of output starting with
// marker; none or more than one is an error, never an empty answer.
func markedLine(output, marker string) (string, error) {
	var found []string
	for _, line := range strings.Split(output, "\n") {
		if rest, ok := strings.CutPrefix(strings.TrimRight(line, "\r"), marker); ok {
			found = append(found, rest)
		}
	}
	if len(found) != 1 {
		return "", fmt.Errorf("%d lines starting %s, want one", len(found), marker)
	}
	return found[0], nil
}

// readRoster reads the running cell's live slots through its own node and
// refuses while one belongs to a member outside this stack that runs
// another release than the target. A member already on the target release
// is a host of the cell updated before this one: it stays, and this stack
// joins it once switched.
func (u *updater) readRoster() error {
	ctx, cancel := context.WithTimeout(u.ctx, composeRunTimeout)
	defer cancel()
	if err := u.listRunning(ctx); err != nil {
		return err
	}
	if !slices.Contains(u.running, "cyfr") {
		return nil
	}
	output, err := u.composeOutput(ctx, "exec", "-T", "cyfr", "bin/cyfr", "rpc", rosterExpr)
	if err != nil {
		return fmt.Errorf("cyfr update could not read the cluster's roster through the running cyfr (%v); nothing was changed", err)
	}
	var answer struct {
		Self    string        `json:"self"`
		Release string        `json:"release"`
		Slots   *[]rosterSlot `json:"slots"`
	}
	payload, err := markedLine(output, "CYFR_ROSTER=")
	if err == nil {
		err = json.Unmarshal([]byte(payload), &answer)
	}
	if err == nil && (answer.Self == "" || answer.Slots == nil) {
		err = errors.New("no server name or no slots")
	}
	if err != nil {
		return fmt.Errorf("The cluster's roster did not read (%v); cyfr update reads no answer as an empty roster, and nothing was changed", err)
	}
	// The release the running cyfr reports holds the refusal whatever the
	// compose file's tags say (latest, or a set that differs).
	if err := u.refuseNewer(answer.Release, "runs"); err != nil {
		return fmt.Errorf("%w. Nothing was changed", err)
	}
	var foreign []string
	for _, slot := range *answer.Slots {
		if slot.Node != answer.Self && !u.onTarget(slot) {
			foreign = append(foreign, fmt.Sprintf("%s (release %s)", slot.Node, slot.Release))
		}
	}
	if len(foreign) > 0 {
		return fmt.Errorf("The cluster has a live server outside this stack on another release than %s: %s. cyfr update cannot stop it; stop it first, then run 'cyfr update' again. Nothing was changed", u.version, strings.Join(foreign, ", "))
	}
	return nil
}

// listRunning reads the stack's running services into u.running under the
// stack's own selection: the head and every profile of its own the compose
// file set declares (ownServices), since a compose file an older release
// left may run services under a profile .env's head does not name. The
// running services of its own are beside, and their profiles are own.
func (u *updater) listRunning(ctx context.Context) error {
	apart, wide, err := u.ownServices(ctx)
	if err != nil {
		return fmt.Errorf("%v; nothing was changed", err)
	}
	u.own, u.beside = wide, nil
	ps, err := u.composeOutput(ctx, "ps", "--services", "--status", "running")
	if err != nil {
		return fmt.Errorf("docker compose could not list the running services (%v); nothing was changed", err)
	}
	u.running = nil
	for _, line := range strings.Split(ps, "\n") {
		if name := strings.TrimSpace(line); name != "" && !slices.Contains(u.running, name) {
			u.running = append(u.running, name)
		}
	}
	u.own = nil
	for _, svc := range u.running {
		if profiles, ok := apart[svc]; ok {
			u.beside = append(u.beside, svc)
			u.own = append(u.own, profiles...)
		}
	}
	slices.Sort(u.own)
	u.own = slices.Compact(u.own)
	return nil
}

// ownServices answers, by name, the services of the stack's compose file
// set that run only under profiles of its own, which no browser address
// kind selects (DeclaredProfiles), as an older release ran its builds under
// one: none of them starts under .env's head. Each maps to those of its
// profiles; wide are every such profile the file set declares.
func (u *updater) ownServices(ctx context.Context) (apart map[string][]string, wide []string, err error) {
	declared, err := u.engine.DeclaredProfiles(ctx)
	if err != nil {
		return nil, nil, fmt.Errorf("docker compose could not list the stack's profiles (%v)", engineFailure(err))
	}
	wide = slices.DeleteFunc(declared, func(p string) bool { return slices.Contains(access.BrowserProfiles(), p) })
	if len(wide) == 0 {
		return nil, nil, nil
	}
	h := u.head
	h.Profiles = slices.Concat(h.Profiles, wide)
	args, err := u.engine.ComposeArgs(ctx, h, "config", "--format", "json")
	if err != nil {
		return nil, nil, fmt.Errorf("docker compose could not read the stack's configuration (%v)", engineFailure(err))
	}
	raw, err := u.dockerOutput(ctx, nil, args...)
	if err != nil {
		return nil, nil, fmt.Errorf("docker compose could not read the stack's configuration (%v)", err)
	}
	var config composeConfig
	if err := json.Unmarshal([]byte(raw), &config); err != nil {
		return nil, nil, errors.New("docker compose's configuration did not read as JSON")
	}
	apart = map[string][]string{}
	for name, svc := range config.Services {
		if slices.ContainsFunc(svc.Profiles, func(p string) bool { return slices.Contains(u.head.Profiles, p) }) {
			continue
		}
		if own := slices.DeleteFunc(slices.Clone(svc.Profiles), func(p string) bool { return !slices.Contains(wide, p) }); len(own) > 0 {
			apart[name] = own
		}
	}
	return apart, wide, nil
}

// startCommand is the compose command, quoted as the person runs it, that
// starts services, which run only under profiles of the stack's own
// (ownServices).
func startCommand(services, profiles []string) string {
	command := "docker compose"
	for _, p := range profiles {
		command += " --profile " + p
	}
	return "'" + command + " up -d " + strings.Join(services, " ") + "'"
}

// unselectedLine is the sentence that says which services of the stack's
// own (ownServices) .env's head leaves stopped, and the command that starts
// them: what a start that ran under the head alone says of them. It is ""
// when there are none, or when they do not read, since the start it
// follows has already said how it went.
func (u *updater) unselectedLine() string {
	ctx, cancel := u.detached(composeRunTimeout)
	defer cancel()
	apart, _, err := u.ownServices(ctx)
	if err != nil || len(apart) == 0 {
		return ""
	}
	services := slices.Sorted(maps.Keys(apart))
	var profiles []string
	for _, svc := range services {
		profiles = append(profiles, apart[svc]...)
	}
	return notStartedLine(services, profiles)
}

// notStartedLine is the sentence that names services of the stack's own,
// under profiles .env's head does not select, as not started, and the
// command that starts them.
func notStartedLine(services, profiles []string) string {
	profiles = slices.Compact(slices.Sorted(slices.Values(profiles)))
	return fmt.Sprintf("These services are not started, since .env selects none of their profiles: %s; %s starts them.", strings.Join(services, ", "), startCommand(services, profiles))
}

// besideLine is notStartedLine of the services that ran beside the head's
// (updater.beside), after " " for a sentence that says 'cyfr up' starts the
// stack, which starts none of them; "" when none ran.
func (u *updater) besideLine() string {
	if len(u.beside) == 0 {
		return ""
	}
	return " " + notStartedLine(u.beside, u.own)
}

// onTarget reports whether slot's member runs the release this update
// installs.
func (u *updater) onTarget(slot rosterSlot) bool {
	return slot.Release == u.version
}

// ---- stop, re-read, snapshot -----------------------------------------------------

// stop closes Serve (the engine's CloseServe, as every stop of the
// engine's own does first), so no tailnet request reaches a stack going
// away, then stops every running service one at a time in stopOrder,
// timing each, then the rest at once.
func (u *updater) stop() error {
	if err := u.engine.CloseServe(context.WithoutCancel(u.ctx)); err != nil {
		return fmt.Errorf("Tailscale Serve could not be closed before the stop (%v); nothing was stopped", engineFailure(err))
	}
	for _, svc := range stopOrder {
		if !slices.Contains(u.running, svc) {
			continue
		}
		took, err := u.stopServices(svc)
		if err != nil {
			return fmt.Errorf("docker compose stop %s failed (%v)", svc, err)
		}
		u.stopTimes = append(u.stopTimes, serviceStop{svc, took})
		fmt.Fprintf(u.out, "stopped %s in %.1fs\n", svc, took.Seconds())
	}
	var rest []string
	for _, svc := range u.running {
		if !slices.Contains(stopOrder, svc) {
			rest = append(rest, svc)
		}
	}
	took, err := u.stopServices()
	if err != nil {
		return fmt.Errorf("docker compose stop failed (%v)", err)
	}
	if len(rest) > 0 {
		name := strings.Join(rest, ", ")
		u.stopTimes = append(u.stopTimes, serviceStop{name, took})
		fmt.Fprintf(u.out, "stopped %s in %.1fs\n", name, took.Seconds())
	}
	return nil
}

func (u *updater) stopServices(services ...string) (time.Duration, error) {
	ctx, cancel := u.detached(stopTimeout)
	defer cancel()
	began := time.Now()
	err := u.composeDocker(ctx, append([]string{"stop"}, services...)...)
	return time.Since(began), err
}

// rereadOffline reads the live slots with nothing of the stack running,
// until none is live but members of the target release (hosts of the cell
// updated before this one) or the window closes; a member stopped past its
// grace leaves its row until its lease runs out. Any error or unreadable
// answer refuses, never reads as no slot.
func (u *updater) rereadOffline() error {
	release, others, err := u.waitLiveSlots(u.onTarget)
	if err != nil {
		return err
	}
	if len(others) > 0 {
		return fmt.Errorf("A slot is still live %s after the stop: %s. A server outside this stack holds it; stop that server first", liveSlotsWindow, slotNames(others))
	}
	// A home whose cyfr was not running, so no roster answered before the
	// stop, is held to the release its image answers here, before the
	// snapshot and the switch.
	if err := u.refuseNewer(release, "is on"); err != nil {
		return err
	}
	u.oldRelease = release
	return nil
}

// waitLiveSlots reads the live slots offline, in a container of the
// configured image with nothing of the stack running, until every live slot
// is one admit admits or the window closes, and answers the release the
// image runs and the live slots admit does not admit, none when the read
// ended with every slot admitted. An error or an unreadable answer is an
// error, never no slot.
func (u *updater) waitLiveSlots(admit func(rosterSlot) bool) (string, []rosterSlot, error) {
	deadline := time.Now().Add(liveSlotsWindow)
	for {
		ctx, cancel := u.detached(composeRunTimeout)
		args, err := u.offlineEval(ctx, liveSlotsExpr)
		output := ""
		if err == nil {
			output, err = u.dockerOutput(ctx, nil, args...)
		}
		cancel()
		if err != nil {
			return "", nil, fmt.Errorf("The offline roster read failed (%v)", err)
		}
		var answer struct {
			Release string        `json:"release"`
			Slots   *[]rosterSlot `json:"slots"`
		}
		payload, err := markedLine(output, "CYFR_LIVE_SLOTS=")
		if err == nil {
			err = json.Unmarshal([]byte(payload), &answer)
		}
		if err == nil && (answer.Release == "" || answer.Slots == nil) {
			err = errors.New("no release or no slots")
		}
		if err != nil {
			return "", nil, fmt.Errorf("The offline roster read did not answer (%v)", err)
		}
		var others []rosterSlot
		for _, slot := range *answer.Slots {
			if !admit(slot) {
				others = append(others, slot)
			}
		}
		if len(others) == 0 || !time.Now().Add(liveSlotsPoll).Before(deadline) {
			return answer.Release, others, nil
		}
		time.Sleep(liveSlotsPoll)
	}
}

// slotNames names live slots, each by its node and release.
func slotNames(slots []rosterSlot) string {
	var nodes []string
	for _, slot := range slots {
		nodes = append(nodes, fmt.Sprintf("%s (release %s)", slot.Node, slot.Release))
	}
	return strings.Join(nodes, ", ")
}

// dumpPostgres streams pg_dump's custom-format dump of the configured
// database into file, from the server-major image; the URL reaches the
// container on its standard input.
func (u *updater) dumpPostgres(file string) error {
	f, err := os.OpenFile(file, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return err
	}
	ctx, cancel := u.detached(dumpTimeout)
	defer cancel()
	var stderr bytes.Buffer
	res, err := u.engine.Docker().Run(ctx, access.Call{
		Args: []string{"run", "--rm", "-i", "--network", "host", u.pgImage(),
			"sh", "-c", pgReadURL + `exec pg_dump --format=custom --no-owner "$` + pgURLVariable + `"`},
		Deadline: callDeadline(ctx),
		Stdin:    pgURLInput(u.config.pgURL),
		Stdout:   f,
		Stderr:   &stderr,
	})
	if stderr.Len() > 0 {
		io.WriteString(u.errOut, u.redactor().Text(stderr.String()))
	}
	if err := errors.Join(callFailure(u.redactor(), res, err), f.Sync(), f.Close()); err != nil {
		return fmt.Errorf("pg_dump in %s failed: %w", u.pgImage(), err)
	}
	return nil
}

// writeNewFile creates path, 0600, refusing an existing one, and syncs it.
func writeNewFile(path string, data []byte) error {
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return err
	}
	return errors.Join(writeAll(f, data), f.Sync(), f.Close())
}

// copyFile copies the regular file src to the new file dst, 0600.
func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	return copyTo(in, dst)
}

// copyTo copies in into dst, a new file of mode 0600, synced.
func copyTo(in io.Reader, dst string) error {
	out, err := os.OpenFile(dst, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return err
	}
	_, err = io.Copy(out, in)
	return errors.Join(err, out.Sync(), out.Close())
}

// ---- the switch -----------------------------------------------------------------

// switchCompose writes the release's docker-compose.yml, its images pinned
// (pinRelease), over the person's file, which must still be the bytes the
// plan read and the snapshot holds, keeping its mode. It says once where
// that file is now, and which of its image lines the release's file does
// not keep.
func (u *updater) switchCompose() error {
	current, err := os.ReadFile(u.compose.path)
	if err != nil || !bytes.Equal(current, u.compose.original) {
		return fmt.Errorf("%s changed while cyfr update ran; the snapshot is %s", u.compose.path, u.snapshot)
	}
	info, err := os.Stat(u.compose.path)
	if err != nil {
		return err
	}
	if err := writeFileAtomic(u.compose.path, u.compose.release, info.Mode().Perm()); err != nil {
		return err
	}
	said := fmt.Sprintf("docker-compose.yml is now release %s's own file; the one it replaced, with any edits you made to it, is %s, to copy back from what you still need.", u.version, filepath.Join(u.snapshot, "compose"))
	if len(u.compose.overrides) > 0 {
		var lines []string
		for _, line := range u.compose.overrides {
			lines = append(lines, line.service+": "+line.value)
		}
		said += " Its image lines cyfr update does not manage are not in the new file: " + strings.Join(lines, ", ") + "."
	}
	fmt.Fprintln(u.out, said)
	return nil
}

// up starts the switched stack through the one start path every cyfr
// start takes (access.Engine.Start): the stack checked, a tailnet node
// validated before Serve opens, and cyfr's health awaited, the image's
// health check being its readiness. The update is done only when every
// service of the stack it started is up as well (waitStack).
func (u *updater) up() error {
	fmt.Fprintf(u.out, "Starting release %s...\n", u.version)
	err := u.start("update")
	if local := (startedLocally{}); errors.As(err, &local) {
		u.servedLocally = err
	} else if err != nil {
		return err
	}
	return u.waitStack()
}

// stackContainer is a container as `docker compose ps --format json`
// writes it.
type stackContainer struct {
	Service, State, Health string
}

// waitStack waits, within the one deadline stackHealthWindow from now, for
// every service of the stack the start selected (`docker compose config
// --services` under the head it started) to be up: each of its running
// containers running, and healthy where it has a health check. A service
// whose health check failed ends the wait at once; at the deadline, a
// docker call it cut short included, every service not seen up is named,
// each with what was last seen of it, with the command that shows why.
func (u *updater) waitStack() error {
	wait, cancel := context.WithTimeout(context.WithoutCancel(u.ctx), stackHealthWindow)
	defer cancel()
	call, cancelCall := context.WithTimeout(wait, composeRunTimeout)
	listed, err := u.composeOutput(call, "config", "--services")
	cancelCall()
	services := strings.Fields(listed)
	slices.Sort(services)
	seen := map[string]string{}
	for _, svc := range services {
		seen[svc] = "not read"
	}
	late := func() error {
		names := slices.Sorted(maps.Keys(seen))
		var states []string
		for _, svc := range names {
			states = append(states, fmt.Sprintf("%s (%s)", svc, seen[svc]))
		}
		return fmt.Errorf("%s did not come up within %s; see why with 'docker compose logs %s'", strings.Join(states, ", "), stackHealthWindow, strings.Join(names, " "))
	}
	switch {
	case err != nil && wait.Err() != nil:
		return fmt.Errorf("the started stack's services did not read within %s (%v)", stackHealthWindow, err)
	case err != nil:
		return fmt.Errorf("docker compose could not list the started stack's services (%v)", err)
	}
	for {
		// Each read ends by the wait's own deadline, within the bound of
		// every docker call.
		call, cancelCall := context.WithTimeout(wait, composeRunTimeout)
		raw, err := u.composeOutput(call, "ps", "--format", "json")
		cancelCall()
		if err != nil {
			if wait.Err() != nil {
				return late()
			}
			return fmt.Errorf("docker compose could not list the started stack's containers (%v)", err)
		}
		containers, err := readContainers(raw)
		if err != nil {
			return fmt.Errorf("docker compose ps answered what is not its JSON (%v)", err)
		}
		failed := false
		for _, svc := range services {
			seen[svc] = "not running"
			for _, c := range containers {
				if c.Service != svc {
					continue
				}
				switch {
				case c.State != "running":
					seen[svc] = c.State
				case c.Health == "unhealthy":
					seen[svc], failed = c.Health, true
				case c.Health != "" && c.Health != "healthy":
					seen[svc] = c.Health
				default:
					delete(seen, svc)
					continue
				}
				break
			}
		}
		if len(seen) == 0 {
			return nil
		}
		deadline, _ := wait.Deadline()
		if failed || !time.Now().Add(stackHealthPoll).Before(deadline) {
			return late()
		}
		time.Sleep(stackHealthPoll)
	}
}

// readContainers reads `docker compose ps --format json`: one object a
// line, or one array, as Compose before 2.21 writes it.
func readContainers(raw string) ([]stackContainer, error) {
	raw = strings.TrimSpace(raw)
	var containers []stackContainer
	if strings.HasPrefix(raw, "[") {
		err := json.Unmarshal([]byte(raw), &containers)
		return containers, err
	}
	for _, line := range strings.Split(raw, "\n") {
		if line = strings.TrimSpace(line); line == "" {
			continue
		}
		var c stackContainer
		if err := json.Unmarshal([]byte(line), &c); err != nil {
			return nil, err
		}
		containers = append(containers, c)
	}
	return containers, nil
}

// start starts the stack as .env and the compose file hold it, through the
// one start path (access.Engine.StartWithin), cause naming the command,
// waiting startHealth for cyfr's health, then the services beside the
// head's under the stack's own selection, those alone: none they depend on
// starts, so nothing that did not run before the stop runs after it. The
// head the start read is the update's from then on, so what is waited for
// and what a failure stops is what it started. A start that leaves the
// home on this machine alone answers startedLocally; one whose services
// beside did not start, besideFailed.
func (u *updater) start(cause string) error {
	rc, err := u.engine.StartWithin(context.WithoutCancel(u.ctx), cause, startHealth)
	if rc.FinalHead != nil {
		u.head = *rc.FinalHead
	}
	err = answerFailure(rc, err)
	if local := (startedLocally{}); len(u.beside) > 0 && (err == nil || errors.As(err, &local)) {
		ctx, cancel := u.detached(stopTimeout)
		defer cancel()
		if upErr := u.composeDocker(ctx, append([]string{"up", "-d", "--no-deps"}, u.beside...)...); upErr != nil {
			return besideFailed{services: u.beside, profiles: u.own, err: upErr, local: err}
		}
	}
	return err
}

// besideFailed is a start whose head's services started and whose services
// beside them (updater.beside, under profiles) did not, err saying why;
// local is the head's start's answer, nil or startedLocally.
type besideFailed struct {
	services, profiles []string
	err, local         error
}

func (b besideFailed) Error() string {
	text := fmt.Sprintf("%s did not start (%v); %s starts them", strings.Join(b.services, ", "), b.err, startCommand(b.services, b.profiles))
	if b.local != nil {
		text += ". " + b.local.Error()
	}
	return text
}

// restartOld starts the old stack again after a failure before the switch,
// when no byte has been migrated, and refuses with reason.
func (u *updater) restartOld(reason error) error {
	if len(u.running) == 0 {
		return fmt.Errorf("%v.\nThe stack was not running before the update; %s", u.redactor().Text(reason.Error()), u.composeAsRead())
	}
	// The old stack starts again only under the compose file the update
	// read: one that changed since is the person's, kept as it is, and the
	// stack stays stopped rather than start under a file nothing checked.
	if current, err := os.ReadFile(u.compose.path); err != nil || !bytes.Equal(current, u.compose.original) {
		if unreleased := u.leaveStopped(); unreleased != "" {
			return fmt.Errorf("%v.\nThe old stack is stopped: %s. %s", u.redactor().Text(reason.Error()), u.composeAsRead(), unreleased)
		}
		return fmt.Errorf("%v.\nThe old stack is left stopped: %s, so it is not started under it. Start the stack with 'cyfr up' once docker-compose.yml is the configuration you mean to run", u.redactor().Text(reason.Error()), u.composeAsRead())
	}
	fmt.Fprintln(u.out, "Starting the old stack again...")
	err := u.start("update")
	if beside := (besideFailed{}); errors.As(err, &beside) {
		return fmt.Errorf("%v.\nThe old stack was started again and docker-compose.yml is unchanged, but %v", u.redactor().Text(reason.Error()), err)
	}
	if local := (startedLocally{}); errors.As(err, &local) {
		return fmt.Errorf("%v.\nThe old stack was started again, on this machine alone; docker-compose.yml is unchanged. %v", u.redactor().Text(reason.Error()), err)
	}
	if err != nil {
		return fmt.Errorf("%v.\nThe old stack did not start again (%v); docker-compose.yml is unchanged, so 'cyfr up' starts it.%s", u.redactor().Text(reason.Error()), err, u.besideLine())
	}
	return fmt.Errorf("%v.\nThe old stack was started again; docker-compose.yml is unchanged", u.redactor().Text(reason.Error()))
}

// leaveStopped releases the update's hold at an exit that leaves the stack
// stopped on purpose, "" once released. A release that fails may have left
// the hold (its removal failed) or not (its directory's sync failed after
// the removal), so the next cyfr command may start the stack: it answers
// the sentence that says so, in place of the promise that the stack stays
// stopped.
func (u *updater) leaveStopped() string {
	if err := u.engine.Release(); err != nil {
		return fmt.Sprintf("Clearing the record of the stop could not be confirmed (%v), so the next cyfr command may start CYFR as .env and docker-compose.yml then hold it", engineFailure(err))
	}
	return ""
}

// composeAsRead says whether the compose file is still the bytes the
// update read, for an exit's report: the update writes it only in the
// switch, so a difference before the switch is someone else's edit. Every
// exit after the read that reports the file reports it through here.
func (u *updater) composeAsRead() string {
	current, err := os.ReadFile(u.compose.path)
	switch {
	case err != nil:
		return fmt.Sprintf("%s could not be read (%v)", u.compose.path, err)
	case !bytes.Equal(current, u.compose.original):
		return fmt.Sprintf("%s changed while cyfr update ran and is kept as it is", u.compose.path)
	}
	return "docker-compose.yml is unchanged"
}

// stopAfterSwitch leaves the stack stopped after a failure from the switch
// on: the new release may have migrated the database, so old code never
// starts over it. The snapshot restores the old release.
func (u *updater) stopAfterSwitch(reason error) error {
	ctx, cancel := u.detached(stopTimeout)
	defer cancel()
	message := fmt.Sprintf("Release %s did not start (%v); the stack is left stopped.", u.version, reason)
	if err := u.stopFailedStart(ctx); err != nil {
		message = fmt.Sprintf("Release %s did not start (%v), and %v; stop it with 'cyfr down'.", u.version, reason, err)
	} else if fatal := bootFatal(ctx, u.engine, u.head); fatal != "" {
		// A stop keeps the container, so its log is still there to read.
		message += "\n" + fatal
	}
	return fmt.Errorf("%s\nThe snapshot of release %s is %s; restore it with:\n  cyfr restore %s", message, u.oldRelease, u.snapshot, u.snapshot)
}

// stopFailedStart stops every service of the stack after a start that
// failed, closing Serve first (the engine's CloseServe) as every stop
// does: a failed start can leave Serve's open configuration published, as
// one whose directory sync failed after the file was written does, and no
// stop leaves it open. Serve that does not close stops nothing.
func (u *updater) stopFailedStart(ctx context.Context) error {
	if err := u.engine.CloseServe(ctx); err != nil {
		return fmt.Errorf("Tailscale Serve could not be closed (%v), so nothing was stopped and the stack may still be running with Serve open", engineFailure(err))
	}
	if err := u.composeDocker(ctx, "stop"); err != nil {
		return fmt.Errorf("docker compose stop failed (%v)", err)
	}
	return nil
}

// report prints the update's outcome.
func (u *updater) report() {
	fmt.Fprintf(u.out, "\nUpdated to release %s.\n", u.version)
	for _, s := range u.stopTimes {
		fmt.Fprintf(u.out, "  stopped %s in %.1fs\n", s.service, s.took.Seconds())
	}
	fmt.Fprintf(u.out, "Snapshot of release %s: %s\n", u.oldRelease, u.snapshot)
}

// mapValue returns the value node for the given key in a mapping node, or
// nil if the key is absent or the node isn't a mapping.
func mapValue(m *yaml.Node, key string) *yaml.Node {
	if m == nil || m.Kind != yaml.MappingNode {
		return nil
	}
	for i := 0; i < len(m.Content); i += 2 {
		if i+1 >= len(m.Content) {
			break
		}
		k := m.Content[i]
		if k.Value == key {
			return m.Content[i+1]
		}
	}
	return nil
}

// devicesTurn is what writing u.devices over .env's device settings does
// to the Locus services: on where it first gives them both devices, off
// where it takes both away. A .env that does not read does neither; the
// update refuses it with its own sentence.
func (u *updater) devicesTurn() (on, off bool) {
	values, err := access.ReadEnvValues(".env")
	if err != nil {
		return false, false
	}
	return passes(u.devices) && !passes(values), passes(values) && !passes(u.devices)
}

// nothingChanged opens what an update that ends unmade says: nothing
// changed, or, where it emptied device settings first (emptyStrayDevices),
// nothing else.
func (u *updater) nothingChanged() string {
	if u.emptied {
		return "Nothing else changed"
	}
	return "Nothing changed"
}
