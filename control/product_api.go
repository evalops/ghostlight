package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

const (
	maxJSONBodyBytes          = 1 << 20
	maxAttachmentBytes        = 25 << 20
	maxSessionAttachments     = 100
	maxSessionAttachmentBytes = 1 << 30
	maxBridgeCommands         = 100
	continuityIntentTTL       = 10 * time.Minute
	peripheralGrantTTL        = 8 * time.Hour
)

var peripheralDirections = map[string]string{
	"paste": "local_to_remote", "upload": "local_to_remote", "drag_in": "local_to_remote",
	"camera": "local_to_remote", "microphone": "local_to_remote", "pointer_lock": "local_to_remote", "cursor_control": "local_to_remote",
	"copy": "remote_to_local", "download": "remote_to_local", "drag_out": "remote_to_local",
	"audio": "remote_to_local", "notifications": "remote_to_local",
}

var brokeredPeripheralCapabilities = map[string]bool{
	"download": true, "camera": true, "microphone": true,
}

var credentialBearingURLQueryKeys = map[string]bool{
	"accesscode": true, "accesstoken": true, "apikey": true, "auth": true,
	"authorization": true, "code": true, "cookie": true, "credential": true,
	"idtoken": true, "jwt": true, "key": true, "password": true, "passwd": true,
	"refreshtoken": true, "secret": true,
	"session": true, "sessionid": true, "sessiontoken": true, "sig": true,
	"signature": true, "token": true, "xamzcredential": true,
	"xamzsecuritytoken": true, "xamzsignature": true, "xgoogcredential": true,
	"xgoogsecuritytoken": true, "xgoogsignature": true,
}

func (h *handler) handleAPI(w http.ResponseWriter, r *http.Request) {
	if h.store == nil {
		writeError(w, http.StatusNotFound, "not_found", "route not found")
		return
	}
	principal, err := h.authenticateAPI(r)
	if err != nil {
		if errors.Is(err, errUnauthorized) {
			writeError(w, http.StatusUnauthorized, "unauthorized", "a valid API token is required")
		} else {
			writeStoreError(w, err)
		}
		return
	}
	parts := splitPath(r.URL.Path)
	switch {
	case len(parts) == 2 && parts[1] == "native-client":
		if !requireNativeClientPrincipal(w, principal) {
			return
		}
		h.handleNativeClient(w, r, principal.id)
	case len(parts) == 2 && parts[1] == "native-client-enrollments":
		if !requireOperatorPrincipal(w, principal) {
			return
		}
		h.handleNativeClientEnrollments(w, r)
	case len(parts) == 2 && parts[1] == "native-clients":
		if !requireOperatorPrincipal(w, principal) {
			return
		}
		h.handleNativeClients(w, r)
	case len(parts) == 3 && parts[1] == "native-clients":
		if !requireOperatorPrincipal(w, principal) {
			return
		}
		h.handleNativeClient(w, r, parts[2])
	case len(parts) == 2 && parts[1] == "workspaces":
		if !requirePrincipalScope(w, principal, nativeClientScope) {
			return
		}
		h.handleWorkspaces(w, r)
	case len(parts) == 4 && parts[1] == "workspaces" && parts[3] == "preferences":
		if !requirePrincipalScope(w, principal, nativeClientScope) {
			return
		}
		h.handleWorkspacePreferences(w, r, parts[2])
	case len(parts) == 4 && parts[1] == "workspaces" && parts[3] == "spaces":
		if !requirePrincipalScope(w, principal, nativeClientScope) {
			return
		}
		h.handleActivitySpaces(w, r, parts[2])
	case len(parts) == 4 && parts[1] == "workspaces" && parts[3] == "continuity":
		if !requirePrincipalScope(w, principal, nativeClientScope) {
			return
		}
		h.handleContinuity(w, r, parts[2])
	case len(parts) == 4 && parts[1] == "workspaces" && parts[3] == "peripheral-grants":
		if !requirePrincipalScope(w, principal, nativeClientScope) {
			return
		}
		h.handlePeripheralGrants(w, r, parts[2], principal)
	case len(parts) == 5 && parts[1] == "workspaces" && parts[3] == "peripheral-grants":
		if !requirePrincipalScope(w, principal, nativeClientScope) {
			return
		}
		h.handlePeripheralGrant(w, r, parts[2], parts[4], principal)
	case len(parts) == 4 && parts[1] == "workspaces" && parts[3] == "peripheral-authorizations":
		if !requirePrincipalScope(w, principal, nativeClientScope) {
			return
		}
		h.handlePeripheralAuthorization(w, r, parts[2], principal)
	case len(parts) == 4 && parts[1] == "workspaces" && parts[3] == "peripheral-audit":
		if !requirePrincipalScope(w, principal, nativeClientScope) {
			return
		}
		h.handlePeripheralAudit(w, r, parts[2], principal)
	case len(parts) == 6 && parts[1] == "workspaces" && parts[3] == "spaces":
		if !requirePrincipalScope(w, principal, nativeClientScope) {
			return
		}
		h.handleActivitySpaceAction(w, r, parts[2], parts[4], parts[5])
	case len(parts) == 4 && parts[1] == "workspaces" && parts[3] == "chrome-pairings":
		if !requirePrincipalScope(w, principal, nativeClientScope) {
			return
		}
		h.handleChromePairings(w, r, parts[2])
	case len(parts) == 4 && parts[1] == "workspaces" && parts[3] == "chrome-devices":
		if !requirePrincipalScope(w, principal, nativeClientScope) {
			return
		}
		h.handleChromeDevices(w, r, parts[2])
	case len(parts) == 5 && parts[1] == "workspaces" && parts[3] == "chrome-devices":
		if !requirePrincipalScope(w, principal, nativeClientScope) {
			return
		}
		h.handleChromeDevice(w, r, parts[2], parts[4])
	case len(parts) == 4 && parts[1] == "workspaces" && parts[3] == "chrome-handoffs":
		if !requirePrincipalScope(w, principal, nativeClientScope) {
			return
		}
		h.handleWorkspaceChromeHandoffs(w, r, parts[2], "")
	case len(parts) == 5 && parts[1] == "workspaces" && parts[3] == "chrome-handoffs":
		if !requirePrincipalScope(w, principal, nativeClientScope) {
			return
		}
		h.handleWorkspaceChromeHandoffs(w, r, parts[2], parts[4])
	case len(parts) == 4 && parts[1] == "workspaces" && parts[3] == "chrome-library":
		if !requirePrincipalScope(w, principal, nativeClientScope) {
			return
		}
		h.handleWorkspaceChromeLibrary(w, r, parts[2])
	case len(parts) == 2 && parts[1] == "sessions":
		if !requirePrincipalScope(w, principal, nativeClientScope) {
			return
		}
		h.handleSessions(w, r)
	case len(parts) >= 3 && parts[1] == "sessions":
		if !requirePrincipalScope(w, principal, nativeClientScope) {
			return
		}
		h.handleSessionResource(w, r, parts[2], parts[3:], principal)
	default:
		writeError(w, http.StatusNotFound, "not_found", "route not found")
	}
}

func canonicalPeripheralOrigin(raw string) (string, bool) {
	value, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || (value.Scheme != "http" && value.Scheme != "https") || value.Host == "" || value.User != nil || value.RawQuery != "" || value.Fragment != "" || (value.Path != "" && value.Path != "/") {
		return "", false
	}
	value.Scheme = strings.ToLower(value.Scheme)
	value.Host = strings.ToLower(value.Host)
	value.Path = ""
	return value.String(), true
}

func principalGrantClientID(principal apiPrincipal) string {
	if principal.isOperator() {
		return "operator"
	}
	return principal.id
}

func (h *handler) handlePeripheralGrants(w http.ResponseWriter, r *http.Request, workspaceID string, principal apiPrincipal) {
	clientID := principalGrantClientID(principal)
	if r.Method == http.MethodGet {
		values, err := h.store.listPeripheralGrants(r.Context(), workspaceID, clientID)
		if err != nil {
			writeStoreError(w, err)
			return
		}
		writeJSON(w, http.StatusOK, values)
		return
	}
	if r.Method != http.MethodPost {
		writeMethodNotAllowed(w, http.MethodGet+", "+http.MethodPost)
		return
	}
	key := strings.TrimSpace(r.Header.Get("Idempotency-Key"))
	if key == "" || len(key) > 200 || leaseToken(r) == "" {
		writeError(w, http.StatusBadRequest, "invalid_request", "Idempotency-Key and lease token are required")
		return
	}
	var input struct {
		SessionID  string    `json:"session_id"`
		Capability string    `json:"capability"`
		Direction  string    `json:"direction"`
		Origin     string    `json:"origin"`
		ExpiresAt  time.Time `json:"expires_at"`
	}
	body, err := decodeStrictJSON(r, &input)
	input.Capability = strings.TrimSpace(input.Capability)
	input.Direction = strings.TrimSpace(input.Direction)
	origin, validOrigin := canonicalPeripheralOrigin(input.Origin)
	now := h.now().UTC()
	if err != nil || input.SessionID == "" || peripheralDirections[input.Capability] != input.Direction || !validOrigin || !input.ExpiresAt.After(now) || input.ExpiresAt.After(now.Add(peripheralGrantTTL)) {
		writeError(w, http.StatusBadRequest, "invalid_request", "a known capability, its fixed direction, canonical HTTP(S) origin, session_id, and expiry within 8 hours are required")
		return
	}
	if !brokeredPeripheralCapabilities[input.Capability] {
		writeError(w, http.StatusConflict, "capability_unavailable", "this capability has no enforceable native adapter")
		return
	}
	digest := sha256.Sum256(append([]byte("peripheral-grant\x00"), body...))
	value, created, err := h.store.createPeripheralGrant(r.Context(), workspaceID, input.SessionID, clientID, leaseToken(r), key, hex.EncodeToString(digest[:]), input.Capability, input.Direction, origin, input.ExpiresAt.UTC())
	if err != nil {
		writeStoreError(w, err)
		return
	}
	status := http.StatusOK
	if created {
		status = http.StatusCreated
	}
	writeJSON(w, status, value)
}

func (h *handler) handlePeripheralGrant(w http.ResponseWriter, r *http.Request, workspaceID, grantID string, principal apiPrincipal) {
	if r.Method != http.MethodDelete {
		writeMethodNotAllowed(w, http.MethodDelete)
		return
	}
	value, err := h.store.revokePeripheralGrant(r.Context(), workspaceID, grantID, principalGrantClientID(principal))
	if err != nil {
		writeStoreError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, value)
}

func (h *handler) handlePeripheralAuthorization(w http.ResponseWriter, r *http.Request, workspaceID string, principal apiPrincipal) {
	if r.Method != http.MethodPost {
		writeMethodNotAllowed(w, http.MethodPost)
		return
	}
	var input struct {
		SessionID  string `json:"session_id"`
		Capability string `json:"capability"`
		Direction  string `json:"direction"`
		Origin     string `json:"origin"`
	}
	_, err := decodeStrictJSON(r, &input)
	origin, validOrigin := canonicalPeripheralOrigin(input.Origin)
	if err != nil || input.SessionID == "" || peripheralDirections[input.Capability] != input.Direction || !validOrigin {
		writeError(w, http.StatusBadRequest, "invalid_request", "a known capability, its fixed direction, canonical HTTP(S) origin, and session_id are required")
		return
	}
	value, err := h.store.authorizePeripheral(r.Context(), workspaceID, input.SessionID, principalGrantClientID(principal), input.Capability, input.Direction, origin)
	if err != nil {
		writeStoreError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, value)
}

func (h *handler) handlePeripheralAudit(w http.ResponseWriter, r *http.Request, workspaceID string, principal apiPrincipal) {
	if r.Method != http.MethodGet {
		writeMethodNotAllowed(w, http.MethodGet)
		return
	}
	values, err := h.store.listPeripheralAudit(r.Context(), workspaceID, principalGrantClientID(principal))
	if err != nil {
		writeStoreError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, values)
}

func (h *handler) handleContinuity(w http.ResponseWriter, r *http.Request, workspaceID string) {
	if r.Method == http.MethodGet {
		resume, err := h.store.listActivitySpaces(r.Context(), workspaceID)
		if err != nil {
			writeStoreError(w, err)
			return
		}
		bookmarks, err := h.store.listChromeLibrary(r.Context(), workspaceID, "bookmark")
		if err != nil {
			writeStoreError(w, err)
			return
		}
		readingList, err := h.store.listChromeLibrary(r.Context(), workspaceID, "reading_list")
		if err != nil {
			writeStoreError(w, err)
			return
		}
		send, err := h.store.listChromeHandoffs(r.Context(), workspaceID)
		if err != nil {
			writeStoreError(w, err)
			return
		}
		writeJSON(w, http.StatusOK, ContinuityOverview{
			Resume:      resume,
			Browse:      ContinuityBrowse{Authority: "chrome_snapshot", Bookmarks: bookmarks, ReadingList: readingList},
			Send:        send,
			GeneratedAt: h.now().UTC(),
		})
		return
	}
	if r.Method != http.MethodPost {
		writeMethodNotAllowed(w, http.MethodGet+", "+http.MethodPost)
		return
	}
	key := strings.TrimSpace(r.Header.Get("Idempotency-Key"))
	if key == "" || len(key) > 200 || leaseToken(r) == "" {
		writeError(w, http.StatusBadRequest, "invalid_request", "Idempotency-Key and lease token are required")
		return
	}
	var input struct {
		Verb             string    `json:"verb"`
		Adapter          string    `json:"adapter"`
		SessionID        string    `json:"session_id"`
		ExpectedRevision int64     `json:"expected_revision"`
		ExpiresAt        time.Time `json:"expires_at"`
		SpaceID          string    `json:"space_id,omitempty"`
		URL              string    `json:"url,omitempty"`
	}
	body, err := decodeStrictJSON(r, &input)
	input.Verb = strings.TrimSpace(input.Verb)
	input.Adapter = strings.TrimSpace(input.Adapter)
	now := h.now().UTC()
	validAdapter := input.Adapter == "native_ui" || input.Adapter == "url_handler" || input.Adapter == "share" || input.Adapter == "chrome_extension"
	if err != nil || (input.Verb != "resume" && input.Verb != "send") || !validAdapter || input.SessionID == "" || input.ExpectedRevision < 1 || !input.ExpiresAt.After(now) || input.ExpiresAt.After(now.Add(continuityIntentTTL)) {
		writeError(w, http.StatusBadRequest, "invalid_request", "verb, adapter, session_id, expected_revision, and an expiry within 10 minutes are required")
		return
	}
	session, err := h.store.getSession(r.Context(), input.SessionID)
	if err != nil {
		writeStoreError(w, err)
		return
	}
	if session.WorkspaceID != workspaceID {
		writeError(w, http.StatusNotFound, "not_found", "session was not found in this workspace")
		return
	}
	command := BrowserCommand{
		ExpectedRevision:  input.ExpectedRevision,
		ContinuityVerb:    input.Verb,
		ContinuityAdapter: input.Adapter,
		ContinuityExpiry:  &input.ExpiresAt,
	}
	var space *ActivitySpace
	switch input.Verb {
	case "resume":
		if input.SpaceID == "" || input.URL != "" {
			writeError(w, http.StatusBadRequest, "invalid_request", "resume requires only space_id")
			return
		}
		value, err := h.store.getActivitySpace(r.Context(), workspaceID, input.SpaceID)
		if err != nil {
			writeStoreError(w, err)
			return
		}
		destinations := make([]string, len(value.Tabs))
		for index, tab := range value.Tabs {
			destinations[index] = tab.URL
		}
		command.Type = "restore_space"
		command.SpaceID = value.ID
		command.Destinations = destinations
		command.ActivePosition = value.ActivePosition
		space = &value
	case "send":
		if input.SpaceID != "" || !validRecentURL(input.URL) {
			writeError(w, http.StatusBadRequest, "unsafe_url", "send requires one credential-free HTTP or HTTPS destination")
			return
		}
		command.Type = "create_tab"
		command.URL = input.URL
	}
	digest := sha256.Sum256(append([]byte("continuity\x00"), body...))
	queued, created, err := h.store.createCommand(r.Context(), input.SessionID, leaseToken(r), key, hex.EncodeToString(digest[:]), command)
	if err != nil {
		writeStoreError(w, err)
		return
	}
	status := http.StatusOK
	if created {
		status = http.StatusAccepted
	}
	writeJSON(w, status, ContinuityIntentReceipt{Verb: input.Verb, Adapter: input.Adapter, Authority: "ghostlight_session", ExpiresAt: input.ExpiresAt, Space: space, Command: queued})
}

func (h *handler) handleActivitySpaces(w http.ResponseWriter, r *http.Request, workspaceID string) {
	switch r.Method {
	case http.MethodGet:
		spaces, err := h.store.listActivitySpaces(r.Context(), workspaceID)
		if err != nil {
			writeStoreError(w, err)
			return
		}
		writeJSON(w, http.StatusOK, spaces)
	case http.MethodPost:
		key := strings.TrimSpace(r.Header.Get("Idempotency-Key"))
		if key == "" || len(key) > 200 || leaseToken(r) == "" {
			writeError(w, http.StatusBadRequest, "invalid_request", "Idempotency-Key and lease token are required")
			return
		}
		var input struct {
			Name             string `json:"name"`
			SessionID        string `json:"session_id"`
			ExpectedRevision int64  `json:"expected_revision"`
		}
		body, err := decodeStrictJSON(r, &input)
		input.Name = strings.TrimSpace(input.Name)
		if err != nil || input.Name == "" || utf8.RuneCountInString(input.Name) > 80 || input.SessionID == "" || input.ExpectedRevision < 1 {
			writeError(w, http.StatusBadRequest, "invalid_request", "space name, session_id, and expected_revision are required")
			return
		}
		digest := sha256.Sum256(body)
		space, created, err := h.store.createActivitySpace(r.Context(), workspaceID, input.SessionID, input.Name, input.ExpectedRevision, leaseToken(r), key, hex.EncodeToString(digest[:]))
		if err != nil {
			writeStoreError(w, err)
			return
		}
		status := http.StatusOK
		if created {
			status = http.StatusCreated
		}
		writeJSON(w, status, space)
	default:
		writeMethodNotAllowed(w, http.MethodGet+", "+http.MethodPost)
	}
}

func (h *handler) handleActivitySpaceAction(w http.ResponseWriter, r *http.Request, workspaceID, spaceID, action string) {
	if r.Method != http.MethodPost || (action != "park" && action != "activate") {
		writeMethodNotAllowed(w, http.MethodPost)
		return
	}
	key := strings.TrimSpace(r.Header.Get("Idempotency-Key"))
	if key == "" || len(key) > 200 || leaseToken(r) == "" {
		writeError(w, http.StatusBadRequest, "invalid_request", "Idempotency-Key and lease token are required")
		return
	}
	var input struct {
		SessionID        string `json:"session_id"`
		ExpectedRevision int64  `json:"expected_revision"`
	}
	body, err := decodeStrictJSON(r, &input)
	if err != nil || input.SessionID == "" || input.ExpectedRevision < 1 {
		writeError(w, http.StatusBadRequest, "invalid_request", "session_id and expected_revision are required")
		return
	}
	digest := sha256.Sum256([]byte(action + "\x00" + spaceID + "\x00" + string(body)))
	hash := hex.EncodeToString(digest[:])
	if action == "park" {
		space, err := h.store.parkActivitySpace(r.Context(), workspaceID, spaceID, input.SessionID, input.ExpectedRevision, leaseToken(r), key, hash)
		if err != nil {
			writeStoreError(w, err)
			return
		}
		writeJSON(w, http.StatusOK, space)
		return
	}
	space, err := h.store.getActivitySpace(r.Context(), workspaceID, spaceID)
	if err != nil {
		writeStoreError(w, err)
		return
	}
	destinations := make([]string, len(space.Tabs))
	for index, tab := range space.Tabs {
		destinations[index] = tab.URL
	}
	command := BrowserCommand{Type: "restore_space", SpaceID: space.ID, Destinations: destinations, ActivePosition: space.ActivePosition, ExpectedRevision: input.ExpectedRevision}
	queued, _, err := h.store.createCommand(r.Context(), input.SessionID, leaseToken(r), key, hash, command)
	if err != nil {
		writeStoreError(w, err)
		return
	}
	writeJSON(w, http.StatusAccepted, ActivitySpaceActivation{Space: space, Command: queued})
}

func (h *handler) handleWorkspacePreferences(w http.ResponseWriter, r *http.Request, workspaceID string) {
	switch r.Method {
	case http.MethodGet:
		preferences, err := h.store.getWorkspacePreferences(r.Context(), workspaceID)
		if err != nil {
			writeStoreError(w, err)
			return
		}
		writeJSON(w, http.StatusOK, preferences)
	case http.MethodPut:
		var input WorkspacePreferences
		if _, err := decodeStrictJSON(r, &input); err != nil {
			writeError(w, http.StatusBadRequest, "invalid_request", "workspace preferences are invalid")
			return
		}
		input.WorkspaceID = workspaceID
		if !validWorkspacePreferences(input) {
			writeError(w, http.StatusBadRequest, "invalid_request", "workspace preferences are invalid")
			return
		}
		preferences, err := h.store.putWorkspacePreferences(r.Context(), input)
		if err != nil {
			writeStoreError(w, err)
			return
		}
		writeJSON(w, http.StatusOK, preferences)
	default:
		writeMethodNotAllowed(w, http.MethodGet+", "+http.MethodPut)
	}
}

func validWorkspacePreferences(value WorkspacePreferences) bool {
	if len(value.Shortcuts) > 24 || len(value.RecentURLs) > 20 || len(value.SearchURL) > 500 || !strings.Contains(value.SearchURL, "{query}") {
		return false
	}
	if !validNavigationURL(strings.ReplaceAll(value.SearchURL, "{query}", "test")) {
		return false
	}
	seen := map[string]bool{}
	for position, shortcut := range value.Shortcuts {
		if shortcut.ID == "" || len(shortcut.ID) > 100 || shortcut.Name == "" || len(shortcut.Name) > 100 || shortcut.Position != position || !validNavigationURL(shortcut.URL) || seen[shortcut.ID] {
			return false
		}
		seen[shortcut.ID] = true
	}
	for _, recent := range value.RecentURLs {
		if !validRecentURL(recent) {
			return false
		}
	}
	return true
}

func (h *handler) handleBridge(w http.ResponseWriter, r *http.Request) {
	if h.store == nil {
		writeError(w, http.StatusNotFound, "not_found", "route not found")
		return
	}
	if !authorized(r, h.config.BridgeToken) {
		writeError(w, http.StatusUnauthorized, "unauthorized", "a valid bridge token is required")
		return
	}
	parts := splitPath(r.URL.Path)
	switch {
	case len(parts) == 3 && parts[2] == "bootstrap":
		if r.Method != http.MethodGet {
			writeMethodNotAllowed(w, http.MethodGet)
			return
		}
		sessions, err := h.store.listSessions(r.Context())
		if err != nil || len(sessions) != 1 {
			writeStoreError(w, err)
			return
		}
		writeJSON(w, http.StatusOK, map[string]string{"session_id": sessions[0].ID})
	case len(parts) == 3 && parts[2] == "heartbeat":
		h.handleBridgeHeartbeat(w, r)
	case len(parts) == 3 && parts[2] == "commands":
		h.handleBridgeCommands(w, r)
	case len(parts) == 5 && parts[2] == "commands" && parts[4] == "ack":
		h.handleBridgeCommandAck(w, r, parts[3])
	case len(parts) == 4 && parts[2] == "attachments":
		h.handleBridgeAttachment(w, r, parts[3])
	default:
		writeError(w, http.StatusNotFound, "not_found", "route not found")
	}
}

func (h *handler) handleWorkspaces(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeMethodNotAllowed(w, http.MethodGet)
		return
	}
	workspaces, err := h.store.listWorkspaces(r.Context())
	if err != nil {
		writeStoreError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, workspaces)
}

func (h *handler) handleSessions(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		sessions, err := h.store.listSessions(r.Context())
		if err != nil {
			writeStoreError(w, err)
			return
		}
		writeJSON(w, http.StatusOK, sessions)
	case http.MethodPost:
		key := strings.TrimSpace(r.Header.Get("Idempotency-Key"))
		if key == "" || len(key) > 200 {
			writeError(w, http.StatusBadRequest, "invalid_request", "Idempotency-Key is required")
			return
		}
		var input struct {
			WorkspaceID string `json:"workspace_id"`
		}
		body, err := decodeStrictJSON(r, &input)
		if err != nil || input.WorkspaceID == "" {
			writeError(w, http.StatusBadRequest, "invalid_request", "workspace_id is required")
			return
		}
		digest := sha256.Sum256(body)
		session, err := h.store.ensureSession(r.Context(), input.WorkspaceID, key, hex.EncodeToString(digest[:]))
		if err != nil {
			writeStoreError(w, err)
			return
		}
		writeJSON(w, http.StatusOK, session)
	default:
		writeMethodNotAllowed(w, http.MethodGet+", "+http.MethodPost)
	}
}

func (h *handler) handleSessionResource(w http.ResponseWriter, r *http.Request, sessionID string, tail []string, principal apiPrincipal) {
	if sessionID == "" {
		writeError(w, http.StatusNotFound, "session_not_found", "session was not found")
		return
	}
	switch {
	case len(tail) == 0:
		if r.Method != http.MethodGet {
			writeMethodNotAllowed(w, http.MethodGet)
			return
		}
		session, err := h.store.getSession(r.Context(), sessionID)
		if err != nil {
			writeStoreError(w, err)
			return
		}
		writeJSON(w, http.StatusOK, session)
	case len(tail) == 1 && tail[0] == "events":
		if r.Method != http.MethodGet {
			writeMethodNotAllowed(w, http.MethodGet)
			return
		}
		after, err := strconv.ParseInt(r.URL.Query().Get("after_revision"), 10, 64)
		if err != nil || after < 0 {
			writeError(w, http.StatusBadRequest, "invalid_request", "after_revision must be a non-negative integer")
			return
		}
		waitMilliseconds := int64(0)
		if raw := r.URL.Query().Get("wait_ms"); raw != "" {
			waitMilliseconds, err = strconv.ParseInt(raw, 10, 64)
			if err != nil || waitMilliseconds < 0 || waitMilliseconds > 10000 {
				writeError(w, http.StatusBadRequest, "invalid_request", "wait_ms must be an integer between 0 and 10000")
				return
			}
		}
		deadline := time.NewTimer(time.Duration(waitMilliseconds) * time.Millisecond)
		defer deadline.Stop()
		poll := time.NewTicker(50 * time.Millisecond)
		defer poll.Stop()
		for {
			session, err := h.store.getSession(r.Context(), sessionID)
			if err != nil {
				writeStoreError(w, err)
				return
			}
			if session.Revision > after {
				writeJSON(w, http.StatusOK, session)
				return
			}
			if waitMilliseconds == 0 {
				w.WriteHeader(http.StatusNoContent)
				return
			}
			select {
			case <-r.Context().Done():
				return
			case <-deadline.C:
				w.WriteHeader(http.StatusNoContent)
				return
			case <-poll.C:
			}
		}
	case len(tail) == 1 && tail[0] == "leases":
		h.handleLeaseAcquire(w, r, sessionID)
	case len(tail) == 2 && tail[0] == "leases":
		h.handleLease(w, r, sessionID, tail[1])
	case len(tail) == 1 && tail[0] == "commands":
		h.handleCommand(w, r, sessionID)
	case len(tail) == 2 && tail[0] == "commands":
		h.handleCommandStatus(w, r, sessionID, tail[1])
	case len(tail) == 1 && tail[0] == "stream":
		h.handleStream(w, r, sessionID, principal)
	case len(tail) == 1 && tail[0] == "attachments":
		h.handleAttachments(w, r, sessionID)
	case len(tail) == 2 && tail[0] == "attachments":
		h.handleAttachmentMetadata(w, r, sessionID, tail[1])
	default:
		writeError(w, http.StatusNotFound, "not_found", "route not found")
	}
}

func (h *handler) handleCommandStatus(w http.ResponseWriter, r *http.Request, sessionID, commandID string) {
	if r.Method != http.MethodGet {
		writeMethodNotAllowed(w, http.MethodGet)
		return
	}
	command, err := h.store.getCommand(r.Context(), sessionID, commandID)
	if err != nil {
		writeStoreError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, command)
}

func (h *handler) handleLeaseAcquire(w http.ResponseWriter, r *http.Request, sessionID string) {
	if r.Method != http.MethodPost {
		writeMethodNotAllowed(w, http.MethodPost)
		return
	}
	var input struct {
		ClientID string `json:"client_id"`
	}
	if _, err := decodeStrictJSON(r, &input); err != nil || input.ClientID == "" || len(input.ClientID) > 200 {
		writeError(w, http.StatusBadRequest, "invalid_request", "client_id is required")
		return
	}
	lease, err := h.store.acquireLease(r.Context(), sessionID, input.ClientID, h.config.LeaseTTL)
	if err != nil {
		writeStoreError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, lease)
}

func (h *handler) handleLease(w http.ResponseWriter, r *http.Request, sessionID, leaseID string) {
	token := leaseToken(r)
	if token == "" {
		writeError(w, http.StatusUnauthorized, "unauthorized", "a valid lease token is required")
		return
	}
	switch r.Method {
	case http.MethodPut:
		if r.Body != nil {
			var empty struct{}
			if _, err := decodeStrictJSON(r, &empty); err != nil {
				writeError(w, http.StatusBadRequest, "invalid_request", "request body must be an empty JSON object")
				return
			}
		}
		lease, err := h.store.renewLease(r.Context(), sessionID, leaseID, token, h.config.LeaseTTL)
		if err != nil {
			writeStoreError(w, err)
			return
		}
		writeJSON(w, http.StatusOK, lease)
	case http.MethodDelete:
		if err := h.store.releaseLease(r.Context(), sessionID, leaseID, token); err != nil {
			writeStoreError(w, err)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	default:
		writeMethodNotAllowed(w, http.MethodPut+", "+http.MethodDelete)
	}
}

func (h *handler) handleCommand(w http.ResponseWriter, r *http.Request, sessionID string) {
	if r.Method != http.MethodPost {
		writeMethodNotAllowed(w, http.MethodPost)
		return
	}
	key := strings.TrimSpace(r.Header.Get("Idempotency-Key"))
	if key == "" || len(key) > 200 {
		writeError(w, http.StatusBadRequest, "invalid_request", "Idempotency-Key is required")
		return
	}
	token := leaseToken(r)
	var command BrowserCommand
	body, err := decodeStrictJSON(r, &command)
	if err != nil || !validCommand(command) {
		writeError(w, http.StatusBadRequest, "invalid_request", "command type or fields are invalid")
		return
	}
	digest := sha256.Sum256(body)
	queued, created, err := h.store.createCommand(r.Context(), sessionID, token, key, hex.EncodeToString(digest[:]), command)
	if err != nil {
		writeStoreError(w, err)
		return
	}
	status := http.StatusOK
	if created {
		status = http.StatusAccepted
	}
	writeJSON(w, status, queued)
}

func (h *handler) handleStream(w http.ResponseWriter, r *http.Request, sessionID string, principal apiPrincipal) {
	if r.Method != http.MethodPost {
		writeMethodNotAllowed(w, http.MethodPost)
		return
	}
	var input struct {
		ClientID string `json:"client_id"`
	}
	if _, err := decodeStrictJSON(r, &input); err != nil && !errors.Is(err, io.EOF) {
		writeError(w, http.StatusBadRequest, "invalid_request", "stream request is invalid")
		return
	}
	input.ClientID = strings.TrimSpace(input.ClientID)
	if len(input.ClientID) > 200 {
		writeError(w, http.StatusBadRequest, "invalid_request", "client_id is too long")
		return
	}
	if _, err := h.store.getSession(r.Context(), sessionID); err != nil {
		writeStoreError(w, err)
		return
	}
	nativeClientID := ""
	if !principal.isOperator() {
		nativeClientID = principal.id
	}
	stream, err := h.store.createStream(r.Context(), sessionID, input.ClientID, nativeClientID, h.viewerURL, defaultStreamTTL)
	if err != nil {
		writeStoreError(w, err)
		return
	}
	if stream.Capability != "" {
		w.Header().Set("Cache-Control", "no-store")
	}
	writeJSON(w, http.StatusCreated, stream)
}

func (h *handler) handleViewerCapabilityRedemption(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeMethodNotAllowed(w, http.MethodPost)
		return
	}
	capability := bearerToken(r)
	var input struct {
		ClientID string `json:"client_id"`
	}
	if capability == "" || len(capability) > 200 || func() bool { _, err := decodeStrictJSON(r, &input); return err != nil }() || strings.TrimSpace(input.ClientID) == "" {
		writeError(w, http.StatusUnauthorized, "viewer_capability_invalid", "viewer capability is missing or invalid")
		return
	}
	stream, err := h.store.redeemViewerCapability(r.Context(), capability, input.ClientID)
	if err != nil {
		if errors.Is(err, errUnauthorized) {
			writeError(w, http.StatusUnauthorized, "viewer_capability_invalid", "viewer capability is missing or invalid")
		} else {
			writeStoreError(w, err)
		}
		return
	}
	credential, err := h.createViewerCredential(r.Context(), stream)
	if err != nil {
		_ = h.store.releaseViewerCapability(r.Context(), capability)
		writeError(w, http.StatusBadGateway, "viewer_login_failed", "viewer session could not be created")
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, ViewerBootstrap{StreamID: stream.ID, ViewerURL: stream.URL, ViewerCredential: credential, ExpiresAt: stream.ExpiresAt})
}

func (h *handler) createViewerCredential(ctx context.Context, stream StreamConnection) (ViewerCredential, error) {
	loginURL, err := endpointURL(h.viewerHealthURL, "/api/login")
	if err != nil {
		return ViewerCredential{}, err
	}
	payload, err := json.Marshal(map[string]string{
		"username": "ghostlight-" + stream.ID,
		"password": h.config.ViewerPassword,
	})
	if err != nil {
		return ViewerCredential{}, err
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, loginURL, bytes.NewReader(payload))
	if err != nil {
		return ViewerCredential{}, err
	}
	request.Header.Set("Accept", "application/json")
	request.Header.Set("Content-Type", "application/json")
	response, err := h.viewerClient.Do(request)
	if err != nil {
		return ViewerCredential{}, err
	}
	defer response.Body.Close()
	body, err := io.ReadAll(io.LimitReader(response.Body, maxJSONBodyBytes+1))
	if err != nil || len(body) > maxJSONBodyBytes || response.StatusCode < http.StatusOK || response.StatusCode >= http.StatusMultipleChoices {
		return ViewerCredential{}, errors.New("Neko login failed")
	}
	for _, cookie := range response.Cookies() {
		if cookie.Name == "" || cookie.Value == "" {
			continue
		}
		expiresAt := cookie.Expires
		if expiresAt.IsZero() || expiresAt.After(stream.ExpiresAt) {
			expiresAt = stream.ExpiresAt
		}
		path := cookie.Path
		if path == "" {
			path = "/"
		}
		return ViewerCredential{
			Type:      "cookie",
			Name:      cookie.Name,
			Value:     cookie.Value,
			Path:      path,
			Secure:    cookie.Secure,
			HTTPOnly:  cookie.HttpOnly,
			SameSite:  sameSiteName(cookie.SameSite),
			ExpiresAt: expiresAt,
		}, nil
	}
	var login struct {
		Token string `json:"token"`
	}
	if err := json.Unmarshal(body, &login); err == nil && strings.TrimSpace(login.Token) != "" {
		return ViewerCredential{
			Type:      "neko_login",
			Name:      "ghostlight-" + stream.ID,
			Value:     login.Token,
			ExpiresAt: stream.ExpiresAt,
		}, nil
	}
	return ViewerCredential{}, errors.New("Neko login returned no WebKit-compatible session cookie")
}

func endpointURL(base, path string) (string, error) {
	parsed, err := url.Parse(base)
	if err != nil || !parsed.IsAbs() || parsed.Host == "" {
		return "", errors.New("viewer endpoint is invalid")
	}
	parsed.Path = path
	parsed.RawPath = ""
	parsed.RawQuery = ""
	parsed.ForceQuery = false
	parsed.Fragment = ""
	return parsed.String(), nil
}

func sameSiteName(value http.SameSite) string {
	switch value {
	case http.SameSiteLaxMode:
		return "lax"
	case http.SameSiteStrictMode:
		return "strict"
	case http.SameSiteNoneMode:
		return "none"
	default:
		return ""
	}
}

func (h *handler) handleAttachments(w http.ResponseWriter, r *http.Request, sessionID string) {
	switch r.Method {
	case http.MethodGet:
		attachments, err := h.store.listAttachments(r.Context(), sessionID)
		if err != nil {
			writeStoreError(w, err)
			return
		}
		writeJSON(w, http.StatusOK, attachments)
	case http.MethodPost:
		token := leaseToken(r)
		tx, err := h.store.db.BeginTx(r.Context(), nil)
		if err != nil {
			writeStoreError(w, err)
			return
		}
		_, _, leaseErr := h.store.findLeaseByTokenTx(r.Context(), tx, sessionID, token)
		_ = tx.Rollback()
		if leaseErr != nil {
			writeStoreError(w, leaseErr)
			return
		}
		h.uploadAttachment(w, r, sessionID, token)
	default:
		writeMethodNotAllowed(w, http.MethodGet+", "+http.MethodPost)
	}
}

func (h *handler) uploadAttachment(w http.ResponseWriter, r *http.Request, sessionID, leaseToken string) {
	r.Body = http.MaxBytesReader(w, r.Body, maxAttachmentBytes+(1<<20))
	reader, err := r.MultipartReader()
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_request", "multipart form data is required")
		return
	}
	part, err := nextFilePart(reader)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_request", "one file part is required")
		return
	}
	defer part.Close()
	filename, err := validateAttachmentFilename(part.FileName())
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_request", err.Error())
		return
	}
	id, err := randomID(16)
	if err != nil {
		writeStoreError(w, err)
		return
	}
	directory := filepath.Join(h.config.AttachmentDir, sessionID)
	if err := os.MkdirAll(directory, 0o700); err != nil {
		writeStoreError(w, err)
		return
	}
	path := filepath.Join(directory, id)
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		writeStoreError(w, err)
		return
	}
	hasher := sha256.New()
	size, copyErr := io.Copy(io.MultiWriter(file, hasher), io.LimitReader(part, maxAttachmentBytes+1))
	closeErr := file.Close()
	if copyErr != nil || closeErr != nil || size > maxAttachmentBytes {
		_ = os.Remove(path)
		if size > maxAttachmentBytes {
			writeError(w, http.StatusRequestEntityTooLarge, "request_too_large", "attachment exceeds 25 MiB")
			return
		}
		writeStoreError(w, errors.Join(copyErr, closeErr))
		return
	}
	attachment := Attachment{ID: id, SessionID: sessionID, Filename: filename, ContentType: part.Header.Get("Content-Type"), Size: size, Digest: "sha256:" + hex.EncodeToString(hasher.Sum(nil)), CreatedAt: h.now().UTC()}
	if err := h.store.addAttachmentWithLease(r.Context(), attachment, leaseToken); err != nil {
		_ = os.Remove(path)
		writeStoreError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, attachment)
}

func (h *handler) handleAttachmentMetadata(w http.ResponseWriter, r *http.Request, sessionID, attachmentID string) {
	if r.Method != http.MethodGet {
		writeMethodNotAllowed(w, http.MethodGet)
		return
	}
	attachment, err := h.store.getAttachment(r.Context(), sessionID, attachmentID)
	if err != nil {
		writeStoreError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, attachment)
}

func (h *handler) handleBridgeHeartbeat(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeMethodNotAllowed(w, http.MethodPost)
		return
	}
	var heartbeat struct {
		SessionID    string       `json:"session_id"`
		RuntimeState string       `json:"runtime_state"`
		ActiveTabID  string       `json:"active_tab_id"`
		Tabs         []BrowserTab `json:"tabs"`
		Sequence     int64        `json:"sequence"`
		AgentVersion string       `json:"agent_version"`
	}
	if _, err := decodeStrictJSON(r, &heartbeat); err != nil || heartbeat.SessionID == "" || len(heartbeat.Tabs) > 1000 || (heartbeat.RuntimeState != "ready" && heartbeat.RuntimeState != "starting" && heartbeat.RuntimeState != "unavailable") {
		writeError(w, http.StatusBadRequest, "invalid_request", "heartbeat payload is invalid")
		return
	}
	session, err := h.store.heartbeat(r.Context(), heartbeat.SessionID, heartbeat.RuntimeState, heartbeat.ActiveTabID, heartbeat.Tabs)
	if err != nil {
		writeStoreError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, session)
}

func (h *handler) handleBridgeCommands(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeMethodNotAllowed(w, http.MethodGet)
		return
	}
	sessionID := r.URL.Query().Get("session_id")
	after, err := strconv.ParseInt(r.URL.Query().Get("after"), 10, 64)
	if err != nil || after < 0 || sessionID == "" {
		writeError(w, http.StatusBadRequest, "invalid_request", "session_id and non-negative after are required")
		return
	}
	commands, err := h.store.listCommands(r.Context(), sessionID, after, maxBridgeCommands)
	if err != nil {
		writeStoreError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"commands": commands})
}

func (h *handler) handleBridgeCommandAck(w http.ResponseWriter, r *http.Request, commandID string) {
	if r.Method != http.MethodPost {
		writeMethodNotAllowed(w, http.MethodPost)
		return
	}
	var acknowledgment struct {
		Status    string          `json:"status"`
		ErrorCode string          `json:"error_code"`
		Error     string          `json:"error"`
		Result    json.RawMessage `json:"result"`
	}
	if _, err := decodeStrictJSON(r, &acknowledgment); err != nil || (acknowledgment.Status != "ok" && acknowledgment.Status != "failed") || (acknowledgment.Status == "failed" && acknowledgment.Error == "") || len(acknowledgment.Error) > 2000 || (len(acknowledgment.Result) != 0 && !json.Valid(acknowledgment.Result)) {
		writeError(w, http.StatusBadRequest, "invalid_request", "acknowledgment status and result are invalid")
		return
	}
	state := "applied"
	if acknowledgment.Status == "failed" {
		state = "failed"
		if acknowledgment.ErrorCode == "" {
			acknowledgment.ErrorCode = "browser_command_failed"
		}
	}
	if len(acknowledgment.ErrorCode) > 100 {
		writeError(w, http.StatusBadRequest, "invalid_request", "error_code is too long")
		return
	}
	command, err := h.store.ackCommand(r.Context(), commandID, state, acknowledgment.ErrorCode, acknowledgment.Error, acknowledgment.Result)
	if err != nil {
		writeStoreError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, command)
}

func (h *handler) handleBridgeAttachment(w http.ResponseWriter, r *http.Request, attachmentID string) {
	if r.Method != http.MethodGet {
		writeMethodNotAllowed(w, http.MethodGet)
		return
	}
	attachment, err := h.store.getAttachment(r.Context(), "", attachmentID)
	if err != nil {
		writeStoreError(w, err)
		return
	}
	file, err := os.Open(h.store.attachmentPath(attachment))
	if err != nil {
		writeStoreError(w, err)
		return
	}
	defer file.Close()
	w.Header().Set("Content-Type", attachment.ContentType)
	w.Header().Set("Content-Length", strconv.FormatInt(attachment.Size, 10))
	w.Header().Set("X-Ghostlight-Filename", attachment.Filename)
	w.Header().Set("X-Ghostlight-SHA256", strings.TrimPrefix(attachment.Digest, "sha256:"))
	w.Header().Set("Content-Disposition", fmt.Sprintf("attachment; filename=%q", attachment.Filename))
	w.WriteHeader(http.StatusOK)
	_, _ = io.Copy(w, file)
}

func authorized(r *http.Request, expected string) bool {
	actual := bearerToken(r)
	return expected != "" && len(actual) == len(expected) && subtle.ConstantTimeCompare([]byte(actual), []byte(expected)) == 1
}

func bearerToken(r *http.Request) string {
	value := r.Header.Get("Authorization")
	if !strings.HasPrefix(value, "Bearer ") {
		return ""
	}
	return strings.TrimPrefix(value, "Bearer ")
}

func leaseToken(r *http.Request) string {
	return strings.TrimSpace(r.Header.Get("X-Ghostlight-Lease-Token"))
}

func splitPath(path string) []string {
	trimmed := strings.Trim(path, "/")
	if trimmed == "" {
		return nil
	}
	return strings.Split(trimmed, "/")
}

func decodeStrictJSON(r *http.Request, target any) ([]byte, error) {
	if r.Body == nil {
		return nil, io.EOF
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, maxJSONBodyBytes+1))
	if err != nil || len(body) > maxJSONBodyBytes {
		return nil, errors.New("request body exceeds size limit")
	}
	decoder := json.NewDecoder(bytes.NewReader(body))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		return nil, err
	}
	if decoder.Decode(&struct{}{}) != io.EOF {
		return nil, errors.New("request body contains trailing JSON")
	}
	return body, nil
}

func validCommand(command BrowserCommand) bool {
	if command.ExpectedRevision < 1 || command.ContinuityVerb != "" || command.ContinuityAdapter != "" || command.ContinuityExpiry != nil {
		return false
	}
	switch command.Type {
	case "navigate":
		return validNavigationURL(command.URL)
	case "create_tab":
		return validNavigationURL(command.URL)
	case "activate_tab", "close_tab", "back", "forward", "reload":
		return command.TabID != ""
	case "stage_attachment":
		return command.AttachmentID != ""
	default:
		return false
	}
}

func validNavigationURL(raw string) bool {
	parsed, err := url.Parse(raw)
	return err == nil && parsed.IsAbs() && parsed.Hostname() != "" && parsed.User == nil && parsed.Fragment == "" && (parsed.Scheme == "http" || parsed.Scheme == "https")
}

func validRecentURL(raw string) bool {
	if !validNavigationURL(raw) {
		return false
	}
	parsed, err := url.Parse(raw)
	if err != nil {
		return false
	}
	for key := range parsed.Query() {
		normalized := strings.Map(func(character rune) rune {
			if character >= 'A' && character <= 'Z' {
				return character + ('a' - 'A')
			}
			if character >= 'a' && character <= 'z' || character >= '0' && character <= '9' {
				return character
			}
			return -1
		}, key)
		if credentialBearingURLQueryKeys[normalized] || strings.HasSuffix(normalized, "token") || strings.HasSuffix(normalized, "password") {
			return false
		}
	}
	return true
}

func validateAttachmentFilename(value string) (string, error) {
	if value == "" || value == "." || value == ".." || filepath.Base(value) != value || strings.ContainsAny(value, `/\`) || !utf8.ValidString(value) || len(value) > 180 {
		return "", errors.New("attachment filename must be one safe path component")
	}
	for _, character := range value {
		if character < 0x20 || character == 0x7f {
			return "", errors.New("attachment filename contains a control character")
		}
	}
	return value, nil
}

func nextFilePart(reader *multipart.Reader) (*multipart.Part, error) {
	for {
		part, err := reader.NextPart()
		if err != nil {
			return nil, err
		}
		if part.FormName() == "file" && part.FileName() != "" {
			return part, nil
		}
		_ = part.Close()
	}
}

func writeStoreError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, errNotFound):
		writeError(w, http.StatusNotFound, "not_found", "resource was not found")
	case errors.Is(err, errConflict):
		writeError(w, http.StatusConflict, "lease_held", "another client holds the controller lease")
	case errors.Is(err, errStaleRevision):
		writeError(w, http.StatusConflict, "stale_revision", "session revision changed")
	case errors.Is(err, errIdempotencyKey):
		writeError(w, http.StatusConflict, "idempotency_conflict", "Idempotency-Key was reused with another request")
	case errors.Is(err, errUnauthorized), errors.Is(err, errLeaseExpired):
		writeError(w, http.StatusUnauthorized, "lease_invalid", "controller lease is missing, expired, or invalid")
	case errors.Is(err, errCapabilityExpired):
		writeError(w, http.StatusUnauthorized, "viewer_capability_expired", "viewer capability expired")
	case errors.Is(err, errCapabilityUsed):
		writeError(w, http.StatusConflict, "viewer_capability_used", "viewer capability was already redeemed")
	case errors.Is(err, errStorageLimit):
		writeError(w, http.StatusInsufficientStorage, "attachment_limit", "session attachment storage limit was reached")
	default:
		writeError(w, http.StatusInternalServerError, "internal_error", "request could not be completed")
	}
}
