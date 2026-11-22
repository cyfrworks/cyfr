// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package holder

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/ed25519"
	"io/fs"
	"maps"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"golang.org/x/crypto/argon2"
)

// What a person's key is made and opened under, by value: the parameters
// written here are read from no constant of the holder's, and the key they
// derive opens what the holder sealed.
func TestAPersonsKeyIsDerivedUnderTheFixedParameters(t *testing.T) {
	if argonTime != 3 || argonMemory != 65536 || argonThreads != 4 || argonKeyLen != 32 {
		t.Fatalf("the fixed parameters are time %d, memory %d KiB, threads %d, key %d bytes", argonTime, argonMemory, argonThreads, argonKeyLen)
	}
	if c := derivationCost(); c != (argonCost{time: 3, memoryKiB: 65536}) {
		t.Fatalf("a derivation costs %+v", c)
	}
	r, pass := softwareRecord(t)
	b := r.Software
	if b.Time != 3 || b.MemoryKiB != 65536 || b.Threads != 4 || b.KeyLen != 32 {
		t.Fatalf("a key's record names %+v", b)
	}
	block, err := aes.NewCipher(argon2.IDKey(pass, b.Salt, 3, 65536, 4, 32))
	if err != nil {
		t.Fatal(err)
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		t.Fatal(err)
	}
	seed, err := aead.Open(nil, b.Nonce, b.Ciphertext, r.aad())
	if err != nil {
		t.Fatalf("the holder sealed under other parameters than the fixed ones: %v", err)
	}
	if !bytes.Equal(ed25519.NewKeyFromSeed(seed).Public().(ed25519.PublicKey), r.PublicKey) {
		t.Fatal("the seed sealed is not the record's key")
	}
}

// A key made cheaply opens under no fixed derivation, and a person's key
// under no cheap one: neither record can pass for the other.
func TestACheapKeyIsRefusedUnderTheFixedDerivation(t *testing.T) {
	person, pass := softwareRecord(t) // shared, so made before the switch
	t.Cleanup(func() { testCost.Store(nil) })
	fixed := CheapDerivationForTests()
	cheap, err := NewSoftware(pass)
	if err != nil {
		t.Fatal(err)
	}
	if b := cheap.Software; b.Time != 1 || b.MemoryKiB != 64 || b.Threads != 4 || b.KeyLen != 32 {
		t.Fatalf("a cheap key's record names %+v", b)
	}
	k, err := cheap.Open(pass)
	if err != nil {
		t.Fatalf("a cheap key does not open cheaply: %v", err)
	}
	k.Erase()
	if k, err := person.Open(pass); k != nil || err == nil || !strings.Contains(err.Error(), "Argon2id parameters") {
		t.Fatalf("a person's key under the cheap derivation = key %t, %v", k != nil, err)
	}
	fixed()
	if c := derivationCost(); c != (argonCost{time: 3, memoryKiB: 65536}) {
		t.Fatalf("after fixed a derivation costs %+v", c)
	}
	if k, err := cheap.Open(pass); k != nil || err == nil || !strings.Contains(err.Error(), "Argon2id parameters") {
		t.Fatalf("a cheap key under the fixed derivation = key %t, %v", k != nil, err)
	}
}

// Nothing of a program reaches the cheap derivation: every Go source of the
// module is read, for every system and build tag, and each name is referred
// to exactly so many times in exactly these files, so one reference more
// fails here, in a file listed as in any other. A comment refers to nothing,
// a directive does. The test files in the list are the search's positive
// control.
func TestNoProgramReachesTheCheapDerivation(t *testing.T) {
	want := map[string]map[string]int{
		"CheapDerivationForTests": {"internal/holder/cheap.go": 2, "internal/holder/cheap_test.go": 2, "internal/shell/shell_test.go": 2},
		"testCost":                {"internal/holder/cheap.go": 3, "internal/holder/cheap_test.go": 3, "internal/holder/software.go": 1},
	}
	root := filepath.Join("..", "..")
	got := map[string]map[string]int{}
	for name := range want {
		got[name] = map[string]int{}
	}
	err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		switch {
		case err != nil:
			return err
		case d.IsDir() && d.Name() == "node_modules":
			return fs.SkipDir
		case d.IsDir() || filepath.Ext(path) != ".go":
			return nil
		}
		src, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		for name := range want {
			n := 0
			for line := range strings.Lines(string(src)) {
				if code := strings.TrimSpace(line); !strings.HasPrefix(code, "//") || strings.HasPrefix(code, "//go:") {
					n += strings.Count(code, name)
				}
			}
			if n == 0 {
				continue
			}
			got[name][filepath.ToSlash(rel)] = n
			if name == "testCost" && filepath.Base(path) == "software.go" &&
				bytes.Count(src, []byte(name)) != bytes.Count(src, []byte(name+".Load()")) {
				t.Errorf("%s does more with %s than read it", rel, name)
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if !maps.EqualFunc(got, want, maps.Equal) {
		t.Fatalf("the cheap derivation is referred to %v, not %v alone", got, want)
	}
}
