// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build unix

package access

import (
	"encoding/json"
	"errors"
	"maps"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// composeReads is what real compose gives the cyfr service of a project
// whose only file is compose.yml, `env_file: .env`, with env as the .env:
// the environment `docker compose config` shows, its doubled `$`
// undone, or false when compose refuses to read it.
func composeReads(t *testing.T, env string) (map[string]string, bool) {
	t.Helper()
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, "compose.yml"), []byte("services:\n  cyfr:\n    image: busybox:latest\n    env_file: .env\n"))
	writeFile(t, filepath.Join(dir, ".env"), []byte(env))
	c := exec.Command("docker", "compose", "-p", "reachdotenv", "--project-directory", dir, "-f", filepath.Join(dir, "compose.yml"), "config", "--format", "json")
	c.Env = sanitizedEnv(os.Environ())
	out, err := c.Output()
	var exit *exec.ExitError
	if errors.As(err, &exit) {
		return nil, false
	}
	if err != nil {
		t.Fatal(err)
	}
	var cfg struct {
		Services map[string]struct {
			Environment map[string]*string `json:"environment"`
		} `json:"services"`
	}
	if err := json.Unmarshal(out, &cfg); err != nil {
		t.Fatal(err)
	}
	got := map[string]string{}
	for k, v := range cfg.Services["cyfr"].Environment {
		if v != nil {
			got[k] = strings.ReplaceAll(*v, "$$", "$")
		}
	}
	return got, true
}

// readsAsCompose reads env through ReadEnvValues, or false when it is
// refused.
func readsAsCompose(t *testing.T, env string) (map[string]string, bool) {
	t.Helper()
	path := filepath.Join(t.TempDir(), ".env")
	writeFile(t, path, []byte(env))
	got, err := ReadEnvValues(path)
	if err != nil {
		if refusalCode(err) != "compose_env_refused" {
			t.Fatalf("ReadEnvValues refused with %v, not compose_env_refused", err)
		}
		return nil, false
	}
	return got, true
}

// ReadEnvValues reads every form of compose's dotenv grammar as the
// installed Docker Compose does, and refuses exactly what compose refuses
// to read: compared with `docker compose config` over a corpus of each
// feature, interpolation from the environment and from the file itself
// included.
func TestReadEnvValuesReadsAsRealComposeDoes(t *testing.T) {
	requireCompose(t)
	t.Setenv("ACCESS_DIFF_SET", "from-the-environment")
	t.Setenv("ACCESS_DIFF_EMPTY", "")
	t.Setenv("access_diff_lower", "lowercase name")
	corpus := map[string]string{
		"comments and blanks":        "# a comment\n\n   \n  # indented comment\nA=1\n",
		"export forms":               "export A=1\nexport   B = two\n\texport C: three\nexport=4\nexportD=5\nexport\nE=6\n",
		"separators and spaces":      "A=1\nB = 2\nC: 3\nD :4\nE   =   five  \nF=\nG:\n",
		"last statement wins":        "A=1\nA=2\nB=x\nexport B=y\nB: z\n",
		"bare value comments":        "A=x #c\nB=x#c\nC=x\t#c\nD= #c\nE=#c\nF=x  \t \nG=a # b # c\n",
		"crlf lines":                 "A=1\r\nB='two'\r\nC=\"three\"\r\nD\r\n",
		"single quotes":              "A='x y'\nB='it\\'s'\nC='back\\\\slash'\nD='a\\nb'\nE='$X ${Y} $$'\nF='trail'  # c\nG=''\n",
		"single quote multi-line":    "A='first\nB=second\nthird'\nC=after\n",
		"after a closing quote":      "A='x'B=2\nC=\"y\" D=3\nE='z' bare\nF='w' # comment\n",
		"double quote escapes":       "A=\"tab\\there\"\nB=\"nl\\nnl\"\nC=\"q\\\"q\"\nD=\"b\\\\b\"\nE=\"d\\$x\"\nF=\"\\a\\b\\f\\v\\r\"\nG=\"\\c\\x\\q\"\nH=\"\\0101\\012\\0\\08\"\n",
		"double quote multi-line":    "A=\"one\ntwo\\nthree\"\nB=after\n",
		"interpolation":              "A=$ACCESS_DIFF_SET\nB=${ACCESS_DIFF_SET}\nC=\"x ${ACCESS_DIFF_SET} y\"\nD=$$\nE=$$ACCESS_DIFF_SET\nF=$1\nG=$\nH=${access_diff_lower}\nI=$ACCESS_DIFF_UNSET\n",
		"operators":                  "A=${ACCESS_DIFF_UNSET:-d1}\nB=${ACCESS_DIFF_UNSET-d2}\nC=${ACCESS_DIFF_EMPTY:-d3}\nD=${ACCESS_DIFF_EMPTY-d4}\nE=${ACCESS_DIFF_SET:+a5}\nF=${ACCESS_DIFF_SET+a6}\nG=${ACCESS_DIFF_EMPTY:+a7}\nH=${ACCESS_DIFF_UNSET+a8}\nI=${ACCESS_DIFF_SET?m}\nJ=${ACCESS_DIFF_SET:?m}\n",
		"nested and greedy":          "A=${ACCESS_DIFF_UNSET:-${ACCESS_DIFF_SET}}\nB=${ACCESS_DIFF_UNSET:-x}y}\nC=${ACCESS_DIFF_UNSET:-{b}c}\nD=${ACCESS_DIFF_SET:+${ACCESS_DIFF_UNSET:-n}}\nE=${ACCESS_DIFF_UNSET-a}${ACCESS_DIFF_SET}\n",
		"from the file itself":       "A=1\nB=${A}\nA=2\nC=$B-$A\nD=${LATER:-none}\nLATER=set\n",
		"names read without case":    "A=${\u017f:-x}\nB=${\u212a:-y}\nC=$\u017f.\nD=$é\nE=$\u212a\nF=${k\u212a1}\n",
		"a fold outside ASCII":       "A=${\u212b:-z}\n",
		"a name of another letter":   "A=${é:-z}\n",
		"braces in the word":         "A=${ACCESS_DIFF_UNSET:-{}x}\nB=${ACCESS_DIFF_UNSET:-}}\nC=${ACCESS_DIFF_UNSET-1}${ACCESS_DIFF_UNSET+2}$ACCESS_DIFF_UNSET\nD=${ACCESS_DIFF_UNSET:-{b}c}d}\n",
		"octal escapes":              "A=\"\\0377\\0400\\01\\0\\0089\\x\"\n",
		"a newline in a braced word": "A=\"${ACCESS_DIFF_UNSET:-x\ny}\"\n",
		"bare names":                 "ACCESS_DIFF_SET\nACCESS_DIFF_UNSET\nACCESS_DIFF_EMPTY\nA=1\nA\n",
		"bare name at the end":       "A=1\nTRAILING",
		"key characters":             "A.B=1\nA-B=2\nA[0]=3\nÄKEY=4\n1KEY=5\nA\tB=6\n_X=7\n",
		"byte order mark":            "\uFEFFA=1\nB=2\n",
		"unterminated quote":         "A=1\nB=\"open\nC=2\n",
		"unterminated single":        "A='open\n",
		"bad name":                   "BROKEN! x=1\n",
		"name with a space":          "A B=1\n",
		"bare name with a space":     "A B\n",
		"invalid template":           "A=${\n",
		"invalid braced name":        "A=${1X}\n",
		"required unset":             "A=${ACCESS_DIFF_UNSET?the message}\n",
		"required empty":             "A=${ACCESS_DIFF_EMPTY:?}\n",
		"required in quotes":         "A=\"${ACCESS_DIFF_UNSET:?m}\"\n",
		"required set later":         "A=${LATE:?m}\nLATE=1\n",
		"required emptied later":     "X=1\nA=${X:?m}\nX=\n",
	}
	for name, env := range corpus {
		t.Run(name, func(t *testing.T) {
			want, composeOK := composeReads(t, env)
			got, ok := readsAsCompose(t, env)
			switch {
			case composeOK != ok:
				t.Fatalf("compose reads %q: %v; ReadEnvValues: %v (%v)", env, composeOK, ok, got)
			case ok && !maps.Equal(got, want):
				t.Fatalf("%q\nReadEnvValues %q\ncompose       %q", env, got, want)
			}
		})
	}
}

// A value holding a quote and an interpolation is written so compose
// reads it back as written, the interpolation literal.
func TestEditEnvWritesALiteralDollarAndQuoteComposeReadsBack(t *testing.T) {
	requireCompose(t)
	t.Setenv("SOL_REVIEW_EXPAND", "unexpected-expansion")
	dir := t.TempDir()
	const value = "it's ${SOL_REVIEW_EXPAND}"
	env, err := EditEnv([]byte("CYFR_ACCESS=local\nCYFR_HOST=localhost\nCYFR_PORT=4000\n"), map[string]string{"CUSTOM": value}, nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, ".env"), env, 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "compose.yml"), []byte("services:\n  cyfr:\n    image: busybox:latest\n    env_file: .env\n"), 0600); err != nil {
		t.Fatal(err)
	}
	e, err := Open(dir, nil)
	if err != nil {
		t.Fatal(err)
	}
	h, err := e.Head()
	if err != nil {
		t.Fatal(err)
	}
	data, err := e.flatten(bg, h)
	if err != nil {
		t.Fatal(err)
	}
	cfg, err := parseConfig(data)
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.ReplaceAll(cyfrEnv(cfg)["CUSTOM"], "$$", "$"); got != value {
		t.Fatalf("EditEnv changed semantic value in actual Compose: got %q, want %q; dotenv %q", got, value, env)
	}
}

// Every name the engine and the CLI write to .env (the head's keys,
// restore's bar, the snapshot keyring's keys, init's keys) takes any value
// compose can read back as written: each value with `$`, `${…}`, quotes,
// backslashes and line breaks reads back from real compose byte for byte,
// beside the shipped template's own lines. A value single quotes cannot
// carry is refused and nothing is written.
func TestEditEnvWritesEveryKeyComposeReadsBack(t *testing.T) {
	requireCompose(t)
	t.Setenv("ACCESS_ROUND_TRIP", "expanded")
	written := append(headKeys(),
		"CYFR_RESTORE_INCOMPLETE",                     // restore's bar
		"CYFR_CRYPTO_KEYRING", "CYFR_SECRET_KEY_BASE", // the snapshot keyring
		"CYFR_CORS_ALLOWED_ORIGINS", "CYFR_SETUP_TOKEN", // init
		"LOCUS_RUNTIME_KEY", "CYFR_LOCUS_BACKENDS_KEY", "CYFR_LOCUS_BUILDS_KEY", "CYFR_PRIVATE_EGRESS_TARGETS",
	)
	values := []string{
		"plain", "", "$", "$$", "${ACCESS_ROUND_TRIP}", "$ACCESS_ROUND_TRIP", "a $b ${c:-d}",
		"it's", `"double"`, `'single'`, "mixed 'one' \"two\" `three`", `back\slash`, `\\two`, `\n literal`,
		"two\nlines", "three\nlines\n", "trailing space ", " leading space", "# hash", "a #b", "a\t#b",
		"x\\\\'y", "ünïcode ✓", "=leading", ": colon", "tab\tin",
	}
	base := string(repoFile(t, ".env.example"))
	for i, key := range written {
		for j, value := range values {
			// Each key takes each value, a few keys at a time.
			if (i+j)%len(written) > 2 {
				continue
			}
			env, err := EditEnv([]byte(base), map[string]string{key: value}, nil)
			if err != nil {
				t.Errorf("%s=%q was refused: %v", key, value, err)
				continue
			}
			got, ok := composeReads(t, string(env))
			if !ok || got[key] != value {
				t.Errorf("%s=%q reads back from compose as %q (%v):\n%s", key, value, got[key], ok, env)
			}
		}
	}
	for _, value := range []string{`ends\`, `a\'b`, `three\\\`, `x\\\'y`} {
		before := base + "KEEP=1\n"
		if env, err := EditEnv([]byte(before), map[string]string{"CYFR_RESTORE_INCOMPLETE": value}, nil); err == nil {
			t.Errorf("%q was written, which single quotes cannot carry:\n%s", value, env)
		}
		path := filepath.Join(t.TempDir(), ".env")
		writeFile(t, path, []byte(before))
		if err := EditEnvFile(path, map[string]string{"CYFR_RESTORE_INCOMPLETE": value}, nil); err == nil || strings.Contains(err.Error(), value) {
			t.Errorf("EditEnvFile answered %v for %q", err, value)
		}
		if data, _ := os.ReadFile(path); string(data) != before {
			t.Errorf("a refused value changed the file:\n%s", data)
		}
	}
}

// An interpolated name is read without case as compose reads it, Unicode
// simple case folding included: the Kelvin sign is the letter k, in a
// default's name as in a name the file itself assigns.
func TestInterpolationReadsTheKelvinSignAsComposeDoes(t *testing.T) {
	requireCompose(t)
	for _, src := range []string{"A=${\u212a:-fallback}\n", "\u212a=from-file\nA=$\u212a\nB=${\u212a}\n"} {
		want, composeOK := composeReads(t, src)
		got, readOK := readsAsCompose(t, src)
		if composeOK != readOK || composeOK && !maps.Equal(got, want) {
			t.Fatalf("for %q compose (%v) reads %q and the reader (%v) %q", src, composeOK, want, readOK, got)
		}
	}
}
