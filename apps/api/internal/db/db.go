package db

import (
	"context"
	"fmt"
	"net"
	"os"

	"cloud.google.com/go/cloudsqlconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

// New opens a pgx pool that connects via the Cloud SQL Auth Proxy when
// CSQL_INSTANCE_CONNECTION_NAME is set (production), or falls back to a
// direct private-IP DSN for local-cluster testing.
//
// Auth in prod: IAM auth — the pod's KSA → GSA has roles/cloudsql.client,
// cloudsqlconn dialer mints an OAuth token per connection. No DB password
// on the wire. Break-glass password is in Secret Manager but not used by
// the app.
func New(ctx context.Context) (*pgxpool.Pool, error) {
	dbName := getenv("DB_NAME", "app")
	dbUser := getenv("DB_USER", "app")

	dsn := fmt.Sprintf("user=%s database=%s sslmode=disable", dbUser, dbName)
	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		return nil, fmt.Errorf("parse: %w", err)
	}
	cfg.MaxConns = 10
	cfg.MinConns = 1

	if instance := os.Getenv("CSQL_INSTANCE_CONNECTION_NAME"); instance != "" {
		dialer, err := cloudsqlconn.NewDialer(ctx,
			cloudsqlconn.WithIAMAuthN(),
		)
		if err != nil {
			return nil, fmt.Errorf("cloudsql dialer: %w", err)
		}
		cfg.ConnConfig.DialFunc = func(ctx context.Context, _ /* network */, _ /* addr */ string) (net.Conn, error) {
			return dialer.Dial(ctx, instance)
		}
	} else {
		// Fallback: direct private-IP. Used only for local k8s testing.
		cfg.ConnConfig.Host = getenv("DB_HOST", "localhost")
		cfg.ConnConfig.Port = 5432
		cfg.ConnConfig.Password = os.Getenv("DB_PASSWORD")
	}

	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, fmt.Errorf("connect: %w", err)
	}
	return pool, nil
}

func getenv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}
