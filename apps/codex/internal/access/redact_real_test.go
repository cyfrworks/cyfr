// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build unix

package access

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io/fs"
	"maps"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"testing"
)

// realProject writes files into a new project directory dir, which may
// hold spaces, and opens its engine on the real docker.
func realProject(t *testing.T, dir string, files map[string]string) *Engine {
	t.Helper()
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	for name, data := range files {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(data), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	e, err := Open(dir, nil)
	if err != nil {
		t.Fatal(err)
	}
	return e
}

// said is every text an error carries: its own, and a refusal's sentence.
func said(err error) string {
	text := err.Error()
	if r, ok := err.(*Refusal); ok {
		text += "\n" + r.Message()
	}
	return text
}

// An env_file a .env value names, holding a line compose cannot read:
// compose names the file, which is the value. CheckStack says only that
// an env file it was not given could not be read.
func TestRealComposeDiagnosticNamesNoFileAnEnvValueNames(t *testing.T) {
	requireCompose(t)
	const secret = "review-secret-as-env-filename"
	e := realProject(t, t.TempDir(), map[string]string{
		".env":        "CYFR_ACCESS=local\nCYFR_HOST=localhost\nCYFR_PORT=4000\nCYFR_SECRET_KEY_BASE=" + secret + "\n",
		"compose.yml": "services:\n  cyfr:\n    image: busybox:latest\n    env_file:\n      - .env\n      - ${CYFR_SECRET_KEY_BASE}\n",
		secret:        "BROKEN! sentinel =value\n",
	})
	err := e.CheckStack(bg)
	if err == nil {
		t.Fatal("invalid env file unexpectedly passed")
	}
	if text := said(err); strings.Contains(text, secret) || !strings.Contains(text, "it could not read an env file") {
		t.Fatalf("diagnostic filename disclosed .env secret: %v", text)
	}
}

// Text inside a quoted value that reads like a diagnostic compose
// writes, in a project whose path holds spaces, is never taken for one:
// a .env line compose cannot read is refused by its number before compose
// is asked, and another env file's is said as an env file that could not
// be read, never by what its line holds.
func TestRealComposeDiagnosticReadsNoTextInsideAQuotedValue(t *testing.T) {
	requireCompose(t)
	const secret = "s3cr3tVal"
	const malformed = "DATABASE_URL=\"postgres://alice:no such service: " + secret + "@db/cyfr\n"
	for name, c := range map[string]struct{ env, extra, says string }{
		".env":        {env: malformed, says: ""},
		"an env file": {extra: malformed, says: "it could not read an env file"},
	} {
		t.Run(name, func(t *testing.T) {
			e := realProject(t, filepath.Join(t.TempDir(), "home with spaces"), map[string]string{
				".env":        "CYFR_ACCESS=local\nCYFR_HOST=localhost\nCYFR_PORT=4000\n" + c.env,
				"compose.yml": "services:\n  cyfr:\n    image: busybox:latest\n    env_file:\n      - .env\n      - extra.env\n",
				"extra.env":   c.extra,
			})
			err := e.CheckStack(bg)
			if err == nil {
				t.Fatal("unterminated database URL unexpectedly passed")
			}
			if text := said(err); strings.Contains(text, secret) || !strings.Contains(text, c.says) {
				t.Fatalf("recognized text inside quoted DATABASE_URL disclosed secret: %v", text)
			}
		})
	}
}

// A secret interpolated into a value compose cannot convert is said by
// the configuration path compose names, never the value.
func TestRealComposeConversionDiagnosticCarriesNoEnvValue(t *testing.T) {
	requireCompose(t)
	const secret = "review-secret-that-must-stay-private"
	e := realProject(t, t.TempDir(), map[string]string{
		".env":        "CYFR_ACCESS=local\nCYFR_HOST=localhost\nCYFR_PORT=4000\nCYFR_SECRET_KEY_BASE=" + secret + "\n",
		"compose.yml": "services:\n  cyfr:\n    image: busybox:latest\n    env_file: .env\n    deploy:\n      resources:\n        limits:\n          cpus: ${CYFR_SECRET_KEY_BASE}\n",
	})
	err := e.CheckStack(bg)
	if err == nil {
		t.Fatal("invalid cpus unexpectedly passed")
	}
	if text := said(err); strings.Contains(text, secret) || !strings.Contains(text, "it refused the value of services[cyfr].deploy.resources.limits.cpus") {
		t.Fatalf("Docker diagnostic disclosed .env secret: %v", text)
	}
}

// leakCheck looks for planted secrets: every text that left the engine
// (out), and every payload value and head field the engine made before
// its last pass (raw), so redaction is not what keeps a value out of
// those.
type leakCheck struct {
	t      *testing.T
	tokens []string
	// boot are the tokens of the boot's own settings that are not head
	// keys (CYFR_BIND_ADDRESS, CYFR_PROXY_*, CYFR_TRUSTED_PROXY_*): an
	// invalid one fills access_setting_invalid's value slot under the
	// cross-language boot-refusal contract (Prima.Refusal, the ResolveBoot
	// vectors of access_modes.json), so raw does not check them; they are
	// redacted at the engine's boundary, which out checks.
	boot []string
}

func (l *leakCheck) out(what string, texts ...string) {
	l.t.Helper()
	for _, text := range texts {
		for _, tok := range append(slices.Clone(l.tokens), l.boot...) {
			if strings.Contains(text, tok) {
				l.t.Errorf("%s: a secret of .env left the engine:\n%s", what, text)
				return
			}
		}
	}
}

func (l *leakCheck) raw(what string, payloads []map[string]string, heads []*Head) {
	l.t.Helper()
	var values []string
	for _, p := range payloads {
		for _, v := range p {
			values = append(values, v)
		}
	}
	for _, h := range heads {
		if h != nil {
			values = append(values, string(h.Canonical()))
		}
	}
	for _, v := range values {
		for _, tok := range l.tokens {
			if strings.Contains(v, tok) {
				l.t.Errorf("%s: a secret of .env became a payload value or a head field before the last pass: %q", what, v)
			}
		}
	}
}

// errTexts are what an error says: its text, a refusal's or the lock's
// sentence and payload.
func errTexts(err error) []string {
	if err == nil {
		return nil
	}
	texts := []string{err.Error()}
	var r *Refusal
	if errors.As(err, &r) {
		texts = append(texts, r.Message(), r.Sentence(), fmt.Sprint(r.Payload))
	}
	var busy *ErrBusy
	if errors.As(err, &busy) {
		texts = append(texts, busy.Refusal().Message())
	}
	return texts
}

func errPayloads(err error) []map[string]string {
	var r *Refusal
	if errors.As(err, &r) {
		return []map[string]string{r.Payload}
	}
	return nil
}

func receiptTexts(rc Receipt) []string {
	texts := []string{fmt.Sprintf("%+v", rc), strings.Join(rc.Observed, " ")}
	if rc.FinalHead != nil {
		texts = append(texts, string(rc.FinalHead.Canonical()))
	}
	if ref := rc.Refusal(); ref != nil {
		texts = append(texts, ref.Message())
	}
	return texts
}

func statusTexts(s Status) []string {
	texts := append([]string{fmt.Sprintf("%+v", s), string(s.Head.Canonical())}, errTexts(s.HeadErr)...)
	for _, rc := range []*Receipt{s.Unfinished, s.Last} {
		if rc != nil {
			texts = append(texts, receiptTexts(*rc)...)
		}
	}
	return append(texts, s.Health...)
}

func statusRaw(s Status) ([]map[string]string, []*Head) {
	payloads := errPayloads(s.HeadErr)
	heads := []*Head{&s.Head}
	for _, rc := range []*Receipt{s.Unfinished, s.Last} {
		if rc != nil {
			payloads = append(payloads, rc.Payload)
			heads = append(heads, rc.FinalHead)
		}
	}
	return payloads, heads
}

// stateTexts are the files the engine wrote under .cyfr/ but the
// materialized configurations, which hold .env's values by design (0600)
// as the configuration compose runs.
func stateTexts(t *testing.T, e *Engine) []string {
	var texts []string
	filepath.WalkDir(e.path(), func(path string, d fs.DirEntry, err error) error {
		if err == nil && !d.IsDir() && !strings.HasPrefix(d.Name(), resolvedFront) {
			data, _ := os.ReadFile(path)
			texts = append(texts, path+"\n"+string(data))
		}
		return nil
	})
	return texts
}

// Every value .env assigns to a name that is not the head's, a distinct
// random secret in each of .env.example's names and in names of the
// person's own (one an env_file names, one an image, one a limit compose
// converts, one quoted with every quote, one across lines, a database
// URL), never leaves the engine, in a project whose path holds spaces,
// whatever docker and compose report: a .env line compose cannot read, an
// env file a value names that compose cannot read, a value compose
// refuses at services[..], a service compose does not have, an image it
// cannot find, a port another process holds, a daemon it cannot reach or
// may not use. Errors, refusals, receipts returned, resent and persisted,
// journals, status and previews are checked as they leave the engine;
// payloads and heads before its last pass too.
func TestRealComposeNoEnvSecretLeavesTheEngine(t *testing.T) {
	requireCompose(t)
	requireDocker(t)
	token := func() string {
		b := make([]byte, 8)
		rand.Read(b)
		return "tok" + hex.EncodeToString(b)
	}
	// Every setting the boot reads is left out of the plants: the head's
	// keys are said by design, and an invalid other one is refused before
	// anything runs; "a setting of the boot's own" below plants one.
	head := map[string]bool{}
	for _, k := range readKeys {
		head[k] = true
	}
	secrets := map[string]string{}
	var tokens []string
	plant := func(key, value, tok string) {
		secrets[key] = value
		tokens = append(tokens, tok)
	}
	for _, m := range regexp.MustCompile(`(?m)^#?\s*([A-Z][A-Z0-9_]*)=`).FindAllStringSubmatch(string(repoFile(t, ".env.example")), -1) {
		if !head[m[1]] {
			tok := token()
			plant(m[1], "sec-"+tok, tok)
		}
	}
	if len(secrets) < 20 {
		t.Fatalf(".env.example names only %v", secrets)
	}
	fileTok, imageTok, cpuTok, quotedTok, firstTok, secondTok, dbTok := token(), token(), token(), token(), token(), token(), token()
	plant("SECRET_ENV_FILE", "envfile-"+fileTok, fileTok)
	plant("SECRET_IMAGE", "secretimage"+imageTok, imageTok)
	plant("SECRET_CPU", "cpu-"+cpuTok, cpuTok)
	plant("QUOTED_SECRET", `it's "q" $x ${y} `+quotedTok, quotedTok)
	plant("MULTILINE_SECRET", "first-"+firstTok+"\nsecond-"+secondTok, firstTok)
	tokens = append(tokens, secondTok)
	plant("DATABASE_URL", "postgres://alice:"+dbTok+"@db/cyfr", dbTok)
	insideTok := token()
	tokens = append(tokens, insideTok)
	env, err := EditEnv([]byte("CYFR_ACCESS=local\nCYFR_HOST=localhost\nCYFR_PORT=4000\n"), secrets, nil)
	if err != nil {
		t.Fatal(err)
	}

	held, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer held.Close()
	port := held.Addr().(*net.TCPAddr).Port
	compose := fmt.Sprintf(`services:
  cyfr:
    image: busybox:latest
    init: true
    command: ["sleep", "600"]
    env_file:
      - .env
    healthcheck:
      test: ["CMD", "true"]
      interval: 1s
      start_period: 1s
  proxy:
    image: busybox:latest
    init: true
    command: ["sleep", "600"]
    profiles: ["public"]
    ports:
      - "127.0.0.1:%d:80"
`, port)

	home := func(t *testing.T, extra map[string]string) (*Engine, *leakCheck) {
		t.Helper()
		b := make([]byte, 4)
		rand.Read(b)
		suffix := hex.EncodeToString(b)
		dir := filepath.Join(t.TempDir(), "home with spaces "+suffix)
		files := map[string]string{".env": string(env), "compose.yml": compose}
		maps.Copy(files, extra)
		e := realProject(t, dir, files)
		t.Cleanup(func() {
			out, _ := exec.Command("docker", "ps", "-aq", "--filter", "label=com.docker.compose.project="+e.project).Output()
			if ids := strings.Fields(string(out)); len(ids) > 0 {
				exec.Command("docker", append([]string{"rm", "-f"}, ids...)...).Run()
			}
			exec.Command("docker", "network", "rm", e.project+"_default").Run()
		})
		sys := e.docker.(*systemDocker)
		sys.watchdog, sys.environ = []string{exeOrSkip(t), "-access.watchdog"}, func() []string { return childEnv() }
		unlock, err := e.Lock("test")
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(unlock)
		return e, &leakCheck{t: t, tokens: tokens}
	}
	public := Target{Mode: ModePublic, Domain: "home.example.com"}

	// reads are the engine's answers that change nothing, before its last
	// pass and as they leave it.
	reads := func(e *Engine, l *leakCheck) {
		l.t.Helper()
		err := e.checkStack(bg)
		l.raw("checkStack", errPayloads(err), nil)
		l.out("CheckStack", errTexts(e.CheckStack(bg))...)
		h, err := e.envHead()
		l.raw("envHead", errPayloads(err), []*Head{&h})
		h, err = e.Head()
		l.out("Head", append(errTexts(err), string(h.Canonical()))...)
		s, err := e.status(bg)
		payloads, heads := statusRaw(s)
		l.raw("status", append(payloads, errPayloads(err)...), heads)
		s, err = e.Status(bg)
		l.out("Status", append(statusTexts(s), errTexts(err)...)...)
		p, err := e.preview(bg, public, "")
		l.raw("preview", errPayloads(err), []*Head{&p.Old, &p.New})
		p, err = e.Preview(bg, public, "")
		l.out("Preview", append(errTexts(err), fmt.Sprintf("%+v", p))...)
	}
	// operate runs a mutating operation before the last pass and as the
	// boundary passes it on.
	operate := func(e *Engine, l *leakCheck, what string, op func() (Receipt, error)) Receipt {
		l.t.Helper()
		before := e.redactor()
		rc, err := op()
		l.raw(what, append(errPayloads(err), rc.Payload), []*Head{rc.FinalHead})
		rc, err = e.leaving(before, rc, err)
		l.out(what, append(receiptTexts(rc), errTexts(err)...)...)
		return rc
	}
	settle := func(e *Engine, l *leakCheck) {
		l.t.Helper()
		rcs, err := e.Resume(bg)
		for _, rc := range rcs {
			l.out("Resume", receiptTexts(rc)...)
		}
		l.out("Resume", errTexts(err)...)
		operate(e, l, "Stop", func() (Receipt, error) { return e.doStop(bg, "down", true) })
		l.out("state", stateTexts(l.t, e)...)
	}

	t.Run("a .env line compose cannot read", func(t *testing.T) {
		e, l := home(t, map[string]string{".env": string(env) + `BROKEN="never closed ` + insideTok + "\n"})
		reads(e, l)
		operate(e, l, "Start", func() (Receipt, error) { return e.doStart(bg, "up", HealthDeadline) })
		operate(e, l, "Switch", func() (Receipt, error) {
			return e.doSwitch(bg, SwitchRequest{ID: id(1), Target: public})
		})
		settle(e, l)
	})
	t.Run("an env file a value names", func(t *testing.T) {
		e, l := home(t, map[string]string{
			"compose.override.yml": "services:\n  cyfr:\n    env_file:\n      - ${SECRET_ENV_FILE}\n",
			"envfile-" + fileTok:   "DATABASE_URL=\"postgres://alice:no such service: " + insideTok + "@db/cyfr\n",
		})
		reads(e, l)
		if err := e.CheckStack(bg); err == nil || !strings.Contains(err.Error(), "it could not read an env file") {
			t.Errorf("CheckStack answered %v", err)
		}
		operate(e, l, "Start", func() (Receipt, error) { return e.doStart(bg, "up", HealthDeadline) })
		settle(e, l)
	})
	t.Run("a value compose refuses at services[..]", func(t *testing.T) {
		e, l := home(t, map[string]string{"compose.override.yml": "services:\n  cyfr:\n    deploy:\n      resources:\n        limits:\n          cpus: ${SECRET_CPU}\n"})
		reads(e, l)
		if err := e.CheckStack(bg); err == nil || !strings.Contains(err.Error(), "it refused the value of services[cyfr].deploy.resources.limits.cpus") {
			t.Errorf("CheckStack answered %v", err)
		}
		operate(e, l, "Start", func() (Receipt, error) { return e.doStart(bg, "up", HealthDeadline) })
		settle(e, l)
	})
	t.Run("a service compose does not have", func(t *testing.T) {
		e, l := home(t, nil)
		h, err := e.Head()
		if err != nil {
			t.Fatal(err)
		}
		args, err := e.ComposeArgs(bg, h, "up", "-d", "sec-"+insideTok)
		if err != nil {
			t.Fatal(err)
		}
		res, err := e.Docker().Run(bg, Call{Args: args, Deadline: StopDeadline})
		said := e.callFailed("docker compose up", err, res.Stderr)
		if !strings.Contains(string(res.Stderr), "no such service: sec-"+insideTok) || !strings.HasSuffix(said, ": it has no such service)") {
			t.Errorf("compose wrote %q, said as %q", res.Stderr, said)
		}
		l.out("no such service", said)
		settle(e, l)
	})
	t.Run("an image compose cannot find", func(t *testing.T) {
		e, l := home(t, map[string]string{"compose.override.yml": "services:\n  cyfr:\n    image: ${SECRET_IMAGE}\n    pull_policy: never\n"})
		reads(e, l)
		rc := operate(e, l, "Start", func() (Receipt, error) { return e.doStart(bg, "up", HealthDeadline) })
		if rc.Outcome != "failed" {
			t.Errorf("Start answered %+v", rc)
		}
		_, err := e.Start(bg, "up")
		if err == nil || !strings.Contains(err.Error(), "an image could not be found or pulled") {
			t.Errorf("Start answered %v", err)
		}
		l.out("Start", errTexts(err)...)
		settle(e, l)
	})
	t.Run("a port another process holds", func(t *testing.T) {
		e, l := home(t, nil)
		if rc, err := e.Start(bg, "up"); err != nil || rc.Outcome != "ok" {
			t.Fatalf("Start answered %+v, %v", rc, err)
		}
		reads(e, l)
		p, err := e.Preview(bg, public, "")
		if err != nil {
			t.Fatal(err)
		}
		r := SwitchRequest{ID: id(7), Target: public, OldDigest: p.OldDigest, NewDigest: p.NewDigest, Content: RequestContent{Mode: ModePublic, Domain: public.Domain}}
		rc := operate(e, l, "Switch", func() (Receipt, error) { return e.doSwitch(bg, r) })
		if rc.Outcome != "rolled_back" || !strings.Contains(rc.Payload["reason"], fmt.Sprintf("port %d is already in use", port)) {
			t.Errorf("the switch answered %+v", rc)
		}
		again, _, err := e.Receipt(r.ID)
		l.out("Receipt", append(receiptTexts(again), errTexts(err)...)...)
		raw, _, err := e.receiptOf(r.ID)
		l.raw("receiptOf", append(errPayloads(err), raw.Payload), []*Head{raw.FinalHead})
		resent, _, err := e.Resent(r.ID, r.Content)
		l.out("Resent", append(receiptTexts(resent), errTexts(err)...)...)
		reads(e, l)
		settle(e, l)
	})
	t.Run("a daemon docker cannot reach", func(t *testing.T) {
		e, l := home(t, nil)
		t.Setenv("DOCKER_HOST", "unix:///nonexistent")
		reads(e, l)
		s, err := e.Status(bg)
		if err != nil || !slices.ContainsFunc(s.Health, func(h string) bool { return strings.Contains(h, "the Docker daemon is not reachable") }) {
			t.Errorf("Status answered %+v, %v", s, err)
		}
		operate(e, l, "Start", func() (Receipt, error) { return e.doStart(bg, "up", HealthDeadline) })
		operate(e, l, "Stop", func() (Receipt, error) { return e.doStop(bg, "down", true) })
		l.out("state", stateTexts(t, e)...)
	})
	t.Run("a daemon this user may not use", func(t *testing.T) {
		if os.Geteuid() == 0 {
			t.Skip("root may use any socket")
		}
		e, l := home(t, nil)
		sock := filepath.Join(t.TempDir(), "docker.sock")
		ln, err := net.Listen("unix", sock)
		if err != nil {
			t.Fatal(err)
		}
		defer ln.Close()
		if err := os.Chmod(sock, 0); err != nil {
			t.Fatal(err)
		}
		t.Setenv("DOCKER_HOST", "unix://"+sock)
		s, err := e.Status(bg)
		if err != nil || !slices.ContainsFunc(s.Health, func(h string) bool { return strings.Contains(h, "this user may not use the Docker daemon") }) {
			t.Errorf("Status answered %+v, %v", s, err)
		}
		l.out("Status", statusTexts(s)...)
		operate(e, l, "Start", func() (Receipt, error) { return e.doStart(bg, "up", HealthDeadline) })
	})
	t.Run("a setting of the boot's own", func(t *testing.T) {
		tok := token()
		e, l := home(t, map[string]string{".env": string(env) + "CYFR_PROXY_BIND_ADDRESS=sec-" + tok + "\n"})
		// Before the last pass the boot refusal holds the value, as the
		// cross-language contract has it; past the boundary it is
		// redacted (leakCheck.boot).
		l.boot = []string{tok}
		reads(e, l)
		_, err := e.envHead()
		if r := (*Refusal)(nil); !errors.As(err, &r) || r.Code != "access_setting_invalid" || r.Payload["value"] != "sec-"+tok {
			t.Errorf("the boot's refusal reads %v", err)
		}
		operate(e, l, "Start", func() (Receipt, error) { return e.doStart(bg, "up", HealthDeadline) })
		settle(e, l)
	})
}
