// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
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
	"syscall"
	"time"
	"unicode/utf8"

	"github.com/cyfr/codex/internal/release"
	"github.com/cyfr/codex/internal/scaffold"
	"github.com/cyfr/codex/internal/version"
	"github.com/spf13/cobra"
	"gopkg.in/yaml.v3"
)

func init() {
	rootCmd.AddCommand(updateCmd)
}

var updateCmd = &cobra.Command{
	Use:   "update",
	Short: "Update the stack to this cyfr's release: verified images, a snapshot, then the switch",
	Long: `Update the project in the current directory to the release this cyfr was built as, in one ceremony that changes nothing until the old stack is stopped and a snapshot of it is taken.

1. Fetch the release's signed manifest (release.json) and verify it; a manifest that does not verify, or no network access to it, refuses.
2. Read docker-compose.yml. Every bundled service (locus-runtime, locus-builds, locus-backends and both egress guards) must be present; one missing refuses, naming 'cyfr init --force'. An image line naming ghcr.io/cyfrworks/cyfr, ghcr.io/cyfrworks/cyfr-locus or the bundled Caddy is managed; any other image is an override, left as written and reported.
3. While the stack still runs: read its configuration, pull every managed image by the manifest's digest, read the cell's roster, refusing while a member outside this stack holds a live slot on another release than this one (a host of the cell already updated stays), then update the scaffold files (guides, WIT definitions, the keeper's seccomp profile, the shipped AQUA prompts).
4. Stop every service, timing each, and re-read the roster offline until no slot of another release than this one is live (at most one lease); one still live restarts the old stack and refuses.
5. Snapshot the database, the local storage root, the keyring, .env and docker-compose.yml as it stands into backups/<UTC timestamp>/, snapshot.json last.
6. Rewrite the managed image lines to <image>:<version>@<digest> (Caddy keeps its tag) and start the stack, waiting for every service to be healthy. A failure from here leaves the stack stopped and prints the snapshot and the restore command; old code never starts over migrated data.

An interrupt before the stop changes nothing; from the stop on, the running step finishes and the update ends as that step's failure would.`,
	GroupID: "server",
	Example: "  cyfr update",
	RunE: func(cmd *cobra.Command, args []string) error {
		return runUpdate(cmd.Context(), cmd.OutOrStdout(), cmd.ErrOrStderr())
	},
}

// The release's manifest and the scaffold files, each a package variable so
// tests substitute them; production calls the verified release fetch and
// the checksum-verified scaffold update.
var (
	fetchManifest  = release.FetchManifest
	updateScaffold = scaffold.Update
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
	// updateLockName is the file in the project directory that admits one
	// update at a time; it holds the updating process's pid.
	updateLockName = ".cyfr-update.lock"

	// rosterExpr reads the running cell's live slots through its own node,
	// beside that node's name, so a slot of another node is a member outside
	// this stack.
	rosterExpr = `{:ok, rows} = Arca.ControlPlane.roster(); IO.puts("CYFR_ROSTER=" <> JSON.encode!(%{self: Atom.to_string(node()), release: Prima.Version.current(), slots: Enum.map(rows, fn r -> %{node: r.node, owner: r.owner, release: r.release, lease_until: DateTime.to_iso8601(r.lease_until)} end)}))`
	// liveSlotsExpr reads the live slots offline, in a container of the old
	// image with nothing of the stack running; Cyfr.Release.live_slots/0
	// raises on any error, so an answer is a read.
	liveSlotsExpr = `IO.puts("CYFR_LIVE_SLOTS=" <> JSON.encode!(%{release: Prima.Version.current(), slots: Cyfr.Release.live_slots()}))`

	// pgImageProbe is the client image the server's major is read with; the
	// dump runs in postgres:<that major>.
	pgImageProbe = "postgres:18"
	// pgURLVariable carries the database URL into a postgres container
	// through the child's environment, never its argv.
	pgURLVariable = "CYFR_UPDATE_PG_URL"

	pullTimeout       = 30 * time.Minute
	composeRunTimeout = 2 * time.Minute
	stopTimeout       = 10 * time.Minute
	dumpTimeout       = 60 * time.Minute
	upWaitSeconds     = "900"

	// appWorkdir is the cyfr image's WORKDIR, against which the server
	// expands a relative path setting.
	appWorkdir = "/app"
)

// bundledServices are the services of the bundled stack besides cyfr, whose
// fields ensureCyfrComposeFields keeps; caddy is the TLS profile's and
// optional to a project that never runs one.
var bundledServices = []string{"locus-runtime", "locus-builds", "locus-backends", "locus-builds-guard", "locus-backends-guard"}

// stopOrder is the order the stop step stops services in: the proxy first,
// then cyfr, then each Locus service before the guard whose network
// namespace it shares.
var stopOrder = []string{"caddy", "cyfr", "locus-runtime", "locus-builds", "locus-backends", "locus-builds-guard", "locus-backends-guard"}

// managedRepositories are the repositories the release's manifest carries a
// digest for, normalized as Docker normalizes a reference.
var managedRepositories = []string{release.RepoCyfr, release.RepoCyfrLocus, release.RepoCaddy}

var manifestDigest = regexp.MustCompile(`^sha256:[0-9a-f]{64}$`)

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
// anything stopped.
var errUpdateInterrupted = errors.New("cyfr update was interrupted before anything stopped; the running stack and docker-compose.yml are unchanged")

// runUpdate is `cyfr update` in the working directory. ctx is cancelled by
// SIGINT or SIGTERM (main's signal context): before the stop step the
// cancellation aborts the update with nothing changed; from the stop step
// on, every step runs under a context detached from it, and the update ends
// after the running step as that step's failure would.
func runUpdate(ctx context.Context, out, errOut io.Writer) error {
	if ctx == nil {
		ctx = context.Background()
	}
	if _, err := os.Stat("cyfr.yaml"); err != nil {
		return errors.New("Not in a cyfr project directory (no cyfr.yaml found).\nRun 'cyfr init' to create a new project.")
	}
	unlock, err := takeUpdateLock()
	if err != nil {
		return err
	}
	defer unlock()

	v := version.Version
	if v == "" || v == "dev" {
		return errors.New("This cyfr is a development build, which has no signed release to install; run 'cyfr update' with a released cyfr")
	}
	u := &updater{ctx: ctx, version: v, out: out, errOut: errOut}
	return u.run()
}

// takeUpdateLock creates the update lock, refusing while another update
// holds it, and answers the function that removes it.
func takeUpdateLock() (func(), error) {
	f, err := os.OpenFile(updateLockName, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if errors.Is(err, fs.ErrExist) {
		holder := "an unknown process"
		if data, err := os.ReadFile(updateLockName); err == nil && strings.TrimSpace(string(data)) != "" {
			holder = "pid " + strings.TrimSpace(string(data))
		}
		abs, _ := filepath.Abs(updateLockName)
		return nil, fmt.Errorf("Another cyfr update holds %s (%s). If no update is running, remove the file and run 'cyfr update' again", abs, holder)
	}
	if err != nil {
		return nil, fmt.Errorf("could not take the update lock %s: %w", updateLockName, err)
	}
	_, werr := fmt.Fprintf(f, "%d\n", os.Getpid())
	if err := errors.Join(werr, f.Close()); err != nil {
		os.Remove(updateLockName)
		return nil, fmt.Errorf("could not take the update lock %s: %w", updateLockName, err)
	}
	return func() { os.Remove(updateLockName) }, nil
}

// updater carries one update's state from step to step.
type updater struct {
	ctx         context.Context
	version     string
	out, errOut io.Writer
	profiles    []string
	// secrets are the values held from the effective environment: written
	// only into the snapshot, and taken out of any child output cyfr echoes.
	secrets []string

	manifest *release.Manifest
	compose  *composePlan
	config   *stackConfig
	running  []string
	// stopTimes are the stop step's durations, in the order stopped.
	stopTimes []serviceStop
	// oldRelease is the old stack's version, as its image answers it.
	oldRelease string
	snapshot   string
}

type serviceStop struct {
	service string
	took    time.Duration
}

func (u *updater) run() error {
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
	u.profiles = composeProfiles(".env")

	// Every step before the stop runs under ctx and changes no deployment
	// state, so an interrupt or a failure here leaves the stack running on
	// the compose file as it was. The scaffold files, the one write of these
	// steps, come after every refusal.
	steps := []func() error{u.readConfig, u.probePostgres, u.pull, u.readRoster, u.updateScaffold}
	for _, step := range steps {
		if err := step(); err != nil {
			if u.ctx.Err() != nil {
				return errUpdateInterrupted
			}
			return err
		}
		if u.ctx.Err() != nil {
			return errUpdateInterrupted
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
	if err := u.takeSnapshot(); err != nil {
		where := "no snapshot directory was made"
		if u.snapshot != "" {
			where = "the partial snapshot is " + u.snapshot
		}
		return fmt.Errorf("The snapshot failed: %v.\nThe stack is left stopped and docker-compose.yml is unchanged; %s. Fix the cause and run 'cyfr update' again, or start the old stack with 'cyfr up'", u.redact(err.Error()), where)
	}
	if u.ctx.Err() != nil {
		return u.restartOld(fmt.Errorf("cyfr update was interrupted during the snapshot (complete at %s)", u.snapshot))
	}
	if err := u.switchImages(); err != nil {
		return u.restartOld(err)
	}
	if err := u.up(); err != nil {
		return u.stopAfterSwitch(err)
	}
	u.report()
	return nil
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
		case release.RepoCaddy:
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

// ownProcessGroup answers attributes that start a child in a process group
// of its own, so a terminal's ^C reaches cyfr alone and never a docker
// child in the middle of a stop, a dump or a start: cyfr decides when each
// step ends. Set by field name, since the field is Setpgid on a Unix and
// CREATE_NEW_PROCESS_GROUP in CreationFlags on Windows.
func ownProcessGroup() *syscall.SysProcAttr {
	attr := &syscall.SysProcAttr{}
	fields := reflect.ValueOf(attr).Elem()
	if field := fields.FieldByName("Setpgid"); field.IsValid() && field.Kind() == reflect.Bool {
		field.SetBool(true)
	}
	if field := fields.FieldByName("CreationFlags"); field.IsValid() && field.Kind() == reflect.Uint32 {
		const createNewProcessGroup = 0x00000200
		field.SetUint(field.Uint() | createNewProcessGroup)
	}
	return attr
}

// composeArgs prefixes args with `compose` and the project's profiles.
func (u *updater) composeArgs(args ...string) []string {
	return slices.Concat([]string{"compose"}, profileArgs(u.profiles), args)
}

// docker runs docker with args under ctx, its stdout into stdout (cyfr's
// own when nil) and its stderr into cyfr's, env added to cyfr's
// environment. A child that outlives ctx is killed.
func (u *updater) docker(ctx context.Context, stdout io.Writer, env []string, args ...string) error {
	c := exec.CommandContext(ctx, "docker", args...)
	c.SysProcAttr = ownProcessGroup()
	c.WaitDelay = 10 * time.Second
	if env != nil {
		c.Env = append(os.Environ(), env...)
	}
	c.Stdout = u.out
	if stdout != nil {
		c.Stdout = stdout
	}
	c.Stderr = u.errOut
	return c.Run()
}

// dockerOutput runs docker as docker does and answers its stdout; its
// stderr is echoed after the run with every held secret taken out.
func (u *updater) dockerOutput(ctx context.Context, env []string, args ...string) (string, error) {
	var stdout, stderr bytes.Buffer
	c := exec.CommandContext(ctx, "docker", args...)
	c.SysProcAttr = ownProcessGroup()
	c.WaitDelay = 10 * time.Second
	if env != nil {
		c.Env = append(os.Environ(), env...)
	}
	c.Stdout, c.Stderr = &stdout, &stderr
	err := c.Run()
	if stderr.Len() > 0 {
		io.WriteString(u.errOut, u.redact(stderr.String()))
	}
	return stdout.String(), err
}

// redact takes every held secret out of text.
func (u *updater) redact(text string) string {
	for _, secret := range u.secrets {
		if secret != "" {
			text = strings.ReplaceAll(text, secret, "[redacted]")
		}
	}
	return text
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
	// storageRoot is the local storage root's host path.
	storageRoot string
	// keyring is the snapshot's keyring file, dotenv lines.
	keyring string
}

// composeConfig is the part of `docker compose config --format json` the
// update reads.
type composeConfig struct {
	Services map[string]struct {
		Environment map[string]*string `json:"environment"`
		Volumes     []struct {
			Type   string `json:"type"`
			Source string `json:"source"`
			Target string `json:"target"`
		} `json:"volumes"`
	} `json:"services"`
}

// readConfig reads cyfr's effective environment and mounts from compose and
// derives what the snapshot copies, refusing a setting it cannot snapshot.
func (u *updater) readConfig() error {
	ctx, cancel := context.WithTimeout(u.ctx, composeRunTimeout)
	defer cancel()
	raw, err := u.dockerOutput(ctx, nil, u.composeArgs("config", "--format", "json")...)
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
	env := func(name string) string {
		if value := cyfr.Environment[name]; value != nil {
			return strings.TrimSpace(*value)
		}
		return ""
	}
	// containerToHost maps a container path through the bind mount whose
	// target is its longest prefix.
	containerToHost := func(p string) (string, bool) {
		best, host := -1, ""
		for _, v := range cyfr.Volumes {
			target := path.Clean(v.Target)
			if v.Type != "bind" || v.Source == "" {
				continue
			}
			rel, ok := strings.CutPrefix(p, target)
			if !ok || rel != "" && !strings.HasPrefix(rel, "/") && target != "/" {
				continue
			}
			if len(target) > best {
				best, host = len(target), filepath.Join(v.Source, filepath.FromSlash(rel))
			}
		}
		return host, best >= 0
	}
	settingPath := func(name, fallback string) (string, error) {
		value := fallback
		if raw := cyfr.Environment[name]; raw != nil {
			if value = strings.TrimSpace(*raw); value == "" {
				return "", fmt.Errorf("%s is set but blank; nothing was changed", name)
			}
		}
		if !path.IsAbs(value) {
			value = path.Join(appWorkdir, value)
		}
		return path.Clean(value), nil
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
		u.secrets = append(u.secrets, c.pgURL)
		if parsed, err := url.Parse(c.pgURL); err == nil && parsed.User != nil {
			if password, ok := parsed.User.Password(); ok {
				u.secrets = append(u.secrets, password)
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
		c.storageRoot = resolved
	case "s3":
		c.storage = "s3"
	default:
		return fmt.Errorf("CYFR_STORAGE=%s is neither local nor s3; nothing was changed", storage)
	}

	var keyring []string
	for _, name := range []string{"CYFR_CRYPTO_KEYRING", "CYFR_SECRET_KEY_BASE"} {
		raw := cyfr.Environment[name]
		if raw == nil || strings.TrimSpace(*raw) == "" {
			continue
		}
		u.secrets = append(u.secrets, *raw)
		line, ok := dotenvLine(name, *raw)
		if !ok {
			return fmt.Errorf("%s holds both quote characters or a line break, so the snapshot's keyring file cannot hold it; nothing was changed", name)
		}
		keyring = append(keyring, line)
	}
	if len(keyring) == 0 {
		return errors.New("Neither CYFR_CRYPTO_KEYRING nor CYFR_SECRET_KEY_BASE is set for cyfr, so a snapshot would hold no key to its data; nothing was changed")
	}
	c.keyring = strings.Join(keyring, "\n") + "\n"
	if f, err := os.Open(".env"); err != nil {
		return fmt.Errorf("cyfr update cannot read .env (%v), which the snapshot copies; nothing was changed", err)
	} else {
		f.Close()
	}
	u.config = c
	return nil
}

// dotenvLine spells name=value so parseEnvFile reads value back exactly:
// single-quoted, or double-quoted when value holds a single quote. ok is
// false for a value holding both quotes or a line break.
func dotenvLine(name, value string) (string, bool) {
	switch {
	case strings.ContainsAny(value, "\r\n"):
		return "", false
	case !strings.Contains(value, "'"):
		return name + "='" + value + "'", true
	case !strings.Contains(value, `"`):
		return name + `="` + value + `"`, true
	}
	return "", false
}

// probePostgres reads the PostgreSQL server's major version, which names
// the dump's image; the URL reaches the container through its environment.
func (u *updater) probePostgres() error {
	if u.config.adapter != "postgres" {
		return nil
	}
	ctx, cancel := context.WithTimeout(u.ctx, composeRunTimeout)
	defer cancel()
	answer, err := u.dockerOutput(ctx, []string{pgURLVariable + "=" + u.config.pgURL},
		"run", "--rm", "--network", "host", "-e", pgURLVariable, pgImageProbe,
		"sh", "-c", `exec psql "$`+pgURLVariable+`" -tAc "SHOW server_version_num"`)
	if err != nil {
		return fmt.Errorf("cyfr update could not reach the PostgreSQL server at CYFR_DATABASE_URL to read its version (%v); nothing was changed", err)
	}
	num, err := strconv.Atoi(strings.TrimSpace(answer))
	if err != nil || num < 10000 {
		return errors.New("the PostgreSQL server's version did not read as a number; nothing was changed")
	}
	u.config.pgMajor = num / 10000
	return nil
}

// pgImage is the dump's image, the server's own major.
func (u *updater) pgImage() string { return "postgres:" + strconv.Itoa(u.config.pgMajor) }

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
			return fmt.Errorf("docker pull %s failed (%v); docker-compose.yml and the running stack are unchanged", ref, err)
		}
		if u.ctx.Err() != nil {
			return errUpdateInterrupted
		}
	}
	return nil
}

// updateScaffold refreshes the scaffold files from the release, whose
// checksums the scaffold update verifies itself.
func (u *updater) updateScaffold() error {
	if err := updateScaffold(u.version); err != nil {
		return fmt.Errorf("Failed to update scaffold files (%v); docker-compose.yml and the running stack are unchanged", err)
	}
	fmt.Fprintf(u.out, "Scaffold files updated (%s, wit/, aqua/).\n", strings.Join(scaffold.Guides, ", "))
	return nil
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
	ps, err := u.dockerOutput(ctx, nil, u.composeArgs("ps", "--services", "--status", "running")...)
	if err != nil {
		return fmt.Errorf("docker compose could not list the running services (%v); nothing was changed", err)
	}
	u.running = nil
	for _, line := range strings.Split(ps, "\n") {
		if name := strings.TrimSpace(line); name != "" && !slices.Contains(u.running, name) {
			u.running = append(u.running, name)
		}
	}
	if !slices.Contains(u.running, "cyfr") {
		return nil
	}
	output, err := u.dockerOutput(ctx, nil, u.composeArgs("exec", "-T", "cyfr", "bin/cyfr", "rpc", rosterExpr)...)
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

// onTarget reports whether slot's member runs the release this update
// installs; a slot naming no release does not.
func (u *updater) onTarget(slot rosterSlot) bool {
	return slot.Release != nil && *slot.Release == u.version
}

// ---- stop, re-read, snapshot -----------------------------------------------------

// stop stops every running service one at a time in stopOrder, timing each,
// then the rest at once.
func (u *updater) stop() error {
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
	err := u.docker(ctx, nil, nil, u.composeArgs(append([]string{"stop"}, services...)...)...)
	return time.Since(began), err
}

// rereadOffline reads the live slots with nothing of the stack running,
// until none is live but members of the target release (hosts of the cell
// updated before this one) or the window closes; a member stopped past its
// grace leaves its row until its lease runs out. Any error or unreadable
// answer refuses, never reads as no slot.
func (u *updater) rereadOffline() error {
	deadline := time.Now().Add(liveSlotsWindow)
	for {
		ctx, cancel := u.detached(composeRunTimeout)
		output, err := u.dockerOutput(ctx, nil, u.composeArgs("run", "--rm", "--no-deps", "-T", "cyfr", "bin/cyfr", "eval", liveSlotsExpr)...)
		cancel()
		if err != nil {
			return fmt.Errorf("The offline roster read failed (%v)", err)
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
			return fmt.Errorf("The offline roster read did not answer (%v)", err)
		}
		var others []rosterSlot
		for _, slot := range *answer.Slots {
			if !u.onTarget(slot) {
				others = append(others, slot)
			}
		}
		if len(others) == 0 {
			u.oldRelease = answer.Release
			return nil
		}
		if !time.Now().Add(liveSlotsPoll).Before(deadline) {
			var nodes []string
			for _, slot := range others {
				nodes = append(nodes, fmt.Sprintf("%s (%s)", slot.Node, slot.release()))
			}
			return fmt.Errorf("A slot is still live %s after the stop: %s. A member outside this stack holds the cell; stop it first", liveSlotsWindow, strings.Join(nodes, ", "))
		}
		time.Sleep(liveSlotsPoll)
	}
}

// snapshotManifest is snapshot.json, written last: its presence marks a
// complete snapshot.
type snapshotManifest struct {
	Version        string   `json:"version"`
	TakenAt        string   `json:"taken_at"`
	Parts          []string `json:"parts"`
	StorageAdapter string   `json:"storage_adapter"`
	Complete       bool     `json:"complete"`
}

// takeSnapshot copies the stopped cell into backups/<UTC timestamp>/: the
// database, the local storage root, the keyring, .env and the compose file
// as it stood before the switch, then snapshot.json. Directories are 0700
// and files 0600.
func (u *updater) takeSnapshot() error {
	now := updateNow().UTC()
	if err := os.Mkdir("backups", 0700); err != nil && !errors.Is(err, fs.ErrExist) {
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
		if err := copyTree(c.storageRoot, filepath.Join(dir, "storage"), exclude, u.out); err != nil {
			return err
		}
		parts = append(parts, "storage")
	} else {
		fmt.Fprintln(u.out, "The object store (S3) is outside the snapshot; it relies on the bucket's own versioning.")
	}

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

// dumpPostgres streams pg_dump's custom-format dump of the configured
// database into file, from the server-major image; the URL reaches the
// container through its environment.
func (u *updater) dumpPostgres(file string) error {
	f, err := os.OpenFile(file, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return err
	}
	ctx, cancel := u.detached(dumpTimeout)
	defer cancel()
	var stderr bytes.Buffer
	c := exec.CommandContext(ctx, "docker", "run", "--rm", "--network", "host", "-e", pgURLVariable, u.pgImage(),
		"sh", "-c", `exec pg_dump --format=custom --no-owner "$`+pgURLVariable+`"`)
	c.SysProcAttr = ownProcessGroup()
	c.WaitDelay = 10 * time.Second
	c.Env = append(os.Environ(), pgURLVariable+"="+u.config.pgURL)
	c.Stdout, c.Stderr = f, &stderr
	err = c.Run()
	if stderr.Len() > 0 {
		io.WriteString(u.errOut, u.redact(stderr.String()))
	}
	if err := errors.Join(err, f.Sync(), f.Close()); err != nil {
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

// copyTree copies the directory root to the new directory dst: directories
// 0700, regular files 0600, a symlink as the link it is, never followed;
// the host paths in exclude are left out, and any other kind of entry is
// skipped and named.
func copyTree(root, dst string, exclude map[string]bool, out io.Writer) error {
	return filepath.WalkDir(root, func(p string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if exclude[filepath.Clean(p)] {
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
	if added, err := ensureCyfrComposeFields(u.compose.path); err != nil {
		fmt.Fprintf(u.errOut, "Note: %v\n", err)
	} else if len(added) > 0 {
		fmt.Fprintf(u.out, "Added missing fields to docker-compose.yml: %v\n", added)
	}
	return nil
}

// up starts the switched stack and waits for every service to be healthy;
// the cyfr image's health check is its readiness.
func (u *updater) up() error {
	fmt.Fprintf(u.out, "Starting release %s...\n", u.version)
	return u.docker(context.WithoutCancel(u.ctx), nil, nil, u.composeArgs("up", "-d", "--wait", "--wait-timeout", upWaitSeconds)...)
}

// restartOld starts the old stack again after a failure before the switch,
// when no byte has been migrated, and refuses with reason.
func (u *updater) restartOld(reason error) error {
	if len(u.running) == 0 {
		return fmt.Errorf("%v.\nThe stack was not running before the update; docker-compose.yml is unchanged", u.redact(reason.Error()))
	}
	fmt.Fprintln(u.out, "Starting the old stack again...")
	ctx, cancel := u.detached(stopTimeout)
	defer cancel()
	if err := u.docker(ctx, nil, nil, u.composeArgs("start")...); err != nil {
		return fmt.Errorf("%v.\nThe old stack did not start again (%v); docker-compose.yml is unchanged, so 'cyfr up' starts it", u.redact(reason.Error()), err)
	}
	return fmt.Errorf("%v.\nThe old stack was started again; docker-compose.yml is unchanged", u.redact(reason.Error()))
}

// stopAfterSwitch leaves the stack stopped after a failure from the switch
// on: the new release may have migrated the database, so old code never
// starts over it. The snapshot restores the old release.
func (u *updater) stopAfterSwitch(reason error) error {
	ctx, cancel := u.detached(stopTimeout)
	defer cancel()
	stopErr := u.docker(ctx, nil, nil, u.composeArgs("stop")...)
	message := fmt.Sprintf("Release %s did not start (%v); the stack is left stopped", u.version, reason)
	if stopErr != nil {
		message += fmt.Sprintf(" (docker compose stop failed: %v; stop it with 'cyfr down')", stopErr)
	}
	return fmt.Errorf("%s.\nThe snapshot of release %s is %s; restore it with:\n  cyfr restore %s", message, u.oldRelease, u.snapshot, u.snapshot)
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

// requiredVolumes maps a host path to its container mount path. Each entry
// must appear in the cyfr service's volumes list.
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

	// volumes — ensure each required mount is present.
	for _, mount := range requiredVolumes {
		if ensureSequenceItem(cyfrNode, "volumes", mount) {
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
	lookup := composeEnv(filepath.Join(filepath.Dir(path), ".env"))
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
	if err := os.WriteFile(path, []byte(buf.String()), 0644); err != nil {
		return nil, fmt.Errorf("failed to write docker-compose.yml: %w", err)
	}
	return added, nil
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
	dotenv := parseEnvFile("")
	if data, err := os.ReadFile(envPath); err == nil {
		dotenv = parseEnvFile(string(data))
	}
	return func(name string) (string, bool) {
		if value, ok := os.LookupEnv(name); ok {
			return value, true
		}
		return dotenv.value(name)
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
	if seq.Kind != yaml.SequenceNode {
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
