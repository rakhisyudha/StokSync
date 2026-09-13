package config

import (
	"strings"
	"testing"
	"time"
)

func TestLoadFromLookupUsesDefaults(t *testing.T) {
	t.Parallel()

	cfg, err := LoadFromLookup(func(string) (string, bool) { return "", false })
	if err != nil {
		t.Fatalf("LoadFromLookup() error = %v", err)
	}

	if cfg.Environment != "development" {
		t.Errorf("Environment = %q, want development", cfg.Environment)
	}
	if cfg.HTTPAddr != ":8080" {
		t.Errorf("HTTPAddr = %q, want :8080", cfg.HTTPAddr)
	}
	if cfg.ShutdownTimeout != 10*time.Second {
		t.Errorf("ShutdownTimeout = %s, want 10s", cfg.ShutdownTimeout)
	}
}

func TestLoadFromLookupUsesConfiguredValues(t *testing.T) {
	t.Parallel()

	values := map[string]string{
		"STOKSYNC_ENV":              "production",
		"STOKSYNC_HTTP_ADDR":        "127.0.0.1:9090",
		"STOKSYNC_SHUTDOWN_TIMEOUT": "3s",
	}
	cfg, err := LoadFromLookup(mapLookup(values))
	if err != nil {
		t.Fatalf("LoadFromLookup() error = %v", err)
	}

	if cfg.Environment != "production" {
		t.Errorf("Environment = %q, want production", cfg.Environment)
	}
	if cfg.HTTPAddr != "127.0.0.1:9090" {
		t.Errorf("HTTPAddr = %q, want 127.0.0.1:9090", cfg.HTTPAddr)
	}
	if cfg.ShutdownTimeout != 3*time.Second {
		t.Errorf("ShutdownTimeout = %s, want 3s", cfg.ShutdownTimeout)
	}
}

func TestLoadFromLookupRejectsInvalidShutdownTimeout(t *testing.T) {
	t.Parallel()

	_, err := LoadFromLookup(mapLookup(map[string]string{
		"STOKSYNC_SHUTDOWN_TIMEOUT": "not-a-duration",
	}))
	if err == nil {
		t.Fatal("LoadFromLookup() error = nil, want validation error")
	}
	if !strings.Contains(err.Error(), "STOKSYNC_SHUTDOWN_TIMEOUT") {
		t.Errorf("LoadFromLookup() error = %q, want shutdown timeout context", err)
	}
}

func mapLookup(values map[string]string) func(string) (string, bool) {
	return func(key string) (string, bool) {
		value, ok := values[key]
		return value, ok
	}
}
