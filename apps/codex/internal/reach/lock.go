// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package reach

import (
	"errors"
	"fmt"
	"os"
	"strconv"
	"sync"
	"time"
)

// holderRecord is who holds the lock, as reach_busy reports it: the
// command, the host or container it runs in, its pid in its own
// namespace and when it took the lock; and, once it has started a docker
// child, the watchdog that holds the lock's descriptor for that child and
// when the child's deadline ends.
type holderRecord struct {
	Command     string     `json:"command"`
	Host        string     `json:"host"`
	PID         int        `json:"pid"`
	Started     time.Time  `json:"started"`
	WatchdogPID int        `json:"watchdog_pid,omitempty"`
	Until       *time.Time `json:"until,omitempty"`
}

func (h holderRecord) String() string {
	return fmt.Sprintf("cyfr %s, pid %d on %s, since %s", h.Command, h.PID, h.Host, h.Started.UTC().Format(time.RFC3339))
}

func (e *Engine) lockProject(command string) (func(), error) {
	if e.lock != nil {
		return nil, errors.New("reach: this engine already holds the lock")
	}
	if err := e.ensureState(); err != nil {
		return nil, err
	}
	f, err := os.OpenFile(e.path(lockFile), os.O_RDWR|os.O_CREATE, 0o600)
	if err != nil {
		return nil, fmt.Errorf("reach: open the lock: %w", err)
	}
	busy, err := lockExclusive(f)
	if err != nil || busy {
		f.Close()
		if busy {
			return nil, e.busy()
		}
		return nil, fmt.Errorf("reach: take the lock: %w", err)
	}
	host, _ := os.Hostname()
	e.mu.Lock()
	e.lock = f
	e.holder = holderRecord{Command: command, Host: host, PID: os.Getpid(), Started: time.Now().UTC()}
	err = e.writeJSON(e.path(holderFile), e.holder)
	e.mu.Unlock()
	if err != nil {
		e.unlock()
		return nil, err
	}
	return sync.OnceFunc(e.unlock), nil
}

// unlock ends the lock's operation: the materialized files it made that
// no unfinished journal names are removed, the holder record goes, and
// the lock's descriptor is closed. A docker child still holding the
// descriptor keeps the lock until it exits.
func (e *Engine) unlock() {
	e.dropFiles(nil, false)
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.lock == nil {
		return
	}
	os.Remove(e.path(holderFile))
	syncDir(e.path())
	e.lock.Close()
	e.lock = nil
}

// busy is the lock's refusal, from the holder record the holder wrote.
func (e *Engine) busy() *ErrBusy {
	var h holderRecord
	b := &ErrBusy{Holder: "an unknown process"}
	if ok, err := readJSON(e.path(holderFile), &h); err == nil && ok && h.Command != "" {
		b.Holder = h.String()
		b.WatchdogPID = h.WatchdogPID
		if h.Until != nil {
			b.Until = *h.Until
		}
	}
	return b
}

// noteWatchdog records, durably, the watchdog now holding the lock's
// descriptor for a docker child and when its deadline ends.
func (e *Engine) noteWatchdog(pid int, until time.Time) {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.lock == nil {
		return
	}
	until = until.UTC().Truncate(time.Second).Add(time.Second)
	e.holder.WatchdogPID, e.holder.Until = pid, &until
	e.writeJSON(e.path(holderFile), e.holder)
}

// requireLock refuses a method that changes the stack without the lock.
func (e *Engine) requireLock() error {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.lock == nil {
		return errors.New("reach: the engine's lock is not held; take it with Lock first")
	}
	return nil
}

func (b *ErrBusy) refusal() *Refusal {
	pid, until := "none", "none"
	if b.WatchdogPID > 0 {
		pid = strconv.Itoa(b.WatchdogPID)
	}
	if !b.Until.IsZero() {
		until = b.Until.UTC().Format(time.RFC3339)
	}
	return Refuse("reach_busy", map[string]string{"holder": b.Holder, "pid": pid, "until": until})
}
