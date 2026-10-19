// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package reach

import (
	"bytes"
	"errors"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"

	"gopkg.in/yaml.v3"
)

// redactedText replaces a .env value in what leaves the engine.
const redactedText = "<redacted>"

// redactMin is the shortest value redacted, in characters.
const redactMin = 4

// redactor is the engine's last pass over what leaves it: every error,
// receipt, status and log line, and every receipt and journal it writes,
// has each occurrence of each value .env assigns to a name that is not a
// head key replaced by <redacted>: the value as written, quotes and all,
// as compose reads it, and each line of either, whatever is
// redactMin characters or longer. A value is read leniently: a line
// compose cannot read still gives its right-hand side and its words. The
// head keys' values are not secrets, and the engine names them in every
// sentence by design; nor are the names the configuration itself
// publishes (the project's, its services') or the engine's own words (its
// services, the modes, the names of the settings the boot reads): an
// occurrence inside one of those is kept, and one that reaches past it is
// redacted whole. Only free text is redacted: a refusal's code, its
// payload keys and the values a variant fixes are kept, so the sentence
// it renders is the same. A value is matched as it reads: one docker
// prints reformatted, re-indented or re-wrapped, is not matched.
type redactor struct {
	secrets []string
	keep    []string
}

// redactor is the project's: its .env as it reads now, and the names its
// configuration publishes.
func (e *Engine) redactor() *redactor {
	data, _ := os.ReadFile(e.envPath())
	return redactorFor(data, e.publishedNames())
}

// publishedNames are the names the engine says that no .env value hides:
// the project's, then its compose files' services.
func (e *Engine) publishedNames() []string { return publishedNames(e.dir) }

func publishedNames(dir string) []string {
	names := []string{projectName(dir)}
	files, _ := defaultFileSet(dir)
	for _, f := range files {
		data, err := os.ReadFile(filepath.Join(dir, f))
		if err != nil {
			continue
		}
		var doc struct {
			Services map[string]any `yaml:"services"`
		}
		if yaml.Unmarshal(data, &doc) == nil {
			for name := range doc.Services {
				names = append(names, name)
			}
		}
	}
	return names
}

// engineWords are the names and words the engine itself says: its
// services, the modes, the settings the boot reads by name.
var engineWords = slices.Concat([]string{cyfrService, serveService, buildsService, ModeLocal, ModeTailnet, ModePublic, "localhost", redactedText}, readKeys)

// redactorFor is the redactor of the .env text data, keeping names.
func redactorFor(data []byte, names []string) *redactor {
	r := &redactor{keep: slices.Concat(engineWords, names)}
	head := map[string]bool{}
	for _, k := range headKeys() {
		head[k] = true
	}
	add := func(to *[]string, texts ...string) {
		for _, t := range texts {
			*to = append(*to, redactable(t)...)
		}
	}
	text := string(data)
	stmts, _ := scanDotenv(text, true, func(at int, line string) {
		// A statement compose cannot read: its right-hand side as
		// written, unquoted too, the line itself and each of its words.
		key, rhs, found := strings.Cut(line, "=")
		if k, r, ok := strings.Cut(line, ":"); ok && (!found || len(k) < len(key)) {
			key, rhs, found = k, r, true
		}
		key = strings.TrimSpace(cutExport(strings.TrimSpace(key)))
		to := &r.secrets
		if head[key] {
			to = &r.keep
		}
		if found {
			rhs = strings.TrimSpace(rhs)
			add(to, rhs, strings.Trim(rhs, `"'`))
		}
		if to == &r.secrets {
			add(to, append([]string{line}, strings.Fields(line)...)...)
		}
	})
	d, _ := parseDotenv(data, composeEnv)
	for _, st := range stmts {
		to := &r.secrets
		if head[st.key] {
			to = &r.keep
		}
		add(to, st.raw, st.text, strings.Trim(strings.TrimSpace(st.raw), `"'`))
		if v, ok := st.evaluated(d); ok {
			add(to, v)
		}
	}
	// A value that is also a head value or a published name is said by
	// design.
	r.secrets = slices.DeleteFunc(r.secrets, func(s string) bool { return slices.Contains(r.keep, s) })
	slices.SortFunc(r.secrets, func(a, b string) int { return len(b) - len(a) })
	r.secrets = slices.Compact(r.secrets)
	return r
}

// redactable are the texts a value is redacted as: the value exactly as
// it reads, spaces and all, and each line of a multi-line one, each
// redactMin characters or longer and not white space alone, which holds
// nothing to keep secret.
func redactable(v string) []string {
	var out []string
	for _, piece := range append([]string{v}, strings.Split(v, "\n")...) {
		if runes(piece) >= redactMin && strings.TrimSpace(piece) != "" {
			out = append(out, piece)
		}
	}
	return out
}

// evaluated is the value compose gives the statement's name in d when d
// read it and it is the name's last statement, or its value interpolated
// from the environment alone.
func (st statement) evaluated(d *dotenv) (string, bool) {
	if st.inherit {
		v, ok := d.env[st.key]
		return v, ok
	}
	v, err := st.value(func(k string) (string, bool) {
		if v, ok := composeEnv(k); ok {
			return v, true
		}
		v, ok := d.env[k]
		return v, ok
	})
	return v, err == nil
}

// holding is r with values a command holds redacted too, whatever their
// length and whatever name they equal.
func (r *redactor) holding(values []string) *redactor {
	out := &redactor{secrets: slices.Clone(r.secrets), keep: slices.DeleteFunc(slices.Clone(r.keep), func(k string) bool { return slices.Contains(values, k) })}
	for _, v := range values {
		if v == "" {
			continue
		}
		out.secrets = append(out.secrets, v)
		out.secrets = append(out.secrets, redactable(v)...)
	}
	slices.SortFunc(out.secrets, func(a, b string) int { return len(b) - len(a) })
	out.secrets = slices.Compact(out.secrets)
	return out
}

// with is r and o together: what either redacts is redacted.
func (r *redactor) with(o *redactor) *redactor {
	if o == nil {
		return r
	}
	out := &redactor{secrets: slices.Concat(r.secrets, o.secrets), keep: slices.Concat(r.keep, o.keep)}
	out.secrets = slices.DeleteFunc(out.secrets, func(s string) bool { return slices.Contains(out.keep, s) })
	slices.SortFunc(out.secrets, func(a, b string) int { return len(b) - len(a) })
	out.secrets = slices.Compact(out.secrets)
	return out
}

// text is s with every occurrence of a secret that does not lie wholly
// inside an occurrence of a kept name replaced, overlapping and adjoining
// occurrences as one.
func (r *redactor) text(s string) string {
	open := false
	return render([]byte(s), r.cover([]byte(s), 0), &open)
}

// cover marks the bytes of s an occurrence of a secret covers, one that
// lies wholly inside an occurrence of a kept name aside, and the first
// pre bytes, which an occurrence already passed on covers; nil for none.
func (r *redactor) cover(s []byte, pre int) []bool {
	var cover []bool
	if pre > 0 {
		cover = make([]bool, len(s))
		for n := range min(pre, len(s)) {
			cover[n] = true
		}
	}
	if r == nil || len(r.secrets) == 0 || len(s) == 0 {
		return cover
	}
	type span struct{ from, to int }
	var kept []span
	for _, k := range r.keep {
		for i := 0; k != "" && i <= len(s); {
			j := bytes.Index(s[i:], []byte(k))
			if j < 0 {
				break
			}
			kept = append(kept, span{i + j, i + j + len(k)})
			i += j + 1
		}
	}
	for _, secret := range r.secrets {
		for i := 0; i <= len(s); {
			j := bytes.Index(s[i:], []byte(secret))
			if j < 0 {
				break
			}
			from, to := i+j, i+j+len(secret)
			if !slices.ContainsFunc(kept, func(k span) bool { return k.from <= from && to <= k.to }) {
				if cover == nil {
					cover = make([]bool, len(s))
				}
				for n := from; n < to; n++ {
					cover[n] = true
				}
			}
			i = from + 1
		}
	}
	return cover
}

// render is s with each run of covered bytes said as <redacted> once, a
// run that continues one already said (open) not said again; open is
// left saying whether s ends inside a run.
func render(s []byte, cover []bool, open *bool) string {
	if cover == nil {
		if len(s) > 0 {
			*open = false
		}
		return string(s)
	}
	var b strings.Builder
	for i, c := range s {
		switch {
		case !cover[i]:
			b.WriteByte(c)
			*open = false
		case !*open:
			b.WriteString(redactedText)
			*open = true
		}
	}
	return b.String()
}

// pending is the length of the longest suffix of s that is a proper
// prefix of a secret, the most of one that may still be arriving: at
// most the longest secret's length less one.
func (r *redactor) pending(s []byte) int {
	longest := 0
	for _, secret := range r.secrets {
		for from := max(len(s)-len(secret)+1, 0); from < len(s); from++ {
			if len(s)-from <= longest {
				break
			}
			if strings.HasPrefix(secret, string(s[from:])) {
				longest = len(s) - from
				break
			}
		}
	}
	return longest
}

func (r *redactor) texts(s []string) []string {
	if s == nil {
		return nil
	}
	out := make([]string, len(s))
	for i, t := range s {
		out[i] = r.text(t)
	}
	return out
}

// fixedKeys are the payload keys of code whose values select its
// sentence, which are kept: those a variant of an engine row fixes, a
// join's id, and the names and modes a boot refusal's sentence reads.
func fixedKeys(code string) map[string]bool {
	fixed := map[string]bool{"join_id": true}
	row, ok := refusalRows[code]
	if !ok {
		fixed["key"], fixed["mode"], fixed["needs"] = true, true, true
	}
	for _, v := range row.Variants {
		for k := range v.Fixed {
			fixed[k] = true
		}
	}
	return fixed
}

// payload is a refusal's payload with its free text redacted.
func (r *redactor) payload(code string, p map[string]string) map[string]string {
	if p == nil {
		return nil
	}
	fixed := fixedKeys(code)
	out := make(map[string]string, len(p))
	for k, v := range p {
		if fixed[k] {
			out[k] = v
		} else {
			out[k] = r.text(v)
		}
	}
	return out
}

func (r *redactor) refusal(ref *Refusal) *Refusal {
	if ref == nil {
		return nil
	}
	return &Refusal{Code: ref.Code, Class: ref.Class, Payload: r.payload(ref.Code, ref.Payload)}
}

// receipt is rc with its refusal's free text redacted: a receipt that
// carries no code holds data in its payload (a join's machine), which is
// kept.
func (r *redactor) receipt(rc Receipt) Receipt {
	if rc.Code != "" {
		rc.Payload = r.payload(rc.Code, rc.Payload)
	}
	rc.Observed = r.texts(rc.Observed)
	return rc
}

func (r *redactor) receipts(rcs []Receipt) []Receipt {
	if rcs == nil {
		return nil
	}
	out := make([]Receipt, len(rcs))
	for i, rc := range rcs {
		out[i] = r.receipt(rc)
	}
	return out
}

// status is s with its free text redacted: the head and its words are
// the head keys' and the engine's.
func (r *redactor) status(s Status) Status {
	s.HeadErr = r.err(s.HeadErr)
	if s.Unfinished != nil {
		u := r.receipt(*s.Unfinished)
		s.Unfinished = &u
	}
	if s.Last != nil {
		l := r.receipt(*s.Last)
		s.Last = &l
	}
	s.Health = r.texts(s.Health)
	if s.Containers != nil {
		cs := make([]Container, len(s.Containers))
		for i, c := range s.Containers {
			cs[i] = Container{Service: r.text(c.Service), Name: r.text(c.Name), State: r.text(c.State)}
		}
		s.Containers = cs
	}
	return s
}

// err is err as it leaves the engine: a refusal or the lock's refusal
// with its free text redacted; any other error whose text holds a secret,
// or whose chain holds a refusal, as an error of the redacted text that
// errors.Is and errors.As still read, a refusal in its chain answered
// redacted.
func (r *redactor) err(err error) error {
	switch v := err.(type) {
	case nil:
		return nil
	case *Refusal:
		if v == nil {
			return err
		}
		return r.refusal(v)
	case *ErrBusy:
		if v == nil {
			return err
		}
		b := *v
		b.Holder = r.text(v.Holder)
		return &b
	}
	var ref *Refusal
	var busy *ErrBusy
	msg := r.text(err.Error())
	if msg == err.Error() && !errors.As(err, &ref) && !errors.As(err, &busy) {
		return err
	}
	return &redactedError{msg: msg, err: err, r: r}
}

// redactedError is an error whose text was redacted.
type redactedError struct {
	msg string
	err error
	r   *redactor
}

func (e *redactedError) Error() string { return e.msg }

func (e *redactedError) Is(target error) bool { return errors.Is(e.err, target) }

func (e *redactedError) As(target any) bool {
	switch t := target.(type) {
	case **Refusal:
		var ref *Refusal
		if !errors.As(e.err, &ref) {
			return false
		}
		*t = e.r.refusal(ref)
		return true
	case **ErrBusy:
		var busy *ErrBusy
		if !errors.As(e.err, &busy) {
			return false
		}
		*t = e.r.err(busy).(*ErrBusy)
		return true
	}
	return errors.As(e.err, target)
}

// Redactor is the engine's redaction pass (redactor) for a command's own
// text: what a docker call it ran through the engine's runner (Docker)
// wrote, which the engine never reads, and what it says of it. It redacts
// the values of every .env it has seen the project hold, read afresh at
// each use, so a .env a command puts in place is redacted as well as the
// one it replaced, and the values the command holds itself (Hold).
type Redactor struct {
	dir  string
	mu   sync.Mutex
	seen map[string]bool
	base *redactor
	held []string
	r    *redactor
}

// NewRedactor is the redactor of the project at projectDir.
func NewRedactor(projectDir string) *Redactor {
	if abs, err := filepath.Abs(projectDir); err == nil {
		projectDir = abs
	}
	return &Redactor{dir: projectDir, seen: map[string]bool{}, base: &redactor{keep: slices.Clone(engineWords)}}
}

// Redactor is the redactor of the engine's project.
func (e *Engine) Redactor() *Redactor { return NewRedactor(e.dir) }

// Hold adds values the command holds, a database URL or a keyring's keys,
// redacted as .env's are, whatever their length.
func (r *Redactor) Hold(values ...string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.held = append(r.held, values...)
	r.r = nil
}

// current is the pass with .env as it reads now folded in.
func (r *Redactor) current() *redactor {
	r.mu.Lock()
	defer r.mu.Unlock()
	data, _ := os.ReadFile(filepath.Join(r.dir, ".env"))
	if sum := sha256Hex(data); !r.seen[sum] {
		r.seen[sum] = true
		r.base = r.base.with(redactorFor(data, publishedNames(r.dir)))
		r.r = nil
	}
	if r.r == nil {
		r.r = r.base.holding(r.held)
	}
	return r.r
}

// Text is s with every secret replaced by <redacted>.
func (r *Redactor) Text(s string) string { return r.current().text(s) }

// Err is err with its text redacted, errors.Is and errors.As still
// reading it (redactor.err).
func (r *Redactor) Err(err error) error { return r.current().err(err) }

// Writer is w behind the pass: what is written reaches w redacted as the
// whole stream would read (redactor.text), a value matched across the
// writes and lines it spans, overlapping occurrences included. Every
// whole occurrence is redacted as it arrives; only the longest end that
// is the start of a value is held back, at most the longest value's
// length less one byte however occurrences overlap, so progress still
// shows; the rest goes at Flush.
func (r *Redactor) Writer(w io.Writer) *RedactedWriter { return &RedactedWriter{r: r, w: w} }

// RedactedWriter is a writer behind a Redactor (Redactor.Writer).
type RedactedWriter struct {
	r   *Redactor
	w   io.Writer
	mu  sync.Mutex
	buf []byte
	// covered is how many of buf's first bytes an occurrence already
	// passed on covers, and open whether the last byte passed on was
	// redacted: the held bytes keep their cover, and a run of redacted
	// bytes across a cut is said once.
	covered int
	open    bool
}

func (w *RedactedWriter) Write(p []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.buf = append(w.buf, p...)
	r := w.r.current()
	if err := w.pass(r, len(w.buf)-r.pending(w.buf)); err != nil {
		return 0, err
	}
	return len(p), nil
}

// pass redacts buf as a whole and passes on its first cut bytes, keeping
// the rest with the cover an occurrence passed on gives them.
func (w *RedactedWriter) pass(r *redactor, cut int) error {
	if cut <= 0 {
		return nil
	}
	cover := r.cover(w.buf, w.covered)
	done := render(w.buf[:cut], cover, &w.open)
	w.covered = 0
	for cover != nil && cut+w.covered < len(w.buf) && cover[cut+w.covered] {
		w.covered++
	}
	w.buf = append(w.buf[:0], w.buf[cut:]...)
	_, err := io.WriteString(w.w, done)
	return err
}

// Flush passes on what is held, redacted, at the end of the stream.
func (w *RedactedWriter) Flush() error {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.pass(w.r.current(), len(w.buf))
}
