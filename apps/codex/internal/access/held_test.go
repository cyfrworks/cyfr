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
// subnets the compose file fixes, whatever words its error had. A network
// of this stack's own, or another on a subnet the file does not fix, is
// no other CYFR, and the start's own sentence stays.
func TestAStartBesideAnotherCYFRSaysThisComputerHasOne(t *testing.T) {
	network := func(project, subnet string) string {
		return fmt.Sprintf(`{"Labels":{%q:%q,%q:"default"},"IPAM":{"Config":[{"Subnet":%q}]}}`, labelProject, project, labelNetwork, subnet)
	}
	start := func(t *testing.T, networks []string, folder string) string {
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
			case a[0] == "ps" && slices.Contains(a, "label="+labelProject+"=cyfr-old"):
				return &fakeAnswer{Stdout: folder + "\n"}
			}
			return nil
		}
		_, err := h.e.Start(bg, "up")
		if err == nil {
			t.Fatal("the start beside it succeeded")
		}
		return err.Error()
	}
	alone := start(t, nil, "")
	if strings.Contains(alone, "already") || !strings.HasPrefix(alone, "cyfr up: the stack did not start: ") {
		t.Fatalf("with no other CYFR the start says %q", alone)
	}
	for _, c := range []struct {
		name, folder, want string
		networks           []string
	}{
		{"running, its folder named", "/home/ada/cyfr", "cyfr up: the stack did not start: this computer already has a CYFR, in /home/ada/cyfr, and one computer holds one CYFR",
			[]string{network("OWN", "172.16.231.0/24"), network("cyfr-old", "172.16.231.0/24")}},
		{"stopped, its project named", "", "cyfr up: the stack did not start: this computer already has a CYFR, the Compose project cyfr-old, and one computer holds one CYFR",
			[]string{network("cyfr-old", "172.16.230.0/24")}},
		{"another project on a subnet not fixed", "/home/ada/cyfr", alone, []string{network("cyfr-old", "10.9.0.0/24")}},
		{"this stack's own networks", "/home/ada/cyfr", alone, []string{network("OWN", "172.16.231.0/24")}},
	} {
		t.Run(c.name, func(t *testing.T) {
			if got := start(t, c.networks, c.folder); got != c.want {
				t.Errorf("the start says %q, want %q", got, c.want)
			}
		})
	}
}
