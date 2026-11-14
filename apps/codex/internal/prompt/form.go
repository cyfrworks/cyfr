// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package prompt

import (
	"context"

	"charm.land/huh/v2"
)

// KeyCreateForm holds the collected values for key creation.
type KeyCreateForm struct {
	Name        string
	Scopes      []string
	Tools       string
	IPAllowlist string
}

// RunKeyCreateForm presents a multi-field form for creating an API key.
func RunKeyCreateForm(ctx context.Context) (*KeyCreateForm, error) {
	f := &KeyCreateForm{}

	err := run(ctx, newForm(
		huh.NewGroup(
			huh.NewInput().
				Title("Key name").
				Placeholder("my-service").
				Value(&f.Name).
				Validate(huh.ValidateNotEmpty()),

			huh.NewMultiSelect[string]().
				Title("What it may do").
				Description("Leave empty to run tools and read their runs").
				Options(
					huh.NewOption("Run tools", "execute"),
					huh.NewOption("Read components", "component_read"),
					huh.NewOption("Read files, runs and logs", "storage_read"),
					huh.NewOption("Build and publish components", "component_manage"),
					huh.NewOption("Write files", "storage_write"),
					huh.NewOption("Manage keys, webhooks and programs", "admin"),
					huh.NewOption("List OAuth clients", "vault_read"),
				).
				Value(&f.Scopes),

			huh.NewInput().
				Title("Only these tools").
				Description("Comma-separated, each without a version; leave empty for any tool you granted").
				Placeholder("c:local.my-tool").
				Value(&f.Tools),

			huh.NewInput().
				Title("IP allowlist").
				Description("Comma-separated CIDRs, leave empty for none").
				Placeholder("10.0.0.0/8,192.168.1.0/24").
				Value(&f.IPAllowlist),
		),
	))
	if err != nil {
		return nil, err
	}
	return f, nil
}
