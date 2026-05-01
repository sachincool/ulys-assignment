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

	// IndexHTML is the bytes of apps/web/index.html with the literal
	// ${API_URL} placeholder replaced by empty string at startup, so the
	// JS in the page falls through to window.location.origin and does
	// same-origin fetches. Nil if the file wasn't present in the image
	// (the handler then 404s cleanly).
	IndexHTML []byte
}

func (s *Server) Healthz(w http.ResponseWriter, _ *http.Request) {
	_, _ = w.Write([]byte("ok"))
}

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

// Web serves the cached index.html. Mounted at GET / so the page is
// same-origin with the api — sidesteps the mixed-content block that the
// HTTPS GCS bucket version triggered (HTTPS page can't fetch HTTP api).
func (s *Server) Web(w http.ResponseWriter, _ *http.Request) {
	if s.IndexHTML == nil {
		http.NotFound(w, nil)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "public, max-age=60")
	_, _ = w.Write(s.IndexHTML)
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

// callWorker hits the worker via its in-cluster Service URL
// (http://worker.ulys.svc.cluster.local). Authentication is handled by
// `s.WorkerClient`, which is built with `idtoken.NewClient` in main.go —
// it transparently attaches a Google ID token (audience = WorkerURL,
// identity = the api KSA via Workload Identity) to every request,
// refreshed automatically. The worker's requireGoogleIDToken middleware
// validates signature + aud + email against Google JWKs; NetworkPolicy
// is the second, network-layer block.
//
// Production-upgrade path (see README "What's deferred for production"):
//   - Linkerd injection for mTLS at the transport layer; the ID-token
//     check stays as the application-layer signal that survives a mesh
//     outage.
//   - If worker ever moves to Cloud Run for burst fan-out, this call
//     site is unchanged: idtoken.NewClient already targets the audience
//     URL, and Cloud Run's front door enforces roles/run.invoker on the
//     api GSA exactly the same way.
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
