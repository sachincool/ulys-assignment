package main

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"google.golang.org/api/idtoken"
)

const serviceName = "worker"

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	slog.SetDefault(logger)

	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer cancel()

	// Auth config — both required at boot. The worker validates that
	// every /transform request carries a Google ID token whose audience
	// matches WORKER_AUDIENCE and whose `email` claim equals API_SA_EMAIL.
	// Anything else: 401. NetworkPolicy is the second layer.
	audience := os.Getenv("WORKER_AUDIENCE")
	apiSA := os.Getenv("API_SA_EMAIL")
	if audience == "" || apiSA == "" {
		logger.Error("WORKER_AUDIENCE and API_SA_EMAIL must be set")
		os.Exit(1)
	}

	mux := http.NewServeMux()
	live := func(w http.ResponseWriter, _ *http.Request) { _, _ = w.Write([]byte("ok")) }
	mux.HandleFunc("/livez", live)
	mux.HandleFunc("/healthz", live)
	mux.Handle("/transform", requireGoogleIDToken(audience, apiSA, logger, http.HandlerFunc(transform)))

	port := envOr("PORT", "8080")
	srv := &http.Server{
		Addr:              ":" + port,
		Handler:           otelhttp.NewHandler(mux, serviceName),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      15 * time.Second,
	}

	go func() {
		logger.Info("worker listening", "port", port, "audience", audience, "trusted_caller", apiSA)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			logger.Error("listen", "err", err)
			cancel()
		}
	}()

	<-ctx.Done()
	logger.Info("shutdown: draining 25s")
	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 25*time.Second)
	defer shutdownCancel()
	_ = srv.Shutdown(shutdownCtx)
	logger.Info("shutdown: done")
}

func transform(w http.ResponseWriter, r *http.Request) {
	var in map[string]any
	_ = json.NewDecoder(r.Body).Decode(&in)
	out := map[string]any{
		"input":     in,
		"processed": time.Now().UTC().Format(time.RFC3339),
		"by":        serviceName,
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(out)
}

// requireGoogleIDToken validates `Authorization: Bearer <jwt>` against
// Google's JWKs. Accepts only tokens whose `aud` matches `audience` and
// whose `email` claim equals `expectedEmail` (the api's GSA email). The
// idtoken package handles signature, expiry, and issuer checks; we layer
// the email check on top because audience alone doesn't bind to a
// principal.
func requireGoogleIDToken(audience, expectedEmail string, logger *slog.Logger, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		raw := r.Header.Get("Authorization")
		token, ok := strings.CutPrefix(raw, "Bearer ")
		if !ok || token == "" {
			logger.WarnContext(r.Context(), "auth: missing bearer", "path", r.URL.Path)
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		payload, err := idtoken.Validate(r.Context(), token, audience)
		if err != nil {
			logger.WarnContext(r.Context(), "auth: validate", "err", err)
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		email, _ := payload.Claims["email"].(string)
		verified, _ := payload.Claims["email_verified"].(bool)
		if !verified || email != expectedEmail {
			logger.WarnContext(r.Context(), "auth: principal mismatch", "got", email, "want", expectedEmail)
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}
