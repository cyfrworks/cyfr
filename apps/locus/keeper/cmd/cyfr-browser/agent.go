// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package main

import (
	"context"
	"strings"
)

// The headless shell names itself HeadlessChrome: in its User-Agent, its
// Sec-CH-UA client hints and navigator.userAgentData's brands, which a
// site may read to turn a headless browser away. Every target the driver
// attaches, a window, a frame of another process, a worker or a window a
// page opened, is told to name itself as the Chromium it is instead, its
// own version and platform, before it runs: the User-Agent Chromium
// answers with Chrome in place of HeadlessChrome, and Chromium as its one
// brand. Nothing else a page reads is changed: navigator.webdriver,
// plugins, screen and the rest are the shell's own.

// version is Chrome's answer to Browser.getVersion.
type version struct {
	Product   string `json:"product"`
	UserAgent string `json:"userAgent"`
}

// agentOf is the override every target is given, for a browser of
// version v on the machine arch (runtime.GOARCH); nil when v names no
// version, so nothing is changed.
func agentOf(v version, arch string) map[string]any {
	_, full, found := strings.Cut(v.Product, "/")
	if !found || full == "" || v.UserAgent == "" {
		return nil
	}
	major, _, _ := strings.Cut(full, ".")
	architecture := map[string]string{"amd64": "x86", "arm64": "arm"}[arch]
	return map[string]any{
		"userAgent": strings.Replace(v.UserAgent, "HeadlessChrome/", "Chrome/", 1),
		"userAgentMetadata": map[string]any{
			"brands":          []map[string]string{{"brand": "Chromium", "version": major}},
			"fullVersionList": []map[string]string{{"brand": "Chromium", "version": full}},
			"fullVersion":     full,
			"platform":        "Linux",
			"platformVersion": "",
			"architecture":    architecture,
			"bitness":         "64",
			"model":           "",
			"mobile":          false,
			"wow64":           false,
		},
	}
}

// name tells the target of session, of kind (a target type), to name
// itself by the browser's agent: a worker through its network, every
// other target through its emulation, which its navigator reads too.
func (b *browser) name(ctx context.Context, session, kind string) error {
	if b.agent == nil {
		return nil
	}
	method := "Emulation.setUserAgentOverride"
	if strings.HasSuffix(kind, "worker") {
		method = "Network.setUserAgentOverride"
	}
	return b.c.call(ctx, session, method, b.agent, nil)
}
