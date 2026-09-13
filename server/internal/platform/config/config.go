// Package config loads API process configuration from environment variables.
package config

import (
	"fmt"
	"os"
	"strings"
	"time"
)

const (
	defaultEnvironment     = "development"
	defaultHTTPAddr        = ":8080"
	defaultShutdownTimeout = 10 * time.Second
)

// Config contains process-level API settings.
type Config struct {
	Environment     string
	HTTPAddr        string
	ShutdownTimeout time.Duration
}

// Load loads configuration from the process environment.
func Load() (Config, error) {
	return LoadFromLookup(os.LookupEnv)
}

// LoadFromLookup loads configuration from a lookup function. It is exposed to
// make configuration validation independently testable.
func LoadFromLookup(lookup func(string) (string, bool)) (Config, error) {
	cfg := Config{
		Environment:     valueOrDefault(lookup, "STOKSYNC_ENV", defaultEnvironment),
		HTTPAddr:        valueOrDefault(lookup, "STOKSYNC_HTTP_ADDR", defaultHTTPAddr),
		ShutdownTimeout: defaultShutdownTimeout,
	}

	if cfg.HTTPAddr == "" {
		return Config{}, fmt.Errorf("STOKSYNC_HTTP_ADDR must not be empty")
	}

	if rawTimeout, ok := lookup("STOKSYNC_SHUTDOWN_TIMEOUT"); ok && strings.TrimSpace(rawTimeout) != "" {
		timeout, err := time.ParseDuration(rawTimeout)
		if err != nil {
			return Config{}, fmt.Errorf("parse STOKSYNC_SHUTDOWN_TIMEOUT: %w", err)
		}
		if timeout <= 0 {
			return Config{}, fmt.Errorf("STOKSYNC_SHUTDOWN_TIMEOUT must be greater than zero")
		}
		cfg.ShutdownTimeout = timeout
	}

	return cfg, nil
}

func valueOrDefault(lookup func(string) (string, bool), key, defaultValue string) string {
	value, ok := lookup(key)
	if !ok || strings.TrimSpace(value) == "" {
		return defaultValue
	}
	return strings.TrimSpace(value)
}
