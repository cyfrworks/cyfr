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
	"slices"
	"strings"
	"time"

	"github.com/cyfr/codex/internal/access"
	"github.com/cyfr/codex/internal/config"
	"github.com/spf13/cobra"
)

func init() {
	uninstallCmd.Flags().Bool("delete-data", false, "Remove CYFR's data too: data/ and backups/, through sudo, since CYFR's container owns them")
	uninstallCmd.Flags().Bool("yes", false, "Uninstall without asking to confirm it")
	rootCmd.AddCommand(uninstallCmd)
}

var uninstallCmd = &cobra.Command{
	Use:     "uninstall",
	Short:   "Take CYFR off this machine: its stack and this program, keeping its data unless asked",
	GroupID: "server",
	Long: `Take the CYFR in this directory off this machine, with this program.

cyfr uninstall shows what it removes and what it keeps, then asks (--yes removes without asking; with no terminal and no --yes it shows the list and removes nothing; answered no, it removes nothing and exits 0). It removes:

- the stack: every container, network and volume of this directory's project, and the images its compose file names (one another container still uses stays, and is said);
- this machine's screen service, when 'cyfr screen on' installed it, giving the screen back to its login prompt;
- everything in this directory but data/ and backups/, and the directory itself once it is empty;
- this program and the link to it in /usr/local/bin, and its settings in ~/.cyfr. A Homebrew install is left to 'brew uninstall --cask cyfr'.

It keeps CYFR's data, data/ and backups/, unless --delete-data asks for them too: CYFR's container owns them, so they are removed as root, through sudo, which asks for this machine's password in its own prompt. Docker and every package other software uses stay. Commands that need root run first, through one sudo, after the stack has stopped; a refused sudo removes nothing else, and 'cyfr up' starts the stack again.`,
	Example: "  cyfr uninstall\n  cyfr uninstall --delete-data",
	RunE: func(cmd *cobra.Command, args []string) error {
		ctx := cmd.Context()
		if ctx == nil {
			ctx = context.Background()
		}
		deleteData, _ := cmd.Flags().GetBool("delete-data")
		yes, _ := cmd.Flags().GetBool("yes")
		return runUninstall(ctx, cmd.OutOrStdout(), deleteData, yes)
	},
}

// usrLocalLink is the link install.sh makes onto PATH, and screenInstalled
// whether `cyfr screen on` installed the screen service; tests stand in
// for both.
var (
	usrLocalLink    = "/usr/local/bin/cyfr"
	screenInstalled = func() bool { return fileExists(screenUnit) }
)

// keptData are the entries of CYFR's directory that hold its data, kept
// unless --delete-data: the database and storage, and the snapshots.
var keptData = []string{"data", "backups"}

// uninstallPlan is what cyfr uninstall removes, read before anything is.
type uninstallPlan struct {
	dir     string
	project string
	images  []string
	// files are the directory's entries it removes, by name.
	files []string
	// data are the data entries it removes as root (--delete-data).
	data       []string
	deleteData bool
	screen     bool
	self       string
	cask       bool
	link       bool
	config     string
}

// readUninstallPlan reads what an uninstall of the CYFR in the working
// directory removes; it changes nothing.
func readUninstallPlan(deleteData bool) (*uninstallPlan, error) {
	dir, err := os.Getwd()
	if err != nil {
		return nil, err
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	p := &uninstallPlan{dir: dir, project: access.ProjectName(dir), deleteData: deleteData, screen: screenInstalled(), cask: caskInstalled()}
	for _, name := range access.ComposeMainFiles {
		if fileExists(name) {
			p.images = imagesFromCompose(name, []string{buildsProfile, access.ModePublic, access.ModeTailnet})
			break
		}
	}
	for _, entry := range entries {
		switch {
		case !slices.Contains(keptData, entry.Name()):
			p.files = append(p.files, entry.Name())
		case deleteData:
			p.data = append(p.data, entry.Name())
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
	if cfg, err := config.DefaultConfigDir(); err == nil && fileExists(cfg) {
		p.config = cfg
	}
	return p, nil
}

// rootCommands are the commands the uninstall runs as root, through one
// sudo: the screen given back, the data removed, the link onto PATH.
func (p *uninstallPlan) rootCommands() []string {
	var commands []string
	if p.screen {
		commands = append(commands, screenOffCommands...)
	}
	if len(p.data) > 0 {
		paths := []string{"rm", "-rf", "--"}
		for _, name := range p.data {
			paths = append(paths, filepath.Join(p.dir, name))
		}
		commands = append(commands, shellQuote(paths))
	}
	if p.link {
		commands = append(commands, shellQuote([]string{"rm", "-f", "--", usrLocalLink}))
	}
	return commands
}

// show says what the uninstall removes and keeps, and the commands it
// runs as root.
func (p *uninstallPlan) show(out io.Writer) {
	fmt.Fprintln(out, "cyfr uninstall removes from this machine:")
	stack := "  the CYFR stack of " + p.dir + ": its containers, networks and volumes"
	if len(p.images) > 0 {
		stack += ", and the images " + strings.Join(p.images, ", ")
	}
	fmt.Fprintln(out, stack)
	if p.screen {
		fmt.Fprintln(out, "  this machine's screen service, which gives the screen back to its login prompt")
	}
	if len(p.files) > 0 {
		fmt.Fprintf(out, "  in %s: %s\n", p.dir, strings.Join(p.files, ", "))
	}
	for _, name := range p.data {
		fmt.Fprintf(out, "  CYFR's data, %s\n", filepath.Join(p.dir, name))
	}
	if p.self != "" {
		program := "  this program, " + p.self
		if p.link {
			program += ", and its link " + usrLocalLink
		}
		fmt.Fprintln(out, program)
	}
	if p.config != "" {
		fmt.Fprintf(out, "  its settings, %s\n", p.config)
	}
	fmt.Fprintln(out, "It keeps:")
	if !p.deleteData {
		fmt.Fprintf(out, "  CYFR's data, data/ and backups/ in %s (cyfr uninstall --delete-data removes it too)\n", p.dir)
	}
	if p.cask {
		fmt.Fprintln(out, "  this program, which Homebrew installed: remove it with 'brew uninstall --cask cyfr'")
	}
	fmt.Fprintln(out, "  Docker, and every package other software uses")
	if commands := p.rootCommands(); len(commands) > 0 {
		fmt.Fprintln(out, "These commands run as root, through one sudo, which asks for this machine's password:")
		for _, c := range commands {
			fmt.Fprintf(out, "  %s\n", c)
		}
	}
}

// runUninstall is `cyfr uninstall` in the working directory: the plan
// shown and confirmed, then, under the stack's lock, the stack stopped,
// the root commands run, and the project's networks, volumes and images
// removed; then the directory's files, the settings and the program. A
// failure before the root commands have run removes nothing; the stack
// stays stopped and 'cyfr up' starts it.
func runUninstall(ctx context.Context, out io.Writer, deleteData, yes bool) error {
	if !access.HasComposeFile(".") {
		return fmt.Errorf("There is no CYFR in this directory, so nothing was removed: it holds no compose file (%s). Run 'cyfr uninstall' in CYFR's directory, the one that holds its docker-compose.yml", strings.Join(access.ComposeMainFiles, ", "))
	}
	p, err := readUninstallPlan(deleteData)
	if err != nil {
		return fmt.Errorf("cyfr uninstall could not read this directory (%v); nothing was removed", err)
	}
	p.show(out)
	if !yes {
		if !askTerminal() {
			return errors.New("Nothing was removed: there is no terminal to confirm the uninstall on. Run it again with --yes to uninstall, or at a terminal")
		}
		a, err := ask(ctx, bufio.NewReader(askInput), out, "Uninstall CYFR? (yes/no)", "no")
		if err != nil {
			return interruption{errors.New("cyfr uninstall was interrupted; nothing was removed")}
		}
		if a = strings.ToLower(a); a != "yes" && a != "y" {
			fmt.Fprintln(out, "Nothing was removed.")
			return nil
		}
	}

	kept, err := p.removeStack(ctx, out)
	if err != nil {
		return err
	}
	if err := p.removeFiles(); err != nil {
		return fmt.Errorf("The stack is removed, but %v. Remove what is left of %s by hand", err, p.dir)
	}
	if p.config != "" {
		if err := os.RemoveAll(p.config); err != nil {
			return fmt.Errorf("The stack and CYFR's files are removed, but its settings %s were not (%v); remove them by hand", p.config, err)
		}
	}
	if p.self != "" {
		if err := os.Remove(p.self); err != nil {
			return fmt.Errorf("CYFR is removed but this program was not (%v); remove it with: sudo rm %s", err, p.self)
		}
	}
	for _, image := range kept {
		fmt.Fprintf(out, "The image %s stays: another container uses it.\n", image)
	}
	if !p.deleteData {
		fmt.Fprintf(out, "CYFR is uninstalled. Its data stays in %s; cyfr uninstall --delete-data, or sudo rm -rf %s, removes it.\n", p.dir, p.dir)
	} else {
		fmt.Fprintln(out, "CYFR is uninstalled, its data with it.")
	}
	return nil
}

// uninstallTimeout bounds each docker call of the uninstall.
const uninstallTimeout = 5 * time.Minute

// removeStack stops the stack under its lock, runs the root commands, and
// removes the project's networks, volumes and images, answering the images
// another container still uses.
func (p *uninstallPlan) removeStack(ctx context.Context, out io.Writer) ([]string, error) {
	e, unlock, _, err := openLocked(ctx, "uninstall", out)
	if err != nil {
		return nil, err
	}
	defer unlock()
	if err := answerFailure(e.Stop(context.WithoutCancel(ctx), "uninstall", true)); err != nil {
		return nil, fmt.Errorf("%v; nothing was removed", err)
	}
	if commands := p.rootCommands(); len(commands) > 0 {
		err := machine.apply(commands)
		machine.forget()
		if err != nil {
			return nil, errors.New("The commands as root did not run, so nothing was removed; the stack is stopped, and 'cyfr up' starts it again")
		}
	}
	docker := func(args ...string) (access.Result, error) {
		ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), uninstallTimeout)
		defer cancel()
		return e.Docker().Run(ctx, access.Call{Args: args, Deadline: uninstallTimeout})
	}
	label := "label=com.docker.compose.project=" + p.project
	for _, kind := range []string{"network", "volume"} {
		res, err := docker(kind, "ls", "-q", "--filter", label)
		if err == nil && res.ExitCode != 0 {
			err = fmt.Errorf("docker %s ls exited %d", kind, res.ExitCode)
		}
		if err != nil {
			return nil, fmt.Errorf("The stack is stopped, but its %ss could not be listed (%v); nothing else was removed", kind, err)
		}
		if ids := strings.Fields(string(res.Stdout)); len(ids) > 0 {
			res, err := docker(append([]string{kind, "rm"}, ids...)...)
			if err == nil && res.ExitCode != 0 {
				err = fmt.Errorf("docker %s rm exited %d: %s", kind, res.ExitCode, strings.TrimSpace(string(res.Stderr)))
			}
			if err != nil {
				return nil, fmt.Errorf("The stack is stopped, but its %ss were not removed (%v); nothing else was removed", kind, err)
			}
		}
	}
	var kept []string
	for _, image := range p.images {
		res, err := docker("image", "rm", image)
		switch {
		case err != nil:
			return nil, fmt.Errorf("The stack's containers, networks and volumes are removed, but the image %s was not (%v)", image, err)
		case res.ExitCode == 0, strings.Contains(string(res.Stderr), "No such image"):
		case strings.Contains(string(res.Stderr), "is being used by"), strings.Contains(string(res.Stderr), "conflict"):
			kept = append(kept, image)
		default:
			return nil, fmt.Errorf("The stack's containers, networks and volumes are removed, but the image %s was not (%s)", image, strings.TrimSpace(string(res.Stderr)))
		}
	}
	return kept, nil
}

// removeFiles removes the directory's entries the plan names, then the
// directory itself when nothing is left in it. Its data, when the plan
// removes it, went with the root commands.
func (p *uninstallPlan) removeFiles() error {
	for _, name := range p.files {
		if err := os.RemoveAll(filepath.Join(p.dir, name)); err != nil {
			return fmt.Errorf("%s could not be removed (%v)", name, err)
		}
	}
	if left, err := os.ReadDir(p.dir); err == nil && len(left) == 0 {
		if err := os.Remove(p.dir); err != nil {
			return fmt.Errorf("the empty directory could not be removed (%v)", err)
		}
	}
	return nil
}
