// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/cyfr/codex/internal/reach"
)

// What a docker call cyfr update runs through the engine's runner writes,
// on its live streams or in the stderr cyfr echoes after it, and the
// failure cyfr reports of it, carry no value .env assigns to a name other
// than the head's, nor a value the update holds (the keyring's): docker
// prints planted secrets on stdout and stderr, as compose's config does on
// its stderr and a pull that fails on both. Progress written with carriage
// returns still shows.
func TestUpdateSaysNoEnvSecretDockerPrints(t *testing.T) {
	token := func() string {
		b := make([]byte, 8)
		rand.Read(b)
		return "planted" + hex.EncodeToString(b)
	}
	password, apiToken := token(), token()
	s := newUpdateScenario(t, shippedCompose(t), nil)
	s.edit(".env", scenarioEnv+"DB_ADMIN_PASSWORD="+password+"\nAPI_TOKEN='it\\'s "+apiToken+"'\n")
	secrets := []string{password, apiToken, keyBase, "keyring-secret-value"}
	s.answer("config.err", "warning: the value "+password+" is not used\n")
	s.answer("pull.out", "Pulling it's "+apiToken+"\rDownloading 50%\rDownloading 100%\n")
	s.answer("pull.err", "Error response from daemon: "+password+" denied for "+keyBase+"\n")
	s.answer("pull.exit", "1")
	out, err := s.run(context.Background())
	if err == nil {
		t.Fatalf("the update went on past a failed pull:\n%s", out)
	}
	said := out + "\n" + err.Error()
	for _, secret := range secrets {
		if strings.Contains(said, secret) {
			t.Errorf("a planted secret reached the output or the error:\n%s", said)
		}
	}
	for _, shown := range []string{"Downloading 50%", "Downloading 100%", "Error response from daemon: <redacted> denied for <redacted>", "warning: the value <redacted> is not used", "docker pull"} {
		if !strings.Contains(said, shown) {
			t.Errorf("the output lacks %q:\n%s", shown, said)
		}
	}
}

// liveDockerSays is what cyfr update's live docker streams show of a
// docker call that writes line to its stdout, with .env holding
// STREAM_SECRET=value.
func liveDockerSays(t *testing.T, value, line string) string {
	t.Helper()
	s := newUpdateScenario(t, shippedCompose(t), nil)
	if err := os.WriteFile(filepath.Join(s.project, ".env"), []byte(scenarioEnv+"STREAM_SECRET='"+value+"'\n"), 0600); err != nil {
		t.Fatal(err)
	}
	e, err := openEngine(".")
	if err != nil {
		t.Fatal(err)
	}
	unlock, err := e.Lock("update")
	if err != nil {
		t.Fatal(err)
	}
	defer unlock()
	var out, errOut bytes.Buffer
	docker := observedDocker(func(ctx context.Context, call reach.Call) (reach.Result, error) {
		_, err := fmt.Fprint(call.Stdout, line)
		return reach.Result{}, err
	})
	u := &updater{ctx: context.Background(), out: &out, errOut: &errOut, engine: observedEngine{e, docker}}
	if err := u.docker(context.Background(), nil, nil, "version"); err != nil {
		t.Fatal(err)
	}
	return out.String() + errOut.String()
}

// A .env value that runs across lines is redacted where docker prints it
// whole on a live stream, its line break inside it.
func TestUpdateRedactsAMultilineSecretOnTheLiveStream(t *testing.T) {
	if got, want := liveDockerSays(t, "q2\nx4", "diagnostic q2\nx4 end\n"), "diagnostic <redacted> end\n"; got != want {
		t.Fatalf("the live stream showed %q, want %q", got, want)
	}
}

// A .env value is redacted as the reader gives it, its spaces included:
// " abc " is five characters, past the threshold, though "abc" is not.
func TestUpdateRedactsASecretWithItsSignificantSpaces(t *testing.T) {
	if got, want := liveDockerSays(t, " abc ", "diagnostic  abc  end\n"), "diagnostic <redacted> end\n"; got != want {
		t.Fatalf("the live stream showed %q, want %q", got, want)
	}
}
