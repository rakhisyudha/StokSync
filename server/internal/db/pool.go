// Package db provides PostgreSQL pooling and the typed persistence primitives
// used by StokSync domain and synchronization services.
package db

import (
	"context"
	"fmt"
	"sync"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

const (
	defaultMaxConns          int32 = 10
	defaultMaxConnLifetime         = time.Hour
	defaultMaxConnIdleTime         = 30 * time.Minute
	defaultHealthCheckPeriod       = time.Minute
)

// PoolConfig controls the pgx connection pool. URL is never logged by this
// package because it may contain a password.
type PoolConfig struct {
	URL               string
	MaxConns          int32
	MinConns          int32
	MaxConnLifetime   time.Duration
	MaxConnIdleTime   time.Duration
	HealthCheckPeriod time.Duration
}

func (c PoolConfig) withDefaults() PoolConfig {
	if c.MaxConns == 0 {
		c.MaxConns = defaultMaxConns
	}
	if c.MaxConnLifetime == 0 {
		c.MaxConnLifetime = defaultMaxConnLifetime
	}
	if c.MaxConnIdleTime == 0 {
		c.MaxConnIdleTime = defaultMaxConnIdleTime
	}
	if c.HealthCheckPeriod == 0 {
		c.HealthCheckPeriod = defaultHealthCheckPeriod
	}
	return c
}

// Validate checks settings that must be valid before pgxpool is created.
func (c PoolConfig) Validate() error {
	if c.URL == "" {
		return fmt.Errorf("database URL must not be empty")
	}
	if c.MaxConns <= 0 {
		return fmt.Errorf("database max connections must be greater than zero")
	}
	if c.MinConns < 0 {
		return fmt.Errorf("database min connections must not be negative")
	}
	if c.MinConns > c.MaxConns {
		return fmt.Errorf("database min connections must not exceed max connections")
	}
	if c.MaxConnLifetime <= 0 {
		return fmt.Errorf("database max connection lifetime must be greater than zero")
	}
	if c.MaxConnIdleTime <= 0 {
		return fmt.Errorf("database max connection idle time must be greater than zero")
	}
	if c.HealthCheckPeriod <= 0 {
		return fmt.Errorf("database health check period must be greater than zero")
	}
	return nil
}

// Pool owns a pgxpool.Pool and exposes its lifecycle plus transaction helper.
// Callers must call Close during process shutdown.
type Pool struct {
	*pgxpool.Pool
	closeOnce sync.Once
}

// Open parses the database URL and creates a lazy pgx connection pool. The
// pool does not make startup readiness implicit; callers should wire Ping into
// the HTTP readiness check and can therefore start health endpoints while the
// database is temporarily unavailable.
func Open(ctx context.Context, config PoolConfig) (*Pool, error) {
	if ctx == nil {
		return nil, errNilContext
	}

	config = config.withDefaults()
	if err := config.Validate(); err != nil {
		return nil, err
	}

	poolConfig, err := pgxpool.ParseConfig(config.URL)
	if err != nil {
		// Do not wrap the parser error: it may echo a URL containing a secret.
		return nil, fmt.Errorf("parse database URL: invalid database configuration")
	}
	poolConfig.MaxConns = config.MaxConns
	poolConfig.MinConns = config.MinConns
	poolConfig.MaxConnLifetime = config.MaxConnLifetime
	poolConfig.MaxConnIdleTime = config.MaxConnIdleTime
	poolConfig.HealthCheckPeriod = config.HealthCheckPeriod

	pool, err := pgxpool.NewWithConfig(ctx, poolConfig)
	if err != nil {
		return nil, fmt.Errorf("create database pool: %w", err)
	}
	return &Pool{Pool: pool}, nil
}

// Close releases idle and in-use connections. It is safe to call with a nil
// receiver or a pool that failed to initialize.
func (p *Pool) Close() {
	if p == nil || p.Pool == nil {
		return
	}
	p.closeOnce.Do(func() {
		p.Pool.Close()
	})
}

// BeginTx adapts pgx's transaction return type to the small testable
// TxBeginner interface used by WithTx.
func (p *Pool) BeginTx(ctx context.Context) (Tx, error) {
	if p == nil || p.Pool == nil {
		return nil, fmt.Errorf("database pool is nil")
	}
	return p.Pool.Begin(ctx)
}

// Queries returns typed queries bound to this pool. Services should use
// Queries inside WithTx for mutations that must commit atomically.
func (p *Pool) Queries() *Queries {
	if p == nil {
		return nil
	}
	return NewQueries(p)
}

// WithTx runs a callback in a pooled PostgreSQL transaction.
func (p *Pool) WithTx(ctx context.Context, fn func(*Queries) error) error {
	return WithTx(ctx, p, fn)
}

// WithTxResult runs a value-returning callback in a pooled PostgreSQL
// transaction.
func WithPoolTxResult[T any](ctx context.Context, p *Pool, fn func(*Queries) (T, error)) (T, error) {
	return WithTxResult(ctx, p, fn)
}
