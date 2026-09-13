package server

import (
	"context"
	"io"
	"log/slog"
	"net/http"
	"testing"
	"time"
)

func TestRunStopsGracefullyWhenContextIsCancelled(t *testing.T) {
	t.Parallel()

	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	httpServer := &http.Server{
		Addr:    "127.0.0.1:0",
		Handler: http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}),
	}
	logger := slog.New(slog.NewJSONHandler(io.Discard, nil))

	if err := Run(ctx, httpServer, time.Second, logger); err != nil {
		t.Fatalf("Run() error = %v", err)
	}
}
