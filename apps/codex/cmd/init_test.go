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
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/cyfr/codex/internal/config"
	"github.com/cyfr/codex/internal/reach"
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

// reachOf is the mode the working directory's .env holds.
func reachOf(t *testing.T) string {
	t.Helper()
	mode, _ := projectEnv(t).value("CYFR_REACH")
	return mode
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

// --no-interactive makes a local home unless --reach tailnet comes with
// --tailscale-auth-key-file or --reach public with --domain; each other
// combination of the reach flags says why it is local, or refuses before
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
		{name: "no flags", o: initOptions{}, mode: reach.ModeLocal},
		{name: "--reach local", o: initOptions{mode: reach.ModeLocal}, mode: reach.ModeLocal},
		{name: "--reach tailnet alone", o: initOptions{mode: reach.ModeTailnet}, mode: reach.ModeLocal, notice: "--reach tailnet joins a tailnet with no one to approve the machine only with --tailscale-auth-key-file"},
		{name: "--reach tailnet with a key file", o: initOptions{mode: reach.ModeTailnet, reachOptions: reachOptions{keyFile: keyFile, hostname: "home"}}, mode: reach.ModeTailnet},
		{name: "--reach public alone", o: initOptions{mode: reach.ModePublic}, mode: reach.ModeLocal, notice: "--reach public needs --domain"},
		{name: "--reach public with a domain", o: initOptions{mode: reach.ModePublic, reachOptions: reachOptions{domain: "cyfr.example.com", acmeEmail: "ops@example.com"}}, mode: reach.ModePublic},
		{name: "a domain without --reach", o: initOptions{reachOptions: reachOptions{domain: "cyfr.example.com"}}, refusal: "only beside --reach"},
		{name: "a domain for a local home", o: initOptions{mode: reach.ModeLocal, reachOptions: reachOptions{domain: "cyfr.example.com"}}, refusal: "`--domain` is for a public home, and this command chooses `local`"},
		{name: "an email for a tailnet home", o: initOptions{mode: reach.ModeTailnet, reachOptions: reachOptions{acmeEmail: "ops@example.com", keyFile: keyFile}}, refusal: "`--acme-email` is for a public home, and this command chooses `tailnet`"},
		{name: "a machine name for a public home", o: initOptions{mode: reach.ModePublic, reachOptions: reachOptions{domain: "cyfr.example.com", hostname: "home"}}, refusal: "`--hostname` is for joining a tailnet, and this command chooses `public`"},
		{name: "a domain that is not one", o: initOptions{mode: reach.ModePublic, reachOptions: reachOptions{domain: "localhost"}}, refusal: "`localhost` is not a valid domain"},
		{name: "a mode that is none", o: initOptions{mode: "tls"}, refusal: `--reach takes local, tailnet or public; "tls" is none of them`},
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
			if got := reachOf(t); got != c.mode {
				t.Errorf("the home is %s, want %s", got, c.mode)
			}
			if c.notice != "" && !strings.Contains(out.String(), c.notice) {
				t.Errorf("init does not say why the home is local:\n%s", out.String())
			}
			// A local home is .env as init writes it: no engine, no lock.
			if wantSwitch := c.mode != reach.ModeLocal; (len(s.switches) == 1) != wantSwitch || (s.locks == 1) != wantSwitch {
				t.Errorf("%d switches under %d locks, want a switch: %v", len(s.switches), s.locks, wantSwitch)
			}
		})
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
	if !strings.Contains(out.String(), "Prism:           http://localhost:4123/") {
		t.Errorf("init does not print the home's address:\n%s", out.String())
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
	err := runInit(context.Background(), initOptions{mode: reach.ModeTailnet, reachOptions: reachOptions{keyFile: keyFile}, noPull: true}, &out, &out)
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
	for k, want := range map[string]string{"CYFR_REACH": "tailnet", "CYFR_HOST": "cyfr.tail1234.ts.net", "CYFR_TAILNET_NODE_ID": "nTESTNODE1CNTRL", "CYFR_PUBLIC_URL": "https://cyfr.tail1234.ts.net"} {
		if got, _ := f.value(k); got != want {
			t.Errorf(".env's %s is %q, want %q", k, got, want)
		}
	}
	env, _ := os.ReadFile(".env")
	if strings.Contains(string(env)+out.String(), key) {
		t.Errorf("the auth key reached .env or the output")
	}
	if !strings.Contains(out.String(), "Prism:           https://cyfr.tail1234.ts.net/") {
		t.Errorf("init does not print the home's address from its head:\n%s", out.String())
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
		s.join = func(ctx context.Context, r reach.JoinRequest) (reach.Receipt, error) {
			r.OnAuthURL("https://login.tailscale.com/a/approve-test")
			return reach.Receipt{RequestID: r.ID, Op: "join", State: "completed", Outcome: "failed", Code: "tailnet_join_expired"}, nil
		}
		askTerminal = func() bool { return true }
		askInput = strings.NewReader("1\n\n\n")
		var out bytes.Buffer
		err := runInit(context.Background(), initOptions{noPull: true}, &out, &out)
		expired := reach.Refuse("tailnet_join_expired", nil).Message()
		if err == nil || !strings.Contains(err.Error(), expired) || !strings.Contains(err.Error(), "reached from this computer only; `cyfr reach tailnet` changes that") {
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
		s.join = func(jctx context.Context, r reach.JoinRequest) (reach.Receipt, error) {
			r.OnAuthURL("https://login.tailscale.com/a/approve-test")
			cancel()
			<-jctx.Done()
			return reach.Receipt{}, jctx.Err()
		}
		askTerminal = func() bool { return true }
		askInput = strings.NewReader("1\nhome\n\n")
		var out bytes.Buffer
		err := runInit(ctx, initOptions{noPull: true}, &out, &out)
		cancelled := reach.Refuse("tailnet_join_cancelled", nil).Message()
		var refusal *reach.Refusal
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
	err := runInit(context.Background(), initOptions{mode: reach.ModePublic, reachOptions: reachOptions{domain: "cyfr.example.com"}, noPull: true}, &out, &out)
	if want := reach.Refuse("tailnet_node_mismatch", mismatch()).Message(); err == nil || err.Error() != want || ExitStatus(err) != exitStartedLocally {
		t.Fatalf("init answered %v (exit %d), want %q and exit 3", err, ExitStatus(err), want)
	}
}

// localAndMade fails unless init left a local home with the project made
// around it and nothing switched.
func localAndMade(t *testing.T, s *fakeStack) {
	t.Helper()
	if got := reachOf(t); got != reach.ModeLocal {
		t.Errorf("the home is %s, want local", got)
	}
	if len(s.switches) != 0 {
		t.Errorf("init switched after the join ended without a machine: %+v", s.switches)
	}
	for _, name := range []string{".gitignore", "cyfr.yaml", "data", "aqua"} {
		if _, err := os.Stat(name); err != nil {
			t.Errorf("init did not make %s: %v", name, err)
		}
	}
	if holder := s.held(); holder != "" {
		t.Errorf("init left the lock held, by %s", holder)
	}
}

// Run again on a .env that does not say how its home is reached, init
// refuses with reach_missing's sentence and writes nothing; a --reach that
// contradicts the mode an existing .env holds is refused the same way,
// since `cyfr reach` changes an existing home's.
func TestInitRefusesAnExistingEnvWithoutReachAndWritesNothing(t *testing.T) {
	for _, c := range []struct {
		name, env string
		o         initOptions
		want      string
	}{
		{"no CYFR_REACH", "CYFR_SECRET_KEY_BASE=kept\nCYFR_HOST=localhost\n", initOptions{}, reach.Refuse("reach_missing", nil).Message()},
		{"CYFR_REACH blank", "CYFR_REACH=\nCYFR_LOCUS_RUNTIME_ROOT=\n", initOptions{mode: reach.ModeLocal}, reach.Refuse("reach_missing", nil).Message()},
		{"another mode", "CYFR_REACH=local\n", initOptions{mode: reach.ModePublic, reachOptions: reachOptions{domain: "cyfr.example.com"}}, ".env says this home is reached as local"},
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

// Given no operator email, init mints the setup token into .env and says
// how the link is had, and `cyfr setup link` prints it at the home's
// loopback port; given one, the operators' line holds it and there is no
// token and no link.
func TestInitMintsTheSetupTokenWithoutAnEmail(t *testing.T) {
	newInitProject(t)
	useFakeEngine(t)
	var out bytes.Buffer
	if err := runInit(context.Background(), initOptions{noPull: true}, &out, &out); err != nil {
		t.Fatalf("init: %v\n%s", err, out.String())
	}
	token, _ := projectEnv(t).value(setupTokenVar)
	if !setupTokenPattern.MatchString(token) {
		t.Fatalf("CYFR_SETUP_TOKEN is %q, want 64 lowercase hexadecimal characters", token)
	}
	if admins, assigned := projectEnv(t).value(adminEmailVar); assigned {
		t.Errorf("a home given no email names the administrators %q", admins)
	}
	if !strings.Contains(out.String(), "run `cyfr setup link`") || strings.Contains(out.String(), token) {
		t.Errorf("init does not say how the setup link is had, or prints the token:\n%s", out.String())
	}
	link, err := setupLink(".env")
	if err != nil || link != "http://localhost:4000/setup#t="+token {
		t.Errorf("cyfr setup link answered %q, %v", link, err)
	}

	newInitProject(t)
	useFakeEngine(t)
	askTerminal = func() bool { return true }
	askInput = strings.NewReader("3\nme@example.com\n")
	out.Reset()
	if err := runInit(context.Background(), initOptions{noPull: true}, &out, &out); err != nil {
		t.Fatalf("init: %v\n%s", err, out.String())
	}
	if admins, _ := projectEnv(t).value(adminEmailVar); admins != "me@example.com" {
		t.Errorf("the administrators are %q, want the email answered", admins)
	}
	if token, assigned := projectEnv(t).value(setupTokenVar); assigned {
		t.Errorf("a home given its operator's email holds the setup token %q", token)
	}
	if _, err := setupLink(".env"); err == nil || !strings.Contains(err.Error(), "names its administrators") {
		t.Errorf("cyfr setup link on a home with administrators answered %v", err)
	}
}

// On a terminal the reach question comes first, before the email; an
// answer that is none of the three is asked again, and a public home's
// domain is asked, an invalid one with the rule it breaks.
func TestInitAsksTheReachQuestionFirst(t *testing.T) {
	newInitProject(t)
	s := useFakeEngine(t)
	askTerminal = func() bool { return true }
	askInput = strings.NewReader("9\n2\nlocalhost\ncyfr.example.com\nnot-an-email\nops@example.com\n\n")
	var out bytes.Buffer
	if err := runInit(context.Background(), initOptions{noPull: true}, &out, &out); err != nil {
		t.Fatalf("init: %v\n%s", err, out.String())
	}
	text := out.String()
	question, again, email := strings.Index(text, "How will you reach this home?"), strings.Index(text, "Answer 1, 2 or 3."), strings.Index(text, "Your email")
	if question < 0 || again < question || email < again {
		t.Errorf("the reach question does not come first, asked again on a wrong answer, before the email:\n%s", text)
	}
	for _, want := range []string{"`localhost` is not a valid domain", "`not-an-email` is not a valid email address"} {
		if !strings.Contains(text, want) {
			t.Errorf("init does not say %q:\n%s", want, text)
		}
	}
	if len(s.switches) != 1 || s.switches[0].Target != (reach.Target{Mode: reach.ModePublic, Domain: "cyfr.example.com", ACMEEmail: "ops@example.com"}) {
		t.Errorf("the switch was %+v", s.switches)
	}
	f := projectEnv(t)
	for k, want := range map[string]string{"CYFR_REACH": "public", "CYFR_HOST": "cyfr.example.com", "CYFR_PUBLIC_URL": "https://cyfr.example.com", "CADDY_ACME_EMAIL": "ops@example.com"} {
		if got, _ := f.value(k); got != want {
			t.Errorf(".env's %s is %q, want %q", k, got, want)
		}
	}
	if !strings.Contains(text, "Prism:           https://cyfr.example.com/") || strings.Contains(text, "<your CYFR_HOST>") {
		t.Errorf("init does not print the home's address from its head:\n%s", text)
	}
}

// init through the reach engine itself and this host's Docker: the
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
	err := runInit(ctx, initOptions{mode: reach.ModePublic, reachOptions: reachOptions{domain: "cyfr.example.com", acmeEmail: "ops@example.com"}, noPull: true}, &out, &out)
	if err != nil {
		t.Fatalf("init: %v\n%s", err, out.String())
	}
	f := projectEnv(t)
	for k, want := range map[string]string{"CYFR_REACH": "public", "CYFR_HOST": "cyfr.example.com", "CYFR_PUBLIC_URL": "https://cyfr.example.com", "CADDY_ACME_EMAIL": "ops@example.com"} {
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
