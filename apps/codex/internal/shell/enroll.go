// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package shell

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/cookiejar"
	"strconv"
	"strings"
	"time"
)

// Enrolled is what an admitted enrollment answers: the certificate the
// home issued this box's key, and, for a setup, the person's recovery code
// until it is said saved.
type Enrolled struct {
	Certificate json.RawMessage `json:"certificate"`
	Recovery    *Recovery       `json:"recovery"`
}

// Recovery is the identity recovery code a setup shows once.
type Recovery struct {
	AttemptID  string `json:"attempt_id"`
	Code       string `json:"code"`
	Identifier string `json:"identifier"`
	Name       string `json:"name"`
}

// HomeError is the home's refusal of an HTTP entry: its status and code.
type HomeError struct {
	Status     int
	Code       string
	RetryAfter int
}

func (e *HomeError) Error() string {
	if e.Code != "" {
		return "CYFR refused it (" + e.Code + ")"
	}
	return "CYFR refused it (HTTP " + strconv.Itoa(e.Status) + ")"
}

// Holder is what an enrollment reports of this box's key: its request, the
// holder that keeps it and the name Devices lists it by (at most 64 bytes),
// information the home shows and decides nothing by.
type Holder struct {
	RequestID   string
	Kind        string
	DisplayName string
}

// Admission is how an enrollment is admitted: the setup token for the
// installation's first person, or a restore session for a restored one.
// Its credentials travel in headers alone (and a restore's session in its
// cookie), never in a URL or a body.
type Admission struct {
	Kind   string // "setup" or "restore"
	Client *http.Client
	// header is the credential of the enrollment's entries; resume is the
	// one its resume takes.
	header, resume http.Header
	// reprove, when set, gives the admission its entries need, asked only
	// once a resume found nothing committed: a finished restore's session
	// is proven again by the recovery code, never before the saved key had
	// its chance to find its committed client.
	reprove func(context.Context) (Admission, error)
}

// SetupAdmission admits the first person under the installation's setup
// token, in X-Cyfr-Setup-Token on every entry, resume included.
func SetupAdmission(client *http.Client, token string) Admission {
	h := http.Header{"X-Cyfr-Setup-Token": {token}}
	return Admission{Kind: "setup", Client: client, header: h, resume: h}
}

// Restore restores the person whose recovery code this is onto this empty
// installation (POST /restore, the installation's restore token as its
// bearer), and answers the admission its restore session carries: that
// session's cookie, held in this process alone, admits the enrollment, and
// the restore token resumes it.
func Restore(ctx context.Context, client *http.Client, address, token, code string) (Admission, error) {
	jar, _ := cookiejar.New(nil)
	c := *client
	c.Jar = jar
	bearer := http.Header{"Authorization": {"Bearer " + token}}
	a := Admission{Kind: "restore", Client: &c, header: http.Header{}, resume: bearer}
	err := post(ctx, &c, address, "/restore", bearer, map[string]any{"recovery_code": code}, nil)
	var refused *HomeError
	if errors.As(err, &refused) && refused.Code == "restored" {
		// The restore completed in an earlier run whose session this
		// process never held: a reproof gives a new one.
		var ch struct {
			Challenge json.RawMessage `json:"challenge"`
		}
		if err = post(ctx, &c, address, "/restore/challenge", bearer, map[string]any{}, &ch); err == nil {
			err = post(ctx, &c, address, "/restore/reproof", bearer, map[string]any{"recovery_code": code, "challenge": ch.Challenge}, nil)
		}
	}
	return a, err
}

// Enroll enrolls key under a: the home's enroll challenge for this
// admission, key and request, checked and signed, then completed with
// extra (a setup's name and a recovery secret drawn here). A complete
// whose answer is lost is recovered by resume, proving the same key, never
// by enrolling again; resumed says to resume first, for a key a previous
// run may have enrolled.
func Enroll(ctx context.Context, address string, a Admission, b Binding, d Holder, key Signer, extra map[string]any, resumed bool) (Enrolled, error) {
	requestID := d.RequestID
	if resumed {
		got, err := resume(ctx, address, a, b, requestID, key)
		// Only the resume's explicit answer that nothing was committed
		// (404 not_found) leads to a new enrollment, and to a restore's
		// reproof; any other refusal is the resume's own, and sends no
		// recovery code.
		var refused *HomeError
		if err == nil || !errors.As(err, &refused) || refused.Status != http.StatusNotFound || refused.Code != "not_found" {
			return got, err
		}
		if a.reprove != nil {
			if a, err = a.reprove(ctx); err != nil {
				return Enrolled{}, err
			}
		}
	}
	proof, err := enrollProof(ctx, address, "/device/enrollment/challenge", a.header, a, b, requestID, key,
		map[string]any{"holder_kind": d.Kind, "display_name": d.DisplayName})
	if err != nil {
		return Enrolled{}, err
	}
	body := map[string]any{"proof": proof}
	for k, v := range extra {
		body[k] = v
	}
	var got Enrolled
	err = post(ctx, a.Client, address, "/device/enrollment/complete", a.header, body, &got)
	var refused *HomeError
	if err != nil && !errors.As(err, &refused) {
		return resume(ctx, address, a, b, requestID, key)
	}
	return got, err
}

func resume(ctx context.Context, address string, a Admission, b Binding, requestID string, key Signer) (Enrolled, error) {
	proof, err := enrollProof(ctx, address, "/device/enrollment/resume", a.resume, a, b, requestID, key, nil)
	if err != nil {
		return Enrolled{}, err
	}
	var got Enrolled
	err = post(ctx, a.Client, address, "/device/enrollment/resume", a.resume, map[string]any{"proof": proof}, &got)
	return got, err
}

func enrollProof(ctx context.Context, address, path string, h http.Header, a Admission, b Binding, requestID string, key Signer, reported map[string]any) (map[string]any, error) {
	var ch struct {
		Challenge json.RawMessage `json:"challenge"`
	}
	asked := map[string]any{"admission": a.Kind, "device_key": b64(b.DeviceKey), "request_id": requestID}
	for k, v := range reported {
		asked[k] = v
	}
	err := post(ctx, a.Client, address, path, h, asked, &ch)
	if err != nil {
		return nil, err
	}
	c, err := Challenge(ch.Challenge, "enroll", b, Expect{"admission": a.Kind, "request_id": requestID})
	if err != nil {
		return nil, err
	}
	return Prove(c, key)
}

// post sends one JSON request and decodes its JSON answer into out. A
// refusal is a *HomeError; a failure to reach the home is
// ErrUnavailable's.
func post(ctx context.Context, client *http.Client, address, path string, h http.Header, body, out any) error {
	raw, err := json.Marshal(body)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimRight(address, "/")+path, bytes.NewReader(raw))
	if err != nil {
		return err
	}
	for k, v := range h {
		req.Header[k] = v
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")
	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("%w (%v)", ErrUnavailable, err)
	}
	defer resp.Body.Close()
	answer, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return fmt.Errorf("%w (%v)", ErrUnavailable, err)
	}
	if resp.StatusCode != http.StatusOK {
		var m struct {
			Error      string `json:"error"`
			RetryAfter int    `json:"retry_after"`
		}
		_ = json.Unmarshal(answer, &m)
		return &HomeError{Status: resp.StatusCode, Code: m.Error, RetryAfter: m.RetryAfter}
	}
	if out == nil {
		return nil
	}
	if err := json.Unmarshal(answer, out); err != nil {
		return fmt.Errorf("%w (an answer that is not JSON)", ErrUnavailable)
	}
	return nil
}

// RequestID draws an enrollment's request id: req_ and 32 hex digits.
func RequestID() string { return "req_" + hex.EncodeToString(random(16)) }

// RecoverySecret draws a new recovery code's secret: 32 bytes, unpadded
// base64url.
func RecoverySecret() string { return b64(random(32)) }

func random(n int) []byte {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return b
}
