// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package vm

import (
	"net/netip"
	"os"
	"reflect"
	"strings"
	"testing"
	"time"

	"golang.org/x/sys/unix"

	"github.com/cyfr/locus/keeper/internal/home"
	"github.com/cyfr/locus/keeper/internal/stage"
)

// stageEnd is the two ends of a person's VM's space's route socket: the
// stage's and the keeper's.
func stageEnd(t *testing.T) (*os.File, *os.File) {
	t.Helper()
	fds, err := unix.Socketpair(unix.AF_UNIX, unix.SOCK_STREAM|unix.SOCK_CLOEXEC, 0)
	if err != nil {
		t.Fatal(err)
	}
	if err := unix.SetNonblock(fds[1], true); err != nil {
		t.Fatal(err)
	}
	s, k := os.NewFile(uintptr(fds[0]), "stage"), os.NewFile(uintptr(fds[1]), "keeper")
	t.Cleanup(func() { s.Close(); k.Close() })
	return s, k
}

// handUp sends four descriptors as a person's machine's stage does, and
// answers what the keeper then writes, or the end of the socket.
func handUp(t *testing.T, s *os.File) <-chan string {
	t.Helper()
	var held []int
	for i := 0; i < 4; i++ {
		fd, err := unix.Open("/dev/null", unix.O_RDONLY|unix.O_CLOEXEC, 0)
		if err != nil {
			t.Fatal(err)
		}
		held = append(held, fd)
	}
	word := make(chan string, 1)
	go func() {
		if err := unix.Sendmsg(int(s.Fd()), []byte{'r'}, unix.UnixRights(held...), nil, 0); err != nil {
			word <- "send: " + err.Error()
			return
		}
		for _, fd := range held {
			_ = unix.Close(fd)
		}
		b := make([]byte, 1)
		if n, err := s.Read(b); n != 1 || err != nil {
			word <- "end"
			return
		}
		word <- string(b)
	}()
	return word
}

// A person's VM's space hands its namespace and name sockets up; the
// route is made from them as the VMM's uid's, and only then is the stage
// told to go on, the machine holding the route's two addresses.
func TestAPersonsVMIsToldToGoOnOnceItsRouteIsMade(t *testing.T) {
	s, k := stageEnd(t)
	word := handUp(t, s)
	m := &Machine{uid: 30201}
	want := Network{Inner: netip.MustParseAddr("10.213.0.2"), Gateway: netip.MustParseAddr("10.213.0.1")}
	var asked int
	err := m.route(k, func(uid int, netns, udp, tcp, nl *os.File) (Network, error) {
		asked = uid
		for _, f := range []*os.File{netns, udp, tcp, nl} {
			if f == nil {
				t.Error("a descriptor is missing")
			}
		}
		return want, nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if asked != 30201 || m.Network() != want {
		t.Fatalf("the route was made for uid %d, the machine holds %+v", asked, m.Network())
	}
	if got := <-word; got != string(stage.RouteGo) {
		t.Fatalf("the stage was told %q", got)
	}
}

// A route the guard refuses tells the stage nothing: it ends with the
// socket, and no VMM is executed.
func TestAPersonsVMWhoseRouteIsRefusedIsNeverToldToGoOn(t *testing.T) {
	s, k := stageEnd(t)
	word := handUp(t, s)
	m := &Machine{uid: 30201}
	err := m.route(k, func(int, *os.File, *os.File, *os.File, *os.File) (Network, error) {
		return Network{}, os.ErrPermission
	})
	if err == nil || !strings.Contains(err.Error(), "the machine's route") {
		t.Fatalf("a refused route answered %v", err)
	}
	k.Close()
	if got := <-word; got != "end" {
		t.Fatalf("a stage whose route was refused was told %q", got)
	}
	if m.Network().Inner.IsValid() {
		t.Fatal("a machine whose route was refused holds an address")
	}
}

// A space that hands nothing up within the bound is refused, naming it.
func TestAPersonsVMThatHandsNoRouteUpIsRefusedAtItsBound(t *testing.T) {
	saved := stageWait
	stageWait = 200 * time.Millisecond
	t.Cleanup(func() { stageWait = saved })
	_, k := stageEnd(t)
	m := &Machine{uid: 30201}
	err := (m.route(k, func(int, *os.File, *os.File, *os.File, *os.File) (Network, error) {
		t.Error("a route was made with nothing handed up")
		return Network{}, nil
	}))
	if err == nil || !strings.Contains(err.Error(), "handed up no route within 200ms") {
		t.Fatalf("a space that handed nothing up answered %v", err)
	}
}

// guest-check's machine is configured as before: the image's programs
// alone, no card. A person's VM has their disk second, writable, its card
// on the guard's tap, and its address on the kernel's command line.
func TestAPersonsVMHasItsDiskCardAndAddress(t *testing.T) {
	device := &Device{Path: "/var/lib/locus/guest/" + strings.Repeat("a", 64) + ".sqfs"}
	check := Config{Device: device, VCPUs: 1, MemoryMiB: 256, BootArgs: "quiet"}
	m := &Machine{dir: "/run/locus/machines/30201-x"}
	var paths []string
	for _, p := range m.puts(check) {
		paths = append(paths, p.path)
	}
	if want := []string{"/machine-config", "/boot-source", "/drives/programs", "/vsock", "/balloon", "/actions"}; !reflect.DeepEqual(paths, want) {
		t.Fatalf("guest-check's machine is configured by %v", paths)
	}
	person := check
	person.Disk = "/var/lib/locus/kept/" + strings.Repeat("b", 64) + ".img"
	m.network = Network{Inner: netip.MustParseAddr("10.213.0.6"), Gateway: netip.MustParseAddr("10.213.0.5")}
	got := map[string]any{}
	paths = nil
	for _, p := range m.puts(person) {
		paths = append(paths, p.path)
		got[p.path] = p.body
	}
	if want := []string{"/machine-config", "/boot-source", "/drives/programs", "/drives/disk", "/network-interfaces/eth0", "/vsock", "/balloon", "/actions"}; !reflect.DeepEqual(paths, want) {
		t.Fatalf("a person's VM is configured by %v", paths)
	}
	if disk := got["/drives/disk"].(map[string]any); disk["path_on_host"] != person.Disk || disk["is_read_only"] != false || disk["is_root_device"] != false {
		t.Fatalf("the disk: %v", disk)
	}
	if card := got["/network-interfaces/eth0"].(map[string]any); card["host_dev_name"] != "tap0" || card["guest_mac"] != "06:00:0a:00:00:02" {
		t.Fatalf("the card: %v", card)
	}
	if args := got["/boot-source"].(map[string]any)["boot_args"]; args != "quiet cyfr.net=10.213.0.6,10.213.0.5" {
		t.Fatalf("the command line: %v", args)
	}
}

// Descriptors a space hands up just after the bound are never the keeper's:
// none is left open in this process, however many times it happens.
func TestARouteHandedUpPastTheBoundLeavesNothingOpen(t *testing.T) {
	saved := stageWait
	stageWait = 50 * time.Millisecond
	t.Cleanup(func() { stageWait = saved })
	open := func() int {
		entries, err := os.ReadDir("/proc/self/fd")
		if err != nil {
			t.Fatal(err)
		}
		return len(entries)
	}
	before := open()
	for i := 0; i < 20; i++ {
		s, k := stageEnd(t)
		late := make(chan struct{})
		go func() {
			defer close(late)
			time.Sleep(stageWait + 10*time.Millisecond) // sleep-ok: the hand-up comes just past the bound, as the review's did
			var held []int
			for j := 0; j < 4; j++ {
				fd, err := unix.Open("/dev/null", unix.O_RDONLY|unix.O_CLOEXEC, 0)
				if err == nil {
					held = append(held, fd)
				}
			}
			_ = unix.Sendmsg(int(s.Fd()), []byte{'r'}, unix.UnixRights(held...), nil, 0)
			for _, fd := range held {
				_ = unix.Close(fd)
			}
		}()
		m := &Machine{uid: 30201}
		if err := m.route(k, func(int, *os.File, *os.File, *os.File, *os.File) (Network, error) { return Network{}, nil }); err == nil {
			t.Fatal("a route handed up past the bound was taken")
		}
		<-late
		s.Close()
		k.Close()
	}
	if after := open(); after > before {
		t.Fatalf("%d descriptors are left open by routes handed up past the bound", after-before)
	}
}

// A person's VMM writes its disk's image, up to the image's own size, and
// no further; guest-check's, which has no disk, keeps its file-size limit
// at its sockets'. Past its limit the kernel would end the VMM at the
// guest's first write there.
func TestAPersonsVMMWritesItsImageToItsSize(t *testing.T) {
	if got := limitsOf(Config{Disk: "/var/lib/locus/kept/" + strings.Repeat("b", 64) + ".img"}).Fsize; got != home.ImageBytes {
		t.Fatalf("a person's VMM may write %d bytes of a file, want its image's %d", got, uint64(home.ImageBytes))
	}
	if got := limitsOf(Config{}).Fsize; got != machineLimits.Fsize {
		t.Fatalf("guest-check's VMM may write %d bytes of a file, want %d", got, machineLimits.Fsize)
	}
}
