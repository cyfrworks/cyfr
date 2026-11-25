// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Package written records what one run of a command wrote: each file it
// created or replaced and each directory it made, at the real path the
// write landed on, links resolved. A command run through sudo gives
// exactly that back to the account that ran sudo (cmd's
// returnToSudoAccount), never a file it only read.
//
// One run records at a time: Begin starts the record and its Set's End
// stops it. Every writer that writes a command's files (the access
// engine's durable writes and lock, the scaffold's extraction, the
// snapshot and the put-back) reports through File and Dir, which record
// nothing while no run records.
package written

import (
	"os"
	"path/filepath"
	"sync"
)

// Entry is one recorded write: the real, absolute path it landed on, and
// whether it is a directory the run made, every entry under which the
// run made too.
type Entry struct {
	Path string
	Made bool
}

// Set is one run's record, in the order the writes happened, each path
// once.
type Set struct {
	mu      sync.Mutex
	entries []Entry
	seen    map[string]int
}

var (
	mu      sync.Mutex
	current *Set
)

// Begin starts recording a run's writes into a new Set, replacing any
// record still open.
func Begin() *Set {
	s := &Set{seen: map[string]int{}}
	mu.Lock()
	current = s
	mu.Unlock()
	return s
}

// End stops recording into s; a later run's record is left open.
func (s *Set) End() {
	mu.Lock()
	if current == s {
		current = nil
	}
	mu.Unlock()
}

// Entries answers what s recorded, in order.
func (s *Set) Entries() []Entry {
	if s == nil {
		return nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]Entry(nil), s.entries...)
}

// File records that the open run created or replaced the file at p.
func File(p string) { record(p, false) }

// Dir records that the open run made the directory at p.
func Dir(p string) { record(p, true) }

func record(p string, made bool) {
	mu.Lock()
	s := current
	mu.Unlock()
	if s == nil {
		return
	}
	real := realPath(p)
	s.mu.Lock()
	defer s.mu.Unlock()
	if i, ok := s.seen[real]; ok {
		s.entries[i].Made = s.entries[i].Made || made
		return
	}
	s.seen[real] = len(s.entries)
	s.entries = append(s.entries, Entry{Path: real, Made: made})
}

// realPath is where a write at p landed: p absolute, the links of the
// directory it lies in resolved. The entry itself is not resolved: a
// write that replaces a link replaces the link.
func realPath(p string) string {
	abs, err := filepath.Abs(p)
	if err != nil {
		return p
	}
	if dir, err := filepath.EvalSymlinks(filepath.Dir(abs)); err == nil {
		return filepath.Join(dir, filepath.Base(abs))
	}
	return abs
}

// Missing reports whether nothing is at p, so a write there creates it.
func Missing(p string) bool {
	_, err := os.Lstat(p)
	return os.IsNotExist(err)
}
