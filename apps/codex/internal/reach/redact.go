// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package reach

import (
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strings"

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
// it renders is the same.
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
// the project's, its compose files' services, the engine's own services
// and words.
func (e *Engine) publishedNames() []string {
	names := []string{e.project}
	files, _ := e.defaultFiles()
	for _, f := range files {
		data, err := os.ReadFile(filepath.Join(e.dir, f))
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
			for _, piece := range append([]string{t}, strings.Split(t, "\n")...) {
				if piece = strings.TrimSpace(piece); runes(piece) >= redactMin {
					*to = append(*to, piece)
				}
			}
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
// inside an occurrence of a kept name replaced, overlapping occurrences
// as one.
func (r *redactor) text(s string) string {
	if r == nil || len(r.secrets) == 0 || s == "" {
		return s
	}
	type span struct{ from, to int }
	var kept []span
	for _, k := range r.keep {
		for i := 0; k != "" && i <= len(s); {
			j := strings.Index(s[i:], k)
			if j < 0 {
				break
			}
			kept = append(kept, span{i + j, i + j + len(k)})
			i += j + 1
		}
	}
	var cover []bool
	for _, secret := range r.secrets {
		for i := 0; i <= len(s); {
			j := strings.Index(s[i:], secret)
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
	if cover == nil {
		return s
	}
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		if !cover[i] {
			b.WriteByte(s[i])
			continue
		}
		b.WriteString(redactedText)
		for i+1 < len(s) && cover[i+1] {
			i++
		}
	}
	return b.String()
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
