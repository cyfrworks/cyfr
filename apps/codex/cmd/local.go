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
	"slices"
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
// address, the account service, the route and the setup token, with no
// value taken or interpolated from this process's environment. The binding
// is the one client to that CYFR (localFolder.client): as each connection
// opens the folder is read again, a reading naming another CYFR than the
// one opened sends nothing, and Docker says that the folder's own cyfr
// container runs publishing the address's port, the same container before
// the connection was made and after, so that no other program holding the
// port is taken for it. A retained address therefore never receives what
// was read for another.

// The route to a CYFR with tailnet access from the computer it runs on:
// its SOCKS5 proxy on loopback, the one way there, and the engine's
// resolver rules, so that no name is looked up past it.
const (
	localProxyPort = 1055
	localProxy     = "socks5://127.0.0.1:1055"
	localResolver  = "MAP * ~NOTFOUND, EXCLUDE 127.0.0.1"
)

// localhostIsIPv4 is the engine's resolver rule elsewhere: localhost is
// 127.0.0.1 alone, where Docker publishes a local CYFR, and never ::1,
// where any other program may listen on the same port
// (desktop/src/policy.js LOCALHOST_IS_IPV4).
const localhostIsIPv4 = "MAP localhost 127.0.0.1"

const directoryVar = "CYFR_DIRECTORY_URL"

// localBound is what a connection to a folder's CYFR is bound to: what a
// reading names of it.
type localBound struct {
	mode, address, directory string
	// port is the one its cyfr container publishes on loopback.
	port int
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
			mode:      head.Mode,
			address:   address,
			directory: cmp.Or(strings.TrimSpace(values[directoryVar]), account.DefaultDirectory),
			port:      head.Port,
		},
		token: strings.TrimSpace(values[setupTokenVar]),
	}, nil
}

// localFolder is the CYFR in dir as one reading opened it.
type localFolder struct {
	dir, holder string
	opened      localBound
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

// readLocal is the CYFR set up in dir, as the screen and the CYFR app open
// it: one reading (readFolder), with no call to Docker and nothing
// started, and the client bound to it. holder names the caller in the
// stack's lock while it reads whether setup is open.
func readLocal(dir, holder string) (desktop.Local, error) {
	read, err := readFolder(dir)
	if err != nil {
		return desktop.Local{}, err
	}
	f := &localFolder{dir: dir, holder: holder, opened: read.localBound}
	client, err := f.client()
	if err != nil {
		return desktop.Local{}, err
	}
	var l desktop.Local
	if read.mode == access.ModeTailnet {
		l.Proxy, l.Resolver = localProxy, localResolver
	}
	l.Shell = shell.Config{
		Address:    read.address,
		Client:     client,
		Directory:  read.directory,
		DataDir:    filepath.Join(dir, "data"),
		SetupToken: f.setupToken,
	}
	l.Answers = func(ctx context.Context) error { return f.answers(ctx, client) }
	return l, nil
}

// client is the one client to the folder's CYFR. A request to it is bound
// (dial) and takes no proxy of this process's environment. A request to
// another program on this computer is refused: the only one this client
// speaks to is that CYFR. One to anywhere else, the account service at
// cyfr.run say, takes this computer's own way there. Each request dials,
// so that each is bound.
func (f *localFolder) client() (*http.Client, error) {
	at, err := url.Parse(f.opened.address)
	if err != nil {
		return nil, err
	}
	own, bound, to := hostPort(at), hostPort(at), hostPort(at)
	var socks *url.URL
	switch f.opened.mode {
	case access.ModeLocal:
		to = net.JoinHostPort("127.0.0.1", strconv.Itoa(f.opened.port))
	case access.ModeTailnet:
		if socks, err = url.Parse(localProxy); err != nil {
			return nil, err
		}
		bound, to = socks.Host, socks.Host
	}
	route := func(r *http.Request) (*url.URL, error) {
		switch {
		case hostPort(r.URL) == own:
			return socks, nil
		case onThisComputer(r.URL.Hostname()):
			return nil, &shell.Unbound{Sentence: fmt.Sprintf("%s is not the CYFR in %s, so nothing was sent there.", r.URL.Host, f.dir)}
		case socks != nil:
			return socks, nil
		}
		return computersProxy(r)
	}
	dial := func(ctx context.Context, network, address string) (net.Conn, error) {
		if address == bound {
			return f.dial(ctx, to)
		}
		return dialTCP(ctx, network, address)
	}
	return &http.Client{Transport: &http.Transport{
		Proxy:               route,
		DialContext:         dial,
		DisableKeepAlives:   true,
		TLSHandshakeTimeout: 10 * time.Second,
	}}, nil
}

// dial connects to the folder's CYFR at to, or sends nothing: the folder
// is read now and must still name the CYFR opened, and the containers
// Docker says serve it must be the same before and after the connection
// was made, so that they held the port while it was.
func (f *localFolder) dial(ctx context.Context, to string) (net.Conn, error) {
	ctx, cancel := context.WithTimeout(ctx, localDialWithin)
	defer cancel()
	now, err := f.read()
	if err != nil {
		return nil, err
	}
	before, err := f.serving(ctx, now.localBound)
	if err != nil {
		return nil, err
	}
	conn, err := dialTCP(ctx, "tcp", to)
	if err != nil {
		return nil, err
	}
	after, err := f.serving(ctx, now.localBound)
	if err == nil && !slices.Equal(before, after) {
		err = f.stopped()
	}
	if err != nil {
		conn.Close()
		return nil, err
	}
	return conn, nil
}

// read is the folder read now, refused unless it names the CYFR opened.
func (f *localFolder) read() (localReading, error) {
	now, err := readFolder(f.dir)
	if err != nil {
		return localReading{}, &shell.Unbound{Sentence: fmt.Sprintf("The CYFR in %s can no longer be read (%v), so nothing was sent to it.", f.dir, engineFailure(err))}
	}
	if now.localBound != f.opened {
		return localReading{}, &shell.Unbound{Moved: true, Sentence: fmt.Sprintf(
			"The settings of the CYFR in %s changed after it was opened here, so nothing was sent to it. Quit CYFR and open it again.", f.dir)}
	}
	return now, nil
}

func (f *localFolder) stopped() error {
	return &shell.Unbound{Sentence: fmt.Sprintf("The CYFR in %s is not running. Run cyfr up in that folder, then try again.", f.dir)}
}

// serving is Docker's word for what serves at on this computer: the
// folder's cyfr container, and with tailnet access its tailscale one, each
// running and publishing its port on loopback. Only a Docker on this
// computer can say that. Nothing is started and no lock is taken.
func (f *localFolder) serving(ctx context.Context, at localBound) ([]access.Published, error) {
	unsaid := func(why error) error {
		return &shell.Unbound{Sentence: fmt.Sprintf("Docker could not say whether the CYFR in %s is running (%v), so nothing was sent to it.", f.dir, why)}
	}
	e, err := openEngine(f.dir)
	if err != nil {
		return nil, unsaid(engineFailure(err))
	}
	docker := e.Docker()
	here, err := access.DockerIsHere(ctx, docker)
	if err != nil {
		return nil, unsaid(err)
	}
	if !here {
		return nil, unsaid(errors.New("this Docker runs containers on another computer"))
	}
	type publisher struct {
		service string
		port    int
	}
	need := []publisher{{"cyfr", at.port}}
	if at.mode == access.ModeTailnet {
		need = append(need, publisher{"tailscale", localProxyPort})
	}
	var all []access.Published
	for _, p := range need {
		c, ok, err := access.PublishedBy(ctx, docker, f.dir, p.service, p.port)
		switch {
		case err != nil:
			return nil, unsaid(err)
		case !ok:
			return nil, f.stopped()
		}
		all = append(all, c)
	}
	return all, nil
}

// setupToken is the setup token for a first hello, or "". It is one
// reading under the stack's lock: the .env that still names the CYFR
// opened, that CYFR's container, and that same container's log since its
// start saying no one is set up. The log is a reason to offer the token
// and no more. It is a snapshot, and can lag an admission that has
// committed: the CYFR decides again in its own transaction. The lock is
// taken without waiting: held by a command changing the stack, or with
// anything unread, no token is offered and the door decides. .env keeps
// the token after setup, so it is never offered for being there.
func (f *localFolder) setupToken(ctx context.Context) string {
	e, err := openEngine(f.dir)
	if err != nil {
		return ""
	}
	unlock, err := e.Lock(f.holder)
	if err != nil {
		return ""
	}
	defer unlock()
	now, err := f.read()
	if err != nil || now.token == "" {
		return ""
	}
	serving, err := f.serving(ctx, now.localBound)
	if err != nil {
		return ""
	}
	res, err := e.Docker().Run(ctx, access.Call{
		Args:     []string{"logs", "--since", serving[0].Started, serving[0].ID},
		Deadline: composeRunTimeout,
	})
	if err != nil || res.ExitCode != 0 || setUpIn(res) != setUpNone {
		return ""
	}
	return now.token
}

// answers is nil once the folder's CYFR answers at its address over a
// bound connection. Asking starts nothing.
func (f *localFolder) answers(ctx context.Context, client *http.Client) error {
	ctx, cancel := context.WithTimeout(ctx, localDialWithin)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, f.opened.address+"/", nil)
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
		return &shell.Unbound{Sentence: fmt.Sprintf("The CYFR in %s is running and does not answer at %s yet. Try again in a moment.", f.dir, f.opened.address)}
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
