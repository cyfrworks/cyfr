// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package frame

import (
	"bytes"
	"encoding/hex"
	"errors"
	"io"
	"testing"
)

func TestRoundTripAndEndMarker(t *testing.T) {
	var buf bytes.Buffer
	if err := Write(&buf, StreamStdout, []byte("hello")); err != nil {
		t.Fatal(err)
	}
	if err := Write(&buf, StreamStderr, nil); err != nil {
		t.Fatal(err)
	}

	if got := hex.EncodeToString(buf.Bytes()); got != "010000000568656c6c6f"+"0200000000" {
		t.Fatalf("encoding = %s", got)
	}

	scratch := make([]byte, MaxPayload)
	stream, payload, err := Read(&buf, scratch)
	if err != nil || stream != StreamStdout || string(payload) != "hello" {
		t.Fatalf("first frame = %d %q %v", stream, payload, err)
	}
	stream, payload, err = Read(&buf, scratch)
	if err != nil || stream != StreamStderr || len(payload) != 0 {
		t.Fatalf("end marker = %d %q %v", stream, payload, err)
	}
	if _, _, err := Read(&buf, scratch); err != io.EOF {
		t.Fatalf("clean end = %v, want io.EOF", err)
	}
}

func TestControlIsTheLastStream(t *testing.T) {
	var buf bytes.Buffer
	if err := Write(&buf, StreamControl, []byte(`{"v":1}`+"\n")); err != nil {
		t.Fatal(err)
	}
	if got := hex.EncodeToString(buf.Bytes()); got != "0400000008"+"7b2276223a317d0a" {
		t.Fatalf("encoding = %s", got)
	}
	stream, payload, err := Read(&buf, make([]byte, MaxPayload))
	if err != nil || stream != StreamControl || string(payload) != `{"v":1}`+"\n" {
		t.Fatalf("control frame = %d %q %v", stream, payload, err)
	}
	if err := Write(io.Discard, StreamControl+1, nil); !errors.Is(err, ErrUnknownStream) {
		t.Fatalf("the stream after control was accepted: %v", err)
	}
}

func TestRefusesOversizeAndUnknownStreams(t *testing.T) {
	if err := Write(io.Discard, StreamStdin, make([]byte, MaxPayload+1)); !errors.Is(err, ErrTooLarge) {
		t.Fatalf("oversize write = %v", err)
	}
	if err := Write(io.Discard, 9, nil); !errors.Is(err, ErrUnknownStream) {
		t.Fatalf("unknown stream write = %v", err)
	}

	scratch := make([]byte, MaxPayload)
	oversize, _ := hex.DecodeString("0100010001")
	if _, _, err := Read(bytes.NewReader(oversize), scratch); !errors.Is(err, ErrTooLarge) {
		t.Fatalf("oversize read = %v", err)
	}
	unknown, _ := hex.DecodeString("0700000000")
	if _, _, err := Read(bytes.NewReader(unknown), scratch); !errors.Is(err, ErrUnknownStream) {
		t.Fatalf("unknown stream read = %v", err)
	}
}

func TestTruncatedFrameIsUnexpectedEOF(t *testing.T) {
	scratch := make([]byte, MaxPayload)
	for _, input := range []string{"0100", "0100000005686570"} {
		raw, _ := hex.DecodeString(input)
		if _, _, err := Read(bytes.NewReader(raw), scratch); !errors.Is(err, io.ErrUnexpectedEOF) {
			t.Fatalf("%s: err = %v, want io.ErrUnexpectedEOF", input, err)
		}
	}
}

func TestReadNeedsAFullBuffer(t *testing.T) {
	if _, _, err := Read(bytes.NewReader(nil), make([]byte, 8)); err == nil {
		t.Fatal("a short buffer was accepted")
	}
}
