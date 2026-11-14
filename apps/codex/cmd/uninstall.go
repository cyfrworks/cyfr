// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/user"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"github.com/cyfr/codex/internal/access"
	"github.com/cyfr/codex/internal/config"
	"github.com/cyfr/codex/internal/scaffold"
	"github.com/spf13/cobra"
)

func init() {
	uninstallCmd.Flags().Bool("yes", false, "Uninstall without asking to confirm it")
	rootCmd.AddCommand(uninstallCmd)
}

var uninstallCmd = &cobra.Command{
	Use:     "uninstall",
	Short:   "Take CYFR's stack and this program off this machine, deleting no file in your folder",
	GroupID: "server",
	Long: `Take the CYFR in this directory off this machine, with this program. It deletes no file in your folder.

cyfr uninstall shows what it removes and what it leaves, then asks once (--yes answers; with no terminal and no --yes it removes nothing; answered no, it removes nothing and exits 0). It removes:
- the stack's containers, under its lock, and its networks and the images its compose file names (one another container still uses stays, and is said);
- this machine's screen service, when 'cyfr screen on' installed it, giving the screen back to its login prompt, and the link to this program in /usr/local/bin, both as root through sudo;
- this program's own settings files, ~/.cyfr/config.json and ~/.cyfr/version-check.json, by those names;
- this program. A Homebrew install is left to 'brew uninstall --cask cyfr'.

It leaves every file in this directory as it is (the compose file, the Caddyfile, .env, .gitignore, the guides, .cyfr/, data/, backups/), the stack's volumes and this machine's device key. It ends by naming each and the commands that remove them by hand. When this directory is your user folder, ~, it names the entries CYFR's install makes there, never the folder.

Each step is said as it is done; when one fails, the command says what is already gone and what is still here.`,
	Example: "  cyfr uninstall\n  cyfr uninstall --yes",
	RunE: func(cmd *cobra.Command, args []string) error {
		ctx := cmd.Context()
		if ctx == nil {
			ctx = context.Background()
		}
		yes, _ := cmd.Flags().GetBool("yes")
		return runUninstall(ctx, cmd.OutOrStdout(), yes)
	},
}

// usrLocalLink is the link install.sh makes onto PATH, and screenInstalled
// whether `cyfr screen on` installed the screen service; tests stand in
// for both.
var (
	usrLocalLink    = "/usr/local/bin/cyfr"
	screenInstalled = func() bool { return fileExists(screenUnit) }
)

// stateMarker is the stack's state, which cyfr init makes beside the .env
// naming how CYFR is reached: together, CYFR's own mark of a project.
const stateMarker = ".cyfr"

// isCYFRProject reports whether the working directory is a CYFR cyfr init
// made: a compose file, .cyfr/, and a .env that names CYFR_ACCESS.
func isCYFRProject() bool {
	values, err := access.ReadEnvValues(".env")
	return err == nil && values["CYFR_ACCESS"] != "" && access.HasComposeFile(".") && fileExists(stateMarker)
}

// installEntries are the entries CYFR's install makes in a project
// folder: the scaffold's, .env, the .gitignore init writes, the stack's
// state and the data. When the folder is the home folder, the closing
// sentence names these, never the folder.
var installEntries = append(slices.Clone(scaffold.Guides),
	scaffold.SeccompProfile, "docker-compose.yml", "Caddyfile", ".env", ".env.example", ".env.locus.example",
	".gitignore", "LICENSE", "LICENSES", "FAIR_SOURCE.md", "wit", "aqua", stateMarker, "data", "backups")

// uninstallPlan is what cyfr uninstall removes and leaves, read before
// anything is removed.
type uninstallPlan struct {
	dir     string
	project string
	images  []string
	screen  bool
	self    string
	cask    bool
	link    bool
	// settings are this program's settings files, by their exact names.
	settings []string
	// deviceKey is this machine's device key, which stays.
	deviceKey string
	// holdsHome is the project folder being the home folder, or holding
	// it: no command the uninstall names removes the folder.
	holdsHome bool
}

// readUninstallPlan reads what an uninstall of the CYFR in the working
// directory removes and leaves; it changes nothing.
func readUninstallPlan() (*uninstallPlan, error) {
	dir, err := os.Getwd()
	if err != nil {
		return nil, err
	}
	p := &uninstallPlan{dir: dir, project: access.ProjectName(dir), screen: screenInstalled(), cask: caskInstalled(), holdsHome: holdsHome(dir)}
	for _, name := range access.ComposeMainFiles {
		if fileExists(name) {
			p.images = imagesFromCompose(name, []string{buildsProfile, access.ModePublic, access.ModeTailnet})
			break
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
		if path, err := path(); err == nil {
			if info, err := os.Lstat(path); err == nil && info.Mode().IsRegular() {
				p.settings = append(p.settings, path)
			}
		}
	}
	if path, err := deviceKey(); err == nil && fileExists(path) {
		p.deviceKey = path
	}
	return p, nil
}

// holdsHome reports whether dir is a home folder, or holds one, however it
// is reached: HOME through a link, the account's own home when HOME says
// otherwise, and the invoking account's under sudo.
func holdsHome(dir string) bool {
	homes := []string{os.Getenv("HOME")}
	if u, err := user.Current(); err == nil {
		homes = append(homes, u.HomeDir)
	}
	if name := os.Getenv("SUDO_USER"); name != "" {
		if u, err := user.Lookup(name); err == nil {
			homes = append(homes, u.HomeDir)
		}
	}
	real, err := filepath.EvalSymlinks(dir)
	if err != nil {
		real = dir
	}
	for _, home := range homes {
		if home == "" {
			continue
		}
		if resolved, err := filepath.EvalSymlinks(home); err == nil {
			home = resolved
		}
		if home == real || strings.HasPrefix(home, real+string(filepath.Separator)) {
			return true
		}
	}
	return false
}

// show says what the uninstall removes and what it leaves.
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
	fmt.Fprintln(out, "It leaves, as they are:")
	fmt.Fprintf(out, "  every file in %s, CYFR's data among them\n", p.dir)
	fmt.Fprintln(out, "  the stack's volumes")
	if p.deviceKey != "" {
		fmt.Fprintf(out, "  this machine's device key, %s\n", p.deviceKey)
	}
	if p.cask {
		fmt.Fprintln(out, "  this program, which Homebrew installed: remove it with 'brew uninstall --cask cyfr'")
	}
	fmt.Fprintln(out, "  Docker, and every package other software uses")
}

// runUninstall is `cyfr uninstall` in the working directory: the plan
// shown, one question, then each removal in turn, and what is left named
// with the commands that remove it.
func runUninstall(ctx context.Context, out io.Writer, yes bool) error {
	if !isCYFRProject() {
		return errors.New("This directory is not a CYFR that cyfr init made, so nothing was removed: it lacks a compose file, .cyfr/ or a .env that names CYFR_ACCESS. Run 'cyfr uninstall' in CYFR's directory")
	}
	p, err := readUninstallPlan()
	if err != nil {
		return fmt.Errorf("cyfr uninstall could not read this directory (%v); nothing was removed", err)
	}
	p.show(out)
	if !yes {
		if !askTerminal() {
			return errors.New("Nothing was removed: there is no terminal to confirm the uninstall on. Run it again with --yes to uninstall, or at a terminal")
		}
		a, err := ask(ctx, bufio.NewReader(askInput), out, "Uninstall CYFR? (yes/no)", "no")
		if a = strings.ToLower(a); err != nil || (a != "yes" && a != "y") {
			fmt.Fprintln(out, "Nothing was removed.")
			return nil
		}
	}
	r := &uninstallRun{p: p, out: out}
	defer machine.forget()
	if err := r.run(ctx); err != nil {
		return err
	}
	for _, image := range r.keptImages {
		fmt.Fprintf(out, "The image %s stays: another container uses it.\n", image)
	}
	fmt.Fprint(out, p.left(r.volumes))
	return nil
}

// left names what the uninstall left and the commands that remove it by
// hand: the folder, or, when the folder is or holds a home folder, the
// entries CYFR's install made in it, never the folder; the volumes by
// name; the device key.
func (p *uninstallPlan) left(volumes []string) string {
	var b strings.Builder
	b.WriteString("CYFR is uninstalled. Left as they were, with the commands that remove them by hand:\n")
	if p.holdsHome {
		var entries []string
		for _, name := range installEntries {
			if _, err := os.Lstat(filepath.Join(p.dir, name)); err == nil {
				entries = append(entries, name)
			}
		}
		fmt.Fprintf(&b, "  the entries CYFR's install made in %s, CYFR's data among them:\n    cd %s && sudo rm -rf -- %s\n",
			p.dir, shellQuote([]string{p.dir}), shellQuote(entries))
	} else {
		fmt.Fprintf(&b, "  the folder %s, CYFR's data in it:\n    sudo rm -rf -- %s\n", p.dir, shellQuote([]string{p.dir}))
	}
	if len(volumes) > 0 {
		fmt.Fprintf(&b, "  the stack's volumes:\n    docker volume rm %s\n", shellQuote(volumes))
	}
	if p.deviceKey != "" {
		fmt.Fprintf(&b, "  this machine's device key:\n    rm -- %s\n", shellQuote([]string{p.deviceKey}))
	}
	return b.String()
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
	volumes    []string
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
	fmt.Fprintf(&b, " Every file in %s is still here, so 'cyfr up' starts the stack again. Run 'cyfr uninstall' again to finish.", r.p.dir)
	return errors.New(b.String())
}

// run removes, in order: the stack's containers under its lock, the
// screen service and the link onto PATH as root, the networks and images,
// the settings files by name, and the program. It deletes no file in the
// project folder.
func (r *uninstallRun) run(ctx context.Context) error {
	p := r.p
	e, unlock, _, err := openLocked(ctx, "uninstall", r.out)
	if err != nil {
		return r.failed("taking the stack's lock", err)
	}
	defer unlock()
	if err := answerFailure(e.Stop(context.WithoutCancel(ctx), "uninstall", true)); err != nil {
		return r.failed("stopping the stack", err)
	}
	r.done("the stack's containers")
	if p.screen {
		for _, c := range screenOffCommands {
			if err := machine.apply([]string{c}); err != nil {
				return r.failed("giving the screen back ("+c+")", err)
			}
		}
		r.done("the screen service")
	}
	if p.link {
		if err := machine.apply([]string{shellQuote([]string{"rm", "-f", "--", usrLocalLink})}); err != nil {
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
	// The volumes stay; they are listed to be named at the end.
	if r.volumes, err = listed("volume"); err != nil {
		return r.failed("listing the stack's volumes", err)
	}
	for _, path := range p.settings {
		if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
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
	return nil
}
