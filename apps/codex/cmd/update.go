// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"bufio"
	"bytes"
	"cmp"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"maps"
	"net/url"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/cyfr/codex/internal/access"
	"github.com/cyfr/codex/internal/release"
	"github.com/cyfr/codex/internal/scaffold"
	"github.com/cyfr/codex/internal/version"
	"github.com/spf13/cobra"
	"gopkg.in/yaml.v3"
)

func init() {
	updateCmd.Flags().String("version", "", "Install exactly this release, a pre-release or an older release included, instead of the newest one")
	updateCmd.Flags().Bool("yes", false, "Update the home without asking to confirm it")
	// The release the program step installed, which the new program it
	// hands over to checks it is (updateProgram).
	updateCmd.Flags().String("continue-as", "", "")
	_ = updateCmd.Flags().MarkHidden("continue-as")
	rootCmd.AddCommand(updateCmd)
}

var updateCmd = &cobra.Command{
	Use:   "update",
	Short: "Update this cyfr to the newest release, then the home in this directory to it",
	Long: `Update this program to the newest release, then the home in the current directory to the program's release, in one command.

The program: when a release newer than this one is published, pre-releases aside, cyfr update installs it: a Homebrew cask install through brew, any other install by downloading the release's archive for this platform, verifying it against the release's checksums.txt signed by the release workflow for that tag, and only then replacing this program's file. It then goes on as the new program. --version names the exact release to install instead, a pre-release or an older release included; a Homebrew install takes only its tap's release. A development build is not replaced. Outside a home directory (no cyfr.yaml) the update stops here.

The home: after steps 1 and 2 below, cyfr update shows what changes and asks to make the change (--yes makes it without asking; with no terminal and no --yes it shows the change and makes none). A home whose docker-compose.yml names this release already is left alone, with no stop and no snapshot, and a home on a newer release than this cyfr is refused, since its database may not run under older code. The change is one ceremony that changes nothing until the old stack is stopped and a snapshot of it is taken:

1. Fetch the release's signed manifest (release.json) and verify it; a manifest that does not verify, or no network access to it, refuses.
2. Read docker-compose.yml. Every bundled service (locus-runtime, locus-builds, locus-backends and both egress guards) must be present; one missing refuses, naming 'cyfr init --force'. An image line naming ghcr.io/cyfrworks/cyfr, ghcr.io/cyfrworks/cyfr-locus, the bundled Caddy or the bundled Tailscale is managed; any other image is an override, left as written and reported.
3. While the stack still runs: read its configuration, naming the storage root it snapshots, pull every managed image by the manifest's digest, read the cell's roster, refusing while a member outside this stack holds a live slot on another release than this one (a host of the cell already updated stays), then fetch and verify the release's scaffold files (guides, WIT definitions, the keeper's seccomp profile, the shipped AQUA prompts) without writing them. A restore that has not finished (CYFR_RESTORE_INCOMPLETE in .env) refuses.
4. Cancel a tailnet join that waits for approval, then stop every service, timing each, and re-read the roster offline until no slot of another release than this one is live (at most one lease); one still live restarts the old stack and refuses.
5. Snapshot the database, the local storage root, every scaffold file the release manages as it stands, the keyring, .env and docker-compose.yml as it stands into backups/<UTC timestamp>/, snapshot.json last.
6. Write the release's scaffold files and rewrite the managed image lines to <image>:<version>@<digest> (Caddy and Tailscale keep their tags); a failure of either puts the scaffold files back from the snapshot and starts the old stack again. Then start the stack as every cyfr start runs, waiting for cyfr's health. A failure from here leaves the stack stopped and prints the snapshot and the restore command; old code never starts over migrated data.

The update holds the stack's lock from before its first docker call to its end, after finishing a change an interrupted command left; every docker call it makes runs under that lock. Exit status 3: the update is done and the new release started, but on this machine only, because the tailnet machine is not ready to serve it (not the one .env names, not joined, or HTTPS off); the message says what to do. An interrupt before the stop changes nothing. From the stop until the switch, the running step finishes and the update ends as that step's failure would. Once the switch begins, the switch and the start run to their end, so the stack is never left half-switched; an interrupt then is reported, not acted on.`,
	GroupID: "server",
	Example: "  cyfr update\n  cyfr update --yes\n  cyfr update --version 0.6.0-alpha.1",
	RunE: func(cmd *cobra.Command, args []string) error {
		var o updateOptions
		o.version, _ = cmd.Flags().GetString("version")
		o.yes, _ = cmd.Flags().GetBool("yes")
		o.continueAs, _ = cmd.Flags().GetString("continue-as")
		o.noInteractive = flagNoInteractive
		return runUpdate(cmd.Context(), cmd.OutOrStdout(), cmd.ErrOrStderr(), o)
	},
}

// The release's manifest and the scaffold files, each a package variable so
// tests substitute them; production calls the verified release fetch and
// the checksum-verified scaffold fetch.
var (
	fetchManifest = release.FetchManifest
	fetchScaffold = func(version string) (scaffoldRelease, error) {
		r, err := scaffold.Fetch(version)
		if err != nil {
			return nil, err
		}
		return r, nil
	}
	// updateNow names the snapshot directory and stamps snapshot.json.
	updateNow = time.Now
	// liveSlotsWindow bounds the offline re-read, measured from the end of
	// the stop step: one lease (15 s), within which a member killed past its
	// grace lets its row lapse, and 5 s of slack. liveSlotsPoll spaces the
	// attempts after the first.
	liveSlotsWindow = 20 * time.Second
	liveSlotsPoll   = time.Second
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

// bundledServices are the services of the bundled stack besides cyfr, whose
// fields ensureCyfrComposeFields keeps; caddy and tailscale are the public
// and tailnet profiles' proxies, optional to a project that never runs one.
var bundledServices = []string{"locus-runtime", "locus-builds", "locus-backends", "locus-builds-guard", "locus-backends-guard"}

// stopOrder is the order the stop step stops services in: the proxies
// first, then cyfr, then each Locus service before the guard whose network
// namespace it shares.
var stopOrder = []string{"caddy", "tailscale", "cyfr", "locus-runtime", "locus-builds", "locus-backends", "locus-builds-guard", "locus-backends-guard"}

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

// missingStackServices returns the bundled services the compose file at
// path lacks, in bundledServices' order; nil when it has them all or cannot
// be read as a compose file. `cyfr update` reads the file itself first and
// refuses one it cannot parse.
func missingStackServices(path string) []string {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	var root yaml.Node
	if err := yaml.Unmarshal(data, &root); err != nil || root.Kind != yaml.DocumentNode || len(root.Content) == 0 {
		return nil
	}
	services := mapValue(root.Content[0], "services")
	if services == nil {
		return nil
	}
	var missing []string
	for _, name := range bundledServices {
		if mapValue(services, name) == nil {
			missing = append(missing, name)
		}
	}
	return missing
}

// errUpdateInterrupted is the refusal of an update a signal ended before
// anything stopped; once the compose file is read, the refusal says what
// it is now (composeAsRead).
var errUpdateInterrupted = errors.New("cyfr update was interrupted before anything stopped; it changed nothing and the running stack was not touched")

// runUpdate is `cyfr update` in the working directory: the program step
// (updateProgram), which hands the rest over to the program it installs,
// then, in a home directory, the home step (runHomeUpdate). The program
// a handover starts is told the release it must be (o.continueAs) and
// skips the program step.
func runUpdate(ctx context.Context, out, errOut io.Writer, o updateOptions) error {
	if ctx == nil {
		ctx = context.Background()
	}
	switch {
	case o.continueAs == "":
		finished, err := updateProgram(ctx, out, o)
		if finished || err != nil {
			return err
		}
	case o.continueAs != version.Version:
		self, _ := selfExecutable()
		return fmt.Errorf("The cyfr at %s is %s, not release %s that cyfr update installed; the home was not touched. Run 'cyfr update' again", self, version.Version, o.continueAs)
	}
	if _, err := os.Stat("cyfr.yaml"); err != nil {
		fmt.Fprintln(out, "There is no home in this directory (no cyfr.yaml), so the update ends with the program; run 'cyfr update' in a home's directory to update that home.")
		return nil
	}
	return runHomeUpdate(ctx, out, errOut, o.yes)
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
func runHomeUpdate(ctx context.Context, out, errOut io.Writer, yes bool) error {
	v := version.Version
	if !release.IsVersion(v) {
		return errors.New("This cyfr is a development build, which has no signed release to install; run 'cyfr update' with a released cyfr")
	}
	u := &updater{ctx: ctx, version: v, out: out, errOut: errOut}
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
	if done, err := u.offer(yes); done || err != nil {
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

// scaffoldRelease is a release's scaffold fetched and verified, nothing of
// it written (scaffold.Release).
type scaffoldRelease interface {
	Managed() []string
	Write(overwriteManaged bool) error
}

// updater carries one update's state from step to step.
type updater struct {
	ctx         context.Context
	version     string
	out, errOut io.Writer
	// engine holds the stack's lock and runs every docker call of the
	// update; head is .env's access head, whose selection every compose
	// call of the update runs with.
	engine stackEngine
	head   access.Head
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
	snapshot   string
	// scaffold is the release's scaffold, written only after the snapshot
	// holds every file of it that it manages.
	scaffold scaffoldRelease
	// offlineEnv are the settings each offline eval sets in its one-off
	// container: a restore's lifts its own bar (restoreBarrier).
	offlineEnv []string
	// boundTargets are the container paths compose resolves a mount of the
	// cyfr service at, through every form compose reads (merge keys,
	// extends, override files), so the switch adds no default mount at one.
	boundTargets map[string]bool
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
	steps := []func() error{u.readConfig, u.probePostgres, u.pull, u.readRoster, u.fetchScaffold}
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

	// A join waiting for approval would enrol the machine while the stack
	// is down for the update, so it is cancelled first.
	if err := u.engine.CancelWaitingJoin(u.ctx); err != nil {
		return fmt.Errorf("cyfr update could not cancel the tailnet join waiting for approval (%v); the running stack was not touched, and %s", engineFailure(err), u.composeAsRead())
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
	if err := u.takeSnapshot(); err != nil {
		where := "no snapshot directory was made"
		if u.snapshot != "" {
			where = "the partial snapshot is " + u.snapshot
		}
		return fmt.Errorf("The snapshot failed: %v.\nThe stack is left stopped and %s; %s. Fix the cause and run 'cyfr update' again, or start the old stack with 'cyfr up'", u.redactor().Text(err.Error()), u.composeAsRead(), where)
	}
	if u.ctx.Err() != nil {
		return u.restartOld(fmt.Errorf("cyfr update was interrupted during the snapshot (complete at %s)", u.snapshot))
	}
	// The scaffold files and the compose file are written only now, with
	// the snapshot holding both as they stood; a failure puts the scaffold
	// files back, so the old stack starts again under its own.
	if err := u.writeScaffold(); err != nil {
		return u.revertScaffold(err)
	}
	if err := u.switchImages(); err != nil {
		if errors.Is(err, errComposeLeftSwitched) {
			return fmt.Errorf("%v.\nThe stack is left stopped; restore the snapshot of release %s with:\n  cyfr restore %s", u.redactor().Text(err.Error()), u.oldRelease, u.snapshot)
		}
		return u.revertScaffold(err)
	}
	if err := u.up(); err != nil {
		return u.stopAfterSwitch(err)
	}
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

// offer shows what the update changes and asks to make it, answering done
// when the update ends here: a home whose compose file names this
// release's digests on every managed line already is left alone, with no
// stop and no snapshot; a home on a newer release than this cyfr is
// refused, since the update would start older code over a database the
// newer release migrated; and a change not confirmed is not made. yes
// makes the change without asking; with no terminal to ask on and no yes,
// the change is shown and not made.
func (u *updater) offer(yes bool) (bool, error) {
	plan := u.compose
	if plan.onRelease() {
		fmt.Fprintf(u.out, "This home is on release %s already, so there is nothing to update; 'cyfr up' starts it if it is stopped.\n", u.version)
		return true, nil
	}
	from := plan.homeRelease()
	if from != "" && release.IsNewer(from, u.version) {
		return true, fmt.Errorf("This home is on release %s, newer than this cyfr's %s, and cyfr update never moves a home to an older release: the older code would start over a database %s may have migrated. Nothing was changed. To keep %s, run 'cyfr update' with a cyfr of %s or later; to go back to %s, restore a snapshot taken on it with 'cyfr restore backups/<timestamp>'", from, u.version, from, from, from, u.version)
	}

	if from != "" {
		fmt.Fprintf(u.out, "\nThis home is on release %s; this cyfr is release %s.\n", from, u.version)
	} else {
		fmt.Fprintf(u.out, "\nThis home's docker-compose.yml names no release (%s); this cyfr is release %s.\n", plan.cyfrImage(), u.version)
	}
	fmt.Fprintf(u.out, "Updating it stops the stack, snapshots it into backups/, switches these images to release %s and starts it:\n", u.version)
	for _, line := range plan.managed {
		if line.value != line.replacement {
			fmt.Fprintf(u.out, "  %s: %s → %s\n", line.service, shortDigest(line.value), shortDigest(line.replacement))
		}
	}
	if len(plan.overrides) > 0 {
		fmt.Fprintln(u.out, "Image lines left as written (not managed by cyfr update):")
		for _, line := range plan.overrides {
			fmt.Fprintf(u.out, "  %s: %s\n", line.service, line.value)
		}
	}
	fmt.Fprintf(u.out, "On that start the release migrates the database, or refuses one it cannot carry forward; only the snapshot takes the home back. Read the release notes first: %s/tag/%s\n", releasesPage, u.version)
	if yes {
		return false, nil
	}
	if !askTerminal() {
		return true, errors.New("The update above was shown, not made: cyfr update changes a home only once it is confirmed, and there is no terminal to confirm it on. Nothing was changed. Run it again with --yes to make it")
	}
	if a := strings.ToLower(ask(bufio.NewReader(askInput), u.out, "Update this home? (yes/no)", "no")); a != "yes" && a != "y" {
		return true, errors.New("The home was not updated: the update was not confirmed. Nothing was changed")
	}
	return false, nil
}

// shortDigest shortens an image reference's sha256 digest to its first 12
// hex digits, for reading.
func shortDigest(ref string) string {
	if i := strings.Index(ref, "@sha256:"); i >= 0 && len(ref) > i+8+12 {
		return ref[:i+8+12] + "…"
	}
	return ref
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

// composePlan is the compose file as read, and the file the switch writes.
type composePlan struct {
	path      string
	original  []byte
	rewritten []byte
	managed   []imageLine
	overrides []imageLine
	// pulls are the managed images, each repository as written once, by the
	// manifest's digest.
	pulls []string
}

// planCompose reads the compose file, refuses one lacking a bundled
// service, and computes the switch's file: every managed image line
// rewritten in place to the manifest's digest, every other byte kept.
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
	if missing := missingStackServices(path); len(missing) > 0 {
		return nil, fmt.Errorf("docker-compose.yml lacks the bundled stack's %s, so this project predates the stack; nothing was changed.\nRun 'cyfr init --force' to regenerate docker-compose.yml (.env is kept), then 'cyfr update' again.", strings.Join(missing, ", "))
	}

	plan := &composePlan{path: path, original: data}
	rewritten := map[*yaml.Node]bool{}
	type edit struct {
		start, end int
		text       string
	}
	var edits []edit
	lines := lineStarts(data)
	for i := 0; i+1 < len(services.Content); i += 2 {
		name, svc := services.Content[i].Value, services.Content[i+1]
		node := serviceImage(svc, 0)
		if node == nil {
			continue
		}
		line := imageLine{service: name, value: node.Value, node: node}
		if node.Kind != yaml.ScalarNode || strings.Contains(node.Value, "$") {
			plan.overrides = append(plan.overrides, line)
			continue
		}
		line.repository, line.tag, _ = splitImageReference(node.Value)
		repo := normalizeRepository(line.repository)
		if line.repository == "" || !slices.Contains(managedRepositories, repo) {
			plan.overrides = append(plan.overrides, line)
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
		plan.managed = append(plan.managed, line)
		if pull := line.repository + "@" + want; !slices.Contains(plan.pulls, pull) {
			plan.pulls = append(plan.pulls, pull)
		}
		if rewritten[node] {
			continue
		}
		rewritten[node] = true
		start, end, err := scalarSpan(data, lines, node)
		if err != nil {
			return nil, fmt.Errorf("cyfr update cannot rewrite %s's image on line %d of %s in place (%v); nothing was changed. Write it as a plain or quoted scalar on one line", name, node.Line, path, err)
		}
		edits = append(edits, edit{start, end, renderScalar(line.replacement, node.Style)})
	}
	slices.SortFunc(edits, func(a, b edit) int { return b.start - a.start })
	out := slices.Clone(data)
	for _, e := range edits {
		out = slices.Concat(out[:e.start], []byte(e.text), out[e.end:])
	}
	if err := checkRewrite(out, plan.managed); err != nil {
		return nil, fmt.Errorf("cyfr update could not rewrite %s's image lines in place (%v); nothing was changed", path, err)
	}
	plan.rewritten = out
	return plan, nil
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

// homeRelease answers the release the compose file's cyfr image lines name,
// the one tag they share when it is a release version, else "".
func (p *composePlan) homeRelease() string {
	found := ""
	for _, line := range p.managed {
		if normalizeRepository(line.repository) != release.RepoCyfr {
			continue
		}
		if !release.IsVersion(line.tag) || found != "" && line.tag != found {
			return ""
		}
		found = line.tag
	}
	return found
}

// cyfrImage answers the cyfr service's image as written, or the first
// managed line's when no service is named cyfr.
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
// update's head: the engine's complete selection of project, files,
// directory and profiles (access.Engine.ComposeArgs).
func (u *updater) composeArgs(ctx context.Context, args ...string) ([]string, error) {
	return u.engine.ComposeArgs(ctx, u.head, args...)
}

// docker runs one docker call through the engine's runner under ctx, held
// to ctx's deadline, stdin on its standard input, its stdout into stdout
// (cyfr's own when nil) and its stderr into cyfr's, what reaches cyfr's
// own streams redacted a line at a time.
func (u *updater) docker(ctx context.Context, stdin io.Reader, stdout io.Writer, args ...string) error {
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
	res, err := u.engine.Docker().Run(ctx, access.Call{Args: args, Deadline: callDeadline(ctx), Stdin: stdin, Stdout: stdout, Stderr: errOut})
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
	// sqliteFile is the SQLite database's host path.
	sqliteFile string
	// pgURL is CYFR_DATABASE_URL; pgMajor the server's major version.
	pgURL   string
	pgMajor int
	storage string // local | s3
	// storageMounts are the mounts that make up the local storage root as cyfr
	// sees it: the root's own bind first, then every bind mounted under it,
	// shallower before deeper.
	storageMounts []storageMount
	// keyring is the snapshot's keyring file, dotenv lines.
	keyring string
}

// storageMount is one bind making up the storage root: rel is where it
// sits under the root (empty for the root itself), host its resolved host
// path, and dir whether that path is a directory.
type storageMount struct {
	rel  string
	host string
	dir  bool
}

// composeConfig is the part of `docker compose config --format json` the
// update reads.
type composeConfig struct {
	Services map[string]composeService `json:"services"`
}

// composeService is a service as `docker compose config --format json`
// writes it: its environment, and every key that mounts something into its
// filesystem.
type composeService struct {
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
// type, its tmpfs paths, and its secrets and configs at their targets. A
// service mounting another's volumes (volumes_from) is refused, since what
// those put where is not in the configuration.
func (svc composeService) mounts() ([]composeMount, error) {
	if len(svc.VolumesFrom) > 0 {
		return nil, fmt.Errorf("the cyfr service mounts the volumes of %s (volumes_from), which cyfr update cannot place, so it cannot snapshot the storage root; nothing was changed", strings.Join(svc.VolumesFrom, ", "))
	}
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
	mounts, err := cyfr.mounts()
	if err != nil {
		return err
	}
	u.boundTargets = map[string]bool{}
	for _, m := range mounts {
		u.boundTargets[path.Clean(m.Target)] = true
	}
	env := func(name string) string { return serviceSetting(cyfr.Environment, name) }
	if snapshot := env(restoreBarrier); snapshot != "" {
		return fmt.Errorf("A cyfr restore of %s has not finished (%s is set in .env), so the cell may hold the snapshot's data undeclared; run 'cyfr restore %s' again before updating; nothing was changed", snapshot, restoreBarrier, snapshot)
	}
	containerToHost := func(p string) (string, bool) { return mountedHost(mounts, p) }
	// nestedMounts answers every mount whose target lies strictly under the
	// container path root, shallower first, refusing one that is not a bind:
	// its bytes are no host directory the snapshot can copy.
	nestedMounts := func(root string) ([]storageMount, error) {
		var nested []storageMount
		for _, n := range mountsUnder(mounts, root) {
			v, target := n.mount, path.Clean(n.mount.Target)
			if v.Type != "bind" || v.Source == "" {
				return nil, fmt.Errorf("The storage root %s has a %s mount at %s, which cyfr update cannot snapshot; nothing was changed", root, v.Type, target)
			}
			resolved, err := filepath.EvalSymlinks(v.Source)
			info, statErr := os.Stat(resolved)
			if err != nil || statErr != nil || !(info.IsDir() || info.Mode().IsRegular()) {
				return nil, fmt.Errorf("The mount %s under the storage root (on the host %s) is not a readable directory or file, so cyfr update cannot snapshot it; nothing was changed", target, v.Source)
			}
			nested = append(nested, storageMount{rel: n.rel, host: resolved, dir: info.IsDir()})
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

	c := &stackConfig{}
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
		host, ok := containerToHost(dbPath)
		if !ok {
			return fmt.Errorf("The SQLite database %s is on no bind mount of the cyfr service, so cyfr update cannot snapshot it; nothing was changed", dbPath)
		}
		resolved, err := filepath.EvalSymlinks(host)
		if info, statErr := os.Stat(resolved); err != nil || statErr != nil || !info.Mode().IsRegular() {
			return fmt.Errorf("The SQLite database %s (on the host %s) is not a readable file, so cyfr update cannot snapshot it; nothing was changed", dbPath, host)
		}
		c.sqliteFile = resolved
	case "postgres":
		c.adapter = "postgres"
		if c.pgURL = env("CYFR_DATABASE_URL"); c.pgURL == "" {
			return errors.New("CYFR_DATABASE=postgres without CYFR_DATABASE_URL: cyfr update has no database to snapshot; nothing was changed")
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
			return fmt.Errorf("The storage root %s is on no bind mount of the cyfr service, so cyfr update cannot snapshot it; nothing was changed", dataPath)
		}
		// Resolved, so a root reached through a link is copied, not linked,
		// and the SQLite file under it is recognized.
		resolved, err := filepath.EvalSymlinks(host)
		if info, statErr := os.Stat(resolved); err != nil || statErr != nil || !info.IsDir() {
			return fmt.Errorf("The storage root %s (on the host %s) is not a readable directory, so cyfr update cannot snapshot it; nothing was changed", dataPath, host)
		}
		nested, err := nestedMounts(dataPath)
		if err != nil {
			return err
		}
		c.storageMounts = append([]storageMount{{host: resolved, dir: true}}, nested...)
		// The root the snapshot copies is the one compose resolves, which
		// the switch keeps: ensureCyfrComposeFields adds no mount at a
		// target already bound.
		fmt.Fprintf(u.out, "Storage root %s is %s on the host.\n", dataPath, resolved)
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
		return fmt.Errorf("cyfr update cannot read .env (%v), which the snapshot copies; nothing was changed", err)
	} else {
		f.Close()
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
	best, host, bind := -1, "", false
	for _, v := range mounts {
		target := path.Clean(v.Target)
		rel, ok := strings.CutPrefix(p, target)
		if !ok || rel != "" && !strings.HasPrefix(rel, "/") && target != "/" {
			continue
		}
		switch isBind := v.Type == "bind" && v.Source != ""; {
		case len(target) > best:
			best, bind = len(target), isBind
			host = filepath.Join(v.Source, filepath.FromSlash(rel))
		case len(target) == best && !isBind:
			// Two mounts at one target: which one cyfr sees is not
			// the configuration's to say, so the path is not mapped.
			bind = false
		}
	}
	return host, best >= 0 && bind
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
// the dump's image; the URL reaches the container through its environment.
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
		return fmt.Errorf("cyfr update could not reach the PostgreSQL server at CYFR_DATABASE_URL to read its version (%v); nothing was changed", err)
	}
	if _, err := pgClientImage(major); err != nil {
		return fmt.Errorf("cyfr update refuses: %w; nothing was changed", err)
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
// scaffold fetch verifies itself, and refuses a managed path that is there
// as something other than a regular file, which the snapshot cannot hold.
func (u *updater) fetchScaffold() error {
	r, err := fetchScaffold(u.version)
	if err != nil {
		return fmt.Errorf("Failed to fetch the scaffold files (%v); the running stack was not touched, and %s", err, u.composeAsRead())
	}
	for _, name := range r.Managed() {
		if info, err := os.Lstat(name); err == nil && !info.Mode().IsRegular() {
			return fmt.Errorf("%s, a scaffold file cyfr update replaces, is not a regular file, so the snapshot cannot hold it; nothing was changed", name)
		}
	}
	u.scaffold = r
	return nil
}

// writeScaffold writes the release's scaffold files over the project's.
func (u *updater) writeScaffold() error {
	if err := u.scaffold.Write(true); err != nil {
		return fmt.Errorf("Writing the scaffold files failed (%v)", err)
	}
	fmt.Fprintf(u.out, "Scaffold files updated (%s, wit/, aqua/).\n", strings.Join(scaffold.Guides, ", "))
	return nil
}

// revertScaffold puts the scaffold files back from the snapshot after a
// failure before the start, then starts the old stack as restartOld does;
// scaffold files it cannot put back leave the stack stopped, since the old
// stack must not start under the new release's files.
func (u *updater) revertScaffold(reason error) error {
	if err := putScaffoldBack(u.snapshot, u.scaffold.Managed()); err != nil {
		return fmt.Errorf("%v.\nThe scaffold files could not be put back from the snapshot (%v), so the stack is left stopped; restore the snapshot with:\n  cyfr restore %s", u.redactor().Text(reason.Error()), err, u.snapshot)
	}
	return u.restartOld(fmt.Errorf("%v; the scaffold files were put back from the snapshot %s", reason, u.snapshot))
}

// rosterSlot is one live slot as the roster and the offline read answer it.
type rosterSlot struct {
	Node       string  `json:"node"`
	Owner      *string `json:"owner"`
	Release    *string `json:"release"`
	LeaseUntil string  `json:"lease_until"`
}

func (s rosterSlot) release() string {
	if s.Release == nil || *s.Release == "" {
		return "an unknown release"
	}
	return "release " + *s.Release
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
		return fmt.Errorf("cyfr update could not read the cell's roster through the running cyfr (%v); nothing was changed", err)
	}
	var answer struct {
		Self  string        `json:"self"`
		Slots *[]rosterSlot `json:"slots"`
	}
	payload, err := markedLine(output, "CYFR_ROSTER=")
	if err == nil {
		err = json.Unmarshal([]byte(payload), &answer)
	}
	if err == nil && (answer.Self == "" || answer.Slots == nil) {
		err = errors.New("no node or no slots")
	}
	if err != nil {
		return fmt.Errorf("The cell's roster did not read (%v); cyfr update reads no answer as an empty roster, and nothing was changed", err)
	}
	var foreign []string
	for _, slot := range *answer.Slots {
		if slot.Node != answer.Self && !u.onTarget(slot) {
			foreign = append(foreign, fmt.Sprintf("%s (%s)", slot.Node, slot.release()))
		}
	}
	if len(foreign) > 0 {
		return fmt.Errorf("The cell has a live member outside this stack on another release than %s: %s. cyfr update cannot stop it; stop it first, then run 'cyfr update' again. Nothing was changed", u.version, strings.Join(foreign, ", "))
	}
	return nil
}

// listRunning reads the stack's running services into u.running.
func (u *updater) listRunning(ctx context.Context) error {
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
	return nil
}

// onTarget reports whether slot's member runs the release this update
// installs; a slot naming no release does not.
func (u *updater) onTarget(slot rosterSlot) bool {
	return slot.Release != nil && *slot.Release == u.version
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
		return fmt.Errorf("A slot is still live %s after the stop: %s. A member outside this stack holds the cell; stop it first", liveSlotsWindow, slotNames(others))
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
		nodes = append(nodes, fmt.Sprintf("%s (%s)", slot.Node, slot.release()))
	}
	return strings.Join(nodes, ", ")
}

// snapshotManifest is snapshot.json, written last: its presence marks a
// complete snapshot.
type snapshotManifest struct {
	Version        string   `json:"version"`
	TakenAt        string   `json:"taken_at"`
	Parts          []string `json:"parts"`
	StorageAdapter string   `json:"storage_adapter"`
	// Scaffold names every scaffold file the update replaces
	// (scaffold.IsManaged), each held under scaffold/ when it was there
	// before the update and absent from it when the update created it.
	Scaffold []string `json:"scaffold"`
	Complete bool     `json:"complete"`
}

// takeSnapshot copies the stopped cell into backups/<UTC timestamp>/: the
// database, the local storage root, the scaffold files the release
// replaces, the keyring, .env and the compose file as it stood before the
// switch, then snapshot.json. Directories are 0700 and files 0600.
// backups/ holds a .gitignore ignoring all of it, since a snapshot holds
// the keyring.
func (u *updater) takeSnapshot() error {
	now := updateNow().UTC()
	if err := os.Mkdir("backups", 0700); err != nil && !errors.Is(err, fs.ErrExist) {
		return err
	}
	if err := writeNewFile(filepath.Join("backups", ".gitignore"), []byte(backupsIgnore)); err != nil && !errors.Is(err, fs.ErrExist) {
		return err
	}
	dir := filepath.Join("backups", now.Format("20060102T150405Z"))
	if err := os.Mkdir(dir, 0700); err != nil {
		return err
	}
	if abs, err := filepath.Abs(dir); err == nil {
		dir = abs
	}
	u.snapshot = dir
	fmt.Fprintf(u.out, "Taking a snapshot into %s...\n", dir)
	c := u.config
	var parts []string

	switch c.adapter {
	case "sqlite":
		if err := copyFile(c.sqliteFile, filepath.Join(dir, "database")); err != nil {
			return err
		}
		parts = append(parts, "database")
		if info, err := os.Stat(c.sqliteFile + "-wal"); err == nil && info.Mode().IsRegular() && info.Size() > 0 {
			if err := copyFile(c.sqliteFile+"-wal", filepath.Join(dir, "database-wal")); err != nil {
				return err
			}
			parts = append(parts, "database-wal")
		}
	case "postgres":
		if err := u.dumpPostgres(filepath.Join(dir, "database")); err != nil {
			return err
		}
		parts = append(parts, "database")
	}

	if c.storage == "local" {
		exclude := map[string]bool{}
		if c.sqliteFile != "" {
			for _, suffix := range []string{"", "-wal", "-shm"} {
				exclude[filepath.Clean(c.sqliteFile+suffix)] = true
			}
		}
		// The access engine's state is no part of any snapshot, whatever
		// mount reaches it: a restored home's lock, journal and receipts
		// are the machine's own, never the backup's.
		if state, err := filepath.Abs(".cyfr"); err == nil {
			if resolved, err := filepath.EvalSymlinks(state); err == nil {
				state = resolved
			}
			exclude[state] = true
		}
		if err := copyStorage(c.storageMounts, filepath.Join(dir, "storage"), exclude, u.out); err != nil {
			return err
		}
		parts = append(parts, "storage")
	} else {
		fmt.Fprintln(u.out, s3OutsideSnapshot)
	}

	managed := u.scaffold.Managed()
	if err := copyScaffold(managed, filepath.Join(dir, "scaffold")); err != nil {
		return err
	}
	parts = append(parts, "scaffold")

	if err := writeNewFile(filepath.Join(dir, "keyring"), []byte(c.keyring)); err != nil {
		return err
	}
	parts = append(parts, "keyring")
	if err := copyFile(".env", filepath.Join(dir, ".env")); err != nil {
		return err
	}
	parts = append(parts, ".env")
	// The compose file as it stood before the switch, so a restore puts the
	// old release's image lines back with the rest.
	if err := writeNewFile(filepath.Join(dir, "compose"), u.compose.original); err != nil {
		return err
	}
	parts = append(parts, "compose")

	data, err := json.MarshalIndent(snapshotManifest{
		Version:        u.oldRelease,
		TakenAt:        now.Format(time.RFC3339),
		Parts:          parts,
		StorageAdapter: c.storage,
		Scaffold:       managed,
		Complete:       true,
	}, "", "  ")
	if err != nil {
		return err
	}
	// Written to a temporary name, synced and renamed, so snapshot.json
	// exists only whole and only after every part is.
	tmp := filepath.Join(dir, ".snapshot.json.tmp")
	if err := writeNewFile(tmp, append(data, '\n')); err != nil {
		return err
	}
	if err := os.Rename(tmp, filepath.Join(dir, "snapshot.json")); err != nil {
		return err
	}
	if d, err := os.Open(dir); err == nil {
		d.Sync()
		d.Close()
	}
	return nil
}

// backupsIgnore is backups/.gitignore: nothing under backups/ is tracked.
const backupsIgnore = "# Snapshots hold the keyring and the database; never commit them.\n*\n"

// copyScaffold copies each of the scaffold files names that is there into
// dst at its own relative path, the absent ones left out.
func copyScaffold(names []string, dst string) error {
	if err := os.Mkdir(dst, 0700); err != nil {
		return err
	}
	for _, name := range names {
		info, err := os.Lstat(name)
		if errors.Is(err, fs.ErrNotExist) {
			continue
		}
		if err != nil {
			return err
		}
		if !info.Mode().IsRegular() {
			return fmt.Errorf("%s is not a regular file", name)
		}
		target := filepath.Join(dst, name)
		if err := os.MkdirAll(filepath.Dir(target), 0700); err != nil {
			return err
		}
		if err := copyFile(name, target); err != nil {
			return err
		}
	}
	return nil
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
	out, err := os.OpenFile(dst, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return err
	}
	_, err = io.Copy(out, in)
	return errors.Join(err, out.Sync(), out.Close())
}

// copyStorage copies the storage root as cyfr sees it into dst: each mount
// in order, shallower first, into its place under dst, leaving out of each
// the host paths a deeper mount covers in the container, so every byte
// copied is one cyfr reads and none it reads is missing.
func copyStorage(mounts []storageMount, dst string, exclude map[string]bool, out io.Writer) error {
	for i, m := range mounts {
		skip := maps.Clone(exclude)
		for _, deeper := range mounts[i+1:] {
			if m.rel == "" {
				skip[filepath.Join(m.host, filepath.FromSlash(deeper.rel))] = true
			} else if rest, ok := strings.CutPrefix(deeper.rel, m.rel+"/"); ok {
				skip[filepath.Join(m.host, filepath.FromSlash(rest))] = true
			}
		}
		target := filepath.Join(dst, filepath.FromSlash(m.rel))
		if m.rel != "" {
			if err := os.MkdirAll(filepath.Dir(target), 0700); err != nil {
				return err
			}
		}
		if !m.dir {
			if err := copyFile(m.host, target); err != nil {
				return err
			}
			continue
		}
		if err := copyTree(m.host, target, skip, out); err != nil {
			return err
		}
	}
	return nil
}

// copyTree copies the directory root to the new directory dst: directories
// 0700, regular files 0600, a symlink as the link it is, never followed;
// the host paths in exclude, and everything under an excluded directory,
// are left out, and any other kind of entry is skipped and named.
func copyTree(root, dst string, exclude map[string]bool, out io.Writer) error {
	return filepath.WalkDir(root, func(p string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if exclude[filepath.Clean(p)] {
			// An excluded directory is a deeper mount's place: nothing under
			// it is the root's.
			if entry.IsDir() {
				return fs.SkipDir
			}
			return nil
		}
		rel, err := filepath.Rel(root, p)
		if err != nil {
			return err
		}
		target := filepath.Join(dst, rel)
		switch mode := entry.Type(); {
		case entry.IsDir():
			return os.Mkdir(target, 0700)
		case mode&fs.ModeSymlink != 0:
			link, err := os.Readlink(p)
			if err != nil {
				return err
			}
			return os.Symlink(link, target)
		case mode.IsRegular():
			return copyFile(p, target)
		default:
			fmt.Fprintf(out, "Skipped %s, neither a file, a directory nor a link.\n", p)
			return nil
		}
	})
}

// ---- the switch -----------------------------------------------------------------

// switchImages writes the planned compose file over one that is still the
// file the plan read, then lets ensureCyfrComposeFields add any field cyfr
// requires.
func (u *updater) switchImages() error {
	current, err := os.ReadFile(u.compose.path)
	if err != nil || !bytes.Equal(current, u.compose.original) {
		return fmt.Errorf("%s changed while cyfr update ran; the snapshot is %s", u.compose.path, u.snapshot)
	}
	info, err := os.Stat(u.compose.path)
	if err != nil {
		return err
	}
	if err := writeFileAtomic(u.compose.path, u.compose.rewritten, info.Mode().Perm()); err != nil {
		return err
	}
	added, err := ensureComposeFields(u.compose.path, u.boundTargets)
	if err != nil {
		// The old stack starts again under the file it was created from.
		if perr := replaceCompose(u.compose.path, u.compose.original, info.Mode().Perm()); perr != nil {
			return fmt.Errorf("%w: %s could not gain the fields cyfr requires (%v), and the file the update read could not be put back (%v)", errComposeLeftSwitched, u.compose.path, err, perr)
		}
		return fmt.Errorf("%s could not gain the fields cyfr requires (%v); it was put back as the update read it", u.compose.path, err)
	}
	if len(added) > 0 {
		fmt.Fprintf(u.out, "Added missing fields to docker-compose.yml: %v\n", added)
	}
	return nil
}

// errComposeLeftSwitched is a switch that failed with the switched compose
// file still in place, so the old stack must not start under it.
var errComposeLeftSwitched = errors.New("the compose file is left switched")

// up starts the switched stack through the one start path every cyfr
// start takes (access.Engine.Start): the stack checked, a tailnet node
// validated before Serve opens, and cyfr's health awaited, the image's
// health check being its readiness.
func (u *updater) up() error {
	fmt.Fprintf(u.out, "Starting release %s...\n", u.version)
	err := u.start("update")
	if local := (startedLocally{}); errors.As(err, &local) {
		u.servedLocally = err
		return nil
	}
	return err
}

// start starts the stack as .env and the compose file hold it, through the
// one start path (access.Engine.StartWithin), cause naming the command,
// waiting startHealth for cyfr's health. A start that leaves the home on
// this machine alone answers startedLocally.
func (u *updater) start(cause string) error {
	return answerFailure(u.engine.StartWithin(context.WithoutCancel(u.ctx), cause, startHealth))
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
		return fmt.Errorf("%v.\nThe old stack is left stopped: %s, so it is not started under it. Start the stack with 'cyfr up' once docker-compose.yml is the configuration you mean to run", u.redactor().Text(reason.Error()), u.composeAsRead())
	}
	fmt.Fprintln(u.out, "Starting the old stack again...")
	err := u.start("update")
	if local := (startedLocally{}); errors.As(err, &local) {
		return fmt.Errorf("%v.\nThe old stack was started again, on this machine alone; docker-compose.yml is unchanged. %v", u.redactor().Text(reason.Error()), err)
	}
	if err != nil {
		return fmt.Errorf("%v.\nThe old stack did not start again (%v); docker-compose.yml is unchanged, so 'cyfr up' starts it", u.redactor().Text(reason.Error()), err)
	}
	return fmt.Errorf("%v.\nThe old stack was started again; docker-compose.yml is unchanged", u.redactor().Text(reason.Error()))
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
	message := fmt.Sprintf("Release %s did not start (%v); the stack is left stopped", u.version, reason)
	if err := u.stopFailedStart(ctx); err != nil {
		message = fmt.Sprintf("Release %s did not start (%v), and %v; stop it with 'cyfr down'", u.version, reason, err)
	}
	return fmt.Errorf("%s.\nThe snapshot of release %s is %s; restore it with:\n  cyfr restore %s", message, u.oldRelease, u.snapshot, u.snapshot)
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
	if len(u.compose.overrides) > 0 {
		fmt.Fprintln(u.out, "Image lines left as written (not managed by cyfr update):")
		for _, line := range u.compose.overrides {
			fmt.Fprintf(u.out, "  %s: %s\n", line.service, line.value)
		}
	}
}

// requiredVolumes are the cyfr service's default mounts, each added only when
// no volume of the service, in short or long syntax, already targets its
// container path: a customized source keeps its own.
var requiredVolumes = []string{
	"./data:/app/data",
	"./aqua:/app/seed/aqua",
}

// requiredPorts must appear in the cyfr service's ports list, each spelled as
// the shipped docker-compose.yml spells it. Bound to the loopback interface:
// the Codex CLI and the browser talk to http://127.0.0.1:${CYFR_PORT:-4000},
// but the un-TLS'd endpoint is never published to the internet (Caddy fronts
// :80/:443 and reaches cyfr over the compose network).
var requiredPorts = []string{
	"127.0.0.1:${CYFR_PORT:-4000}:${CYFR_PORT:-4000}",
}

// requiredEnvFiles must appear in the cyfr service's env_file list.
var requiredEnvFiles = []string{
	".env",
}

// ensureCyfrComposeFields parses docker-compose.yml, locates the cyfr service,
// and ensures all required fields are present. Missing volumes, ports,
// env_file entries, and container_name are added. Existing user content
// (env vars, networks, labels, custom additions) is preserved.
//
// Returns a list of human-readable descriptions of what was added (empty if
// nothing was missing). Returns an error if the file can't be parsed as YAML
// or if no cyfr service can be found.
func ensureCyfrComposeFields(path string) ([]string, error) {
	return ensureComposeFields(path, nil)
}

// ensureComposeFields is ensureCyfrComposeFields with bound, when not nil,
// the container paths compose itself resolves a mount of the cyfr service
// at: no default mount is added at one of them, whatever form binds it.
func ensureComposeFields(path string, bound map[string]bool) ([]string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("docker-compose.yml not found")
	}

	var root yaml.Node
	if err := yaml.Unmarshal(data, &root); err != nil {
		return nil, fmt.Errorf("docker-compose.yml is not valid YAML: %w", err)
	}
	if root.Kind != yaml.DocumentNode || len(root.Content) == 0 {
		return nil, fmt.Errorf("docker-compose.yml is empty")
	}

	doc := root.Content[0]
	if doc.Kind != yaml.MappingNode {
		return nil, fmt.Errorf("docker-compose.yml top level is not a mapping")
	}

	servicesNode := mapValue(doc, "services")
	if servicesNode == nil || servicesNode.Kind != yaml.MappingNode {
		return nil, fmt.Errorf("docker-compose.yml has no `services:` section")
	}

	// Find the cyfr service. We look for a service literally named `cyfr`
	// first; if not present, fall back to the first service whose
	// `container_name` is `cyfr` (some users rename the service key).
	cyfrNode := mapValue(servicesNode, "cyfr")
	if cyfrNode == nil {
		for i := 0; i < len(servicesNode.Content); i += 2 {
			if i+1 >= len(servicesNode.Content) {
				break
			}
			svc := servicesNode.Content[i+1]
			if svc.Kind != yaml.MappingNode {
				continue
			}
			if cn := mapValue(svc, "container_name"); cn != nil && cn.Value == "cyfr" {
				cyfrNode = svc
				break
			}
		}
	}
	if cyfrNode == nil || cyfrNode.Kind != yaml.MappingNode {
		return nil, fmt.Errorf("docker-compose.yml has no `cyfr` service (looked for `services.cyfr` and `container_name: cyfr`)")
	}

	var added []string

	// container_name: cyfr — stable name for `docker compose` / `docker logs cyfr`.
	if cn := mapValue(cyfrNode, "container_name"); cn == nil {
		setMapValue(cyfrNode, "container_name", &yaml.Node{
			Kind:  yaml.ScalarNode,
			Tag:   "!!str",
			Value: "cyfr",
		})
		added = append(added, "container_name: cyfr")
	}

	// volumes — ensure each required mount's target is bound, matched by
	// the container path as compose reads it, its variables taken from the
	// environment and the project's .env, so a customized source is never
	// shadowed by a second mount at its target.
	lookup := composeEnv(filepath.Join(filepath.Dir(path), ".env"))
	for _, mount := range requiredVolumes {
		if ensureVolumeTarget(cyfrNode, mount, lookup, bound) {
			added = append(added, "volumes: "+mount)
		}
	}

	// ports — ensure the cyfr listener's port is published. We match by
	// container port and protocol as compose reads them, its variables taken
	// from the environment and the project's .env (any host-binding form
	// counts), so an existing "4000:4000" isn't duplicated; only a project
	// publishing no tcp mapping of that port, a udp-only one included, gets
	// the loopback-bound entry added (existing 0.0.0.0 publishes are left
	// alone).
	for _, port := range requiredPorts {
		if ensurePublishedPort(cyfrNode, port, lookup) {
			added = append(added, "ports: "+port)
		}
	}

	// env_file — ensure .env is referenced.
	for _, ef := range requiredEnvFiles {
		if ensureSequenceItem(cyfrNode, "env_file", ef) {
			added = append(added, "env_file: "+ef)
		}
	}

	if len(added) == 0 {
		return nil, nil
	}

	// Re-serialize with 2-space indentation to match the cyfr init template
	// (yaml.v3 defaults to 4 spaces, which would surprise users on update).
	var buf strings.Builder
	enc := yaml.NewEncoder(&buf)
	enc.SetIndent(2)
	if err := enc.Encode(&root); err != nil {
		return nil, fmt.Errorf("failed to re-serialize docker-compose.yml: %w", err)
	}
	if err := enc.Close(); err != nil {
		return nil, fmt.Errorf("failed to close encoder: %w", err)
	}
	info, err := os.Stat(path)
	if err != nil {
		return nil, fmt.Errorf("failed to write docker-compose.yml: %w", err)
	}
	if err := replaceCompose(path, []byte(buf.String()), info.Mode().Perm()); err != nil {
		return nil, fmt.Errorf("failed to write docker-compose.yml: %w", err)
	}
	return added, nil
}

// replaceCompose replaces the compose file whole with the mode given, so a
// write that fails or dies leaves the file as it was: the fields' rewrite
// and the switch's put-back. A variable so a test can fail it.
var replaceCompose = writeFileAtomic

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

// setMapValue sets a key in a mapping node, replacing it if present or
// appending it if absent.
func setMapValue(m *yaml.Node, key string, value *yaml.Node) {
	if m == nil || m.Kind != yaml.MappingNode {
		return
	}
	for i := 0; i < len(m.Content); i += 2 {
		if i+1 >= len(m.Content) {
			break
		}
		if m.Content[i].Value == key {
			m.Content[i+1] = value
			return
		}
	}
	m.Content = append(m.Content,
		&yaml.Node{Kind: yaml.ScalarNode, Tag: "!!str", Value: key},
		value,
	)
}

// composeEnv returns the lookup compose expands docker-compose.yml's
// variables with: the process environment, then the dotenv file at envPath.
func composeEnv(envPath string) func(string) (string, bool) {
	dotenv, err := access.ReadEnvValues(envPath)
	if err != nil {
		dotenv = map[string]string{}
	}
	return func(name string) (string, bool) {
		if value, ok := os.LookupEnv(name); ok {
			return value, true
		}
		value, ok := dotenv[name]
		return value, ok
	}
}

// interpolate expands s's variables as compose does, each value taken from
// lookup: `$$` is a literal `$`; `$VAR` and `${VAR}` are VAR's value, empty
// when unset; `${VAR:-word}` is word when VAR is unset or empty and
// `${VAR-word}` when it is unset; `${VAR:+word}` is word when VAR is set and
// non-empty and `${VAR+word}` when it is set, else empty; `${VAR:?err}` and
// `${VAR?err}` refuse where `:-` and `-` would take the word. A word may hold
// variables itself. ok is false where compose refuses the text.
func interpolate(s string, lookup func(string) (string, bool)) (string, bool) {
	var out strings.Builder
	for i := 0; i < len(s); i++ {
		if s[i] != '$' || i+1 == len(s) {
			out.WriteByte(s[i])
			continue
		}
		switch next := s[i+1]; {
		case next == '$':
			out.WriteByte('$')
			i++
		case next == '{':
			end := closingBrace(s, i+1)
			if end < 0 {
				return "", false
			}
			value, ok := substitute(s[i+2:end], lookup)
			if !ok {
				return "", false
			}
			out.WriteString(value)
			i = end
		case isNameByte(next, true):
			end := i + 2
			for end < len(s) && isNameByte(s[end], false) {
				end++
			}
			value, _ := lookup(s[i+1 : end])
			out.WriteString(value)
			i = end - 1
		default:
			out.WriteByte('$')
		}
	}
	return out.String(), true
}

// substitute expands the body of one `${…}`.
func substitute(body string, lookup func(string) (string, bool)) (string, bool) {
	n := 0
	for n < len(body) && isNameByte(body[n], n == 0) {
		n++
	}
	if n == 0 {
		return "", false
	}
	value, set := lookup(body[:n])
	op := body[n:]
	if op == "" {
		return value, true
	}
	colon := op[0] == ':'
	if colon {
		op = op[1:]
	}
	if op == "" {
		return "", false
	}
	word := op[1:]
	present := set && (!colon || value != "")
	switch op[0] {
	case '-':
		if present {
			return value, true
		}
		return interpolate(word, lookup)
	case '+':
		if present {
			return interpolate(word, lookup)
		}
		return "", true
	case '?':
		return value, present
	}
	return "", false
}

// closingBrace returns the index of the brace closing the one at open,
// counting the braces between; -1 when it is unclosed.
func closingBrace(s string, open int) int {
	depth := 0
	for i := open; i < len(s); i++ {
		switch s[i] {
		case '{':
			depth++
		case '}':
			if depth--; depth == 0 {
				return i
			}
		}
	}
	return -1
}

// isNameByte reports whether b may stand in a variable's name, first when it
// would begin it.
func isNameByte(b byte, first bool) bool {
	return b == '_' || 'a' <= b && b <= 'z' || 'A' <= b && b <= 'Z' || !first && '0' <= b && b <= '9'
}

// portSpec is the container side of a compose `ports` entry: the ports first
// through last, and the protocol.
type portSpec struct {
	first, last uint64
	protocol    string
}

// publishes reports whether p publishes want's first port under its protocol.
func (p portSpec) publishes(want portSpec) bool {
	return p.protocol == want.protocol && p.first <= want.first && want.first <= p.last
}

// publishedPort reads the container side of a compose `ports` entry as
// compose does, after expanding its variables with lookup: the short syntax
// `[[host_ip:]host_port:]container_port[/protocol]`, either port a single
// port or a range and an IPv6 host_ip holding colons of its own, or the long
// syntax's mapping, its `target` and `protocol`. An alias entry reads as the
// entry it names. The protocol defaults to tcp. ok is false when the entry's
// container port does not read as one.
func publishedPort(entry *yaml.Node, lookup func(string) (string, bool)) (portSpec, bool) {
	if entry.Kind == yaml.AliasNode {
		entry = entry.Alias
	}
	var target, protocol string
	switch entry.Kind {
	case yaml.ScalarNode:
		mapping, ok := interpolate(entry.Value, lookup)
		if !ok {
			return portSpec{}, false
		}
		target, protocol, _ = strings.Cut(mapping[strings.LastIndexByte(mapping, ':')+1:], "/")
	case yaml.MappingNode:
		node := mapValue(entry, "target")
		if node == nil || node.Kind != yaml.ScalarNode {
			return portSpec{}, false
		}
		var ok bool
		if target, ok = interpolate(node.Value, lookup); !ok {
			return portSpec{}, false
		}
		if node := mapValue(entry, "protocol"); node != nil {
			if node.Kind != yaml.ScalarNode {
				return portSpec{}, false
			}
			if protocol, ok = interpolate(node.Value, lookup); !ok {
				return portSpec{}, false
			}
		}
	default:
		return portSpec{}, false
	}
	low, high, isRange := strings.Cut(target, "-")
	first, err := strconv.ParseUint(low, 10, 16)
	if err != nil {
		return portSpec{}, false
	}
	last := first
	if isRange {
		if last, err = strconv.ParseUint(high, 10, 16); err != nil || last < first {
			return portSpec{}, false
		}
	}
	if protocol = strings.ToLower(protocol); protocol == "" {
		protocol = "tcp"
	}
	return portSpec{first, last, protocol}, true
}

// ensurePublishedPort makes sure the service publishes want's container port
// under want's protocol in some form, every entry and want read with lookup.
// If no existing `ports` entry publishes it, want is appended. An entry whose
// container port does not read leaves the list as it is, since it may be the
// port itself, and so does a want that does not read. Returns true if want
// was added.
func ensurePublishedPort(svc *yaml.Node, want string, lookup func(string) (string, bool)) bool {
	wantSpec, ok := publishedPort(&yaml.Node{Kind: yaml.ScalarNode, Value: want}, lookup)
	if !ok {
		return false
	}
	if seq := mapValue(svc, "ports"); seq != nil && seq.Kind == yaml.SequenceNode {
		for _, child := range seq.Content {
			if spec, ok := publishedPort(child, lookup); !ok || spec.publishes(wantSpec) {
				return false
			}
		}
	}
	return ensureSequenceItem(svc, "ports", want)
}

// volumeTarget answers the container path a volumes entry mounts at, as
// compose reads it: a long-syntax mapping's target, or a short-syntax
// [SOURCE:]TARGET[:MODE] string's TARGET, its variables interpolated with
// lookup. ok is false for an entry whose target does not read.
func volumeTarget(entry *yaml.Node, lookup func(string) (string, bool)) (string, bool) {
	if entry.Kind == yaml.AliasNode && entry.Alias != nil {
		entry = entry.Alias
	}
	var target string
	switch entry.Kind {
	case yaml.MappingNode:
		t := mapValue(entry, "target")
		if t == nil || t.Kind != yaml.ScalarNode {
			return "", false
		}
		target = t.Value
	case yaml.ScalarNode:
		spec, ok := interpolate(entry.Value, lookup)
		if !ok {
			return "", false
		}
		parts := strings.Split(spec, ":")
		// A Windows drive letter (C:\...) splits off a one-letter field.
		if len(parts) > 2 && len(parts[0]) == 1 && strings.HasPrefix(parts[1], `\`) {
			parts = append([]string{parts[0] + ":" + parts[1]}, parts[2:]...)
		}
		switch len(parts) {
		case 1:
			target = parts[0]
		default:
			target = parts[1]
		}
		return path.Clean(target), target != ""
	default:
		return "", false
	}
	target, ok := interpolate(target, lookup)
	return path.Clean(target), ok && target != ""
}

// ensureVolumeTarget adds mount ("SOURCE:TARGET") to svc's volumes unless
// TARGET is bound, and reports whether it did. TARGET is bound when bound
// names it (compose's own resolution), or when an entry of the volumes svc
// has or inherits through YAML merge keys targets it; an entry whose target
// does not read counts as binding it, and so does any target of a service
// that extends another when bound is nil, since its volumes are not in
// this file. A list svc inherits, or reaches through an alias another
// service may share, is copied into its own volumes with the mount, never
// replaced by a list of the mount alone nor appended to in place; an
// anchored list of its own, which other services may alias, is left as it
// is and nothing is added.
func ensureVolumeTarget(svc *yaml.Node, mount string, lookup func(string) (string, bool), bound map[string]bool) bool {
	_, want, _ := strings.Cut(mount, ":")
	want = path.Clean(want)
	if bound[want] || bound == nil && mapValue(svc, "extends") != nil {
		return false
	}
	seq, own := serviceVolumes(svc, 0)
	if seq == nil {
		return ensureSequenceItem(svc, "volumes", mount)
	}
	if seq.Kind != yaml.SequenceNode {
		return false
	}
	for _, entry := range seq.Content {
		target, ok := volumeTarget(entry, lookup)
		if !ok || target == want {
			return false
		}
	}
	item := &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!str", Value: mount}
	direct := mapValue(svc, "volumes")
	if own && direct != nil && direct.Kind != yaml.AliasNode {
		if seq.Anchor != "" {
			return false
		}
		seq.Content = append(seq.Content, item)
		return true
	}
	inherited := &yaml.Node{Kind: yaml.SequenceNode, Tag: "!!seq"}
	for _, entry := range seq.Content {
		inherited.Content = append(inherited.Content, copyNode(entry))
	}
	inherited.Content = append(inherited.Content, item)
	setMapValue(svc, "volumes", inherited)
	return true
}

// serviceVolumes answers the volumes sequence of the service mapping svc,
// its own key or, as serviceImage reads the image, the one it inherits
// through YAML merge keys; own reports whether it is svc's own.
func serviceVolumes(svc *yaml.Node, depth int) (seq *yaml.Node, own bool) {
	if svc != nil && svc.Kind == yaml.AliasNode {
		svc = svc.Alias
	}
	if svc == nil || svc.Kind != yaml.MappingNode || depth > 16 {
		return nil, false
	}
	if node := mapValue(svc, "volumes"); node != nil {
		if node.Kind == yaml.AliasNode {
			node = node.Alias
		}
		return node, depth == 0
	}
	merge := mapValue(svc, "<<")
	if merge == nil {
		return nil, false
	}
	sources := []*yaml.Node{merge}
	if merge.Kind == yaml.SequenceNode {
		sources = merge.Content
	}
	for _, source := range sources {
		if node, _ := serviceVolumes(source, depth+1); node != nil {
			return node, false
		}
	}
	return nil, false
}

// copyNode answers a deep copy of node without its anchors, so the copy
// adds no second anchor of one name to the file; an alias stays the alias
// it is.
func copyNode(node *yaml.Node) *yaml.Node {
	if node.Kind == yaml.AliasNode {
		return node
	}
	c := *node
	c.Anchor = ""
	c.Content = nil
	for _, child := range node.Content {
		c.Content = append(c.Content, copyNode(child))
	}
	return &c
}

// ensureSequenceItem makes sure that the sequence at parent[key] contains
// the given scalar item. If the sequence doesn't exist, it's created. If the
// item is already present (by string equality), nothing changes. Returns
// true if the item was added.
func ensureSequenceItem(parent *yaml.Node, key, item string) bool {
	seq := mapValue(parent, key)
	if seq == nil {
		// Create the sequence with the item as its only element.
		setMapValue(parent, key, &yaml.Node{
			Kind: yaml.SequenceNode,
			Content: []*yaml.Node{
				{Kind: yaml.ScalarNode, Tag: "!!str", Value: item},
			},
		})
		return true
	}
	// An anchored list may be aliased by another service, which an append
	// would change too.
	if seq.Kind != yaml.SequenceNode || seq.Anchor != "" {
		return false
	}
	for _, child := range seq.Content {
		if child.Value == item {
			return false
		}
	}
	seq.Content = append(seq.Content, &yaml.Node{
		Kind:  yaml.ScalarNode,
		Tag:   "!!str",
		Value: item,
	})
	return true
}
