package prompt

import (
	"github.com/charmbracelet/huh"
)

// KeyCreateForm holds the collected values for key creation.
type KeyCreateForm struct {
	Name        string
	Type        string
	Scopes      []string
	RateLimit   string
	IPAllowlist string
}

// RunKeyCreateForm presents a multi-field form for creating an API key.
func RunKeyCreateForm() (*KeyCreateForm, error) {
	f := &KeyCreateForm{
		Type: "public",
	}

	err := newForm(
		huh.NewGroup(
			huh.NewInput().
				Title("Key name").
				Placeholder("my-service").
				Value(&f.Name).
				Validate(huh.ValidateNotEmpty()),

			huh.NewSelect[string]().
				Title("Key type").
				Options(
					huh.NewOption("Public (pk_)", "public"),
					huh.NewOption("Secret (sk_)", "secret"),
					huh.NewOption("Admin (ak_)", "admin"),
				).
				Value(&f.Type),

			huh.NewMultiSelect[string]().
				Title("Permission scopes").
				Description("Leave empty for default scopes").
				Options(
					huh.NewOption("execute", "execute"),
					huh.NewOption("read", "read"),
					huh.NewOption("write", "write"),
					huh.NewOption("admin", "admin"),
				).
				Value(&f.Scopes),

			huh.NewInput().
				Title("Rate limit").
				Description("e.g. 100/1m, leave empty for none").
				Placeholder("100/1m").
				Value(&f.RateLimit),

			huh.NewInput().
				Title("IP allowlist").
				Description("Comma-separated CIDRs, leave empty for none").
				Placeholder("10.0.0.0/8,192.168.1.0/24").
				Value(&f.IPAllowlist),
		),
	).Run()
	if err != nil {
		return nil, err
	}
	return f, nil
}
