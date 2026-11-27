// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package serve

import (
	"bytes"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/cyfr/locus/keeper/guard"
	"github.com/cyfr/locus/keeper/internal/admission"
	"github.com/cyfr/locus/keeper/internal/cgroup"
	"github.com/cyfr/locus/keeper/internal/frame"
	"github.com/cyfr/locus/keeper/internal/home"
	"github.com/cyfr/locus/keeper/internal/packview"
	"github.com/cyfr/locus/keeper/internal/protocol"
	"github.com/cyfr/locus/keeper/internal/vm"
)

// A person's sessions run in their own VM, booted at their first: one VM
// for one person's two sessions, given that person's image, uid and route,
// and another for another person's. Each session is placed, its home made
// and spawned in its VM's guest, its standard streams joined to the role's
// attach socket byte for byte, and the host is charged once for the VM.
func TestAPersonsSessionsRunInTheirOwnVM(t *testing.T) {
	k := newVMKeeper(t)
	k.disk(t, "ath_a", "vlt_a1", "vlt_a2")
	k.disk(t, "ath_b", "vlt_b1")
	_, conn := k.session(t, "s1", "ath_a", "vlt_a1", nil)
	buf := make([]byte, frame.MaxPayload)
	_ = conn.SetReadDeadline(time.Now().Add(20 * time.Second))
	if stream, out, err := frame.Read(conn, buf); err != nil || stream != frame.StreamStdout || string(out) != "from the guest\n" {
		t.Fatalf("the role's half read %d %q %v, want the guest's own output", stream, out, err)
	}
	k.session(t, "s2", "ath_a", "vlt_a2", nil)
	if n := len(k.guest.booted()); n != 1 {
		t.Fatalf("one person's two sessions booted %d VMs, want one", n)
	}
	k.session(t, "s3", "ath_b", "vlt_b1", nil)
	vms := k.guest.booted()
	if len(vms) != 2 {
		t.Fatalf("two people booted %d VMs, want two", len(vms))
	}
	for i, athanor := range []string{"ath_a", "ath_b"} {
		b := vms[i].boot
		if b.Disk != k.kept.ImagePath(athanor) || b.UID != os.Getuid() || b.KeptRoot != k.kept.Root {
			t.Errorf("%s's VM was booted with %+v, want its own image under its disk's uid, the kept root covered", athanor, b)
		}
	}
	// Each VM's route was admitted at the VMM's uid, with reach none, and
	// changed to its person's live sessions' reach before each spawn.
	var admits []string
	for _, c := range k.guard.taken() {
		if c.op == guard.TypeAdmit {
			admits = append(admits, fmt.Sprintf("%s uid %d", c.reach, c.uid))
		}
	}
	if want := []string{fmt.Sprintf("none uid %d", os.Getuid()), fmt.Sprintf("none uid %d", os.Getuid())}; !reflect.DeepEqual(admits, want) {
		t.Fatalf("the guard admitted %v, want %v", admits, want)
	}
	if got, want := k.routeChanges(), []string{"island[]", "island[]"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("the routes' changes %v, want %v: one person's second session needs none", got, want)
	}
	want := []string{"place", "home_make", "spawn", "place", "home_make", "spawn", "place", "home_make", "spawn"}
	var made []string
	for _, r := range k.guest.requests() {
		if r != protocol.TypeMeasure {
			made = append(made, r)
		}
	}
	if !reflect.DeepEqual(made, want) {
		t.Fatalf("the guests read %v, want %v", made, want)
	}
	// The host charges each VM once: both of person a's sessions, starting,
	// within one VM's charge, its own allowance beside the first's.
	k.s.mu.Lock()
	used := k.s.ledger.Report("backends", 0, now()).Used
	k.s.mu.Unlock()
	if want := 2*(2*384+326)<<20 - 384<<20; used != uint64(want) {
		t.Fatalf("the pool holds %d, want two VMs' charges %d", used, want)
	}
}

// A session in a VM releases as one on the host does: its guest asked, its
// exit and its release told, its place freed; the VM stays for the next.
func TestASessionInAVMReleasesAsOnTheHost(t *testing.T) {
	k := newVMKeeper(t)
	k.disk(t, "ath_a", "vlt_a1")
	id, _ := k.session(t, "s1", "ath_a", "vlt_a1", nil)
	ms := int64(100)
	k.s.handle(k.c, &protocol.Request{V: protocol.Version, Type: protocol.TypeRelease, SpawnID: id, GraceMs: &ms})
	if m := k.next(t); m["type"] != "exited" || m["spawn_id"] != id || m["code"] != float64(0) {
		t.Fatalf("the release answered %v first, want its exit", m)
	}
	if m := k.next(t); m["type"] != "released" || m["spawn_id"] != id {
		t.Fatalf("the release answered %v, want released", m)
	}
	k.s.mu.Lock()
	places, held := len(k.c.places), k.s.spawns[id] != nil
	k.s.mu.Unlock()
	if places != 0 || held {
		t.Fatalf("a released session holds %d places, held %t", places, held)
	}
	if f := k.guest.booted()[0]; f.ended() {
		t.Fatal("the VM ended with its last session: it stays for the next")
	}
	k.session(t, "s2", "ath_a", "vlt_a1", nil)
	if n := len(k.guest.booted()); n != 1 {
		t.Fatalf("the next session booted %d VMs, want the one standing", n)
	}
}

// A VM's route allows what its person's live sessions together may reach,
// widened before each session's spawn and narrowed at each release, and
// one person's sessions' union is all a broken guest reaches.
func TestAVMsRouteAllowsItsLiveSessionsTogether(t *testing.T) {
	fakeResolver(t, map[string][]string{"a.example.com": {"203.0.113.7"}, "b.example.com": {"203.0.113.8", "203.0.113.7"}})
	k := newVMKeeper(t)
	k.disk(t, "ath_a", "vlt_a1", "vlt_a2", "vlt_a3")
	one, _ := k.session(t, "s1", "ath_a", "vlt_a1", []string{"a.example.com"})
	two, _ := k.session(t, "s2", "ath_a", "vlt_a2", []string{"b.example.com"})
	three, _ := k.session(t, "s3", "ath_a", "vlt_a3", nil)
	for _, id := range []string{three, two, one} {
		ms := int64(0)
		k.s.handle(k.c, &protocol.Request{V: protocol.Version, Type: protocol.TypeRelease, SpawnID: id, GraceMs: &ms})
		k.expect(t, "released")
	}
	want := []string{
		"hosts[203.0.113.7]",
		"hosts[203.0.113.7 203.0.113.8]",
		"island[]",
		"hosts[203.0.113.7 203.0.113.8]",
		"hosts[203.0.113.7]",
		"none[]",
	}
	if got := k.routeChanges(); !reflect.DeepEqual(got, want) {
		t.Fatalf("the route's changes %v, want %v", got, want)
	}
}

// A session whose hosts would carry its person's VM's route past the
// guard's bound is refused, and nothing of the route changes.
func TestASessionPastTheGuardsBoundIsRefusedAndTheRouteStands(t *testing.T) {
	many := make([]string, 0, guard.MaxAddresses+1)
	for i := 0; i <= guard.MaxAddresses; i++ {
		many = append(many, netip.AddrFrom4([4]byte{198, 18, byte(i >> 8), byte(i)}).String())
	}
	fakeResolver(t, map[string][]string{"a.example.com": many[:600], "b.example.com": many[600:]})
	k := newVMKeeper(t)
	k.disk(t, "ath_a", "vlt_a1", "vlt_a2")
	k.session(t, "s1", "ath_a", "vlt_a1", []string{"a.example.com"})
	before := k.routeChanges()
	k.place(t, "p-s2", "ath_a")
	k.s.handleSpawn(k.c, k.spawnReq("s2", "p-s2", "vlt_a2", []string{"b.example.com"}))
	if m := k.next(t); m["type"] != "error" || m["code"] != protocol.CodeUnavailable {
		t.Fatalf("a session past the guard's bound answered %v", m)
	}
	k.expect(t, "released")
	if got := k.routeChanges(); !reflect.DeepEqual(got, before) {
		t.Fatalf("the route changed %v, want it as it stood, %v", got, before)
	}
	if f := k.guest.booted()[0]; f.ended() {
		t.Fatal("the VM ended for a refused session")
	}
}

// A change the guard refuses while the old reach stands refuses the session
// that needed it, and changes nothing else; a change that leaves the route
// withdrawn ends the VM, its sessions with it.
func TestARefusedChangeRefusesItsSessionAndAWithdrawnOneEndsTheVM(t *testing.T) {
	fakeResolver(t, map[string][]string{"a.example.com": {"203.0.113.7"}, "b.example.com": {"203.0.113.8"}})
	k := newVMKeeper(t)
	k.disk(t, "ath_a", "vlt_a1", "vlt_a2", "vlt_a3")
	one, _ := k.session(t, "s1", "ath_a", "vlt_a1", []string{"a.example.com"})
	k.guard.mu.Lock()
	k.guard.changes = []error{errors.New("the guard refused the change of spawn x: its rules stand")}
	k.guard.mu.Unlock()
	k.place(t, "p-s2", "ath_a")
	k.s.handleSpawn(k.c, k.spawnReq("s2", "p-s2", "vlt_a2", []string{"b.example.com"}))
	if m := k.next(t); m["type"] != "error" || m["code"] != protocol.CodeGuardUnavailable {
		t.Fatalf("a session whose change was refused answered %v", m)
	}
	k.expect(t, "released")
	f := k.guest.booted()[0]
	if f.ended() {
		t.Fatal("a refused change, the old reach standing, ended the VM")
	}
	k.guard.mu.Lock()
	k.guard.changes = []error{fmt.Errorf("%w: refused", guard.ErrRouteWithdrawn)}
	k.guard.mu.Unlock()
	k.place(t, "p-s3", "ath_a")
	k.s.handleSpawn(k.c, k.spawnReq("s3", "p-s3", "vlt_a3", []string{"b.example.com"}))
	if m := k.next(t); m["type"] != "error" || m["code"] != protocol.CodeGuardUnavailable {
		t.Fatalf("a session whose route was withdrawn answered %v", m)
	}
	vmEventually(t, "the VM's end", f.ended)
	// The first session ends as the VM's end.
	var exited map[string]any
	for exited == nil {
		if m := k.next(t); m["type"] == "exited" && m["spawn_id"] == one {
			exited = m
		}
	}
	if exited["signal"] != "SIGKILL" {
		t.Fatalf("a session of a VM whose route was withdrawn exited %v", exited)
	}
}

// A narrowing the guard refuses while the old reach stands is asked again
// at each sweep, and no session joins the VM meanwhile; one that succeeds
// within its bound ends nothing, and one refused past its bound ends the VM.
func TestANarrowingRefusedIsAskedAgainWithinItsBound(t *testing.T) {
	fakeResolver(t, map[string][]string{"a.example.com": {"203.0.113.7"}, "b.example.com": {"203.0.113.8"}})
	k := newVMKeeper(t)
	k.disk(t, "ath_a", "vlt_a1", "vlt_a2", "vlt_a3")
	k.session(t, "s1", "ath_a", "vlt_a1", []string{"a.example.com"})
	two, _ := k.session(t, "s2", "ath_a", "vlt_a2", []string{"b.example.com"})
	k.guard.mu.Lock()
	k.guard.changes = []error{errors.New("refused: its rules stand")}
	k.guard.mu.Unlock()
	ms := int64(0)
	k.s.handle(k.c, &protocol.Request{V: protocol.Version, Type: protocol.TypeRelease, SpawnID: two, GraceMs: &ms})
	k.expect(t, "released")
	m := k.machineOfAthanor("ath_a")
	k.s.mu.Lock()
	narrowing := !m.narrowing.IsZero()
	k.s.mu.Unlock()
	if !narrowing {
		t.Fatal("a refused narrowing was not kept to be asked again")
	}
	// No session joins while it stands.
	k.place(t, "p-s3", "ath_a")
	k.s.handleSpawn(k.c, k.spawnReq("s3", "p-s3", "vlt_a3", nil))
	if m := k.next(t); m["type"] != "error" || m["code"] != protocol.CodeGuardUnavailable {
		t.Fatalf("a session joining while the route narrows answered %v", m)
	}
	k.expect(t, "released")
	// Within its bound, the sweep's ask succeeds: nothing ends.
	k.s.retryNarrowing()
	k.s.mu.Lock()
	narrowing = !m.narrowing.IsZero()
	k.s.mu.Unlock()
	f := k.guest.booted()[0]
	if narrowing || f.ended() {
		t.Fatalf("the narrowing within its bound: still narrowing %t, the VM ended %t", narrowing, f.ended())
	}
	if got := k.routeChanges(); got[len(got)-1] != "hosts[203.0.113.7]" {
		t.Fatalf("the route's last change %v, want the live session's", got)
	}
	k.session(t, "s4", "ath_a", "vlt_a3", nil)
	// Refused again, past its bound: the VM ends.
	k.guard.mu.Lock()
	k.guard.changes = []error{errors.New("refused"), errors.New("refused")}
	k.guard.mu.Unlock()
	four := k.lastSpawnOf(t, "vlt_a3")
	k.s.handle(k.c, &protocol.Request{V: protocol.Version, Type: protocol.TypeRelease, SpawnID: four, GraceMs: &ms})
	k.expect(t, "released")
	k.s.mu.Lock()
	m.narrowing = now().Add(-narrowWait)
	k.s.mu.Unlock()
	k.s.retryNarrowing()
	vmEventually(t, "the VM's end past the narrowing's bound", f.ended)
}

// lastSpawnOf is the spawn id the keeper holds in home.
func (k *vmKeeper) lastSpawnOf(t *testing.T, home string) string {
	t.Helper()
	k.s.mu.Lock()
	defer k.s.mu.Unlock()
	for id, sp := range k.s.spawns {
		if sp.keptHome == home {
			return id
		}
	}
	t.Fatalf("no spawn in %s", home)
	return ""
}

// The guard's loss ends every VM routed over its connection at once: each
// session ends as the VM's end, and the VM is released once its route went
// with the connection.
func TestTheGuardsLossEndsTheVMsRoutedOverIt(t *testing.T) {
	k := newVMKeeper(t)
	k.disk(t, "ath_a", "vlt_a1")
	id, _ := k.session(t, "s1", "ath_a", "vlt_a1", nil)
	m := k.machineOfAthanor("ath_a")
	k.guard.mu.Lock()
	k.guard.dead = true
	k.guard.mu.Unlock()
	k.s.guardLost(1)
	f := k.guest.booted()[0]
	vmEventually(t, "the VM's end", f.ended)
	ex := k.expect(t, "exited")
	if ex["spawn_id"] != id || ex["signal"] != "SIGKILL" {
		t.Fatalf("its session exited %v", ex)
	}
	if r := k.expect(t, "released"); r["spawn_id"] != id {
		t.Fatalf("released %v", r)
	}
	select {
	case <-m.done:
	case <-time.After(20 * time.Second):
		t.Fatal("the VM was not released after the guard's loss")
	}
	k.s.mu.Lock()
	used := k.s.ledger.Report("backends", 0, now()).Used
	k.s.mu.Unlock()
	if used != 0 {
		t.Fatalf("the pool holds %d after the VM's release, want none", used)
	}
}

// The VMM's end, the guest's first process's among them, ends every session
// in it: said as the machine's memory where the VMM's group's own counters
// say the kernel killed for memory, SIGKILL alone otherwise.
func TestTheVMMsEndEndsItsSessionsSaidByItsCounters(t *testing.T) {
	for _, c := range []struct {
		cause  cgroup.Cause
		memory any
	}{{cgroup.AtBound, protocol.MemoryMachine}, {cgroup.NotKilled, nil}} {
		k := newVMKeeper(t)
		k.disk(t, "ath_a", "vlt_a1")
		id, _ := k.session(t, "s1", "ath_a", "vlt_a1", nil)
		k.guest.booted()[0].end(vm.EndOwnExit, c.cause)
		ex := k.expect(t, "exited")
		if ex["spawn_id"] != id || ex["signal"] != "SIGKILL" || ex["memory"] != c.memory {
			t.Fatalf("cause %v: its session exited %v, want memory %v", c.cause, ex, c.memory)
		}
		k.expect(t, "released")
	}
}

// The control connection's end, the guest's relay's, ends the sessions it
// served; the VM stays, and the next session connects to it again.
func TestTheRelaysEndEndsItsSessionsAndTheVMStays(t *testing.T) {
	saved := vmEndWait
	vmEndWait = 10 * time.Millisecond
	t.Cleanup(func() { vmEndWait = saved })
	k := newVMKeeper(t)
	k.disk(t, "ath_a", "vlt_a1", "vlt_a2")
	id, _ := k.session(t, "s1", "ath_a", "vlt_a1", nil)
	f := k.guest.booted()[0]
	f.mu.Lock()
	control := f.controls[0]
	f.mu.Unlock()
	_ = control.Close()
	ex := k.expect(t, "exited")
	if ex["spawn_id"] != id || ex["signal"] != "SIGKILL" || ex["memory"] != nil {
		t.Fatalf("its session exited %v", ex)
	}
	k.expect(t, "released")
	if f.ended() {
		t.Fatal("the relay's end ended the VM")
	}
	k.session(t, "s2", "ath_a", "vlt_a2", nil)
	f.mu.Lock()
	connections := len(f.controls)
	f.mu.Unlock()
	if len(k.guest.booted()) != 1 || connections != 2 {
		t.Fatalf("the next session booted %d VMs over %d connections, want the one VM's second connection", len(k.guest.booted()), connections)
	}
}

// A guest that does not answer within its bound, or does not release a
// session, leaves the VM in no known state for it: the VM ends.
func TestAGuestThatDoesNotAnswerEndsItsVM(t *testing.T) {
	guestWaitFor(t, 200*time.Millisecond)
	k := newVMKeeper(t)
	k.disk(t, "ath_a", "vlt_a1", "vlt_a2")
	k.guest.answer = func(_ *fakeVM, req map[string]any) ([]any, bool) {
		return nil, req["type"] == protocol.TypeSpawn
	}
	k.place(t, "p-s1", "ath_a")
	k.s.handleSpawn(k.c, k.spawnReq("s1", "p-s1", "vlt_a1", nil))
	if m := k.next(t); m["type"] != "error" || m["code"] != protocol.CodeUnavailable {
		t.Fatalf("a spawn its guest never answered answered %v", m)
	}
	vmEventually(t, "the VM's end", k.guest.booted()[0].ended)

	k2 := newVMKeeper(t)
	k2.disk(t, "ath_a", "vlt_a1")
	id, _ := k2.session(t, "s1", "ath_a", "vlt_a1", nil)
	k2.guest.answer = func(_ *fakeVM, req map[string]any) ([]any, bool) {
		return nil, req["type"] == protocol.TypeRelease
	}
	ms := int64(0)
	k2.s.handle(k2.c, &protocol.Request{V: protocol.Version, Type: protocol.TypeRelease, SpawnID: id, GraceMs: &ms})
	vmEventually(t, "the VM's end", k2.guest.booted()[0].ended)
	k2.expect(t, "released")
}

func guestWaitFor(t *testing.T, d time.Duration) {
	saved := guestWait
	guestWait = d
	t.Cleanup(func() { guestWait = saved })
}

// A control connection that greets from another boot is no VM this keeper
// started: what it says settles nothing, and the VM ends.
func TestAGuestOfAnotherBootSettlesNothing(t *testing.T) {
	saved := vmEndWait
	vmEndWait = 10 * time.Millisecond
	t.Cleanup(func() { vmEndWait = saved })
	k := newVMKeeper(t)
	k.disk(t, "ath_a", "vlt_a1", "vlt_a2")
	k.session(t, "s1", "ath_a", "vlt_a1", nil)
	f := k.guest.booted()[0]
	f.mu.Lock()
	f.bootID = "99999999-4b5a-4978-8796-a5b4c3d2e1f0"
	control := f.controls[0]
	f.mu.Unlock()
	_ = control.Close()
	k.expect(t, "released")
	k.place(t, "p-s2", "ath_a")
	k.s.handleSpawn(k.c, k.spawnReq("s2", "p-s2", "vlt_a2", nil))
	if m := k.next(t); m["type"] != "error" {
		t.Fatalf("a session over a guest of another boot answered %v", m)
	}
	vmEventually(t, "the VM's end", f.ended)
}

// A start in a VM whose route was made and whose VMM then did not start
// withdraws that route, and is refused.
func TestAVMThatDoesNotStartWithdrawsItsRoute(t *testing.T) {
	k := newVMKeeper(t)
	k.disk(t, "ath_a", "vlt_a1")
	k.guest.refuseBoot = errors.New("the VMM's space did not start")
	k.place(t, "p-s1", "ath_a")
	k.s.handleSpawn(k.c, k.spawnReq("s1", "p-s1", "vlt_a1", nil))
	if m := k.next(t); m["type"] != "error" || m["code"] != protocol.CodeUnavailable {
		t.Fatalf("a session whose VM did not start answered %v", m)
	}
	m := k.machineOfAthanor("ath_a")
	var ops []string
	for _, c := range k.guard.taken() {
		ops = append(ops, c.op)
	}
	if !reflect.DeepEqual(ops, []string{guard.TypeAdmit, guard.TypeClear}) {
		t.Fatalf("the guard was asked %v, want the route's admit and its clear", ops)
	}
	k.s.mu.Lock()
	used, held := k.s.ledger.Report("backends", 0, now()).Used, m != nil && k.s.vms["ath_a"] == m
	k.s.mu.Unlock()
	if used != 0 || held {
		t.Fatalf("a VM that never started holds %d bytes, kept %t", used, held)
	}
}

// An image that is not its disk's uid's alone is given no VM.
func TestAnImageNotItsUIDsAloneIsGivenNoVM(t *testing.T) {
	k := newVMKeeper(t)
	k.disk(t, "ath_a", "vlt_a1")
	if err := os.Chmod(k.kept.ImagePath("ath_a"), 0o640); err != nil {
		t.Fatal(err)
	}
	k.place(t, "p-s1", "ath_a")
	k.s.handleSpawn(k.c, k.spawnReq("s1", "p-s1", "vlt_a1", nil))
	if m := k.next(t); m["type"] != "error" || m["code"] != protocol.CodeUnavailable {
		t.Fatalf("a session of an image open to its group answered %v", m)
	}
	if n := len(k.guest.booted()); n != 0 {
		t.Fatalf("%d VMs booted on an image open to its group", n)
	}
}

// A session's packs reach its VM's guest by the control connection, as the
// host's own copy's stream, put once: the next session of that generation
// finds it held there.
func TestASessionsPacksArePutIntoItsVMOnce(t *testing.T) {
	k := newVMKeeper(t)
	k.disk(t, "ath_a", "vlt_a1", "vlt_a2")
	files := map[string]string{"pstack/skills/poteto-mode/SKILL.md": "# poteto\n", "pstack/bin/run": "#!/bin/sh\necho ran\n"}
	digest := putPacks(t, k, "ath_a", files)
	for i, h := range []string{"vlt_a1", "vlt_a2"} {
		id := fmt.Sprintf("s%d", i+1)
		k.place(t, "p-"+id, "ath_a")
		req := k.spawnReq(id, "p-"+id, h, nil)
		req.Packs = &protocol.SpawnPacks{Athanor: "ath_a", Digest: digest}
		k.s.handleSpawn(k.c, req)
		k.expect(t, "spawned")
		<-k.roleEnds
	}
	puts := 0
	for _, r := range k.guest.requests() {
		if r == protocol.TypePacksPut {
			puts++
		}
	}
	if puts != 1 {
		t.Fatalf("the generation was put in %d parts across two sessions, want one put", puts)
	}
	k.guest.mu.Lock()
	stream := k.guest.puts[digest]
	k.guest.mu.Unlock()
	dir := t.TempDir()
	if err := packview.Extract(bytes.NewReader(stream), dir); err != nil {
		t.Fatalf("the guest's stream does not extract: %v", err)
	}
	for name, body := range files {
		got, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil || string(got) != body {
			t.Fatalf("%s reached the guest as %q %v", name, got, err)
		}
	}
	if info, err := os.Stat(filepath.Join(dir, "pstack/bin/run")); err != nil || info.Mode().Perm()&0o100 == 0 {
		t.Fatalf("an executable pack file reached the guest without its bit: %v %v", info, err)
	}
}

// putPacks puts a generation of files into the host's store for athanor, as
// a role's put does, and answers its digest.
func putPacks(t *testing.T, k *vmKeeper, athanor string, files map[string]string) string {
	t.Helper()
	src := t.TempDir()
	for name, body := range files {
		mode := os.FileMode(0o644)
		if strings.HasPrefix(body, "#!") {
			mode = 0o755
		}
		if err := os.MkdirAll(filepath.Dir(filepath.Join(src, name)), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(src, name), []byte(body), mode); err != nil {
			t.Fatal(err)
		}
	}
	var stream bytes.Buffer
	if err := packview.Stream(src, &stream); err != nil {
		t.Fatal(err)
	}
	digest := "sha256:" + strings.Repeat("ab", 32)
	owner := &packview.Owner{}
	b := stream.Bytes()
	for seq := 0; ; seq++ {
		end := min(len(b), protocol.MaxPackPartBytes)
		last := end == len(b)
		if _, err := k.s.packs.Put(owner, athanor, "lt-1", digest, uint64(seq), last, b[:end]); err != nil {
			t.Fatal(err)
		}
		b = b[end:]
		if last {
			break
		}
	}
	return digest
}

// The wall is given where the keeper keeps homes, was given KVM and the
// image's guest, and a first session in a VM fits beside the floor; a
// keeper given any less gives spaces, and says why.
func TestTheWallIsGivenOnlyWhereAFirstSessionInAVMFits(t *testing.T) {
	dev := t.TempDir()
	files := []string{filepath.Join(dev, "firecracker"), filepath.Join(dev, "vmlinux")}
	for _, f := range files {
		if err := os.WriteFile(f, nil, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	savedKVM, savedFiles := kvmPath, guestFiles
	t.Cleanup(func() { kvmPath, guestFiles = savedKVM, savedFiles })
	// /dev/full is a character device whose group is root's, as no VMM may
	// hold; a test host without a usable /dev/kvm stands it in for none.
	guestFiles = files
	fits := admission.Allowance(admission.Session) + admission.MachineBytes
	base := func() *server {
		s := &server{cfg: Config{Kept: &home.Kept{Root: dev}}, rest: fits}
		s.roles = []*role{{spec: RoleSpec{Name: "backends", Kept: true}}}
		return s
	}
	kvmPath = "/dev/full"
	if wall, why := base().wallOf(); wall || !strings.Contains(why, "/dev/kvm") {
		t.Fatalf("a device of root's group gave the wall %t (%s)", wall, why)
	}
	if _, err := os.Stat("/dev/kvm"); err != nil || !kvmGiven("/dev/kvm") {
		t.Skip("this host gives no /dev/kvm whose group is not root's")
	}
	kvmPath = "/dev/kvm"
	if wall, why := base().wallOf(); !wall {
		t.Fatalf("a keeper with everything a VM needs gave no wall: %s", why)
	}
	s := base()
	s.rest = fits - 1
	if wall, why := s.wallOf(); wall || !strings.Contains(why, "does not fit") {
		t.Fatalf("a first session that does not fit gave the wall %t (%s)", wall, why)
	}
	s = base()
	s.roles[0].spec.Kept = false
	if wall, _ := s.wallOf(); wall {
		t.Fatal("a keeper whose roles keep no homes gave the wall")
	}
	guestFiles = []string{filepath.Join(dev, "absent")}
	if wall, why := base().wallOf(); wall || !strings.Contains(why, "no guest") {
		t.Fatalf("an image with no guest gave the wall %t (%s)", wall, why)
	}
}

var _ = net.Pipe

// A home on an image is measured by its person's VM: the one standing, or
// one booted for a session place of the person's, as the measure before a
// capped session's spawn is; its home is made in the guest first. With no
// session of the person's placed, no VM boots for a measure.
func TestAHomesMeasureOfAnImageGoesThroughItsVM(t *testing.T) {
	k := newVMKeeper(t)
	k.disk(t, "ath_a", "vlt_a1")
	measure := func(id string) map[string]any {
		k.s.handle(k.c, &protocol.Request{V: protocol.Version, Type: protocol.TypeHomeMeasure, ID: id, Home: "vlt_a1"})
		return k.next(t)
	}
	if m := measure("m0"); m["type"] != "error" || m["code"] != protocol.CodeUnavailable || len(k.guest.booted()) != 0 {
		t.Fatalf("a measure with no session placed answered %v and booted %d VMs", m, len(k.guest.booted()))
	}
	k.place(t, "p-s1", "ath_a")
	if m := measure("m1"); m["type"] != "home_measured" || m["bytes"] != float64(12345) {
		t.Fatalf("a measure before the person's first spawn answered %v", m)
	}
	if n := len(k.guest.booted()); n != 1 {
		t.Fatalf("the measure booted %d VMs, want the person's one", n)
	}
	k.s.handleSpawn(k.c, k.spawnReq("s1", "p-s1", "vlt_a1", nil))
	k.expect(t, "spawned")
	if m := measure("m2"); m["type"] != "home_measured" || len(k.guest.booted()) != 1 {
		t.Fatalf("a measure while the VM runs answered %v, %d VMs", m, len(k.guest.booted()))
	}
	var seen []string
	for _, r := range k.guest.requests() {
		if r == protocol.TypeHomeMake || r == protocol.TypeHomeMeasure || r == protocol.TypeSpawn {
			seen = append(seen, r)
		}
	}
	want := []string{"home_make", "home_measure", "home_make", "spawn", "home_make", "home_measure"}
	if !reflect.DeepEqual(seen, want) {
		t.Fatalf("the guest read %v, want %v", seen, want)
	}
}

// A person's VM is given its role's work's processors, or the machine's
// where those are unbounded, never fewer than a session's.
func TestAVMsProcessorsAreItsRolesWork(t *testing.T) {
	s := &server{}
	for _, c := range []struct {
		work uint64
		want int
	}{{3 * cgroup.CPUPeriod, 3}, {cgroup.CPUPeriod / 2, 2}, {0, min(max(runtime.NumCPU(), 2), maxVCPUs)}} {
		if got := s.machineVCPUs(&role{workCPU: c.work}); got != c.want {
			t.Errorf("work %d: %d processors, want %d", c.work, got, c.want)
		}
	}
}
