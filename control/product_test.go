package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestDurableBootstrapRestartAndModes(t *testing.T) {
	root := t.TempDir()
	cfg := productTestConfig(root)
	h := newProductTestHandler(t, cfg, time.Now)

	workspaces := doJSON(t, h, http.MethodGet, "/v1/workspaces", "", "", nil)
	if workspaces.Code != http.StatusOK || !strings.Contains(workspaces.Body.String(), `"id":"default"`) {
		t.Fatalf("bootstrap workspaces = %d %s", workspaces.Code, workspaces.Body.String())
	}
	sessions := doJSON(t, h, http.MethodGet, "/v1/sessions", "", "", nil)
	if sessions.Code != http.StatusOK || !strings.Contains(sessions.Body.String(), `"id":"default"`) {
		t.Fatalf("bootstrap sessions = %d %s", sessions.Code, sessions.Body.String())
	}

	statePath := filepath.Join(cfg.StateDir, databaseFileName)
	assertMode(t, cfg.StateDir, 0o700)
	assertMode(t, statePath, 0o600)
	for _, suffix := range []string{"-wal", "-shm"} {
		path := statePath + suffix
		if _, err := os.Stat(path); err == nil {
			assertMode(t, path, 0o600)
		} else if !os.IsNotExist(err) {
			t.Fatal(err)
		}
	}
	assertMode(t, cfg.AttachmentDir, 0o700)
	contents, err := os.ReadFile(statePath)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(contents, []byte(cfg.BridgeToken)) || bytes.Contains(contents, []byte(cfg.APIToken)) {
		t.Fatal("configured bearer token was persisted")
	}

	_ = newProductTestHandler(t, cfg, time.Now)
	restarted := newProductTestHandler(t, cfg, time.Now)
	sessions = doJSON(t, restarted, http.MethodGet, "/v1/sessions", "", "", nil)
	var got []BrowserSession
	decodeRecorder(t, sessions, &got)
	if len(got) != 1 || got[0].ID != "default" {
		t.Fatalf("restart sessions = %#v, want one durable default", got)
	}
}

func TestStoreRejectsUnknownSchemaVersion(t *testing.T) {
	root := t.TempDir()
	stateDir := filepath.Join(root, "state")
	attachments := filepath.Join(root, "attachments")
	store, err := openSQLiteStore(stateDir, attachments, time.Now)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.db.Exec(`PRAGMA user_version = 99`); err != nil {
		t.Fatal(err)
	}
	if err := store.close(); err != nil {
		t.Fatal(err)
	}
	if _, err := openSQLiteStore(stateDir, attachments, time.Now); err == nil || !strings.Contains(err.Error(), "unsupported state schema version 99") {
		t.Fatalf("openSQLiteStore() error = %v, want unsupported schema", err)
	}
}

func TestSchemaThreeMigratesChromeWindowAndLibraryState(t *testing.T) {
	root := t.TempDir()
	stateDir := filepath.Join(root, "state")
	attachments := filepath.Join(root, "attachments")
	if err := os.MkdirAll(stateDir, 0o700); err != nil {
		t.Fatal(err)
	}
	db, err := sql.Open("sqlite", filepath.Join(stateDir, databaseFileName))
	if err != nil {
		t.Fatal(err)
	}
	for _, statement := range []string{
		`CREATE TABLE chrome_handoffs (id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL, device_id TEXT NOT NULL, idempotency_key TEXT NOT NULL, request_hash TEXT NOT NULL, title TEXT NOT NULL, url TEXT NOT NULL, state TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL, UNIQUE(device_id,idempotency_key))`,
		`PRAGMA user_version = 3`,
	} {
		if _, err := db.Exec(statement); err != nil {
			t.Fatal(err)
		}
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}

	store, err := openSQLiteStore(stateDir, attachments, time.Now)
	if err != nil {
		t.Fatalf("migrate schema three: %v", err)
	}
	defer store.close()
	tx, err := store.db.BeginTx(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	columns, err := tableColumns(context.Background(), tx, "chrome_handoffs")
	_ = tx.Rollback()
	if err != nil {
		t.Fatal(err)
	}
	if !columns["group_id"] || !columns["position"] {
		t.Fatalf("migrated handoff columns = %#v", columns)
	}
	for _, table := range []string{"chrome_library_snapshots", "chrome_library_items"} {
		var name string
		if err := store.db.QueryRow(`SELECT name FROM sqlite_master WHERE type='table' AND name=?`, table).Scan(&name); err != nil {
			t.Fatalf("migrated table %s: %v", table, err)
		}
	}
}

func TestSchemaFourMigratesNativeClientEnrollment(t *testing.T) {
	root := t.TempDir()
	stateDir := filepath.Join(root, "state")
	attachments := filepath.Join(root, "attachments")
	if err := os.MkdirAll(stateDir, 0o700); err != nil {
		t.Fatal(err)
	}
	db, err := sql.Open("sqlite", filepath.Join(stateDir, databaseFileName))
	if err != nil {
		t.Fatal(err)
	}
	for _, statement := range []string{
		`CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)`,
		`INSERT INTO metadata(key,value) VALUES('schema_version','4')`,
		`PRAGMA user_version = 4`,
	} {
		if _, err := db.Exec(statement); err != nil {
			t.Fatal(err)
		}
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}

	store, err := openSQLiteStore(stateDir, attachments, time.Now)
	if err != nil {
		t.Fatalf("migrate schema four: %v", err)
	}
	defer store.close()
	for _, table := range []string{"native_client_enrollments", "native_clients"} {
		var name string
		if err := store.db.QueryRow(`SELECT name FROM sqlite_master WHERE type='table' AND name=?`, table).Scan(&name); err != nil {
			t.Fatalf("migrated table %s: %v", table, err)
		}
	}
	var version int
	if err := store.db.QueryRow(`PRAGMA user_version`).Scan(&version); err != nil || version != schemaVersion {
		t.Fatalf("migrated version = %d, %v; want %d", version, err, schemaVersion)
	}
}

func TestSchemaFiveMigratesViewerCapabilityNativeClientBinding(t *testing.T) {
	root := t.TempDir()
	stateDir := filepath.Join(root, "state")
	attachments := filepath.Join(root, "attachments")
	if err := os.MkdirAll(stateDir, 0o700); err != nil {
		t.Fatal(err)
	}
	db, err := sql.Open("sqlite", filepath.Join(stateDir, databaseFileName))
	if err != nil {
		t.Fatal(err)
	}
	for _, statement := range []string{
		`CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)`,
		`INSERT INTO metadata(key,value) VALUES('schema_version','5')`,
		`CREATE TABLE viewer_capabilities (token_hash TEXT PRIMARY KEY, stream_id TEXT NOT NULL, session_id TEXT NOT NULL, client_id TEXT NOT NULL, expires_at TEXT NOT NULL, redeemed_at TEXT, created_at TEXT NOT NULL)`,
		`INSERT INTO viewer_capabilities(token_hash,stream_id,session_id,client_id,expires_at,created_at) VALUES('hash','stream','default','legacy-mac','2026-08-13T13:00:00Z','2026-08-13T12:00:00Z')`,
		`PRAGMA user_version = 5`,
	} {
		if _, err := db.Exec(statement); err != nil {
			t.Fatal(err)
		}
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}

	store, err := openSQLiteStore(stateDir, attachments, time.Now)
	if err != nil {
		t.Fatalf("migrate schema five: %v", err)
	}
	defer store.close()
	columns := tableColumnNames(t, store.db, "viewer_capabilities")
	if !columns["native_client_id"] {
		t.Fatalf("migrated viewer capability columns = %#v", columns)
	}
	var nativeClientID sql.NullString
	if err := store.db.QueryRow(`SELECT native_client_id FROM viewer_capabilities WHERE token_hash='hash'`).Scan(&nativeClientID); err != nil || nativeClientID.Valid {
		t.Fatalf("migrated legacy native_client_id = %#v, %v; want NULL", nativeClientID, err)
	}
	var userVersion int
	var recordedVersion string
	if err := store.db.QueryRow(`PRAGMA user_version`).Scan(&userVersion); err != nil {
		t.Fatal(err)
	}
	if err := store.db.QueryRow(`SELECT value FROM metadata WHERE key='schema_version'`).Scan(&recordedVersion); err != nil {
		t.Fatal(err)
	}
	if userVersion != schemaVersion || recordedVersion != fmt.Sprint(schemaVersion) {
		t.Fatalf("migrated versions = %d/%q, want %d", userVersion, recordedVersion, schemaVersion)
	}
}

func TestSchemaSixMigratesActivitySpacesWithoutBrowserProfileData(t *testing.T) {
	root := t.TempDir()
	stateDir := filepath.Join(root, "state")
	attachments := filepath.Join(root, "attachments")
	if err := os.MkdirAll(stateDir, 0o700); err != nil {
		t.Fatal(err)
	}
	db, err := sql.Open("sqlite", filepath.Join(stateDir, databaseFileName))
	if err != nil {
		t.Fatal(err)
	}
	for _, statement := range []string{
		`CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)`,
		`INSERT INTO metadata(key,value) VALUES('schema_version','6')`,
		`CREATE TABLE commands (sequence INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE, session_id TEXT NOT NULL, idempotency_key TEXT NOT NULL, request_hash TEXT NOT NULL, type TEXT NOT NULL, url TEXT NOT NULL, tab_id TEXT NOT NULL, attachment_id TEXT NOT NULL, expected_revision INTEGER NOT NULL, lease_epoch INTEGER NOT NULL, state TEXT NOT NULL, error_code TEXT NOT NULL, error TEXT NOT NULL, result_json TEXT NOT NULL, resulting_revision INTEGER, acknowledged_at TEXT, completed_at TEXT, created_at TEXT NOT NULL, UNIQUE(session_id,idempotency_key))`,
		`CREATE TABLE chrome_handoffs (id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL, device_id TEXT NOT NULL, idempotency_key TEXT NOT NULL, request_hash TEXT NOT NULL, title TEXT NOT NULL, url TEXT NOT NULL, group_id TEXT NOT NULL DEFAULT '', position INTEGER NOT NULL DEFAULT 0, state TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL, UNIQUE(device_id,idempotency_key))`,
		`PRAGMA user_version = 6`,
	} {
		if _, err := db.Exec(statement); err != nil {
			t.Fatal(err)
		}
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}

	store, err := openSQLiteStore(stateDir, attachments, time.Now)
	if err != nil {
		t.Fatalf("migrate schema six: %v", err)
	}
	defer store.close()
	for _, table := range []string{"activity_spaces", "space_idempotency"} {
		var name string
		if err := store.db.QueryRow(`SELECT name FROM sqlite_master WHERE type='table' AND name=?`, table).Scan(&name); err != nil {
			t.Fatalf("migrated table %s: %v", table, err)
		}
	}
	for table, columns := range map[string][]string{
		"commands":        {"payload_json"},
		"chrome_handoffs": {"space_id"},
	} {
		for _, column := range columns {
			var count int
			if err := store.db.QueryRow(`SELECT COUNT(*) FROM pragma_table_info(?) WHERE name=?`, table, column).Scan(&count); err != nil || count != 1 {
				t.Fatalf("migrated %s.%s = %d, %v", table, column, count, err)
			}
		}
	}
	var version int
	if err := store.db.QueryRow(`PRAGMA user_version`).Scan(&version); err != nil || version != schemaVersion {
		t.Fatalf("migrated version = %d, %v; want %d", version, err, schemaVersion)
	}
}

func TestSchemaSevenMigratesContentFreePeripheralTables(t *testing.T) {
	root := t.TempDir()
	stateDir := filepath.Join(root, "state")
	attachments := filepath.Join(root, "attachments")
	if err := os.MkdirAll(stateDir, 0o700); err != nil {
		t.Fatal(err)
	}
	db, err := sql.Open("sqlite", filepath.Join(stateDir, databaseFileName))
	if err != nil {
		t.Fatal(err)
	}
	for _, statement := range []string{
		`CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)`,
		`INSERT INTO metadata(key,value) VALUES('schema_version','7')`,
		`PRAGMA user_version = 7`,
	} {
		if _, err := db.Exec(statement); err != nil {
			t.Fatal(err)
		}
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	store, err := openSQLiteStore(stateDir, attachments, time.Now)
	if err != nil {
		t.Fatalf("migrate schema seven: %v", err)
	}
	defer store.close()
	for _, table := range []string{"peripheral_grants", "peripheral_audit_events"} {
		columns := tableColumnNames(t, store.db, table)
		for _, forbidden := range []string{"filename", "content", "url", "title", "media"} {
			if columns[forbidden] {
				t.Fatalf("%s persists forbidden %s column", table, forbidden)
			}
		}
	}
	var version int
	if err := store.db.QueryRow(`PRAGMA user_version`).Scan(&version); err != nil || version != schemaVersion {
		t.Fatalf("migrated version = %d, %v; want %d", version, err, schemaVersion)
	}
}

func TestActivitySpacesCaptureParkActivateAndAuthorization(t *testing.T) {
	h := newProductTestHandler(t, productTestConfig(t.TempDir()), time.Now)
	lease := acquireLease(t, h, "default")
	heartbeat := doJSON(t, h, http.MethodPost, "/v1/bridge/heartbeat", "", h.config.BridgeToken, strings.NewReader(`{"session_id":"default","sequence":1,"agent_version":"test","tabs":[{"id":"safe","title":"Private title must not persist","url":"https://example.test/work","active":true,"loading":false,"audible":false,"discarded":false,"window_id":1,"index":0},{"id":"internal","title":"Settings","url":"chrome://settings","active":false,"loading":false,"audible":false,"discarded":false,"window_id":1,"index":1}],"active_tab_id":"safe","runtime_state":"ready"}`))
	var session BrowserSession
	decodeRecorder(t, heartbeat, &session)
	directRestore := doJSON(t, h, http.MethodPost, "/v1/sessions/default/commands", "direct-restore", lease.Token, strings.NewReader(fmt.Sprintf(`{"type":"restore_space","space_id":"made-up","destinations":["https://example.test"],"active_position":0,"expected_revision":%d}`, session.Revision)))
	if directRestore.Code != http.StatusBadRequest {
		t.Fatalf("direct restore command = %d %s", directRestore.Code, directRestore.Body.String())
	}

	path := "/v1/workspaces/default/spaces"
	unauthorized := doBearerRequest(h, http.MethodGet, path, "wrong", nil)
	if unauthorized.Code != http.StatusUnauthorized {
		t.Fatalf("unauthorized spaces = %d %s", unauthorized.Code, unauthorized.Body.String())
	}
	createBody := fmt.Sprintf(`{"name":"Launch","session_id":"default","expected_revision":%d}`, session.Revision)
	created := doJSON(t, h, http.MethodPost, path, "space-create", lease.Token, strings.NewReader(createBody))
	if created.Code != http.StatusCreated {
		t.Fatalf("create space = %d %s", created.Code, created.Body.String())
	}
	var space ActivitySpace
	decodeRecorder(t, created, &space)
	if space.Name != "Launch" || space.State != "active" || space.HomePreferencesWorkspaceID != "default" || space.ActivePosition != 0 || len(space.Tabs) != 1 || space.Tabs[0].URL != "https://example.test/work" {
		t.Fatalf("created space = %#v", space)
	}
	if strings.Contains(created.Body.String(), "Private title") || strings.Contains(created.Body.String(), "chrome://") || strings.Contains(created.Body.String(), "cookie") {
		t.Fatalf("space exposed unsafe browser state: %s", created.Body.String())
	}
	retry := doJSON(t, h, http.MethodPost, path, "space-create", lease.Token, strings.NewReader(createBody))
	var retried ActivitySpace
	decodeRecorder(t, retry, &retried)
	if retry.Code != http.StatusOK || retried.ID != space.ID {
		t.Fatalf("idempotent create = %d %#v", retry.Code, retried)
	}

	current := doJSON(t, h, http.MethodGet, "/v1/sessions/default", "", "", nil)
	decodeRecorder(t, current, &session)
	parkBody := fmt.Sprintf(`{"session_id":"default","expected_revision":%d}`, session.Revision)
	parked := doJSON(t, h, http.MethodPost, path+"/"+space.ID+"/park", "space-park", lease.Token, strings.NewReader(parkBody))
	decodeRecorder(t, parked, &space)
	if parked.Code != http.StatusOK || space.State != "parked" {
		t.Fatalf("park space = %d %#v", parked.Code, space)
	}

	stale := doJSON(t, h, http.MethodPost, path+"/"+space.ID+"/activate", "space-activate-stale", lease.Token, strings.NewReader(parkBody))
	if stale.Code != http.StatusConflict || !strings.Contains(stale.Body.String(), "stale_revision") {
		t.Fatalf("stale activation = %d %s", stale.Code, stale.Body.String())
	}
	current = doJSON(t, h, http.MethodGet, "/v1/sessions/default", "", "", nil)
	decodeRecorder(t, current, &session)
	activateBody := fmt.Sprintf(`{"session_id":"default","expected_revision":%d}`, session.Revision)
	activated := doJSON(t, h, http.MethodPost, path+"/"+space.ID+"/activate", "space-activate", lease.Token, strings.NewReader(activateBody))
	if activated.Code != http.StatusAccepted {
		t.Fatalf("activate space = %d %s", activated.Code, activated.Body.String())
	}
	var activation ActivitySpaceActivation
	decodeRecorder(t, activated, &activation)
	if activation.Space.State != "parked" || activation.Command.Type != "restore_space" || activation.Command.SpaceID != space.ID || len(activation.Command.Destinations) != 1 || activation.Command.Destinations[0] != "https://example.test/work" {
		t.Fatalf("activation = %#v", activation)
	}
	listed := doJSON(t, h, http.MethodGet, "/v1/bridge/commands?session_id=default&after=0", "", h.config.BridgeToken, nil)
	if listed.Code != http.StatusOK || !strings.Contains(listed.Body.String(), `"type":"restore_space"`) {
		t.Fatalf("restore command not delivered through bridge = %d %s", listed.Code, listed.Body.String())
	}
	acked := doJSON(t, h, http.MethodPost, "/v1/bridge/commands/"+activation.Command.ID+"/ack", "", h.config.BridgeToken, strings.NewReader(`{"status":"ok","result":{"restored_tabs":1}}`))
	if acked.Code != http.StatusOK {
		t.Fatalf("ack activation = %d %s", acked.Code, acked.Body.String())
	}
	spaces := doJSON(t, h, http.MethodGet, path, "", "", nil)
	var values []ActivitySpace
	decodeRecorder(t, spaces, &values)
	if len(values) != 1 || values[0].State != "active" {
		t.Fatalf("spaces after activation = %#v", values)
	}
}

func TestTypedContinuityRoutesResumeBrowseAndSend(t *testing.T) {
	now := time.Date(2026, 8, 13, 20, 0, 0, 0, time.UTC)
	h := newProductTestHandler(t, productTestConfig(t.TempDir()), func() time.Time { return now })
	lease := acquireLease(t, h, "default")
	heartbeat := doJSON(t, h, http.MethodPost, "/v1/bridge/heartbeat", "", h.config.BridgeToken, strings.NewReader(`{"session_id":"default","sequence":1,"agent_version":"test","tabs":[{"id":"safe","title":"Private title","url":"https://example.test/work","active":true,"loading":false,"audible":false,"discarded":false,"window_id":1,"index":0}],"active_tab_id":"safe","runtime_state":"ready"}`))
	var session BrowserSession
	decodeRecorder(t, heartbeat, &session)

	spaceBody := fmt.Sprintf(`{"name":"Research","session_id":"default","expected_revision":%d}`, session.Revision)
	created := doJSON(t, h, http.MethodPost, "/v1/workspaces/default/spaces", "continuity-space", lease.Token, strings.NewReader(spaceBody))
	var space ActivitySpace
	decodeRecorder(t, created, &space)
	if created.Code != http.StatusCreated {
		t.Fatalf("create continuity space = %d %s", created.Code, created.Body.String())
	}

	overview := doJSON(t, h, http.MethodGet, "/v1/workspaces/default/continuity", "", "", nil)
	var inventory ContinuityOverview
	decodeRecorder(t, overview, &inventory)
	if overview.Code != http.StatusOK || len(inventory.Resume) != 1 || inventory.Resume[0].ID != space.ID || inventory.Browse.Authority != "chrome_snapshot" || inventory.Browse.Bookmarks == nil || inventory.Browse.ReadingList == nil || inventory.Send == nil {
		t.Fatalf("continuity overview = %d %#v", overview.Code, inventory)
	}

	current := doJSON(t, h, http.MethodGet, "/v1/sessions/default", "", "", nil)
	decodeRecorder(t, current, &session)
	expires := now.Add(5 * time.Minute).Format(time.RFC3339)
	sendBody := fmt.Sprintf(`{"verb":"send","adapter":"url_handler","session_id":"default","expected_revision":%d,"expires_at":%q,"url":"https://example.test/sent"}`, session.Revision, expires)
	sent := doJSON(t, h, http.MethodPost, "/v1/workspaces/default/continuity", "continuity-send", lease.Token, strings.NewReader(sendBody))
	var sendReceipt ContinuityIntentReceipt
	decodeRecorder(t, sent, &sendReceipt)
	if sent.Code != http.StatusAccepted || sendReceipt.Verb != "send" || sendReceipt.Adapter != "url_handler" || sendReceipt.Authority != "ghostlight_session" || sendReceipt.Command.Type != "create_tab" || sendReceipt.Command.ContinuityVerb != "send" || sendReceipt.Command.ContinuityAdapter != "url_handler" || sendReceipt.Command.ContinuityExpiry == nil {
		t.Fatalf("send receipt = %d %#v", sent.Code, sendReceipt)
	}
	retried := doJSON(t, h, http.MethodPost, "/v1/workspaces/default/continuity", "continuity-send", lease.Token, strings.NewReader(sendBody))
	var retryReceipt ContinuityIntentReceipt
	decodeRecorder(t, retried, &retryReceipt)
	if retried.Code != http.StatusOK || retryReceipt.Command.ID != sendReceipt.Command.ID {
		t.Fatalf("idempotent send = %d %#v", retried.Code, retryReceipt)
	}
	bridge := doJSON(t, h, http.MethodGet, "/v1/bridge/commands?session_id=default&after=0", "", h.config.BridgeToken, nil)
	if bridge.Code != http.StatusOK || !strings.Contains(bridge.Body.String(), `"continuity_verb":"send"`) || !strings.Contains(bridge.Body.String(), `"continuity_adapter":"url_handler"`) {
		t.Fatalf("continuity provenance missing from durable command = %d %s", bridge.Code, bridge.Body.String())
	}

	unsafeBody := fmt.Sprintf(`{"verb":"send","adapter":"native_ui","session_id":"default","expected_revision":%d,"expires_at":%q,"url":"https://example.test/?access_token=secret"}`, session.Revision+1, expires)
	unsafe := doJSON(t, h, http.MethodPost, "/v1/workspaces/default/continuity", "continuity-unsafe", lease.Token, strings.NewReader(unsafeBody))
	if unsafe.Code != http.StatusBadRequest || !strings.Contains(unsafe.Body.String(), "unsafe_url") {
		t.Fatalf("unsafe send = %d %s", unsafe.Code, unsafe.Body.String())
	}
	expiredBody := fmt.Sprintf(`{"verb":"send","adapter":"native_ui","session_id":"default","expected_revision":%d,"expires_at":%q,"url":"https://example.test"}`, session.Revision+1, now.Add(-time.Second).Format(time.RFC3339))
	expired := doJSON(t, h, http.MethodPost, "/v1/workspaces/default/continuity", "continuity-expired", lease.Token, strings.NewReader(expiredBody))
	if expired.Code != http.StatusBadRequest {
		t.Fatalf("expired send = %d %s", expired.Code, expired.Body.String())
	}

	current = doJSON(t, h, http.MethodGet, "/v1/sessions/default", "", "", nil)
	decodeRecorder(t, current, &session)
	resumeBody := fmt.Sprintf(`{"verb":"resume","adapter":"native_ui","session_id":"default","expected_revision":%d,"expires_at":%q,"space_id":%q}`, session.Revision, expires, space.ID)
	resumed := doJSON(t, h, http.MethodPost, "/v1/workspaces/default/continuity", "continuity-resume", lease.Token, strings.NewReader(resumeBody))
	var resumeReceipt ContinuityIntentReceipt
	decodeRecorder(t, resumed, &resumeReceipt)
	if resumed.Code != http.StatusAccepted || resumeReceipt.Verb != "resume" || resumeReceipt.Space == nil || resumeReceipt.Space.ID != space.ID || resumeReceipt.Command.Type != "restore_space" || resumeReceipt.Command.SpaceID != space.ID {
		t.Fatalf("resume receipt = %d %#v", resumed.Code, resumeReceipt)
	}

	browseMutation := doJSON(t, h, http.MethodPost, "/v1/workspaces/default/continuity", "continuity-browse", lease.Token, strings.NewReader(fmt.Sprintf(`{"verb":"browse","adapter":"native_ui","session_id":"default","expected_revision":%d,"expires_at":%q}`, session.Revision+1, expires)))
	if browseMutation.Code != http.StatusBadRequest {
		t.Fatalf("browse mutation = %d %s", browseMutation.Code, browseMutation.Body.String())
	}
	directMetadata := doJSON(t, h, http.MethodPost, "/v1/sessions/default/commands", "forged-continuity", lease.Token, strings.NewReader(fmt.Sprintf(`{"type":"create_tab","url":"https://example.test","expected_revision":%d,"continuity_verb":"send"}`, session.Revision+1)))
	if directMetadata.Code != http.StatusBadRequest {
		t.Fatalf("forged continuity metadata = %d %s", directMetadata.Code, directMetadata.Body.String())
	}
}

func TestTypedContinuityExpiresQueuedIntentServerSide(t *testing.T) {
	now := time.Date(2026, 8, 13, 20, 0, 0, 0, time.UTC)
	h := newProductTestHandler(t, productTestConfig(t.TempDir()), func() time.Time { return now })
	lease := acquireLease(t, h, "default")
	current := doJSON(t, h, http.MethodGet, "/v1/sessions/default", "", "", nil)
	var session BrowserSession
	decodeRecorder(t, current, &session)
	body := fmt.Sprintf(`{"verb":"send","adapter":"share","session_id":"default","expected_revision":%d,"expires_at":%q,"url":"https://example.test/shared"}`, session.Revision, now.Add(5*time.Minute).Format(time.RFC3339))
	queued := doJSON(t, h, http.MethodPost, "/v1/workspaces/default/continuity", "continuity-expiry", lease.Token, strings.NewReader(body))
	if queued.Code != http.StatusAccepted {
		t.Fatalf("queue expiring continuity = %d %s", queued.Code, queued.Body.String())
	}

	now = now.Add(6 * time.Minute)
	current = doJSON(t, h, http.MethodGet, "/v1/sessions/default", "", "", nil)
	decodeRecorder(t, current, &session)
	if len(session.CommandReceipts) != 1 || session.CommandReceipts[0].State != "failed" || session.CommandReceipts[0].ErrorCode != "continuity_intent_expired" || session.CommandReceipts[0].CompletedAt == nil {
		t.Fatalf("expired continuity receipt = %#v", session.CommandReceipts)
	}
	commands := doJSON(t, h, http.MethodGet, "/v1/bridge/commands?session_id=default&after=0", "", h.config.BridgeToken, nil)
	if commands.Code != http.StatusOK || strings.Contains(commands.Body.String(), `"continuity_verb":"send"`) {
		t.Fatalf("expired continuity remained executable = %d %s", commands.Code, commands.Body.String())
	}
}

func TestPeripheralGrantsAreDirectionalOriginBoundRevocableAndAudited(t *testing.T) {
	h := newProductTestHandler(t, productTestConfig(t.TempDir()), time.Now)
	store := h.store
	lease, err := store.acquireLease(t.Context(), "default", "peripheral-client", time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	expires := store.now().UTC().Add(time.Hour)
	body := fmt.Sprintf(`{"session_id":"default","capability":"download","direction":"remote_to_local","origin":"https://viewer.example.test","expires_at":%q}`, formatTime(expires))
	created := doJSON(t, h, http.MethodPost, "/v1/workspaces/default/peripheral-grants", "grant-download", lease.Token, strings.NewReader(body))
	if created.Code != http.StatusCreated {
		t.Fatalf("create grant = %d %s", created.Code, created.Body.String())
	}
	var grant PeripheralGrant
	decodeRecorder(t, created, &grant)
	if grant.Capability != "download" || grant.Direction != "remote_to_local" || grant.Origin != "https://viewer.example.test" || grant.State != "active" || grant.ClientID != "operator" {
		t.Fatalf("grant = %#v", grant)
	}
	retry := doJSON(t, h, http.MethodPost, "/v1/workspaces/default/peripheral-grants", "grant-download", lease.Token, strings.NewReader(body))
	if retry.Code != http.StatusOK {
		t.Fatalf("retry grant = %d %s", retry.Code, retry.Body.String())
	}
	wrongDirection := doJSON(t, h, http.MethodPost, "/v1/workspaces/default/peripheral-grants", "wrong-direction", lease.Token, strings.NewReader(fmt.Sprintf(`{"session_id":"default","capability":"download","direction":"local_to_remote","origin":"https://viewer.example.test","expires_at":%q}`, formatTime(expires))))
	if wrongDirection.Code != http.StatusBadRequest {
		t.Fatalf("wrong direction = %d %s", wrongDirection.Code, wrongDirection.Body.String())
	}
	unsafeOrigin := doJSON(t, h, http.MethodPost, "/v1/workspaces/default/peripheral-grants", "unsafe-origin", lease.Token, strings.NewReader(fmt.Sprintf(`{"session_id":"default","capability":"camera","direction":"local_to_remote","origin":"https://viewer.example.test/path?token=secret","expires_at":%q}`, formatTime(expires))))
	if unsafeOrigin.Code != http.StatusBadRequest {
		t.Fatalf("unsafe origin = %d %s", unsafeOrigin.Code, unsafeOrigin.Body.String())
	}
	unavailable := doJSON(t, h, http.MethodPost, "/v1/workspaces/default/peripheral-grants", "unavailable-copy", lease.Token, strings.NewReader(fmt.Sprintf(`{"session_id":"default","capability":"copy","direction":"remote_to_local","origin":"https://viewer.example.test","expires_at":%q}`, formatTime(expires))))
	if unavailable.Code != http.StatusConflict || !strings.Contains(unavailable.Body.String(), `"code":"capability_unavailable"`) {
		t.Fatalf("unavailable capability = %d %s", unavailable.Code, unavailable.Body.String())
	}

	authorized := doJSON(t, h, http.MethodPost, "/v1/workspaces/default/peripheral-authorizations", "", "", strings.NewReader(`{"session_id":"default","capability":"download","direction":"remote_to_local","origin":"https://viewer.example.test"}`))
	var decision PeripheralAuthorization
	decodeRecorder(t, authorized, &decision)
	if authorized.Code != http.StatusOK || !decision.Allowed || decision.GrantID != grant.ID {
		t.Fatalf("authorization = %d %#v", authorized.Code, decision)
	}
	denied := doJSON(t, h, http.MethodPost, "/v1/workspaces/default/peripheral-authorizations", "", "", strings.NewReader(`{"session_id":"default","capability":"camera","direction":"local_to_remote","origin":"https://viewer.example.test"}`))
	decision = PeripheralAuthorization{}
	decodeRecorder(t, denied, &decision)
	if denied.Code != http.StatusOK || decision.Allowed {
		t.Fatalf("denied authorization = %d %#v", denied.Code, decision)
	}

	revoked := doJSON(t, h, http.MethodDelete, "/v1/workspaces/default/peripheral-grants/"+grant.ID, "", "", nil)
	if revoked.Code != http.StatusOK || !strings.Contains(revoked.Body.String(), `"state":"revoked"`) {
		t.Fatalf("revoke = %d %s", revoked.Code, revoked.Body.String())
	}
	authorized = doJSON(t, h, http.MethodPost, "/v1/workspaces/default/peripheral-authorizations", "", "", strings.NewReader(`{"session_id":"default","capability":"download","direction":"remote_to_local","origin":"https://viewer.example.test"}`))
	decision = PeripheralAuthorization{}
	decodeRecorder(t, authorized, &decision)
	if decision.Allowed {
		t.Fatalf("authorization after revoke = %#v", decision)
	}
	audit := doJSON(t, h, http.MethodGet, "/v1/workspaces/default/peripheral-audit", "", "", nil)
	if audit.Code != http.StatusOK || !strings.Contains(audit.Body.String(), `"action":"granted"`) || !strings.Contains(audit.Body.String(), `"action":"revoked"`) || !strings.Contains(audit.Body.String(), `"outcome":"denied"`) || strings.Contains(audit.Body.String(), "secret") {
		t.Fatalf("audit = %d %s", audit.Code, audit.Body.String())
	}
}

func TestPeripheralGrantsAreScopedToAuthenticatedNativeClient(t *testing.T) {
	h := newProductTestHandler(t, productTestConfig(t.TempDir()), time.Now)
	first := enrollNativeClient(t, h, "First Mac")
	second := enrollNativeClient(t, h, "Second Mac")
	lease, err := h.store.acquireLease(t.Context(), "default", "controller", time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	expires := formatTime(h.store.now().UTC().Add(time.Hour))
	body := strings.NewReader(fmt.Sprintf(`{"session_id":"default","capability":"camera","direction":"local_to_remote","origin":"https://viewer.example.test","expires_at":%q}`, expires))
	request := httptest.NewRequest(http.MethodPost, "http://ghostlight.test/v1/workspaces/default/peripheral-grants", body)
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("Authorization", "Bearer "+first.ClientToken)
	request.Header.Set("X-Ghostlight-Lease-Token", lease.Token)
	request.Header.Set("Idempotency-Key", "first-camera")
	created := httptest.NewRecorder()
	h.ServeHTTP(created, request)
	var grant PeripheralGrant
	decodeRecorder(t, created, &grant)
	if created.Code != http.StatusCreated || grant.ClientID != first.Client.ID {
		t.Fatalf("native grant = %d %#v", created.Code, grant)
	}

	listed := doBearerRequest(h, http.MethodGet, "/v1/workspaces/default/peripheral-grants", second.ClientToken, nil)
	if listed.Code != http.StatusOK || listed.Body.String() != "[]\n" {
		t.Fatalf("other client grants = %d %s", listed.Code, listed.Body.String())
	}
	authorize := doBearerRequest(h, http.MethodPost, "/v1/workspaces/default/peripheral-authorizations", second.ClientToken, strings.NewReader(`{"session_id":"default","capability":"camera","direction":"local_to_remote","origin":"https://viewer.example.test"}`))
	var decision PeripheralAuthorization
	decodeRecorder(t, authorize, &decision)
	if authorize.Code != http.StatusOK || decision.Allowed {
		t.Fatalf("other client authorization = %d %#v", authorize.Code, decision)
	}
}

func TestSchemaFiveMigrationRollsBackNativeClientBinding(t *testing.T) {
	root := t.TempDir()
	stateDir := filepath.Join(root, "state")
	attachments := filepath.Join(root, "attachments")
	if err := os.MkdirAll(stateDir, 0o700); err != nil {
		t.Fatal(err)
	}
	databasePath := filepath.Join(stateDir, databaseFileName)
	db, err := sql.Open("sqlite", databasePath)
	if err != nil {
		t.Fatal(err)
	}
	for _, statement := range []string{
		`CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)`,
		`INSERT INTO metadata(key,value) VALUES('schema_version','5')`,
		`CREATE TRIGGER reject_schema_six BEFORE UPDATE ON metadata BEGIN SELECT RAISE(ABORT, 'stop schema six'); END`,
		`CREATE TABLE viewer_capabilities (token_hash TEXT PRIMARY KEY, stream_id TEXT NOT NULL, session_id TEXT NOT NULL, client_id TEXT NOT NULL, expires_at TEXT NOT NULL, redeemed_at TEXT, created_at TEXT NOT NULL)`,
		`PRAGMA user_version = 5`,
	} {
		if _, err := db.Exec(statement); err != nil {
			t.Fatal(err)
		}
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}

	if _, err := openSQLiteStore(stateDir, attachments, time.Now); err == nil || !strings.Contains(err.Error(), "stop schema six") {
		t.Fatalf("failed schema five migration error = %v, want injected failure", err)
	}
	db, err = sql.Open("sqlite", databasePath)
	if err != nil {
		t.Fatal(err)
	}
	if columns := tableColumnNames(t, db, "viewer_capabilities"); columns["native_client_id"] {
		t.Fatalf("failed migration left native_client_id behind: %#v", columns)
	}
	var userVersion int
	if err := db.QueryRow(`PRAGMA user_version`).Scan(&userVersion); err != nil || userVersion != 5 {
		t.Fatalf("failed migration version = %d, %v; want 5", userVersion, err)
	}
	if _, err := db.Exec(`DROP TRIGGER reject_schema_six`); err != nil {
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	store, err := openSQLiteStore(stateDir, attachments, time.Now)
	if err != nil {
		t.Fatalf("restart after schema five rollback: %v", err)
	}
	defer store.close()
	if columns := tableColumnNames(t, store.db, "viewer_capabilities"); !columns["native_client_id"] {
		t.Fatalf("successful restart is missing native_client_id: %#v", columns)
	}
}

func TestSchemaMigrationRollsBackAndRestartsCleanly(t *testing.T) {
	root := t.TempDir()
	stateDir := filepath.Join(root, "state")
	attachments := filepath.Join(root, "attachments")
	if err := os.MkdirAll(stateDir, 0o700); err != nil {
		t.Fatal(err)
	}
	databasePath := filepath.Join(stateDir, databaseFileName)
	db, err := sql.Open("sqlite", databasePath)
	if err != nil {
		t.Fatal(err)
	}
	for _, statement := range []string{
		`CREATE TABLE commands (state TEXT NOT NULL, acknowledged_at TEXT)`,
		`INSERT INTO commands(state,acknowledged_at) VALUES('ok','2026-08-13T12:00:00Z')`,
		`CREATE TRIGGER reject_command_migration BEFORE UPDATE ON commands BEGIN SELECT RAISE(ABORT, 'stop migration'); END`,
		`PRAGMA user_version = 1`,
	} {
		if _, err := db.Exec(statement); err != nil {
			t.Fatal(err)
		}
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}

	if _, err := openSQLiteStore(stateDir, attachments, time.Now); err == nil || !strings.Contains(err.Error(), "stop migration") {
		t.Fatalf("failed migration error = %v, want injected failure", err)
	}
	db, err = sql.Open("sqlite", databasePath)
	if err != nil {
		t.Fatal(err)
	}
	columns := commandColumns(t, db)
	for _, column := range []string{"error_code", "resulting_revision", "completed_at"} {
		if columns[column] {
			t.Fatalf("failed migration left column %q behind", column)
		}
	}
	for _, table := range []string{"native_client_enrollments", "native_clients"} {
		var count int
		if err := db.QueryRow(`SELECT count(*) FROM sqlite_master WHERE type='table' AND name=?`, table).Scan(&count); err != nil || count != 0 {
			t.Fatalf("failed migration left table %q behind: count=%d err=%v", table, count, err)
		}
	}
	var version int
	if err := db.QueryRow(`PRAGMA user_version`).Scan(&version); err != nil || version != 1 {
		t.Fatalf("failed migration version = %d, %v; want 1", version, err)
	}
	if _, err := db.Exec(`DROP TRIGGER reject_command_migration`); err != nil {
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}

	store, err := openSQLiteStore(stateDir, attachments, time.Now)
	if err != nil {
		t.Fatalf("restart after failed migration: %v", err)
	}
	defer store.close()
	columns = commandColumns(t, store.db)
	for _, column := range []string{"error_code", "resulting_revision", "completed_at"} {
		if !columns[column] {
			t.Fatalf("successful restart is missing column %q", column)
		}
	}
}

func TestSchemaMigrationRepairsPartiallyAppliedVersionOne(t *testing.T) {
	root := t.TempDir()
	stateDir := filepath.Join(root, "state")
	attachments := filepath.Join(root, "attachments")
	if err := os.MkdirAll(stateDir, 0o700); err != nil {
		t.Fatal(err)
	}
	db, err := sql.Open("sqlite", filepath.Join(stateDir, databaseFileName))
	if err != nil {
		t.Fatal(err)
	}
	for _, statement := range []string{
		`CREATE TABLE commands (state TEXT NOT NULL, acknowledged_at TEXT, error_code TEXT NOT NULL DEFAULT '')`,
		`INSERT INTO commands(state,acknowledged_at) VALUES('ok','2026-08-13T12:00:00Z')`,
		`PRAGMA user_version = 1`,
	} {
		if _, err := db.Exec(statement); err != nil {
			t.Fatal(err)
		}
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}

	store, err := openSQLiteStore(stateDir, attachments, time.Now)
	if err != nil {
		t.Fatalf("repair partially applied migration: %v", err)
	}
	defer store.close()
	columns := commandColumns(t, store.db)
	for _, column := range []string{"error_code", "resulting_revision", "completed_at"} {
		if !columns[column] {
			t.Fatalf("repaired migration is missing column %q", column)
		}
	}
}

func TestSchemaMigrationRepairsVersionZeroCommandsTable(t *testing.T) {
	root := t.TempDir()
	stateDir := filepath.Join(root, "state")
	attachments := filepath.Join(root, "attachments")
	if err := os.MkdirAll(stateDir, 0o700); err != nil {
		t.Fatal(err)
	}
	db, err := sql.Open("sqlite", filepath.Join(stateDir, databaseFileName))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`CREATE TABLE commands (state TEXT NOT NULL, acknowledged_at TEXT)`); err != nil {
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}

	store, err := openSQLiteStore(stateDir, attachments, time.Now)
	if err != nil {
		t.Fatalf("repair version-zero commands table: %v", err)
	}
	defer store.close()
	columns := commandColumns(t, store.db)
	for _, column := range []string{"error_code", "resulting_revision", "completed_at"} {
		if !columns[column] {
			t.Fatalf("repaired version-zero schema is missing column %q", column)
		}
	}
}

func TestReadinessFailsClosedWhenSessionStorageIsUnavailable(t *testing.T) {
	h := newProductTestHandler(t, productTestConfig(t.TempDir()), time.Now)
	if err := h.store.close(); err != nil {
		t.Fatal(err)
	}
	response := doJSON(t, h, http.MethodGet, readinessPath, "", "", nil)
	if response.Code != http.StatusServiceUnavailable || !strings.Contains(response.Body.String(), `"code":"storage_unavailable"`) {
		t.Fatalf("readiness = %d %s", response.Code, response.Body.String())
	}
}

func TestProductRoutesRejectMissingAndWrongBearerTokens(t *testing.T) {
	h := newProductTestHandler(t, productTestConfig(t.TempDir()), time.Now)
	for _, token := range []string{"", "wrong"} {
		request := httptest.NewRequest(http.MethodGet, "http://ghostlight.test/v1/workspaces", nil)
		if token != "" {
			request.Header.Set("Authorization", "Bearer "+token)
		}
		response := httptest.NewRecorder()
		h.ServeHTTP(response, request)
		if response.Code != http.StatusUnauthorized {
			t.Fatalf("token %q status = %d, want 401", token, response.Code)
		}
	}
}

func TestSessionCreateIdempotencyEventsAndStrictJSON(t *testing.T) {
	h := newProductTestHandler(t, productTestConfig(t.TempDir()), time.Now)
	body := `{"workspace_id":"default"}`
	first := doJSON(t, h, http.MethodPost, "/v1/sessions", "create-1", "", strings.NewReader(body))
	if first.Code != http.StatusOK {
		t.Fatalf("first create = %d %s", first.Code, first.Body.String())
	}
	var created BrowserSession
	decodeRecorder(t, first, &created)
	second := doJSON(t, h, http.MethodPost, "/v1/sessions", "create-1", "", strings.NewReader(body))
	var duplicate BrowserSession
	decodeRecorder(t, second, &duplicate)
	if second.Code != http.StatusOK || duplicate.ID != created.ID {
		t.Fatalf("duplicate = %d %#v, first %#v", second.Code, duplicate, created)
	}
	unchanged := doJSON(t, h, http.MethodGet, fmt.Sprintf("/v1/sessions/%s/events?after_revision=%d", created.ID, created.Revision), "", "", nil)
	if unchanged.Code != http.StatusNoContent {
		t.Fatalf("unchanged events = %d %s", unchanged.Code, unchanged.Body.String())
	}
	started := time.Now()
	waited := doJSON(t, h, http.MethodGet, fmt.Sprintf("/v1/sessions/%s/events?after_revision=%d&wait_ms=75", created.ID, created.Revision), "", "", nil)
	if waited.Code != http.StatusNoContent || time.Since(started) < 50*time.Millisecond {
		t.Fatalf("waited events = %d after %s, want bounded wait", waited.Code, time.Since(started))
	}
	invalidWait := doJSON(t, h, http.MethodGet, fmt.Sprintf("/v1/sessions/%s/events?after_revision=%d&wait_ms=10001", created.ID, created.Revision), "", "", nil)
	if invalidWait.Code != http.StatusBadRequest {
		t.Fatalf("invalid wait = %d %s", invalidWait.Code, invalidWait.Body.String())
	}
	bad := doJSON(t, h, http.MethodPost, "/v1/sessions", "create-2", "", strings.NewReader(`{"workspace_id":"default","name":"x"}`))
	if bad.Code != http.StatusBadRequest {
		t.Fatalf("unknown JSON field = %d %s", bad.Code, bad.Body.String())
	}
}

func TestConcurrentLeaseExclusionExpiryAndFencing(t *testing.T) {
	now := time.Date(2026, 8, 13, 12, 0, 0, 0, time.UTC)
	var mu sync.Mutex
	clock := func() time.Time { mu.Lock(); defer mu.Unlock(); return now }
	h := newProductTestHandler(t, productTestConfig(t.TempDir()), clock)

	type result struct {
		code  int
		lease ControllerLease
	}
	results := make(chan result, 2)
	for _, client := range []string{"one", "two"} {
		go func() {
			r := doJSONNoT(h, http.MethodPost, "/v1/sessions/default/leases", "", "", strings.NewReader(fmt.Sprintf(`{"client_id":%q}`, client)))
			var lease ControllerLease
			_ = json.Unmarshal(r.Body.Bytes(), &lease)
			results <- result{r.Code, lease}
		}()
	}
	a, b := <-results, <-results
	if !((a.code == http.StatusCreated && b.code == http.StatusConflict) || (b.code == http.StatusCreated && a.code == http.StatusConflict)) {
		t.Fatalf("lease statuses = %d, %d", a.code, b.code)
	}
	winner := a.lease
	if b.code == http.StatusCreated {
		winner = b.lease
	}
	if winner.Token == "" || winner.Epoch != 1 {
		t.Fatalf("first lease = %#v", winner)
	}
	state, err := os.ReadFile(filepath.Join(h.config.StateDir, databaseFileName))
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(state, []byte(winner.Token)) {
		t.Fatal("lease token was persisted")
	}

	mu.Lock()
	now = now.Add(h.config.LeaseTTL + time.Second)
	mu.Unlock()
	takeover := doJSON(t, h, http.MethodPost, "/v1/sessions/default/leases", "", "", strings.NewReader(`{"client_id":"three"}`))
	var next ControllerLease
	decodeRecorder(t, takeover, &next)
	if takeover.Code != http.StatusCreated || next.Epoch != 2 {
		t.Fatalf("takeover = %d %#v", takeover.Code, next)
	}
	expired := doJSON(t, h, http.MethodPut, "/v1/sessions/default/leases/"+winner.ID, "", winner.Token, strings.NewReader(`{}`))
	if expired.Code != http.StatusUnauthorized && expired.Code != http.StatusConflict {
		t.Fatalf("expired renewal = %d %s", expired.Code, expired.Body.String())
	}
}

func TestExpiredLeaseCommandsAreFencedFromBridgeDelivery(t *testing.T) {
	now := time.Date(2026, 8, 13, 12, 0, 0, 0, time.UTC)
	var mu sync.Mutex
	clock := func() time.Time { mu.Lock(); defer mu.Unlock(); return now }
	h := newProductTestHandler(t, productTestConfig(t.TempDir()), clock)
	lease := acquireLease(t, h, "default")
	session, err := h.store.getSession(t.Context(), "default")
	if err != nil {
		t.Fatal(err)
	}
	command := BrowserCommand{Type: "navigate", URL: "https://example.test", ExpectedRevision: session.Revision}
	body, err := json.Marshal(command)
	if err != nil {
		t.Fatal(err)
	}
	digest := sha256.Sum256(body)
	queued, _, err := h.store.createCommand(t.Context(), "default", lease.Token, "old-controller", hex.EncodeToString(digest[:]), command)
	if err != nil {
		t.Fatal(err)
	}

	mu.Lock()
	now = now.Add(h.config.LeaseTTL + time.Second)
	mu.Unlock()
	if response := doJSON(t, h, http.MethodPost, "/v1/sessions/default/leases", "", "", strings.NewReader(`{"client_id":"new-controller"}`)); response.Code != http.StatusCreated {
		t.Fatalf("lease takeover = %d %s", response.Code, response.Body.String())
	}
	commands, err := h.store.listCommands(t.Context(), "default", 0, maxBridgeCommands)
	if err != nil {
		t.Fatal(err)
	}
	for _, command := range commands {
		if command.ID == queued.ID {
			t.Fatalf("stale command %s was delivered after lease takeover", queued.ID)
		}
	}
	receipt, err := h.store.getCommand(t.Context(), "default", queued.ID)
	if err != nil || receipt.State != "failed" || receipt.ErrorCode != "controller_lease_expired" || receipt.CompletedAt == nil || receipt.ResultingRevision == nil {
		t.Fatalf("stale command receipt = %#v, %v", receipt, err)
	}
}

func TestStreamRevisionAndAttachmentLeaseRevalidation(t *testing.T) {
	now := time.Date(2026, 8, 13, 12, 0, 0, 0, time.UTC)
	var mu sync.Mutex
	clock := func() time.Time { mu.Lock(); defer mu.Unlock(); return now }
	h := newProductTestHandler(t, productTestConfig(t.TempDir()), clock)
	lease := acquireLease(t, h, "default")
	before, err := h.store.getSession(t.Context(), "default")
	if err != nil {
		t.Fatal(err)
	}
	stream, err := h.store.createStream(t.Context(), "default", "test-client", "", h.viewerURL, defaultStreamTTL)
	if err != nil || stream.ID == "" {
		t.Fatalf("createStream() = %#v, %v", stream, err)
	}
	after, err := h.store.getSession(t.Context(), "default")
	if err != nil {
		t.Fatal(err)
	}
	if after.Revision != before.Revision+1 || after.Stream == nil || after.Stream.ID != stream.ID {
		t.Fatalf("stream session = %#v, before revision %d", after, before.Revision)
	}

	mu.Lock()
	now = now.Add(h.config.LeaseTTL + time.Second)
	mu.Unlock()
	attachment := Attachment{ID: "expired-upload", SessionID: "default", Filename: "report.pdf", ContentType: "application/pdf", Size: 4, Digest: "sha256:test", CreatedAt: now}
	if err := h.store.addAttachmentWithLease(t.Context(), attachment, lease.Token); !errors.Is(err, errLeaseExpired) {
		t.Fatalf("addAttachmentWithLease() error = %v, want expired lease", err)
	}
	if _, err := h.store.getAttachment(t.Context(), "default", attachment.ID); !errors.Is(err, errNotFound) {
		t.Fatalf("expired attachment lookup error = %v, want not found", err)
	}
}

func TestViewerCapabilityIsScopedSingleUseAndHashOnly(t *testing.T) {
	h := newProductTestHandler(t, productTestConfig(t.TempDir()), time.Now)
	stream, err := h.store.createStream(t.Context(), "default", "mac-client", "", h.viewerURL, defaultStreamTTL)
	if err != nil || stream.Capability == "" {
		t.Fatalf("createStream() = %#v, %v", stream, err)
	}
	var plaintextCount int
	if err := h.store.db.QueryRowContext(t.Context(), `SELECT count(*) FROM viewer_capabilities WHERE token_hash=?`, stream.Capability).Scan(&plaintextCount); err != nil || plaintextCount != 0 {
		t.Fatalf("plaintext capability persisted: count=%d err=%v", plaintextCount, err)
	}
	if _, err := h.store.redeemViewerCapability(t.Context(), stream.Capability, "wrong-client"); !errors.Is(err, errUnauthorized) {
		t.Fatalf("wrong client redemption error = %v", err)
	}
	if _, err := h.store.redeemViewerCapability(t.Context(), stream.Capability, "mac-client"); err != nil {
		t.Fatalf("first redemption error = %v", err)
	}
	if _, err := h.store.redeemViewerCapability(t.Context(), stream.Capability, "mac-client"); !errors.Is(err, errCapabilityUsed) {
		t.Fatalf("replay error = %v", err)
	}
}

func TestConcurrentViewerHandoffsKeepBothCapabilitiesRedeemable(t *testing.T) {
	h := newProductTestHandler(t, productTestConfig(t.TempDir()), time.Now)
	type handoff struct {
		client string
		stream StreamConnection
		err    error
	}
	results := make(chan handoff, 2)
	for _, client := range []string{"first-client", "second-client"} {
		go func() {
			stream, err := h.store.createStream(context.Background(), "default", client, "", h.viewerURL, defaultStreamTTL)
			results <- handoff{client: client, stream: stream, err: err}
		}()
	}
	first, second := <-results, <-results
	if first.err != nil || second.err != nil {
		t.Fatalf("concurrent handoffs = %v, %v", first.err, second.err)
	}
	if first.stream.Capability == second.stream.Capability {
		t.Fatal("concurrent handoffs reused a capability")
	}
	if _, err := h.store.redeemViewerCapability(t.Context(), first.stream.Capability, first.client); err != nil {
		t.Fatalf("first capability after second handoff: %v", err)
	}
	if _, err := h.store.redeemViewerCapability(t.Context(), second.stream.Capability, second.client); err != nil {
		t.Fatalf("second capability: %v", err)
	}
}

func TestNewHandoffRefreshesActiveStreamLifetimeWithoutChangingItsID(t *testing.T) {
	now := time.Date(2026, 8, 13, 12, 0, 0, 0, time.UTC)
	h := newProductTestHandler(t, productTestConfig(t.TempDir()), func() time.Time { return now })
	first, err := h.store.createStream(t.Context(), "default", "first-client", "", h.viewerURL, defaultStreamTTL)
	if err != nil {
		t.Fatal(err)
	}
	now = now.Add(defaultStreamTTL - time.Second)
	second, err := h.store.createStream(t.Context(), "default", "second-client", "", h.viewerURL, defaultStreamTTL)
	if err != nil {
		t.Fatal(err)
	}
	if second.ID != first.ID {
		t.Fatalf("active stream ID changed from %q to %q", first.ID, second.ID)
	}
	if got := second.ExpiresAt.Sub(now); got != defaultStreamTTL {
		t.Fatalf("refreshed stream lifetime = %s, want %s", got, defaultStreamTTL)
	}
	var capabilityExpiry string
	if err := h.store.db.QueryRow(`SELECT expires_at FROM viewer_capabilities WHERE token_hash=?`, hashSecret(second.Capability)).Scan(&capabilityExpiry); err != nil {
		t.Fatal(err)
	}
	expiresAt, err := parseTime(capabilityExpiry)
	if err != nil || expiresAt.Sub(now) != time.Minute {
		t.Fatalf("new capability lifetime = %s, %v; want 1m", expiresAt.Sub(now), err)
	}
}

func TestStreamCreationPreservesLegacyAndCapabilityAwareClients(t *testing.T) {
	h := newProductTestHandler(t, productTestConfig(t.TempDir()), time.Now)
	legacy := doJSON(t, h, http.MethodPost, "/v1/sessions/default/stream", "", "", nil)
	var legacyStream StreamConnection
	decodeRecorder(t, legacy, &legacyStream)
	if legacy.Code != http.StatusCreated || legacyStream.ID == "" || legacyStream.Capability != "" {
		t.Fatalf("legacy stream = %d %#v", legacy.Code, legacyStream)
	}

	modern := doJSON(t, h, http.MethodPost, "/v1/sessions/default/stream", "", "", strings.NewReader(`{"client_id":"modern-client"}`))
	var modernStream StreamConnection
	decodeRecorder(t, modern, &modernStream)
	if modern.Code != http.StatusCreated || modernStream.ID == "" || modernStream.Capability == "" {
		t.Fatalf("capability-aware stream = %d %#v", modern.Code, modernStream)
	}
	if modern.Header().Get("Cache-Control") != "no-store" {
		t.Fatalf("capability response Cache-Control = %q", modern.Header().Get("Cache-Control"))
	}
}

func TestViewerCapabilityRedeemsToNekoSessionCredentialWithoutPassword(t *testing.T) {
	cfg := productTestConfig(t.TempDir())
	var loginPayload struct {
		Username string `json:"username"`
		Password string `json:"password"`
	}
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if r.Method != http.MethodPost || r.URL.String() != "https://viewer.example.test/api/login" {
			t.Fatalf("Neko login request = %s %s", r.Method, r.URL.String())
		}
		if err := json.NewDecoder(r.Body).Decode(&loginPayload); err != nil {
			t.Fatal(err)
		}
		header := make(http.Header)
		header.Add("Set-Cookie", "NEKO_SESSION=neko-session-token; Path=/; HttpOnly; SameSite=Lax")
		return &http.Response{
			StatusCode: http.StatusOK,
			Header:     header,
			Body:       io.NopCloser(strings.NewReader(`{"id":"neko-session"}`)),
			Request:    r,
		}, nil
	})}
	h, err := newHandlerWithConfig(cfg, client, time.Now)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = h.store.close() })
	stream, err := h.store.createStream(t.Context(), "default", "mac-client", "", h.viewerURL, defaultStreamTTL)
	if err != nil {
		t.Fatal(err)
	}
	request := httptest.NewRequest(http.MethodPost, "http://ghostlight.test/v1/viewer-capabilities/redeem", strings.NewReader(`{"client_id":"mac-client"}`))
	request.Header.Set("Authorization", "Bearer "+stream.Capability)
	request.Header.Set("Content-Type", "application/json")
	response := httptest.NewRecorder()
	h.ServeHTTP(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("redeem = %d %s", response.Code, response.Body.String())
	}
	if response.Header().Get("Cache-Control") != "no-store" {
		t.Fatalf("redemption Cache-Control = %q", response.Header().Get("Cache-Control"))
	}
	if loginPayload.Password != cfg.ViewerPassword || !strings.HasPrefix(loginPayload.Username, "ghostlight-") {
		t.Fatalf("Neko login payload = %#v", loginPayload)
	}
	if strings.Contains(response.Body.String(), cfg.ViewerPassword) || strings.Contains(response.Body.String(), "viewer_password") {
		t.Fatalf("redemption exposed global viewer password: %s", response.Body.String())
	}
	var bootstrap struct {
		ViewerCredential struct {
			Type  string `json:"type"`
			Name  string `json:"name"`
			Value string `json:"value"`
		} `json:"viewer_credential"`
	}
	decodeRecorder(t, response, &bootstrap)
	if bootstrap.ViewerCredential.Type != "cookie" || bootstrap.ViewerCredential.Name != "NEKO_SESSION" || bootstrap.ViewerCredential.Value != "neko-session-token" {
		t.Fatalf("viewer credential = %#v", bootstrap.ViewerCredential)
	}
}

func TestViewerCapabilityCanRetryAfterViewerLoginFailure(t *testing.T) {
	h := newProductTestHandler(t, productTestConfig(t.TempDir()), time.Now)
	stream, err := h.store.createStream(t.Context(), "default", "mac-client", "", h.viewerURL, defaultStreamTTL)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := h.store.redeemViewerCapability(t.Context(), stream.Capability, "mac-client"); err != nil {
		t.Fatal(err)
	}
	if err := h.store.releaseViewerCapability(t.Context(), stream.Capability); err != nil {
		t.Fatal(err)
	}
	if _, err := h.store.redeemViewerCapability(t.Context(), stream.Capability, "mac-client"); err != nil {
		t.Fatalf("retry redemption after failed viewer login: %v", err)
	}
}

func TestExpiredLeaseTerminalizesQueuedReceiptWithoutTakeover(t *testing.T) {
	now := time.Date(2026, 8, 13, 12, 0, 0, 0, time.UTC)
	h := newProductTestHandler(t, productTestConfig(t.TempDir()), func() time.Time { return now })
	lease, err := h.store.acquireLease(t.Context(), "default", "mac-client", time.Second)
	if err != nil {
		t.Fatal(err)
	}
	session, err := h.store.getSession(t.Context(), "default")
	if err != nil {
		t.Fatal(err)
	}
	digest := sha256.Sum256([]byte(`{"type":"reload"}`))
	queued, _, err := h.store.createCommand(t.Context(), "default", lease.Token, "expiry-test", hex.EncodeToString(digest[:]), BrowserCommand{Type: "reload", ExpectedRevision: session.Revision})
	if err != nil {
		t.Fatal(err)
	}
	now = now.Add(2 * time.Second)
	receipts, err := h.store.recentCommandReceipts(t.Context(), "default", 10)
	if err != nil {
		t.Fatal(err)
	}
	for _, receipt := range receipts {
		if receipt.ID == queued.ID {
			if receipt.State != "failed" || receipt.ErrorCode != "lease_expired" || receipt.CompletedAt == nil {
				t.Fatalf("expired receipt = %#v", receipt)
			}
			return
		}
	}
	t.Fatal("expired queued receipt was not returned")
}

func TestWorkspacePreferencesPersistAndRejectUnsafeURLs(t *testing.T) {
	h := newProductTestHandler(t, productTestConfig(t.TempDir()), time.Now)
	initial := doJSON(t, h, http.MethodGet, "/v1/workspaces/default/preferences", "", "", nil)
	var preferences WorkspacePreferences
	decodeRecorder(t, initial, &preferences)
	if initial.Code != http.StatusOK || len(preferences.Shortcuts) == 0 || preferences.SearchURL == "" {
		t.Fatalf("initial preferences = %d %#v", initial.Code, preferences)
	}
	body := `{"search_url":"https://duckduckgo.com/?q={query}","shortcuts":[{"id":"docs","name":"Docs","url":"https://developer.apple.com","position":0}],"recent_urls":["https://example.test"]}`
	updated := doJSON(t, h, http.MethodPut, "/v1/workspaces/default/preferences", "", "", strings.NewReader(body))
	if updated.Code != http.StatusOK {
		t.Fatalf("put preferences = %d %s", updated.Code, updated.Body.String())
	}
	stored := doJSON(t, h, http.MethodGet, "/v1/workspaces/default/preferences", "", "", nil)
	decodeRecorder(t, stored, &preferences)
	if preferences.SearchURL != "https://duckduckgo.com/?q={query}" || len(preferences.Shortcuts) != 1 || preferences.Shortcuts[0].ID != "docs" {
		t.Fatalf("stored preferences = %#v", preferences)
	}
	unsafe := doJSON(t, h, http.MethodPut, "/v1/workspaces/default/preferences", "", "", strings.NewReader(`{"search_url":"javascript:{query}","shortcuts":[],"recent_urls":[]}`))
	if unsafe.Code != http.StatusBadRequest {
		t.Fatalf("unsafe preferences = %d %s", unsafe.Code, unsafe.Body.String())
	}
	for _, recent := range []string{
		"https://user:password@example.test/private",
		"https://example.test/callback?access_token=secret",
		"https://example.test/callback?code=authorization-code",
		"https://example.test/#token=secret",
	} {
		body := fmt.Sprintf(`{"search_url":"https://duckduckgo.com/?q={query}","shortcuts":[],"recent_urls":[%q]}`, recent)
		response := doJSON(t, h, http.MethodPut, "/v1/workspaces/default/preferences", "", "", strings.NewReader(body))
		if response.Code != http.StatusBadRequest {
			t.Fatalf("credential-bearing recent URL %q = %d %s", recent, response.Code, response.Body.String())
		}
	}
}

func TestAttachmentCountLimitFailsClosed(t *testing.T) {
	h := newProductTestHandler(t, productTestConfig(t.TempDir()), time.Now)
	lease := acquireLease(t, h, "default")
	for index := 0; index < maxSessionAttachments; index++ {
		id := fmt.Sprintf("existing-%03d", index)
		if _, err := h.store.db.Exec(`INSERT INTO attachments(id,session_id,filename,content_type,size,digest,created_at) VALUES(?,?,?,?,?,?,?)`, id, "default", "file.txt", "text/plain", 0, "sha256:test", formatTime(time.Now())); err != nil {
			t.Fatal(err)
		}
	}
	attachment := Attachment{ID: "over-limit", SessionID: "default", Filename: "report.pdf", ContentType: "application/pdf", Size: 4, Digest: "sha256:test", CreatedAt: time.Now()}
	if err := h.store.addAttachmentWithLease(t.Context(), attachment, lease.Token); !errors.Is(err, errStorageLimit) {
		t.Fatalf("addAttachmentWithLease() error = %v, want storage limit", err)
	}
}

func TestCommandsHeartbeatAndBridgeAuthentication(t *testing.T) {
	h := newProductTestHandler(t, productTestConfig(t.TempDir()), time.Now)
	bootstrap := doJSON(t, h, http.MethodGet, "/v1/bridge/bootstrap", "", h.config.BridgeToken, nil)
	if bootstrap.Code != http.StatusOK || bootstrap.Body.String() != "{\"session_id\":\"default\"}\n" {
		t.Fatalf("bridge bootstrap = %d %s", bootstrap.Code, bootstrap.Body.String())
	}
	leaseResponse := doJSON(t, h, http.MethodPost, "/v1/sessions/default/leases", "", "", strings.NewReader(`{"client_id":"mac"}`))
	var lease ControllerLease
	decodeRecorder(t, leaseResponse, &lease)
	if leaseResponse.Code != http.StatusCreated || lease.Token == "" {
		t.Fatalf("lease = %d %#v", leaseResponse.Code, lease)
	}
	tx, err := h.store.db.BeginTx(t.Context(), nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := h.store.findLeaseByTokenTx(t.Context(), tx, "default", lease.Token); err != nil {
		_ = tx.Rollback()
		t.Fatalf("new lease token was not immediately valid: %v", err)
	}
	_ = tx.Rollback()

	unauthenticated := doJSON(t, h, http.MethodPost, "/v1/bridge/heartbeat", "", "wrong", strings.NewReader(`{"session_id":"default","tabs":[],"runtime_state":"ready"}`))
	if unauthenticated.Code != http.StatusUnauthorized {
		t.Fatalf("unauthenticated heartbeat = %d", unauthenticated.Code)
	}
	heartbeat := doJSON(t, h, http.MethodPost, "/v1/bridge/heartbeat", "", h.config.BridgeToken, strings.NewReader(`{"session_id":"default","sequence":4,"agent_version":"0.1.0","tabs":[{"id":"tab-1","title":"Example","url":"https://example.test","favicon_url":"https://example.test/icon.png","active":true,"loading":true,"audible":false,"discarded":false,"window_id":2,"index":4}],"active_tab_id":"tab-1","runtime_state":"ready"}`))
	if heartbeat.Code != http.StatusOK {
		t.Fatalf("heartbeat = %d %s", heartbeat.Code, heartbeat.Body.String())
	}
	var session BrowserSession
	decodeRecorder(t, heartbeat, &session)
	if len(session.Tabs) != 1 || session.ActiveTabID != "tab-1" || session.RuntimeState != "ready" || !session.Tabs[0].Active || !session.Tabs[0].Loading || session.Tabs[0].WindowID != 2 || session.Tabs[0].Index != 4 {
		t.Fatalf("heartbeat session = %#v", session)
	}
	repeatedHeartbeat := doJSON(t, h, http.MethodPost, "/v1/bridge/heartbeat", "", h.config.BridgeToken, strings.NewReader(`{"session_id":"default","sequence":5,"agent_version":"0.1.0","tabs":[{"id":"tab-1","title":"Example","url":"https://example.test","favicon_url":"https://example.test/icon.png","active":true,"loading":true,"audible":false,"discarded":false,"window_id":2,"index":4}],"active_tab_id":"tab-1","runtime_state":"ready"}`))
	var unchanged BrowserSession
	decodeRecorder(t, repeatedHeartbeat, &unchanged)
	if unchanged.Revision != session.Revision {
		t.Fatalf("unchanged heartbeat revision = %d, want %d", unchanged.Revision, session.Revision)
	}
	tx, err = h.store.db.BeginTx(t.Context(), nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := h.store.findLeaseByTokenTx(t.Context(), tx, "default", lease.Token); err != nil {
		_ = tx.Rollback()
		t.Fatalf("heartbeat invalidated lease token: %v", err)
	}
	_ = tx.Rollback()

	commandBody := fmt.Sprintf(`{"type":"navigate","url":"https://openai.com","expected_revision":%d}`, session.Revision)
	command := doJSON(t, h, http.MethodPost, "/v1/sessions/default/commands", "cmd-1", lease.Token, strings.NewReader(commandBody))
	if command.Code != http.StatusAccepted {
		t.Fatalf("command = %d %s", command.Code, command.Body.String())
	}
	var queued BrowserCommand
	decodeRecorder(t, command, &queued)
	duplicate := doJSON(t, h, http.MethodPost, "/v1/sessions/default/commands", "cmd-1", lease.Token, strings.NewReader(commandBody))
	var same BrowserCommand
	decodeRecorder(t, duplicate, &same)
	if duplicate.Code != http.StatusOK || same.ID != queued.ID {
		t.Fatalf("duplicate command = %d %#v", duplicate.Code, same)
	}
	stale := doJSON(t, h, http.MethodPost, "/v1/sessions/default/commands", "cmd-2", lease.Token, strings.NewReader(commandBody))
	if stale.Code != http.StatusConflict {
		t.Fatalf("stale command = %d %s", stale.Code, stale.Body.String())
	}
	listed := doJSON(t, h, http.MethodGet, "/v1/bridge/commands?session_id=default&after=0", "", h.config.BridgeToken, nil)
	if listed.Code != http.StatusOK || !strings.Contains(listed.Body.String(), queued.ID) {
		t.Fatalf("bridge commands = %d %s", listed.Code, listed.Body.String())
	}
	acked := doJSON(t, h, http.MethodPost, "/v1/bridge/commands/"+queued.ID+"/ack", "", h.config.BridgeToken, strings.NewReader(`{"status":"ok","result":{"tab_id":17}}`))
	if acked.Code != http.StatusOK {
		t.Fatalf("ack = %d %s", acked.Code, acked.Body.String())
	}
	status := doJSON(t, h, http.MethodGet, "/v1/sessions/default/commands/"+queued.ID, "", "", nil)
	var completed BrowserCommand
	decodeRecorder(t, status, &completed)
	if status.Code != http.StatusOK || completed.State != "applied" || string(completed.Result) != `{"tab_id":17}` || completed.AcknowledgedAt == nil || completed.CompletedAt == nil || completed.ResultingRevision == nil {
		t.Fatalf("command status = %d %#v", status.Code, completed)
	}
	terminalRevision := *completed.ResultingRevision
	repeated := doJSON(t, h, http.MethodPost, "/v1/bridge/commands/"+queued.ID+"/ack", "", h.config.BridgeToken, strings.NewReader(`{"status":"ok","result":{"tab_id":17}}`))
	if repeated.Code != http.StatusOK {
		t.Fatalf("repeated ack = %d %s", repeated.Code, repeated.Body.String())
	}
	var repeatedReceipt BrowserCommand
	decodeRecorder(t, repeated, &repeatedReceipt)
	if repeatedReceipt.ResultingRevision == nil || *repeatedReceipt.ResultingRevision != terminalRevision {
		t.Fatalf("repeated ack changed terminal revision: %#v", repeatedReceipt)
	}
}

func TestStoreCommandAcceptsLeaseAfterHeartbeat(t *testing.T) {
	h := newProductTestHandler(t, productTestConfig(t.TempDir()), time.Now)
	lease := acquireLease(t, h, "default")
	session, err := h.store.heartbeat(t.Context(), "default", "ready", "", []BrowserTab{})
	if err != nil {
		t.Fatal(err)
	}
	command := BrowserCommand{Type: "navigate", URL: "https://example.test", ExpectedRevision: session.Revision}
	body, err := json.Marshal(command)
	if err != nil {
		t.Fatal(err)
	}
	digest := sha256.Sum256(body)
	if _, _, err := h.store.createCommand(t.Context(), "default", lease.Token, "direct", hex.EncodeToString(digest[:]), command); err != nil {
		t.Fatalf("createCommand() error = %v", err)
	}
}

func TestNativeClientEnrollmentHappyPathAndPrincipalBoundary(t *testing.T) {
	now := time.Date(2026, 8, 13, 12, 0, 0, 0, time.UTC)
	h := newProductTestHandler(t, productTestConfig(t.TempDir()), func() time.Time { return now })

	issued := doBearerRequest(h, http.MethodPost, "/v1/native-client-enrollments", h.config.APIToken, strings.NewReader(`{"client_name":"Jonathan's Mac"}`))
	if issued.Code != http.StatusCreated {
		t.Fatalf("issue = %d %s", issued.Code, issued.Body.String())
	}
	var enrollment struct {
		PairingCapability string    `json:"pairing_capability"`
		ClientName        string    `json:"client_name"`
		ExpiresAt         time.Time `json:"expires_at"`
	}
	decodeRecorder(t, issued, &enrollment)
	if len(enrollment.PairingCapability) < 40 || enrollment.ClientName != "Jonathan's Mac" || enrollment.ExpiresAt.Sub(now) != 10*time.Minute {
		t.Fatalf("enrollment = %#v", enrollment)
	}
	if strings.Contains(issued.Body.String(), "client_token") || strings.Contains(issued.Body.String(), "token_hash") {
		t.Fatalf("issuance exposed non-pairing secret material: %s", issued.Body.String())
	}

	redeemed := doBearerRequest(h, http.MethodPost, "/v1/native-client-enrollments/redeem", enrollment.PairingCapability, strings.NewReader(`{"client_name":"Jonathan's Mac"}`))
	if redeemed.Code != http.StatusCreated {
		t.Fatalf("redeem = %d %s", redeemed.Code, redeemed.Body.String())
	}
	var credential struct {
		Client struct {
			ID    string `json:"id"`
			Name  string `json:"name"`
			Scope string `json:"scope"`
		} `json:"client"`
		ClientToken string `json:"client_token"`
	}
	decodeRecorder(t, redeemed, &credential)
	if len(credential.Client.ID) < 16 || credential.Client.Name != "Jonathan's Mac" || credential.Client.Scope != "browser:use" || !strings.HasPrefix(credential.ClientToken, "glnc_") || len(credential.ClientToken) < 40 {
		t.Fatalf("credential = %#v", credential)
	}
	if strings.Contains(redeemed.Body.String(), enrollment.PairingCapability) || strings.Contains(redeemed.Body.String(), "pairing_capability") || strings.Contains(redeemed.Body.String(), "token_hash") {
		t.Fatalf("redemption repeated or exposed secret material: %s", redeemed.Body.String())
	}

	sessions := doBearerRequest(h, http.MethodGet, "/v1/sessions", credential.ClientToken, nil)
	if sessions.Code != http.StatusOK {
		t.Fatalf("native product API = %d %s", sessions.Code, sessions.Body.String())
	}
	lease := doBearerRequest(h, http.MethodPost, "/v1/sessions/default/leases", credential.ClientToken, strings.NewReader(`{"client_id":"native-mac"}`))
	if lease.Code != http.StatusCreated {
		t.Fatalf("native product mutation = %d %s", lease.Code, lease.Body.String())
	}
	operatorOnly := doBearerRequest(h, http.MethodPost, "/v1/native-client-enrollments", credential.ClientToken, strings.NewReader(`{"client_name":"Escalated"}`))
	if operatorOnly.Code != http.StatusForbidden || !strings.Contains(operatorOnly.Body.String(), "scope_denied") {
		t.Fatalf("native operator API = %d %s", operatorOnly.Code, operatorOnly.Body.String())
	}
	bridge := doBearerRequest(h, http.MethodGet, "/v1/bridge/bootstrap", credential.ClientToken, nil)
	if bridge.Code != http.StatusUnauthorized {
		t.Fatalf("native bridge API = %d %s", bridge.Code, bridge.Body.String())
	}
	chrome := doBearerRequest(h, http.MethodPost, "/v1/chrome-handoffs", credential.ClientToken, strings.NewReader(`{"title":"Page","url":"https://example.test"}`))
	if chrome.Code != http.StatusUnauthorized {
		t.Fatalf("native Chrome API = %d %s", chrome.Code, chrome.Body.String())
	}
}

func TestNativeClientEnrollmentExpiresAndRejectsReplayAndWrongClient(t *testing.T) {
	now := time.Date(2026, 8, 13, 12, 0, 0, 0, time.UTC)
	h := newProductTestHandler(t, productTestConfig(t.TempDir()), func() time.Time { return now })

	issue := func(name string) string {
		t.Helper()
		response := doBearerRequest(h, http.MethodPost, "/v1/native-client-enrollments", h.config.APIToken, strings.NewReader(fmt.Sprintf(`{"client_name":%q}`, name)))
		var enrollment struct {
			PairingCapability string `json:"pairing_capability"`
		}
		decodeRecorder(t, response, &enrollment)
		if response.Code != http.StatusCreated || enrollment.PairingCapability == "" {
			t.Fatalf("issue %q = %d %s", name, response.Code, response.Body.String())
		}
		return enrollment.PairingCapability
	}

	capability := issue("Bound Mac")
	missing := doBearerRequest(h, http.MethodPost, "/v1/native-client-enrollments/redeem", "", strings.NewReader(`{"client_name":"Bound Mac"}`))
	if missing.Code != http.StatusUnauthorized || !strings.Contains(missing.Body.String(), "enrollment_invalid") {
		t.Fatalf("missing capability = %d %s", missing.Code, missing.Body.String())
	}
	wrong := doBearerRequest(h, http.MethodPost, "/v1/native-client-enrollments/redeem", capability, strings.NewReader(`{"client_name":"Other Mac"}`))
	if wrong.Code != http.StatusUnauthorized || !strings.Contains(wrong.Body.String(), "enrollment_invalid") {
		t.Fatalf("wrong client = %d %s", wrong.Code, wrong.Body.String())
	}
	correct := doBearerRequest(h, http.MethodPost, "/v1/native-client-enrollments/redeem", capability, strings.NewReader(`{"client_name":"Bound Mac"}`))
	if correct.Code != http.StatusCreated {
		t.Fatalf("correct client after mismatch = %d %s", correct.Code, correct.Body.String())
	}
	replay := doBearerRequest(h, http.MethodPost, "/v1/native-client-enrollments/redeem", capability, strings.NewReader(`{"client_name":"Bound Mac"}`))
	if replay.Code != http.StatusConflict || !strings.Contains(replay.Body.String(), "enrollment_used") {
		t.Fatalf("replay = %d %s", replay.Code, replay.Body.String())
	}

	expiredCapability := issue("Expired Mac")
	now = now.Add(10 * time.Minute)
	expired := doBearerRequest(h, http.MethodPost, "/v1/native-client-enrollments/redeem", expiredCapability, strings.NewReader(`{"client_name":"Expired Mac"}`))
	if expired.Code != http.StatusUnauthorized || !strings.Contains(expired.Body.String(), "enrollment_expired") {
		t.Fatalf("expired = %d %s", expired.Code, expired.Body.String())
	}
}

func TestConcurrentNativeClientEnrollmentRedeemsOnlyOnce(t *testing.T) {
	h := newProductTestHandler(t, productTestConfig(t.TempDir()), time.Now)
	issued := doBearerRequest(h, http.MethodPost, "/v1/native-client-enrollments", h.config.APIToken, strings.NewReader(`{"client_name":"Concurrent Mac"}`))
	var enrollment struct {
		PairingCapability string `json:"pairing_capability"`
	}
	decodeRecorder(t, issued, &enrollment)

	start := make(chan struct{})
	results := make(chan *httptest.ResponseRecorder, 2)
	for range 2 {
		go func() {
			<-start
			results <- doBearerRequest(h, http.MethodPost, "/v1/native-client-enrollments/redeem", enrollment.PairingCapability, strings.NewReader(`{"client_name":"Concurrent Mac"}`))
		}()
	}
	close(start)
	statuses := map[int]int{}
	for range 2 {
		response := <-results
		statuses[response.Code]++
		if response.Code == http.StatusConflict && !strings.Contains(response.Body.String(), "enrollment_used") {
			t.Fatalf("losing redemption = %d %s", response.Code, response.Body.String())
		}
	}
	if statuses[http.StatusCreated] != 1 || statuses[http.StatusConflict] != 1 {
		t.Fatalf("concurrent redemption statuses = %#v", statuses)
	}
}

func TestNativeClientRevocationScopeDenialAndReEnrollment(t *testing.T) {
	h := newProductTestHandler(t, productTestConfig(t.TempDir()), time.Now)
	first := enrollNativeClient(t, h, "Daily Driver")

	if _, err := h.store.db.Exec(`UPDATE native_clients SET scope='browser:read' WHERE id=?`, first.Client.ID); err != nil {
		t.Fatal(err)
	}
	denied := doBearerRequest(h, http.MethodGet, "/v1/sessions", first.ClientToken, nil)
	if denied.Code != http.StatusForbidden || !strings.Contains(denied.Body.String(), "scope_denied") {
		t.Fatalf("wrong scope = %d %s", denied.Code, denied.Body.String())
	}
	if _, err := h.store.db.Exec(`UPDATE native_clients SET scope='browser:use' WHERE id=?`, first.Client.ID); err != nil {
		t.Fatal(err)
	}

	revoked := doBearerRequest(h, http.MethodDelete, "/v1/native-clients/"+first.Client.ID, h.config.APIToken, nil)
	if revoked.Code != http.StatusNoContent {
		t.Fatalf("revoke = %d %s", revoked.Code, revoked.Body.String())
	}
	afterRevoke := doBearerRequest(h, http.MethodGet, "/v1/sessions", first.ClientToken, nil)
	if afterRevoke.Code != http.StatusUnauthorized {
		t.Fatalf("after revoke = %d %s", afterRevoke.Code, afterRevoke.Body.String())
	}

	second := enrollNativeClient(t, h, "Daily Driver")
	if second.Client.ID != first.Client.ID || second.ClientToken == first.ClientToken {
		t.Fatalf("re-enrollment = %#v after %#v", second, first)
	}
	if response := doBearerRequest(h, http.MethodGet, "/v1/sessions", second.ClientToken, nil); response.Code != http.StatusOK {
		t.Fatalf("re-enrolled client = %d %s", response.Code, response.Body.String())
	}
}

func TestNativeClientAuthenticationReportsStorageFailure(t *testing.T) {
	h := newProductTestHandler(t, productTestConfig(t.TempDir()), time.Now)
	credential := enrollNativeClient(t, h, "Storage Failure Mac")
	if err := h.store.close(); err != nil {
		t.Fatal(err)
	}
	nonNative := doBearerRequest(h, http.MethodGet, "/v1/sessions", "arbitrary-bearer", nil)
	if nonNative.Code != http.StatusUnauthorized {
		t.Fatalf("non-native bearer with unavailable store = %d %s", nonNative.Code, nonNative.Body.String())
	}
	response := doBearerRequest(h, http.MethodGet, "/v1/sessions", credential.ClientToken, nil)
	if response.Code != http.StatusInternalServerError || !strings.Contains(response.Body.String(), "internal_error") {
		t.Fatalf("storage failure = %d %s", response.Code, response.Body.String())
	}
}

func TestNativeClientAuthenticationThrottlesLastSeenWrites(t *testing.T) {
	now := time.Date(2026, 8, 13, 12, 0, 0, 0, time.UTC)
	h := newProductTestHandler(t, productTestConfig(t.TempDir()), func() time.Time { return now })
	credential := enrollNativeClient(t, h, "Polling Mac")
	for _, statement := range []string{
		`CREATE TABLE native_client_last_seen_writes (count INTEGER NOT NULL)`,
		`INSERT INTO native_client_last_seen_writes(count) VALUES(0)`,
		`CREATE TRIGGER count_native_client_last_seen AFTER UPDATE OF last_seen_at ON native_clients BEGIN UPDATE native_client_last_seen_writes SET count=count+1; END`,
	} {
		if _, err := h.store.db.Exec(statement); err != nil {
			t.Fatal(err)
		}
	}
	for range 2 {
		if response := doBearerRequest(h, http.MethodGet, "/v1/sessions", credential.ClientToken, nil); response.Code != http.StatusOK {
			t.Fatalf("poll authentication = %d %s", response.Code, response.Body.String())
		}
	}
	var writes int
	if err := h.store.db.QueryRow(`SELECT count FROM native_client_last_seen_writes`).Scan(&writes); err != nil || writes != 0 {
		t.Fatalf("poll last_seen writes = %d, %v; want 0", writes, err)
	}
	now = now.Add(time.Minute)
	for range 2 {
		if response := doBearerRequest(h, http.MethodGet, "/v1/sessions", credential.ClientToken, nil); response.Code != http.StatusOK {
			t.Fatalf("cadence authentication = %d %s", response.Code, response.Body.String())
		}
	}
	if err := h.store.db.QueryRow(`SELECT count FROM native_client_last_seen_writes`).Scan(&writes); err != nil || writes != 1 {
		t.Fatalf("cadence last_seen writes = %d, %v; want 1", writes, err)
	}
}

func TestNativeClientAuthenticationFailsClosedWhenRevokedDuringAcceptance(t *testing.T) {
	now := time.Date(2026, 8, 13, 12, 0, 0, 0, time.UTC)
	h := newProductTestHandler(t, productTestConfig(t.TempDir()), func() time.Time { return now })
	credential := enrollNativeClient(t, h, "Revoked During Auth Mac")
	if _, err := h.store.db.Exec(fmt.Sprintf(`CREATE TRIGGER revoke_during_native_auth BEFORE UPDATE OF last_seen_at ON native_clients WHEN OLD.id=%q BEGIN UPDATE native_clients SET revoked_at='2026-08-13T12:00:30Z' WHERE id=OLD.id; END`, credential.Client.ID)); err != nil {
		t.Fatal(err)
	}
	now = now.Add(time.Minute)
	response := doBearerRequest(h, http.MethodGet, "/v1/sessions", credential.ClientToken, nil)
	if response.Code != http.StatusUnauthorized {
		t.Fatalf("revoked during authentication = %d %s", response.Code, response.Body.String())
	}
}

func TestNativeClientSelfRevocation(t *testing.T) {
	h := newProductTestHandler(t, productTestConfig(t.TempDir()), time.Now)
	credential := enrollNativeClient(t, h, "Forgettable Mac")
	operator := doBearerRequest(h, http.MethodDelete, "/v1/native-client", h.config.APIToken, nil)
	if operator.Code != http.StatusForbidden {
		t.Fatalf("operator self-revoke = %d %s", operator.Code, operator.Body.String())
	}
	wrongMethod := doBearerRequest(h, http.MethodPost, "/v1/native-client", credential.ClientToken, nil)
	if wrongMethod.Code != http.StatusMethodNotAllowed || wrongMethod.Header().Get("Allow") != http.MethodDelete {
		t.Fatalf("self-revoke wrong method = %d Allow=%q %s", wrongMethod.Code, wrongMethod.Header().Get("Allow"), wrongMethod.Body.String())
	}
	revoked := doBearerRequest(h, http.MethodDelete, "/v1/native-client", credential.ClientToken, nil)
	if revoked.Code != http.StatusNoContent {
		t.Fatalf("self-revoke = %d %s", revoked.Code, revoked.Body.String())
	}
	if response := doBearerRequest(h, http.MethodGet, "/v1/sessions", credential.ClientToken, nil); response.Code != http.StatusUnauthorized {
		t.Fatalf("self-revoked client authentication = %d %s", response.Code, response.Body.String())
	}
}

func TestNativeViewerCapabilityIsBoundToRevocablePrincipal(t *testing.T) {
	h := newProductTestHandler(t, productTestConfig(t.TempDir()), time.Now)
	credential := enrollNativeClient(t, h, "Streaming Mac")
	nativeResponse := doBearerRequest(h, http.MethodPost, "/v1/sessions/default/stream", credential.ClientToken, strings.NewReader(`{"client_id":"native-viewer"}`))
	var nativeStream StreamConnection
	decodeRecorder(t, nativeResponse, &nativeStream)
	if nativeResponse.Code != http.StatusCreated || nativeStream.Capability == "" {
		t.Fatalf("native stream = %d %#v %s", nativeResponse.Code, nativeStream, nativeResponse.Body.String())
	}
	var nativeClientID sql.NullString
	if err := h.store.db.QueryRow(`SELECT native_client_id FROM viewer_capabilities WHERE token_hash=?`, hashSecret(nativeStream.Capability)).Scan(&nativeClientID); err != nil || nativeClientID.String != credential.Client.ID {
		t.Fatalf("native capability binding = %#v, %v; want %q", nativeClientID, err, credential.Client.ID)
	}
	if _, err := h.store.redeemViewerCapability(t.Context(), nativeStream.Capability, "native-viewer"); err != nil {
		t.Fatalf("active native capability redemption: %v", err)
	}
	if err := h.store.releaseViewerCapability(t.Context(), nativeStream.Capability); err != nil {
		t.Fatalf("release active native capability: %v", err)
	}
	if response := doBearerRequest(h, http.MethodDelete, "/v1/native-clients/"+credential.Client.ID, h.config.APIToken, nil); response.Code != http.StatusNoContent {
		t.Fatalf("operator revoke = %d %s", response.Code, response.Body.String())
	}
	revokedRedemption := doBearerRequest(h, http.MethodPost, "/v1/viewer-capabilities/redeem", nativeStream.Capability, strings.NewReader(`{"client_id":"native-viewer"}`))
	if revokedRedemption.Code != http.StatusUnauthorized || !strings.Contains(revokedRedemption.Body.String(), "viewer_capability_invalid") {
		t.Fatalf("revoked native capability redemption = %d %s", revokedRedemption.Code, revokedRedemption.Body.String())
	}

	operatorResponse := doBearerRequest(h, http.MethodPost, "/v1/sessions/default/stream", h.config.APIToken, strings.NewReader(`{"client_id":"operator-viewer"}`))
	var operatorStream StreamConnection
	decodeRecorder(t, operatorResponse, &operatorStream)
	if operatorResponse.Code != http.StatusCreated || operatorStream.Capability == "" {
		t.Fatalf("operator stream = %d %#v %s", operatorResponse.Code, operatorStream, operatorResponse.Body.String())
	}
	if err := h.store.db.QueryRow(`SELECT native_client_id FROM viewer_capabilities WHERE token_hash=?`, hashSecret(operatorStream.Capability)).Scan(&nativeClientID); err != nil || nativeClientID.Valid {
		t.Fatalf("operator capability binding = %#v, %v; want NULL", nativeClientID, err)
	}
	if _, err := h.store.redeemViewerCapability(t.Context(), operatorStream.Capability, "operator-viewer"); err != nil {
		t.Fatalf("operator capability redemption: %v", err)
	}
}

func TestNativeClientSecretsAreHashStoredAndReturnedOnlyOnce(t *testing.T) {
	h := newProductTestHandler(t, productTestConfig(t.TempDir()), time.Now)
	issued := doBearerRequest(h, http.MethodPost, "/v1/native-client-enrollments", h.config.APIToken, strings.NewReader(`{"client_name":"Secretless Mac"}`))
	var enrollment struct {
		PairingCapability string `json:"pairing_capability"`
	}
	decodeRecorder(t, issued, &enrollment)
	credential := redeemNativeClient(t, h, enrollment.PairingCapability, "Secretless Mac")

	var enrollmentHash, credentialHash string
	if err := h.store.db.QueryRow(`SELECT token_hash FROM native_client_enrollments`).Scan(&enrollmentHash); err != nil {
		t.Fatal(err)
	}
	if err := h.store.db.QueryRow(`SELECT token_hash FROM native_clients WHERE id=?`, credential.Client.ID).Scan(&credentialHash); err != nil {
		t.Fatal(err)
	}
	if enrollmentHash == enrollment.PairingCapability || credentialHash == credential.ClientToken || enrollmentHash != hashSecret(enrollment.PairingCapability) || credentialHash != hashSecret(credential.ClientToken) {
		t.Fatalf("stored hashes = %q %q", enrollmentHash, credentialHash)
	}
	listed := doBearerRequest(h, http.MethodGet, "/v1/native-clients", h.config.APIToken, nil)
	if listed.Code != http.StatusOK || strings.Contains(listed.Body.String(), enrollment.PairingCapability) || strings.Contains(listed.Body.String(), credential.ClientToken) || strings.Contains(listed.Body.String(), "token_hash") {
		t.Fatalf("client listing exposed secret = %d %s", listed.Code, listed.Body.String())
	}
	databasePath := filepath.Join(h.config.StateDir, databaseFileName)
	for _, path := range []string{databasePath, databasePath + "-wal", databasePath + "-shm"} {
		database, err := os.ReadFile(path)
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			t.Fatal(err)
		}
		if bytes.Contains(database, []byte(enrollment.PairingCapability)) || bytes.Contains(database, []byte(credential.ClientToken)) {
			t.Fatalf("native enrollment or client bearer secret was persisted in plaintext at %s", path)
		}
	}
}

func TestGlobalAPITokenRemainsCompatibleWithNativeClientEnrollment(t *testing.T) {
	h := newProductTestHandler(t, productTestConfig(t.TempDir()), time.Now)
	for _, path := range []string{"/v1/workspaces", "/v1/sessions"} {
		response := doBearerRequest(h, http.MethodGet, path, h.config.APIToken, nil)
		if response.Code != http.StatusOK {
			t.Fatalf("global token %s = %d %s", path, response.Code, response.Body.String())
		}
	}
	issued := doBearerRequest(h, http.MethodPost, "/v1/native-client-enrollments", h.config.APIToken, strings.NewReader(`{"client_name":"Compatibility Mac"}`))
	if issued.Code != http.StatusCreated {
		t.Fatalf("global token enrollment = %d %s", issued.Code, issued.Body.String())
	}
	wrong := doBearerRequest(h, http.MethodPost, "/v1/native-client-enrollments", "wrong", strings.NewReader(`{"client_name":"Denied Mac"}`))
	if wrong.Code != http.StatusUnauthorized {
		t.Fatalf("wrong operator token = %d %s", wrong.Code, wrong.Body.String())
	}
}

func TestChromeHandoffPairingConsentSafetyAndRevocation(t *testing.T) {
	clock := func() time.Time { return time.Date(2026, 8, 13, 12, 0, 0, 0, time.UTC) }
	h := newProductTestHandler(t, productTestConfig(t.TempDir()), clock)

	pairingResponse := doJSON(t, h, http.MethodPost, "/v1/workspaces/default/chrome-pairings", "", "", strings.NewReader(`{"device_name":"Jonathan's Chrome"}`))
	if pairingResponse.Code != http.StatusCreated {
		t.Fatalf("pairing = %d %s", pairingResponse.Code, pairingResponse.Body.String())
	}
	var pairing ChromePairing
	decodeRecorder(t, pairingResponse, &pairing)
	if len(pairing.PairingCode) < 40 || pairing.ExpiresAt.Sub(clock()) != chromePairingTTL {
		t.Fatalf("pairing = %#v", pairing)
	}

	redeemBody := fmt.Sprintf(`{"pairing_code":%q,"device_id":"chrome-device-1234","device_name":"Jonathan's Chrome"}`, pairing.PairingCode)
	redeemed := doChromeRequest(h, http.MethodPost, "/v1/chrome-pairings/redeem", "", "", strings.NewReader(redeemBody))
	if redeemed.Code != http.StatusCreated {
		t.Fatalf("redeem = %d %s", redeemed.Code, redeemed.Body.String())
	}
	var credential ChromeDeviceCredential
	decodeRecorder(t, redeemed, &credential)
	if credential.Device.Scope != chromeDeviceScope || len(credential.DeviceToken) < 40 {
		t.Fatalf("credential = %#v", credential)
	}

	reused := doChromeRequest(h, http.MethodPost, "/v1/chrome-pairings/redeem", "", "", strings.NewReader(redeemBody))
	if reused.Code != http.StatusConflict {
		t.Fatalf("reused pairing = %d %s", reused.Code, reused.Body.String())
	}

	safeBody := `{"title":"A useful page","url":"https://example.test/work?q=ghostlight"}`
	created := doChromeRequest(h, http.MethodPost, "/v1/chrome-handoffs", credential.DeviceToken, "handoff-1", strings.NewReader(safeBody))
	if created.Code != http.StatusCreated {
		t.Fatalf("handoff = %d %s", created.Code, created.Body.String())
	}
	var handoff ChromeHandoff
	decodeRecorder(t, created, &handoff)
	if handoff.State != "pending" || handoff.DeviceName != "Jonathan's Chrome" {
		t.Fatalf("handoff = %#v", handoff)
	}

	retried := doChromeRequest(h, http.MethodPost, "/v1/chrome-handoffs", credential.DeviceToken, "handoff-1", strings.NewReader(safeBody))
	var retry ChromeHandoff
	decodeRecorder(t, retried, &retry)
	if retried.Code != http.StatusCreated || retry.ID != handoff.ID {
		t.Fatalf("retry = %d %#v", retried.Code, retry)
	}

	unsafe := doChromeRequest(h, http.MethodPost, "/v1/chrome-handoffs", credential.DeviceToken, "handoff-2", strings.NewReader(`{"title":"Callback","url":"https://example.test/callback?access_token=secret"}`))
	if unsafe.Code != http.StatusBadRequest {
		t.Fatalf("unsafe = %d %s", unsafe.Code, unsafe.Body.String())
	}

	listed := doJSON(t, h, http.MethodGet, "/v1/workspaces/default/chrome-handoffs", "", "", nil)
	var handoffs []ChromeHandoff
	decodeRecorder(t, listed, &handoffs)
	if len(handoffs) != 1 || handoffs[0].ID != handoff.ID {
		t.Fatalf("listed = %#v", handoffs)
	}

	opened := doJSON(t, h, http.MethodPut, "/v1/workspaces/default/chrome-handoffs/"+handoff.ID, "", "", strings.NewReader(`{"state":"opened"}`))
	if opened.Code != http.StatusOK {
		t.Fatalf("opened = %d %s", opened.Code, opened.Body.String())
	}
	listed = doJSON(t, h, http.MethodGet, "/v1/workspaces/default/chrome-handoffs", "", "", nil)
	decodeRecorder(t, listed, &handoffs)
	if len(handoffs) != 0 {
		t.Fatalf("pending after open = %#v", handoffs)
	}
	if _, err := h.store.db.Exec(`UPDATE chrome_devices SET scope='bookmarks:write' WHERE id=?`, credential.Device.ID); err != nil {
		t.Fatal(err)
	}
	wrongScope := doChromeRequest(h, http.MethodPost, "/v1/chrome-handoffs", credential.DeviceToken, "handoff-scope", strings.NewReader(safeBody))
	if wrongScope.Code != http.StatusForbidden {
		t.Fatalf("wrong scope = %d %s", wrongScope.Code, wrongScope.Body.String())
	}
	if _, err := h.store.db.Exec(`UPDATE chrome_devices SET scope=? WHERE id=?`, chromeDeviceScope, credential.Device.ID); err != nil {
		t.Fatal(err)
	}

	revoked := doJSON(t, h, http.MethodDelete, "/v1/workspaces/default/chrome-devices/"+credential.Device.ID, "", "", nil)
	if revoked.Code != http.StatusNoContent {
		t.Fatalf("revoke = %d %s", revoked.Code, revoked.Body.String())
	}
	afterRevoke := doChromeRequest(h, http.MethodPost, "/v1/chrome-handoffs", credential.DeviceToken, "handoff-3", strings.NewReader(safeBody))
	if afterRevoke.Code != http.StatusUnauthorized {
		t.Fatalf("after revoke = %d %s", afterRevoke.Code, afterRevoke.Body.String())
	}
	repaired := pairChromeDevice(t, h, "Jonathan's Chrome", credential.Device.ID)
	if repaired.Device.ID != credential.Device.ID || repaired.DeviceToken == credential.DeviceToken {
		t.Fatalf("repaired credential = %#v", repaired)
	}
	reconnected := doChromeRequest(h, http.MethodPost, "/v1/chrome-handoffs", repaired.DeviceToken, "handoff-4", strings.NewReader(safeBody))
	if reconnected.Code != http.StatusCreated {
		t.Fatalf("reconnected device = %d %s", reconnected.Code, reconnected.Body.String())
	}

	database, err := os.ReadFile(filepath.Join(h.config.StateDir, databaseFileName))
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(database, []byte(pairing.PairingCode)) || bytes.Contains(database, []byte(credential.DeviceToken)) {
		t.Fatal("pairing or device bearer token was persisted in plaintext")
	}
}

func TestChromePairingExpiresClosed(t *testing.T) {
	now := time.Date(2026, 8, 13, 12, 0, 0, 0, time.UTC)
	h := newProductTestHandler(t, productTestConfig(t.TempDir()), func() time.Time { return now })
	pairingResponse := doJSON(t, h, http.MethodPost, "/v1/workspaces/default/chrome-pairings", "", "", strings.NewReader(`{"device_name":"Chrome"}`))
	var pairing ChromePairing
	decodeRecorder(t, pairingResponse, &pairing)
	now = now.Add(chromePairingTTL)
	body := fmt.Sprintf(`{"pairing_code":%q,"device_id":"chrome-device-1234","device_name":"Chrome"}`, pairing.PairingCode)
	redeemed := doChromeRequest(h, http.MethodPost, "/v1/chrome-pairings/redeem", "", "", strings.NewReader(body))
	if redeemed.Code != http.StatusUnauthorized || !strings.Contains(redeemed.Body.String(), "pairing_expired") {
		t.Fatalf("expired pairing = %d %s", redeemed.Code, redeemed.Body.String())
	}
}

func TestChromeWindowBatchAndLibrarySnapshotsAreAtomicAndMonotonic(t *testing.T) {
	now := time.Date(2026, 8, 13, 12, 0, 0, 0, time.UTC)
	h := newProductTestHandler(t, productTestConfig(t.TempDir()), func() time.Time { return now })
	credential := pairChromeDevice(t, h, "Window Chrome", "window-device-1234")

	batch := `{"group_id":"window-group-1234","tabs":[{"title":"One","url":"https://one.example.test"},{"title":"Two","url":"https://two.example.test/path"}]}`
	created := doChromeRequest(h, http.MethodPost, "/v1/chrome-handoff-batches", credential.DeviceToken, "window-batch-1", strings.NewReader(batch))
	if created.Code != http.StatusCreated {
		t.Fatalf("batch = %d %s", created.Code, created.Body.String())
	}
	var handoffs []ChromeHandoff
	decodeRecorder(t, created, &handoffs)
	if len(handoffs) != 2 || handoffs[0].GroupID != "window-group-1234" || handoffs[1].Position != 1 {
		t.Fatalf("handoffs = %#v", handoffs)
	}

	unsafeBatch := `{"group_id":"window-group-5678","tabs":[{"title":"Good","url":"https://good.example.test"},{"title":"Bad","url":"https://bad.example.test/?token=secret"}]}`
	unsafe := doChromeRequest(h, http.MethodPost, "/v1/chrome-handoff-batches", credential.DeviceToken, "window-batch-2", strings.NewReader(unsafeBatch))
	if unsafe.Code != http.StatusBadRequest {
		t.Fatalf("unsafe batch = %d %s", unsafe.Code, unsafe.Body.String())
	}
	listed := doJSON(t, h, http.MethodGet, "/v1/workspaces/default/chrome-handoffs", "", "", nil)
	decodeRecorder(t, listed, &handoffs)
	if len(handoffs) != 2 {
		t.Fatalf("unsafe batch inserted partial handoffs: %#v", handoffs)
	}
	for index := 0; index < maxPendingHandoffs-len(handoffs); index++ {
		id := fmt.Sprintf("capacity-%03d", index)
		key := fmt.Sprintf("capacity-key-%03d", index)
		if _, err := h.store.db.Exec(`INSERT INTO chrome_handoffs(id,workspace_id,device_id,idempotency_key,request_hash,title,url,state,created_at,updated_at) VALUES(?,?,?,?,?,?,?,'pending',?,?)`, id, "default", credential.Device.ID, key, key, "Capacity", "https://capacity.example.test", formatTime(now), formatTime(now)); err != nil {
			t.Fatal(err)
		}
	}
	retriedBatch := doChromeRequest(h, http.MethodPost, "/v1/chrome-handoff-batches", credential.DeviceToken, "window-batch-1", strings.NewReader(batch))
	if retriedBatch.Code != http.StatusCreated {
		t.Fatalf("batch retry at capacity = %d %s", retriedBatch.Code, retriedBatch.Body.String())
	}

	bookmarkSnapshot := `{"kind":"bookmark","revision":1,"items":[{"external_id":"folder-1","title":"Work","position":0},{"external_id":"bookmark-1","parent_external_id":"folder-1","title":"Docs","url":"https://docs.example.test","position":0}]}`
	receiptResponse := doChromeRequest(h, http.MethodPut, "/v1/chrome-library-snapshots", credential.DeviceToken, "", strings.NewReader(bookmarkSnapshot))
	if receiptResponse.Code != http.StatusOK {
		t.Fatalf("bookmark snapshot = %d %s", receiptResponse.Code, receiptResponse.Body.String())
	}
	var receipt ChromeLibrarySnapshotReceipt
	decodeRecorder(t, receiptResponse, &receipt)
	if receipt.Revision != 1 || receipt.ItemCount != 2 {
		t.Fatalf("receipt = %#v", receipt)
	}

	retry := doChromeRequest(h, http.MethodPut, "/v1/chrome-library-snapshots", credential.DeviceToken, "", strings.NewReader(bookmarkSnapshot))
	if retry.Code != http.StatusOK {
		t.Fatalf("snapshot retry = %d %s", retry.Code, retry.Body.String())
	}
	changedSameRevision := doChromeRequest(h, http.MethodPut, "/v1/chrome-library-snapshots", credential.DeviceToken, "", strings.NewReader(`{"kind":"bookmark","revision":1,"items":[]}`))
	if changedSameRevision.Code != http.StatusConflict || !strings.Contains(changedSameRevision.Body.String(), "snapshot_conflict") {
		t.Fatalf("changed revision = %d %s", changedSameRevision.Code, changedSameRevision.Body.String())
	}
	replacement := doChromeRequest(h, http.MethodPut, "/v1/chrome-library-snapshots", credential.DeviceToken, "", strings.NewReader(`{"kind":"bookmark","revision":2,"items":[{"external_id":"bookmark-2","title":"New","url":"https://new.example.test","position":0}]}`))
	if replacement.Code != http.StatusOK {
		t.Fatalf("replacement = %d %s", replacement.Code, replacement.Body.String())
	}
	stale := doChromeRequest(h, http.MethodPut, "/v1/chrome-library-snapshots", credential.DeviceToken, "", strings.NewReader(bookmarkSnapshot))
	if stale.Code != http.StatusConflict || !strings.Contains(stale.Body.String(), "stale_revision") {
		t.Fatalf("stale revision = %d %s", stale.Code, stale.Body.String())
	}

	library := doJSON(t, h, http.MethodGet, "/v1/workspaces/default/chrome-library?kind=bookmark", "", "", nil)
	var items []ChromeLibraryItem
	decodeRecorder(t, library, &items)
	if len(items) != 1 || items[0].ExternalID != "bookmark-2" || items[0].DeviceName != "Window Chrome" {
		t.Fatalf("library = %#v", items)
	}
	readingUnsafe := doChromeRequest(h, http.MethodPut, "/v1/chrome-library-snapshots", credential.DeviceToken, "", strings.NewReader(`{"kind":"reading_list","revision":1,"items":[{"external_id":"https://example.test/?code=secret","url":"https://example.test/?code=secret","position":0}]}`))
	if readingUnsafe.Code != http.StatusBadRequest {
		t.Fatalf("unsafe reading list = %d %s", readingUnsafe.Code, readingUnsafe.Body.String())
	}
	revoked := doJSON(t, h, http.MethodDelete, "/v1/workspaces/default/chrome-devices/"+credential.Device.ID, "", "", nil)
	if revoked.Code != http.StatusNoContent {
		t.Fatalf("revoke = %d %s", revoked.Code, revoked.Body.String())
	}
	library = doJSON(t, h, http.MethodGet, "/v1/workspaces/default/chrome-library?kind=bookmark", "", "", nil)
	decodeRecorder(t, library, &items)
	if len(items) != 0 {
		t.Fatalf("revoked device retained visible library: %#v", items)
	}
}

func pairChromeDevice(t *testing.T, h *handler, name, deviceID string) ChromeDeviceCredential {
	t.Helper()
	pairingResponse := doJSON(t, h, http.MethodPost, "/v1/workspaces/default/chrome-pairings", "", "", strings.NewReader(fmt.Sprintf(`{"device_name":%q}`, name)))
	var pairing ChromePairing
	decodeRecorder(t, pairingResponse, &pairing)
	body := fmt.Sprintf(`{"pairing_code":%q,"device_id":%q,"device_name":%q}`, pairing.PairingCode, deviceID, name)
	redeemed := doChromeRequest(h, http.MethodPost, "/v1/chrome-pairings/redeem", "", "", strings.NewReader(body))
	if redeemed.Code != http.StatusCreated {
		t.Fatalf("redeem = %d %s", redeemed.Code, redeemed.Body.String())
	}
	var credential ChromeDeviceCredential
	decodeRecorder(t, redeemed, &credential)
	return credential
}

type nativeClientTestCredential struct {
	Client struct {
		ID   string `json:"id"`
		Name string `json:"name"`
	} `json:"client"`
	ClientToken string `json:"client_token"`
}

func enrollNativeClient(t *testing.T, h *handler, name string) nativeClientTestCredential {
	t.Helper()
	issued := doBearerRequest(h, http.MethodPost, "/v1/native-client-enrollments", h.config.APIToken, strings.NewReader(fmt.Sprintf(`{"client_name":%q}`, name)))
	var enrollment struct {
		PairingCapability string `json:"pairing_capability"`
	}
	decodeRecorder(t, issued, &enrollment)
	if issued.Code != http.StatusCreated || enrollment.PairingCapability == "" {
		t.Fatalf("issue = %d %s", issued.Code, issued.Body.String())
	}
	return redeemNativeClient(t, h, enrollment.PairingCapability, name)
}

func redeemNativeClient(t *testing.T, h *handler, capability, name string) nativeClientTestCredential {
	t.Helper()
	response := doBearerRequest(h, http.MethodPost, "/v1/native-client-enrollments/redeem", capability, strings.NewReader(fmt.Sprintf(`{"client_name":%q}`, name)))
	var credential nativeClientTestCredential
	decodeRecorder(t, response, &credential)
	if response.Code != http.StatusCreated || credential.ClientToken == "" {
		t.Fatalf("redeem = %d %s", response.Code, response.Body.String())
	}
	return credential
}

func tableColumnNames(t *testing.T, db *sql.DB, table string) map[string]bool {
	t.Helper()
	rows, err := db.Query(`SELECT name FROM pragma_table_info(?)`, table)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	columns := map[string]bool{}
	for rows.Next() {
		var name string
		if err := rows.Scan(&name); err != nil {
			t.Fatal(err)
		}
		columns[name] = true
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	return columns
}

func productTestConfig(root string) Config {
	return Config{
		ViewerURL:       "https://viewer.example.test",
		ViewerHealthURL: "https://viewer.example.test",
		StateDir:        filepath.Join(root, "state"),
		AttachmentDir:   filepath.Join(root, "attachments"),
		APIToken:        "api-test-secret",
		BridgeToken:     "bridge-test-secret",
		ViewerPassword:  "viewer-test-secret",
		LeaseTTL:        30 * time.Second,
	}
}

func newProductTestHandler(t *testing.T, cfg Config, now func() time.Time) *handler {
	t.Helper()
	h, err := newHandlerWithConfig(cfg, &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return responseWithStatus(r, http.StatusOK), nil
	})}, now)
	if err != nil {
		t.Fatalf("newHandlerWithConfig: %v", err)
	}
	t.Cleanup(func() { _ = h.store.close() })
	return h
}

func doJSON(t *testing.T, h http.Handler, method, path, idempotencyKey, token string, body io.Reader) *httptest.ResponseRecorder {
	t.Helper()
	return doJSONNoT(h, method, path, idempotencyKey, token, body)
}

func doJSONNoT(h http.Handler, method, path, idempotencyKey, token string, body io.Reader) *httptest.ResponseRecorder {
	request := httptest.NewRequest(method, "http://ghostlight.test"+path, body)
	if body != nil {
		request.Header.Set("Content-Type", "application/json")
	}
	if idempotencyKey != "" {
		request.Header.Set("Idempotency-Key", idempotencyKey)
	}
	if strings.HasPrefix(path, "/v1/bridge/") {
		request.Header.Set("Authorization", "Bearer "+token)
	} else {
		request.Header.Set("Authorization", "Bearer api-test-secret")
		if token != "" {
			request.Header.Set("X-Ghostlight-Lease-Token", token)
		}
	}
	recorder := httptest.NewRecorder()
	h.ServeHTTP(recorder, request)
	return recorder
}

func doChromeRequest(h http.Handler, method, path, token, idempotencyKey string, body io.Reader) *httptest.ResponseRecorder {
	request := httptest.NewRequest(method, "http://ghostlight.test"+path, body)
	request.Header.Set("Content-Type", "application/json")
	if token != "" {
		request.Header.Set("Authorization", "Bearer "+token)
	}
	if idempotencyKey != "" {
		request.Header.Set("Idempotency-Key", idempotencyKey)
	}
	recorder := httptest.NewRecorder()
	h.ServeHTTP(recorder, request)
	return recorder
}

func doBearerRequest(h http.Handler, method, path, token string, body io.Reader) *httptest.ResponseRecorder {
	request := httptest.NewRequest(method, "http://ghostlight.test"+path, body)
	if body != nil {
		request.Header.Set("Content-Type", "application/json")
	}
	if token != "" {
		request.Header.Set("Authorization", "Bearer "+token)
	}
	recorder := httptest.NewRecorder()
	h.ServeHTTP(recorder, request)
	return recorder
}

func decodeRecorder(t *testing.T, recorder *httptest.ResponseRecorder, target any) {
	t.Helper()
	if err := json.Unmarshal(recorder.Body.Bytes(), target); err != nil {
		t.Fatalf("decode %d %q: %v", recorder.Code, recorder.Body.String(), err)
	}
}

func acquireLease(t *testing.T, h *handler, sessionID string) ControllerLease {
	t.Helper()
	r := doJSON(t, h, http.MethodPost, "/v1/sessions/"+sessionID+"/leases", "", "", strings.NewReader(`{"client_id":"test"}`))
	var lease ControllerLease
	decodeRecorder(t, r, &lease)
	if r.Code != http.StatusCreated {
		t.Fatalf("lease = %d %s", r.Code, r.Body.String())
	}
	return lease
}

func assertMode(t *testing.T, path string, want os.FileMode) {
	t.Helper()
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if got := info.Mode().Perm(); got != want {
		t.Fatalf("mode %s = %o, want %o", path, got, want)
	}
}

func commandColumns(t *testing.T, db *sql.DB) map[string]bool {
	t.Helper()
	rows, err := db.Query(`PRAGMA table_info(commands)`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	columns := map[string]bool{}
	for rows.Next() {
		var cid, notNull, primaryKey int
		var name, columnType string
		var defaultValue any
		if err := rows.Scan(&cid, &name, &columnType, &notNull, &defaultValue, &primaryKey); err != nil {
			t.Fatal(err)
		}
		columns[name] = true
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	return columns
}
