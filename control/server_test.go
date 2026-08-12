package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestValidateViewerURL(t *testing.T) {
	tests := []struct {
		name string
		url  string
		want bool
	}{
		{name: "http", url: "http://localhost:3000", want: true},
		{name: "https with path", url: "https://viewer.example.test/session", want: true},
		{name: "https with query", url: "https://viewer.example.test/session?mode=control", want: true},
		{name: "ipv6 host", url: "http://[::1]:3000", want: true},
		{name: "missing", url: "", want: false},
		{name: "relative", url: "/viewer", want: false},
		{name: "protocol relative", url: "//viewer.example.test", want: false},
		{name: "unsupported scheme", url: "ftp://viewer.example.test", want: false},
		{name: "missing host", url: "https:///session", want: false},
		{name: "empty hostname", url: "https://:443/session", want: false},
		{name: "malformed port", url: "https://viewer.example.test:not-a-port", want: false},
		{name: "credentials", url: "https://user:password@viewer.example.test", want: false},
		{name: "fragment", url: "https://viewer.example.test/#viewer", want: false},
		{name: "control character", url: "https://viewer.example.test/\nhealth", want: false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := validateViewerURL(tt.url); (got == nil) != tt.want {
				t.Fatalf("validateViewerURL(%q) error = %v, want valid = %v", tt.url, got, tt.want)
			}
		})
	}
}

func TestLoadConfigRequiresAndValidatesViewerURL(t *testing.T) {
	t.Setenv("GHOSTLIGHT_VIEWER_URL", "")
	if _, err := loadConfig(); err == nil {
		t.Fatal("loadConfig() with missing viewer URL returned nil error")
	}

	t.Setenv("GHOSTLIGHT_VIEWER_URL", "ftp://viewer.example.test")
	if _, err := loadConfig(); err == nil {
		t.Fatal("loadConfig() with invalid viewer URL returned nil error")
	}

	t.Setenv("GHOSTLIGHT_VIEWER_URL", "https://viewer.example.test")
	t.Setenv("GHOSTLIGHT_VIEWER_HEALTH_URL", "http://viewer:8080")
	t.Setenv("GHOSTLIGHT_LISTEN_ADDR", " 127.0.0.1:9090 ")
	cfg, err := loadConfig()
	if err != nil {
		t.Fatalf("loadConfig() with valid viewer URL error = %v", err)
	}
	if cfg.ViewerURL != "https://viewer.example.test" {
		t.Fatalf("ViewerURL = %q", cfg.ViewerURL)
	}
	if cfg.ViewerHealthURL != "http://viewer:8080" {
		t.Fatalf("ViewerHealthURL = %q", cfg.ViewerHealthURL)
	}
	if cfg.ListenAddr != "127.0.0.1:9090" {
		t.Fatalf("ListenAddr = %q, want custom address", cfg.ListenAddr)
	}

	t.Setenv("GHOSTLIGHT_LISTEN_ADDR", "")
	cfg, err = loadConfig()
	if err != nil {
		t.Fatalf("loadConfig() with default listen address error = %v", err)
	}
	if cfg.ListenAddr != defaultListenAddr {
		t.Fatalf("ListenAddr = %q, want %q", cfg.ListenAddr, defaultListenAddr)
	}

	t.Setenv("GHOSTLIGHT_VIEWER_HEALTH_URL", "")
	cfg, err = loadConfig()
	if err != nil {
		t.Fatalf("loadConfig() with omitted health URL error = %v", err)
	}
	if cfg.ViewerHealthURL != cfg.ViewerURL {
		t.Fatalf("ViewerHealthURL = %q, want discovery URL fallback %q", cfg.ViewerHealthURL, cfg.ViewerURL)
	}

	t.Setenv("GHOSTLIGHT_VIEWER_HEALTH_URL", "file:///tmp/viewer")
	if _, err := loadConfig(); err == nil {
		t.Fatal("loadConfig() with invalid health URL returned nil error")
	}
}

func TestHealthURLUsesViewerOriginAndOfficialPath(t *testing.T) {
	if got, want := healthURL("https://viewer.example.test:8443/viewer/path?token=value"), "https://viewer.example.test:8443/health"; got != want {
		t.Fatalf("healthURL() = %q, want %q", got, want)
	}
	for _, raw := range []string{"", "/viewer", "file:///tmp/viewer", "https://user@viewer.example.test"} {
		if got := healthURL(raw); got != "" {
			t.Fatalf("healthURL(%q) = %q, want empty URL", raw, got)
		}
	}
}

func TestHTTPServerTimeouts(t *testing.T) {
	server := newHTTPServer(http.NotFoundHandler())
	if server.ReadHeaderTimeout != 5*time.Second {
		t.Fatalf("ReadHeaderTimeout = %s, want %s", server.ReadHeaderTimeout, 5*time.Second)
	}
	if server.ReadTimeout != 30*time.Second {
		t.Fatalf("ReadTimeout = %s, want %s", server.ReadTimeout, 30*time.Second)
	}
	if server.WriteTimeout != 30*time.Second {
		t.Fatalf("WriteTimeout = %s, want %s", server.WriteTimeout, 30*time.Second)
	}
	if server.IdleTimeout != 60*time.Second {
		t.Fatalf("IdleTimeout = %s, want %s", server.IdleTimeout, 60*time.Second)
	}
}

func TestViewerDiscoveryIsStatelessAndIdempotent(t *testing.T) {
	handler := NewHandler("https://viewer.example.test")
	responses := make([]string, 2)
	for i := range responses {
		response := execute(t, handler, http.MethodGet, viewerDiscoveryPath, nil, "")
		if response.StatusCode != http.StatusOK {
			t.Fatalf("GET %s status = %d, want %d", viewerDiscoveryPath, response.StatusCode, http.StatusOK)
		}
		assertJSONContentType(t, response)
		var payload map[string]any
		decodeResponse(t, response, &payload)
		if payload["viewer_url"] != "https://viewer.example.test" {
			t.Fatalf("viewer_url = %v, want configured URL", payload["viewer_url"])
		}
		if _, exists := payload["id"]; exists {
			t.Fatal("stateless discovery returned an id")
		}
		if _, exists := payload["created_at"]; exists {
			t.Fatal("stateless discovery returned created_at")
		}
		encoded, err := json.Marshal(payload)
		if err != nil {
			t.Fatalf("marshal discovery response: %v", err)
		}
		responses[i] = string(encoded)
	}
	if responses[0] != responses[1] {
		t.Fatalf("discovery changed between calls: %q != %q", responses[0], responses[1])
	}

	response := execute(t, handler, http.MethodPost, "/v1/sessions", strings.NewReader(`{}`), "application/json")
	if response.StatusCode != http.StatusNotFound {
		response.Body.Close()
		t.Fatalf("removed session route status = %d, want %d", response.StatusCode, http.StatusNotFound)
	}
	assertErrorResponse(t, response, "not_found")
}

func TestReadinessUsesOfficialViewerHealthEndpoint(t *testing.T) {
	var healthy atomic.Bool
	healthy.Store(true)
	var observedPath atomic.Value
	var observedQuery atomic.Value
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		observedPath.Store(r.URL.Path)
		observedQuery.Store(r.URL.RawQuery)
		status := http.StatusOK
		if r.URL.Path != viewerHealthPath {
			status = http.StatusNotFound
		} else if !healthy.Load() {
			status = http.StatusServiceUnavailable
		}
		return &http.Response{
			StatusCode: status,
			Body:       io.NopCloser(strings.NewReader("")),
			Header:     make(http.Header),
			Request:    r,
		}, nil
	})}
	handler := newHandler("https://viewer.example.test/viewer?token=value", client)

	response := execute(t, handler, http.MethodGet, readinessPath, nil, "")
	if response.StatusCode != http.StatusOK {
		response.Body.Close()
		t.Fatalf("ready response status = %d, want %d", response.StatusCode, http.StatusOK)
	}
	response.Body.Close()
	if got := observedPath.Load(); got != viewerHealthPath {
		t.Fatalf("viewer health path = %v, want %q", got, viewerHealthPath)
	}
	if got := observedQuery.Load(); got != "" {
		t.Fatalf("viewer health query = %v, want empty query", got)
	}

	healthy.Store(false)
	response = execute(t, handler, http.MethodGet, readinessPath, nil, "")
	if response.StatusCode != http.StatusServiceUnavailable {
		response.Body.Close()
		t.Fatalf("unhealthy ready response status = %d, want %d", response.StatusCode, http.StatusServiceUnavailable)
	}
	assertErrorResponse(t, response, "viewer_unavailable")

	response = execute(t, handler, http.MethodGet, healthPath, nil, "")
	if response.StatusCode != http.StatusOK {
		response.Body.Close()
		t.Fatalf("liveness status = %d, want %d while viewer is unhealthy", response.StatusCode, http.StatusOK)
	}
	response.Body.Close()
}

func TestReadinessCanUseInternalHealthURLWithoutChangingDiscovery(t *testing.T) {
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if r.URL.String() != "http://viewer:8080/health" {
			t.Fatalf("health request URL = %q, want internal viewer health URL", r.URL.String())
		}
		return &http.Response{StatusCode: http.StatusOK, Body: io.NopCloser(strings.NewReader("")), Header: make(http.Header), Request: r}, nil
	})}
	handler, err := newHandlerWithHealthURL("http://192.0.2.10:8081", "http://viewer:8080", client)
	if err != nil {
		t.Fatalf("newHandlerWithHealthURL() error = %v", err)
	}

	ready := execute(t, handler, http.MethodGet, readinessPath, nil, "")
	if ready.StatusCode != http.StatusOK {
		ready.Body.Close()
		t.Fatalf("internal health readiness = %d, want %d", ready.StatusCode, http.StatusOK)
	}
	ready.Body.Close()

	discovered := execute(t, handler, http.MethodGet, viewerDiscoveryPath, nil, "")
	if discovered.StatusCode != http.StatusOK {
		discovered.Body.Close()
		t.Fatalf("discovery status = %d, want %d", discovered.StatusCode, http.StatusOK)
	}
	var payload map[string]string
	decodeResponse(t, discovered, &payload)
	if payload["viewer_url"] != "http://192.0.2.10:8081" {
		t.Fatalf("discovered viewer URL = %q, want external URL", payload["viewer_url"])
	}
}

func TestReadinessMapsFailuresAndCanRecover(t *testing.T) {
	var healthy atomic.Bool
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if r.URL.Path != viewerHealthPath {
			return responseWithStatus(r, http.StatusNotFound), nil
		}
		if !healthy.Load() {
			return responseWithStatus(r, http.StatusServiceUnavailable), nil
		}
		return responseWithStatus(r, http.StatusNoContent), nil
	})}
	handler := newHandler("https://viewer.example.test/viewer", client)
	response := execute(t, handler, http.MethodGet, readinessPath, nil, "")
	if response.StatusCode != http.StatusServiceUnavailable {
		response.Body.Close()
		t.Fatalf("starting viewer readiness = %d, want %d", response.StatusCode, http.StatusServiceUnavailable)
	}
	assertErrorResponse(t, response, "viewer_unavailable")

	healthy.Store(true)
	response = execute(t, handler, http.MethodGet, readinessPath, nil, "")
	if response.StatusCode != http.StatusOK {
		response.Body.Close()
		t.Fatalf("recovered viewer readiness = %d, want %d", response.StatusCode, http.StatusOK)
	}
	var payload map[string]string
	decodeResponse(t, response, &payload)
	if payload["status"] != "ok" || payload["viewer"] != "ready" {
		t.Fatalf("recovered readiness payload = %#v", payload)
	}
}

func TestReadinessFailureMapping(t *testing.T) {
	tests := []struct {
		name    string
		handler http.Handler
	}{
		{name: "invalid viewer URL", handler: newHandler("not-a-url", http.DefaultClient)},
		{name: "transport error", handler: newHandler("https://viewer.example.test", &http.Client{Transport: roundTripFunc(func(*http.Request) (*http.Response, error) {
			return nil, errors.New("dial failed")
		})})},
		{name: "redirect status", handler: newHandler("https://viewer.example.test", &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
			return responseWithStatus(r, http.StatusTemporaryRedirect), nil
		})})},
		{name: "server error status", handler: newHandler("https://viewer.example.test", &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
			return responseWithStatus(r, http.StatusInternalServerError), nil
		})})},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			response := execute(t, tt.handler, http.MethodGet, readinessPath, nil, "")
			if response.StatusCode != http.StatusServiceUnavailable {
				response.Body.Close()
				t.Fatalf("readiness status = %d, want %d", response.StatusCode, http.StatusServiceUnavailable)
			}
			assertErrorResponse(t, response, "viewer_unavailable")
		})
	}
}

func TestReadinessDoesNotFollowRedirects(t *testing.T) {
	var redirectedRequests atomic.Int32
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		redirectedRequests.Add(1)
		return responseWithStatus(r, http.StatusTemporaryRedirect), nil
	})}
	response := execute(t, newHandler("https://viewer.example.test", client), http.MethodGet, readinessPath, nil, "")
	if response.StatusCode != http.StatusServiceUnavailable {
		response.Body.Close()
		t.Fatalf("redirecting viewer readiness = %d, want %d", response.StatusCode, http.StatusServiceUnavailable)
	}
	assertErrorResponse(t, response, "viewer_unavailable")
	if got := redirectedRequests.Load(); got != 1 {
		t.Fatalf("readiness sent %d health requests, want 1 without following redirect", got)
	}
}

func TestNewHandlerWithHealthURLRequiresClient(t *testing.T) {
	if _, err := newHandlerWithHealthURL("https://viewer.example.test", "https://viewer.example.test", nil); err == nil {
		t.Fatal("newHandlerWithHealthURL() with nil client returned nil error")
	}
}

func TestNewHandlerPreservesCallerRedirectPolicy(t *testing.T) {
	callerPolicy := func(*http.Request, []*http.Request) error {
		return errors.New("caller redirect policy")
	}
	client := &http.Client{CheckRedirect: callerPolicy}
	handler := newHandler("https://viewer.example.test", client)
	if handler.viewerClient == client {
		t.Fatal("handler reused the caller's client instead of a copy")
	}
	if err := handler.viewerClient.CheckRedirect(&http.Request{}, nil); err == nil || err.Error() != "caller redirect policy" {
		t.Fatalf("CheckRedirect = %v, want caller policy to be preserved", err)
	}
}

func TestReadinessProbeHasIndependentTimeout(t *testing.T) {
	started := make(chan struct{})
	var startOnce sync.Once
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		startOnce.Do(func() { close(started) })
		<-r.Context().Done()
		return nil, r.Context().Err()
	})}

	handler := newHandler("https://viewer.example.test", client)
	handler.viewerTimeout = 75 * time.Millisecond
	start := time.Now()
	response := execute(t, handler, http.MethodGet, readinessPath, nil, "")
	if response.StatusCode != http.StatusServiceUnavailable {
		response.Body.Close()
		t.Fatalf("timed out readiness = %d, want %d", response.StatusCode, http.StatusServiceUnavailable)
	}
	assertErrorResponse(t, response, "viewer_unavailable")
	if elapsed := time.Since(start); elapsed > time.Second {
		t.Fatalf("readiness timeout took %s, want less than 1s", elapsed)
	}
	select {
	case <-started:
	default:
		t.Fatal("viewer health endpoint was not contacted")
	}
}

func TestHTTPIntegrationValidationAndMethods(t *testing.T) {
	handler := NewHandler("https://viewer.example.test")
	for _, method := range []string{http.MethodPost, http.MethodPut, http.MethodDelete, http.MethodPatch, http.MethodHead, http.MethodOptions} {
		for _, path := range []string{healthPath, readinessPath, viewerDiscoveryPath} {
			response := execute(t, handler, method, path, nil, "")
			if response.StatusCode != http.StatusMethodNotAllowed {
				response.Body.Close()
				t.Fatalf("%s %s status = %d, want %d", method, path, response.StatusCode, http.StatusMethodNotAllowed)
			}
			if got := response.Header.Get("Allow"); got != http.MethodGet {
				response.Body.Close()
				t.Fatalf("%s %s Allow = %q, want %q", method, path, got, http.MethodGet)
			}
			assertErrorResponse(t, response, "method_not_allowed")
		}
	}

	response := execute(t, handler, http.MethodGet, "/v1/sessions/missing", nil, "")
	if response.StatusCode != http.StatusNotFound {
		response.Body.Close()
		t.Fatalf("removed session route status = %d, want %d", response.StatusCode, http.StatusNotFound)
	}
	assertErrorResponse(t, response, "not_found")
}

func TestConcurrentReadiness(t *testing.T) {
	var probes atomic.Int32
	started := make(chan struct{})
	release := make(chan struct{})
	var startOnce sync.Once
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		probes.Add(1)
		startOnce.Do(func() { close(started) })
		<-release
		return responseWithStatus(r, http.StatusNoContent), nil
	})}
	handler := newHandler("https://viewer.example.test", client)
	const count = 32
	errCh := make(chan error, count)
	var wg sync.WaitGroup
	for range count {
		wg.Add(1)
		go func() {
			defer wg.Done()
			response := execute(t, handler, http.MethodGet, readinessPath, nil, "")
			defer response.Body.Close()
			if response.StatusCode != http.StatusOK {
				errCh <- errors.New("concurrent readiness returned non-200 status")
			}
		}()
	}
	// Hold the first probe open so the remaining requests coalesce onto it.
	<-started
	time.Sleep(100 * time.Millisecond)
	close(release)
	wg.Wait()
	close(errCh)
	for err := range errCh {
		t.Fatal(err)
	}
	if got := probes.Load(); got != 1 {
		t.Fatalf("viewer probes = %d, want 1 coalesced probe for %d concurrent requests", got, count)
	}
}

func TestShutdownHTTPServerIsBounded(t *testing.T) {
	t.Run("never started", func(t *testing.T) {
		server := newHTTPServer(http.NotFoundHandler())
		if err := shutdownHTTPServer(server); err != nil {
			t.Fatalf("shutdownHTTPServer() error = %v", err)
		}
	})

	t.Run("force closes a blocked handler", func(t *testing.T) {
		entered := make(chan struct{})
		release := make(chan struct{})
		server := newHTTPServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
			close(entered)
			<-release // block longer than shutdownTimeout
		}))
		defer close(release)

		listener, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			t.Fatalf("net.Listen() error = %v", err)
		}
		serveErrors := make(chan error, 1)
		go func() { serveErrors <- server.Serve(listener) }()

		requestDone := make(chan struct{})
		go func() {
			defer close(requestDone)
			_, _ = http.Get("http://" + listener.Addr().String() + "/")
		}()
		<-entered

		start := time.Now()
		shutdownErr := shutdownHTTPServer(server)
		elapsed := time.Since(start)
		if shutdownErr == nil {
			t.Fatal("shutdownHTTPServer() with a blocked handler returned nil error, want timeout")
		}
		if !errors.Is(shutdownErr, context.DeadlineExceeded) {
			t.Fatalf("shutdownHTTPServer() error = %v, want %v", shutdownErr, context.DeadlineExceeded)
		}
		if elapsed > shutdownTimeout+2*time.Second {
			t.Fatalf("force close took %s, want bounded near %s", elapsed, shutdownTimeout)
		}
		// The force close must have released the blocked handler and Serve.
		<-requestDone
		if err := <-serveErrors; !errors.Is(err, http.ErrServerClosed) {
			t.Fatalf("Serve() error = %v, want %v", err, http.ErrServerClosed)
		}
	})
}

func TestHTTPIntegrationConcurrentDiscovery(t *testing.T) {
	handler := NewHandler("https://viewer.example.test")
	const count = 32
	responses := make(chan string, count)
	errs := make(chan error, count)
	var wg sync.WaitGroup
	for i := 0; i < count; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			response := execute(t, handler, http.MethodGet, viewerDiscoveryPath, nil, "")
			if response.StatusCode != http.StatusOK {
				response.Body.Close()
				errs <- errors.New("concurrent discovery returned non-200 status")
				return
			}
			var payload struct {
				ViewerURL string `json:"viewer_url"`
			}
			if err := json.NewDecoder(response.Body).Decode(&payload); err != nil {
				response.Body.Close()
				errs <- err
				return
			}
			response.Body.Close()
			responses <- payload.ViewerURL
		}()
	}
	wg.Wait()
	close(responses)
	close(errs)

	for err := range errs {
		t.Fatalf("concurrent discovery error = %v", err)
	}
	counted := 0
	for discoveredURL := range responses {
		counted++
		if discoveredURL != "https://viewer.example.test" {
			t.Fatalf("concurrent viewer_url = %q, want configured URL", discoveredURL)
		}
	}
	if counted != count {
		t.Fatalf("received %d discovery responses, want %d", counted, count)
	}
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) {
	return f(r)
}

func responseWithStatus(request *http.Request, status int) *http.Response {
	return &http.Response{
		StatusCode: status,
		Body:       io.NopCloser(strings.NewReader("")),
		Header:     make(http.Header),
		Request:    request,
	}
}

func execute(t *testing.T, handler http.Handler, method, path string, body io.Reader, contentType string) *http.Response {
	t.Helper()
	request := httptest.NewRequest(method, "http://ghostlight.test"+path, body)
	if contentType != "" {
		request.Header.Set("Content-Type", contentType)
	}
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, request)
	return recorder.Result()
}

func decodeResponse(t *testing.T, response *http.Response, target any) {
	t.Helper()
	defer response.Body.Close()
	if err := json.NewDecoder(response.Body).Decode(target); err != nil {
		t.Fatalf("decode response: %v", err)
	}
}

func assertJSONContentType(t *testing.T, response *http.Response) {
	t.Helper()
	if got := response.Header.Get("Content-Type"); !strings.HasPrefix(got, "application/json") {
		response.Body.Close()
		t.Fatalf("Content-Type = %q, want application/json", got)
	}
}

func assertErrorResponse(t *testing.T, response *http.Response, wantCode string) {
	t.Helper()
	assertJSONContentType(t, response)
	var got struct {
		Error APIError `json:"error"`
	}
	decodeResponse(t, response, &got)
	if got.Error.Code != wantCode {
		t.Fatalf("error code = %q, want %q", got.Error.Code, wantCode)
	}
	if got.Error.Message == "" {
		t.Fatal("error message is empty")
	}
}
