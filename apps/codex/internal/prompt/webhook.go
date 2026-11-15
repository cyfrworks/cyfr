// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package prompt

import (
	"context"
	"fmt"

	"github.com/cyfr/codex/internal/mcp"
	"github.com/cyfr/codex/internal/ops"
)

// FetchWebhooks calls webhook list and returns options for selection.
func FetchWebhooks(ctx context.Context, client *mcp.Client) ([]Option, error) {
	result, err := client.CallTool(ctx, ops.Webhook, ops.WebhookListArgs{})
	if err != nil {
		return nil, err
	}

	hooks, ok := result["webhooks"].([]any)
	if !ok {
		return nil, nil
	}

	opts := make([]Option, 0, len(hooks))
	for _, h := range hooks {
		hook, ok := h.(map[string]any)
		if !ok {
			continue
		}
		name, _ := hook["name"].(string)
		if name == "" {
			continue
		}
		target, _ := hook["target_ref"].(string)
		opts = append(opts, Option{
			Value: name,
			Label: fmt.Sprintf("%s → %s", name, target),
		})
	}
	return opts, nil
}
