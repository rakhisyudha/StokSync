package main

import (
	"context"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/stoksync/stoksync/server/internal/auth"
	"github.com/stoksync/stoksync/server/internal/db"
	"github.com/stoksync/stoksync/server/internal/httpx"
	"github.com/stoksync/stoksync/server/internal/platform/config"
	"github.com/stoksync/stoksync/server/internal/platform/logging"
	platformserver "github.com/stoksync/stoksync/server/internal/platform/server"
	"github.com/stoksync/stoksync/server/internal/snapshot"
)

func main() {
	cfg, err := config.Load()
	if err != nil {
		slog.Error("invalid configuration", "error", err)
		os.Exit(1)
	}

	logger := logging.New(cfg.Environment)

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	pool, err := db.Open(ctx, db.PoolConfig{
		URL:               cfg.Database.DatabaseURL,
		MaxConns:          cfg.Database.MaxConns,
		MinConns:          cfg.Database.MinConns,
		MaxConnLifetime:   cfg.Database.MaxConnLifetime,
		MaxConnIdleTime:   cfg.Database.MaxConnIdleTime,
		HealthCheckPeriod: cfg.Database.HealthCheckPeriod,
	})
	if err != nil {
		logger.Error("invalid database configuration", "error", err)
		os.Exit(1)
	}
	defer pool.Close()

	authService, err := auth.NewService(pool, auth.Config{
		AccessTokenSecret: cfg.Auth.AccessTokenSecret,
		AccessTokenTTL:    cfg.Auth.AccessTokenTTL,
		RefreshTokenTTL:   cfg.Auth.RefreshTokenTTL,
		TokenIssuer:       cfg.Auth.TokenIssuer,
		TokenAudience:     cfg.Auth.TokenAudience,
		PasswordHashCost:  cfg.Auth.PasswordHashCost,
	})
	if err != nil {
		logger.Error("invalid authentication configuration", "error", err)
		os.Exit(1)
	}
	authHandler := auth.NewHandler(authService, authService.RequireAuth)
	snapshotService, err := snapshot.NewService(pool)
	if err != nil {
		logger.Error("invalid snapshot configuration", "error", err)
		os.Exit(1)
	}
	snapshotHandler := snapshot.NewHandler(snapshotService, authService.RequireAuth)
	handler := httpx.NewRouterWithSnapshot(logger, pool.Ping, authHandler.Routes(), snapshotHandler.Routes())

	httpServer := &http.Server{
		Addr:              cfg.HTTPAddr,
		Handler:           handler,
		ReadHeaderTimeout: 5 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	if err := platformserver.Run(ctx, httpServer, cfg.ShutdownTimeout, logger); err != nil {
		logger.Error("api server stopped unexpectedly", "error", err)
		os.Exit(1)
	}
}
