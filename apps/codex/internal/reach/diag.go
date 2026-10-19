// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package reach

import (
	"fmt"
	"path/filepath"
	"regexp"
)

// What docker writes when a call fails can quote .env: compose names the
// value it could not read or convert, and an interpolated secret is such
// a value. A diagnosis therefore never carries docker's text: it is
// recognized by its form and said in fixed words, naming at most a file,
// a line, a configuration path or a port, each matched to a grammar no
// value fits; anything else is said only by its exit status.
var diagnoses = []struct {
	form *regexp.Regexp
	say  func(m []string) string
}{
	{regexp.MustCompile(`Cannot connect to the Docker daemon`), func([]string) string { return "the Docker daemon is not reachable" }},
	{regexp.MustCompile(`permission denied while trying to connect to the Docker daemon`), func([]string) string { return "this user may not use the Docker daemon" }},
	{regexp.MustCompile(`failed to read (/[^\s:]+|[^\s:/]+): line ([0-9]+):`), func(m []string) string {
		return "it could not read " + filepath.Base(m[1]) + " at line " + m[2]
	}},
	{regexp.MustCompile(`(?m)^'(services\[[A-Za-z0-9._-]+\][A-Za-z0-9._\[\]-]*)'`), func(m []string) string { return "it refused the value of " + m[1] }},
	{regexp.MustCompile(`:([0-9]{1,5}) failed: port is already allocated`), func(m []string) string { return "port " + m[1] + " is already in use" }},
	{regexp.MustCompile(`(No such image|pull access denied|manifest unknown)`), func([]string) string { return "an image could not be found or pulled" }},
	{regexp.MustCompile(`no such service: ([A-Za-z0-9._-]+)`), func(m []string) string { return "it has no service " + m[1] }},
}

// failed is what an error says of a docker call that failed: the step,
// the call's own error (its exit status), and what docker's diagnostic
// is recognized as, if anything.
func failed(step string, err error, stderr []byte) string {
	for _, d := range diagnoses {
		if m := d.form.FindStringSubmatch(string(stderr)); m != nil {
			return fmt.Sprintf("%s failed (%v: %s)", step, err, d.say(m))
		}
	}
	return fmt.Sprintf("%s failed (%v)", step, err)
}
