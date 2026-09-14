// Package logging provides the API's structured logger.
package logging

import (
	"fmt"
	"io"
	"log/slog"
	"os"
	"regexp"
	"strings"
)

const redactedValue = "[REDACTED]"

var (
	credentialPattern = regexp.MustCompile(`(?i)(password|passwd|access[_-]?token|refresh[_-]?token|authorization|bearer|secret)\s*[:=]\s*("[^"]*"|'[^']*'|[^\s,;}]+)`)
	bearerPattern     = regexp.MustCompile(`(?i)(bearer\s+)[^\s,;}]+`)
)

// New returns a JSON structured logger for the API process. The handler
// removes credential-like fields and never serializes arbitrary errors,
// request payloads, or objects that may contain secrets.
func New(environment string) *slog.Logger {
	return NewWithWriter(environment, os.Stdout)
}

// NewWithWriter is the injectable form of New used by tests and embedders.
func NewWithWriter(environment string, writer io.Writer) *slog.Logger {
	level := slog.LevelInfo
	if environment == "development" {
		level = slog.LevelDebug
	}
	if writer == nil {
		writer = io.Discard
	}

	return slog.New(slog.NewJSONHandler(writer, &slog.HandlerOptions{
		Level:       level,
		ReplaceAttr: replaceAttr,
	}))
}

// SafeErrorType returns a type-only diagnostic for an error. Error text is
// intentionally excluded because database and transport errors can contain
// credentials, connection strings, or request data.
func SafeErrorType(err error) string {
	if err == nil {
		return ""
	}
	return fmt.Sprintf("%T", err)
}

// SafeRequestID accepts generated UUID-style request IDs and replaces
// externally supplied values that could be used to smuggle secrets into logs.
func SafeRequestID(value string) string {
	value = strings.TrimSpace(value)
	if len(value) != 36 {
		return "[external]"
	}
	for index, character := range value {
		if character == '-' {
			if index != 8 && index != 13 && index != 18 && index != 23 {
				return "[external]"
			}
			continue
		}
		if !((character >= '0' && character <= '9') ||
			(character >= 'a' && character <= 'f') ||
			(character >= 'A' && character <= 'F')) {
			return "[external]"
		}
	}
	return value
}

func replaceAttr(_ []string, attr slog.Attr) slog.Attr {
	if attr.Key == "" {
		return attr
	}
	if sensitiveKey(attr.Key) {
		return slog.String(attr.Key, redactedValue)
	}

	switch attr.Value.Kind() {
	case slog.KindString:
		return slog.String(attr.Key, redactString(attr.Value.String()))
	case slog.KindAny:
		// Arbitrary values may implement Stringer or error and can contain
		// secrets. Keep only their type rather than invoking them.
		return slog.String(attr.Key, SafeAnyType(attr.Value.Any()))
	case slog.KindGroup:
		return slog.Group(attr.Key, sanitizeGroupArgs(attr.Value.Group())...)
	default:
		return attr
	}
}

// SafeAnyType returns a type-only representation for arbitrary slog values.
func SafeAnyType(value any) string {
	if value == nil {
		return "nil"
	}
	return fmt.Sprintf("%T", value)
}

func sanitizeGroupArgs(attrs []slog.Attr) []any {
	result := make([]any, 0, len(attrs))
	for _, attr := range attrs {
		result = append(result, replaceAttr(nil, attr))
	}
	return result
}

func sensitiveKey(key string) bool {
	normalized := strings.ToLower(strings.NewReplacer("-", "_", ".", "_").Replace(key))
	switch normalized {
	case "password", "passwd", "access_token", "refresh_token", "token",
		"authorization", "bearer", "secret", "cookie", "set_cookie",
		"payload", "body", "request", "response", "request_body",
		"response_body", "headers", "request_headers", "response_headers",
		"query", "raw_query", "email", "error", "panic":
		return true
	default:
		return strings.Contains(normalized, "password") ||
			strings.Contains(normalized, "token") ||
			strings.Contains(normalized, "authorization") ||
			strings.Contains(normalized, "secret") ||
			strings.Contains(normalized, "payload")
	}
}

func redactString(value string) string {
	value = credentialPattern.ReplaceAllString(value, `$1=[REDACTED]`)
	return bearerPattern.ReplaceAllString(value, `${1}[REDACTED]`)
}
