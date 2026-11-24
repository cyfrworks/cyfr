// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
)

// The headless shell names itself HeadlessChrome: in its User-Agent, its
// Sec-CH-UA client hints and navigator.userAgentData's brands, which a
// site may read to turn a headless browser away. At its start the driver
// reads what the shell says of itself, its User-Agent and its client
// hints as a page of the reserved origin reads them, and every target it
// attaches, a window, a frame of another process, a worker or a window a
// page opened, is told before it runs to say the same with the
// HeadlessChrome entry taken out: Chrome in place of HeadlessChrome in the
// User-Agent, and the shell's own brand and full-version lists without
// their HeadlessChrome entry, nothing else added, removed or reordered. A
// target Chrome refuses to name that way is not let run (page.go). Nothing
// else a page reads is changed by it.

// headless is the product name the shell gives itself.
const headless = "HeadlessChrome"

// version is Chrome's answer to Browser.getVersion.
type version struct {
	Product   string `json:"product"`
	UserAgent string `json:"userAgent"`
}

// brand is one entry of a brand or full-version list.
type brand struct {
	Brand   string `json:"brand"`
	Version string `json:"version"`
}

// hints are the client hints a page reads of the browser, as
// navigator.userAgentData.getHighEntropyValues answers them.
type hints struct {
	Brands          []brand  `json:"brands"`
	FullVersionList []brand  `json:"fullVersionList"`
	UAFullVersion   string   `json:"uaFullVersion"`
	Platform        string   `json:"platform"`
	PlatformVersion string   `json:"platformVersion"`
	Architecture    string   `json:"architecture"`
	Bitness         string   `json:"bitness"`
	Model           string   `json:"model"`
	Mobile          bool     `json:"mobile"`
	Wow64           bool     `json:"wow64"`
	FormFactors     []string `json:"formFactors"`
}

// readHints is what a page of the reserved origin evaluates to read the
// shell's client hints.
const readHints = `navigator.userAgentData.getHighEntropyValues(["architecture", "bitness", "formFactors",
	"fullVersionList", "model", "platformVersion", "uaFullVersion", "wow64"]).then(JSON.stringify)`

// agentOf is the override every target is given: the shell's own
// User-Agent with Chrome in place of HeadlessChrome, and its own client
// hints with their HeadlessChrome entries taken out.
func agentOf(userAgent string, own hints) (map[string]any, error) {
	if userAgent == "" || len(own.Brands) == 0 || len(own.FullVersionList) == 0 {
		return nil, errors.New("Chrome named no User-Agent or brands")
	}
	without := func(list []brand) []brand {
		kept := []brand{}
		for _, b := range list {
			if b.Brand != headless {
				kept = append(kept, b)
			}
		}
		return kept
	}
	formFactors := own.FormFactors
	if formFactors == nil {
		formFactors = []string{}
	}
	return map[string]any{
		"userAgent": strings.Replace(userAgent, headless+"/", "Chrome/", 1),
		"userAgentMetadata": map[string]any{
			"brands":          without(own.Brands),
			"fullVersionList": without(own.FullVersionList),
			"fullVersion":     own.UAFullVersion,
			"platform":        own.Platform,
			"platformVersion": own.PlatformVersion,
			"architecture":    own.Architecture,
			"bitness":         own.Bitness,
			"model":           own.Model,
			"mobile":          own.Mobile,
			"wow64":           own.Wow64,
			"formFactors":     formFactors,
		},
	}, nil
}

// ownAgent reads the shell's client hints in a target of its own, a blank
// page of the reserved origin the driver answers itself, so nothing
// leaves the box, and closes it; and answers the override (agentOf).
func ownAgent(ctx context.Context, c *cdp, userAgent string) (map[string]any, error) {
	var target struct {
		TargetID string `json:"targetId"`
	}
	if err := c.call(ctx, "", "Target.createTarget", map[string]any{"url": "about:blank"}, &target); err != nil {
		return nil, err
	}
	defer func() {
		_ = c.call(context.WithoutCancel(ctx), "", "Target.closeTarget", map[string]any{"targetId": target.TargetID}, nil)
	}()
	var attached struct {
		SessionID string `json:"sessionId"`
	}
	if err := c.call(ctx, "", "Target.attachToTarget", map[string]any{"targetId": target.TargetID, "flatten": true}, &attached); err != nil {
		return nil, err
	}
	session := attached.SessionID
	events := c.watch(session, func(method string, _ json.RawMessage) bool {
		return method == "Fetch.requestPaused" || method == "Page.loadEventFired"
	})
	defer c.unwatch(events)
	for _, step := range []struct {
		method string
		params any
	}{{"Page.enable", nil}, {"Fetch.enable", fetchPatterns}} {
		if err := c.call(ctx, session, step.method, step.params, nil); err != nil {
			return nil, err
		}
	}
	// The navigation answers only once its paused request is fulfilled, so
	// it runs beside the loop that fulfils it.
	navigated := make(chan error, 1)
	go func() {
		navigated <- c.call(ctx, session, "Page.navigate", map[string]any{"url": reservedOrigin + "/"}, nil)
	}()
	for loaded := false; !loaded; {
		ev, err := events.next(ctx)
		if err != nil {
			return nil, err
		}
		switch ev.method {
		case "Fetch.requestPaused":
			var paused struct {
				RequestID string `json:"requestId"`
			}
			_ = json.Unmarshal(ev.params, &paused)
			if err := c.call(ctx, session, "Fetch.fulfillRequest", map[string]any{"requestId": paused.RequestID,
				"responseCode": 200, "responseHeaders": []map[string]string{{"name": "Content-Type", "value": "text/html"}},
				"body": ""}, nil); err != nil {
				return nil, err
			}
		case "Page.loadEventFired":
			loaded = true
		}
	}
	if err := <-navigated; err != nil {
		return nil, err
	}
	var evaluated struct {
		Result struct {
			Value string `json:"value"`
		} `json:"result"`
		ExceptionDetails *struct {
			Text string `json:"text"`
		} `json:"exceptionDetails"`
	}
	if err := c.call(ctx, session, "Runtime.evaluate", map[string]any{"expression": readHints, "awaitPromise": true,
		"returnByValue": true}, &evaluated); err != nil {
		return nil, err
	}
	if evaluated.ExceptionDetails != nil {
		return nil, fmt.Errorf("Chrome did not read its client hints (%s)", evaluated.ExceptionDetails.Text)
	}
	var own hints
	if err := json.Unmarshal([]byte(evaluated.Result.Value), &own); err != nil {
		return nil, fmt.Errorf("Chrome's client hints do not read: %w", err)
	}
	return agentOf(userAgent, own)
}

// name tells the target of session, of kind (a target type), to name
// itself by the browser's agent: a worker through its network, every
// other target through its emulation, which its navigator reads too; and
// every target its person's locale (person.go).
func (b *browser) name(ctx context.Context, session, kind string) error {
	if b.agent == nil {
		return nil
	}
	method := "Emulation.setUserAgentOverride"
	if strings.HasSuffix(kind, "worker") {
		method = "Network.setUserAgentOverride"
	}
	if err := b.c.call(ctx, session, method, b.agent, nil); err != nil {
		return err
	}
	return b.person.placeIn(ctx, b.c, session)
}
