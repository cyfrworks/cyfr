// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package access

import (
	"context"
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"testing"
	"time"
)

func TestProjectNameIsComposesDefault(t *testing.T) {
	for dir, want := range map[string]string{
		"/srv/home": "home", "/srv/My Home.v2": "myhomev2", "/srv/_cyfr-1": "cyfr-1", "/srv/--x_y": "x_y", "/srv/ÉtÉ": "t",
	} {
		if got := projectName(dir); got != want {
			t.Errorf("projectName(%q) = %q, want %q", dir, got, want)
		}
	}
}

// The default file set is one main file and at most one override, and is
// refused when compose's own choice would not be determined.
func TestDefaultFileSetIsRefusedWhenNotDetermined(t *testing.T) {
	h := newHome(t)
	writeFile(t, filepath.Join(h.dir, "docker-compose.override.yml"), []byte("services: {}\n"))
	if files, err := h.e.defaultFiles(); err != nil || !slices.Equal(files, []string{"docker-compose.yml", "docker-compose.override.yml"}) {
		t.Errorf("the file set is %v, %v", files, err)
	}
	writeFile(t, filepath.Join(h.dir, "compose.override.yaml"), []byte("services: {}\n"))
	if _, err := h.e.defaultFiles(); err == nil || !strings.Contains(err.Error(), "override files") {
		t.Errorf("two override files answered %v", err)
	}
	os.Remove(filepath.Join(h.dir, "compose.override.yaml"))
	writeFile(t, filepath.Join(h.dir, "compose.yaml"), []byte("services: {}\n"))
	if _, err := h.e.defaultFiles(); err == nil || !strings.Contains(err.Error(), "compose.yaml and docker-compose.yml") {
		t.Errorf("two main files answered %v", err)
	}
}

// Materialized configurations: one per head, named by its digest, mode
// 0600, every later compose call of the operation on exactly that file;
// a source changed mid-operation is not read again; the journal names
// each file before it exists; completion removes them all.
func TestMaterializedFilesAreTheOperationsInputs(t *testing.T) {
	h := newHome(t)
	h.fake.startStack(t, h.head())
	r := h.request(id(1), publicTarget, "")
	name := resolvedName(r.NewDigest)
	var checked bool
	h.fake.hook = func(_ context.Context, c *fakeCall) *fakeAnswer {
		if c.Args[0] != "compose" || !slices.Contains(c.Args, "--no-deps") || checked {
			return nil
		}
		checked = true
		info, err := os.Stat(filepath.Join(h.dir, name))
		if err != nil || runtime.GOOS != "windows" && info.Mode().Perm() != 0o600 {
			t.Errorf("the materialized file is %v, %v", info, err)
		}
		if j, _ := h.e.readJournal(); j == nil || !slices.Contains(j.Files, name) {
			t.Errorf("the journal does not name %s: %+v", name, j)
		}
		// The compose file changes under the operation: the proxy's
		// image is no longer the one checked.
		compose := filepath.Join(h.dir, "docker-compose.yml")
		data, _ := os.ReadFile(compose)
		writeFile(t, compose, []byte(strings.Replace(string(data), "image: caddy:2.11-alpine", "image: evil/caddy", 1)))
		return nil
	}
	if rc, err := h.e.Switch(bg, r); err != nil || rc.Outcome != "ok" {
		t.Fatalf("switch answered %+v, %v", rc, err)
	}
	if !checked {
		t.Fatal("no start ran")
	}
	for _, c := range h.fake.calls() {
		if c.Args[0] == "compose" && !slices.Contains(c.Args, "config") && !slices.Contains(c.Args, name) {
			t.Errorf("a compose call of the operation is not on %s: %s", name, c)
		}
	}
	h.fake.mu.Lock()
	image := h.fake.st.Containers["home-caddy-1"].Image
	h.fake.mu.Unlock()
	if !strings.HasPrefix(image, "caddy:2.11-alpine") {
		t.Errorf("the proxy started from %q, a source changed mid-operation", image)
	}
	h.assertConverged(publicStack...)
}

// An interrupted operation keeps exactly the files its journal names;
// recovery never starts from a kept file: it materializes afresh, and
// removes them once it is done.
func TestKeptFilesAreNeverUsedToStart(t *testing.T) {
	h := newHome(t)
	h.fake.startStack(t, h.head())
	r := h.request(id(1), publicTarget, "")
	h.killAt("journal:switch:rolling_back", func(e *Engine) {
		unhealthyWhen(h, "CYFR_ACCESS=public")
		e.Switch(bg, r)
	})
	h.fake.hook, h.fake.st.Health = nil, "healthy"
	j, _ := h.e.readJournal()
	kept := h.files(resolvedGlob)
	var named []string
	for _, f := range j.Files {
		named = append(named, filepath.Base(f))
	}
	slices.Sort(named)
	if !slices.Equal(kept, named) || len(kept) == 0 {
		t.Fatalf("kept %v, the journal names %v", kept, named)
	}
	// A kept file tampered with: a start from it would run its image.
	path := filepath.Join(h.dir, resolvedName(r.NewDigest))
	data, _ := os.ReadFile(path)
	writeFile(t, path, []byte(strings.ReplaceAll(string(data), "ghcr.io/cyfrworks/cyfr:latest", "evil/cyfr")))
	if _, err := h.e.Resume(bg); err != nil {
		t.Fatal(err)
	}
	h.fake.mu.Lock()
	image := h.fake.st.Containers["cyfr"].Image
	h.fake.mu.Unlock()
	if image != "ghcr.io/cyfrworks/cyfr:latest" {
		t.Errorf("recovery started cyfr from %q, a kept file", image)
	}
	h.assertConverged(publicStack...)
}

// overrideSets is compose_override_refused's sentence for a head key a
// compose file assigns, word for word.
func overrideSets(file, service, key string) string {
	return "`" + file + "` sets `" + key + "` in the `" + service + "` service's environment, where it would override how .env says CYFR is reached. Nothing started. Remove `" + key + "` from `" + file + "`; .env alone holds it, and `cyfr access` writes it."
}

// overrideNames is compose_override_refused's sentence for a name
// written with `$` in a service's environment, word for word.
func overrideNames(file, service, key string) string {
	return "`" + file + "` names `" + key + "` in the `" + service + "` service's environment, a name with `$` in it, which cyfr cannot check before Docker Compose reads it. Nothing started. Write the name in `" + file + "` without `$`."
}

// Provenance, before anything is flattened: a head key in the cyfr
// service's own environment: entries in any file of the source set is
// refused with compose_override_refused naming the file, the service and
// the key, even with the value .env holds; .env must reach cyfr through
// its env_file; access settings through env_file alone pass. A name written
// with `$` in any service's environment, a list entry's or a mapping
// key, is refused as written, whatever compose would make of it; a value
// is not read, so one that interpolates, even a variable set nowhere,
// passes. A start refused so changes nothing and answers the same
// refusal.
func TestCheckStackReadsTheSourcesProvenance(t *testing.T) {
	for _, c := range []struct {
		name               string
		files              map[string]string
		file, service, key string
		plain              string
	}{
		{name: "shipped"},
		{"override", map[string]string{"docker-compose.override.yml": "services:\n  cyfr:\n    environment:\n      - CYFR_HOST=localhost\n"}, "docker-compose.override.yml", "cyfr", "CYFR_HOST", ""},
		{"mapping form", map[string]string{"docker-compose.override.yml": "services:\n  cyfr:\n    environment:\n      CYFR_ACCESS: local\n"}, "docker-compose.override.yml", "cyfr", "CYFR_ACCESS", ""},
		{"inherited", map[string]string{"docker-compose.override.yml": "services:\n  cyfr:\n    environment:\n      - CYFR_PORT\n"}, "docker-compose.override.yml", "cyfr", "CYFR_PORT", ""},
		{"include", map[string]string{
			"docker-compose.override.yml": "include:\n  - extra/more.yml\n",
			"extra/more.yml":              "services:\n  cyfr:\n    environment:\n      CYFR_PUBLIC_URL: https://x.example.com\n",
		}, "extra/more.yml", "cyfr", "CYFR_PUBLIC_URL", ""},
		{"extends", map[string]string{
			"docker-compose.override.yml": "services:\n  cyfr:\n    extends:\n      file: base.yml\n      service: base\n",
			"base.yml":                    "services:\n  base:\n    environment:\n      - CYFR_TAILNET_NODE_ID=n1\n",
		}, "base.yml", "base", "CYFR_TAILNET_NODE_ID", ""},
		{name: "remote include", files: map[string]string{"docker-compose.override.yml": "include:\n  - oci://example.com/stack\n"}, plain: "cannot check"},
		// A name with `$`, wherever and however it is written.
		{"interpolated key", map[string]string{"docker-compose.override.yml": "services:\n  cyfr:\n    environment:\n      - ${HOSTKEY}=localhost\n"}, "docker-compose.override.yml", "cyfr", "${HOSTKEY}", ""},
		{"interpolated bare name", map[string]string{"docker-compose.override.yml": "services:\n  cyfr:\n    environment:\n      - $HOSTKEY\n"}, "docker-compose.override.yml", "cyfr", "$HOSTKEY", ""},
		{"unresolvable key", map[string]string{"docker-compose.override.yml": "services:\n  cyfr:\n    environment:\n      - ${NOT_SET_ANYWHERE}=localhost\n"}, "docker-compose.override.yml", "cyfr", "${NOT_SET_ANYWHERE}", ""},
		{"interpolated mapping key", map[string]string{"docker-compose.override.yml": "services:\n  cyfr:\n    environment:\n      ${HOSTKEY}: localhost\n"}, "docker-compose.override.yml", "cyfr", "${HOSTKEY}", ""},
		{"interpolated key in another service", map[string]string{"docker-compose.override.yml": "services:\n  locus-runtime:\n    environment:\n      - ${PREFIX}_SETTING=1\n"}, "docker-compose.override.yml", "locus-runtime", "${PREFIX}_SETTING", ""},
		{"interpolated key in an extended service", map[string]string{
			"docker-compose.override.yml": "services:\n  helper:\n    image: busybox:latest\n    extends:\n      file: base.yml\n      service: base\n",
			"base.yml":                    "services:\n  base:\n    environment:\n      - $${HOSTKEY}=1\n",
		}, "base.yml", "base", "$${HOSTKEY}", ""},
		{name: "interpolated value", files: map[string]string{"docker-compose.override.yml": "services:\n  cyfr:\n    environment:\n      SOME_SETTING: ${HOSTKEY}\n"}},
		{name: "unset value", files: map[string]string{"docker-compose.override.yml": "services:\n  cyfr:\n    environment:\n      - SOME_SETTING=${NOT_SET_ANYWHERE}\n"}},
		// Every merge form.
		{"merged service sequence", map[string]string{"docker-compose.override.yml": "x-part: &part\n  cyfr:\n    environment:\n      CYFR_HOST: localhost\nservices:\n  <<: [*part]\n"}, "docker-compose.override.yml", "cyfr", "CYFR_HOST", ""},
		{"merged environment alias", map[string]string{"docker-compose.override.yml": "x-env: &env\n  CYFR_PORT: \"4000\"\nservices:\n  cyfr:\n    environment:\n      <<: *env\n"}, "docker-compose.override.yml", "cyfr", "CYFR_PORT", ""},
		{"nested merges", map[string]string{"docker-compose.override.yml": "x-inner: &inner\n  environment:\n    CYFR_ACCESS: local\nx-outer: &outer\n  <<: [*inner]\nx-svc: &svc\n  cyfr:\n    <<: *outer\nservices:\n  <<: *svc\n"}, "docker-compose.override.yml", "cyfr", "CYFR_ACCESS", ""},
	} {
		t.Run(c.name, func(t *testing.T) {
			h := newHome(t)
			for name, text := range c.files {
				os.MkdirAll(filepath.Dir(filepath.Join(h.dir, name)), 0o755)
				writeFile(t, filepath.Join(h.dir, name), []byte(text))
			}
			writeFile(t, h.e.envPath(), []byte(h.env()+"HOSTKEY=CYFR_HOST\n"))
			err := h.e.CheckStack(bg)
			switch {
			case c.file == "" && c.plain == "":
				if err != nil {
					t.Fatalf("CheckStack refused it: %v", err)
				}
				return
			case c.plain != "":
				if err == nil || refusalCode(err) != "" || !strings.Contains(err.Error(), c.plain) {
					t.Fatalf("CheckStack answered %v, want %q", err, c.plain)
				}
				return
			}
			want := map[string]string{"file": c.file, "service": c.service, "key": c.key}
			sentence := overrideSets(c.file, c.service, c.key)
			if strings.Contains(c.key, "$") {
				want["why"] = "interpolated"
				sentence = overrideNames(c.file, c.service, c.key)
			}
			var r *Refusal
			if !asRefusal(err, &r) || r.Code != "compose_override_refused" || !mapsEqual(r.Payload, want) || r.Class != "invalid_argument" {
				t.Fatalf("CheckStack answered %v, want compose_override_refused %v", err, want)
			}
			if got := r.Message(); got != sentence {
				t.Errorf("the sentence reads %q", got)
			}
			before := h.snapshot()
			rc, err := h.e.Start(bg, "up")
			if !asRefusal(err, &r) || r.Code != "compose_override_refused" || rc.State != "rejected" || rc.Code != "compose_override_refused" || !mapsEqual(rc.Payload, want) {
				t.Errorf("start answered %+v, %v", rc, err)
			}
			if !mapsEqual(before, h.snapshot()) {
				t.Error("a refused start changed a file")
			}
			for _, call := range h.fake.calls() {
				if slices.Contains(call.Args, "up") {
					t.Errorf("a refused stack ran %s", call)
				}
			}
		})
	}

	h := newHome(t)
	compose := filepath.Join(h.dir, "docker-compose.yml")
	data, _ := os.ReadFile(compose)
	writeFile(t, compose, []byte(strings.Replace(string(data), "    env_file:\n      - .env\n    # Every access", "    # Every access", 1)))
	writeFile(t, filepath.Join(h.dir, "docker-compose.override.yml"), []byte("services:\n  cyfr:\n    image: ghcr.io/cyfrworks/cyfr:latest\n"))
	var r *Refusal
	err := h.e.CheckStack(bg)
	if !asRefusal(err, &r) || r.Code != "compose_override_refused" || !mapsEqual(r.Payload, map[string]string{"file": "docker-compose.yml", "service": "cyfr"}) {
		t.Fatalf("a cyfr service without .env in its env_file answered %v", err)
	}
	if want := "`docker-compose.yml` does not give the `cyfr` service .env through its env_file, so it would not read how CYFR is reached. Nothing started. Add `env_file: .env` to the `cyfr` service in `docker-compose.yml`, as the shipped docker-compose.yml has it."; r.Message() != want {
		t.Errorf("the sentence reads %q", r.Message())
	}
}

// The effective values are checked as the release would boot them: .env
// against what compose gives cyfr.
func TestCheckStackValidatesTheEffectiveValues(t *testing.T) {
	h := newHome(t)
	writeFile(t, filepath.Join(h.dir, ".env"), append(repoFile(t, ".env.example"), []byte("CYFR_BIND_ADDRESS=127.0.0.1\n")...))
	if err := h.e.CheckStack(bg); refusalCode(err) != "access_source_conflict" {
		t.Errorf("a .env bind the compose file overrides answered %v", err)
	}
	writeFile(t, filepath.Join(h.dir, ".env"), append(repoFile(t, ".env.example"), []byte("CYFR_LOCAL_INGRESS_ASSERTED=true\n")...))
	if err := h.e.CheckStack(bg); refusalCode(err) != "access_source_conflict" && refusalCode(err) != "access_assertion_from_file" {
		t.Errorf("the assertion from .env answered %v", err)
	}
}

// ComposeArgs never runs a stale configuration: its file is reused while
// every input reads as it did, and made afresh, under the same name, once
// the compose file, a file it includes, or .env has changed.
func TestComposeArgsFollowsItsInputs(t *testing.T) {
	h := newHome(t)
	writeFile(t, filepath.Join(h.dir, "docker-compose.override.yml"), []byte("include:\n  - extra.yml\n"))
	writeFile(t, filepath.Join(h.dir, "extra.yml"), []byte("services:\n  extra:\n    image: extra:one\n"))
	head := h.head()
	path := filepath.Join(h.dir, resolvedName(head.Digest()))
	configs := func() int {
		return len(slices.DeleteFunc(h.fake.calls(), func(c fakeCall) bool { return c.Args[0] != "compose" || !slices.Contains(c.Args, "config") }))
	}
	read := func() string {
		args, err := h.e.ComposeArgs(bg, head, "ps")
		if err != nil {
			t.Fatal(err)
		}
		if !slices.Contains(args, resolvedName(head.Digest())) {
			t.Fatalf("ComposeArgs answered %v", args)
		}
		data, _ := os.ReadFile(path)
		return string(data)
	}
	first := read()
	if again := read(); again != first || configs() != 1 {
		t.Errorf("unchanged inputs were read again (%d config calls)", configs())
	}
	for _, change := range []struct{ name, file, from, to, want string }{
		{"the compose file", "docker-compose.yml", "ghcr.io/cyfrworks/cyfr:latest", "ghcr.io/cyfrworks/cyfr:0.9.1", "image: ghcr.io/cyfrworks/cyfr:0.9.1"},
		{"an included file", "extra.yml", "extra:one", "extra:two", "image: extra:two"},
		{".env", ".env", "CYFR_PRIVATE_EGRESS_TARGETS=locus-backends", "CYFR_PRIVATE_EGRESS_TARGETS=locus-backends,db", "CYFR_PRIVATE_EGRESS_TARGETS: locus-backends,db"},
	} {
		before, calls := read(), configs()
		data, _ := os.ReadFile(filepath.Join(h.dir, change.file))
		writeFile(t, filepath.Join(h.dir, change.file), []byte(strings.Replace(string(data), change.from, change.to, 1)))
		after := read()
		if configs() != calls+1 || !strings.Contains(after, change.want) {
			t.Errorf("%s changed and ComposeArgs did not run the configuration it now gives", change.name)
		}
		if after == before {
			t.Errorf("%s changed and the materialized file is the same", change.name)
		}
	}
}

// StartWithin waits as long as its caller says for cyfr's health; Start
// waits HealthDeadline.
func TestStartWithinWaitsItsOwnHealth(t *testing.T) {
	h := newHome(t)
	h.fake.st.Health = "starting"
	for _, c := range []struct {
		start func() (Receipt, error)
		wait  time.Duration
	}{
		{func() (Receipt, error) { return h.e.Start(bg, "up") }, HealthDeadline},
		{func() (Receipt, error) { return h.e.StartWithin(bg, "update", 15*time.Minute) }, 15 * time.Minute},
	} {
		before := h.clock.Now()
		rc, err := c.start()
		waited := h.clock.Now().Sub(before)
		if err == nil || rc.Outcome != "failed" || !strings.Contains(err.Error(), "not healthy within "+c.wait.String()) || waited < c.wait || waited > c.wait+time.Minute {
			t.Errorf("a %s wait answered %+v, %v after %s", c.wait, rc, err, waited)
		}
		h.e.Stop(bg, "down", true)
	}
}

// ProjectName and DefaultFiles are the engine's own resolution, for the
// commands that need them.
func TestProjectNameAndDefaultFiles(t *testing.T) {
	h := newHome(t)
	wd, _ := os.Getwd()
	t.Cleanup(func() { os.Chdir(wd) })
	os.Chdir(h.dir)
	if got := ProjectName("."); got != "home" {
		t.Errorf("ProjectName(.) = %q", got)
	}
	if main, override, err := DefaultFiles(h.dir); main != "docker-compose.yml" || override != "" || err != nil {
		t.Errorf("DefaultFiles = %q, %q, %v", main, override, err)
	}
	writeFile(t, filepath.Join(h.dir, "compose.override.yaml"), []byte("services: {}\n"))
	if main, override, err := DefaultFiles(h.dir); main != "docker-compose.yml" || override != "compose.override.yaml" || err != nil {
		t.Errorf("DefaultFiles = %q, %q, %v", main, override, err)
	}
	writeFile(t, filepath.Join(h.dir, "compose.yml"), []byte("services: {}\n"))
	if _, _, err := DefaultFiles(h.dir); err == nil {
		t.Error("two main files are not refused")
	}
}
