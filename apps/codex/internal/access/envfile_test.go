// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package access

import (
	"maps"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// .env reads as compose's dotenv reads it: `export`, `:` as well as `=`,
// space around either, quoted values across lines, an inline comment
// after a bare value, a bare name taking the environment's value or none,
// and the last assignment winning.
func TestDotenvReadsAsComposeDoes(t *testing.T) {
	text := strings.Join([]string{
		"# a comment",
		"A=1",
		"  export B = two",
		"C: three",
		`D="four # not a comment"`,
		"E=five # a comment",
		`F="multi`,
		`COMPOSE_PROFILES=inside a quoted value`,
		`line"`,
		"G='single'",
		"H",
		"A=last",
		"",
	}, "\n")
	d, err := readDotenv([]byte(text), noEnv)
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]string{
		"A": "last", "B": "two", "C": "three", "D": "four # not a comment", "E": "five",
		"F": "multi\nCOMPOSE_PROFILES=inside a quoted value\nline", "G": "single",
	}
	if got := d.values(); !maps.Equal(got, want) {
		t.Errorf("values %v\nwant   %v", got, want)
	}
	if key := d.composeKey(); key != "" {
		t.Errorf("a COMPOSE_ line inside a quoted value reads as the setting %s", key)
	}
	inherited, err := readDotenv([]byte(text), func(k string) (string, bool) { return "from the environment", k == "H" })
	if err != nil || inherited.values()["H"] != "from the environment" {
		t.Errorf("the bare name H reads %q (%v)", inherited.values()["H"], err)
	}
	if out, err := EditEnv([]byte(text), nil, nil); err != nil || string(out) != text {
		t.Errorf("the file does not write back byte for byte: %q, %v", out, err)
	}
}

// noEnv is an environment that sets nothing.
func noEnv(string) (string, bool) { return "", false }

// A switch's .env changes only the head's keys, through EditEnv: a
// changed key on its last assignment's lines, every other assignment of
// it gone; a removed key loses every line, an inheriting one too; a key
// .env lacks is appended at the end; an unchanged key keeps its own
// spelling; every other line is kept byte for byte.
func TestEnvWriterChangesOnlyTheHeadsKeys(t *testing.T) {
	before := strings.Join([]string{
		"# keep me",
		"CYFR_SECRET_KEY_BASE=abc",
		"CYFR_ACCESS=public",
		`CYFR_HOST="home.example.com"`,
		"CYFR_PORT='4000'",
		"CYFR_PUBLIC_URL=https://home.example.com",
		"OTHER=x # trailing",
		"CADDY_ACME_EMAIL=a@example.com",
		"CADDY_ACME_EMAIL=b@example.com",
		"CYFR_TAILNET_NODE_ID",
		"CYFR_LOCUS_BUILDS_URL=",
		"",
	}, "\n")
	want := strings.Join([]string{
		"# keep me",
		"CYFR_SECRET_KEY_BASE=abc",
		"CYFR_ACCESS=tailnet",
		`CYFR_HOST=cyfr.tail1234.ts.net`,
		"CYFR_PORT='4000'",
		"CYFR_PUBLIC_URL=https://cyfr.tail1234.ts.net",
		"OTHER=x # trailing",
		"CYFR_TAILNET_NODE_ID=nAbc123CNTRL",
		"CYFR_LOCUS_BUILDS_URL=",
		"",
	}, "\n")
	d, err := Derive(Target{Mode: ModeTailnet}, Current{Port: 4000}, &Join{Name: "cyfr.tail1234.ts.net", NodeID: "nAbc123CNTRL"})
	if err != nil {
		t.Fatal(err)
	}
	// The node id's inheriting line is its assignment, rewritten in
	// place; the email's two lines both go.
	edit := func(text string, h Head) string {
		out, err := editHeadKeys([]byte(text), keysOf(h))
		if err != nil {
			t.Fatal(err)
		}
		return string(out)
	}
	if got := edit(before, d.Head); got != want {
		t.Errorf(".env became\n%s\nwant\n%s", got, want)
	}

	// A key .env lacks entirely goes right after CYFR_ACCESS.
	minimal := "A=1\nCYFR_ACCESS=local\nCYFR_HOST=localhost\nB=2\n"
	pub, _ := Derive(Target{Mode: ModePublic, Domain: "home.example.com"}, Current{Port: 4000}, nil)
	got := edit(minimal, pub.Head)
	if want := "A=1\nCYFR_ACCESS=public\nCYFR_HOST=home.example.com\nB=2\nCYFR_PORT=4000\nCYFR_PUBLIC_URL=https://home.example.com\n"; got != want {
		t.Errorf("a minimal .env became\n%s\nwant\n%s", got, want)
	}
	read, err := readDotenv([]byte(got), noEnv)
	if err != nil {
		t.Fatal(err)
	}
	if h, err := headOf(read.values()); err != nil || h.Digest() != pub.Head.Digest() {
		t.Errorf("the written .env holds %+v (%v), not the head", h, err)
	}
}

// A .env that names any COMPOSE_* setting, compose's way of writing it
// included, is refused by the first in byte order, before any docker
// call: by Start, the head's read and the stack check alike. The project
// still opens, so recovery can stop the stack.
func TestComposeSettingsInEnvAreRefused(t *testing.T) {
	for _, line := range []string{"COMPOSE_PROFILES=public,tailnet", "COMPOSE_PROFILES: public", "  export COMPOSE_FILE = x.yml\nCOMPOSE_PROFILES=public", "COMPOSE_PROJECT_NAME"} {
		dir := filepath.Join(t.TempDir(), "home")
		os.Mkdir(dir, 0o755)
		writeFile(t, filepath.Join(dir, ".env"), append(repoFile(t, ".env.example"), []byte(line+"\n")...))
		writeFile(t, filepath.Join(dir, "docker-compose.yml"), repoFile(t, "docker-compose.yml"))
		fake := newFakeDocker(dir, nil)
		e, err := Open(dir, fake)
		if err != nil {
			t.Fatalf("%q: the project does not open: %v", line, err)
		}
		unlock, err := e.Lock("up")
		if err != nil {
			t.Fatal(err)
		}
		_, err = e.Start(bg, "up")
		unlock()
		want := strings.Fields(strings.NewReplacer("=", " ", ":", " ", "export", "").Replace(line))[0]
		var r *Refusal
		if !asRefusal(err, &r) || r.Code != "compose_env_refused" || r.Payload["key"] != want {
			t.Errorf("%q: Start answered %v, want compose_env_refused naming %s", line, err, want)
			continue
		}
		if _, err := e.Head(); refusalCode(err) != "compose_env_refused" {
			t.Errorf("%q: Head answered %v", line, err)
		}
		if err := e.CheckStack(bg); refusalCode(err) != "compose_env_refused" {
			t.Errorf("%q: CheckStack answered %v", line, err)
		}
		if !strings.Contains(r.Message(), "`.env` sets `"+want+"`") {
			t.Errorf("the sentence reads %q", r.Message())
		}
		if calls := fake.calls(); len(calls) != 0 {
			t.Errorf("%q: docker was called: %v", line, calls)
		}
	}
}

func asRefusal(err error, r **Refusal) bool {
	ref, ok := err.(*Refusal)
	if ok {
		*r = ref
	}
	return ok
}

// ReadEnvValues reads a .env as compose does: the export and colon forms,
// quoting, and a later assignment overriding an earlier one.
func TestReadEnvValues(t *testing.T) {
	path := filepath.Join(t.TempDir(), ".env")
	writeFile(t, path, []byte("CYFR_PORT=4000\nexport CYFR_HOST = home.example.com\nCYFR_ACCESS: public\nCYFR_PUBLIC_URL=\"https://home.example.com\"\nCYFR_PORT=4100 # later\n"))
	got, err := ReadEnvValues(path)
	want := map[string]string{"CYFR_PORT": "4100", "CYFR_HOST": "home.example.com", "CYFR_ACCESS": "public", "CYFR_PUBLIC_URL": "https://home.example.com"}
	if err != nil || !maps.Equal(got, want) {
		t.Errorf("ReadEnvValues = %v, %v\nwant %v", got, err, want)
	}
	if _, err := ReadEnvValues(filepath.Join(t.TempDir(), "none")); err == nil {
		t.Error("a missing file reads")
	}
}

// CheckEnvFile refuses what the engine would before anything starts: a
// COMPOSE_* setting in any form first, then the head's boot refusal, a
// later assignment deciding it; a coherent home's .env passes.
func TestCheckEnvFile(t *testing.T) {
	base := string(repoFile(t, ".env.example"))
	for _, c := range []struct {
		name, extra, code, sentence string
	}{
		{"coherent", "", "", ""},
		{"colon form", "COMPOSE_PROFILES: public\n", "compose_env_refused", "`.env` sets `COMPOSE_PROFILES`, which Docker Compose would read to choose this stack's files, project or services behind cyfr's back. Nothing started. Remove it; cyfr chooses them from CYFR_ACCESS and CYFR_LOCUS_BUILDS_URL."},
		{"export form", "export COMPOSE_FILE=x.yml\nCYFR_ACCESS=sideways\n", "compose_env_refused", ""},
		{"later assignment", "CYFR_ACCESS=sideways\n", "access_unknown_mode", "CYFR_ACCESS is `sideways`; it must be `local`, `tailnet` or `public`. Run `cyfr access <mode>` to set it with the address it implies."},
		{"later assignment restores", "CYFR_ACCESS=sideways\nCYFR_ACCESS=local\n", "", ""},
	} {
		t.Run(c.name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), ".env")
			writeFile(t, path, []byte(base+c.extra))
			err := CheckEnvFile(path)
			if refusalCode(err) != c.code || (c.code == "") != (err == nil) {
				t.Fatalf("CheckEnvFile answered %v, want %s", err, c.code)
			}
			if c.sentence != "" && err.(*Refusal).Message() != c.sentence {
				t.Errorf("the sentence reads %q", err.(*Refusal).Message())
			}
		})
	}
}

// EditEnv reads .env as the engine and compose read it: a quoted value's
// lines, even ones that look like `KEY=…` or `KEY: …`, are its value and
// stay untouched; a set key's last assignment is rewritten and its
// earlier ones removed, whatever their form; an unset key loses every
// assignment; a new key is appended; a value that needs quotes reads back
// as itself.
func TestEditEnv(t *testing.T) {
	text := strings.Join([]string{
		"# a comment",
		"A=1",
		`PEM="-----BEGIN-----`,
		`A=inside the value`,
		`B: inside too`,
		`-----END-----"`,
		"export A = 2",
		"B: 3",
		"C='x",
		"A=still inside",
		"'",
		"D",
		"",
	}, "\n")
	values := []string{"plain", "has space", "has # hash", `has "double" quotes`, "it's single", "two\nlines", ""}
	line := func(key, value string) string {
		l, err := envLine(key, value)
		if err != nil {
			t.Fatal(err)
		}
		return l
	}
	for _, v := range values {
		got, err := EditEnv([]byte(text), map[string]string{"A": v, "NEW": v}, []string{"B", "D"})
		if err != nil {
			t.Errorf("value %q: EditEnv refused: %v", v, err)
			continue
		}
		want := strings.Join([]string{
			"# a comment",
			`PEM="-----BEGIN-----`,
			`A=inside the value`,
			`B: inside too`,
			`-----END-----"`,
			line("A", v),
			"C='x",
			"A=still inside",
			"'",
			line("NEW", v),
			"",
		}, "\n")
		if string(got) != want {
			t.Errorf("value %q: EditEnv gave\n%s\nwant\n%s", v, got, want)
			continue
		}
		d, err := readDotenv(got, noEnv)
		if err != nil {
			t.Fatal(err)
		}
		read := d.values()
		if read["A"] != v || read["NEW"] != v || read["PEM"] != "-----BEGIN-----\nA=inside the value\nB: inside too\n-----END-----" || read["C"] != "x\nA=still inside\n" {
			t.Errorf("value %q reads back as %q", v, read)
		}
		if _, ok := read["B"]; ok {
			t.Errorf("value %q: B is still assigned", v)
		}
	}
	if got, err := EditEnv(nil, map[string]string{"K": "v"}, nil); err != nil || string(got) != "K=v\n" {
		t.Errorf("an empty file became %q (%v)", got, err)
	}
	if got, err := EditEnv([]byte("A=1"), map[string]string{"K": "v"}, nil); err != nil || string(got) != "A=1\nK=v\n" {
		t.Errorf("a file without a final newline became %q (%v)", got, err)
	}
}

// EditEnvFile edits the file durably and keeps its mode; a new file is
// private to its owner.
func TestEditEnvFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, ".env")
	writeFile(t, path, []byte("A=1\nB=2\n"))
	os.Chmod(path, 0o640)
	if err := EditEnvFile(path, map[string]string{"A": "one"}, []string{"B"}); err != nil {
		t.Fatal(err)
	}
	got, _ := os.ReadFile(path)
	info, _ := os.Stat(path)
	if string(got) != "A=one\n" || runtime.GOOS != "windows" && info.Mode().Perm() != 0o640 {
		t.Errorf("the file is %q, mode %v", got, info.Mode())
	}
	fresh := filepath.Join(dir, "new.env")
	if err := EditEnvFile(fresh, map[string]string{"K": "v"}, nil); err != nil {
		t.Fatal(err)
	}
	if info, _ := os.Stat(fresh); runtime.GOOS != "windows" && info.Mode().Perm() != 0o600 {
		t.Errorf("a new file has mode %v", info.Mode())
	}
	if left, _ := filepath.Glob(filepath.Join(dir, ".*.tmp-*")); len(left) != 0 {
		t.Errorf("temporary files are left: %v", left)
	}
}
