// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package reach

import (
	"context"
	"fmt"
	"maps"
	"os"
	"path/filepath"
	"slices"
	"strings"

	"gopkg.in/yaml.v3"
)

// The services the engine names: cyfr itself, and the tailnet proxy
// whose Serve configuration it writes. Every other reach service comes
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
	files, err := e.defaultFiles()
	if err != nil {
		return nil, err
	}
	res, err := e.docker.Run(ctx, Call{Args: append(e.selection(files, h), "config"), Deadline: StopDeadline})
	if err != nil {
		return nil, fmt.Errorf("reach: docker compose config failed (%v): %s", err, lastLine(res.Stderr))
	}
	return res.Stdout, nil
}

// materialize writes h's configuration afresh to
// .cyfr/compose.resolved.<digest>.yml (0600: it holds .env's values),
// after checking the stack it describes (checkStack). An operation with
// a journal names the file there before writing it, so an interrupted
// operation keeps exactly the files its journal names.
func (e *Engine) materialize(ctx context.Context, h Head, j *journal) ([]byte, error) {
	if err := e.checkProvenance(); err != nil {
		return nil, err
	}
	stamp := e.sourceStamp()
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
	e.files[name] = stamp
	e.mu.Unlock()
	return content, nil
}

// sourceStamp fingerprints what a flattened configuration is read from:
// the default file set and .env.
func (e *Engine) sourceStamp() string {
	files, _ := e.defaultFiles()
	var all []byte
	for _, f := range append(files, ".env") {
		data, _ := os.ReadFile(filepath.Join(e.dir, f))
		all = append(all, []byte(f+"\x00"+sha256Hex(data)+"\x00")...)
	}
	return sha256Hex(all)
}

// composeArgs is a compose command of h on its materialized file.
func (e *Engine) composeArgs(h Head, args ...string) []string {
	return append(e.selection([]string{resolvedName(h.Digest())}, h), args...)
}

// composeArgsFor is ComposeArgs: h's file is materialized on first use
// and reused while its sources read as they did then; a command that
// rewrote the compose file or .env since gets the configuration they now
// give.
func (e *Engine) composeArgsFor(ctx context.Context, h Head, args ...string) ([]string, error) {
	name := resolvedName(h.Digest())
	e.mu.Lock()
	stamp, held := e.files[name]
	e.mu.Unlock()
	if _, err := os.Stat(filepath.Join(e.dir, filepath.FromSlash(name))); !held || err != nil || stamp != e.sourceStamp() {
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
		return fmt.Errorf("reach: remove materialized configuration: %v", errs)
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

func parseConfig(content []byte) (config, error) {
	var c config
	if err := yaml.Unmarshal(content, &c); err != nil {
		return c, fmt.Errorf("reach: read the flattened configuration: %w", err)
	}
	return c, nil
}

// reachServices are the services of c that h's reach profiles select:
// every profile of h but locus-builds, which a switch never changes.
func reachServices(c config, h Head) []string {
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

// servicesOf reads h's reach services from content, or from a flattened
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
	return reachServices(c, h), nil
}

// otherServices are c's services that are not reach services of h.
func otherServices(c config, h Head) []string {
	reach := reachServices(c, h)
	var out []string
	for name := range c.Services {
		if !slices.Contains(reach, name) {
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
		return fmt.Errorf("reach: the stack's configuration has no %s service", cyfrService)
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
		return fmt.Errorf("reach: the stack's configuration starts cyfr reached as %s, not as %s", wordsText(Describe(b.Head)), wordsText(Describe(h)))
	}
	return nil
}

// checkStack is CheckStack: the sources, then the effective values of
// .env's head, reading and writing nothing under .cyfr/.
func (e *Engine) checkStack(ctx context.Context) error {
	if err := e.checkProvenance(); err != nil {
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
// the default files and every file they include, and each service the
// cyfr service extends, wherever it is. No head key may be assigned in
// the cyfr service's own environment: entries there would override what
// .env says, and the flattened configuration cannot show where a value
// came from. .env must reach cyfr through its env_file.
func (e *Engine) checkProvenance() error {
	files, err := e.defaultFiles()
	if err != nil {
		return err
	}
	p := &provenance{e: e, seen: map[string]bool{}}
	for _, f := range files {
		if err := p.file(filepath.Join(e.dir, f)); err != nil {
			return err
		}
	}
	if !p.envFile {
		return fmt.Errorf(".env does not reach the cyfr service through its env_file in %s, so cyfr would not read how this home is reached. Nothing started. Give the cyfr service `env_file: [.env]`", strings.Join(files, " or "))
	}
	return nil
}

type provenance struct {
	e       *Engine
	seen    map[string]bool
	envFile bool
}

func (p *provenance) rel(path string) string {
	if r, err := filepath.Rel(p.e.dir, path); err == nil {
		return filepath.ToSlash(r)
	}
	return path
}

// load reads a compose file into its top-level mapping node.
func (p *provenance) load(path string) (*yaml.Node, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("reach: read %s: %w", p.rel(path), err)
	}
	var doc yaml.Node
	if err := yaml.Unmarshal(data, &doc); err != nil {
		return nil, fmt.Errorf("reach: read %s: %w", p.rel(path), err)
	}
	if len(doc.Content) == 0 {
		return &yaml.Node{Kind: yaml.MappingNode}, nil
	}
	return doc.Content[0], nil
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
	if inc := mapping(root, "include"); inc != nil {
		var entries []any
		if err := inc.Decode(&entries); err != nil {
			return fmt.Errorf("reach: read the include: list of %s: %w", p.rel(path), err)
		}
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
	}
	if svc := mapping(mapping(root, "services"), cyfrService); svc != nil {
		return p.service(path, svc, cyfrService, map[string]bool{})
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

// service checks one definition of a service in cyfr's chain: its own
// environment: entries, its env_file, and the service it extends.
func (p *provenance) service(path string, svc *yaml.Node, name string, chain map[string]bool) error {
	key := path + "\x00" + name
	if chain[key] {
		return nil
	}
	chain[key] = true
	var def struct {
		Environment any `yaml:"environment"`
		EnvFile     any `yaml:"env_file"`
		Extends     any `yaml:"extends"`
	}
	if err := svc.Decode(&def); err != nil {
		return fmt.Errorf("reach: read the %s service of %s: %w", name, p.rel(path), err)
	}
	for _, k := range environmentKeys(def.Environment) {
		if slices.Contains(headKeys(), k) {
			return fmt.Errorf("%s sets %s in the %s service's environment:, where it would override .env; how this home is reached comes from .env alone, which `cyfr reach` writes. Nothing started. Remove %s from %s", p.rel(path), k, name, k, p.rel(path))
		}
	}
	for _, f := range envFiles(def.EnvFile) {
		if target, err := p.local(path, f, "env_file:"); err == nil && target == filepath.Join(p.e.dir, ".env") {
			p.envFile = true
		}
	}
	if def.Extends == nil {
		return nil
	}
	base, file := "", ""
	switch v := def.Extends.(type) {
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
	next := mapping(mapping(root, "services"), base)
	if next == nil {
		return fmt.Errorf("reach: the %s service of %s extends %s, which %s does not define", name, p.rel(path), base, p.rel(target))
	}
	return p.service(target, next, base, chain)
}

// environmentKeys are the names an environment: block assigns, in its
// mapping form or its list form (`NAME=value`, or `NAME` taken from the
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

// mapping is the value of key in the mapping node m, or nil.
func mapping(m *yaml.Node, key string) *yaml.Node {
	if m == nil || m.Kind != yaml.MappingNode {
		return nil
	}
	for i := 0; i+1 < len(m.Content); i += 2 {
		if m.Content[i].Value == key {
			return m.Content[i+1]
		}
	}
	// A merge key's mapping, as compose reads `<<: *anchor`.
	for i := 0; i+1 < len(m.Content); i += 2 {
		if m.Content[i].Tag == "!!merge" || m.Content[i].Value == "<<" {
			v := m.Content[i+1]
			if v.Kind == yaml.AliasNode {
				v = v.Alias
			}
			if found := mapping(v, key); found != nil {
				return found
			}
		}
	}
	return nil
}

func lastLine(b []byte) string {
	lines := strings.Split(strings.TrimSpace(string(b)), "\n")
	return strings.TrimSpace(lines[len(lines)-1])
}
