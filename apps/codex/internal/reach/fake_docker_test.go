// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package reach

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"sync"
	"time"

	"gopkg.in/yaml.v3"
)

// fakeDocker is docker as the engine sees it: compose over the project's
// real compose files, the containers it starts, the tailscale state
// volume's machine, and the join containers. It records every call and
// lets a test fail, block or rewrite any of them. The state is plain
// data, so the same model also answers as a docker binary (fakeBinary)
// for the tests that run the system implementation.
type fakeDocker struct {
	mu    sync.Mutex
	st    fakeState
	dir   string
	env   []string
	clock *fakeClock
	// hook runs before a call is answered; a non-nil answer replaces it.
	hook func(ctx context.Context, c *fakeCall) *fakeAnswer
}

type fakeState struct {
	Project    string
	Containers map[string]*fakeContainer
	Volumes    map[string]*fakeNode
	Networks   map[string]bool
	// Health is what cyfr's health check reads once it starts.
	Health string
	// The machines a login makes: their tailnet's domain, whether HTTPS
	// certificates are on, and how many logins there have been.
	Domain  string
	NoHTTPS bool
	Logins  int
	Calls   []fakeCall
	// Pause blocks the first call whose arguments hold Match until the
	// file Release exists (the binary model only).
	Pause *fakePause
}

type fakePause struct {
	Match, Paused, Release string
	Done                   bool
}

type fakeContainer struct {
	Name, Service, State, Health string
	Image                        string
	Profiles                     []string
	Env                          map[string]string
	// A join container: its labels, its state volume, and the key it is
	// waiting for on its standard input.
	Join             bool
	JoinID, Deadline string
	Volume           string
	WantsKey         bool
	Hostname, Key    string
}

// fakeNode is the machine a tailscale state volume holds.
type fakeNode struct {
	LoggedIn bool
	Name, ID string
	HTTPS    bool
	AuthURL  string
	Key      string
}

type fakeCall struct {
	Args     []string
	Env      []string `json:",omitempty"`
	Stdin    string   `json:",omitempty"`
	Deadline time.Duration
	// Serve is Serve's configuration when the call ran.
	Serve string
	// Env and .env as the call found them, for the order checks.
	DotEnv string
	// The binary model's process facts: its process group, the lock's
	// descriptor and its working directory.
	OwnGroup bool   `json:",omitempty"`
	LockFD   bool   `json:",omitempty"`
	Dir      string `json:",omitempty"`
}

func (c fakeCall) String() string { return strings.Join(c.Args, " ") }

type fakeAnswer struct {
	Stdout, Stderr string
	Code           int
}

func newFakeDocker(dir string, clock *fakeClock) *fakeDocker {
	return &fakeDocker{dir: dir, clock: clock, st: fakeState{
		Project: projectName(dir), Containers: map[string]*fakeContainer{}, Volumes: map[string]*fakeNode{},
		Networks: map[string]bool{}, Health: "healthy", Domain: "tail1234.ts.net",
	}}
}

func (f *fakeDocker) Run(ctx context.Context, c Call) (Result, error) {
	var stdin string
	if c.Stdin != nil {
		data, _ := io.ReadAll(c.Stdin)
		stdin = string(data)
	}
	call := &fakeCall{Args: slices.Clone(c.Args), Env: f.env, Stdin: stdin, Deadline: c.Deadline}
	if f.hook != nil {
		if a := f.hook(ctx, call); a != nil {
			f.mu.Lock()
			f.record(call)
			f.mu.Unlock()
			return f.result(c, *a)
		}
	}
	if len(c.Args) > 0 && c.Args[0] == "attach" {
		// An attached call reads its input, then stays until it is
		// killed, as `docker attach` does.
		f.mu.Lock()
		a := f.handle(call)
		f.mu.Unlock()
		if a.Code == 0 {
			<-ctx.Done()
			a.Code = 137
		}
		return f.result(c, a)
	}
	f.mu.Lock()
	a := f.handle(call)
	f.mu.Unlock()
	return f.result(c, a)
}

func (f *fakeDocker) result(c Call, a fakeAnswer) (Result, error) {
	r := Result{ExitCode: a.Code}
	if c.Stdout != nil {
		io.WriteString(c.Stdout, a.Stdout)
	} else {
		r.Stdout = []byte(a.Stdout)
	}
	if c.Stderr != nil {
		io.WriteString(c.Stderr, a.Stderr)
	} else {
		r.Stderr = []byte(a.Stderr)
	}
	if a.Code != 0 {
		return r, &CallError{ExitCode: a.Code}
	}
	return r, nil
}

func (f *fakeDocker) record(c *fakeCall) {
	serve, _ := os.ReadFile(filepath.Join(f.dir, stateDir, serveDir, serveFile))
	env, _ := os.ReadFile(filepath.Join(f.dir, ".env"))
	c.Serve, c.DotEnv = string(serve), string(env)
	f.st.Calls = append(f.st.Calls, *c)
}

func (f *fakeDocker) calls() []fakeCall {
	f.mu.Lock()
	defer f.mu.Unlock()
	return slices.Clone(f.st.Calls)
}

func (f *fakeDocker) now() time.Time {
	if f.clock != nil {
		return f.clock.Now()
	}
	return time.Now().UTC()
}

func fail(code int, format string, args ...any) fakeAnswer {
	return fakeAnswer{Stderr: fmt.Sprintf(format, args...) + "\n", Code: code}
}

// handle answers one call; f.mu is held.
func (f *fakeDocker) handle(c *fakeCall) fakeAnswer {
	f.record(c)
	f.expireJoins()
	args := c.Args
	if len(args) == 0 {
		return fail(1, "no command")
	}
	switch args[0] {
	case "compose":
		return f.compose(c)
	case "ps":
		return f.ps(args)
	case "inspect":
		name := args[len(args)-1]
		ct, ok := f.st.Containers[name]
		if !ok {
			return fail(1, "Error: No such object: %s", name)
		}
		st := map[string]any{"Status": ct.State, "ExitCode": 0}
		if ct.Health != "" {
			st["Health"] = map[string]string{"Status": ct.Health}
		}
		out, _ := json.Marshal(st)
		return fakeAnswer{Stdout: string(out) + "\n"}
	case "stop", "rm":
		names := slices.DeleteFunc(slices.Clone(args[1:]), func(a string) bool { return strings.HasPrefix(a, "-") })
		var errs []string
		for _, n := range names {
			ct, ok := f.st.Containers[n]
			if !ok {
				errs = append(errs, "Error response from daemon: No such container: "+n)
				continue
			}
			if args[0] == "stop" {
				ct.State = "exited"
			} else {
				delete(f.st.Containers, n)
			}
		}
		if len(errs) > 0 {
			return fakeAnswer{Stderr: strings.Join(errs, "\n") + "\n", Code: 1}
		}
		return fakeAnswer{Stdout: strings.Join(names, "\n") + "\n"}
	case "volume":
		return f.volume(args[1:])
	case "network":
		name := args[len(args)-1]
		switch args[1] {
		case "inspect":
			if !f.st.Networks[name] {
				return fail(1, "Error response from daemon: network %s not found", name)
			}
		case "create":
			f.st.Networks[name] = true
		}
		return fakeAnswer{Stdout: name + "\n"}
	case "run":
		return f.run(args[1:])
	case "attach":
		name := args[len(args)-1]
		ct, ok := f.st.Containers[name]
		if !ok || !ct.WantsKey {
			return fail(1, "Error: cannot attach to %s", name)
		}
		ct.Key = strings.TrimSuffix(c.Stdin, "\n")
		ct.WantsKey = false
		if node := f.st.Volumes[ct.Volume]; node != nil && !node.LoggedIn && ct.Key != "" {
			f.login(node, ct.Hostname, ct.Key)
		}
		return fakeAnswer{}
	case "exec":
		return f.exec(args[1:])
	}
	return fail(1, "fake docker: unknown command %q", args[0])
}

// expireJoins ends the join containers whose own deadline passed, as
// `timeout` and `--rm` end them.
func (f *fakeDocker) expireJoins() {
	for name, ct := range f.st.Containers {
		if !ct.Join {
			continue
		}
		if t, err := time.Parse(time.RFC3339, ct.Deadline); err == nil && !f.now().Before(t) {
			delete(f.st.Containers, name)
		}
	}
}

func (f *fakeDocker) login(node *fakeNode, hostname, key string) {
	f.st.Logins++
	node.LoggedIn, node.Key, node.AuthURL = true, key, ""
	node.Name = hostname + "." + f.st.Domain
	node.ID = fmt.Sprintf("n%04dCNTRL", f.st.Logins)
	node.HTTPS = !f.st.NoHTTPS
}

// approve logs the volume's machine in, as a person approving the link.
func (f *fakeDocker) approve(volume, hostname string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	node := f.st.Volumes[volume]
	if node == nil {
		node = &fakeNode{}
		f.st.Volumes[volume] = node
	}
	f.login(node, hostname, "")
}

func (f *fakeDocker) volume(args []string) fakeAnswer {
	name := args[len(args)-1]
	switch args[0] {
	case "inspect":
		if _, ok := f.st.Volumes[name]; !ok {
			return fail(1, "Error response from daemon: get %s: no such volume", name)
		}
	case "create":
		if _, ok := f.st.Volumes[name]; !ok {
			f.st.Volumes[name] = &fakeNode{}
		}
	case "rm":
		for _, ct := range f.st.Containers {
			if ct.Volume == name && running(ct.State) {
				return fail(1, "Error response from daemon: remove %s: volume is in use", name)
			}
		}
		delete(f.st.Volumes, name)
	}
	return fakeAnswer{Stdout: name + "\n"}
}

func (f *fakeDocker) status(node *fakeNode) fakeAnswer {
	s := map[string]any{"BackendState": "NeedsLogin", "AuthURL": node.AuthURL, "Self": map[string]string{"DNSName": "", "ID": ""}, "CertDomains": nil}
	if node.LoggedIn {
		s["BackendState"], s["AuthURL"] = "Running", ""
		s["Self"] = map[string]string{"DNSName": node.Name + ".", "ID": node.ID}
		if node.HTTPS {
			s["CertDomains"] = []string{node.Name}
		}
	}
	out, _ := json.Marshal(s)
	return fakeAnswer{Stdout: string(out) + "\n"}
}

func (f *fakeDocker) nodeOf(volume string) *fakeNode {
	node := f.st.Volumes[volume]
	if node == nil {
		node = &fakeNode{}
		f.st.Volumes[volume] = node
	}
	if !node.LoggedIn && node.AuthURL == "" {
		node.AuthURL = fmt.Sprintf("https://login.tailscale.com/a/%d", len(f.st.Calls))
	}
	return node
}

func (f *fakeDocker) exec(args []string) fakeAnswer {
	name := args[0]
	ct, ok := f.st.Containers[name]
	if !ok || !running(ct.State) {
		return fail(1, "Error response from daemon: container %s is not running", name)
	}
	if len(args) >= 3 && args[1] == "tailscale" && args[2] == "status" {
		if ct.WantsKey {
			return fail(1, "failed to connect to local tailscaled")
		}
		return f.status(f.nodeOf(ct.Volume))
	}
	return fail(1, "fake docker: cannot exec %v", args[1:])
}

func (f *fakeDocker) run(args []string) fakeAnswer {
	ct := &fakeContainer{State: "running", Join: true, Env: map[string]string{}}
	labels := map[string]string{}
	var detach bool
	i := 0
	for ; i < len(args) && strings.HasPrefix(args[i], "-"); i++ {
		switch args[i] {
		case "-d":
			detach = true
		case "-i":
			ct.WantsKey = true
		case "--rm":
		case "--name":
			i++
			ct.Name = args[i]
		case "--label":
			i++
			k, v, _ := strings.Cut(args[i], "=")
			labels[k] = v
		case "--network":
			i++
			if !f.st.Networks[args[i]] {
				return fail(125, "network %s not found", args[i])
			}
		case "-v":
			i++
			ct.Volume, _, _ = strings.Cut(args[i], ":")
		case "-e":
			i++
			k, v, _ := strings.Cut(args[i], "=")
			ct.Env[k] = v
		default:
			return fail(125, "fake docker run: unknown flag %s", args[i])
		}
	}
	if !detach || i >= len(args) {
		return fail(125, "fake docker run: wants -d and an image")
	}
	ct.Image = args[i]
	ct.Hostname = ct.Env["TS_HOSTNAME"]
	ct.JoinID, ct.Deadline = labels[labelJoinID], labels[labelJoinDeadline]
	if _, ok := f.st.Containers[ct.Name]; ok {
		return fail(125, "Conflict. The container name %s is already in use", ct.Name)
	}
	for _, other := range f.st.Containers {
		if other.Volume == ct.Volume && running(other.State) {
			return fail(125, "fake docker: %s already runs a tailscaled on %s", other.Name, ct.Volume)
		}
	}
	f.st.Containers[ct.Name] = ct
	node := f.nodeOf(ct.Volume)
	_ = node
	return fakeAnswer{Stdout: ct.Name + "\n"}
}

func (f *fakeDocker) ps(args []string) fakeAnswer {
	filter := ""
	for i, a := range args {
		if a == "--filter" {
			filter = args[i+1]
		}
	}
	var lines []string
	names := slices.Sorted(func(yield func(string) bool) {
		for n := range f.st.Containers {
			if !yield(n) {
				return
			}
		}
	})
	for _, n := range names {
		ct := f.st.Containers[n]
		switch {
		case filter == "label="+labelProject+"="+f.st.Project && !ct.Join:
			out, _ := json.Marshal(map[string]string{"name": ct.Name, "service": ct.Service, "state": ct.State})
			lines = append(lines, string(out))
		case filter == "label="+labelJoinProject+"="+f.st.Project && ct.Join:
			out, _ := json.Marshal(map[string]string{"name": ct.Name, "join_id": ct.JoinID, "deadline": ct.Deadline, "state": ct.State})
			lines = append(lines, string(out))
		}
	}
	if len(lines) == 0 {
		return fakeAnswer{}
	}
	return fakeAnswer{Stdout: strings.Join(lines, "\n") + "\n"}
}

// compose answers `compose -p P -f F… --project-directory . --profile X…
// <command>`, honouring COMPOSE_PROFILES, COMPOSE_FILE and
// COMPOSE_PROJECT_NAME from the call's environment as compose does.
func (f *fakeDocker) compose(c *fakeCall) fakeAnswer {
	args := c.Args[1:]
	var files, profiles []string
	project := ""
	for _, kv := range c.Env {
		k, v, _ := strings.Cut(kv, "=")
		switch k {
		case "COMPOSE_PROFILES":
			profiles = append(profiles, strings.Split(v, ",")...)
		case "COMPOSE_FILE":
			files = append(files, strings.Split(v, string(os.PathListSeparator))...)
		case "COMPOSE_PROJECT_NAME":
			project = v
		}
	}
	explicitFiles := false
	i := 0
	for ; i < len(args) && strings.HasPrefix(args[i], "-"); i++ {
		switch args[i] {
		case "-p":
			i++
			project = args[i]
		case "-f":
			i++
			if !explicitFiles {
				files, explicitFiles = nil, true
			}
			files = append(files, args[i])
		case "--project-directory":
			i++
		case "--profile":
			i++
			profiles = append(profiles, args[i])
		default:
			return fail(1, "fake compose: unknown flag %s", args[i])
		}
	}
	if project != f.st.Project {
		return fail(1, "fake compose: project %q, not %q", project, f.st.Project)
	}
	if i >= len(args) {
		return fail(1, "fake compose: no command")
	}
	cmd, rest := args[i], args[i+1:]
	cfg, err := f.load(files, profiles, c.Env)
	if err != nil {
		return fail(1, "%v", err)
	}
	switch cmd {
	case "config":
		out, _ := yaml.Marshal(cfg)
		return fakeAnswer{Stdout: string(out)}
	case "up":
		var names []string
		for _, a := range rest {
			if !strings.HasPrefix(a, "-") {
				names = append(names, a)
			}
		}
		if len(names) == 0 {
			names = slices.Sorted(func(yield func(string) bool) {
				for n := range cfg.Services {
					if !yield(n) {
						return
					}
				}
			})
		}
		for _, n := range names {
			svc, ok := cfg.Services[n]
			if !ok {
				return fail(1, "no such service: %s", n)
			}
			name := svc.ContainerName
			if name == "" {
				name = project + "-" + n + "-1"
			}
			ct := &fakeContainer{Name: name, Service: n, State: "running", Image: svc.Image, Profiles: svc.Profiles, Env: svc.Environment}
			if n == cyfrService {
				ct.Health = f.st.Health
			}
			if n == serveService {
				ct.Volume = project + "_tailscale_state"
			}
			f.st.Containers[name] = ct
		}
		return fakeAnswer{}
	case "exec":
		svcName := ""
		for _, a := range rest {
			if !strings.HasPrefix(a, "-") {
				svcName = a
				break
			}
		}
		for _, ct := range f.st.Containers {
			if ct.Service == svcName && !ct.Join {
				return f.exec(append([]string{ct.Name}, rest[slices.Index(rest, svcName)+1:]...))
			}
		}
		return fail(1, "service %q is not running", svcName)
	case "down":
		for n, ct := range f.st.Containers {
			if !ct.Join {
				delete(f.st.Containers, n)
			}
		}
		return fakeAnswer{}
	}
	return fail(1, "fake compose: unknown command %s", cmd)
}

// fakeConfig is the flattened configuration the fake writes and reads.
type fakeConfig struct {
	Name     string                    `yaml:"name"`
	Services map[string]*fakeService   `yaml:"services"`
	Volumes  map[string]map[string]any `yaml:"volumes,omitempty"`
}

type fakeService struct {
	ContainerName string            `yaml:"container_name,omitempty"`
	Image         string            `yaml:"image,omitempty"`
	Profiles      []string          `yaml:"profiles,omitempty"`
	Environment   map[string]string `yaml:"environment,omitempty"`
}

// load reads the compose files and flattens them for the profiles: a
// materialized file as it is, a source set merged service by service, its
// env_file .env inlined and its ${…} interpolated from .env and the
// environment.
func (f *fakeDocker) load(files, profiles []string, env []string) (*fakeConfig, error) {
	if len(files) == 0 {
		return nil, fmt.Errorf("fake compose: no file named")
	}
	dotenv := map[string]string{}
	if data, err := os.ReadFile(filepath.Join(f.dir, ".env")); err == nil {
		if d, err := readDotenv(data, composeEnv); err == nil {
			dotenv = d.values()
		}
	}
	lookup := func(k string) (string, bool) {
		for _, kv := range env {
			if name, v, _ := strings.Cut(kv, "="); name == k {
				return v, true
			}
		}
		v, ok := dotenv[k]
		return v, ok
	}
	if len(files) == 1 && strings.HasPrefix(filepath.ToSlash(files[0]), stateDir+"/") {
		data, err := os.ReadFile(filepath.Join(f.dir, files[0]))
		if err != nil {
			return nil, fmt.Errorf("open %s: no such file or directory", files[0])
		}
		var cfg fakeConfig
		if err := yaml.Unmarshal(data, &cfg); err != nil {
			return nil, err
		}
		return &cfg, nil
	}
	cfg := &fakeConfig{Name: f.st.Project, Services: map[string]*fakeService{}}
	for i := 0; i < len(files); i++ {
		data, err := os.ReadFile(filepath.Join(f.dir, files[i]))
		if err != nil {
			return nil, err
		}
		var doc struct {
			Include  []string                  `yaml:"include"`
			Services map[string]map[string]any `yaml:"services"`
		}
		if err := yaml.Unmarshal(data, &doc); err != nil {
			return nil, err
		}
		files = append(files, doc.Include...)
		for svcName, raw := range doc.Services {
			svc := cfg.Services[svcName]
			if svc == nil {
				svc = &fakeService{Environment: map[string]string{}}
				cfg.Services[svcName] = svc
			}
			if v, ok := raw["container_name"].(string); ok {
				svc.ContainerName = v
			}
			if v, ok := raw["image"].(string); ok {
				svc.Image = interpolate(v, lookup)
			}
			if v, ok := raw["profiles"].([]any); ok {
				svc.Profiles = nil
				for _, p := range v {
					svc.Profiles = append(svc.Profiles, fmt.Sprint(p))
				}
			}
			for _, envFile := range envFiles(raw["env_file"]) {
				if filepath.Clean(envFile) == ".env" {
					for k, v := range dotenv {
						svc.Environment[k] = v
					}
				}
			}
			switch e := raw["environment"].(type) {
			case []any:
				for _, item := range e {
					k, v, _ := strings.Cut(fmt.Sprint(item), "=")
					svc.Environment[k] = interpolate(v, lookup)
				}
			case map[string]any:
				for k, v := range e {
					svc.Environment[k] = interpolate(fmt.Sprint(v), lookup)
				}
			}
		}
	}
	for name, svc := range cfg.Services {
		if len(svc.Profiles) > 0 && !slices.ContainsFunc(svc.Profiles, func(p string) bool { return slices.Contains(profiles, p) }) {
			delete(cfg.Services, name)
		}
	}
	return cfg, nil
}

var interpolation = regexp.MustCompile(`\$\{([A-Za-z0-9_]+)(?:(:?[-?])([^}]*))?\}`)

func interpolate(s string, lookup func(string) (string, bool)) string {
	return interpolation.ReplaceAllStringFunc(s, func(m string) string {
		sub := interpolation.FindStringSubmatch(m)
		v, ok := lookup(sub[1])
		switch sub[2] {
		case ":-":
			if !ok || v == "" {
				return sub[3]
			}
		case "-":
			if !ok {
				return sub[3]
			}
		}
		return v
	})
}

// fakeClock is the engine's time in a test: a sleep advances it at once.
type fakeClock struct {
	mu  sync.Mutex
	now time.Time
	// onSleep runs at each sleep, after the clock moved.
	onSleep func(now time.Time)
}

func newFakeClock() *fakeClock {
	return &fakeClock{now: time.Date(2026, 10, 19, 12, 0, 0, 0, time.UTC)}
}

func (c *fakeClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *fakeClock) Sleep(ctx context.Context, d time.Duration) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	c.mu.Lock()
	c.now = c.now.Add(d)
	now, hook := c.now, c.onSleep
	c.mu.Unlock()
	if hook != nil {
		hook(now)
	}
	return ctx.Err()
}

func (c *fakeClock) advance(d time.Duration) {
	c.mu.Lock()
	c.now = c.now.Add(d)
	c.mu.Unlock()
}

// running containers of the fake, by service.
func (f *fakeDocker) runningServices() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	var out []string
	for _, ct := range f.st.Containers {
		if running(ct.State) {
			if ct.Join {
				out = append(out, "join")
			} else {
				out = append(out, ct.Service)
			}
		}
	}
	slices.Sort(out)
	return out
}

// startStack starts every service of head h's selection, as a stack
// already running before a test's operation.
func (f *fakeDocker) startStack(t interface{ Fatalf(string, ...any) }, h Head) {
	args := []string{"compose", "-p", f.st.Project}
	files := []string{"docker-compose.yml"}
	if _, err := os.Stat(filepath.Join(f.dir, "docker-compose.override.yml")); err == nil {
		files = append(files, "docker-compose.override.yml")
	}
	for _, file := range files {
		args = append(args, "-f", file)
	}
	args = append(args, "--project-directory", ".")
	for _, p := range h.Profiles {
		args = append(args, "--profile", p)
	}
	f.mu.Lock()
	a := f.handle(&fakeCall{Args: append(args, "up", "-d")})
	f.st.Calls = nil
	f.mu.Unlock()
	if a.Code != 0 {
		t.Fatalf("start the stack: %s", a.Stderr)
	}
}
