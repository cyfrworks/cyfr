// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package reach

import (
	"maps"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// .env reads as compose's dotenv reads it: `export`, `:` as well as `=`,
// space around either, quoted values across lines, an inline comment
// after a bare value, a bare name inheriting, and the last assignment
// winning.
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
	d := parseDotenv([]byte(text))
	want := map[string]string{
		"A": "last", "B": "two", "C": "three", "D": "four # not a comment", "E": "five",
		"F": "multi\nCOMPOSE_PROFILES=inside a quoted value\nline", "G": "single", "H": "",
	}
	if got := d.values(); !maps.Equal(got, want) {
		t.Errorf("values %v\nwant   %v", got, want)
	}
	if key := d.composeKey(); key != "" {
		t.Errorf("a COMPOSE_ line inside a quoted value reads as the setting %s", key)
	}
	if string(d.bytes()) != text {
		t.Error("the file does not write back byte for byte")
	}
}

// A switch's .env changes only the head's keys: a changed key on its
// first assignment's line, every other assignment of it gone; a removed
// key loses every line, an inheriting one too; a key .env lacks goes
// right after the CYFR_REACH line; an unchanged key keeps its own
// spelling; every other line is kept byte for byte.
func TestEnvWriterChangesOnlyTheHeadsKeys(t *testing.T) {
	before := strings.Join([]string{
		"# keep me",
		"CYFR_SECRET_KEY_BASE=abc",
		"CYFR_REACH=public",
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
		"CYFR_REACH=tailnet",
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
	if got := string(parseDotenv([]byte(before)).withKeys(keysOf(d.Head))); got != want {
		t.Errorf(".env became\n%s\nwant\n%s", got, want)
	}

	// A key .env lacks entirely goes right after CYFR_REACH.
	minimal := "A=1\nCYFR_REACH=local\nCYFR_HOST=localhost\nB=2\n"
	pub, _ := Derive(Target{Mode: ModePublic, Domain: "home.example.com"}, Current{Port: 4000}, nil)
	got := string(parseDotenv([]byte(minimal)).withKeys(keysOf(pub.Head)))
	if want := "A=1\nCYFR_REACH=public\nCYFR_PUBLIC_URL=https://home.example.com\nCYFR_PORT=4000\nCYFR_HOST=home.example.com\nB=2\n"; got != want {
		t.Errorf("a minimal .env became\n%s\nwant\n%s", got, want)
	}
	if h, err := headOf(parseDotenv([]byte(got)).values()); err != nil || h.Digest() != pub.Head.Digest() {
		t.Errorf("the written .env holds %+v (%v), not the head", h, err)
	}
}

// Open refuses a .env that names any COMPOSE_* setting, compose's way of
// writing it included, the first in byte order, before any docker call.
func TestOpenRefusesComposeSettingsInEnv(t *testing.T) {
	for _, line := range []string{"COMPOSE_PROFILES=public,tailnet", "COMPOSE_PROFILES: public", "  export COMPOSE_FILE = x.yml\nCOMPOSE_PROFILES=public", "COMPOSE_PROJECT_NAME"} {
		dir := filepath.Join(t.TempDir(), "home")
		os.Mkdir(dir, 0o755)
		writeFile(t, filepath.Join(dir, ".env"), append(repoFile(t, ".env.example"), []byte(line+"\n")...))
		fake := newFakeDocker(dir, nil)
		_, err := Open(dir, fake)
		want := strings.Fields(strings.NewReplacer("=", " ", ":", " ", "export", "").Replace(line))[0]
		var r *Refusal
		if !asRefusal(err, &r) || r.Code != "compose_env_refused" || r.Payload["key"] != want {
			t.Errorf("%q: Open answered %v, want compose_env_refused naming %s", line, err, want)
			continue
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
	writeFile(t, path, []byte("CYFR_PORT=4000\nexport CYFR_HOST = home.example.com\nCYFR_REACH: public\nCYFR_PUBLIC_URL=\"https://home.example.com\"\nCYFR_PORT=4100 # later\n"))
	got, err := ReadEnvValues(path)
	want := map[string]string{"CYFR_PORT": "4100", "CYFR_HOST": "home.example.com", "CYFR_REACH": "public", "CYFR_PUBLIC_URL": "https://home.example.com"}
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
		{"colon form", "COMPOSE_PROFILES: public\n", "compose_env_refused", "`.env` sets `COMPOSE_PROFILES`, which Docker Compose would read to choose this stack's files, project or services behind cyfr's back. Nothing started. Remove it; cyfr chooses them from CYFR_REACH and CYFR_LOCUS_BUILDS_URL."},
		{"export form", "export COMPOSE_FILE=x.yml\nCYFR_REACH=sideways\n", "compose_env_refused", ""},
		{"later assignment", "CYFR_REACH=sideways\n", "reach_unknown_mode", "CYFR_REACH is `sideways`; it must be `local`, `tailnet` or `public`. Run `cyfr reach <mode>` to set it with the address it implies."},
		{"later assignment restores", "CYFR_REACH=sideways\nCYFR_REACH=local\n", "", ""},
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
