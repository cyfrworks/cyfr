// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

// Command cyfr-browser drives Aqua's browser: Chromium's headless shell
// with its profile in a kept home. It is the command of a `driven` program row,
// which the backends service runs on a pseudo-terminal under the home's
// uid; its one host, Opus.Browser, speaks framed messages to it over that
// terminal's bytes, and it speaks the Chrome DevTools Protocol to Chrome
// over Chrome's debugging pipe, which never leaves the box. No debugging
// port is ever opened.
//
//	cyfr-browser [--chrome PATH] [--net-log PATH] [--chunk BYTES] [--keep-ms MS]
//
// It starts the image's Chromium headless shell, Debian's, by its
// absolute path (Dockerfile.locus), and fetches nothing; --chrome starts
// the Chrome at PATH instead. --net-log has Chrome log its network to PATH, which only
// tests pass.
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
// chunk by chunk and may ask to send again. A `req` of op `cast` starts a
// window's cast, whose images go out one at a time beside the responses
// and whose window takes the person's input (cast.go, input.go). A `req`
// of op `page` is a put, which runs once the `part`s that follow it have
// brought its files; the window's page is answered from them, and the
// calls it makes go up as `call`s, each fulfilled by the host's `answer`
// or ended by the driver's `callend` (page.go). Chrome
// exiting ends the driver with 1; its input ending, a hangup or a TERM
// closes Chrome, which then writes its profile, and ends it with 0.
package main

import (
	"context"
	"encoding/base64"
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
	"regexp"
	"strings"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

const (
	defaultChunk  = 49152
	defaultKeepMS = 120000
	// chromium is the image's Chromium headless shell: the browser engine
	// with no sign-in, sync, component updater or session restore of its
	// own, which the full browser has and reaches Google for at start.
	chromium = "/usr/lib/chromium/chromium-headless-shell"
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
	chrome := flags.String("chrome", chromium, "Chrome's binary")
	chunk := flags.Int("chunk", defaultChunk, "bytes of response text one res frame carries")
	keepMS := flags.Int64("keep-ms", defaultKeepMS, "milliseconds an unacknowledged response is kept")
	netLog := flags.String("net-log", "", "a file Chrome logs its network to")
	personFlag := flags.String("person", "", "the person's language and time zone, a JSON object of locale and time_zone")
	if err := flags.Parse(args); err != nil {
		return 2
	}
	who, err := readPerson(*personFlag)
	if flags.NArg() != 0 || *chunk < 1 || *chunk > maxChunk || *keepMS < 1 || *chrome == "" || err != nil {
		fmt.Fprintf(os.Stderr, "usage: cyfr-browser [--chrome PATH] [--net-log PATH] [--chunk 1-%d] [--keep-ms MS] "+
			"[--person '{\"locale\":TAG,\"time_zone\":ZONE}']\n", maxChunk)
		return 2
	}
	// The end is taken before anything is announced: a TERM that comes
	// while Chrome starts, or just after the hello, is held until the
	// serve loop takes it, and Chrome is then closed and the bye said.
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, unix.SIGTERM, unix.SIGHUP)
	defer signal.Stop(stop)
	if err := makeRaw(int(os.Stdin.Fd())); err != nil {
		fmt.Fprintln(os.Stderr, "cyfr-browser: its terminal:", err)
		return 1
	}
	s := newSlot(os.Stdout, *chunk, time.Duration(*keepMS)*time.Millisecond)
	hello := helloMessage{T: "hello", V: 1, Chunk: *chunk, KeepMS: *keepMS}
	b := newBrowser()
	b.person = who
	home, err := browserHome()
	if err != nil {
		hello.Error = "The browser could not start: " + err.Error() + "."
		_ = s.write(hello)
		return 1
	}
	removeLeftovers(home, os.Stderr)
	var logging []string
	if *netLog != "" {
		logging = []string{"--log-net-log=" + *netLog, "--net-log-capture-mode=Default"}
	}
	running, err := startChrome(*chrome, home, b, logging)
	if err != nil {
		hello.Error = "The browser could not start: " + err.Error() + "."
		_ = s.write(hello)
		return 1
	}
	if err := s.write(hello); err != nil {
		running.close()
		return 1
	}
	err = serve(os.Stdin, s, b, running.exited, stop)
	// Chrome is gone before the driver says bye, so whatever it writes as
	// it closes, the profile and a network log, is written by then.
	running.close()
	_ = s.write(byeMessage{T: "bye"})
	if err != nil {
		if !errors.Is(err, errChromeExited) {
			fmt.Fprintln(os.Stderr, "cyfr-browser:", err)
		}
		return 1
	}
	return 0
}

// byeMessage is the driver's last message, once its Chrome has exited.
type byeMessage struct {
	T string `json:"t"`
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

// quiet is how Chrome is started so that it reaches nothing by itself:
// no window of its own at start, so neither the pages of the profile's
// last session nor its startup pages load until a request asks for a
// window; and none of the traffic a browser makes on its own: update and
// component checks, sync, the time and spelling services, field trials,
// domain reliability, safe-browsing and phishing models, metrics and
// pings, the cast and translate services, the server checks of autofill,
// optimization hints, the new tab's feed and lens, the AI Mode eligibility
// check (AimEnabled), which no narrower switch stops, and the preconnect to
// the default search engine that every new window makes
// (PreconnectToSearch). Measured with Chrome's own network log over a start
// with nothing asked and over a session of put pages
// (tests/locus-backends-image/browser.py), it makes no request. Nor does
// Chrome ever ask a resolver for the reserved origin's name: what a page
// asks of it that no interception pauses, a socket, a preconnect or a
// shared worker's request, fails at once inside Chrome.
var quiet = []string{
	"--no-startup-window", "--no-first-run", "--no-default-browser-check",
	"--disable-background-networking", "--disable-component-update", "--disable-sync",
	"--disable-domain-reliability", "--disable-client-side-phishing-detection", "--disable-default-apps",
	"--disable-component-extensions-with-background-pages", "--no-pings", "--metrics-recording-only",
	"--disable-breakpad", "--no-service-autorun", "--disable-search-engine-choice-screen",
	"--disable-features=Translate,OptimizationHints,OptimizationHintsFetching,OptimizationGuideModelDownloading," +
		"OptimizationTargetPrediction,MediaRouter,DialMediaRouteProvider,AutofillServerCommunication," +
		"CertificateTransparencyComponentUpdater,NetworkTimeServiceQuerying,InterestFeedContentSuggestions," +
		"LensOverlay,AimEnabled,PreconnectToSearch",
	"--host-resolver-rules=MAP " + reservedHost + " ~NOTFOUND",
}

// browserHome is the folder the browser keeps its profile in, $HOME, which
// must name a folder by an absolute path: under any other, nothing is
// removed and Chrome is not started.
func browserHome() (string, error) {
	home := os.Getenv("HOME")
	if !filepath.IsAbs(home) {
		return "", errors.New("HOME names no folder")
	}
	if info, err := os.Stat(home); err != nil || !info.IsDir() {
		return "", errors.New("HOME names no folder")
	}
	return home, nil
}

// startChrome starts Chrome on its debugging pipe with its profile in
// home's chrome folder, reaching nothing by itself (quiet), by the name
// the shell gives itself less Headless (ownName), waits for its first
// answer, and gives b its pipe and its agent; logging is added to its
// flags.
func startChrome(path, home string, b *browser, logging []string) (*chromeProcess, error) {
	profile := filepath.Join(home, "chrome")
	// The host runs one session per person, so a singleton entry in the
	// profile is a dead Chrome's, and Chrome refuses the profile while it
	// stands.
	for _, name := range []string{"SingletonLock", "SingletonSocket", "SingletonCookie"} {
		if err := os.Remove(filepath.Join(profile, name)); err != nil && !errors.Is(err, fs.ErrNotExist) {
			return nil, err
		}
	}
	if err := chromeTemp(home); err != nil {
		return nil, err
	}
	// Chrome's own sandbox cannot start under the backends service's
	// options (no new privileges, and a seccomp profile that denies making
	// a namespace), so Chrome runs without it, held by the home's uid, the
	// egress guard, the read-only root and its memory bound.
	// The debugging pipe makes Chrome tell its pages navigator.webdriver is
	// true; AutomationControlled, the one feature behind it, is turned off
	// so it reads false as a person's browser does. Nothing else a page
	// reads changes with it.
	args := append([]string{"--no-sandbox", "--remote-debugging-pipe", "--disable-dev-shm-usage",
		"--password-store=basic", "--window-size=1280,900", "--disable-blink-features=AutomationControlled"}, quiet...)
	args = append(args, b.person.switches()...)
	// The person's zone is Chrome's process's TZ, and only Chrome's: the
	// driver's own environment, which a row of the browser never sets, holds
	// none (person.go).
	env := append(without(without(without(os.Environ(), "DBUS_SESSION_BUS_ADDRESS"), "TMPDIR"), "TZ"),
		"DBUS_SESSION_BUS_ADDRESS=disabled:", "TMPDIR="+chromeTmp)
	env = append(env, b.person.env()...)
	reading, cancel := context.WithTimeout(context.Background(), startWait)
	agent, err := ownName(reading, path, home, args, env, b.log)
	cancel()
	if err != nil {
		return nil, err
	}
	args = append(args, "--user-data-dir="+profile, "--user-agent="+agent["userAgent"].(string))
	p, err := launch(path, home, append(args, logging...), env, b.onTarget)
	if err != nil {
		return nil, err
	}
	b.c = p.c
	ctx, cancel := context.WithTimeout(context.Background(), startWait)
	defer cancel()
	if _, err := ready(ctx, p); err != nil {
		return nil, err
	}
	b.agent = agent
	if err := p.c.call(ctx, "", "Target.setAutoAttach", browserTargets, nil); err != nil {
		p.kill()
		return nil, fmt.Errorf("Chrome refused to show the windows pages open (%v)", err)
	}
	return p, nil
}

// readingName is the name of the throwaway profile ownName reads the
// shell's name in, in Chrome's temporary folder: readingPrefix and the
// digits os.MkdirTemp adds, a name no person's file has. chromeTemp
// removes a real folder of that name a killed reading left, and nothing
// else.
const readingPrefix = "cyfr-browser-reading-"

var readingName = regexp.MustCompile(`\A` + readingPrefix + `[0-9]+\z`)

// ownName runs the shell once, as startChrome runs it, on a throwaway
// profile in home's Chrome temporary folder and by no name of the
// driver's, reads how it names itself, its User-Agent and its client
// hints (ownAgent), and answers the override every target is given
// (agentOf). Chrome is started by the switch the override names, which
// blanks the high-entropy client hints a page reads of the running Chrome
// (measured on the image's Chromium 156), so they are read before it
// starts. The whole reading, its shell's close among it, holds to ctx's
// deadline, at which the shell is killed; the profile is removed whatever
// the reading's end, and a removal that fails is said on log.
func ownName(ctx context.Context, path, home string, args, env []string, log io.Writer) (map[string]any, error) {
	profile, err := os.MkdirTemp(filepath.Join(home, chromeTmp), readingPrefix)
	if err != nil {
		return nil, err
	}
	defer func() {
		if err := os.RemoveAll(profile); err != nil {
			fmt.Fprintf(log, "cyfr-browser: the profile Chrome's name was read in is not removed: %v\n", err)
		}
	}()
	p, err := launch(path, home, append(args, "--user-data-dir="+profile), env, func(string, json.RawMessage) {})
	if err != nil {
		return nil, err
	}
	defer p.closeWithin(ctx)
	v, err := ready(ctx, p)
	if err != nil {
		return nil, err
	}
	agent, err := ownAgent(ctx, p.c, v.UserAgent)
	if err != nil {
		return nil, fmt.Errorf("Chrome did not say how it names itself (%v)", err)
	}
	return agent, nil
}

// launch starts Chrome at path with args and env in home, its pipe's
// target events to onTarget.
func launch(path, home string, args, env []string, onTarget func(string, json.RawMessage)) (*chromeProcess, error) {
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
	cmd := exec.Command(path, args...)
	// Chrome runs in its home with its temporary folder named relative to
	// it (chromeTemp), so the socket that locks its profile has a short path
	// whatever the home's.
	cmd.Dir = home
	cmd.Env = env
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
	p.c = newCDP(commandsOut, answersIn, onTarget)
	return p, nil
}

// ready waits for p's Chrome's first answer, its version, has it report
// its targets' ends, and closes any page target it finds, which no window
// uses: with no startup window there is none. A Chrome that does not get
// there is killed, and the error says why.
func ready(ctx context.Context, p *chromeProcess) (version, error) {
	v, err := readied(ctx, p.c)
	if err != nil {
		p.kill()
		var refused *cdpError
		switch {
		case errors.Is(err, context.DeadlineExceeded):
			return v, fmt.Errorf("Chrome did not answer within %d seconds", int(startWait.Seconds()))
		case errors.As(err, &refused):
			return v, fmt.Errorf("Chrome refused %s", refused.Message)
		default:
			return v, fmt.Errorf("Chrome ended (%s)", p.cmd.ProcessState)
		}
	}
	return v, nil
}

func readied(ctx context.Context, c *cdp) (version, error) {
	var v version
	if err := c.call(ctx, "", "Browser.getVersion", nil, &v); err != nil {
		return v, err
	}
	if err := c.call(ctx, "", "Target.setDiscoverTargets", map[string]any{"discover": true}, nil); err != nil {
		return v, err
	}
	var targets struct {
		TargetInfos []struct {
			TargetID string `json:"targetId"`
			Type     string `json:"type"`
		} `json:"targetInfos"`
	}
	if err := c.call(ctx, "", "Target.getTargets", nil, &targets); err != nil {
		return v, err
	}
	for _, t := range targets.TargetInfos {
		if t.Type == "page" {
			if err := c.call(ctx, "", "Target.closeTarget", map[string]any{"targetId": t.TargetID}, nil); err != nil {
				return v, err
			}
		}
	}
	return v, nil
}

// chromeTmp is Chrome's temporary folder, relative to the home it runs in.
// Chrome locks its profile with a socket in a folder it makes there, and a
// socket's path holds at most 107 bytes: a kept home's absolute path with
// a row's id leaves too little for Chrome's own names
// (/var/lib/locus/kept/mcp_<uuid>/tmp/org.chromium.Chromium.XXXXXX/SingletonSocket
// is 109), and Chrome aborts. Named relative to the home, the path it
// binds is short however long the home's.
const chromeTmp = "tmp"

// chromeTemp makes Chrome's temporary folder in home, a real folder of
// the home's and never one it links to, and removes the lock folders a
// dead Chrome left there and the throwaway profile a killed reading of the
// shell's name left (ownName): the host runs one session per person, so
// none is a live Chrome's. Only a real folder of those names is removed,
// never a file or a link.
func chromeTemp(home string) error {
	dir := filepath.Join(home, chromeTmp)
	if err := os.Mkdir(dir, 0o700); err != nil && !errors.Is(err, fs.ErrExist) {
		return err
	}
	if info, err := os.Lstat(dir); err != nil || !info.IsDir() {
		return fmt.Errorf("the home's %s is not a folder of its own", chromeTmp)
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return err
	}
	for _, entry := range entries {
		name := entry.Name()
		if !entry.IsDir() || !(strings.HasPrefix(name, "org.chromium.Chromium.") || readingName.MatchString(name)) {
			continue
		}
		if err := os.RemoveAll(filepath.Join(dir, name)); err != nil {
			return err
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

// closeWithin asks Chrome to close within ctx and kills its process group
// when it has not by ctx's end.
func (p *chromeProcess) closeWithin(ctx context.Context) {
	select {
	case <-p.exited:
		return
	default:
	}
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
// response made ready, a cast's start, frame or end, or the end of the
// host's input. A part's bytes are its text; an answer's status and body
// are its own.
type event struct {
	kind    string
	id      int64
	seq     int64
	req     request
	text    []byte
	failed  bool
	session string
	frame   chromeFrame
	input   []inputEvent
	status  int
	body    string
}

// serve answers the host until its input ends (nil), Chrome exits
// (errChromeExited), a stop signal arrives (nil) or the output fails.
func serve(in io.Reader, s *slot, b *browser, exited <-chan struct{}, stop <-chan os.Signal) error {
	events := make(chan event, 64)
	cs := newCasts(b, s, events)
	defer cs.stop()
	ps := newPuts(s, func(r request) { go func() { events <- event{kind: "ready", id: r.ID, text: b.do(r)} }() })
	cl := newCalls(b, s)
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
			if err = s.expire(); err == nil {
				err = ps.expire()
			}
		case pe := <-b.pages:
			err = cl.take(pe)
		case e := <-events:
			switch e.kind {
			case "end":
				return nil
			case "req":
				var run bool
				if run, err = s.take(e.req.ID); run && e.req.Op == "cast" {
					cs.start(e.req)
				} else if run && e.req.Op == "page" {
					err = ps.start(e.req)
				} else if run {
					go func(r request) { events <- event{kind: "ready", id: r.ID, text: b.do(r)} }(e.req)
				}
			case "ready":
				err = s.ready(e.id, e.text)
			case "part":
				err = ps.part(e.id, e.seq, e.text, e.failed)
			case "answer":
				cl.answer(e.id, e.status, e.body)
			case "ack":
				err = s.ack(e.id, int(e.seq))
			case "again":
				err = s.again(e.id, int(e.seq))
			case "casting":
				err = cs.casting(e)
			case "image":
				err = cs.image(e.id, e.frame)
			case "castend":
				err = cs.ended(e.id)
			case "seen":
				err = cs.seen(e.id, e.seq)
			case "uncast":
				cs.uncast(e.id)
			case "input":
				cs.input(e.id, e.input)
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
		T      string          `json:"t"`
		ID     *int64          `json:"id"`
		Seq    *int64          `json:"seq"`
		Win    string          `json:"win"`
		Op     string          `json:"op"`
		Args   json.RawMessage `json:"args"`
		Of     int64           `json:"of"`
		Evs    json.RawMessage `json:"evs"`
		Part   *string         `json:"part"`
		Status *int            `json:"status"`
		Body   *string         `json:"body"`
	}
	if json.Unmarshal(body, &m) != nil || m.ID == nil {
		return event{}, false
	}
	switch m.T {
	case "req":
		return event{kind: "req", req: request{ID: *m.ID, Win: m.Win, Op: m.Op, Args: m.Args, Of: m.Of}}, true
	case "part":
		if m.Seq == nil || m.Part == nil {
			return event{}, false
		}
		data, err := base64.StdEncoding.DecodeString(*m.Part)
		return event{kind: "part", id: *m.ID, seq: *m.Seq, text: data, failed: err != nil}, true
	case "answer":
		if m.Status == nil || m.Body == nil {
			return event{}, false
		}
		return event{kind: "answer", id: *m.ID, status: *m.Status, body: *m.Body}, true
	case "ack", "again", "seen":
		if m.Seq == nil {
			return event{}, false
		}
		return event{kind: m.T, id: *m.ID, seq: *m.Seq}, true
	case "uncast":
		return event{kind: "uncast", id: *m.ID}, true
	case "input":
		events, ok := parseInput(m.Evs)
		if !ok {
			return event{}, false
		}
		return event{kind: "input", id: *m.ID, input: events}, true
	}
	return event{}, false
}
