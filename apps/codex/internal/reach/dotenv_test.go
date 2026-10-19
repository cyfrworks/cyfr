// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package reach

import (
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"testing"
)

// The editor refuses a .env it cannot read exactly as compose does, or
// one whose other statements its edit would change, naming the line and
// never its text, and leaves the file as it was, bytes and mode.
func TestEditEnvRefusesALineComposeCannotRead(t *testing.T) {
	const secret = "sentinel-secret-in-a-bad-line"
	for _, c := range []struct {
		name, text string
		line       string
	}{
		{"bad name", "A=1\nBROKEN! " + secret + " =value\n", "2"},
		{"name with a space", "A=1\n\nDATABASE_URL postgres://" + secret + "\n", "3"},
		{"unterminated double quote", "A=1\nB=\"" + secret + "\nC=2\n", "2"},
		{"unterminated single quote", "A='one\ntwo'\nB='" + secret + "\n", "3"},
		{"invalid interpolation", "A=1\nB=${" + secret + "\n", "2"},
		{"required variable unset", "A=1\nB=x\nC=${REACH_EDIT_UNSET_X?" + secret + "}\n", "3"},
		{"a statement after the quote on its line", "A=1\nCYFR_RESTORE_INCOMPLETE='old'K=" + secret + "\n", "2"},
		{"a bare name at the very end", "A=1\n" + secret, "2"},
	} {
		t.Run(c.name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), ".env")
			writeFile(t, path, []byte(c.text))
			if err := os.Chmod(path, 0o640); err != nil {
				t.Fatal(err)
			}
			err := EditEnvFile(path, map[string]string{"CYFR_RESTORE_INCOMPLETE": "/p/b", "K": "v"}, nil)
			var r *Refusal
			if !errors.As(err, &r) || r.Code != "compose_env_refused" || r.Payload["line"] != c.line || len(r.Payload) != 1 {
				t.Fatalf("EditEnvFile answered %v, want compose_env_refused naming line %s", err, c.line)
			}
			want := "Line " + c.line + " of `.env` does not read as Docker Compose reads it, so cyfr cannot read or change .env as compose would. Nothing was changed. Correct that line, then run the command again."
			if r.Message() != want || strings.Contains(err.Error(), secret) {
				t.Errorf("the refusal reads %q (%v)", r.Message(), err)
			}
			data, _ := os.ReadFile(path)
			info, _ := os.Stat(path)
			if string(data) != c.text || runtime.GOOS != "windows" && info.Mode().Perm() != 0o640 {
				t.Errorf("the refused edit changed the file to %q, mode %v", data, info.Mode())
			}
			if _, err := EditEnv([]byte(c.text), map[string]string{"K": "v"}, nil); refusalCode(err) != "compose_env_refused" {
				t.Errorf("EditEnv answered %v", err)
			}
		})
	}
}

// A .env compose cannot read is refused by its line before anything
// starts or changes, by every operation alike, and no docker call is
// made.
func TestEngineRefusesAnEnvComposeCannotRead(t *testing.T) {
	h := newHome(t)
	text := h.env() + "BROKEN=\"never closed\n"
	writeFile(t, h.e.envPath(), []byte(text))
	line := strings.Count(text, "\n")
	before := len(h.fake.calls())
	want := Refuse("compose_env_refused", map[string]string{"line": strconv.Itoa(line)}).Message()
	check := func(what string, err error) {
		t.Helper()
		var r *Refusal
		if !errors.As(err, &r) || r.Message() != want {
			t.Errorf("%s answered %v, want %q", what, err, want)
		}
	}
	_, err := h.e.Start(bg, "up")
	check("Start", err)
	_, err = h.e.Switch(bg, SwitchRequest{ID: id(1), Target: publicTarget})
	check("Switch", err)
	_, err = h.e.Join(bg, JoinRequest{ID: id(2)})
	check("Join", err)
	_, err = h.e.Head()
	check("Head", err)
	check("CheckStack", h.e.CheckStack(bg))
	check("CheckEnvFile", CheckEnvFile(h.e.envPath()))
	_, err = ReadEnvValues(h.e.envPath())
	check("ReadEnvValues", err)
	if calls := h.fake.calls(); len(calls) != before {
		t.Errorf("docker was called: %v", calls[before:])
	}
	if h.env() != text {
		t.Error(".env was changed")
	}
}

// A value is written bare where compose reads a bare value back as
// written, else in single quotes with each quote escaped; a value single
// quotes cannot carry, an odd run of backslashes before a quote or at its
// end, is refused naming the key alone.
func TestEnvLineWritesWhatComposeReadsBack(t *testing.T) {
	for value, want := range map[string]string{
		"":                     "K=",
		"plain-1.2_3:4/5@6":    "K=plain-1.2_3:4/5@6",
		"has space":            "K='has space'",
		"$X ${Y}":              "K='$X ${Y}'",
		"it's":                 `K='it\'s'`,
		`back\slash`:           `K='back\slash'`,
		`two\\'`:               `K='two\\\''`,
		"two\nlines":           "K='two\nlines'",
		"# hash":               "K='# hash'",
		`"double"`:             `K='"double"'`,
		`even\\` + `\\` + "'x": `K='even\\\\\'x'`,
	} {
		got, err := envLine("K", value)
		if err != nil || got != want {
			t.Errorf("envLine(%q) = %q, %v; want %q", value, got, err, want)
			continue
		}
		if d, err := readDotenv([]byte(got+"\n"), noEnv); err != nil || d.values()["K"] != value {
			t.Errorf("%q reads back as %q (%v)", got, d.values()["K"], err)
		}
	}
	for _, value := range []string{`ends\`, `a\'b`, `three\\\`, `x\\\'y`} {
		if line, err := envLine("K", value); err == nil || strings.Contains(err.Error(), value) || !strings.Contains(err.Error(), "K") {
			t.Errorf("envLine(%q) = %q, %v", value, line, err)
		}
	}
}

// The statements compose reads where a line holds more than one, or a
// name or value runs on: what follows a closing quote starts the next
// statement; a bare name ends at its line; text after the last byte of
// a file with no name is the value of the name "".
func TestDotenvStatementsAsComposeFindsThem(t *testing.T) {
	for text, want := range map[string]map[string]string{
		"A='x'B=2\n":         {"A": "x", "B": "2"},
		"A=\"x\" garbage\n":  {"A": "x"},
		"A='x' # c\nB=1\n":   {"A": "x", "B": "1"},
		"export\nFOO=1\n":    {"FOO": "1"},
		"A=1\nTRAILING":      {"A": "1", "": "TRAILING"},
		"A\tB=1\n":           {"A\tB": "1"},
		"\uFEFFA=1\n":        {"A": "1"},
		"A=1\nB=${A}\nA=2\n": {"A": "2", "B": "2"},
		"A=${X:-${Y:-z}}w\n": {"A": "zw"},
		"A=${X:-x}y}\n":      {"A": "xy}"},
		"A=\"\\0101\\$x\"\n": {"A": "A$x"},
		"A='a\\nb\\\\'\n":    {"A": `a\nb\\`},
		"A=x \t#c\nB=y #c\n": {"A": "x \t#c", "B": "y"},
	} {
		d, err := readDotenv([]byte(text), noEnv)
		if err != nil {
			t.Errorf("%q is refused: %v", text, err)
			continue
		}
		got := d.values()
		if len(got) != len(want) {
			t.Errorf("%q reads %q, want %q", text, got, want)
			continue
		}
		for k, v := range want {
			if got[k] != v {
				t.Errorf("%q reads %q, want %q", text, got, want)
				break
			}
		}
	}
}
