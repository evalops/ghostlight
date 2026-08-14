package main

import (
	"errors"
	"net/http"
	"strings"
	"unicode/utf8"
)

func (h *handler) handleNativeClientEnrollments(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeMethodNotAllowed(w, http.MethodPost)
		return
	}
	var input struct {
		ClientName string `json:"client_name"`
	}
	if _, err := decodeStrictJSON(r, &input); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_request", "client_name is required")
		return
	}
	input.ClientName = strings.TrimSpace(input.ClientName)
	if input.ClientName == "" || utf8.RuneCountInString(input.ClientName) > maxNativeClientName {
		writeError(w, http.StatusBadRequest, "invalid_request", "client_name is required and must be at most 100 characters")
		return
	}
	enrollment, err := h.store.createNativeClientEnrollment(r.Context(), input.ClientName)
	if err != nil {
		writeStoreError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, enrollment)
}

func (h *handler) handleNativeClientEnrollmentRedemption(w http.ResponseWriter, r *http.Request) {
	if h.store == nil {
		writeError(w, http.StatusNotFound, "not_found", "route not found")
		return
	}
	if r.Method != http.MethodPost {
		writeMethodNotAllowed(w, http.MethodPost)
		return
	}
	capability := bearerToken(r)
	var input struct {
		ClientName string `json:"client_name"`
	}
	if _, err := decodeStrictJSON(r, &input); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_request", "enrollment request is invalid")
		return
	}
	input.ClientName = strings.TrimSpace(input.ClientName)
	if input.ClientName == "" || utf8.RuneCountInString(input.ClientName) > maxNativeClientName {
		writeError(w, http.StatusBadRequest, "invalid_request", "enrollment request is invalid")
		return
	}
	if len(capability) < 40 {
		writeError(w, http.StatusUnauthorized, "enrollment_invalid", "native client enrollment is invalid")
		return
	}
	credential, err := h.store.redeemNativeClientEnrollment(r.Context(), capability, input.ClientName)
	if err != nil {
		switch {
		case errors.Is(err, errEnrollmentExpired):
			writeError(w, http.StatusUnauthorized, "enrollment_expired", "native client enrollment expired")
		case errors.Is(err, errEnrollmentUsed):
			writeError(w, http.StatusConflict, "enrollment_used", "native client enrollment was already redeemed")
		case errors.Is(err, errUnauthorized):
			writeError(w, http.StatusUnauthorized, "enrollment_invalid", "native client enrollment is invalid")
		case errors.Is(err, errConflict):
			writeError(w, http.StatusConflict, "client_exists", "an active native client already uses this name")
		default:
			writeStoreError(w, err)
		}
		return
	}
	writeJSON(w, http.StatusCreated, credential)
}

func (h *handler) handleNativeClients(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeMethodNotAllowed(w, http.MethodGet)
		return
	}
	clients, err := h.store.listNativeClients(r.Context())
	if err != nil {
		writeStoreError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, clients)
}

func (h *handler) handleNativeClient(w http.ResponseWriter, r *http.Request, clientID string) {
	if r.Method != http.MethodDelete {
		writeMethodNotAllowed(w, http.MethodDelete)
		return
	}
	if err := h.store.revokeNativeClient(r.Context(), clientID); err != nil {
		writeStoreError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
