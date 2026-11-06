// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package config

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"slices"
)

// Config is the top-level ~/.cyfr/config.json structure.
type Config struct {
	CurrentContext string              `json:"current_context"`
	Contexts       map[string]*Context `json:"contexts"`
}

// SignedOut is told the contexts whose old sign-in a load deleted from
// the file, once, as it is deleted; the command line says so.
var SignedOut = func(contexts []string) {}

// Context is a named server connection and this command line's standing
// there: the client CYFR admitted its device key as and the certificate it
// connects under, both CYFR's own word and neither a credential alone (the
// key, unlocked, proves the person; cyfr login). The session lives only in
// memory, and unattended work brings an API key by --token or CYFR_TOKEN.
type Context struct {
	URL         string          `json:"url"`
	ClientID    string          `json:"client_id,omitempty"`
	Certificate json.RawMessage `json:"certificate,omitempty"`
}

// DefaultConfigDir returns ~/.cyfr.
func DefaultConfigDir() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("get home directory: %w", err)
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
	dropped, err := dropTokens(data)
	if err != nil {
		return nil, fmt.Errorf("parse config: %w", err)
	}
	if len(dropped) > 0 {
		// A session an earlier command line saved, by an approval or a
		// provider's sign-in, proves no device: it is deleted here, with
		// the file's field, before anything can send it.
		if err := cfg.SaveTo(path); err != nil {
			return nil, fmt.Errorf("remove the old sign-in from the config: %w", err)
		}
		SignedOut(dropped)
	}
	return &cfg, nil
}

// dropTokens names the contexts whose stored form still carries the
// session an earlier command line saved ("token").
func dropTokens(data []byte) ([]string, error) {
	var stored struct {
		Contexts map[string]map[string]json.RawMessage `json:"contexts"`
	}
	if err := json.Unmarshal(data, &stored); err != nil {
		return nil, err
	}
	var names []string
	for name, fields := range stored.Contexts {
		if _, ok := fields["token"]; ok {
			names = append(names, name)
		}
	}
	slices.Sort(names)
	return names, nil
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
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0700); err != nil {
		return fmt.Errorf("create config dir: %w", err)
	}

	// MkdirAll does not tighten the permissions of a dir that already exists.
	// The directory holds this command line's device keys (cyfr login), so
	// enforce 0700 even when it already exists with looser permissions.
	if err := os.Chmod(dir, 0700); err != nil {
		return fmt.Errorf("secure config dir: %w", err)
	}

	data, err := json.MarshalIndent(c, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal config: %w", err)
	}

	// Write to a private temporary file (0600), then rename atomically.
	// A failed write leaves the existing file intact.
	tmp, err := os.CreateTemp(dir, ".config-*.json")
	if err != nil {
		return fmt.Errorf("create temp config: %w", err)
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName)

	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return fmt.Errorf("write config: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("write config: %w", err)
	}
	if err := os.Rename(tmpName, path); err != nil {
		return fmt.Errorf("save config: %w", err)
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
		return "http://127.0.0.1:4000"
	}
	return ctx.URL
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
				URL: "http://127.0.0.1:4000",
			},
		},
	}
}
