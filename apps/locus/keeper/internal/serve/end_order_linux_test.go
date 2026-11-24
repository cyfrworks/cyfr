// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package serve

import (
	"bytes"
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
	"github.com/cyfr/locus/keeper/internal/logx"
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
	go func() { ended <- k.s.endInOrder("t", testPoolFirst, group, leader, time.Now().Add(endGrace)) }()
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
	if !k.s.endInOrder("t", testPoolFirst, group, leader, started.Add(endGrace)) {
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
// that session is still ending, a home_make of the home answers its uid and
// a spawn of it waits for the uid's retirement, as for any retiring uid,
// and another home is made under another uid. A newcomer is never admitted beside a uid
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

	// A made home's make answers its uid, retiring or not.
	if made := k.homeRequest(t, protocol.TypeHomeMake, "m2", home, uid); made["type"] != protocol.TypeHomeMade {
		t.Fatalf("home_make of the home while its last session ends: %v", made)
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

	if placed := k.place(t, "newcomer", protocol.KindProgram); placed["type"] != protocol.TypePlaced {
		t.Fatalf("the newcomer's place answered %v", placed)
	}
	go k.s.handleSpawn(keptRequest(t, k.attach, "newcomer", `echo newcomer-started >> "$HOME/log"; sleep 600`, home, nil))
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

// waitingFor makes the end's wait for the leader's children say when it
// begins: poll is first asked once the pass that sends those children TERM
// is over.
func waitingFor(t *testing.T) chan struct{} {
	t.Helper()
	waiting := make(chan struct{})
	var once sync.Once
	poll = func(fds []unix.PollFd, timeout int) (int, error) {
		once.Do(func() { close(waiting) })
		return unix.Poll(fds, timeout)
	}
	t.Cleanup(func() { poll = unix.Poll })
	return waiting
}

// A shell-like leader, as the backends service's /bin/sh -c in front of a
// program is, that exits at once on TERM, around a program that ends its
// own child when asked: once the leader has exited the program alone is
// asked, and the keeper waits for it with no TERM pending on its child; the
// child ends as the program told it. The test rests on two events and no
// order: the keeper entering its wait for the leader's children, which
// comes only after its pass over them is done, and TERM pending on the
// program's child, read from the kernel. The first, with the child's TERM
// not pending then, passes; the second fails. On TERM to the rest of the
// group at once after the leader, the keeper never waits for the leader's
// children and the child's TERM comes, however that pass is paused.
func TestTheProgramTheLeaderStartedIsAskedBeforeItsOwnChildren(t *testing.T) {
	waiting := waitingFor(t)
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
		 trap 'echo leader-exits >> "$L"; exit 0' TERM
		 echo leader-ready >> "$L"
		 while :; do sleep 0.05; done`)
	child := childPID(t, logged(t, log, "child-ready", "program-ready", "leader-ready"))
	ended := ending(k, group, leader)
	for deadline := time.Now().Add(20 * time.Second); ; time.Sleep(time.Millisecond) {
		select {
		case <-waiting:
		default:
			if termReached(t, log, child) {
				t.Fatal("TERM reached the program's child before the keeper waited for the program")
			}
			if time.Now().After(deadline) {
				t.Fatal("the keeper never waited for the leader's children")
			}
			continue
		}
		break
	}
	if termReached(t, log, child) {
		t.Fatal("TERM reached the program's child while the program was still ending")
	}
	logged(t, log, "leader-exits", "program-got-term")
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
	if !k.s.endInOrder("t", testPoolFirst, group, leader, started.Add(endGrace)) {
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
	if !k.s.endInOrder("t", testPoolFirst, withStranger{group, stranger.pid}, leader, time.Now().Add(endGrace)) {
		t.Fatal("the group outlived its end")
	}
	if termReached(t, strangerLog, stranger.pid) {
		t.Fatal("the end sent TERM to a pid the group listed that was not the leader's child")
	}

	leader, group, log = endingGroup(t, k, testPoolFirst, `sleep 600 &
		 echo leader-ready >> "$L"
		 while :; do wait; sleep 0.05; done`)
	logged(t, log, "leader-ready")
	e := keptEnder(testPoolFirst, group)
	children := k.s.leaderChildren(e, group, leader, time.Now().Add(endGrace))
	if len(children.held) != 1 || children.why != "" {
		t.Fatalf("the leader's one child is held by %d pidfds (%q)", len(children.held), children.why)
	}
	defer e.Release(children.held)
	held := []int{children.held[0].Fd}
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
	go func() { ended <- k.s.endInOrder("t", testPoolFirst, scan, leader, deadline) }()
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

	// The end does not wait for the scan past its deadline: the group's kill
	// comes while the scan is still held, and the scan is let go after it.
	select {
	case <-scan.killed:
	case <-time.After(endGrace + 20*time.Second):
		t.Fatal("the group's kill waited for a scan held past the deadline")
	}
	if time.Now().Before(deadline) {
		t.Fatal("the group's kill came before the deadline")
	}
	if !<-ended {
		t.Fatal("the end reported its group not empty")
	}
	resumed.Do(func() { close(scan.resume) })
	eventually(t, "the held scan's pidfds to be let go", func() bool {
		budget.Lock()
		defer budget.Unlock()
		return budget.total == 0
	})
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
	probe = func(fd int) error {
		probed.Do(func() { close(probing) })
		return unix.PidfdSendSignal(fd, 0, nil, 0)
	}
	t.Cleanup(func() {
		poll = unix.Poll
		probe = func(fd int) error { return unix.PidfdSendSignal(fd, 0, nil, 0) }
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
	go func() {
		ended <- k.s.endInOrder("t", testPoolFirst, killRecorded{group, killed}, leader, time.Now().Add(endGrace))
	}()
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

// eventually waits until done holds, a bounded condition check.
func eventually(t *testing.T, what string, done func() bool) {
	t.Helper()
	for deadline := time.Now().Add(20 * time.Second); !done(); time.Sleep(10 * time.Millisecond) {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
	}
}

// lockedLog is the keeper's log written where a test reads it.
type lockedLog struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (l *lockedLog) Write(p []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.buf.Write(p)
}

// lines are the log's lines that hold text.
func (l *lockedLog) lines(text string) []string {
	l.mu.Lock()
	defer l.mu.Unlock()
	var found []string
	for _, line := range strings.Split(l.buf.String(), "\n") {
		if strings.Contains(line, text) {
			found = append(found, line)
		}
	}
	return found
}

// logTo has the keeper log to a lockedLog.
func logTo(k *keeper) *lockedLog {
	l := &lockedLog{}
	k.s.log = logx.NewWriter(l, "cyfr-locus", false)
	return l
}

// unlisted is a group whose listing fails, and whose kill records that it ran.
type unlisted struct {
	*cgroup.Group
	killed chan struct{}
}

func (g unlisted) Procs() ([]int, error) { return nil, errors.New("cgroup.procs: unreadable") }

func (g unlisted) KillBy(deadline time.Time) bool {
	close(g.killed)
	return g.Group.KillBy(deadline)
}

// reapedInScan is a group whose listing ends only once its leader has been
// killed and reaped, as a leader that ends during the scan is.
type reapedInScan struct {
	*cgroup.Group
	k      *keeper
	leader *child
}

func (g reapedInScan) Procs() ([]int, error) {
	pids, err := g.Group.Procs()
	g.k.s.signalChild(g.leader, syscall.SIGKILL)
	<-g.leader.done
	return pids, err
}

// Every path on which the children's level of a running leader's end is
// skipped or incomplete says so once on the keeper's log for the spawn,
// with why: the group could not be listed; children could not be held
// (here past the bound of one end); the leader was reaped during the scan.
// A leader already reaped as the end begins says nothing.
func TestAnEndThatCannotHoldTheLeadersChildrenSaysSoOnce(t *testing.T) {
	k := boundedKeeper(t)
	log := logTo(k)
	// The leader forks nothing once it runs, so its children are those the
	// test started.
	idle := `exec perl -e '$SIG{TERM} = sub { exit 0 }; open my $f, ">>", $ARGV[0]; print $f "leader-ready\n"; close $f; sleep 1 while 1' "$L"`

	leader, group, file := endingGroup(t, k, testPoolFirst, idle)
	logged(t, file, "leader-ready")
	killed := make(chan struct{})
	k.s.endInOrder("listed", testPoolFirst, unlisted{group, killed}, leader, time.Now().Add(endGrace))
	if got := log.lines("spawn listed:"); len(got) != 1 || !strings.Contains(got[0], "its group could not be listed") {
		t.Fatalf("an end whose group could not be listed logged %q", got)
	}

	many := strings.Repeat("sleep 600 &\n", endHeld+2)
	leader, group, file = endingGroup(t, k, testPoolFirst, many+idle)
	logged(t, file, "leader-ready")
	k.s.endInOrder("many", testPoolFirst, group, leader, time.Now().Add(endGrace))
	if got := log.lines("spawn many:"); len(got) != 1 || !strings.Contains(got[0], "2 of its leader's children could not be held") {
		t.Fatalf("an end that could hold %d of its leader's %d children logged %q", endHeld, endHeld+2, got)
	}

	leader, group, file = endingGroup(t, k, testPoolFirst, `sleep 600 &
		 `+idle)
	logged(t, file, "leader-ready")
	k.s.endInOrder("reaped", testPoolFirst, reapedInScan{group, k, leader}, leader, time.Now().Add(endGrace))
	if got := log.lines("spawn reaped:"); len(got) != 1 || !strings.Contains(got[0], "its leader was reaped during the scan") {
		t.Fatalf("an end whose leader was reaped during its scan logged %q", got)
	}

	leader, group, file = endingGroup(t, k, testPoolFirst, `sleep 600 &
		 `+idle)
	logged(t, file, "leader-ready")
	k.s.signalChild(leader, syscall.SIGKILL)
	<-leader.done
	k.s.endInOrder("gone", testPoolFirst, group, leader, time.Now().Add(endGrace))
	if got := log.lines("spawn gone:"); len(got) != 0 {
		t.Fatalf("an end whose leader was reaped before it began logged %q", got)
	}
}

// A probe that answers anything but ESRCH keeps the wait for the leader's
// children: with every poll failing and every probe answering EPERM, the
// group's kill comes at the deadline, not before, while the program is held.
func TestAProbeErrorThatIsNotTheEndKeepsTheWait(t *testing.T) {
	poll = func([]unix.PollFd, int) (int, error) { return -1, unix.EINVAL }
	probe = func(int) error { return unix.EPERM }
	t.Cleanup(func() {
		poll = unix.Poll
		probe = func(fd int) error { return unix.PidfdSendSignal(fd, 0, nil, 0) }
	})
	k := boundedKeeper(t)
	leader, group, log := endingGroup(t, k, testPoolFirst, `perl -e '$SIG{TERM} = sub { open my $f, ">>", $ARGV[0]; print $f "program-got-term\n"; close $f };
		          open my $f, ">>", $ARGV[0]; print $f "program-ready\n"; close $f; sleep 1 while 1' "$L" &
		 trap 'exit 0' TERM
		 echo leader-ready >> "$L"
		 while :; do sleep 0.05; done`)
	logged(t, log, "program-ready", "leader-ready")
	killed := make(chan struct{})
	deadline := time.Now().Add(endGrace)
	ended := make(chan bool, 1)
	go func() { ended <- k.s.endInOrder("t", testPoolFirst, killRecorded{group, killed}, leader, deadline) }()
	logged(t, log, "program-got-term")
	<-killed
	if time.Now().Before(deadline) {
		t.Fatal("a probe error that was not ESRCH ended the wait before the deadline")
	}
	<-ended
}
