package prompt

import (
	"encoding/json"
	"fmt"
	"strings"

	"github.com/charmbracelet/huh"
	"github.com/cyfr/codex/internal/mcp"
	"github.com/cyfr/codex/internal/ref"
)

// WebhookCreateForm holds the collected values for webhook creation.
type WebhookCreateForm struct {
	Name            string
	TargetRef       string
	Description     string
	SignatureHeader string
	RateLimit       string
	InputTemplate   string // JSON object string; "{}" if blank
}

// RunWebhookCreateForm presents a multi-field form for creating a webhook.
//
// `input_template` is a JSON object that gets merged into the component's
// invoke payload at runtime. The reserved key `_webhook` is rejected
// server-side (and pre-checked here for a cleaner error).
func RunWebhookCreateForm() (*WebhookCreateForm, error) {
	f := &WebhookCreateForm{
		SignatureHeader: "x-cyfr-signature",
		InputTemplate:   "{}",
	}

	err := newForm(
		huh.NewGroup(
			huh.NewInput().
				Title("Webhook name").
				Placeholder("github-push").
				Value(&f.Name).
				Validate(huh.ValidateNotEmpty()),

			huh.NewInput().
				Title("Target component").
				Description("Component reference invoked on each verified POST. e.g. f:local.handle-github-push").
				Placeholder("f:local.my-handler").
				Value(&f.TargetRef).
				Validate(func(s string) error {
					if strings.TrimSpace(s) == "" {
						return fmt.Errorf("target component is required")
					}
					p := ref.ParseRef(s)
					if err := ref.Validate(p); err != nil {
						return err
					}
					return nil
				}),

			huh.NewInput().
				Title("Signature header").
				Description("HTTP header carrying the HMAC signature").
				Placeholder("x-cyfr-signature").
				Value(&f.SignatureHeader),

			huh.NewInput().
				Title("Rate limit").
				Description("e.g. 100/1m, leave empty for default").
				Placeholder("100/1m").
				Value(&f.RateLimit),

			huh.NewInput().
				Title("Description").
				Description("Optional human-readable description").
				Value(&f.Description),

			huh.NewText().
				Title("Input template (JSON object)").
				Description("Static fields merged into the component invoke payload. Reserved key '_webhook' is not allowed.").
				Placeholder(`{"channel":"alerts","priority":"high"}`).
				Value(&f.InputTemplate).
				Lines(5).
				Validate(validateInputTemplateJSON),
		),
	).Run()
	if err != nil {
		return nil, err
	}
	return f, nil
}

// validateInputTemplateJSON ensures the supplied template parses as a JSON
// object and does not contain the reserved key `_webhook`. Empty input is
// treated as `{}`.
func validateInputTemplateJSON(s string) error {
	trimmed := strings.TrimSpace(s)
	if trimmed == "" || trimmed == "{}" {
		return nil
	}

	var decoded any
	if err := json.Unmarshal([]byte(trimmed), &decoded); err != nil {
		return fmt.Errorf("not valid JSON: %w", err)
	}

	obj, ok := decoded.(map[string]any)
	if !ok {
		return fmt.Errorf("must be a JSON object (not array or scalar)")
	}

	if _, exists := obj["_webhook"]; exists {
		return fmt.Errorf("reserved key '_webhook' is not allowed in input_template")
	}

	return nil
}

// FetchWebhooks calls webhook list and returns options for selection.
func FetchWebhooks(client *mcp.Client) ([]Option, error) {
	result, err := client.CallTool("webhook", map[string]any{"action": "list"})
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
