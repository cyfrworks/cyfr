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
	"strconv"
	"strings"
	"sync"
	"time"
	"unsafe"

	"golang.org/x/sys/unix"

	"github.com/cyfr/locus/keeper/internal/home"
	"github.com/cyfr/locus/keeper/internal/protocol"
)

const (
	// helperTimeout bounds one `cyfr-locus home` run.
	helperTimeout = 30 * time.Second
	// homeRetireGrace is the grace a home's processes get before a
	// home_retire kills them.
	homeRetireGrace = time.Second
	// ptyRows and ptyCols are a pseudo-terminal's size.
	ptyRows = 40
	ptyCols = 120
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

// handleKeptSpawn starts a spawn in a made kept home, under the home's own
// uid and no uid of a pool, refused as CodeHomeOverCap when the home already
// holds its home_max_bytes. Its start holds the uid's lock, so it never
// starts during the uid's full retirement or a home request.
func (s *server) handleKeptSpawn(req *protocol.Request) {
	uid, err := s.keptHome(req.HomePath, req.HomeUID)
	if err != nil {
		s.log.Warn("spawn %s refused: %v", req.ID, err)
		s.send(protocol.NewError(req.ID, "", protocol.CodeBadRequest))
		return
	}
	s.mu.Lock()
	_, known := s.pools[req.Pool]
	s.mu.Unlock()
	if !known {
		s.send(protocol.NewError(req.ID, "", protocol.CodeUnknownPool))
		return
	}
	acct := KeptAccount(uid)
	lock := s.keptLock(uid)
	lock.Lock()
	if err := home.CheckKeptHome(req.HomePath, uid); err != nil {
		lock.Unlock()
		s.log.Warn("spawn %s refused: the kept home of uid %d is not made: %v", req.ID, uid, err)
		s.send(protocol.NewError(req.ID, "", protocol.CodeBadRequest))
		return
	}
	if max := req.HomeMaxBytes; max != nil {
		bytes, err := s.measureHome(acct, req.HomePath)
		if err != nil {
			lock.Unlock()
			s.log.Error("spawn %s: measuring the kept home of uid %d: %v", req.ID, uid, err)
			s.send(protocol.NewError(req.ID, "", protocol.CodeInternal))
			return
		}
		if bytes >= *max {
			lock.Unlock()
			s.log.Warn("spawn %s refused: the kept home of uid %d holds %d bytes, at or over its bound %d", req.ID, uid, bytes, *max)
			s.send(protocol.NewError(req.ID, "", protocol.CodeHomeOverCap))
			return
		}
	}
	s.mu.Lock()
	s.keptLive[uid]++
	s.mu.Unlock()
	lock.Unlock()

	sp := &spawn{kept: true, account: acct, home: req.HomePath, exitReported: make(chan struct{}), retired: make(chan struct{})}
	if sp.id, err = randomHex(16); err != nil {
		s.log.Error("spawn %s: %v", req.ID, err)
		s.retire(sp, 0, false)
		s.send(protocol.NewError(req.ID, "", protocol.CodeInternal))
		return
	}
	if code, err := s.launch(sp, req); err != nil {
		s.log.Error("spawn %s on kept uid %d: %v", req.ID, uid, err)
		s.retire(sp, 0, false)
		s.send(protocol.NewError(req.ID, "", code))
		return
	}
	s.mu.Lock()
	s.spawns[sp.id] = sp
	s.mu.Unlock()
	s.log.Info("spawn %s: kept uid %d, leader pid %d", sp.id, uid, sp.leader.pid)
	s.send(protocol.NewSpawned(req.ID, sp.id, uid, sp.leader.pid))
	go s.watchLeader(sp)
}

// retireKept ends a kept spawn once: the processes of its own group, which
// are everything it started; then, when no other spawn holds its uid, the
// uid's full retirement, every process and IPC object of the uid and what it
// left on the writable mounts but its home. The uid stays its home's.
func (s *server) retireKept(sp *spawn, grace time.Duration, notify bool) {
	sp.retireOnce.Do(func() {
		go func() {
			defer close(sp.retired)
			uid := sp.account.UID
			if sp.group != nil && !sp.group.Kill(grace) {
				s.log.Warn("spawn %s: processes of kept uid %d outlived their group's kill", sp.id, uid)
			}
			if sp.relay != nil {
				select {
				case <-sp.relay.done:
				case <-time.After(time.Second):
					s.signalChild(sp.relay, unix.SIGKILL)
				}
			}
			s.mu.Lock()
			s.keptLive[uid]--
			s.mu.Unlock()

			lock := s.keptLock(uid)
			lock.Lock()
			s.mu.Lock()
			last := s.keptLive[uid] == 0
			if last {
				delete(s.keptLive, uid)
			}
			s.mu.Unlock()
			if last && !s.scrub(sp.account, 0, nil, sp.home) {
				s.log.Warn("spawn %s: kept uid %d: a process or something it left outside its home outlived retirement", sp.id, uid)
			}
			lock.Unlock()

			if sp.group != nil {
				if err := sp.group.Remove(); err != nil {
					s.log.Warn("spawn %s: removing the memory group of kept uid %d: %v", sp.id, uid, err)
				}
			}
			s.mu.Lock()
			delete(s.spawns, sp.id)
			s.mu.Unlock()
			s.log.Info("spawn %s: kept uid %d retired", sp.id, uid)
			if notify {
				s.reportReleased(sp)
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

// openPty opens a pseudo-terminal of ptyRows by ptyCols: its master, which
// the relay holds, and its slave, which becomes the spawn's stdin, stdout
// and stderr and its controlling terminal.
func openPty() (master, slave *os.File, err error) {
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
	if err := unix.IoctlSetWinsize(sfd, unix.TIOCSWINSZ, &unix.Winsize{Row: ptyRows, Col: ptyCols}); err != nil {
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
