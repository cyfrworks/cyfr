// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package guard

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"golang.org/x/sys/unix"

	"github.com/cyfr/locus/keeper/internal/logx"
)

// The guard's own files, on its tmpfs (docker-compose.yml's locus-guard):
//
//	ready          the digest of the static rules, written last as the
//	               guard starts, once every rule is in and the control
//	               listens: the health check's first condition
//	lock           taken exclusively around each route's change and shared
//	               by the health check, so a check in its own process never
//	               reads a rule set half changed
//	range          the route range the static rules chose
//	routes/sp<n>   each route's record: what the kernel held of it as it
//	               was installed (routeText)
//
// Each change of a route writes its record before it answers, so the check
// compares the chains installed with what the guard recorded, never with a
// snapshot a later change took.
type place struct {
	// dir is the guard's own folder, proc the kernel's /proc.
	dir  string
	proc string
}

// at is the guard's place in its container.
var at = place{dir: "/run/cyfr-guard", proc: "/proc"}

func (p place) ready() string              { return filepath.Join(p.dir, "ready") }
func (p place) lock() string               { return filepath.Join(p.dir, "lock") }
func (p place) rangeFile() string          { return filepath.Join(p.dir, "range") }
func (p place) routes() string             { return filepath.Join(p.dir, "routes") }
func (p place) record(iface string) string { return filepath.Join(p.routes(), iface) }

const (
	// applyTimeout bounds one change of a route's rules, every tool it
	// runs included, and each other run of a tool.
	applyTimeout = 30 * time.Second
	// checkLockWait bounds how long the health check waits for a route's
	// change to end.
	checkLockWait = 2 * time.Second
	// resolveTimeout bounds the resolution of one private host's name.
	resolveTimeout = 10 * time.Second
)

// tool runs one iptables tool with stdin, found on PATH, within ctx, and
// answers its output; its own errors reach the guard's log, unless quiet.
func tool(ctx context.Context, stdin string, quiet bool, name string, args ...string) (string, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Stdin = strings.NewReader(stdin)
	var out bytes.Buffer
	cmd.Stdout = &out
	if !quiet {
		cmd.Stderr = os.Stderr
	}
	err := cmd.Run()
	if ctx.Err() != nil {
		return "", fmt.Errorf("%s did not finish within its bound", name)
	}
	return out.String(), err
}

// iptables runs `iptables -w 5 args…` within ctx.
func iptables(ctx context.Context, quiet bool, args ...string) (string, error) {
	return tool(ctx, "", quiet, "iptables", append([]string{"-w", "5"}, args...)...)
}

// bounded is a context of applyTimeout.
func bounded() (context.Context, context.CancelFunc) {
	return context.WithTimeout(context.Background(), applyTimeout)
}

// saves reads the tables the static rules' digest is of: both families'
// filter tables and the IPv4 nat table. A read that fails answers no
// digest, so nothing is ever recorded or compared of a table that could
// not be read.
func saves(ctx context.Context, log *logx.Logger) (string, error) {
	v4, err := tool(ctx, "", false, "iptables-save", "-t", "filter")
	if err != nil {
		log.Error("iptables-save failed")
		return "", err
	}
	v6, err := tool(ctx, "", false, "ip6tables-save", "-t", "filter")
	if err != nil {
		log.Error("ip6tables-save failed")
		return "", err
	}
	nat, err := tool(ctx, "", false, "iptables-save", "-t", "nat")
	if err != nil {
		log.Error("iptables-save of the nat table failed")
		return "", err
	}
	return digest(v4, v6, nat), nil
}

// sysctls refuses a namespace whose forwarding or ICMP rate limit is not
// what a route needs.
func sysctls(log *logx.Logger, p place) error {
	read := func(name string) string {
		b, err := os.ReadFile(filepath.Join(p.proc, "sys/net/ipv4", name))
		if err != nil {
			return ""
		}
		return strings.TrimRight(string(b), "\n")
	}
	if v := read("ip_forward"); v != "1" {
		log.Error("net.ipv4.ip_forward is '%s' in this namespace, not 1: the guard's compose service sets it (sysctls)", v)
		return errNotReady
	}
	if v := read("icmp_ratelimit"); v != "0" {
		log.Error("net.ipv4.icmp_ratelimit is '%s' in this namespace, not 0: the guard's compose service sets it (sysctls)", v)
		return errNotReady
	}
	return nil
}

// readIsland reads the guard's namespace and environment: its routes,
// subnets and addresses from the kernel's tables under p.proc, and each
// private host CYFR_PRIVATE_EGRESS_TARGETS names, a name resolved now and
// logged.
func readIsland(log *logx.Logger, p place, env func(string) string, resolve func(string) []string) island {
	read := func(name string) string {
		b, _ := os.ReadFile(filepath.Join(p.proc, name))
		return string(b)
	}
	routes := read("net/route")
	isl := island{controlPlane: env("CYFR_GUARD_CONTROL_PLANE"), hostAPI: env("CYFR_GUARD_HOST_API"),
		routes: v4Routes(routes, false), subnets: v4Routes(routes, true),
		v6Subnets: v6Subnets(read("net/ipv6_route")), local: localAddresses(read("net/fib_trie"))}
	for _, target := range splitTargets(env("CYFR_PRIVATE_EGRESS_TARGETS")) {
		addresses := []string{target}
		if !strings.Contains(target, "/") {
			addresses = resolve(target)
		}
		if len(addresses) == 0 {
			log.Info("private target %s resolves to nothing here: it opens nothing", target)
			continue
		}
		for _, a := range addresses {
			log.Info("private target %s: %s passes", target, a)
		}
		isl.targets = append(isl.targets, addresses...)
	}
	return isl
}

// resolveHost is a name's addresses of both families, sorted, each once;
// none where it does not resolve.
func resolveHost(name string) []string {
	ctx, cancel := context.WithTimeout(context.Background(), resolveTimeout)
	defer cancel()
	addrs, err := net.DefaultResolver.LookupHost(ctx, name)
	if err != nil {
		return nil
	}
	return sortedOnce(addrs)
}

// rulesOf is the route rules the guard installs and withdraws in the
// kernel, each change under the lock taken exclusively.
type rulesOf struct {
	log  *logx.Logger
	at   place
	st   static
	lock *os.File
}

// exclusive takes the lock for one change and answers its release.
func (k *rulesOf) exclusive() (func(), error) {
	if err := unix.Flock(int(k.lock.Fd()), unix.LOCK_EX); err != nil {
		return nil, fmt.Errorf("taking the guard's lock: %w", err)
	}
	return func() { _ = unix.Flock(int(k.lock.Fd()), unix.LOCK_UN) }, nil
}

// install installs r's rules and records them; a route of r's guard's end
// that stands is removed first, and a route that fails at any step is
// removed whole.
func (k *rulesOf) install(r *route) error {
	unlock, err := k.exclusive()
	if err != nil {
		return err
	}
	defer unlock()
	ctx, cancel := bounded()
	defer cancel()
	iface := outerName(r.slot)
	if err := k.remove(ctx, iface); err != nil {
		return err
	}
	if _, err := tool(ctx, routeRules(r, k.st), false, "iptables-restore", "-w", "5", "--noflush"); err != nil {
		k.log.Error("route %s's rules failed: %v", iface, err)
		_ = k.remove(ctx, iface)
		return fmt.Errorf("route %s's rules failed: %w", iface, err)
	}
	if err := k.record(ctx, iface); err != nil {
		k.log.Error("route %s could not be recorded: %v", iface, err)
		_ = k.remove(ctx, iface)
		return fmt.Errorf("route %s could not be recorded: %w", iface, err)
	}
	what := r.reach
	switch {
	case r.reach == ReachRole && r.private:
		what = fmt.Sprintf("role %d private", r.port)
	case r.reach == ReachRole:
		what = fmt.Sprintf("role %d", r.port)
	}
	for _, a := range r.addresses {
		if family(a) == 4 {
			what += " " + a
		}
	}
	k.log.Info("route %s for %s (%s) installed, mark %d", iface, r.inner, what, r.mark)
	return nil
}

// withdraw removes r's rules and record; a route already gone is removed.
func (k *rulesOf) withdraw(r *route) error {
	unlock, err := k.exclusive()
	if err != nil {
		return err
	}
	defer unlock()
	ctx, cancel := bounded()
	defer cancel()
	iface := outerName(r.slot)
	if err := k.remove(ctx, iface); err != nil {
		return err
	}
	k.log.Info("route %s removed", iface)
	return nil
}

// listed is what the kernel lists of the route chains of iface and of the
// chains every route's jumps are in; a route chain it does not hold is "".
func listed(ctx context.Context, iface string) (installed, error) {
	slot := strings.TrimPrefix(iface, "sp")
	var k installed
	k.r, _ = iptables(ctx, true, "-S", chainRoute+slot)
	k.p, _ = iptables(ctx, true, "-S", chainPass+slot)
	var err error
	if k.out, err = iptables(ctx, false, "-S", chainOut); err != nil {
		return k, err
	}
	if k.in, err = iptables(ctx, false, "-S", chainIn); err != nil {
		return k, err
	}
	k.roles, err = iptables(ctx, false, "-t", "nat", "-S", chainRoles)
	return k, err
}

// text is what the kernel holds of iface's route, or an error where a
// part of it cannot be read.
func text(ctx context.Context, iface string) (string, error) {
	k, err := listed(ctx, iface)
	if err != nil {
		return "", err
	}
	if k.r == "" || k.p == "" {
		return "", fmt.Errorf("route %s's chains are not installed", iface)
	}
	return routeText(iface, k), nil
}

// remove removes every chain and jump of iface's route and a role's
// forwarding, then its record. The lock is held.
func (k *rulesOf) remove(ctx context.Context, iface string) error {
	l, err := listed(ctx, iface)
	if err != nil {
		k.log.Error("the routes' jumps could not be read")
		return fmt.Errorf("the routes' jumps could not be read: %w", err)
	}
	if _, err := tool(ctx, removal(iface, l), false, "iptables-restore", "-w", "5", "--noflush"); err != nil {
		k.log.Error("route %s's rules could not be removed", iface)
		return fmt.Errorf("route %s's rules could not be removed: %w", iface, err)
	}
	if err := os.Remove(k.at.record(iface)); err != nil && !errors.Is(err, os.ErrNotExist) {
		k.log.Error("route %s's record could not be dropped", iface)
		return fmt.Errorf("route %s's record could not be dropped: %w", iface, err)
	}
	return nil
}

// record writes what the kernel holds of iface's route as its record.
func (k *rulesOf) record(ctx context.Context, iface string) error {
	have, err := text(ctx, iface)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(k.at.routes(), 0o755); err != nil {
		return err
	}
	return writeFile(k.at.record(iface), have)
}

// writeFile writes path whole, through a temporary file beside it.
func writeFile(path, content string) error {
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, []byte(content), 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// CheckMain runs `cyfr-locus guard-check`, the guard's health probe: it
// exits 0 when the guard is ready, and 1 naming why otherwise.
func CheckMain(args []string) int {
	log := logx.New("cyfr-guard")
	if len(args) != 0 {
		log.Error("usage: cyfr-locus guard-check")
		return ExitUsage
	}
	if check(log, at) != nil {
		return ExitRefused
	}
	return 0
}

// check is the health check: the ready file is present, every rule table
// can be read, the static rules are the ones the ready file recorded when
// they were installed, the routes' masquerade stands, and every route the
// guard recorded is installed as it was recorded, with no chain or jump of
// a route it holds no record of. It waits at most checkLockWait for a
// route's change to end.
func check(log *logx.Logger, p place) error {
	notReady := func(format string, args ...any) error {
		log.Error("not ready: "+format, args...)
		return errNotReady
	}
	if info, err := os.Stat(p.ready()); err != nil || !info.Mode().IsRegular() {
		return notReady("%s is absent", p.ready())
	}
	lock, err := os.OpenFile(p.lock(), os.O_WRONLY|os.O_CREATE|unix.O_CLOEXEC, 0o644)
	if err != nil {
		return notReady("the lock: %v", err)
	}
	defer lock.Close()
	if !shared(lock, checkLockWait) {
		return notReady("the rules are changing")
	}
	ctx, cancel := bounded()
	defer cancel()
	if err := sysctls(log, p); err != nil {
		return err
	}
	recorded, err := os.ReadFile(p.ready())
	if err != nil {
		return notReady("%s could not be read", p.ready())
	}
	installed, err := saves(ctx, log)
	if err != nil {
		return notReady("a rule table could not be read")
	}
	if strings.TrimRight(string(recorded), "\n") != installed {
		return notReady("the rules installed are not the ones recorded")
	}
	rng, err := os.ReadFile(p.rangeFile())
	if err != nil {
		return notReady("%s could not be read", p.rangeFile())
	}
	r := strings.TrimRight(string(rng), "\n")
	if _, err := iptables(ctx, true, masquerade(r)...); err != nil {
		return notReady("the routes' masquerade for %s is not installed", r)
	}
	return routesInstalled(ctx, log, p)
}

// shared takes lock shared within wait: flock takes no bound of its own.
func shared(lock *os.File, wait time.Duration) bool {
	deadline := time.Now().Add(wait)
	for {
		err := unix.Flock(int(lock.Fd()), unix.LOCK_SH|unix.LOCK_NB)
		if err == nil {
			return true
		}
		if !errors.Is(err, unix.EWOULDBLOCK) || time.Now().After(deadline) {
			return false
		}
		time.Sleep(10 * time.Millisecond) // sleep-ok: flock has no timed wait; polled within the check's bound
	}
}

// routesInstalled is whether every route the guard recorded is installed
// exactly as recorded, and no route it holds no record of has a chain or a
// jump, naming what differs otherwise.
func routesInstalled(ctx context.Context, log *logx.Logger, p place) error {
	notReady := func(format string, args ...any) error {
		log.Error("not ready: "+format, args...)
		return errNotReady
	}
	var recorded []string
	entries, _ := os.ReadDir(p.routes())
	for _, e := range entries {
		if !routeLink.MatchString(e.Name()) {
			continue
		}
		if info, err := os.Stat(p.record(e.Name())); err == nil && info.Mode().IsRegular() {
			recorded = append(recorded, e.Name())
		}
	}
	recorded = sortedOnce(recorded)
	filter, err := iptables(ctx, false, "-S")
	if err != nil {
		return notReady("the IPv4 rules could not be read")
	}
	roles, err := iptables(ctx, false, "-t", "nat", "-S", chainRoles)
	if err != nil {
		return notReady("the roles' forwarding could not be read")
	}
	chains, jumps := routesListed(filter, roles)
	if !slices.Equal(chains, recorded) {
		return notReady("the routes' chains are not the routes the guard recorded")
	}
	if !slices.Equal(jumps, recorded) {
		return notReady("the jumps to routes are not the routes the guard recorded")
	}
	for _, iface := range recorded {
		have, err := text(ctx, iface)
		if err != nil {
			return notReady("route %s could not be read", iface)
		}
		want, err := os.ReadFile(p.record(iface))
		if err != nil || strings.TrimRight(have, "\n") != strings.TrimRight(string(want), "\n") {
			return notReady("route %s is not installed as the guard recorded it", iface)
		}
	}
	return nil
}
