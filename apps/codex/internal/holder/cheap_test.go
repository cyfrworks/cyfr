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
	"slices"
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
// module is read, for every system and build tag, and each name is in
// exactly these files. The test files in the list are the search's positive
// control.
func TestNoProgramReachesTheCheapDerivation(t *testing.T) {
	want := map[string][]string{
		"CheapDerivationForTests": {"internal/holder/cheap.go", "internal/holder/cheap_test.go", "internal/shell/shell_test.go"},
		"testCost":                {"internal/holder/cheap.go", "internal/holder/cheap_test.go", "internal/holder/software.go"},
	}
	root := filepath.Join("..", "..")
	got := map[string][]string{}
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
			if !bytes.Contains(src, []byte(name)) {
				continue
			}
			got[name] = append(got[name], filepath.ToSlash(rel))
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
	for name := range got {
		slices.Sort(got[name])
	}
	if !maps.EqualFunc(got, want, slices.Equal) {
		t.Fatalf("the cheap derivation is named in %v, not in %v alone", got, want)
	}
}
