// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package access

import (
	"errors"
	"fmt"
	"os"
	"strconv"
	"sync"
	"time"
)

// holderRecord is who holds the lock, as access_busy reports it: the
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
	return fmt.Sprintf("cyfr %s on %s, since %s", h.Command, h.Host, h.Started.UTC().Format(time.RFC3339))
}

func (e *Engine) lockProject(command string) (func(), error) {
	if e.lock != nil {
		return nil, errors.New("access: this engine already holds the lock")
	}
	if err := e.ensureState(); err != nil {
		return nil, err
	}
	f, err := os.OpenFile(e.path(lockFile), os.O_RDWR|os.O_CREATE, 0o600)
	if err != nil {
		return nil, fmt.Errorf("access: open the lock: %w", err)
	}
	busy, err := lockExclusive(f)
	if err != nil || busy {
		f.Close()
		if busy {
			return nil, e.busy()
		}
		return nil, fmt.Errorf("access: take the lock: %w", err)
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

// recordWait bounds how long a refused taker waits for the holder's
// record: a holder writes it right after it takes the lock, so a taker
// refused in between, or finding the record a dead holder left, reads it
// again before naming the holder.
const recordWait = 250 * time.Millisecond

// busy is the lock's refusal, from the holder record the holder wrote. A
// record on this host whose holder and watchdog have both died is an
// earlier holder's, not this one's. A holder that wrote none (a process
// taking the lock some other way) is named by the kernel's lock table
// where it has one.
func (e *Engine) busy() *ErrBusy {
	host, _ := os.Hostname()
	end := time.Now().Add(recordWait)
	for {
		var h holderRecord
		ok, err := readJSON(e.path(holderFile), &h)
		live := err == nil && ok && h.Command != "" &&
			(h.Host != host || processAlive(h.PID) || h.WatchdogPID > 0 && processAlive(h.WatchdogPID))
		if live {
			b := &ErrBusy{Holder: h.String(), PID: h.PID, WatchdogPID: h.WatchdogPID}
			if h.Until != nil {
				b.Until = *h.Until
			}
			return b
		}
		if !time.Now().Before(end) {
			return &ErrBusy{Holder: "a process that wrote no holder record", PID: lockOwner(e.path(lockFile))}
		}
		time.Sleep(5 * time.Millisecond)
	}
}

// noteWatchdog records, durably, the watchdog now holding the lock's
// descriptor for a docker child and when its deadline ends; doneWatchdog
// records that it ended. The record names the running child whose
// deadline ends last, and none between calls.
func (e *Engine) noteWatchdog(pid int, until time.Time) {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.lock == nil {
		return
	}
	if e.watchdogs == nil {
		e.watchdogs = map[int]time.Time{}
	}
	e.watchdogs[pid] = until.UTC().Truncate(time.Second).Add(time.Second)
	e.writeHolder()
}

func (e *Engine) doneWatchdog(pid int) {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.lock == nil {
		return
	}
	delete(e.watchdogs, pid)
	e.writeHolder()
}

// writeHolder writes the holder record with its latest running child;
// e.mu is held.
func (e *Engine) writeHolder() {
	e.holder.WatchdogPID, e.holder.Until = 0, nil
	for pid, until := range e.watchdogs {
		if e.holder.Until == nil || until.After(*e.holder.Until) {
			u := until
			e.holder.WatchdogPID, e.holder.Until = pid, &u
		}
	}
	e.writeJSON(e.path(holderFile), e.holder)
}

// requireLock refuses a method that changes the stack without the lock.
func (e *Engine) requireLock() error {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.lock == nil {
		return errors.New("access: the engine's lock is not held; take it with Lock first")
	}
	return nil
}

// refusal is access_busy: the watchdog and its deadline while a docker
// child holds the lock, else the holder's own pid, or "unknown" for a
// holder neither its record nor the kernel names.
func (b *ErrBusy) refusal() *Refusal {
	if b.WatchdogPID > 0 && !b.Until.IsZero() {
		return Refuse("access_busy", map[string]string{"holder": b.Holder, "pid": strconv.Itoa(b.WatchdogPID), "until": b.Until.UTC().Format(time.RFC3339)})
	}
	if b.PID > 0 {
		return Refuse("access_busy", map[string]string{"holder": b.Holder, "pid": strconv.Itoa(b.PID)})
	}
	return Refuse("access_busy", map[string]string{"holder": b.Holder})
}

// joinBusy is access_busy for a join still waiting for its approval.
func joinBusy(joinID string, until time.Time) *Refusal {
	return Refuse("access_busy", map[string]string{"join_id": joinID, "until": until.UTC().Format(time.RFC3339)})
}
