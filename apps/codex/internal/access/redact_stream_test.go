// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package access

import (
	"bytes"
	"path/filepath"
	"strings"
	"testing"
)

// A redacting stream reads as the whole text redacted, wherever its writes
// split it, and after every write holds no more than the longest value's
// length less one byte: every four-letter value over {a, b} against every
// text of up to seven letters over them, split a byte at a time and at
// every point, and values that overlap themselves and each other, a
// multi-line one, one with significant spaces and multi-byte ones, split
// a byte at a time and at every pair of points.
func TestRedactedStreamReadsAsTheWholeTextWhereverItsWritesSplitIt(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, ".env"), []byte("CYFR_ACCESS=local\n"))
	streams := 0
	check := func(values []string, text string, everyPair bool) {
		t.Helper()
		r := NewRedactor(dir)
		r.Hold(values...)
		longest := 0
		for _, v := range values {
			longest = max(longest, len(v))
		}
		want := r.Text(text)
		run := func(chunks []string) {
			t.Helper()
			var out bytes.Buffer
			w := r.Writer(&out)
			for _, c := range chunks {
				n, err := w.Write([]byte(c))
				if err != nil || n != len(c) {
					t.Fatalf("Write %q: %d, %v", c, n, err)
				}
				if len(w.buf) > longest-1 {
					t.Fatalf("values %q, text %q, chunks %q: %d bytes held, more than %d", values, text, chunks, len(w.buf), longest-1)
				}
			}
			if err := w.Flush(); err != nil {
				t.Fatal(err)
			}
			if out.String() != want {
				t.Fatalf("values %q, text %q, chunks %q: the stream showed %q, the whole text %q", values, text, chunks, out.String(), want)
			}
			streams++
		}
		bytewise := make([]string, len(text))
		for i := range bytewise {
			bytewise[i] = text[i : i+1]
		}
		run(bytewise)
		for i := 0; i <= len(text); i++ {
			if !everyPair {
				run([]string{text[:i], text[i:]})
				continue
			}
			for j := i; j <= len(text); j++ {
				run([]string{text[:i], text[i:j], text[j:]})
			}
		}
	}
	binary := func(n, bits int) string {
		v := make([]byte, n)
		for i := range v {
			v[i] = 'a' + byte((bits>>i)&1)
		}
		return string(v)
	}
	for secret := 0; secret < 16; secret++ {
		v := binary(4, secret)
		for n := 0; n <= 7; n++ {
			for text := 0; text < 1<<n; text++ {
				check([]string{v}, binary(n, text), false)
			}
		}
	}
	for _, c := range []struct {
		values []string
		text   string
	}{
		{[]string{"----"}, strings.Repeat("-", 32)},
		{[]string{"abab"}, "xabababy ababab z"},
		{[]string{"abab", "baba"}, "xabababababababay"},
		{[]string{"abcd", "bcde", "cdef"}, "xxabcdefabcdefyy"},
		{[]string{"aaaa", "aaab", "aaba"}, "aaaaaaabaaabaaaa"},
		{[]string{"aabbaa", "bbaabb"}, "xaabbaabbaabbaabby"},
		{[]string{"q2\nx4", " abc "}, "xq2\nx4q2\nx4  abc y"},
		{[]string{"一二一二", "二一二一"}, "x一二一二一二一二y"},
	} {
		check(c.values, c.text, true)
	}
	t.Logf("%d streams checked", streams)
}
