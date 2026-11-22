// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"context"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/cyfr/codex/internal/access"
	"github.com/cyfr/codex/internal/account"
	"github.com/cyfr/codex/internal/desktop"
	"github.com/cyfr/codex/internal/shell"
)

// The route to a CYFR with tailnet access from the computer it runs on:
// its SOCKS5 proxy on loopback, the one way there, and the engine's
// resolver rules, so that no name is looked up past it.
const (
	localProxy    = "socks5://127.0.0.1:1055"
	localResolver = "MAP * ~NOTFOUND, EXCLUDE 127.0.0.1"
)

// readLocal is the CYFR set up in dir, as the screen and the CYFR app open
// it: all of it read from dir and none from the working directory, with no
// call to Docker and nothing started. holder names the caller in the
// stack's lock while it reads whether setup is open.
func readLocal(dir, holder string) (desktop.Local, error) {
	e, err := openEngine(dir)
	if err != nil {
		return desktop.Local{}, err
	}
	head, err := e.Head()
	if err != nil {
		return desktop.Local{}, err
	}
	var l desktop.Local
	client := &http.Client{}
	if head.Mode == access.ModeTailnet {
		proxy, err := url.Parse(localProxy)
		if err != nil {
			return desktop.Local{}, err
		}
		client.Transport = &http.Transport{Proxy: http.ProxyURL(proxy)}
		l.Proxy, l.Resolver = localProxy, localResolver
	}
	address := access.Describe(head).Address
	l.Shell = shell.Config{
		Address:   address,
		Client:    client,
		Directory: localDirectory(dir),
		DataDir:   filepath.Join(dir, "data"),
		Tokens:    func() string { return localToken(dir) },
		// .env keeps the setup token after setup: the device brings it only
		// while no one is set up.
		SetupOpen: func(ctx context.Context) bool { return localSetupOpen(ctx, dir, holder) },
	}
	l.Answers = func() bool { return localAnswers(client, address) }
	return l, nil
}

// localSetupOpen is whether no one is set up on the CYFR in dir yet, as
// cyfr's log since its start says, read under the stack's lock as cyfr
// setup reads it (readSetUp). The lock is taken without waiting: held by a
// command changing the stack, or with a log that cannot be read, setup is
// taken as closed, so the door decides and the next unlock asks again.
func localSetupOpen(ctx context.Context, dir, holder string) bool {
	e, err := openEngine(dir)
	if err != nil {
		return false
	}
	unlock, err := e.Lock(holder)
	if err != nil {
		return false
	}
	defer unlock()
	head, err := e.Head()
	if err != nil {
		return false
	}
	return readSetUp(ctx, e, head) == setUpNone
}

// localToken reads the setup token in dir's .env as the server reads it,
// each time a page needs it, so it never travels in an argument.
func localToken(dir string) string {
	values, err := access.ReadEnvValues(filepath.Join(dir, ".env"))
	if err != nil {
		return ""
	}
	return strings.TrimSpace(values[setupTokenVar])
}

// localAnswers is whether the CYFR at address answers now, within two
// seconds.
func localAnswers(client *http.Client, address string) bool {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, address+"/", nil)
	if err != nil {
		return false
	}
	resp, err := client.Do(req)
	if err != nil {
		return false
	}
	resp.Body.Close()
	return true
}

// localDirectory is the directory a new account is made at and a name is
// looked up through: CYFR_DIRECTORY_URL from the environment or from dir's
// .env, as the server reads it, else cyfr.run.
func localDirectory(dir string) string {
	if v := strings.TrimSpace(os.Getenv(directoryVar)); v != "" {
		return v
	}
	if values, err := access.ReadEnvValues(filepath.Join(dir, ".env")); err == nil {
		if v := strings.TrimSpace(values[directoryVar]); v != "" {
			return v
		}
	}
	return account.DefaultDirectory
}

const directoryVar = "CYFR_DIRECTORY_URL"
