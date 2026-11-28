// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"cmp"
	"context"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/cyfr/codex/internal/access"
	"github.com/cyfr/codex/internal/account"
	"github.com/cyfr/codex/internal/desktop"
	"github.com/cyfr/codex/internal/shell"
)

// One rule holds whatever this device does for the CYFR in a folder: it
// comes from one reading of that folder, made at the moment it opens, and
// is bound to the one CYFR that reading names. Nothing is carried over
// from an earlier reading and nothing comes from outside the folder.
//
// A reading is the folder's .env read once and alone (readFolder): the
// address, the account service, the engine's route and the setup token,
// with no value taken or interpolated from this process's environment.
//
// The binding is the one way cyfr itself reaches that CYFR, the same in
// every kind of browser address (localFolder.transport): the loopback listener, which
// the folder's cyfr container publishes at 127.0.0.1 and CYFR_PORT, under
// the configured address's name. That name is what is signed and shown,
// and is never looked up or connected to. As each connection opens the
// folder is read again, a reading naming another CYFR than the one opened
// sends nothing, and Docker names the container publishing that port, by
// its id and its start: the same before the connection was made and
// after, so that no other program holding the port is taken for it. A
// setup token goes only on a connection to the one container whose log
// was read for it. A retained address therefore never receives what was
// read for another.
//
// Each reading made as a connection opens, or as the setup token is asked
// for, and Docker's word of it are made together in setup's work (look,
// setup_project.go), the one place this device asks Docker: that process
// has the docker group and Docker Desktop's docker where this one lacks
// them, and none of this one's settings.

// The engine's route to a CYFR with a tailnet address from the computer it
// runs on, for CYFR's own pages alone: its SOCKS5 proxy on loopback, the
// one way to that name. The engine asks the proxy for each name, and
// looks none of them up itself.
const localProxy = "socks5://127.0.0.1:1055"

const directoryVar = "CYFR_DIRECTORY_URL"

// localBound is what a connection to a folder's CYFR is bound to: what a
// reading names of it.
type localBound struct {
	Browser   string `json:"browser"`
	Address   string `json:"address"`
	Directory string `json:"directory"`
	// Port is the one its cyfr container publishes on loopback.
	Port int `json:"port"`
}

// folderLook is what setup's work answers of a folder: one reading, and
// Docker's word of it, the container serving or why nothing is sent.
type folderLook struct {
	Bound     localBound       `json:"bound"`
	Container access.Published `json:"container"`
	Refused   string           `json:"refused,omitempty"`
	// Lasting is a refusal waiting does not cure: only a new login gives
	// this account's processes the docker group.
	Lasting bool `json:"lasting,omitempty"`
	// Token is the setup token, from that same reading and container,
	// where it may be offered (lookForToken).
	Token string `json:"token,omitempty"`
}

type localReading struct {
	localBound
	token string
}

// readFolder is one reading of dir: its .env, once and alone.
func readFolder(dir string) (localReading, error) {
	values, head, err := access.ReadProjectAlone(dir)
	if err != nil {
		return localReading{}, err
	}
	// The spelling the CYFR signs and is signed to in
	// (Prima.Identity.Encoding.canonical_home): a default port is dropped.
	address, ok := account.CanonicalHome(access.Describe(head).Address)
	if !ok {
		return localReading{}, fmt.Errorf("%s is not an address a device can open", access.Describe(head).Address)
	}
	return localReading{
		localBound: localBound{
			Browser:   head.Browser,
			Address:   address,
			Directory: cmp.Or(strings.TrimSpace(values[directoryVar]), account.DefaultDirectory),
			Port:      head.Port,
		},
		token: strings.TrimSpace(values[setupTokenVar]),
	}, nil
}

// localFolder is the CYFR in dir as one reading opened it.
type localFolder struct {
	dir, holder string
	opened      localBound
	// name is the opened address's host and port, loopback where its
	// container publishes it on this computer.
	name, loopback string

	// work is everything begun for this CYFR here, and begin begins
	// setup's work for a reading under it, as the program's settings were
	// when the folder was opened (preparer).
	work  *shell.Work
	begin func(context.Context, []string) (*workProcess, error)
}

// dialTCP makes a connection once a localFolder allows it. A test stands
// in for it.
var dialTCP = (&net.Dialer{Timeout: 10 * time.Second}).DialContext

// computersProxy is this computer's own way to anywhere but the folder's
// CYFR. A test stands in for it, since it reads the environment once a
// process.
var computersProxy = http.ProxyFromEnvironment

// localDialWithin bounds one connection: Docker's word, the connection and
// Docker's word again.
const localDialWithin = 20 * time.Second

// openFolder is the CYFR set up in dir as one reading of it opens it,
// everything begun for it begun under work.
func openFolder(work *shell.Work, dir, holder string) (*localFolder, localReading, error) {
	read, err := readFolder(dir)
	if err != nil {
		return nil, read, err
	}
	at, err := url.Parse(read.Address)
	if err != nil {
		return nil, read, err
	}
	return &localFolder{dir: dir, holder: holder, opened: read.localBound,
		name: hostPort(at), loopback: net.JoinHostPort("127.0.0.1", strconv.Itoa(read.Port)),
		work: work, begin: beginUnder(work, preparer())}, read, nil
}

// localRoute is the engine's route to a CYFR of browser address kind on
// the computer it runs on: a tailnet one's proxy, none for any other.
func localRoute(browser string) string {
	if browser == access.BrowserTailnet {
		return localProxy
	}
	return ""
}

// readLocal is the CYFR set up in dir, as the screen and the CYFR app open
// it: one reading (readFolder), with no call to Docker and nothing
// started, and the client bound to it, which asks Docker through setup's
// work alone, begun under work. holder names the caller in the stack's
// lock while it reads whether setup is open.
func readLocal(work *shell.Work, dir, holder string) (desktop.Local, error) {
	f, read, err := openFolder(work, dir, holder)
	if err != nil {
		return desktop.Local{}, err
	}
	client := &http.Client{Transport: f.transport(nil)}
	l := desktop.Local{Work: work}
	l.Proxy = localRoute(read.Browser)
	l.Shell = shell.Config{
		Address:    read.Address,
		Client:     client,
		Directory:  read.Directory,
		DataDir:    filepath.Join(dir, "data"),
		SetupToken: f.setupToken,
	}
	l.Answers = func(ctx context.Context) error { return f.answers(ctx, client) }
	return l, nil
}

// transport is the one way to the folder's CYFR. A request to its name is
// sent to loopback on a connection of its own, bound (dial) to named when
// that is given and otherwise to the container serving as it opens, and
// through no proxy. A request to another program on this computer is
// refused: the only one spoken to here is that CYFR. One to anywhere
// else, the account service at cyfr.run say, takes this computer's own
// way there.
func (f *localFolder) transport(named *access.Published) http.RoundTripper {
	return &folderTransport{
		f: f,
		// No connection is kept, so that each request's is bound.
		bound: &http.Transport{
			DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
				// net/http dials on past its request's end, for a request
				// that may come; this dial is its request's alone, so it
				// ends with that request (sentBy).
				if r, ok := ctx.Value(sentBy{}).(context.Context); ok {
					var stop context.CancelFunc
					ctx, stop = context.WithCancel(ctx)
					defer context.AfterFunc(r, stop)()
					defer stop()
				}
				return f.dial(ctx, named)
			},
			DisableKeepAlives: true,
		},
		elsewhere: &http.Transport{
			Proxy:               computersProxy,
			DialContext:         dialTCP,
			DisableKeepAlives:   true,
			TLSHandshakeTimeout: 10 * time.Second,
		},
	}
}

// sentBy keys the context of the request a bound connection is dialled
// for.
type sentBy struct{}

type folderTransport struct {
	f                *localFolder
	bound, elsewhere http.RoundTripper
}

func (t *folderTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	if hostPort(r.URL) == t.f.name {
		sent := r.Clone(context.WithValue(r.Context(), sentBy{}, r.Context()))
		sent.URL.Scheme, sent.URL.Host = "http", t.f.loopback
		sent.Host = cmp.Or(r.Host, r.URL.Host)
		resp, err := t.bound.RoundTrip(sent)
		if err != nil {
			return nil, err
		}
		resp.Request = r
		return resp, nil
	}
	if onThisComputer(r.URL.Hostname()) {
		if r.Body != nil {
			r.Body.Close()
		}
		return nil, &shell.Unbound{Sentence: fmt.Sprintf("%s is not the CYFR in %s, so nothing was sent there.", r.URL.Host, t.f.dir)}
	}
	return t.elsewhere.RoundTrip(r)
}

// dial connects to the folder's CYFR on this computer, or sends nothing:
// the folder is read now and must still name the CYFR opened, and the
// container Docker says serves it, named's when that is given, must be
// the same by id and start before and after the connection was made, so
// that it held the port while it was.
func (f *localFolder) dial(ctx context.Context, named *access.Published) (net.Conn, error) {
	ctx, cancel := context.WithTimeout(ctx, localDialWithin)
	defer cancel()
	before, err := f.look(ctx, workLook, f.dir)
	if err != nil {
		return nil, err
	}
	if named == nil {
		named = &before.Container
	}
	if before.Container != *named {
		return nil, f.replaced()
	}
	conn, err := dialTCP(ctx, "tcp", f.loopback)
	if err != nil {
		return nil, err
	}
	after, err := f.look(ctx, workLook, f.dir)
	if err == nil && after.Container != *named {
		err = f.replaced()
	}
	if err != nil {
		conn.Close()
		return nil, err
	}
	return conn, nil
}

// look has setup's work read the folder now, refused unless that reading
// names the CYFR opened and Docker's word of it names the container
// serving.
func (f *localFolder) look(ctx context.Context, args ...string) (folderLook, error) {
	ctx, stop := f.work.Join(ctx)
	defer stop()
	end, err := workBegunBy(ctx, f.begin, nil, args...)
	var failed workFailure
	switch {
	case errors.As(err, &failed):
		return folderLook{}, &shell.Unbound{Sentence: failed.sentence}
	case err != nil:
		return folderLook{}, &shell.Unbound{Sentence: unread(f.dir, err)}
	case end.Look == nil:
		return folderLook{}, &shell.Unbound{Sentence: unread(f.dir, errNoReading)}
	case end.Look.Bound != f.opened:
		return folderLook{}, &shell.Unbound{Moved: true, Lasting: true, Sentence: fmt.Sprintf(
			"The settings of the CYFR in %s changed after it was opened here, so nothing was sent to it. Press Connect on the left, then choose this CYFR again: on a box's screen, This box.", f.dir)}
	case end.Look.Refused != "":
		return folderLook{}, &shell.Unbound{Sentence: end.Look.Refused, Lasting: end.Look.Lasting}
	case end.Look.Container.ID == "":
		return folderLook{}, &shell.Unbound{Sentence: unread(f.dir, errNoReading)}
	}
	return *end.Look, nil
}

var errNoReading = errors.New("setup's work named no container")

func (f *localFolder) replaced() error {
	return &shell.Unbound{Sentence: fmt.Sprintf("The CYFR in %s started again while this device was connecting, so nothing was sent to it. Try again.", f.dir)}
}

// setupToken is the setup token for a first hello and the one transport
// it may be sent by, or "": what one reading in setup's work offers
// (lookForToken), only where that reading names the CYFR opened. The
// transport connects to that reading's container alone, by its id and
// start, so the token reaches no other.
func (f *localFolder) setupToken(ctx context.Context) (string, http.RoundTripper) {
	ctx, cancel := context.WithTimeout(ctx, localDialWithin)
	defer cancel()
	look, err := f.look(ctx, workToken, f.dir, f.holder)
	if err != nil || look.Token == "" {
		return "", nil
	}
	return look.Token, f.transport(&look.Container)
}

// loginMissing is Docker refusing a process that lacks the docker group
// its account is in, which only a new login gives it.
type loginMissing struct{ sentence string }

func (l loginMissing) Error() string { return l.sentence }

func notRunning(dir string, port int) string {
	return fmt.Sprintf("Docker shows no CYFR of %s running at %s. Run cyfr up in that folder, then try again.", dir, net.JoinHostPort("127.0.0.1", strconv.Itoa(port)))
}

// unread is a reading of dir that never came back from setup's work,
// which is all this process saw: whether Docker was asked, it cannot say.
func unread(dir string, why error) string {
	if errors.Is(why, context.Canceled) || errors.Is(why, context.DeadlineExceeded) || errors.Is(why, shell.ErrEnded) {
		why = errors.New("it was ended before it answered")
	}
	return fmt.Sprintf("The CYFR in %s could not be read here (%v), so nothing was sent to it. Try again.", dir, why)
}

func dockerUnsaid(dir string, why error) string {
	return fmt.Sprintf("Docker could not say whether the CYFR in %s is running (%v), so nothing was sent to it. Check Docker, then try again.", dir, why)
}

// ---- in setup's work

// lookInFolder is one reading of dir and Docker's word of it. Nothing is
// started and no lock is taken.
func lookInFolder(ctx context.Context, dir string) (*folderLook, error) {
	read, err := readFolder(dir)
	if err != nil {
		return nil, fmt.Errorf("The CYFR in %s can no longer be read (%w), so nothing was sent to it.", dir, engineFailure(err))
	}
	return lookedAt(ctx, dir, read), nil
}

func lookedAt(ctx context.Context, dir string, read localReading) *folderLook {
	look := &folderLook{Bound: read.localBound}
	container, err := servingIn(ctx, dir, read.Port)
	if err != nil {
		var login loginMissing
		look.Refused, look.Lasting = err.Error(), errors.As(err, &login)
		return look
	}
	look.Container = container
	return look
}

// lookForToken is lookInFolder under the stack's lock, holder its name
// there, with the setup token where that one reading may offer it: that
// same container's log since its start says no one is set up. The log is
// a reason to offer the token and no more. It is a snapshot, and can lag
// an admission that has committed: the CYFR decides again in its own
// transaction. The lock is taken without waiting: held by a command
// changing the stack, or with anything unread, no token is offered and
// the door decides. .env keeps the token after setup, so it is never
// offered for being there.
func lookForToken(ctx context.Context, dir, holder string) (*folderLook, error) {
	e, err := openEngine(dir)
	if err != nil {
		return nil, engineFailure(err)
	}
	unlock, err := e.Lock(holder)
	if err != nil {
		return nil, engineFailure(err)
	}
	defer unlock()
	read, err := readFolder(dir)
	if err != nil {
		return nil, engineFailure(err)
	}
	look := lookedAt(ctx, dir, read)
	if look.Refused != "" || read.token == "" {
		return look, nil
	}
	res, err := e.Docker().Run(ctx, access.Call{
		Args:     []string{"logs", "--since", look.Container.Started, look.Container.ID},
		Deadline: composeRunTimeout,
	})
	if err == nil && res.ExitCode == 0 && setUpIn(res) == setUpNone {
		look.Token = read.token
	}
	return look, nil
}

// servingIn is Docker's word for what serves dir's CYFR at port on this
// computer: the folder's cyfr container, running and publishing the port
// on loopback. Only a Docker on this computer can say that. Its error is
// the sentence a person reads.
func servingIn(ctx context.Context, dir string, port int) (access.Published, error) {
	unsaid := func(why error) error { return errors.New(dockerUnsaid(dir, why)) }
	var none access.Published
	e, err := openEngine(dir)
	if err != nil {
		return none, fmt.Errorf("The CYFR in %s could not be opened here (%v), so Docker was not asked and nothing was sent to it. Correct that, then try again.", dir, engineFailure(err))
	}
	docker := e.Docker()
	here, err := access.DockerIsHere(ctx, docker)
	if err != nil {
		return none, unsaid(err)
	}
	if !here {
		return none, unsaid(errors.New("this Docker runs containers on another computer"))
	}
	c, ok, err := access.PublishedBy(ctx, docker, dir, "cyfr", port)
	switch {
	case err != nil && refusedHere(ctx, err):
		// This computer's own Docker refused this process, which lacks the
		// docker group its account is in: setup's work without sg, which
		// only a new login cures.
		return none, loginMissing{fmt.Sprintf("%s. Nothing was sent to the CYFR in %s.", loginAgain, dir)}
	case err != nil:
		return none, unsaid(err)
	case !ok:
		return none, errors.New(notRunning(dir, port))
	}
	return c, nil
}

// refusedHere is whether err, a Docker command's on this computer's own
// Docker, is that Docker refusing this process while it lacks the docker
// group its account is in: the command ran to its exit (not its deadline,
// nor ctx's), and only a new login gives the group, as setup's work came
// without sg.
func refusedHere(ctx context.Context, err error) bool {
	var failed *access.DockerFailed
	if !errors.As(err, &failed) || ctx.Err() != nil || !olderThanGroup(ctx) {
		return false
	}
	why, _ := dockerSentence(seeDocker(ctx, true))
	return why == loginAgain
}

// answers is nil once the folder's CYFR answers on this computer over a
// bound connection. Asking starts nothing.
func (f *localFolder) answers(ctx context.Context, client *http.Client) error {
	ctx, cancel := context.WithTimeout(ctx, localDialWithin)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, f.opened.Address+"/", nil)
	if err != nil {
		return err
	}
	// The sign-in redirect is an answer, and nothing follows it.
	once := *client
	once.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	resp, err := once.Do(req)
	var unbound *shell.Unbound
	switch {
	case errors.As(err, &unbound):
		return unbound
	case err != nil:
		// What was seen is no answer: Docker, the connection or CYFR may be
		// what held it.
		return &shell.Unbound{Sentence: fmt.Sprintf("No answer came from the CYFR in %s. Check with docker ps that Docker answers and CYFR runs, then try again in a moment.", f.dir)}
	}
	resp.Body.Close()
	return nil
}

// hostPort is u's host and port, the scheme's default spelled out, as a
// transport dials it.
func hostPort(u *url.URL) string {
	port := u.Port()
	if port == "" {
		port = "80"
		if u.Scheme == "https" || u.Scheme == "wss" {
			port = "443"
		}
	}
	return net.JoinHostPort(strings.ToLower(u.Hostname()), port)
}

// onThisComputer is whether host names this computer's loopback.
func onThisComputer(host string) bool {
	h := strings.TrimSuffix(strings.ToLower(host), ".")
	if h == "localhost" || strings.HasSuffix(h, ".localhost") {
		return true
	}
	ip := net.ParseIP(h)
	return ip != nil && (ip.IsLoopback() || ip.IsUnspecified())
}
