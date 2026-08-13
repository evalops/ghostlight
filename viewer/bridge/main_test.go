package main

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestNativeMessageRoundTrip(t *testing.T) {
	want := nativeRequest{Operation: "poll", SessionID: "session-1", After: 42}
	var framed bytes.Buffer
	if err := writeNativeMessage(&framed, nativeResponse{OK: true, Payload: mustJSON(want)}); err != nil {
		t.Fatalf("writeNativeMessage() error = %v", err)
	}

	var size uint32
	if err := binary.Read(&framed, binary.LittleEndian, &size); err != nil {
		t.Fatalf("read frame size: %v", err)
	}
	if size == 0 || size > maxNativeMessageBytes {
		t.Fatalf("frame size = %d", size)
	}
	body := make([]byte, size)
	if _, err := io.ReadFull(&framed, body); err != nil {
		t.Fatalf("read frame body: %v", err)
	}
	var response nativeResponse
	if err := json.Unmarshal(body, &response); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	var got nativeRequest
	if err := json.Unmarshal(response.Payload, &got); err != nil {
		t.Fatalf("decode payload: %v", err)
	}
	if got.Operation != want.Operation || got.SessionID != want.SessionID || got.After != want.After {
		t.Fatalf("payload = %#v, want %#v", got, want)
	}
}

func TestReadNativeMessageRejectsOversize(t *testing.T) {
	var framed bytes.Buffer
	if err := binary.Write(&framed, binary.LittleEndian, uint32(maxNativeMessageBytes+1)); err != nil {
		t.Fatal(err)
	}
	if _, err := readNativeMessage(&framed); err == nil || !strings.Contains(err.Error(), "too large") {
		t.Fatalf("readNativeMessage() error = %v, want size error", err)
	}
}

func TestBridgeClientAuthenticatesAndBoundsResponses(t *testing.T) {
	var authorization string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		authorization = r.Header.Get("Authorization")
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, `{"commands":[]}`)
	}))
	defer server.Close()

	client, err := newBridgeClient(server.URL, "bridge-secret", t.TempDir(), server.Client())
	if err != nil {
		t.Fatalf("newBridgeClient() error = %v", err)
	}
	response, err := client.handle(t.Context(), nativeRequest{Operation: "poll", SessionID: "session-1", After: 7})
	if err != nil {
		t.Fatalf("handle(poll) error = %v", err)
	}
	if authorization != "Bearer bridge-secret" {
		t.Fatalf("Authorization = %q", authorization)
	}
	if string(response) != `{"commands":[]}` {
		t.Fatalf("response = %s", response)
	}
}

func TestBridgeClientStagesAttachmentSafely(t *testing.T) {
	const content = "fixture attachment"
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/bridge/attachments/attachment-1" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("X-Ghostlight-Filename", "report.txt")
		w.Header().Set("X-Ghostlight-SHA256", sha256Hex([]byte(content)))
		_, _ = io.WriteString(w, content)
	}))
	defer server.Close()

	downloads := t.TempDir()
	client, err := newBridgeClient(server.URL, "bridge-secret", downloads, server.Client())
	if err != nil {
		t.Fatalf("newBridgeClient() error = %v", err)
	}
	response, err := client.handle(t.Context(), nativeRequest{Operation: "stage_attachment", AttachmentID: "attachment-1"})
	if err != nil {
		t.Fatalf("handle(stage_attachment) error = %v", err)
	}
	var staged stagedAttachment
	if err := json.Unmarshal(response, &staged); err != nil {
		t.Fatalf("decode stage response: %v", err)
	}
	if staged.Filename != "report.txt" {
		t.Fatalf("filename = %q", staged.Filename)
	}
	path := filepath.Join(downloads, staged.Filename)
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read staged attachment: %v", err)
	}
	if string(data) != content {
		t.Fatalf("staged content = %q", data)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("mode = %o, want 600", info.Mode().Perm())
	}
}

func TestSanitizeFilename(t *testing.T) {
	for _, invalid := range []string{"", ".", "..", "../secret", "a/b", "a\\b", "\x00bad"} {
		if _, err := sanitizeFilename(invalid); err == nil {
			t.Fatalf("sanitizeFilename(%q) unexpectedly succeeded", invalid)
		}
	}
	if got, err := sanitizeFilename("Quarterly report (final).pdf"); err != nil || got != "Quarterly_report__final_.pdf" {
		t.Fatalf("sanitizeFilename() = %q, %v", got, err)
	}
}

func TestNewBridgeClientRejectsUnsafeConfiguration(t *testing.T) {
	for _, rawURL := range []string{"", "file:///tmp/control", "http://user:pass@control:8080", "http://control:8080/#fragment"} {
		if _, err := newBridgeClient(rawURL, "token", t.TempDir(), http.DefaultClient); err == nil {
			t.Fatalf("newBridgeClient(%q) unexpectedly succeeded", rawURL)
		}
	}
	if _, err := newBridgeClient("http://control:8080", "", t.TempDir(), http.DefaultClient); err == nil {
		t.Fatal("newBridgeClient() accepted empty bridge token")
	}
}
