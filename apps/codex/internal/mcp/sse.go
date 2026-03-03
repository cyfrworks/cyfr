package mcp

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"sync/atomic"
	"time"
)

// SSEEvent represents a parsed Server-Sent Event containing an MCP message.
type SSEEvent struct {
	ID   string
	Data json.RawMessage
}

// EventStream represents an open SSE connection to the MCP server.
type EventStream struct {
	Events <-chan SSEEvent
	Errors <-chan error

	// RetryInterval holds the server-suggested reconnect interval.
	// Updated atomically when the server sends a retry: field.
	retryMs atomic.Int64

	cancel context.CancelFunc
	resp   *http.Response
}

// RetryInterval returns the server-suggested reconnect interval,
// or the provided default if the server hasn't sent one.
func (s *EventStream) RetryInterval(defaultInterval time.Duration) time.Duration {
	ms := s.retryMs.Load()
	if ms > 0 {
		return time.Duration(ms) * time.Millisecond
	}
	return defaultInterval
}

// Close terminates the SSE stream.
func (s *EventStream) Close() {
	s.cancel()
	if s.resp != nil {
		s.resp.Body.Close()
	}
}

// OpenStream opens an SSE stream via GET /mcp for receiving server-initiated
// notifications and requests. Per MCP 2025-11-25 spec, this allows the server
// to push messages like notifications/tools/list_changed to the client.
//
// The optional lastEventID enables resumption after reconnection.
// Returns an EventStream with channels for events and errors.
func (c *Client) OpenStream(lastEventID string) (*EventStream, error) {
	if c.SessionID == "" {
		return nil, ErrSessionRequired
	}

	ctx, cancel := context.WithCancel(context.Background())

	req, err := http.NewRequestWithContext(ctx, "GET", c.BaseURL+"/mcp", nil)
	if err != nil {
		cancel()
		return nil, fmt.Errorf("create SSE request: %w", err)
	}

	req.Header.Set("Accept", "text/event-stream")
	req.Header.Set("MCP-Protocol-Version", protocolVersion)
	req.Header.Set("MCP-Session-Id", c.SessionID)
	if lastEventID != "" {
		req.Header.Set("Last-Event-ID", lastEventID)
	}

	resp, err := c.httpClient.Do(req)
	if err != nil {
		cancel()
		return nil, fmt.Errorf("open SSE stream: %w", err)
	}

	if resp.StatusCode == http.StatusMethodNotAllowed {
		resp.Body.Close()
		cancel()
		return nil, fmt.Errorf("server does not support SSE streaming (HTTP 405)")
	}

	if resp.StatusCode == http.StatusNotFound {
		resp.Body.Close()
		cancel()
		return nil, ErrSessionExpired
	}

	if resp.StatusCode != http.StatusOK {
		resp.Body.Close()
		cancel()
		return nil, fmt.Errorf("SSE stream HTTP %d", resp.StatusCode)
	}

	events := make(chan SSEEvent, 16)
	errs := make(chan error, 1)

	stream := &EventStream{
		Events: events,
		Errors: errs,
		cancel: cancel,
		resp:   resp,
	}

	go parseSSEStream(ctx, resp, events, errs, &stream.retryMs)

	return stream, nil
}

// parseSSEStream reads SSE events from the HTTP response body and sends
// parsed events to the channel. Runs until the context is cancelled or
// the connection is closed.
func parseSSEStream(ctx context.Context, resp *http.Response, events chan<- SSEEvent, errs chan<- error, retryMs *atomic.Int64) {
	defer close(events)
	defer close(errs)

	scanner := bufio.NewScanner(resp.Body)
	var currentID string
	var dataLines []string

	for scanner.Scan() {
		if ctx.Err() != nil {
			return
		}

		line := scanner.Text()

		switch {
		case line == "":
			// Empty line = end of event
			if len(dataLines) > 0 {
				data := strings.Join(dataLines, "\n")
				// Skip empty data fields (priming events)
				if strings.TrimSpace(data) != "" {
					events <- SSEEvent{
						ID:   currentID,
						Data: json.RawMessage(data),
					}
				}
			}
			currentID = ""
			dataLines = nil

		case strings.HasPrefix(line, "id:"):
			currentID = strings.TrimSpace(strings.TrimPrefix(line, "id:"))

		case strings.HasPrefix(line, "data:"):
			dataLines = append(dataLines, strings.TrimPrefix(line, "data:"))

		case strings.HasPrefix(line, "event:"):
			// We only handle "message" events per MCP spec; ignore the field name

		case strings.HasPrefix(line, "retry:"):
			if ms, err := strconv.ParseInt(strings.TrimSpace(strings.TrimPrefix(line, "retry:")), 10, 64); err == nil && ms >= 0 {
				retryMs.Store(ms)
			}

		case strings.HasPrefix(line, ":"):
			// Comment (e.g., keep-alive); ignore
		}
	}

	if err := scanner.Err(); err != nil && ctx.Err() == nil {
		errs <- fmt.Errorf("SSE stream read: %w", err)
	}
}
