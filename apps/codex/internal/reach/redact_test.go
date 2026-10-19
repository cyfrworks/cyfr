// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package reach

import (
	"bytes"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The redactor takes every value .env assigns to a name that is not a
// head key, as written and as compose reads it, each line of a multi-line
// one, and a malformed line's right-hand side; it keeps the head's values,
// the names the configuration publishes and the engine's words, and
// redacts a value that reaches past one of those whole.
func TestRedactorRedactsEveryValueButTheHeads(t *testing.T) {
	t.Setenv("REACH_REDACT_FROM_ENV", "interpolated-from-the-environment")
	env := strings.Join([]string{
		"CYFR_REACH=local",
		"CYFR_HOST=localhost",
		"CYFR_PORT=4000",
		"PLAIN=plain-secret-1",
		`QUOTED='it\'s quoted-secret-2'`,
		`DOUBLE="tab\tdouble-secret-3"`,
		"MULTI='first-line-secret-4",
		"second-line-secret-5'",
		"INTERPOLATED=${REACH_REDACT_FROM_ENV}",
		"SERVICE=locus-backends",
		"PORTLIKE=4000",
		"HOSTLIKE=host",
		"SHORT=abc",
		"WIDE=localhost-and-more-6",
		"BROKEN! malformed-secret-7 =x",
		`UNCLOSED="unclosed-secret-8`,
	}, "\n") + "\n"
	r := redactorFor([]byte(env), []string{"locus-backends"})
	for in, want := range map[string]string{
		"plain-secret-1":                    "<redacted>",
		"it's quoted-secret-2":              "<redacted>",
		`'it\'s quoted-secret-2'`:           "<redacted>",
		"tab\tdouble-secret-3":              "<redacted>",
		"first-line-secret-4 and more":      "<redacted> and more",
		"x second-line-secret-5 y":          "x <redacted> y",
		"interpolated-from-the-environment": "<redacted>",
		"${REACH_REDACT_FROM_ENV}":          "<redacted>",
		"home-locus-backends-1":             "home-locus-backends-1",
		"http://localhost:4000":             "http://localhost:4000",
		"a host and abc":                    "a <redacted> and abc",
		"localhost-and-more-6 at localhost": "<redacted> at localhost",
		"malformed-secret-7":                "<redacted>",
		"unclosed-secret-8":                 "<redacted>",
		"plain-secret-1plain-secret-1":      "<redacted>",
		"<redacted>":                        "<redacted>",
	} {
		if got := r.text(in); got != want {
			t.Errorf("%q redacts to %q, want %q", in, got, want)
		}
	}
}

// A refusal keeps its code, its payload's keys and the values a variant
// fixes, so it renders the same sentence with its slots redacted; a boot
// refusal keeps the names and modes its sentence reads.
func TestRedactedRefusalsRenderTheSameSentence(t *testing.T) {
	const secret = "slot-secret-value"
	r := redactorFor([]byte("X="+secret+"\nTHEN=started\n"), nil)
	rolled := Refuse("reach_rolled_back", map[string]string{"new": "a", "old": "b", "reason": "why " + secret, "local": "tailnet_node_mismatch"})
	got := r.refusal(rolled)
	if got.Payload["local"] != "tailnet_node_mismatch" || got.Payload["reason"] != "why <redacted>" || got.Code != rolled.Code || got.Class != rolled.Class {
		t.Errorf("redacted to %+v", got)
	}
	if strings.Contains(got.Message(), secret) || got.Message() != strings.Replace(rolled.Message(), secret, "<redacted>", 1) {
		t.Errorf("the sentence reads %q", got.Message())
	}
	edited := r.refusal(Refuse("reach_env_edited", map[string]string{"then": "started", "env": "e"}))
	if edited.Payload["then"] != "started" {
		t.Errorf("a fixed value was redacted: %+v", edited)
	}
	boot := r.refusal(refuse("reach_setting_invalid", map[string]string{"key": "CYFR_PROXY_PORT", "value": secret}))
	if boot.Payload["key"] != "CYFR_PROXY_PORT" || boot.Payload["value"] != "<redacted>" || strings.Contains(boot.Sentence(), secret) {
		t.Errorf("the boot refusal redacted to %+v", boot)
	}
}

// An error leaves the engine with its text redacted and its identity
// whole: errors.Is still finds the sentinel it wraps, errors.As a refusal
// or the lock's refusal, each redacted.
func TestRedactedErrorsKeepTheirIdentity(t *testing.T) {
	const secret = "error-secret-value"
	r := redactorFor([]byte("X="+secret+"\n"), nil)
	wrapped := r.err(fmt.Errorf("reach: read %s: %w", secret, fs.ErrNotExist))
	if !errors.Is(wrapped, fs.ErrNotExist) || strings.Contains(wrapped.Error(), secret) {
		t.Errorf("a wrapped sentinel left as %v", wrapped)
	}
	inner := Refuse("docker_unavailable", map[string]string{"reason": secret})
	var ref *Refusal
	if err := r.err(fmt.Errorf("start: %w", inner)); !errors.As(err, &ref) || ref.Payload["reason"] != "<redacted>" || strings.Contains(err.Error(), secret) {
		t.Errorf("a wrapped refusal left as %v (%+v)", err, ref)
	}
	if err := r.err(inner); err.(*Refusal).Payload["reason"] != "<redacted>" {
		t.Errorf("a refusal left as %v", err)
	}
	var busy *ErrBusy
	if err := r.err(&ErrBusy{Holder: "cyfr up " + secret, PID: 7}); !errors.As(err, &busy) || busy.Holder != "cyfr up <redacted>" || busy.PID != 7 {
		t.Errorf("the lock's refusal left as %v", err)
	}
	plain := errors.New("nothing to hide")
	if r.err(plain) != plain {
		t.Error("an error with nothing to redact was replaced")
	}
	if r.err(nil) != nil {
		t.Error("no error became one")
	}
}

// A refusal whose slot holds a value .env gained during the operation is
// redacted in the journal it writes, the receipt it persists, and every
// answer, a resend's included: the redactor reads .env before and after.
func TestReceiptsAndJournalsArePersistedRedacted(t *testing.T) {
	const secret = "203.0.113.77/33-candidate-secret"
	h := newHome(t)
	h.fake.startStack(t, h.head())
	var journals []string
	h.e.hook = func(point string) {
		switch {
		case point == "env:commit":
			f, err := os.OpenFile(h.e.envPath(), os.O_APPEND|os.O_WRONLY, 0)
			if err != nil {
				t.Fatal(err)
			}
			fmt.Fprintf(f, "CYFR_TRUSTED_PROXY_CIDRS=%s\n", secret)
			f.Close()
		case strings.HasPrefix(point, "journal:"):
			data, _ := os.ReadFile(filepath.Join(h.dir, stateDir, journalFile))
			journals = append(journals, string(data))
		}
	}
	r := h.request(id(1), publicTarget, "")
	rc, err := h.e.Switch(bg, r)
	if rc.Code == "" || !strings.Contains(strings.Join(journals, ""), `\u003credacted\u003e`) {
		t.Fatalf("the switch did not fail on the value it gained: %+v %v\n%s", rc, err, journals)
	}
	texts := append(journals, fmt.Sprintf("%+v", rc), fmt.Sprint(err))
	if ref := rc.Refusal(); ref != nil {
		texts = append(texts, ref.Message())
	}
	again, _, err := h.e.Receipt(r.ID)
	texts = append(texts, fmt.Sprintf("%+v %v", again, err))
	resent, _, err := h.e.Resent(r.ID, r.Content)
	texts = append(texts, fmt.Sprintf("%+v %v", resent, err))
	s, err := h.e.Status(bg)
	texts = append(texts, fmt.Sprintf("%+v %v", s, err))
	for path, data := range h.snapshot() {
		if path != ".env" && !strings.HasPrefix(filepath.Base(path), resolvedFront) {
			texts = append(texts, data)
		}
	}
	for _, text := range texts {
		if strings.Contains(text, secret) {
			t.Errorf("the value .env gained left the engine:\n%s", text)
		}
	}
}

// The watchdog's own lines are redacted with the .env of the directory it
// runs in.
func TestWatchdogLinesAreRedacted(t *testing.T) {
	const secret = "watchdog-secret-option"
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, ".env"), []byte("X=--"+secret+"\n"))
	t.Chdir(dir)
	var stderr bytes.Buffer
	if code := WatchdogMain([]string{"--" + secret}, nil, &bytes.Buffer{}, &stderr); code != 125 || strings.Contains(stderr.String(), secret) || !strings.Contains(stderr.String(), "unknown option") {
		t.Errorf("the watchdog exited %d, saying %q", code, stderr.String())
	}
}

// A command's redactor is the engine's pass: .env's values, of every .env
// the project has held while it was used, and the values the command
// holds, whatever their length; its writer redacts a line at a time, a
// secret split across writes included, flushing at each line break and
// carriage return and at Flush.
func TestCommandRedactorIsTheEnginesPass(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, ".env"), []byte("CYFR_REACH=local\nFIRST=first-env-secret\n"))
	r := NewRedactor(dir)
	if got := r.Text("a first-env-secret at localhost"); got != "a <redacted> at localhost" {
		t.Errorf("the first .env's value reads %q", got)
	}
	writeFile(t, filepath.Join(dir, ".env"), []byte("CYFR_REACH=local\nSECOND=second-env-secret\n"))
	r.Hold("pw", "postgres://u:pw@db/x")
	if got := r.Text("first-env-secret second-env-secret postgres://u:pw@db/x pw local"); got != "<redacted> <redacted> <redacted> <redacted> local" {
		t.Errorf("the redactor reads %q", got)
	}
	var out bytes.Buffer
	w := r.Writer(&out)
	for _, chunk := range []string{"Pulling sec", "ond-env-secret\rDown", "loading 50%\r", "done\nlast first-env-", "secret"} {
		if n, err := w.Write([]byte(chunk)); n != len(chunk) || err != nil {
			t.Fatalf("Write answered %d, %v", n, err)
		}
	}
	if got := out.String(); got != "Pulling <redacted>\rDownloading 50%\rdone\n" {
		t.Errorf("before the flush the writer wrote %q", got)
	}
	if err := w.Flush(); err != nil || out.String() != "Pulling <redacted>\rDownloading 50%\rdone\nlast <redacted>" {
		t.Errorf("after the flush the writer wrote %q (%v)", out.String(), err)
	}
	if err := r.Err(fmt.Errorf("docker: %w", fs.ErrNotExist)); !errors.Is(err, fs.ErrNotExist) {
		t.Errorf("Err lost the error's identity: %v", err)
	}
}
