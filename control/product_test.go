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
	stream, err := h.store.createStream(t.Context(), "default", "test-client", h.viewerURL, defaultStreamTTL)
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
	stream, err := h.store.createStream(t.Context(), "default", "mac-client", h.viewerURL, defaultStreamTTL)
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
			stream, err := h.store.createStream(context.Background(), "default", client, h.viewerURL, defaultStreamTTL)
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
	first, err := h.store.createStream(t.Context(), "default", "first-client", h.viewerURL, defaultStreamTTL)
	if err != nil {
		t.Fatal(err)
	}
	now = now.Add(defaultStreamTTL - time.Second)
	second, err := h.store.createStream(t.Context(), "default", "second-client", h.viewerURL, defaultStreamTTL)
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
	stream, err := h.store.createStream(t.Context(), "default", "mac-client", h.viewerURL, defaultStreamTTL)
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
	stream, err := h.store.createStream(t.Context(), "default", "mac-client", h.viewerURL, defaultStreamTTL)
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
