// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package shell

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"
)

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
		if m.RetryAfter == 0 {
			// rate_limited and unavailable say when in Retry-After.
			m.RetryAfter, _ = strconv.Atoi(resp.Header.Get("Retry-After"))
		}
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
