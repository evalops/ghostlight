package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"
)

const (
	defaultListenAddr     = ":8080"
	defaultStorePath      = "/data/sessions.json"
	maxRequestBodyBytes   = 1 << 20
	viewerURLEnvironment  = "GHOSTLIGHT_VIEWER_URL"
	storePathEnvironment  = "GHOSTLIGHT_STORE_PATH"
	listenAddrEnvironment = "GHOSTLIGHT_LISTEN_ADDR"
)

type Config struct {
	ListenAddr string
	StorePath  string
	ViewerURL  string
}

type APIError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

type errorResponse struct {
	Error APIError `json:"error"`
}

type handler struct {
	store     *FileStore
	viewerURL string
}

func loadConfig() (Config, error) {
	viewerURL := strings.TrimSpace(os.Getenv(viewerURLEnvironment))
	if err := validateViewerURL(viewerURL); err != nil {
		return Config{}, fmt.Errorf("%s: %w", viewerURLEnvironment, err)
	}

	listenAddr := strings.TrimSpace(os.Getenv(listenAddrEnvironment))
	if listenAddr == "" {
		listenAddr = defaultListenAddr
	}
	storePath := strings.TrimSpace(os.Getenv(storePathEnvironment))
	if storePath == "" {
		storePath = defaultStorePath
	}
	return Config{ListenAddr: listenAddr, StorePath: storePath, ViewerURL: viewerURL}, nil
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
	switch strings.ToLower(parsed.Scheme) {
	case "http", "https":
		return nil
	default:
		return errors.New("must use the http or https scheme")
	}
}

func NewHandler(store *FileStore, viewerURL string) http.Handler {
	return &handler{store: store, viewerURL: viewerURL}
}

func (h *handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	switch {
	case r.URL.Path == "/healthz":
		h.handleHealth(w, r)
	case r.URL.Path == "/v1/sessions":
		h.handleSessions(w, r)
	case strings.HasPrefix(r.URL.Path, "/v1/sessions/"):
		h.handleSession(w, r)
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

func (h *handler) handleSessions(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeMethodNotAllowed(w, http.MethodPost)
		return
	}
	if !validateAndConsumeOptionalJSON(w, r) {
		return
	}

	session, err := h.store.Create(h.viewerURL, time.Now().UTC())
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error", "could not create session")
		return
	}
	w.Header().Set("Location", "/v1/sessions/"+session.ID)
	writeJSON(w, http.StatusCreated, session)
}

func (h *handler) handleSession(w http.ResponseWriter, r *http.Request) {
	id := strings.TrimPrefix(r.URL.Path, "/v1/sessions/")
	if id == "" || strings.Contains(id, "/") {
		writeError(w, http.StatusNotFound, "session_not_found", "session not found")
		return
	}

	switch r.Method {
	case http.MethodGet:
		session, err := h.store.Get(id)
		if errors.Is(err, ErrSessionNotFound) {
			writeError(w, http.StatusNotFound, "session_not_found", "session not found")
			return
		}
		if err != nil {
			writeError(w, http.StatusInternalServerError, "internal_error", "could not read session")
			return
		}
		writeJSON(w, http.StatusOK, session)
	case http.MethodDelete:
		if err := h.store.Delete(id); errors.Is(err, ErrSessionNotFound) {
			writeError(w, http.StatusNotFound, "session_not_found", "session not found")
		} else if err != nil {
			writeError(w, http.StatusInternalServerError, "internal_error", "could not delete session")
		} else {
			w.WriteHeader(http.StatusNoContent)
		}
	default:
		writeMethodNotAllowed(w, http.MethodGet+", "+http.MethodDelete)
	}
}

func validateAndConsumeOptionalJSON(w http.ResponseWriter, r *http.Request) bool {
	contentType := strings.TrimSpace(r.Header.Get("Content-Type"))
	if contentType != "" {
		mediaType, _, err := mime.ParseMediaType(contentType)
		if err != nil || !strings.EqualFold(mediaType, "application/json") {
			writeError(w, http.StatusUnsupportedMediaType, "unsupported_media_type", "Content-Type must be application/json")
			return false
		}
	} else if r.ContentLength != 0 {
		writeError(w, http.StatusUnsupportedMediaType, "unsupported_media_type", "Content-Type must be application/json when a body is present")
		return false
	}

	if r.ContentLength > maxRequestBodyBytes {
		writeError(w, http.StatusRequestEntityTooLarge, "request_too_large", "request body exceeds 1048576 bytes")
		return false
	}

	body := http.MaxBytesReader(w, r.Body, maxRequestBodyBytes)
	defer body.Close()
	decoder := json.NewDecoder(body)
	var object map[string]json.RawMessage
	if err := decoder.Decode(&object); err != nil {
		if errors.Is(err, io.EOF) {
			return true
		}
		if isRequestTooLarge(err) {
			writeError(w, http.StatusRequestEntityTooLarge, "request_too_large", "request body exceeds 1048576 bytes")
		} else {
			writeError(w, http.StatusBadRequest, "invalid_json", "request body must be a JSON object")
		}
		return false
	}
	if object == nil {
		writeError(w, http.StatusBadRequest, "invalid_json", "request body must be a JSON object")
		return false
	}

	var extra json.RawMessage
	if err := decoder.Decode(&extra); err != io.EOF {
		if isRequestTooLarge(err) {
			writeError(w, http.StatusRequestEntityTooLarge, "request_too_large", "request body exceeds 1048576 bytes")
		} else {
			writeError(w, http.StatusBadRequest, "invalid_json", "request body must contain one JSON object")
		}
		return false
	}
	return true
}

func isRequestTooLarge(err error) bool {
	var maxBytesError *http.MaxBytesError
	return errors.As(err, &maxBytesError)
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
