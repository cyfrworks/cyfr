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
	"maps"
	"net/url"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"time"

	"github.com/cyfr/codex/internal/access"
	"github.com/cyfr/codex/internal/scaffold"
	"github.com/spf13/cobra"
)

var restoreNoStart bool

func init() {
	rootCmd.AddCommand(restoreCmd)
	restoreCmd.Flags().BoolVar(&restoreNoStart, "no-start", false, "Put the snapshot back and declare the restore, leaving the stack stopped")
}

var restoreCmd = &cobra.Command{
	Use:   "restore <snapshot>",
	Short: "Put a snapshot from backups/ back with the whole cluster stopped, and declare the restore",
	Long: `Put back a snapshot 'cyfr update' took (backups/<timestamp>/) and declare the restore, so the next start suspends every credential and method the backup carried until its owner re-enables it.

1. Read the snapshot: snapshot.json must be there and say complete, its parts must be exactly what the directory holds, and its .env must be one cyfr can start CYFR from (no COMPOSE_* setting, and access settings that agree); an incomplete snapshot, a layout cyfr restore cannot invert or a .env cyfr refuses refuses before anything stops.
2. Take the stack's lock, finishing a change an interrupted command left; cancel a tailnet join that waits for approval; then stop this host's stack, timing each service.
3. Bar CYFR from starting: set CYFR_RESTORE_INCOMPLETE=<snapshot> in .env, synced, and remove the stopped cyfr container, so every start of the cyfr service until the restore is declared is a new container that reads the setting and refuses (the image's entrypoint), and 'cyfr up' and 'cyfr update' refuse it too.
4. Put the snapshot's .env (with the setting) back and its docker-compose.yml beside the project's, and read the configuration they give cyfr: the setting must reach the cyfr service, the database, the storage root and every bind mounted under it must be where the snapshot can be put back, and the keyring must be the snapshot's. Only then does the snapshot's docker-compose.yml replace the project's, so the compose file in place delivers the setting at every step. A refusal here puts the two files back as they were, which lifts the bar.
5. Read the cluster's live slots offline, in the snapshot's image: a live server on any host refuses, whatever its release, since every server of the cluster shares the database.
6. Put the scaffold files back as they stood before the update (the keeper's seccomp profile among them), then the storage root, each bind mounted under it at its own source, then the database (the SQLite file, or the dump through pg_restore in the PostgreSQL server's own major).
7. Declare the restore: bin/cyfr eval 'IO.puts("CYFR_RESTORE_ID=" <> Cyfr.Release.mark_restore())' in the snapshot's image, then take CYFR_RESTORE_INCOMPLETE out of .env. A restore that is not declared never starts.
8. Forget the record of the machine's last tailnet join, since the snapshot's .env names its own tailnet machine, then start the stack as every cyfr start runs, waiting for cyfr's health, unless --no-start.

Exit status 3: the restore is declared and CYFR started, but on this machine only, because the tailnet machine is not ready to serve it (not the one the snapshot's .env names, not joined, or HTTPS off); the message says what to do. A failure leaves the stack stopped and says what to do; from step 3 until the declaration, a crash leaves it barred, and 'cyfr restore <snapshot>' run again puts every part back from the start. An object store (S3) is outside the snapshot: objects written since it was taken stay, and objects deleted since come back only from the bucket's own versioning.`,
	GroupID: "server",
	Example: "  cyfr restore backups/20261016T120000Z",
	Args:    cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		return runRestore(cmd.Context(), args[0], !restoreNoStart, cmd.OutOrStdout(), cmd.ErrOrStderr())
	},
}

const (
	// restoreDeclared begins the one line markRestoreExpr prints, the
	// restore's id after it.
	restoreDeclared = "CYFR_RESTORE_ID="

	// markRestoreExpr declares the restore in the restored database and
	// prints its id.
	markRestoreExpr = `IO.puts("` + restoreDeclared + `" <> Cyfr.Release.mark_restore())`

	// restoreBarrier is the .env setting that bars the cell from starting
	// while a restore has not been declared, its value the snapshot being
	// put back. The cyfr service reads .env (env_file) on every start, and
	// docker-entrypoint.sh refuses to run while it is set, so it reaches
	// every start of a new container of any configuration; 'cyfr up' and
	// 'cyfr update' refuse it too. The restore's own offline runs set it
	// empty for their one-off container, which the server's settings
	// roster admits as a name the CLI and the entrypoint own. The name,
	// the entrypoint's exit and the declaration are spelled once, in
	// tests/fixtures/restore_barrier.json, which restore_test.go holds
	// these constants to.
	restoreBarrier = "CYFR_RESTORE_INCOMPLETE"

	// restoreScript reads the database URL, the first line of its stdin,
	// then empties the database's public schema and loads the
	// custom-format dump, the rest of its stdin, in one transaction: the
	// dump is first turned into SQL whole, so a dump that does not read
	// changes nothing, and a statement that fails rolls everything back.
	restoreScript = pgReadURL + `{ printf 'DROP SCHEMA IF EXISTS public CASCADE;\nCREATE SCHEMA public;\n'; pg_restore --no-owner --exit-on-error -f -; } >/tmp/cyfr-restore.sql && exec psql -X -q -v ON_ERROR_STOP=1 --single-transaction -o /dev/null -f /tmp/cyfr-restore.sql "$` + pgURLVariable + `"`
)

// snapshotParts are the parts a snapshot may hold, in the order update
// writes them. None holds the tailnet's state volume (tailscale_state) or
// the access engine's .cyfr/: a node's keys stay out of every backup, and a
// restored home's node is validated against its .env before Serve opens.
var snapshotParts = []string{"database", "database-wal", "storage", "scaffold", "keyring", ".env", "compose"}

var restoreIDPattern = regexp.MustCompile(`^[A-Za-z0-9_-]+$`)

var (
	sqliteMagic           = []byte("SQLite format 3\x00")
	pgDumpMagic           = []byte("PGDMP")
	errRestoreInterrupted = errors.New("cyfr restore was interrupted before anything stopped; nothing was changed")
)

// snapshotFiles is a snapshot directory read and checked.
type snapshotFiles struct {
	dir      string
	manifest snapshotManifest
	parts    map[string]bool
	// database is the dump's kind: sqlite or postgres.
	database string
	// keyring are the keyring file's settings, read as .env is read.
	keyring map[string]string
}

func (s *snapshotFiles) path(part string) string { return filepath.Join(s.dir, part) }

// readSnapshot reads the snapshot at dir and refuses one it cannot put
// back: no snapshot.json or one not complete, a part listed twice, unknown
// or missing, an entry no part names, a database of neither kind, a WAL
// beside a dump, storage/ against the storage adapter, scaffold files
// snapshot.json does not list as managed ones, a keyring file with no
// key, or a .env the engine refuses (access.CheckEnvFile). A snapshot
// without the scaffold part, which no released cyfr took, is refused as
// one it cannot put back whole.
func readSnapshot(dir string) (*snapshotFiles, error) {
	refuse := func(format string, args ...any) error {
		return fmt.Errorf("%s cannot be restored: %s; nothing was changed", dir, fmt.Sprintf(format, args...))
	}
	data, err := os.ReadFile(filepath.Join(dir, "snapshot.json"))
	if errors.Is(err, fs.ErrNotExist) {
		return nil, refuse("it has no snapshot.json, so it is an incomplete snapshot (update writes snapshot.json last)")
	}
	if err != nil {
		return nil, refuse("snapshot.json does not read (%v)", err)
	}
	s := &snapshotFiles{dir: dir, parts: map[string]bool{}}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&s.manifest); err != nil {
		return nil, refuse("snapshot.json is not a snapshot's (%v)", err)
	}
	m := s.manifest
	switch {
	case !m.Complete:
		return nil, refuse("snapshot.json does not say complete")
	case m.Version == "":
		return nil, refuse("snapshot.json names no release")
	case m.StorageAdapter != "local" && m.StorageAdapter != "s3":
		return nil, refuse("snapshot.json's storage adapter %q is neither local nor s3", m.StorageAdapter)
	}
	if _, err := time.Parse(time.RFC3339, m.TakenAt); err != nil {
		return nil, refuse("snapshot.json's taken_at %q is no time", m.TakenAt)
	}
	for _, part := range m.Parts {
		if !slices.Contains(snapshotParts, part) {
			return nil, refuse("snapshot.json lists %q, which is no part cyfr restore knows", part)
		}
		if s.parts[part] {
			return nil, refuse("snapshot.json lists %q twice", part)
		}
		s.parts[part] = true
	}
	for _, part := range []string{"database", "scaffold", "keyring", ".env", "compose"} {
		if !s.parts[part] {
			return nil, refuse("snapshot.json does not list the part %s", part)
		}
	}
	if s.parts["storage"] != (m.StorageAdapter == "local") {
		return nil, refuse("its storage adapter is %s, but snapshot.json lists storage %v", m.StorageAdapter, s.parts["storage"])
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, refuse("the directory does not read (%v)", err)
	}
	for _, entry := range entries {
		if name := entry.Name(); name != "snapshot.json" && !s.parts[name] {
			return nil, refuse("it holds %s, which snapshot.json does not list", name)
		}
	}
	for part := range s.parts {
		info, err := os.Lstat(s.path(part))
		switch {
		case err != nil:
			return nil, refuse("snapshot.json lists %s, which is not there", part)
		case (part == "storage" || part == "scaffold") && !info.IsDir():
			return nil, refuse("%s is not a directory", part)
		case part != "storage" && part != "scaffold" && !info.Mode().IsRegular():
			return nil, refuse("%s is not a regular file", part)
		}
	}
	if err := checkScaffoldPart(s); err != nil {
		return nil, refuse("%v", err)
	}
	head := make([]byte, len(sqliteMagic))
	f, err := os.Open(s.path("database"))
	if err != nil {
		return nil, refuse("the database does not read (%v)", err)
	}
	n, _ := io.ReadFull(f, head)
	f.Close()
	switch head = head[:n]; {
	case bytes.HasPrefix(head, sqliteMagic):
		s.database = "sqlite"
	case bytes.HasPrefix(head, pgDumpMagic):
		s.database = "postgres"
	default:
		return nil, refuse("the database is neither a SQLite file nor a custom-format PostgreSQL dump")
	}
	if s.parts["database-wal"] && s.database != "sqlite" {
		return nil, refuse("it holds a WAL beside a PostgreSQL dump")
	}
	if s.keyring, err = access.ReadEnvValues(s.path("keyring")); err != nil {
		// The engine's sentence names .env; the keyring's line is said here.
		if r := (*access.Refusal)(nil); errors.As(err, &r) && r.Code == "compose_env_refused" && r.Payload["line"] != "" {
			return nil, refuse("line %s of its keyring does not read as Docker Compose reads it", r.Payload["line"])
		}
		return nil, refuse("the keyring does not read (%v)", err)
	}
	if !slices.ContainsFunc(keyringSettings, func(name string) bool { _, ok := s.keyring[name]; return ok }) {
		return nil, refuse("its keyring file holds neither %s", strings.Join(keyringSettings, " nor "))
	}
	// The snapshot's .env becomes the project's, so it is refused before
	// anything stops as the engine refuses a home's .env before anything
	// starts: a COMPOSE_* setting in any form, then a head that does not
	// boot.
	if err := access.CheckEnvFile(s.path(".env")); err != nil {
		var r *access.Refusal
		if !errors.As(err, &r) {
			return nil, refuse("its .env does not read (%v)", err)
		}
		return nil, fmt.Errorf("%s cannot be restored, and nothing was changed: its .env would become this CYFR's, and %w", dir, refusalError{r})
	}
	return s, nil
}

// checkScaffoldPart checks snapshot.json's scaffold list against the
// scaffold owner's policy and the scaffold/ directory: each name a local,
// clean path that scaffold.IsManaged admits, listed once, and every file
// under scaffold/ a regular file the list names.
func checkScaffoldPart(s *snapshotFiles) error {
	listed := map[string]bool{}
	for _, name := range s.manifest.Scaffold {
		switch {
		case !filepath.IsLocal(name) || filepath.Clean(name) != name:
			return fmt.Errorf("snapshot.json lists the scaffold file %q, which is no path in the project", name)
		case !scaffold.IsManaged(name):
			return fmt.Errorf("snapshot.json lists the scaffold file %s, which cyfr update does not manage", name)
		case listed[name]:
			return fmt.Errorf("snapshot.json lists the scaffold file %s twice", name)
		}
		listed[name] = true
	}
	root := s.path("scaffold")
	return filepath.WalkDir(root, func(p string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.IsDir() {
			return nil
		}
		rel, err := filepath.Rel(root, p)
		if err != nil {
			return err
		}
		if !entry.Type().IsRegular() || !listed[rel] {
			return fmt.Errorf("scaffold/ holds %s, which snapshot.json does not list as a scaffold file", rel)
		}
		return nil
	})
}

// putScaffoldBack puts each of the scaffold files names back as the
// snapshot at dir holds it, as it stood before the update: the snapshot's
// bytes where scaffold/ holds the file, and no file where the update
// created it.
func putScaffoldBack(dir string, names []string) error {
	for _, name := range names {
		data, err := os.ReadFile(filepath.Join(dir, "scaffold", name))
		if errors.Is(err, fs.ErrNotExist) {
			if err := os.Remove(name); err != nil && !errors.Is(err, fs.ErrNotExist) {
				return err
			}
			continue
		}
		if err != nil {
			return err
		}
		if err := os.MkdirAll(filepath.Dir(name), 0755); err != nil {
			return err
		}
		if err := scaffold.ReplaceFile(name, data, 0644); err != nil {
			return fmt.Errorf("put %s back: %w", name, err)
		}
	}
	return nil
}

// runRestore is `cyfr restore <snapshot>` in the working directory. ctx is
// cancelled by SIGINT, SIGTERM or SIGHUP (Main): before the stop the
// cancellation ends the restore with nothing changed; from the stop until
// the parts are put back it ends the restore at the next step with the
// stack stopped and the configuration files as they were; putting the
// parts back and declaring the restore run to their end, and an interrupt
// then only keeps the stack from starting.
func runRestore(ctx context.Context, snapshot string, start bool, out, errOut io.Writer) error {
	if ctx == nil {
		ctx = context.Background()
	}
	if _, err := os.Stat("cyfr.yaml"); err != nil {
		return errors.New("Not in a cyfr project directory (no cyfr.yaml found).\nRun 'cyfr restore' in the project the snapshot was taken of")
	}
	dir, err := filepath.Abs(snapshot)
	if err == nil {
		var info os.FileInfo
		if info, err = os.Stat(dir); err == nil && !info.IsDir() {
			err = errors.New("not a directory")
		}
	}
	if err != nil {
		return fmt.Errorf("%s is no snapshot directory (%v).\nUsage: cyfr restore <snapshot>, a directory under backups/ that 'cyfr update' took", snapshot, err)
	}
	snap, err := readSnapshot(dir)
	if err != nil {
		return err
	}
	// The lock an up, an update and an access change hold too, held from
	// before the first docker call to the restore's end; a change recovery
	// could not finish leaves the stack in no known state, and the restore
	// does nothing.
	e, unlock, receipts, err := openLocked(ctx, "restore", out)
	if err != nil {
		return err
	}
	defer unlock()
	if err := refuseUnfinished(receipts); err != nil {
		return err
	}
	if _, err := exec.LookPath("docker"); err != nil {
		return errors.New("cyfr restore needs docker on PATH to stop and start the stack; nothing was changed")
	}
	head, err := e.Head()
	if err != nil {
		return engineFailure(err)
	}
	r := &restorer{updater: updater{ctx: ctx, out: out, errOut: errOut, engine: e, head: head}, snap: snap, start: start}
	return r.run()
}

// restorer carries one restore's state from step to step.
type restorer struct {
	updater
	snap  *snapshotFiles
	start bool
	// held are docker-compose.yml's and .env's bytes before the restore put
	// the snapshot's back, nil for a file that was absent.
	held map[string][]byte
	// sqliteLive reports whether the restored configuration's SQLite file
	// exists, so a member may hold a slot in it.
	sqliteLive bool
	restoreID  string
}

// restoreFiles are the configuration files the restore replaces with the
// snapshot's, held to be put back on a refusal.
var restoreFiles = []struct{ file string }{{"docker-compose.yml"}, {".env"}}

func (r *restorer) run() error {
	m := r.snap.manifest
	fmt.Fprintf(r.out, "Restoring the snapshot of release %s taken at %s (%s).\n", m.Version, m.TakenAt, r.snap.dir)
	if m.StorageAdapter == "s3" {
		fmt.Fprintln(r.out, s3OutsideSnapshot+" Objects written since the snapshot stay in the bucket.")
	}
	ctx, cancel := context.WithTimeout(r.ctx, composeRunTimeout)
	err := r.listRunning(ctx)
	cancel()
	if r.ctx.Err() != nil {
		return errRestoreInterrupted
	}
	if err != nil {
		return err
	}
	// A join waiting for approval would enrol the machine under the
	// configuration the restore replaces, so it is cancelled first.
	if err := r.engine.CancelWaitingJoin(r.ctx); err != nil {
		return fmt.Errorf("cyfr restore could not cancel the tailnet join waiting for approval (%v); nothing was changed", engineFailure(err))
	}

	// From the stop on every child runs detached from ctx, and an
	// interrupt ends the restore at the next step.
	if err := r.stop(); err != nil {
		return fmt.Errorf("%v.\nThe stack may be partly stopped and nothing was restored; stop it with 'cyfr down' and run 'cyfr restore %s' again", err, r.snap.dir)
	}
	if r.ctx.Err() != nil {
		return errors.New("cyfr restore was interrupted during the stop; the stack is left stopped and nothing was restored. Start it again with 'cyfr up'")
	}
	steps := []func() error{r.holdConfigFiles, r.raiseBarrier, r.putConfigFiles, r.readRestoredConfig, r.publishCompose, r.probeRestoredPostgres, r.refuseLiveMembers}
	for _, step := range steps {
		err := step()
		if err == nil && r.ctx.Err() != nil {
			err = errors.New("cyfr restore was interrupted")
		}
		if err != nil {
			return r.refuseStopped(err)
		}
	}

	// Putting the parts back and declaring the restore run to their end, so
	// the cell is never left half-restored by an interrupt.
	if err := r.putParts(); err != nil {
		return fmt.Errorf("Putting the snapshot back failed: %v.\nThe stack is left stopped and is not declared restored, so it stays barred from starting (%s in .env); docker-compose.yml and .env are the snapshot's. Fix the cause and run 'cyfr restore %s' again, which puts every part back from the start", r.redactor().Text(err.Error()), restoreBarrier, r.snap.dir)
	}
	if err := r.declare(); err != nil {
		return fmt.Errorf("Every part of the snapshot is back, but the restore could not be declared: %v.\nThe stack is left stopped and barred from starting undeclared (%s in .env). Fix the cause and run 'cyfr restore %s' again, or declare it by hand with:\n  docker compose run --rm --no-deps -T -e %s= cyfr bin/cyfr eval '%s'\nthen take the %s line out of .env", r.redactor().Text(err.Error()), restoreBarrier, r.snap.dir, restoreBarrier, markRestoreExpr, restoreBarrier)
	}
	if err := r.lowerBarrier(); err != nil {
		return fmt.Errorf("The restore %s is declared, but %s could not be taken out of .env (%v); take that line out of .env and start the stack with 'cyfr up'", r.restoreID, restoreBarrier, err)
	}
	fmt.Fprintf(r.out, "Declared restore %s; the first start suspends every credential and method the backup carried until its owner re-enables it.\n", r.restoreID)
	// The record of the machine's last tailnet join is this home's before
	// the restore: the snapshot's .env names its own node, which the start
	// validates against the machine before Serve opens.
	if err := r.engine.ForgetJoin(); err != nil {
		fmt.Fprintf(r.errOut, "Warning: the record of this machine's last tailnet join could not be removed (%v); `cyfr access tailnet` may offer it again.\n", engineFailure(err))
	}
	if !r.start {
		fmt.Fprintln(r.out, "The stack is left stopped (--no-start); start it with 'cyfr up'.")
		return nil
	}
	if r.ctx.Err() != nil {
		return errors.New("cyfr restore was interrupted; every part is back and the restore is declared, and the stack is left stopped. Start it with 'cyfr up'")
	}
	fmt.Fprintf(r.out, "Starting release %s...\n", m.Version)
	err = r.updater.start("restore")
	if local := (startedLocally{}); errors.As(err, &local) {
		fmt.Fprintf(r.out, "\nRestored the snapshot of release %s taken at %s; restore %s. It runs on this machine alone.\n", m.Version, m.TakenAt, r.restoreID)
		return err
	}
	if err != nil {
		ctx, cancel := r.detached(stopTimeout)
		defer cancel()
		message := fmt.Sprintf("The restored stack did not start (%v); it is left stopped", err)
		if stopErr := r.stopFailedStart(ctx); stopErr != nil {
			message = fmt.Sprintf("The restored stack did not start (%v), and %v; stop it with 'cyfr down'", err, stopErr)
		}
		return fmt.Errorf("%s.\nThe restore %s is declared and the next start takes it; read 'cyfr logs', fix the cause and run 'cyfr up'", message, r.restoreID)
	}
	fmt.Fprintf(r.out, "\nRestored the snapshot of release %s taken at %s; restore %s.\n", m.Version, m.TakenAt, r.restoreID)
	return nil
}

// refuseStopped puts docker-compose.yml and .env back as they were and
// refuses with reason, the stack left stopped.
func (r *restorer) refuseStopped(reason error) error {
	message := fmt.Sprintf("%v.\nThe stack is left stopped and nothing of the snapshot was put back", r.redactor().Text(reason.Error()))
	if err := r.putBackHeld(); err != nil {
		return fmt.Errorf("%s; docker-compose.yml and .env could not be put back as they were (%v), so they may be the snapshot's, and the stack stays barred from starting until 'cyfr restore %s' runs again", message, err, r.snap.dir)
	}
	return fmt.Errorf("%s; docker-compose.yml and .env are as they were. Start the stack again with 'cyfr up'", message)
}

// holdConfigFiles reads the project's docker-compose.yml and .env, for a
// refusal to put back.
func (r *restorer) holdConfigFiles() error {
	r.held = map[string][]byte{}
	for _, f := range restoreFiles {
		data, err := os.ReadFile(f.file)
		switch {
		case errors.Is(err, fs.ErrNotExist):
			r.held[f.file] = nil
		case err != nil:
			return fmt.Errorf("%s does not read (%v)", f.file, err)
		default:
			r.held[f.file] = data
		}
	}
	return nil
}

// withBarrier answers the dotenv text env with restoreBarrier set to the
// snapshot through the engine's editor (access.EditEnv): its one
// assignment, every other taken out, so no other line can set it empty,
// and every other line, a quoted value's included, kept byte for byte. A
// .env the editor cannot change so is refused, and nothing is written.
func withBarrier(env []byte, snapshot string) ([]byte, error) {
	out, err := access.EditEnv(env, map[string]string{restoreBarrier: snapshot}, nil)
	return out, engineFailure(err)
}

// writeDurable writes data over the file at name as writeFileAtomic does,
// then syncs the directory, so the rename survives a crash.
func writeDurable(name string, data []byte, mode os.FileMode) error {
	if err := writeFileAtomic(name, data, mode); err != nil {
		return err
	}
	d, err := os.Open(filepath.Dir(name))
	if err != nil {
		return err
	}
	return errors.Join(d.Sync(), d.Close())
}

// raiseBarrier sets restoreBarrier in the project's .env, durably, before
// any part lands, then removes the stopped cyfr container: a stopped
// container starts again with the environment it was created with, so
// only a new one, created from .env as it now stands, is barred.
func (r *restorer) raiseBarrier() error {
	r.offlineEnv = []string{restoreBarrier + "="}
	barred, err := withBarrier(r.held[".env"], r.snap.dir)
	if err == nil {
		err = writeDurable(".env", barred, 0600)
	}
	if err != nil {
		return fmt.Errorf("cyfr restore could not bar CYFR from starting (%v)", err)
	}
	ctx, cancel := r.detached(composeRunTimeout)
	defer cancel()
	if err := r.composeDocker(ctx, "rm", "--force", "cyfr"); err != nil {
		return fmt.Errorf("docker compose rm cyfr failed (%v), so the stopped cyfr container could start without the bar", err)
	}
	return nil
}

// lowerBarrier puts the snapshot's .env back as the snapshot holds it,
// without restoreBarrier, once the restore is declared.
func (r *restorer) lowerBarrier() error {
	data, err := os.ReadFile(r.snap.path(".env"))
	if err != nil {
		return err
	}
	return writeDurable(".env", data, 0600)
}

// stagedCompose is where the restore writes the snapshot's compose file
// until the configuration it gives cyfr is read and carries the bar; only
// then is it renamed over docker-compose.yml (publishCompose), so the
// compose file in place delivers the bar at every step.
const stagedCompose = ".docker-compose.yml.restore"

// putConfigFiles writes the snapshot's .env over the project's, with the
// barrier, and the snapshot's compose file at stagedCompose: the
// configuration they give cyfr is the one the snapshot was taken under,
// whose mounts the storage part follows. .env is 0600; the compose file
// keeps docker-compose.yml's mode.
func (r *restorer) putConfigFiles() error {
	env, err := os.ReadFile(r.snap.path(".env"))
	if err != nil {
		return err
	}
	barred, err := withBarrier(env, r.snap.dir)
	if err != nil {
		return err
	}
	if err := writeDurable(".env", barred, 0600); err != nil {
		return err
	}
	// From here every compose call runs under the snapshot's head.
	if r.head, err = r.engine.Head(); err != nil {
		return engineFailure(err)
	}
	compose, err := os.ReadFile(r.snap.path("compose"))
	if err != nil {
		return err
	}
	mode := os.FileMode(0600)
	if info, err := os.Stat("docker-compose.yml"); err == nil {
		mode = info.Mode().Perm()
	}
	return writeDurable(stagedCompose, compose, mode)
}

// publishCompose renames the staged compose file, whose configuration
// readRestoredConfig read with the bar reaching cyfr, over
// docker-compose.yml.
func (r *restorer) publishCompose() error {
	if err := os.Rename(stagedCompose, "docker-compose.yml"); err != nil {
		return err
	}
	d, err := os.Open(".")
	if err != nil {
		return err
	}
	return errors.Join(d.Sync(), d.Close())
}

// stagedComposeArgs are the compose arguments that read the configuration
// the staged compose file gives once it is docker-compose.yml: the file set
// compose loads by default (access.DefaultFiles), the staged file in
// docker-compose.yml's place, under the complete selection every compose
// call of the engine makes (the project, the directory and the snapshot's
// head's profiles). The set is refused when compose's default is not
// docker-compose.yml and at most one override file, the set the staged
// file is published into.
func (r *restorer) stagedComposeArgs(args ...string) ([]string, error) {
	main, override, err := access.DefaultFiles(".")
	if err != nil {
		return nil, errors.New(strings.TrimPrefix(err.Error(), "access: "))
	}
	if main != "docker-compose.yml" {
		return nil, fmt.Errorf("the project's compose file is %s, so docker compose would not load the docker-compose.yml cyfr restore puts back; rename it docker-compose.yml", main)
	}
	files := []string{"compose", "-p", access.ProjectName("."), "-f", stagedCompose}
	if override != "" {
		files = append(files, "-f", override)
	}
	files = append(files, "--project-directory", ".")
	for _, profile := range r.head.Profiles {
		files = append(files, "--profile", profile)
	}
	return slices.Concat(files, args), nil
}

// putBackHeld writes the held configuration files back.
func (r *restorer) putBackHeld() error {
	var errs []error
	for _, f := range restoreFiles {
		data, held := r.held[f.file]
		switch {
		case !held:
		case data == nil:
			if err := os.Remove(f.file); err != nil && !errors.Is(err, fs.ErrNotExist) {
				errs = append(errs, err)
			} else if d, err := os.Open("."); err == nil {
				errs = append(errs, d.Sync(), d.Close())
			}
		default:
			mode := os.FileMode(0600)
			if info, err := os.Stat(f.file); err == nil {
				mode = info.Mode().Perm()
			}
			errs = append(errs, writeDurable(f.file, data, mode))
		}
	}
	if err := os.Remove(stagedCompose); err != nil && !errors.Is(err, fs.ErrNotExist) {
		errs = append(errs, err)
	}
	if head, err := r.engine.Head(); err == nil {
		r.head = head
	}
	return errors.Join(errs...)
}

// readRestoredConfig reads the configuration the snapshot's compose file and
// .env give cyfr and checks the snapshot fits it: the database of the
// adapter it names, the storage adapter the snapshot was taken with, a bind
// for the storage root and one for each mount under it, each such mount's
// place in storage/ of its kind and none holding the project or the
// snapshot, and the snapshot's keyring.
func (r *restorer) readRestoredConfig() error {
	refuse := func(format string, args ...any) error {
		return fmt.Errorf("The snapshot does not fit the configuration its docker-compose.yml and .env give cyfr: %s", fmt.Sprintf(format, args...))
	}
	// No COMPOSE_FILE reaches this read or any other compose call: the
	// engine's runner takes every COMPOSE_* out of cyfr's environment, the
	// engine refuses one in the project's .env and readSnapshot one in the
	// snapshot's, so what is read is what starts.
	ctx, cancel := r.detached(composeRunTimeout)
	defer cancel()
	staged, err := r.stagedComposeArgs("config", "--format", "json")
	if err != nil {
		return refuse("%v", err)
	}
	raw, err := r.dockerOutput(ctx, nil, staged...)
	if err != nil {
		return fmt.Errorf("docker compose could not read the snapshot's configuration (%v)", err)
	}
	var config composeConfig
	if err := json.Unmarshal([]byte(raw), &config); err != nil {
		return errors.New("docker compose's configuration did not read as JSON")
	}
	cyfr, ok := config.Services["cyfr"]
	if !ok {
		return refuse("it has no cyfr service")
	}
	if len(cyfr.VolumesFrom) > 0 {
		return refuse("the cyfr service mounts the volumes of %s (volumes_from), which cyfr restore cannot place", strings.Join(cyfr.VolumesFrom, ", "))
	}
	mounts, err := cyfr.mounts()
	if err != nil {
		return refuse("%v", err)
	}
	env := func(name string) string { return serviceSetting(cyfr.Environment, name) }
	if env(restoreBarrier) != r.snap.dir {
		return refuse("the cyfr service does not take %s from .env (its env_file), so nothing would bar it from starting before the restore is declared", restoreBarrier)
	}
	settingPath := func(name, fallback string) (string, error) {
		value, ok := settingPathIn(cyfr.Environment, name, fallback)
		if !ok {
			return "", refuse("%s is set but blank", name)
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
		host, ok := mountedHost(mounts, dbPath)
		if !ok {
			return refuse("the SQLite database %s is on no bind mount of the cyfr service", dbPath)
		}
		if c.sqliteFile, err = hostPath(host, false); err != nil {
			return refuse("the SQLite database %s (on the host %s): %v", dbPath, host, err)
		}
		_, err = os.Lstat(c.sqliteFile)
		r.sqliteLive = err == nil
	case "postgres":
		c.adapter = "postgres"
		if c.pgURL = env("CYFR_DATABASE_URL"); c.pgURL == "" {
			return refuse("CYFR_DATABASE=postgres without CYFR_DATABASE_URL")
		}
		if strings.ContainsAny(c.pgURL, "\r\n") {
			return refuse("its CYFR_DATABASE_URL holds a line break, which no database URL holds")
		}
		r.redactor().Hold(c.pgURL)
		if parsed, err := url.Parse(c.pgURL); err == nil && parsed.User != nil {
			if password, ok := parsed.User.Password(); ok {
				r.redactor().Hold(password)
			}
		}
	default:
		return refuse("CYFR_DATABASE=%s is neither sqlite nor postgres", adapter)
	}
	if c.adapter != r.snap.database {
		return refuse("its database is %s, but the snapshot's database part is a %s one", c.adapter, r.snap.database)
	}

	switch storage := strings.ToLower(env("CYFR_STORAGE")); storage {
	case "", "local":
		c.storage = "local"
	case "s3":
		c.storage = "s3"
	default:
		return refuse("CYFR_STORAGE=%s is neither local nor s3", storage)
	}
	if c.storage != r.snap.manifest.StorageAdapter {
		return refuse("its storage is %s, but the snapshot was taken of %s storage", c.storage, r.snap.manifest.StorageAdapter)
	}
	if c.storage == "local" {
		host, ok := mountedHost(mounts, dataPath)
		if !ok {
			return refuse("the storage root %s is on no bind mount of the cyfr service", dataPath)
		}
		root, err := hostPath(host, true)
		if err != nil {
			return refuse("the storage root %s (on the host %s): %v", dataPath, host, err)
		}
		c.storageMounts = []storageMount{{host: root, dir: true}}
		var nested []storageMount
		for _, n := range mountsUnder(mounts, dataPath) {
			v, target := n.mount, path.Clean(n.mount.Target)
			if v.Type != "bind" || v.Source == "" {
				return refuse("the storage root %s has a %s mount at %s, whose bytes no host path holds", dataPath, v.Type, target)
			}
			placed, err := os.Lstat(filepath.Join(r.snap.path("storage"), filepath.FromSlash(n.rel)))
			if err != nil || !placed.IsDir() && !placed.Mode().IsRegular() {
				return refuse("the mount at %s has no place storage/%s in the snapshot, which was taken under another layout of mounts and cannot be inverted", target, n.rel)
			}
			host, err := hostPath(v.Source, placed.IsDir())
			if err != nil {
				return refuse("the mount at %s (on the host %s): %v", target, v.Source, err)
			}
			nested = append(nested, storageMount{rel: n.rel, host: host, dir: placed.IsDir()})
		}
		sortByDepth(nested)
		c.storageMounts = append(c.storageMounts, nested...)
		// A mount's bytes are replaced whole, so none may hold the project
		// or the snapshot, nor lie inside the snapshot.
		project, err := os.Getwd()
		if err == nil {
			project, err = filepath.EvalSymlinks(project)
		}
		if err != nil {
			return fmt.Errorf("the project directory does not read (%v)", err)
		}
		snapshot, err := filepath.EvalSymlinks(r.snap.dir)
		if err != nil {
			return fmt.Errorf("the snapshot directory does not read (%v)", err)
		}
		for _, m := range c.storageMounts {
			if within(project, m.host) || within(snapshot, m.host) || within(m.host, snapshot) {
				return refuse("the storage root or a mount under it is on the host %s, which holds the project or the snapshot, so its bytes cannot be replaced", m.host)
			}
		}
	}

	for _, name := range keyringSettings {
		want, inSnapshot := r.snap.keyring[name]
		raw := cyfr.Environment[name]
		has := raw != nil && strings.TrimSpace(*raw) != ""
		if has {
			r.redactor().Hold(*raw)
		}
		if inSnapshot {
			r.redactor().Hold(want)
		}
		if has != inSnapshot || has && *raw != want {
			return refuse("its %s is not the one the snapshot's keyring file (%s) holds; set it as that file holds it, so the restored data can be read", name, r.snap.path("keyring"))
		}
	}
	r.config = c
	return nil
}

// hostPath resolves a host path the restore writes to: through its links
// when it exists, refusing one that is not of the kind the snapshot holds
// for it; else through the links of its parent, since the restore creates
// it.
func hostPath(p string, dir bool) (string, error) {
	resolved, err := filepath.EvalSymlinks(p)
	if err == nil {
		info, err := os.Stat(resolved)
		switch {
		case err != nil:
			return "", err
		case dir && !info.IsDir():
			return "", errors.New("it is not a directory")
		case !dir && !info.Mode().IsRegular():
			return "", errors.New("it is not a regular file")
		}
		return resolved, nil
	}
	if !errors.Is(err, fs.ErrNotExist) {
		return "", err
	}
	if _, err := os.Lstat(p); err == nil {
		return "", errors.New("it is a link to nothing")
	}
	if parent, err := filepath.EvalSymlinks(filepath.Dir(p)); err == nil {
		return filepath.Join(parent, filepath.Base(p)), nil
	}
	return filepath.Clean(p), nil
}

// within reports whether p is root or lies under it.
func within(p, root string) bool {
	return p == root || strings.HasPrefix(p, strings.TrimSuffix(root, string(filepath.Separator))+string(filepath.Separator))
}

// probeRestoredPostgres reads the server's major, which names the image the
// dump is loaded with.
func (r *restorer) probeRestoredPostgres() error {
	if r.config.adapter != "postgres" {
		return nil
	}
	ctx, cancel := r.detached(composeRunTimeout)
	defer cancel()
	major, err := r.serverMajor(ctx)
	if err != nil {
		return fmt.Errorf("cyfr restore could not read the version of the PostgreSQL server at the snapshot's CYFR_DATABASE_URL (%v)", err)
	}
	if _, err := pgClientImage(major); err != nil {
		return fmt.Errorf("cyfr restore refuses: %w", err)
	}
	r.config.pgMajor = major
	return nil
}

// refuseLiveMembers reads the live slots of the database the restore writes,
// offline in the snapshot's image, until none is live or the window closes.
// Any live slot refuses, whatever its release: the restore replaces bytes
// every member of the cell shares. A SQLite database that does not exist
// holds no slot.
func (r *restorer) refuseLiveMembers() error {
	if r.config.adapter == "sqlite" && !r.sqliteLive {
		fmt.Fprintf(r.out, "No database is at %s yet, so no server of the cluster holds a slot in it.\n", r.config.sqliteFile)
		return nil
	}
	_, live, err := r.waitLiveSlots(func(rosterSlot) bool { return false })
	if err != nil {
		return err
	}
	if len(live) > 0 {
		return fmt.Errorf("A server of the cluster is still live %s after the stop: %s. A restore needs the whole cluster stopped; stop it on its host with 'cyfr down', then run 'cyfr restore %s' again", liveSlotsWindow, slotNames(live), r.snap.dir)
	}
	return nil
}

// putParts puts the scaffold files back, then the storage root, each mount
// under it at its own source, then the database. Each part is replaced
// whole, so a restore run again after a failure puts every part back from
// the start.
func (r *restorer) putParts() error {
	c := r.config
	fmt.Fprintln(r.out, "Putting the scaffold files back...")
	if err := putScaffoldBack(r.snap.dir, r.snap.manifest.Scaffold); err != nil {
		return err
	}
	if c.storage == "local" {
		fmt.Fprintln(r.out, "Putting the storage root back...")
		keep := map[string]bool{}
		if c.sqliteFile != "" {
			for _, suffix := range []string{"", "-wal", "-shm"} {
				keep[filepath.Clean(c.sqliteFile+suffix)] = true
			}
		}
		if err := restoreStorage(c.storageMounts, r.snap.path("storage"), keep, r.out); err != nil {
			return err
		}
	}
	fmt.Fprintln(r.out, "Putting the database back...")
	if c.adapter == "sqlite" {
		return r.restoreSQLite()
	}
	return r.restorePostgres()
}

// restoreStorage puts the snapshot's storage/ back at the mounts making up
// the storage root, shallower first. Each mount's own bytes are replaced:
// what it holds is removed and the snapshot's copied in, but for the host
// paths in keep and the places a deeper mount covers, which hold bytes cyfr
// does not see through this mount.
func restoreStorage(mounts []storageMount, src string, keep map[string]bool, out io.Writer) error {
	for i, m := range mounts {
		covered := maps.Clone(keep)
		skip := map[string]bool{}
		for _, deeper := range mounts[i+1:] {
			rest, ok := deeper.rel, m.rel == ""
			if !ok {
				rest, ok = strings.CutPrefix(deeper.rel, m.rel+"/")
			}
			if ok {
				covered[filepath.Join(m.host, filepath.FromSlash(rest))] = true
				skip[filepath.Join(src, filepath.FromSlash(deeper.rel))] = true
			}
		}
		from := filepath.Join(src, filepath.FromSlash(m.rel))
		if !m.dir {
			if err := os.MkdirAll(filepath.Dir(m.host), 0700); err != nil {
				return err
			}
			if err := replaceFile(from, m.host); err != nil {
				return err
			}
			continue
		}
		if err := os.MkdirAll(m.host, 0700); err != nil {
			return err
		}
		if err := clearDir(m.host, covered); err != nil {
			return err
		}
		if err := copyInto(from, m.host, skip, out); err != nil {
			return err
		}
	}
	return nil
}

// clearDir removes everything under dir but the paths in keep and the
// directories leading to them.
func clearDir(dir string, keep map[string]bool) error {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return err
	}
	for _, entry := range entries {
		p := filepath.Join(dir, entry.Name())
		if keep[p] {
			continue
		}
		holds := false
		for kept := range keep {
			if strings.HasPrefix(kept, p+string(filepath.Separator)) {
				holds = true
				break
			}
		}
		if holds && entry.IsDir() {
			if err := clearDir(p, keep); err != nil {
				return err
			}
			continue
		}
		if err := os.RemoveAll(p); err != nil {
			return err
		}
	}
	return nil
}

// copyInto copies the snapshot directory src into the existing directory
// dst as copyTree copied it out: directories 0700, regular files 0600, a
// link as the link it is; the snapshot paths in skip, a deeper mount's
// bytes, are left out.
func copyInto(src, dst string, skip map[string]bool, out io.Writer) error {
	return filepath.WalkDir(src, func(p string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if skip[filepath.Clean(p)] {
			if entry.IsDir() {
				return fs.SkipDir
			}
			return nil
		}
		rel, err := filepath.Rel(src, p)
		if err != nil {
			return err
		}
		target := filepath.Join(dst, rel)
		switch mode := entry.Type(); {
		case entry.IsDir():
			return os.MkdirAll(target, 0700)
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

// replaceFile writes a copy of src over dst, 0600, through a temporary file
// beside dst renamed into place, so dst is the old file or the new one.
func replaceFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	tmp, err := os.CreateTemp(filepath.Dir(dst), "."+filepath.Base(dst)+".restore-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	_, err = io.Copy(tmp, in)
	if err = errors.Join(err, tmp.Chmod(0600), tmp.Sync(), tmp.Close()); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), dst)
}

// restoreSQLite puts the SQLite file back, and its WAL as the snapshot
// holds it. The old WAL and shared-memory index go first, so the restored
// file is never read with another file's WAL; a WAL the snapshot holds is
// put in place after the file it belongs to.
func (r *restorer) restoreSQLite() error {
	file := r.config.sqliteFile
	if err := os.MkdirAll(filepath.Dir(file), 0700); err != nil {
		return err
	}
	for _, suffix := range []string{"-shm", "-wal"} {
		if err := os.Remove(file + suffix); err != nil && !errors.Is(err, fs.ErrNotExist) {
			return err
		}
	}
	if err := replaceFile(r.snap.path("database"), file); err != nil {
		return err
	}
	if r.snap.parts["database-wal"] {
		if err := replaceFile(r.snap.path("database-wal"), file+"-wal"); err != nil {
			return err
		}
	}
	if d, err := os.Open(filepath.Dir(file)); err == nil {
		d.Sync()
		d.Close()
	}
	return nil
}

// restorePostgres loads the snapshot's dump into the configured database in
// the server-major image, in one transaction that first empties the public
// schema, so tables a later release added go with the rest; the URL
// reaches the container on its standard input, the line before the dump.
func (r *restorer) restorePostgres() error {
	dump, err := os.Open(r.snap.path("database"))
	if err != nil {
		return err
	}
	defer dump.Close()
	ctx, cancel := r.detached(dumpTimeout)
	defer cancel()
	var stderr bytes.Buffer
	res, err := r.engine.Docker().Run(ctx, access.Call{
		Args:     []string{"run", "--rm", "-i", "--network", "host", r.pgImage(), "sh", "-c", restoreScript},
		Deadline: callDeadline(ctx),
		Stdin:    io.MultiReader(pgURLInput(r.config.pgURL), dump),
		Stdout:   io.Discard,
		Stderr:   &stderr,
	})
	err = callFailure(r.redactor(), res, err)
	if stderr.Len() > 0 {
		io.WriteString(r.errOut, r.redactor().Text(stderr.String()))
	}
	if err != nil {
		return fmt.Errorf("pg_restore in %s failed (%v); its transaction rolled back", r.pgImage(), err)
	}
	return nil
}

// declare runs mark_restore in the snapshot's image against the restored
// database and reads the restore id it prints.
func (r *restorer) declare() error {
	ctx, cancel := r.detached(composeRunTimeout)
	defer cancel()
	args, err := r.offlineEval(ctx, markRestoreExpr)
	output := ""
	if err == nil {
		output, err = r.dockerOutput(ctx, nil, args...)
	}
	if err != nil {
		return fmt.Errorf("Cyfr.Release.mark_restore/0 failed in release %s's image (%v)", r.snap.manifest.Version, err)
	}
	id, err := markedLine(output, restoreDeclared)
	if err == nil && !restoreIDPattern.MatchString(id) {
		err = fmt.Errorf("the restore id %q does not read", id)
	}
	if err != nil {
		return fmt.Errorf("Cyfr.Release.mark_restore/0 did not answer a restore id (%v)", err)
	}
	r.restoreID = id
	return nil
}
