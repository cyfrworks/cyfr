// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package reach

import (
	"context"
	"errors"
	"io"
	"os"
	"time"
)

// errNotBuilt marks the engine API before its implementation lands.
var errNotBuilt = errors.New("reach: the engine is not built yet")

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

// Engine owns how one project's home is reached: the reach keys of its
// .env, the stack's reach services, and the state under .cyfr/.
type Engine struct {
	dir    string
	docker Docker
	lock   *os.File
}

// Open opens the engine of the project at projectDir, running docker
// through d, or through the system implementation when d is nil. It
// refuses a .env that sets any COMPOSE_* key (compose_env_refused) before
// anything else reads it.
func Open(projectDir string, d Docker) (*Engine, error) { return nil, errNotBuilt }

// ErrBusy is the lock's refusal while another holder has it: the holder
// record it wrote (command, host or container, pid in its namespace, start
// time), the watchdog's pid when a docker child of a dead holder still
// holds it, and the time that child's deadline ends. Its Refusal is
// reach_busy.
type ErrBusy struct {
	Holder      string
	WatchdogPID int
	Until       time.Time
}

func (e *ErrBusy) Error() string { return "reach: " + e.Refusal().Error() }

// Refusal is the lock's refusal as the CLI prints it.
func (e *ErrBusy) Refusal() *Refusal { return nil }

// Lock takes the project's kernel lock on .cyfr/lock without waiting and
// durably writes the holder record, naming holder (the command). It
// answers the function that releases it, or *ErrBusy. Every method below
// but Status, Preview and Receipt requires the lock held by this engine.
func (e *Engine) Lock(holder string) (unlock func(), err error) { return nil, errNotBuilt }

// Docker is the engine's docker runner, for a command that holds the lock
// and makes docker calls of its own (update's snapshot and pulls,
// restore's copies): each call keeps the lock as the engine's own do.
func (e *Engine) Docker() Docker { return e.docker }

// ComposeArgs answers the arguments, after `docker`, of a compose command
// for head h: `compose -p <project> -f .cyfr/compose.resolved.<digest>.yml
// --project-directory . --profile <each of h.Profiles>`, then args. The
// configuration of h is materialized and validated on first use within
// the operation (`docker compose config` over the default file set, with
// the sanitized environment and h's selection), and every later call runs
// on that file.
func (e *Engine) ComposeArgs(ctx context.Context, h Head, args ...string) ([]string, error) {
	return nil, errNotBuilt
}

// Head is the head .env holds now, or the boot refusal that says why it
// holds none (ResolveBoot with .env's own read, Release true).
func (e *Engine) Head() (Head, error) { return Head{}, errNotBuilt }

// CheckStack checks what `docker compose config` resolves for the stack
// before anything starts: no reach key is assigned in the cyfr service's
// own environment: entries in any file of the source set (the main file,
// its override, every include: and extends:), .env reaches cyfr through
// its env_file, and the effective values pass ResolveBoot with .env's own
// read as File and the flattened environment as Process.
func (e *Engine) CheckStack(ctx context.Context) error { return errNotBuilt }

// Receipt is an operation's answer: rejected (Code says why, nothing
// changed), accepted in Phase (in progress; "uncertain" is still unfinished
// and resumable with `cyfr reach --resume`), completed with Outcome (ok,
// rolled_back, not_applied or failed), or unknown (no journal and no
// receipt holds the id).
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
	Observed      []string          `json:"observed,omitempty"`
	At            time.Time         `json:"at"`
}

// Refusal is the code a receipt answers with, nil for a plain success.
func (r Receipt) Refusal() *Refusal { return nil }

// Resume runs recovery under the lock: an unfinished operation in
// journal.json is stopped and verified, then finished by comparing .env's
// head with its two heads; a join container past its deadline is removed
// and its attempt expired; an accepted cancel is completed. It answers the
// receipts recovery wrote, none when nothing was unfinished.
func (e *Engine) Resume(ctx context.Context) ([]Receipt, error) { return nil, errNotBuilt }

// Container is one container of the project, as docker reports it by the
// project's compose label.
type Container struct {
	Service string
	Name    string
	State   string
}

// Status is what `cyfr reach status` shows: .env's head or why it has
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
func (e *Engine) Status(ctx context.Context) (Status, error) { return Status{}, errNotBuilt }

// Preview is a change shown before it is made: both complete heads, their
// digests and words, and what stops working when the address changes.
type Preview struct {
	Old, New             Head
	OldDigest, NewDigest string
	OldWords, NewWords   Words
	AddressChanges       []string
}

// Preview derives the head target t makes, for tailnet from the join
// joinID completed, and shows it against .env's. It reads without the lock.
// It refuses as Derive does, with reach_unchanged when both heads are the
// same, and with tailnet_active when t asks to join while the head's node
// is serving.
func (e *Engine) Preview(ctx context.Context, t Target, joinID string) (Preview, error) {
	return Preview{}, errNotBuilt
}

// SwitchRequest is a switch: its request id, the target, the join whose
// frozen name and id a tailnet head takes, and both digests the preview
// showed, which the fence recomputes (reach_stale, tailnet_name_changed).
type SwitchRequest struct {
	ID        string
	Target    Target
	JoinID    string
	OldDigest string
	NewDigest string
}

// Switch moves the home to the request's head: stop and verify, commit
// .env, start what was running with node validation and health, roll back
// on a failed start. The receipt is its outcome; resending the same id
// answers the same receipt.
func (e *Engine) Switch(ctx context.Context, r SwitchRequest) (Receipt, error) {
	return Receipt{}, errNotBuilt
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
	return Receipt{}, errNotBuilt
}

// CancelRequest cancels the waiting join JoinID.
type CancelRequest struct {
	ID     string
	JoinID string
}

// CancelJoin cancels the current waiting join; any other answers
// tailnet_join_not_current.
func (e *Engine) CancelJoin(ctx context.Context, r CancelRequest) (Receipt, error) {
	return Receipt{}, errNotBuilt
}

// CancelWaitingJoin cancels whatever join waits, for update and restore
// before they stop the stack.
func (e *Engine) CancelWaitingJoin(ctx context.Context) error { return errNotBuilt }

// ForgetJoin removes join.json, for restore after its recovery: the
// snapshot's head names its own node.
func (e *Engine) ForgetJoin() error { return errNotBuilt }

// Start is the one start path (up, update, restore; cause names it): it
// checks the stack (CheckStack), writes Serve's empty configuration,
// starts cyfr and the head's reach services, validates a tailnet node
// against the head before Serve opens (tailnet_node_mismatch leaves Serve
// closed and cyfr running), and waits for cyfr's health.
func (e *Engine) Start(ctx context.Context, cause string) (Receipt, error) {
	return Receipt{}, errNotBuilt
}

// Stop stops and verifies cyfr and every reach service of .env's head and
// of any unfinished operation's heads, writing Serve's empty configuration
// first; with all, it takes every service of the project down (`cyfr
// down`). A stop that cannot be verified answers reach_uncertain with what
// was observed.
func (e *Engine) Stop(ctx context.Context, cause string, all bool) (Receipt, error) {
	return Receipt{}, errNotBuilt
}

// Receipt answers the receipt or the unfinished journal entry of request
// id, reading without the lock.
func (e *Engine) Receipt(id string) (Receipt, bool, error) { return Receipt{}, false, errNotBuilt }

// WatchdogMain is `cyfr internal docker-run`: it runs the docker command
// its arguments name, holding the lock descriptor it inherited, and kills
// it at the deadline its arguments name. It answers the process's exit
// status.
func WatchdogMain(args []string, stdin io.Reader, stdout, stderr io.Writer) int { return 2 }
