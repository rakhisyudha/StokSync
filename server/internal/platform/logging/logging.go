// Package logging provides the API's structured logger.
package logging

import (
	"log/slog"
	"os"
)

// New returns a JSON structured logger for the API process.
func New(environment string) *slog.Logger {
	level := slog.LevelInfo
	if environment == "development" {
		level = slog.LevelDebug
	}

	return slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: level}))
}
