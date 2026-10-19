// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"strings"
	"testing"
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
