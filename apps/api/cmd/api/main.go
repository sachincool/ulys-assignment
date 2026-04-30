package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"
	"github.com/redis/go-redis/v9"
	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"

	"github.com/sachincool/ulys/apps/api/internal/db"
	"github.com/sachincool/ulys/apps/api/internal/server"
	"github.com/sachincool/ulys/apps/api/internal/telemetry"
)

const serviceName = "api"

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: slog.LevelInfo,
		AddSource: false,
	}))
	slog.SetDefault(logger)

	gitSHA := envOr("GIT_SHA", "unknown")
	buildTime := envOr("BUILD_TIME", "unknown")

	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer cancel()

	// OTel: only init if a collector endpoint is reachable. Skipping is the
	// safe default when the collector isn't yet deployed (e.g., dev). We
	// don't block the api startup on tracing.
	shutdownTraces := func(context.Context) error { return nil }
	if os.Getenv("OTEL_ENABLE") == "true" {
		s, err := telemetry.Init(ctx, serviceName, gitSHA)
		if err != nil {
			logger.Error("otel init", "err", err)
		} else {
			shutdownTraces = s
		}
	}

	pool, err := db.New(ctx)
	if err != nil {
		logger.Error("db init", "err", err)
		os.Exit(1)
	}
	defer pool.Close()

	if _, err := pool.Exec(ctx, `
		CREATE TABLE IF NOT EXISTS hits (
			id  SERIAL PRIMARY KEY,
			ts  TIMESTAMPTZ DEFAULT NOW(),
			sha TEXT
		)`); err != nil {
		logger.Warn("schema init (will retry on next request)", "err", err)
	}

	rdb := redis.NewClient(&redis.Options{
		Addr:     envOr("REDIS_ADDR", "localhost:6379"),
		Password: os.Getenv("REDIS_PASSWORD"), // empty in dev
	})
	defer rdb.Close()

	srv := &server.Server{
		DB:           pool,
		Redis:        rdb,
		WorkerClient: &http.Client{Timeout: 5 * time.Second},
		WorkerURL:    envOr("WORKER_URL", "http://worker.ulys.svc.cluster.local"),
		GitSHA:       gitSHA,
		BuildTime:    buildTime,
		Logger:       logger,
	}

	r := chi.NewRouter()
	r.Use(middleware.Recoverer)
	r.Use(middleware.RealIP)
	r.Use(middleware.RequestID)
	r.Use(slogRequestLogger(logger))
	r.Use(corsAllowAll)

	// /healthz mirrors /livez — both return 200 OK from the same handler.
	// The mesh + K8s probes target /livez; /healthz is here for the
	// assignment-spec contract and any platform that reserves /livez.
	r.Get("/healthz", srv.Healthz)
	r.Get("/livez",   srv.Livez)
	r.Get("/readyz",  srv.Readyz)
	r.Get("/version", srv.Version)
	r.Get("/work",    srv.Work)

	port := envOr("PORT", "8080")
	httpSrv := &http.Server{
		Addr:              ":" + port,
		Handler:           otelhttp.NewHandler(r, serviceName),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      15 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	go func() {
		logger.Info("api listening", "port", port, "sha", gitSHA)
		if err := httpSrv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			logger.Error("listen", "err", err)
			cancel()
		}
	}()

	<-ctx.Done()
	logger.Info("shutdown: draining for up to 25s")

	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 25*time.Second)
	defer shutdownCancel()
	if err := httpSrv.Shutdown(shutdownCtx); err != nil {
		logger.Error("http shutdown", "err", err)
	}
	if err := shutdownTraces(shutdownCtx); err != nil {
		logger.Error("trace shutdown", "err", err)
	}
	logger.Info("shutdown: done")
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func slogRequestLogger(logger *slog.Logger) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			start := time.Now()
			ww := middleware.NewWrapResponseWriter(w, r.ProtoMajor)
			next.ServeHTTP(ww, r)
			dur := time.Since(start)
			if r.URL.Path == "/livez" || r.URL.Path == "/healthz" {
				return // suppress probe noise
			}
			logger.LogAttrs(r.Context(), slog.LevelInfo, "request",
				slog.String("method", r.Method),
				slog.String("path", r.URL.Path),
				slog.Int("status", ww.Status()),
				slog.Int("bytes", ww.BytesWritten()),
				slog.Duration("dur", dur),
				slog.String("req_id", middleware.GetReqID(r.Context())),
			)
		})
	}
}

func corsAllowAll(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		next.ServeHTTP(w, r)
	})
}
