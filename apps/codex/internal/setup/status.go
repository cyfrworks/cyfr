// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package setup

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// Status is whether setup is still open, as the application running on
// this machine answers POST /api/setup/status. Its wire is
// Prima.SetupStatus, held to tests/fixtures/setup_status.json.
type Status string

const (
	// StatusOpen is an application whose setup the token opens.
	StatusOpen Status = "open"
	// StatusClosed is every other answer about setup: it is done, or the
	// token is not this application's.
	StatusClosed Status = "closed"
	// StatusUnavailable is an application whose store cannot answer, which
	// says nothing about whether setup is open.
	StatusUnavailable Status = "unavailable"
)

const (
	statusPath    = "/api/setup/status"
	statusRequest = `{"version":1}`
	statusVersion = 1
	statusTimeout = 5 * time.Second
	// A longer answer is none of the wire's.
	statusMaxAnswer = 4096
)

// ErrUpdateRequired is an application older than the route, whose setup
// cannot be read: neither .env nor its setup token says.
var ErrUpdateRequired = errors.New("this CYFR cannot say whether setup is open. Run `cyfr update`")

// ReadStatus asks the application at base, its loopback address, whether
// setup is open, under the setup token. Any answer that is not the wire's
// is an error, so nothing is read as closed that did not say so. The token
// travels in the request's Authorization header alone, to base alone: no
// redirect is followed and no proxy used.
func ReadStatus(ctx context.Context, base, token string) (Status, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimRight(base, "/")+statusPath, strings.NewReader(statusRequest))
	if err != nil {
		return "", fmt.Errorf("asking whether setup is open: %w", err)
	}
	request.Header.Set("Authorization", "Bearer "+token)
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("Accept", "application/json")

	client := &http.Client{
		Timeout:       statusTimeout,
		Transport:     &http.Transport{DisableKeepAlives: true},
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
	response, err := client.Do(request)
	if err != nil {
		return "", fmt.Errorf("asking whether setup is open: %w", err)
	}
	defer response.Body.Close()

	if response.StatusCode == http.StatusNotFound {
		return "", ErrUpdateRequired
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, statusMaxAnswer+1))
	if err != nil {
		return "", fmt.Errorf("reading whether setup is open: %w", err)
	}
	status, ok := parseStatus(response.StatusCode, body)
	if !ok {
		return "", fmt.Errorf("the setup status route answered %d, not whether setup is open", response.StatusCode)
	}
	return status, nil
}

// parseStatus reads the wire's answer: open or closed at 200, unavailable
// at 503, and exactly its two fields.
func parseStatus(code int, body []byte) (Status, bool) {
	if len(body) > statusMaxAnswer {
		return "", false
	}
	var answer struct {
		Version int    `json:"version"`
		State   Status `json:"state"`
	}
	decoder := json.NewDecoder(bytes.NewReader(body))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&answer) != nil || decoder.More() || answer.Version != statusVersion {
		return "", false
	}
	switch {
	case code == http.StatusOK && (answer.State == StatusOpen || answer.State == StatusClosed):
		return answer.State, true
	case code == http.StatusServiceUnavailable && answer.State == StatusUnavailable:
		return answer.State, true
	}
	return "", false
}
