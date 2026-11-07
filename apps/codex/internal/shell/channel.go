// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package shell

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/coder/websocket"
	"github.com/cyfr/codex/internal/account"
)

// The device channel's message protocol (tests/fixtures/device.json) and
// the certificates a CYFR issues its devices (device_cert.json).
const (
	DeviceProtocol      = "cyfr-device/v1"
	CertificateProtocol = "cyfr-device-cert/v2"
)

// reportEvery is how often an open channel reports this box's
// capabilities, as the home's standing check reads its client every 30
// seconds; heardWithin bounds each report's write and the ping sent
// after it, so a connection the network silently drops ends the channel
// at the next report instead of standing until the kernel gives up on
// its retransmissions. Both are variables for the tests.
// They are atomics because a test sets them while an earlier test's
// channel may still be reporting.
var (
	reportEvery = durationVar(30 * time.Second)
	heardWithin = durationVar(10 * time.Second)
	// readerFirst is how long a failed report or ping waits for the
	// reader to record a close the home sent (4403, 4408), which the
	// failure may have raced, before it records the silence itself.
	readerFirst = durationVar(2 * time.Second)
)

// A duration read by a channel's goroutines and set by a test.
type duration struct{ atomic.Int64 }

func durationVar(d time.Duration) *duration {
	v := &duration{}
	v.Store(int64(d))
	return v
}

func (d *duration) Get() time.Duration  { return time.Duration(d.Load()) }
func (d *duration) Set(v time.Duration) { d.Store(int64(v)) }

// The reasons a channel ends, each a sentence the lock page can show.
var (
	// ErrRevoked is a client whose standing ended (close 4403, or a
	// revoke naming no grant).
	ErrRevoked = errors.New("CYFR does not take this device any more")
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
// certificate and proven by the key; renewed receives every certificate
// the home issues, to persist before it is used. report is this box's
// capability list, sent once the channel stands and every 30 seconds
// after.
func (d Dialer) Open(ctx context.Context, device Device, key Signer, report func() []string, renewed func(json.RawMessage)) (*Channel, error) {
	c, err := d.open(ctx, device, key, report, renewed, func(c *Channel, ctx context.Context) error { return c.handshake(ctx, "connect") })
	if errors.Is(err, ErrRenew) {
		c, err = d.open(ctx, device, key, report, renewed, func(c *Channel, ctx context.Context) error { return c.handshake(ctx, "renew") })
	}
	return c, err
}

// Hello is a device's first connection to a CYFR (Prima.Device's hello):
// the key it holds (its public half), the account whose log lists it, the
// holder that keeps it, the name the CYFR lists it by and, for a new
// person, the capability that admits them ({"setup": token} or
// {"invitation": code}).
type Hello struct {
	Key         []byte
	Identifier  string
	HolderKind  string
	DisplayName string
	Admission   map[string]any
}

// Admitted is the CYFR's answer to a hello: the client it admitted this
// key as and the first certificate it connects under.
type Admitted struct {
	ClientID    string
	Athanor     string
	Certificate json.RawMessage
}

// Hello opens a first connection: the hello, the CYFR's sign_in request
// held to this home and purpose, its digest signed by key (the device's
// answer), then the admission, which admitted persists before anything
// else; then on the same connection the connect, its challenge and proof,
// and the standing, as Open's.
func (d Dialer) Hello(ctx context.Context, h Hello, key Signer, admitted func(Admitted) error, report func() []string, renewed func(json.RawMessage)) (*Channel, error) {
	device := Device{Binding: Binding{Home: d.Address, DeviceKey: h.Key}}
	return d.open(ctx, device, key, report, renewed, func(c *Channel, ctx context.Context) error {
		got, err := c.hello(ctx, h)
		if err != nil {
			return err
		}
		if err := admitted(got); err != nil {
			return err
		}
		c.device.Athanor, c.device.ClientID, c.device.Certificate = got.Athanor, got.ClientID, got.Certificate
		return c.handshake(ctx, "connect")
	})
}

func (d Dialer) open(ctx context.Context, device Device, key Signer, report func() []string, renewed func(json.RawMessage), first func(*Channel, context.Context) error) (*Channel, error) {
	dialCtx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	conn, _, err := websocket.Dial(dialCtx, d.url(), &websocket.DialOptions{HTTPClient: d.Client})
	if err != nil {
		return nil, fmt.Errorf("%w (%v)", ErrUnavailable, err)
	}
	conn.SetReadLimit(1 << 20)
	c := &Channel{conn: conn, device: device, key: key, report: report, renewed: renewed,
		waiting: map[string]chan answer{}, done: make(chan struct{})}
	if err := first(c, dialCtx); err != nil {
		conn.CloseNow()
		return nil, err
	}
	go c.read()
	go c.reportLoop()
	return c, nil
}

// hello sends the hello, answers the CYFR's sign_in request and reads its
// admission: a client and a certificate for exactly this key and account
// at this CYFR. Anything else is refused before it is kept.
func (c *Channel) hello(ctx context.Context, h Hello) (Admitted, error) {
	kid := account.Kid(h.Key)
	if err := c.send(ctx, h.message()); err != nil {
		return Admitted{}, err
	}
	for {
		got, err := c.recv(ctx)
		if err != nil {
			return Admitted{}, err
		}
		switch got.Type {
		case "sign_in_request":
			r, err := account.ReadRequest(got.Request)
			if err != nil || r.Purpose != "sign_in" || r.Audience != c.device.Home {
				return Admitted{}, fmt.Errorf("%w: CYFR asked to sign something other than this device's sign-in here", ErrRefusedChallenge)
			}
			answer, err := r.Answer(kid, c.key.Sign)
			if err != nil {
				return Admitted{}, err
			}
			if err := c.send(ctx, map[string]any{"type": "sign_in_answer", "answer": answer}); err != nil {
				return Admitted{}, err
			}
		case "admitted":
			return admittedHere(got, h, c.device.Home)
		case "refused":
			// The CYFR's sentence for a refused hello or answer, sent
			// right before it closes; one malformed is left to the close.
			if r, ok := readRefused(got.raw); ok {
				return Admitted{}, r
			}
		case "revoke":
			return Admitted{}, ErrRevoked
		}
	}
}

// RefusedError is a CYFR's refusal of a hello or of its sign-in answer,
// told before it closes (Prima.Device's refused): its class and the
// sentence a person reads.
type RefusedError struct{ Class, Message string }

func (e *RefusedError) Error() string { return e.Message }

// readRefused reads a refused message: exactly its protocol, type and
// error, the error exactly a non-empty class and message.
func readRefused(raw []byte) (*RefusedError, bool) {
	var m map[string]json.RawMessage
	if json.Unmarshal(raw, &m) != nil || len(m) != 3 ||
		string(m["protocol"]) != `"`+DeviceProtocol+`"` || string(m["type"]) != `"refused"` {
		return nil, false
	}
	var e map[string]any
	if json.Unmarshal(m["error"], &e) != nil || len(e) != 2 {
		return nil, false
	}
	class, _ := e["class"].(string)
	sentence, _ := e["message"].(string)
	if class == "" || sentence == "" {
		return nil, false
	}
	return &RefusedError{Class: class, Message: sentence}, true
}

// message is the hello as the channel sends it, but its protocol.
func (h Hello) message() map[string]any {
	m := map[string]any{"type": "hello", "kid": account.Kid(h.Key), "identifier": h.Identifier,
		"holder_kind": h.HolderKind, "display_name": h.DisplayName}
	if h.Admission != nil {
		m["admission"] = h.Admission
	}
	return m
}

// admittedHere reads an admission: its client and the certificate this
// CYFR issued for that client, this key and this account, at this CYFR.
func admittedHere(m message, h Hello, home string) (Admitted, error) {
	var cert struct {
		Protocol   string `json:"protocol"`
		Kid        string `json:"kid"`
		ClientID   string `json:"client_id"`
		Identifier string `json:"identifier"`
		Athanor    string `json:"athanor"`
		Audience   string `json:"audience"`
		ExpiresAt  int64  `json:"expires_at"`
	}
	if json.Unmarshal(m.Certificate, &cert) != nil || cert.Protocol != CertificateProtocol || cert.Kid != account.Kid(h.Key) ||
		cert.Identifier != h.Identifier || cert.Audience != home || cert.ClientID != m.ClientID ||
		!strings.HasPrefix(cert.ClientID, "pcl_") || !strings.HasPrefix(cert.Athanor, "ath_") || cert.ExpiresAt == 0 {
		return Admitted{}, fmt.Errorf("%w: the certificate is not for this device at this CYFR", ErrRefused)
	}
	return Admitted{ClientID: cert.ClientID, Athanor: cert.Athanor, Certificate: m.Certificate}, nil
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
			ch, err := Challenge(m.Challenge, asked, c.device.Binding)
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
	ClientID    string          `json:"client_id"`
	Challenge   json.RawMessage `json:"challenge"`
	Certificate json.RawMessage `json:"certificate"`
	Request     any             `json:"request"`
	Result      json.RawMessage `json:"result"`
	Error       json.RawMessage `json:"error"`
	raw         []byte
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
	m.raw = raw
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
	t := time.NewTicker(reportEvery.Get())
	defer t.Stop()
	for {
		select {
		case <-c.done:
			return
		case <-t.C:
			ctx, cancel := context.WithTimeout(context.Background(), heardWithin.Get())
			err := c.send(ctx, c.capabilities())
			if err == nil {
				err = c.conn.Ping(ctx)
			}
			cancel()
			if err != nil {
				select {
				case <-c.done:
				case <-time.After(readerFirst.Get()):
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
		ch, err := Challenge(raw, "renew", c.device.Binding)
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
