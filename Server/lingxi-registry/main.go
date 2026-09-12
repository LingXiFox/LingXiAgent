// Command lingxi-registry serves the LingXi Unified Model Registry.
//
// The service owns three things and nothing else:
//
//   - the registry source (vendors, products, overlays, discovery profiles),
//     which is the only place protocol, auth, capability and compatibility
//     knowledge is declared;
//   - public model discovery against upstream listings that need no credential,
//     with a last-known-good cache;
//   - one published catalog document derived from both.
//
// It holds no user credentials. Anything account-scoped is discovered by the
// client against the user's own account.
package main

import (
	"context"
	"errors"
	"flag"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"lingxi/registry/internal/api"
	"lingxi/registry/internal/discovery"
	"lingxi/registry/internal/registry"
)

type config struct {
	registryDir     string
	cacheDir        string
	listen          string
	refreshInterval time.Duration
	dumpPath        string
}

func main() {
	cfg := config{}
	flag.StringVar(&cfg.registryDir, "registry", "/srv/lingxi-registry/registry", "registry source directory")
	flag.StringVar(&cfg.cacheDir, "cache", "/srv/lingxi-registry/cache/discovered-models", "discovery cache directory")
	flag.StringVar(&cfg.listen, "listen", "127.0.0.1:8787", "HTTP listen address")
	flag.DurationVar(&cfg.refreshInterval, "refresh", 30*time.Minute, "discovery refresh interval")
	flag.StringVar(&cfg.dumpPath, "dump", "", "write the catalog snapshot to this path and exit")
	flag.Parse()

	logger := log.New(os.Stdout, "lingxi-registry ", log.LstdFlags|log.LUTC)

	reg, err := registry.Load(cfg.registryDir)
	if err != nil {
		logger.Fatalf("load registry from %s: %v", cfg.registryDir, err)
	}
	logger.Printf("registry loaded: vendors=%d products=%d overlays=%d profiles=%d revision=%s",
		len(reg.Vendors), len(reg.Products), len(reg.Overlays), len(reg.Profiles), reg.SourceRevision)

	disc := discovery.NewManager(cfg.cacheDir)
	server := api.New(reg, disc, api.Options{
		RefreshInterval: cfg.refreshInterval,
		Logger:          logger,
	})

	if err := server.Rebuild(); err != nil {
		logger.Fatalf("initial catalog build: %v", err)
	}

	// One-shot mode: emit the canonical artifact and exit. This is how the
	// published snapshot file stays in step with the running service.
	if cfg.dumpPath != "" {
		if err := server.Dump(cfg.dumpPath); err != nil {
			logger.Fatalf("dump catalog: %v", err)
		}
		logger.Printf("catalog snapshot written to %s", cfg.dumpPath)
		return
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	// The initial discovery pass runs in the background so the service is
	// serving from cache immediately, even before the first upstream call.
	go func() {
		server.RefreshOnce(ctx)
		server.RunRefreshLoop(ctx)
	}()

	httpServer := &http.Server{
		Addr:              cfg.listen,
		Handler:           server.Handler(),
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      60 * time.Second,
		IdleTimeout:       120 * time.Second,
	}

	go func() {
		logger.Printf("listening on %s", cfg.listen)
		if err := httpServer.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			logger.Fatalf("serve: %v", err)
		}
	}()

	<-ctx.Done()
	logger.Printf("shutting down")

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := httpServer.Shutdown(shutdownCtx); err != nil {
		logger.Printf("shutdown: %v", err)
	}
}
