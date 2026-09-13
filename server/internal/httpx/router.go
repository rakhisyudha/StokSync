// Package httpx contains HTTP transport setup shared by API handlers.
package httpx

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"runtime/debug"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"
)

// ReadinessCheck reports whether dependencies required to serve traffic are available.
type ReadinessCheck func(context.Context) error

// NewRouter constructs the versioned API router and its cross-cutting middleware.
func NewRouter(logger *slog.Logger, readiness ReadinessCheck) http.Handler {
	if logger == nil {
		logger = slog.Default()
	}
	if readiness == nil {
		readiness = func(context.Context) error { return nil }
	}

	router := chi.NewRouter()
	router.Use(middleware.RequestID)
	router.Use(requestLogger(logger))
	router.Use(recoverer(logger))

	router.Get("/v1/health", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, statusResponse{Status: "ok"})
	})
	router.Get("/v1/ready", func(w http.ResponseWriter, r *http.Request) {
		if err := readiness(r.Context()); err != nil {
			logger.Error("readiness check failed", "error", err)
			writeJSON(w, http.StatusServiceUnavailable, statusResponse{Status: "not_ready"})
			return
		}
		writeJSON(w, http.StatusOK, statusResponse{Status: "ready"})
	})

	return router
}

type statusResponse struct {
	Status string `json:"status"`
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}

func requestLogger(logger *slog.Logger) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			started := time.Now()
			requestID := middleware.GetReqID(r.Context())
			wrapped := middleware.NewWrapResponseWriter(w, r.ProtoMajor)
			if requestID != "" {
				wrapped.Header().Set("X-Request-ID", requestID)
			}

			next.ServeHTTP(wrapped, r)

			status := wrapped.Status()
			if status == 0 {
				status = http.StatusOK
			}
			logger.Info("http request completed",
				"request_id", requestID,
				"method", r.Method,
				"path", r.URL.Path,
				"status", status,
				"bytes", wrapped.BytesWritten(),
				"duration", time.Since(started),
			)
		})
	}
}

func recoverer(logger *slog.Logger) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			defer func() {
				if recovered := recover(); recovered != nil {
					logger.Error("panic while handling request",
						"request_id", middleware.GetReqID(r.Context()),
						"panic", recovered,
						"stack", string(debug.Stack()),
					)
					http.Error(w, http.StatusText(http.StatusInternalServerError), http.StatusInternalServerError)
				}
			}()

			next.ServeHTTP(w, r)
		})
	}
}
