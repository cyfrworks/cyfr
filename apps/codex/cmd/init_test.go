// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"bytes"
	"context"
	"errors"
	"io"
	"io/fs"
	"os"
	"os/user"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/cyfr/codex/internal/access"
	"github.com/cyfr/codex/internal/config"
)

// newInitProject makes the working directory, a directory of the test's
// own, a new project for cyfr init: the shipped .env.example in it, as a
// dev build's init finds it once copied from a checkout.
func newInitProject(t *testing.T) string {
	t.Helper()
	template := readShippedTemplate(t)
	dir := t.TempDir()
	t.Chdir(dir)
	if err := os.WriteFile(".env.example", []byte(template), 0644); err != nil {
		t.Fatal(err)
	}
	return dir
}

// projectEnv answers the .env of the working directory, which must exist.
func projectEnv(t *testing.T) *envFile {
	t.Helper()
	data, err := os.ReadFile(".env")
	if err != nil {
		t.Fatal(err)
	}
	return parseEnvFile(string(data))
}

// accessOf is the mode the working directory's .env holds.
func accessOf(t *testing.T) string {
	t.Helper()
	mode, _ := projectEnv(t).value("CYFR_ACCESS")
	return mode
}

// setupTokenOf is the setup token the working directory's .env holds,
// which must be 64 lowercase hexadecimal characters.
func setupTokenOf(t *testing.T) string {
	t.Helper()
	token, _ := projectEnv(t).value(setupTokenVar)
	if !regexp.MustCompile(`^[0-9a-f]{64}$`).MatchString(token) {
		t.Fatalf(".env's %s is %q, not 64 lowercase hexadecimal characters", setupTokenVar, token)
	}
	return token
}

// setupLinkLine is the line init's ending gives the setup link of the
// CYFR at address on, with the setup token the working directory's .env
// holds.
func setupLinkLine(t *testing.T, address string) string {
	t.Helper()
	return "Next: cyfr up. Then open " + address + "/setup#" + setupTokenOf(t) + " to set up its first person, or run cyfr login --setup here.\n"
}

// initThenPublic is a new CYFR from init, then made public at
// cyfr.example.com, with acmeEmail, by cyfr access: the engine's switch of
// its stopped stack.
func initThenPublic(ctx context.Context, acmeEmail string, out io.Writer) error {
	if err := initProject(ctx, initOptions{noPull: true}, nil, out, out); err != nil {
		return err
	}
	return runAccess(ctx, access.ModePublic, accessOptions{domain: "cyfr.example.com", acmeEmail: acmeEmail}, true, "", out)
}

// nothingWritten fails unless the working directory holds exactly names.
func nothingWritten(t *testing.T, names ...string) {
	t.Helper()
	entries, err := os.ReadDir(".")
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, e := range entries {
		got = append(got, e.Name())
	}
	slices.Sort(names)
	if !slices.Equal(got, names) {
		t.Errorf("the project holds %v, want %v alone", got, names)
	}
}

// init asks nothing about how CYFR is reached, at a terminal or not: it
// writes a home reached from this machine, takes no lock and switches
// nothing, and none of the flags that chose another way is init's.
func TestInitAsksNothingAboutHowCYFRIsReached(t *testing.T) {
	// A machine init installs nothing on and offers no screen to.
	saved := machine.supported
	t.Cleanup(func() { machine.supported = saved })
	machine.supported = func() bool { return false }
	for _, terminal := range []bool{false, true} {
		newInitProject(t)
		s := useFakeEngine(t)
		askTerminal = func() bool { return terminal }
		askInput = noInput{t}
		var out bytes.Buffer
		if err := runInit(context.Background(), initOptions{noPull: true}, &out, &out); err != nil {
			t.Fatalf("init: %v\n%s", err, out.String())
		}
		if got := accessOf(t); got != access.ModeLocal {
			t.Errorf("the home is %s, want local", got)
		}
		if s.locks != 0 || len(s.joins) != 0 || len(s.switches) != 0 {
			t.Errorf("init took the lock %d times, joined %v and switched %v", s.locks, s.joins, s.switches)
		}
		if strings.Contains(out.String(), "How will you reach CYFR?") {
			t.Errorf("init asked how CYFR is reached:\n%s", out.String())
		}
	}
	for _, name := range []string{"access", "domain", "acme-email", "tailscale-auth-key-file", "hostname", "no-open"} {
		if initCmd.Flags().Lookup(name) != nil {
			t.Errorf("cyfr init has --%s", name)
		}
	}
}

// An existing .env is read as compose and the engine read it
// (access.ReadEnvValues): `export CYFR_ACCESS=local` says how the home is
// reached, a stack key spelled `export NAME=` is kept and never minted
// again beside it, and the port is the last assignment's.
func TestInitReadsAnExistingEnvAsComposeDoes(t *testing.T) {
	newInitProject(t)
	useFakeEngine(t)
	const kept = "kept-secret-key-base-kept-secret-key-base-kept-secret-key-base-kept"
	env := "export CYFR_ACCESS=local\nexport " + secretKeyBaseVar + "=" + kept + "\nCYFR_PORT=4000\nCYFR_PORT: 4123\n"
	if err := os.WriteFile(".env", []byte(env), 0600); err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	if err := runInit(context.Background(), initOptions{noPull: true}, &out, &out); err != nil {
		t.Fatalf("init on %q: %v\n%s", env, err, out.String())
	}
	f := projectEnv(t)
	if v, _ := f.value(secretKeyBaseVar); v != kept || len(f.assignments(secretKeyBaseVar)) != 1 {
		t.Errorf("init rewrote the kept %s (now %q, on %d lines):\n%s", secretKeyBaseVar, v, len(f.assignments(secretKeyBaseVar)), f.String())
	}
	if !strings.HasPrefix(f.String(), env) {
		t.Errorf("init moved .env's own lines:\n%s", f.String())
	}
	cfg, err := config.Load()
	if err != nil {
		t.Fatal(err)
	}
	if got := cfg.Contexts["local"].URL; got != "http://127.0.0.1:4123" {
		t.Errorf("the local context is %s, want the port of .env's last assignment", got)
	}
}

// The CLI's local context and Prism's address are the loopback port the
// home's .env names.
func TestInitFollowsTheTemplatesPort(t *testing.T) {
	newInitProject(t)
	useFakeEngine(t)
	template := strings.Replace(read(t, ".env.example"), "\nCYFR_PORT=4000\n", "\nCYFR_PORT=4123\n", 1)
	if err := os.WriteFile(".env.example", []byte(template), 0644); err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	if err := runInit(context.Background(), initOptions{noPull: true}, &out, &out); err != nil {
		t.Fatalf("init: %v\n%s", err, out.String())
	}
	cfg, err := config.Load()
	if err != nil {
		t.Fatal(err)
	}
	if got := cfg.Contexts["local"].URL; got != "http://127.0.0.1:4123" {
		t.Errorf("the local context is %s, want the home's loopback port", got)
	}
	if !strings.Contains(out.String(), "CYFR is set up in this directory, reached from this computer at http://localhost:4123.\n") || !strings.Contains(out.String(), setupLinkLine(t, "http://localhost:4123")) {
		t.Errorf("init does not print the home's address and setup link at its port:\n%s", out.String())
	}
	if strings.Contains(out.String(), "CYFR is reached as:") {
		t.Errorf("init describes how CYFR is reached before its ending, which says it:\n%s", out.String())
	}
}

// Run again on a .env that does not say how its home is reached, init
// refuses with access_missing's sentence and writes nothing.
func TestInitRefusesAnExistingEnvWithoutAccessAndWritesNothing(t *testing.T) {
	for _, c := range []struct {
		name, env string
		want      string
	}{
		{"no CYFR_ACCESS", "CYFR_SECRET_KEY_BASE=kept\nCYFR_HOST=localhost\n", access.Refuse("access_missing", nil).Message()},
		{"CYFR_ACCESS blank", "CYFR_ACCESS=\nCYFR_LOCUS_RUNTIME_ROOT=\n", access.Refuse("access_missing", nil).Message()},
		// The last assignment is the one compose reads.
		{"CYFR_ACCESS blanked by a later line", "CYFR_ACCESS=local\nCYFR_ACCESS=\n", access.Refuse("access_missing", nil).Message()},
	} {
		t.Run(c.name, func(t *testing.T) {
			newInitProject(t)
			s := useFakeEngine(t)
			if err := os.WriteFile(".env", []byte(c.env), 0600); err != nil {
				t.Fatal(err)
			}
			var out bytes.Buffer
			err := runInit(context.Background(), initOptions{noPull: true}, &out, &out)
			if err == nil || !strings.Contains(err.Error(), c.want) {
				t.Fatalf("init answered %v, want %q", err, c.want)
			}
			if got := read(t, ".env"); got != c.env {
				t.Errorf(".env holds %q, want it as it was", got)
			}
			nothingWritten(t, ".env", ".env.example")
			if s.locks != 0 {
				t.Errorf("the refused init took the lock")
			}
		})
	}
}

// A dev build fetches no scaffold, and says where its files come from: a
// repo checkout, or the checkout's own source development stack, never a
// bare `mix phx.server`, which runs no component.
func TestInitOnADevBuildSaysWhereTheScaffoldComesFrom(t *testing.T) {
	const notice = "⚠  dev build — docker-compose.yml, Caddyfile, .env.example and the bundled\n" +
		"   scaffold (guides, wit/, aqua/) are only fetched for released\n" +
		"   versions. Copy those files from a repo checkout, or run the server from\n" +
		"   the checkout itself as CONTRIBUTING.md's \"Running from source\" says.\n"
	newInitProject(t)
	useFakeEngine(t)
	var out bytes.Buffer
	if err := runInit(context.Background(), initOptions{noPull: true}, &out, &out); err != nil {
		t.Fatalf("init: %v\n%s", err, out.String())
	}
	if !strings.Contains(out.String(), "\n"+notice) {
		t.Errorf("a dev build's init does not say where its scaffold comes from:\n%s", out.String())
	}
}

// A new CYFR made public through the access engine itself and this host's
// Docker: the engine's docker calls run through its watchdog re-exec,
// `cyfr internal docker-run`, which here is this test binary (TestMain),
// and the switch of the stopped stack writes the public head into .env.
func TestANewCYFRSwitchesThroughTheRealEngineAndHostDocker(t *testing.T) {
	requireCompose(t)
	newInitProject(t)
	useRealEngine(t, nil)
	var out bytes.Buffer
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	if err := initThenPublic(ctx, "ops@example.com", &out); err != nil {
		t.Fatalf("init, then access public: %v\n%s", err, out.String())
	}
	f := projectEnv(t)
	for k, want := range map[string]string{"CYFR_ACCESS": "public", "CYFR_HOST": "cyfr.example.com", "CYFR_PUBLIC_URL": "https://cyfr.example.com", "CADDY_ACME_EMAIL": "ops@example.com"} {
		if got, _ := f.value(k); got != want {
			t.Errorf(".env's %s is %q, want %q", k, got, want)
		}
	}
	if _, err := os.Stat(".cyfr"); err != nil {
		t.Errorf("the engine kept no state under .cyfr/: %v", err)
	}
	if leftovers, _ := filepath.Glob(filepath.Join(".cyfr", "compose.resolved.*")); len(leftovers) != 0 {
		t.Errorf("the switch left %v", leftovers)
	}
	if _, err := os.Stat(filepath.Join(".cyfr", "journal.json")); !errors.Is(err, fs.ErrNotExist) {
		t.Errorf("the switch left its journal (%v)", err)
	}
}

// A new .env gets a setup token of 32 random bytes in 64 lowercase
// hexadecimal characters, on one line, and init ends on the setup link at
// the new CYFR's address; init run again keeps the token as it is, and
// ends on the next step alone.
func TestInitWritesTheSetupTokenAndPrintsTheSetupLink(t *testing.T) {
	newInitProject(t)
	useFakeEngine(t)
	stubLauncher(t, true, nil)
	var out bytes.Buffer
	if err := runInit(context.Background(), initOptions{noPull: true}, &out, &out); err != nil {
		t.Fatalf("init: %v\n%s", err, out.String())
	}
	line := setupLinkLine(t, "http://localhost:4000")
	token := setupTokenOf(t)
	if n := len(projectEnv(t).assignments(setupTokenVar)); n != 1 {
		t.Errorf(".env assigns %s on %d lines, want one", setupTokenVar, n)
	}
	text := out.String()
	if !strings.HasSuffix(text, "\n\n"+localEnding("http://localhost:4000")+line) || strings.Contains(text, "Prism:") {
		t.Errorf("init printed:\n%s\nwant it to end on the setup link %q", text, line)
	}

	out.Reset()
	if err := runInit(context.Background(), initOptions{noPull: true}, &out, &out); err != nil {
		t.Fatalf("init again: %v\n%s", err, out.String())
	}
	if again, _ := projectEnv(t).value(setupTokenVar); again != token {
		t.Errorf("init run again changed the setup token from %q to %q", token, again)
	}
	again := out.String()
	if !strings.HasSuffix(again, "says.\nNext: get docker-compose.yml + Caddyfile (a released CLI or a repo checkout), then 'cyfr up'.\n") || strings.Contains(again, "/setup#") {
		t.Errorf("init run again printed:\n%s", again)
	}
}

// localEnding is the head of init's ending for a CYFR reached from this
// machine at address, up to its next step.
func localEnding(address string) string {
	return "CYFR is set up in this directory, reached from this computer at " + address + ".\n" +
		"Want it on your phone and laptop too? Run cyfr access tailnet first.\n"
}

// Without the screen, init's last line on a machine with no display is
// the ssh command that brings the address to another computer, with this
// account and this machine's name; with a display there is none.
func TestInitEndsWithTheSSHLineOnAMachineWithNoDisplay(t *testing.T) {
	account, err := user.Current()
	if err != nil {
		t.Fatal(err)
	}
	host, err := os.Hostname()
	if err != nil {
		t.Fatal(err)
	}
	for _, display := range []bool{false, true} {
		newInitProject(t)
		useFakeEngine(t)
		stubLauncher(t, display, nil)
		var out bytes.Buffer
		if err := runInit(context.Background(), initOptions{noPull: true}, &out, &out); err != nil {
			t.Fatalf("init: %v\n%s", err, out.String())
		}
		want := "\n\n" + localEnding("http://localhost:4000") + setupLinkLine(t, "http://localhost:4000")
		if !display {
			want += "From another computer: ssh -L 4000:127.0.0.1:4000 " + account.Username + "@" + host + ", then open the link there.\n"
		}
		if !strings.HasSuffix(out.String(), want) {
			t.Errorf("with a display %v init printed:\n%s\nwant it to end on:\n%s", display, out.String(), want)
		}
	}
}

// A new .env that makes CYFR headless, CYFR_HEADLESS read as the server
// reads it, prints that the first person runs cyfr login --setup after
// cyfr up, and no setup link, since a headless CYFR serves no page.
func TestInitPrintsLoginSetupForAHeadlessCYFR(t *testing.T) {
	const notice = "\nCYFR is set up in this directory, reached from this computer at http://localhost:4000.\n" +
		"Want it on your phone and laptop too? Run cyfr access tailnet first.\n" +
		"CYFR is headless: after 'cyfr up', its first person runs 'cyfr login --setup' in this directory.\n"
	for _, c := range []struct {
		assignment string
		headless   bool
	}{
		{"CYFR_HEADLESS=on", true},
		{`CYFR_HEADLESS=" on "`, true},
		{"CYFR_HEADLESS=off", false},
		{"CYFR_HEADLESS=", false},
	} {
		t.Run(c.assignment, func(t *testing.T) {
			newInitProject(t)
			useFakeEngine(t)
			if err := os.WriteFile(".env.example", []byte(read(t, ".env.example")+c.assignment+"\n"), 0644); err != nil {
				t.Fatal(err)
			}
			var out bytes.Buffer
			if err := runInit(context.Background(), initOptions{noPull: true}, &out, &out); err != nil {
				t.Fatalf("init: %v\n%s", err, out.String())
			}
			text := out.String()
			printsNotice, printsLink := strings.HasSuffix(text, notice), strings.Contains(text, "/setup#")
			if printsNotice != c.headless || printsLink == c.headless {
				t.Errorf("init printed the headless notice %v and the setup link %v, want the notice %v:\n%s", printsNotice, printsLink, c.headless, text)
			}
		})
	}
}
