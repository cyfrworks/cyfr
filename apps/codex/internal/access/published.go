// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package access

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"
)

// The labels compose puts on a container beside its project and service:
// the folder it was started from, and whether it is a `run` one-off.
const (
	labelWorkingDir = "com.docker.compose.project.working_dir"
	labelOneoff     = "com.docker.compose.oneoff"
)

// publishedFormat reads of a container what PublishedBy decides on and
// nothing more: an inspect's whole answer holds its environment.
const publishedFormat = `{"id":{{json .Id}},"running":{{json .State.Running}},"paused":{{json .State.Paused}},"restarting":{{json .State.Restarting}},"started":{{json .State.StartedAt}},"dir":{{json (index .Config.Labels "` + labelWorkingDir + `")}},"ports":{{json .NetworkSettings.Ports}}}`

// Published is one run of a container: which, and when it started.
type Published struct{ ID, Started string }

// PublishedBy is Docker's word for which container of service, of the
// project in dir and of no other folder's project by the same name, runs
// now publishing port on 127.0.0.1 at that port. It starts and changes
// nothing, and needs no lock.
func PublishedBy(ctx context.Context, d Docker, dir, service string, port int) (Published, bool, error) {
	ask := func(what string, args ...string) (string, error) {
		res, err := d.Run(ctx, Call{Args: args, Deadline: probeDeadline})
		if err != nil || res.ExitCode != 0 {
			return "", noAnswer(ctx, what, res, err)
		}
		return string(res.Stdout), nil
	}
	ids, err := ask("ps", "ps", "-q", "--no-trunc",
		"--filter", "label="+labelProject+"="+ProjectName(dir),
		"--filter", "label="+labelService+"="+service,
		"--filter", "label="+labelOneoff+"=False",
		"--filter", "status=running")
	if err != nil || strings.TrimSpace(ids) == "" {
		return Published{}, false, err
	}
	seen, err := ask("inspect", append([]string{"inspect", "--format", publishedFormat}, strings.Fields(ids)...)...)
	if err != nil {
		return Published{}, false, err
	}
	here, err := os.Stat(dir)
	if err != nil {
		return Published{}, false, err
	}
	number := strconv.Itoa(port)
	for line := range strings.SplitSeq(strings.TrimSpace(seen), "\n") {
		var c struct {
			ID, Started, Dir            string
			Running, Paused, Restarting bool
			Ports                       map[string][]struct{ HostIP, HostPort string }
		}
		if json.Unmarshal([]byte(line), &c) != nil {
			return Published{}, false, fmt.Errorf("docker inspect answered something cyfr does not read")
		}
		if !c.Running || c.Paused || c.Restarting || c.Dir == "" {
			continue
		}
		// Two folders of one name share compose's project name.
		if from, err := os.Stat(c.Dir); err != nil || !os.SameFile(from, here) {
			continue
		}
		for _, at := range c.Ports[number+"/tcp"] {
			if at.HostIP == "127.0.0.1" && at.HostPort == number {
				return Published{ID: c.ID, Started: c.Started}, true, nil
			}
		}
	}
	return Published{}, false, nil
}

// noAnswer is a Docker command's failure as it was seen: ended before it
// answered, failed, or never an answer at all.
func noAnswer(ctx context.Context, what string, res Result, err error) error {
	var call *CallError
	failed := errors.As(err, &call)
	switch {
	case ctx.Err() != nil, failed && call.Deadline:
		return fmt.Errorf("docker %s was ended before it answered", what)
	case failed, err == nil:
		return &DockerFailed{What: what, ExitCode: res.ExitCode}
	}
	return fmt.Errorf("docker %s gave no answer: %w", what, err)
}

// DockerFailed is a Docker command that ran to its own exit, not 0: its
// answer, a refusal among them, before any deadline.
type DockerFailed struct {
	What     string
	ExitCode int
}

func (f *DockerFailed) Error() string {
	return fmt.Sprintf("docker %s failed with exit status %d", f.What, f.ExitCode)
}

// DockerIsHere is whether the Docker that calls reach runs its containers
// on this computer, which its endpoint says: a socket or a pipe, never an
// address. Only such a Docker can say what answers on this computer's
// loopback.
func DockerIsHere(ctx context.Context, d Docker) (bool, error) {
	res, err := d.Run(ctx, Call{Args: []string{"context", "inspect", "--format", "{{.Endpoints.docker.Host}}"}, Deadline: probeDeadline})
	if err != nil || res.ExitCode != 0 {
		return false, noAnswer(ctx, "context", res, err)
	}
	endpoint := strings.TrimSpace(string(res.Stdout))
	return strings.HasPrefix(endpoint, "unix://") || strings.HasPrefix(endpoint, "npipe://"), nil
}
