package main

import (
	"context"
	"crypto/subtle"
	"database/sql"
	"errors"
	"net/http"
	"strings"
	"time"
)

const (
	nativeClientEnrollmentTTL = 10 * time.Minute
	nativeClientScope         = "browser:use"
	maxNativeClientName       = 100
)

var (
	errEnrollmentExpired   = errors.New("native client enrollment expired")
	errEnrollmentUsed      = errors.New("native client enrollment already used")
	errNativeClientRevoked = errors.New("native client revoked")
)

type apiPrincipal struct {
	kind  string
	id    string
	name  string
	scope string
}

func (p apiPrincipal) isOperator() bool { return p.kind == "operator" }

func (p apiPrincipal) allows(scope string) bool {
	if p.isOperator() {
		return true
	}
	for _, candidate := range strings.Fields(p.scope) {
		if subtle.ConstantTimeCompare([]byte(candidate), []byte(scope)) == 1 {
			return true
		}
	}
	return false
}

func requireOperatorPrincipal(w http.ResponseWriter, principal apiPrincipal) bool {
	if principal.isOperator() {
		return true
	}
	writeError(w, http.StatusForbidden, "scope_denied", "operator credentials are required")
	return false
}

func requirePrincipalScope(w http.ResponseWriter, principal apiPrincipal, scope string) bool {
	if principal.allows(scope) {
		return true
	}
	writeError(w, http.StatusForbidden, "scope_denied", "client is not allowed to use the native browser API")
	return false
}

func (h *handler) authenticateAPI(r *http.Request) (apiPrincipal, error) {
	token := bearerToken(r)
	if h.config.APIToken != "" && len(token) == len(h.config.APIToken) && subtle.ConstantTimeCompare([]byte(token), []byte(h.config.APIToken)) == 1 {
		return apiPrincipal{kind: "operator", name: "operator"}, nil
	}
	client, err := h.store.nativeClientForToken(r.Context(), token)
	if err != nil {
		if errors.Is(err, errUnauthorized) || errors.Is(err, errNativeClientRevoked) {
			return apiPrincipal{}, errUnauthorized
		}
		return apiPrincipal{}, err
	}
	return apiPrincipal{kind: "native_client", id: client.ID, name: client.Name, scope: client.Scope}, nil
}

func (s *sqliteStore) createNativeClientEnrollment(ctx context.Context, clientName string) (NativeClientEnrollment, error) {
	capability, err := randomID(32)
	if err != nil {
		return NativeClientEnrollment{}, err
	}
	now := s.now().UTC()
	expires := now.Add(nativeClientEnrollmentTTL)
	if _, err := s.db.ExecContext(ctx, `INSERT INTO native_client_enrollments(token_hash,client_name,expires_at,created_at) VALUES(?,?,?,?)`, hashSecret(capability), clientName, formatTime(expires), formatTime(now)); err != nil {
		return NativeClientEnrollment{}, err
	}
	return NativeClientEnrollment{PairingCapability: capability, ClientName: clientName, ExpiresAt: expires}, nil
}

func (s *sqliteStore) redeemNativeClientEnrollment(ctx context.Context, capability, clientName string) (NativeClientCredential, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return NativeClientCredential{}, err
	}
	defer tx.Rollback()
	var expectedName, expiry string
	var redeemed sql.NullString
	if err := tx.QueryRowContext(ctx, `SELECT client_name,expires_at,redeemed_at FROM native_client_enrollments WHERE token_hash=?`, hashSecret(capability)).Scan(&expectedName, &expiry, &redeemed); errors.Is(err, sql.ErrNoRows) {
		return NativeClientCredential{}, errUnauthorized
	} else if err != nil {
		return NativeClientCredential{}, err
	}
	if redeemed.Valid {
		return NativeClientCredential{}, errEnrollmentUsed
	}
	expires, _ := parseTime(expiry)
	now := s.now().UTC()
	if !now.Before(expires) {
		return NativeClientCredential{}, errEnrollmentExpired
	}
	if subtle.ConstantTimeCompare([]byte(expectedName), []byte(clientName)) != 1 {
		return NativeClientCredential{}, errUnauthorized
	}
	token, err := randomID(32)
	if err != nil {
		return NativeClientCredential{}, err
	}
	result, err := tx.ExecContext(ctx, `UPDATE native_client_enrollments SET redeemed_at=? WHERE token_hash=? AND redeemed_at IS NULL`, formatTime(now), hashSecret(capability))
	if err != nil {
		return NativeClientCredential{}, err
	}
	if rows, _ := result.RowsAffected(); rows != 1 {
		return NativeClientCredential{}, errEnrollmentUsed
	}

	clientID, err := randomID(16)
	if err != nil {
		return NativeClientCredential{}, err
	}
	createdAt := now
	_, err = tx.ExecContext(ctx, `INSERT INTO native_clients(id,name,scope,token_hash,created_at,last_seen_at) VALUES(?,?,?,?,?,?)`, clientID, clientName, nativeClientScope, hashSecret(token), formatTime(now), formatTime(now))
	if err != nil {
		if !strings.Contains(err.Error(), "UNIQUE") {
			return NativeClientCredential{}, err
		}
		var existingCreated string
		if err := tx.QueryRowContext(ctx, `SELECT id,created_at FROM native_clients WHERE name=? AND revoked_at IS NOT NULL`, clientName).Scan(&clientID, &existingCreated); errors.Is(err, sql.ErrNoRows) {
			return NativeClientCredential{}, errConflict
		} else if err != nil {
			return NativeClientCredential{}, err
		}
		createdAt, _ = parseTime(existingCreated)
		result, err := tx.ExecContext(ctx, `UPDATE native_clients SET scope=?,token_hash=?,last_seen_at=?,revoked_at=NULL WHERE id=? AND revoked_at IS NOT NULL`, nativeClientScope, hashSecret(token), formatTime(now), clientID)
		if err != nil {
			return NativeClientCredential{}, err
		}
		if rows, _ := result.RowsAffected(); rows != 1 {
			return NativeClientCredential{}, errConflict
		}
	}
	if err := tx.Commit(); err != nil {
		return NativeClientCredential{}, err
	}
	client := NativeClient{ID: clientID, Name: clientName, Scope: nativeClientScope, CreatedAt: createdAt, LastSeenAt: now}
	return NativeClientCredential{Client: client, ClientToken: token}, nil
}

func (s *sqliteStore) nativeClientForToken(ctx context.Context, token string) (NativeClient, error) {
	if token == "" {
		return NativeClient{}, errUnauthorized
	}
	var client NativeClient
	var created, lastSeen string
	var revoked sql.NullString
	err := s.db.QueryRowContext(ctx, `SELECT id,name,scope,created_at,last_seen_at,revoked_at FROM native_clients WHERE token_hash=?`, hashSecret(token)).Scan(&client.ID, &client.Name, &client.Scope, &created, &lastSeen, &revoked)
	if errors.Is(err, sql.ErrNoRows) {
		return NativeClient{}, errUnauthorized
	}
	if err != nil {
		return NativeClient{}, err
	}
	client.CreatedAt, _ = parseTime(created)
	client.LastSeenAt, _ = parseTime(lastSeen)
	if revoked.Valid {
		return NativeClient{}, errNativeClientRevoked
	}
	now := s.now().UTC()
	if _, err := s.db.ExecContext(ctx, `UPDATE native_clients SET last_seen_at=? WHERE id=? AND revoked_at IS NULL`, formatTime(now), client.ID); err != nil {
		return NativeClient{}, err
	}
	client.LastSeenAt = now
	return client, nil
}

func (s *sqliteStore) listNativeClients(ctx context.Context) ([]NativeClient, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT id,name,scope,created_at,last_seen_at,revoked_at FROM native_clients ORDER BY created_at,id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	clients := []NativeClient{}
	for rows.Next() {
		var client NativeClient
		var created, lastSeen string
		var revoked sql.NullString
		if err := rows.Scan(&client.ID, &client.Name, &client.Scope, &created, &lastSeen, &revoked); err != nil {
			return nil, err
		}
		client.CreatedAt, _ = parseTime(created)
		client.LastSeenAt, _ = parseTime(lastSeen)
		if revoked.Valid {
			stamp, _ := parseTime(revoked.String)
			client.RevokedAt = &stamp
		}
		clients = append(clients, client)
	}
	return clients, rows.Err()
}

func (s *sqliteStore) revokeNativeClient(ctx context.Context, clientID string) error {
	result, err := s.db.ExecContext(ctx, `UPDATE native_clients SET revoked_at=? WHERE id=? AND revoked_at IS NULL`, formatTime(s.now().UTC()), clientID)
	if err != nil {
		return err
	}
	if rows, _ := result.RowsAffected(); rows != 1 {
		return errNotFound
	}
	return nil
}
