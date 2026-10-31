// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build !linux

package install

import (
	"context"
	"errors"
	"io"
	"time"
)

// ObserveSelf answers that automatic preparation does not run on this
// system: init prepares the project as it always has.
func ObserveSelf(ctx context.Context, p Policy) (Facts, error) {
	return Facts{}, ctx.Err()
}

// NewHost answers a host that changes nothing: the root entry runs on
// Linux alone.
func NewHost(p Policy, out io.Writer) Host { return otherHost{} }

type otherHost struct{}

var errNotLinux = errors.New("CYFR installs requirements on Linux alone")

func (otherHost) Observe(context.Context, Account) (Facts, error) { return Facts{}, nil }
func (otherHost) Run(context.Context, Command) (string, error)    { return "", errNotLinux }
func (otherHost) Lock(context.Context, string, time.Duration) (func(), error) {
	return nil, errNotLinux
}
func (otherHost) Now() time.Time { return time.Now() }

func (otherHost) Sleep(context.Context, time.Duration) error { return errNotLinux }
