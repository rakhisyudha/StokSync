// Package server runs and gracefully stops the HTTP API server.
package server

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"time"
)

// Run serves HTTP requests until the context is cancelled or the server stops.
// Cancellation triggers a bounded graceful shutdown, allowing in-flight requests
// to complete before listeners are closed.
func Run(ctx context.Context, httpServer *http.Server, shutdownTimeout time.Duration, logger *slog.Logger) error {
	if httpServer == nil {
		return fmt.Errorf("http server must not be nil")
	}
	if shutdownTimeout <= 0 {
		return fmt.Errorf("shutdown timeout must be greater than zero")
	}
	if logger == nil {
		logger = slog.Default()
	}

	listener, err := net.Listen("tcp", httpServer.Addr)
	if err != nil {
		return fmt.Errorf("listen on %q: %w", httpServer.Addr, err)
	}
	logger.Info("http server listening", "address", listener.Addr().String())

	serveErr := make(chan error, 1)
	go func() {
		serveErr <- httpServer.Serve(listener)
	}()

	select {
	case err := <-serveErr:
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return fmt.Errorf("serve HTTP: %w", err)
	case <-ctx.Done():
		logger.Info("graceful shutdown started")

		shutdownCtx, cancel := context.WithTimeout(context.Background(), shutdownTimeout)
		defer cancel()
		if err := httpServer.Shutdown(shutdownCtx); err != nil {
			return fmt.Errorf("graceful shutdown: %w", err)
		}

		err := <-serveErr
		if err != nil && !errors.Is(err, http.ErrServerClosed) {
			return fmt.Errorf("serve HTTP after shutdown: %w", err)
		}
		logger.Info("graceful shutdown completed")
		return nil
	}
}
