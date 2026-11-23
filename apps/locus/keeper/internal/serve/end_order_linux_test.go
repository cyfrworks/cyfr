// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package serve

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"golang.org/x/sys/unix"

	"github.com/cyfr/locus/keeper/internal/cgroup"
	"github.com/cyfr/locus/keeper/internal/protocol"
)

// endGrace is the grace these tests end a group within, the kept spawn's
// own (the backends service's stop grace).
const endGrace = 2 * time.Second

// blockingChild is a child that blocks TERM, so a TERM sent to it stays
// pending, which /proc/<pid>/status shows: the test reads from the kernel
// whether TERM has reached it, with no clock. It says "child-ready <pid>"
// once TERM is blocked. Told by its leader (the stop file), it ends after
// close seconds saying "child-clean"; once TERM is pending, it says
// "child-asked", ends after close seconds saying "child-ended".
func blockingChild(close string) string {
	return `perl -MPOSIX -MTime::HiRes=sleep -e '
		my ($log, $stop, $close) = @ARGV;
		sub out { open my $f, ">>", $log or die; print $f "@_\n"; close $f }
		POSIX::sigprocmask(POSIX::SIG_BLOCK(), POSIX::SigSet->new(POSIX::SIGTERM())) or die;
		out("child-ready", $$);
		while (1) {
			if (-e $stop) { sleep $close; out("child-clean"); exit 0 }
			my $pending = POSIX::SigSet->new; POSIX::sigpending($pending);
			if ($pending->ismember(POSIX::SIGTERM())) { out("child-asked"); sleep $close; out("child-ended"); exit 0 }
			sleep 0.01;
		}' "$L" "$L.stop" ` + close
}

// heldLeader is a leader's script around its child (run in the background
// before it): on TERM it says "leader-got-term" and waits for the test's
// word, the go file, before it does what then does and exits.
func heldLeader(then string) string {
	return ` &
		 child=$!
		 trap 'echo leader-got-term >> "$L"; while [ ! -e "$L.go" ]; do sleep 0.01; done; ` + then + `; echo leader-exits >> "$L"; exit 0' TERM
		 echo leader-ready >> "$L"
		 while :; do sleep 0.05; done`
}

// endingGroup runs script as the leader of a bounded group of its own and
// answers the leader, the group and a log file the script writes to as $L.
func endingGroup(t *testing.T, k *keeper, uid int, script string) (*child, *cgroup.Group, string) {
	t.Helper()
	group, err := k.s.memory.Create(cgroup.Name(uid), 256<<20, protocol.CPUPeriod)
	if err != nil {
		t.Fatal(err)
	}
	log := filepath.Join(t.TempDir(), "log")
	if err := os.WriteFile(log, nil, 0o666); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		group.Kill(0)
		if err := group.Remove(); err != nil {
			t.Error(err)
		}
	})
	leader, _ := k.runIn(t, group, "L="+log+"; "+script)
	return leader, group, log
}

// logged waits until the log holds a line beginning with each of want and
// answers its lines as their words; a line that never comes fails the test.
func logged(t *testing.T, log string, want ...string) [][]string {
	t.Helper()
	for deadline := time.Now().Add(20 * time.Second); ; time.Sleep(10 * time.Millisecond) {
		data, err := os.ReadFile(log)
		if err != nil && !os.IsNotExist(err) {
			t.Fatal(err)
		}
		var got [][]string
		have := map[string]bool{}
		for _, line := range strings.Split(string(data), "\n") {
			if fields := strings.Fields(line); len(fields) > 0 {
				got = append(got, fields)
				have[fields[0]] = true
			}
		}
		var missing []string
		for _, w := range want {
			if !have[w] {
				missing = append(missing, w)
			}
		}
		if len(missing) == 0 {
			return got
		}
		if time.Now().After(deadline) {
			t.Fatalf("%v never came: %q", missing, names(got))
		}
	}
}

// names are the lines' first words, in their order.
func names(lines [][]string) string {
	var out []string
	for _, l := range lines {
		out = append(out, l[0])
	}
	return strings.Join(out, " ")
}

// childPID is the pid the child said it is.
func childPID(t *testing.T, lines [][]string) int {
	t.Helper()
	for _, l := range lines {
		if l[0] == "child-ready" && len(l) > 1 {
			pid, err := strconv.Atoi(l[1])
			if err != nil {
				t.Fatal(err)
			}
			return pid
		}
	}
	t.Fatal("the child named no pid")
	return 0
}

// termReached says whether TERM has reached the child of pid: a TERM
// pending on it, which blocks TERM, read from the kernel's own record, or
// its log's word that it saw one and is ending, or its end.
func termReached(t *testing.T, log string, pid int) bool {
	t.Helper()
	data, err := os.ReadFile(fmt.Sprintf("/proc/%d/status", pid))
	if err != nil {
		return true
	}
	if lines, _ := os.ReadFile(log); strings.Contains(string(lines), "child-asked") {
		return true
	}
	for _, line := range strings.Split(string(data), "\n") {
		name, value, _ := strings.Cut(line, ":")
		if name != "SigPnd" && name != "ShdPnd" {
			continue
		}
		mask, err := strconv.ParseUint(strings.TrimSpace(value), 16, 64)
		if err != nil {
			t.Fatal(err)
		}
		if mask&(1<<(uint(syscall.SIGTERM)-1)) != 0 {
			return true
		}
	}
	return false
}

// ending runs endInOrder on the group in the background and answers a
// channel that carries whether the group was empty when it returned.
func ending(k *keeper, group *cgroup.Group, leader *child) chan bool {
	ended := make(chan bool, 1)
	go func() { ended <- k.s.endInOrder("t", group, leader, time.Now().Add(endGrace)) }()
	return ended
}

// A leader that ends its child on TERM: while the leader holds its TERM the
// child has no TERM pending, and it ends as its leader told it. On TERM to
// the whole group at once, Group.Signal sends TERM to every process of it
// in one loop before the leader's trap has run and written its word, so the
// child's TERM is already pending when the test reads it, in any order.
func TestAnEndAsksTheLeaderFirst(t *testing.T) {
	k := boundedKeeper(t)
	leader, group, log := endingGroup(t, k, testPoolFirst, blockingChild("0")+heldLeader(`touch "$L.stop"; wait $child`))
	child := childPID(t, logged(t, log, "child-ready", "leader-ready"))
	ended := ending(k, group, leader)
	logged(t, log, "leader-got-term")
	if termReached(t, log, child) {
		t.Fatal("TERM reached the child while its leader was still ending")
	}
	if err := os.WriteFile(log+".go", nil, 0o666); err != nil {
		t.Fatal(err)
	}
	if !<-ended {
		t.Fatal("the group outlived its end")
	}
	if got := names(logged(t, log, "child-clean", "leader-exits")); strings.Contains(got, "child-asked") {
		t.Fatalf("the child was asked to end, not told by its leader: %q", got)
	}
}

// A leader that exits without telling its child: while the leader holds
// its TERM the child has no TERM pending; once the leader has exited, TERM
// reaches the child, which has the rest of the grace to end. On TERM to
// the whole group at once the child's TERM is pending while the leader is
// held, so the test cannot pass there in any order.
func TestAChildItsLeaderDidNotTellIsAskedAfterIt(t *testing.T) {
	k := boundedKeeper(t)
	leader, group, log := endingGroup(t, k, testPoolFirst, blockingChild("0.3")+heldLeader(`:`))
	child := childPID(t, logged(t, log, "child-ready", "leader-ready"))
	ended := ending(k, group, leader)
	logged(t, log, "leader-got-term")
	if termReached(t, log, child) {
		t.Fatal("TERM reached the child before its leader exited")
	}
	if err := os.WriteFile(log+".go", nil, 0o666); err != nil {
		t.Fatal(err)
	}
	if !<-ended {
		t.Fatal("the group outlived its end")
	}
	if got := names(logged(t, log, "leader-exits", "child-asked", "child-ended")); !strings.HasSuffix(got, "child-asked child-ended") {
		t.Fatalf("the child was not asked after its leader, or had no time to end: %q", got)
	}
}

// A leader that ignores TERM is killed with its group at the grace's end:
// the group is empty when the end returns, and it did not return before
// the grace's end. KillBy waits until the deadline and no longer, and
// sends its kill within one 20 ms poll of it; the ceiling here is loose,
// so as not to fail under load.
func TestALeaderThatIgnoresTheEndIsKilledAtTheGracesEnd(t *testing.T) {
	k := boundedKeeper(t)
	leader, group, log := endingGroup(t, k, testPoolFirst,
		`perl -e '$SIG{TERM} = "IGNORE"; open my $f, ">>", $ARGV[0]; print $f "child-ready\n"; close $f; sleep 600' "$L" &
		 trap '' TERM
		 echo leader-ready >> "$L"
		 while :; do sleep 0.05; done`)
	logged(t, log, "child-ready", "leader-ready")
	started := time.Now()
	if !k.s.endInOrder("t", group, leader, started.Add(endGrace)) {
		t.Fatal("the group outlived its end")
	}
	if took := time.Since(started); took < endGrace || took > endGrace+time.Second {
		t.Fatalf("the group was killed after %s, not at its grace's end, %s", took, endGrace)
	}
	if pids, err := group.Procs(); err != nil || len(pids) != 0 {
		t.Fatalf("the group holds %v after its end (%v)", pids, err)
	}
	k.awaitExit(t, leader)
}

// Two sessions of one kept home, a slow closer released first and a fast
// one second: the fast one's end does not cut the slow one's short, since
// the uid's full retirement, which kills every process of it, runs only
// once no session of it is still ending. When the last release ran it at
// once, it killed the slow one's child while it was still closing.
func TestTwoSessionsOfOneHomeEachEndInTheirOwnTime(t *testing.T) {
	k := keptKeeper(t)
	uid := testKeptFirst
	home := filepath.Join(k.s.cfg.Kept.Root, "vlt_end-order")
	if made := k.homeRequest(t, protocol.TypeHomeMake, "m", home, uid); made["type"] != protocol.TypeHomeMade {
		t.Fatalf("home_make: %v", made)
	}
	log := filepath.Join(home, "log")
	slow, _ := k.spawnKept(t, "slow", `L="$HOME/log"; `+blockingChild("1")+` &
		 child=$!
		 trap 'touch "$L.stop"; wait $child; echo leader-exits >> "$L"; exit 0' TERM
		 echo leader-ready >> "$L"
		 while :; do sleep 0.05; done`, home, uid)
	fast, _ := k.spawnKept(t, "fast", `echo fast-ready >> "$HOME/log"; while :; do sleep 0.05; done`, home, uid)
	logged(t, log, "child-ready", "leader-ready", "fast-ready")

	grace := endGrace.Milliseconds()
	for _, spawnID := range []string{slow, fast} {
		k.s.handleRelease(&protocol.Request{V: protocol.Version, Type: protocol.TypeRelease, SpawnID: spawnID, GraceMs: &grace})
	}
	released := map[string]bool{}
	for len(released) < 2 {
		if m := k.reply(t); m["type"] == protocol.TypeReleased {
			released[fmt.Sprint(m["spawn_id"])] = true
		}
	}
	if got := names(logged(t, log, "child-clean", "leader-exits")); strings.Contains(got, "child-asked") {
		t.Fatalf("the slow session's child was asked to end by the other's end: %q", got)
	}
	if retired := k.homeRequest(t, protocol.TypeHomeRetire, "r", home, uid); retired["type"] != protocol.TypeHomeRetired {
		t.Fatalf("home_retire: %v", retired)
	}
}

// The release of a home's only session marks its uid retiring at once: while
// that session is still ending, a home_make of the home is refused and a
// spawn of it waits for the uid's retirement, as for any retiring uid, and
// another home is unaffected. A newcomer is never admitted beside a uid
// whose last session is ending.
func TestANewcomerWaitsForTheLastSessionsEnd(t *testing.T) {
	k := keptKeeper(t)
	uid := testKeptFirst
	home := filepath.Join(k.s.cfg.Kept.Root, "vlt_newcomer")
	other := filepath.Join(k.s.cfg.Kept.Root, "vlt_newcomer-other")
	if made := k.homeRequest(t, protocol.TypeHomeMake, "m", home, uid); made["type"] != protocol.TypeHomeMade {
		t.Fatalf("home_make: %v", made)
	}
	log := filepath.Join(home, "log")
	only, _ := k.spawnKept(t, "only", `L="$HOME/log"; sleep 600`+heldLeader(`:`), home, uid)
	logged(t, log, "leader-ready")
	grace := endGrace.Milliseconds()
	k.s.handleRelease(&protocol.Request{V: protocol.Version, Type: protocol.TypeRelease, SpawnID: only, GraceMs: &grace})
	logged(t, log, "leader-got-term")

	if busy := k.homeRequest(t, protocol.TypeHomeMake, "m2", home, uid); busy["code"] != protocol.CodeUIDBusy {
		t.Fatalf("home_make of the home while its last session ends: %v", busy)
	}
	k.s.mu.Lock()
	retiring, busy := k.s.keptState(uid, home)
	k.s.mu.Unlock()
	if retiring == nil || busy {
		t.Fatalf("a spawn of the home while its last session ends would not wait for its retirement: %v %v", retiring, busy)
	}
	if made := k.homeRequest(t, protocol.TypeHomeMake, "m3", other, uid+1); made["type"] != protocol.TypeHomeMade {
		t.Fatalf("home_make of another home: %v", made)
	}

	go k.s.handleSpawn(keptRequest(t, k.attach, "newcomer", `echo newcomer-started >> "$HOME/log"; sleep 600`, home, uid, nil))
	if err := os.WriteFile(log+".go", nil, 0o666); err != nil {
		t.Fatal(err)
	}
	var newcomer string
	for newcomer == "" {
		m := k.reply(t)
		if m["type"] == protocol.TypeError {
			t.Fatalf("the newcomer was refused: %v", m)
		}
		if m["type"] == protocol.TypeSpawned {
			newcomer = m["spawn_id"].(string)
		}
	}
	k.accept(t)
	if got := names(logged(t, log, "leader-exits", "newcomer-started")); !strings.HasSuffix(got, "leader-exits newcomer-started") {
		t.Fatalf("the newcomer started before the last session ended: %q", got)
	}
	zero := int64(0)
	k.s.handleRelease(&protocol.Request{V: protocol.Version, Type: protocol.TypeRelease, SpawnID: newcomer, GraceMs: &zero})
}

// marker is a second child of the leader, started once the program's child
// runs, that writes "marker-got-term" when TERM reaches it and ends. Cgroup
// v2 lists a group's processes in the order they joined it, a fork adding
// the child at the end of its css_set's task list, so the marker, forked
// last, comes after the program and the program's child in cgroup.procs, and
// any pass that signals the group by that list has signalled both before
// it: its word proves such a pass is over.
const marker = `while ! grep -q child-ready "$L"; do sleep 0.01; done
		 perl -e '$SIG{TERM} = sub { open my $f, ">>", $ARGV[0]; print $f "marker-got-term\n"; close $f; exit 0 };
		          open my $f, ">>", $ARGV[0]; print $f "marker-ready\n"; close $f; sleep 1 while 1' "$L" &`

// A shell-like leader, as the backends service's /bin/sh -c in front of a
// program is, that exits at once on TERM, around a program that ends its
// own child when asked: once the leader has exited the program alone is
// asked, and its child has no TERM pending while the program holds its
// TERM, read once the marker, the leader's other child, has had its TERM;
// the child ends as the program told it. On TERM to the rest of the group
// at once after the leader, however that pass is paused between the program
// and its child, the marker's TERM comes after the child's, so the child's
// is pending when the test reads it.
func TestTheProgramTheLeaderStartedIsAskedBeforeItsOwnChildren(t *testing.T) {
	k := boundedKeeper(t)
	program := filepath.Join(t.TempDir(), "program.sh")
	if err := os.WriteFile(program, []byte(`L="$1"; `+blockingChild("0")+` &
		 child=$!
		 trap 'echo program-got-term >> "$L"; while [ ! -e "$L.go" ]; do sleep 0.01; done; touch "$L.stop"; wait $child; echo program-exits >> "$L"; exit 0' TERM
		 echo program-ready >> "$L"
		 while :; do sleep 0.05; done
`), 0o644); err != nil {
		t.Fatal(err)
	}
	leader, group, log := endingGroup(t, k, testPoolFirst, `sh `+program+` "$L" &
		 `+marker+`
		 trap 'echo leader-exits >> "$L"; exit 0' TERM
		 while ! grep -q marker-ready "$L"; do sleep 0.01; done
		 echo leader-ready >> "$L"
		 while :; do sleep 0.05; done`)
	child := childPID(t, logged(t, log, "child-ready", "program-ready", "marker-ready", "leader-ready"))
	ended := ending(k, group, leader)
	logged(t, log, "leader-exits", "program-got-term", "marker-got-term")
	if termReached(t, log, child) {
		t.Fatal("TERM reached the program's child while the program was still ending")
	}
	if err := os.WriteFile(log+".go", nil, 0o666); err != nil {
		t.Fatal(err)
	}
	if !<-ended {
		t.Fatal("the group outlived its end")
	}
	if got := names(logged(t, log, "child-clean", "program-exits")); strings.Contains(got, "child-asked") {
		t.Fatalf("the program's child was asked to end, not told by the program: %q", got)
	}
}

// A program its shell-like leader started that ignores TERM is killed with
// its group at the grace's end: the wait for the leader's children ends at
// the one deadline, the group is empty when the end returns, and it did not
// return before the grace's end. The ceiling here is loose, so as not to
// fail under load.
func TestAProgramThatIgnoresTheEndIsKilledAtTheGracesEnd(t *testing.T) {
	k := boundedKeeper(t)
	leader, group, log := endingGroup(t, k, testPoolFirst,
		`perl -e '$SIG{TERM} = "IGNORE"; open my $f, ">>", $ARGV[0]; print $f "program-ready\n"; close $f; sleep 600' "$L" &
		 trap 'exit 0' TERM
		 echo leader-ready >> "$L"
		 while :; do sleep 0.05; done`)
	logged(t, log, "program-ready", "leader-ready")
	started := time.Now()
	if !k.s.endInOrder("t", group, leader, started.Add(endGrace)) {
		t.Fatal("the group outlived its end")
	}
	if took := time.Since(started); took < endGrace || took > endGrace+time.Second {
		t.Fatalf("the group was killed after %s, not at its grace's end, %s", took, endGrace)
	}
	if pids, err := group.Procs(); err != nil || len(pids) != 0 {
		t.Fatalf("the group holds %v after its end (%v)", pids, err)
	}
	k.awaitExit(t, leader)
}

// withStranger is a group that also lists a process no leader of it
// started, as a pid of the leader's child reused by another process before
// the end took it would be listed.
type withStranger struct {
	*cgroup.Group
	stranger int
}

func (g withStranger) Procs() ([]int, error) {
	pids, err := g.Group.Procs()
	return append(pids, g.stranger), err
}

// A pid the leader's child no longer holds is never signalled. A pid the
// group lists that is not the leader's child when its pidfd is taken, as a
// child's pid another process took would be, is not held, and gets no TERM
// from the end: here a stranger outside the group that blocks TERM, whose
// pending signals the kernel shows. And a held pidfd names its child alone:
// once the child has exited and been reaped, a signal through it reaches
// no process, whichever takes the pid next.
func TestAPidTheLeadersChildNoLongerHoldsIsNeverSignalled(t *testing.T) {
	k := boundedKeeper(t)
	strangerLog := filepath.Join(t.TempDir(), "stranger")
	if err := os.WriteFile(strangerLog, nil, 0o666); err != nil {
		t.Fatal(err)
	}
	stranger, err := k.s.start("/usr/bin/perl", []string{"perl", "-MPOSIX", "-e",
		`POSIX::sigprocmask(POSIX::SIG_BLOCK(), POSIX::SigSet->new(POSIX::SIGTERM())) or die;
		 open my $f, ">>", $ARGV[0] or die; print $f "stranger-ready\n"; close $f; sleep 600`, strangerLog},
		nil, []uintptr{0, 2, 2}, 0, 0, "/")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		k.s.signalChild(stranger, syscall.SIGKILL)
		<-stranger.done
	})
	logged(t, strangerLog, "stranger-ready")
	leader, group, log := endingGroup(t, k, testPoolFirst, `sleep 600 &
		 trap 'exit 0' TERM
		 echo leader-ready >> "$L"
		 while :; do sleep 0.05; done`)
	logged(t, log, "leader-ready")
	if !k.s.endInOrder("t", withStranger{group, stranger.pid}, leader, time.Now().Add(endGrace)) {
		t.Fatal("the group outlived its end")
	}
	if termReached(t, strangerLog, stranger.pid) {
		t.Fatal("the end sent TERM to a pid the group listed that was not the leader's child")
	}

	leader, group, log = endingGroup(t, k, testPoolFirst, `sleep 600 &
		 echo leader-ready >> "$L"
		 while :; do wait; sleep 0.05; done`)
	logged(t, log, "leader-ready")
	held, unheld := k.s.leaderChildren(group, leader, time.Now().Add(endGrace))
	if len(held) != 1 || unheld != 0 {
		t.Fatalf("the leader's one child is held by %d pidfds, %d not held", len(held), unheld)
	}
	defer releaseHeld(held)
	if err := unix.PidfdSendSignal(held[0], unix.SIGKILL, nil, 0); err != nil {
		t.Fatal(err)
	}
	// Its leader reaps it in its wait; a signal to a process not yet reaped
	// still succeeds, so the condition is the reaping.
	for deadline := time.Now().Add(20 * time.Second); unix.PidfdSendSignal(held[0], 0, nil, 0) == nil; time.Sleep(10 * time.Millisecond) {
		if time.Now().After(deadline) {
			t.Fatal("the leader's child was never reaped")
		}
	}
	if err := unix.PidfdSendSignal(held[0], unix.SIGTERM, nil, 0); !errors.Is(err, unix.ESRCH) {
		t.Fatalf("a signal through the pidfd of a child reaped answered %v, not ESRCH", err)
	}
	k.s.signalChild(leader, syscall.SIGKILL)
	k.awaitExit(t, leader)
}

// heldScan is a group whose listing waits for the test's word, as a scan
// slowed past its deadline would, and whose kill only records that it ran,
// so what the end sent before it can be read after it.
type heldScan struct {
	*cgroup.Group
	entered, resume chan struct{}
	killed          chan struct{}
}

func (g heldScan) Procs() ([]int, error) {
	close(g.entered)
	<-g.resume
	return g.Group.Procs()
}

func (g heldScan) KillBy(time.Time) bool {
	close(g.killed)
	return true
}

// A scan of the leader's children never holds the keeper's lock: while it
// waits, another spawn's release is served. And a scan that ends past the
// deadline keeps nothing and sends no TERM: neither the leader nor its
// child, which blocks TERM so the kernel shows one pending, is asked before
// the group's kill. On a scan under the keeper's lock the release waits for
// it, and the test fails there.
func TestAScanNeverHoldsTheLockNorSignalsPastTheDeadline(t *testing.T) {
	k := keptKeeper(t)
	uid := testKeptFirst
	home := filepath.Join(k.s.cfg.Kept.Root, "vlt_end-scan")
	if made := k.homeRequest(t, protocol.TypeHomeMake, "m", home, uid); made["type"] != protocol.TypeHomeMade {
		t.Fatalf("home_make: %v", made)
	}
	other, _ := k.spawnKept(t, "other", `echo other-ready >> "$HOME/log"; while :; do sleep 0.05; done`, home, uid)
	logged(t, filepath.Join(home, "log"), "other-ready")

	// The leader blocks TERM too, so a TERM sent to it stays pending.
	leader, group, log := endingGroup(t, k, testPoolFirst, blockingChild("0")+` &
		 exec perl -MPOSIX -e 'POSIX::sigprocmask(POSIX::SIG_BLOCK(), POSIX::SigSet->new(POSIX::SIGTERM())) or die;
		                       open my $f, ">>", $ARGV[0] or die; print $f "leader-ready\n"; close $f; sleep 600' "$L"`)
	child := childPID(t, logged(t, log, "child-ready", "leader-ready"))
	scan := heldScan{Group: group, entered: make(chan struct{}), resume: make(chan struct{}), killed: make(chan struct{})}
	var resumed sync.Once
	t.Cleanup(func() { resumed.Do(func() { close(scan.resume) }) })
	deadline := time.Now().Add(endGrace)
	ended := make(chan bool, 1)
	go func() { ended <- k.s.endInOrder("t", scan, leader, deadline) }()
	<-scan.entered

	released := make(chan map[string]any, 1)
	go func() {
		for {
			if m := k.reply(t); m["type"] != protocol.TypeExited {
				released <- m
				return
			}
		}
	}()
	zero := int64(0)
	go k.s.handleRelease(&protocol.Request{V: protocol.Version, Type: protocol.TypeRelease, SpawnID: other, GraceMs: &zero})
	select {
	case m := <-released:
		if m["type"] != protocol.TypeReleased {
			t.Fatalf("the other spawn's release answered %v", m)
		}
	case <-time.After(20 * time.Second):
		t.Fatal("another spawn's release was not served while the scan ran")
	}

	// The deadline is what this test is about: the scan is let go once it has passed.
	for time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond) // sleep-ok: waiting for the end's own deadline to pass
	}
	resumed.Do(func() { close(scan.resume) })
	<-scan.killed
	if !<-ended {
		t.Fatal("the end reported its group not empty")
	}
	if termReached(t, log, leader.pid) {
		t.Fatal("TERM reached the leader past the deadline")
	}
	if termReached(t, log, child) {
		t.Fatal("TERM reached the leader's child past the deadline")
	}
}

// A wait for the leader's children that cannot poll still waits for their
// exit: with every poll failing, the program's child has no TERM pending
// while the program holds its TERM, the wait asking the program's pidfd
// whether it is still there (the probe's first question is the test's event
// that the wait went on), and the group's kill comes only after the program
// has exited. On a wait that ended at the poll's failure, the group's kill
// comes first, while the program is held.
func TestAWaitThatCannotPollStillWaitsForTheChildsExit(t *testing.T) {
	failed := make(chan struct{})
	var once sync.Once
	poll = func([]unix.PollFd, int) (int, error) {
		once.Do(func() { close(failed) })
		return -1, unix.EINVAL
	}
	probing := make(chan struct{})
	var probed sync.Once
	probe = func(fd int) bool {
		probed.Do(func() { close(probing) })
		return unix.PidfdSendSignal(fd, 0, nil, 0) == nil
	}
	t.Cleanup(func() {
		poll = unix.Poll
		probe = func(fd int) bool { return unix.PidfdSendSignal(fd, 0, nil, 0) == nil }
	})
	k := boundedKeeper(t)
	program := filepath.Join(t.TempDir(), "program.sh")
	if err := os.WriteFile(program, []byte(`L="$1"; `+blockingChild("0")+` &
		 child=$!
		 trap 'echo program-got-term >> "$L"; while [ ! -e "$L.go" ]; do sleep 0.01; done; touch "$L.stop"; wait $child; echo program-exits >> "$L"; exit 0' TERM
		 echo program-ready >> "$L"
		 while :; do sleep 0.05; done
`), 0o644); err != nil {
		t.Fatal(err)
	}
	leader, group, log := endingGroup(t, k, testPoolFirst, `sh `+program+` "$L" &
		 trap 'exit 0' TERM
		 echo leader-ready >> "$L"
		 while :; do sleep 0.05; done`)
	child := childPID(t, logged(t, log, "child-ready", "program-ready", "leader-ready"))
	killed := make(chan struct{})
	ended := make(chan bool, 1)
	go func() { ended <- k.s.endInOrder("t", killRecorded{group, killed}, leader, time.Now().Add(endGrace)) }()
	logged(t, log, "program-got-term")
	<-failed
	select {
	case <-probing:
	case <-killed:
		t.Fatal("the group's kill came at the poll's failure, while the program was still ending")
	}
	if termReached(t, log, child) {
		t.Fatal("TERM reached the program's child while the program was still ending")
	}
	if err := os.WriteFile(log+".go", nil, 0o666); err != nil {
		t.Fatal(err)
	}
	if !<-ended {
		t.Fatal("the group outlived its end")
	}
	if got := names(logged(t, log, "child-clean", "program-exits")); strings.Contains(got, "child-asked") {
		t.Fatalf("the program's child was asked to end, not told by the program: %q", got)
	}
}

// killRecorded is a group whose kill says when it begins.
type killRecorded struct {
	*cgroup.Group
	killed chan struct{}
}

func (g killRecorded) KillBy(deadline time.Time) bool {
	close(g.killed)
	return g.Group.KillBy(deadline)
}
