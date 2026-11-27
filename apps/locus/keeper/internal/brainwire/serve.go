// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package brainwire

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

// Fatal ends the driver with a status: the protocol was broken (2), or the
// harness ended or could not run (its status, or 1). Its reason goes to
// the driver's standard error, never to the wire, since it may carry a
// system's words, a path or the program's own; the wire is told only its
// Why, in an `ending` event, which the holder words for the person. Only
// Fail makes one, and it takes a Why, so no end goes unworded.
type Fatal interface {
	error
	ending() *ending
}

type ending struct {
	status int
	why    Why
	reason string
}

func (e *ending) Error() string   { return e.reason }
func (e *ending) ending() *ending { return e }

// Fail ends the driver with `status`, the holder told `why` and the
// driver's standard error `reason` ("" for none: one said there already).
func Fail(status int, why Why, reason string) Fatal {
	if why.code == "" {
		panic("brainwire: an end with no Why")
	}
	return &ending{status, why, reason}
}

// Why is what a driver's end says the person reads, as the wire's
// `ending` names it: one of the Whys below and no other, since only this
// package makes one. Each is the driver's own finding, never the
// program's words.
type Why struct{ code string }

var (
	// WhyUnanswered: the program did not answer its start, or CYFR's
	// tools did not reach it, within the driver's bound.
	WhyUnanswered = Why{"unanswered"}
	// WhyServersUnlisted: the program did not list its MCP servers, so no
	// name for CYFR's could be chosen beside the person's own.
	WhyServersUnlisted = Why{"servers_unlisted"}
	// WhyRefused: the program refused to start its server or a session.
	WhyRefused = Why{"refused"}
	// WhyOutdated: the program's version is older than the first the
	// driver drives.
	WhyOutdated = Why{"outdated"}
	// WhyUnsupported: the program named no version the driver reads, another
	// protocol, or lacks what the driver needs to go on with a session.
	WhyUnsupported = Why{"unsupported"}
	// WhyEnded: the program's process ended, or no longer took its input.
	WhyEnded = Why{"ended"}
	// WhyUnrunnable: the program could not be run, or the driver could not
	// make what it runs in.
	WhyUnrunnable = Why{"unrunnable"}
	// WhyUnreadable: the program answered in a way the driver cannot use:
	// a line past its bound, or a start that names no session it can.
	WhyUnreadable = Why{"unreadable"}
	// WhyUnfit: the program does not take the model, effort or access the
	// work chose for it.
	WhyUnfit = Why{"unfit"}
	// WhyTooManyTools: the start's tools are past what the program takes
	// whole, as its driver measures them.
	WhyTooManyTools = Why{"too_many_tools"}
	// WhyBroken: the driver and its holder did not read each other: a
	// command the wire does not read or does not allow, or an output that
	// could not be written.
	WhyBroken = Why{"broken"}
)

// Whys are the codes an `ending` may name, in the wire's order.
var Whys = []Why{WhyUnanswered, WhyServersUnlisted, WhyRefused, WhyOutdated, WhyUnsupported,
	WhyEnded, WhyUnrunnable, WhyUnreadable, WhyUnfit, WhyTooManyTools, WhyBroken}

func whyCodes() []string {
	codes := make([]string, len(Whys))
	for i, w := range Whys {
		codes[i] = w.code
	}
	return codes
}

// Conn is a driver's side of the wire: the holder's events go out on it.
type Conn struct {
	name   string
	out    io.Writer
	ErrOut io.Writer
	// Boot is this driver process's, fresh for each.
	Boot string
}

// NewConn writes the wire's events to out, for the driver `name`.
func NewConn(name string, out, errOut io.Writer) *Conn {
	return &Conn{name: name, out: out, ErrOut: errOut, Boot: RandomHex(16)}
}

// Emit writes one event, once it reads as the wire's.
func (c *Conn) Emit(e *Event) error {
	line, err := EncodeEvent(e)
	if err != nil {
		return Fail(1, WhyBroken, err.Error())
	}
	if _, err := c.out.Write(append(line, '\n')); err != nil {
		return Fail(1, WhyBroken, "its output: "+err.Error())
	}
	return nil
}

// TextCutNote ends a text cut to fit one line of the wire.
const TextCutNote = "…[CYFR cut this text to fit one line of the wire.]"

// QuestionsDeclined is what a harness's model reads when a driver declines
// its harness's own question tool: in CYFR a question is the brain's
// reply, and the person's answer comes as a later message.
const QuestionsDeclined = "CYFR does not take this tool's questions. Ask the person in your reply instead, " +
	"in words, with the choices as a short list, and end your turn. The answer is the person's own message, " +
	"or, in a job Aqua handed you, the person's answer as Aqua hands it on."

// EmitText writes an event carrying text as its member `name`, cut to fit
// one line when it would not, with a note saying so.
func (c *Conn) EmitText(e *Event, name, text string) error {
	full := *e
	full.members = append(append([]member{}, e.members...), member{name, text})
	if line, err := EncodeEvent(&full); err == nil && len(line) < MaxLineBytes {
		return c.Emit(&full)
	}
	room := MaxLineBytes/2 - len(TextCutNote)
	cut := []rune(text)
	for len(string(cut)) > room {
		cut = cut[:len(cut)*3/4]
	}
	return c.Emit(e.Set(name, string(cut)+TextCutNote))
}

// Refuse answers the command `id`: it was not written, for `reason`.
func (c *Conn) Refuse(id, reason string) error {
	return c.Emit(NewEvent("refused").Set("id", id).Set("reason", reason))
}

// RefuseSignedOut refuses the command `id` for `reason`, saying that the
// harness's own account answer was signed out.
func (c *Conn) RefuseSignedOut(id, reason string) error {
	return c.Emit(NewEvent("refused").Set("id", id).Set("reason", reason).Set("account", SignedOut))
}

// Accept answers the command `id`: the harness took it.
func (c *Conn) Accept(id string) error { return c.Emit(NewEvent("accepted").Set("id", id)) }

// Later answers the post `id`: it was not written, since the harness takes
// a message only between its native turns, and it is still the holder's,
// which writes it again once the native turn's `idle` has come.
func (c *Conn) Later(id string) error { return c.Emit(NewEvent("later").Set("id", id)) }

// Driver is one harness's side of a driver: Serve hands it each command
// the wire read and each line of its harness's.
type Driver interface {
	// Command handles one command, `t` with its members as read.
	Command(t string, members map[string]json.RawMessage) error
	// Process is the harness process running now, or nil.
	Process() *Process
	// Line handles one line of the running process's output; nil is one
	// past its bound.
	Line(line []byte) error
	// Ended handles the running process's end.
	Ended() error
	// Close closes the harness, if one runs.
	Close()
	// Deadline is when an answer the driver waits on from its harness is
	// overdue, or nil when it waits on none; Expired handles its passing.
	Deadline() <-chan time.Time
	Expired() error
	// Inbox carries what the driver's own goroutines hand the loop (a
	// harness's call of CYFR's tools through its socket, cmd/cyfr-acp),
	// each run in the loop as a command is, or nil for none.
	Inbox() <-chan func() error
}

// Serve speaks the wire on in and c's output until in ends, the harness
// ends, or stop, each time closing the harness first, and answers the
// status the driver ends with. Its first line is `hello`.
func Serve(c *Conn, d Driver, in io.Reader, stop <-chan os.Signal) int {
	if err := c.Emit(NewEvent("hello").Set("v", Version).Set("driver", c.name).Set("boot", c.Boot)); err != nil {
		return 1
	}
	commands := make(chan []byte)
	go readLines(in, MaxLineBytes, commands)
	for {
		var lines chan []byte
		var exited chan struct{}
		if p := d.Process(); p != nil {
			lines, exited = p.Lines, p.Done
		}
		var err error
		select {
		case line, ok := <-commands:
			if !ok {
				d.Close()
				return 0
			}
			err = command(d, line)
		case line := <-lines:
			err = d.Line(line)
		case <-exited:
			err = d.Ended()
		case <-d.Deadline():
			err = d.Expired()
		case handed := <-d.Inbox():
			err = handed()
		case <-stop:
			d.Close()
			return 0
		}
		var fatal Fatal
		if errors.As(err, &fatal) {
			end := fatal.ending()
			if end.reason != "" {
				fmt.Fprintf(c.ErrOut, "%s: %s\n", c.name, end.reason)
			}
			// The holder reads the end's Why before the process ends, and
			// before its harness is closed, however long that takes; an
			// output that no longer takes it ends the driver the same.
			_ = c.Emit(NewEvent("ending").Set("why", end.why.code))
			d.Close()
			return end.status
		}
	}
}

// Usage ends a driver run with no harness it can drive, saying how it is
// run: on a terminal that alone, and off one as every end, `unrunnable`.
func Usage(name, usage string) int {
	if isTerminal(int(os.Stdin.Fd())) {
		fmt.Fprintln(os.Stderr, usage)
		return 2
	}
	return Unserved(NewConn(name, os.Stdout, os.Stderr), Fail(2, WhyUnrunnable, usage))
}

// Unserved ends a driver that cannot serve the wire at all, as Serve ends
// one: its hello, then its ending, its reason on standard error alone.
func Unserved(c *Conn, end Fatal) int {
	e := end.ending()
	if e.reason != "" {
		fmt.Fprintf(c.ErrOut, "%s: %s\n", c.name, e.reason)
	}
	if err := c.Emit(NewEvent("hello").Set("v", Version).Set("driver", c.name).Set("boot", c.Boot)); err == nil {
		_ = c.Emit(NewEvent("ending").Set("why", e.why.code))
	}
	return e.status
}

func command(d Driver, line []byte) error {
	if line == nil {
		return Fail(2, WhyBroken, "a command past the wire's bound")
	}
	t, members, err := ReadLine(line, Commands)
	if err != nil {
		return Fail(2, WhyBroken, fmt.Sprintf("a command the wire does not read (%v)", err))
	}
	return d.Command(t, members)
}

// Main runs a driver as its command: `args` is the harness's own command.
// On a terminal it runs that command unchanged, in its place, so the
// person signs in to the harness on the same row; otherwise it serves the
// wire on standard input and output until either ends, a hangup or a
// TERM.
func Main(name string, args []string, newDriver func(command []string, c *Conn, home string) Driver) int {
	if len(args) == 0 {
		return Usage(name, fmt.Sprintf("usage: %s HARNESS [ARG]...", name))
	}
	if isTerminal(int(os.Stdin.Fd())) {
		return runUnchanged(name, args)
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return Unserved(NewConn(name, os.Stdout, os.Stderr), Fail(1, WhyUnrunnable, "no home: "+err.Error()))
	}
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, unix.SIGTERM, unix.SIGHUP)
	c := NewConn(name, os.Stdout, os.Stderr)
	return Serve(c, newDriver(args, c, home), os.Stdin, stop)
}

func isTerminal(fd int) bool {
	_, err := unix.IoctlGetTermios(fd, unix.TCGETS)
	return err == nil
}

// runUnchanged replaces the driver with the harness's command, as it was
// given, so the terminal is the harness's.
func runUnchanged(name string, command []string) int {
	path, err := exec.LookPath(command[0])
	if err != nil {
		fmt.Fprintf(os.Stderr, "%s: %v\n", name, err)
		return 127
	}
	err = syscall.Exec(path, command, os.Environ())
	fmt.Fprintf(os.Stderr, "%s: %v\n", name, err)
	if errors.Is(err, syscall.ENOENT) {
		return 127
	}
	return 126
}
