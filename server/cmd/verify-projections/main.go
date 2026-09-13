// Command verify-projections checks (and optionally repairs) the server's
// rebuildable product balance projection for one account.
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"time"

	"github.com/google/uuid"

	"github.com/stoksync/stoksync/server/internal/db"
	"github.com/stoksync/stoksync/server/internal/movements"
	"github.com/stoksync/stoksync/server/internal/platform/config"
)

func main() {
	userIDValue := flag.String("user-id", "", "account UUID whose product balances should be verified")
	rebuild := flag.Bool("rebuild", false, "rebuild projection rows from the immutable ledger before the final verification")
	flag.Parse()

	userID, err := uuid.Parse(*userIDValue)
	if err != nil || userID == uuid.Nil {
		fmt.Fprintln(os.Stderr, "-user-id must be a non-zero UUID")
		os.Exit(2)
	}

	cfg, err := config.Load()
	if err != nil {
		fmt.Fprintf(os.Stderr, "load configuration: %v\n", err)
		os.Exit(2)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	pool, err := db.Open(ctx, db.PoolConfig{
		URL:               cfg.Database.DatabaseURL,
		MaxConns:          cfg.Database.MaxConns,
		MinConns:          cfg.Database.MinConns,
		MaxConnLifetime:   cfg.Database.MaxConnLifetime,
		MaxConnIdleTime:   cfg.Database.MaxConnIdleTime,
		HealthCheckPeriod: cfg.Database.HealthCheckPeriod,
	})
	if err != nil {
		fmt.Fprintf(os.Stderr, "open database: %v\n", err)
		os.Exit(1)
	}
	defer pool.Close()

	service, err := movements.NewService(pool)
	if err != nil {
		fmt.Fprintf(os.Stderr, "create projection service: %v\n", err)
		os.Exit(1)
	}
	report, err := service.VerifyProductBalances(ctx, userID)
	if err != nil {
		fmt.Fprintf(os.Stderr, "verify product balances: %v\n", err)
		os.Exit(1)
	}
	if !report.Consistent && !*rebuild {
		writeMismatches(report)
		os.Exit(1)
	}
	if !report.Consistent && *rebuild {
		if err := service.RebuildProductBalances(ctx, userID); err != nil {
			fmt.Fprintf(os.Stderr, "rebuild product balances: %v\n", err)
			os.Exit(1)
		}
		report, err = service.VerifyProductBalances(ctx, userID)
		if err != nil {
			fmt.Fprintf(os.Stderr, "verify rebuilt product balances: %v\n", err)
			os.Exit(1)
		}
	}
	if !report.Consistent {
		writeMismatches(report)
		os.Exit(1)
	}
	fmt.Printf("product balance projection is consistent for %s (%d products)\n", report.UserID, report.CheckedProducts)
}

func writeMismatches(report movements.ProjectionVerification) {
	fmt.Fprintf(os.Stderr, "product balance projection has %d mismatch(es) for %s:\n", len(report.Mismatches), report.UserID)
	for _, mismatch := range report.Mismatches {
		fmt.Fprintf(os.Stderr, "  %s: %s expected_qty=%d actual_qty=%s\n",
			mismatch.ProductID, mismatch.Kind, mismatch.ExpectedQty, formatQuantity(mismatch.ActualQty))
	}
}

func formatQuantity(value *int64) string {
	if value == nil {
		return "<missing>"
	}
	return fmt.Sprintf("%d", *value)
}
