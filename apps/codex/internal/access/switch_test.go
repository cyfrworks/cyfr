// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package access

import (
	"context"
	"errors"
	"maps"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

var bg = context.Background()

// A running stack switches in order: the old access services and cyfr
// stopped and verified, .env committed with the new head, cyfr then the
// new proxy started under the new head's materialized configuration, its
// health awaited; the receipt is durable and nothing is left behind.
func TestSwitchStopsCommitsThenStarts(t *testing.T) {
	h := newHome(t)
	h.fake.startStack(t, h.head())
	target := Target{Browser: BrowserDomain, Domain: "home.example.com"}
	r := h.request(id(1), target, "")
	rc, err := h.e.Switch(bg, r)
	if err != nil || rc.State != "completed" || rc.Outcome != "ok" {
		t.Fatalf("switch answered %+v, %v", rc, err)
	}
	if got := h.head(); got.Digest() != r.NewDigest {
		t.Errorf(".env holds %+v, not the new head", got)
	}
	h.assertConverged(domainStack...)

	calls := h.fake.calls()
	commit := slices.IndexFunc(calls, func(c fakeCall) bool { return strings.Contains(c.DotEnv, "CYFR_BROWSER=domain") })
	if commit < 0 {
		t.Fatal("no call saw the committed .env")
	}
	stops := slices.IndexFunc(calls, func(c fakeCall) bool { return c.Args[0] == "stop" })
	if stops < 0 || stops > commit {
		t.Errorf("the stop (call %d) is not before the commit (call %d)", stops, commit)
	}
	for i, c := range calls {
		if c.Args[0] != "compose" || !slices.Contains(c.Args, "up") {
			continue
		}
		if i < commit {
			t.Errorf("compose up before the commit: %s", c)
		}
		if c.Serve != serveClosed {
			t.Errorf("compose up while Serve held %q: %s", c.Serve, c)
		}
		want := []string{"compose", "-p", "home", "-f", resolvedName(r.NewDigest), "--project-directory", ".", "--profile", "domain"}
		if !slices.Equal(c.Args[:len(want)], want) {
			t.Errorf("compose up is not on the new head's materialized file and selection: %s", c)
		}
	}
	if rc2, ok, err := h.e.Receipt(id(1)); !ok || err != nil || rc2.Outcome != "ok" {
		t.Errorf("the receipt reads %+v %v %v", rc2, ok, err)
	}
}

// A stopped stack switches with no compose call: docker's containers are
// read by label, none runs, .env is committed and nothing starts. It
// works with no compose file at all.
func TestStoppedStackSwitchMakesNoComposeCall(t *testing.T) {
	h := newHome(t)
	os.Remove(filepath.Join(h.dir, "docker-compose.yml"))
	r := h.request(id(1), Target{Browser: BrowserDomain, Domain: "home.example.com"}, "")
	rc, err := h.e.Switch(bg, r)
	if err != nil || rc.Outcome != "ok" {
		t.Fatalf("switch answered %+v, %v", rc, err)
	}
	for _, c := range h.fake.calls() {
		if c.Args[0] != "ps" {
			t.Errorf("a stopped-stack switch ran docker %s", c)
		}
	}
	if h.head().Digest() != r.NewDigest {
		t.Error(".env does not hold the new head")
	}
	h.assertConverged()
}

// The fence: the preview binds both heads by digest, and a change to
// either between the preview and the switch refuses with access_stale and
// the words .env holds now, changing nothing; an email alone changes the
// public head's digest; the same head again is access_unchanged.
func TestSwitchFenceRefusesAStalePreview(t *testing.T) {
	h := newHome(t)
	pub := Target{Browser: BrowserDomain, Domain: "home.example.com"}
	withEmail := Target{Browser: BrowserDomain, Domain: "home.example.com", ACMEEmail: "ops@example.com"}
	if h.preview(pub, "").NewDigest == h.preview(withEmail, "").NewDigest {
		t.Error("an email-only change keeps the public head's digest")
	}
	for n, edit := range []struct{ name, from, to string }{
		{"port", "CYFR_PORT=4000", "CYFR_PORT=4100"},
	} {
		r := h.request(id(10+n), pub, "")
		before := strings.Replace(h.env(), edit.from, edit.to, 1)
		writeFile(t, filepath.Join(h.dir, ".env"), []byte(before))
		rc, err := h.e.Switch(bg, r)
		if refusalCode(err) != "access_stale" || rc.State != "rejected" {
			t.Errorf("%s changed after the preview: answered %+v, %v", edit.name, rc, err)
		}
		if words := rc.Payload["words"]; !strings.Contains(words, "only this computer, at http://h-xeypbemm44chehc5.localhost:") {
			t.Errorf("%s: access_stale names %q", edit.name, words)
		}
		if h.env() != before {
			t.Errorf("%s: a refused switch changed .env", edit.name)
		}
		writeFile(t, filepath.Join(h.dir, ".env"), []byte(strings.Replace(before, edit.to, edit.from, 1)))
	}
	if _, err := h.e.Preview(bg, Target{Browser: BrowserNone}, ""); refusalCode(err) != "access_unchanged" {
		t.Errorf("previewing the head .env holds answered %v", err)
	}
	if calls := h.fake.calls(); slices.ContainsFunc(calls, func(c fakeCall) bool { return c.Args[0] != "ps" && c.Args[0] != "compose" }) {
		t.Errorf("a refused switch ran docker beyond its reads: %v", calls)
	}
}

// A start the boot refused says the boot's own refusal in its rolled-back
// sentence, read before the container that logged it is stopped: an
// account service's origin, which only the database holds, is refused
// there, and the person reads why and that CYFR was put back.
func TestAFailedStartSaysTheRefusalItsBootLogged(t *testing.T) {
	h := newHome(t)
	h.fake.startStack(t, h.head())
	fatal := "[Cyfr] FATAL: This CYFR serves its own account service, which keeps its address for good: it was first served at " + testPrivate + ", and these settings give https://home.example.com. Nothing started."
	h.fake.hook = func(_ context.Context, c *fakeCall) *fakeAnswer {
		h.fake.mu.Lock()
		defer h.fake.mu.Unlock()
		domain := envNow(h.dir, "CYFR_BROWSER=domain")
		if slices.Contains(c.Args, "logs") && domain {
			return &fakeAnswer{Stdout: "starting\n" + fatal + "\n"}
		}
		h.fake.st.Health = "healthy"
		if domain {
			h.fake.st.Health = "unhealthy"
		}
		return nil
	}
	rc, err := h.e.Switch(bg, h.request(id(1), Target{Browser: BrowserDomain, Domain: "home.example.com"}, ""))
	if refusalCode(err) != "access_rolled_back" || rc.Outcome != "rolled_back" {
		t.Fatalf("switch answered %+v, %v", rc, err)
	}
	if !strings.Contains(err.(*Refusal).Message(), "health check failed: "+fatal) || !strings.Contains(err.(*Refusal).Message(), "CYFR was put back") {
		t.Errorf("the sentence reads %q", err.(*Refusal).Message())
	}
}

// A failed start: the target's proxy starts, cyfr's health fails.
// The target's proxy and cyfr are stopped and verified stopped before
// .env is restored or the old head starts; the receipt says rolled back,
// in the generated sentence.
func TestRollbackStopsTheTargetBeforeRestoringTheOldHead(t *testing.T) {
	h := newHome(t)
	h.fake.startStack(t, h.head())
	old := h.head()
	r := h.request(id(1), Target{Browser: BrowserDomain, Domain: "home.example.com"}, "")
	h.fake.hook = func(_ context.Context, c *fakeCall) *fakeAnswer {
		h.fake.mu.Lock()
		defer h.fake.mu.Unlock()
		// The new head's cyfr fails its health; the old one's passes.
		h.fake.st.Health = "healthy"
		if envNow(h.dir, "CYFR_BROWSER=domain") {
			h.fake.st.Health = "unhealthy"
		}
		return nil
	}
	rc, err := h.e.Switch(bg, r)
	if refusalCode(err) != "access_rolled_back" || rc.Outcome != "rolled_back" {
		t.Fatalf("switch answered %+v, %v", rc, err)
	}
	if !strings.Contains(err.(*Refusal).Message(), "could not start as anyone on the internet") || !strings.Contains(err.(*Refusal).Message(), "health check failed") {
		t.Errorf("the sentence reads %q", err.(*Refusal).Message())
	}
	if h.head().Digest() != old.Digest() {
		t.Error(".env does not hold the old head again")
	}
	h.assertConverged(baseStack...)

	calls := h.fake.calls()
	proxyUp := slices.IndexFunc(calls, func(c fakeCall) bool { return slices.Contains(c.Args, "up") && slices.Contains(c.Args, "caddy") })
	unhealthy := slices.IndexFunc(calls, func(c fakeCall) bool {
		return c.Args[0] == "inspect" && strings.Contains(c.DotEnv, "CYFR_BROWSER=domain")
	})
	restored := slices.IndexFunc(calls[max(unhealthy, 0):], func(c fakeCall) bool { return strings.Contains(c.DotEnv, "CYFR_BROWSER=none") }) + max(unhealthy, 0)
	if proxyUp < 0 || unhealthy < proxyUp || restored <= unhealthy {
		t.Fatalf("no proxy start, failed health, then restore in %v", calls)
	}
	between := calls[unhealthy:restored]
	stop := slices.IndexFunc(between, func(c fakeCall) bool {
		return c.Args[0] == "stop" && slices.Contains(c.Args, "cyfr") && slices.Contains(c.Args, "home-caddy-1")
	})
	if stop < 0 {
		t.Errorf("the target's proxy and cyfr were not stopped before .env was restored: %v", between)
	}
	if reads := between[stop:]; len(slices.DeleteFunc(slices.Clone(reads), func(c fakeCall) bool { return c.Args[0] != "ps" })) < 4 {
		t.Errorf("the stop was not verified by two reads before .env was restored: %v", reads)
	}
	for _, c := range calls[:restored] {
		if slices.Contains(c.Args, "up") && strings.Contains(strings.Join(c.Args, " "), resolvedName(old.Digest())) {
			t.Errorf("the old head started before .env was restored: %s", c)
		}
	}
}

// A stop command that fails gives uncertain with what was seen running,
// never "stopped": nothing more starts, .env keeps the old head, the
// journal and its files stay, and every mutating method answers that
// receipt until Resume converges it, after which one coherent head runs
// and nothing is left behind.
func TestFailedStopIsUncertainThenResumeConverges(t *testing.T) {
	h := newHome(t)
	h.fake.startStack(t, h.head())
	old := h.env()
	r := h.request(id(1), Target{Browser: BrowserDomain, Domain: "home.example.com"}, "")
	broken := true
	h.fake.hook = func(_ context.Context, c *fakeCall) *fakeAnswer {
		if broken && c.Args[0] == "stop" {
			return &fakeAnswer{Stderr: "Error response from daemon: cannot stop container cyfr: tried to kill container, but did not receive an exit event\n", Code: 1}
		}
		return nil
	}
	rc, err := h.e.Switch(bg, r)
	if refusalCode(err) != "access_uncertain" || rc.State != "accepted" || rc.Phase != "uncertain" {
		t.Fatalf("switch answered %+v, %v", rc, err)
	}
	if !slices.Contains(rc.Observed, "cyfr") || !strings.Contains(rc.Payload["observed"], "cyfr") {
		t.Errorf("uncertain names %v / %q, not cyfr", rc.Observed, rc.Payload["observed"])
	}
	if h.env() != old {
		t.Error("an uncertain stop changed .env")
	}
	if _, ok, _ := h.e.readReceipt(id(1)); ok {
		t.Error("an uncertain stop wrote a terminal receipt")
	}
	if j, _ := h.e.readJournal(); j == nil || j.Phase != "uncertain" {
		t.Fatalf("the journal is %+v", j)
	}
	other := h.request(id(2), Target{Browser: BrowserDomain, Domain: "other.example.com"}, "")
	if rc, err := h.e.Switch(bg, other); refusalCode(err) != "access_uncertain" || rc.RequestID != id(1) {
		t.Errorf("another switch answered %+v, %v, not the uncertain receipt", rc, err)
	}
	if _, err := h.e.Start(bg, "up"); refusalCode(err) != "access_uncertain" {
		t.Errorf("a start answered %v while the switch is uncertain", err)
	}

	// The owner restarts and runs `cyfr access --resume`, as the sentence
	// says.
	broken = false
	h.crash()
	h.open()
	receipts, err := h.e.Resume(bg)
	if err != nil || len(receipts) != 1 || receipts[0].State != "completed" {
		t.Fatalf("resume answered %+v, %v", receipts, err)
	}
	h.assertConverged(baseStack...)
	if rc, _, _ := h.e.Receipt(id(1)); rc.State != "completed" || rc.Outcome != "not_applied" {
		t.Errorf("the switch's receipt is %+v", rc)
	}
}

// envNow reports whether .env holds line now.
func envNow(dir, line string) bool {
	data, _ := os.ReadFile(filepath.Join(dir, ".env"))
	return strings.Contains(string(data), line+"\n")
}

// A rollback whose stop cannot be verified stays uncertain with the
// files its journal names: neither a stop by the same command nor the
// lock's release removes them, and the recovery that converges does.
func TestUncertainRollbackKeepsItsFiles(t *testing.T) {
	h := newHome(t)
	h.fake.startStack(t, h.head())
	r := h.request(id(1), domainTarget, "")
	broken := true
	h.fake.hook = func(_ context.Context, c *fakeCall) *fakeAnswer {
		h.fake.mu.Lock()
		defer h.fake.mu.Unlock()
		public := envNow(h.dir, "CYFR_BROWSER=domain")
		h.fake.st.Health = "healthy"
		if public {
			h.fake.st.Health = "unhealthy"
		}
		if broken && public && c.Args[0] == "stop" {
			return &fakeAnswer{Stderr: "Error response from daemon: cannot stop container\n", Code: 1}
		}
		return nil
	}
	if rc, err := h.e.Switch(bg, r); refusalCode(err) != "access_uncertain" || rc.Phase != "uncertain" {
		t.Fatalf("switch answered %+v, %v", rc, err)
	}
	j, _ := h.e.readJournal()
	if j == nil || !slices.Contains(j.Files, resolvedName(r.NewDigest)) {
		t.Fatalf("the journal is %+v", j)
	}
	kept := func(when string) {
		t.Helper()
		if got := h.files(resolvedGlob); !slices.Equal(got, []string{filepath.Base(resolvedName(r.NewDigest))}) {
			t.Errorf("%s the materialized files are %v", when, got)
		}
	}
	kept("while uncertain")
	if _, err := h.e.Stop(bg, "down", false); refusalCode(err) != "access_uncertain" {
		t.Errorf("a stop answered %v", err)
	}
	kept("after a stop")
	h.unlock()
	kept("after the lock's release")
	broken = false
	h.open()
	if receipts, err := h.e.Resume(bg); err != nil || len(receipts) != 1 || receipts[0].State != "completed" {
		t.Fatalf("resume answered %+v, %v", receipts, err)
	}
	h.assertConverged(baseStack...)
}

// An auth key's fingerprint, which a request binds, is the key's with
// surrounding space removed; no key has none.
func TestAuthKeyFingerprintIsTheTrimmedKeys(t *testing.T) {
	if fp := authKeyFingerprint([]byte(" " + testKey + "\n")); fp != "sha256:"+sha256Hex([]byte(testKey)) || authKeyFingerprint([]byte(" \n")) != "" {
		t.Errorf("authKeyFingerprint gave %q", fp)
	}
}

// A switch refuses a stated trust every start would refuse, by the boot's
// own refusal and with the stack stopped, before .env is written: each
// boot vector the trust's rule refuses (tests/fixtures/access.json) is
// the input, to every kind with a proxy listener.
func TestStoppedSwitchRefusesTheTrustEveryStartRefuses(t *testing.T) {
	var cases int
	for _, v := range readVectors(t).Boot {
		key := ""
		if v.Refusal != nil && v.Refusal.Code == "access_setting_invalid" {
			key = v.Refusal.Payload["key"]
		}
		if key != "CYFR_TRUSTED_PROXY_HOPS" && key != "CYFR_TRUSTED_PROXY_CIDRS" {
			continue
		}
		cases++
		for _, target := range []Target{
			{Browser: BrowserProxy, Domain: "cyfr.example.com"},
			{Browser: BrowserDomain, Domain: "cyfr.example.com"},
			{Browser: BrowserTailnet},
		} {
			h := newHome(t)
			old := h.head().Digest()
			before := h.env() + key + "=" + v.Input.Process[key] + "\n"
			writeFile(t, filepath.Join(h.dir, ".env"), []byte(before))
			if _, err := h.e.Preview(bg, target, ""); refusalCode(err) != "access_setting_invalid" {
				t.Errorf("%s: the preview to %s answered %v", v.Name, target.Browser, err)
			}
			rc, err := h.e.Switch(bg, SwitchRequest{ID: id(1), Target: target, OldDigest: old, NewDigest: "sha256:any"})
			var r *Refusal
			// The refusal names the setting; its value is redacted as every
			// .env value an engine refusal carries.
			if !errors.As(err, &r) || r.Code != "access_setting_invalid" || r.Payload["key"] != key || rc.Outcome == "ok" {
				t.Errorf("%s: the switch to %s answered %+v, %v; want the boot's refusal of %s", v.Name, target.Browser, rc, err, key)
			}
			if h.env() != before {
				t.Errorf("%s: the refused switch to %s wrote .env:\n%s", v.Name, target.Browser, h.env())
			}
		}
	}
	if cases == 0 {
		t.Fatal("the access vectors hold no trust the boot refuses")
	}
}

// The proxy trust is .env's own word: a trust key whose value .env takes
// from another variable, which the caller's environment would choose, is
// refused by name, at the update's read of .env and at every engine read;
// the same text single-quoted is a literal, read as any value is.
func TestTrustKeysTakeLiteralValuesOnly(t *testing.T) {
	t.Setenv("S2_TRUST", "10.0.0.0/8")
	for _, c := range []struct {
		line, key string
	}{
		{"CYFR_TRUSTED_PROXY_CIDRS=${S2_TRUST}", "CYFR_TRUSTED_PROXY_CIDRS"},
		{"CYFR_TRUSTED_PROXY_CIDRS=\"$S2_TRUST\"", "CYFR_TRUSTED_PROXY_CIDRS"},
		{"CYFR_TRUSTED_PROXY_HOPS=${S2_HOPS:-1}", "CYFR_TRUSTED_PROXY_HOPS"},
		{"CYFR_TRUSTED_PROXY_HOPS", "CYFR_TRUSTED_PROXY_HOPS"},
		{"CYFR_TRUSTED_PROXY_CIDRS", "CYFR_TRUSTED_PROXY_CIDRS"},
	} {
		h := newHome(t)
		path := filepath.Join(h.dir, ".env")
		writeFile(t, path, []byte(h.env()+c.line+"\n"))
		for name, err := range map[string]error{"the update's read": CheckEnvFile(path), "the engine's read": func() error { _, err := h.e.Head(); return err }()} {
			var r *Refusal
			if !errors.As(err, &r) || r.Code != "access_trust_interpolated" || r.Payload["key"] != c.key {
				t.Errorf("%q: %s answered %v", c.line, name, err)
			}
		}
	}
	h := newHome(t)
	path := filepath.Join(h.dir, ".env")
	writeFile(t, path, []byte(h.env()+"CYFR_TRUSTED_PROXY_HOPS='2'\n"))
	if err := CheckEnvFile(path); err != nil {
		t.Errorf("a single-quoted literal trust is refused: %v", err)
	}
}

// A server that serves its own account service keeps the address it gives
// out: a change that adds its browser address, removes it or moves it to
// another host is refused before anything changes, by the preview and by
// the switch, naming the address it keeps and the one it would move to;
// a change that moves no address, a certificate email, is made.
func TestAWriterKeepsTheAddressItGivesOut(t *testing.T) {
	h := newHome(t)
	writer := func() { writeFile(t, filepath.Join(h.dir, ".env"), []byte(h.env()+"CYFR_DIRECTORY_SERVE=writer\n")) }
	refused := func(n int, target Target, pinned, origin string) {
		t.Helper()
		_, err := h.e.Preview(bg, target, "")
		var r *Refusal
		want := map[string]string{"pinned": pinned, "origin": origin}
		if !errors.As(err, &r) || r.Code != "access_origin_pinned" || r.Class != "conflict" || !maps.Equal(r.Payload, want) {
			t.Errorf("preview of %+v answered %v, want access_origin_pinned %v", target, err, want)
		}
		d, err := Derive(target, Current{Port: 4000}, nil)
		if err != nil {
			t.Fatal(err)
		}
		before, calls := h.env(), len(h.fake.calls())
		rc, err := h.e.Switch(bg, SwitchRequest{ID: id(n), Target: target, OldDigest: h.head().Digest(), NewDigest: d.Head.Digest()})
		if refusalCode(err) != "access_origin_pinned" || rc.State != "rejected" || !maps.Equal(rc.Payload, want) {
			t.Errorf("switch to %+v answered %+v, %v", target, rc, err)
		}
		if h.env() != before || len(h.fake.calls()) != calls {
			t.Errorf("a refused switch to %+v changed .env or called docker", target)
		}
		if r != nil && (!strings.Contains(r.Message(), pinned) || !strings.Contains(r.Message(), origin)) {
			t.Errorf("the refusal reads %q", r.Message())
		}
	}

	// Pinned to its private address, as a writer with no browser address;
	// a tailnet address is refused before the join that would name it.
	writer()
	refused(1, domainTarget, testPrivate, "https://home.example.com")
	_, err := h.e.Preview(bg, Target{Browser: BrowserTailnet}, "")
	if r := (*Refusal)(nil); !errors.As(err, &r) || r.Code != "access_origin_pinned" || !maps.Equal(r.Payload, map[string]string{"pinned": testPrivate, "origin": unjoinedTailnet}) {
		t.Errorf("a tailnet address for a writer that has not joined answered %v", err)
	}

	// Pinned to its browser address, as one that became a writer there.
	h2 := newHome(t)
	h = h2
	if rc, err := h.e.Switch(bg, h.request(id(2), domainTarget, "")); err != nil || rc.Outcome != "ok" {
		t.Fatalf("switch answered %+v, %v", rc, err)
	}
	writer()
	refused(3, Target{Browser: BrowserNone}, "https://home.example.com", testPrivate)
	refused(4, Target{Browser: BrowserDomain, Domain: "other.example.com"}, "https://home.example.com", "https://other.example.com")

	email := Target{Browser: BrowserDomain, Domain: "home.example.com", ACMEEmail: "ops@example.com"}
	if rc, err := h.e.Switch(bg, h.request(id(5), email, "")); err != nil || rc.Outcome != "ok" {
		t.Errorf("a writer's certificate email change answered %+v, %v", rc, err)
	}
}

// A .env without the tunnel key, or with one that is no public key,
// holds no head, after any refusal of its access settings: the engine
// refuses it as the boot does, and derives no head from it.
func TestATunnelKeyIsRead(t *testing.T) {
	h := newHome(t)
	good := h.env()
	for _, c := range []struct {
		name, env, code string
	}{
		{"missing", strings.Replace(good, linkLine, "", 1), "access_link_missing"},
		{"blank", strings.Replace(good, linkLine, "CYFR_LINK_PUBLIC= \n", 1), "access_link_missing"},
		{"uppercase", strings.Replace(good, linkLine, strings.ToUpper(linkLine), 1), "access_link_invalid"},
		{"an access refusal first", strings.Replace(strings.Replace(good, linkLine, "", 1), "CYFR_BROWSER=none", "CYFR_BROWSER=sideways", 1), "access_unknown_browser"},
	} {
		writeFile(t, filepath.Join(h.dir, ".env"), []byte(c.env))
		if _, err := h.e.Head(); refusalCode(err) != c.code {
			t.Errorf("%s: the head answered %v, want %s", c.name, err, c.code)
		}
		if _, err := h.e.Preview(bg, domainTarget, ""); c.code != "access_unknown_browser" && refusalCode(err) != c.code {
			t.Errorf("%s: the preview answered %v, want %s", c.name, err, c.code)
		}
	}
	for _, c := range []struct{ text, code string }{{"", "access_link_missing"}, {"  ", "access_link_missing"}, {"nodekey:" + testLink, "access_link_invalid"}} {
		if _, err := ResolveLink(c.text, 4000); refusalCode(err) != c.code {
			t.Errorf("ResolveLink(%q) answered %v, want %s", c.text, err, c.code)
		}
	}
	if got, err := ResolveLink(" "+testLink+" ", 4000); err != nil || got != testPrivate {
		t.Errorf("ResolveLink answered %q, %v", got, err)
	}
	for _, code := range []string{"access_link_missing", "access_link_invalid"} {
		if class := Refuse(code, nil).Class; class != map[string]string{"access_link_missing": "setup_required", "access_link_invalid": "invalid_argument"}[code] {
			t.Errorf("%s is class %s", code, class)
		}
	}
}
