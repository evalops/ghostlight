package main

import (
	"context"
	"crypto/subtle"
	"database/sql"
	"errors"
	"strings"
	"time"
)

const (
	chromePairingTTL      = 10 * time.Minute
	chromeDeviceScope     = "handoff:write"
	maxPendingHandoffs    = 100
	maxChromeDeviceName   = 100
	maxChromeHandoffTitle = 300
)

func (s *sqliteStore) createChromePairing(ctx context.Context, workspaceID, deviceName string) (ChromePairing, error) {
	var exists int
	if err := s.db.QueryRowContext(ctx, `SELECT 1 FROM workspaces WHERE id=?`, workspaceID).Scan(&exists); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return ChromePairing{}, errNotFound
		}
		return ChromePairing{}, err
	}
	code, err := randomID(32)
	if err != nil {
		return ChromePairing{}, err
	}
	now := s.now().UTC()
	expires := now.Add(chromePairingTTL)
	_, err = s.db.ExecContext(ctx, `INSERT INTO chrome_pairings(token_hash,workspace_id,device_name,expires_at,created_at) VALUES(?,?,?,?,?)`, hashSecret(code), workspaceID, deviceName, formatTime(expires), formatTime(now))
	if err != nil {
		return ChromePairing{}, err
	}
	return ChromePairing{PairingCode: code, WorkspaceID: workspaceID, DeviceName: deviceName, ExpiresAt: expires}, nil
}

func (s *sqliteStore) redeemChromePairing(ctx context.Context, code, deviceID, deviceName string) (ChromeDeviceCredential, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return ChromeDeviceCredential{}, err
	}
	defer tx.Rollback()
	var workspaceID, expectedName, expiry string
	var redeemed sql.NullString
	err = tx.QueryRowContext(ctx, `SELECT workspace_id,device_name,expires_at,redeemed_at FROM chrome_pairings WHERE token_hash=?`, hashSecret(code)).Scan(&workspaceID, &expectedName, &expiry, &redeemed)
	if errors.Is(err, sql.ErrNoRows) {
		return ChromeDeviceCredential{}, errUnauthorized
	}
	if err != nil {
		return ChromeDeviceCredential{}, err
	}
	if redeemed.Valid {
		return ChromeDeviceCredential{}, errPairingUsed
	}
	expires, _ := parseTime(expiry)
	now := s.now().UTC()
	if !now.Before(expires) {
		return ChromeDeviceCredential{}, errPairingExpired
	}
	if expectedName != "" && subtle.ConstantTimeCompare([]byte(expectedName), []byte(deviceName)) != 1 {
		return ChromeDeviceCredential{}, errUnauthorized
	}
	token, err := randomID(32)
	if err != nil {
		return ChromeDeviceCredential{}, err
	}
	result, err := tx.ExecContext(ctx, `UPDATE chrome_pairings SET redeemed_at=? WHERE token_hash=? AND redeemed_at IS NULL`, formatTime(now), hashSecret(code))
	if err != nil {
		return ChromeDeviceCredential{}, err
	}
	if rows, _ := result.RowsAffected(); rows != 1 {
		return ChromeDeviceCredential{}, errPairingUsed
	}
	_, err = tx.ExecContext(ctx, `INSERT INTO chrome_devices(id,workspace_id,name,scope,token_hash,created_at,last_seen_at) VALUES(?,?,?,?,?,?,?)`, deviceID, workspaceID, deviceName, chromeDeviceScope, hashSecret(token), formatTime(now), formatTime(now))
	if err != nil {
		if strings.Contains(err.Error(), "UNIQUE") {
			return ChromeDeviceCredential{}, errConflict
		}
		return ChromeDeviceCredential{}, err
	}
	if err := tx.Commit(); err != nil {
		return ChromeDeviceCredential{}, err
	}
	device := ChromeDevice{ID: deviceID, WorkspaceID: workspaceID, Name: deviceName, Scope: chromeDeviceScope, CreatedAt: now, LastSeenAt: now}
	return ChromeDeviceCredential{Device: device, DeviceToken: token}, nil
}

func (s *sqliteStore) chromeDeviceForToken(ctx context.Context, token string) (ChromeDevice, error) {
	var value ChromeDevice
	var created, seen string
	var revoked sql.NullString
	err := s.db.QueryRowContext(ctx, `SELECT id,workspace_id,name,scope,created_at,last_seen_at,revoked_at FROM chrome_devices WHERE token_hash=?`, hashSecret(token)).Scan(&value.ID, &value.WorkspaceID, &value.Name, &value.Scope, &created, &seen, &revoked)
	if errors.Is(err, sql.ErrNoRows) {
		return ChromeDevice{}, errUnauthorized
	}
	if err != nil {
		return ChromeDevice{}, err
	}
	value.CreatedAt, _ = parseTime(created)
	value.LastSeenAt, _ = parseTime(seen)
	if revoked.Valid {
		stamp, _ := parseTime(revoked.String)
		value.RevokedAt = &stamp
		return ChromeDevice{}, errDeviceRevoked
	}
	return value, nil
}

func (s *sqliteStore) listChromeDevices(ctx context.Context, workspaceID string) ([]ChromeDevice, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT id,workspace_id,name,scope,created_at,last_seen_at,revoked_at FROM chrome_devices WHERE workspace_id=? ORDER BY created_at,id`, workspaceID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	values := []ChromeDevice{}
	for rows.Next() {
		var value ChromeDevice
		var created, seen string
		var revoked sql.NullString
		if err := rows.Scan(&value.ID, &value.WorkspaceID, &value.Name, &value.Scope, &created, &seen, &revoked); err != nil {
			return nil, err
		}
		value.CreatedAt, _ = parseTime(created)
		value.LastSeenAt, _ = parseTime(seen)
		if revoked.Valid {
			stamp, _ := parseTime(revoked.String)
			value.RevokedAt = &stamp
		}
		values = append(values, value)
	}
	return values, rows.Err()
}

func (s *sqliteStore) revokeChromeDevice(ctx context.Context, workspaceID, deviceID string) error {
	now := formatTime(s.now().UTC())
	result, err := s.db.ExecContext(ctx, `UPDATE chrome_devices SET revoked_at=? WHERE id=? AND workspace_id=? AND revoked_at IS NULL`, now, deviceID, workspaceID)
	if err != nil {
		return err
	}
	if rows, _ := result.RowsAffected(); rows != 1 {
		return errNotFound
	}
	return nil
}

func (s *sqliteStore) createChromeHandoff(ctx context.Context, device ChromeDevice, idempotencyKey, requestHash, title, targetURL string) (ChromeHandoff, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return ChromeHandoff{}, err
	}
	defer tx.Rollback()
	var existingID, existingHash string
	err = tx.QueryRowContext(ctx, `SELECT id,request_hash FROM chrome_handoffs WHERE device_id=? AND idempotency_key=?`, device.ID, idempotencyKey).Scan(&existingID, &existingHash)
	if err == nil {
		if subtle.ConstantTimeCompare([]byte(existingHash), []byte(requestHash)) != 1 {
			return ChromeHandoff{}, errIdempotencyKey
		}
		return s.chromeHandoffByIDTx(ctx, tx, existingID)
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return ChromeHandoff{}, err
	}
	var pending int
	if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM chrome_handoffs WHERE workspace_id=? AND state='pending'`, device.WorkspaceID).Scan(&pending); err != nil {
		return ChromeHandoff{}, err
	}
	if pending >= maxPendingHandoffs {
		return ChromeHandoff{}, errStorageLimit
	}
	id, err := randomID(16)
	if err != nil {
		return ChromeHandoff{}, err
	}
	now := s.now().UTC()
	_, err = tx.ExecContext(ctx, `INSERT INTO chrome_handoffs(id,workspace_id,device_id,idempotency_key,request_hash,title,url,state,created_at,updated_at) VALUES(?,?,?,?,?,?,?,'pending',?,?)`, id, device.WorkspaceID, device.ID, idempotencyKey, requestHash, title, targetURL, formatTime(now), formatTime(now))
	if err != nil {
		return ChromeHandoff{}, err
	}
	if _, err := tx.ExecContext(ctx, `UPDATE chrome_devices SET last_seen_at=? WHERE id=? AND revoked_at IS NULL`, formatTime(now), device.ID); err != nil {
		return ChromeHandoff{}, err
	}
	if err := tx.Commit(); err != nil {
		return ChromeHandoff{}, err
	}
	return ChromeHandoff{ID: id, WorkspaceID: device.WorkspaceID, DeviceID: device.ID, DeviceName: device.Name, Title: title, URL: targetURL, State: "pending", CreatedAt: now, UpdatedAt: now}, nil
}

func (s *sqliteStore) chromeHandoffByIDTx(ctx context.Context, tx *sql.Tx, id string) (ChromeHandoff, error) {
	var value ChromeHandoff
	var created, updated string
	err := tx.QueryRowContext(ctx, `SELECT h.id,h.workspace_id,h.device_id,d.name,h.title,h.url,h.state,h.created_at,h.updated_at FROM chrome_handoffs h JOIN chrome_devices d ON d.id=h.device_id WHERE h.id=?`, id).Scan(&value.ID, &value.WorkspaceID, &value.DeviceID, &value.DeviceName, &value.Title, &value.URL, &value.State, &created, &updated)
	if errors.Is(err, sql.ErrNoRows) {
		return ChromeHandoff{}, errNotFound
	}
	if err != nil {
		return ChromeHandoff{}, err
	}
	value.CreatedAt, _ = parseTime(created)
	value.UpdatedAt, _ = parseTime(updated)
	return value, nil
}

func (s *sqliteStore) listChromeHandoffs(ctx context.Context, workspaceID string) ([]ChromeHandoff, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT h.id,h.workspace_id,h.device_id,d.name,h.title,h.url,h.state,h.created_at,h.updated_at FROM chrome_handoffs h JOIN chrome_devices d ON d.id=h.device_id WHERE h.workspace_id=? AND h.state='pending' ORDER BY h.created_at DESC,h.id DESC`, workspaceID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	values := []ChromeHandoff{}
	for rows.Next() {
		var value ChromeHandoff
		var created, updated string
		if err := rows.Scan(&value.ID, &value.WorkspaceID, &value.DeviceID, &value.DeviceName, &value.Title, &value.URL, &value.State, &created, &updated); err != nil {
			return nil, err
		}
		value.CreatedAt, _ = parseTime(created)
		value.UpdatedAt, _ = parseTime(updated)
		values = append(values, value)
	}
	return values, rows.Err()
}

func (s *sqliteStore) updateChromeHandoff(ctx context.Context, workspaceID, id, state string) (ChromeHandoff, error) {
	now := s.now().UTC()
	result, err := s.db.ExecContext(ctx, `UPDATE chrome_handoffs SET state=?,updated_at=? WHERE id=? AND workspace_id=? AND state='pending'`, state, formatTime(now), id, workspaceID)
	if err != nil {
		return ChromeHandoff{}, err
	}
	if rows, _ := result.RowsAffected(); rows != 1 {
		return ChromeHandoff{}, errConflict
	}
	var value ChromeHandoff
	var created, updated string
	err = s.db.QueryRowContext(ctx, `SELECT h.id,h.workspace_id,h.device_id,d.name,h.title,h.url,h.state,h.created_at,h.updated_at FROM chrome_handoffs h JOIN chrome_devices d ON d.id=h.device_id WHERE h.id=?`, id).Scan(&value.ID, &value.WorkspaceID, &value.DeviceID, &value.DeviceName, &value.Title, &value.URL, &value.State, &created, &updated)
	if err != nil {
		return ChromeHandoff{}, err
	}
	value.CreatedAt, _ = parseTime(created)
	value.UpdatedAt, _ = parseTime(updated)
	return value, nil
}
