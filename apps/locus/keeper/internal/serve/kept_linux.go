// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package serve

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"golang.org/x/sys/unix"

	"github.com/cyfr/locus/keeper/internal/cgroup"
	"github.com/cyfr/locus/keeper/internal/home"
	"github.com/cyfr/locus/keeper/internal/protocol"
	"github.com/cyfr/locus/keeper/internal/stage"
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

// homeLock is a kept home's lock and the number of requests holding or
// waiting for it; s.mu guards refs.
type homeLock struct {
	mu   sync.Mutex
	refs int
}

// lockHome takes the kept home id's lock and answers its release. The
// entry lives in homeOps only while a request holds or waits for it, so a
// home retired, or an id never made, leaves nothing behind.
func (s *server) lockHome(id string) (unlock func()) {
	s.mu.Lock()
	if s.homeOps == nil {
		s.homeOps = map[string]*homeLock{}
	}
	l := s.homeOps[id]
	if l == nil {
		l = &homeLock{}
		s.homeOps[id] = l
	}
	l.refs++
	s.mu.Unlock()
	l.mu.Lock()
	return func() {
		l.mu.Unlock()
		s.mu.Lock()
		defer s.mu.Unlock()
		if l.refs--; l.refs == 0 {
			delete(s.homeOps, id)
		}
	}
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
	if s.keptMaking == nil {
		s.keptMaking = map[int]bool{}
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

// keptHome looks up the kept home id for c under the home's lock: its
// path, and its uid when it is made (home.Kept.Owner). It answers the
// refusal of a keeper that keeps no homes, or of a role whose sessions keep
// none (CodeUnavailable), of a home not made (CodeHomeAbsent, with its
// path) and of an entry that is no home (CodeBadRequest).
func (s *server) keptHome(c *client, id string) (path string, uid int, code string) {
	if s.cfg.Kept == nil || !c.role.spec.Kept {
		return "", 0, protocol.CodeUnavailable
	}
	path = filepath.Join(s.cfg.Kept.Root, id)
	uid, err := s.cfg.Kept.Owner(id)
	switch {
	case errors.Is(err, fs.ErrNotExist):
		return path, 0, protocol.CodeHomeAbsent
	case err != nil:
		s.log.Warn("kept home %s: %v", id, err)
		return path, 0, protocol.CodeBadRequest
	}
	return path, uid, ""
}

// drawKept reads which uids of the range are taken (taken, home.Kept.Taken
// in production) and holds the lowest that the reading does not hold and
// the keeper holds for nothing (no make or reset holds it, and it is not
// retiring, quarantined or live) as making until unmakeKept; with none left
// it answers false. The reading and the draw are one step under keptDraw,
// which unmakeKept takes too: a make that ends, its home now a folder of
// its uid, cannot free that uid between another draw's reading, which saw
// no folder, and that draw, so two homes never get one uid.
func (s *server) drawKept(taken func() (map[int]bool, error)) (int, bool, error) {
	s.keptDraw.Lock()
	defer s.keptDraw.Unlock()
	held, err := taken()
	if err != nil {
		return 0, false, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.keptMaps()
	for uid := s.cfg.Kept.First; uid <= s.cfg.Kept.Last; uid++ {
		_, quarantined := s.keptQuarantined[uid]
		if held[uid] || s.keptMaking[uid] || quarantined || s.keptRetiring[uid] != nil || s.keptLive[uid] > 0 {
			continue
		}
		s.keptMaking[uid] = true
		return uid, true, nil
	}
	return 0, false, nil
}

// unmakeKept ends the hold drawKept or a reset took on uid, under keptDraw
// (drawKept).
func (s *server) unmakeKept(uid int) {
	s.keptDraw.Lock()
	defer s.keptDraw.Unlock()
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.keptMaking, uid)
}

// startKeptSpawn starts a spawn in a made kept home, under the home's own
// uid and no uid of a pool, refused as CodeHomeOverCap when the home already
// holds its home_max_bytes. Its start holds the uid's lock, so it never
// starts during the uid's full retirement or a home request. Every session
// of the home shares the uid and its files, and each has its own space and
// route, which reaches what its own start resolved. It answers as
// startSpawn does.
func (s *server) startKeptSpawn(c *client, req *protocol.Request, reach string, e egress, known bool) (*spawn, string) {
	// The home's uid, read under its lock, is the home's for its life: a
	// home retired after this read is absent once the uid's lock is held,
	// and a reset keeps the uid.
	unlockHome := s.lockHome(req.Home)
	path, uid, code := s.keptHome(c, req.Home)
	unlockHome()
	if code != "" {
		s.log.Warn("spawn %s refused: kept home %s: %s", req.ID, req.Home, code)
		return nil, code
	}
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
		retiring, busy := s.keptState(uid, path)
		s.mu.Unlock()
		if retiring == nil && !busy {
			lock.Lock()
			s.mu.Lock()
			retiring, busy = s.keptState(uid, path)
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
	if err := home.CheckKeptHome(path, uid); err != nil {
		lock.Unlock()
		s.log.Warn("spawn %s refused: the kept home of uid %d is not made: %v", req.ID, uid, err)
		if errors.Is(err, fs.ErrNotExist) {
			return nil, protocol.CodeHomeAbsent
		}
		return nil, protocol.CodeBadRequest
	}
	if max := req.HomeMaxBytes; max != nil {
		bytes, err := s.measureHome(acct, path)
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
	s.keptHomes[uid] = path
	s.mu.Unlock()
	lock.Unlock()

	sp := &spawn{id: randomHex(16), client: c, kept: true, account: acct, home: path, reach: reach, retired: make(chan struct{})}
	s.madeIn(req.Place, sp)
	if code, err := s.launch(sp, req, e); err != nil {
		s.log.Error("spawn %s on kept uid %d: %v", req.ID, uid, err)
		return sp, code
	}
	if !s.hold(sp) {
		return sp, protocol.CodeInternal
	}
	s.log.Info("spawn %s: kept uid %d, leader pid %d", sp.id, uid, sp.leader.pid)
	s.send(c, protocol.NewSpawned(req.ID, sp.id, uid, sp.leader.pid))
	go s.watchLeader(sp)
	return sp, ""
}

// endInOrder ends a kept spawn's group by the levels a kept session ends
// by (stage.Ender, whose order the space's init runs too), by deadline:
// TERM to the leader alone, which has until then to end what it started;
// once the keeper has reaped it, TERM to the processes the leader had
// started when the end began, and in turn to theirs (Ender.InTurn), each
// level waited for; then the group's kill (cgroup.Group.KillBy), which asks
// whatever is left once, waits for the group until the same deadline, never
// past it, and kills within one poll of it. Every step looks at the deadline
// before it acts, none is taken past it, and the end does not wait for the
// scan of the leader's children past it: a scan still running then is left
// to end by itself and what it held is let go. The leader is signalled
// through signalChild, which holds the reaper's lock, and each process of
// a level through a pidfd held from before its level was asked
// (leaderChildren, Ender.Children), so no pid already reaped and given to
// another process is ever signalled. When the leader ran as the end began
// and its children's level was skipped or incomplete, the log says so once
// for the spawn, with why: then a program and its own children are asked
// together. A leader already reaped as the end begins is the ordinary end
// and says nothing. It reports whether the group is empty.
func (s *server) endInOrder(spawnID string, uid int, group endable, leader *child, deadline time.Time) bool {
	if leader != nil && !leader.reaped() && time.Now().Before(deadline) {
		e := keptEnder(uid, group)
		scanning := make(chan scanned, 1)
		go func() { scanning <- s.leaderChildren(e, group, leader, deadline) }()
		var children scanned
		timer := time.NewTimer(time.Until(deadline))
		select {
		case children = <-scanning:
		case <-timer.C:
			children = scanned{why: "the scan of its leader's children did not end before the deadline"}
			go func() { late := <-scanning; e.Release(late.held) }()
		}
		timer.Stop()
		if children.why != "" {
			s.log.Warn("spawn %s: %s; its leader's children are asked to end with the rest of its group", spawnID, children.why)
		}
		if time.Now().Before(deadline) {
			s.signalChild(leader, unix.SIGTERM)
			timer := time.NewTimer(time.Until(deadline))
			select {
			case <-leader.done:
				e.InTurn(children.held, deadline)
				children.held = nil
			case <-timer.C:
			}
			timer.Stop()
		}
		e.Release(children.held)
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
	held []stage.Held
	why  string
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

// keptEnder is the end by levels (stage.Ender) as the keeper runs it on
// group, a kept spawn's: one end holds at most endHeld pidfds at once,
// each in uid's budget and the keeper's.
func keptEnder(uid int, group endable) stage.Ender {
	held := 0
	return stage.Ender{
		Procs: group.Procs,
		Reserve: func() bool {
			if held >= endHeld || !reserve(uid) {
				return false
			}
			held++
			return true
		},
		Unreserve:    func(n int) { held -= n; unreserve(uid, n) },
		Poll:         func(fds []unix.PollFd, ms int) (int, error) { return poll(fds, ms) },
		Probe:        func(fd int) error { return probe(fd) },
		PollInterval: cgroup.PollInterval,
	}
}

// leaderChildren holds, each by a pidfd, the processes of group whose parent
// is the leader, as they stand now (Ender.Children), and says why when it
// could not hold them all. It never holds the keeper's lock across its scan;
// then it takes the lock once to ask whether the leader is still not
// reaped. Only the reaper frees the leader's pid, and it does so under that
// lock, so a leader not reaped then was not reaped at any moment of the
// scan: every parent read as its pid was the leader, and what is held is
// the leader's children. A leader reaped meanwhile, or a scan that ends
// past the deadline, keeps nothing.
func (s *server) leaderChildren(e stage.Ender, group endable, leader *child, deadline time.Time) scanned {
	held, unheld, err := e.Children([]int{leader.pid}, deadline)
	if err != nil {
		return scanned{why: "its group could not be listed"}
	}
	s.mu.Lock()
	reaped := leader.reaped()
	s.mu.Unlock()
	switch {
	case reaped:
		e.Release(held)
		return scanned{why: "its leader was reaped during the scan"}
	case !time.Now().Before(deadline):
		e.Release(held)
		return scanned{why: "the scan of its leader's children did not end before the deadline"}
	case unheld > 0:
		return scanned{held: held, why: fmt.Sprintf("%d of its leader's children could not be held", unheld)}
	}
	return scanned{held: held}
}

// poll is unix.Poll; a test fails it.
var poll = unix.Poll

// probe asks whether the process a pidfd names is still there: ESRCH says
// it is gone. A test watches it.
var probe = func(fd int) error { return unix.PidfdSendSignal(fd, 0, nil, 0) }

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
			defer sp.releasePacks()
			if sp.group != nil && !s.endInOrder(sp.id, uid, sp.group, sp.leader, deadline) {
				s.log.Warn("spawn %s: processes of kept uid %d outlived their group's kill", sp.id, uid)
			}
			// Its processes are gone, or past their group's kill: its route
			// carries nothing more.
			s.withdrawRoute(sp.id, &sp.route)
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
				s.send(sp.client, protocol.NewReleased(sp.id))
			}
		}()
	})
}

// handleHome answers a home request under the home's lock, each helper it
// runs under the uid's lock: `home_make` answers a made home's uid or makes
// the home under a uid it draws (makeHome), `home_measure` answers the
// bytes allocated under it, `home_reset` ends every process of the uid and
// makes the home again empty under it, and `home_retire` ends every process
// of the uid and removes the home and everything else the uid left.
func (s *server) handleHome(c *client, req *protocol.Request) {
	if s.keepsNoHomes(c, req) {
		return
	}
	defer s.lockHome(req.Home)()
	path, uid, code := s.keptHome(c, req.Home)
	absent := code == protocol.CodeHomeAbsent
	if code != "" && !absent {
		s.log.Warn("%s %s refused: kept home %s: %s", req.Type, req.ID, req.Home, code)
		s.send(c, protocol.NewError(req.ID, "", code))
		return
	}
	switch {
	case req.Type == protocol.TypeHomeMake && !absent:
		s.send(c, protocol.NewHomeMade(req.ID, uid))
	case req.Type == protocol.TypeHomeMake:
		s.makeHome(c, req, path)
	case absent && req.Type == protocol.TypeHomeMeasure:
		s.send(c, protocol.NewError(req.ID, "", protocol.CodeHomeAbsent))
	case absent:
		s.send(c, protocol.NewHomeRetired(req.ID))
	case req.Type == protocol.TypeHomeMeasure:
		uidLock := s.keptLock(uid)
		uidLock.Lock()
		bytes, err := s.measureHome(KeptAccount(uid), path)
		uidLock.Unlock()
		if err != nil {
			s.log.Error("home_measure %s: uid %d: %v", req.ID, uid, err)
			s.send(c, protocol.NewError(req.ID, "", protocol.CodeInternal))
			return
		}
		s.send(c, protocol.NewHomeMeasured(req.ID, bytes))
	default:
		s.retireHome(c, req, path, uid)
	}
}

// keepsNoHomes refuses req as CodeUnavailable when the keeper was given no
// --kept-homes or c's role is not the kept one, and answers whether it did.
func (s *server) keepsNoHomes(c *client, req *protocol.Request) bool {
	switch {
	case s.cfg.Kept == nil:
		s.log.Warn("%s %s refused: this keeper keeps no homes (no --kept-homes)", req.Type, req.ID)
	case !c.role.spec.Kept:
		s.log.Warn("%s %s refused: role %s's sessions keep no homes", req.Type, req.ID, c.role.spec.Name)
	default:
		return false
	}
	s.send(c, protocol.NewError(req.ID, "", protocol.CodeUnavailable))
	return true
}

// makeHome makes the absent home at path under the lowest free uid of the
// range (drawKept), held as making until the home is made.
func (s *server) makeHome(c *client, req *protocol.Request, path string) {
	uid, ok, err := s.drawKept(func() (map[int]bool, error) { return s.cfg.Kept.Taken("/proc") })
	if err != nil {
		s.log.Error("home_make %s: reading the kept homes' root and /proc: %v", req.ID, err)
		s.send(c, protocol.NewError(req.ID, "", protocol.CodeUnavailable))
		return
	}
	if !ok {
		s.log.Warn("home_make %s refused: every kept uid is taken", req.ID)
		s.send(c, protocol.NewError(req.ID, "", protocol.CodeCapacity))
		return
	}
	defer s.unmakeKept(uid)
	lock := s.keptLock(uid)
	lock.Lock()
	defer lock.Unlock()
	if _, err := s.runHomeHelper(KeptAccount(uid), home.HelperSpec{Op: home.OpMake, Path: path, UID: uid}); err != nil {
		s.log.Error("home_make %s: uid %d: %v", req.ID, uid, err)
		s.send(c, protocol.NewError(req.ID, "", protocol.CodeInternal))
		return
	}
	s.send(c, protocol.NewHomeMade(req.ID, uid))
}

// retireHome ends every process of the made home's uid and removes the home
// and everything else the uid left, then, for a `home_reset`, makes the
// home again empty under the same uid, which stays held as making between
// the two so no draw takes it while no folder owns it.
func (s *server) retireHome(c *client, req *protocol.Request, path string, uid int) {
	reset := req.Type == protocol.TypeHomeReset
	if reset {
		s.mu.Lock()
		s.keptMaps()
		s.keptMaking[uid] = true
		s.mu.Unlock()
		defer s.unmakeKept(uid)
	}
	acct := KeptAccount(uid)
	lock := s.keptLock(uid)
	lock.Lock()
	defer lock.Unlock()
	if !s.scrub(acct, homeRetireGrace, []string{path}, "") {
		s.log.Warn("%s %s: uid %d: a process or something it left outlived retirement", req.Type, req.ID, uid)
		s.send(c, protocol.NewError(req.ID, "", protocol.CodeInternal))
		return
	}
	if _, err := os.Lstat(path); !errors.Is(err, fs.ErrNotExist) {
		s.log.Warn("%s %s: uid %d: the home is still there", req.Type, req.ID, uid)
		s.send(c, protocol.NewError(req.ID, "", protocol.CodeInternal))
		return
	}
	s.mu.Lock()
	s.keptMaps()
	delete(s.keptQuarantined, uid)
	s.mu.Unlock()
	if !reset {
		s.log.Info("kept uid %d retired with its home", uid)
		s.send(c, protocol.NewHomeRetired(req.ID))
		return
	}
	if _, err := s.runHomeHelper(acct, home.HelperSpec{Op: home.OpMake, Path: path, UID: uid}); err != nil {
		s.log.Error("home_reset %s: uid %d: %v", req.ID, uid, err)
		s.send(c, protocol.NewError(req.ID, "", protocol.CodeInternal))
		return
	}
	s.log.Info("kept uid %d reset with its home", uid)
	s.send(c, protocol.NewHomeMade(req.ID, uid))
}

// handleHomeList answers a `home_list` with the page of kept home ids after
// its `after`, at most protocol.MaxHomeListIDs, naming the last as `next`
// when more follow.
func (s *server) handleHomeList(c *client, req *protocol.Request) {
	if s.keepsNoHomes(c, req) {
		return
	}
	ids, err := s.cfg.Kept.IDs()
	if err != nil {
		s.log.Error("home_list %s: listing the kept homes' root: %v", req.ID, err)
		s.send(c, protocol.NewError(req.ID, "", protocol.CodeUnavailable))
		return
	}
	ids = ids[sort.SearchStrings(ids, req.After):]
	if len(ids) > 0 && ids[0] == req.After {
		ids = ids[1:]
	}
	next := ""
	if len(ids) > protocol.MaxHomeListIDs {
		ids = ids[:protocol.MaxHomeListIDs]
		next = ids[len(ids)-1]
	}
	s.send(c, protocol.NewHomes(req.ID, ids, next))
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

// receiveTerminal reads the master of a pty spawn's terminal, which the
// space's first process opened in the space's own devpts and handed up, and
// sets its size to rows by cols, within stageTimeout.
func receiveTerminal(from *os.File, rows, cols uint16) (*os.File, error) {
	if err := from.SetReadDeadline(time.Now().Add(stageTimeout)); err != nil {
		return nil, fmt.Errorf("its socket: %w", err)
	}
	fds, err := receiveDescriptors(from, 1)
	if err != nil {
		return nil, err
	}
	master := os.NewFile(uintptr(fds[0]), "pty-master")
	if err := unix.IoctlSetWinsize(fds[0], unix.TIOCSWINSZ, &unix.Winsize{Row: rows, Col: cols}); err != nil {
		_ = master.Close()
		return nil, fmt.Errorf("its size: %w", err)
	}
	return master, nil
}

// dupFile duplicates f, close-on-exec.
func dupFile(f *os.File, name string) (*os.File, error) {
	fd, err := unix.FcntlInt(f.Fd(), unix.F_DUPFD_CLOEXEC, 0)
	if err != nil {
		return nil, err
	}
	return os.NewFile(uintptr(fd), name), nil
}
