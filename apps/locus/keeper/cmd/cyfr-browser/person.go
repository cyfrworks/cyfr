// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package main

import (
	"context"
	"encoding/json"
	"errors"
	"regexp"
	"strings"
	"time"
)

// The browser reads pages in its person's own language and time zone, as
// their own browser reports them to CYFR, handed to the driver at its start
// (--person, the vectors' person) and to Chrome as its own: its language by
// its switches (--lang and --accept-lang), and its zone as the TZ of
// Chrome's process, which the driver sets for its child and nowhere else.
// So every window, frame and worker sends the language, exactly as it was
// reported, as its Accept-Language, and reads it as navigator.languages,
// and reads the zone in Intl and Date.
//
// Chrome's switches miss two things, measured on the image's Chromium 156:
// Intl's default locale stays en-US on every surface, and a shared
// worker's navigator.language is en-US. So every target, held at its start
// (page.go), is told the locale before it runs, and a shared worker the
// language beside its user agent (agent.go); one Chrome refuses is not let
// run. Chrome holds a locale override for a renderer process, and a target
// whose process already holds the driver's, the one it ever sets, is told
// so: that is the override in effect. A service worker answers no command
// until it runs (page.go), so it is told after: it sends the language and
// reads the zone from Chrome's own, but the first of its script reads
// Chrome's en-US as its navigator.language and Intl's locale; its override
// refused then is said in the driver's log. Values the person never
// reported are absent and leave Chrome's own: the image's en-US and UTC.
type person struct {
	Locale   string
	TimeZone string
}

// A language is a well-formed tag: a primary subtag of 2 or 3 letters, then
// subtags of 1 to 8 letters and digits, joined by hyphens, a one-character
// subtag never last, at most maxLanguage bytes. A zone is one the zone
// database loads, in the grammar CYFR holds the browser's report to. The
// vectors' person carries both, and Opus.Browser.Frame holds the host to
// the same.
const maxLanguage = 35

var (
	primaryGrammar  = regexp.MustCompile(`\A[A-Za-z]{2,3}\z`)
	subtagGrammar   = regexp.MustCompile(`\A[A-Za-z0-9]{1,8}\z`)
	timeZoneGrammar = regexp.MustCompile(`\A[A-Za-z][A-Za-z0-9_+-]{0,31}(/[A-Za-z0-9][A-Za-z0-9_+-]{0,31}){0,2}\z`)
)

var errBadPerson = errors.New("--person names a language tag and a time zone the zone database loads, as a JSON object of locale and time_zone")

func languageOK(tag string) bool {
	if len(tag) > maxLanguage {
		return false
	}
	parts := strings.Split(tag, "-")
	if !primaryGrammar.MatchString(parts[0]) {
		return false
	}
	for _, part := range parts[1:] {
		if !subtagGrammar.MatchString(part) {
			return false
		}
	}
	return len(parts) == 1 || len(parts[len(parts)-1]) > 1
}

func zoneOK(zone string) bool {
	if !timeZoneGrammar.MatchString(zone) || zone == "Local" {
		return false
	}
	_, err := time.LoadLocation(zone)
	return err == nil
}

// readPerson reads --person's value: nothing for none, else exactly an
// object of locale and time_zone, each once and a string, either absent,
// none null, no other field, each in its grammar, nothing after it.
func readPerson(text string) (person, error) {
	var p person
	if text == "" {
		return p, nil
	}
	in := json.NewDecoder(strings.NewReader(text))
	if open, err := in.Token(); err != nil || open != json.Delim('{') {
		return person{}, errBadPerson
	}
	seen := map[string]bool{}
	for in.More() {
		key, err := in.Token()
		name, ok := key.(string)
		var raw json.RawMessage
		var value string
		if err != nil || !ok || seen[name] || in.Decode(&raw) != nil || string(raw) == "null" ||
			json.Unmarshal(raw, &value) != nil {
			return person{}, errBadPerson
		}
		seen[name] = true
		switch {
		case name == "locale" && languageOK(value):
			p.Locale = value
		case name == "time_zone" && zoneOK(value):
			p.TimeZone = value
		default:
			return person{}, errBadPerson
		}
	}
	if end, err := in.Token(); err != nil || end != json.Delim('}') {
		return person{}, errBadPerson
	}
	if _, err := in.Token(); err == nil {
		return person{}, errBadPerson
	}
	return p, nil
}

// switches are Chrome's own switches for the person's language.
func (p person) switches() []string {
	if p.Locale == "" {
		return nil
	}
	return []string{"--lang=" + p.Locale, "--accept-lang=" + p.Locale}
}

// env is the environment Chrome's process is started with for the
// person's zone.
func (p person) env() []string {
	if p.TimeZone == "" {
		return nil
	}
	return []string{"TZ=" + p.TimeZone}
}

// alreadyInEffect is Chrome's answer to a locale override in a renderer
// process that holds one.
const alreadyInEffect = "Another locale override is already in effect"

// placeIn tells the target of session the person's locale, which Intl
// reads; a process that holds the driver's own already is answered so.
func (p person) placeIn(ctx context.Context, c *cdp, session string) error {
	if p.Locale == "" {
		return nil
	}
	err := c.call(ctx, session, "Emulation.setLocaleOverride", map[string]any{"locale": p.Locale}, nil)
	var refused *cdpError
	if errors.As(err, &refused) && refused.Message == alreadyInEffect {
		return nil
	}
	return err
}
