// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package holder

import (
	"bytes"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/cloudflare/circl/oprf"
)

// testHome is a home's evaluator for one device as the tests stand it in:
// circl's OPRF server under a fresh key, counting evaluations.
type testEvaluator struct {
	server oprf.Server
	calls  int
}

func newTestEvaluator(t *testing.T) *testEvaluator {
	t.Helper()
	k, err := oprf.GenerateKey(pinSuite, rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return &testEvaluator{server: oprf.NewServer(pinSuite, k)}
}

func (e *testEvaluator) eval(blinded []byte) ([]byte, error) {
	e.calls++
	el := pinSuite.Group().NewElement()
	if err := el.UnmarshalBinary(blinded); err != nil {
		return nil, err
	}
	got, err := e.server.Evaluate(&oprf.EvaluationRequest{Elements: []oprf.Blinded{el}})
	if err != nil {
		return nil, err
	}
	return got.Elements[0].MarshalBinaryCompress()
}

func hexBytes(t *testing.T, s string) []byte {
	t.Helper()
	b, err := hex.DecodeString(s)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

// TestPINOutputRFC9497Vectors runs RFC 9497's ristretto255-SHA512 OPRF
// (mode 0) vectors through the client the holder uses: the blind given,
// the blinded element the client sends must be the vector's, and the
// vector's evaluated element must finalize to its output.
func TestPINOutputRFC9497Vectors(t *testing.T) {
	for _, v := range rfc9497Vectors(t) {
		var sent []byte
		out, err := oprfRound(oprf.NewClient(pinSuite), v.input, func(blinded []byte) ([]byte, error) {
			sent = slices.Clone(blinded)
			return v.evaluated, nil
		}, v.blind)
		if err != nil {
			t.Fatalf("input %x: %v", v.input, err)
		}
		if !bytes.Equal(sent, v.blinded) {
			t.Fatalf("input %x: blinded %x, want %x", v.input, sent, v.blinded)
		}
		if !bytes.Equal(out, v.output) {
			t.Fatalf("input %x: output %x, want %x", v.input, out, v.output)
		}
	}
}

// TestPINOutputRFC9497Server checks the vectors' evaluated elements are
// what the RFC's key evaluates, so the client and a server under the same
// suite agree on the whole round.
func TestPINOutputRFC9497Server(t *testing.T) {
	for _, v := range rfc9497Vectors(t) {
		k := new(oprf.PrivateKey)
		if err := k.UnmarshalBinary(pinSuite, v.key); err != nil {
			t.Fatal(err)
		}
		s := &testEvaluator{server: oprf.NewServer(pinSuite, k)}
		got, err := s.eval(v.blinded)
		if err != nil || !bytes.Equal(got, v.evaluated) {
			t.Fatalf("evaluated %x (%v), want %x", got, err, v.evaluated)
		}
	}
}

func pinRecord(t *testing.T, e *testEvaluator, pin string) *Record {
	t.Helper()
	rec, pass := softwareRecord(t)
	k, err := rec.Open(pass)
	if err != nil {
		t.Fatal(err)
	}
	defer k.Erase()
	hard, err := rec.HardenPIN(k, "dpe_test", []byte(pin), e.eval)
	if err != nil {
		t.Fatal(err)
	}
	return hard
}

func TestPINRoundTrip(t *testing.T) {
	e := newTestEvaluator(t)
	rec := pinRecord(t, e, "123456")
	if rec.Software != nil || rec.PIN == nil || rec.Kind != KindSoftware || !rec.Hardened() {
		t.Fatalf("a hardened record keeps Software %v, PIN %v, kind %s", rec.Software, rec.PIN, rec.Kind)
	}
	e.calls = 0
	k, err := rec.OpenPIN([]byte("123456"), e.eval)
	if err != nil {
		t.Fatal(err)
	}
	defer k.Erase()
	if !bytes.Equal(k.Public(), rec.PublicKey) || e.calls != 1 {
		t.Fatalf("opened %x after %d evaluations; want the record's key after one", k.Public(), e.calls)
	}
}

// TestPINWrongPINChargedOnce: a wrong PIN is one evaluation at the home,
// then ErrWrongSecret; the holder never asks again by itself.
func TestPINWrongPINChargedOnce(t *testing.T) {
	e := newTestEvaluator(t)
	rec := pinRecord(t, e, "123456")
	e.calls = 0
	if _, err := rec.OpenPIN([]byte("123457"), e.eval); !errors.Is(err, ErrWrongSecret) {
		t.Fatalf("wrong PIN: %v, want ErrWrongSecret", err)
	}
	if e.calls != 1 {
		t.Fatalf("a wrong PIN made %d evaluations, want 1", e.calls)
	}
}

// TestPINNeedsTheHomesKey: the same PIN under another evaluator (a
// copied record guessed against a key of the guesser's own) opens nothing.
func TestPINNeedsTheHomesKey(t *testing.T) {
	rec := pinRecord(t, newTestEvaluator(t), "123456")
	if _, err := rec.OpenPIN([]byte("123456"), newTestEvaluator(t).eval); !errors.Is(err, ErrWrongSecret) {
		t.Fatalf("another evaluator: %v, want ErrWrongSecret", err)
	}
}

func TestPINOpenOfflineRefused(t *testing.T) {
	rec := pinRecord(t, newTestEvaluator(t), "123456")
	if _, err := rec.Open([]byte("123456")); !errors.Is(err, ErrNeedsHome) {
		t.Fatalf("Open of a PIN record: %v, want ErrNeedsHome", err)
	}
}

// TestPINUnreachableHomeOpensNothing: without the home's answer the
// record cannot open, the first unlock after a reboot included.
func TestPINUnreachableHomeOpensNothing(t *testing.T) {
	rec := pinRecord(t, newTestEvaluator(t), "123456")
	gone := errors.New("CYFR could not be reached")
	if _, err := rec.OpenPIN([]byte("123456"), func([]byte) ([]byte, error) { return nil, gone }); !errors.Is(err, gone) {
		t.Fatalf("home unreachable: %v", err)
	}
}

func TestPINBadElementRefused(t *testing.T) {
	rec := pinRecord(t, newTestEvaluator(t), "123456")
	identity, _ := pinSuite.Group().Identity().MarshalBinaryCompress()
	for name, answer := range map[string][]byte{
		"empty":     nil,
		"short":     make([]byte, 31),
		"long":      make([]byte, 33),
		"identity":  identity,
		"not_point": bytes.Repeat([]byte{0xff}, 32),
	} {
		if _, err := rec.OpenPIN([]byte("123456"), func([]byte) ([]byte, error) { return answer, nil }); !errors.Is(err, ErrBadElement) {
			t.Fatalf("%s: %v, want ErrBadElement", name, err)
		}
	}
}

// TestPINSendsOneBlindedElement: each open sends exactly one 32-byte
// element, fresh each time (a new blind), and never the PIN.
func TestPINSendsOneBlindedElement(t *testing.T) {
	e := newTestEvaluator(t)
	rec := pinRecord(t, e, "123456")
	var sent [][]byte
	for range 2 {
		k, err := rec.OpenPIN([]byte("123456"), func(b []byte) ([]byte, error) {
			sent = append(sent, slices.Clone(b))
			return e.eval(b)
		})
		if err != nil {
			t.Fatal(err)
		}
		k.Erase()
	}
	if len(sent) != 2 || len(sent[0]) != ElementSize || bytes.Equal(sent[0], sent[1]) ||
		bytes.Contains(sent[0], []byte("123456")) {
		t.Fatalf("sent %x", sent)
	}
}

func TestPINRefusesShape(t *testing.T) {
	e := newTestEvaluator(t)
	rec := pinRecord(t, e, "123456")
	e.calls = 0
	for _, pin := range []string{"12345", "1234567", "12345a", "abandon ability able about above absent"} {
		if _, err := rec.OpenPIN([]byte(pin), e.eval); !errors.Is(err, ErrSecretShape) {
			t.Fatalf("%q: %v, want ErrSecretShape", pin, err)
		}
	}
	if e.calls != 0 {
		t.Fatalf("a mis-shaped PIN reached the home %d times", e.calls)
	}
}

// TestPINBoundToItsEvaluatorName: a record relabelled to another
// evaluator's name, or moved to another home, no longer opens.
func TestPINBoundToItsEvaluatorName(t *testing.T) {
	e := newTestEvaluator(t)
	for name, edit := range map[string]func(*Record){
		"evaluator": func(r *Record) { r.PIN.Evaluator = "dpe_other" },
		"home":      func(r *Record) { r.Home = "https://other.example" },
		"salt":      func(r *Record) { r.PIN.Salt[0] ^= 1 },
	} {
		rec := pinRecord(t, e, "123456")
		edit(rec)
		if _, err := rec.OpenPIN([]byte("123456"), e.eval); !errors.Is(err, ErrWrongSecret) {
			t.Fatalf("%s edited: %v, want ErrWrongSecret", name, err)
		}
	}
}

// TestPINRecordOnDisk: the saved record holds the sealed seed, its salt
// and nonce and the evaluator's name, and nothing that opens it: no PIN,
// no OPRF output, no wrap key, no blind.
func TestPINRecordOnDisk(t *testing.T) {
	rec := pinRecord(t, newTestEvaluator(t), "123456")
	path := filepath.Join(t.TempDir(), "device.json")
	if err := rec.Save(path); err != nil {
		t.Fatal(err)
	}
	back, err := Load(path)
	if err != nil || back.PIN == nil || back.PIN.Evaluator != "dpe_test" {
		t.Fatalf("load: %v %+v", err, back)
	}
	var onDisk map[string]json.RawMessage
	data, _ := json.Marshal(rec)
	_ = json.Unmarshal(data, &onDisk)
	var keys []string
	for k := range onDisk {
		keys = append(keys, k)
	}
	slices.Sort(keys)
	if got := strings.Join(keys, ","); got != "admission,home,kind,pin,public_key,request_id,version" {
		t.Fatalf("record fields %s", got)
	}
	var blob map[string]json.RawMessage
	_ = json.Unmarshal(onDisk["pin"], &blob)
	keys = keys[:0]
	for k := range blob {
		keys = append(keys, k)
	}
	slices.Sort(keys)
	if got := strings.Join(keys, ","); got != "ciphertext,evaluator,nonce,salt" {
		t.Fatalf("pin blob fields %s", got)
	}
}

func TestPINRecordRefusesTwoBlobs(t *testing.T) {
	rec := pinRecord(t, newTestEvaluator(t), "123456")
	other, _ := softwareRecord(t)
	rec.Software = other.Software
	if err := rec.Save(filepath.Join(t.TempDir(), "device.json")); err == nil {
		t.Fatal("a record with a passphrase blob and a PIN blob was saved")
	}
}

func TestHardenPINRefusesAnotherKey(t *testing.T) {
	rec, pass := softwareRecord(t)
	fresh, err := NewSoftware(testHome, "r", "a", pass)
	if err != nil {
		t.Fatal(err)
	}
	k, err := fresh.Open(pass)
	if err != nil {
		t.Fatal(err)
	}
	defer k.Erase()
	if _, err := rec.HardenPIN(k, "dpe_test", []byte("123456"), newTestEvaluator(t).eval); err == nil {
		t.Fatal("another record's key was sealed under this record")
	}
}

// The elements the fixture says a home refuses (the identity, a
// non-canonical encoding, bytes no element has) are refused as an
// answer here too: circl decodes the identity, so the holder checks it.
func TestPINRefusesTheFixturesElements(t *testing.T) {
	rec := pinRecord(t, newTestEvaluator(t), "123456")
	for _, e := range readPINVectors(t).Elements.Refused {
		raw, err := base64.RawURLEncoding.DecodeString(e.Blinded)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := rec.OpenPIN([]byte("123456"), func([]byte) ([]byte, error) { return raw, nil }); !errors.Is(err, ErrBadElement) {
			t.Errorf("%s: %v, want ErrBadElement", e.Name, err)
		}
	}
}
