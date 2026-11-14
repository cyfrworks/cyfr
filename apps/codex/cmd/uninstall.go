// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"github.com/cyfr/codex/internal/access"
	"github.com/cyfr/codex/internal/config"
	"github.com/cyfr/codex/internal/release"
	"github.com/cyfr/codex/internal/scaffold"
	"github.com/cyfr/codex/internal/version"
	"github.com/spf13/cobra"
)

func init() {
	uninstallCmd.Flags().Bool("yes", false, "Answer yes to the uninstall's question; CYFR's data is still asked about, and kept without a terminal")
	uninstallCmd.Flags().Bool("delete-data-without-asking", false, "Delete CYFR's data too, without asking: the database, files, backups, the programs' kept files and the device key")
	rootCmd.AddCommand(uninstallCmd)
}

var uninstallCmd = &cobra.Command{
	Use:     "uninstall",
	Short:   "Take CYFR off this machine: its stack, its files and this program, keeping its data unless asked",
	GroupID: "server",
	Long: `Take the CYFR in this directory off this machine, with this program. It removes what CYFR put there and can name, and nothing else.

Before anything is removed it shows what it removes and what it keeps, then asks "Uninstall CYFR?". Answered yes, it asks a second question, "Delete CYFR's data too?", and goes on either way: answered no, or with no terminal to ask on, the data stays. --yes answers the first question alone; --delete-data-without-asking answers the second. With no terminal and no --yes it removes nothing.

It removes:
- the stack: its containers and networks, and the images its compose file names (one another container still uses stays, and is said);
- this machine's screen service, when 'cyfr screen on' installed it, giving the screen back to its login prompt;
- each file CYFR shipped or wrote in the directory, by name: the files cyfr init and cyfr update recorded in .cyfr/files as they wrote them (never a file that was there before, which they kept), or, for a CYFR that keeps no record, the files of the scaffold of the release it runs, read from that release; and the stack's own state in .cyfr/; then each of their directories, and the directory itself, once nothing is left in it. Nothing is read or removed through a symbolic link, and a link stays as it was;
- this program and its link in /usr/local/bin, and its settings and update check in ~/.cyfr. A Homebrew install is left to 'brew uninstall --cask cyfr'.

It keeps every other file in the directory, a file of your own beside CYFR's included, a .gitignore that was changed, and, whatever any list names, CYFR's data unless the second question says yes: data/ and backups/, the stack's volumes (the programs' kept files among them) and this machine's device key in ~/.cyfr/device. data/ and backups/ belong to CYFR's container, so they are removed as root, through sudo. Docker and every package other software uses stay.

Each step is said as it is done, the data's last; when one fails, the command says what is already gone and what is still here.`,
	Example: "  cyfr uninstall\n  cyfr uninstall --yes",
	RunE: func(cmd *cobra.Command, args []string) error {
		ctx := cmd.Context()
		if ctx == nil {
			ctx = context.Background()
		}
		yes, _ := cmd.Flags().GetBool("yes")
		deleteData, _ := cmd.Flags().GetBool("delete-data-without-asking")
		return runUninstall(ctx, cmd.OutOrStdout(), yes, deleteData)
	},
}

// usrLocalLink is the link install.sh makes onto PATH, and screenInstalled
// whether `cyfr screen on` installed the screen service; tests stand in
// for both.
var (
	usrLocalLink    = "/usr/local/bin/cyfr"
	screenInstalled = func() bool { return fileExists(screenUnit) }
)

// projectData are the directory's entries that hold a person's data.
var projectData = []string{"data", "backups"}

// stateMarker is the stack's state, which cyfr init makes beside the .env
// naming how CYFR is reached: together, CYFR's own mark of a project.
const stateMarker = ".cyfr"

// isCYFRProject reports whether the working directory is a CYFR cyfr init
// made: a compose file, .cyfr/, and a .env that names CYFR_ACCESS.
func isCYFRProject() bool {
	values, err := access.ReadEnvValues(".env")
	return err == nil && values["CYFR_ACCESS"] != "" && access.HasComposeFile(".") && fileExists(stateMarker)
}

// installRecord is where cyfr init and cyfr update record the files they
// wrote in a project (scaffold.InstallRecord): one project-relative name
// a line, each a file the command wrote, never one it found and left.
const installRecord = scaffold.InstallRecord

// recordInstall adds written, the files a command just wrote, to the
// working directory's record, and writes the record whole, atomically.
// A file that was there before and was not written is never added.
func recordInstall(written []string) error {
	names, _, err := readInstallRecord()
	if err != nil {
		return err
	}
	for _, name := range written {
		if err := recordName(name); err != nil {
			return err
		}
	}
	names = append(names, written...)
	slices.Sort(names)
	names = slices.Compact(names)
	if err := os.MkdirAll(filepath.Dir(installRecord), 0o700); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(installRecord), ".files.*")
	if err != nil {
		return err
	}
	var data []byte
	for _, name := range names {
		data = append(data, name+"\n"...)
	}
	_, err = tmp.Write(data)
	err = errors.Join(err, tmp.Sync(), tmp.Close())
	if err == nil {
		err = os.Rename(tmp.Name(), installRecord)
	}
	if err != nil {
		_ = os.Remove(tmp.Name())
	}
	return err
}

// recordName refuses a name the record cannot hold: empty, absolute,
// holding .., not clean, or holding a control character.
func recordName(name string) error {
	ok := name != "" && !filepath.IsAbs(name) && !strings.Contains(name, "..") &&
		filepath.Clean(name) == name && filepath.IsLocal(name) && !strings.Contains(name, `\`)
	for _, r := range name {
		if r < 0x20 || r == 0x7f {
			ok = false
		}
	}
	if !ok {
		return fmt.Errorf("%s names %q, which is not a path inside this directory", installRecord, name)
	}
	return nil
}

// readInstallRecord answers the working directory's install record, one
// name a line, false when it keeps none. One line it cannot hold refuses
// the whole record: it is never followed in part.
func readInstallRecord() ([]string, bool, error) {
	if info, err := os.Lstat(installRecord); err != nil || !info.Mode().IsRegular() {
		return nil, false, nil
	}
	data, err := os.ReadFile(installRecord)
	if err != nil {
		return nil, true, err
	}
	var names []string
	for _, line := range strings.SplitAfter(string(data), "\n") {
		if line == "" {
			continue
		}
		name, complete := strings.CutSuffix(line, "\n")
		if !complete {
			return nil, true, fmt.Errorf("%s does not end its last line", installRecord)
		}
		if err := recordName(name); err != nil {
			return nil, true, err
		}
		names = append(names, name)
	}
	return names, true, nil
}

// installedFiles answers which files CYFR put in the working directory:
// the record init and update keep, else, for a project that keeps none,
// the names of the scaffold of the release it runs with .env and
// .gitignore; and with either, the stack's own state under .cyfr/. What
// is the person's data is decided apart, whatever the names say
// (uninstallPlan.personData).
func installedFiles() ([]string, error) {
	names, kept, err := readInstallRecord()
	switch {
	case err != nil:
		return nil, fmt.Errorf("its record of the files CYFR put here cannot be used (%v)", err)
	case !kept:
		installed := installedRelease()
		shipped, err := uninstallScaffold(installed)
		if err != nil {
			return nil, fmt.Errorf("this CYFR keeps no record of the files it put here (%s), and release %s's list of them could not be read (%v)", installRecord, installed, err)
		}
		names = append(shipped, ".env", ".gitignore")
	}
	// The stack's own state: every file under .cyfr/. WalkDir descends
	// into no symbolic link.
	if info, err := os.Lstat(stateMarker); err == nil && info.IsDir() {
		_ = filepath.WalkDir(stateMarker, func(path string, d fs.DirEntry, err error) error {
			if err == nil && d.Type().IsRegular() {
				names = append(names, filepath.ToSlash(path))
			}
			return nil
		})
	}
	return names, nil
}

// uninstallScaffold names the files the scaffold of release version lays
// down, the list cyfr init writes from (scaffold.Release.Names); a
// variable so a test names them.
var uninstallScaffold = func(version string) ([]string, error) {
	r, err := scaffold.Fetch(version)
	if err != nil {
		return nil, err
	}
	return r.Names(), nil
}

// installedRelease is the release the CYFR in the working directory runs,
// by its compose file's cyfr image tag, else this program's.
func installedRelease() string {
	for _, name := range access.ComposeMainFiles {
		for _, ref := range imagesFromCompose(name, nil) {
			repository, tag, _ := splitImageReference(ref)
			if normalizeRepository(repository) == release.RepoCyfr && release.IsVersion(tag) {
				return tag
			}
		}
	}
	return version.Version
}

// uninstallPlan is what cyfr uninstall removes and keeps, read before
// anything is removed.
type uninstallPlan struct {
	dir     string
	project string
	images  []string
	// files are the files CYFR shipped or wrote in the directory, by name:
	// each a regular file reached through no symbolic link. Nothing else
	// in the directory is removed.
	files []string
	// data are the directory's data folders, each a real directory,
	// removed as root when the data goes, with the stack's volumes.
	data []string
	// linkedData are data entries that are symbolic links: kept, the link
	// as it was found, whatever is asked.
	linkedData []string
	screen     bool
	self       string
	cask       bool
	link       bool
	// settings are ~/.cyfr's files of this program; deviceKey is the
	// device key there, which goes with the data.
	settings  []string
	deviceKey string
	// deviceDir holds this machine's device key, which is data.
	deviceDir string
	// deleteData is the data's own question answered yes.
	deleteData bool
}

// personData reports whether path is the person's data, which the
// ordinary removal never touches whatever names it: the project's data/
// and backups/ and everything in them, and the device key's folder, under
// ~/.cyfr or, when the project is the home folder, its own .cyfr. Only the
// data's own question removes it.
func (p *uninstallPlan) personData(path string) bool {
	roots := []string{p.deviceDir}
	for _, name := range projectData {
		roots = append(roots, filepath.Join(p.dir, name))
	}
	for _, root := range roots {
		if root != "" && (path == root || strings.HasPrefix(path, root+string(filepath.Separator))) {
			return true
		}
	}
	return false
}

// changedGitignore reports whether name is a .gitignore that is not the
// one cyfr init writes, byte for byte: a person's change makes it theirs,
// whichever source named it.
func changedGitignore(name string) bool {
	if name != ".gitignore" {
		return false
	}
	data, err := os.ReadFile(name)
	return err != nil || !bytes.Equal(data, []byte(projectGitignore))
}

// regularFile reports whether rel, under dir, is a regular file reached
// through no symbolic link: every directory on the way is a real one.
func regularFile(dir, rel string) bool {
	path := dir
	parts := strings.Split(filepath.ToSlash(rel), "/")
	for i, part := range parts {
		if part == "" || part == "." || part == ".." {
			return false
		}
		path = filepath.Join(path, part)
		info, err := os.Lstat(path)
		switch {
		case err != nil:
			return false
		case i < len(parts)-1 && !info.IsDir():
			return false
		case i == len(parts)-1:
			return info.Mode().IsRegular()
		}
	}
	return false
}

// readUninstallPlan reads what an uninstall of the CYFR in the working
// directory removes and keeps; it changes nothing.
func readUninstallPlan(named []string) (*uninstallPlan, error) {
	dir, err := os.Getwd()
	if err != nil {
		return nil, err
	}
	p := &uninstallPlan{dir: dir, project: access.ProjectName(dir), screen: screenInstalled(), cask: caskInstalled()}
	for _, name := range access.ComposeMainFiles {
		if regularFile(dir, name) {
			p.images = imagesFromCompose(name, []string{buildsProfile, access.ModePublic, access.ModeTailnet})
			break
		}
	}
	if path, err := deviceKey(); err == nil {
		p.deviceDir = filepath.Dir(path)
	}
	for _, name := range named {
		if regularFile(dir, name) && !p.personData(filepath.Join(dir, name)) && !changedGitignore(name) && !slices.Contains(p.files, name) {
			p.files = append(p.files, name)
		}
	}
	slices.Sort(p.files)
	for _, name := range projectData {
		info, err := os.Lstat(name)
		switch {
		case err != nil:
		case info.IsDir():
			p.data = append(p.data, name)
		default:
			p.linkedData = append(p.linkedData, name)
		}
	}
	if !p.cask {
		if self, err := selfExecutable(); err == nil {
			if resolved, err := filepath.EvalSymlinks(self); err == nil {
				self = resolved
			}
			p.self = self
			if target, err := filepath.EvalSymlinks(usrLocalLink); err == nil && target == self && usrLocalLink != self {
				p.link = true
			}
		}
	}
	for _, path := range []func() (string, error){config.DefaultConfigPath, versionCheckPath} {
		if path, err := path(); err == nil && regularFile(filepath.Dir(path), filepath.Base(path)) {
			p.settings = append(p.settings, path)
		}
	}
	if path, err := deviceKey(); err == nil && regularFile(filepath.Dir(filepath.Dir(path)), filepath.Join("device", filepath.Base(path))) {
		p.deviceKey = path
	}
	return p, nil
}

// dataNames names CYFR's data as it is shown: the directory's data
// folders, the stack's volumes and the device key.
func (p *uninstallPlan) dataNames() string {
	var names []string
	for _, name := range p.data {
		names = append(names, filepath.Join(p.dir, name))
	}
	names = append(names, "the stack's volumes (the programs' kept files among them)")
	if p.deviceKey != "" {
		names = append(names, p.deviceKey+" (this machine's device key)")
	}
	return strings.Join(names, ", ")
}

// show says what the uninstall removes and what it keeps.
func (p *uninstallPlan) show(out io.Writer) {
	fmt.Fprintln(out, "cyfr uninstall removes:")
	stack := "  the CYFR stack of " + p.dir + ": its containers and networks"
	if len(p.images) > 0 {
		stack += ", and the images " + strings.Join(p.images, ", ")
	}
	fmt.Fprintln(out, stack)
	if p.screen {
		fmt.Fprintln(out, "  this machine's screen service, which gives the screen back to its login prompt")
	}
	if len(p.files) > 0 {
		fmt.Fprintf(out, "  the files CYFR shipped or wrote in %s, each by name: %s\n", p.dir, strings.Join(p.files, ", "))
	}
	if p.self != "" {
		program := "  this program, " + p.self
		if p.link {
			program += ", and its link " + usrLocalLink
		}
		fmt.Fprintln(out, program)
	}
	if len(p.settings) > 0 {
		fmt.Fprintf(out, "  its settings, %s\n", strings.Join(p.settings, ", "))
	}
	fmt.Fprintln(out, "It keeps:")
	fmt.Fprintf(out, "  CYFR's data, unless you say next to delete it: %s\n", p.dataNames())
	for _, name := range p.linkedData {
		fmt.Fprintf(out, "  %s, a link, as it is\n", filepath.Join(p.dir, name))
	}
	fmt.Fprintf(out, "  every other file in %s, and every link, as it is\n", p.dir)
	if p.cask {
		fmt.Fprintln(out, "  this program, which Homebrew installed: remove it with 'brew uninstall --cask cyfr'")
	}
	fmt.Fprintln(out, "  Docker, and every package other software uses")
}

// runUninstall is `cyfr uninstall` in the working directory: the plan
// shown, the uninstall's question and the data's, then each removal in
// turn, the data last.
func runUninstall(ctx context.Context, out io.Writer, yes, deleteData bool) error {
	if !isCYFRProject() {
		return errors.New("This directory is not a CYFR that cyfr init made, so nothing was removed: it lacks a compose file, .cyfr/ or a .env that names CYFR_ACCESS. Run 'cyfr uninstall' in CYFR's directory")
	}
	named, err := installedFiles()
	if err != nil {
		self, _ := selfExecutable()
		return fmt.Errorf("cyfr uninstall cannot name the files CYFR put here: %v. Nothing was removed. To remove CYFR by hand: run 'cyfr down' here, then remove this directory (with sudo: CYFR's container owns data/), the program %s and ~/.cyfr", err, self)
	}
	p, err := readUninstallPlan(named)
	if err != nil {
		return fmt.Errorf("cyfr uninstall could not read this directory (%v); nothing was removed", err)
	}
	p.show(out)
	reader := bufio.NewReader(askInput)
	if !yes {
		if !askTerminal() {
			return errors.New("Nothing was removed: there is no terminal to confirm the uninstall on. Run it again with --yes to uninstall, or at a terminal")
		}
		if !askedYes(ctx, reader, out, "Uninstall CYFR? (yes/no)") {
			fmt.Fprintln(out, "Nothing was removed.")
			return nil
		}
	}
	switch {
	case deleteData:
		p.deleteData = true
	case askTerminal():
		fmt.Fprintf(out, "CYFR's data: %s.\n", p.dataNames())
		p.deleteData = askedYes(ctx, reader, out, "Delete CYFR's data too? It cannot be undone. (yes/no)")
	}
	if p.deleteData {
		fmt.Fprintln(out, "CYFR's data goes too, last.")
	} else {
		fmt.Fprintln(out, "CYFR's data stays.")
	}

	r := &uninstallRun{p: p, out: out}
	defer machine.forget()
	if err := r.run(ctx); err != nil {
		return err
	}
	for _, image := range r.keptImages {
		fmt.Fprintf(out, "The image %s stays: another container uses it.\n", image)
	}
	if p.deleteData {
		fmt.Fprintln(out, "CYFR is uninstalled, its data with it.")
	} else {
		fmt.Fprintf(out, "CYFR is uninstalled. Its data stays: %s.\n", p.dataNames())
	}
	return nil
}

// askedYes asks question and reports a yes; no answer, or an interrupt,
// is no.
func askedYes(ctx context.Context, reader *bufio.Reader, out io.Writer, question string) bool {
	a, err := ask(ctx, reader, out, question, "no")
	a = strings.ToLower(a)
	return err == nil && (a == "yes" || a == "y")
}

// uninstallTimeout bounds each docker call of the uninstall.
const uninstallTimeout = 5 * time.Minute

// uninstallRun is one uninstall's progress: each removal said as it is
// done, so a failure says what is gone and what is still here.
type uninstallRun struct {
	p          *uninstallPlan
	out        io.Writer
	gone       []string
	keptImages []string
	// filesGone is CYFR's files removed, after which the stack cannot be
	// started from here; dataGone is any of the data removed.
	filesGone, dataGone bool
}

func (r *uninstallRun) done(what string) {
	r.gone = append(r.gone, what)
	fmt.Fprintf(r.out, "Removed %s.\n", what)
}

// failed is a step's failure as the person reads it: what failed, what is
// already gone, and what is still here.
func (r *uninstallRun) failed(step string, err error) error {
	var b strings.Builder
	fmt.Fprintf(&b, "cyfr uninstall stopped: %s failed (%v).", step, err)
	if len(r.gone) == 0 {
		b.WriteString(" Nothing was removed.")
	} else {
		fmt.Fprintf(&b, " Already removed: %s.", strings.Join(r.gone, "; "))
	}
	if !r.dataGone {
		fmt.Fprintf(&b, " CYFR's data is still here: %s.", r.p.dataNames())
	}
	if !r.filesGone && !r.dataGone {
		b.WriteString(" CYFR's files are still here, so 'cyfr up' starts the stack again.")
	}
	b.WriteString(" Run 'cyfr uninstall' again to finish, or remove what is left by hand.")
	return errors.New(b.String())
}

// root runs one command as root, through sudo; each runs alone, so a
// failure is known to be that command's.
func (r *uninstallRun) root(command string) error {
	return machine.apply([]string{command})
}

// run removes, in order: the stack's containers under its lock, the
// screen service and the link onto PATH as root, the networks and images,
// CYFR's files, the settings, the program, and last, when asked, the data.
func (r *uninstallRun) run(ctx context.Context) error {
	p := r.p
	e, unlock, _, err := openLocked(ctx, "uninstall", r.out)
	if err != nil {
		return r.failed("taking the stack's lock", err)
	}
	locked := true
	defer func() {
		if locked {
			unlock()
		}
	}()
	if err := answerFailure(e.Stop(context.WithoutCancel(ctx), "uninstall", true)); err != nil {
		return r.failed("stopping the stack", err)
	}
	r.done("the stack's containers")
	if p.screen {
		for _, c := range screenOffCommands {
			if err := r.root(c); err != nil {
				return r.failed("giving the screen back ("+c+")", err)
			}
		}
		r.done("the screen service")
	}
	if p.link {
		if err := r.root(shellQuote([]string{"rm", "-f", "--", usrLocalLink})); err != nil {
			return r.failed("removing the link "+usrLocalLink, err)
		}
		r.done("the link " + usrLocalLink)
	}
	docker := func(args ...string) (access.Result, error) {
		ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), uninstallTimeout)
		defer cancel()
		res, err := e.Docker().Run(ctx, access.Call{Args: args, Deadline: uninstallTimeout})
		if err == nil && res.ExitCode != 0 {
			err = fmt.Errorf("docker %s %s exited %d: %s", args[0], args[1], res.ExitCode, strings.TrimSpace(string(res.Stderr)))
		}
		return res, err
	}
	label := "label=com.docker.compose.project=" + p.project
	listed := func(kind string) ([]string, error) {
		res, err := docker(kind, "ls", "-q", "--filter", label)
		return strings.Fields(string(res.Stdout)), err
	}
	networks, err := listed("network")
	if err == nil && len(networks) > 0 {
		_, err = docker(append([]string{"network", "rm"}, networks...)...)
	}
	if err != nil {
		return r.failed("removing the stack's networks", err)
	}
	r.done("the stack's networks")
	for _, image := range p.images {
		res, err := docker("image", "rm", image)
		stderr := string(res.Stderr)
		switch {
		case err == nil, strings.Contains(stderr, "No such image"):
		case strings.Contains(stderr, "conflict"), strings.Contains(stderr, "is being used by"):
			r.keptImages = append(r.keptImages, image)
		default:
			return r.failed("removing the image "+image, err)
		}
	}
	r.done("the stack's images")
	// The volumes are listed now, under the lock, so the data's removal at
	// the end removes the ones this stack holds.
	volumes, err := listed("volume")
	if err != nil {
		return r.failed("listing the stack's volumes", err)
	}
	unlock()
	locked = false

	r.filesGone = true
	for _, name := range p.files {
		if err := os.Remove(filepath.Join(p.dir, name)); err != nil && !errors.Is(err, fs.ErrNotExist) {
			return r.failed("removing "+name, err)
		}
	}
	removeEmptyParents(p.dir, p.files)
	r.done("the files CYFR put in " + p.dir)
	for _, path := range p.settings {
		if err := os.Remove(path); err != nil && !errors.Is(err, fs.ErrNotExist) {
			return r.failed("removing "+path, err)
		}
	}
	if len(p.settings) > 0 {
		r.done("its settings")
	}
	if p.self != "" {
		if err := os.Remove(p.self); err != nil {
			return r.failed("removing this program "+p.self, err)
		}
		r.done("this program")
	}

	if p.deleteData {
		var paths []string
		for _, name := range p.data {
			paths = append(paths, filepath.Join(p.dir, name))
		}
		if len(paths) > 0 {
			r.dataGone = true
			if err := r.root(shellQuote(append([]string{"rm", "-rf", "--"}, paths...))); err != nil {
				return r.failed("removing "+strings.Join(paths, " and ")+" as root", err)
			}
			r.done(strings.Join(paths, " and "))
		}
		if len(volumes) > 0 {
			r.dataGone = true
			if _, err := docker(append([]string{"volume", "rm"}, volumes...)...); err != nil {
				return r.failed("removing the stack's volumes", err)
			}
			r.done("the stack's volumes")
		}
		if p.deviceKey != "" {
			r.dataGone = true
			if err := os.Remove(p.deviceKey); err != nil {
				return r.failed("removing the device key "+p.deviceKey, err)
			}
			r.done("this machine's device key")
		}
	}
	// Each directory goes only when nothing is left in it: a person's own
	// file, or the data kept, keeps it.
	if p.deviceKey != "" {
		removeEmptyDir(filepath.Dir(p.deviceKey))
	}
	if dir, err := config.DefaultConfigDir(); err == nil {
		removeEmptyDir(dir)
	}
	removeEmptyDir(p.dir)
	return nil
}

// removeEmptyDir removes path when it is a real directory, not a link,
// and nothing is in it.
func removeEmptyDir(path string) {
	if info, err := os.Lstat(path); err == nil && info.IsDir() {
		_ = os.Remove(path)
	}
}

// removeEmptyParents removes, deepest first, each directory under dir that
// holds one of files and is a real directory, not a link, once it is
// empty; a directory that still holds anything stays.
func removeEmptyParents(dir string, files []string) {
	var dirs []string
	for _, name := range files {
		for parent := filepath.Dir(filepath.FromSlash(name)); parent != "."; parent = filepath.Dir(parent) {
			if !slices.Contains(dirs, parent) {
				dirs = append(dirs, parent)
			}
		}
	}
	slices.SortFunc(dirs, func(a, b string) int {
		return strings.Count(b, string(filepath.Separator)) - strings.Count(a, string(filepath.Separator))
	})
	for _, parent := range dirs {
		path := filepath.Join(dir, parent)
		if info, err := os.Lstat(path); err == nil && info.IsDir() {
			_ = os.Remove(path)
		}
	}
}
