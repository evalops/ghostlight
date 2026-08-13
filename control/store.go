package main

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	_ "modernc.org/sqlite"
)

const databaseFileName = "ghostlight.db"

var (
	errNotFound          = errors.New("not found")
	errConflict          = errors.New("conflict")
	errUnauthorized      = errors.New("unauthorized")
	errStaleRevision     = errors.New("stale revision")
	errLeaseExpired      = errors.New("lease expired")
	errStorageLimit      = errors.New("storage limit reached")
	errIdempotencyKey    = errors.New("idempotency key reused with different request")
	errCapabilityExpired = errors.New("viewer capability expired")
	errCapabilityUsed    = errors.New("viewer capability already used")
)

type sqliteStore struct {
	db            *sql.DB
	attachmentDir string
	now           func() time.Time
}

func openSQLiteStore(stateDir, attachmentDir string, now func() time.Time) (*sqliteStore, error) {
	if now == nil {
		now = time.Now
	}
	for _, dir := range []string{stateDir, attachmentDir} {
		if dir == "" {
			return nil, errors.New("storage directory must not be empty")
		}
		if err := os.MkdirAll(dir, 0o700); err != nil {
			return nil, fmt.Errorf("create storage directory: %w", err)
		}
		if err := os.Chmod(dir, 0o700); err != nil {
			return nil, fmt.Errorf("secure storage directory: %w", err)
		}
	}
	databasePath := filepath.Join(stateDir, databaseFileName)
	db, err := sql.Open("sqlite", databasePath)
	if err != nil {
		return nil, fmt.Errorf("open state database: %w", err)
	}
	db.SetMaxOpenConns(1)
	db.SetMaxIdleConns(1)
	s := &sqliteStore{db: db, attachmentDir: attachmentDir, now: now}
	if err := s.initialize(context.Background()); err != nil {
		db.Close()
		return nil, err
	}
	for _, path := range []string{databasePath, databasePath + "-wal", databasePath + "-shm"} {
		if err := os.Chmod(path, 0o600); err != nil && !errors.Is(err, os.ErrNotExist) {
			db.Close()
			return nil, fmt.Errorf("secure state database file: %w", err)
		}
	}
	return s, nil
}

func (s *sqliteStore) initialize(ctx context.Context) error {
	var currentVersion int
	if err := s.db.QueryRowContext(ctx, `PRAGMA user_version`).Scan(&currentVersion); err != nil {
		return fmt.Errorf("read state schema version: %w", err)
	}
	if currentVersion < 0 || currentVersion > schemaVersion {
		return fmt.Errorf("unsupported state schema version %d; maximum supported is %d", currentVersion, schemaVersion)
	}
	statements := []string{
		`PRAGMA foreign_keys = ON`,
		`PRAGMA journal_mode = WAL`,
		`PRAGMA busy_timeout = 5000`,
		`CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)`,
		`CREATE TABLE IF NOT EXISTS workspaces (id TEXT PRIMARY KEY, name TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL)`,
		`CREATE TABLE IF NOT EXISTS sessions (id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL REFERENCES workspaces(id), name TEXT NOT NULL, revision INTEGER NOT NULL, runtime_state TEXT NOT NULL, tabs_json TEXT NOT NULL, active_tab_id TEXT NOT NULL, last_heartbeat TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL)`,
		`CREATE TABLE IF NOT EXISTS lease_epochs (session_id TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE, epoch INTEGER NOT NULL)`,
		`CREATE TABLE IF NOT EXISTS leases (id TEXT PRIMARY KEY, session_id TEXT NOT NULL UNIQUE REFERENCES sessions(id) ON DELETE CASCADE, client_id TEXT NOT NULL, token_hash TEXT NOT NULL, epoch INTEGER NOT NULL, expires_at TEXT NOT NULL)`,
		`CREATE TABLE IF NOT EXISTS streams (id TEXT PRIMARY KEY, session_id TEXT NOT NULL UNIQUE REFERENCES sessions(id) ON DELETE CASCADE, url TEXT NOT NULL, state TEXT NOT NULL, expires_at TEXT NOT NULL, created_at TEXT NOT NULL)`,
		`CREATE TABLE IF NOT EXISTS session_idempotency (key TEXT PRIMARY KEY, request_hash TEXT NOT NULL, session_id TEXT NOT NULL REFERENCES sessions(id))`,
		`CREATE TABLE IF NOT EXISTS commands (sequence INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE, session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE, idempotency_key TEXT NOT NULL, request_hash TEXT NOT NULL, type TEXT NOT NULL, url TEXT NOT NULL, tab_id TEXT NOT NULL, attachment_id TEXT NOT NULL, expected_revision INTEGER NOT NULL, lease_epoch INTEGER NOT NULL, state TEXT NOT NULL, error_code TEXT NOT NULL, error TEXT NOT NULL, result_json TEXT NOT NULL, resulting_revision INTEGER, acknowledged_at TEXT, completed_at TEXT, created_at TEXT NOT NULL, UNIQUE(session_id, idempotency_key))`,
		`CREATE TABLE IF NOT EXISTS attachments (id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE, filename TEXT NOT NULL, content_type TEXT NOT NULL, size INTEGER NOT NULL, digest TEXT NOT NULL, created_at TEXT NOT NULL)`,
		`CREATE TABLE IF NOT EXISTS viewer_capabilities (token_hash TEXT PRIMARY KEY, stream_id TEXT NOT NULL, session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE, client_id TEXT NOT NULL, expires_at TEXT NOT NULL, redeemed_at TEXT, created_at TEXT NOT NULL)`,
		`CREATE TABLE IF NOT EXISTS workspace_preferences (workspace_id TEXT PRIMARY KEY REFERENCES workspaces(id) ON DELETE CASCADE, search_url TEXT NOT NULL, shortcuts_json TEXT NOT NULL, recent_urls_json TEXT NOT NULL, updated_at TEXT NOT NULL)`,
	}
	for _, statement := range statements {
		if _, err := s.db.ExecContext(ctx, statement); err != nil {
			return fmt.Errorf("initialize state database: %w", err)
		}
	}
	if currentVersion == 1 {
		for _, statement := range []string{
			`ALTER TABLE commands ADD COLUMN error_code TEXT NOT NULL DEFAULT ''`,
			`ALTER TABLE commands ADD COLUMN resulting_revision INTEGER`,
			`ALTER TABLE commands ADD COLUMN completed_at TEXT`,
			`UPDATE commands SET state=CASE state WHEN 'ok' THEN 'applied' WHEN 'error' THEN 'failed' ELSE state END, completed_at=acknowledged_at`,
		} {
			if _, err := s.db.ExecContext(ctx, statement); err != nil {
				return fmt.Errorf("migrate state database: %w", err)
			}
		}
	}
	if _, err := s.db.ExecContext(ctx, fmt.Sprintf(`PRAGMA user_version = %d`, schemaVersion)); err != nil {
		return fmt.Errorf("record state schema version: %w", err)
	}
	now := s.now().UTC()
	stamp := formatTime(now)
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, `INSERT INTO metadata(key,value) VALUES('schema_version',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value`, fmt.Sprint(schemaVersion)); err != nil {
		return err
	}
	var recordedVersion string
	if err := tx.QueryRowContext(ctx, `SELECT value FROM metadata WHERE key='schema_version'`).Scan(&recordedVersion); err != nil {
		return err
	}
	if recordedVersion != fmt.Sprint(schemaVersion) {
		return fmt.Errorf("unsupported recorded state schema version %s; expected %d", recordedVersion, schemaVersion)
	}
	if _, err := tx.ExecContext(ctx, `INSERT OR IGNORE INTO workspaces(id,name,created_at,updated_at) VALUES('default','Default',?,?)`, stamp, stamp); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `INSERT OR IGNORE INTO sessions(id,workspace_id,name,revision,runtime_state,tabs_json,active_tab_id,created_at,updated_at) VALUES('default','default','Browser',1,'starting','[]','',?,?)`, stamp, stamp); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `INSERT OR IGNORE INTO lease_epochs(session_id,epoch) VALUES('default',0)`); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *sqliteStore) close() error { return s.db.Close() }

func (s *sqliteStore) listWorkspaces(ctx context.Context) ([]Workspace, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT id,name,created_at,updated_at FROM workspaces ORDER BY created_at,id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var result []Workspace
	for rows.Next() {
		var w Workspace
		var created, updated string
		if err := rows.Scan(&w.ID, &w.Name, &created, &updated); err != nil {
			return nil, err
		}
		w.CreatedAt, _ = parseTime(created)
		w.UpdatedAt, _ = parseTime(updated)
		result = append(result, w)
	}
	return result, rows.Err()
}

func defaultWorkspacePreferences(workspaceID string, now time.Time) WorkspacePreferences {
	items := []struct{ id, name, url string }{
		{"gmail", "Gmail", "https://mail.google.com"},
		{"calendar", "Google Calendar", "https://calendar.google.com"},
		{"drive", "Google Drive", "https://drive.google.com"},
		{"github", "GitHub", "https://github.com"},
		{"chatgpt", "ChatGPT", "https://chatgpt.com"},
		{"slack", "Slack", "https://app.slack.com"},
	}
	shortcuts := make([]WorkspaceShortcut, 0, len(items))
	for position, item := range items {
		shortcuts = append(shortcuts, WorkspaceShortcut{ID: item.id, Name: item.name, URL: item.url, Position: position})
	}
	return WorkspacePreferences{WorkspaceID: workspaceID, SearchURL: "https://www.google.com/search?q={query}", Shortcuts: shortcuts, RecentURLs: []string{}, UpdatedAt: now.UTC()}
}

func (s *sqliteStore) getWorkspacePreferences(ctx context.Context, workspaceID string) (WorkspacePreferences, error) {
	var exists int
	if err := s.db.QueryRowContext(ctx, `SELECT 1 FROM workspaces WHERE id=?`, workspaceID).Scan(&exists); errors.Is(err, sql.ErrNoRows) {
		return WorkspacePreferences{}, errNotFound
	} else if err != nil {
		return WorkspacePreferences{}, err
	}
	var value WorkspacePreferences
	var shortcutsJSON, recentsJSON, updated string
	err := s.db.QueryRowContext(ctx, `SELECT search_url,shortcuts_json,recent_urls_json,updated_at FROM workspace_preferences WHERE workspace_id=?`, workspaceID).Scan(&value.SearchURL, &shortcutsJSON, &recentsJSON, &updated)
	if errors.Is(err, sql.ErrNoRows) {
		value = defaultWorkspacePreferences(workspaceID, s.now())
		return s.putWorkspacePreferences(ctx, value)
	}
	if err != nil {
		return WorkspacePreferences{}, err
	}
	value.WorkspaceID = workspaceID
	if err := json.Unmarshal([]byte(shortcutsJSON), &value.Shortcuts); err != nil {
		return WorkspacePreferences{}, err
	}
	if err := json.Unmarshal([]byte(recentsJSON), &value.RecentURLs); err != nil {
		return WorkspacePreferences{}, err
	}
	value.UpdatedAt, _ = parseTime(updated)
	return value, nil
}

func (s *sqliteStore) putWorkspacePreferences(ctx context.Context, value WorkspacePreferences) (WorkspacePreferences, error) {
	shortcuts, err := json.Marshal(value.Shortcuts)
	if err != nil {
		return WorkspacePreferences{}, err
	}
	recents, err := json.Marshal(value.RecentURLs)
	if err != nil {
		return WorkspacePreferences{}, err
	}
	value.UpdatedAt = s.now().UTC()
	result, err := s.db.ExecContext(ctx, `INSERT INTO workspace_preferences(workspace_id,search_url,shortcuts_json,recent_urls_json,updated_at) VALUES(?,?,?,?,?) ON CONFLICT(workspace_id) DO UPDATE SET search_url=excluded.search_url,shortcuts_json=excluded.shortcuts_json,recent_urls_json=excluded.recent_urls_json,updated_at=excluded.updated_at`, value.WorkspaceID, value.SearchURL, string(shortcuts), string(recents), formatTime(value.UpdatedAt))
	if err != nil {
		if strings.Contains(err.Error(), "FOREIGN KEY") {
			return WorkspacePreferences{}, errNotFound
		}
		return WorkspacePreferences{}, err
	}
	if rows, _ := result.RowsAffected(); rows != 1 {
		return WorkspacePreferences{}, errNotFound
	}
	return value, nil
}

func (s *sqliteStore) listSessions(ctx context.Context) ([]BrowserSession, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT id FROM sessions ORDER BY created_at,id`)
	if err != nil {
		return nil, err
	}
	var ids []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			rows.Close()
			return nil, err
		}
		ids = append(ids, id)
	}
	rows.Close()
	result := make([]BrowserSession, 0, len(ids))
	for _, id := range ids {
		session, err := s.getSession(ctx, id)
		if err != nil {
			return nil, err
		}
		result = append(result, session)
	}
	return result, nil
}

func (s *sqliteStore) getSession(ctx context.Context, id string) (BrowserSession, error) {
	session, err := s.getSessionQuery(ctx, s.db, id)
	if err != nil {
		return BrowserSession{}, err
	}
	receipts, err := s.recentCommandReceipts(ctx, id, 20)
	if err != nil {
		return BrowserSession{}, err
	}
	session.CommandReceipts = receipts
	return session, nil
}

type queryer interface {
	QueryRowContext(context.Context, string, ...any) *sql.Row
}

func (s *sqliteStore) getSessionQuery(ctx context.Context, q queryer, id string) (BrowserSession, error) {
	var session BrowserSession
	var tabs, created, updated string
	var heartbeat sql.NullString
	err := q.QueryRowContext(ctx, `SELECT id,workspace_id,name,revision,runtime_state,tabs_json,active_tab_id,last_heartbeat,created_at,updated_at FROM sessions WHERE id=?`, id).Scan(&session.ID, &session.WorkspaceID, &session.Name, &session.Revision, &session.RuntimeState, &tabs, &session.ActiveTabID, &heartbeat, &created, &updated)
	if errors.Is(err, sql.ErrNoRows) {
		return BrowserSession{}, errNotFound
	}
	if err != nil {
		return BrowserSession{}, err
	}
	if err := json.Unmarshal([]byte(tabs), &session.Tabs); err != nil {
		return BrowserSession{}, err
	}
	if session.Tabs == nil {
		session.Tabs = []BrowserTab{}
	}
	session.CreatedAt, _ = parseTime(created)
	session.UpdatedAt, _ = parseTime(updated)
	if heartbeat.Valid {
		value, _ := parseTime(heartbeat.String)
		session.LastHeartbeat = &value
	}
	var lease ControllerLease
	var expires string
	err = q.QueryRowContext(ctx, `SELECT id,session_id,client_id,epoch,expires_at FROM leases WHERE session_id=?`, id).Scan(&lease.ID, &lease.SessionID, &lease.ClientID, &lease.Epoch, &expires)
	if err == nil {
		lease.ExpiresAt, _ = parseTime(expires)
		if lease.ExpiresAt.After(s.now()) {
			lease.RenewAfter = lease.ExpiresAt.Add(-leaseDurationUntilRenew(lease.ExpiresAt, s.now()))
			session.Controller = &lease
		}
	} else if !errors.Is(err, sql.ErrNoRows) {
		return BrowserSession{}, err
	}
	var stream StreamConnection
	var streamExpiry, streamCreated string
	err = q.QueryRowContext(ctx, `SELECT id,session_id,url,state,expires_at,created_at FROM streams WHERE session_id=?`, id).Scan(&stream.ID, &stream.SessionID, &stream.URL, &stream.State, &streamExpiry, &streamCreated)
	if err == nil {
		stream.ExpiresAt, _ = parseTime(streamExpiry)
		stream.CreatedAt, _ = parseTime(streamCreated)
		if stream.ExpiresAt.After(s.now()) {
			session.Stream = &stream
		}
	} else if !errors.Is(err, sql.ErrNoRows) {
		return BrowserSession{}, err
	}
	return session, nil
}

func leaseDurationUntilRenew(expires, now time.Time) time.Duration { return expires.Sub(now) / 2 }

func (s *sqliteStore) ensureSession(ctx context.Context, workspaceID, key, requestHash string) (BrowserSession, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return BrowserSession{}, err
	}
	defer tx.Rollback()
	var oldHash, sessionID string
	err = tx.QueryRowContext(ctx, `SELECT request_hash,session_id FROM session_idempotency WHERE key=?`, key).Scan(&oldHash, &sessionID)
	if err == nil {
		if oldHash != requestHash {
			return BrowserSession{}, errIdempotencyKey
		}
		session, err := s.getSessionQuery(ctx, tx, sessionID)
		return session, err
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return BrowserSession{}, err
	}
	var exists int
	if err := tx.QueryRowContext(ctx, `SELECT 1 FROM workspaces WHERE id=?`, workspaceID).Scan(&exists); errors.Is(err, sql.ErrNoRows) {
		return BrowserSession{}, errNotFound
	} else if err != nil {
		return BrowserSession{}, err
	}
	// Ghostlight currently owns one durable browser runtime, represented by the bootstrap session.
	sessionID = "default"
	if _, err = tx.ExecContext(ctx, `INSERT INTO session_idempotency(key,request_hash,session_id) VALUES(?,?,?)`, key, requestHash, sessionID); err != nil {
		return BrowserSession{}, err
	}
	session, err := s.getSessionQuery(ctx, tx, sessionID)
	if err != nil {
		return BrowserSession{}, err
	}
	if err := tx.Commit(); err != nil {
		return BrowserSession{}, err
	}
	return session, nil
}

func (s *sqliteStore) acquireLease(ctx context.Context, sessionID, clientID string, ttl time.Duration) (ControllerLease, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return ControllerLease{}, err
	}
	defer tx.Rollback()
	var exists int
	if err := tx.QueryRowContext(ctx, `SELECT 1 FROM sessions WHERE id=?`, sessionID).Scan(&exists); errors.Is(err, sql.ErrNoRows) {
		return ControllerLease{}, errNotFound
	} else if err != nil {
		return ControllerLease{}, err
	}
	now := s.now().UTC()
	var currentID, expiry string
	err = tx.QueryRowContext(ctx, `SELECT id,expires_at FROM leases WHERE session_id=?`, sessionID).Scan(&currentID, &expiry)
	if err == nil {
		parsed, _ := parseTime(expiry)
		if parsed.After(now) {
			return ControllerLease{}, errConflict
		}
		if _, err = tx.ExecContext(ctx, `DELETE FROM leases WHERE session_id=?`, sessionID); err != nil {
			return ControllerLease{}, err
		}
	} else if !errors.Is(err, sql.ErrNoRows) {
		return ControllerLease{}, err
	}
	if _, err = tx.ExecContext(ctx, `UPDATE lease_epochs SET epoch=epoch+1 WHERE session_id=?`, sessionID); err != nil {
		return ControllerLease{}, err
	}
	var epoch int64
	if err = tx.QueryRowContext(ctx, `SELECT epoch FROM lease_epochs WHERE session_id=?`, sessionID).Scan(&epoch); err != nil {
		return ControllerLease{}, err
	}
	if _, err = tx.ExecContext(ctx, `UPDATE commands SET state='failed',error_code='controller_lease_expired',error='controller lease expired before the command completed',resulting_revision=(SELECT revision+1 FROM sessions WHERE id=?),acknowledged_at=?,completed_at=? WHERE session_id=? AND lease_epoch<? AND state='queued'`, sessionID, formatTime(now), formatTime(now), sessionID, epoch); err != nil {
		return ControllerLease{}, err
	}
	token, err := randomID(32)
	if err != nil {
		return ControllerLease{}, err
	}
	id, err := randomID(16)
	if err != nil {
		return ControllerLease{}, err
	}
	expires := now.Add(ttl)
	if _, err = tx.ExecContext(ctx, `INSERT INTO leases(id,session_id,client_id,token_hash,epoch,expires_at) VALUES(?,?,?,?,?,?)`, id, sessionID, clientID, hashSecret(token), epoch, formatTime(expires)); err != nil {
		return ControllerLease{}, err
	}
	if _, err = tx.ExecContext(ctx, `UPDATE sessions SET revision=revision+1,updated_at=? WHERE id=?`, formatTime(now), sessionID); err != nil {
		return ControllerLease{}, err
	}
	if err = tx.Commit(); err != nil {
		return ControllerLease{}, err
	}
	return ControllerLease{ID: id, SessionID: sessionID, ClientID: clientID, Token: token, Epoch: epoch, ExpiresAt: expires, RenewAfter: now.Add(ttl / 2)}, nil
}

func (s *sqliteStore) validateLeaseTx(ctx context.Context, tx *sql.Tx, sessionID, leaseID, token string) (int64, error) {
	var tokenHash, expiry string
	var epoch int64
	err := tx.QueryRowContext(ctx, `SELECT token_hash,epoch,expires_at FROM leases WHERE id=? AND session_id=?`, leaseID, sessionID).Scan(&tokenHash, &epoch, &expiry)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, errUnauthorized
	}
	if err != nil {
		return 0, err
	}
	if subtle.ConstantTimeCompare([]byte(tokenHash), []byte(hashSecret(token))) != 1 {
		return 0, errUnauthorized
	}
	expires, _ := parseTime(expiry)
	if !expires.After(s.now()) {
		return 0, errLeaseExpired
	}
	return epoch, nil
}

func (s *sqliteStore) findLeaseByTokenTx(ctx context.Context, tx *sql.Tx, sessionID, token string) (string, int64, error) {
	var id, tokenHash, expiry string
	var epoch int64
	err := tx.QueryRowContext(ctx, `SELECT id,token_hash,epoch,expires_at FROM leases WHERE session_id=?`, sessionID).Scan(&id, &tokenHash, &epoch, &expiry)
	if errors.Is(err, sql.ErrNoRows) {
		return "", 0, errUnauthorized
	}
	if err != nil {
		return "", 0, err
	}
	if subtle.ConstantTimeCompare([]byte(tokenHash), []byte(hashSecret(token))) != 1 {
		return "", 0, errUnauthorized
	}
	expires, _ := parseTime(expiry)
	if !expires.After(s.now()) {
		return "", 0, errLeaseExpired
	}
	return id, epoch, nil
}

func (s *sqliteStore) renewLease(ctx context.Context, sessionID, leaseID, token string, ttl time.Duration) (ControllerLease, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return ControllerLease{}, err
	}
	defer tx.Rollback()
	epoch, err := s.validateLeaseTx(ctx, tx, sessionID, leaseID, token)
	if err != nil {
		return ControllerLease{}, err
	}
	now := s.now().UTC()
	expires := now.Add(ttl)
	if _, err = tx.ExecContext(ctx, `UPDATE leases SET expires_at=? WHERE id=?`, formatTime(expires), leaseID); err != nil {
		return ControllerLease{}, err
	}
	var client string
	if err = tx.QueryRowContext(ctx, `SELECT client_id FROM leases WHERE id=?`, leaseID).Scan(&client); err != nil {
		return ControllerLease{}, err
	}
	if err = tx.Commit(); err != nil {
		return ControllerLease{}, err
	}
	return ControllerLease{ID: leaseID, SessionID: sessionID, ClientID: client, Token: token, Epoch: epoch, ExpiresAt: expires, RenewAfter: now.Add(ttl / 2)}, nil
}

func (s *sqliteStore) releaseLease(ctx context.Context, sessionID, leaseID, token string) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err = s.validateLeaseTx(ctx, tx, sessionID, leaseID, token); err != nil {
		return err
	}
	if _, err = tx.ExecContext(ctx, `DELETE FROM leases WHERE id=?`, leaseID); err != nil {
		return err
	}
	now := formatTime(s.now())
	if _, err = tx.ExecContext(ctx, `UPDATE sessions SET revision=revision+1,updated_at=? WHERE id=?`, now, sessionID); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *sqliteStore) createStream(ctx context.Context, sessionID, clientID, url string, ttl time.Duration) (StreamConnection, error) {
	now := s.now().UTC()
	id, err := randomID(16)
	if err != nil {
		return StreamConnection{}, err
	}
	capability, err := randomID(32)
	if err != nil {
		return StreamConnection{}, err
	}
	stream := StreamConnection{ID: id, SessionID: sessionID, URL: url, State: "connecting", ExpiresAt: now.Add(ttl), CreatedAt: now, Capability: capability}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return StreamConnection{}, err
	}
	defer tx.Rollback()
	result, err := tx.ExecContext(ctx, `INSERT INTO streams(id,session_id,url,state,expires_at,created_at) VALUES(?,?,?,?,?,?) ON CONFLICT(session_id) DO UPDATE SET id=excluded.id,url=excluded.url,state=excluded.state,expires_at=excluded.expires_at,created_at=excluded.created_at`, stream.ID, stream.SessionID, stream.URL, stream.State, formatTime(stream.ExpiresAt), formatTime(stream.CreatedAt))
	if err != nil {
		return StreamConnection{}, err
	}
	if rows, _ := result.RowsAffected(); rows == 0 {
		return StreamConnection{}, errNotFound
	}
	if _, err := tx.ExecContext(ctx, `UPDATE sessions SET revision=revision+1,updated_at=? WHERE id=?`, formatTime(now), sessionID); err != nil {
		return StreamConnection{}, err
	}
	capabilityExpiry := now.Add(ttl)
	if capabilityExpiry.After(now.Add(time.Minute)) {
		capabilityExpiry = now.Add(time.Minute)
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO viewer_capabilities(token_hash,stream_id,session_id,client_id,expires_at,created_at) VALUES(?,?,?,?,?,?)`, hashSecret(capability), stream.ID, sessionID, clientID, formatTime(capabilityExpiry), formatTime(now)); err != nil {
		return StreamConnection{}, err
	}
	if err := tx.Commit(); err != nil {
		return StreamConnection{}, err
	}
	return stream, nil
}

func (s *sqliteStore) redeemViewerCapability(ctx context.Context, capability, clientID string) (StreamConnection, error) {
	now := s.now().UTC()
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return StreamConnection{}, err
	}
	defer tx.Rollback()
	var streamID, sessionID, expectedClient, expires string
	var redeemed sql.NullString
	err = tx.QueryRowContext(ctx, `SELECT stream_id,session_id,client_id,expires_at,redeemed_at FROM viewer_capabilities WHERE token_hash=?`, hashSecret(capability)).Scan(&streamID, &sessionID, &expectedClient, &expires, &redeemed)
	if errors.Is(err, sql.ErrNoRows) {
		return StreamConnection{}, errUnauthorized
	}
	if err != nil {
		return StreamConnection{}, err
	}
	if subtle.ConstantTimeCompare([]byte(expectedClient), []byte(clientID)) != 1 {
		return StreamConnection{}, errUnauthorized
	}
	if redeemed.Valid {
		return StreamConnection{}, errCapabilityUsed
	}
	expiresAt, err := parseTime(expires)
	if err != nil || !expiresAt.After(now) {
		return StreamConnection{}, errCapabilityExpired
	}
	result, err := tx.ExecContext(ctx, `UPDATE viewer_capabilities SET redeemed_at=? WHERE token_hash=? AND redeemed_at IS NULL`, formatTime(now), hashSecret(capability))
	if err != nil {
		return StreamConnection{}, err
	}
	if rows, _ := result.RowsAffected(); rows != 1 {
		return StreamConnection{}, errCapabilityUsed
	}
	var stream StreamConnection
	var streamExpiry, created string
	err = tx.QueryRowContext(ctx, `SELECT id,session_id,url,state,expires_at,created_at FROM streams WHERE id=? AND session_id=?`, streamID, sessionID).Scan(&stream.ID, &stream.SessionID, &stream.URL, &stream.State, &streamExpiry, &created)
	if errors.Is(err, sql.ErrNoRows) {
		return StreamConnection{}, errNotFound
	}
	if err != nil {
		return StreamConnection{}, err
	}
	stream.ExpiresAt, _ = parseTime(streamExpiry)
	stream.CreatedAt, _ = parseTime(created)
	return stream, tx.Commit()
}

func (s *sqliteStore) createCommand(ctx context.Context, sessionID, token, key, requestHash string, input BrowserCommand) (BrowserCommand, bool, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return BrowserCommand{}, false, err
	}
	defer tx.Rollback()
	var oldHash string
	var sequence int64
	err = tx.QueryRowContext(ctx, `SELECT request_hash,sequence FROM commands WHERE session_id=? AND idempotency_key=?`, sessionID, key).Scan(&oldHash, &sequence)
	if err == nil {
		if oldHash != requestHash {
			return BrowserCommand{}, false, errIdempotencyKey
		}
		cmd, err := scanCommand(tx.QueryRowContext(ctx, commandSelect+` WHERE sequence=?`, sequence))
		return cmd, false, err
	} else if !errors.Is(err, sql.ErrNoRows) {
		return BrowserCommand{}, false, err
	}
	_, epoch, err := s.findLeaseByTokenTx(ctx, tx, sessionID, token)
	if err != nil {
		return BrowserCommand{}, false, err
	}
	var revision int64
	if err = tx.QueryRowContext(ctx, `SELECT revision FROM sessions WHERE id=?`, sessionID).Scan(&revision); errors.Is(err, sql.ErrNoRows) {
		return BrowserCommand{}, false, errNotFound
	} else if err != nil {
		return BrowserCommand{}, false, err
	}
	if revision != input.ExpectedRevision {
		return BrowserCommand{}, false, errStaleRevision
	}
	if input.AttachmentID != "" {
		var found int
		if err = tx.QueryRowContext(ctx, `SELECT 1 FROM attachments WHERE id=? AND session_id=?`, input.AttachmentID, sessionID).Scan(&found); errors.Is(err, sql.ErrNoRows) {
			return BrowserCommand{}, false, errNotFound
		} else if err != nil {
			return BrowserCommand{}, false, err
		}
	}
	id, err := randomID(16)
	if err != nil {
		return BrowserCommand{}, false, err
	}
	now := s.now().UTC()
	result, err := tx.ExecContext(ctx, `INSERT INTO commands(id,session_id,idempotency_key,request_hash,type,url,tab_id,attachment_id,expected_revision,lease_epoch,state,error_code,error,result_json,created_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`, id, sessionID, key, requestHash, input.Type, input.URL, input.TabID, input.AttachmentID, input.ExpectedRevision, epoch, "queued", "", "", "", formatTime(now))
	if err != nil {
		return BrowserCommand{}, false, err
	}
	sequence, err = result.LastInsertId()
	if err != nil {
		return BrowserCommand{}, false, err
	}
	if _, err = tx.ExecContext(ctx, `UPDATE sessions SET revision=revision+1,updated_at=? WHERE id=?`, formatTime(now), sessionID); err != nil {
		return BrowserCommand{}, false, err
	}
	if err = tx.Commit(); err != nil {
		return BrowserCommand{}, false, err
	}
	input.ID = id
	input.Sequence = sequence
	input.SessionID = sessionID
	input.LeaseEpoch = epoch
	input.State = "queued"
	input.CreatedAt = now
	return input, true, nil
}

const commandSelect = `SELECT id,sequence,session_id,type,url,tab_id,attachment_id,expected_revision,lease_epoch,state,error_code,error,result_json,resulting_revision,acknowledged_at,completed_at,created_at FROM commands`

func scanCommand(row *sql.Row) (BrowserCommand, error) {
	var c BrowserCommand
	var created, result string
	var acknowledged, completed sql.NullString
	var resultingRevision sql.NullInt64
	err := row.Scan(&c.ID, &c.Sequence, &c.SessionID, &c.Type, &c.URL, &c.TabID, &c.AttachmentID, &c.ExpectedRevision, &c.LeaseEpoch, &c.State, &c.ErrorCode, &c.Error, &result, &resultingRevision, &acknowledged, &completed, &created)
	if errors.Is(err, sql.ErrNoRows) {
		return BrowserCommand{}, errNotFound
	}
	if err != nil {
		return BrowserCommand{}, err
	}
	c.CreatedAt, _ = parseTime(created)
	if result != "" {
		c.Result = json.RawMessage(result)
	}
	if acknowledged.Valid {
		value, _ := parseTime(acknowledged.String)
		c.AcknowledgedAt = &value
	}
	if completed.Valid {
		value, _ := parseTime(completed.String)
		c.CompletedAt = &value
	}
	if resultingRevision.Valid {
		value := resultingRevision.Int64
		c.ResultingRevision = &value
	}
	return c, nil
}

func (s *sqliteStore) getCommand(ctx context.Context, sessionID, id string) (BrowserCommand, error) {
	return scanCommand(s.db.QueryRowContext(ctx, commandSelect+` WHERE session_id=? AND id=?`, sessionID, id))
}

func (s *sqliteStore) recentCommandReceipts(ctx context.Context, sessionID string, limit int) ([]BrowserCommand, error) {
	rows, err := s.db.QueryContext(ctx, commandSelect+` WHERE session_id=? ORDER BY sequence DESC LIMIT ?`, sessionID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	receipts := []BrowserCommand{}
	for rows.Next() {
		var c BrowserCommand
		var created, resultJSON string
		var acknowledged, completed sql.NullString
		var resultingRevision sql.NullInt64
		if err := rows.Scan(&c.ID, &c.Sequence, &c.SessionID, &c.Type, &c.URL, &c.TabID, &c.AttachmentID, &c.ExpectedRevision, &c.LeaseEpoch, &c.State, &c.ErrorCode, &c.Error, &resultJSON, &resultingRevision, &acknowledged, &completed, &created); err != nil {
			return nil, err
		}
		c.CreatedAt, _ = parseTime(created)
		if resultJSON != "" {
			c.Result = json.RawMessage(resultJSON)
		}
		if acknowledged.Valid {
			value, _ := parseTime(acknowledged.String)
			c.AcknowledgedAt = &value
		}
		if completed.Valid {
			value, _ := parseTime(completed.String)
			c.CompletedAt = &value
		}
		if resultingRevision.Valid {
			value := resultingRevision.Int64
			c.ResultingRevision = &value
		}
		receipts = append(receipts, c)
	}
	return receipts, rows.Err()
}

func (s *sqliteStore) listCommands(ctx context.Context, sessionID string, after int64, limit int) ([]BrowserCommand, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT c.id,c.sequence,c.session_id,c.type,c.url,c.tab_id,c.attachment_id,c.expected_revision,c.lease_epoch,c.state,c.error_code,c.error,c.result_json,c.resulting_revision,c.acknowledged_at,c.completed_at,c.created_at
		FROM commands c
		JOIN leases l ON l.session_id=c.session_id AND l.epoch=c.lease_epoch
		WHERE c.session_id=? AND c.sequence>? AND c.state='queued' AND l.expires_at>?
		ORDER BY c.sequence LIMIT ?`, sessionID, after, formatTime(s.now()), limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := []BrowserCommand{}
	for rows.Next() {
		var c BrowserCommand
		var created, resultJSON string
		var acknowledged, completed sql.NullString
		var resultingRevision sql.NullInt64
		if err := rows.Scan(&c.ID, &c.Sequence, &c.SessionID, &c.Type, &c.URL, &c.TabID, &c.AttachmentID, &c.ExpectedRevision, &c.LeaseEpoch, &c.State, &c.ErrorCode, &c.Error, &resultJSON, &resultingRevision, &acknowledged, &completed, &created); err != nil {
			return nil, err
		}
		c.CreatedAt, _ = parseTime(created)
		if resultJSON != "" {
			c.Result = json.RawMessage(resultJSON)
		}
		if acknowledged.Valid {
			value, _ := parseTime(acknowledged.String)
			c.AcknowledgedAt = &value
		}
		if completed.Valid {
			value, _ := parseTime(completed.String)
			c.CompletedAt = &value
		}
		if resultingRevision.Valid {
			value := resultingRevision.Int64
			c.ResultingRevision = &value
		}
		result = append(result, c)
	}
	return result, rows.Err()
}

func (s *sqliteStore) ackCommand(ctx context.Context, id, status, errorCode, failure string, result json.RawMessage) (BrowserCommand, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return BrowserCommand{}, err
	}
	defer tx.Rollback()
	command, err := scanCommand(tx.QueryRowContext(ctx, commandSelect+` WHERE id=?`, id))
	if err != nil {
		return BrowserCommand{}, err
	}
	if command.State != "queued" {
		return command, tx.Commit()
	}
	now := s.now().UTC()
	resultJSON := ""
	if len(result) != 0 {
		resultJSON = string(result)
	}
	if _, err = tx.ExecContext(ctx, `UPDATE sessions SET revision=revision+1,updated_at=? WHERE id=?`, formatTime(now), command.SessionID); err != nil {
		return BrowserCommand{}, err
	}
	var resultingRevision int64
	if err = tx.QueryRowContext(ctx, `SELECT revision FROM sessions WHERE id=?`, command.SessionID).Scan(&resultingRevision); err != nil {
		return BrowserCommand{}, err
	}
	if _, err = tx.ExecContext(ctx, `UPDATE commands SET state=?,error_code=?,error=?,result_json=?,resulting_revision=?,acknowledged_at=?,completed_at=? WHERE id=? AND state='queued'`, status, errorCode, failure, resultJSON, resultingRevision, formatTime(now), formatTime(now), id); err != nil {
		return BrowserCommand{}, err
	}
	command, err = scanCommand(tx.QueryRowContext(ctx, commandSelect+` WHERE id=?`, id))
	if err != nil {
		return BrowserCommand{}, err
	}
	return command, tx.Commit()
}

func (s *sqliteStore) heartbeat(ctx context.Context, sessionID, runtimeState, activeTabID string, tabs []BrowserTab) (BrowserSession, error) {
	encoded, err := json.Marshal(tabs)
	if err != nil {
		return BrowserSession{}, err
	}
	now := s.now().UTC()
	result, err := s.db.ExecContext(ctx, `UPDATE sessions SET
		revision=revision+CASE WHEN tabs_json<>? OR active_tab_id<>? OR runtime_state<>? THEN 1 ELSE 0 END,
		tabs_json=?,active_tab_id=?,runtime_state=?,last_heartbeat=?,updated_at=?
		WHERE id=?`, string(encoded), activeTabID, runtimeState, string(encoded), activeTabID, runtimeState, formatTime(now), formatTime(now), sessionID)
	if err != nil {
		return BrowserSession{}, err
	}
	if rows, _ := result.RowsAffected(); rows == 0 {
		return BrowserSession{}, errNotFound
	}
	return s.getSession(ctx, sessionID)
}

func (s *sqliteStore) addAttachmentWithLease(ctx context.Context, a Attachment, token string) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, _, err := s.findLeaseByTokenTx(ctx, tx, a.SessionID, token); err != nil {
		return err
	}
	var count, total int64
	if err := tx.QueryRowContext(ctx, `SELECT COUNT(*),COALESCE(SUM(size),0) FROM attachments WHERE session_id=?`, a.SessionID).Scan(&count, &total); err != nil {
		return err
	}
	if count >= maxSessionAttachments || total+a.Size > maxSessionAttachmentBytes {
		return errStorageLimit
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO attachments(id,session_id,filename,content_type,size,digest,created_at) VALUES(?,?,?,?,?,?,?)`, a.ID, a.SessionID, a.Filename, a.ContentType, a.Size, a.Digest, formatTime(a.CreatedAt)); err != nil {
		return err
	}
	return tx.Commit()
}
func (s *sqliteStore) listAttachments(ctx context.Context, sessionID string) ([]Attachment, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT id,session_id,filename,content_type,size,digest,created_at FROM attachments WHERE session_id=? ORDER BY created_at,id`, sessionID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := []Attachment{}
	for rows.Next() {
		var a Attachment
		var created string
		if err := rows.Scan(&a.ID, &a.SessionID, &a.Filename, &a.ContentType, &a.Size, &a.Digest, &created); err != nil {
			return nil, err
		}
		a.CreatedAt, _ = parseTime(created)
		result = append(result, a)
	}
	return result, rows.Err()
}
func (s *sqliteStore) getAttachment(ctx context.Context, sessionID, id string) (Attachment, error) {
	var a Attachment
	var created string
	err := s.db.QueryRowContext(ctx, `SELECT id,session_id,filename,content_type,size,digest,created_at FROM attachments WHERE id=? AND (?='' OR session_id=?)`, id, sessionID, sessionID).Scan(&a.ID, &a.SessionID, &a.Filename, &a.ContentType, &a.Size, &a.Digest, &created)
	if errors.Is(err, sql.ErrNoRows) {
		return Attachment{}, errNotFound
	}
	if err != nil {
		return Attachment{}, err
	}
	a.CreatedAt, _ = parseTime(created)
	return a, nil
}
func (s *sqliteStore) attachmentPath(a Attachment) string {
	return filepath.Join(s.attachmentDir, a.SessionID, a.ID)
}

func randomID(bytesCount int) (string, error) {
	value := make([]byte, bytesCount)
	if _, err := rand.Read(value); err != nil {
		return "", err
	}
	return hex.EncodeToString(value), nil
}
func hashSecret(value string) string {
	sum := sha256.Sum256([]byte(value))
	return hex.EncodeToString(sum[:])
}
func formatTime(value time.Time) string         { return value.UTC().Format(time.RFC3339Nano) }
func parseTime(value string) (time.Time, error) { return time.Parse(time.RFC3339Nano, value) }
