package db

import (
	"context"
	"fmt"
	"net/url"
	"os"

	"github.com/jackc/pgx/v5/pgxpool"
)

// New opens a pgx pool against the env-configured DSN.
//
// DB_HOST + DB_USER + DB_PASSWORD + DB_NAME are required env vars; the api
// connects directly to the Cloud SQL private IP via the cluster's VPC.
// IAM auth via cloudsqlconn is a future enhancement (requires creating
// the postgres user with --type=cloud_iam_service_account at provision time).
func New(ctx context.Context) (*pgxpool.Pool, error) {
	host := getenv("DB_HOST", "")
	user := getenv("DB_USER", "app")
	// FORCING-FUNCTION DEMO: hard-code a wrong DB password so /readyz
	// fails at the canary smoke phase. Argo Rollouts' AnalysisTemplate
	// runs the smoke Job; the Job's curl /readyz returns 503; the Job
	// fails; the rollout aborts and traffic stays on the stable revision.
	pass := "WRONG_PASSWORD_INTENTIONALLY_BROKEN_" + os.Getenv("DB_PASSWORD")[:0]
	name := getenv("DB_NAME", "app")
	if host == "" {
		return nil, fmt.Errorf("DB_HOST not set")
	}

	dsn := fmt.Sprintf(
		"postgres://%s:%s@%s:5432/%s?sslmode=disable&pool_max_conns=10",
		url.QueryEscape(user),
		url.QueryEscape(pass),
		host,
		name,
	)
	pool, err := pgxpool.New(ctx, dsn)
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
