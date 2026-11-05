// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package guard

import (
	"net/netip"
	"reflect"
	"strconv"
	"strings"
	"testing"
)

func TestParseRequest(t *testing.T) {
	good := []string{
		`{"v":1,"type":"admit","uid":40001,"addresses":["1.2.3.4","2606:4700::1111"]}`,
		`{"v":1,"type":"clear","uid":20001}`,
	}
	for _, line := range good {
		if _, err := ParseRequest([]byte(line)); err != nil {
			t.Errorf("%s: %v", line, err)
		}
	}
	bad := map[string]string{
		"another version":       `{"v":2,"type":"clear","uid":20001}`,
		"an unknown type":       `{"v":1,"type":"open","uid":20001}`,
		"an unknown member":     `{"v":1,"type":"clear","uid":20001,"extra":1}`,
		"no uid":                `{"v":1,"type":"clear"}`,
		"uid zero":              `{"v":1,"type":"clear","uid":0}`,
		"uid of no one":         `{"v":1,"type":"clear","uid":4294967295}`,
		"an admit of nothing":   `{"v":1,"type":"admit","uid":40001,"addresses":[]}`,
		"an admit, no list":     `{"v":1,"type":"admit","uid":40001}`,
		"a clear with a list":   `{"v":1,"type":"clear","uid":40001,"addresses":["1.2.3.4"]}`,
		"a hostname":            `{"v":1,"type":"admit","uid":40001,"addresses":["example.com"]}`,
		"a CIDR":                `{"v":1,"type":"admit","uid":40001,"addresses":["1.2.3.0/24"]}`,
		"a zone":                `{"v":1,"type":"admit","uid":40001,"addresses":["fe80::1%eth0"]}`,
		"a mapped address":      `{"v":1,"type":"admit","uid":40001,"addresses":["::ffff:1.2.3.4"]}`,
		"a non-canonical form":  `{"v":1,"type":"admit","uid":40001,"addresses":["2606:4700:0::1111"]}`,
		"a request with netns":  `{"v":1,"type":"clear","uid":40001,"netns":"net:[1]"}`,
		"trailing data":         `{"v":1,"type":"clear","uid":40001} {}`,
		"not an object":         `[1]`,
		"a guard's own message": `{"v":1,"type":"admitted","uid":40001}`,
	}
	for why, line := range bad {
		if _, err := ParseRequest([]byte(line)); err == nil {
			t.Errorf("%s was accepted: %s", why, line)
		}
	}
	many := make([]string, MaxAddresses+1)
	for i := range many {
		many[i] = `"10.0.` + strconv.Itoa(i/256) + `.` + strconv.Itoa(i%256) + `"`
	}
	line := `{"v":1,"type":"admit","uid":40001,"addresses":[` + strings.Join(many, ",") + `]}`
	if _, err := ParseRequest([]byte(line)); err == nil {
		t.Error("an admit of more than MaxAddresses was accepted")
	}
	if len(line) > MaxLineBytes {
		t.Errorf("an admit of MaxAddresses does not fit a line: %d bytes", len(line))
	}
}

func TestParseRanges(t *testing.T) {
	got, err := ParseRanges("20001-20032,40001-49999")
	if err != nil || !reflect.DeepEqual(got, []Range{{20001, 20032}, {40001, 49999}}) {
		t.Fatalf("got %v, %v", got, err)
	}
	if !Holds(got, 40001) || !Holds(got, 20032) || Holds(got, 30001) || Holds(got, 0) {
		t.Fatal("Holds answers wrong")
	}
	for _, bad := range []string{"", "20001", "20032-20001", "0-5", "a-b", "1-2,", "1-2-3"} {
		if _, err := ParseRanges(bad); err == nil {
			t.Errorf("%q was accepted", bad)
		}
	}
}

func TestClientAdmitsUnmappedAddresses(t *testing.T) {
	addrs := []netip.Addr{netip.MustParseAddr("::ffff:1.2.3.4"), netip.MustParseAddr("2606:4700::1111")}
	text := make([]string, len(addrs))
	for i, a := range addrs {
		text[i] = a.Unmap().WithZone("").String()
	}
	for _, a := range text {
		if _, err := CanonicalAddress(a); err != nil {
			t.Errorf("%s: %v", a, err)
		}
	}
}
