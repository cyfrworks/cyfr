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
	"path/filepath"
	"strings"
	"time"

	"github.com/cyfr/codex/internal/access"
	"github.com/cyfr/codex/internal/config"
	"github.com/spf13/cobra"
)

func init() {
	uninstallCmd.Flags().Bool("yes", false, "Uninstall without asking to confirm it")
	rootCmd.AddCommand(uninstallCmd)
}

var uninstallCmd = &cobra.Command{
	Use:     "uninstall",
	Short:   "Take CYFR's stack and this program off this machine: it stops CYFR as cyfr down does and removes nothing else from your folder",
	GroupID: "server",
	Long: `Take the CYFR in this directory off this machine, with this program. It stops CYFR as cyfr down does and removes nothing else from your folder.

cyfr uninstall shows what it removes and what it leaves, then asks once (--yes answers; with no terminal and no --yes it removes nothing; answered no, it removes nothing and exits 0). It stops the stack as cyfr down does, then removes:
- the stack's networks and the images its compose file names (one another container still uses stays, and is said);
- this machine's screen service, when 'cyfr screen on' installed it, giving the screen back to its login prompt, and the link to this program in /usr/local/bin, both as root through sudo;
- this program's own settings files, ~/.cyfr/config.json and ~/.cyfr/version-check.json, by those names;
- this program. A Homebrew install is left to 'brew uninstall --cask cyfr'.
Of these, whatever lies in this directory or resolves into it through a link stays.

It leaves every file in this directory as cyfr down leaves it (the compose file, the Caddyfile, .env, .gitignore, the guides, .cyfr/, data/, backups/), the stack's volumes and this machine's device key. It ends by naming each by its path, and the command that removes the volumes.

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

// uninstallPlan is what cyfr uninstall removes and leaves, read before
// anything is removed.
type uninstallPlan struct {
	dir     string
	project string
	images  []string
	screen  bool
	cask    bool
	// self, link and settings are the program, its link onto PATH and its
	// settings files that the uninstall removes; inFolder are those of them
	// that resolve into the project folder, which stay.
	self     string
	link     bool
	settings []string
	inFolder []string
	// deviceKey is this machine's device key, which stays.
	deviceKey string
}

// readUninstallPlan reads what an uninstall of the CYFR in the working
// directory removes and leaves; it changes nothing.
func readUninstallPlan() (*uninstallPlan, error) {
	dir, err := os.Getwd()
	if err != nil {
		return nil, err
	}
	realDir, err := filepath.EvalSymlinks(dir)
	if err != nil {
		return nil, err
	}
	p := &uninstallPlan{dir: dir, project: access.ProjectName(dir), screen: screenInstalled(), cask: caskInstalled()}
	// removable is the one rule every removal passes: what resolves into
	// the project folder stays, and is named.
	removable := func(path string) bool {
		if resolvesInto(realDir, path) {
			p.inFolder = append(p.inFolder, path)
			return false
		}
		return true
	}
	for _, name := range access.ComposeMainFiles {
		if fileExists(name) {
			p.images = imagesFromCompose(name, []string{buildsProfile, access.ModePublic, access.ModeTailnet})
			break
		}
	}
	if !p.cask {
		if self, err := selfExecutable(); err == nil {
			if self, err = filepath.EvalSymlinks(self); err == nil {
				if removable(self) {
					p.self = self
				}
				if target, err := filepath.EvalSymlinks(usrLocalLink); err == nil && target == self && usrLocalLink != self {
					p.link = removable(usrLocalLink)
				}
			}
		}
	}
	for _, path := range []func() (string, error){config.DefaultConfigPath, versionCheckPath} {
		if path, err := path(); err == nil {
			if _, err := os.Stat(path); err == nil && removable(path) {
				p.settings = append(p.settings, path)
			}
		}
	}
	if path, err := deviceKey(); err == nil && fileExists(path) {
		p.deviceKey = path
	}
	return p, nil
}

// resolvesInto reports whether path, resolved through every link, lies in
// realDir, itself resolved. A path that does not resolve counts as in it,
// so a doubt never removes.
func resolvesInto(realDir, path string) bool {
	real, err := filepath.EvalSymlinks(path)
	if err != nil {
		return true
	}
	rel, err := filepath.Rel(realDir, real)
	return err != nil || (rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator)))
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
	fmt.Fprintf(out, "  every file in %s, CYFR's data among them, as cyfr down leaves it\n", p.dir)
	if len(p.inFolder) > 0 {
		fmt.Fprintf(out, "  %s, which resolve into that folder\n", strings.Join(p.inFolder, ", "))
	}
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
// shown, one question, then each removal in turn, and what is left named.
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

// left names what the uninstall left, each by its path, and the one
// command it gives, the volumes' removal: it never prints a command that
// removes a file or a folder.
func (p *uninstallPlan) left(volumes []string) string {
	var b strings.Builder
	b.WriteString("CYFR is uninstalled. Left as they were:\n")
	fmt.Fprintf(&b, "  every file in %s, CYFR's data among them\n", p.dir)
	if len(p.inFolder) > 0 {
		fmt.Fprintf(&b, "  %s, which resolve into that folder\n", strings.Join(p.inFolder, ", "))
	}
	if p.deviceKey != "" {
		fmt.Fprintf(&b, "  this machine's device key, %s\n", p.deviceKey)
	}
	if len(volumes) > 0 {
		fmt.Fprintf(&b, "  the stack's volumes, which this command removes:\n    docker volume rm %s\n", shellQuote(volumes))
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

// run removes, in order: the stack's containers, stopped as cyfr down
// stops them, under the lock it keeps; the screen service and the link
// onto PATH as root; the networks and images; the settings files by name;
// and the program. The plan holds nothing that resolves into the project
// folder.
func (r *uninstallRun) run(ctx context.Context) error {
	p := r.p
	e, unlock, err := stopStack(ctx, "uninstall", r.out)
	if err != nil {
		return r.failed("stopping the stack as cyfr down does", err)
	}
	defer unlock()
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
