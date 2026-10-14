// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package mcp

import (
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"testing"
)

// The shared vectors bind this client to Prima's MCP codec, which reads the
// same file: the revision and _meta keys a request declares, the routing
// headers it carries, the header sentinel, and the consent errors a server
// answers.
type wireVectors struct {
	ProtocolVersion string            `json:"protocol_version"`
	Supported       []string          `json:"supported"`
	Meta            map[string]string `json:"meta"`
	HeaderValues    []struct {
		Why    string `json:"why"`
		Value  string `json:"value"`
		Header string `json:"header"`
	} `json:"header_values"`
	NamedSubject []struct {
		Why     string `json:"why"`
		Request struct {
			Method string         `json:"method"`
			Params map[string]any `json:"params"`
		} `json:"request"`
		Headers map[string]*string `json:"headers"`
	} `json:"named_subject"`
	ErrorCodes struct {
		CYFR map[string]int `json:"cyfr"`
	} `json:"error_codes"`
	ConsentTags   []string `json:"consent_tags"`
	ConsentErrors []struct {
		Why          string          `json:"why"`
		Tag          string          `json:"tag"`
		DataStripped bool            `json:"data_stripped"`
		Response     json.RawMessage `json:"response"`
	} `json:"consent_errors"`
}

func readWireVectors(t *testing.T) wireVectors {
	t.Helper()

	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "..", "tests", "fixtures", "mcp_wire.json"))
	if err != nil {
		t.Fatalf("read shared fixture: %v", err)
	}

	var vectors wireVectors
	if err := json.Unmarshal(raw, &vectors); err != nil {
		t.Fatalf("decode shared fixture: %v", err)
	}
	if vectors.ProtocolVersion == "" || len(vectors.HeaderValues) == 0 || len(vectors.NamedSubject) == 0 ||
		len(vectors.ConsentErrors) == 0 {
		t.Fatalf("the fixture carries no MCP wire vectors: %+v", vectors)
	}
	return vectors
}

func TestWireVectors_RevisionAndMeta(t *testing.T) {
	vectors := readWireVectors(t)

	if protocolVersion != vectors.ProtocolVersion {
		t.Errorf("protocol version: Go %q, the vector says %q", protocolVersion, vectors.ProtocolVersion)
	}
	if !slices.Contains(vectors.Supported, protocolVersion) {
		t.Errorf("the vectors' server supports %v, not the client's %q", vectors.Supported, protocolVersion)
	}

	meta, ok := withMeta(map[string]any{"name": "weather.get"}, "", "")["_meta"].(map[string]any)
	if !ok {
		t.Fatal("a request carries no _meta object")
	}

	want := []string{vectors.Meta["protocol_version"], vectors.Meta["client_info"], vectors.Meta["client_capabilities"]}
	got := make([]string, 0, len(meta))
	for key := range meta {
		got = append(got, key)
	}
	slices.Sort(want)
	slices.Sort(got)
	if !slices.Equal(got, want) {
		t.Errorf("_meta keys: Go %v, the vectors say %v", got, want)
	}
	if meta[vectors.Meta["protocol_version"]] != vectors.ProtocolVersion {
		t.Errorf("_meta declares %v, the vector says %q", meta[vectors.Meta["protocol_version"]], vectors.ProtocolVersion)
	}
}

func TestWireVectors_HeaderValues(t *testing.T) {
	for _, c := range readWireVectors(t).HeaderValues {
		if got := encodeHeaderValue(c.Value); got != c.Header {
			t.Errorf("%s: encodeHeaderValue(%q) = %q, the vector says %q", c.Why, c.Value, got, c.Header)
		}
	}
}

func TestWireVectors_RoutingHeaders(t *testing.T) {
	for _, c := range readWireVectors(t).NamedSubject {
		req, err := http.NewRequest(http.MethodPost, "http://cyfr.test/mcp", nil)
		if err != nil {
			t.Fatal(err)
		}
		routingHeaders(req, c.Request.Method, c.Request.Params)

		for _, name := range []string{"Mcp-Method", "Mcp-Name"} {
			want, ok := c.Headers[name]
			if !ok {
				t.Fatalf("%s: the vector names no %s", c.Why, name)
			}
			got := req.Header.Values(name)

			switch {
			case want == nil && len(got) != 0:
				t.Errorf("%s: %s = %q, the vector says none", c.Why, name, got)
			case want != nil && !slices.Equal(got, []string{*want}):
				t.Errorf("%s: %s = %q, the vector says %q", c.Why, name, got, *want)
			}
		}
	}
}

func TestWireVectors_ConsentAndAuthCodes(t *testing.T) {
	vectors := readWireVectors(t)

	if len(consentTagByCode) != len(vectors.ConsentTags) {
		t.Errorf("Go knows %d consent codes, the vectors %d", len(consentTagByCode), len(vectors.ConsentTags))
	}
	for _, tag := range vectors.ConsentTags {
		code, ok := vectors.ErrorCodes.CYFR[tag]
		if !ok {
			t.Fatalf("the vectors give %s no code", tag)
		}
		if consentTagByCode[code] != tag {
			t.Errorf("code %d: Go reads tag %q, the vector says %q", code, consentTagByCode[code], tag)
		}
	}

	auth := rpcError(&JSONRPCError{Code: vectors.ErrorCodes.CYFR["auth_required"], Message: "sign in"})
	if !errors.Is(auth, ErrAuthRequired) {
		t.Errorf("code %d reads as %v, not ErrAuthRequired", vectors.ErrorCodes.CYFR["auth_required"], auth)
	}
}

func TestWireVectors_ConsentErrors(t *testing.T) {
	for _, c := range readWireVectors(t).ConsentErrors {
		var want struct {
			ID    any `json:"id"`
			Error struct {
				Message string `json:"message"`
				Data    *struct {
					Tag     string         `json:"tag"`
					Payload map[string]any `json:"payload"`
				} `json:"data"`
			} `json:"error"`
		}
		if err := json.Unmarshal(c.Response, &want); err != nil {
			t.Fatalf("%s: decode the vector's response: %v", c.Why, err)
		}

		var resp JSONRPCResponse
		if err := json.Unmarshal(c.Response, &resp); err != nil {
			t.Fatalf("%s: the client cannot read the response: %v", c.Why, err)
		}
		if resp.Error == nil || resp.Result != nil {
			t.Fatalf("%s: read as %+v, not an error response", c.Why, resp)
		}
		if !reflect.DeepEqual(resp.ID, want.ID) {
			t.Errorf("%s: id %v, the vector says %v", c.Why, resp.ID, want.ID)
		}

		var consent *ConsentError
		if !errors.As(rpcError(resp.Error), &consent) {
			t.Fatalf("%s: read as %v, not a consent error", c.Why, rpcError(resp.Error))
		}
		if consent.Tag != c.Tag {
			t.Errorf("%s: tag %q, the vector says %q", c.Why, consent.Tag, c.Tag)
		}
		if consent.Message != want.Error.Message {
			t.Errorf("%s: message %q, the vector says %q", c.Why, consent.Message, want.Error.Message)
		}

		switch {
		case c.DataStripped && (want.Error.Data != nil || consent.Payload != nil):
			t.Errorf("%s: a stripped error reads a payload %v", c.Why, consent.Payload)
		case !c.DataStripped && want.Error.Data == nil:
			t.Fatalf("%s: the vector carries no data", c.Why)
		case !c.DataStripped && !reflect.DeepEqual(consent.Payload, want.Error.Data.Payload):
			t.Errorf("%s: payload %v, the vector says %v", c.Why, consent.Payload, want.Error.Data.Payload)
		}
	}
}
