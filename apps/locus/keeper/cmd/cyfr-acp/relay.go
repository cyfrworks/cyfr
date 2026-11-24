// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package main

import (
	"errors"
	"fmt"
	"regexp"
	"strings"
	"time"

	"github.com/cyfr/locus/keeper/internal/homepath"
)

// CYFR's server takes no place of a server of the person's own: a program
// keeps one server of a name, whichever it registers first (OpenCode 2.4.1
// drops the person's, Antigravity 1.5.16 drops CYFR's). So at each start
// the driver asks the program for its servers, by the program's own words
// for them (profile's serverList), and names CYFR's `cyfr`, or else the
// first of `cyfr-2`, `cyfr-3`… that none of them takes. CYFR reads no file
// of the program's: the names are the program's answer. A program that
// lists none the driver can read starts no session, since no name is then
// known to leave the person's servers theirs.
//
// A program whose listing starts the servers it lists (profile's
// namesOnce) is asked once, when a session is made: the name is kept with
// the session, one file a session, `<home>/.cache/cyfr-acp/servers/<session>`,
// beside its instructions record, and a start that goes on with the
// session takes the kept name with no listing. A record that is lost, or
// holds no name CYFR gives its server, is listed for again and kept anew.

// relayServer is the name CYFR's server takes when no server of the
// person's takes it.
const relayServer = "cyfr"

// listCap bounds what the program prints of its servers.
const listCap = 1 << 20

// serverFor is the name CYFR's server takes beside the servers `listed`:
// one no listed server has, and that no listed server's name begins with
// followed by `_`, since a program that names a tool by its server and the
// tool joined with `_` (Antigravity's `mcp_<server>_<tool>`) could then
// spell a tool of theirs as one of CYFR's.
func serverFor(listed []string) string {
	taken := func(name string) bool {
		for _, other := range listed {
			if other == name || strings.HasPrefix(other, name+"_") {
				return true
			}
		}
		return false
	}
	name := relayServer
	for n := 2; taken(name); n++ {
		name = fmt.Sprintf("%s-%d", relayServer, n)
	}
	return name
}

// personsServers runs the program's command with its profile's words for
// its servers, within the driver's bound for an answer, and reads their
// names from what it prints.
func (d *driver) personsServers() ([]string, error) {
	p, err := d.c.Spawn(append(append([]string{}, d.harnessCommand...), d.p.serverList...))
	if err != nil {
		return nil, err
	}
	defer p.Stop()
	deadline := time.After(d.answerWait)
	var out []byte
	for {
		select {
		case line := <-p.Lines:
			if line == nil || len(out)+len(line) > listCap {
				return nil, errors.New("it printed past what CYFR reads")
			}
			out = append(append(out, line...), '\n')
		case <-p.Done:
			if p.Status != 0 {
				return nil, errors.New("it ended with an error")
			}
			names, ok := d.p.serverNames(out)
			if !ok {
				return nil, errors.New("it printed no listing CYFR reads")
			}
			return names, nil
		case <-deadline:
			return nil, errors.New("it did not answer in time")
		}
	}
}

// relayName is the form of every name serverFor gives.
var relayName = regexp.MustCompile(`^cyfr(-[1-9][0-9]{0,8})?$`)

func serverPath(home, session string) homepath.Path {
	return homepath.Path{Root: home, Rel: driverFolder + "/servers/" + session}
}

// keptServer is the name CYFR's server took when the session was made, or
// "" where none is kept.
func keptServer(home, session string) string {
	held, err := homepath.ReadFile(serverPath(home, session))
	if err != nil || !relayName.Match(held) {
		return ""
	}
	return string(held)
}

// recordServer keeps the name CYFR's server takes in the session. One that
// cannot be written is as a lost one: the next start lists again.
func recordServer(home, session, name string) {
	if keptServer(home, session) != name {
		_ = homepath.WriteFile(serverPath(home, session), []byte(name))
	}
}
