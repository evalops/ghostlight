package main

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"net/http"
	"strings"
	"unicode/utf8"
)

func (h *handler) handleChromePairings(w http.ResponseWriter, r *http.Request, workspaceID string) {
	if r.Method != http.MethodPost {
		writeMethodNotAllowed(w, http.MethodPost)
		return
	}
	var input struct {
		DeviceName string `json:"device_name"`
	}
	if _, err := decodeStrictJSON(r, &input); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_request", "device_name is required")
		return
	}
	input.DeviceName = strings.TrimSpace(input.DeviceName)
	if input.DeviceName == "" || utf8.RuneCountInString(input.DeviceName) > maxChromeDeviceName {
		writeError(w, http.StatusBadRequest, "invalid_request", "device_name is required and must be at most 100 characters")
		return
	}
	pairing, err := h.store.createChromePairing(r.Context(), workspaceID, input.DeviceName)
	if err != nil {
		writeStoreError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, pairing)
}

func (h *handler) handleChromePairingRedemption(w http.ResponseWriter, r *http.Request) {
	if h.store == nil {
		writeError(w, http.StatusNotFound, "not_found", "route not found")
		return
	}
	if r.Method != http.MethodPost {
		writeMethodNotAllowed(w, http.MethodPost)
		return
	}
	var input struct {
		PairingCode string `json:"pairing_code"`
		DeviceID    string `json:"device_id"`
		DeviceName  string `json:"device_name"`
	}
	if _, err := decodeStrictJSON(r, &input); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_request", "pairing request is invalid")
		return
	}
	input.PairingCode = strings.TrimSpace(input.PairingCode)
	input.DeviceID = strings.TrimSpace(input.DeviceID)
	input.DeviceName = strings.TrimSpace(input.DeviceName)
	if len(input.PairingCode) < 40 || len(input.DeviceID) < 16 || len(input.DeviceID) > 100 || input.DeviceName == "" || utf8.RuneCountInString(input.DeviceName) > maxChromeDeviceName {
		writeError(w, http.StatusBadRequest, "invalid_request", "pairing request is invalid")
		return
	}
	credential, err := h.store.redeemChromePairing(r.Context(), input.PairingCode, input.DeviceID, input.DeviceName)
	if err != nil {
		switch {
		case errors.Is(err, errPairingExpired):
			writeError(w, http.StatusUnauthorized, "pairing_expired", "pairing code expired")
		case errors.Is(err, errPairingUsed):
			writeError(w, http.StatusConflict, "pairing_used", "pairing code was already redeemed")
		case errors.Is(err, errUnauthorized):
			writeError(w, http.StatusUnauthorized, "pairing_invalid", "pairing code is invalid")
		case errors.Is(err, errConflict):
			writeError(w, http.StatusConflict, "device_exists", "device identifier is already paired")
		default:
			writeStoreError(w, err)
		}
		return
	}
	writeJSON(w, http.StatusCreated, credential)
}

func (h *handler) handleChromeDeviceHandoffs(w http.ResponseWriter, r *http.Request) {
	if h.store == nil {
		writeError(w, http.StatusNotFound, "not_found", "route not found")
		return
	}
	if r.Method != http.MethodPost {
		writeMethodNotAllowed(w, http.MethodPost)
		return
	}
	device, err := h.store.chromeDeviceForToken(r.Context(), bearerToken(r))
	if err != nil {
		writeError(w, http.StatusUnauthorized, "device_invalid", "Chrome device token is missing, revoked, or invalid")
		return
	}
	if device.Scope != chromeDeviceScope {
		writeError(w, http.StatusForbidden, "scope_denied", "Chrome device is not allowed to create handoffs")
		return
	}
	key := strings.TrimSpace(r.Header.Get("Idempotency-Key"))
	if key == "" || len(key) > 200 {
		writeError(w, http.StatusBadRequest, "invalid_request", "Idempotency-Key is required")
		return
	}
	var input struct {
		Title string `json:"title"`
		URL   string `json:"url"`
	}
	body, err := decodeStrictJSON(r, &input)
	input.Title = strings.TrimSpace(input.Title)
	input.URL = strings.TrimSpace(input.URL)
	if err != nil || utf8.RuneCountInString(input.Title) > maxChromeHandoffTitle || len(input.URL) > 4096 || !validRecentURL(input.URL) {
		writeError(w, http.StatusBadRequest, "unsafe_url", "handoff must contain a safe HTTP or HTTPS URL without credentials, fragments, or credential-bearing query parameters")
		return
	}
	digest := sha256.Sum256(body)
	handoff, err := h.store.createChromeHandoff(r.Context(), device, key, hex.EncodeToString(digest[:]), input.Title, input.URL)
	if err != nil {
		switch {
		case errors.Is(err, errStorageLimit):
			writeError(w, http.StatusInsufficientStorage, "handoff_limit", "pending Chrome handoff limit was reached")
		default:
			writeStoreError(w, err)
		}
		return
	}
	writeJSON(w, http.StatusCreated, handoff)
}

func (h *handler) handleWorkspaceChromeHandoffs(w http.ResponseWriter, r *http.Request, workspaceID, handoffID string) {
	if handoffID == "" {
		if r.Method != http.MethodGet {
			writeMethodNotAllowed(w, http.MethodGet)
			return
		}
		values, err := h.store.listChromeHandoffs(r.Context(), workspaceID)
		if err != nil {
			writeStoreError(w, err)
			return
		}
		writeJSON(w, http.StatusOK, values)
		return
	}
	if r.Method != http.MethodPut {
		writeMethodNotAllowed(w, http.MethodPut)
		return
	}
	var input struct {
		State string `json:"state"`
	}
	if _, err := decodeStrictJSON(r, &input); err != nil || (input.State != "opened" && input.State != "dismissed") {
		writeError(w, http.StatusBadRequest, "invalid_request", "state must be opened or dismissed")
		return
	}
	value, err := h.store.updateChromeHandoff(r.Context(), workspaceID, handoffID, input.State)
	if err != nil {
		if errors.Is(err, errConflict) {
			writeError(w, http.StatusConflict, "handoff_resolved", "handoff is no longer pending")
			return
		}
		writeStoreError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, value)
}

func (h *handler) handleChromeDevices(w http.ResponseWriter, r *http.Request, workspaceID string) {
	if r.Method != http.MethodGet {
		writeMethodNotAllowed(w, http.MethodGet)
		return
	}
	values, err := h.store.listChromeDevices(r.Context(), workspaceID)
	if err != nil {
		writeStoreError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, values)
}

func (h *handler) handleChromeDevice(w http.ResponseWriter, r *http.Request, workspaceID, deviceID string) {
	if r.Method != http.MethodDelete {
		writeMethodNotAllowed(w, http.MethodDelete)
		return
	}
	if err := h.store.revokeChromeDevice(r.Context(), workspaceID, deviceID); err != nil {
		writeStoreError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
