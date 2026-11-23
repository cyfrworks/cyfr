// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package serve

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"golang.org/x/sys/unix"

	"github.com/cyfr/locus/keeper/internal/frame"
	"github.com/cyfr/locus/keeper/internal/protocol"
)

// counted is the byte at offset p of what fill writes: consecutive 8-byte
// little-endian counters, so a byte lost, repeated or moved changes every
// byte after it.
func counted(p int) byte { return byte(uint64(p/8) >> (8 * (p % 8))) }

// fill writes counted bytes to its stdout without blocking until the
// stdout has stayed full for half a second, so the pipe, the relay and the
// socket to the reader hold all they can, then prints on stderr how many
// bytes it wrote and exits 0.
func fill() int {
	// The pipe is grown, where its owner's pipe pages allow it, to the most
	// an unprivileged writer may make it, so more is left behind the socket
	// than the socket holds; what is checked holds at any size.
	_, _ = unix.FcntlInt(1, unix.F_SETPIPE_SZ, 1<<20)
	if err := unix.SetNonblock(1, true); err != nil {
		return 1
	}
	buf := make([]byte, 64<<10)
	written := 0
	var fullSince time.Time
	for {
		for i := range buf {
			buf[i] = counted(written + i)
		}
		n, err := unix.Write(1, buf)
		if n > 0 {
			written += n
			fullSince = time.Time{}
			continue
		}
		if !errors.Is(err, unix.EAGAIN) {
			return 1
		}
		if fullSince.IsZero() {
			fullSince = time.Now()
		}
		if time.Since(fullSince) > 500*time.Millisecond {
			fmt.Fprintf(os.Stderr, "wrote %d\n", written)
			return 0
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// start starts a spawn of `/bin/sh -c script` and answers its spawn id
// and its relay.
type start func(id, script string) (string, *relayConn)

// eachSpawn runs check on a keeper of its own for a pooled spawn and for a
// kept one, whose retirements end their relays apart.
func eachSpawn(t *testing.T, check func(t *testing.T, k *keeper, spawn start)) {
	t.Run("pooled", func(t *testing.T) {
		k := boundedKeeper(t)
		check(t, k, func(id, script string) (string, *relayConn) {
			spawnID, _, rc := k.spawn(t, id, script, map[string]string{}, false)
			return spawnID, rc
		})
	})
	t.Run("kept", func(t *testing.T) {
		k := keptKeeper(t)
		path := filepath.Join(k.s.cfg.Kept.Root, "vlt_relay")
		if made := k.homeRequest(t, protocol.TypeHomeMake, "m1", path, testKeptFirst); made["type"] != protocol.TypeHomeMade {
			t.Fatalf("home_make: %v", made)
		}
		check(t, k, func(id, script string) (string, *relayConn) {
			return k.spawnKept(t, id, script, path, testKeptFirst)
		})
	})
}

// nextReply reads the keeper's next line in the background and answers it
// on the channel it returns, as nil when the line does not parse.
func (k *keeper) nextReply() <-chan map[string]any {
	next := make(chan map[string]any, 1)
	go func() {
		var m map[string]any
		if line, tooLong, err := k.channel.Next(); err == nil && !tooLong {
			_ = json.Unmarshal(line, &m)
		}
		next <- m
	}()
	return next
}

// within answers what next answers, failing when nothing comes within d.
func within(t *testing.T, next <-chan map[string]any, d time.Duration, what string) map[string]any {
	t.Helper()
	select {
	case m := <-next:
		return m
	case <-time.After(d):
		t.Fatalf("no %s within %v", what, d)
		return nil
	}
}

// queued is how many bytes wait in conn's receive queue: delivered to the
// reader's socket and not yet read.
func queued(t *testing.T, conn net.Conn) int {
	t.Helper()
	raw, err := conn.(syscall.Conn).SyscallConn()
	if err != nil {
		t.Fatal(err)
	}
	var n int
	var ierr error
	if err := raw.Control(func(fd uintptr) { n, ierr = unix.IoctlGetInt(int(fd), unix.SIOCINQ) }); err != nil {
		t.Fatal(err)
	}
	if ierr != nil {
		t.Fatal(ierr)
	}
	return n
}

// slowReader reads at most 16 KiB at a time, 5 ms apart, as a reader
// slower than its writer does, and counts what it took.
type slowReader struct {
	conn  net.Conn
	taken int
}

func (r *slowReader) Read(p []byte) (int, error) {
	time.Sleep(5 * time.Millisecond)
	n, err := r.conn.Read(p[:min(len(p), 16<<10)])
	r.taken += n
	return n, err
}

// A reader slower than its spawn takes every byte the spawn wrote, however
// long after the leader's exit it reads them, and the end of each stream;
// `released` comes only once the relay has handed the reader's socket its
// last byte.
func TestASlowReaderTakesEveryByteAfterItsLeaderExits(t *testing.T) {
	eachSpawn(t, func(t *testing.T, k *keeper, spawn start) {
		spawnID, rc := spawn("slow", "exec "+k.s.self+" fill")
		if exited := within(t, k.nextReply(), 20*time.Second, "exit"); exited["type"] != protocol.TypeExited || exited["spawn_id"] != spawnID || exited["code"] != float64(0) {
			t.Fatalf("the writer's exit: %v", exited)
		}
		released := k.nextReply()
		// The reader takes nothing for a while after the leader's exit: the
		// time that passes cuts nothing.
		time.Sleep(1500 * time.Millisecond)
		_ = rc.conn.SetDeadline(time.Now().Add(60 * time.Second))
		atStart := queued(t, rc.conn)

		r := &slowReader{conn: rc.conn}
		var stdout, stderr []byte
		ended := map[byte]bool{}
		// releasedAt is how much of the connection the reader had taken or
		// held in its socket when `released` came.
		releasedAt := -1
		for {
			stream, payload, err := frame.Read(r, rc.buf)
			if errors.Is(err, io.EOF) {
				break
			}
			if err != nil {
				t.Fatalf("reading the relay after %d bytes: %v", r.taken, err)
			}
			switch {
			case len(payload) == 0:
				ended[stream] = true
			case stream == frame.StreamStdout:
				stdout = append(stdout, payload...)
			case stream == frame.StreamStderr:
				stderr = append(stderr, payload...)
			default:
				t.Fatalf("a frame on stream %d", stream)
			}
			if releasedAt < 0 {
				select {
				case m := <-released:
					if m["type"] != protocol.TypeReleased || m["spawn_id"] != spawnID {
						t.Fatalf("after the exit: %v", m)
					}
					releasedAt = r.taken + queued(t, rc.conn)
				default:
				}
			}
		}
		if !ended[frame.StreamStdout] || !ended[frame.StreamStderr] {
			t.Fatalf("the relay's connection ended before its streams did: stdout ended %t, stderr ended %t, after %d bytes of stdout and stderr %q",
				ended[frame.StreamStdout], ended[frame.StreamStderr], len(stdout), stderr)
		}
		wrote, err := strconv.Atoi(strings.TrimSuffix(strings.TrimPrefix(string(stderr), "wrote "), "\n"))
		if err != nil {
			t.Fatalf("stderr %q", stderr)
		}
		if len(stdout) != wrote {
			t.Fatalf("the spawn wrote %d bytes and the reader took %d", wrote, len(stdout))
		}
		for p, b := range stdout {
			if b != counted(p) {
				t.Fatalf("byte %d of %d is %#x, not %#x", p, wrote, b, counted(p))
			}
		}
		if atStart >= r.taken {
			t.Fatalf("every byte was already in the reader's socket when it began to read (%d of %d): nothing waited on the reader", atStart, r.taken)
		}
		if releasedAt < 0 {
			m := within(t, released, 10*time.Second, "`released` after the relay's end")
			if m["type"] != protocol.TypeReleased || m["spawn_id"] != spawnID {
				t.Fatalf("after the exit: %v", m)
			}
			releasedAt = r.taken
		}
		if releasedAt < r.taken {
			t.Fatalf("`released` came with %d of the connection's %d bytes taken or in the reader's socket: the relay still held some", releasedAt, r.taken)
		}
		t.Logf("%d bytes written; %d in the reader's socket when it began; %d of the connection's bytes taken", wrote, atStart, r.taken)
	})
}

// A reader that closes its connection cuts the relay, as one that dies does
// by dying, and its spawn's retirement goes on without it: with the leader
// still running, a release ends it; with the leader exited, the close
// alone lets the retirement finish. Until the reader closes, a relay with
// bytes for it holds the retirement, whatever time passes.
func TestAReaderThatClosesItsConnectionCutsTheRelay(t *testing.T) {
	t.Run("leader running", func(t *testing.T) {
		eachSpawn(t, func(t *testing.T, k *keeper, spawn start) {
			// The leader outlives its stdout's reader: a failed write
			// leaves it running.
			spawnID, rc := spawn("cut", `trap '' PIPE; while :; do cat /dev/zero; sleep 1; done`)
			rc.readUntil(t, func() bool { return len(rc.got[frame.StreamStdout]) > 0 })
			rc.conn.Close()
			k.release(t, spawnID)
			asked := time.Now()
			if exited := within(t, k.nextReply(), 10*time.Second, "exit after the release"); exited["type"] != protocol.TypeExited || exited["spawn_id"] != spawnID {
				t.Fatalf("after the release: %v", exited)
			}
			if m := within(t, k.nextReply(), 10*time.Second, "`released` after the reader closed"); m["type"] != protocol.TypeReleased || m["spawn_id"] != spawnID {
				t.Fatalf("after the exit: %v", m)
			}
			t.Logf("released %v after the release", time.Since(asked))
		})
	})
	t.Run("leader exited", func(t *testing.T) {
		eachSpawn(t, func(t *testing.T, k *keeper, spawn start) {
			spawnID, rc := spawn("cut", "exec "+k.s.self+" fill")
			if exited := within(t, k.nextReply(), 20*time.Second, "exit"); exited["type"] != protocol.TypeExited || exited["spawn_id"] != spawnID || exited["code"] != float64(0) {
				t.Fatalf("the writer's exit: %v", exited)
			}
			released := k.nextReply()
			select {
			case m := <-released:
				t.Fatalf("%v came while the reader held its connection open and the relay held bytes for it", m)
			case <-time.After(1500 * time.Millisecond):
			}
			rc.readUntil(t, func() bool { return len(rc.got[frame.StreamStdout]) > 0 })
			rc.conn.Close()
			closed := time.Now()
			if m := within(t, released, 10*time.Second, "`released` after the reader closed"); m["type"] != protocol.TypeReleased || m["spawn_id"] != spawnID {
				t.Fatalf("after the exit: %v", m)
			}
			t.Logf("released %v after the reader closed", time.Since(closed))
		})
	})
}
