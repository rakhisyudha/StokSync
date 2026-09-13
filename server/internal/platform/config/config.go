// Package config loads API process configuration from environment variables.
package config

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"
)

const (
	defaultEnvironment     = "development"
	defaultHTTPAddr        = ":8080"
	defaultShutdownTimeout = 10 * time.Second

	defaultDatabaseMaxConns          int32 = 10
	defaultDatabaseMinConns          int32 = 2
	defaultDatabaseMaxConnLifetime         = time.Hour
	defaultDatabaseMaxConnIdleTime         = 30 * time.Minute
	defaultDatabaseHealthCheckPeriod       = time.Minute
)

// Config contains process-level API settings.
type Config struct {
	Environment     string
	HTTPAddr        string
	ShutdownTimeout time.Duration
	Database        DatabaseConfig
}

// DatabaseConfig contains PostgreSQL connection-pool settings. DatabaseURL is
// intentionally not given a default: starting the API without an explicit
// database is an operational error, while keeping it optional here lets
// configuration parsing remain independently testable.
type DatabaseConfig struct {
	DatabaseURL       string
	MaxConns          int32
	MinConns          int32
	MaxConnLifetime   time.Duration
	MaxConnIdleTime   time.Duration
	HealthCheckPeriod time.Duration
}

// Load loads configuration from the process environment.
func Load() (Config, error) {
	return LoadFromLookup(os.LookupEnv)
}

// LoadFromLookup loads configuration from a lookup function. It is exposed to
// make configuration validation independently testable.
func LoadFromLookup(lookup func(string) (string, bool)) (Config, error) {
	if lookup == nil {
		return Config{}, fmt.Errorf("configuration lookup must not be nil")
	}

	maxConns, err := int32OrDefault(lookup, "STOKSYNC_DATABASE_MAX_CONNS", defaultDatabaseMaxConns)
	if err != nil {
		return Config{}, err
	}
	minConns, err := int32OrDefault(lookup, "STOKSYNC_DATABASE_MIN_CONNS", defaultDatabaseMinConns)
	if err != nil {
		return Config{}, err
	}
	maxConnLifetime, err := durationOrDefault(lookup, "STOKSYNC_DATABASE_MAX_CONN_LIFETIME", defaultDatabaseMaxConnLifetime)
	if err != nil {
		return Config{}, err
	}
	maxConnIdleTime, err := durationOrDefault(lookup, "STOKSYNC_DATABASE_MAX_CONN_IDLE_TIME", defaultDatabaseMaxConnIdleTime)
	if err != nil {
		return Config{}, err
	}
	healthCheckPeriod, err := durationOrDefault(lookup, "STOKSYNC_DATABASE_HEALTH_CHECK_PERIOD", defaultDatabaseHealthCheckPeriod)
	if err != nil {
		return Config{}, err
	}

	cfg := Config{
		Environment:     valueOrDefault(lookup, "STOKSYNC_ENV", defaultEnvironment),
		HTTPAddr:        valueOrDefault(lookup, "STOKSYNC_HTTP_ADDR", defaultHTTPAddr),
		ShutdownTimeout: defaultShutdownTimeout,
		Database: DatabaseConfig{
			DatabaseURL:       valueOrDefault(lookup, "STOKSYNC_DATABASE_URL", ""),
			MaxConns:          maxConns,
			MinConns:          minConns,
			MaxConnLifetime:   maxConnLifetime,
			MaxConnIdleTime:   maxConnIdleTime,
			HealthCheckPeriod: healthCheckPeriod,
		},
	}

	if cfg.HTTPAddr == "" {
		return Config{}, fmt.Errorf("STOKSYNC_HTTP_ADDR must not be empty")
	}
	if cfg.Database.MaxConns <= 0 {
		return Config{}, fmt.Errorf("STOKSYNC_DATABASE_MAX_CONNS must be greater than zero")
	}
	if cfg.Database.MinConns < 0 {
		return Config{}, fmt.Errorf("STOKSYNC_DATABASE_MIN_CONNS must not be negative")
	}
	if cfg.Database.MinConns > cfg.Database.MaxConns {
		return Config{}, fmt.Errorf("STOKSYNC_DATABASE_MIN_CONNS must not exceed STOKSYNC_DATABASE_MAX_CONNS")
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

func int32OrDefault(lookup func(string) (string, bool), key string, defaultValue int32) (int32, error) {
	raw, ok := lookup(key)
	if !ok || strings.TrimSpace(raw) == "" {
		return defaultValue, nil
	}

	value, err := strconv.ParseInt(strings.TrimSpace(raw), 10, 32)
	if err != nil {
		return 0, fmt.Errorf("parse %s: %w", key, err)
	}
	return int32(value), nil
}

func durationOrDefault(lookup func(string) (string, bool), key string, defaultValue time.Duration) (time.Duration, error) {
	raw, ok := lookup(key)
	if !ok || strings.TrimSpace(raw) == "" {
		return defaultValue, nil
	}

	value, err := time.ParseDuration(strings.TrimSpace(raw))
	if err != nil {
		return 0, fmt.Errorf("parse %s: %w", key, err)
	}
	if value <= 0 {
		return 0, fmt.Errorf("%s must be greater than zero", key)
	}
	return value, nil
}
