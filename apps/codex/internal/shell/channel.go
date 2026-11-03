// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package shell

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"
)

// DeviceProtocol is the device channel's message protocol
// (tests/fixtures/device.json).
const DeviceProtocol = "cyfr-device/v1"

// reportEvery is how often an open channel reports this box's
// capabilities, as the home's standing check reads its client every 30
// seconds; heardWithin bounds each report's write and the ping sent
// after it, so a connection the network silently drops ends the channel
// at the next report instead of standing until the kernel gives up on
// its retransmissions. Both are variables for the tests.
var (
	reportEvery = 30 * time.Second
	heardWithin = 10 * time.Second
	// readerFirst is how long a failed report or ping waits for the
	// reader to record a close the home sent (4403, 4408), which the
	// failure may have raced, before it records the silence itself.
	readerFirst = 2 * time.Second
)

// The reasons a channel ends, each a sentence the lock page can show.
var (
	// ErrRevoked is a client whose standing ended (close 4403, or a
	// revoke naming no grant).
	ErrRevoked = errors.New("This screen's pairing was revoked")
	// ErrRenew is a certificate the home will not take any more (4408):
	// the channel renews it first.
	ErrRenew = errors.New("this screen's certificate must be renewed")
	// ErrUnavailable is a home that could not be reached or check the
	// connection now (1013, a network failure): nothing is retried with
	// the PIN; the person tries again.
	ErrUnavailable = errors.New("CYFR could not be reached")
	// ErrRefused is a proof the home refused (4401) or a frame it refused
	// (4400).
	ErrRefused = errors.New("CYFR refused this screen's proof")
)

// Device is what a certified device presents on its channel.
type Device struct {
	Binding
	Certificate json.RawMessage
}

// Channel is one certified device channel: the raw WebSocket at
// /device/websocket carrying one cyfr-device/v1 message per text frame.
// It exists only while the box is unlocked; its close ends every session
// it holds, at the home.
type Channel struct {
	conn    *websocket.Conn
	device  Device
	key     Signer
	report  func() []string
	renewed func(json.RawMessage)

	mu      sync.Mutex
	next    int
	waiting map[string]chan answer
	renew   chan json.RawMessage // a renewal's challenge, while one is asked
	ended   error
	done    chan struct{}
}

type answer struct {
	Result json.RawMessage `json:"result"`
	Error  json.RawMessage `json:"error"`
}

// IntentError is a home's refusal of one intent, the channel staying open.
type IntentError struct{ Raw json.RawMessage }

func (e *IntentError) Error() string {
	var m struct {
		Class   string `json:"class"`
		Tag     string `json:"tag"`
		Message string `json:"message"`
	}
	_ = json.Unmarshal(e.Raw, &m)
	switch {
	case m.Message != "":
		return m.Message
	case m.Tag != "":
		return "CYFR refused it: " + m.Tag
	case m.Class != "":
		return "CYFR refused it: " + m.Class
	}
	return "CYFR refused it"
}

// class is the refusal's class, which every refusal on the channel
// carries (with its sentence) where it carries no reason: "unavailable"
// for a home or a cyfr.run that did not answer.
func (e *IntentError) class() string {
	var m struct {
		Class string `json:"class"`
	}
	_ = json.Unmarshal(e.Raw, &m)
	return m.Class
}

// says is whether the refusal names one of reasons, as its tag, reason
// or code.
func (e *IntentError) says(reasons ...string) bool {
	var m map[string]any
	_ = json.Unmarshal(e.Raw, &m)
	for _, k := range []string{"tag", "reason", "code", "error"} {
		if v, ok := m[k].(string); ok && slices.Contains(reasons, v) {
			return true
		}
	}
	return false
}

// Dialer opens the home's device channel: its address and the HTTP client
// (with the tailnet's proxy when the home is reached through it).
type Dialer struct {
	Address string
	Client  *http.Client
}

func (d Dialer) url() string {
	u := strings.TrimRight(d.Address, "/") + "/device/websocket"
	if rest, ok := strings.CutPrefix(u, "https://"); ok {
		return "wss://" + rest
	}
	return "ws://" + strings.TrimPrefix(u, "http://")
}

// Open connects as device under key: connect, the home's connect challenge
// checked and signed, then its standing. A certificate the home will not
// take (4408) is renewed first on a new connection, located by the old
// certificate and proven by the key the home stores; renewed receives
// every certificate the home issues, to persist before it is used.
// report is this box's capability list, sent once the channel stands and
// every 30 seconds after.
func (d Dialer) Open(ctx context.Context, device Device, key Signer, report func() []string, renewed func(json.RawMessage)) (*Channel, error) {
	c, err := d.open(ctx, device, key, report, renewed, "connect")
	if errors.Is(err, ErrRenew) {
		c, err = d.open(ctx, device, key, report, renewed, "renew")
	}
	return c, err
}

func (d Dialer) open(ctx context.Context, device Device, key Signer, report func() []string, renewed func(json.RawMessage), asked string) (*Channel, error) {
	dialCtx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	conn, _, err := websocket.Dial(dialCtx, d.url(), &websocket.DialOptions{HTTPClient: d.Client})
	if err != nil {
		return nil, fmt.Errorf("%w (%v)", ErrUnavailable, err)
	}
	conn.SetReadLimit(1 << 20)
	c := &Channel{conn: conn, device: device, key: key, report: report, renewed: renewed,
		waiting: map[string]chan answer{}, done: make(chan struct{})}
	if err := c.handshake(dialCtx, asked); err != nil {
		conn.CloseNow()
		return nil, err
	}
	go c.read()
	go c.reportLoop()
	return c, nil
}

// handshake is the connection's one proof: connect (or renew), the
// challenge for that purpose, the proof, then certificate (on a renewal)
// and standing.
func (c *Channel) handshake(ctx context.Context, asked string) error {
	if err := c.send(ctx, map[string]any{"type": asked, "client_id": c.device.ClientID, "certificate": c.device.Certificate}); err != nil {
		return err
	}
	for {
		m, err := c.recv(ctx)
		if err != nil {
			return err
		}
		switch m.Type {
		case "challenge":
			ch, err := Challenge(m.Challenge, asked, c.device.Binding, nil)
			if err != nil {
				return err
			}
			proof, err := Prove(ch, c.key)
			if err != nil {
				return err
			}
			if err := c.send(ctx, map[string]any{"type": "proof", "proof": proof}); err != nil {
				return err
			}
		case "certificate":
			c.newCertificate(m.Certificate)
		case "standing":
			return c.send(ctx, c.capabilities())
		case "revoke":
			return ErrRevoked
		}
	}
}

func (c *Channel) newCertificate(cert json.RawMessage) {
	c.device.Certificate = cert
	if c.renewed != nil {
		c.renewed(cert)
	}
}

func (c *Channel) capabilities() map[string]any {
	return map[string]any{"type": "capabilities", "capabilities": c.report()}
}

type message struct {
	Type        string          `json:"type"`
	ID          string          `json:"id"`
	GrantID     string          `json:"grant_id"`
	Challenge   json.RawMessage `json:"challenge"`
	Certificate json.RawMessage `json:"certificate"`
	Result      json.RawMessage `json:"result"`
	Error       json.RawMessage `json:"error"`
}

func (c *Channel) send(ctx context.Context, m map[string]any) error {
	m["protocol"] = DeviceProtocol
	raw, err := json.Marshal(m)
	if err != nil {
		return err
	}
	if err := c.conn.Write(ctx, websocket.MessageText, raw); err != nil {
		return closeReason(err)
	}
	return nil
}

func (c *Channel) recv(ctx context.Context) (message, error) {
	var m message
	typ, raw, err := c.conn.Read(ctx)
	if err != nil {
		return m, closeReason(err)
	}
	if typ != websocket.MessageText || json.Unmarshal(raw, &m) != nil {
		return m, fmt.Errorf("%w: a frame that is not a device message", ErrRefused)
	}
	return m, nil
}

// closeReason maps the home's close code to why the channel ended.
func closeReason(err error) error {
	switch websocket.CloseStatus(err) {
	case 4403:
		return ErrRevoked
	case 4408:
		return ErrRenew
	case 4400, 4401:
		return ErrRefused
	}
	return fmt.Errorf("%w (%v)", ErrUnavailable, err)
}

// read delivers answers to their intents and renewals until the channel
// ends.
func (c *Channel) read() {
	for {
		m, err := c.recv(context.Background())
		if err != nil {
			c.end(err)
			return
		}
		switch m.Type {
		case "answer":
			c.mu.Lock()
			w := c.waiting[m.ID]
			delete(c.waiting, m.ID)
			c.mu.Unlock()
			if w != nil {
				w <- answer{m.Result, m.Error}
			}
		case "challenge":
			c.mu.Lock()
			r := c.renew
			c.mu.Unlock()
			if r != nil {
				r <- m.Challenge
			}
		case "certificate":
			c.newCertificate(m.Certificate)
		case "revoke":
			if m.GrantID == "" {
				c.end(ErrRevoked)
				c.conn.CloseNow()
				return
			}
		}
	}
}

// reportLoop reports this box's capabilities every reportEvery and pings
// the home after each report: a report the connection does not take or a
// ping the home does not answer within heardWithin ends the channel as
// unreachable, which locks the box (Shell.watch). A close the home sent
// is the reader's to record, so a failure here first waits readerFirst
// for the reader to end the channel with the home's code; only a
// connection that stays silent is ended here.
func (c *Channel) reportLoop() {
	t := time.NewTicker(reportEvery)
	defer t.Stop()
	for {
		select {
		case <-c.done:
			return
		case <-t.C:
			ctx, cancel := context.WithTimeout(context.Background(), heardWithin)
			err := c.send(ctx, c.capabilities())
			if err == nil {
				err = c.conn.Ping(ctx)
			}
			cancel()
			if err != nil {
				select {
				case <-c.done:
				case <-time.After(readerFirst):
					c.end(closeReason(err))
					c.conn.CloseNow()
				}
				return
			}
		}
	}
}

func (c *Channel) end(err error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.ended != nil {
		return
	}
	c.ended = err
	close(c.done)
	for id, w := range c.waiting {
		close(w)
		delete(c.waiting, id)
	}
}

// Done is closed when the channel ends; Err then says why.
func (c *Channel) Done() <-chan struct{} { return c.done }

// Err is why the channel ended, nil while it is open.
func (c *Channel) Err() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.ended
}

// Call sends one intent and waits for its answer: the result, an
// *IntentError for a refusal, or why the channel ended.
func (c *Channel) Call(ctx context.Context, operation string, args map[string]any) (json.RawMessage, error) {
	c.mu.Lock()
	if c.ended != nil {
		err := c.ended
		c.mu.Unlock()
		return nil, err
	}
	c.next++
	id := "int_" + strconv.Itoa(c.next)
	w := make(chan answer, 1)
	c.waiting[id] = w
	c.mu.Unlock()
	if args == nil {
		args = map[string]any{}
	}
	if err := c.send(ctx, map[string]any{"type": "intent", "id": id, "operation": operation, "args": args}); err != nil {
		return nil, err
	}
	select {
	case a, ok := <-w:
		if !ok {
			return nil, c.Err()
		}
		if len(a.Error) > 0 && string(a.Error) != "null" {
			return nil, &IntentError{a.Error}
		}
		return a.Result, nil
	case <-ctx.Done():
		c.mu.Lock()
		delete(c.waiting, id)
		c.mu.Unlock()
		return nil, ctx.Err()
	}
}

// Renew renews the certificate over the open channel: renew, the renewal
// challenge checked and signed, then the home's certificate.
func (c *Channel) Renew(ctx context.Context) error {
	r := make(chan json.RawMessage, 1)
	c.mu.Lock()
	c.renew = r
	c.mu.Unlock()
	defer func() { c.mu.Lock(); c.renew = nil; c.mu.Unlock() }()
	if err := c.send(ctx, map[string]any{"type": "renew", "client_id": c.device.ClientID}); err != nil {
		return err
	}
	select {
	case raw := <-r:
		ch, err := Challenge(raw, "renew", c.device.Binding, nil)
		if err != nil {
			return err
		}
		proof, err := Prove(ch, c.key)
		if err != nil {
			return err
		}
		return c.send(ctx, map[string]any{"type": "proof", "proof": proof})
	case <-c.done:
		return c.Err()
	case <-ctx.Done():
		return ctx.Err()
	}
}

// Close ends the channel, and with it every session it holds at the home.
func (c *Channel) Close() {
	c.end(errors.New("locked"))
	_ = c.conn.Close(websocket.StatusNormalClosure, "")
}
