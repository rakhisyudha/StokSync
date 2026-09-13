package main

import (
	"context"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/stoksync/stoksync/server/internal/httpx"
	"github.com/stoksync/stoksync/server/internal/platform/config"
	"github.com/stoksync/stoksync/server/internal/platform/logging"
	platformserver "github.com/stoksync/stoksync/server/internal/platform/server"
)

func main() {
	cfg, err := config.Load()
	if err != nil {
		slog.Error("invalid configuration", "error", err)
		os.Exit(1)
	}

	logger := logging.New(cfg.Environment)
	handler := httpx.NewRouter(logger, func(context.Context) error {
		// Dependencies are added to this check as they are introduced.
		return nil
	})

	httpServer := &http.Server{
		Addr:              cfg.HTTPAddr,
		Handler:           handler,
		ReadHeaderTimeout: 5 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	if err := platformserver.Run(ctx, httpServer, cfg.ShutdownTimeout, logger); err != nil {
		logger.Error("api server stopped unexpectedly", "error", err)
		os.Exit(1)
	}
}
