package main

import (
	"context"
	"crypto/subtle"
	"database/sql"
	"errors"
	"time"
)

const (
	maxPeripheralAuditEvents       = 200
	maxStoredPeripheralAuditEvents = 1000
)

func scanPeripheralGrant(row interface{ Scan(...any) error }) (PeripheralGrant, error) {
	var value PeripheralGrant
	var expiresAt, createdAt string
	var revokedAt sql.NullString
	err := row.Scan(&value.ID, &value.WorkspaceID, &value.SessionID, &value.ClientID, &value.Capability, &value.Direction, &value.Origin, &expiresAt, &createdAt, &revokedAt)
	if err != nil {
		return PeripheralGrant{}, err
	}
	value.ExpiresAt, _ = parseTime(expiresAt)
	value.CreatedAt, _ = parseTime(createdAt)
	if revokedAt.Valid {
		parsed, _ := parseTime(revokedAt.String)
		value.RevokedAt = &parsed
		value.State = "revoked"
	} else {
		value.State = "active"
	}
	return value, nil
}

const peripheralGrantSelect = `SELECT id,workspace_id,session_id,client_id,capability,direction,origin,expires_at,created_at,revoked_at FROM peripheral_grants`

func (s *sqliteStore) createPeripheralGrant(ctx context.Context, workspaceID, sessionID, clientID, leaseToken, idempotencyKey, requestHash, capability, direction, origin string, expiresAt time.Time) (PeripheralGrant, bool, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return PeripheralGrant{}, false, err
	}
	defer tx.Rollback()
	var actualWorkspace, storedHash, existingID string
	if err = tx.QueryRowContext(ctx, `SELECT workspace_id FROM sessions WHERE id=?`, sessionID).Scan(&actualWorkspace); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return PeripheralGrant{}, false, errNotFound
		}
		return PeripheralGrant{}, false, err
	}
	if actualWorkspace != workspaceID {
		return PeripheralGrant{}, false, errNotFound
	}
	if _, _, err = s.findLeaseByTokenTx(ctx, tx, sessionID, leaseToken); err != nil {
		return PeripheralGrant{}, false, err
	}
	err = tx.QueryRowContext(ctx, `SELECT request_hash,id FROM peripheral_grants WHERE client_id=? AND idempotency_key=?`, clientID, idempotencyKey).Scan(&storedHash, &existingID)
	if err == nil {
		if subtle.ConstantTimeCompare([]byte(storedHash), []byte(requestHash)) != 1 {
			return PeripheralGrant{}, false, errIdempotencyKey
		}
		value, scanErr := scanPeripheralGrant(tx.QueryRowContext(ctx, peripheralGrantSelect+` WHERE id=?`, existingID))
		if scanErr == nil && value.RevokedAt == nil && !value.ExpiresAt.After(s.now()) {
			value.State = "expired"
		}
		return value, false, scanErr
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return PeripheralGrant{}, false, err
	}
	id, err := randomID(16)
	if err != nil {
		return PeripheralGrant{}, false, err
	}
	now := s.now().UTC()
	if _, err = tx.ExecContext(ctx, `INSERT INTO peripheral_grants(id,workspace_id,session_id,client_id,idempotency_key,request_hash,capability,direction,origin,expires_at,created_at) VALUES(?,?,?,?,?,?,?,?,?,?,?)`, id, workspaceID, sessionID, clientID, idempotencyKey, requestHash, capability, direction, origin, formatTime(expiresAt), formatTime(now)); err != nil {
		return PeripheralGrant{}, false, err
	}
	if err = insertPeripheralAudit(ctx, tx, id, workspaceID, sessionID, clientID, capability, direction, origin, "granted", "allowed", now); err != nil {
		return PeripheralGrant{}, false, err
	}
	if err = tx.Commit(); err != nil {
		return PeripheralGrant{}, false, err
	}
	return PeripheralGrant{ID: id, WorkspaceID: workspaceID, SessionID: sessionID, ClientID: clientID, Capability: capability, Direction: direction, Origin: origin, State: "active", ExpiresAt: expiresAt, CreatedAt: now}, true, nil
}

func (s *sqliteStore) listPeripheralGrants(ctx context.Context, workspaceID, clientID string) ([]PeripheralGrant, error) {
	query := peripheralGrantSelect + ` WHERE workspace_id=? AND client_id=?`
	args := []any{workspaceID, clientID}
	query += ` ORDER BY created_at DESC,id DESC`
	rows, err := s.db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	values := []PeripheralGrant{}
	for rows.Next() {
		value, err := scanPeripheralGrant(rows)
		if err != nil {
			return nil, err
		}
		if !value.ExpiresAt.After(s.now()) && value.RevokedAt == nil {
			value.State = "expired"
		}
		values = append(values, value)
	}
	return values, rows.Err()
}

func (s *sqliteStore) revokePeripheralGrant(ctx context.Context, workspaceID, grantID, clientID string) (PeripheralGrant, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return PeripheralGrant{}, err
	}
	defer tx.Rollback()
	value, err := scanPeripheralGrant(tx.QueryRowContext(ctx, peripheralGrantSelect+` WHERE id=? AND workspace_id=?`, grantID, workspaceID))
	if errors.Is(err, sql.ErrNoRows) {
		return PeripheralGrant{}, errNotFound
	}
	if err != nil {
		return PeripheralGrant{}, err
	}
	if subtle.ConstantTimeCompare([]byte(value.ClientID), []byte(clientID)) != 1 {
		return PeripheralGrant{}, errNotFound
	}
	if value.RevokedAt == nil {
		now := s.now().UTC()
		if _, err = tx.ExecContext(ctx, `UPDATE peripheral_grants SET revoked_at=? WHERE id=?`, formatTime(now), grantID); err != nil {
			return PeripheralGrant{}, err
		}
		if err = insertPeripheralAudit(ctx, tx, grantID, value.WorkspaceID, value.SessionID, value.ClientID, value.Capability, value.Direction, value.Origin, "revoked", "allowed", now); err != nil {
			return PeripheralGrant{}, err
		}
		value.RevokedAt = &now
		value.State = "revoked"
	}
	if err = tx.Commit(); err != nil {
		return PeripheralGrant{}, err
	}
	return value, nil
}

func insertPeripheralAudit(ctx context.Context, tx *sql.Tx, grantID, workspaceID, sessionID, clientID, capability, direction, origin, action, outcome string, now time.Time) error {
	id, err := randomID(16)
	if err != nil {
		return err
	}
	var grantReference any
	if grantID != "" {
		grantReference = grantID
	}
	_, err = tx.ExecContext(ctx, `INSERT INTO peripheral_audit_events(id,grant_id,workspace_id,session_id,client_id,capability,direction,origin,action,outcome,occurred_at) VALUES(?,?,?,?,?,?,?,?,?,?,?)`, id, grantReference, workspaceID, sessionID, clientID, capability, direction, origin, action, outcome, formatTime(now))
	if err == nil {
		_, err = tx.ExecContext(ctx, `DELETE FROM peripheral_audit_events WHERE id IN (SELECT id FROM peripheral_audit_events WHERE workspace_id=? AND client_id=? ORDER BY occurred_at DESC,id DESC LIMIT -1 OFFSET ?)`, workspaceID, clientID, maxStoredPeripheralAuditEvents)
	}
	return err
}

func (s *sqliteStore) authorizePeripheral(ctx context.Context, workspaceID, sessionID, clientID, capability, direction, origin string) (PeripheralAuthorization, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return PeripheralAuthorization{}, err
	}
	defer tx.Rollback()
	now := s.now().UTC()
	var actualWorkspace string
	if err = tx.QueryRowContext(ctx, `SELECT workspace_id FROM sessions WHERE id=?`, sessionID).Scan(&actualWorkspace); errors.Is(err, sql.ErrNoRows) {
		return PeripheralAuthorization{}, errNotFound
	} else if err != nil {
		return PeripheralAuthorization{}, err
	} else if actualWorkspace != workspaceID {
		return PeripheralAuthorization{}, errNotFound
	}
	query := peripheralGrantSelect + ` WHERE workspace_id=? AND session_id=? AND capability=? AND direction=? AND origin=? AND revoked_at IS NULL AND expires_at>?`
	args := []any{workspaceID, sessionID, capability, direction, origin, formatTime(now)}
	query += ` AND client_id=?`
	args = append(args, clientID)
	query += ` ORDER BY expires_at DESC LIMIT 1`
	grant, scanErr := scanPeripheralGrant(tx.QueryRowContext(ctx, query, args...))
	outcome, grantID, expiry := "denied", "", time.Time{}
	if scanErr == nil {
		outcome, grantID, expiry = "allowed", grant.ID, grant.ExpiresAt
	} else if !errors.Is(scanErr, sql.ErrNoRows) {
		return PeripheralAuthorization{}, scanErr
	}
	if err = insertPeripheralAudit(ctx, tx, grantID, workspaceID, sessionID, clientID, capability, direction, origin, "used", outcome, now); err != nil {
		return PeripheralAuthorization{}, err
	}
	if err = tx.Commit(); err != nil {
		return PeripheralAuthorization{}, err
	}
	return PeripheralAuthorization{Allowed: outcome == "allowed", GrantID: grantID, ExpiresAt: expiry}, nil
}

func (s *sqliteStore) listPeripheralAudit(ctx context.Context, workspaceID, clientID string) ([]PeripheralAuditEvent, error) {
	query := `SELECT id,COALESCE(grant_id,''),workspace_id,session_id,client_id,capability,direction,origin,action,outcome,occurred_at FROM peripheral_audit_events WHERE workspace_id=? AND client_id=?`
	args := []any{workspaceID, clientID}
	query += ` ORDER BY occurred_at DESC,id DESC LIMIT ?`
	args = append(args, maxPeripheralAuditEvents)
	rows, err := s.db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	values := []PeripheralAuditEvent{}
	for rows.Next() {
		var value PeripheralAuditEvent
		var occurred string
		if err := rows.Scan(&value.ID, &value.GrantID, &value.WorkspaceID, &value.SessionID, &value.ClientID, &value.Capability, &value.Direction, &value.Origin, &value.Action, &value.Outcome, &occurred); err != nil {
			return nil, err
		}
		value.OccurredAt, _ = parseTime(occurred)
		values = append(values, value)
	}
	return values, rows.Err()
}
