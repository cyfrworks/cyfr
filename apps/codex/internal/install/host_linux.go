// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package install

import (
	"bytes"
	"context"
	"errors"
	"io"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"runtime"
	"slices"
	"strconv"
	"strings"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

// probeTimeout bounds each read-only call Observe makes.
const probeTimeout = 20 * time.Second

// osHost is the running system; actions' output goes to out.
type osHost struct {
	policy Policy
	out    io.Writer
}

// NewHost answers the running system as a Host, showing actions' output
// on out.
func NewHost(p Policy, out io.Writer) Host { return osHost{policy: p, out: out} }

// ObserveSelf observes the machine for the account running this process.
func ObserveSelf(ctx context.Context, p Policy) (Facts, error) {
	u, err := user.Current()
	if err != nil {
		return Facts{}, err
	}
	uid, _ := strconv.Atoi(u.Uid)
	account := Account{Name: u.Username, UID: uid, Root: uid == 0}
	if name := os.Getenv("SUDO_USER"); account.Root && name != "" && name != "root" {
		if by, err := user.Lookup(name); err == nil && by.Uid != "0" {
			account.SudoUser = name
		}
	}
	return osHost{policy: p}.Observe(ctx, account)
}

func (h osHost) Now() time.Time { return time.Now() }

func (h osHost) Sleep(ctx context.Context, d time.Duration) error {
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-time.After(d):
		return nil
	}
}

// probe runs a read-only call and answers its standard output, with its
// standard error appended when it fails.
func probe(ctx context.Context, name string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, probeTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Env = append(os.Environ(), "LC_ALL=C")
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	err := cmd.Run()
	if err != nil {
		return stdout.String() + stderr.String(), err
	}
	return stdout.String(), nil
}

func (h osHost) Observe(ctx context.Context, account Account) (Facts, error) {
	p := h.policy
	raw, _ := os.ReadFile("/etc/os-release")
	sys := ParseSystem(string(raw), runtime.GOARCH)
	f := Facts{Supported: p.Supports(sys), System: sys.Name, Account: account}
	if !f.Supported {
		return f, nil
	}
	if err := ctx.Err(); err != nil {
		return f, err
	}

	codename := sys.Codename
	if codename == "" {
		codename = p.System.Codename
	}
	targets, _ := probe(ctx, "apt-get", UniverseArgs...)
	f.Universe = UniverseEnabled(targets, codename, p.Universe.Component)

	names := []string{"-W", "-f", "${Package}\t${db:Status-Status}\n"}
	for _, pkg := range p.Docker.Packages {
		names = append(names, pkg.Package)
	}
	// dpkg-query exits 1 when a package is unknown and still prints the
	// known ones.
	status, _ := probe(ctx, "dpkg-query", names...)
	f.Packages = parseDpkgStatus(status)
	audit, _ := probe(ctx, "dpkg", "--audit")
	f.Interrupted = strings.TrimSpace(audit) != ""

	f.Docker = observeDocker(ctx, p)
	f.Kernel = observeKernel()

	if group, err := user.LookupGroup(p.Docker.Group); err == nil {
		f.Account.Member = groupLists(group.Gid, account.Name)
		gid, _ := strconv.Atoi(group.Gid)
		groups, _ := os.Getgroups()
		f.Account.Process = slices.Contains(groups, gid) || os.Getegid() == gid
	}
	return f, ctx.Err()
}

// groupLists reports whether /etc/group's entry of gid lists name.
func groupLists(gid, name string) bool {
	raw, err := os.ReadFile("/etc/group")
	if err != nil {
		return false
	}
	for _, line := range strings.Split(string(raw), "\n") {
		fields := strings.Split(line, ":")
		if len(fields) == 4 && fields[2] == gid {
			return slices.Contains(strings.Split(fields[3], ","), name)
		}
	}
	return false
}

func observeDocker(ctx context.Context, p Policy) Docker {
	var d Docker
	d.Service, d.Enabled = observeService(ctx, p.Docker.Service)
	path, err := exec.LookPath("docker")
	if err != nil {
		return d
	}
	d.CLI = "other"
	if real, err := filepath.EvalSymlinks(path); err == nil {
		if owner, err := probe(ctx, "dpkg-query", "-S", real); err == nil && strings.HasPrefix(owner, "docker.io:") {
			d.CLI = "ubuntu"
		}
	}
	d.Endpoint = os.Getenv("DOCKER_HOST")
	if d.Endpoint == "" {
		out, _ := probe(ctx, path, "context", "inspect", "--format", "{{.Endpoints.docker.Host}}")
		d.Endpoint = strings.TrimSpace(out)
	}
	d.Endpoint = SameSocket(d.Endpoint, p.Docker.Endpoint)
	out, err := probe(ctx, path, "info", "--format", "{{json .}}")
	if major, cgroup, security, ok := parseDockerInfo(strings.TrimSpace(out)); err == nil && ok {
		d.Daemon, d.Major, d.Cgroup, d.Security = "running", major, cgroup, security
	} else if strings.Contains(strings.ToLower(out), "permission denied") {
		d.Daemon = "denied"
	} else {
		d.Daemon = "stopped"
	}
	compose, err := probe(ctx, path, "compose", "version", "--short")
	d.Compose = err == nil && composeV2(compose)
	return d
}

func observeService(ctx context.Context, unit string) (state string, enabled bool) {
	load, _ := probe(ctx, "systemctl", "show", "--property=LoadState", "--value", unit)
	if strings.TrimSpace(load) != "loaded" {
		return "absent", false
	}
	active, _ := probe(ctx, "systemctl", "is-active", unit)
	state = "inactive"
	if strings.TrimSpace(active) == "active" {
		state = "active"
	}
	on, _ := probe(ctx, "systemctl", "is-enabled", unit)
	return state, strings.TrimSpace(on) == "enabled"
}

func observeKernel() Kernel {
	var k Kernel
	if raw, err := os.ReadFile("/proc/sys/user/max_user_namespaces"); err == nil {
		n, _ := strconv.Atoi(strings.TrimSpace(string(raw)))
		k.UserNS = n > 0
	}
	// Debian's switch, where the kernel has it.
	if raw, err := os.ReadFile("/proc/sys/kernel/unprivileged_userns_clone"); err == nil && strings.TrimSpace(string(raw)) != "1" {
		k.UserNS = false
	}
	var fs unix.Statfs_t
	k.Cgroup2 = unix.Statfs("/sys/fs/cgroup", &fs) == nil && fs.Type == unix.CGROUP2_SUPER_MAGIC
	return k
}

func (h osHost) Run(ctx context.Context, c Command) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, c.Timeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, c.Argv[0], c.Argv[1:]...)
	cmd.Env = RootEnv
	cmd.Stdin = nil
	// A cancelled or overdue package step is asked to stop, as an
	// interrupt from the terminal asks it, and killed only if it does not.
	cmd.Cancel = func() error { return cmd.Process.Signal(syscall.SIGTERM) }
	cmd.WaitDelay = 30 * time.Second
	var buf bytes.Buffer
	if c.Quiet || h.out == nil {
		cmd.Stdout, cmd.Stderr = &buf, &buf
	} else {
		w := io.MultiWriter(&buf, h.out)
		cmd.Stdout, cmd.Stderr = w, w
	}
	err := cmd.Run()
	if err == nil && ctx.Err() != nil {
		err = ctx.Err()
	}
	return buf.String(), err
}

// Lock takes an exclusive flock(2) on path, the lock the install script
// takes with flock(1). The file is root's, in root's /run, opened without
// following a link.
func (h osHost) Lock(ctx context.Context, path string, wait time.Duration) (func(), error) {
	f, err := os.OpenFile(path, os.O_RDWR|os.O_CREATE|syscall.O_NOFOLLOW|syscall.O_CLOEXEC, 0o644)
	if err != nil {
		return nil, err
	}
	deadline := time.Now().Add(wait)
	for {
		err := unix.Flock(int(f.Fd()), unix.LOCK_EX|unix.LOCK_NB)
		if err == nil {
			return func() { _ = f.Close() }, nil
		}
		if !errors.Is(err, unix.EWOULDBLOCK) {
			_ = f.Close()
			return nil, err
		}
		if !time.Now().Before(deadline) {
			_ = f.Close()
			return nil, ErrLockHeld
		}
		select {
		case <-ctx.Done():
			_ = f.Close()
			return nil, ctx.Err()
		case <-time.After(250 * time.Millisecond):
		}
	}
}
