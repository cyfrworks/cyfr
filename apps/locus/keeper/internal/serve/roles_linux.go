// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package serve

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"time"

	"golang.org/x/sys/unix"

	"github.com/cyfr/locus/keeper/guard"
	"github.com/cyfr/locus/keeper/internal/home"
	"github.com/cyfr/locus/keeper/internal/pool"
	"github.com/cyfr/locus/keeper/internal/stage"
)

// A role's process runs in a space of its own, as every spawn does
// (package stage): its uid mapped to itself, no capability, its own user,
// pid, IPC, mount, cgroup and network namespaces, routed by the guard as a
// role at its port, the image read-only, its own /proc, /tmp and /dev/shm,
// and its run folder writable at the same path it has outside, where the
// relays the keeper starts for its spawns reach the sockets it listens on.
// It sees no other role's run folder, no home root and no kept root. Its
// environment is RoleEnviron's, its channel to the keeper is a socketpair
// on its fd 3, and its group is its role's leaf.

// startRole starts r's process in its space with a fresh channel, and
// answers it once the command has executed: its route admitted by the
// guard first, so it is never started without it. From its channel's
// making the start is r's starting until its caller publishes it
// (publishRole). A failure ends the space, its route withdrawn, and
// answers why.
func (s *server) startRole(r *role) (*client, error) {
	fds, err := unix.Socketpair(unix.AF_UNIX, unix.SOCK_STREAM|unix.SOCK_CLOEXEC, 0)
	if err != nil {
		return nil, fmt.Errorf("its channel: %w", err)
	}
	if err := unix.SetNonblock(fds[0], true); err != nil {
		_ = unix.Close(fds[0])
		_ = unix.Close(fds[1])
		return nil, fmt.Errorf("its channel: %w", err)
	}
	c := &client{role: r, id: randomHex(16), channel: os.NewFile(uintptr(fds[0]), "channel-"+r.spec.Name), places: map[string]*place{}}
	theirs := os.NewFile(uintptr(fds[1]), "role-channel-"+r.spec.Name)
	s.mu.Lock()
	r.starting = c
	s.mu.Unlock()
	defer func() {
		if c.proc == nil {
			s.mu.Lock()
			if r.starting == c {
				r.starting = nil
			}
			s.mu.Unlock()
		}
	}()
	defer theirs.Close()
	channelID, err := socketID(theirs)
	if err != nil {
		_ = c.channel.Close()
		return nil, fmt.Errorf("its channel: %w", err)
	}
	spec, err := json.Marshal(stage.Spec{
		UID:      r.account.UID,
		GID:      r.account.GID,
		User:     r.account.Name,
		Role:     r.spec.Name,
		HomeRoot: s.runRoot,
		Home:     r.runDir,
		Argv:     s.cfg.Command,
		Env:      RoleEnviron(os.Environ(), r.spec, r.runDir, channelID),
		Control:  true,
		Reach:    pool.ReachRouted,
		Cgroup:   r.leaf.Path(),
	})
	if err != nil {
		_ = c.channel.Close()
		return nil, err
	}

	var opened []*os.File
	defer func() {
		for _, f := range opened {
			_ = f.Close()
		}
	}()
	specR, specW, err := os.Pipe()
	if err == nil {
		opened = append(opened, specR, specW)
	}
	var statusR, statusW, stageRoute, keeperRoute *os.File
	if err == nil {
		if statusR, statusW, err = os.Pipe(); err == nil {
			opened = append(opened, statusR, statusW)
		}
	}
	if err == nil {
		if stageRoute, keeperRoute, err = keeperPair("route"); err == nil {
			opened = append(opened, stageRoute, keeperRoute)
		}
	}
	if err != nil {
		_ = c.channel.Close()
		return nil, err
	}
	// The role's stdio is the keeper's own; its channel goes to the stage
	// as a spawn's control channel does, to be the command's fd 3.
	leader, err := s.startStage([]uintptr{0, 1, 2, specR.Fd(), statusW.Fd(), theirs.Fd(), stageRoute.Fd()}, r.account, r.leaf)
	for _, f := range []*os.File{specR, statusW, theirs, stageRoute} {
		_ = f.Close()
	}
	started := false
	defer func() {
		if started {
			return
		}
		if leader != nil {
			s.signalChild(leader, unix.SIGKILL)
			<-leader.done
		}
		s.withdrawRoute(c.id, &c.route)
		_ = c.channel.Close()
	}()
	if err != nil {
		return nil, fmt.Errorf("its space's stage: %w", err)
	}
	_ = specW.SetWriteDeadline(time.Now().Add(stageTimeout))
	if _, err := specW.Write(spec); err != nil {
		return nil, fmt.Errorf("its space's spec: %w", err)
	}
	_ = specW.Close()
	if _, err := s.admitRoute(keeperRoute, &c.route, nil, func(netns, udp, tcp *os.File) (guard.Route, error) {
		return s.guard.AdmitRole(c.id, r.spec.Port, r.spec.Private, netns, udp, tcp)
	}); err != nil {
		return nil, err
	}
	reason, err := readStatus(statusR)
	if err == nil && reason != "" {
		err = errors.New("its space's stage: " + reason)
	}
	if err != nil {
		return nil, err
	}
	c.proc = leader
	started = true
	return c, nil
}

// keepRole serves r's process standing and, at each end of it, its death
// or its channel's end, ends what it held (endClient) and starts it again
// alone after restartAfter, with a fresh channel and account, until the
// keeper stops or ends. The other roles run on untouched. A start that
// fails is tried again after restartAfter.
func (s *server) keepRole(r *role) {
	s.mu.Lock()
	c := r.client
	s.mu.Unlock()
	for {
		lost := make(chan struct{})
		// The reader takes this start's client, whatever c names by the
		// time it runs: an end that wins the race sets c to nil below.
		go func(c *client) {
			if s.readerStarts != nil {
				s.readerStarts(r)
			}
			s.serveChannel(c)
			close(lost)
		}(c)
		why := "its channel ended"
		select {
		case <-c.proc.done:
			why = "its process ended " + describeStatus(c.proc.status)
		case <-lost:
		}
		s.endClient(c)
		if s.stopping.Load() || s.closing.Load() {
			s.log.Info("role %s: %s; every spawn it held is retired", r.spec.Name, why)
			return
		}
		s.log.Warn("role %s: %s; every spawn it held is retired, and it starts again alone in %v", r.spec.Name, why, restartAfter)
		for c = nil; c == nil; {
			select {
			case <-time.After(restartAfter):
			case <-s.ended:
				return
			}
			if s.stopping.Load() || s.closing.Load() {
				return
			}
			next, err := s.startRole(r)
			if err != nil {
				s.log.Error("role %s: starting it again: %v; it is tried again in %v", r.spec.Name, err, restartAfter)
				continue
			}
			// A stop or an end that came during the start finds no process
			// to ask, so this one is ended here, and nothing asks it twice.
			if ending := s.publishRole(r, next); ending {
				s.endClient(next)
				return
			}
			c = next
		}
		s.log.Info("role %s: pid %d started again as %s", r.spec.Name, c.proc.pid, r.account.Name)
	}
}

// publishRole makes c, a start of r that startRole answered, r's process
// standing, and answers whether the keeper is stopping or ending. The
// guard's loss, which looks under the same lock, finds c either as r's
// start or as its process standing (guardLost).
func (s *server) publishRole(r *role, c *client) (ending bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	r.client = c
	if r.starting == c {
		r.starting = nil
	}
	return s.stopping.Load() || s.closing.Load()
}

// endClient ends c and everything it held: its channel, every process of
// its space and its relays, which its role's leaf holds, its route, and
// every spawn and place it held, each spawn retired before it returns. A
// role whose processes outlive their group's kill, or whose spawns do not
// retire within retireTimeout, or whose spawn starts in flight do not end
// within startsTimeout, ends the keeper: a role does not start again beside
// what its last start left. It may be called again for c, which then does
// what is left.
func (s *server) endClient(c *client) {
	s.mu.Lock()
	c.ended = true
	if c.role.client == c {
		c.role.client = nil
	}
	var held []*spawn
	for _, sp := range s.spawns {
		if sp.client == c {
			held = append(held, sp)
		}
	}
	s.mu.Unlock()
	_ = c.channel.Close()
	s.signalChild(c.proc, unix.SIGKILL)
	emptied := c.role.leaf.KillBy(time.Now())
	select {
	case <-c.proc.done:
	case <-time.After(retireTimeout):
		emptied = false
	}
	if !emptied {
		s.log.Error("role %s: processes of its space or its relays outlived their group's kill; the keeper ends", c.role.spec.Name)
		s.end(ExitLost)
	}
	s.withdrawRoute(c.id, &c.route)
	if s.packs != nil {
		s.packs.End(&c.packs)
	}
	for _, sp := range held {
		s.retire(sp, lostGrace, false)
	}
	if !s.awaitRetired(held) {
		s.log.Error("role %s: its spawns did not retire within %v; the keeper ends", c.role.spec.Name, retireTimeout)
		s.end(ExitLost)
	}
	// A start in flight as the end began is refused at its ownership check
	// or, past it, as it is held, and retired (handleSpawn): the role
	// starts again only once each has.
	if !s.awaitStarts(c) {
		s.log.Error("role %s: its spawns' starts did not end within %v; the keeper ends", c.role.spec.Name, startsTimeout)
		s.end(ExitLost)
	}
}

// awaitStarts waits up to startsTimeout for c's spawn starts in flight
// (c.starts), and answers whether every one ended.
func (s *server) awaitStarts(c *client) bool {
	done := make(chan struct{})
	go func() {
		c.starts.Wait()
		close(done)
	}()
	select {
	case <-done:
		return true
	case <-time.After(startsTimeout):
		return false
	}
}

// endRoles kills every role's process standing and closes its channel;
// each one's keepRole ends the rest (endClient).
func (s *server) endRoles() {
	s.mu.Lock()
	var standing []*client
	for _, r := range s.roles {
		if r.client != nil {
			standing = append(standing, r.client)
		}
	}
	s.mu.Unlock()
	for _, c := range standing {
		_ = c.channel.Close()
		s.signalChild(c.proc, unix.SIGKILL)
	}
}

// signalRoles passes sig to every role's process standing: its space's
// waiter passes it to the init, which passes it to the command alone
// (package stage).
func (s *server) signalRoles(sig syscall.Signal) {
	s.mu.Lock()
	var standing []*client
	for _, r := range s.roles {
		if r.client != nil {
			standing = append(standing, r.client)
		}
	}
	s.mu.Unlock()
	for _, c := range standing {
		s.signalChild(c.proc, sig)
	}
}

// roleNames lists the roles' names for the log.
func roleNames(roles []*role) string {
	names := make([]string, len(roles))
	for i, r := range roles {
		names[i] = r.spec.Name
	}
	return strings.Join(names, ", ")
}

// describeStatus says how a process ended, for the log.
func describeStatus(ws unix.WaitStatus) string {
	if ws.Signaled() {
		return "by " + unix.SignalName(ws.Signal())
	}
	return fmt.Sprintf("with %d", ws.ExitStatus())
}

// RunRootMode is the run root's mode while the roles run: only its owner,
// uid 0, makes anything in it, and each role enters its own folder alone.
const RunRootMode = os.ModeDir | 0o711

// makeRunDirs makes each role's run folder under root, 0700 and its uid's.
// The keeper holds no capability over files it does not own, so a folder is
// made by its role's uid itself (makeOwnDir), under the root opened to
// others (sticky, 0733) for that alone and closed again (RunRootMode) before
// any role runs: no role makes or takes anything there. A folder already
// there must be its role's. The root must be a directory of uid 0.
func makeRunDirs(root string, roles []*role) (err error) {
	info, err := os.Lstat(root)
	if err != nil {
		return fmt.Errorf("the run root: %w", err)
	}
	st, ok := info.Sys().(*syscall.Stat_t)
	if !info.IsDir() || !ok || st.Uid != 0 {
		return fmt.Errorf("the run root %s is not a directory of uid 0", root)
	}
	if err := os.Chmod(root, os.ModeSticky|0o733); err != nil {
		return fmt.Errorf("opening the run root %s to its roles: %w", root, err)
	}
	defer func() {
		if cerr := os.Chmod(root, RunRootMode.Perm()); cerr != nil && err == nil {
			err = fmt.Errorf("closing the run root %s: %w", root, cerr)
		}
	}()
	for _, r := range roles {
		if err := makeOwnDir(r.runDir, r.account.UID, r.account.GID); err != nil {
			return fmt.Errorf("role %s's run folder %s: %w", r.spec.Name, r.runDir, err)
		}
		if err := home.CheckOwnDir(r.runDir, r.account.UID, errors.New("not the role's own 0700 folder")); err != nil {
			return fmt.Errorf("role %s's run folder: %w", r.spec.Name, err)
		}
	}
	return nil
}

// makeOwnDir makes path a 0700 folder of uid and gid as they would, on a
// thread that takes their file ids and ends with its goroutine, never
// unlocked, so no other goroutine runs with them. Before it answers, on
// success and on failure alike, the thread takes the keeper's own file ids
// back and reads them from its own status (threadFileIDs): a goroutine that
// ends locked on the process's main thread leaves that thread parked, not
// gone, and the main thread's ids are the keeper's as /proc shows them. A
// folder already there is made 0700 only where it is theirs.
func makeOwnDir(path string, uid, gid int) error {
	done := make(chan error, 1)
	ownUID, ownGID := unix.Getuid(), unix.Getgid()
	go func() {
		runtime.LockOSThread()
		err := asFileIDs(uid, gid, func() error {
			if err := unix.Mkdir(path, 0o700); err != nil && !errors.Is(err, unix.EEXIST) {
				return err
			}
			return unix.Chmod(path, 0o700)
		})
		_ = unix.Setfsuid(ownUID)
		_ = unix.Setfsgid(ownGID)
		if fsUID, fsGID, rerr := threadFileIDs(); rerr != nil || fsUID != ownUID || fsGID != ownGID {
			err = errors.Join(err, fmt.Errorf("the thread's file ids are %d:%d after their restoration, not the keeper's %d:%d (%v)", fsUID, fsGID, ownUID, ownGID, rerr))
		}
		done <- err
	}()
	return <-done
}

// asFileIDs runs fn on the calling thread, which the caller has locked,
// under the file ids uid and gid, which it reads back first.
func asFileIDs(uid, gid int, fn func() error) error {
	_ = unix.Setfsgid(gid)
	_ = unix.Setfsuid(uid)
	// setfsuid and setfsgid answer the ids before, never an error: the
	// ids the thread now holds are read back.
	if got, _ := unix.SetfsuidRetUid(-1); got != uid {
		return fmt.Errorf("the thread's file uid is %d, not %d", got, uid)
	}
	if got, _ := unix.SetfsgidRetGid(-1); got != gid {
		return fmt.Errorf("the thread's file gid is %d, not %d", got, gid)
	}
	return fn()
}

// threadFileIDs reads the calling thread's file uid and gid, the fourth of
// the Uid and Gid lines of /proc/thread-self/status.
func threadFileIDs() (uid, gid int, err error) {
	status, err := os.ReadFile("/proc/thread-self/status")
	if err != nil {
		return 0, 0, err
	}
	ids := map[string]int{}
	for _, line := range strings.Split(string(status), "\n") {
		name, rest, ok := strings.Cut(line, ":")
		if f := strings.Fields(rest); ok && (name == "Uid" || name == "Gid") && len(f) == 4 {
			if ids[name], err = strconv.Atoi(f[3]); err != nil {
				return 0, 0, err
			}
		}
	}
	u, okU := ids["Uid"]
	g, okG := ids["Gid"]
	if !okU || !okG {
		return 0, 0, errors.New("no Uid or Gid line of four ids")
	}
	return u, g, nil
}
