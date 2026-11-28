// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package serve

import (
	"os"
	"sort"
	"syscall"

	"golang.org/x/sys/unix"

	"github.com/cyfr/locus/keeper/internal/admission"
	"github.com/cyfr/locus/keeper/internal/home"
	"github.com/cyfr/locus/keeper/internal/protocol"
	"github.com/cyfr/locus/keeper/internal/retire"
	"github.com/cyfr/locus/keeper/internal/vm"
)

// The wall (plan D18). A keeper gives each person a VM of their own where
// it keeps homes, its kept role runs, it holds the two devices a VMM opens,
// KVM (vm.KVM) and tun (tunDevice), the image carries the guest
// (vm.Firecracker, vm.Kernel), its guard routes a person's VM (the hello's
// machines member, guard.Client.Machines), and a first session in a VM
// fits rest beside the floor: a session's allowance and the VM's own,
// which follows the guest's size, rest (machineGuest). Each device is read
// by its numbers, as docker-compose.yml gives /dev/null at a path whose
// device the machine lacks, by the bits a VMM's own open needs, and opened:
// a VMM opens KVM through its group, which is never root's, and tun as
// anyone. It decides once, at its start, from its own W and F, and the
// decision is whole before any disk is touched (giveWall); elsewhere the
// same spaces run on the shared kernel, as they do without KVM.

// Seams of the wall's decision: the devices and files it reads, and how a
// device is opened.
var (
	kvmPath    = vm.KVM
	tunPath    = tunDevice
	guestFiles = []string{vm.Firecracker, vm.Kernel}
	openDevice = func(path string) error {
		fd, err := unix.Open(path, unix.O_RDWR|unix.O_CLOEXEC, 0)
		if err == nil {
			_ = unix.Close(fd)
		}
		return err
	}
)

// tunDevice is the tun device's path, where the stage binds it from into
// a VM's space (package stage).
const tunDevice = "/dev/net/tun"

// The two devices' numbers (linux/miscdevice.h): each a misc device.
const (
	miscMajor = 10
	kvmMinor  = 232
	tunMinor  = 200
)

// wallOf is the decision, as the keeper's report carries it
// (protocol.WallGiven, WallNoRoom or WallLacking), and, where it is no,
// why not.
func (s *server) wallOf() (string, string) {
	kept := false
	for _, r := range s.roles {
		kept = kept || r.spec.Kept
	}
	if s.cfg.Kept == nil || !kept {
		return protocol.WallLacking, "no role of it keeps homes"
	}
	if why := deviceHeld(kvmPath, vm.KVM, kvmMinor, true); why != "" {
		return protocol.WallLacking, why
	}
	if why := deviceHeld(tunPath, tunDevice, tunMinor, false); why != "" {
		return protocol.WallLacking, why
	}
	for _, f := range guestFiles {
		if _, err := os.Stat(f); err != nil {
			return protocol.WallLacking, "the image carries no guest (" + f + ")"
		}
	}
	// The kept role's pool is routed, so the keeper's start has proved its
	// guard (proveGuard) and read its hello. It is asked after KVM: a
	// guest's own keeper, which has none, never takes its own guard's
	// answer for the host's.
	if why := s.guard.Machines(); why != "" {
		return protocol.WallLacking, why
	}
	if need := admission.Allowance(admission.Session) + admission.MachineBytes(s.machineGuest()); s.rest < need {
		return protocol.WallNoRoom, "a first session in a VM, " + describeBytes(need) + ", does not fit the work pool's " + describeBytes(s.rest) + " beside the floor"
	}
	return protocol.WallGiven, ""
}

// deviceHeld says why the device named name, at path, is not one a VMM can
// open, "" where it is: the misc device of minor, read and written through
// its group, which is not root's, where byGroup (KVM), or by anyone (tun),
// and open to this keeper.
func deviceHeld(path, name string, minor uint32, byGroup bool) string {
	info, err := os.Stat(path)
	if err != nil || info.Mode()&os.ModeCharDevice == 0 {
		return "the container was given no " + name
	}
	st, ok := info.Sys().(*syscall.Stat_t)
	if !ok || unix.Major(st.Rdev) != miscMajor || unix.Minor(st.Rdev) != minor {
		return "the container was given no " + name
	}
	switch {
	case byGroup && st.Gid == 0:
		return name + "'s group is root's, which no VMM holds"
	case byGroup && info.Mode().Perm()&0o060 != 0o060:
		return name + " is not read and written by its group, as a VMM opens it"
	case !byGroup && info.Mode().Perm()&0o006 != 0o006:
		return name + " is not read and written by everyone, as a VMM opens it"
	}
	if err := openDevice(path); err != nil {
		return name + " does not open here: " + err.Error()
	}
	return ""
}

// giveWall applies the decision at the keeper's start, before any role
// starts: where the keeper gives the wall, every disk it makes is an image,
// and every disk of the directory form is retired, its homes, its work
// folder and its record, so the person's programs sign in again in their
// VM. Nothing turns one form into the other. A retirement that does not
// finish leaves that disk refusing every session of it (startKeptSpawn).
func (s *server) giveWall() {
	given, why := s.wallOf()
	// The one place the report's wall is set: handleReport copies it.
	wall := given == protocol.WallGiven
	s.wall, s.wallGiven, s.imageDisks, s.wallWhy = wall, given, wall, why
	if !wall {
		s.log.Info("each person's work runs in its own space on this machine: %s", why)
		return
	}
	s.log.Info("each person's work runs in a separate small computer on this machine: a VM of their own, booted at their first session")
	s.retireDirectories()
	// No VM runs at the start: every disk that has never held a kept home
	// goes, one a keeper killed while retiring it left among them.
	s.mu.Lock()
	s.keptMaps()
	var unkept []string
	for a, d := range s.disks {
		if d.Unkept {
			unkept = append(unkept, a)
		}
	}
	s.mu.Unlock()
	sort.Strings(unkept)
	for _, a := range unkept {
		s.retireUnkept(a)
	}
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
