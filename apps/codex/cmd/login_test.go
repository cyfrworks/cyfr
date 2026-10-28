// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/cyfr/codex/internal/config"
	"github.com/cyfr/codex/internal/mcp"
)

// devicePollServer answers every session.device_poll with the given status.
func devicePollServer(status string) *httptest.Server {
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		resp := map[string]any{
			"jsonrpc": "2.0",
			"id":      1,
			"result": map[string]any{
				"content": []map[string]any{
					{"type": "text", "text": fmt.Sprintf(`{"status":%q}`, status)},
				},
			},
		}
		json.NewEncoder(w).Encode(resp)
	}))
}

// Cancellation must end device polling promptly.
func TestPollDeviceAuth_ReturnsPromptlyOnCancel(t *testing.T) {
	srv := devicePollServer("pending")
	defer srv.Close()

	client := mcp.NewClient(srv.URL)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	start := time.Now()
	done := make(chan error, 1)
	go func() {
		_, err := pollDeviceAuth(ctx, client, "github", "dev-code",
			50*time.Millisecond, time.Now().Add(30*time.Second), 30, "laptop")
		done <- err
	}()

	// Let at least one poll round-trip happen, then cancel mid-loop.
	time.Sleep(120 * time.Millisecond)
	cancel()

	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("want context.Canceled, got %v", err)
		}
		if elapsed := time.Since(start); elapsed > 2*time.Second {
			t.Fatalf("poll loop took %v to notice cancellation", elapsed)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("poll loop did not return after cancellation — it would spin until the deadline")
	}
}

func TestPollDeviceAuth_CompleteReturnsResult(t *testing.T) {
	srv := devicePollServer("complete")
	defer srv.Close()

	client := mcp.NewClient(srv.URL)
	result, err := pollDeviceAuth(t.Context(), client, "github", "dev-code",
		10*time.Millisecond, time.Now().Add(5*time.Second), 5, "laptop")
	if err != nil {
		t.Fatalf("pollDeviceAuth failed: %v", err)
	}
	if status, _ := result["status"].(string); status != "complete" {
		t.Errorf("want the complete poll result back, got %v", result)
	}
}

func TestPollDeviceAuth_DeniedStops(t *testing.T) {
	srv := devicePollServer("denied")
	defer srv.Close()

	client := mcp.NewClient(srv.URL)
	_, err := pollDeviceAuth(t.Context(), client, "github", "dev-code",
		10*time.Millisecond, time.Now().Add(5*time.Second), 5, "laptop")
	if err == nil || !strings.Contains(err.Error(), "Authorization denied") {
		t.Fatalf("want denial error, got %v", err)
	}
}

func TestPollDeviceAuth_DeadlineTimesOut(t *testing.T) {
	// Deadline already passed: the loop must not poll at all.
	client := mcp.NewClient("http://127.0.0.1:0")
	_, err := pollDeviceAuth(t.Context(), client, "github", "dev-code",
		10*time.Millisecond, time.Now().Add(-time.Second), 900, "laptop")
	if err == nil || !strings.Contains(err.Error(), "Login timed out") {
		t.Fatalf("want timeout error, got %v", err)
	}
}

// testSetupToken is the setup token the tests' .env holds.
const testSetupToken = "0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0"

// inSetupProject makes the working directory a project of the test's own
// whose .env holds env, and a config whose current context is home's.
func inSetupProject(t *testing.T, home *stubHome, env string) string {
	t.Helper()
	t.Chdir(t.TempDir())
	if env != "" {
		if err := os.WriteFile(".env", []byte(env), 0600); err != nil {
			t.Fatal(err)
		}
	}
	return withContexts(t, "local", map[string]*config.Context{"local": {URL: home.URL}})
}

// cyfr login --setup sends the setup token .env holds and the machine's
// name, with no credential, and saves the session CYFR answers under the
// context; run again, it signs the same person in again, each run saving
// its own session.
func TestLoginSetup_SignsTheFirstPersonInAndAgain(t *testing.T) {
	home := newStubHome(t)
	path := inSetupProject(t, home, "CYFR_ACCESS=local\nCYFR_SETUP_TOKEN= "+testSetupToken+" \n")

	for i, want := range []string{"Signed in as this CYFR's first person.", "Signed in again as this CYFR's first person."} {
		out, err := runLogin(t, t.Context(), "login", "--setup")
		if err != nil {
			t.Fatalf("login --setup (run %d): %v\n%s", i+1, err, out)
		}
		if !strings.Contains(out, want) {
			t.Errorf("run %d printed %q, want %q", i+1, out, want)
		}
		if got := loadContexts(t, path).Contexts["local"].Token; got != fmt.Sprintf("setup-session-%d", i+1) {
			t.Errorf("run %d left the context holding %q, want its own session", i+1, got)
		}
	}

	if got := home.actions(); !slices.Equal(got, []string{"setup", "setup"}) {
		t.Errorf("CYFR was asked %v, want two setups alone", got)
	}
	call, _ := home.call("setup")
	if token, _ := call.arguments["setup_token"].(string); token != testSetupToken {
		t.Errorf("the setup sent the token %q, want .env's, trimmed", token)
	}
	if machine, _ := call.arguments["machine"].(string); machine != machineName() {
		t.Errorf("the setup named the machine %q, want %q", machine, machineName())
	}
	if call.authorization != "" {
		t.Errorf("the setup carried the credential %q", call.authorization)
	}
}

// Without a setup token in the working directory's .env, cyfr login
// --setup is refused naming .env before anything reaches CYFR, and saves
// nothing.
func TestLoginSetup_RefusesWithoutATokenInEnv(t *testing.T) {
	for name, c := range map[string]struct{ env, want string }{
		"no .env":             {"", "There is no .env here, so no CYFR_SETUP_TOKEN: run cyfr login --setup in the directory cyfr init set up."},
		".env without it":     {"CYFR_ACCESS=local\n", "There is no CYFR_SETUP_TOKEN in .env here: run cyfr login --setup in the directory cyfr init set up."},
		".env assigning none": {"CYFR_ACCESS=local\nCYFR_SETUP_TOKEN=\n", "There is no CYFR_SETUP_TOKEN in .env here: run cyfr login --setup in the directory cyfr init set up."},
	} {
		t.Run(name, func(t *testing.T) {
			home := newStubHome(t)
			path := inSetupProject(t, home, c.env)
			out, err := runLogin(t, t.Context(), "login", "--setup")
			if err == nil || err.Error() != c.want {
				t.Fatalf("login --setup answered %v, want %q\n%s", err, c.want, out)
			}
			if n := home.reached(); n != 0 {
				t.Errorf("%d requests reached CYFR", n)
			}
			if got := loadContexts(t, path).Contexts["local"].Token; got != "" {
				t.Errorf("the context holds %q", got)
			}
		})
	}
}

// --setup and --provider together are refused before anything reaches
// CYFR.
func TestLoginSetup_RefusesAProviderBesideIt(t *testing.T) {
	home := newStubHome(t)
	inSetupProject(t, home, "CYFR_SETUP_TOKEN="+testSetupToken+"\n")
	_, err := runLogin(t, t.Context(), "login", "--setup", "--provider", "github")
	if err == nil || !strings.Contains(err.Error(), "--setup") || !strings.Contains(err.Error(), "--provider") {
		t.Fatalf("login --setup --provider answered %v", err)
	}
	if n := home.reached(); n != 0 {
		t.Errorf("%d requests reached CYFR", n)
	}
}

// A CYFR whose first person has a sign-in method refuses the setup token:
// the command line says CYFR's sentence and that cyfr login signs it in,
// and saves nothing.
func TestLoginSetup_SetupClosedNamesCyfrLogin(t *testing.T) {
	const closed = "This CYFR is set up. Sign in with your passkey, a device you connected, or a sign-in method you linked."
	home := newStubHome(t)
	home.refusing["setup"] = closed
	path := inSetupProject(t, home, "CYFR_SETUP_TOKEN="+testSetupToken+"\n")
	_, err := runLogin(t, t.Context(), "login", "--setup")
	if err == nil || !strings.HasPrefix(err.Error(), closed+"\n") || !strings.Contains(err.Error(), "signs in with cyfr login.") {
		t.Fatalf("login --setup answered %v, want CYFR's sentence and cyfr login", err)
	}
	if got := loadContexts(t, path).Contexts["local"].Token; got != "" {
		t.Errorf("the context holds %q", got)
	}
}

// A CYFR that does not answer is the command line's connection refusal,
// as cyfr login's.
func TestLoginSetup_ServerDownIsAConnectionRefusal(t *testing.T) {
	home := newStubHome(t)
	inSetupProject(t, home, "CYFR_SETUP_TOKEN="+testSetupToken+"\n")
	home.Close()
	_, err := runLogin(t, t.Context(), "login", "--setup")
	if err == nil || !strings.HasPrefix(err.Error(), "Failed to connect: ") {
		t.Fatalf("login --setup answered %v, want the connection refusal", err)
	}
}

// A context changed to another address while the setup signs in keeps
// nothing: the session is ended at the CYFR that issued it.
func TestLoginSetup_EndsTheSessionWhenTheContextMoved(t *testing.T) {
	home := newStubHome(t)
	path := inSetupProject(t, home, "CYFR_SETUP_TOKEN="+testSetupToken+"\n")
	home.onAction = func(action string) {
		if action == "setup" {
			cfg := loadContexts(t, path)
			cfg.Contexts["local"].URL = "https://other.example"
			if err := cfg.SaveTo(path); err != nil {
				t.Error(err)
			}
		}
	}
	_, err := runLogin(t, t.Context(), "login", "--setup")
	if err == nil || !errors.Is(err, errContextMoved) || !strings.Contains(err.Error(), "the session was ended and nothing saved") {
		t.Fatalf("login --setup answered %v", err)
	}
	if logout, ok := home.call("logout"); !ok || logout.authorization != "Bearer setup-session-1" {
		t.Errorf("the session was not ended with its own credential: %+v", logout)
	}
	if got := loadContexts(t, path).Contexts["local"]; got.Token != "" || got.URL != "https://other.example" {
		t.Errorf("the moved context holds %+v", got)
	}
}
