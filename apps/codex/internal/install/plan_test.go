// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package install_test

import (
	"errors"
	"strings"
	"testing"

	"github.com/cyfr/codex/internal/install"
)

// TestReadPlanAcceptsWhatInitSends reads the plan init sends for a fresh
// machine.
func TestReadPlanAcceptsWhatInitSends(t *testing.T) {
	p := install.Load()
	body := `{"version":1,"account":"alice","uid":1000,"actions":[{"kind":"apt-update"},{"kind":"apt-install","packages":["docker.io","docker-compose-v2"]},{"kind":"docker-enable"},{"kind":"group-add","account":"alice"}]}`
	plan, err := install.ReadPlan(strings.NewReader(body), p, 1000, "alice")
	if err != nil {
		t.Fatal(err)
	}
	if len(plan.Actions) != 4 || plan.Account != "alice" || plan.UID != 1000 {
		t.Fatalf("plan = %+v", plan)
	}
}

// TestReadPlanRefusesAnythingOutsideThePolicy refuses each plan that names
// a command, a package, an account, a path or a field the root entry does
// not take.
func TestReadPlanRefusesAnythingOutsideThePolicy(t *testing.T) {
	p := install.Load()
	for name, body := range map[string]string{
		"an unknown action":                              `{"version":1,"account":"alice","uid":1000,"actions":[{"kind":"run","packages":["sh"]}]}`,
		"a package outside the policy":                   `{"version":1,"account":"alice","uid":1000,"actions":[{"kind":"apt-update"},{"kind":"apt-install","packages":["openssh-server"]}]}`,
		"an option as a package":                         `{"version":1,"account":"alice","uid":1000,"actions":[{"kind":"apt-update"},{"kind":"apt-install","packages":["-oAPT::Update::Pre-Invoke::=sh"]}]}`,
		"an install without update":                      `{"version":1,"account":"alice","uid":1000,"actions":[{"kind":"apt-install","packages":["docker.io"]}]}`,
		"another account's group":                        `{"version":1,"account":"alice","uid":1000,"actions":[{"kind":"group-add","account":"bob"}]}`,
		"a plan for another account":                     `{"version":1,"account":"bob","uid":1001,"actions":[{"kind":"docker-enable"}]}`,
		"a uid that is not the caller":                   `{"version":1,"account":"alice","uid":0,"actions":[{"kind":"docker-enable"}]}`,
		"an action twice":                                `{"version":1,"account":"alice","uid":1000,"actions":[{"kind":"docker-enable"},{"kind":"docker-enable"}]}`,
		"no actions":                                     `{"version":1,"account":"alice","uid":1000,"actions":[]}`,
		"an unknown field":                               `{"version":1,"account":"alice","uid":1000,"actions":[{"kind":"docker-enable"}],"command":"sh"}`,
		"another version":                                `{"version":2,"account":"alice","uid":1000,"actions":[{"kind":"docker-enable"}]}`,
		"a continuation, which the entry no longer runs": `{"version":1,"account":"alice","uid":1000,"actions":[{"kind":"docker-enable"}],"continue":{"dir":"/home/alice","args":[],"terminal":false}}`,
		"not JSON":                                       `apt-get install docker.io`,
		"an oversized plan":                              `{"version":1,"account":"alice","uid":1000,"actions":[{"kind":"docker-enable"}],"pad":"` + strings.Repeat("x", 70000) + `"}`,
	} {
		t.Run(name, func(t *testing.T) {
			_, err := install.ReadPlan(strings.NewReader(body), p, 1000, "alice")
			if !errors.Is(err, install.ErrInvalidPlan) {
				t.Fatalf("ReadPlan = %v, want a refusal", err)
			}
		})
	}
}

// TestRootPlanTakesNoGroup refuses a plan for root that adds root to the
// group.
func TestRootPlanTakesNoGroup(t *testing.T) {
	p := install.Load()
	for _, body := range []string{
		`{"version":1,"account":"root","uid":0,"actions":[{"kind":"group-add","account":"root"}]}`,
	} {
		if _, err := install.ReadPlan(strings.NewReader(body), p, 0, "root"); !errors.Is(err, install.ErrInvalidPlan) {
			t.Errorf("ReadPlan(%s) = %v", body, err)
		}
	}
	ok := `{"version":1,"account":"root","uid":0,"actions":[{"kind":"apt-update"},{"kind":"apt-install","packages":["docker.io"]}]}`
	if _, err := install.ReadPlan(strings.NewReader(ok), p, 0, "root"); err != nil {
		t.Errorf("root's install: %v", err)
	}
}

// TestCommandsAreFixed holds each action to its exact call: absolute
// programs, the lock deadline on every install, no shell.
func TestCommandsAreFixed(t *testing.T) {
	p := install.Load()
	for _, c := range []struct {
		a    install.Action
		want string
	}{
		{install.Action{Kind: install.AptUpdate}, "/usr/bin/apt-get update"},
		{install.Action{Kind: install.DpkgConfigure}, "/usr/bin/dpkg --configure -a"},
		{install.Action{Kind: install.AptInstall, Packages: []string{"docker.io", "apparmor"}}, "/usr/bin/apt-get -o DPkg::Lock::Timeout=60 install -y --no-install-recommends docker.io apparmor"},
		{install.Action{Kind: install.DockerEnable}, "/usr/bin/systemctl enable --now docker.service"},
		{install.Action{Kind: install.GroupAdd, Account: "alice"}, "/usr/sbin/usermod -aG docker alice"},
	} {
		if got := strings.Join(c.a.Command(p).Argv, " "); got != c.want {
			t.Errorf("%s = %q, want %q", c.a.Kind, got, c.want)
		}
	}
}
