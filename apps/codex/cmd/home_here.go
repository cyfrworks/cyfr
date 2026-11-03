// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"context"
	"errors"
	"io/fs"
	"net"
	"net/url"
	"os"
	"strings"
	"time"

	"github.com/cyfr/codex/internal/access"
)

// homeHere is whether the home at address runs on this machine, as far as
// this command line can tell: its host is loopback or resolves to one of
// this machine's own addresses, or the CYFR stack in the working directory
// (the one cyfr init set up) serves that address. A six-digit PIN the
// home counts protects nothing when both the home's data and this key
// record sit on one disk, so the command line refuses that mode here. It
// is the command line's own rule, not something the home can check.
var homeHere = func(address string) bool {
	u, err := url.Parse(strings.TrimRight(address, "/"))
	if err != nil || u.Hostname() == "" {
		return false
	}
	if stackServes(address) {
		return true
	}
	host := u.Hostname()
	if strings.EqualFold(host, "localhost") {
		return true
	}
	ips := []net.IP{net.ParseIP(host)}
	if ips[0] == nil {
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		found, err := net.DefaultResolver.LookupIPAddr(ctx, host)
		if err != nil {
			return false
		}
		ips = ips[:0]
		for _, a := range found {
			ips = append(ips, a.IP)
		}
	}
	own, _ := net.InterfaceAddrs()
	for _, ip := range ips {
		if ip.IsLoopback() || ownAddress(ip, own) {
			return true
		}
	}
	return false
}

// ownAddress is whether ip is assigned to one of this machine's interfaces.
func ownAddress(ip net.IP, own []net.Addr) bool {
	for _, a := range own {
		if n, ok := a.(*net.IPNet); ok && n.IP.Equal(ip) {
			return true
		}
	}
	return false
}

// stackServes is whether the working directory holds a CYFR stack whose
// address, as its .env says it is reached, is address: a home reached
// through a tailnet node in a container names no address of this machine's
// interfaces, yet its stack is here.
func stackServes(address string) bool {
	if _, err := os.Stat(".env"); errors.Is(err, fs.ErrNotExist) || err != nil {
		return false
	}
	head, err := currentHead()
	if err != nil {
		return false
	}
	return sameAddress(deviceHome(access.Describe(head).Address), deviceHome(address))
}
