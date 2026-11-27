// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package serve

import (
	"os"
	"sort"
	"syscall"

	"github.com/cyfr/locus/keeper/internal/admission"
	"github.com/cyfr/locus/keeper/internal/home"
	"github.com/cyfr/locus/keeper/internal/retire"
	"github.com/cyfr/locus/keeper/internal/vm"
)

// The wall (plan D18). A keeper gives each person a VM of their own where
// it keeps homes, its kept role runs, it was given KVM (vm.KVM, a device
// whose group is not root's, as every VMM holds it) and the image carries
// the guest (vm.Firecracker, vm.Kernel), its guard routes a person's VM
// (the hello's machines member, guard.Client.Machines), and a first
// session in a VM fits
// rest beside the floor: a session's allowance and the VM's own, which
// follows the guest's size, rest (machineGuest). It decides
// once, at its start, from its own W and F; elsewhere the same spaces run
// on the shared kernel, as they do without KVM.

// Seams of the wall's decision: the devices and files it reads.
var (
	kvmPath    = vm.KVM
	guestFiles = []string{vm.Firecracker, vm.Kernel}
)

// wallOf is the decision and, where it is no, why not.
func (s *server) wallOf() (bool, string) {
	kept := false
	for _, r := range s.roles {
		kept = kept || r.spec.Kept
	}
	switch {
	case s.cfg.Kept == nil || !kept:
		return false, "no role of it keeps homes"
	case !kvmGiven(kvmPath):
		return false, "the container was given no " + vm.KVM
	}
	for _, f := range guestFiles {
		if _, err := os.Stat(f); err != nil {
			return false, "the image carries no guest (" + f + ")"
		}
	}
	// The kept role's pool is routed, so the keeper's start has proved its
	// guard (proveGuard) and read its hello. It is asked after KVM: a
	// guest's own keeper, which has none, never takes its own guard's
	// answer for the host's.
	if why := s.guard.Machines(); why != "" {
		return false, why
	}
	if need := admission.Allowance(admission.Session) + admission.MachineBytes(s.machineGuest()); s.rest < need {
		return false, "a first session in a VM, " + describeBytes(need) + ", does not fit the work pool's " + describeBytes(s.rest) + " beside the floor"
	}
	return true, ""
}

// kvmGiven says path is a character device whose group is not root's.
func kvmGiven(path string) bool {
	info, err := os.Stat(path)
	if err != nil || info.Mode()&os.ModeCharDevice == 0 {
		return false
	}
	st, ok := info.Sys().(*syscall.Stat_t)
	return ok && st.Gid != 0
}

// giveWall applies the decision at the keeper's start, before any role
// starts: where the keeper gives the wall, every disk it makes is an image,
// and every disk of the directory form is retired, its homes, its work
// folder and its record, so the person's programs sign in again in their
// VM. Nothing turns one form into the other. A retirement that does not
// finish leaves that disk refusing every session of it (startKeptSpawn).
func (s *server) giveWall() {
	wall, why := s.wallOf()
	s.wall, s.imageDisks = wall, wall
	if !wall {
		s.log.Info("each person's work runs in its own space on this machine: %s", why)
		return
	}
	s.log.Info("each person's work runs in a separate small computer on this machine: a VM of their own, booted at their first session")
	s.retireDirectories()
}

// retireDirectories retires every disk of the directory form, on a keeper
// that gives the wall.
func (s *server) retireDirectories() {
	s.mu.Lock()
	s.keptMaps()
	var directories []home.Disk
	for _, d := range s.disks {
		if d.Form == home.FormDirectory {
			directories = append(directories, *d)
		}
	}
	s.mu.Unlock()
	sort.Slice(directories, func(i, j int) bool { return directories[i].UID < directories[j].UID })
	retired := 0
	for _, d := range directories {
		if s.retireDisk(d) {
			retired++
		}
	}
	if len(directories) > 0 {
		s.log.Info("%d of %d disks of the directory form retired: their people sign in to their programs again", retired, len(directories))
	}
}

// retireDisk retires a disk of the directory form whole, as its uid: every
// process of the uid, its folder, then its record.
func (s *server) retireDisk(d home.Disk) bool {
	unlock := s.lockDisk(d.Athanor)
	defer unlock()
	path := s.cfg.Kept.DiskPath(d.Athanor)
	if exit := s.runRetire(KeptAccount(d.UID), []string{path}, 0); exit != retire.ExitClean && exit != retire.ExitResidue {
		s.log.Error("the directory disk of uid %d was not retired (retire exited %d): its sessions are refused", d.UID, exit)
		return false
	}
	if _, err := os.Lstat(path); err == nil || !os.IsNotExist(err) {
		s.log.Error("the directory disk of uid %d is still there after its retirement: its sessions are refused", d.UID)
		return false
	}
	if err := s.cfg.Kept.RemoveDisk(d.Athanor); err != nil {
		s.log.Error("the record of the retired directory disk of uid %d: %v", d.UID, err)
		return false
	}
	s.indexDisk(d.Athanor, nil)
	return true
}
