// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package access

import (
	"context"
	"fmt"
	"slices"
	"strings"
	"testing"
)

// A start that fails while this computer already holds another CYFR's
// stack, running or stopped, says so, naming that CYFR's folder when its
// containers name it and else its project: Docker is asked what holds the
// networks the compose file fixes the subnets of, whatever words its error
// had. Only a project holding every one of them, by the same compose name
// on the same subnets, is a CYFR's: another project on one of those
// ranges (a photo service), one holding part of them, and this stack's
// own networks are none, and the start keeps its own sentence.
func TestAStartBesideAnotherCYFRSaysThisComputerHasOne(t *testing.T) {
	network := func(project, name, subnet string) string {
		return fmt.Sprintf(`{"Labels":{%q:%q,%q:%q},"IPAM":{"Config":[{"Subnet":%q}]}}`, labelProject, project, labelNetwork, name, subnet)
	}
	stack := func(project string) []string {
		return []string{network(project, "default", "172.16.230.0/24"), network(project, "edge", "172.16.234.0/24"),
			network(project, "locus", "172.16.231.0/24")}
	}
	start := func(t *testing.T, networks []string, folders map[string]string) string {
		h := newHome(t)
		h.fake.hook = func(_ context.Context, c *fakeCall) *fakeAnswer {
			a := c.Args
			switch {
			case a[0] == "compose" && slices.Contains(a, "up"):
				return &fakeAnswer{Code: 1, Stderr: "Error response from daemon: it did not go\n"}
			case a[0] == "network" && a[1] == "ls":
				ids := ""
				for i := range networks {
					ids += fmt.Sprintf("n%d\n", i)
				}
				return &fakeAnswer{Stdout: ids}
			case a[0] == "network" && a[1] == "inspect":
				out := ""
				for _, n := range networks {
					out += strings.ReplaceAll(n, "OWN", h.fake.st.Project) + "\n"
				}
				return &fakeAnswer{Stdout: out}
			case a[0] == "ps":
				for project, folder := range folders {
					if slices.Contains(a, "label="+labelProject+"="+project) {
						return &fakeAnswer{Stdout: folder + "\n"}
					}
				}
			}
			return nil
		}
		_, err := h.e.Start(bg, "up")
		if err == nil {
			t.Fatal("the start beside it succeeded")
		}
		return err.Error()
	}
	alone := start(t, nil, nil)
	if strings.Contains(alone, "already") || !strings.HasPrefix(alone, "cyfr up: the stack did not start: ") {
		t.Fatalf("with no other CYFR the start says %q", alone)
	}
	photos := map[string]string{"photos": "/home/ada/photos"}
	for _, c := range []struct {
		name, want string
		networks   []string
		folders    map[string]string
	}{
		{"a CYFR running, its folder named", "cyfr up: the stack did not start: this computer already has a CYFR, in /home/ada/cyfr, and one computer holds one CYFR",
			append(stack("OWN"), stack("cyfr-old")...), map[string]string{"cyfr-old": "/home/ada/cyfr"}},
		{"a CYFR stopped, its project named", "cyfr up: the stack did not start: this computer already has a CYFR, the Compose project cyfr-old, and one computer holds one CYFR",
			stack("cyfr-old"), nil},
		{"a photo service on one of its ranges", alone, []string{network("photos", "default", "172.16.231.0/24")}, photos},
		{"a project holding part of them", alone, []string{network("photos", "default", "172.16.230.0/24"), network("photos", "locus", "172.16.231.0/24")}, photos},
		{"this stack's own networks", alone, stack("OWN"), nil},
	} {
		t.Run(c.name, func(t *testing.T) {
			if got := start(t, c.networks, c.folders); got != c.want {
				t.Errorf("the start says %q, want %q", got, c.want)
			}
		})
	}
}
