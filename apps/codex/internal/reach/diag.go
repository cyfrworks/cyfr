// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package reach

import (
	"fmt"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
)

// What docker writes when a call fails can quote .env: compose names the
// value it could not read or convert, and an interpolated secret is such
// a value, a file name included. A diagnosis therefore never carries
// docker's text: it is recognized by a whole line of the form docker or
// compose writes it (Docker 29 and Compose 2.40 as installed and their
// predecessors' wording), and said in fixed words that name at most what
// the engine itself knows: a file only if it is one the engine passes
// compose (.env, the compose files, the materialized configuration), a
// service only if the project's configuration or the engine names it, a
// configuration path only under such a service and in compose's grammar
// of keys and indexes, a line or a port by its digits. Anything else is
// said only by the call's exit status.
var diagnoses = []struct {
	form *regexp.Regexp
	say  func(k known, m []string) string
}{
	{regexp.MustCompile(`(?m)^(?:Cannot connect to the Docker daemon at .+\. Is the docker daemon running\?|failed to connect to the docker API at .+; check if the path is correct and if the daemon is running: .+)$`),
		func(known, []string) string { return "the Docker daemon is not reachable" }},
	{regexp.MustCompile(`(?m)^permission denied while trying to connect to the (?:Docker daemon socket|docker API) at .+$`),
		func(known, []string) string { return "this user may not use the Docker daemon" }},
	{regexp.MustCompile(`(?m)^failed to read .+$`), func(k known, m []string) string { return k.unreadable(m[0]) }},
	{regexp.MustCompile(`(?m)^'services\[([A-Za-z0-9._-]+)\]((?:\.[A-Za-z0-9_-]+|\[[0-9]+\])*)' .+$`), func(k known, m []string) string {
		if !k.services[m[1]] {
			return "it refused a value of the configuration"
		}
		return "it refused the value of services[" + m[1] + "]" + m[2]
	}},
	{regexp.MustCompile(`(?m)^Error response from daemon: (?:failed to set up container networking: )?driver failed programming external connectivity on endpoint .+ \([0-9a-f]+\): (?:Bind for .+:([0-9]{1,5}) failed: port is already allocated|failed to bind host port .+:([0-9]{1,5})/(?:tcp|udp|sctp): address already in use)$`),
		func(_ known, m []string) string { return "port " + m[1] + m[2] + " is already in use" }},
	{regexp.MustCompile(`(?m)^Error response from daemon: (?:pull access denied for \S+, repository does not exist or may require 'docker login'|No such image: \S+|failed to resolve reference "[^"]+": .+: not found|manifest for \S+ not found: manifest unknown: .+)$`),
		func(known, []string) string { return "an image could not be found or pulled" }},
	{regexp.MustCompile(`(?m)^no such service: ([A-Za-z0-9._-]+)$`), func(k known, m []string) string {
		if !k.services[m[1]] {
			return "it has no such service"
		}
		return "it has no service " + m[1]
	}},
}

// known is what a diagnosis may name: the files the engine passes docker,
// by every absolute path docker may print for one, and the services the
// project's configuration and the engine name.
type known struct {
	files    map[string]string
	services map[string]bool
}

// known is the engine's: .env, the default compose files and the
// materialized configurations under the project directory, as given and
// with its links resolved; the services of the compose files and the
// engine's own.
func (e *Engine) known() known {
	k := known{files: map[string]string{}, services: map[string]bool{}}
	names := []string{".env"}
	files, _ := e.defaultFiles()
	names = append(names, files...)
	if matches, err := filepath.Glob(filepath.Join(e.path(), resolvedGlob)); err == nil {
		for _, m := range matches {
			names = append(names, filepath.ToSlash(filepath.Join(stateDir, filepath.Base(m))))
		}
	}
	dirs := []string{e.dir}
	if real, err := filepath.EvalSymlinks(e.dir); err == nil && real != e.dir {
		dirs = append(dirs, real)
	}
	for _, dir := range dirs {
		for _, name := range names {
			k.files[filepath.Join(dir, filepath.FromSlash(name))] = name
		}
	}
	for _, name := range slices.Concat([]string{cyfrService, serveService, buildsService}, e.publishedNames()[1:]) {
		k.services[name] = true
	}
	return k
}

// unreadable says a `failed to read` line: the file by its name when
// the engine passed it, the line when compose names one.
func (k known) unreadable(line string) string {
	paths := make([]string, 0, len(k.files))
	for p := range k.files {
		paths = append(paths, p)
	}
	// The longest first, so a path is never taken for a prefix of it.
	slices.SortFunc(paths, func(a, b string) int { return len(b) - len(a) })
	for _, p := range paths {
		rest, ok := strings.CutPrefix(line, "failed to read "+p+": ")
		if !ok {
			rest, ok = strings.CutPrefix(line, "failed to read file "+strconv.Quote(p)+": ")
		}
		if !ok {
			continue
		}
		if m := lineNumber.FindStringSubmatch(rest); m != nil {
			return "it could not read " + k.files[p] + " at line " + m[1]
		}
		return "it could not read " + k.files[p]
	}
	if strings.HasPrefix(line, `failed to read file "`) {
		return "it could not read a file"
	}
	return "it could not read an env file"
}

var lineNumber = regexp.MustCompile(`^line ([0-9]+): `)

// callFailed is what an error says of a docker call that failed: the step,
// the call's own error (its exit status), and what docker's diagnostic
// is recognized as, if anything.
func (e *Engine) callFailed(step string, err error, stderr []byte) string {
	for _, d := range diagnoses {
		if m := d.form.FindStringSubmatch(string(stderr)); m != nil {
			return fmt.Sprintf("%s failed (%v: %s)", step, err, d.say(e.known(), m))
		}
	}
	return fmt.Sprintf("%s failed (%v)", step, err)
}
