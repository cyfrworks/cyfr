// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package outer

import (
	"maps"
	"testing"
)

// ParseTable reads syscall_64.tbl's lines, whatever follows a call's name,
// keeps the 64-bit ABI's calls and skips comments, blank lines and x32.
func TestParseTableReadsTheKernelsFormat(t *testing.T) {
	tbl := "#\n# 64-bit system call numbers and entry vectors\n#\n\n" +
		"0\tcommon\tread\t\t\tsys_read\n" +
		"13\t64\trt_sigaction\t\tsys_rt_sigaction\n" +
		"60\tcommon\texit\t\t\tsys_exit\t\t\t-\t\t\tnoreturn\n" +
		"435 common clone3 sys_clone3 # after a call\n" +
		"512\tx32\trt_sigaction\t\tcompat_sys_rt_sigaction\n"
	got, err := ParseTable([]byte(tbl))
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]uint32{"read": 0, "rt_sigaction": 13, "exit": 60, "clone3": 435}
	if !maps.Equal(got, want) {
		t.Fatalf("ParseTable: %v, want %v", got, want)
	}
}

// A table that is empty, malformed or ambiguous describes no kernel, and
// is refused.
func TestParseTableRefusesWhatIsNoKernelsTable(t *testing.T) {
	for what, tbl := range map[string]string{
		"an empty table":              "",
		"comments alone":              "# <number> <abi> <name>\n#\n",
		"x32 calls alone":             "512\tx32\trt_sigaction\tcompat_sys_rt_sigaction\n",
		"a line without a name":       "0\tcommon\n",
		"a number that is not one":    "zero\tcommon\tread\tsys_read\n",
		"a negative number":           "-1\tcommon\tread\tsys_read\n",
		"a number past 32 bits":       "4294967296\tcommon\tread\tsys_read\n",
		"another architecture's abi":  "0\ti386\trestart_syscall\tsys_restart_syscall\n",
		"a name listed twice":         "0\tcommon\tread\tsys_read\n1\tcommon\tread\tsys_read\n",
		"a number given to two names": "0\tcommon\tread\tsys_read\n0\tcommon\twrite\tsys_write\n",
	} {
		if table, err := ParseTable([]byte(tbl)); err == nil {
			t.Errorf("%s: read as %v", what, table)
		}
	}
}
