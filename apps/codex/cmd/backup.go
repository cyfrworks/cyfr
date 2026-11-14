// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"time"

	"github.com/cyfr/codex/internal/scaffold"
	"github.com/spf13/cobra"
)

func init() {
	rootCmd.AddCommand(backupCmd)
}

var backupCmd = &cobra.Command{
	Use:     "backup",
	Short:   "Take a snapshot of the CYFR in this directory into backups/, which cyfr restore puts back",
	GroupID: "server",
	Long: `Take a snapshot of the CYFR in this directory into backups/<UTC timestamp>/, the one cyfr update takes before it changes anything, which 'cyfr restore backups/<timestamp>' puts back.

The snapshot holds the database, the local storage root, the managed scaffold files this directory holds (the guides, the WIT definitions, the keeper's seccomp profile and the shipped AQUA files), the keyring, .env and docker-compose.yml, then snapshot.json, written last. A snapshot holds the keyring and the database: keep it as you keep the data. Storage on S3 is not in it.

It takes the stack's lock first. A running CYFR is stopped for the snapshot, as cyfr update stops it, and started again afterwards, also when the snapshot fails; a stopped one stays stopped.`,
	Example: "  cyfr backup",
	RunE: func(cmd *cobra.Command, args []string) error {
		ctx := cmd.Context()
		if ctx == nil {
			ctx = context.Background()
		}
		return runBackup(ctx, cmd.OutOrStdout(), cmd.ErrOrStderr())
	},
}

// errBackupInterrupted is the refusal of a backup a signal ended before
// anything stopped.
var errBackupInterrupted = errors.New("cyfr backup was interrupted before anything stopped; it changed nothing and the running stack was not touched")

// runBackup is `cyfr backup` in the working directory: under the stack's
// lock and after recovery, cyfr update's reads of the configuration and
// the running services, its stop when anything runs, the offline read of
// the release the stack's image runs, the snapshot, then the start of what
// ran. ctx is cancelled by SIGINT, SIGTERM or SIGHUP (Main): before the
// stop it ends the backup with nothing changed; from the stop on every
// step runs detached from it, so a stopped stack is always started again.
func runBackup(ctx context.Context, out, errOut io.Writer) error {
	original, err := os.ReadFile("docker-compose.yml")
	if err != nil {
		return errors.New("There is no CYFR in this directory to back up, so nothing was done: it holds no docker-compose.yml. Run 'cyfr backup' in CYFR's directory")
	}
	if _, err := exec.LookPath("docker"); err != nil {
		return errors.New("cyfr backup needs docker on PATH to read the stack; nothing was done")
	}
	e, unlock, receipts, err := openLocked(ctx, "backup", out)
	if err != nil {
		return err
	}
	defer unlock()
	if err := refuseUnfinished(receipts); err != nil {
		return err
	}
	head, err := e.Head()
	if err != nil {
		return engineFailure(err)
	}
	u := &updater{ctx: ctx, command: "backup", out: out, errOut: errOut, engine: e, head: head,
		compose: &composePlan{path: "docker-compose.yml", original: original}}
	listRunning := func() error {
		ctx, cancel := context.WithTimeout(ctx, composeRunTimeout)
		defer cancel()
		return u.listRunning(ctx)
	}
	for _, step := range []func() error{u.readConfig, u.probePostgres, listRunning} {
		if err := step(); err != nil {
			if ctx.Err() != nil {
				return errBackupInterrupted
			}
			return err
		}
		if ctx.Err() != nil {
			return errBackupInterrupted
		}
	}
	managed, err := managedPresent()
	if err != nil {
		return fmt.Errorf("cyfr backup could not list the scaffold files this directory holds (%v); nothing was changed", err)
	}
	if len(u.running) > 0 {
		// A join waiting for approval would enrol the machine while the
		// stack is down for the snapshot, as in an update.
		if err := u.engine.CancelWaitingJoin(ctx); err != nil {
			return fmt.Errorf("cyfr backup could not cancel the tailnet join waiting for approval (%v); the running stack was not touched", engineFailure(err))
		}
		if err := u.stop(); err != nil {
			return u.startAgain(err)
		}
	}
	release, others, err := u.waitLiveSlots(func(rosterSlot) bool { return false })
	if err == nil && len(others) > 0 {
		err = fmt.Errorf("A slot is still live %s after the stop: %s. A server outside this stack holds it and may write the database; stop that server first", liveSlotsWindow, slotNames(others))
	}
	if err == nil {
		if err = u.takeSnapshot(release, managed); err != nil {
			where := "no snapshot directory was made"
			if u.snapshot != "" {
				where = "the partial snapshot " + u.snapshot + " lacks snapshot.json, so cyfr restore refuses it"
			}
			err = fmt.Errorf("The snapshot failed: %v; %s", u.redactor().Text(err.Error()), where)
		}
	}
	if err != nil {
		return u.startAgain(err)
	}
	fmt.Fprintf(out, "The snapshot of release %s is in %s; 'cyfr restore %s' puts it back.\n", release, u.snapshot, u.snapshot)
	if len(u.running) == 0 {
		fmt.Fprintln(out, "The stack was not running, so it stays stopped.")
		return nil
	}
	fmt.Fprintln(out, "Starting the stack again...")
	if err := u.start("backup"); err != nil {
		if local := (startedLocally{}); errors.As(err, &local) {
			fmt.Fprintf(out, "The stack runs again, on this machine alone: %v\n", err)
			return nil
		}
		return fmt.Errorf("The snapshot is whole, but the stack did not start again (%v); 'cyfr up' starts it", err)
	}
	fmt.Fprintln(out, "The stack runs again.")
	return nil
}

// startAgain answers a backup's failure after the reads: the stack started
// again when it ran before, and reason with what became of it.
func (u *updater) startAgain(reason error) error {
	text := u.redactor().Text(reason.Error())
	if len(u.running) == 0 {
		return fmt.Errorf("%s.\nThe stack was not running before the backup and stays stopped", text)
	}
	fmt.Fprintln(u.out, "Starting the stack again...")
	err := u.start("backup")
	if local := (startedLocally{}); errors.As(err, &local) {
		return fmt.Errorf("%s.\nThe stack was started again, on this machine alone. %v", text, err)
	}
	if err != nil {
		return fmt.Errorf("%s.\nThe stack did not start again (%v); 'cyfr up' starts it", text, err)
	}
	return fmt.Errorf("%s.\nThe stack was started again", text)
}

// managedPresent answers the managed scaffold files (scaffold.IsManaged)
// the working directory holds as regular files, sorted: the guides, the
// keeper's seccomp profile and what is managed under wit/ and aqua/. A
// link is no managed file and is left out.
func managedPresent() ([]string, error) {
	var names []string
	for _, name := range append(slices.Clone(scaffold.Guides), scaffold.SeccompProfile) {
		if info, err := os.Lstat(name); err == nil && info.Mode().IsRegular() {
			names = append(names, name)
		}
	}
	for _, root := range []string{"wit", "aqua"} {
		err := filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
			if err != nil {
				if p == root && errors.Is(err, fs.ErrNotExist) {
					return nil
				}
				return err
			}
			if name := filepath.ToSlash(p); d.Type().IsRegular() && scaffold.IsManaged(name) {
				names = append(names, name)
			}
			return nil
		})
		if err != nil {
			return nil, err
		}
	}
	slices.Sort(names)
	return names, nil
}

// snapshotManifest is snapshot.json, written last: its presence marks a
// complete snapshot.
type snapshotManifest struct {
	Version        string   `json:"version"`
	TakenAt        string   `json:"taken_at"`
	Parts          []string `json:"parts"`
	StorageAdapter string   `json:"storage_adapter"`
	// Scaffold names every scaffold file the snapshot answers for
	// (scaffold.IsManaged): an update's, the files the release replaces,
	// each held under scaffold/ when it was there before the update and
	// absent from it when the update created it; a backup's, the managed
	// files the directory holds.
	Scaffold []string `json:"scaffold"`
	Complete bool     `json:"complete"`
}

// takeSnapshot copies the stopped cell of release into
// backups/<UTC timestamp>/: the database, the local storage root, the
// scaffold files managed names (scaffold.IsManaged) as they stand, the
// keyring, .env and the compose file as the command read it, then
// snapshot.json, which `cyfr restore` reads. Directories are 0700 and files
// 0600. backups/ holds a .gitignore ignoring all of it, since a snapshot
// holds the keyring. cyfr update and cyfr backup both take it.
func (u *updater) takeSnapshot(release string, managed []string) error {
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
	// The compose file as the command read it, so a restore puts the
	// release's image lines back with the rest.
	if err := writeNewFile(filepath.Join(dir, "compose"), u.compose.original); err != nil {
		return err
	}
	parts = append(parts, "compose")

	data, err := json.MarshalIndent(snapshotManifest{
		Version:        release,
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
