package main

import (
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"path/filepath"
	"strings"
	"sync"
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
		{name: "missing", url: "", want: false},
		{name: "relative", url: "/viewer", want: false},
		{name: "unsupported scheme", url: "ftp://viewer.example.test", want: false},
		{name: "missing host", url: "https:///session", want: false},
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
	t.Setenv("GHOSTLIGHT_STORE_PATH", "")
	t.Setenv("GHOSTLIGHT_LISTEN_ADDR", "")
	cfg, err := loadConfig()
	if err != nil {
		t.Fatalf("loadConfig() with valid viewer URL error = %v", err)
	}
	if cfg.ViewerURL != "https://viewer.example.test" {
		t.Fatalf("ViewerURL = %q", cfg.ViewerURL)
	}
	if cfg.ListenAddr != defaultListenAddr {
		t.Fatalf("ListenAddr = %q, want %q", cfg.ListenAddr, defaultListenAddr)
	}
	if cfg.StorePath != defaultStorePath {
		t.Fatalf("StorePath = %q, want %q", cfg.StorePath, defaultStorePath)
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

func TestHTTPIntegrationLifecycle(t *testing.T) {
	server := newIntegrationServer(t)
	defer server.Close()

	resp, err := http.Get(server.URL + "/healthz")
	if err != nil {
		t.Fatalf("GET /healthz error = %v", err)
	}
	if resp.StatusCode != http.StatusOK {
		resp.Body.Close()
		t.Fatalf("GET /healthz status = %d, want %d", resp.StatusCode, http.StatusOK)
	}
	assertJSONContentType(t, resp)
	var health map[string]string
	decodeResponse(t, resp, &health)
	if health["status"] != "ok" {
		t.Fatalf("health status = %q, want %q", health["status"], "ok")
	}

	resp = doRequest(t, http.MethodPost, server.URL+"/v1/sessions", nil, "")
	if resp.StatusCode != http.StatusCreated {
		resp.Body.Close()
		t.Fatalf("POST /v1/sessions with empty body status = %d, want %d", resp.StatusCode, http.StatusCreated)
	}
	var optionalBodySession Session
	decodeResponse(t, resp, &optionalBodySession)
	if optionalBodySession.ViewerURL != "https://viewer.example.test" {
		t.Fatalf("empty-body session viewer URL = %q, want %q", optionalBodySession.ViewerURL, "https://viewer.example.test")
	}

	resp = doJSONRequest(t, http.MethodPost, server.URL+"/v1/sessions", `{"profile":"default"}`)
	if resp.StatusCode != http.StatusCreated {
		resp.Body.Close()
		t.Fatalf("POST /v1/sessions status = %d, want %d", resp.StatusCode, http.StatusCreated)
	}
	assertJSONContentType(t, resp)
	var want Session
	decodeResponse(t, resp, &want)
	if want.ID == "" || want.ViewerURL != "https://viewer.example.test" || want.CreatedAt.IsZero() {
		t.Fatalf("POST /v1/sessions returned incomplete session: %#v", want)
	}

	resp, err = http.Get(server.URL + "/v1/sessions/" + want.ID)
	if err != nil {
		t.Fatalf("GET session error = %v", err)
	}
	if resp.StatusCode != http.StatusOK {
		resp.Body.Close()
		t.Fatalf("GET session status = %d, want %d", resp.StatusCode, http.StatusOK)
	}
	var got Session
	decodeResponse(t, resp, &got)
	if got != want {
		t.Fatalf("GET session = %#v, want %#v", got, want)
	}

	req, err := http.NewRequest(http.MethodDelete, server.URL+"/v1/sessions/"+want.ID, nil)
	if err != nil {
		t.Fatalf("construct DELETE request: %v", err)
	}
	resp, err = http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("DELETE session error = %v", err)
	}
	if resp.StatusCode != http.StatusNoContent {
		resp.Body.Close()
		t.Fatalf("DELETE session status = %d, want %d", resp.StatusCode, http.StatusNoContent)
	}
	resp.Body.Close()

	resp, err = http.Get(server.URL + "/v1/sessions/" + want.ID)
	if err != nil {
		t.Fatalf("GET deleted session error = %v", err)
	}
	if resp.StatusCode != http.StatusNotFound {
		resp.Body.Close()
		t.Fatalf("GET deleted session status = %d, want %d", resp.StatusCode, http.StatusNotFound)
	}
	assertErrorResponse(t, resp, "session_not_found")
}

func TestHTTPIntegrationValidationAndNotFound(t *testing.T) {
	server := newIntegrationServer(t)
	defer server.Close()

	resp := doRequest(t, http.MethodPost, server.URL+"/v1/sessions", strings.NewReader(`{}`), "text/plain")
	if resp.StatusCode != http.StatusUnsupportedMediaType {
		resp.Body.Close()
		t.Fatalf("wrong content type status = %d, want %d", resp.StatusCode, http.StatusUnsupportedMediaType)
	}
	assertErrorResponse(t, resp, "unsupported_media_type")

	resp = doRequest(t, http.MethodPost, server.URL+"/v1/sessions", strings.NewReader(`{"unterminated":`), "application/json")
	if resp.StatusCode != http.StatusBadRequest {
		resp.Body.Close()
		t.Fatalf("invalid JSON status = %d, want %d", resp.StatusCode, http.StatusBadRequest)
	}
	assertErrorResponse(t, resp, "invalid_json")

	resp = doRequest(t, http.MethodPost, server.URL+"/v1/sessions", strings.NewReader(`[]`), "application/json")
	if resp.StatusCode != http.StatusBadRequest {
		resp.Body.Close()
		t.Fatalf("non-object JSON status = %d, want %d", resp.StatusCode, http.StatusBadRequest)
	}
	assertErrorResponse(t, resp, "invalid_json")

	resp = doRequest(t, http.MethodPost, server.URL+"/v1/sessions", strings.NewReader(strings.Repeat("x", int(maxRequestBodyBytes)+1)), "application/json")
	if resp.StatusCode != http.StatusRequestEntityTooLarge {
		resp.Body.Close()
		t.Fatalf("oversized JSON status = %d, want %d", resp.StatusCode, http.StatusRequestEntityTooLarge)
	}
	assertErrorResponse(t, resp, "request_too_large")

	resp = doRequest(t, http.MethodGet, server.URL+"/v1/sessions/missing", nil, "")
	if resp.StatusCode != http.StatusNotFound {
		resp.Body.Close()
		t.Fatalf("missing session status = %d, want %d", resp.StatusCode, http.StatusNotFound)
	}
	assertErrorResponse(t, resp, "session_not_found")

	resp = doRequest(t, http.MethodGet, server.URL+"/healthz", nil, "")
	if resp.StatusCode != http.StatusOK {
		resp.Body.Close()
		t.Fatalf("GET /healthz status = %d, want %d", resp.StatusCode, http.StatusOK)
	}
	resp.Body.Close()

	resp = doRequest(t, http.MethodPost, server.URL+"/healthz", nil, "")
	if resp.StatusCode != http.StatusMethodNotAllowed {
		resp.Body.Close()
		t.Fatalf("POST /healthz status = %d, want %d", resp.StatusCode, http.StatusMethodNotAllowed)
	}
	assertErrorResponse(t, resp, "method_not_allowed")
}

func TestHTTPIntegrationConcurrentCreate(t *testing.T) {
	server := newIntegrationServer(t)
	defer server.Close()

	const count = 32
	ids := make(chan string, count)
	errs := make(chan error, count)
	var wg sync.WaitGroup
	for i := 0; i < count; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			resp, err := doJSONRequestWithClient(server.Client(), http.MethodPost, server.URL+"/v1/sessions", `{}`)
			if err != nil {
				errs <- err
				return
			}
			if resp.StatusCode != http.StatusCreated {
				resp.Body.Close()
				errs <- errors.New("concurrent create returned non-201 status")
				return
			}
			var session Session
			if err := json.NewDecoder(resp.Body).Decode(&session); err != nil {
				resp.Body.Close()
				errs <- err
				return
			}
			resp.Body.Close()
			ids <- session.ID
		}()
	}
	wg.Wait()
	close(ids)
	close(errs)

	for err := range errs {
		t.Fatalf("concurrent HTTP create error = %v", err)
	}
	seen := make(map[string]struct{}, count)
	for id := range ids {
		if _, exists := seen[id]; exists {
			t.Fatalf("duplicate HTTP session id %q", id)
		}
		seen[id] = struct{}{}
	}
	if len(seen) != count {
		t.Fatalf("created %d HTTP sessions, want %d", len(seen), count)
	}
}

type integrationServer struct {
	URL    string
	server *http.Server
	done   chan error
}

func (s *integrationServer) Client() *http.Client {
	return http.DefaultClient
}

func (s *integrationServer) Close() {
	_ = s.server.Close()
	<-s.done
}

func newIntegrationServer(t *testing.T) *integrationServer {
	t.Helper()
	store, err := NewFileStore(filepath.Join(t.TempDir(), "sessions.json"))
	if err != nil {
		t.Fatalf("NewFileStore() error = %v", err)
	}
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen for integration server: %v", err)
	}
	server := newHTTPServer(NewHandler(store, "https://viewer.example.test"))
	done := make(chan error, 1)
	go func() {
		done <- server.Serve(listener)
	}()
	return &integrationServer{
		URL:    "http://" + listener.Addr().String(),
		server: server,
		done:   done,
	}
}

func doJSONRequest(t *testing.T, method, url, body string) *http.Response {
	t.Helper()
	resp, err := doRequestWithClient(http.DefaultClient, method, url, strings.NewReader(body), "application/json")
	if err != nil {
		t.Fatalf("%s %s error = %v", method, url, err)
	}
	return resp
}

func doJSONRequestWithClient(client *http.Client, method, url, body string) (*http.Response, error) {
	return doRequestWithClient(client, method, url, strings.NewReader(body), "application/json")
}

func doRequest(t *testing.T, method, url string, body io.Reader, contentType string) *http.Response {
	t.Helper()
	resp, err := doRequestWithClient(http.DefaultClient, method, url, body, contentType)
	if err != nil {
		t.Fatalf("%s %s error = %v", method, url, err)
	}
	return resp
}

func doRequestWithClient(client *http.Client, method, url string, body io.Reader, contentType string) (*http.Response, error) {
	req, err := http.NewRequest(method, url, body)
	if err != nil {
		return nil, err
	}
	if contentType != "" {
		req.Header.Set("Content-Type", contentType)
	}
	return client.Do(req)
}

func decodeResponse(t *testing.T, resp *http.Response, target any) {
	t.Helper()
	defer resp.Body.Close()
	if err := json.NewDecoder(resp.Body).Decode(target); err != nil {
		t.Fatalf("decode response: %v", err)
	}
}

func assertJSONContentType(t *testing.T, resp *http.Response) {
	t.Helper()
	if got := resp.Header.Get("Content-Type"); !strings.HasPrefix(got, "application/json") {
		resp.Body.Close()
		t.Fatalf("Content-Type = %q, want application/json", got)
	}
}

func assertErrorResponse(t *testing.T, resp *http.Response, wantCode string) {
	t.Helper()
	assertJSONContentType(t, resp)
	var got struct {
		Error APIError `json:"error"`
	}
	decodeResponse(t, resp, &got)
	if got.Error.Code != wantCode {
		t.Fatalf("error code = %q, want %q", got.Error.Code, wantCode)
	}
	if got.Error.Message == "" {
		t.Fatal("error message is empty")
	}
}
