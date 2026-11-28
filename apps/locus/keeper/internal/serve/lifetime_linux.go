// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package serve

import (
	"time"

	"github.com/cyfr/locus/keeper/internal/admission"
	"github.com/cyfr/locus/keeper/internal/vm"
)

// A person's VM's lifetime (plan V2). It boots at the first session of
// theirs the keeper admits and outlives their last: a program lives for one
// turn, and a VM that ended with its last session would boot at every turn.
// It ends once it has held no session for machineIdleFor, or sooner where a
// start needs its room: a VM that holds no session is idle work, which gives
// way before any start is refused, as idle runners do (admission's
// giveWay); a VM that holds a session is never ended for room. Its end is
// asked of the guest's first process, which acknowledges it, stops the
// guest's keeper and resets the guest; one not acknowledged, or whose VMM
// has not exited, within the close's own bound is killed. Its release
// follows as at any end of a VM (machineEnded).

// machineIdleFor is how long a person's VM may hold no session before it
// ends: one constant, no setting. A variable its tests shorten.
var machineIdleFor = 10 * time.Minute

// machineCloseWait bounds a VM's asked end, the close's own wait
// (Prima.LocusBackends.close_wait_ms, admission.RoomWait): past it the VMM
// is killed.
const machineCloseWait = admission.RoomWait

// endMachine ends m, at rest, for why: only one no place names, whose end
// has not begun, so no session of the person is cut short, and a start of
// theirs from here boots a VM of its own once this one is released.
func (s *server) endMachine(m *machine, why string) {
	s.mu.Lock()
	idle := m.vm != nil && !m.ending && m.places == 0 && len(m.sessions) == 0
	if idle {
		m.ending = true
	}
	g := m.vm
	s.mu.Unlock()
	if !idle {
		return
	}
	s.log.Info("a person's VM ends: %s", why)
	go func() {
		if how := g.End(machineCloseWait); how != vm.EndAcknowledged {
			s.log.Warn("a person's VM's end was not acknowledged within %s: %s", machineCloseWait, how)
		}
	}()
}

// giveWay ends an idle VM the admission asked room of.
func (s *server) giveWay(m *machine) {
	s.endMachine(m, "it held no session, and a start needs its room")
}

// endIdleMachines ends every VM that has held no session for
// machineIdleFor, and no place names (endMachine).
func (s *server) endIdleMachines() {
	s.mu.Lock()
	var idle []*machine
	for _, m := range s.vms {
		if m.vm != nil && !m.ending && len(m.sessions) == 0 && now().Sub(m.idleSince) >= machineIdleFor {
			idle = append(idle, m)
		}
	}
	s.mu.Unlock()
	for _, m := range idle {
		s.endMachine(m, "it held no session for "+machineIdleFor.String())
	}
}
