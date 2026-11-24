// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package serve

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
	"unsafe"

	"golang.org/x/sys/unix"

	"github.com/cyfr/locus/keeper/internal/cgroup"
	"github.com/cyfr/locus/keeper/internal/home"
	"github.com/cyfr/locus/keeper/internal/protocol"
)

const (
	// helperTimeout bounds one `cyfr-locus home` run.
	helperTimeout = 30 * time.Second
	// homeRetireGrace is the grace a home's processes get before a
	// home_retire kills them.
	homeRetireGrace = time.Second
	// keptRetireWait bounds how long a kept spawn of a home waits for its
	// uid's retirement to finish before it is refused as CodeUIDBusy.
	keptRetireWait = 30 * time.Second
)

// keptLock is the lock of a kept home's uid.
func (s *server) keptLock(uid int) *sync.Mutex {
	s.mu.Lock()
	defer s.mu.Unlock()
	l := s.keptOps[uid]
	if l == nil {
		l = &sync.Mutex{}
		s.keptOps[uid] = l
	}
	return l
}

// keptMaps makes the kept uids' state maps; s.mu is held.
func (s *server) keptMaps() {
	if s.keptLive == nil {
		s.keptLive = map[int]int{}
	}
	if s.keptHomes == nil {
		s.keptHomes = map[int]string{}
	}
	if s.keptRetiring == nil {
		s.keptRetiring = map[int]chan struct{}{}
	}
	if s.keptEnding == nil {
		s.keptEnding = map[int]int{}
	}
	if s.keptQuarantined == nil {
		s.keptQuarantined = map[int]string{}
	}
}

// keptState is why a kept home's uid cannot take the home at path now,
// with s.mu held: the channel its retirement closes when it is retiring,
// busy when it is quarantined or live under another home.
func (s *server) keptState(uid int, path string) (retiring chan struct{}, busy bool) {
	s.keptMaps()
	if _, q := s.keptQuarantined[uid]; q {
		return nil, true
	}
	if ch := s.keptRetiring[uid]; ch != nil {
		return ch, false
	}
	return nil, s.keptLive[uid] > 0 && s.keptHomes[uid] != path
}

// sweepKept retries the retirement of every quarantined kept uid, as the
// sweeper retries a pooled one, and frees each once nothing of it remains.
func (s *server) sweepKept() {
	s.mu.Lock()
	s.keptMaps()
	todo := make(map[int]string, len(s.keptQuarantined))
	for uid, path := range s.keptQuarantined {
		todo[uid] = path
	}
	s.mu.Unlock()
	for uid, path := range todo {
		lock := s.keptLock(uid)
		lock.Lock()
		clean := s.scrub(KeptAccount(uid), 0, nil, path)
		if clean {
			s.mu.Lock()
			delete(s.keptQuarantined, uid)
			s.mu.Unlock()
			s.log.Info("kept uid %d retired after its quarantine", uid)
		}
		lock.Unlock()
	}
}

// keptHome checks a kept home's path and uid against --kept-homes.
func (s *server) keptHome(path string, uid *uint64) (int, error) {
	if s.cfg.Kept == nil {
		return 0, errors.New("this keeper keeps no homes (no --kept-homes)")
	}
	if uid == nil {
		return 0, errors.New("no uid")
	}
	id := int(*uid)
	return id, s.cfg.Kept.Validate(path, id)
}

// startKeptSpawn starts a spawn in a made kept home, under the home's own
// uid and no uid of a pool, refused as CodeHomeOverCap when the home already
// holds its home_max_bytes. Its start holds the uid's lock, so it never
// starts during the uid's full retirement or a home request. Every session
// of the home shares the uid and its files, and each has its own space and
// route, which reaches what its own start resolved. It answers as
// startSpawn does.
func (s *server) startKeptSpawn(req *protocol.Request, reach string, e egress) (*spawn, string) {
	uid, err := s.keptHome(req.HomePath, req.HomeUID)
	if err != nil {
		s.log.Warn("spawn %s refused: %v", req.ID, err)
		return nil, protocol.CodeBadRequest
	}
	s.mu.Lock()
	_, known := s.pools[req.Pool]
	s.mu.Unlock()
	if !known {
		return nil, protocol.CodeUnknownPool
	}
	acct := KeptAccount(uid)
	lock := s.keptLock(uid)
	deadline := time.Now().Add(keptRetireWait)
	// A uid whose last spawn was released is retiring until every process
	// of it is gone: a spawn of the same home waits for that; one on a uid
	// quarantined or live under another home is refused.
	for {
		s.mu.Lock()
		retiring, busy := s.keptState(uid, req.HomePath)
		s.mu.Unlock()
		if retiring == nil && !busy {
			lock.Lock()
			s.mu.Lock()
			retiring, busy = s.keptState(uid, req.HomePath)
			s.mu.Unlock()
			if retiring == nil && !busy {
				break
			}
			lock.Unlock()
		}
		if busy {
			s.log.Warn("spawn %s refused: kept uid %d is quarantined or live under another home", req.ID, uid)
			return nil, protocol.CodeUIDBusy
		}
		select {
		case <-retiring:
		case <-time.After(time.Until(deadline)):
			s.log.Warn("spawn %s refused: kept uid %d is still retiring", req.ID, uid)
			return nil, protocol.CodeUIDBusy
		}
	}
	if err := home.CheckKeptHome(req.HomePath, uid); err != nil {
		lock.Unlock()
		s.log.Warn("spawn %s refused: the kept home of uid %d is not made: %v", req.ID, uid, err)
		return nil, protocol.CodeBadRequest
	}
	if max := req.HomeMaxBytes; max != nil {
		bytes, err := s.measureHome(acct, req.HomePath)
		if err != nil {
			lock.Unlock()
			s.log.Error("spawn %s: measuring the kept home of uid %d: %v", req.ID, uid, err)
			return nil, protocol.CodeInternal
		}
		if bytes >= *max {
			lock.Unlock()
			s.log.Warn("spawn %s refused: the kept home of uid %d holds %d bytes, at or over its bound %d", req.ID, uid, bytes, *max)
			return nil, protocol.CodeHomeOverCap
		}
	}
	s.mu.Lock()
	s.keptMaps()
	s.keptLive[uid]++
	s.keptHomes[uid] = req.HomePath
	s.mu.Unlock()
	lock.Unlock()

	sp := &spawn{id: randomHex(16), kept: true, account: acct, home: req.HomePath, reach: reach, retired: make(chan struct{})}
	s.madeIn(req.Place, sp)
	if code, err := s.launch(sp, req, e); err != nil {
		s.log.Error("spawn %s on kept uid %d: %v", req.ID, uid, err)
		return sp, code
	}
	s.mu.Lock()
	s.spawns[sp.id] = sp
	s.mu.Unlock()
	s.log.Info("spawn %s: kept uid %d, leader pid %d", sp.id, uid, sp.leader.pid)
	s.send(protocol.NewSpawned(req.ID, sp.id, uid, sp.leader.pid))
	go s.watchLeader(sp)
	return sp, ""
}

// endInOrder ends a kept spawn's group by levels, by deadline: TERM to the
// leader alone, which has until then to end what it started; once the keeper
// has reaped it, TERM to the processes the leader had started when the end
// began, so a program the session's own shell runs is asked as a leader is
// and closes what it started before the rest is asked; once those have
// exited, TERM to whatever of the group is left, so a process neither level
// told is still asked; at the deadline the group's kill (cgroup.Group.KillBy),
// which waits for the group until the same deadline, never past it, and
// kills within one poll of it. One level below the leader and no deeper: the
// shell is the one layer CYFR puts in front of a program, and a program's
// own tree is its own to end. Every step looks at the deadline before it
// acts, none is taken past it, and the end does not wait for the scan of
// the leader's children past it: a scan still running then is left to end
// by itself and what it held is let go. The leader is signalled through
// signalChild, which holds the reaper's lock, and each of its children
// through a pidfd held from before the end (leaderChildren), so no pid
// already reaped and given to another process is ever signalled. When the
// leader ran as the end began and its children's level was skipped or
// incomplete, the log says so once for the spawn, with why: then a program
// and its own children are asked together. A leader already reaped as the
// end begins is the ordinary end and says nothing. It reports whether the
// group is empty.
func (s *server) endInOrder(spawnID string, uid int, group endable, leader *child, deadline time.Time) bool {
	if leader != nil && !leader.reaped() && time.Now().Before(deadline) {
		scanning := make(chan scanned, 1)
		go func() { scanning <- s.leaderChildren(uid, group, leader, deadline) }()
		var children scanned
		timer := time.NewTimer(time.Until(deadline))
		select {
		case children = <-scanning:
		case <-timer.C:
			children = scanned{why: "the scan of its leader's children did not end before the deadline"}
			go func() { late := <-scanning; releaseHeld(uid, late.fds) }()
		}
		timer.Stop()
		defer releaseHeld(uid, children.fds)
		if children.why != "" {
			s.log.Warn("spawn %s: %s; its leader's children are asked to end with the rest of its group", spawnID, children.why)
		}
		if time.Now().Before(deadline) {
			s.signalChild(leader, unix.SIGTERM)
			timer := time.NewTimer(time.Until(deadline))
			select {
			case <-leader.done:
				for _, fd := range children.fds {
					if !time.Now().Before(deadline) {
						break
					}
					_ = unix.PidfdSendSignal(fd, unix.SIGTERM, nil, 0)
				}
				awaitExits(children.fds, deadline)
			case <-timer.C:
			}
			timer.Stop()
		}
	}
	return group.KillBy(deadline)
}

// endable is what endInOrder needs of a spawn's group: its processes
// and its kill by a deadline (*cgroup.Group).
type endable interface {
	Procs() ([]int, error)
	KillBy(time.Time) bool
}

// scanned is what a scan of the leader's children held, and why, when it is
// not empty, the children's level is skipped or incomplete.
type scanned struct {
	fds []int
	why string
}

// The pidfds the ends hold. One end holds at most endHeld, for the leader's
// children, which are one or two in every row CYFR ships; one uid's ends at
// once at most uidHeld; every end at once at most endsHeld. A place is
// reserved before a pidfd is opened. Nothing bounds how many kept spawns end
// at once (the kept homes' range is 9999 uids, each with sessions the
// keeper does not count), so the keeper-wide budget stays, split so that no
// uid takes more than its share: 4096 is under 1% of the keeper's own open
// files, 1048575 in the shipped box and at least 524287 under Docker's
// default hard limit. A child past any bound is not held, is counted, and
// is asked with the rest of its group.
const (
	endHeld  = 4
	uidHeld  = 16
	endsHeld = 4096
)

var budget struct {
	sync.Mutex
	total int
	uids  map[int]int
}

// reserve takes a place for one pidfd of uid's, and answers whether it did.
func reserve(uid int) bool {
	budget.Lock()
	defer budget.Unlock()
	if budget.total >= endsHeld || budget.uids[uid] >= uidHeld {
		return false
	}
	if budget.uids == nil {
		budget.uids = map[int]int{}
	}
	budget.total++
	budget.uids[uid]++
	return true
}

// unreserve gives back n of uid's places.
func unreserve(uid, n int) {
	if n == 0 {
		return
	}
	budget.Lock()
	defer budget.Unlock()
	budget.total -= n
	if budget.uids[uid] -= n; budget.uids[uid] <= 0 {
		delete(budget.uids, uid)
	}
}

// releaseHeld closes the pidfds an end of uid's held and gives back their
// places.
func releaseHeld(uid int, fds []int) {
	for _, fd := range fds {
		_ = unix.Close(fd)
	}
	unreserve(uid, len(fds))
}

// leaderChildren holds, each by a pidfd, the processes of group whose parent
// is the leader, as they stand now, and says why when it could not hold them
// all. It never holds the keeper's lock across its scan: it lists the group,
// opens a pidfd for each process and reads its parent from the kernel with
// the lock released, keeping a pidfd only when, after it was opened, the
// parent read is the leader's pid and the process still runs, so the pidfd
// names that process and no other that took its pid since. Then it takes
// the lock once to ask whether the leader is still not reaped. Only the
// reaper frees the leader's pid, and it does so under that lock, so a leader
// not reaped then was not reaped at any moment of the scan: every parent
// read as its pid was the leader, and what is held is the leader's children.
// A leader reaped meanwhile, or a scan that ends past the deadline, keeps
// nothing. A process that may be the leader's child and is not held (its
// parent cannot be read, its pidfd cannot be opened or asked for a reason
// other than its end, or a bound is reached) is counted.
func (s *server) leaderChildren(uid int, group endable, leader *child, deadline time.Time) scanned {
	pids, err := group.Procs()
	if err != nil {
		return scanned{why: "its group could not be listed"}
	}
	var fds []int
	unheld := 0
	mayBeChild := func(pid int) bool {
		parent := parentOf(pid)
		return parent == leader.pid || parent == 0
	}
	for _, pid := range pids {
		if pid == leader.pid {
			continue
		}
		if !time.Now().Before(deadline) {
			releaseHeld(uid, fds)
			return scanned{why: "the scan of its leader's children did not end before the deadline"}
		}
		if len(fds) >= endHeld || !reserve(uid) {
			if mayBeChild(pid) {
				unheld++
			}
			continue
		}
		fd, err := unix.PidfdOpen(pid, 0)
		if err != nil {
			unreserve(uid, 1)
			if !errors.Is(err, unix.ESRCH) && mayBeChild(pid) {
				unheld++
			}
			continue
		}
		parent := parentOf(pid)
		running := unix.PidfdSendSignal(fd, 0, nil, 0)
		if running == nil && parent == leader.pid {
			fds = append(fds, fd)
			continue
		}
		_ = unix.Close(fd)
		unreserve(uid, 1)
		if !errors.Is(running, unix.ESRCH) && (parent == leader.pid || parent == 0) {
			unheld++
		}
	}
	s.mu.Lock()
	reaped := leader.reaped()
	s.mu.Unlock()
	switch {
	case reaped:
		releaseHeld(uid, fds)
		return scanned{why: "its leader was reaped during the scan"}
	case !time.Now().Before(deadline):
		releaseHeld(uid, fds)
		return scanned{why: "the scan of its leader's children did not end before the deadline"}
	case unheld > 0:
		return scanned{fds: fds, why: fmt.Sprintf("%d of its leader's children could not be held", unheld)}
	}
	return scanned{fds: fds}
}

// parentOf is the parent pid /proc gives pid, 0 when it is unreadable.
func parentOf(pid int) int {
	stat, err := os.ReadFile(fmt.Sprintf("/proc/%d/stat", pid))
	if err != nil {
		return 0
	}
	// The command name may hold spaces and parentheses; the fields after
	// the last ')' are the state and then the parent's pid.
	fields := strings.Fields(string(stat[bytes.LastIndexByte(stat, ')')+1:]))
	if len(fields) < 2 {
		return 0
	}
	ppid, err := strconv.Atoi(fields[1])
	if err != nil {
		return 0
	}
	return ppid
}

// poll is unix.Poll; a test fails it.
var poll = unix.Poll

// probe asks whether the process a pidfd names is still there: ESRCH says
// it is gone. A test watches it.
var probe = func(fd int) error { return unix.PidfdSendSignal(fd, 0, nil, 0) }

// awaitExits waits until every process the pidfds name has exited, or until
// the deadline. Each pidfd turns readable at its process's exit; a wait that
// cannot poll waits all the same, asking each pidfd on KillBy's interval
// whether its process is still there.
func awaitExits(fds []int, deadline time.Time) {
	waiting := make([]unix.PollFd, 0, len(fds))
	for _, fd := range fds {
		waiting = append(waiting, unix.PollFd{Fd: int32(fd), Events: unix.POLLIN})
	}
	for len(waiting) > 0 {
		left := time.Until(deadline)
		if left <= 0 {
			return
		}
		n, err := poll(waiting, int(left.Milliseconds())+1)
		if errors.Is(err, unix.EINTR) {
			continue
		}
		if err != nil {
			probeExits(waiting, deadline)
			return
		}
		if n == 0 {
			continue
		}
		still := waiting[:0]
		for _, p := range waiting {
			if p.Revents == 0 {
				still = append(still, p)
			}
		}
		waiting = still
	}
}

// probeExits waits until no process the pidfds name is still there, asking
// each with signal 0 on KillBy's interval, or until the deadline. Only ESRCH
// proves a process gone; any other answer keeps the wait.
func probeExits(waiting []unix.PollFd, deadline time.Time) {
	for len(waiting) > 0 && time.Now().Before(deadline) {
		still := waiting[:0]
		for _, p := range waiting {
			if !errors.Is(probe(int(p.Fd)), unix.ESRCH) {
				still = append(still, p)
			}
		}
		waiting = still
		if len(waiting) > 0 {
			time.Sleep(min(cgroup.PollInterval, time.Until(deadline)))
		}
	}
}

// retireKept ends a kept spawn once: the processes of its own group, which
// are everything it started, its leader first (endInOrder); then, when no other spawn holds its uid, the
// uid's full retirement, every process of the uid and what it left on the
// writable mounts and in the mqueue mount but its home. The uid stays its home's.
func (s *server) retireKept(sp *spawn, grace time.Duration, notify bool) {
	sp.retireOnce.Do(func() {
		uid := sp.account.UID
		deadline := time.Now().Add(grace)
		// The spawn is no longer live but ending, and the uid is retiring
		// from this moment when this spawn was its last live one: no
		// home_make and no other spawn takes it until every process of it
		// is gone, however a child of the spawn hides from its group's kill.
		s.mu.Lock()
		s.keptMaps()
		s.keptLive[uid]--
		s.keptEnding[uid]++
		if s.keptLive[uid] <= 0 {
			delete(s.keptLive, uid)
			s.keptRetiring[uid] = make(chan struct{})
		}
		s.mu.Unlock()
		go func() {
			defer close(sp.retired)
			if sp.group != nil && !s.endInOrder(sp.id, uid, sp.group, sp.leader, deadline) {
				s.log.Warn("spawn %s: processes of kept uid %d outlived their group's kill", sp.id, uid)
			}
			// Its processes are gone, or past their group's kill: its route
			// carries nothing more.
			s.withdrawRoute(sp)
			// The relay ends as a pooled spawn's does (retire): at its
			// reader's taking the last byte or closing, never cut here.
			if sp.relay != nil {
				<-sp.relay.done
			}
			// The uid's full retirement, which kills every process of it at
			// once, runs once it is retiring and no spawn of it is still
			// ending, so no session of it is cut short while it closes: the
			// spawn whose end returns last runs it.
			s.mu.Lock()
			s.keptEnding[uid]--
			done := s.keptRetiring[uid]
			last := done != nil && s.keptEnding[uid] <= 0
			if s.keptEnding[uid] <= 0 {
				delete(s.keptEnding, uid)
			}
			s.mu.Unlock()
			if last {
				// Every process of the uid is killed (SIGKILL until none is
				// left) and what it left outside its home removed before the
				// uid is free; one that survives quarantines it.
				lock := s.keptLock(uid)
				lock.Lock()
				clean := s.scrub(sp.account, 0, nil, sp.home)
				lock.Unlock()
				s.mu.Lock()
				delete(s.keptRetiring, uid)
				delete(s.keptHomes, uid)
				if !clean {
					s.keptQuarantined[uid] = sp.home
				}
				close(done)
				s.mu.Unlock()
				if !clean {
					s.log.Warn("spawn %s: kept uid %d quarantined: a process or something it left outside its home outlived retirement", sp.id, uid)
				}
			}

			if notify {
				s.reportExit(sp)
			}
			removed := s.removeSpawnGroup(sp)
			s.mu.Lock()
			s.leave(sp, removed, removal{notify: notify})
			s.mu.Unlock()
			if !removed {
				return
			}
			s.log.Info("spawn %s: kept uid %d retired", sp.id, uid)
			if notify {
				s.send(protocol.NewReleased(sp.id))
			}
		}()
	})
}

// handleHome answers a home request: `home_make` makes the home as its uid,
// `home_measure` answers the bytes allocated under it, and `home_retire`
// ends every process of the uid and removes the home and everything else
// the uid left. Each holds the uid's lock.
func (s *server) handleHome(req *protocol.Request) {
	uid, err := s.keptHome(req.Path, req.UID)
	if err != nil {
		s.log.Warn("%s %s refused: %v", req.Type, req.ID, err)
		s.send(protocol.NewError(req.ID, "", protocol.CodeBadRequest))
		return
	}
	acct := KeptAccount(uid)
	lock := s.keptLock(uid)
	lock.Lock()
	defer lock.Unlock()
	switch req.Type {
	case protocol.TypeHomeMake:
		s.mu.Lock()
		retiring, busy := s.keptState(uid, req.Path)
		s.mu.Unlock()
		if retiring != nil || busy {
			s.log.Warn("home_make %s refused: kept uid %d is retiring, quarantined or live under another home", req.ID, uid)
			s.send(protocol.NewError(req.ID, "", protocol.CodeUIDBusy))
			return
		}
		if _, err := s.runHomeHelper(acct, home.HelperSpec{Op: home.OpMake, Path: req.Path, UID: uid}); err != nil {
			s.log.Error("home_make %s: uid %d: %v", req.ID, uid, err)
			s.send(protocol.NewError(req.ID, "", protocol.CodeInternal))
			return
		}
		s.send(protocol.NewHomeMade(req.ID))
	case protocol.TypeHomeMeasure:
		bytes, err := s.measureHome(acct, req.Path)
		if err != nil {
			s.log.Error("home_measure %s: uid %d: %v", req.ID, uid, err)
			s.send(protocol.NewError(req.ID, "", protocol.CodeInternal))
			return
		}
		s.send(protocol.NewHomeMeasured(req.ID, bytes))
	case protocol.TypeHomeRetire:
		if !s.scrub(acct, homeRetireGrace, []string{req.Path}, "") {
			s.log.Warn("home_retire %s: uid %d: a process or something it left outlived retirement", req.ID, uid)
			s.send(protocol.NewError(req.ID, "", protocol.CodeInternal))
			return
		}
		if _, err := os.Lstat(req.Path); !errors.Is(err, fs.ErrNotExist) {
			s.log.Warn("home_retire %s: uid %d: the home is still there", req.ID, uid)
			s.send(protocol.NewError(req.ID, "", protocol.CodeInternal))
			return
		}
		s.mu.Lock()
		s.keptMaps()
		delete(s.keptQuarantined, uid)
		s.mu.Unlock()
		s.log.Info("kept uid %d retired with its home", uid)
		s.send(protocol.NewHomeRetired(req.ID))
	}
}

// measureHome answers the bytes allocated under a kept home, measured as its
// uid; an absent home holds none.
func (s *server) measureHome(acct Account, path string) (uint64, error) {
	out, err := s.runHomeHelper(acct, home.HelperSpec{Op: home.OpMeasure, Path: path, UID: acct.UID})
	if err != nil {
		if _, serr := os.Lstat(path); errors.Is(serr, fs.ErrNotExist) {
			return 0, nil
		}
		return 0, err
	}
	return strconv.ParseUint(strings.TrimSpace(out), 10, 64)
}

// runHomeHelper runs `cyfr-locus home` as the account with spec, and answers
// what it wrote to its result pipe once it exited 0.
func (s *server) runHomeHelper(acct Account, spec home.HelperSpec) (string, error) {
	data, err := json.Marshal(spec)
	if err != nil {
		return "", err
	}
	specR, specW, err := os.Pipe()
	if err != nil {
		return "", err
	}
	defer specW.Close()
	resultR, resultW, err := os.Pipe()
	if err != nil {
		specR.Close()
		return "", err
	}
	defer resultR.Close()
	devnull, err := os.Open(os.DevNull)
	if err != nil {
		specR.Close()
		resultW.Close()
		return "", err
	}
	c, err := s.start(s.self, []string{"cyfr-locus", "home"}, helperEnviron(),
		[]uintptr{devnull.Fd(), devnull.Fd(), 2, specR.Fd(), resultW.Fd()}, acct.UID, acct.GID, "/")
	specR.Close()
	resultW.Close()
	devnull.Close()
	if err != nil {
		return "", err
	}
	_ = specW.SetWriteDeadline(time.Now().Add(stageTimeout))
	_, _ = specW.Write(data)
	_ = specW.Close()
	_ = resultR.SetReadDeadline(time.Now().Add(helperTimeout))
	out, rerr := io.ReadAll(io.LimitReader(resultR, 64))
	select {
	case <-c.done:
	case <-time.After(helperTimeout):
		s.signalChild(c, unix.SIGKILL)
		<-c.done
	}
	switch {
	case !c.status.Exited():
		return "", fmt.Errorf("home %s ended %v", spec.Op, c.status)
	case c.status.ExitStatus() != home.ExitDone:
		return "", fmt.Errorf("home %s exited %d", spec.Op, c.status.ExitStatus())
	case rerr != nil:
		return "", rerr
	}
	return string(out), nil
}

// openPty opens a pseudo-terminal of rows by cols: its master, which the
// relay holds, and its slave, which becomes the spawn's stdin, stdout and
// stderr and its controlling terminal.
func openPty(rows, cols uint16) (master, slave *os.File, err error) {
	mfd, err := unix.Open("/dev/ptmx", unix.O_RDWR|unix.O_NOCTTY|unix.O_CLOEXEC, 0)
	if err != nil {
		return nil, nil, fmt.Errorf("ptmx: %w", err)
	}
	master = os.NewFile(uintptr(mfd), "pty-master")
	fail := func(err error) (*os.File, *os.File, error) {
		_ = master.Close()
		return nil, nil, err
	}
	unlock := 0
	if _, _, errno := unix.Syscall(unix.SYS_IOCTL, uintptr(mfd), unix.TIOCSPTLCK, uintptr(unsafe.Pointer(&unlock))); errno != 0 {
		return fail(fmt.Errorf("unlocking the pty: %w", errno))
	}
	n, err := unix.IoctlGetUint32(mfd, unix.TIOCGPTN)
	if err != nil {
		return fail(fmt.Errorf("the pty's number: %w", err))
	}
	sfd, err := unix.Open("/dev/pts/"+strconv.FormatUint(uint64(n), 10), unix.O_RDWR|unix.O_NOCTTY|unix.O_CLOEXEC, 0)
	if err != nil {
		return fail(fmt.Errorf("the pty's slave: %w", err))
	}
	if err := unix.IoctlSetWinsize(sfd, unix.TIOCSWINSZ, &unix.Winsize{Row: rows, Col: cols}); err != nil {
		_ = unix.Close(sfd)
		return fail(fmt.Errorf("the pty's size: %w", err))
	}
	return master, os.NewFile(uintptr(sfd), "pty-slave"), nil
}

// dupFile duplicates f, close-on-exec.
func dupFile(f *os.File, name string) (*os.File, error) {
	fd, err := unix.FcntlInt(f.Fd(), unix.F_DUPFD_CLOEXEC, 0)
	if err != nil {
		return nil, err
	}
	return os.NewFile(uintptr(fd), name), nil
}
