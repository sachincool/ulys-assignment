package db

import (
	"bytes"
	"context"
	"fmt"
	"net/url"
	"os"

	"github.com/jackc/pgx/v5/pgxpool"
)

// New opens a pgx pool against the env-configured DSN.
//
// DB_HOST + DB_USER + DB_NAME are required env vars; the api connects
// directly to the Cloud SQL private IP via the cluster's VPC. The
// password is sourced from DB_PASSWORD_FILE (a CSI-mounted Secret
// Manager file) if set, falling back to DB_PASSWORD env. The file
// path is preferred — it avoids round-tripping the secret through a
// K8s Secret resource (which the GKE-managed Secrets Store CSI
// driver can't sync due to Autopilot RBAC restrictions). IAM auth
// via cloudsqlconn is a future enhancement (requires creating the
// postgres user with --type=cloud_iam_service_account at provision).
func New(ctx context.Context) (*pgxpool.Pool, error) {
	host := getenv("DB_HOST", "")
	user := getenv("DB_USER", "app")
	pass, err := readPassword()
	if err != nil {
		return nil, err
	}
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

func readPassword() (string, error) {
	if path := os.Getenv("DB_PASSWORD_FILE"); path != "" {
		b, err := os.ReadFile(path)
		if err != nil {
			return "", fmt.Errorf("read DB_PASSWORD_FILE %s: %w", path, err)
		}
		return string(bytes.TrimSpace(b)), nil
	}
	return os.Getenv("DB_PASSWORD"), nil
}
