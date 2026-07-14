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
		Type: "application",
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
					huh.NewOption("Application (cyfr_pk_)", "application"),
					huh.NewOption("Service (cyfr_sk_)", "service"),
					huh.NewOption("Admin (cyfr_ak_)", "admin"),
				).
				Value(&f.Type),

			huh.NewMultiSelect[string]().
				Title("Permission scopes").
				Description("Leave empty for type defaults (application: execute, component_read, policy_read, storage_read)").
				Options(
					huh.NewOption("execute", "execute"),
					huh.NewOption("secrets_read", "secrets_read"),
					huh.NewOption("secrets_write", "secrets_write"),
					huh.NewOption("component_read", "component_read"),
					huh.NewOption("component_manage", "component_manage"),
					huh.NewOption("policy_read", "policy_read"),
					huh.NewOption("policy_manage", "policy_manage"),
					huh.NewOption("storage_read", "storage_read"),
					huh.NewOption("storage_write", "storage_write"),
					huh.NewOption("users_read", "users_read"),
					huh.NewOption("users_manage", "users_manage"),
					huh.NewOption("execution_write", "execution_write"),
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
