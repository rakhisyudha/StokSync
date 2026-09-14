package logging

import (
	"bytes"
	"errors"
	"strings"
	"testing"
)

func TestNewWithWriterRedactsSensitiveFieldsAndUnsafeValues(t *testing.T) {
	var output bytes.Buffer
	logger := NewWithWriter("production", &output)

	logger.Info("diagnostic",
		"request_id", "0192f200-0000-7000-8000-000000000001",
		"password", "raw-password",
		"access_token", "access-token",
		"refresh_token", "refresh-token",
		"authorization", "Bearer access-token",
		"payload", map[string]string{"note": "sensitive payload"},
		"error", errors.New("database password=error-secret"),
		"safe_count", 2,
	)

	line := output.String()
	for _, secret := range []string{
		"raw-password",
		"access-token",
		"refresh-token",
		"sensitive payload",
		"error-secret",
	} {
		if strings.Contains(line, secret) {
			t.Fatalf("log output contains secret %q: %s", secret, line)
		}
	}
	for _, expected := range []string{"diagnostic", "request_id", "safe_count", "[REDACTED]"} {
		if !strings.Contains(line, expected) {
			t.Fatalf("log output does not contain safe field %q: %s", expected, line)
		}
	}
}

func TestSafeRequestIDRejectsUntrustedMetadata(t *testing.T) {
	if got := SafeRequestID("0192f200-0000-7000-8000-000000000001"); got != "0192f200-0000-7000-8000-000000000001" {
		t.Fatalf("SafeRequestID(valid) = %q", got)
	}
	if got := SafeRequestID("Bearer secret-token"); got != "[external]" {
		t.Fatalf("SafeRequestID(secret) = %q, want [external]", got)
	}
}

func TestSafeErrorTypeDoesNotIncludeErrorText(t *testing.T) {
	if got := SafeErrorType(errors.New("password=secret")); strings.Contains(got, "secret") {
		t.Fatalf("SafeErrorType leaked error text: %q", got)
	}
}
