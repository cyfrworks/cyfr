// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package access

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
	t.Setenv("ACCESS_REDACT_FROM_ENV", "interpolated-from-the-environment")
	env := strings.Join([]string{
		"CYFR_ACCESS=local",
		"CYFR_HOST=localhost",
		"CYFR_PORT=4000",
		"PLAIN=plain-secret-1",
		`QUOTED='it\'s quoted-secret-2'`,
		`DOUBLE="tab\tdouble-secret-3"`,
		"MULTI='first-line-secret-4",
		"second-line-secret-5'",
		"INTERPOLATED=${ACCESS_REDACT_FROM_ENV}",
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
		"${ACCESS_REDACT_FROM_ENV}":         "<redacted>",
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
	rolled := Refuse("access_rolled_back", map[string]string{"new": "a", "old": "b", "reason": "why " + secret, "local": "tailnet_node_mismatch"})
	got := r.refusal(rolled)
	if got.Payload["local"] != "tailnet_node_mismatch" || got.Payload["reason"] != "why <redacted>" || got.Code != rolled.Code || got.Class != rolled.Class {
		t.Errorf("redacted to %+v", got)
	}
	if strings.Contains(got.Message(), secret) || got.Message() != strings.Replace(rolled.Message(), secret, "<redacted>", 1) {
		t.Errorf("the sentence reads %q", got.Message())
	}
	edited := r.refusal(Refuse("access_env_edited", map[string]string{"then": "started", "env": "e"}))
	if edited.Payload["then"] != "started" {
		t.Errorf("a fixed value was redacted: %+v", edited)
	}
	boot := r.refusal(refuse("access_setting_invalid", map[string]string{"key": "CYFR_PROXY_PORT", "value": secret}))
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
	wrapped := r.err(fmt.Errorf("access: read %s: %w", secret, fs.ErrNotExist))
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
// holds, whatever their length; its writer redacts a secret split across
// writes, passing on all but the tail a secret may still be arriving in,
// so progress shows, and the rest at Flush.
func TestCommandRedactorIsTheEnginesPass(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, ".env"), []byte("CYFR_ACCESS=local\nFIRST=first-env-secret\n"))
	r := NewRedactor(dir)
	if got := r.Text("a first-env-secret at localhost"); got != "a <redacted> at localhost" {
		t.Errorf("the first .env's value reads %q", got)
	}
	writeFile(t, filepath.Join(dir, ".env"), []byte("CYFR_ACCESS=local\nSECOND=second-env-secret\n"))
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
	const whole = "Pulling <redacted>\rDownloading 50%\rdone\nlast <redacted>"
	if got := out.String(); !strings.HasPrefix(whole, got) || !strings.Contains(got, "Downloading 50%\r") {
		t.Errorf("before the flush the writer wrote %q", got)
	}
	if err := w.Flush(); err != nil || out.String() != whole {
		t.Errorf("after the flush the writer wrote %q (%v)", out.String(), err)
	}
	if err := r.Err(fmt.Errorf("docker: %w", fs.ErrNotExist)); !errors.Is(err, fs.ErrNotExist) {
		t.Errorf("Err lost the error's identity: %v", err)
	}
}

// A stream is redacted as one text: a value is matched across the writes
// and the lines it spans, wherever the writes split it, spaces and all;
// the writer holds back only an end that is a value's start, so progress
// shows while the stream runs.
func TestRedactedStreamMatchesAcrossWritesAndLines(t *testing.T) {
	dir := t.TempDir()
	const long = "long-secret-value-0123456789"
	writeFile(t, filepath.Join(dir, ".env"), []byte("CYFR_ACCESS=local\nML='q2\nx4'\nSP=' abc '\nLONG="+long+"\n"))
	r := NewRedactor(dir)
	const text = "a q2\nx4 b  abc  c " + long + " d\rprogress 50%\r"
	const want = "a <redacted> b <redacted> c <redacted> d\rprogress 50%\r"
	if got := r.Text(text); got != want {
		t.Fatalf("the text reads %q, want %q", got, want)
	}
	streamed := func(chunks ...string) string {
		var out bytes.Buffer
		w := r.Writer(&out)
		for _, c := range chunks {
			if _, err := w.Write([]byte(c)); err != nil {
				t.Fatal(err)
			}
		}
		if err := w.Flush(); err != nil {
			t.Fatal(err)
		}
		return out.String()
	}
	for i := 0; i <= len(text); i++ {
		if got := streamed(text[:i], text[i:]); got != want {
			t.Errorf("split at %d the stream showed %q", i, got)
		}
	}
	bytewise := make([]string, len(text))
	for i := range text {
		bytewise[i] = text[i : i+1]
	}
	if got := streamed(bytewise...); got != want {
		t.Errorf("a byte at a time the stream showed %q", got)
	}
	var out bytes.Buffer
	w := r.Writer(&out)
	progress := "Downloading 10%\r" + strings.Repeat(".", len(long)-1)
	if _, err := w.Write([]byte(progress)); err != nil {
		t.Fatal(err)
	}
	if got := out.String(); got != progress {
		t.Errorf("with no value's start at its end, the stream showed %q, want all of it", got)
	}
	arriving := long[:len(long)-1]
	if _, err := w.Write([]byte("\rDownloading 20%\r" + arriving)); err != nil {
		t.Fatal(err)
	}
	if got := out.String(); got != progress+"\rDownloading 20%\r" || string(w.buf) != arriving {
		t.Errorf("with a value arriving, the stream showed %q and held %q", got, w.buf)
	}
}

// Overlapping occurrences hold nothing back beyond the most of a value
// still arriving: a stream of hyphens past a '----' value passes on all
// but its last bytes at each write, never more than the longest value's
// length less one, and reads as the whole stream does.
func TestRedactedStreamPassesProgressWhileOccurrencesOverlap(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, ".env"), []byte("CYFR_ACCESS=local\nSEPARATOR='----'\n"))
	r := NewRedactor(dir)
	var out bytes.Buffer
	w := r.Writer(&out)
	const chunk = "--------------------------------"
	for i := 0; i < 8; i++ {
		if _, err := w.Write([]byte(chunk)); err != nil {
			t.Fatal(err)
		}
		// The longest value is '----' as written, six bytes.
		if len(w.buf) > 5 {
			t.Fatalf("after %d bytes the writer holds %d, more than five", (i+1)*len(chunk), len(w.buf))
		}
	}
	if out.Len() == 0 {
		t.Errorf("no progress after %d bytes", 8*len(chunk))
	}
	if err := w.Flush(); err != nil {
		t.Fatal(err)
	}
	if got, want := out.String(), r.Text(strings.Repeat(chunk, 8)); got != want {
		t.Fatalf("streamed %q, want %q", got, want)
	}
}

// A value that overlaps itself is redacted across a cut as the whole
// stream reads it: the bytes held back keep the cover an occurrence
// already passed on gives them, and one run of redacted bytes is said
// once, wherever the writes split it.
func TestRedactedStreamKeepsTheCoverOfAnOccurrencePassedOn(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, ".env"), []byte("CYFR_ACCESS=local\nPERIODIC=abab\n"))
	r := NewRedactor(dir)
	const text = "xabababy ababab z"
	want := r.Text(text)
	if want != "x<redacted>y <redacted> z" {
		t.Fatalf("the text reads %q", want)
	}
	for i := 0; i <= len(text); i++ {
		for j := i; j <= len(text); j++ {
			var out bytes.Buffer
			w := r.Writer(&out)
			for _, c := range []string{text[:i], text[i:j], text[j:]} {
				if _, err := w.Write([]byte(c)); err != nil {
					t.Fatal(err)
				}
			}
			if err := w.Flush(); err != nil {
				t.Fatal(err)
			}
			if got := out.String(); got != want {
				t.Fatalf("split at %d and %d the stream showed %q, want %q", i, j, got, want)
			}
		}
	}
}

// A value of white space alone is not redacted, it holds nothing to keep
// secret, unless the command holds it; one with anything else in it is
// redacted whole, its white space included.
func TestOnlyAWhitespaceOnlyValueIsLeftUnredacted(t *testing.T) {
	for _, v := range []string{"    ", "\t\t\t\t", "\n\n\n\n"} {
		r := redactorFor([]byte("SECRET='"+v+"'\n"), nil)
		if got := r.text(v); got != v {
			t.Errorf("the whitespace-only value %q reads %q", v, got)
		}
		if got := r.holding([]string{v}).text(v); got != redactedText {
			t.Errorf("the held whitespace-only value %q reads %q", v, got)
		}
	}
	for _, v := range []string{" abc ", "\ta\t\t", " \nq ", " a  "} {
		r := redactorFor([]byte("SECRET='"+v+"'\n"), nil)
		if got := r.text(v); got != redactedText {
			t.Errorf("the value %q reads %q", v, got)
		}
	}
}
