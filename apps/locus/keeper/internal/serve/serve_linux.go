// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package serve

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"golang.org/x/sys/unix"

	"github.com/cyfr/locus/keeper/guard"
	"github.com/cyfr/locus/keeper/internal/admission"
	"github.com/cyfr/locus/keeper/internal/cgroup"
	"github.com/cyfr/locus/keeper/internal/home"
	"github.com/cyfr/locus/keeper/internal/logx"
	"github.com/cyfr/locus/keeper/internal/packview"
	"github.com/cyfr/locus/keeper/internal/pool"
	"github.com/cyfr/locus/keeper/internal/proc"
	"github.com/cyfr/locus/keeper/internal/procfs"
	"github.com/cyfr/locus/keeper/internal/protocol"
	"github.com/cyfr/locus/keeper/internal/relay"
	"github.com/cyfr/locus/keeper/internal/residue"
	"github.com/cyfr/locus/keeper/internal/retire"
	"github.com/cyfr/locus/keeper/internal/stage"
)

// Exit statuses of `cyfr-locus serve`.
const (
	// ExitStopped follows a termination signal forwarded to every role.
	ExitStopped = 0
	// ExitUsage reports a malformed command line.
	ExitUsage = 64
	// ExitLost reports the guard's loss under a role's route, or a role's
	// spawns that did not retire.
	ExitLost = 70
	// ExitStart reports that a role could not be started at the boot.
	ExitStart = 71
	// ExitConfig reports a privilege or environment the keeper refuses.
	ExitConfig = 78
)

const (
	// leaderExitGrace is the grace given to the rest of a spawn's processes
	// once its leader has exited.
	leaderExitGrace = 2 * time.Second
	// lostGrace is the grace given to every spawn when the channel is lost.
	lostGrace = time.Second
	// stageTimeout bounds a stage from start to exec.
	stageTimeout = 10 * time.Second
	// clearTimeout bounds the wait for a retired uid's last zombies.
	clearTimeout = 2 * time.Second
	// sweepInterval is how often quarantined uids are retried.
	sweepInterval = 5 * time.Second
	// scrubPasses bounds the retirements of one uid before it is quarantined.
	scrubPasses = 3
	// writeTimeout bounds one reply; a client that stops reading for this
	// long is treated as lost.
	writeTimeout = 30 * time.Second
	// retireTimeout bounds the retirement of a role's spawns at its end, and
	// of every spawn at the keeper's.
	retireTimeout = 30 * time.Second
)

// restartAfter is how long a role's process waits after its end before it
// starts again; startsTimeout bounds the wait of a role's end for its
// spawns' starts in flight, longer than a start takes: its hosts'
// resolution, a kept uid's retirement and its stage are each bounded
// within it. Past it the keeper ends, its last act the kill of every
// role's group (serve). Variables so a test can shorten them.
var (
	restartAfter  = time.Second
	startsTimeout = 2 * time.Minute
)

// RunRoot holds each role's run folder, named for the role.
const RunRoot = "/run/locus"

// Main runs `cyfr-locus serve` with the arguments after the subcommand.
func Main(args []string) int {
	log := logx.New("cyfr-locus")
	cfg, err := ParseArgs(args)
	if err != nil {
		log.Error("%v; usage: %s", err, Usage)
		return ExitUsage
	}
	if cfg.Resolver != "" {
		lookupHost = resolverAt(cfg.Resolver)
	}
	if err := CheckEnviron(os.Environ()); err != nil {
		log.Error("refusing to start: %v", err)
		return ExitConfig
	}
	environ := os.Environ()
	cpus := make([]uint64, len(cfg.Roles))
	var keyed []int
	reserve, share, err := PoolMemory(environ)
	if err != nil {
		log.Error("refusing to start: %v", err)
		return ExitConfig
	}
	for i, r := range cfg.Roles {
		if cpus[i], err = RoleCPU(environ, r); err != nil {
			log.Error("refusing to start: role %s: %v", r.Name, err)
			return ExitConfig
		}
		if Keyed(environ, r) {
			keyed = append(keyed, i)
		}
	}
	if len(keyed) == 0 {
		keys := make([]string, len(cfg.Roles))
		for i, r := range cfg.Roles {
			keys[i] = r.KeyEnv()
		}
		log.Error("refusing to start: no role's key is set (%s), so no role would run", strings.Join(keys, ", "))
		return ExitConfig
	}

	raw, err := os.ReadFile("/proc/self/status")
	if err != nil {
		log.Error("reading /proc/self/status: %v", err)
		return ExitConfig
	}
	st, err := procfs.ParseStatus(raw)
	if err != nil {
		log.Error("%v", err)
		return ExitConfig
	}
	if err := procfs.CheckKeeperCaps(st); err != nil {
		log.Error("refusing to start: %v", err)
		return ExitConfig
	}
	// no_new_privs is per thread; setting it on every thread makes every
	// process this one starts inherit it.
	if _, _, errno := syscall.AllThreadsSyscall(unix.SYS_PRCTL, unix.PR_SET_NO_NEW_PRIVS, 1, 0); errno != 0 {
		log.Error("refusing to start: PR_SET_NO_NEW_PRIVS: %v", errno)
		return ExitConfig
	}
	if err := unix.Prctl(unix.PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0); err != nil {
		log.Error("refusing to start: PR_SET_CHILD_SUBREAPER: %v", err)
		return ExitConfig
	}
	var homeRoots []string
	for _, r := range cfg.Roles {
		root := filepath.Join(cfg.HomeRoot, r.Name)
		if err := home.CheckRoot(root); err != nil {
			log.Error("refusing to start: role %s's spawns' homes: %v", r.Name, err)
			return ExitConfig
		}
		homeRoots = append(homeRoots, root)
	}
	roleAccounts, accounts, err := ResolveAccounts(cfg, SystemLookup)
	if err != nil {
		log.Error("refusing to start: %v", err)
		return ExitConfig
	}
	mounts, roots, err := residue.ReadRoots()
	if err != nil {
		log.Error("refusing to start: %v", err)
		return ExitConfig
	}
	keptRoot := ""
	if cfg.Kept != nil {
		if err := home.CheckKeptRoot(cfg.Kept.Root, heldGID(cfg, roleAccounts, accounts)); err != nil {
			log.Error("refusing to start: %v", err)
			return ExitConfig
		}
		keptRoot = cfg.Kept.Root
	}
	if err := residue.CheckMounts(mounts, homeRoots, keptRoot, PoolAccounts(accounts)); err != nil {
		log.Error("refusing to start: %v", err)
		return ExitConfig
	}
	// The packs' folder is made by its first put: nothing of it decides
	// whether the keeper starts. What an earlier keeper left half put is
	// removed now, and a folder that cannot be swept is only said.
	var packs *packview.Store
	if cfg.Kept != nil {
		packs = packview.New(filepath.Join(cfg.Kept.Root, packview.DirName))
		if err := packs.Sweep(); err != nil {
			log.Warn("the packs' folder holds what an earlier keeper left, and it was not removed: %v", err)
		}
	}
	self, err := os.Executable()
	if err != nil {
		log.Error("refusing to start: %v", err)
		return ExitConfig
	}
	// A stage keeps the keeper's supplementary groups, since its namespace
	// denies setgroups: they are cleared here first.
	if err := syscall.Setgroups([]int{}); err != nil {
		log.Error("refusing to start: clearing the supplementary groups: %v", err)
		return ExitConfig
	}
	enforced, err := stage.Confinement()
	if err != nil {
		log.Error("refusing to start: %v", err)
		return ExitConfig
	}
	if !enforced {
		log.Info("this host enforces no AppArmor, so nothing stands in the place of Docker's masks, which the container's system paths unmask: the keeper alone, never a space, may write /proc/sys")
	}
	if err := probeSpaces(self, cfg, accounts); err != nil {
		log.Error("refusing to start: %v", err)
		return ExitConfig
	}

	s := &server{
		cfg:       cfg,
		log:       log,
		self:      self,
		accounts:  accounts,
		roots:     roots,
		runRoot:   RunRoot,
		pools:     map[string]*pool.Pool{},
		spawns:    map[string]*spawn{},
		unremoved: map[*spawn]*removal{},
		waiters:   map[int]*child{},
		keptLive:  map[int]int{},
		keptOps:   map[int]*sync.Mutex{},
		packs:     packs,
		ended:     make(chan struct{}),
	}
	for _, spec := range cfg.Pools {
		s.pools[spec.Name] = pool.New(spec)
	}
	// Which homes each disk holds is its record's, read once here: a kept
	// spawn and every home request but a make find a home by its id alone.
	if cfg.Kept != nil {
		if err := s.loadDisks(); err != nil {
			log.Error("refusing to start: reading the disks' records: %v", err)
			return ExitConfig
		}
	}
	netns, err := os.Readlink("/proc/self/ns/net")
	if err != nil {
		log.Error("refusing to start: reading this network namespace: %v", err)
		return ExitConfig
	}
	s.guard = guard.NewClient(cfg.Guard, netns, s.guardLost)
	for _, spec := range cfg.Pools {
		if spec.Routed() {
			if err := s.proveGuard(spec); err != nil {
				log.Error("refusing to start: %v", err)
				return ExitConfig
			}
			break
		}
	}
	log.Info("egress: every routed space's route is made by the guard on %s before it starts", cfg.Guard)
	memory, err := delegateMemory()
	if err != nil {
		log.Error("refusing to start: every role and spawn is held in a cgroup group of its own, and none can be made here: %v", err)
		return ExitConfig
	}
	log.Info("memory and CPU bounds are enforced: a cgroup under %s for each role and each spawn", cgroup.Root)
	tree, err := memory.NewTree()
	if err != nil {
		log.Error("refusing to start: the pool's groups: %v", err)
		return ExitConfig
	}
	var roleCPUs []uint64
	for _, i := range keyed {
		spec, _ := poolOf(cfg.Pools, cfg.Roles[i].Pool)
		s.roles = append(s.roles, &role{
			spec:     cfg.Roles[i],
			pool:     spec,
			account:  roleAccounts[i],
			runDir:   filepath.Join(s.runRoot, cfg.Roles[i].Name),
			homeRoot: filepath.Join(cfg.HomeRoot, cfg.Roles[i].Name),
		})
		roleCPUs = append(roleCPUs, cpus[i])
	}
	sizes, err := makePool(log, tree, s.roles, roleCPUs, memory, "/proc/meminfo", reserve, share)
	if err != nil {
		log.Error("refusing to start: %v", err)
		return ExitConfig
	}
	floor := false
	for _, r := range s.roles {
		floor = floor || r.spec.Floor
	}
	s.begin(sizes, floor)
	if err := makeRunDirs(s.runRoot, s.roles); err != nil {
		log.Error("refusing to start: %v", err)
		return ExitConfig
	}
	return s.run()
}

// begin gives this start of the keeper its boot id, minted here, and its
// admission of a pool of the sizes, F kept where floor: it counts nothing
// yet, so its revs begin at 1.
func (s *server) begin(sizes admission.Sizes, floor bool) {
	s.boot = randomHex(16)
	s.budget = sizes.Budget
	s.rest = sizes.Rest
	s.ledger = admission.New(sizes.Work, floor)
}

// heldGID says whether a gid is held by a process the keeper starts: a
// role's, a pooled uid's or a kept home's.
func heldGID(cfg Config, roles []Account, accounts map[int]Account) func(gid int) bool {
	return func(gid int) bool {
		for _, r := range roles {
			if r.GID == gid {
				return true
			}
		}
		for _, a := range accounts {
			if a.GID == gid {
				return true
			}
		}
		return cfg.Kept != nil && cfg.Kept.Contains(gid)
	}
}

// describeBytes and describeQuota say a bound for the log.
func describeBytes(n uint64) string {
	return strconv.FormatUint(n>>20, 10) + " MiB"
}

func describeQuota(q uint64) string {
	if q == 0 {
		return "unbounded"
	}
	return strconv.FormatFloat(float64(q)/cgroup.CPUPeriod, 'f', -1, 64)
}

// probeSpaces proves, before the keeper serves, that this host gives each of
// its pools' spawns its space: for every reach the keeper serves it clones a
// stage as it clones every spawn's, maps the first uid of the first pool of
// that reach, and waits for the stage to become it, bring up a routed
// space's loopback and bind its name sockets, clone the space's first
// process, which builds the space's files and pivots into them, and with it
// drop every capability set, pass the check a spawn's stage makes before it
// executes anything and install the space's filter. A host that refuses any
// step refuses the keeper, naming what to check: there is no weaker space.
func probeSpaces(self string, cfg Config, accounts map[int]Account) error {
	probed := map[string]bool{}
	for _, spec := range cfg.Pools {
		if probed[spec.Reach] {
			continue
		}
		probed[spec.Reach] = true
		if err := probeSpace(self, spec, accounts[spec.First]); err != nil {
			return err
		}
	}
	return nil
}

// probeSpace is probeSpaces's proof for one pool's reach.
func probeSpace(self string, spec pool.Spec, acct Account) error {
	refuse := func(err error) error {
		return fmt.Errorf("pool %s's spawns run in a space of their own, a user, network, IPC, pid, mount and cgroup namespace with files of its own (%s), "+
			"and this host does not let cyfr-locus make one: %w; the host must allow unprivileged user namespaces (check user.max_user_namespaces, above 0, "+
			"and, where AppArmor restricts them, kernel.apparmor_restrict_unprivileged_userns, which the profile below satisfies), "+
			"and the container must run under the seccomp profile apps/locus/keeper/seccomp/keeper.json (/etc/cyfr/keeper.json in the image), which lets "+
			"clone make them and a space mount its files, with its system paths unmasked (security_opt systempaths=unconfined), since a masked /proc "+
			"lets no space mount its own, and, on a host with AppArmor, under this release's profile, which .env's CYFR_LOCUS_APPARMOR names "+
			"(security_opt apparmor=${CYFR_LOCUS_APPARMOR}) and cyfr init and cyfr update load", spec.Name, spec.Reach, err)
	}
	devnull, err := os.Open(os.DevNull)
	if err != nil {
		return err
	}
	defer devnull.Close()
	specR, specW, err := os.Pipe()
	if err != nil {
		return err
	}
	defer specW.Close()
	statusR, statusW, err := os.Pipe()
	if err != nil {
		specR.Close()
		return err
	}
	defer statusR.Close()
	pid, err := syscall.ForkExec(self, []string{"cyfr-locus", "stage", stage.ProbeArg}, &syscall.ProcAttr{
		Dir:   "/",
		Env:   []string{},
		Files: []uintptr{devnull.Fd(), devnull.Fd(), devnull.Fd(), specR.Fd(), statusW.Fd()},
		Sys:   stage.SpaceAttr(),
	})
	specR.Close()
	statusW.Close()
	if err != nil {
		return refuse(fmt.Errorf("cloning: %w", err))
	}
	reap := func() unix.WaitStatus {
		var ws unix.WaitStatus
		for {
			if _, err := unix.Wait4(pid, &ws, 0, nil); !errors.Is(err, unix.EINTR) {
				return ws
			}
		}
	}
	if err := stage.MapIDs(pid, acct.UID, acct.GID); err != nil {
		_ = unix.Kill(pid, unix.SIGKILL)
		reap()
		return refuse(err)
	}
	probe, err := json.Marshal(stage.Probe{UID: acct.UID, GID: acct.GID, Routed: spec.Routed()})
	if err == nil {
		_, err = specW.Write(probe)
	}
	_ = specW.Close()
	_ = statusR.SetReadDeadline(time.Now().Add(stageTimeout))
	// The status pipe closes when the stage exits; a stage that neither
	// answers nor exits within the bound is killed, so the reap below ends.
	reason, rerr := io.ReadAll(io.LimitReader(statusR, 4096))
	if err == nil {
		err = rerr
	}
	if err != nil || len(reason) > 0 {
		_ = unix.Kill(pid, unix.SIGKILL)
	}
	ws := reap()
	switch {
	case err != nil:
		return refuse(err)
	case len(reason) > 0:
		return refuse(errors.New("the cloned stage: " + string(reason)))
	case !ws.Exited() || ws.ExitStatus() != 0:
		return refuse(fmt.Errorf("the cloned stage ended %v", ws))
	}
	return nil
}

// proveGuard proves, before a routed keeper serves, that its guard makes a
// space's route: a probe stage of pool spec's first uid, in a space of its
// own, hands its namespace and name sockets up; the guard admits a route
// with them, and once the stage has ended, clears it. A guard that does
// either otherwise, or none at all, refuses the keeper by name.
func (s *server) proveGuard(spec pool.Spec) error {
	refuse := func(err error) error {
		return fmt.Errorf("pool %s's spaces are routed, and its guard on %s does not make a route: %w", spec.Name, s.cfg.Guard, err)
	}
	acct := s.accounts[spec.First]
	devnull, err := os.Open(os.DevNull)
	if err != nil {
		return err
	}
	defer devnull.Close()
	specR, specW, err := os.Pipe()
	if err != nil {
		return err
	}
	defer specW.Close()
	statusR, statusW, err := os.Pipe()
	if err != nil {
		specR.Close()
		return err
	}
	defer statusR.Close()
	stageRoute, keeperRoute, err := keeperPair("probe-route")
	if err != nil {
		specR.Close()
		statusW.Close()
		return err
	}
	defer keeperRoute.Close()
	pid, err := syscall.ForkExec(s.self, []string{"cyfr-locus", "stage", stage.ProbeArg}, &syscall.ProcAttr{
		Dir:   "/",
		Env:   []string{},
		Files: []uintptr{devnull.Fd(), devnull.Fd(), devnull.Fd(), specR.Fd(), statusW.Fd(), ^uintptr(0), stageRoute.Fd()},
		Sys:   stage.SpaceAttr(),
	})
	specR.Close()
	statusW.Close()
	stageRoute.Close()
	if err != nil {
		return refuse(fmt.Errorf("cloning its probe: %w", err))
	}
	reaped := false
	reap := func() unix.WaitStatus {
		var ws unix.WaitStatus
		for !reaped {
			if _, err := unix.Wait4(pid, &ws, 0, nil); !errors.Is(err, unix.EINTR) {
				reaped = true
			}
		}
		return ws
	}
	defer func() {
		if !reaped {
			_ = unix.Kill(pid, unix.SIGKILL)
			reap()
		}
	}()
	if err := stage.MapIDs(pid, acct.UID, acct.GID); err != nil {
		return refuse(err)
	}
	probe, err := json.Marshal(stage.Probe{UID: acct.UID, GID: acct.GID, Routed: true, Route: true})
	if err == nil {
		_, err = specW.Write(probe)
	}
	_ = specW.Close()
	if err != nil {
		return refuse(err)
	}
	if err := keeperRoute.SetReadDeadline(time.Now().Add(stageTimeout)); err != nil {
		return refuse(fmt.Errorf("its probe's route socket: %w", err))
	}
	files, err := receiveRoute(keeperRoute)
	if err != nil {
		return refuse(fmt.Errorf("its probe's descriptors: %w", err))
	}
	id := randomHex(16)
	r, err := s.guard.Admit(id, guard.ReachIsland, nil, files[0], files[1], files[2])
	for _, f := range files {
		_ = f.Close()
	}
	if err != nil {
		return refuse(err)
	}
	if _, err := keeperRoute.Write([]byte{stage.RouteGo}); err != nil {
		return refuse(err)
	}
	_ = statusR.SetReadDeadline(time.Now().Add(stageTimeout))
	reason, _ := io.ReadAll(io.LimitReader(statusR, 4096))
	ws := reap()
	if len(reason) > 0 || !ws.Exited() || ws.ExitStatus() != 0 {
		return refuse(fmt.Errorf("its probe ended %v: %s", ws, reason))
	}
	if err := s.guard.Clear(id, r); err != nil {
		return refuse(fmt.Errorf("the probe route was not cleared: %w", err))
	}
	return nil
}

// delegateMemory prepares the keeper's cgroup for its roles' and spawns'
// groups, or says why it cannot.
func delegateMemory() (*cgroup.Manager, error) {
	self, err := os.ReadFile(cgroup.SelfPath)
	if err != nil {
		return nil, err
	}
	return cgroup.Delegate(cgroup.Root, self)
}

// poolTree is the pool's groups as makePool makes them: a *cgroup.Tree.
type poolTree interface {
	Role(name string, cpu uint64, floor bool) (*cgroup.Manager, *cgroup.Group, error)
	Bound(work, rest uint64) error
}

// containerLimit is the container's own memory limit, false where it has
// none: a *cgroup.Manager of the namespace root.
type containerLimit interface {
	Limit() (uint64, bool, error)
}

// makePool is the boot's making of the pool: each role's groups in tree,
// at its processors cpus[i], and only once every group is made, since the
// kernel makes no group under one already bounded to 0, work's and rest's
// memory bounds by the sizing rule, from the meminfo file's MemTotal, the
// container's own limit, the reserve and the share, F kept where a role
// keeps the floor. It sets each role's groups and answers the sizes.
func makePool(log *logx.Logger, tree poolTree, roles []*role, cpus []uint64, container containerLimit, meminfo string,
	reserve, share uint64) (admission.Sizes, error) {
	floor := false
	for i, r := range roles {
		var err error
		if r.groups, r.leaf, err = tree.Role(r.spec.Name, cpus[i], r.spec.Floor); err != nil {
			return admission.Sizes{}, fmt.Errorf("role %s's group: %w", r.spec.Name, err)
		}
		floor = floor || r.spec.Floor
		service := cgroup.ServiceCPU(cpus[i])
		r.workCPU = cpus[i] - service
		log.Info("role %s: processors %s for its service and %s for its work, its spawns' groups in %s", r.spec.Name,
			describeQuota(service), describeQuota(cpus[i]-service), r.groups.Path())
	}
	total, err := memTotal(meminfo)
	if err != nil {
		return admission.Sizes{}, fmt.Errorf("the pool's memory: %w", err)
	}
	limit, limited, err := container.Limit()
	if err != nil {
		return admission.Sizes{}, fmt.Errorf("the pool's memory: %w", err)
	}
	sizes := admission.Size(total, limit, limited, reserve, share, floor)
	if err := tree.Bound(sizes.Work, sizes.Rest); err != nil {
		return admission.Sizes{}, fmt.Errorf("the pool's memory: %w", err)
	}
	log.Info("the pool: budget %s, work %s, rest %s; the services outside it", describeBytes(sizes.Budget),
		describeBytes(sizes.Work), describeBytes(sizes.Rest))
	if sizes.Work == 0 {
		cause := fmt.Sprintf("the machine's %s less the reserve, %s,", describeBytes(total), describeBytes(reserve))
		if limited && limit < sub(total, reserve) {
			cause = fmt.Sprintf("the container's own limit of %s", describeBytes(limit))
		}
		log.Warn("the pool holds no memory for work: %s leaves nothing beside the services' %s, so no spawn starts", cause, describeBytes(share))
	}
	return sizes, nil
}

func sub(a, b uint64) uint64 {
	if a < b {
		return 0
	}
	return a - b
}

// memTotal reads MemTotal of the meminfo file at path, in bytes.
func memTotal(path string) (uint64, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return 0, err
	}
	for _, line := range strings.Split(string(raw), "\n") {
		if rest, ok := strings.CutPrefix(line, "MemTotal:"); ok {
			kb, err := strconv.ParseUint(strings.TrimSuffix(strings.TrimSpace(rest), " kB"), 10, 64)
			if err != nil {
				return 0, fmt.Errorf("%s: MemTotal %q", path, rest)
			}
			return kb << 10, nil
		}
	}
	return 0, fmt.Errorf("%s has no MemTotal", path)
}

// child is a process this keeper started and will reap.
type child struct {
	pid    int
	done   chan struct{}
	status unix.WaitStatus
}

func (c *child) reaped() bool {
	select {
	case <-c.done:
		return true
	default:
		return false
	}
}

// keptRoot is the kept-homes root every space is given covered
// (stage.Spec.KeptRoot), "" for a keeper that keeps none.
func (s *server) keptRoot() string {
	if s.cfg.Kept == nil {
		return ""
	}
	return s.cfg.Kept.Root
}

// spawn is one allocation: a uid, its home, its leader and its relay. A
// kept spawn runs under its disk's uid in its home on that disk, and has no
// pool: every kept spawn of a person shares the disk's uid, and the uid is
// never a pool's.
type spawn struct {
	id string
	// client is the start of the role process that asked for it: its
	// replies and reports go to that one's channel, its place is among
	// that one's, and that one's end retires it.
	client  *client
	pool    *pool.Pool
	kept    bool
	account Account
	home    string
	// keptHome, work and disk are a kept spawn's home's id, its disk's work
	// folder, bound at /work, and its disk.
	keptHome, work, disk string
	leader               *child
	relay                *child
	// group is the spawn's memory-bounded cgroup, nil until it is created,
	// with limits, its place's kind's at its claim.
	group  *cgroup.Group
	limits admission.Limits
	// place is the id of the place the spawn was made in, set as it is
	// made; its retirement frees the place in the step that follows its
	// group's removal, so no measure answers a place whose spawn's group is
	// gone, and no place goes while its group stays.
	place string
	// reading says a read of the spawn's group is out: no other starts
	// until it returns.
	reading atomic.Bool
	// reach is the spawn's space's, its pool's (package pool).
	reach string
	// route is a routed spawn's route, set once the guard admitted it over
	// a connection that had not ended, and nil again once withdrawn; s.mu
	// guards it.
	route *guard.Route
	// pty is the keeper's own descriptor of the master of the spawn's
	// pseudo-terminal, which a `resize` sets the size through; nil for a
	// spawn without one. s.mu guards it once the spawn is in spawns, and
	// the retirement that removes the spawn from spawns closes it.
	pty *os.File

	// killedFor is what memory limit the kernel killed processes of the
	// spawn for, an `exited`'s `memory`, once its exit settled one; "" for
	// none. Its release counts it (forget). s.mu guards it.
	killedFor string

	// exitOnce settles the leader's one `exited`, sent or never to be:
	// whichever of its watcher and the retirement comes first reads the
	// cause and settles it, and the other waits for that. It is settled
	// before `released`, so no exit follows one, and at the refusal of a
	// spawn refused once made, which was never spawned and is owed none.
	exitOnce sync.Once
	// retired closes when retirement has finished.
	retired    chan struct{}
	retireOnce sync.Once
	// ended says a kept spawn's group was found empty at its retirement,
	// set before groupEnded closes, which a kept spawn's retirement closes
	// once its group's end returned, before its relay drains; s.mu guards
	// ended.
	ended      bool
	groupEnded chan struct{}
	// packs is the generation its space binds (packview.Store.Acquire),
	// whose release its final release calls (forget); nil for none.
	packs func()

	// machine is the person's VM a kept spawn of an image disk runs in
	// (machine_linux.go): such a spawn has no leader, group, relay or route
	// of its own on the host. egress is what it may reach, its VM's route
	// holding it among its person's live sessions'; link the VM's control
	// connection it was made over, guest and guestPlace its spawn and place
	// there, guestPID its leader's pid there; s.mu guards the four.
	machine    *machine
	egress     egress
	link       *guestLink
	guest      string
	guestPlace string
	guestPID   int
	// announced closes once its start has settled, its `spawned` sent or
	// its refusal's exit settled as none; guestEvents carries its guest's
	// exit and release to its follower (followGuest); guestEnded closes
	// once its guest released it, or is lost to it (gone), lost saying
	// which and lostMemory why.
	announced   chan struct{}
	guestEvents chan []byte
	guestEnded  chan struct{}
	goneOnce    sync.Once
	lost        bool
	lostMemory  *string
	// spliceMu guards ends and spliced, its standard streams' two halves
	// and the channel that closes once they are joined no more.
	spliceMu sync.Mutex
	ends     []net.Conn
	spliced  chan struct{}
}

// releasePacks lets go of the generation the spawn's space binds.
func (sp *spawn) releasePacks() {
	if sp.packs != nil {
		sp.packs()
	}
}

// role is one role the keeper runs: its spec and account, its run folder,
// the folder its spawns' homes are made in, its groups and its process.
type role struct {
	spec     RoleSpec
	pool     pool.Spec
	account  Account
	runDir   string
	homeRoot string
	// groups makes the role's spawns' groups, inside the role's group in
	// work, its people's VMs' among them; nil where none can be made, and
	// every spawn is refused. leaf is the role's leaf in service, which
	// holds its process and its relays. workCPU is its work's processors,
	// in microseconds of every period, 0 for no bound.
	groups  *cgroup.Manager
	leaf    *cgroup.Group
	workCPU uint64
	// client is the role's process standing, nil from its end until it is
	// started again; starting is its start in progress, from its channel's
	// making until it is published as client (publishRole) or fails, so the
	// guard's loss finds a role whose route is admitted before it stands
	// (guardLost). s.mu guards both.
	client   *client
	starting *client
}

// client is one start of a role's process: its space's stage, its channel,
// and what it holds, which goes with it at its end.
type client struct {
	role *role
	// id names its route at the guard.
	id      string
	proc    *child
	channel *os.File
	writeMu sync.Mutex
	// places are the places it holds, by its own ids; route is its space's
	// route once admitted; ended says its end has begun, from which no
	// spawn is held for it. s.mu guards the three.
	places map[string]*place
	route  *guard.Route
	ended  bool
	// starts counts its spawn starts in flight, each counted before its end
	// began or not at all (beginStart); its end waits for them (endClient).
	starts sync.WaitGroup
	// packs owns its puts at the packs' store (packview), ended with it.
	packs packview.Owner
	// out holds the lines queued for its channel, in order (queue); drainMu
	// lets one drain at a time write them, and wake tells its writer that
	// more are queued.
	outMu   sync.Mutex
	out     []any
	drainMu sync.Mutex
	wake    chan struct{}
}

type server struct {
	cfg      Config
	log      *logx.Logger
	self     string
	accounts map[int]Account
	// roots are the writable mounts and the mqueue mount a pooled uid can
	// leave something behind in.
	roots residue.Roots
	// guard makes each routed space's route (--guard).
	guard routeGuard
	// roles are the roles the keeper runs, one for each key it was given,
	// and runRoot holds their run folders.
	roles   []*role
	runRoot string

	// mu guards pools, spawns, every client's places, the ledger,
	// unremoved and waiters, and is held across every fork, reap and
	// signal, so a pid is never signalled after it was reaped.
	mu sync.Mutex
	// ledger is the one admission of every role's places (package
	// admission), and what it counts of who used what.
	ledger *admission.Ledger
	pools  map[string]*pool.Pool
	spawns map[string]*spawn
	// unremoved holds every retired spawn whose group could not be removed,
	// out of spawns, with what its retirement leaves to the retry that
	// removes the group: until then its place stays, read as a live
	// spawn's is, and a pooled uid stays out of its pool.
	unremoved map[*spawn]*removal
	// routing holds every routed spawn from before its admit until its
	// retirement ends, so the end of the guard's connection finds every
	// space routed over it (guardLost); lostRoutes names each connection
	// that ended, so an admit answered over one is never recorded.
	routing    map[string]*spawn
	lostRoutes map[uint64]bool
	// uncleared holds every withdrawn route the guard has not yet said
	// cleared, by its spawn id, asked again at each sweep.
	uncleared map[string]unclearedRoute
	// exit ends the keeper (os.Exit in production) and groupKilled kills a
	// spawn's group and answers whether it is empty (killGroup); tests set
	// either. readerStarts, nil in production, runs as a role's channel
	// reader starts, before it reads, and roleStarted between a role's
	// start at the boot and its publication: tests hold either there.
	exit         func(code int)
	groupKilled  func(sp *spawn) bool
	readerStarts func(r *role)
	roleStarted  func(r *role)
	// measuring is called at a kept home's measure, under its uid's lock:
	// tests hold a kept spawn's start there.
	measuring func(path string)
	waiters   map[int]*child
	// keptLive counts the live spawns of each disk's uid; keptOps holds
	// each such uid's lock, which a spawn's start, the uid's full
	// retirement and a home request's helper take, so none of them
	// interleaves with another of the same uid. A kept uid follows a pooled
	// uid's discipline, a person's at once: from the release of its last
	// spawn until every process of it is ended and nothing it left outside
	// its disk remains, it is retiring (keptRetiring, its channel closed at
	// the end); a retirement that cannot finish quarantines it
	// (keptQuarantined, naming its disk) until the sweeper's retry does.
	// keptMaking holds the uid a home_make drew for a new disk from the draw
	// until the disk's record holds it, so no other draw takes it; keptDraw
	// makes a draw's reading and its draw one step (drawKept). disks is
	// every disk's record by its athanor, and homeDisk whose disk holds each
	// home (loadDisks, putDisk). homeOps holds each kept home's lock, by its
	// id, and diskOps each disk's, by its athanor, while a request holds or
	// waits for it (lockHome, lockDisk).
	keptLive        map[int]int
	keptEnding      map[int]int // a kept uid's released spawns still ending in order (retireKept)
	keptOps         map[int]*sync.Mutex
	keptRetiring    map[int]chan struct{}
	keptQuarantined map[int]string
	keptMaking      map[int]bool
	keptDraw        sync.Mutex
	disks           map[string]*home.Disk
	homeDisk        map[string]string
	keptWithheld    map[int]bool // a uid whose disk's record did not read back after a failed write (putDisk)
	diskOps         map[string]*homeLock
	// writeDisk writes a disk's record, home.Kept.WriteDisk when nil: tests
	// fail it.
	writeDisk func(home.Disk) error
	homeOps   map[string]*homeLock
	// packs is every person's packs (package packview) under the kept
	// homes' root; nil for a keeper that keeps no homes.
	packs *packview.Store
	// imageDisks says a disk made now takes the image form, a person's VM's
	// drive (home.FormImage).
	imageDisks bool
	// wall says this keeper gives the VM wall (plan D18): it was given KVM
	// and the image's guest, and a first session in a VM fits rest; then
	// imageDisks too, and every session of a person runs in their VM;
	// wallWhy is why it gives none, as its start line says; wallGiven is
	// the decision as every report carries it (protocol.WallGiven,
	// WallNoRoom, WallLacking), "" before giveWall, which no reader takes.
	// vms is each person's VM by their athanor (machine_linux.go), and
	// bootVM starts one, startVM in production.
	wall      bool
	wallWhy   string
	wallGiven string
	vms       map[string]*machine
	vmsEnding map[*machine]bool
	bootVM    func(vmBoot) (guestVM, error)

	// boot is this start's id, 16 random bytes in hex, minted at the start
	// and of nothing else: every report carries it, its counters' revs
	// being this start's. budget is the pool's budget (admission.Sizes).
	// uncounted is the ledger's uncounted uses as last logged; s.mu guards
	// it.
	boot      string
	budget    uint64
	rest      uint64
	uncounted uint64

	stopping atomic.Bool
	closing  atomic.Bool
	// ended closes when the keeper must end with endCode: the guard was
	// lost under a role's route, or a role's spawns did not retire.
	ended   chan struct{}
	endOnce sync.Once
	endCode int
	// rolesKilled, nil in production, runs once the guard's loss has
	// killed the roles routed over the lost connection (guardLost).
	rolesKilled func()
}

func (s *server) run() int {
	sigchld := make(chan os.Signal, 1)
	signal.Notify(sigchld, unix.SIGCHLD)
	stop := make(chan os.Signal, 4)
	signal.Notify(stop, unix.SIGTERM, unix.SIGINT, unix.SIGHUP)
	go s.reaper(sigchld)
	return s.serve(stop)
}

// serve boots the roles (bootRoles) and keeps each until a stop signal on
// stop or the keeper's end, then retires every spawn. Its last act on
// every exit is the kernel's kill of every role's group (killRoleGroups),
// so no process of a role, a spawn or a start still in flight, registered
// or not, outlives the keeper.
func (s *server) serve(stop <-chan os.Signal) int {
	defer s.killRoleGroups()
	// The wall is decided, and a disk of the directory form retired as its
	// uid where it is given, once the reaper runs and before any role.
	s.giveWall()
	if !s.bootRoles() {
		s.markClosing()
		s.endRoles()
		select {
		case <-s.ended:
			return s.endCode
		default:
			return ExitStart
		}
	}

	go s.sweeper()
	reading := make(chan struct{})
	defer close(reading)
	go s.reader(reading)
	done := make(chan struct{}, len(s.roles))
	for _, r := range s.roles {
		go func() {
			s.keepRole(r)
			done <- struct{}{}
		}()
	}

	running := len(s.roles)
loop:
	for running > 0 {
		select {
		case sig := <-stop:
			if sig != unix.SIGHUP {
				s.stopping.Store(true)
			}
			s.signalRoles(sig.(syscall.Signal))
		case <-done:
			running--
		case <-s.ended:
			break loop
		}
	}

	s.markClosing()
	s.endRoles()
	s.mu.Lock()
	live := make([]*spawn, 0, len(s.spawns))
	for _, sp := range s.spawns {
		live = append(live, sp)
	}
	s.mu.Unlock()
	for _, sp := range live {
		s.retire(sp, lostGrace, false)
	}
	if !s.awaitRetired(live) {
		s.log.Error("retirement did not finish within %v", retireTimeout)
		return ExitLost
	}
	select {
	case <-s.ended:
		s.log.Error("every role and spawn ended")
		return s.endCode
	default:
	}
	s.log.Info("stopped")
	return ExitStopped
}

// bootRoles starts every role and publishes each (publishRole), and
// answers whether all stand. A role that cannot start refuses the boot by
// its name; once the keeper's end has begun, the guard's loss among its
// causes, no further role is started.
func (s *server) bootRoles() bool {
	for _, r := range s.roles {
		c, err := s.startRole(r)
		if err != nil {
			s.log.Error("refusing to start: role %s: %v", r.spec.Name, err)
			return false
		}
		if s.roleStarted != nil {
			s.roleStarted(r)
		}
		if ending := s.publishRole(r, c); ending {
			s.log.Error("role %s: the keeper's end began as it started; no further role starts", r.spec.Name)
			return false
		}
		s.log.Info("role %s: pid %d started as %s; pool %s", r.spec.Name, c.proc.pid, r.account.Name, r.spec.Pool)
	}
	return true
}

// killRoleGroups kills every role's groups, its leaf with its process and
// its relays, and its group in work with every spawn group in it, by the
// kernel's group kill, and logs a group that will not empty.
func (s *server) killRoleGroups() {
	for _, r := range s.roles {
		if r.leaf != nil && !r.leaf.KillBy(time.Now()) {
			s.log.Error("role %s: its leaf did not empty at the keeper's end", r.spec.Name)
		}
		if r.groups != nil && !r.groups.Kill() {
			s.log.Error("role %s: its group in work did not empty at the keeper's end", r.spec.Name)
		}
	}
}

// end has the keeper end with code, once: every role and spawn ends first.
func (s *server) end(code int) {
	s.endOnce.Do(func() {
		s.endCode = code
		s.markClosing()
		close(s.ended)
	})
}

// markClosing begins the keeper's end in the critical section a start's
// last check takes (owns): a start checked before it sends to its stage
// before the end, which the group kill of every role then ends, and one
// checked after it sends nothing.
func (s *server) markClosing() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.closing.Store(true)
}

// awaitRetired waits retireTimeout at most for every one of spawns to be
// retired, and says whether they were.
func (s *server) awaitRetired(spawns []*spawn) bool {
	deadline := time.After(retireTimeout)
	for _, sp := range spawns {
		select {
		case <-sp.retired:
		case <-deadline:
			return false
		}
	}
	return true
}

// reaper collects every exited child, including orphans reparented to this
// subreaper, and wakes whoever waits on a known pid.
func (s *server) reaper(sigchld <-chan os.Signal) {
	tick := time.NewTicker(time.Second)
	defer tick.Stop()
	for {
		select {
		case <-sigchld:
		case <-tick.C:
		}
		s.reap()
	}
}

func (s *server) reap() {
	s.mu.Lock()
	defer s.mu.Unlock()
	for {
		var ws unix.WaitStatus
		pid, err := unix.Wait4(-1, &ws, unix.WNOHANG, nil)
		if errors.Is(err, unix.EINTR) {
			continue
		}
		if err != nil || pid <= 0 {
			return
		}
		if c := s.waiters[pid]; c != nil {
			c.status = ws
			close(c.done)
			delete(s.waiters, pid)
		}
	}
}

// start forks and executes a process in a session of its own as uid and
// gid with no supplementary groups, killed if this keeper dies.
func (s *server) start(argv0 string, argv, env []string, files []uintptr, uid, gid int, dir string) (*child, error) {
	return s.startWith(argv0, argv, env, files, dir, &syscall.SysProcAttr{
		Setsid:     true,
		Credential: &syscall.Credential{Uid: uint32(uid), Gid: uint32(gid), Groups: []uint32{}},
		Pdeathsig:  syscall.SIGKILL,
	})
}

// startWith forks and executes a process as sys says.
func (s *server) startWith(argv0 string, argv, env []string, files []uintptr, dir string, sys *syscall.SysProcAttr) (*child, error) {
	attr := &syscall.ProcAttr{Dir: dir, Env: env, Files: files, Sys: sys}
	s.mu.Lock()
	defer s.mu.Unlock()
	pid, err := syscall.ForkExec(argv0, argv, attr)
	if err != nil {
		return nil, err
	}
	c := &child{pid: pid, done: make(chan struct{})}
	s.waiters[pid] = c
	return c, nil
}

// startTool is the start the keeper hands a package that waits for a
// process of its own (proc.Start): the keeper's own start, so the reaper
// that takes every exited child gives the package its child's end, and no
// child of the keeper is waited for but by it.
func (s *server) startTool(argv0 string, argv, env []string, files []uintptr, dir string, sys *syscall.SysProcAttr) (proc.Process, error) {
	c, err := s.startWith(argv0, argv, env, files, dir, sys)
	if err != nil {
		return nil, err
	}
	return tool{s: s, c: c}, nil
}

// tool is a child started by startTool, as a proc.Process.
type tool struct {
	s *server
	c *child
}

func (t tool) Pid() int                         { return t.c.pid }
func (t tool) Done() <-chan struct{}            { return t.c.done }
func (t tool) Status() (unix.WaitStatus, error) { return t.c.status, nil }

// Kill signals under the reaper's lock, as signalChild does, so no kill
// reaches a pid or a group's id once the child is reaped.
func (t tool) Kill(group bool) {
	t.s.mu.Lock()
	defer t.s.mu.Unlock()
	if t.c.reaped() {
		return
	}
	pid := t.c.pid
	if group {
		pid = -pid
	}
	_ = unix.Kill(pid, unix.SIGKILL)
}

// signalChild signals one child unless it has been reaped.
func (s *server) signalChild(c *child, sig syscall.Signal) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !c.reaped() {
		_ = unix.Kill(c.pid, sig)
	}
}

// serveChannel answers c's requests until its channel ends.
func (s *server) serveChannel(c *client) {
	stop := make(chan struct{})
	defer close(stop)
	go s.writer(c, stop)
	lr := protocol.NewLineReader(c.channel)
	for {
		line, tooLong, err := lr.Next()
		if err != nil {
			if !errors.Is(err, io.EOF) && !errors.Is(err, os.ErrClosed) {
				s.log.Error("reading role %s's channel: %v", c.role.spec.Name, err)
			}
			return
		}
		if tooLong {
			s.log.Warn("refused a request longer than %d bytes", protocol.MaxLineBytes)
			s.send(c, protocol.NewError("", "", protocol.CodeBadRequest))
			continue
		}
		req, rerr := protocol.ParseRequest(line)
		if rerr != nil {
			s.log.Warn("refused a request: %s", rerr.Detail)
			s.send(c, rerr.Reply())
			continue
		}
		// A place, a drop and an assign are applied here, before the next
		// line is read, in the order the client sent them: a spawn finds the
		// place sent before it, and a drop or an assign what came before it.
		// Every other request runs on a goroutine of its own.
		switch req.Type {
		case protocol.TypePlace, protocol.TypeDrop, protocol.TypeAssign:
			s.handle(c, req)
		default:
			go s.handle(c, req)
		}
	}
}

// send writes reply to c's channel, after every line queued before it:
// every reply goes to the channel its request came on, every report of a
// spawn to its client's. It waits for c's own channel alone.
func (s *server) send(c *client, reply any) {
	c.queue(reply)
	s.drain(c)
}

// queue puts line at the end of c's lines and wakes its writer: it never
// waits for a write, so a step of the admission under s.mu, or another
// client's handler, never waits on c.
func (c *client) queue(line any) {
	c.outMu.Lock()
	c.out = append(c.out, line)
	c.outMu.Unlock()
	select {
	case c.wake <- struct{}{}:
	default:
	}
}

// drain writes c's queued lines in their order, one drain at a time.
func (s *server) drain(c *client) {
	c.drainMu.Lock()
	defer c.drainMu.Unlock()
	for {
		c.outMu.Lock()
		out := c.out
		c.out = nil
		c.outMu.Unlock()
		if len(out) == 0 {
			return
		}
		for _, line := range out {
			s.write(c, line)
		}
	}
}

// writer drains c's lines whenever more are queued, until stop closes: the
// lines another client's step queued for c are written by c's writer
// alone.
func (s *server) writer(c *client, stop <-chan struct{}) {
	for {
		select {
		case <-stop:
			return
		case <-c.wake:
			s.drain(c)
		}
	}
}

// write writes one line to c's channel, within writeTimeout; a write that
// fails closes the channel.
func (s *server) write(c *client, reply any) {
	line, err := protocol.Encode(reply)
	if err != nil {
		s.log.Error("encoding a reply: %v", err)
		return
	}
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	_ = c.channel.SetWriteDeadline(time.Now().Add(writeTimeout))
	if _, err := c.channel.Write(line); err != nil && !errors.Is(err, os.ErrClosed) {
		s.log.Error("writing role %s's channel: %v", c.role.spec.Name, err)
		_ = c.channel.Close()
	}
}

func (s *server) handle(c *client, req *protocol.Request) {
	switch req.Type {
	case protocol.TypePlace:
		s.handlePlace(c, req)
	case protocol.TypeDrop:
		s.handleDrop(c, req)
	case protocol.TypeAssign:
		s.handleAssign(c, req)
	case protocol.TypeSpawn:
		s.handleSpawn(c, req)
	case protocol.TypeSignal:
		s.handleSignal(c, req)
	case protocol.TypeResize:
		s.handleResize(c, req)
	case protocol.TypeRelease:
		s.handleRelease(c, req)
	case protocol.TypePool:
		s.handlePool(c, req)
	case protocol.TypeMeasure:
		s.handleMeasure(c, req)
	case protocol.TypeHomeMake, protocol.TypeHomeMeasure, protocol.TypeHomeReset, protocol.TypeHomeRetire:
		s.handleHome(c, req)
	case protocol.TypeHomeList:
		s.handleHomeList(c, req)
	case protocol.TypeReport:
		s.handleReport(c, req)
	case protocol.TypePacksHold, protocol.TypePacksPut:
		s.handlePacks(c, req)
	}
}

// heldSpawn is the spawn id when c holds it, nil for one another role
// holds as for one the keeper does not; s.mu is held.
func (s *server) heldSpawn(c *client, id string) *spawn {
	if sp := s.spawns[id]; sp != nil && sp.client == c {
		return sp
	}
	return nil
}

// poolOf is c's role's pool spec when it is named name: another role's
// pool is unknown to c as one the keeper does not serve.
func (c *client) poolOf(name string) (pool.Spec, bool) {
	if name != c.role.pool.Name {
		return pool.Spec{}, false
	}
	return c.role.pool, true
}

func (s *server) handlePool(c *client, req *protocol.Request) {
	_, known := c.poolOf(req.Pool)
	s.mu.Lock()
	p := s.pools[req.Pool]
	var st pool.Stats
	if known && p != nil {
		st = p.Stats()
	}
	s.mu.Unlock()
	if !known || p == nil {
		s.send(c, protocol.NewError(req.ID, "", protocol.CodeUnknownPool))
		return
	}
	s.send(c, protocol.NewPoolReply(req.ID, req.Pool, st.Size, st.Free, st.Quarantined))
}

func (s *server) handleSignal(c *client, req *protocol.Request) {
	sig := signalNumbers[req.Sig]
	s.mu.Lock()
	sp := s.heldSpawn(c, req.SpawnID)
	if sp != nil && sp.machine != nil {
		s.mu.Unlock()
		s.guestSignal(sp, req)
		return
	}
	running := sp != nil && sp.leader != nil && !sp.leader.reaped()
	if running {
		_ = unix.Kill(-sp.leader.pid, sig)
	}
	s.mu.Unlock()
	switch {
	case sp == nil:
		s.send(c, protocol.NewError("", req.SpawnID, protocol.CodeUnknownSpawn))
	case !running:
		s.send(c, protocol.NewError("", req.SpawnID, protocol.CodeNotRunning))
	}
}

// handleResize sets the size of a spawn's pseudo-terminal; the kernel
// signals SIGWINCH to the terminal's foreground process group.
func (s *server) handleResize(c *client, req *protocol.Request) {
	s.mu.Lock()
	sp := s.heldSpawn(c, req.SpawnID)
	if sp != nil && sp.machine != nil {
		s.mu.Unlock()
		s.guestResize(sp, req)
		return
	}
	hasPty := sp != nil && sp.pty != nil
	var err error
	if hasPty {
		err = unix.IoctlSetWinsize(int(sp.pty.Fd()), unix.TIOCSWINSZ, &unix.Winsize{Row: uint16(*req.Rows), Col: uint16(*req.Cols)})
	}
	s.mu.Unlock()
	switch {
	case sp == nil:
		s.send(c, protocol.NewError("", req.SpawnID, protocol.CodeUnknownSpawn))
	case !hasPty:
		s.send(c, protocol.NewError("", req.SpawnID, protocol.CodeBadRequest))
	case err != nil:
		s.log.Error("spawn %s: resizing its terminal: %v", sp.id, err)
		s.send(c, protocol.NewError("", req.SpawnID, protocol.CodeInternal))
	}
}

// closePty closes the keeper's descriptor of the spawn's terminal; s.mu is
// held.
func (sp *spawn) closePty() {
	if sp.pty != nil {
		_ = sp.pty.Close()
		sp.pty = nil
	}
}

func (s *server) handleRelease(c *client, req *protocol.Request) {
	s.mu.Lock()
	sp := s.heldSpawn(c, req.SpawnID)
	s.mu.Unlock()
	if sp == nil {
		s.send(c, protocol.NewError("", req.SpawnID, protocol.CodeUnknownSpawn))
		return
	}
	s.retire(sp, time.Duration(*req.GraceMs)*time.Millisecond, true)
}

var signalNumbers = map[string]syscall.Signal{
	"SIGTERM": unix.SIGTERM,
	"SIGKILL": unix.SIGKILL,
	"SIGINT":  unix.SIGINT,
	"SIGHUP":  unix.SIGHUP,
	"SIGQUIT": unix.SIGQUIT,
	"SIGUSR1": unix.SIGUSR1,
	"SIGUSR2": unix.SIGUSR2,
}

// handleSpawn claims the place a spawn names before anything else is done,
// and starts the spawn in it. One naming a place the keeper does not hold,
// or one another spawn named, is refused. A spawn refused before the keeper
// made it is refused under its request's id alone, its place freed before
// the refusal is sent, so the client may place that id again. One refused
// once made is refused under the spawn id the keeper gave it too, and is
// retired after the refusal is sent, its exit settled first as none, since
// it was never spawned: its retirement frees the place once the spawn's
// group is removed, and then sends its `released`.
func (s *server) handleSpawn(c *client, req *protocol.Request) {
	if s.closing.Load() {
		return
	}
	// A start of a client whose end has begun is not made: its channel is
	// closed, and nothing answers.
	if !s.beginStart(c) {
		return
	}
	defer c.starts.Done()
	claim, limits := s.claimPlace(c, req)
	switch claim {
	case claimNone:
		s.log.Warn("spawn %s refused: the keeper holds no place %s of role %s with room, or another spawn named it", req.ID, req.Place, c.role.spec.Name)
		s.send(c, protocol.NewError(req.ID, "", protocol.CodeBadRequest))
		return
	case claimOthersPacks:
		s.log.Warn("spawn %s refused: its packs are not its place's athanor's, or role %s keeps none", req.ID, c.role.spec.Name)
		s.send(c, protocol.NewError(req.ID, "", protocol.CodeBadRequest))
		return
	}
	made, code := s.startSpawn(c, req, limits)
	switch {
	case code == "":
	case made == nil:
		s.mu.Lock()
		s.freePlace(c, req.Place)
		s.mu.Unlock()
		s.send(c, protocol.NewError(req.ID, "", code))
	default:
		// A start refused once made is retired before it counts as done
		// (c.starts): a role's end waiting for it then finds nothing of it.
		s.send(c, protocol.NewError(req.ID, made.id, code))
		made.exitOnce.Do(func() {})
		s.retire(made, 0, true)
		<-made.retired
	}
}

// startSpawn starts the spawn req asks for in the place it claimed. It
// answers the code it is refused with, or "" once it is spawned, and the
// spawn it made in the place, nil when it is refused before it made one.
func (s *server) startSpawn(c *client, req *protocol.Request, limits admission.Limits) (*spawn, string) {
	// A relay pool's space reaches nothing: it takes no hosts, and no kept
	// home or terminal, which are a program's, whose pool is routed. A pool
	// that is not the role's is refused below, as one the keeper does not
	// serve always was.
	spec, known := c.poolOf(req.Pool)
	if known && !spec.Routed() && (req.Hosts != nil || req.HomeMode == protocol.HomeKept || req.Pty != nil) {
		s.log.Warn("spawn %s refused: pool %s's spaces reach nothing, and it names hosts, a kept home or a pty", req.ID, req.Pool)
		return nil, protocol.CodeBadRequest
	}
	if c.role.groups == nil {
		s.log.Warn("spawn %s refused: its memory and CPU bounds are unavailable here", req.ID)
		return nil, protocol.CodeMemoryUnavailable
	}
	reach, code, err := s.spawnEgress(req)
	if err != nil {
		s.log.Warn("spawn %s refused: %v", req.ID, err)
		return nil, code
	}
	// The resolution may outlast the client's process: a command of a role
	// whose end has begun never starts.
	if s.clientEnded(c) {
		s.log.Warn("spawn %s refused: role %s's process ended as its hosts resolved", req.ID, c.role.spec.Name)
		return nil, protocol.CodeInternal
	}
	if req.HomeMode == protocol.HomeKept {
		return s.startKeptSpawn(c, req, spec.Reach, reach, known, limits)
	}
	// Every session of a person runs in their VM where the keeper gives the
	// wall, a scratch one too: its place names the VM.
	s.mu.Lock()
	var m *machine
	if p := c.places[req.Place]; p != nil {
		m = p.machine
	}
	s.mu.Unlock()
	if m != nil {
		if !known {
			return nil, protocol.CodeUnknownPool
		}
		return s.startScratchInMachine(c, req, m.athanor, spec.Reach, reach, limits)
	}
	s.mu.Lock()
	var p *pool.Pool
	if known {
		p = s.pools[req.Pool]
	}
	var uid int
	var ok bool
	if p != nil {
		uid, ok = p.Allocate(func(uid int) bool {
			c, err := procfs.ScanUID("/proc", uid, 0)
			if err != nil || c.Total() > 0 {
				return true
			}
			found, err := residue.Find(s.roots, uid)
			return err != nil || !found.Empty()
		})
	}
	s.mu.Unlock()
	switch {
	case p == nil:
		return nil, protocol.CodeUnknownPool
	case !ok:
		return nil, protocol.CodeCapacity
	}

	sp := &spawn{id: randomHex(16), client: c, pool: p, account: s.accounts[uid], reach: spec.Reach, limits: limits, retired: make(chan struct{})}
	s.madeIn(req.Place, sp)
	name, err := home.NewName(uid)
	if err != nil {
		s.log.Error("spawn %s: %v", req.ID, err)
		return sp, protocol.CodeInternal
	}
	sp.home = filepath.Join(c.role.homeRoot, name)

	if code, err := s.launch(sp, req, reach); err != nil {
		s.log.Error("spawn %s on uid %d: %v", req.ID, uid, err)
		return sp, code
	}
	if !s.hold(sp) {
		return sp, protocol.CodeInternal
	}
	s.log.Info("spawn %s: uid %d, leader pid %d", sp.id, uid, sp.leader.pid)
	s.send(c, protocol.NewSpawned(req.ID, sp.id, uid, sp.leader.pid))
	go s.watchLeader(sp)
	return sp, ""
}

// beginStart counts a spawn start of c in flight (c.starts) unless c's end
// has begun, and answers whether it did; the end, which begins under the
// same lock, waits for every start counted (endClient).
func (s *server) beginStart(c *client) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if c.ended {
		return false
	}
	c.starts.Add(1)
	return true
}

// clientEnded reports whether c's end has begun.
func (s *server) clientEnded(c *client) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return c.ended
}

// owns reports, with s.mu held, whether c still owns what it starts: its
// end has not begun (endClient marks it under s.mu), nor the keeper's.
func (s *server) owns(c *client) bool {
	return !c.ended && !s.closing.Load()
}

// errNotOwned refuses a start whose role's end, or the keeper's, began
// before anything of it reached its stage.
var errNotOwned = errors.New("its role's process, or the keeper, ended as it started")

// hold makes a started spawn one its client holds, unless that client's
// end has begun, which retires everything it held: such a spawn is refused
// and retired as any refused once made is.
func (s *server) hold(sp *spawn) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if sp.client.ended {
		s.log.Warn("spawn %s refused: role %s's process ended as it started", sp.id, sp.client.role.spec.Name)
		return false
	}
	s.spawns[sp.id] = sp
	return true
}

// launch starts the spawn's stage (startStage) and then releases it with
// its spec; a routed space's stage then hands up its namespace and name
// sockets, and only once the guard has admitted its route (admitRoute) is
// it told to go on. launch waits until the stage has executed the command,
// and starts the relay as the spawn's role's uid, in its role's leaf,
// holding the other ends of the command's pipes and, when the request asks
// for a control channel, the relay's end of its socketpair; the command's
// end goes to the stage, which makes it the command's fd 3. A failure kills
// the stage, which has executed nothing. It returns the error code to
// reply with.
func (s *server) launch(sp *spawn, req *protocol.Request, e egress) (string, error) {
	var opened []*os.File
	closeAll := func() {
		for _, f := range opened {
			_ = f.Close()
		}
	}
	defer closeAll()
	pipe := func() (*os.File, *os.File, error) {
		r, w, err := os.Pipe()
		if err == nil {
			opened = append(opened, r, w)
		}
		return r, w, err
	}

	stdinR, stdinW, err := pipe()
	if err != nil {
		return protocol.CodeInternal, err
	}
	stdoutR, stdoutW, err := pipe()
	if err != nil {
		return protocol.CodeInternal, err
	}
	stderrR, stderrW, err := pipe()
	if err != nil {
		return protocol.CodeInternal, err
	}
	specR, specW, err := pipe()
	if err != nil {
		return protocol.CodeInternal, err
	}
	statusR, statusW, err := pipe()
	if err != nil {
		return protocol.CodeInternal, err
	}
	socketpair := func(name string) (*os.File, *os.File, error) {
		fds, err := unix.Socketpair(unix.AF_UNIX, unix.SOCK_STREAM|unix.SOCK_CLOEXEC, 0)
		if err != nil {
			return nil, nil, err
		}
		command, helper := os.NewFile(uintptr(fds[0]), name+"-command"), os.NewFile(uintptr(fds[1]), name+"-relay")
		opened = append(opened, command, helper)
		return command, helper, nil
	}
	// The control channel is one socketpair: commandCtl becomes the
	// command's fd 3 (stage.ControlFD to the stage), relayCtl the relay's
	// relay.ControlFD. A relay space's relay is another: commandRelay
	// becomes the command's fd 4 (stage.RelayFD), helperRelay the relay's
	// relay.RelayFD, so control lines and relay frames never share a
	// socket. The keeper keeps no end of either. A routed space's route
	// socket is a third, at the stage's stage.RouteFD, whose other end,
	// keeperRoute, the keeper holds until the command executes.
	relayed := sp.reach == pool.ReachRelay
	var commandCtl, relayCtl, commandRelay, helperRelay, stageRoute, keeperRoute *os.File
	if req.Control {
		if commandCtl, relayCtl, err = socketpair("control"); err != nil {
			return protocol.CodeInternal, err
		}
	}
	if relayed {
		if commandRelay, helperRelay, err = socketpair("relay"); err != nil {
			return protocol.CodeInternal, err
		}
	} else if stageRoute, keeperRoute, err = keeperPair("route"); err != nil {
		return protocol.CodeInternal, err
	} else {
		opened = append(opened, stageRoute, keeperRoute)
	}

	// The spawn's group exists before its stage does, and the stage
	// is moved into it while it still waits for its spec, so nothing of the
	// spawn runs outside the bound; the stage checks where it is for itself.
	r := sp.client.role
	groupName := cgroup.Name(sp.account.UID)
	homeRoot := r.homeRoot
	if sp.kept {
		groupName = cgroup.SpawnName(sp.id)
		homeRoot = s.cfg.Kept.Root
	}
	group, err := r.groups.Create(groupName, sp.limits.MemoryBytes, sp.limits.Processors*cgroup.CPUPeriod)
	if err != nil {
		return protocol.CodeInternal, err
	}
	sp.group = group
	packs := ""
	if req.Packs != nil {
		path, empty, release, err := s.packs.Acquire(req.Packs.Athanor, req.Packs.Digest)
		if err != nil {
			return protocol.CodeBadRequest, fmt.Errorf("its packs: %w", err)
		}
		sp.packs = release
		if !empty {
			packs = path
		}
	}

	spec, err := json.Marshal(stage.Spec{
		UID:      sp.account.UID,
		GID:      sp.account.GID,
		User:     sp.account.Name,
		HomeRoot: homeRoot,
		Home:     sp.home,
		Work:     sp.work,
		Kept:     sp.kept,
		Argv:     req.Argv,
		Env:      req.Env,
		Limits:   limits(sp.kept, req.Rlimits),
		Control:  req.Control,
		Terminal: req.Pty != nil,
		Reach:    sp.reach,
		Cgroup:   group.Path(),
		Packs:    packs,
		KeptRoot: s.keptRoot(),
	})
	if err != nil {
		return protocol.CodeInternal, err
	}
	stageFiles := []uintptr{stdinR.Fd(), stdoutW.Fd(), stderrW.Fd(), specR.Fd(), statusW.Fd()}
	stageOwned := []*os.File{stdinR, stdoutW, stderrW, specR, statusW}
	// A pty spawn's stdin, stdout and stderr are a terminal of its space's
	// own, which the space's first process opens and whose master it hands
	// up over the terminal socket (stage.TerminalFD); the stage itself has
	// none. The relay holds the master as its stdin and its stdout, and its
	// stderr is a pipe no one writes, which ends at once. The keeper keeps
	// a descriptor of the master as sp.pty, which a `resize` sets the size
	// through; the spawn's retirement closes it, after a failure here too.
	pty := req.Pty != nil
	var stageTerminal, keeperTerminal *os.File
	if pty {
		devnull, err := os.Open(os.DevNull)
		if err != nil {
			return protocol.CodeInternal, err
		}
		opened = append(opened, devnull)
		if stageTerminal, keeperTerminal, err = keeperPair("terminal"); err != nil {
			return protocol.CodeInternal, err
		}
		opened = append(opened, stageTerminal, keeperTerminal)
		stageFiles = []uintptr{devnull.Fd(), devnull.Fd(), devnull.Fd(), specR.Fd(), statusW.Fd()}
		stageOwned = []*os.File{specR, statusW}
		_ = stderrW.Close()
	}
	// A descriptor of ^0 is closed in the child: a spawn without a control
	// channel has no stage.ControlFD before its stage.RelayFD or
	// stage.RouteFD.
	if commandCtl != nil {
		stageFiles = append(stageFiles, commandCtl.Fd())
		stageOwned = append(stageOwned, commandCtl)
	} else {
		stageFiles = append(stageFiles, ^uintptr(0))
	}
	if relayed {
		stageFiles = append(stageFiles, commandRelay.Fd())
		stageOwned = append(stageOwned, commandRelay)
	} else {
		stageFiles = append(stageFiles, stageRoute.Fd())
		stageOwned = append(stageOwned, stageRoute)
	}
	if pty {
		stageFiles = append(stageFiles, stageTerminal.Fd())
		stageOwned = append(stageOwned, stageTerminal)
	}
	if !relayed {
		// From here the end of the guard's connection finds this spawn
		// (guardLost); its retirement removes it.
		s.mu.Lock()
		if s.routing == nil {
			s.routing = map[string]*spawn{}
		}
		s.routing[sp.id] = sp
		s.mu.Unlock()
	}
	leader, err := s.startStage(stageFiles, sp.account, sp.group)
	for _, f := range stageOwned {
		_ = f.Close()
	}
	if leader == nil {
		return protocol.CodeInternal, err
	}
	sp.leader = leader
	// The stage waits for its spec still holding the keeper's ids, which
	// retirement under the pooled uid cannot end, and, routed, for its
	// route's word: it is killed here on every failure before the command
	// executes.
	started := false
	defer func() {
		if !started {
			s.signalChild(leader, unix.SIGKILL)
		}
	}()
	if err != nil {
		return protocol.CodeInternal, err
	}

	// The spec is all a relay space's stage waits for before it executes
	// the command: it is sent only while the spawn's role owns it, decided
	// in the critical section the role's end marks it ended in, so no end
	// comes between the check and the send. A routed space's stage waits
	// for its route's word too, held to the same rule in the same section
	// (admitRoute): the relay space's send and the routed one's word are
	// one check under s.mu.
	s.mu.Lock()
	if !s.owns(sp.client) {
		s.mu.Unlock()
		return protocol.CodeInternal, errNotOwned
	}
	_ = specW.SetWriteDeadline(time.Now().Add(stageTimeout))
	_, err = specW.Write(spec)
	s.mu.Unlock()
	if err != nil {
		return protocol.CodeExecFailed, err
	}
	_ = specW.Close()
	if !relayed {
		if code, err := s.admitSpawn(sp, keeperRoute, e); err != nil {
			return code, err
		}
	}
	if pty {
		master, err := receiveTerminal(keeperTerminal, uint16(*req.Pty.Rows), uint16(*req.Pty.Cols))
		if err != nil {
			reason, _ := readStatus(statusR)
			return protocol.CodeExecFailed, fmt.Errorf("the space's terminal: %w%s", err, reason)
		}
		opened = append(opened, master)
		masterIn, err := dupFile(master, "pty-stdin")
		if err != nil {
			return protocol.CodeInternal, err
		}
		opened = append(opened, masterIn)
		if sp.pty, err = dupFile(master, "pty-master"); err != nil {
			return protocol.CodeInternal, err
		}
		stdinW, stdoutR = masterIn, master
	}
	reason, err := readStatus(statusR)
	if err != nil {
		return protocol.CodeExecFailed, err
	}
	if len(reason) > 0 {
		return protocol.CodeExecFailed, errors.New("stage: " + string(reason))
	}
	started = true

	relaySpecR, relaySpecW, err := pipe()
	if err != nil {
		return protocol.CodeInternal, err
	}
	devnull, err := os.Open(os.DevNull)
	if err != nil {
		return protocol.CodeInternal, err
	}
	opened = append(opened, devnull)
	relaySpec, err := json.Marshal(relay.Spec{Path: req.Attach.Path, Token: req.Attach.Token, Control: req.Control, Relay: relayed})
	if err != nil {
		return protocol.CodeInternal, err
	}
	relayFiles := []uintptr{devnull.Fd(), devnull.Fd(), 2, relaySpecR.Fd(), stdinW.Fd(), stdoutR.Fd(), stderrR.Fd()}
	switch {
	case relayCtl != nil:
		relayFiles = append(relayFiles, relayCtl.Fd())
	case relayed:
		relayFiles = append(relayFiles, ^uintptr(0))
	}
	if relayed {
		relayFiles = append(relayFiles, helperRelay.Fd())
	}
	relayProc, err := s.start(s.self, []string{"cyfr-locus", "relay"}, helperEnviron(), relayFiles,
		r.account.UID, r.account.GID, "/")
	if err != nil {
		return protocol.CodeInternal, err
	}
	sp.relay = relayProc
	// The relay waits for its spec, doing nothing, until it is in its
	// role's leaf, whose bounds hold it as they hold the role.
	if err := r.leaf.Add(relayProc.pid); err != nil {
		return protocol.CodeInternal, err
	}
	_ = relaySpecW.SetWriteDeadline(time.Now().Add(stageTimeout))
	if _, err := relaySpecW.Write(relaySpec); err != nil {
		return protocol.CodeInternal, err
	}
	return "", nil
}

// startStage starts a space's stage, cloned into its space (spaceAttr) with
// files, maps its ids to acct's and places it in group, in that order: the
// stage waits for its spec, executing nothing, until its caller sends it.
// It answers the stage once started, which its caller kills on an error,
// this one's too; nil when none was started.
func (s *server) startStage(files []uintptr, acct Account, group *cgroup.Group) (*child, error) {
	leader, err := s.startWith(s.self, []string{"cyfr-locus", "stage"}, nil, files, "/", stage.SpaceAttr())
	if err != nil {
		return nil, err
	}
	if err := stage.MapIDs(leader.pid, acct.UID, acct.GID); err != nil {
		return leader, err
	}
	return leader, group.Add(leader.pid)
}

// keeperPair is a socketpair whose first end goes to a stage and whose
// second the keeper holds itself: non-blocking, so that a deadline set on
// it bounds the keeper's wait on the stage.
func keeperPair(name string) (stageEnd, keeperEnd *os.File, err error) {
	fds, err := unix.Socketpair(unix.AF_UNIX, unix.SOCK_STREAM|unix.SOCK_CLOEXEC, 0)
	if err != nil {
		return nil, nil, err
	}
	if err := unix.SetNonblock(fds[1], true); err != nil {
		_ = unix.Close(fds[0])
		_ = unix.Close(fds[1])
		return nil, nil, err
	}
	return os.NewFile(uintptr(fds[0]), name+"-stage"), os.NewFile(uintptr(fds[1]), name+"-keeper"), nil
}

// readStatus reads a stage's status pipe to its end, within stageTimeout:
// empty once the command has executed, the stage's reason otherwise.
func readStatus(statusR *os.File) (string, error) {
	_ = statusR.SetReadDeadline(time.Now().Add(stageTimeout))
	reason, err := io.ReadAll(io.LimitReader(statusR, 4096))
	return string(reason), err
}

// watchLeader reports the leader's exit and retires the spawn.
func (s *server) watchLeader(sp *spawn) {
	<-sp.leader.done
	s.reportExit(sp)
	s.retire(sp, leaderExitGrace, true)
}

// reportExit settles the spawn's one `exited`, with what the counters say
// killed it, once its leader is reaped or clearTimeout has passed: a
// retirement settles it before it removes the group, while the counters
// stand, however late the watcher runs, and waits for the reaping only that
// long, since a leader stuck in the kernel may never be reaped. A leader not
// reaped by then has SIGKILL's where the counters count a kill for memory,
// which takes every process of the group, and none now or later where they
// count none.
func (s *server) reportExit(sp *spawn) {
	sp.exitOnce.Do(func() {
		select {
		case <-sp.leader.done:
		case <-time.After(clearTimeout):
		}
		reaped := sp.leader.reaped()
		memory := s.memoryEnd(sp)
		if memory != nil {
			s.mu.Lock()
			sp.killedFor = *memory
			s.mu.Unlock()
		}
		if !reaped && memory == nil {
			return
		}
		var code *int
		var sig *string
		switch {
		case !reaped:
			name := unix.SignalName(unix.SIGKILL)
			sig = &name
		case sp.leader.status.Signaled():
			signal := sp.leader.status.Signal()
			name := unix.SignalName(signal)
			if name == "" {
				name = signal.String()
			}
			sig = &name
		default:
			c := sp.leader.status.ExitStatus()
			code = &c
		}
		s.send(sp.client, protocol.NewExited(sp.id, code, sig, memory))
	})
}

// readKill reads, for a retirement that reports no exit (its role's
// death), what the kernel killed processes of the spawn for, while its
// group's counters stand, so its release counts the kill as an exit's
// would. Its processes are gone by then, so the counters are final, and the
// kill is counted once, at the release (forget).
func (s *server) readKill(sp *spawn) {
	if memory := s.memoryEnd(sp); memory != nil {
		s.mu.Lock()
		sp.killedFor = *memory
		s.mu.Unlock()
	}
}

// memoryEnd says what the kernel killed processes of the spawn for, as its
// group's counters say (cgroup.KilledFor): its own bound (MemoryCap), a
// limit above it (MemoryMachine), or one of the two that they cannot tell
// apart (MemoryEither), which is never reported as the cap; nil for no kill,
// or for counters that do not read. The kernel counts a kill before it
// delivers it, so a leader reaped after one finds it counted.
func (s *server) memoryEnd(sp *spawn) *string {
	if sp.group == nil {
		return nil
	}
	var memory string
	cause, err := sp.group.KilledFor()
	switch {
	case err != nil:
		s.log.Error("spawn %s: reading its memory counters: %v", sp.id, err)
		return nil
	case cause == cgroup.AtBound:
		memory = protocol.MemoryCap
		s.log.Warn("spawn %s: uid %d reached its memory bound and the kernel killed its processes", sp.id, sp.account.UID)
	case cause == cgroup.Above:
		memory = protocol.MemoryMachine
		s.log.Warn("spawn %s: processes of uid %d were killed for a memory limit above the spawn's own, the container's or the machine's", sp.id, sp.account.UID)
	case cause == cgroup.Either:
		memory = protocol.MemoryEither
		s.log.Warn("spawn %s: processes of uid %d were killed for memory, and the counters do not say whether at the spawn's own bound or above it", sp.id, sp.account.UID)
	default:
		return nil
	}
	return &memory
}

// retire ends a spawn once: every process of its uid is terminated, what
// the uid left behind is removed and the uid returned to its pool, or
// quarantined if a process or anything it left survives. With notify,
// `released` follows, once the spawn's relay has ended and its group is
// removed.
func (s *server) retire(sp *spawn, grace time.Duration, notify bool) {
	if sp.machine != nil {
		s.retireGuest(sp, grace, notify)
		return
	}
	if sp.kept {
		s.retireKept(sp, grace, notify)
		return
	}
	sp.retireOnce.Do(func() {
		s.mu.Lock()
		s.ending(sp)
		s.mu.Unlock()
		go func() {
			defer close(sp.retired)
			uid := sp.account.UID
			var paths []string
			if sp.home != "" {
				paths = []string{sp.home}
			}
			clean := s.scrub(sp.account, grace, paths, "")
			// Its processes are gone, or past every kill: its route carries
			// nothing more.
			s.withdrawRoute(sp.id, &sp.route)
			// The relay's end is its own and its reader's: it has handed the
			// reader the end of every stream, which closes once the spawn's
			// processes are gone, or the reader has closed its connection.
			// Nothing here cuts it, so `released` follows the last byte the
			// reader took.
			if sp.relay != nil {
				<-sp.relay.done
			}
			if notify {
				s.reportExit(sp)
			} else {
				s.readKill(sp)
			}
			// A group is removable once it holds no process, which a clean
			// scrub has established. A clean uid whose group stays goes back
			// to its pool only once the group is removed: the next spawn
			// under the uid takes the group's name.
			removed := s.removeSpawnGroup(sp)

			s.mu.Lock()
			switch {
			case !clean:
				_ = sp.pool.Quarantine(uid)
			case removed:
				_ = sp.pool.Release(uid)
			}
			s.leave(sp, removed, removal{notify: notify, clean: clean})
			s.mu.Unlock()

			if !clean {
				s.log.Warn("spawn %s: uid %d quarantined: a process or something it left outlived retirement", sp.id, uid)
			}
			if !removed {
				return
			}
			if clean {
				s.log.Info("spawn %s: uid %d retired", sp.id, uid)
			}
			if notify {
				s.send(sp.client, protocol.NewReleased(sp.id))
			}
		}()
	})
}

// removeSpawnGroup removes a retired spawn's group, where it has one, and
// says whether none is left.
func (s *server) removeSpawnGroup(sp *spawn) bool {
	if sp.group == nil {
		return true
	}
	if err := removeGroup(sp.group); err != nil {
		s.log.Warn("spawn %s: its memory group of uid %d stays, its place and its release held until a retry removes it: %v", sp.id, sp.account.UID, err)
		return false
	}
	return true
}

// leave is a retirement's last step, with s.mu held. A spawn whose group
// was removed leaves spawns, its place with it, in this one step. One whose
// group stays keeps its place, still read and measured, a started one stays
// in spawns, and it waits in unremoved for the reader's retry of the
// removal, which finishes what left says: until then a release of a started
// one waits as its retirement's `released` does, and no `unknown_spawn`
// answers it.
func (s *server) leave(sp *spawn, removed bool, left removal) {
	sp.closePty()
	if !removed {
		s.unremoved[sp] = &left
		return
	}
	s.forget(sp)
}

// forget is a spawn's final release, with s.mu held: it leaves spawns, a
// kill for memory its exit settled is counted, once, as its place goes with
// its routing, and the generation of packs its space binds is let go only
// now, its group gone, so no start can remove files a process of it may
// still read.
func (s *server) forget(sp *spawn) {
	delete(s.spawns, sp.id)
	if p := sp.client.places[sp.place]; p != nil && p.spawn == sp && sp.killedFor != "" {
		s.ledger.Killed(p.entry, sp.killedFor, now())
	}
	s.freePlace(sp.client, sp.place)
	delete(s.routing, sp.id)
	sp.releasePacks()
}

// scrub retires a uid until nothing of it remains: `cyfr-locus retire` ends
// its processes and removes its message queues and the given paths; then the keeper looks for anything else the uid owns on the
// writable mounts and retires it again with what it found. It reports
// whether the uid is clean.
func (s *server) scrub(acct Account, grace time.Duration, paths []string, except string) bool {
	for pass := 1; ; pass++ {
		if exit := s.runRetire(acct, paths, grace); exit != retire.ExitClean && exit != retire.ExitResidue {
			return false
		}
		if !s.waitClear(acct.UID) {
			return false
		}
		found, err := residue.FindExcept(s.roots, acct.UID, except)
		if err != nil {
			s.log.Error("uid %d: looking for what it left: %v", acct.UID, err)
			return false
		}
		if found.Empty() {
			return true
		}
		if pass == scrubPasses {
			s.log.Warn("uid %d: %d entries (truncated: %t) and %d message queues outlived retirement",
				acct.UID, len(found.Paths), found.Truncated, len(found.Queues))
			return false
		}
		paths, grace = found.Paths, 0
	}
}

// runRetire runs `cyfr-locus retire` as the account and returns its exit
// status, or -1 when it could not be run or did not exit.
func (s *server) runRetire(acct Account, paths []string, grace time.Duration) int {
	spec, err := json.Marshal(retire.Spec{UID: acct.UID, GraceMs: grace.Milliseconds(), Paths: paths})
	if err != nil {
		return -1
	}
	specR, specW, err := os.Pipe()
	if err != nil {
		s.log.Error("retire uid %d: %v", acct.UID, err)
		return -1
	}
	defer specW.Close()
	devnull, err := os.Open(os.DevNull)
	if err != nil {
		specR.Close()
		return -1
	}
	c, err := s.start(s.self, []string{"cyfr-locus", "retire"}, helperEnviron(),
		[]uintptr{devnull.Fd(), devnull.Fd(), 2, specR.Fd()}, acct.UID, acct.GID, "/")
	specR.Close()
	devnull.Close()
	if err != nil {
		s.log.Error("retire uid %d: %v", acct.UID, err)
		return -1
	}
	_ = specW.SetWriteDeadline(time.Now().Add(stageTimeout))
	_, _ = specW.Write(spec)
	_ = specW.Close()

	select {
	case <-c.done:
	case <-time.After(grace + 15*time.Second):
		s.log.Error("retire uid %d did not finish; killing it", acct.UID)
		s.signalChild(c, unix.SIGKILL)
		<-c.done
	}
	if !c.status.Exited() {
		return -1
	}
	return c.status.ExitStatus()
}

// waitClear waits for every process of uid, zombies included, to be gone.
func (s *server) waitClear(uid int) bool {
	deadline := time.Now().Add(clearTimeout)
	for {
		s.reap()
		c, err := procfs.ScanUID("/proc", uid, 0)
		if err == nil && c.Total() == 0 {
			return true
		}
		if time.Now().After(deadline) {
			return false
		}
		time.Sleep(20 * time.Millisecond)
	}
}

// sweeper retries retirement of quarantined uids every sweepInterval.
func (s *server) sweeper() {
	tick := time.NewTicker(sweepInterval)
	defer tick.Stop()
	for range tick.C {
		s.sweep()
	}
}

// sweep retries retirement of every quarantined uid, kept or pooled, and
// returns each pooled one to its pool once nothing of it remains, its group
// included.
func (s *server) sweep() {
	type entry struct {
		pool *pool.Pool
		uid  int
	}
	var todo []entry
	s.mu.Lock()
	for _, p := range s.pools {
		for _, uid := range p.Quarantined() {
			todo = append(todo, entry{p, uid})
		}
	}
	s.mu.Unlock()
	s.sweepKept()
	if s.guard != nil {
		s.retryClears()
		s.retryNarrowing()
		s.finishMachines()
		s.endIdleMachines()
	}
	for _, e := range todo {
		if !s.scrub(s.accounts[e.uid], 0, nil, "") {
			continue
		}
		// A uid whose group stays goes back to its pool only once the
		// reader's retry removed the group, whose name the next spawn
		// under the uid would take.
		s.mu.Lock()
		stays := false
		for sp := range s.unremoved {
			if sp.pool == e.pool && sp.account.UID == e.uid {
				stays = true
				break
			}
		}
		s.mu.Unlock()
		if stays {
			continue
		}
		s.mu.Lock()
		_ = e.pool.Release(e.uid)
		s.mu.Unlock()
		s.log.Info("uid %d returned to pool %s", e.uid, e.pool.Spec().Name)
	}
}

// helperEnviron is the environment of relay and retire processes.
func helperEnviron() []string {
	if v := os.Getenv("CYFR_LOG_FORMAT"); v != "" {
		return []string{"CYFR_LOG_FORMAT=" + v}
	}
	return []string{}
}

// socketID is the name /proc/<pid>/fd gives the socket f: `socket:[inode]`.
func socketID(f *os.File) (string, error) {
	var st unix.Stat_t
	if err := unix.Fstat(int(f.Fd()), &st); err != nil {
		return "", err
	}
	return "socket:[" + strconv.FormatUint(st.Ino, 10) + "]", nil
}

// randomHex is n random bytes in hex. crypto/rand.Read never returns an
// error: it ends the process first.
func randomHex(n int) string {
	b := make([]byte, n)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

// limits are a spawn's resource limits: the ceilings lowered by its
// request, with no file-size limit of its own for a kept spawn, whose disk
// its home's bound and the kept homes' volume hold.
func limits(kept bool, r *protocol.Rlimits) protocol.Limits {
	if kept {
		return r.ResolveKept()
	}
	return r.Resolve()
}
