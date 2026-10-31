// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package install

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

// The parsers read the real output of the programs they name, as Ubuntu
// 26.04 prints it.

func TestParseDpkgStatus(t *testing.T) {
	out := "apparmor\tinstalled\ndocker.io\tunpacked\ndocker-compose-v2\tnot-installed\n"
	want := map[string]string{"apparmor": "installed", "docker.io": "unpacked"}
	if got := parseDpkgStatus(out); !reflect.DeepEqual(got, want) {
		t.Errorf("parseDpkgStatus = %v, want %v", got, want)
	}
}

func TestParseDockerInfo(t *testing.T) {
	out := `{"ServerVersion":"29.1.3","CgroupVersion":"2","SecurityOptions":["name=apparmor","name=seccomp,profile=builtin","name=cgroupns"],"Name":"p1"}`
	major, cgroup, security, ok := parseDockerInfo(out)
	if !ok || major != 29 || cgroup != "2" || !reflect.DeepEqual(security, []string{"apparmor", "seccomp", "cgroupns"}) {
		t.Errorf("parseDockerInfo = %d %q %v %t", major, cgroup, security, ok)
	}
	if _, _, _, ok := parseDockerInfo(`{"ServerVersion":""}`); ok {
		t.Error("a client-only answer read as a daemon")
	}
}

func TestComposeV2(t *testing.T) {
	for out, want := range map[string]bool{"2.40.3\n": true, "v2.40.3": true, "5.0.1": true, "1.29.2": false, "": false} {
		if got := composeV2(out); got != want {
			t.Errorf("composeV2(%q) = %t", out, got)
		}
	}
}

func TestParseCandidate(t *testing.T) {
	ubuntu := `docker.io:
  Installed: 28.2.2-0ubuntu1
  Candidate: 29.1.3-0ubuntu1~26.04.1
  Version table:
     29.1.3-0ubuntu1~26.04.1 500
        500 http://archive.ubuntu.com/ubuntu resolute-updates/universe amd64 Packages
 *** 28.2.2-0ubuntu1 500
        500 http://archive.ubuntu.com/ubuntu resolute/universe amd64 Packages
        100 /var/lib/dpkg/status
`
	if v, archive := parseCandidate(ubuntu, "resolute"); v != "29.1.3-0ubuntu1~26.04.1" || !archive || debianMajor(v) != 29 {
		t.Errorf("Ubuntu's candidate = %q archive=%t", v, archive)
	}
	// The installed version is the archive's; the candidate is another
	// repository's.
	third := `docker.io:
  Installed: 28.2.2-0ubuntu1
  Candidate: 30.0.0-1
  Version table:
     30.0.0-1 900
        900 https://example.com/apt stable/main amd64 Packages
 *** 28.2.2-0ubuntu1 500
        500 http://archive.ubuntu.com/ubuntu resolute/universe amd64 Packages
        100 /var/lib/dpkg/status
`
	if v, archive := parseCandidate(third, "resolute"); v != "30.0.0-1" || archive {
		t.Errorf("a third-party candidate = %q archive=%t", v, archive)
	}
	if v, archive := parseCandidate("docker.io:\n  Installed: (none)\n  Candidate: (none)\n  Version table:\n", "resolute"); v != "" || archive {
		t.Errorf("no candidate = %q archive=%t", v, archive)
	}
	if debianMajor("1:27.5.1-0ubuntu3") != 27 {
		t.Error("an epoch hides the major")
	}
}

// SameSocket takes a link to the policy's socket for the socket itself,
// and nothing else.
func TestSameSocket(t *testing.T) {
	dir := t.TempDir()
	sock := filepath.Join(dir, "run", "docker.sock")
	if err := os.MkdirAll(filepath.Dir(sock), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(sock, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(dir, "run"), filepath.Join(dir, "var-run")); err != nil {
		t.Fatal(err)
	}
	want := "unix://" + filepath.Join(dir, "var-run", "docker.sock")
	if got := SameSocket("unix://"+sock, want); got != want {
		t.Errorf("the same socket by another path = %q", got)
	}
	other := filepath.Join(dir, "run", "other.sock")
	if err := os.WriteFile(other, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	for _, endpoint := range []string{"unix://" + other, "tcp://build.example.com:2376", ""} {
		if got := SameSocket(endpoint, want); got != endpoint {
			t.Errorf("SameSocket(%q) = %q", endpoint, got)
		}
	}
}
