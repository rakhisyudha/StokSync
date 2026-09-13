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
	if cfg.Database.DatabaseURL != "" {
		t.Errorf("Database.DatabaseURL = %q, want empty when unset", cfg.Database.DatabaseURL)
	}
	if cfg.Database.MaxConns != 10 {
		t.Errorf("Database.MaxConns = %d, want 10", cfg.Database.MaxConns)
	}
	if cfg.Database.MinConns != 2 {
		t.Errorf("Database.MinConns = %d, want 2", cfg.Database.MinConns)
	}
	if cfg.Database.MaxConnLifetime != time.Hour {
		t.Errorf("Database.MaxConnLifetime = %s, want 1h", cfg.Database.MaxConnLifetime)
	}
	if cfg.Database.MaxConnIdleTime != 30*time.Minute {
		t.Errorf("Database.MaxConnIdleTime = %s, want 30m", cfg.Database.MaxConnIdleTime)
	}
	if cfg.Database.HealthCheckPeriod != time.Minute {
		t.Errorf("Database.HealthCheckPeriod = %s, want 1m", cfg.Database.HealthCheckPeriod)
	}
}

func TestLoadFromLookupUsesConfiguredValues(t *testing.T) {
	t.Parallel()

	values := map[string]string{
		"STOKSYNC_ENV":                          "production",
		"STOKSYNC_HTTP_ADDR":                    "127.0.0.1:9090",
		"STOKSYNC_SHUTDOWN_TIMEOUT":             "3s",
		"STOKSYNC_DATABASE_URL":                 "postgres://user:password@localhost/stoksync",
		"STOKSYNC_DATABASE_MAX_CONNS":           "20",
		"STOKSYNC_DATABASE_MIN_CONNS":           "4",
		"STOKSYNC_DATABASE_MAX_CONN_LIFETIME":   "2h",
		"STOKSYNC_DATABASE_MAX_CONN_IDLE_TIME":  "15m",
		"STOKSYNC_DATABASE_HEALTH_CHECK_PERIOD": "20s",
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
	if cfg.Database.DatabaseURL != values["STOKSYNC_DATABASE_URL"] {
		t.Errorf("Database.DatabaseURL = %q, want configured URL", cfg.Database.DatabaseURL)
	}
	if cfg.Database.MaxConns != 20 || cfg.Database.MinConns != 4 {
		t.Errorf("database pool bounds = (%d, %d), want (20, 4)", cfg.Database.MaxConns, cfg.Database.MinConns)
	}
	if cfg.Database.MaxConnLifetime != 2*time.Hour {
		t.Errorf("Database.MaxConnLifetime = %s, want 2h", cfg.Database.MaxConnLifetime)
	}
	if cfg.Database.MaxConnIdleTime != 15*time.Minute {
		t.Errorf("Database.MaxConnIdleTime = %s, want 15m", cfg.Database.MaxConnIdleTime)
	}
	if cfg.Database.HealthCheckPeriod != 20*time.Second {
		t.Errorf("Database.HealthCheckPeriod = %s, want 20s", cfg.Database.HealthCheckPeriod)
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

func TestLoadFromLookupRejectsInvalidPoolSettings(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name   string
		values map[string]string
		want   string
	}{
		{
			name:   "non-numeric max connections",
			values: map[string]string{"STOKSYNC_DATABASE_MAX_CONNS": "many"},
			want:   "STOKSYNC_DATABASE_MAX_CONNS",
		},
		{
			name:   "zero max connections",
			values: map[string]string{"STOKSYNC_DATABASE_MAX_CONNS": "0"},
			want:   "STOKSYNC_DATABASE_MAX_CONNS",
		},
		{
			name: "minimum exceeds maximum",
			values: map[string]string{
				"STOKSYNC_DATABASE_MAX_CONNS": "2",
				"STOKSYNC_DATABASE_MIN_CONNS": "3",
			},
			want: "STOKSYNC_DATABASE_MIN_CONNS",
		},
		{
			name:   "invalid idle duration",
			values: map[string]string{"STOKSYNC_DATABASE_MAX_CONN_IDLE_TIME": "soon"},
			want:   "STOKSYNC_DATABASE_MAX_CONN_IDLE_TIME",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			_, err := LoadFromLookup(mapLookup(test.values))
			if err == nil {
				t.Fatal("LoadFromLookup() error = nil, want validation error")
			}
			if !strings.Contains(err.Error(), test.want) {
				t.Errorf("LoadFromLookup() error = %q, want %q context", err, test.want)
			}
		})
	}
}

func TestLoadFromLookupRejectsNilLookup(t *testing.T) {
	t.Parallel()

	if _, err := LoadFromLookup(nil); err == nil {
		t.Fatal("LoadFromLookup() error = nil, want validation error")
	}
}

func mapLookup(values map[string]string) func(string) (string, bool) {
	return func(key string) (string, bool) {
		value, ok := values[key]
		return value, ok
	}
}

func TestLoadFromLookupUsesAuthenticationDefaults(t *testing.T) {
	t.Parallel()

	cfg, err := LoadFromLookup(func(string) (string, bool) { return "", false })
	if err != nil {
		t.Fatalf("LoadFromLookup() error = %v", err)
	}
	if cfg.Auth.AccessTokenTTL != 15*time.Minute || cfg.Auth.RefreshTokenTTL != 90*24*time.Hour {
		t.Errorf("auth lifetimes = (%s, %s), want (15m, 90d)", cfg.Auth.AccessTokenTTL, cfg.Auth.RefreshTokenTTL)
	}
	if cfg.Auth.TokenIssuer != "stoksync-api" || cfg.Auth.TokenAudience != "stoksync-client" || cfg.Auth.PasswordHashCost != 12 {
		t.Errorf("auth defaults = %#v, want documented defaults", cfg.Auth)
	}
	if cfg.Auth.AccessTokenSecret != "" {
		t.Error("auth secret should remain unset when not configured")
	}
}

func TestLoadFromLookupRejectsInvalidAuthenticationCost(t *testing.T) {
	t.Parallel()

	_, err := LoadFromLookup(mapLookup(map[string]string{"STOKSYNC_AUTH_BCRYPT_COST": "3"}))
	if err == nil || !strings.Contains(err.Error(), "STOKSYNC_AUTH_BCRYPT_COST") {
		t.Fatalf("invalid auth cost error = %v, want auth-cost context", err)
	}
}
