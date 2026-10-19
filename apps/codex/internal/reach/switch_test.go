// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package reach

import (
	"context"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

var bg = context.Background()

// A running stack switches in order: the old reach services and cyfr
// stopped and verified, .env committed with the new head, cyfr then the
// new proxy started under the new head's materialized configuration, its
// health awaited; the receipt is durable and nothing is left behind.
func TestSwitchStopsCommitsThenStarts(t *testing.T) {
	h := newHome(t)
	h.fake.startStack(t, h.head())
	target := Target{Mode: ModePublic, Domain: "home.example.com"}
	r := h.request(id(1), target, "")
	rc, err := h.e.Switch(bg, r)
	if err != nil || rc.State != "completed" || rc.Outcome != "ok" {
		t.Fatalf("switch answered %+v, %v", rc, err)
	}
	if got := h.head(); got.Digest() != r.NewDigest {
		t.Errorf(".env holds %+v, not the new head", got)
	}
	h.assertConverged(publicStack...)

	calls := h.fake.calls()
	commit := slices.IndexFunc(calls, func(c fakeCall) bool { return strings.Contains(c.DotEnv, "CYFR_REACH=public") })
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
		want := []string{"compose", "-p", "home", "-f", resolvedName(r.NewDigest), "--project-directory", ".", "--profile", "locus-builds", "--profile", "public"}
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
	r := h.request(id(1), Target{Mode: ModePublic, Domain: "home.example.com"}, "")
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
// either between the preview and the switch refuses with reach_stale and
// the words .env holds now, changing nothing; an email alone changes the
// public head's digest; the same head again is reach_unchanged.
func TestSwitchFenceRefusesAStalePreview(t *testing.T) {
	h := newHome(t)
	pub := Target{Mode: ModePublic, Domain: "home.example.com"}
	withEmail := Target{Mode: ModePublic, Domain: "home.example.com", ACMEEmail: "ops@example.com"}
	if h.preview(pub, "").NewDigest == h.preview(withEmail, "").NewDigest {
		t.Error("an email-only change keeps the public head's digest")
	}
	for n, edit := range []struct{ name, from, to string }{
		{"port", "CYFR_PORT=4000", "CYFR_PORT=4100"},
		{"builds URL", "CYFR_LOCUS_BUILDS_URL=http://locus-builds:4100", "CYFR_LOCUS_BUILDS_URL=http://builder.example.com:4100"},
		{"builds off", "CYFR_LOCUS_BUILDS_URL=http://locus-builds:4100", "CYFR_LOCUS_BUILDS_URL="},
	} {
		r := h.request(id(10+n), pub, "")
		before := strings.Replace(h.env(), edit.from, edit.to, 1)
		writeFile(t, filepath.Join(h.dir, ".env"), []byte(before))
		rc, err := h.e.Switch(bg, r)
		if refusalCode(err) != "reach_stale" || rc.State != "rejected" {
			t.Errorf("%s changed after the preview: answered %+v, %v", edit.name, rc, err)
		}
		if words := rc.Payload["words"]; !strings.Contains(words, "only this computer, at http://localhost:") {
			t.Errorf("%s: reach_stale names %q", edit.name, words)
		}
		if h.env() != before {
			t.Errorf("%s: a refused switch changed .env", edit.name)
		}
		if again, err := h.e.Switch(bg, r); refusalCode(err) != "reach_stale" || again.State != "rejected" {
			t.Errorf("%s: the resent request answers %+v, %v, not its rejected receipt", edit.name, again, err)
		}
		writeFile(t, filepath.Join(h.dir, ".env"), []byte(strings.Replace(before, edit.to, edit.from, 1)))
	}
	if _, err := h.e.Preview(bg, Target{Mode: ModeLocal}, ""); refusalCode(err) != "reach_unchanged" {
		t.Errorf("previewing the head .env holds answered %v", err)
	}
	if calls := h.fake.calls(); slices.ContainsFunc(calls, func(c fakeCall) bool { return c.Args[0] != "ps" && c.Args[0] != "compose" }) {
		t.Errorf("a refused switch ran docker beyond its reads: %v", calls)
	}
}

// A completed switch whose reply was lost answers its receipt when the
// same id and content are sent again after a restart, with no second
// mutation; the same id with other content is reach_request_reused and
// changes nothing.
func TestSwitchResentAnswersItsReceipt(t *testing.T) {
	h := newHome(t)
	h.fake.startStack(t, h.head())
	pub := Target{Mode: ModePublic, Domain: "home.example.com"}
	r := h.request(id(1), pub, "")
	first, err := h.e.Switch(bg, r)
	if err != nil {
		t.Fatal(err)
	}
	h.crash()
	h.open()
	before := len(h.fake.calls())
	again, err := h.e.Switch(bg, r)
	if err != nil || again.Outcome != "ok" || again.At != first.At || again.RequestDigest != first.RequestDigest {
		t.Errorf("the resent switch answered %+v, %v, not %+v", again, err, first)
	}
	if calls := h.fake.calls()[before:]; len(calls) != 0 {
		t.Errorf("the resent switch ran docker again: %v", calls)
	}
	other := r
	other.Target.Domain = "other.example.com"
	env := h.env()
	if rc, err := h.e.Switch(bg, other); refusalCode(err) != "reach_request_reused" || rc.State != "rejected" {
		t.Errorf("other content under the same id answered %+v, %v", rc, err)
	}
	if h.env() != env {
		t.Error("a reused id changed .env")
	}
	if rc, _, _ := h.e.Receipt(id(1)); rc.Outcome != "ok" {
		t.Errorf("a reused id overwrote the receipt: %+v", rc)
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
	r := h.request(id(1), Target{Mode: ModePublic, Domain: "home.example.com"}, "")
	h.fake.hook = func(_ context.Context, c *fakeCall) *fakeAnswer {
		h.fake.mu.Lock()
		defer h.fake.mu.Unlock()
		// The new head's cyfr fails its health; the old one's passes.
		h.fake.st.Health = "healthy"
		if envNow(h.dir, "CYFR_REACH=public") {
			h.fake.st.Health = "unhealthy"
		}
		return nil
	}
	rc, err := h.e.Switch(bg, r)
	if refusalCode(err) != "reach_rolled_back" || rc.Outcome != "rolled_back" {
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
		return c.Args[0] == "inspect" && strings.Contains(c.DotEnv, "CYFR_REACH=public")
	})
	restored := slices.IndexFunc(calls[max(unhealthy, 0):], func(c fakeCall) bool { return strings.Contains(c.DotEnv, "CYFR_REACH=local") }) + max(unhealthy, 0)
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
	r := h.request(id(1), Target{Mode: ModePublic, Domain: "home.example.com"}, "")
	broken := true
	h.fake.hook = func(_ context.Context, c *fakeCall) *fakeAnswer {
		if broken && c.Args[0] == "stop" {
			return &fakeAnswer{Stderr: "Error response from daemon: cannot stop container cyfr: tried to kill container, but did not receive an exit event\n", Code: 1}
		}
		return nil
	}
	rc, err := h.e.Switch(bg, r)
	if refusalCode(err) != "reach_uncertain" || rc.State != "accepted" || rc.Phase != "uncertain" {
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
	other := h.request(id(2), Target{Mode: ModePublic, Domain: "other.example.com"}, "")
	if rc, err := h.e.Switch(bg, other); refusalCode(err) != "reach_uncertain" || rc.RequestID != id(1) {
		t.Errorf("another switch answered %+v, %v, not the uncertain receipt", rc, err)
	}
	if _, err := h.e.Start(bg, "up"); refusalCode(err) != "reach_uncertain" {
		t.Errorf("a start answered %v while the switch is uncertain", err)
	}

	// The owner restarts and runs `cyfr reach --resume`, as the sentence
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
	r := h.request(id(1), publicTarget, "")
	broken := true
	h.fake.hook = func(_ context.Context, c *fakeCall) *fakeAnswer {
		h.fake.mu.Lock()
		defer h.fake.mu.Unlock()
		public := envNow(h.dir, "CYFR_REACH=public")
		h.fake.st.Health = "healthy"
		if public {
			h.fake.st.Health = "unhealthy"
		}
		if broken && public && c.Args[0] == "stop" {
			return &fakeAnswer{Stderr: "Error response from daemon: cannot stop container\n", Code: 1}
		}
		return nil
	}
	if rc, err := h.e.Switch(bg, r); refusalCode(err) != "reach_uncertain" || rc.Phase != "uncertain" {
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
	if _, err := h.e.Stop(bg, "down", false); refusalCode(err) != "reach_uncertain" {
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

// A request id sent again is bound to all it was first sent with,
// whatever its outcome: the same content answers its receipt (or its
// unfinished journal's answer); another mode, domain, email, machine
// name, --new-node or auth key answers reach_request_reused, changing and
// writing nothing; an id never sent answers false. The raw key is never
// stored.
func TestResentBindsTheWholeRequest(t *testing.T) {
	content := RequestContent{Mode: ModePublic, Domain: "home.example.com", ACMEEmail: "ops@example.com", Hostname: "home", NewNode: true, AuthKeyFingerprint: AuthKeyFingerprint([]byte(testKey + "\n"))}
	target := Target{Mode: ModePublic, Domain: "home.example.com", ACMEEmail: "ops@example.com"}
	others := map[string]RequestContent{}
	for name, change := range map[string]func(*RequestContent){
		"mode":     func(c *RequestContent) { c.Mode = ModeLocal },
		"domain":   func(c *RequestContent) { c.Domain = "other.example.com" },
		"email":    func(c *RequestContent) { c.ACMEEmail = "" },
		"hostname": func(c *RequestContent) { c.Hostname = "cyfr" },
		"new node": func(c *RequestContent) { c.NewNode = false },
		"key":      func(c *RequestContent) { c.AuthKeyFingerprint = AuthKeyFingerprint([]byte("tskey-auth-another")) },
	} {
		c := content
		change(&c)
		others[name] = c
	}
	for _, outcome := range []string{"ok", "rolled_back", "rejected", "unfinished"} {
		t.Run(outcome, func(t *testing.T) {
			h := newHome(t)
			h.fake.startStack(t, h.head())
			r := h.request(id(1), target, "")
			r.Content = content
			switch outcome {
			case "rolled_back":
				unhealthyWhen(h, "CYFR_REACH=public")
			case "rejected":
				r.OldDigest = "sha256:stale"
			}
			if outcome == "unfinished" {
				h.killAt("journal:switch:stopped", func(e *Engine) { e.Switch(bg, r) })
			} else {
				h.e.Switch(bg, r)
			}
			want, ok, err := h.e.Receipt(id(1))
			if err != nil || !ok || want.ContentDigest == "" {
				t.Fatalf("the receipt is %+v, %v, %v", want, ok, err)
			}
			got, ok, err := h.e.Resent(id(1), content)
			if err != nil || !ok || got.State != want.State || got.Outcome != want.Outcome || got.Code != want.Code || got.Phase != want.Phase || got.At != want.At {
				t.Errorf("the same content answers %+v, %v, %v, not %+v", got, ok, err, want)
			}
			before := h.snapshot()
			for name, c := range others {
				rc, ok, err := h.e.Resent(id(1), c)
				if err != nil || !ok || rc.State != "rejected" || rc.Code != "reach_request_reused" || rc.Refusal().Message() != "This request names a different change than the one first sent under its id. Nothing was changed. Send it again under a new id." {
					t.Errorf("another %s answers %+v, %v, %v", name, rc, ok, err)
				}
			}
			if !mapsEqual(before, h.snapshot()) {
				t.Error("Resent changed a file")
			}
			if _, ok, err := h.e.Resent(id(9), content); ok || err != nil {
				t.Errorf("an id never sent answers %v, %v", ok, err)
			}
			assertNoKey(t, h, testKey)
		})
	}

	// The fingerprint is the key's, surrounding space aside; no key has
	// none.
	if fp := AuthKeyFingerprint([]byte(" " + testKey + "\n")); fp != "sha256:"+sha256Hex([]byte(testKey)) || AuthKeyFingerprint([]byte(" \n")) != "" {
		t.Errorf("AuthKeyFingerprint gave %q", fp)
	}

	// A join's id is bound the same way, by its own request.
	h := newHome(t)
	h.join(1, testKey, false)
	if rc, ok, _ := h.e.Resent(id(1), RequestContent{Mode: ModeTailnet, AuthKeyFingerprint: AuthKeyFingerprint([]byte(testKey))}); !ok || rc.Op != "join" || rc.State != "completed" {
		t.Errorf("the join's content answers %+v", rc)
	}
	if rc, _, _ := h.e.Resent(id(1), RequestContent{Mode: ModeTailnet, AuthKeyFingerprint: AuthKeyFingerprint([]byte("tskey-auth-another"))}); rc.Code != "reach_request_reused" {
		t.Errorf("another key answers %+v", rc)
	}
}

// Switch binds a request id to the whole request as Resent does, whatever
// its first answer was: done in tailnet or in another mode, rolled back,
// rejected or still unfinished. The same request again answers that
// first answer, running no docker command; the same id with another
// mode, domain, email, machine name, --new-node or auth key answers
// reach_request_reused, changing and writing nothing and leaving the
// first receipt as it was.
func TestSwitchBindsAResentIDToTheWholeRequest(t *testing.T) {
	for _, first := range []string{"tailnet", "public", "rolled_back", "rejected", "unfinished"} {
		t.Run(first, func(t *testing.T) {
			h := newHome(t)
			var r SwitchRequest
			if first == "tailnet" {
				joined := h.join(10, testKey, false)
				r = h.request(id(1), Target{Mode: ModeTailnet}, joined.Payload["join_id"])
				r.Content = RequestContent{Mode: ModeTailnet, AuthKeyFingerprint: AuthKeyFingerprint([]byte(testKey))}
			} else {
				h.fake.startStack(t, h.head())
				r = h.request(id(1), publicTarget, "")
				r.Content = RequestContent{Mode: ModePublic, Domain: publicTarget.Domain}
			}
			switch first {
			case "rolled_back":
				unhealthyWhen(h, "CYFR_REACH=public")
			case "rejected":
				r.OldDigest = "sha256:stale"
			}
			if first == "unfinished" {
				h.killAt("journal:switch:stopped", func(e *Engine) { e.Switch(bg, r) })
			} else {
				h.e.Switch(bg, r)
			}
			want, ok, err := h.e.Receipt(id(1))
			wantState := map[string]string{"tailnet": "completed", "public": "completed", "rolled_back": "completed", "rejected": "rejected", "unfinished": "accepted"}[first]
			if err != nil || !ok || want.State != wantState {
				t.Fatalf("the first answer is %+v, %v, %v", want, ok, err)
			}
			before, calls := h.snapshot(), len(h.fake.calls())
			again, err := h.e.Switch(bg, r)
			if again.State != want.State || again.Outcome != want.Outcome || again.Code != want.Code || again.Phase != want.Phase || again.At != want.At || again.RequestDigest != want.RequestDigest || refusalCode(err) != want.Code {
				t.Errorf("the same request answers %+v, %v, not %+v", again, err, want)
			}
			for name, change := range map[string]func(*RequestContent){
				"mode":     func(c *RequestContent) { c.Mode = ModeLocal },
				"domain":   func(c *RequestContent) { c.Domain = "other.example.com" },
				"email":    func(c *RequestContent) { c.ACMEEmail = "ops@example.com" },
				"hostname": func(c *RequestContent) { c.Hostname = "different" },
				"new node": func(c *RequestContent) { c.NewNode = !c.NewNode },
				"key":      func(c *RequestContent) { c.AuthKeyFingerprint = AuthKeyFingerprint([]byte("tskey-auth-another")) },
			} {
				other := r
				change(&other.Content)
				rc, err := h.e.Switch(bg, other)
				if refusalCode(err) != "reach_request_reused" || rc.State != "rejected" || rc.Code != "reach_request_reused" || rc.Refusal().Message() != "This request names a different change than the one first sent under its id. Nothing was changed. Send it again under a new id." {
					t.Errorf("another %s answers %+v, %v", name, rc, err)
				}
			}
			if !mapsEqual(before, h.snapshot()) {
				t.Error("a resent request changed a file")
			}
			if after := h.fake.calls()[calls:]; len(after) != 0 {
				t.Errorf("a resent request ran docker: %v", after)
			}
			if rc, _, _ := h.e.Receipt(id(1)); rc.State != want.State || rc.Outcome != want.Outcome || rc.Code != want.Code || rc.At != want.At {
				t.Errorf("a reused id changed the first answer to %+v", rc)
			}
		})
	}
}
