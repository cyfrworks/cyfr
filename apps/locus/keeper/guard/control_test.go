// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package guard

import (
	"bytes"
	"encoding/json"
	"os"
	"reflect"
	"strconv"
	"strings"
	"testing"
)

// vectors is testdata/control.json, the control's one vector file, which
// the keeper's side (client_linux_test.go) and the guard's side
// (server_linux_test.go) both read.
type vectors struct {
	Comment  string          `json:"comment"`
	Hello    json.RawMessage `json:"hello"`
	Requests []struct {
		Descriptors int             `json:"descriptors"`
		Message     json.RawMessage `json:"message"`
	} `json:"requests"`
	Refused []struct {
		Why         string          `json:"why"`
		Descriptors int             `json:"descriptors"`
		Message     json.RawMessage `json:"message"`
	} `json:"refused"`
	Answers []struct {
		Asked   string          `json:"asked"`
		SpawnID string          `json:"spawn_id"`
		Message json.RawMessage `json:"message"`
	} `json:"answers"`
	NotAnswers []struct {
		Why     string          `json:"why"`
		Asked   string          `json:"asked"`
		SpawnID string          `json:"spawn_id"`
		Message json.RawMessage `json:"message"`
	} `json:"not_answers"`
}

func loadVectors(t *testing.T) vectors {
	t.Helper()
	data, err := os.ReadFile("testdata/control.json")
	if err != nil {
		t.Fatal(err)
	}
	var v vectors
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&v); err != nil {
		t.Fatal(err)
	}
	if len(v.Requests) == 0 || len(v.Refused) == 0 || len(v.Answers) == 0 || len(v.NotAnswers) == 0 {
		t.Fatal("a section of the vectors is empty")
	}
	return v
}

// sameJSON reports whether two encodings hold the same value.
func sameJSON(t *testing.T, a, b []byte) bool {
	t.Helper()
	var x, y any
	if err := json.Unmarshal(a, &x); err != nil {
		t.Fatalf("%s: %v", a, err)
	}
	if err := json.Unmarshal(b, &y); err != nil {
		t.Fatalf("%s: %v", b, err)
	}
	return reflect.DeepEqual(x, y)
}

func TestTheGuardTakesEveryRequestOfTheVectorsAndRefusesTheRest(t *testing.T) {
	v := loadVectors(t)
	for _, r := range v.Requests {
		m, err := ParseRequest(r.Message, r.Descriptors)
		if err != nil {
			t.Errorf("%s: %v", r.Message, err)
			continue
		}
		out, err := Encode(m)
		if err != nil || !sameJSON(t, out, r.Message) {
			t.Errorf("%s encodes again as %s (%v)", r.Message, out, err)
		}
	}
	for _, r := range v.Refused {
		if _, err := ParseRequest(r.Message, r.Descriptors); err == nil {
			t.Errorf("%s was accepted: %s", r.Why, r.Message)
		}
	}
	many := make([]string, MaxAddresses+1)
	for i := range many {
		many[i] = `"10.0.` + strconv.Itoa(i/256) + `.` + strconv.Itoa(i%256) + `"`
	}
	packet := `{"v":4,"type":"admit","spawn_id":"00112233445566778899aabbccddeeff","reach":"hosts","addresses":[` + strings.Join(many, ",") + `]}`
	if _, err := ParseRequest([]byte(packet), AdmitDescriptors); err == nil {
		t.Error("an admit of more than MaxAddresses was accepted")
	}
	if len(packet) > MaxMessageBytes {
		t.Errorf("an admit of MaxAddresses does not fit a message: %d bytes", len(packet))
	}
}

func TestTheKeeperTakesEveryAnswerOfTheVectorsAndNoOther(t *testing.T) {
	v := loadVectors(t)
	for _, a := range v.Answers {
		if _, err := ParseAnswer(a.Message, a.Asked, a.SpawnID); err != nil {
			t.Errorf("%s to a %s: %v", a.Message, a.Asked, err)
		}
	}
	for _, a := range v.NotAnswers {
		if _, err := ParseAnswer(a.Message, a.Asked, a.SpawnID); err == nil {
			t.Errorf("%s was taken: %s", a.Why, a.Message)
		}
	}
	hello, err := Decode(v.Hello)
	if err != nil || hello.Type != TypeHello || hello.Netns == "" {
		t.Errorf("the hello %s: %+v %v", v.Hello, hello, err)
	}
}

func TestParseRange(t *testing.T) {
	if p, err := ParseRange("10.213.0.0/16"); err != nil || p.String() != "10.213.0.0/16" {
		t.Fatalf("%v %v", p, err)
	}
	for _, bad := range []string{"", "10.213.0.0/24", "10.213.1.0/16", "10.213.0.0", "fd00::/16", "10.213.000.0/16"} {
		if _, err := ParseRange(bad); err == nil {
			t.Errorf("%q was accepted", bad)
		}
	}
}
