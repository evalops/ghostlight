package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"
)

const (
	defaultListenAddr          = ":8080"
	viewerURLEnvironment       = "GHOSTLIGHT_VIEWER_URL"
	viewerHealthURLEnvironment = "GHOSTLIGHT_VIEWER_HEALTH_URL"
	listenAddrEnvironment      = "GHOSTLIGHT_LISTEN_ADDR"
	viewerHealthPath           = "/health"
	viewerHealthTimeout        = 2 * time.Second
	healthPath                 = "/healthz"
	readinessPath              = "/readyz"
	viewerDiscoveryPath        = "/v1/viewer"
)

type Config struct {
	ListenAddr      string
	ViewerURL       string
	ViewerHealthURL string
}

type APIError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

type errorResponse struct {
	Error APIError `json:"error"`
}

type handler struct {
	viewerURL       string
	viewerHealthURL string
	viewerClient    *http.Client
	viewerTimeout   time.Duration

	// probeMu guards the in-flight readiness probe so concurrent /readyz
	// requests share one upstream health check instead of one per request.
	probeMu sync.Mutex
	flight  *probeFlight
}

type probeFlight struct {
	done   chan struct{}
	result bool
}

func loadConfig() (Config, error) {
	viewerURL := strings.TrimSpace(os.Getenv(viewerURLEnvironment))
	if err := validateViewerURL(viewerURL); err != nil {
		return Config{}, fmt.Errorf("%s: %w", viewerURLEnvironment, err)
	}
	viewerHealthURL := strings.TrimSpace(os.Getenv(viewerHealthURLEnvironment))
	if viewerHealthURL == "" {
		viewerHealthURL = viewerURL
	}
	if err := validateViewerURL(viewerHealthURL); err != nil {
		return Config{}, fmt.Errorf("%s: %w", viewerHealthURLEnvironment, err)
	}

	listenAddr := strings.TrimSpace(os.Getenv(listenAddrEnvironment))
	if listenAddr == "" {
		listenAddr = defaultListenAddr
	}
	return Config{ListenAddr: listenAddr, ViewerURL: viewerURL, ViewerHealthURL: viewerHealthURL}, nil
}

func validateViewerURL(raw string) error {
	if raw == "" {
		return errors.New("must be set")
	}
	parsed, err := url.Parse(raw)
	if err != nil {
		return fmt.Errorf("must be an absolute HTTP URL: %w", err)
	}
	if !parsed.IsAbs() || parsed.Host == "" || parsed.Hostname() == "" {
		return errors.New("must be an absolute HTTP URL")
	}
	if parsed.User != nil || parsed.Fragment != "" {
		return errors.New("must not contain credentials or a fragment")
	}
	switch strings.ToLower(parsed.Scheme) {
	case "http", "https":
		return nil
	default:
		return errors.New("must use the http or https scheme")
	}
}

func NewHandler(viewerURL string) http.Handler {
	return newHandler(viewerURL, &http.Client{Timeout: viewerHealthTimeout})
}

func newHandler(viewerURL string, client *http.Client) *handler {
	h, err := newHandlerWithHealthURL(viewerURL, viewerURL, client)
	if err != nil {
		panic(err)
	}
	return h
}

func newHandlerWithHealthURL(viewerURL, viewerHealthURL string, client *http.Client) (*handler, error) {
	if client == nil {
		return nil, errors.New("viewer HTTP client must not be nil")
	}
	clientCopy := *client
	if clientCopy.CheckRedirect == nil {
		clientCopy.CheckRedirect = func(*http.Request, []*http.Request) error {
			return http.ErrUseLastResponse
		}
	}
	return &handler{
		viewerURL:       viewerURL,
		viewerHealthURL: healthURL(viewerHealthURL),
		viewerClient:    &clientCopy,
		viewerTimeout:   viewerHealthTimeout,
	}, nil
}

func healthURL(viewerURL string) string {
	if err := validateViewerURL(viewerURL); err != nil {
		return ""
	}
	parsed, err := url.Parse(viewerURL)
	if err != nil {
		return ""
	}
	parsed.Path = viewerHealthPath
	parsed.RawPath = ""
	parsed.RawQuery = ""
	parsed.ForceQuery = false
	parsed.Fragment = ""
	return parsed.String()
}

func (h *handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	switch {
	case r.URL.Path == healthPath:
		h.handleHealth(w, r)
	case r.URL.Path == readinessPath:
		h.handleReadiness(w, r)
	case r.URL.Path == viewerDiscoveryPath:
		h.handleViewerDiscovery(w, r)
	default:
		writeError(w, http.StatusNotFound, "not_found", "route not found")
	}
}

func (h *handler) handleHealth(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeMethodNotAllowed(w, http.MethodGet)
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (h *handler) handleReadiness(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeMethodNotAllowed(w, http.MethodGet)
		return
	}

	if !h.viewerReady(r) {
		writeError(w, http.StatusServiceUnavailable, "viewer_unavailable", "configured viewer health check failed")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok", "viewer": "ready"})
}

func (h *handler) handleViewerDiscovery(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeMethodNotAllowed(w, http.MethodGet)
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"viewer_url": h.viewerURL})
}

func (h *handler) viewerReady(r *http.Request) bool {
	if h.viewerHealthURL == "" || h.viewerClient == nil || h.viewerTimeout <= 0 {
		return false
	}

	h.probeMu.Lock()
	if h.flight != nil {
		flight := h.flight
		h.probeMu.Unlock()
		<-flight.done
		return flight.result
	}
	flight := &probeFlight{done: make(chan struct{})}
	h.flight = flight
	h.probeMu.Unlock()

	result := h.probeViewer(r)

	h.probeMu.Lock()
	flight.result = result
	close(flight.done)
	h.flight = nil
	h.probeMu.Unlock()
	return result
}

func (h *handler) probeViewer(r *http.Request) bool {
	ctx, cancel := context.WithTimeout(r.Context(), h.viewerTimeout)
	defer cancel()
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, h.viewerHealthURL, nil)
	if err != nil {
		return false
	}
	response, err := h.viewerClient.Do(request)
	if err != nil {
		return false
	}
	defer response.Body.Close()
	// Drain the body so the connection can be reused by keep-alive.
	_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 4<<10))
	return response.StatusCode >= http.StatusOK && response.StatusCode < http.StatusMultipleChoices
}

func writeMethodNotAllowed(w http.ResponseWriter, allow string) {
	w.Header().Set("Allow", allow)
	writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}

func writeError(w http.ResponseWriter, status int, code, message string) {
	writeJSON(w, status, errorResponse{Error: APIError{Code: code, Message: message}})
}
