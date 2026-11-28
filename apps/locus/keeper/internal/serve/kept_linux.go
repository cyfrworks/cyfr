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
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"golang.org/x/sys/unix"

	"github.com/cyfr/locus/keeper/internal/admission"
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

// diskForm is the form a disk made now takes.
func (s *server) diskForm() string {
	if s.imageDisks {
		return home.FormImage
	}
	return home.FormDirectory
}

// keptLock is the lock of a disk's uid.
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

// homeLock is a lock of a kept home or of a disk and the number of
// requests holding or waiting for it; s.mu guards refs.
type homeLock struct {
	mu   sync.Mutex
	refs int
}

// lockHome takes the kept home id's lock and answers its release. The
// entry lives in homeOps only while a request holds or waits for it, so a
// home retired, or an id never made, leaves nothing behind.
func (s *server) lockHome(id string) (unlock func()) {
	return s.lockIn(&s.homeOps, id)
}

// lockDisk takes the lock of the disk of athanor, which every change of its
// record holds from its read to its write, and answers its release. Lock
// order: a home's, then its disk's, then the uid's.
func (s *server) lockDisk(athanor string) (unlock func()) {
	return s.lockIn(&s.diskOps, athanor)
}

// lockIn takes the lock of key in *locks, made while a request holds or
// waits for it and removed with its last.
func (s *server) lockIn(locks *map[string]*homeLock, key string) (unlock func()) {
	s.mu.Lock()
	if *locks == nil {
		*locks = map[string]*homeLock{}
	}
	l := (*locks)[key]
	if l == nil {
		l = &homeLock{}
		(*locks)[key] = l
	}
	l.refs++
	s.mu.Unlock()
	l.mu.Lock()
	return func() {
		l.mu.Unlock()
		s.mu.Lock()
		defer s.mu.Unlock()
		if l.refs--; l.refs == 0 {
			delete(*locks, key)
		}
	}
}

// keptMaps makes the kept uids' and the disks' state maps; s.mu is held.
func (s *server) keptMaps() {
	if s.keptLive == nil {
		s.keptLive = map[int]int{}
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
	if s.disks == nil {
		s.disks = map[string]*home.Disk{}
	}
	if s.homeDisk == nil {
		s.homeDisk = map[string]string{}
	}
	if s.keptWithheld == nil {
		s.keptWithheld = map[int]bool{}
	}
}

// loadDisks reads every disk's record (home.Kept.LoadDisks) into the
// keeper's own index: the disk of each athanor, and whose disk holds each
// home. A record the keeper cannot trust refuses its start.
func (s *server) loadDisks() error {
	disks, err := s.cfg.Kept.LoadDisks()
	if err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.keptMaps()
	for a, d := range disks {
		s.disks[a] = d
		for _, id := range d.Homes {
			s.homeDisk[id] = a
		}
	}
	return nil
}

// putDisk records d on its disk (home.Kept.WriteDisk) and then in the
// index; the disk's lock is held. A write that failed may still have put
// its record in place, its rename done and its folder's sync not: the
// index then takes what the record on disk says, so the two never disagree
// about a uid, and a record that cannot be read back keeps d's uid
// withheld from every draw for the keeper's life. Its error is answered
// all the same.
func (s *server) putDisk(d home.Disk) error {
	write := s.cfg.Kept.WriteDisk
	if s.writeDisk != nil {
		write = s.writeDisk
	}
	err := write(d)
	if err == nil {
		s.indexDisk(d.Athanor, &d)
		return nil
	}
	got, rerr := s.cfg.Kept.ReadDisk(d.Athanor)
	switch {
	case rerr == nil:
		s.indexDisk(d.Athanor, got)
	case errors.Is(rerr, fs.ErrNotExist):
		s.indexDisk(d.Athanor, nil)
	default:
		s.mu.Lock()
		s.keptMaps()
		s.keptWithheld[d.UID] = true
		s.mu.Unlock()
		s.log.Error("the record of a disk of uid %d does not read back after its write failed: the uid is withheld: %v", d.UID, rerr)
	}
	return err
}

// indexDisk makes d the index's disk of athanor, or none for nil.
func (s *server) indexDisk(athanor string, d *home.Disk) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.keptMaps()
	if old := s.disks[athanor]; old != nil {
		for _, id := range old.Homes {
			delete(s.homeDisk, id)
		}
	}
	delete(s.disks, athanor)
	if d == nil {
		return
	}
	s.disks[athanor] = d
	for _, id := range d.Homes {
		s.homeDisk[id] = athanor
	}
}

// keptAt is where a kept home is: whose disk holds it, the disk, the home
// and the disk's work folder, and the disk's uid.
type keptAt struct {
	athanor, disk, path, work string
	uid                       int
	// image says the disk is a person's VM's drive, whose homes run in that
	// VM alone (home.FormImage).
	image bool
}

// keptState is why a disk's uid cannot take a spawn now, with s.mu held:
// the channel its retirement closes when it is retiring, busy when it is
// quarantined. Every home of a disk shares its uid, so a uid live under
// one home takes a spawn of another.
func (s *server) keptState(uid int) (retiring chan struct{}, busy bool) {
	s.keptMaps()
	if _, q := s.keptQuarantined[uid]; q {
		return nil, true
	}
	return s.keptRetiring[uid], false
}

// sweepKept retries the retirement of every quarantined kept uid, as the
// sweeper retries a pooled one, and frees each once nothing of it remains
// outside its disk.
func (s *server) sweepKept() {
	s.mu.Lock()
	s.keptMaps()
	todo := make(map[int]string, len(s.keptQuarantined))
	for uid, disk := range s.keptQuarantined {
		todo[uid] = disk
	}
	s.mu.Unlock()
	for uid, disk := range todo {
		lock := s.keptLock(uid)
		lock.Lock()
		clean := s.scrub(KeptAccount(uid), 0, nil, disk)
		if clean {
			s.mu.Lock()
			delete(s.keptQuarantined, uid)
			s.mu.Unlock()
			s.log.Info("kept uid %d retired after its quarantine", uid)
		}
		lock.Unlock()
	}
}

// keptHome finds the kept home id on the disk that holds it, from the
// keeper's index of the disks' records: never by a walk inside a disk. It
// answers the refusal of a keeper that keeps no homes, or of a role whose
// sessions keep none (CodeUnavailable), and of a home no disk holds
// (CodeHomeAbsent).
func (s *server) keptHome(c *client, id string) (keptAt, string) {
	if s.cfg.Kept == nil || !c.role.spec.Kept {
		return keptAt{}, protocol.CodeUnavailable
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.keptMaps()
	a, ok := s.homeDisk[id]
	if !ok {
		return keptAt{}, protocol.CodeHomeAbsent
	}
	k := s.cfg.Kept
	d := s.disks[a]
	return keptAt{athanor: a, disk: k.DiskPath(a), path: k.HomePath(a, id), work: k.WorkOf(a), uid: d.UID, image: d.Form == home.FormImage}, ""
}

// drawKept reads which uids of the range are taken (taken, home.Kept.Taken
// in production) and holds the lowest that the reading does not hold, no
// disk's record holds and the keeper holds for nothing (no make holds it,
// no record that failed to read back withholds it, and it is not retiring,
// quarantined or live) as making until unmakeKept; with none left it
// answers false. The reading and the draw are one step under keptDraw,
// which unmakeKept takes too: a make that ends, its disk now recorded,
// cannot free that uid between another draw's reading and that draw, so
// two disks never get one uid.
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
	recorded := make(map[int]bool, len(s.disks))
	for _, d := range s.disks {
		recorded[d.UID] = true
	}
	for uid := s.cfg.Kept.First; uid <= s.cfg.Kept.Last; uid++ {
		_, quarantined := s.keptQuarantined[uid]
		if held[uid] || recorded[uid] || s.keptWithheld[uid] || s.keptMaking[uid] || quarantined || s.keptRetiring[uid] != nil || s.keptLive[uid] > 0 {
			continue
		}
		s.keptMaking[uid] = true
		return uid, true, nil
	}
	return 0, false, nil
}

// unmakeKept ends the hold drawKept took on uid, under keptDraw (drawKept).
func (s *server) unmakeKept(uid int) {
	s.keptDraw.Lock()
	defer s.keptDraw.Unlock()
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.keptMaking, uid)
}

// startKeptSpawn starts a spawn in a home of a person's disk, under the
// disk's uid and no uid of a pool, with the disk's work folder at /work,
// refused as CodeHomeOverCap when the home already holds its
// home_max_bytes, and as CodeBadRequest when its place is not the disk's
// athanor's. Its start holds the home's lock until the spawn is held, so a
// reset or a retirement of the home, which takes that lock, finds every
// session of it; and it registers the spawn live under the uid's lock in
// the same step that finds the uid not retiring, so the uid's full
// retirement, which runs only once no spawn of the uid is live, never ends
// a spawn of the person's other programs: one that began before it is
// counted live and holds it off, or finds it retiring and waits for it.
// Every session of the disk shares the uid, and each has its own space,
// which sees its own home and the work folder and no other home, and its
// own route, which reaches what its own start resolved. It answers as
// startSpawn does.
func (s *server) startKeptSpawn(c *client, req *protocol.Request, reach string, e egress, known bool, limits admission.Limits) (*spawn, string) {
	defer s.lockHome(req.Home)()
	at, code := s.keptHome(c, req.Home)
	if code != "" {
		s.log.Warn("spawn %s refused: kept home %s: %s", req.ID, req.Home, code)
		return nil, code
	}
	if !known {
		return nil, protocol.CodeUnknownPool
	}
	// An image is mounted by its person's VM alone: on a keeper that gives
	// the wall its sessions run there, and here, with no VM to run its
	// session, it is refused by name, and nothing of it is touched. A
	// directory disk left on a keeper that gives the wall, whose
	// retirement at the start did not finish, runs nowhere: no session of
	// any person runs outside a VM there.
	switch {
	case at.image && s.wall:
		return s.startMachineSpawn(c, req, at, reach, e, limits)
	case at.image:
		s.log.Warn("spawn %s refused: kept home %s is on a disk image, which runs only in its person's VM, and this machine runs none: give the container /dev/kvm again", req.ID, req.Home)
		return nil, protocol.CodeUnavailable
	case s.wall:
		s.log.Warn("spawn %s refused: kept home %s is on a disk of the directory form, which this machine retires at its start, and its retirement has not finished", req.ID, req.Home)
		return nil, protocol.CodeUnavailable
	}
	s.mu.Lock()
	p := c.places[req.Place]
	others := p == nil || p.whose.Athanor != at.athanor
	s.mu.Unlock()
	if others {
		s.log.Warn("spawn %s refused: its place is not the athanor's whose disk holds kept home %s", req.ID, req.Home)
		return nil, protocol.CodeBadRequest
	}
	uid := at.uid
	acct := KeptAccount(uid)
	lock := s.keptLock(uid)
	deadline := time.Now().Add(keptRetireWait)
	// A uid whose last spawn was released is retiring until every process
	// of it is gone: a spawn waits for that; one on a uid quarantined is
	// refused.
	for {
		lock.Lock()
		s.mu.Lock()
		retiring, busy := s.keptState(uid)
		if retiring == nil && !busy {
			break
		}
		s.mu.Unlock()
		lock.Unlock()
		if busy {
			s.log.Warn("spawn %s refused: kept uid %d is quarantined", req.ID, uid)
			return nil, protocol.CodeUIDBusy
		}
		select {
		case <-retiring:
		case <-time.After(time.Until(deadline)):
			s.log.Warn("spawn %s refused: kept uid %d is still retiring", req.ID, uid)
			return nil, protocol.CodeUIDBusy
		}
	}
	// Live from here, in the step that found the uid not retiring (s.mu and
	// the uid's lock held): its home's measure below runs as the uid.
	s.keptLive[uid]++
	s.mu.Unlock()
	sp := &spawn{id: randomHex(16), client: c, kept: true, account: acct, keptHome: req.Home, home: at.path, work: at.work, disk: at.disk,
		reach: reach, limits: limits, retired: make(chan struct{}), groupEnded: make(chan struct{})}
	if max := req.HomeMaxBytes; max != nil {
		bytes, err := s.measureHome(acct, at.path)
		switch {
		case err != nil:
			s.log.Error("spawn %s: measuring kept home %s of uid %d: %v", req.ID, req.Home, uid, err)
			code = protocol.CodeInternal
		case bytes >= *max:
			s.log.Warn("spawn %s refused: kept home %s of uid %d holds %d bytes, at or over its bound %d", req.ID, req.Home, uid, bytes, *max)
			code = protocol.CodeHomeOverCap
		}
	}
	lock.Unlock()
	if code != "" {
		// Never made: it gives back its count as a released spawn does, and
		// the uid retires when it was the last.
		s.unliveKept(uid, at.disk)
		return nil, code
	}

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

// unliveKept gives back the live count of a kept spawn refused before it
// was made, as a released spawn's end does (retireKept): a uid left with
// no live spawn is retiring, and is scrubbed now when nothing of it is
// still ending, or by the last end otherwise.
func (s *server) unliveKept(uid int, disk string) {
	s.mu.Lock()
	s.keptMaps()
	var done chan struct{}
	if s.keptLive[uid]--; s.keptLive[uid] <= 0 {
		delete(s.keptLive, uid)
		if s.keptRetiring[uid] == nil {
			s.keptRetiring[uid] = make(chan struct{})
		}
		if s.keptEnding[uid] <= 0 {
			done = s.keptRetiring[uid]
		}
	}
	s.mu.Unlock()
	if done != nil {
		go s.scrubKept(uid, disk, done)
	}
}

// scrubKept is a disk's uid's full retirement, once it is retiring and no
// spawn of it is live or ending: every process of the uid is killed
// (SIGKILL until none is left) and what it left outside its disk removed
// before the uid is free; one that survives quarantines it, which holds
// every program of the person until the sweeper's retry finishes it. done
// closes at the end.
func (s *server) scrubKept(uid int, disk string, done chan struct{}) {
	lock := s.keptLock(uid)
	lock.Lock()
	clean := s.scrub(KeptAccount(uid), 0, nil, disk)
	lock.Unlock()
	s.mu.Lock()
	delete(s.keptRetiring, uid)
	if !clean {
		s.keptQuarantined[uid] = disk
	}
	close(done)
	s.mu.Unlock()
	if !clean {
		s.log.Warn("kept uid %d quarantined: a process or something it left outside its disk outlived retirement", uid)
	}
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
// are everything it started, its leader first (endInOrder); then, when no
// other spawn of the person holds its uid, the uid's full retirement
// (scrubKept), every process of the uid and what it left on the writable
// mounts and in the mqueue mount but its disk. The uid stays its disk's.
// Whether the group was found empty is sp.ended.
func (s *server) retireKept(sp *spawn, grace time.Duration, notify bool) {
	sp.retireOnce.Do(func() {
		uid := sp.account.UID
		deadline := time.Now().Add(grace)
		// The spawn is no longer live but ending, and the uid is retiring
		// from this moment when this spawn was its last live one: no
		// home_make and no other spawn takes it until every process of it
		// is gone, however a child of the spawn hides from its group's kill.
		s.mu.Lock()
		s.ending(sp)
		s.keptMaps()
		s.keptLive[uid]--
		s.keptEnding[uid]++
		if s.keptLive[uid] <= 0 {
			delete(s.keptLive, uid)
			if s.keptRetiring[uid] == nil {
				s.keptRetiring[uid] = make(chan struct{})
			}
		}
		s.mu.Unlock()
		go func() {
			defer close(sp.retired)
			ended := sp.group == nil || s.endInOrder(sp.id, uid, sp.group, sp.leader, deadline)
			if !ended {
				s.log.Warn("spawn %s: processes of kept uid %d outlived their group's kill", sp.id, uid)
			}
			s.mu.Lock()
			sp.ended = ended
			s.mu.Unlock()
			if sp.groupEnded != nil {
				close(sp.groupEnded)
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
				s.scrubKept(uid, sp.disk, done)
			}

			if notify {
				s.reportExit(sp)
			} else {
				s.readKill(sp)
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
// runs under the disk's uid's lock: `home_make` makes the home on its
// athanor's disk (makeHome), `home_measure` answers the bytes allocated
// under the home, `home_reset` ends the home's sessions and makes it again
// empty, and `home_retire` ends them and removes the home from its disk
// (retireHome).
func (s *server) handleHome(c *client, req *protocol.Request) {
	if s.keepsNoHomes(c, req) {
		return
	}
	defer s.lockHome(req.Home)()
	if req.Type == protocol.TypeHomeMake {
		s.makeHome(c, req)
		return
	}
	at, code := s.keptHome(c, req.Home)
	switch {
	case code == protocol.CodeHomeAbsent && req.Type == protocol.TypeHomeMeasure:
		s.send(c, protocol.NewError(req.ID, "", protocol.CodeHomeAbsent))
	case code == protocol.CodeHomeAbsent:
		s.send(c, protocol.NewHomeRetired(req.ID))
	case code != "":
		s.send(c, protocol.NewError(req.ID, "", code))
	case at.image && s.wall && req.Type == protocol.TypeHomeMeasure:
		s.measureInMachine(c, req, at)
	case at.image:
		// An image's homes are inside it, which the host never walks: only
		// its person's VM measures, resets or retires one.
		s.log.Warn("%s %s refused: kept home %s is on a disk image, which only its person's VM reaches, and this machine runs none", req.Type, req.ID, req.Home)
		s.send(c, protocol.NewError(req.ID, "", protocol.CodeUnavailable))
	case req.Type == protocol.TypeHomeMeasure:
		uidLock := s.keptLock(at.uid)
		uidLock.Lock()
		bytes, err := s.measureHome(KeptAccount(at.uid), at.path)
		uidLock.Unlock()
		if err != nil {
			s.log.Error("home_measure %s: uid %d: %v", req.ID, at.uid, err)
			s.send(c, protocol.NewError(req.ID, "", protocol.CodeInternal))
			return
		}
		s.send(c, protocol.NewHomeMeasured(req.ID, bytes))
	default:
		s.retireHome(c, req, at)
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

// makeHome makes the home req names on the disk of its athanor, the home's
// lock held. A disk not yet recorded is drawn the lowest free uid
// (drawKept), held as making until its record holds it. The record comes
// first: it holds the home before the folder is made, so a keeper killed
// between the two leaves a home its record lists and no folder, which the
// next make makes, and never a folder no record knows. A disk that holds
// home.MaxDiskHomes refuses another as CodeCapacity, so no record is ever
// written that a keeper's boot would refuse. The make itself is
// the helper's, as the disk's uid, and makes the disk and its work folder
// too where they are not yet made. A home another athanor's disk holds is
// refused, and nothing changes.
func (s *server) makeHome(c *client, req *protocol.Request) {
	s.mu.Lock()
	s.keptMaps()
	whose, held := s.homeDisk[req.Home]
	s.mu.Unlock()
	if held && whose != req.Athanor {
		s.log.Warn("home_make %s refused: kept home %s is on another athanor's disk", req.ID, req.Home)
		s.send(c, protocol.NewError(req.ID, "", protocol.CodeBadRequest))
		return
	}
	unlockDisk := s.lockDisk(req.Athanor)
	d, code := s.recordDisk("home_make "+req.ID, req.Athanor, req.Home)
	if code != "" {
		unlockDisk()
		s.send(c, protocol.NewError(req.ID, "", code))
		return
	}
	// An image's homes are made inside it, by its person's VM's keeper at
	// their first session: the host makes the image, after its record, and
	// again where a keeper that died between the two left none.
	if d.Form == home.FormImage {
		err := s.cfg.Kept.EnsureImage(req.Athanor, d.UID, s.startTool)
		unlockDisk()
		if err != nil {
			s.log.Error("home_make %s: %v", req.ID, err)
			s.send(c, protocol.NewError(req.ID, "", protocol.CodeInternal))
			return
		}
		s.send(c, protocol.NewHomeMade(req.ID, d.UID))
		return
	}
	unlockDisk()
	lock := s.keptLock(d.UID)
	lock.Lock()
	defer lock.Unlock()
	path := s.cfg.Kept.HomePath(req.Athanor, req.Home)
	if _, err := s.runHomeHelper(KeptAccount(d.UID), home.HelperSpec{Op: home.OpMake, Path: path, UID: d.UID}); err != nil {
		s.log.Error("home_make %s: uid %d: %v", req.ID, d.UID, err)
		s.send(c, protocol.NewError(req.ID, "", protocol.CodeInternal))
		return
	}
	s.send(c, protocol.NewHomeMade(req.ID, d.UID))
}

// recordDisk is athanor's disk, its record written first where none is,
// holding homeID where one is given, with the disk's lock held (lockDisk):
// a new disk draws its uid (drawKept) and takes this keeper's form
// (diskForm). It answers the code a refusal sends, logged as what's: the
// kept uids unreadable or every one taken, a disk that holds its most
// homes, or a record not written.
func (s *server) recordDisk(what, athanor, homeID string) (home.Disk, string) {
	s.mu.Lock()
	var d home.Disk
	recorded := s.disks[athanor] != nil
	if recorded {
		d = *s.disks[athanor]
	}
	s.mu.Unlock()
	if !recorded {
		uid, ok, err := s.drawKept(func() (map[int]bool, error) { return s.cfg.Kept.Taken("/proc") })
		if err != nil {
			s.log.Error("%s: reading the kept homes' root and /proc: %v", what, err)
			return d, protocol.CodeUnavailable
		}
		if !ok {
			s.log.Warn("%s refused: every kept uid is taken", what)
			return d, protocol.CodeCapacity
		}
		// Once its record is written the record holds the uid.
		defer s.unmakeKept(uid)
		d = home.Disk{Athanor: athanor, Form: s.diskForm(), UID: uid, Homes: []string{}}
	}
	if homeID == "" {
		if !recorded {
			if err := s.putDisk(d); err != nil {
				s.log.Error("%s: recording the person's disk: %v", what, err)
				return d, protocol.CodeInternal
			}
		}
		return d, ""
	}
	if recorded && !d.Holds(homeID) && len(d.Homes) >= home.MaxDiskHomes {
		s.log.Warn("%s refused: the disk of kept home %s holds %d homes, its most", what, homeID, len(d.Homes))
		return d, protocol.CodeCapacity
	}
	if !recorded || !d.Holds(homeID) {
		if err := s.putDisk(d.With(homeID)); err != nil {
			s.log.Error("%s: recording kept home %s on its disk: %v", what, homeID, err)
			return d, protocol.CodeInternal
		}
	}
	return d.With(homeID), ""
}

// retireHome ends every session of the home at, by its group, as a release
// does, and then, as the disk's uid, makes the home again empty for a
// `home_reset` or removes it for a `home_retire`; the home's lock is held,
// so no session of it starts meanwhile. Nothing else of the disk is
// touched: its other homes, their sessions, its work folder and its uid
// stay. A session whose group outlives its kill refuses the request, which
// changes nothing more. A retirement removes the folder before its record:
// a keeper killed between the two leaves a home its record lists and no
// folder, which the next retirement, or a make, settles.
func (s *server) retireHome(c *client, req *protocol.Request, at keptAt) {
	if !s.endHomeSessions(req.Home) {
		s.log.Warn("%s %s: a session of kept home %s outlived its group's kill", req.Type, req.ID, req.Home)
		s.send(c, protocol.NewError(req.ID, "", protocol.CodeInternal))
		return
	}
	op := home.OpRemove
	if req.Type == protocol.TypeHomeReset {
		op = home.OpReset
	}
	lock := s.keptLock(at.uid)
	lock.Lock()
	_, err := s.runHomeHelper(KeptAccount(at.uid), home.HelperSpec{Op: op, Path: at.path, UID: at.uid})
	lock.Unlock()
	if err != nil {
		s.log.Error("%s %s: kept home %s of uid %d: %v", req.Type, req.ID, req.Home, at.uid, err)
		s.send(c, protocol.NewError(req.ID, "", protocol.CodeInternal))
		return
	}
	if op == home.OpReset {
		s.log.Info("kept home %s of uid %d reset", req.Home, at.uid)
		s.send(c, protocol.NewHomeMade(req.ID, at.uid))
		return
	}
	defer s.lockDisk(at.athanor)()
	s.mu.Lock()
	recorded := s.disks[at.athanor]
	s.mu.Unlock()
	// The disk's record may have gone from the index meanwhile, removed by
	// hand while a write for that disk failed (putDisk): then no record
	// holds the home, as for a home no disk holds, and nothing is left to
	// change.
	if recorded == nil {
		s.log.Warn("home_retire %s: kept home %s's disk has no record any more; its folder is removed", req.ID, req.Home)
		s.send(c, protocol.NewHomeRetired(req.ID))
		return
	}
	if err := s.putDisk(recorded.Without(req.Home)); err != nil {
		s.log.Error("home_retire %s: removing kept home %s from its disk's record: %v", req.ID, req.Home, err)
		s.send(c, protocol.NewError(req.ID, "", protocol.CodeInternal))
		return
	}
	s.log.Info("kept home %s of uid %d retired; its disk, its work folder and its uid stay", req.Home, at.uid)
	s.send(c, protocol.NewHomeRetired(req.ID))
}

// endHomeSessions ends every spawn the keeper holds in the kept home id, as
// a release with homeRetireGrace does, and waits for each one's group to
// end, by its kill's own bound: its relay drains, and its `released`
// follows, on its reader's time, which the home's lock never waits for. It
// answers whether every one's group was found empty.
func (s *server) endHomeSessions(id string) bool {
	s.mu.Lock()
	var sessions []*spawn
	for _, sp := range s.spawns {
		if sp.kept && sp.keptHome == id {
			sessions = append(sessions, sp)
		}
	}
	s.mu.Unlock()
	for _, sp := range sessions {
		s.retire(sp, homeRetireGrace, true)
	}
	ended := true
	for _, sp := range sessions {
		if sp.groupEnded != nil {
			<-sp.groupEnded
		} else {
			<-sp.retired
		}
		s.mu.Lock()
		ended = ended && sp.ended
		s.mu.Unlock()
	}
	return ended
}

// handleHomeList answers a `home_list` with the page of kept home ids after
// its `after`, at most protocol.MaxHomeListIDs, naming the last as `next`
// when more follow: every home a disk's record holds, from the keeper's
// index.
func (s *server) handleHomeList(c *client, req *protocol.Request) {
	if s.keepsNoHomes(c, req) {
		return
	}
	s.mu.Lock()
	s.keptMaps()
	ids := make([]string, 0, len(s.homeDisk))
	for id := range s.homeDisk {
		ids = append(ids, id)
	}
	s.mu.Unlock()
	sort.Strings(ids)
	after := req.After.ID()
	ids = ids[sort.SearchStrings(ids, after):]
	if len(ids) > 0 && ids[0] == after {
		ids = ids[1:]
	}
	next := ""
	if len(ids) > protocol.MaxHomeListIDs {
		ids = ids[:protocol.MaxHomeListIDs]
		next = ids[len(ids)-1]
	}
	s.send(c, protocol.NewHomes(req.ID, ids, next))
}

// measureHome answers the bytes allocated under a kept home, measured as
// its disk's uid; a home not made holds none.
func (s *server) measureHome(acct Account, path string) (uint64, error) {
	if s.measuring != nil {
		s.measuring(path)
	}
	out, err := s.runHomeHelper(acct, home.HelperSpec{Op: home.OpMeasure, Path: path, UID: acct.UID})
	if err != nil {
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
	fds, err := stage.ReceiveDescriptors(from, 1)
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
