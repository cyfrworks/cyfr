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
)

// The browser reads pages in its person's own language and time zone, as
// their own browser reports them to CYFR (Aqua.Language, Aqua.Day), handed
// to the driver at its start (--person, the vectors' person): every window
// and every frame of another process is told the time zone and the locale
// before it runs, which a page's Intl and Date read, and every target, a
// worker among them, sends the language as its Accept-Language and reads
// it as navigator.language and navigator.languages, from the one override
// that names the browser (agent.go). A value the person has never reported
// is absent and leaves Chrome's own: the image's en-US and UTC.
type person struct {
	Locale   string `json:"locale,omitempty"`
	TimeZone string `json:"time_zone,omitempty"`
}

// A language tag and an IANA zone's name, in the grammar CYFR holds the
// browser's report to (Prima.TinctureWire.locale?/1 and time_zone?/1).
var (
	localeGrammar   = regexp.MustCompile(`\A[A-Za-z]{2,8}(-[A-Za-z0-9]{1,8}){0,7}\z`)
	timeZoneGrammar = regexp.MustCompile(`\A[A-Za-z][A-Za-z0-9_+-]{0,31}(/[A-Za-z0-9][A-Za-z0-9_+-]{0,31}){0,2}\z`)
)

var errBadPerson = errors.New("--person names a language and a time zone, as a JSON object of locale and time_zone, each in its grammar")

// readPerson reads --person's value: nothing for none, else exactly an
// object of the two, each present one in its grammar.
func readPerson(text string) (person, error) {
	var p person
	if text == "" {
		return p, nil
	}
	var fields map[string]json.RawMessage
	in := json.NewDecoder(strings.NewReader(text))
	in.DisallowUnknownFields()
	if in.Decode(&p) != nil || in.More() || json.Unmarshal([]byte(text), &fields) != nil {
		return person{}, errBadPerson
	}
	for name, value := range fields {
		var s string
		if json.Unmarshal(value, &s) != nil || s == "" {
			return person{}, errBadPerson
		}
		if (name == "locale" && (len(s) > 64 || !localeGrammar.MatchString(s))) ||
			(name == "time_zone" && !timeZoneGrammar.MatchString(s)) {
			return person{}, errBadPerson
		}
	}
	return p, nil
}

// languages are the person's languages as navigator.languages lists them:
// the tag, then its language alone after it when the tag names more, as
// Chrome lists its own. Chrome takes them, comma-separated, as the
// override's acceptLanguage, and weighs each after the first in the
// Accept-Language it sends (the vectors' accept_language).
func (p person) languages() []string {
	if p.Locale == "" {
		return nil
	}
	language, _, more := strings.Cut(p.Locale, "-")
	if !more {
		return []string{p.Locale}
	}
	return []string{p.Locale, language}
}

// placeIn tells the target of session to read pages in the person's time
// zone and locale; one Chrome refuses is refused.
func (p person) placeIn(ctx context.Context, c *cdp, session string) error {
	if p.TimeZone != "" {
		if err := c.call(ctx, session, "Emulation.setTimezoneOverride", map[string]any{"timezoneId": p.TimeZone}, nil); err != nil {
			return err
		}
	}
	if p.Locale != "" {
		return c.call(ctx, session, "Emulation.setLocaleOverride", map[string]any{"locale": p.Locale}, nil)
	}
	return nil
}

// check has Chrome take the person's time zone and locale in a blank
// target of its own, which it closes: one Chrome refuses is said at the
// start, not met by every window after.
func (p person) check(ctx context.Context, c *cdp) error {
	if p == (person{}) {
		return nil
	}
	var target struct {
		TargetID string `json:"targetId"`
	}
	if err := c.call(ctx, "", "Target.createTarget", map[string]any{"url": "about:blank"}, &target); err != nil {
		return err
	}
	defer func() {
		_ = c.call(context.WithoutCancel(ctx), "", "Target.closeTarget", map[string]any{"targetId": target.TargetID}, nil)
	}()
	var attached struct {
		SessionID string `json:"sessionId"`
	}
	if err := c.call(ctx, "", "Target.attachToTarget", map[string]any{"targetId": target.TargetID, "flatten": true}, &attached); err != nil {
		return err
	}
	return p.placeIn(ctx, c, attached.SessionID)
}
