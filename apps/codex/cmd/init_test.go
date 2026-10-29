// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"bytes"
	"context"
	"errors"
	"io/fs"
	"os"
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

// setupLinkLine is the line init prints the setup link of the CYFR at
// address on, with the setup token the working directory's .env holds.
func setupLinkLine(t *testing.T, address string) string {
	t.Helper()
	return "  Setup link:      " + address + "/setup#" + setupTokenOf(t) + "\n"
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

// --no-interactive makes a local home unless --access tailnet comes with
// --tailscale-auth-key-file or --access public with --domain; each other
// combination of the access flags says why it is local, or refuses before
// anything is written.
func TestInitNoInteractiveRules(t *testing.T) {
	keyFile := filepath.Join(t.TempDir(), "authkey")
	if err := os.WriteFile(keyFile, []byte("tskey-auth-kTEST-SECRET\n"), 0600); err != nil {
		t.Fatal(err)
	}
	cases := []struct {
		name    string
		o       initOptions
		mode    string
		notice  string
		refusal string
	}{
		{name: "no flags", o: initOptions{}, mode: access.ModeLocal},
		{name: "--access local", o: initOptions{mode: access.ModeLocal}, mode: access.ModeLocal},
		{name: "--access tailnet alone", o: initOptions{mode: access.ModeTailnet}, mode: access.ModeLocal, notice: "--access tailnet joins a tailnet with no one to approve the machine only with --tailscale-auth-key-file"},
		{name: "--access tailnet with a key file", o: initOptions{mode: access.ModeTailnet, accessOptions: accessOptions{keyFile: keyFile, hostname: "home"}}, mode: access.ModeTailnet},
		{name: "--access public alone", o: initOptions{mode: access.ModePublic}, mode: access.ModeLocal, notice: "--access public needs --domain"},
		{name: "--access public with a domain", o: initOptions{mode: access.ModePublic, accessOptions: accessOptions{domain: "cyfr.example.com", acmeEmail: "ops@example.com"}}, mode: access.ModePublic},
		{name: "a domain without --access", o: initOptions{accessOptions: accessOptions{domain: "cyfr.example.com"}}, refusal: "only beside --access"},
		{name: "a domain for a local home", o: initOptions{mode: access.ModeLocal, accessOptions: accessOptions{domain: "cyfr.example.com"}}, refusal: "`--domain` is for public access, and this command chooses `local`"},
		{name: "an email for a tailnet home", o: initOptions{mode: access.ModeTailnet, accessOptions: accessOptions{acmeEmail: "ops@example.com", keyFile: keyFile}}, refusal: "`--acme-email` is for public access, and this command chooses `tailnet`"},
		{name: "a machine name for a public home", o: initOptions{mode: access.ModePublic, accessOptions: accessOptions{domain: "cyfr.example.com", hostname: "home"}}, refusal: "`--hostname` is for joining a tailnet, and this command chooses `public`"},
		{name: "a domain that is not one", o: initOptions{mode: access.ModePublic, accessOptions: accessOptions{domain: "localhost"}}, refusal: "`localhost` is not a valid domain"},
		{name: "a mode that is none", o: initOptions{mode: "tls"}, refusal: `--access takes local, tailnet or public; "tls" is none of them`},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			newInitProject(t)
			s := useFakeEngine(t)
			c.o.noPull = true
			var out bytes.Buffer
			err := runInit(context.Background(), c.o, &out, &out)
			if c.refusal != "" {
				if err == nil || !strings.Contains(err.Error(), c.refusal) || !strings.Contains(err.Error(), "Nothing was changed") {
					t.Fatalf("init answered %v, want the refusal %q", err, c.refusal)
				}
				nothingWritten(t, ".env.example")
				if s.locks != 0 {
					t.Errorf("a refused init took the lock")
				}
				return
			}
			if err != nil {
				t.Fatalf("init: %v\n%s", err, out.String())
			}
			if got := accessOf(t); got != c.mode {
				t.Errorf("the home is %s, want %s", got, c.mode)
			}
			if c.notice != "" && !strings.Contains(out.String(), c.notice) {
				t.Errorf("init does not say why the home is local:\n%s", out.String())
			}
			// A local home is .env as init writes it: no engine, no lock.
			if wantSwitch := c.mode != access.ModeLocal; (len(s.switches) == 1) != wantSwitch || (s.locks == 1) != wantSwitch {
				t.Errorf("%d switches under %d locks, want a switch: %v", len(s.switches), s.locks, wantSwitch)
			}
		})
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
	if !strings.Contains(out.String(), setupLinkLine(t, "http://localhost:4123")) {
		t.Errorf("init does not print the setup link at the home's address:\n%s", out.String())
	}
}

// A tailnet home init joins first, with the auth key the file holds, which
// reaches the engine's join alone: never .env, the output or a request.
// The switch then takes the joined machine's name and id.
func TestInitJoinsATailnetHomeWithTheKeyFile(t *testing.T) {
	newInitProject(t)
	s := useFakeEngine(t)
	keyFile := filepath.Join(t.TempDir(), "authkey")
	const key = "tskey-auth-kTEST-SECRET"
	if err := os.WriteFile(keyFile, []byte(key+"\n"), 0600); err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	err := runInit(context.Background(), initOptions{mode: access.ModeTailnet, accessOptions: accessOptions{keyFile: keyFile}, noPull: true}, &out, &out)
	if err != nil {
		t.Fatalf("init: %v\n%s", err, out.String())
	}
	if len(s.joins) != 1 || string(s.joinKeys[0]) != key || s.joins[0].Hostname != "" || s.joins[0].NewNode {
		t.Fatalf("the join was %+v with key %q, want one join with the file's key", s.joins, s.joinKeys)
	}
	if len(s.switches) != 1 || s.switches[0].JoinID != "join-"+s.joins[0].ID || s.switches[0].ID == s.joins[0].ID {
		t.Fatalf("the switch %+v does not take the join's machine under a request id of its own", s.switches)
	}
	f := projectEnv(t)
	for k, want := range map[string]string{"CYFR_ACCESS": "tailnet", "CYFR_HOST": "cyfr.tail1234.ts.net", "CYFR_TAILNET_NODE_ID": "nTESTNODE1CNTRL", "CYFR_PUBLIC_URL": "https://cyfr.tail1234.ts.net"} {
		if got, _ := f.value(k); got != want {
			t.Errorf(".env's %s is %q, want %q", k, got, want)
		}
	}
	env, _ := os.ReadFile(".env")
	if strings.Contains(string(env)+out.String(), key) {
		t.Errorf("the auth key reached .env or the output")
	}
	if !strings.Contains(out.String(), setupLinkLine(t, "https://cyfr.tail1234.ts.net")) {
		t.Errorf("init does not print the setup link at the home's address from its head:\n%s", out.String())
	}
}

// A join that fails, or one an interrupt cancels while it waits for the
// approval, leaves the home reached from this computer only: .env local,
// no switch, the rest of the project made, and init says so and exits
// non-zero. The cancelled join is cancelled in the engine, whose container
// would outlive init otherwise.
func TestInitLeavesTheHomeLocalWhenTheJoinFailsOrIsCancelled(t *testing.T) {
	t.Run("the approval link expires", func(t *testing.T) {
		newInitProject(t)
		s := useFakeEngine(t)
		s.join = func(ctx context.Context, r access.JoinRequest) (access.Receipt, error) {
			r.OnAuthURL("https://login.tailscale.com/a/approve-test")
			return access.Receipt{RequestID: r.ID, Op: "join", State: "completed", Outcome: "failed", Code: "tailnet_join_expired"}, nil
		}
		askTerminal = func() bool { return true }
		askInput = strings.NewReader("1\n\n")
		var out bytes.Buffer
		err := runInit(context.Background(), initOptions{noPull: true}, &out, &out)
		expired := access.Refuse("tailnet_join_expired", nil).Message()
		if err == nil || !strings.Contains(err.Error(), expired) || !strings.Contains(err.Error(), "reached from this computer only; `cyfr access tailnet` changes that") {
			t.Fatalf("init answered %v\n%s", err, out.String())
		}
		if !strings.Contains(out.String(), "https://login.tailscale.com/a/approve-test") {
			t.Errorf("init does not print the approval link:\n%s", out.String())
		}
		localAndMade(t, s)
	})
	t.Run("an interrupt cancels the waiting join", func(t *testing.T) {
		newInitProject(t)
		s := useFakeEngine(t)
		ctx, cancel := context.WithCancel(context.Background())
		defer cancel()
		s.join = func(jctx context.Context, r access.JoinRequest) (access.Receipt, error) {
			r.OnAuthURL("https://login.tailscale.com/a/approve-test")
			cancel()
			<-jctx.Done()
			return access.Receipt{}, jctx.Err()
		}
		askTerminal = func() bool { return true }
		askInput = strings.NewReader("1\nhome\n")
		var out bytes.Buffer
		err := runInit(ctx, initOptions{noPull: true}, &out, &out)
		cancelled := access.Refuse("tailnet_join_cancelled", nil).Message()
		var refusal *access.Refusal
		if err == nil || !errors.As(err, &refusal) || refusal.Code != "tailnet_join_cancelled" || !strings.HasPrefix(err.Error(), cancelled+"\n") {
			t.Fatalf("init answered %v\n%s", err, out.String())
		}
		if s.cancels != 1 {
			t.Errorf("the waiting join was cancelled %d times, want once", s.cancels)
		}
		if s.joins[0].Hostname != "home" {
			t.Errorf("the join asked for %q, want the machine name answered", s.joins[0].Hostname)
		}
		localAndMade(t, s)
	})
}

// A switch whose start left the home on this machine only is no success:
// init answers tailnet_node_mismatch's sentence alone, which exits 3, and
// never says the home stayed local, since the switch was made.
func TestInitReportsAStartOnThisMachineOnly(t *testing.T) {
	newInitProject(t)
	s := useFakeEngine(t)
	local := startedLocalReceipt("switch")
	s.switchReceipt = &local
	var out bytes.Buffer
	err := runInit(context.Background(), initOptions{mode: access.ModePublic, accessOptions: accessOptions{domain: "cyfr.example.com"}, noPull: true}, &out, &out)
	if want := access.Refuse("tailnet_node_mismatch", mismatch()).Message(); err == nil || err.Error() != want || ExitStatus(err) != exitStartedLocally {
		t.Fatalf("init answered %v (exit %d), want %q and exit 3", err, ExitStatus(err), want)
	}
}

// localAndMade fails unless init left a local home with the project made
// around it and nothing switched.
func localAndMade(t *testing.T, s *fakeStack) {
	t.Helper()
	if got := accessOf(t); got != access.ModeLocal {
		t.Errorf("the home is %s, want local", got)
	}
	if len(s.switches) != 0 {
		t.Errorf("init switched after the join ended without a machine: %+v", s.switches)
	}
	for _, name := range []string{".gitignore", "data", "aqua"} {
		if _, err := os.Stat(name); err != nil {
			t.Errorf("init did not make %s: %v", name, err)
		}
	}
	if _, err := os.Stat("cyfr.yaml"); err == nil {
		t.Error("init wrote cyfr.yaml, which no command reads")
	}
	if holder := s.held(); holder != "" {
		t.Errorf("init left the lock held, by %s", holder)
	}
}

// Run again on a .env that does not say how its home is reached, init
// refuses with access_missing's sentence and writes nothing; a --access that
// contradicts the mode an existing .env holds is refused the same way,
// since `cyfr access` changes an existing home's.
func TestInitRefusesAnExistingEnvWithoutAccessAndWritesNothing(t *testing.T) {
	for _, c := range []struct {
		name, env string
		o         initOptions
		want      string
	}{
		{"no CYFR_ACCESS", "CYFR_SECRET_KEY_BASE=kept\nCYFR_HOST=localhost\n", initOptions{}, access.Refuse("access_missing", nil).Message()},
		{"CYFR_ACCESS blank", "CYFR_ACCESS=\nCYFR_LOCUS_RUNTIME_ROOT=\n", initOptions{mode: access.ModeLocal}, access.Refuse("access_missing", nil).Message()},
		{"another mode", "CYFR_ACCESS=local\n", initOptions{mode: access.ModePublic, accessOptions: accessOptions{domain: "cyfr.example.com"}}, ".env says CYFR is reached as local"},
		// The last assignment is the one compose reads.
		{"CYFR_ACCESS blanked by a later line", "CYFR_ACCESS=local\nCYFR_ACCESS=\n", initOptions{}, access.Refuse("access_missing", nil).Message()},
	} {
		t.Run(c.name, func(t *testing.T) {
			newInitProject(t)
			s := useFakeEngine(t)
			if err := os.WriteFile(".env", []byte(c.env), 0600); err != nil {
				t.Fatal(err)
			}
			var out bytes.Buffer
			err := runInit(context.Background(), c.o, &out, &out)
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

// The end of the input is no answer: init's access question read at it
// makes the home local, as --no-interactive would, saying so, and never
// joins a tailnet; an empty line takes the recommended answer.
func TestInitTakesTheEndOfInputAsNoAnswer(t *testing.T) {
	newInitProject(t)
	s := useFakeEngine(t)
	askTerminal = func() bool { return true }
	askInput = strings.NewReader("")
	var out bytes.Buffer
	if err := runInit(context.Background(), initOptions{noPull: true}, &out, &out); err != nil {
		t.Fatalf("init: %v\n%s", err, out.String())
	}
	if len(s.joins) != 0 || len(s.switches) != 0 || accessOf(t) != access.ModeLocal {
		t.Fatalf("the end of the input joined %d times, switched %d times and left the home %s, want local and nothing joined\n%s", len(s.joins), len(s.switches), accessOf(t), out.String())
	}
	if want := "No answer was read, so CYFR is reached from this computer only; `cyfr access tailnet` or `cyfr access public --domain <your domain>` changes that."; !strings.Contains(out.String(), want) {
		t.Errorf("init does not say why the home is local:\n%s", out.String())
	}

	newInitProject(t)
	s = useFakeEngine(t)
	askTerminal = func() bool { return true }
	askInput = strings.NewReader("\n")
	out.Reset()
	if err := runInit(context.Background(), initOptions{noPull: true}, &out, &out); err != nil {
		t.Fatalf("init: %v\n%s", err, out.String())
	}
	if len(s.joins) != 1 || accessOf(t) != access.ModeTailnet {
		t.Errorf("an empty line joined %d times and left the home %s, want the recommended tailnet\n%s", len(s.joins), accessOf(t), out.String())
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

// On a terminal the access question comes first; an answer that is none
// of the three is asked again, and a public home's domain is asked, an
// invalid one with the rule it breaks.
func TestInitAsksTheAccessQuestionFirst(t *testing.T) {
	newInitProject(t)
	s := useFakeEngine(t)
	askTerminal = func() bool { return true }
	askInput = strings.NewReader("9\n2\nlocalhost\ncyfr.example.com\nnot-an-email\nops@example.com\n")
	var out bytes.Buffer
	if err := runInit(context.Background(), initOptions{noPull: true}, &out, &out); err != nil {
		t.Fatalf("init: %v\n%s", err, out.String())
	}
	text := out.String()
	question, again := strings.Index(text, "How will you reach CYFR?"), strings.Index(text, "Answer 1, 2 or 3.")
	if question < 0 || again < question {
		t.Errorf("the access question does not come first, or is not asked again on a wrong answer:\n%s", text)
	}
	for _, want := range []string{"`localhost` is not a valid domain", "`not-an-email` is not a valid email address"} {
		if !strings.Contains(text, want) {
			t.Errorf("init does not say %q:\n%s", want, text)
		}
	}
	if len(s.switches) != 1 || s.switches[0].Target != (access.Target{Mode: access.ModePublic, Domain: "cyfr.example.com", ACMEEmail: "ops@example.com"}) {
		t.Errorf("the switch was %+v", s.switches)
	}
	f := projectEnv(t)
	for k, want := range map[string]string{"CYFR_ACCESS": "public", "CYFR_HOST": "cyfr.example.com", "CYFR_PUBLIC_URL": "https://cyfr.example.com", "CADDY_ACME_EMAIL": "ops@example.com"} {
		if got, _ := f.value(k); got != want {
			t.Errorf(".env's %s is %q, want %q", k, got, want)
		}
	}
	if !strings.Contains(text, setupLinkLine(t, "https://cyfr.example.com")) || strings.Contains(text, "<your CYFR_HOST>") {
		t.Errorf("init does not print the setup link at the home's address from its head:\n%s", text)
	}
}

// init through the access engine itself and this host's Docker: the
// engine's docker calls run through its watchdog re-exec, `cyfr internal
// docker-run`, which here is this test binary (TestMain), and the switch of
// the stopped stack writes the public head into .env.
func TestInitSwitchesThroughTheRealEngineAndHostDocker(t *testing.T) {
	requireCompose(t)
	newInitProject(t)
	useRealEngine(t, nil)
	var out bytes.Buffer
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	err := runInit(ctx, initOptions{mode: access.ModePublic, accessOptions: accessOptions{domain: "cyfr.example.com", acmeEmail: "ops@example.com"}, noPull: true}, &out, &out)
	if err != nil {
		t.Fatalf("init: %v\n%s", err, out.String())
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

// On a machine with a display init opens a tailnet join's approval link in
// the default browser once it has printed it, and still waits for the
// approval; with --no-open, or with no display, it prints the link alone.
// Off a terminal the link and the setup link are plain text.
func TestInitOpensTheJoinLinkOnADisplay(t *testing.T) {
	const link = "https://login.tailscale.com/a/approve-test"
	for _, c := range []struct {
		name            string
		display, noOpen bool
	}{
		{"a display", true, false},
		{"--no-open", true, true},
		{"no display", false, false},
	} {
		t.Run(c.name, func(t *testing.T) {
			newInitProject(t)
			s := useFakeEngine(t)
			l := stubLauncher(t, c.display, nil)
			askTerminal = func() bool { return true }
			askInput = strings.NewReader("1\n\n")
			var out bytes.Buffer
			if err := runInit(context.Background(), initOptions{noPull: true, accessOptions: accessOptions{noOpen: c.noOpen}}, &out, &out); err != nil {
				t.Fatalf("init: %v\n%s", err, out.String())
			}
			opened := c.display && !c.noOpen
			between := ""
			if opened {
				between = "Opened it in your browser.\n"
			}
			want := "To join this machine to your tailnet, open this link and approve the machine:\n  " + link + "\n" + between + "Waiting for the approval (Ctrl-C cancels the join)...\n"
			if !strings.Contains(out.String(), want) || !strings.Contains(out.String(), setupLinkLine(t, "https://cyfr.tail1234.ts.net")) {
				t.Errorf("init printed:\n%s\nwant within it:\n%s", out.String(), want)
			}
			var handed []string
			if opened {
				handed = []string{link}
			}
			if got := l.all(); !slices.Equal(got, handed) {
				t.Errorf("the launcher was handed %v, want %v", got, handed)
			}
			if len(s.switches) != 1 || accessOf(t) != access.ModeTailnet {
				t.Errorf("the join did not go on to the switch: %+v", s.switches)
			}
		})
	}
}

// A new .env gets a setup token of 32 random bytes in 64 lowercase
// hexadecimal characters, on one line, and init prints the setup link at
// the new CYFR's address in place of its bare address; init run again
// keeps the token as it is.
func TestInitWritesTheSetupTokenAndPrintsTheSetupLink(t *testing.T) {
	newInitProject(t)
	useFakeEngine(t)
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
	if !strings.Contains(text, line+"  Once CYFR is up, the setup link sets up its first person, who administers it, with a passkey.\n") || strings.Contains(text, "Prism:") {
		t.Errorf("init printed:\n%s\nwant the setup link %q and no bare address", text, line)
	}

	out.Reset()
	if err := runInit(context.Background(), initOptions{noPull: true}, &out, &out); err != nil {
		t.Fatalf("init again: %v\n%s", err, out.String())
	}
	if again, _ := projectEnv(t).value(setupTokenVar); again != token {
		t.Errorf("init run again changed the setup token from %q to %q", token, again)
	}
}

// A new .env that makes CYFR headless, CYFR_HEADLESS read as the server
// reads it, prints that the first person runs cyfr login --setup after
// cyfr up, and no setup link, since a headless CYFR serves no page.
func TestInitPrintsLoginSetupForAHeadlessCYFR(t *testing.T) {
	const notice = "  CYFR is headless: after 'cyfr up', its first person runs 'cyfr login --setup' in this directory.\n"
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
			printsNotice, printsLink := strings.Contains(text, notice), strings.Contains(text, "Setup link:")
			if printsNotice != c.headless || printsLink == c.headless {
				t.Errorf("init printed the headless notice %v and the setup link %v, want the notice %v:\n%s", printsNotice, printsLink, c.headless, text)
			}
		})
	}
}
