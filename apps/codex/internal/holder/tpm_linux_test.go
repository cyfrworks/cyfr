// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package holder

import (
	"bytes"
	"crypto/ed25519"
	"encoding/binary"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/google/go-tpm/tpm2"
	"github.com/google/go-tpm/tpm2/transport"
	"github.com/google/go-tpm/tpm2/transport/linuxudstpm"
)

func init() {
	// No test opens the host's own chip: provisioning it would set its
	// lockout authorization to bytes nobody keeps. Chip tests point openTPM
	// at a disposable swtpm.
	openTPM = func() (transport.TPMCloser, error) { return nil, errors.New("tests never open the host's TPM") }
}

const (
	testPIN  = "135790"
	wrongPIN = "000000"
)

// swtpm is a disposable software TPM serving one test from its own state
// directory.
type swtpm struct {
	bin, dir string
	env      []string
	cmd      *exec.Cmd
	done     chan struct{} // closed once cmd has exited and been waited for
}

// startSWTPM starts an swtpm on a fresh state directory and points openTPM
// at it until the test ends. CYFR_TEST_SWTPM names an unpacked swtpm binary
// (<root>/usr/bin/swtpm, its libraries under <root>/usr/lib); without it the
// swtpm on PATH runs, and without either the test skips.
func startSWTPM(t *testing.T) *swtpm {
	t.Helper()
	s := &swtpm{bin: os.Getenv("CYFR_TEST_SWTPM"), dir: t.TempDir(), env: os.Environ()}
	if s.bin != "" {
		if _, err := os.Stat(s.bin); err != nil {
			t.Fatalf("CYFR_TEST_SWTPM: %v", err)
		}
		root := filepath.Dir(filepath.Dir(filepath.Dir(s.bin)))
		libs, _ := filepath.Glob(filepath.Join(root, "usr", "lib", "*-linux-gnu"))
		var path []string
		for _, l := range libs {
			path = append(path, l, filepath.Join(l, "swtpm"))
		}
		s.env = append(s.env, "LD_LIBRARY_PATH="+strings.Join(path, ":"))
	} else if p, err := exec.LookPath("swtpm"); err == nil {
		s.bin = p
	} else if os.Getenv("CYFR_TEST_SWTPM_REQUIRED") != "" {
		// CI installs swtpm and sets this, so a lost install fails the
		// job rather than skipping the chip tests unseen.
		t.Fatal("swtpm is not installed, and CYFR_TEST_SWTPM_REQUIRED says the chip tests must run")
	} else {
		t.Skip("swtpm is not installed: the chip holder is unproven here")
	}
	saved := openTPM
	t.Cleanup(func() {
		openTPM = saved
		if s.cmd != nil {
			_ = s.cmd.Process.Kill()
			<-s.done
		}
	})
	openTPM = func() (transport.TPMCloser, error) { return linuxudstpm.Open(s.sock()) }
	s.start(t)
	return s
}

func (s *swtpm) sock() string { return filepath.Join(s.dir, "s") }

func (s *swtpm) log() string {
	b, _ := os.ReadFile(filepath.Join(s.dir, "log"))
	return string(b)
}

// start runs swtpm and waits until its socket accepts a connection.
func (s *swtpm) start(t *testing.T) {
	t.Helper()
	_ = os.Remove(s.sock())
	log, err := os.OpenFile(filepath.Join(s.dir, "log"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	defer log.Close()
	s.cmd = exec.Command(s.bin, "socket", "--tpm2", "--tpmstate", "dir="+s.dir,
		"--server", "type=unixio,path="+s.sock(), "--ctrl", "type=unixio,path="+filepath.Join(s.dir, "c"),
		"--flags", "not-need-init,startup-clear")
	s.cmd.Env, s.cmd.Stdout, s.cmd.Stderr = s.env, log, log
	if err := s.cmd.Start(); err != nil {
		t.Fatal(err)
	}
	done, cmd := make(chan struct{}), s.cmd
	s.done = done
	go func() { _ = cmd.Wait(); close(done) }()
	deadline := time.Now().Add(10 * time.Second)
	for {
		if c, err := net.Dial("unix", s.sock()); err == nil {
			c.Close()
			return
		}
		select {
		case <-done:
			t.Fatalf("swtpm exited before it listened:\n%s", s.log())
		case <-time.After(10 * time.Millisecond):
		}
		if time.Now().After(deadline) {
			t.Fatalf("swtpm did not listen within 10 s:\n%s", s.log())
		}
	}
}

// restart shuts the TPM down in order, as an operating system does before a
// reboot, stops swtpm and starts a new swtpm process on the same state.
func (s *swtpm) restart(t *testing.T) {
	t.Helper()
	withTPM(t, func(tp transport.TPM) {
		if _, err := (tpm2.Shutdown{ShutdownType: tpm2.TPMSUClear}).Execute(tp); err != nil {
			t.Fatalf("TPM2_Shutdown: %v", err)
		}
	})
	// The orderly shutdown has written the chip's state; swtpm under a
	// loaded host may be slow to act on SIGTERM, and the claim is the
	// state's, not the exit's, so a slow one is killed.
	_ = s.cmd.Process.Signal(syscall.SIGTERM)
	select {
	case <-s.done:
	case <-time.After(10 * time.Second):
		_ = s.cmd.Process.Kill()
		select {
		case <-s.done:
		case <-time.After(10 * time.Second):
			t.Fatalf("swtpm did not stop on SIGTERM or SIGKILL:\n%s", s.log())
		}
	}
	s.start(t)
}

// withTPM runs f on a fresh connection to the test's swtpm.
func withTPM(t *testing.T, f func(tp transport.TPM)) {
	t.Helper()
	tp, err := openTPM()
	if err != nil {
		t.Fatal(err)
	}
	defer tp.Close()
	f(tp)
}

func readProperty(t *testing.T, pt tpm2.TPMPT) uint32 {
	t.Helper()
	var v uint32
	withTPM(t, func(tp transport.TPM) {
		var err error
		if v, err = property(tp, pt); err != nil {
			t.Fatal(err)
		}
	})
	return v
}

func newChipRecord(t *testing.T) *Record {
	t.Helper()
	r, err := NewChip([]byte(testPIN))
	if err != nil {
		t.Fatalf("NewChip: %v", err)
	}
	return r
}

func openRight(t *testing.T, r *Record) {
	t.Helper()
	k, err := r.Open([]byte(testPIN))
	if err != nil {
		t.Fatalf("Open(right PIN): %v", err)
	}
	if !bytes.Equal(k.Public(), r.PublicKey) {
		t.Fatalf("opened public key %x, record %x", k.Public(), r.PublicKey)
	}
	if !ed25519.Verify(r.PublicKey, []byte("hello"), k.Sign([]byte("hello"))) {
		t.Fatal("the opened key's signature does not verify against the record's public key")
	}
	k.Erase()
}

func openWrong(t *testing.T, r *Record) {
	t.Helper()
	if k, err := r.Open([]byte(wrongPIN)); !errors.Is(err, ErrWrongSecret) || k != nil {
		t.Fatalf("Open(wrong PIN) = key %t, %v; want ErrWrongSecret", k != nil, err)
	}
}

func TestChipOpen(t *testing.T) {
	startSWTPM(t)
	r := newChipRecord(t)
	if r.Version != 2 || r.Kind != KindChip || r.Software != nil || r.Chip == nil || len(r.PublicKey) != ed25519.PublicKeySize {
		t.Fatalf("record = %+v", r)
	}
	path := filepath.Join(t.TempDir(), "key.json")
	if err := r.Save(path); err != nil {
		t.Fatal(err)
	}
	loaded, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	openRight(t, loaded)
}

func TestChipWrongPIN(t *testing.T) {
	startSWTPM(t)
	r := newChipRecord(t)
	openWrong(t, r)
	if _, err := r.Open([]byte("12345")); !errors.Is(err, ErrSecretShape) {
		t.Fatalf("Open(five digits) = %v; want ErrSecretShape", err)
	}
	if _, err := r.Open([]byte("abandon ability able about above zoo")); !errors.Is(err, ErrSecretShape) {
		t.Fatalf("Open(passphrase) = %v; want ErrSecretShape", err)
	}
	if got := readProperty(t, tpm2.TPMPTLockoutCounter); got != 1 {
		t.Fatalf("lockout counter = %d, want 1: only the wrong PIN reaches the chip", got)
	}
}

func TestChipDictionaryAttackProvisioned(t *testing.T) {
	startSWTPM(t)
	if readProperty(t, tpm2.TPMPTMaxAuthFail) == daMaxTries || readProperty(t, tpm2.TPMPTPermanent)&permanentLockoutAuthSet != 0 {
		t.Fatal("a fresh swtpm already has the holder's policy; this test would prove nothing")
	}
	first := newChipRecord(t)
	for pt, want := range map[tpm2.TPMPT]uint32{
		tpm2.TPMPTMaxAuthFail:     8,
		tpm2.TPMPTLockoutInterval: 600,
		tpm2.TPMPTLockoutRecovery: 86400,
	} {
		if got := readProperty(t, pt); got != want {
			t.Errorf("property %#x = %d, want %d", uint32(pt), got, want)
		}
	}
	if readProperty(t, tpm2.TPMPTPermanent)&permanentLockoutAuthSet == 0 {
		t.Error("lockoutAuthSet is false after NewChip")
	}
	// A replacement record on a chip provisioned before is accepted, with a
	// new key.
	second := newChipRecord(t)
	if bytes.Equal(second.PublicKey, first.PublicKey) || bytes.Equal(second.Chip.Private, first.Chip.Private) {
		t.Fatal("a second record reused the first one's key or blob")
	}
	openRight(t, first)
	openRight(t, second)
}

func TestChipRefusesSomeoneElsesLockout(t *testing.T) {
	startSWTPM(t)
	withTPM(t, func(tp transport.TPM) {
		if err := daParameters(tp, 32, 7200, 86400); err != nil {
			t.Fatal(err)
		}
		if _, err := (tpm2.HierarchyChangeAuth{AuthHandle: tpm2.TPMRHLockout,
			NewAuth: tpm2.TPM2BAuth{Buffer: []byte("someone else's")}}).Execute(tp); err != nil {
			t.Fatal(err)
		}
	})
	r, err := NewChip([]byte(testPIN))
	var refused *ChipRefusedError
	if !errors.As(err, &refused) || !errors.Is(err, ErrNoChip) || r != nil {
		t.Fatalf("NewChip = record %t, %v; want a *ChipRefusedError matching ErrNoChip", r != nil, err)
	}
	if !strings.Contains(refused.Reason, "set by someone else") {
		t.Fatalf("reason = %q", refused.Reason)
	}
	if a, b := readProperty(t, tpm2.TPMPTMaxAuthFail), readProperty(t, tpm2.TPMPTLockoutInterval); a != 32 || b != 7200 {
		t.Fatalf("the refused chip's limits became %d/%d; the holder must change nothing", a, b)
	}
}

func TestChipRefusesOwnerPassword(t *testing.T) {
	startSWTPM(t)
	withTPM(t, func(tp transport.TPM) {
		if _, err := (tpm2.HierarchyChangeAuth{AuthHandle: tpm2.TPMRHOwner,
			NewAuth: tpm2.TPM2BAuth{Buffer: []byte("the owner's")}}).Execute(tp); err != nil {
			t.Fatal(err)
		}
	})
	_, err := NewChip([]byte(testPIN))
	var refused *ChipRefusedError
	if !errors.As(err, &refused) || !errors.Is(err, ErrNoChip) {
		t.Fatalf("NewChip = %v; want a *ChipRefusedError matching ErrNoChip", err)
	}
	if readProperty(t, tpm2.TPMPTPermanent)&permanentLockoutAuthSet != 0 {
		t.Fatal("the holder set the lockout authorization of a chip it refused")
	}
}

func TestChipLocksOutAfterEightWrongPINs(t *testing.T) {
	startSWTPM(t)
	r := newChipRecord(t)
	for range 8 {
		openWrong(t, r)
	}
	if k, err := r.Open([]byte(testPIN)); !errors.Is(err, ErrLockedOut) || k != nil {
		t.Fatalf("Open(right PIN) after eight wrong ones = key %t, %v; want ErrLockedOut", k != nil, err)
	}
	if got := readProperty(t, tpm2.TPMPTLockoutCounter); got != 8 {
		t.Fatalf("lockout counter = %d, want 8", got)
	}
}

func TestChipWrongPINCountSurvivesRestart(t *testing.T) {
	s := startSWTPM(t)
	path := filepath.Join(t.TempDir(), "key.json")
	if err := newChipRecord(t).Save(path); err != nil {
		t.Fatal(err)
	}
	r, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	openWrong(t, r)
	openWrong(t, r)
	// Every Open closed its connection; a fresh one reads the chip's count.
	if got := readProperty(t, tpm2.TPMPTLockoutCounter); got != 2 {
		t.Fatalf("lockout counter on a fresh connection = %d, want 2", got)
	}
	s.restart(t)
	if got := readProperty(t, tpm2.TPMPTLockoutCounter); got != 2 {
		t.Fatalf("lockout counter after the TPM restarted = %d, want 2", got)
	}
	again, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	openRight(t, again)
}

func TestChipOpenAuthorizesEveryTime(t *testing.T) {
	startSWTPM(t)
	r := newChipRecord(t)
	openRight(t, r)
	openRight(t, r)
	openWrong(t, r)
	if got := readProperty(t, tpm2.TPMPTLockoutCounter); got != 1 {
		t.Fatalf("lockout counter = %d, want 1", got)
	}
	openRight(t, r)
	openWrong(t, r)
	if got := readProperty(t, tpm2.TPMPTLockoutCounter); got != 2 {
		t.Fatalf("lockout counter = %d, want 2: a right PIN before must not authorize a wrong one", got)
	}
}

func TestChipClearedLosesKey(t *testing.T) {
	startSWTPM(t)
	r := newChipRecord(t)
	withTPM(t, func(tp transport.TPM) {
		// Test-only: swtpm's platform hierarchy has an empty authorization.
		if _, err := (tpm2.Clear{AuthHandle: tpm2.AuthHandle{Handle: tpm2.TPMRHPlatform,
			Auth: tpm2.PasswordAuth(nil)}}).Execute(tp); err != nil {
			t.Fatalf("TPM2_Clear: %v", err)
		}
	})
	k, err := r.Open([]byte(testPIN))
	if err == nil || k != nil || errors.Is(err, ErrWrongSecret) || errors.Is(err, ErrLockedOut) {
		t.Fatalf("Open after TPM2_Clear = key %t, %v; want the key lost", k != nil, err)
	}
}

func TestChipSealedObjectAttributes(t *testing.T) {
	startSWTPM(t)
	r := newChipRecord(t)
	withTPM(t, func(tp transport.TPM) {
		p, err := createParent(tp)
		if err != nil {
			t.Fatal(err)
		}
		defer flush(tp, p.handle)
		obj, err := load(tp, p, r.Chip)
		if err != nil {
			t.Fatal(err)
		}
		defer flush(tp, obj.ObjectHandle)
		rsp, err := tpm2.ReadPublic{ObjectHandle: obj.ObjectHandle}.Execute(tp)
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(tpm2.Marshal(rsp.OutPublic), r.Chip.Public) {
			t.Fatal("the chip reads back another public area than the record's")
		}
		pub, err := rsp.OutPublic.Contents()
		if err != nil {
			t.Fatal(err)
		}
		// fixedTPM (bit 1) | fixedParent (bit 4) | userWithAuth (bit 6), and
		// nothing else: no sensitiveDataOrigin, noDA, adminWithPolicy, sign
		// or decrypt.
		if got := fmt.Sprintf("%x", tpm2.Marshal(&pub.ObjectAttributes)); got != "00000052" {
			t.Fatalf("sealed object attributes = %s, want 00000052", got)
		}
		scheme, err := pub.Parameters.KeyedHashDetail()
		if err != nil {
			t.Fatal(err)
		}
		if pub.Type != tpm2.TPMAlgKeyedHash || pub.NameAlg != tpm2.TPMAlgSHA256 ||
			len(pub.AuthPolicy.Buffer) != 0 || scheme.Scheme.Scheme != tpm2.TPMAlgNull {
			t.Fatalf("sealed object public area = %+v", pub)
		}
	})
}

func TestNewChipWithoutDevice(t *testing.T) {
	saved := openTPM
	t.Cleanup(func() { openTPM = saved })
	openTPM = func() (transport.TPMCloser, error) {
		t.Error("a malformed PIN reached the chip")
		return nil, errors.New("unreachable")
	}
	if _, err := NewChip([]byte("12345")); !errors.Is(err, ErrSecretShape) {
		t.Fatalf("NewChip(five digits) = %v; want ErrSecretShape", err)
	}
	openTPM = func() (transport.TPMCloser, error) { return nil, fmt.Errorf("open %s: %w", tpmPath, os.ErrNotExist) }
	_, err := NewChip([]byte(testPIN))
	var refused *ChipRefusedError
	if !errors.Is(err, ErrNoChip) || errors.As(err, &refused) {
		t.Fatalf("NewChip without a device = %v; want ErrNoChip and no *ChipRefusedError", err)
	}
}

// recorder keeps every command and response that crosses the bus.
type recorder struct {
	transport.TPMCloser
	bus *[][]byte
}

func (r recorder) Send(cmd []byte) ([]byte, error) {
	rsp, err := r.TPMCloser.Send(cmd)
	*r.bus = append(*r.bus, bytes.Clone(cmd), bytes.Clone(rsp))
	return rsp, err
}

func TestChipSecretsNeverCrossTheBusInClear(t *testing.T) {
	startSWTPM(t)
	var bus [][]byte
	swtpmOpen := openTPM
	openTPM = func() (transport.TPMCloser, error) {
		tp, err := swtpmOpen()
		return recorder{tp, &bus}, err
	}
	r := newChipRecord(t)
	k, err := r.Open([]byte(testPIN))
	if err != nil {
		t.Fatal(err)
	}
	defer k.Erase()
	seed := k.priv.Seed()
	for i, msg := range bus {
		if bytes.Contains(msg, []byte(testPIN)) {
			t.Errorf("bus message %d carries the PIN in clear", i)
		}
		if bytes.Contains(msg, seed) {
			t.Errorf("bus message %d carries the seed in clear", i)
		}
	}
	if len(bus) < 20 {
		t.Fatalf("recorded %d messages; the recorder missed the chip's traffic", len(bus))
	}
}

// liar reports the sealed object with noDA set in every TPM2_ReadPublic
// response, as a chip that does not hold what it created would.
type liar struct{ transport.TPMCloser }

func (l liar) Send(cmd []byte) ([]byte, error) {
	rsp, err := l.TPMCloser.Send(cmd)
	// The response header is 10 bytes, then TPM2B_PUBLIC's size, type and
	// nameAlg; byte 18 holds TPMA_OBJECT bits 8-15, and noDA is bit 10.
	if err == nil && binary.BigEndian.Uint32(cmd[6:10]) == uint32(tpm2.TPMCCReadPublic) && len(rsp) > 19 {
		rsp[18] |= 0x04
	}
	return rsp, err
}

func TestChipRefusesAnObjectReadBackOtherwise(t *testing.T) {
	startSWTPM(t)
	swtpmOpen := openTPM
	openTPM = func() (transport.TPMCloser, error) {
		tp, err := swtpmOpen()
		return liar{tp}, err
	}
	r, err := NewChip([]byte(testPIN))
	var refused *ChipRefusedError
	if !errors.As(err, &refused) || !errors.Is(err, ErrNoChip) || r != nil {
		t.Fatalf("NewChip = record %t, %v; want a *ChipRefusedError matching ErrNoChip", r != nil, err)
	}
}

// An unseal salts its session only to the storage key the seed was sealed
// under: a chip whose storage key has another name (one impersonating the
// chip on the bus) is refused before the PIN is presented, and the
// wrong-PIN counter does not move.
func TestChipRefusesAnotherStorageKey(t *testing.T) {
	startSWTPM(t)
	r := newChipRecord(t)
	r.Chip.Parent = append([]byte(nil), r.Chip.Parent...)
	r.Chip.Parent[len(r.Chip.Parent)-1] ^= 1
	_, err := r.Open([]byte(testPIN))
	var refused *ChipRefusedError
	if !errors.As(err, &refused) {
		t.Fatalf("Open under another storage key = %v; want a *ChipRefusedError", err)
	}
	if got := readProperty(t, tpm2.TPMPTLockoutCounter); got != 0 {
		t.Fatalf("lockout counter = %d after a refused storage key; want 0", got)
	}
}
