// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package access

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"maps"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// The deadlines of the engine's own docker calls. The watchdog kills a call
// at its deadline, so an orphaned call holds the lock no longer than this.
const (
	StopDeadline   = 60 * time.Second
	StartDeadline  = 120 * time.Second
	HealthDeadline = 180 * time.Second
)

// Call is one docker command: its arguments after `docker`, the deadline
// the watchdog holds it to, and its standard streams. A nil Stdout or
// Stderr is captured into the Result.
type Call struct {
	Args     []string
	Deadline time.Duration
	Stdin    io.Reader
	Stdout   io.Writer
	Stderr   io.Writer
}

// Result is a finished call: its exit status and whatever it wrote to a
// stream the Call left nil.
type Result struct {
	ExitCode int
	Stdout   []byte
	Stderr   []byte
}

// Docker is every docker call the engine and the commands holding its lock
// make. The system implementation runs each call with every COMPOSE_*
// variable removed from the environment and DOCKER_* kept, in a process
// group of its own, and, while the lock is held, passes the lock's
// descriptor to a watchdog re-exec of cyfr (`cyfr internal docker-run`)
// that kills the call at its deadline (Unix), or starts it in the
// kill-on-close Job Object (Windows). Tests substitute a fake that injects
// a failure at any step.
type Docker interface {
	Run(ctx context.Context, c Call) (Result, error)
}

// Engine owns how one project's home is reached: the access keys of its
// .env, the stack's access services, and the state under .cyfr/. What an
// exported method answers, and every receipt and journal it writes,
// passes the redactor (redact.go) last.
type Engine struct {
	dir    string
	docker Docker
	lock   *os.File

	project string
	// mu guards lock, holder and files, which a docker call reads while
	// another goroutine of the same command may run one.
	mu     sync.Mutex
	holder holderRecord
	// watchdogs are the running docker children's watchdogs and their
	// deadlines, which the holder record names.
	watchdogs map[int]time.Time
	// files are the materialized configurations this engine wrote and
	// has not removed, relative to the project directory, each with what
	// it was made from.
	files map[string]materialized

	// Test seams: the clock, a write's failure at one of its steps, and a
	// named point of an operation.
	clock     clock
	failWrite func(name, step string) error
	hook      func(point string)
}

// Open opens the engine of the project at projectDir, running docker
// through d, or through the system implementation when d is nil. A .env
// compose cannot read, or one that sets any COMPOSE_* key, does not keep
// it from opening, so recovery can still stop the stack; Start, Switch,
// Join and CancelJoin refuse it (compose_env_refused, naming the line or
// the key) before any docker call, and Resume stops and verifies without
// compose, then refuses it.
func Open(projectDir string, d Docker) (*Engine, error) {
	dir, err := filepath.Abs(projectDir)
	if err != nil {
		return nil, fmt.Errorf("access: %w", err)
	}
	e := &Engine{dir: dir, project: projectName(dir), files: map[string]materialized{}}
	if e.project == "" {
		return nil, e.redactor().err(fmt.Errorf("access: %s has no name docker compose can take as its project's", dir))
	}
	e.docker = d
	if d == nil {
		e.docker = newSystemDocker(e)
	}
	return e, nil
}

// ErrBusy is the lock's refusal while another holder has it: the holder
// record it wrote (command, host or container, start time) and the
// holder's pid in its namespace, PID; while a docker child runs, the
// watchdog's pid that holds the lock for it, even past a dead holder,
// and the time that child's deadline ends. Its Refusal is access_busy.
type ErrBusy struct {
	Holder      string
	PID         int
	WatchdogPID int
	Until       time.Time
}

func (e *ErrBusy) Error() string { return "access: " + e.Refusal().Error() }

// Refusal is the lock's refusal as the CLI prints it.
func (e *ErrBusy) Refusal() *Refusal { return e.refusal() }

// Lock takes the project's kernel lock on .cyfr/lock without waiting and
// durably writes the holder record, naming holder (the command). It
// answers the function that releases it, or *ErrBusy. Every method below
// but Status, Preview and Receipt requires the lock held by this engine.
func (e *Engine) Lock(holder string) (unlock func(), err error) {
	unlock, err = e.lockProject(holder)
	return unlock, e.redactor().err(err)
}

// Docker is the engine's docker runner, for a command that holds the lock
// and makes docker calls of its own (update's snapshot and pulls,
// restore's copies): each call keeps the lock as the engine's own do.
// What such a call writes, and what the command says of it, passes the
// engine's redaction (Redactor) before the command prints or returns it.
func (e *Engine) Docker() Docker { return e.docker }

// ComposeArgs answers the arguments, after `docker`, of a compose command
// for head h: `compose -p <project> -f .cyfr/compose.resolved.<digest>.yml
// --project-directory . --profile <each of h.Profiles>`, then args. The
// configuration of h is materialized and validated on first use within
// the operation (`docker compose config` over the default file set, with
// the sanitized environment and h's selection), and every later call runs
// on that file.
func (e *Engine) ComposeArgs(ctx context.Context, h Head, args ...string) ([]string, error) {
	if err := e.requireLock(); err != nil {
		return nil, err
	}
	out, err := e.composeArgsFor(ctx, h, args...)
	return out, e.redactor().err(err)
}

// Head is the head .env holds now, or the boot refusal that says why it
// holds none (ResolveBoot with .env's own read, Release true).
func (e *Engine) Head() (Head, error) {
	h, err := e.envHead()
	return h, e.redactor().err(err)
}

// CheckStack checks what `docker compose config` resolves for the stack
// before anything starts: in any file of the source set (the main file,
// its override, every include: and extends:) no service's environment:
// names a variable with `$` (compose_override_refused, the name as
// written) and no access key is assigned in the cyfr service's own, .env
// reaches cyfr through its env_file, and the effective values, which the
// sources' check does not read, pass ResolveBoot with .env's own
// read as File and the flattened environment as Process.
func (e *Engine) CheckStack(ctx context.Context) error { return e.redactor().err(e.checkStack(ctx)) }

// Receipt is an operation's answer: rejected (Code says why, nothing
// changed), accepted in Phase (in progress; "uncertain" is still unfinished
// and resumable with `cyfr access --resume`), completed with Outcome (ok,
// rolled_back, not_applied, failed, or started_local: cyfr running and
// healthy with Serve closed, Code saying why, tailnet_node_mismatch for
// a machine that is not the head's), or unknown (no journal and no
// receipt holds the id). A join's Payload names its join_id.
type Receipt struct {
	RequestID     string            `json:"request_id"`
	RequestDigest string            `json:"request_digest"`
	Op            string            `json:"op"`
	State         string            `json:"state"`
	Phase         string            `json:"phase,omitempty"`
	Outcome       string            `json:"outcome,omitempty"`
	Code          string            `json:"code,omitempty"`
	Payload       map[string]string `json:"payload,omitempty"`
	FinalHead     *Head             `json:"final_head,omitempty"`
	// ContentDigest binds a switch's receipt to the whole of what its
	// command was asked (RequestContent), for Resent.
	ContentDigest string    `json:"content_digest,omitempty"`
	Observed      []string  `json:"observed,omitempty"`
	At            time.Time `json:"at"`
}

// Refusal is the code a receipt answers with, nil for a plain success. A
// join's join_id names the attempt, not a part of its sentence.
func (r Receipt) Refusal() *Refusal {
	if r.Code == "" {
		return nil
	}
	payload := maps.Clone(r.Payload)
	delete(payload, "join_id")
	return Refuse(r.Code, payload)
}

// Resume runs recovery under the lock: an unfinished operation in
// journal.json is stopped and verified, then finished by comparing .env's
// head with its two heads; a join container past its deadline is removed
// and its attempt expired; an accepted cancel is completed. It answers the
// receipts recovery wrote, none when nothing was unfinished.
func (e *Engine) Resume(ctx context.Context) ([]Receipt, error) {
	before := e.redactor()
	out, err := e.resume(ctx)
	r := before.with(e.redactor())
	return r.receipts(out), r.err(err)
}

// Container is one container of the project, as docker reports it by the
// project's compose label.
type Container struct {
	Service string
	Name    string
	State   string
}

// Status is what `cyfr access status` shows: .env's head or why it has
// none, its words, the project's containers, an unfinished operation, the
// latest receipt, and the health of the mode's proxy.
type Status struct {
	Head       Head
	HeadErr    error
	Words      Words
	Containers []Container
	Unfinished *Receipt
	Last       *Receipt
	Health     []string
}

// Status reads without the lock and changes nothing.
func (e *Engine) Status(ctx context.Context) (Status, error) {
	s, err := e.status(ctx)
	r := e.redactor()
	return r.status(s), r.err(err)
}

// Preview is a change shown before it is made: both complete heads, their
// digests and words, and what stops working when the address changes.
type Preview struct {
	Old, New             Head
	OldDigest, NewDigest string
	OldWords, NewWords   Words
	AddressChanges       []string
	// Reopen is a tailnet head that is .env's already, its Serve closed
	// (the machine was not ready when it started): Old and New are one
	// head, and the switch validates the machine again and opens Serve.
	Reopen bool
}

// Preview derives the head target t makes, for tailnet from the machine
// the join joinID froze, or with no join id from the machine this home
// has (the running tailscale service's, else the latest completed join's;
// tailnet_not_joined when it has none), and shows it against .env's. It
// reads without the lock. It refuses as Derive does, with access_unchanged
// when both heads are the same, and with tailnet_active when t asks for
// tailnet while the head's node is serving.
func (e *Engine) Preview(ctx context.Context, t Target, joinID string) (Preview, error) {
	p, err := e.preview(ctx, t, joinID)
	return p, e.redactor().err(err)
}

// SwitchRequest is a switch: its request id, the target, the join whose
// frozen name and id a tailnet head takes (none: the machine this home
// has, as Preview), and both digests the preview showed, which the fence
// recomputes (access_stale, tailnet_name_changed).
type SwitchRequest struct {
	ID        string
	Target    Target
	JoinID    string
	OldDigest string
	NewDigest string
	// Content is everything the command was asked, which a resend of its
	// id must ask again, to Switch as to Resent.
	Content RequestContent
}

// RequestContent is the whole of what a `cyfr access` command was asked:
// the mode, the domain and email, and for tailnet the machine name,
// --new-node and the auth key's fingerprint (AuthKeyFingerprint, "" with
// no key). A request id is bound to it whatever the outcome.
type RequestContent struct {
	Mode, Domain, ACMEEmail, Hostname string
	NewNode                           bool
	AuthKeyFingerprint                string
}

// Resent answers a request id sent again, reading without the lock: its
// receipt, or its unfinished journal's answer, when c is the content it
// was first sent with; a rejected access_request_reused receipt when it is
// not, which changes and writes nothing; false for an id neither holds.
func (e *Engine) Resent(id string, c RequestContent) (Receipt, bool, error) {
	rc, ok, err := e.resent(id, c)
	r := e.redactor()
	return r.receipt(rc), ok, r.err(err)
}

// AuthKeyFingerprint is an auth key's fingerprint as a request binds it:
// sha256: and the hex of the key's bytes, surrounding space removed; ""
// for no key. The key itself is never stored.
func AuthKeyFingerprint(key []byte) string {
	key = bytes.TrimSpace(key)
	if len(key) == 0 {
		return ""
	}
	return "sha256:" + sha256Hex(key)
}

// Switch moves the home to the request's head: stop and verify, commit
// .env, start what was running with node validation and health, roll back
// on a failed start. The receipt is its outcome; resending the same id
// with the same request, its content included, answers the same receipt,
// and with any other a rejected access_request_reused that changes nothing.
// A reopen (Preview.Reopen) is ok only if, once Serve is open, cyfr runs
// and Serve's configuration is the head's: a home that stopped before the
// switch was accepted is access_stale, and one that stopped, or whose
// Serve changed, after Serve opened has Serve closed again and is
// not_applied with access_stale; neither starts anything more.
func (e *Engine) Switch(ctx context.Context, r SwitchRequest) (Receipt, error) {
	before := e.redactor()
	rc, err := e.doSwitch(ctx, r)
	return e.leaving(before, rc, err)
}

// JoinRequest is a tailnet join: its request id, the machine name asked
// for (cyfr when empty), whether the machine's tailnet identity is
// replaced first (--new-node), the auth key when one was given (the CLI
// alone holds one; only its SHA-256 fingerprint enters the request
// digest), and where the approval link is reported while the join waits.
type JoinRequest struct {
	ID        string
	Hostname  string
	NewNode   bool
	AuthKey   io.Reader
	OnAuthURL func(url string)
}

// Join enrolls this machine in a tailnet through a join container that
// ends at its own deadline, and blocks until the attempt ends: joined (the
// receipt's payload names the frozen name, node id and join id),
// tailnet_https_off, tailnet_join_expired or tailnet_join_cancelled.
func (e *Engine) Join(ctx context.Context, r JoinRequest) (Receipt, error) {
	before := e.redactor()
	rc, err := e.doJoin(ctx, r)
	return e.leaving(before, rc, err)
}

// CancelRequest cancels the waiting join JoinID.
type CancelRequest struct {
	ID     string
	JoinID string
}

// CancelJoin cancels the current waiting join; any other answers
// tailnet_join_not_current.
func (e *Engine) CancelJoin(ctx context.Context, r CancelRequest) (Receipt, error) {
	before := e.redactor()
	rc, err := e.doCancelJoin(ctx, r)
	return e.leaving(before, rc, err)
}

// CancelWaitingJoin cancels whatever join waits, for update and restore
// before they stop the stack.
func (e *Engine) CancelWaitingJoin(ctx context.Context) error {
	return e.redactor().err(e.cancelWaitingJoin(ctx))
}

// ForgetJoin removes join.json, for restore after its recovery: the
// snapshot's head names its own node.
func (e *Engine) ForgetJoin() error { return e.redactor().err(e.forgetJoin()) }

// Start is the one start path (up, update, restore; cause names it): it
// checks the stack (CheckStack), writes Serve's empty configuration,
// removes, verified, any running access service the head does not select,
// starts cyfr and the head's access services, waits HealthDeadline for
// cyfr's health, and validates a tailnet node against the head before
// Serve opens: a node that cannot serve the head (tailnet_node_mismatch,
// tailnet_not_joined, tailnet_https_off) leaves Serve closed and cyfr
// running, Outcome started_local. While a join waits for its approval it
// refuses with access_busy; update and restore cancel the join first
// (CancelWaitingJoin).
func (e *Engine) Start(ctx context.Context, cause string) (Receipt, error) {
	return e.StartWithin(ctx, cause, HealthDeadline)
}

// StartWithin is Start with its own wait for cyfr's health, for a start
// that may take longer, as an update's migrations do.
func (e *Engine) StartWithin(ctx context.Context, cause string, health time.Duration) (Receipt, error) {
	before := e.redactor()
	rc, err := e.doStart(ctx, cause, health)
	return e.leaving(before, rc, err)
}

// Stop cancels a waiting join, then stops and verifies cyfr and every
// service of every access mode's profile, whatever .env's head or an
// unfinished operation says, writing Serve's empty configuration first;
// with all, it takes every service of the project down (`cyfr down`). A
// stop that cannot be verified answers access_uncertain with what was
// observed.
func (e *Engine) Stop(ctx context.Context, cause string, all bool) (Receipt, error) {
	before := e.redactor()
	rc, err := e.doStop(ctx, cause, all)
	return e.leaving(before, rc, err)
}

// CloseServe writes Serve's empty configuration durably, as every stop
// path does first, for a command that stops the stack itself (update's
// and restore's own stops). It requires the lock.
func (e *Engine) CloseServe(ctx context.Context) error {
	if err := e.requireLock(); err != nil {
		return err
	}
	return e.redactor().err(e.closeServe())
}

// Receipt answers the receipt or the unfinished journal entry of request
// id, reading without the lock.
func (e *Engine) Receipt(id string) (Receipt, bool, error) {
	rc, ok, err := e.receiptOf(id)
	r := e.redactor()
	return r.receipt(rc), ok, r.err(err)
}

// leaving is an operation's answer as it leaves the engine, redacted
// (redactor) with what .env held before the operation and holds after
// it, so a value an operation wrote, or one it replaced, is redacted
// alike.
func (e *Engine) leaving(before *redactor, rc Receipt, err error) (Receipt, error) {
	r := before.with(e.redactor())
	return r.receipt(rc), r.err(err)
}

// WatchdogMain is `cyfr internal docker-run`: it runs the docker command
// its arguments name, holding the lock descriptor it inherited, and kills
// it at the deadline its arguments name. It answers the process's exit
// status.
func WatchdogMain(args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	return watchdogMain(args, stdin, stdout, stderr)
}

// lockFile is the lock's descriptor while this engine holds it.
func (e *Engine) lockFile() *os.File {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.lock
}
