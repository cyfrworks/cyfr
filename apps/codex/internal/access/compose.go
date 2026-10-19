// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package access

import (
	"context"
	"fmt"
	"maps"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"

	"gopkg.in/yaml.v3"
)

// The services the engine names: cyfr itself, and the tailnet proxy
// whose Serve configuration it writes. Every other access service comes
// from the head's profiles.
const (
	cyfrService  = "cyfr"
	serveService = "tailscale"
)

// selection is the explicit compose selection of head h over files: the
// project, the files, the project directory and every profile of h.
func (e *Engine) selection(files []string, h Head) []string {
	args := []string{"compose", "-p", e.project}
	for _, f := range files {
		args = append(args, "-f", f)
	}
	args = append(args, "--project-directory", ".")
	for _, p := range h.Profiles {
		args = append(args, "--profile", p)
	}
	return args
}

// flatten is `docker compose config` of h over the default file set: the
// configuration compose would run for h's selection, .env's values
// inlined.
func (e *Engine) flatten(ctx context.Context, h Head) ([]byte, error) {
	// compose reads COMPOSE_* from .env: no compose call runs over one
	// that sets any.
	if _, err := e.readEnv(); err != nil {
		return nil, err
	}
	files, err := e.defaultFiles()
	if err != nil {
		return nil, err
	}
	res, err := e.docker.Run(ctx, Call{Args: append(e.selection(files, h), "config"), Deadline: StopDeadline})
	if err != nil {
		return nil, fmt.Errorf("access: %s", e.callFailed("docker compose config", err, res.Stderr))
	}
	return res.Stdout, nil
}

// materialize writes h's configuration afresh to
// .cyfr/compose.resolved.<digest>.yml (0600: it holds .env's values),
// after checking the stack it describes (checkStack), and keeps the
// stamp of every input it was made from. An operation with a journal
// names the file there before writing it, so an interrupted operation
// keeps exactly the files its journal names.
func (e *Engine) materialize(ctx context.Context, h Head, j *journal) ([]byte, error) {
	sources, err := e.checkProvenance()
	if err != nil {
		return nil, err
	}
	in := materialized{sources: sources}
	in.stamp = e.inputStamp(sources)
	content, err := e.flatten(ctx, h)
	if err != nil {
		return nil, err
	}
	if err := e.checkEffective(h, content); err != nil {
		return nil, err
	}
	name := resolvedName(h.Digest())
	if j != nil && !slices.Contains(j.Files, name) {
		j.Files = append(j.Files, name)
		if err := e.saveJournal(j); err != nil {
			return nil, err
		}
	}
	if err := e.writeDurable(filepath.Join(e.dir, filepath.FromSlash(name)), content, 0o600); err != nil {
		return nil, err
	}
	e.mu.Lock()
	e.files[name] = in
	e.mu.Unlock()
	return content, nil
}

// materialized is what a materialized configuration was made from: every
// compose file the provenance read named (the default set, each include:
// and extends: target), and the stamp of their bytes and .env's.
type materialized struct {
	sources []string
	stamp   string
}

// inputStamp fingerprints a configuration's inputs as they read now: the
// default file set as it stands, the sources it was read from, and .env.
func (e *Engine) inputStamp(sources []string) string {
	files, _ := e.defaultFiles()
	names := []string{filepath.Join(e.dir, ".env")}
	for _, f := range files {
		names = append(names, filepath.Join(e.dir, f))
	}
	names = union(names, sources)
	var all []byte
	for _, name := range names {
		data, err := os.ReadFile(name)
		state := sha256Hex(data)
		if err != nil {
			state = "absent"
		}
		all = append(all, []byte(name+"\x00"+state+"\x00")...)
	}
	return sha256Hex(all)
}

// composeArgs is a compose command of h on its materialized file.
func (e *Engine) composeArgs(h Head, args ...string) []string {
	return append(e.selection([]string{resolvedName(h.Digest())}, h), args...)
}

// composeArgsFor is ComposeArgs: h's file is materialized on first use
// and reused only while every input reads as it did then; a command that
// rewrote the compose file, an included or extended file, or .env since
// gets the configuration they now give, checked afresh.
func (e *Engine) composeArgsFor(ctx context.Context, h Head, args ...string) ([]string, error) {
	name := resolvedName(h.Digest())
	e.mu.Lock()
	in, held := e.files[name]
	e.mu.Unlock()
	if _, err := os.Stat(filepath.Join(e.dir, filepath.FromSlash(name))); !held || err != nil || in.stamp != e.inputStamp(in.sources) {
		if _, err := e.materialize(ctx, h, nil); err != nil {
			return nil, err
		}
	}
	return e.composeArgs(h, args...), nil
}

// dropFiles removes the materialized files this engine made and those
// extra names. Unless finishing, it keeps every file the journal names:
// an unfinished operation keeps exactly those until its receipt.
func (e *Engine) dropFiles(extra []string, finishing bool) error {
	var j *journal
	if !finishing {
		j, _ = e.readJournal()
	}
	e.mu.Lock()
	names := slices.Collect(maps.Keys(e.files))
	e.mu.Unlock()
	names = append(names, extra...)
	var errs []error
	for _, name := range names {
		if j != nil && slices.Contains(j.Files, name) {
			continue
		}
		if err := os.Remove(filepath.Join(e.dir, filepath.FromSlash(name))); err != nil && !os.IsNotExist(err) {
			errs = append(errs, err)
		}
		e.mu.Lock()
		delete(e.files, name)
		e.mu.Unlock()
	}
	if len(names) > 0 {
		syncDir(e.path())
	}
	if len(errs) > 0 {
		return fmt.Errorf("access: remove materialized configuration: %v", errs)
	}
	return nil
}

// config is the part of a flattened configuration the engine reads.
type config struct {
	Services map[string]struct {
		Image       string             `yaml:"image"`
		Profiles    []string           `yaml:"profiles"`
		Environment map[string]*string `yaml:"environment"`
	} `yaml:"services"`
}

var yamlLine = regexp.MustCompile(`line ([0-9]+)`)

func parseConfig(content []byte) (config, error) {
	var c config
	if err := yaml.Unmarshal(content, &c); err != nil {
		// The configuration holds .env's values, which a YAML error may
		// quote: it is said by its line alone.
		where := ""
		if m := yamlLine.FindStringSubmatch(err.Error()); m != nil {
			where = " at line " + m[1]
		}
		return c, fmt.Errorf("access: the flattened configuration does not read as compose writes it%s", where)
	}
	return c, nil
}

// accessServices are the services of c that h's access profiles select:
// every profile of h but locus-builds, which a switch never changes.
func accessServices(c config, h Head) []string {
	var out []string
	for name, svc := range c.Services {
		for _, p := range svc.Profiles {
			if p != buildsService && slices.Contains(h.Profiles, p) {
				out = append(out, name)
				break
			}
		}
	}
	slices.Sort(out)
	return out
}

// servicesOf reads h's access services from content, or from a flattened
// read when there is none (for a head not yet materialized: the service
// names do not depend on .env's values).
func (e *Engine) servicesOf(ctx context.Context, h Head, content []byte) ([]string, error) {
	if content == nil {
		var err error
		if content, err = e.flatten(ctx, h); err != nil {
			return nil, err
		}
	}
	c, err := parseConfig(content)
	if err != nil {
		return nil, err
	}
	return accessServices(c, h), nil
}

// accessModeProfiles are the profiles every mode's head selects to reach
// the home, as Profiles derives them: locus-builds aside, which no mode
// owns.
func accessModeProfiles() []string {
	var out []string
	for _, mode := range []string{ModeLocal, ModeTailnet, ModePublic} {
		out = union(out, slices.DeleteFunc(Profiles(mode, ""), func(p string) bool { return p == buildsService }))
	}
	return out
}

// everyAccessService is every service the stack's configuration puts in a
// access mode's profile, whichever head selects it: what a stop of the
// access services must cover when a head cannot say, and what a start removes when
// its head does not select it.
func (e *Engine) everyAccessService(ctx context.Context) ([]string, error) {
	return e.servicesOf(ctx, Head{Profiles: accessModeProfiles()}, nil)
}

// otherServices are c's services that are not access services of h.
func otherServices(c config, h Head) []string {
	services := accessServices(c, h)
	var out []string
	for name := range c.Services {
		if !slices.Contains(services, name) {
			out = append(out, name)
		}
	}
	slices.Sort(out)
	return out
}

// cyfrEnv is the cyfr service's flattened environment.
func cyfrEnv(c config) map[string]string {
	env := map[string]string{}
	for k, v := range c.Services[cyfrService].Environment {
		if v != nil {
			env[k] = *v
		}
	}
	return env
}

// checkEffective validates the values cyfr would start with: ResolveBoot
// with .env's own read as the file and the flattened environment as the
// process, a release's rules, and the head that answers must be h.
func (e *Engine) checkEffective(h Head, content []byte) error {
	c, err := parseConfig(content)
	if err != nil {
		return err
	}
	if _, ok := c.Services[cyfrService]; !ok {
		return fmt.Errorf("access: the stack's configuration has no %s service", cyfrService)
	}
	env, err := e.readEnv()
	if err != nil {
		return err
	}
	file := map[string]string{}
	if env != nil {
		file = env.values()
	}
	b, err := ResolveBoot(BootInput{File: file, Process: cyfrEnv(c), Release: true})
	if err != nil {
		return err
	}
	if b.Head.Digest() != h.Digest() {
		return fmt.Errorf("access: the stack's configuration starts cyfr reached as %s, not as %s", wordsText(Describe(b.Head)), wordsText(Describe(h)))
	}
	return nil
}

// checkStack is CheckStack: the sources, then the effective values of
// .env's head, reading and writing nothing under .cyfr/.
func (e *Engine) checkStack(ctx context.Context) error {
	if _, err := e.checkProvenance(); err != nil {
		return err
	}
	h, err := e.envHead()
	if err != nil {
		return err
	}
	content, err := e.flatten(ctx, h)
	if err != nil {
		return err
	}
	return e.checkEffective(h, content)
}

// checkProvenance reads the source file set before compose flattens it:
// the default files and every file they include, and each service any of
// their services extends, wherever it is. No service's environment: may
// write a name with `$`, as a list entry, which compose interpolates
// into another name, a head key's among them, or as a mapping key: cyfr
// resolves no name and takes only plain ones. No head key may be
// assigned in the cyfr service's own environment: entries there would
// override what .env says, and the flattened configuration cannot show
// where a value came from. .env must reach cyfr through its env_file.
// Values are not read. It answers every file it read.
func (e *Engine) checkProvenance() ([]string, error) {
	files, err := e.defaultFiles()
	if err != nil {
		return nil, err
	}
	p := &provenance{e: e, seen: map[string]bool{}, read: map[string]bool{}}
	for _, f := range files {
		if err := p.file(filepath.Join(e.dir, f)); err != nil {
			return nil, err
		}
	}
	if !p.envFile {
		// The file to fix is the first that defines cyfr, where the
		// shipped stack gives it .env.
		file := files[0]
		if len(p.defines) > 0 {
			file = p.defines[0]
		}
		return nil, Refuse("compose_override_refused", map[string]string{"file": file, "service": cyfrService})
	}
	return slices.Sorted(maps.Keys(p.read)), nil
}

type provenance struct {
	e       *Engine
	seen    map[string]bool
	read    map[string]bool
	envFile bool
	// defines are the files that define the cyfr service, in the order
	// compose reads them.
	defines []string
}

func (p *provenance) rel(path string) string {
	if r, err := filepath.Rel(p.e.dir, path); err == nil {
		return filepath.ToSlash(r)
	}
	return path
}

// load reads a compose file as compose's YAML reader resolves it:
// anchors, aliases and every form of merge key applied.
func (p *provenance) load(path string) (map[string]any, error) {
	p.read[filepath.Clean(path)] = true
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("access: read %s: %w", p.rel(path), err)
	}
	var doc map[string]any
	if err := yaml.Unmarshal(data, &doc); err != nil {
		return nil, fmt.Errorf("%s does not read as YAML, so cyfr cannot check it before compose reads it. Nothing started. Correct it", p.rel(path))
	}
	return doc, nil
}

// file checks one file of the set and every file it includes.
func (p *provenance) file(path string) error {
	path = filepath.Clean(path)
	if p.seen[path] {
		return nil
	}
	p.seen[path] = true
	root, err := p.load(path)
	if err != nil {
		return err
	}
	entries, _ := root["include"].([]any)
	for _, entry := range entries {
		var paths []string
		switch v := entry.(type) {
		case string:
			paths = []string{v}
		case map[string]any:
			switch q := v["path"].(type) {
			case string:
				paths = []string{q}
			case []any:
				for _, x := range q {
					if s, ok := x.(string); ok {
						paths = append(paths, s)
					}
				}
			}
		}
		for _, inc := range paths {
			target, err := p.local(path, inc, "include:")
			if err != nil {
				return err
			}
			if err := p.file(target); err != nil {
				return err
			}
		}
	}
	services, _ := root["services"].(map[string]any)
	for _, name := range slices.Sorted(maps.Keys(services)) {
		svc, ok := services[name].(map[string]any)
		if !ok {
			continue
		}
		if name == cyfrService {
			p.defines = append(p.defines, p.rel(path))
		}
		if err := p.service(path, svc, name, name == cyfrService, map[string]bool{}); err != nil {
			return err
		}
	}
	return nil
}

// local resolves a path a compose file names, relative to that file,
// refusing one cyfr cannot read before compose does: a remote reference
// or one that interpolates a variable.
func (p *provenance) local(from, name, what string) (string, error) {
	if strings.Contains(name, "$") || strings.Contains(name, "://") || strings.HasPrefix(name, "git@") || strings.HasPrefix(name, "oci:") {
		return "", fmt.Errorf("%s names %s %q, which cyfr cannot check before compose reads it. Nothing started. Name a local file in its place", p.rel(from), what, name)
	}
	if filepath.IsAbs(name) {
		return filepath.Clean(name), nil
	}
	return filepath.Clean(filepath.Join(filepath.Dir(from), name)), nil
}

// service checks one definition of a service and the service it extends:
// the names its environment: assigns as written, and, in cyfr's chain,
// its env_file.
func (p *provenance) service(path string, svc map[string]any, name string, cyfr bool, chain map[string]bool) error {
	key := path + "\x00" + name
	if chain[key] {
		return nil
	}
	chain[key] = true
	for _, k := range environmentKeys(svc["environment"]) {
		switch {
		case strings.Contains(k, "$"):
			return Refuse("compose_override_refused", map[string]string{"file": p.rel(path), "service": name, "key": k, "why": "interpolated"})
		case cyfr && slices.Contains(headKeys(), k):
			return Refuse("compose_override_refused", map[string]string{"file": p.rel(path), "service": name, "key": k})
		}
	}
	if cyfr {
		for _, f := range envFiles(svc["env_file"]) {
			if target, err := p.local(path, f, "env_file:"); err == nil && target == filepath.Join(p.e.dir, ".env") {
				p.envFile = true
			}
		}
	}
	if svc["extends"] == nil {
		return nil
	}
	base, file := "", ""
	switch v := svc["extends"].(type) {
	case string:
		base = v
	case map[string]any:
		base, _ = v["service"].(string)
		file, _ = v["file"].(string)
	}
	target := path
	if file != "" {
		var err error
		if target, err = p.local(path, file, "extends:"); err != nil {
			return err
		}
	}
	root, err := p.load(target)
	if err != nil {
		return err
	}
	services, _ := root["services"].(map[string]any)
	next, ok := services[base].(map[string]any)
	if !ok {
		return fmt.Errorf("access: the %s service of %s extends %s, which %s does not define", name, p.rel(path), base, p.rel(target))
	}
	return p.service(target, next, base, cyfr, chain)
}

// environmentKeys are the names an environment: block assigns as
// written, in byte order: a mapping's keys, and each list entry's name
// before its first = (`NAME=value`, or `NAME` taken from the
// environment).
func environmentKeys(env any) []string {
	var keys []string
	switch v := env.(type) {
	case map[string]any:
		for k := range v {
			keys = append(keys, k)
		}
	case []any:
		for _, item := range v {
			if s, ok := item.(string); ok {
				k, _, _ := strings.Cut(s, "=")
				keys = append(keys, strings.TrimSpace(k))
			}
		}
	}
	slices.Sort(keys)
	return keys
}

// envFiles are the paths an env_file: names, as one path, a list of
// paths, or a list of {path, required}.
func envFiles(v any) []string {
	switch f := v.(type) {
	case string:
		return []string{f}
	case []any:
		var out []string
		for _, item := range f {
			switch x := item.(type) {
			case string:
				out = append(out, x)
			case map[string]any:
				if s, ok := x["path"].(string); ok {
					out = append(out, s)
				}
			}
		}
		return out
	}
	return nil
}
