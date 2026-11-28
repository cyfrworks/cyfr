// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package access

import (
	"bytes"
	"cmp"
	"context"
	"fmt"
	"maps"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
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
// inlined. With proxy it is read again with proxyOverlay over the set.
func (e *Engine) flatten(ctx context.Context, h Head) ([]byte, error) {
	content, err := e.readConfig(ctx, h, nil, "config")
	if err != nil || h.Browser != BrowserProxy {
		return content, err
	}
	c, err := parseConfig(content)
	if err != nil {
		return nil, err
	}
	overlay, err := proxyOverlay(h, cyfrEnv(c)["CYFR_BIND_ADDRESS"])
	if err != nil {
		return nil, err
	}
	return e.readConfig(ctx, h, overlay, "config")
}

// proxyOverlay is the compose file, read last, that publishes the proxy
// listener for proxy, the one kind whose proxy is outside the stack. No
// other kind publishes it, so only proxy lets anything outside the stack
// send the proxy listener forwarded headers it trusts.
//
//   - It publishes the proxy listener's port at the head's CYFR_PROXY_PUBLISH,
//     an IPv4 loopback address of this machine.
//   - The listener binds the loopback listener's own address, bind, on
//     the stack's default network: Docker publishes a port at the
//     container's address on that network, and the edge network's,
//     which the listener binds for Caddy and Tailscale, receives nothing
//     published. No other container joins the default network. A stack
//     whose cyfr service names no such address is refused: the
//     publication would reach no listener.
//   - CYFR_TRUSTED_PROXY_CIDRS is .env's alone: the stack's default names
//     Caddy's and Tailscale's addresses, which do not run with proxy, and
//     would stand in for the trust proxy requires .env to state.
func proxyOverlay(h Head, bind string) ([]byte, error) {
	published, err := publishOf(h.Publish, h.Port)
	if err != nil {
		return nil, err
	}
	if bind == "" {
		return nil, fmt.Errorf("access: the stack's %s service names no CYFR_BIND_ADDRESS, the address its proxy listener is published at with proxy, so CYFR cannot be reached through your proxy. Nothing started. Give the %s service the shipped docker-compose.yml's CYFR_BIND_ADDRESS", cyfrService, cyfrService)
	}
	overlay := map[string]any{"services": map[string]any{cyfrService: map[string]any{
		"ports": []map[string]any{{
			"host_ip": published.Address, "published": strconv.Itoa(published.Port),
			"target": "${CYFR_PROXY_PORT:-4001}", "protocol": "tcp",
		}},
		"environment": map[string]string{
			"CYFR_PROXY_BIND_ADDRESS":  bind,
			"CYFR_TRUSTED_PROXY_CIDRS": "${CYFR_TRUSTED_PROXY_CIDRS:-}",
		},
	}}}
	return yaml.Marshal(overlay)
}

// declaredProfiles is DeclaredProfiles: `docker compose config --profiles`
// over the default file set, under no selection.
func (e *Engine) declaredProfiles(ctx context.Context) ([]string, error) {
	out, err := e.readConfig(ctx, Head{}, nil, "config", "--profiles")
	return strings.Fields(string(out)), err
}

// readConfig is compose's read args over the default file set, and
// overlay read last from standard input when there is one, under h's
// selection, its stdout.
func (e *Engine) readConfig(ctx context.Context, h Head, overlay []byte, args ...string) ([]byte, error) {
	// compose reads COMPOSE_* from .env: no compose call runs over one
	// that sets any.
	if _, err := e.readEnv(); err != nil {
		return nil, err
	}
	files, err := e.defaultFiles()
	if err != nil {
		return nil, err
	}
	call := Call{Deadline: StopDeadline}
	if overlay != nil {
		files = append(files, "-")
		call.Stdin = bytes.NewReader(overlay)
	}
	call.Args = append(e.selection(files, h), args...)
	res, err := e.docker.Run(ctx, call)
	if err != nil {
		return nil, fmt.Errorf("access: %s", e.callFailed("docker compose "+strings.Join(args, " "), err, res.Stderr))
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
		SyncDir(e.path())
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
		Ports       []publication      `yaml:"ports"`
		NetworkMode string             `yaml:"network_mode"`
	} `yaml:"services"`
	// Networks are the subnets the stack fixes (heldBy).
	Networks map[string]struct {
		Ipam struct {
			Config []struct {
				Subnet string `yaml:"subnet"`
			} `yaml:"config"`
		} `yaml:"ipam"`
	} `yaml:"networks"`
}

// publication is one published port of a flattened service, as compose
// writes it: the container port, the host address and port (an empty one
// Docker picks), and the protocol.
type publication struct {
	Target    int    `yaml:"target"`
	HostIP    string `yaml:"host_ip"`
	Published string `yaml:"published"`
	Protocol  string `yaml:"protocol"`
}

func (p publication) String() string {
	host := p.HostIP
	if host == "" {
		host = "every address"
	}
	published := p.Published
	if published == "" {
		published = "a port Docker picks"
	}
	return fmt.Sprintf("%d/%s on %s at %s", p.Target, cmp.Or(p.Protocol, "tcp"), host, published)
}

// checkPublished holds cyfr's final published ports, whatever file put
// them there, to what b's kind allows, judged by the listener each
// binding reaches: a binding reaches the listener on its target port. The
// loopback listener is every kind's; the proxy listener, the one whose
// forwarded headers are trusted, exists with a browser address alone.
//
//   - With proxy, cyfr publishes exactly two bindings: the loopback
//     listener once on this machine's 127.0.0.1, and the proxy listener
//     once at CYFR_PROXY_PUBLISH. Nothing else, and neither is missing.
//     Its two listeners bind one address (proxyOverlay), so they cannot
//     share a port; if they did, no binding could be told apart, and it
//     is refused.
//   - With tailnet and domain, no binding reaches the proxy listener alone.
//     Where the two listeners share a port number at different addresses,
//     which the boot allows, the configuration cannot tell which a binding
//     of that port reaches (Docker publishes at the address of the
//     container's gateway network, which the flattened file does not
//     settle): such a binding stands.
//   - With none there is no proxy listener, and every binding stands.
//
// A cyfr service in the host's network is refused whatever the kind:
// there Docker publishes nothing and every listener is on the host's own
// addresses, so no publication holds.
func checkPublished(c config, b Boot) error {
	if mode := c.Services[cyfrService].NetworkMode; mode == "host" {
		return fmt.Errorf("access: the stack's cyfr service runs in the host's network (network_mode: host), where Docker publishes no port and CYFR's listeners are on the host's own addresses, so neither is held to its publication. Nothing started. Remove network_mode from the cyfr service")
	}
	refused := func(p publication, why string) error {
		return fmt.Errorf("access: the stack's configuration publishes cyfr's port %s, and %s. Nothing started. Remove that publication from the compose file that adds it", p, why)
	}
	loopback := func(p publication) bool { return p.Target == b.Loopback.Port }
	proxy := func(p publication) bool { return b.Proxy != nil && p.Target == b.Proxy.Port }
	tcp := func(p publication) bool { return cmp.Or(p.Protocol, "tcp") == "tcp" }
	ports := c.Services[cyfrService].Ports
	if b.Published == nil {
		for _, p := range ports {
			if proxy(p) && !loopback(p) && tcp(p) {
				return refused(p, "the proxy listener, whose forwarded headers are trusted, is published only with CYFR_BROWSER=proxy, at CYFR_PROXY_PUBLISH")
			}
		}
		return nil
	}
	if b.Proxy.Port == b.Loopback.Port {
		return fmt.Errorf("access: cyfr's loopback listener and proxy listener both take port %d, so no publication of that port can be told to reach the one and not the other. Nothing started. Give CYFR_PORT and CYFR_PROXY_PORT different ports", b.Loopback.Port)
	}
	only := "with proxy cyfr publishes its loopback listener once on 127.0.0.1 and its proxy listener once at CYFR_PROXY_PUBLISH, " + b.Published.Address + ":" + strconv.Itoa(b.Published.Port) + ", and nothing else"
	var loopbacks, proxies int
	for _, p := range ports {
		switch {
		case !tcp(p):
			return refused(p, only)
		case loopback(p) && p.HostIP == "127.0.0.1" && loopbacks == 0:
			loopbacks++
		case proxy(p) && p.HostIP == b.Published.Address && p.Published == strconv.Itoa(b.Published.Port) && proxies == 0:
			proxies++
		default:
			return refused(p, only)
		}
	}
	switch {
	case loopbacks == 0:
		return fmt.Errorf("access: the stack's configuration does not publish cyfr's loopback listener on this machine's 127.0.0.1, which %s. Nothing started", only)
	case proxies == 0:
		return fmt.Errorf("access: the stack's configuration does not publish cyfr's proxy listener at CYFR_PROXY_PUBLISH, %s:%d, so your proxy cannot reach it. Nothing started", b.Published.Address, b.Published.Port)
	}
	return nil
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

// accessServices are the services of c that h's access profiles select.
func accessServices(c config, h Head) []string {
	var out []string
	for name, svc := range c.Services {
		for _, p := range svc.Profiles {
			if slices.Contains(h.Profiles, p) {
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

// everyAccessService is every service the stack's configuration puts in a
// kind's profile, whichever head selects it: what a stop of the access
// services must cover when a head cannot say, and what a start removes
// when its head does not select it.
func (e *Engine) everyAccessService(ctx context.Context) ([]string, error) {
	return e.servicesOf(ctx, Head{Profiles: BrowserProfiles()}, nil)
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
// process, a release's rules, and the head that answers must be h without
// its profiles no kind selects: those choose more of the stack's own
// services (an update's selection of the stack an older release left) and
// reach no setting of cyfr's.
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
	reach := h
	reach.Profiles = slices.DeleteFunc(slices.Clone(h.Profiles), func(p string) bool { return !slices.Contains(BrowserProfiles(), p) })
	if b.Head.Digest() != reach.Digest() {
		return fmt.Errorf("access: the stack's configuration starts cyfr reached as %s, not as %s", wordsText(Describe(b.Head)), wordsText(Describe(h)))
	}
	return checkPublished(c, b)
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
