// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

// Command cyfr-browser drives Aqua's browser: a headless Chrome with its
// profile in a kept home. It is the command of a `driven` program row,
// which the backends service runs on a pseudo-terminal under the home's
// uid; its one host, Opus.Browser, speaks framed messages to it over that
// terminal's bytes, and it speaks the Chrome DevTools Protocol to Chrome
// over Chrome's debugging pipe, which never leaves the box. No debugging
// port is ever opened.
//
//	cyfr-browser [--chrome PATH | --source URL] [--chunk BYTES] [--keep-ms MS]
//
// Chrome is not in the image: the driver fetches it into the kept home
// and starts the one there (fetch.go), from Google's list of Chrome for
// Testing's builds, or from the list --source names, which only tests
// pass. --chrome starts the Chrome at PATH and fetches nothing. A home
// that holds no Chrome and cannot fetch one says hello with the error
// that the browser could not be downloaded.
//
// The framing and its messages are defined in
// tests/fixtures/browser_frames.json (its "comment"). The driver puts its
// terminal in raw mode, so frames pass both ways byte for byte, and writes
// nothing to its output but frames. It says `hello` once Chrome answers,
// or `hello` with an error and exits 1 when Chrome cannot start.
//
// Each `req` runs once, in a goroutine of its own. Its response text,
// `{"ok": …}` or `{"error": {"code", "message"}}`, goes out as `res`
// chunks through the one send slot (slot.go), which the host acknowledges
// chunk by chunk and may ask to send again. Chrome exiting ends the driver
// with 1; its input ending, a hangup or a TERM closes Chrome, which then
// writes its profile, and ends it with 0.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

const (
	defaultChunk  = 49152
	defaultKeepMS = 120000
	// startWait bounds Chrome's first answer.
	startWait = 30 * time.Second
	// closeWait bounds Chrome's own shutdown before it is killed.
	closeWait = 5 * time.Second
)

var errChromeExited = errors.New("Chrome exited")

func main() {
	os.Exit(run(os.Args[1:]))
}

func run(args []string) int {
	flags := flag.NewFlagSet("cyfr-browser", flag.ContinueOnError)
	chrome := flags.String("chrome", "", "Chrome's binary, started in place of the home's, fetching nothing")
	source := flags.String("source", defaultSource, "the list of Chrome for Testing's builds the home's Chrome is fetched from")
	chunk := flags.Int("chunk", defaultChunk, "bytes of response text one res frame carries")
	keepMS := flags.Int64("keep-ms", defaultKeepMS, "milliseconds an unacknowledged response is kept")
	if err := flags.Parse(args); err != nil {
		return 2
	}
	if flags.NArg() != 0 || *chunk < 1 || *chunk > maxChunk || *keepMS < 1 || *source == "" {
		fmt.Fprintf(os.Stderr, "usage: cyfr-browser [--chrome PATH | --source URL] [--chunk 1-%d] [--keep-ms MS]\n", maxChunk)
		return 2
	}
	if err := makeRaw(int(os.Stdin.Fd())); err != nil {
		fmt.Fprintln(os.Stderr, "cyfr-browser: its terminal:", err)
		return 1
	}
	s := newSlot(os.Stdout, *chunk, time.Duration(*keepMS)*time.Millisecond)
	hello := helloMessage{T: "hello", V: 1, Chunk: *chunk, KeepMS: *keepMS}
	b := newBrowser()
	path, err := chromePath(*chrome, *source)
	if err != nil {
		hello.Error = notDownloaded
		if !errors.Is(err, errNotDownloaded) {
			hello.Error = "The browser could not start: " + err.Error() + "."
		}
		_ = s.write(hello)
		return 1
	}
	chromium, err := startChrome(path, b)
	if err != nil {
		hello.Error = "The browser could not start: " + err.Error() + "."
		_ = s.write(hello)
		return 1
	}
	defer chromium.close()
	if err := s.write(hello); err != nil {
		return 1
	}
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, unix.SIGTERM, unix.SIGHUP)
	if err := serve(os.Stdin, s, b.do, chromium.exited, stop); err != nil {
		if !errors.Is(err, errChromeExited) {
			fmt.Fprintln(os.Stderr, "cyfr-browser:", err)
		}
		return 1
	}
	return 0
}

// chromePath is the Chrome to start: the one --chrome names, else the
// home's, fetched first when it holds none or a day has passed.
func chromePath(chrome, source string) (string, error) {
	if chrome != "" {
		return chrome, nil
	}
	s, err := newStore(os.Getenv("HOME"), source)
	if err != nil {
		return "", err
	}
	return s.chrome(context.Background(), os.Stderr)
}

// makeRaw sets the terminal on fd as cfmakeraw(3) does: no echo, no line
// editing, no signals, no flow control and no translation either way.
func makeRaw(fd int) error {
	t, err := unix.IoctlGetTermios(fd, unix.TCGETS)
	if err != nil {
		return err
	}
	t.Iflag &^= unix.IGNBRK | unix.BRKINT | unix.PARMRK | unix.ISTRIP | unix.INLCR | unix.IGNCR | unix.ICRNL | unix.IXON
	t.Oflag &^= unix.OPOST
	t.Lflag &^= unix.ECHO | unix.ECHONL | unix.ICANON | unix.ISIG | unix.IEXTEN
	t.Cflag &^= unix.CSIZE | unix.PARENB
	t.Cflag |= unix.CS8
	t.Cc[unix.VMIN], t.Cc[unix.VTIME] = 1, 0
	return unix.IoctlSetTermios(fd, unix.TCSETS, t)
}

// chromeProcess is the running Chrome and its pipe.
type chromeProcess struct {
	cmd    *exec.Cmd
	c      *cdp
	exited chan struct{}
}

// startChrome starts Chrome on its debugging pipe with its profile in
// $HOME/chrome, waits for its first answer, and gives b its pipe.
func startChrome(path string, b *browser) (*chromeProcess, error) {
	home := os.Getenv("HOME")
	if home == "" {
		return nil, errors.New("HOME names no folder")
	}
	profile := filepath.Join(home, "chrome")
	// The host runs one session per person, so a singleton entry in the
	// profile is a dead Chrome's, and Chrome refuses the profile while it
	// stands.
	for _, name := range []string{"SingletonLock", "SingletonSocket", "SingletonCookie"} {
		if err := os.Remove(filepath.Join(profile, name)); err != nil && !errors.Is(err, fs.ErrNotExist) {
			return nil, err
		}
	}
	commandsIn, commandsOut, err := os.Pipe()
	if err != nil {
		return nil, err
	}
	answersIn, answersOut, err := os.Pipe()
	if err != nil {
		commandsIn.Close()
		commandsOut.Close()
		return nil, err
	}
	cmd := exec.Command(path, "--headless", "--no-sandbox", "--remote-debugging-pipe",
		"--user-data-dir="+profile, "--disable-dev-shm-usage", "--no-first-run", "--no-default-browser-check",
		"--password-store=basic", "--window-size=1280,900")
	cmd.Env = append(without(os.Environ(), "DBUS_SESSION_BUS_ADDRESS"), "DBUS_SESSION_BUS_ADDRESS=disabled:")
	// Chrome reads its commands on fd 3 and writes its answers on fd 4. Its
	// standard streams are the null device, so nothing it prints reaches
	// the terminal. A process group of its own keeps the terminal's hangup
	// from it until the driver has closed it, and the parent-death signal
	// ends it with the driver.
	cmd.ExtraFiles = []*os.File{commandsIn, answersOut}
	cmd.SysProcAttr = &syscall.SysProcAttr{Pdeathsig: syscall.SIGKILL, Setpgid: true}
	err = cmd.Start()
	commandsIn.Close()
	answersOut.Close()
	if err != nil {
		commandsOut.Close()
		answersIn.Close()
		return nil, err
	}
	p := &chromeProcess{cmd: cmd, exited: make(chan struct{})}
	go func() {
		_ = cmd.Wait()
		commandsOut.Close()
		close(p.exited)
	}()
	b.c = newCDP(commandsOut, answersIn, b.onTarget)
	p.c = b.c
	ctx, cancel := context.WithTimeout(context.Background(), startWait)
	defer cancel()
	if err := ready(ctx, b.c); err != nil {
		p.kill()
		var refused *cdpError
		switch {
		case errors.Is(err, context.DeadlineExceeded):
			return nil, fmt.Errorf("Chrome did not answer within %d seconds", int(startWait.Seconds()))
		case errors.As(err, &refused):
			return nil, fmt.Errorf("Chrome refused %s", refused.Message)
		default:
			return nil, fmt.Errorf("Chrome ended (%s)", p.cmd.ProcessState)
		}
	}
	return p, nil
}

// ready waits for Chrome's first answer, has it report its targets' ends,
// and closes the page it opened at start, which no window uses.
func ready(ctx context.Context, c *cdp) error {
	if err := c.call(ctx, "", "Browser.getVersion", nil, nil); err != nil {
		return err
	}
	if err := c.call(ctx, "", "Target.setDiscoverTargets", map[string]any{"discover": true}, nil); err != nil {
		return err
	}
	var targets struct {
		TargetInfos []struct {
			TargetID string `json:"targetId"`
			Type     string `json:"type"`
		} `json:"targetInfos"`
	}
	if err := c.call(ctx, "", "Target.getTargets", nil, &targets); err != nil {
		return err
	}
	for _, t := range targets.TargetInfos {
		if t.Type == "page" {
			if err := c.call(ctx, "", "Target.closeTarget", map[string]any{"targetId": t.TargetID}, nil); err != nil {
				return err
			}
		}
	}
	return nil
}

func without(env []string, name string) []string {
	kept := env[:0:0]
	for _, entry := range env {
		if !strings.HasPrefix(entry, name+"=") {
			kept = append(kept, entry)
		}
	}
	return kept
}

// close asks Chrome to close, which writes its profile, and kills its
// process group when it has not within closeWait.
func (p *chromeProcess) close() {
	select {
	case <-p.exited:
		return
	default:
	}
	ctx, cancel := context.WithTimeout(context.Background(), closeWait)
	defer cancel()
	_ = p.c.call(ctx, "", "Browser.close", nil, nil)
	select {
	case <-p.exited:
	case <-ctx.Done():
		p.kill()
	}
}

func (p *chromeProcess) kill() {
	_ = unix.Kill(-p.cmd.Process.Pid, unix.SIGKILL)
	<-p.exited
}

// event is what the serve loop acts on: a host message, a request's
// response made ready, or the end of the host's input.
type event struct {
	kind string
	id   int64
	seq  int
	req  request
	text []byte
}

// serve answers the host until its input ends (nil), Chrome exits
// (errChromeExited), a stop signal arrives (nil) or the output fails.
func serve(in io.Reader, s *slot, do func(request) []byte, exited <-chan struct{}, stop <-chan os.Signal) error {
	events := make(chan event, 64)
	go readFrames(in, events)
	tick := time.NewTicker(min(max(s.keep/4, 10*time.Millisecond), time.Second))
	defer tick.Stop()
	for {
		var err error
		select {
		case <-exited:
			return errChromeExited
		case <-stop:
			return nil
		case <-tick.C:
			err = s.expire()
		case e := <-events:
			switch e.kind {
			case "end":
				return nil
			case "req":
				var run bool
				if run, err = s.take(e.req.ID); run {
					go func(r request) { events <- event{kind: "ready", id: r.ID, text: do(r)} }(e.req)
				}
			case "ready":
				err = s.ready(e.id, e.text)
			case "ack":
				err = s.ack(e.id, e.seq)
			case "again":
				err = s.again(e.id, e.seq)
			}
		}
		if err != nil {
			return err
		}
	}
}

// readFrames turns the host's frames into events; a body that is no
// message of the host's is passed over.
func readFrames(in io.Reader, events chan<- event) {
	r := reader{max: maxToDriver}
	buf := make([]byte, 64<<10)
	for {
		n, err := in.Read(buf)
		for _, body := range r.feed(buf[:n]) {
			if e, ok := parse(body); ok {
				events <- e
			}
		}
		if err != nil {
			events <- event{kind: "end"}
			return
		}
	}
}

func parse(body []byte) (event, bool) {
	var m struct {
		T    string          `json:"t"`
		ID   *int64          `json:"id"`
		Seq  *int            `json:"seq"`
		Win  string          `json:"win"`
		Op   string          `json:"op"`
		Args json.RawMessage `json:"args"`
	}
	if json.Unmarshal(body, &m) != nil || m.ID == nil {
		return event{}, false
	}
	switch m.T {
	case "req":
		return event{kind: "req", req: request{ID: *m.ID, Win: m.Win, Op: m.Op, Args: m.Args}}, true
	case "ack", "again":
		if m.Seq == nil {
			return event{}, false
		}
		return event{kind: m.T, id: *m.ID, seq: *m.Seq}, true
	}
	return event{}, false
}
