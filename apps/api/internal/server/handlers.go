package server

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"
)

type Server struct {
	DB           *pgxpool.Pool
	Redis        *redis.Client
	WorkerClient *http.Client
	WorkerURL    string
	GitSHA       string
	BuildTime    string
	Logger       *slog.Logger
}

func (s *Server) Healthz(w http.ResponseWriter, _ *http.Request) {
	_, _ = w.Write([]byte("ok"))
}

// Livez is the K8s startupProbe / livenessProbe target. Identical to
// /healthz — the duplication exists for spec compatibility with platforms
// (like Cloud Run) that reserve /healthz at the edge.
func (s *Server) Livez(w http.ResponseWriter, _ *http.Request) {
	_, _ = w.Write([]byte("ok"))
}

// Readyz returns 200 only if all backing systems answer.
// Used as the readinessProbe — pods serve traffic only when ready.
func (s *Server) Readyz(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
	defer cancel()
	if err := s.DB.Ping(ctx); err != nil {
		http.Error(w, "db: "+err.Error(), http.StatusServiceUnavailable)
		return
	}
	if err := s.Redis.Ping(ctx).Err(); err != nil {
		http.Error(w, "redis: "+err.Error(), http.StatusServiceUnavailable)
		return
	}
	if _, err := s.callWorker(ctx, "/livez", nil); err != nil {
		http.Error(w, "worker: "+err.Error(), http.StatusServiceUnavailable)
		return
	}
	_, _ = w.Write([]byte("ready"))
}

func (s *Server) Version(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]string{
		"sha":      s.GitSHA,
		"built":    s.BuildTime,
		"hostname": hostname(),
	})
}

func (s *Server) Work(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	if _, err := s.DB.Exec(ctx, `INSERT INTO hits (sha) VALUES ($1)`, s.GitSHA); err != nil {
		s.Logger.ErrorContext(ctx, "insert hit", "err", err)
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	var count int
	if err := s.DB.QueryRow(ctx, `SELECT COUNT(*) FROM hits`).Scan(&count); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	cached, _ := s.Redis.Get(ctx, "last_work").Result()
	s.Redis.Set(ctx, "last_work", time.Now().Format(time.RFC3339), 5*time.Minute)

	body, _ := json.Marshal(map[string]any{"hits": count, "sha": s.GitSHA})
	resp, err := s.callWorker(ctx, "/transform", body)
	if err != nil {
		http.Error(w, "worker: "+err.Error(), http.StatusBadGateway)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{
		"hits":      count,
		"prev_call": cached,
		"worker":    json.RawMessage(resp),
	})
}

// callWorker hits the worker via the in-cluster ClusterIP service. mTLS and
// identity are handled by the service mesh (Linkerd) — we don't mint Google
// ID tokens any more.
func (s *Server) callWorker(ctx context.Context, path string, body []byte) ([]byte, error) {
	method := http.MethodGet
	var reader io.Reader
	if body != nil {
		method = http.MethodPost
		reader = bytes.NewReader(body)
	}
	req, err := http.NewRequestWithContext(ctx, method, s.WorkerURL+path, reader)
	if err != nil {
		return nil, err
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := s.WorkerClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	if resp.StatusCode >= 400 {
		return nil, fmt.Errorf("status %d: %s", resp.StatusCode, b)
	}
	return b, nil
}

func hostname() string { h, _ := os.Hostname(); return h }
