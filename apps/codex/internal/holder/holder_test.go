// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package holder

import (
	"bytes"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
)

// software is one software record shared by the tests that only read it:
// Argon2id at 64 MiB makes each seal and open take a noticeable moment.
var software struct {
	once sync.Once
	rec  *Record
	pass []byte
	err  error
}

// softwareRecord returns a private copy of the shared record and its
// passphrase.
func softwareRecord(t *testing.T) (*Record, []byte) {
	t.Helper()
	software.once.Do(func() {
		var pass string
		if pass, software.err = GeneratePassphrase(); software.err != nil {
			return
		}
		software.pass = []byte(pass)
		software.rec, software.err = NewSoftware(software.pass)
	})
	if software.err != nil {
		t.Fatalf("create the software record: %v", software.err)
	}
	return copyRecord(t, software.rec), bytes.Clone(software.pass)
}

func copyRecord(t *testing.T, r *Record) *Record {
	t.Helper()
	data, err := json.Marshal(r)
	if err != nil {
		t.Fatal(err)
	}
	var c Record
	if err := json.Unmarshal(data, &c); err != nil {
		t.Fatal(err)
	}
	return &c
}

func TestWordListIsBIP39English(t *testing.T) {
	sum := sha256.Sum256([]byte(wordList))
	if got := hex.EncodeToString(sum[:]); got != "2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda" {
		t.Fatalf("word list SHA-256 = %s", got)
	}
	if len(words) != 2048 || len(wordSet) != 2048 {
		t.Fatalf("word list has %d words, %d distinct; want 2048", len(words), len(wordSet))
	}
}

func TestGeneratePassphrase(t *testing.T) {
	seen := map[string]bool{}
	for range 20 {
		p, err := GeneratePassphrase()
		if err != nil {
			t.Fatal(err)
		}
		w := strings.Split(p, " ")
		if len(w) != 6 {
			t.Fatalf("%q has %d words", p, len(w))
		}
		for _, x := range w {
			if !slices.Contains(words, x) {
				t.Fatalf("%q is not a list word", x)
			}
		}
		if err := CheckPassphrase([]byte(p)); err != nil {
			t.Fatalf("CheckPassphrase(%q) = %v", p, err)
		}
		seen[p] = true
	}
	if len(seen) != 20 {
		t.Fatalf("20 passphrases drew %d distinct ones", len(seen))
	}
}

func TestCheckPassphrase(t *testing.T) {
	for _, p := range []string{
		"123456",
		"000000",
		"1 2 3 4 5 6",
		"abandon ability able about above 123456",
		"abandon ability able about above",
		"abandon ability able about above absent absorb",
		"abandon  ability able about above absent",
		" abandon ability able about above absent",
		"abandon ability able about above absent ",
		"abandon\tability able about above absent",
		"Abandon ability able about above absent",
		"abandon ability able about above cyfr",
		"",
	} {
		if err := CheckPassphrase([]byte(p)); !errors.Is(err, ErrSecretShape) {
			t.Errorf("CheckPassphrase(%q) = %v, want ErrSecretShape", p, err)
		}
	}
	if err := CheckPassphrase([]byte("abandon ability able about above zoo")); err != nil {
		t.Errorf("six list words refused: %v", err)
	}
}

func TestNewSoftwareRefusesDigits(t *testing.T) {
	for _, p := range []string{"123456", "000000", "1234567890", "abandon ability able about above 1"} {
		if r, err := NewSoftware([]byte(p)); !errors.Is(err, ErrSecretShape) || r != nil {
			t.Errorf("NewSoftware(%q) = record %t, %v; want ErrSecretShape", p, r != nil, err)
		}
	}
}

func TestCheckPIN(t *testing.T) {
	for p, ok := range map[string]bool{
		"000000": true, "123456": true, "999999": true,
		"12345": false, "1234567": false, "": false, "12345a": false,
		"12 456": false, "١٢٣٤٥٦": false, "12345\x00": false,
	} {
		err := CheckPIN([]byte(p))
		if ok && err != nil || !ok && !errors.Is(err, ErrSecretShape) {
			t.Errorf("CheckPIN(%q) = %v", p, err)
		}
	}
}

func TestSoftwareRoundTrip(t *testing.T) {
	r, pass := softwareRecord(t)
	if r.Version != 2 || r.Kind != KindSoftware || r.Identifier != "" || r.Chip != nil || len(r.PublicKey) != ed25519.PublicKeySize {
		t.Fatalf("record = %+v", r)
	}
	if s := r.Software; s.Time != 3 || s.MemoryKiB != 65536 || s.Threads != 4 || s.KeyLen != 32 ||
		len(s.Salt) != 16 || len(s.Nonce) != 12 || len(s.Ciphertext) != 32+16 {
		t.Fatalf("software blob = %+v", s)
	}
	k, err := r.Open(pass)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(k.Public(), r.PublicKey) {
		t.Fatalf("opened public key %x, record %x", k.Public(), r.PublicKey)
	}
	if !ed25519.Verify(r.PublicKey, []byte("hello"), k.Sign([]byte("hello"))) {
		t.Fatal("the opened key's signature does not verify against the record's public key")
	}
	priv := k.priv
	k.Erase()
	if k.priv != nil || !bytes.Equal(priv, make([]byte, ed25519.PrivateKeySize)) {
		t.Fatal("Erase left the private key's bytes in place")
	}
}

func TestSoftwareFreshSeedEachTime(t *testing.T) {
	r, pass := softwareRecord(t)
	again, err := NewSoftware(pass)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Equal(again.PublicKey, r.PublicKey) || bytes.Equal(again.Software.Salt, r.Software.Salt) {
		t.Fatal("a second record under the same passphrase reused the key or the salt")
	}
}

func TestSoftwareWrongPassphrase(t *testing.T) {
	r, _ := softwareRecord(t)
	if k, err := r.Open([]byte("abandon ability able about above zoo")); !errors.Is(err, ErrWrongSecret) || k != nil {
		t.Fatalf("Open(wrong) = key %t, %v; want ErrWrongSecret", k != nil, err)
	}
	if _, err := r.Open([]byte("123456")); !errors.Is(err, ErrSecretShape) {
		t.Fatalf("Open(PIN) = %v; want ErrSecretShape", err)
	}
}

func TestSoftwareTamperRefused(t *testing.T) {
	for name, edit := range map[string]func(r *Record){
		"ciphertext": func(r *Record) { r.Software.Ciphertext[0] ^= 1 },
		"nonce":      func(r *Record) { r.Software.Nonce[0] ^= 1 },
		"salt":       func(r *Record) { r.Software.Salt[0] ^= 1 },
		"public key": func(r *Record) { r.PublicKey[0] ^= 1 },
	} {
		t.Run(name, func(t *testing.T) {
			r, pass := softwareRecord(t)
			edit(r)
			if k, err := r.Open(pass); !errors.Is(err, ErrWrongSecret) || k != nil {
				t.Fatalf("Open after editing the %s = key %t, %v; want ErrWrongSecret", name, k != nil, err)
			}
		})
	}
}

func TestSoftwareParametersEditedInFileRefused(t *testing.T) {
	for field, value := range map[string]any{"time": 1, "memory_kib": 8, "threads": 1, "key_len": 16} {
		t.Run(field, func(t *testing.T) {
			r, pass := softwareRecord(t)
			path := filepath.Join(t.TempDir(), "key.json")
			if err := r.Save(path); err != nil {
				t.Fatal(err)
			}
			var doc map[string]any
			data, _ := os.ReadFile(path)
			if err := json.Unmarshal(data, &doc); err != nil {
				t.Fatal(err)
			}
			doc["software"].(map[string]any)[field] = value
			data, _ = json.Marshal(doc)
			if err := os.WriteFile(path, data, 0o600); err != nil {
				t.Fatal(err)
			}
			edited, err := Load(path)
			if err != nil {
				t.Fatal(err)
			}
			k, err := edited.Open(pass)
			if err == nil || k != nil || !strings.Contains(err.Error(), "Argon2id parameters") {
				t.Fatalf("Open with %s=%v = key %t, %v; want the parameters refused", field, value, k != nil, err)
			}
		})
	}
}

func TestOpenDecryptsEveryCall(t *testing.T) {
	r, pass := softwareRecord(t)
	for range 2 {
		k, err := r.Open(pass)
		if err != nil {
			t.Fatal(err)
		}
		k.Erase()
	}
	path := filepath.Join(t.TempDir(), "key.json")
	r.Identifier, r.Directory = "per_"+strings.Repeat("ab", 32), "https://cyfr.run"
	if err := r.Save(path); err != nil {
		t.Fatal(err)
	}
	listed, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	k, err := listed.Open(pass)
	if err != nil {
		t.Fatalf("Open of the saved record once its account is named = %v", err)
	}
	k.Erase()
}

func TestSaveLoad(t *testing.T) {
	r, _ := softwareRecord(t)
	dir := t.TempDir()
	path := filepath.Join(dir, "key.json")
	if err := r.Create(path); err != nil {
		t.Fatal(err)
	}
	r.Identifier, r.Directory = "per_"+strings.Repeat("cd", 32), "https://cyfr.run"
	if err := r.Save(path); err != nil {
		t.Fatal(err)
	}
	entries, _ := os.ReadDir(dir)
	if len(entries) != 1 || entries[0].Name() != "key.json" {
		t.Fatalf("directory holds %v, want only key.json", entries)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("mode = %v, want 0600", info.Mode().Perm())
	}
	got, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	want, _ := json.Marshal(r)
	have, _ := json.Marshal(got)
	if !bytes.Equal(have, want) {
		t.Fatalf("Load = %s\nwant %s", have, want)
	}

	var doc map[string]any
	data, _ := os.ReadFile(path)
	if err := json.Unmarshal(data, &doc); err != nil {
		t.Fatal(err)
	}
	keys := make([]string, 0, len(doc))
	for k := range doc {
		keys = append(keys, k)
	}
	slices.Sort(keys)
	if w := []string{"directory", "identifier", "kind", "public_key", "software", "version"}; !slices.Equal(keys, w) {
		t.Fatalf("record keys = %v, want %v", keys, w)
	}
	if doc["public_key"] != base64.RawURLEncoding.EncodeToString(r.PublicKey) {
		t.Fatalf("public_key = %v, want unpadded base64url", doc["public_key"])
	}
}

func TestLoadRefuses(t *testing.T) {
	if _, err := Load(filepath.Join(t.TempDir(), "absent.json")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("Load(missing) = %v; want os.ErrNotExist", err)
	}
	r, _ := softwareRecord(t)
	for name, edit := range map[string]func(doc map[string]any){
		"unknown version":      func(doc map[string]any) { doc["version"] = 3 },
		"a record of one CYFR": func(doc map[string]any) { doc["version"] = 1 },
		"unknown kind":         func(doc map[string]any) { doc["kind"] = "paper" },
		"chip kind":            func(doc map[string]any) { doc["kind"] = "chip" },
		"both blobs":           func(doc map[string]any) { doc["chip"] = map[string]any{"public": "", "private": ""} },
		"no blob":              func(doc map[string]any) { delete(doc, "software") },
		"short public key":     func(doc map[string]any) { doc["public_key"] = "AAAA" },
		"padded public key":    func(doc map[string]any) { doc["public_key"] = doc["public_key"].(string) + "=" },
		"standard base64":      func(doc map[string]any) { doc["public_key"] = base64.StdEncoding.EncodeToString(r.PublicKey) },
		"version not a number": func(doc map[string]any) { clear(doc); doc["version"] = []int{1} },
	} {
		t.Run(name, func(t *testing.T) {
			data, _ := json.Marshal(r)
			var doc map[string]any
			if err := json.Unmarshal(data, &doc); err != nil {
				t.Fatal(err)
			}
			edit(doc)
			data, _ = json.Marshal(doc)
			path := filepath.Join(t.TempDir(), "key.json")
			if err := os.WriteFile(path, data, 0o600); err != nil {
				t.Fatal(err)
			}
			if got, err := Load(path); err == nil {
				t.Fatalf("Load accepted %s: %+v", data, got)
			}
		})
	}
}

// The first key a machine makes is the one it keeps: a second Create at
// the same path, of another key, answers ErrKeyExists and leaves the
// first whole, and no save replaces a record of another key, or a file
// that is no record; a save of the same key replaces it.
func TestCreateAndSaveKeepTheFirstKey(t *testing.T) {
	first, _ := softwareRecord(t)
	pass, err := GeneratePassphrase()
	if err != nil {
		t.Fatal(err)
	}
	second, err := NewSoftware([]byte(pass))
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	path := filepath.Join(dir, "key.json")
	if err := first.Create(path); err != nil {
		t.Fatal(err)
	}
	if err := second.Create(path); !errors.Is(err, ErrKeyExists) {
		t.Fatalf("a second Create = %v; want ErrKeyExists", err)
	}
	if err := second.Save(path); !errors.Is(err, ErrOtherKey) {
		t.Fatalf("a Save of another key = %v; want ErrOtherKey", err)
	}
	held, err := Load(path)
	if err != nil || !bytes.Equal(held.PublicKey, first.PublicKey) {
		t.Fatalf("the record holds %v (%v), not the first key", held, err)
	}
	first.Identifier = "per_" + strings.Repeat("e", 64)
	if err := first.Save(path); err != nil {
		t.Fatalf("a Save of the same key = %v", err)
	}
	if held, _ := Load(path); held.Identifier != first.Identifier {
		t.Fatal("the same key's save was not kept")
	}
	entries, _ := os.ReadDir(dir)
	if len(entries) != 1 {
		t.Fatalf("the directory holds %v, want only key.json", entries)
	}
	other := filepath.Join(dir, "other.json")
	if err := os.WriteFile(other, []byte("not a record"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := first.Save(other); err == nil {
		t.Fatal("a Save replaced a file that is no record")
	}
}
