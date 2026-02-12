package config

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

// Config is the top-level ~/.cyfr/config.json structure.
type Config struct {
	CurrentContext string              `json:"current_context"`
	Contexts       map[string]*Context `json:"contexts"`
}

// Context is a named server connection.
type Context struct {
	URL       string `json:"url"`
	SessionID string `json:"session_id,omitempty"`
}

// DefaultConfigDir returns ~/.cyfr.
func DefaultConfigDir() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("get home dir: %w", err)
	}
	return filepath.Join(home, ".cyfr"), nil
}

// DefaultConfigPath returns ~/.cyfr/config.json.
func DefaultConfigPath() (string, error) {
	dir, err := DefaultConfigDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "config.json"), nil
}

// Load reads the config from disk, or returns defaults if it doesn't exist.
func Load() (*Config, error) {
	path, err := DefaultConfigPath()
	if err != nil {
		return nil, err
	}
	return LoadFrom(path)
}

// LoadFrom reads the config from a specific path.
func LoadFrom(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return defaultConfig(), nil
		}
		return nil, fmt.Errorf("read config: %w", err)
	}

	var cfg Config
	if err := json.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("parse config: %w", err)
	}
	if cfg.Contexts == nil {
		cfg.Contexts = make(map[string]*Context)
	}
	return &cfg, nil
}

// Save writes the config to disk.
func (c *Config) Save() error {
	path, err := DefaultConfigPath()
	if err != nil {
		return err
	}
	return c.SaveTo(path)
}

// SaveTo writes the config to a specific path.
func (c *Config) SaveTo(path string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return fmt.Errorf("create config dir: %w", err)
	}

	data, err := json.MarshalIndent(c, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal config: %w", err)
	}

	if err := os.WriteFile(path, data, 0600); err != nil {
		return fmt.Errorf("write config: %w", err)
	}
	return nil
}

// Current returns the active context, or nil if none is set.
func (c *Config) Current() *Context {
	if c.CurrentContext == "" {
		return nil
	}
	return c.Contexts[c.CurrentContext]
}

// CurrentURL returns the URL for the active context.
func (c *Config) CurrentURL() string {
	ctx := c.Current()
	if ctx == nil {
		return "http://localhost:4000"
	}
	return ctx.URL
}

// SetSessionID updates the session ID for the active context and saves.
func (c *Config) SetSessionID(sessionID string) error {
	ctx := c.Current()
	if ctx == nil {
		return fmt.Errorf("no active context")
	}
	ctx.SessionID = sessionID
	return c.Save()
}

// DefaultForLocal returns a config with the default local context.
func DefaultForLocal() *Config {
	return defaultConfig()
}

func defaultConfig() *Config {
	return &Config{
		CurrentContext: "local",
		Contexts: map[string]*Context{
			"local": {
				URL: "http://localhost:4000",
			},
		},
	}
}
