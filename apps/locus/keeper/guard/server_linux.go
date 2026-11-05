// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package guard

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"sync"
	"syscall"
	"time"

	"github.com/cyfr/locus/keeper/internal/logx"
)

// Exit statuses of `cyfr-locus guard-control`.
const (
	ExitUsage  = 64
	ExitConfig = 78
	ExitServe  = 70
)

// Script is the guard that installs a uid's rules, run once per request
// (cyfr-guard.sh, installed under this name on PATH).
const Script = "cyfr-guard"

// Main runs `cyfr-locus guard-control <socket> <ranges>`, which the guard
// execs once its rules are installed: it serves the control on socket
// until it is stopped, acting on the uids of ranges alone, the spawn ranges
// the guard was given (`<first>-<last>`, comma-separated).
func Main(args []string) int {
	log := logx.New("cyfr-guard")
	if len(args) != 2 || !filepath.IsAbs(args[0]) || filepath.Clean(args[0]) != args[0] {
		log.Error("usage: cyfr-locus guard-control <socket> <ranges>, the socket a clean absolute path")
		return ExitUsage
	}
	ranges, err := ParseRanges(args[1])
	if err != nil {
		log.Error("refusing to serve: the spawn ranges: %v", err)
		return ExitConfig
	}
	netns, err := os.Readlink("/proc/self/ns/net")
	if err != nil {
		log.Error("refusing to serve: reading this network namespace: %v", err)
		return ExitConfig
	}
	listener, err := listen(args[0])
	if err != nil {
		log.Error("refusing to serve: %v", err)
		return ExitConfig
	}
	log.Info("control: serving %s for spawns %v in %s", args[0], ranges, netns)
	s := &server{log: log, ranges: ranges, netns: netns, apply: runScript}
	for {
		conn, err := listener.AcceptUnix()
		if err != nil {
			log.Error("control: accepting: %v", err)
			return ExitServe
		}
		go s.serve(conn)
	}
}

// listen makes the control's socket: its directory is root's own and is
// made 0700, a socket left by an earlier guard is removed, and the socket
// is made 0600 as it is bound, so no other user ever reaches it.
func listen(path string) (*net.UnixListener, error) {
	dir := filepath.Dir(path)
	info, err := os.Lstat(dir)
	if err != nil {
		return nil, err
	}
	st, ok := info.Sys().(*syscall.Stat_t)
	if !info.IsDir() || !ok || st.Uid != 0 {
		return nil, fmt.Errorf("%s must be a directory root owns", dir)
	}
	if err := os.Chmod(dir, 0o700); err != nil {
		return nil, err
	}
	if old, err := os.Lstat(path); err == nil {
		if old.Mode()&os.ModeSocket == 0 {
			return nil, fmt.Errorf("%s exists and is not a socket", path)
		}
		if err := os.Remove(path); err != nil {
			return nil, err
		}
	}
	mask := syscall.Umask(0o077)
	defer syscall.Umask(mask)
	return net.ListenUnix("unix", &net.UnixAddr{Name: path, Net: "unix"})
}

// server applies requests one at a time: mu is held across each run of the
// guard script, whichever connection asked.
type server struct {
	log    *logx.Logger
	ranges []Range
	netns  string
	mu     sync.Mutex
	// apply runs the guard script with its arguments.
	apply func(args ...string) error
}

func runScript(args ...string) error {
	cmd := exec.Command(Script, args...)
	cmd.Stdout = os.Stderr
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		return err
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	select {
	case err := <-done:
		return err
	case <-time.After(applyTimeout):
		_ = cmd.Process.Kill()
		<-done
		return errors.New("the guard did not finish")
	}
}

// serve answers one connection until it ends, then refuses every uid it
// admitted and did not clear since every public address.
func (s *server) serve(conn *net.UnixConn) {
	defer conn.Close()
	admitted := map[uint64]bool{}
	defer func() {
		uids := make([]uint64, 0, len(admitted))
		for uid := range admitted {
			uids = append(uids, uid)
		}
		sort.Slice(uids, func(i, j int) bool { return uids[i] < uids[j] })
		for _, uid := range uids {
			if err := s.do(Message{Type: TypeAdmit, UID: &uid}); err != nil {
				s.log.Error("control: uid %d, admitted over a connection that ended, could not be refused: %v", uid, err)
			}
		}
		if len(uids) > 0 {
			s.log.Warn("control: a connection ended; uids %v are refused every public address until their next spawn", uids)
		}
	}()
	hello, err := Encode(Message{Type: TypeHello, Netns: s.netns})
	if err == nil {
		_, err = conn.Write(hello)
	}
	if err != nil {
		return
	}
	r := bufio.NewReaderSize(conn, 4096)
	for {
		line, err := readLine(r)
		if err != nil {
			if !errors.Is(err, io.EOF) {
				s.log.Warn("control: reading a request: %v", err)
			}
			return
		}
		reply := s.answer(line, admitted)
		out, err := Encode(reply)
		if err == nil {
			_, err = conn.Write(out)
		}
		if err != nil {
			return
		}
	}
}

// answer applies one request and names the outcome. A request that names
// a uid outside the guard's ranges, or that the guard script could not
// apply, is refused.
func (s *server) answer(line []byte, admitted map[uint64]bool) Message {
	req, err := ParseRequest(line)
	if err != nil {
		s.log.Warn("control: refused a request: %v", err)
		return Message{Type: TypeRefused, Reason: err.Error()}
	}
	uid := *req.UID
	if !Holds(s.ranges, uid) {
		s.log.Warn("control: refused %s of uid %d, outside the spawn ranges", req.Type, uid)
		return Message{Type: TypeRefused, UID: &uid, Reason: "the uid is no spawn's of this island"}
	}
	if req.Type == TypeAdmit {
		admitted[uid] = true
	}
	if err := s.do(req); err != nil {
		s.log.Error("control: %s of uid %d: %v", req.Type, uid, err)
		return Message{Type: TypeRefused, UID: &uid, Reason: "the guard could not install the uid's rules"}
	}
	if req.Type == TypeClear {
		delete(admitted, uid)
		return Message{Type: TypeCleared, UID: &uid}
	}
	return Message{Type: TypeAdmitted, UID: &uid}
}

// do runs the guard script for one request: `admit <uid> [address…]`,
// where no address refuses the uid every public one, or `clear <uid>`.
func (s *server) do(req Message) error {
	args := []string{req.Type, strconv.FormatUint(*req.UID, 10)}
	if req.Type == TypeAdmit {
		args = append(args, req.Addresses...)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.apply(args...)
}
