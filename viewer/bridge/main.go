package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
	"unicode"
)

const (
	maxNativeMessageBytes  = 1 << 20
	maxAPIResponseBytes    = 4 << 20
	maxAttachmentBytes     = 25 << 20
	requestTimeout         = 10 * time.Second
	controlURLEnvironment  = "GHOSTLIGHT_CONTROL_INTERNAL_URL"
	bridgeTokenEnvironment = "GHOSTLIGHT_BRIDGE_TOKEN"
	downloadsEnvironment   = "GHOSTLIGHT_DOWNLOADS_DIR"
	defaultControlURL      = "http://control:8080"
	defaultDownloadsDir    = "/home/neko/Downloads"
)

type nativeRequest struct {
	Operation    string          `json:"operation"`
	SessionID    string          `json:"session_id,omitempty"`
	After        uint64          `json:"after,omitempty"`
	CommandID    string          `json:"command_id,omitempty"`
	AttachmentID string          `json:"attachment_id,omitempty"`
	Payload      json.RawMessage `json:"payload,omitempty"`
}

type nativeResponse struct {
	OK      bool            `json:"ok"`
	Payload json.RawMessage `json:"payload,omitempty"`
	Error   string          `json:"error,omitempty"`
}

type stagedAttachment struct {
	Filename string `json:"filename"`
	SHA256   string `json:"sha256"`
	Bytes    int64  `json:"bytes"`
}

type bridgeClient struct {
	baseURL      *url.URL
	token        string
	downloadsDir string
	httpClient   *http.Client
}

func main() {
	baseURL := strings.TrimSpace(os.Getenv(controlURLEnvironment))
	if baseURL == "" {
		baseURL = defaultControlURL
	}
	downloadsDir := strings.TrimSpace(os.Getenv(downloadsEnvironment))
	if downloadsDir == "" {
		downloadsDir = defaultDownloadsDir
	}
	client, err := newBridgeClient(baseURL, os.Getenv(bridgeTokenEnvironment), downloadsDir, &http.Client{Timeout: requestTimeout})
	if err != nil {
		log.Printf("bridge configuration failed: %v", err)
		os.Exit(1)
	}
	if err := serveNativeMessages(context.Background(), os.Stdin, os.Stdout, client); err != nil && !errors.Is(err, io.EOF) {
		log.Printf("native messaging host stopped: %v", err)
		os.Exit(1)
	}
}

func newBridgeClient(rawURL, token, downloadsDir string, httpClient *http.Client) (*bridgeClient, error) {
	parsed, err := url.Parse(strings.TrimSpace(rawURL))
	if err != nil || !parsed.IsAbs() || parsed.Hostname() == "" {
		return nil, errors.New("control URL must be an absolute HTTP URL")
	}
	if parsed.Scheme != "http" && parsed.Scheme != "https" {
		return nil, errors.New("control URL must use HTTP or HTTPS")
	}
	if parsed.User != nil || parsed.Fragment != "" || parsed.RawQuery != "" {
		return nil, errors.New("control URL must not contain credentials, query, or fragment")
	}
	parsed.Path = strings.TrimRight(parsed.Path, "/")
	if strings.TrimSpace(token) == "" || subtle.ConstantTimeCompare([]byte(token), []byte(strings.TrimSpace(token))) != 1 {
		return nil, errors.New("bridge token must be set without surrounding whitespace")
	}
	if !filepath.IsAbs(downloadsDir) {
		return nil, errors.New("downloads directory must be absolute")
	}
	if httpClient == nil {
		return nil, errors.New("HTTP client must not be nil")
	}
	if err := os.MkdirAll(downloadsDir, 0o700); err != nil {
		return nil, fmt.Errorf("create downloads directory: %w", err)
	}
	info, err := os.Lstat(downloadsDir)
	if err != nil {
		return nil, fmt.Errorf("inspect downloads directory: %w", err)
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return nil, errors.New("downloads path must be a real directory")
	}
	return &bridgeClient{baseURL: parsed, token: token, downloadsDir: downloadsDir, httpClient: httpClient}, nil
}

func serveNativeMessages(ctx context.Context, input io.Reader, output io.Writer, client *bridgeClient) error {
	for {
		request, err := readNativeMessage(input)
		if err != nil {
			return err
		}
		payload, handleErr := client.handle(ctx, request)
		response := nativeResponse{OK: handleErr == nil, Payload: payload}
		if handleErr != nil {
			response.Error = handleErr.Error()
		}
		if err := writeNativeMessage(output, response); err != nil {
			return err
		}
	}
}

func readNativeMessage(reader io.Reader) (nativeRequest, error) {
	var size uint32
	if err := binary.Read(reader, binary.LittleEndian, &size); err != nil {
		return nativeRequest{}, err
	}
	if size == 0 || size > maxNativeMessageBytes {
		return nativeRequest{}, fmt.Errorf("native message too large: %d bytes", size)
	}
	body := make([]byte, size)
	if _, err := io.ReadFull(reader, body); err != nil {
		return nativeRequest{}, fmt.Errorf("read native message: %w", err)
	}
	var request nativeRequest
	decoder := json.NewDecoder(bytes.NewReader(body))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&request); err != nil {
		return nativeRequest{}, fmt.Errorf("decode native message: %w", err)
	}
	if decoder.Decode(&struct{}{}) != io.EOF {
		return nativeRequest{}, errors.New("native message contains trailing JSON")
	}
	return request, nil
}

func writeNativeMessage(writer io.Writer, response nativeResponse) error {
	body, err := json.Marshal(response)
	if err != nil {
		return fmt.Errorf("encode native response: %w", err)
	}
	if len(body) > maxNativeMessageBytes {
		return fmt.Errorf("native response too large: %d bytes", len(body))
	}
	if err := binary.Write(writer, binary.LittleEndian, uint32(len(body))); err != nil {
		return fmt.Errorf("write native response size: %w", err)
	}
	if _, err := writer.Write(body); err != nil {
		return fmt.Errorf("write native response: %w", err)
	}
	return nil
}

func (c *bridgeClient) handle(ctx context.Context, request nativeRequest) (json.RawMessage, error) {
	switch request.Operation {
	case "bootstrap":
		return c.doJSON(ctx, http.MethodGet, "/v1/bridge/bootstrap", nil, nil)
	case "heartbeat":
		if request.SessionID == "" || len(request.Payload) == 0 {
			return nil, errors.New("heartbeat requires session_id and payload")
		}
		return c.doJSON(ctx, http.MethodPost, "/v1/bridge/heartbeat", request.Payload, nil)
	case "poll":
		if request.SessionID == "" {
			return nil, errors.New("poll requires session_id")
		}
		query := url.Values{"session_id": []string{request.SessionID}, "after": []string{strconv.FormatUint(request.After, 10)}}
		return c.doJSON(ctx, http.MethodGet, "/v1/bridge/commands?"+query.Encode(), nil, nil)
	case "ack":
		if request.CommandID == "" {
			return nil, errors.New("ack requires command_id")
		}
		body := request.Payload
		if len(body) == 0 {
			body = json.RawMessage(`{"status":"ok"}`)
		}
		return c.doJSON(ctx, http.MethodPost, "/v1/bridge/commands/"+url.PathEscape(request.CommandID)+"/ack", body, nil)
	case "stage_attachment":
		return c.stageAttachment(ctx, request.AttachmentID)
	default:
		return nil, fmt.Errorf("unsupported operation %q", request.Operation)
	}
}

func (c *bridgeClient) doJSON(ctx context.Context, method, path string, body []byte, headers http.Header) (json.RawMessage, error) {
	requestURL := *c.baseURL
	if strings.HasPrefix(path, "/") {
		requestURL.Path = strings.TrimRight(c.baseURL.Path, "/") + strings.SplitN(path, "?", 2)[0]
	} else {
		return nil, errors.New("bridge path must be absolute")
	}
	if parts := strings.SplitN(path, "?", 2); len(parts) == 2 {
		requestURL.RawQuery = parts[1]
	}
	var reader io.Reader
	if body != nil {
		reader = bytes.NewReader(body)
	}
	request, err := http.NewRequestWithContext(ctx, method, requestURL.String(), reader)
	if err != nil {
		return nil, fmt.Errorf("create control request: %w", err)
	}
	request.Header.Set("Authorization", "Bearer "+c.token)
	request.Header.Set("Accept", "application/json")
	if body != nil {
		request.Header.Set("Content-Type", "application/json")
	}
	for name, values := range headers {
		for _, value := range values {
			request.Header.Add(name, value)
		}
	}
	response, err := c.httpClient.Do(request)
	if err != nil {
		return nil, fmt.Errorf("control request failed: %w", err)
	}
	defer response.Body.Close()
	limited := io.LimitReader(response.Body, maxAPIResponseBytes+1)
	responseBody, err := io.ReadAll(limited)
	if err != nil {
		return nil, fmt.Errorf("read control response: %w", err)
	}
	if len(responseBody) > maxAPIResponseBytes {
		return nil, errors.New("control response exceeded size limit")
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return nil, fmt.Errorf("control returned HTTP %d", response.StatusCode)
	}
	if len(responseBody) == 0 {
		return json.RawMessage(`{}`), nil
	}
	if !json.Valid(responseBody) {
		return nil, errors.New("control returned invalid JSON")
	}
	return responseBody, nil
}

func (c *bridgeClient) stageAttachment(ctx context.Context, attachmentID string) (json.RawMessage, error) {
	if attachmentID == "" {
		return nil, errors.New("stage_attachment requires attachment_id")
	}
	requestURL := *c.baseURL
	requestURL.Path = strings.TrimRight(c.baseURL.Path, "/") + "/v1/bridge/attachments/" + url.PathEscape(attachmentID)
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, requestURL.String(), nil)
	if err != nil {
		return nil, err
	}
	request.Header.Set("Authorization", "Bearer "+c.token)
	response, err := c.httpClient.Do(request)
	if err != nil {
		return nil, fmt.Errorf("download attachment: %w", err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("attachment download returned HTTP %d", response.StatusCode)
	}
	originalFilename, err := sanitizeFilename(response.Header.Get("X-Ghostlight-Filename"))
	if err != nil {
		return nil, fmt.Errorf("attachment filename: %w", err)
	}
	filename := attachmentID + "-" + originalFilename
	expectedDigest := strings.ToLower(response.Header.Get("X-Ghostlight-SHA256"))
	if len(expectedDigest) != sha256.Size*2 {
		return nil, errors.New("attachment response omitted a valid SHA-256 digest")
	}
	if _, err := hex.DecodeString(expectedDigest); err != nil {
		return nil, errors.New("attachment response contained an invalid SHA-256 digest")
	}

	root, err := os.OpenRoot(c.downloadsDir)
	if err != nil {
		return nil, fmt.Errorf("open downloads root: %w", err)
	}
	defer root.Close()
	file, err := root.OpenFile(filename, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return nil, fmt.Errorf("create staged attachment: %w", err)
	}
	hasher := sha256.New()
	count, copyErr := io.Copy(io.MultiWriter(file, hasher), io.LimitReader(response.Body, maxAttachmentBytes+1))
	closeErr := file.Close()
	if copyErr != nil || closeErr != nil || count > maxAttachmentBytes || subtle.ConstantTimeCompare([]byte(hex.EncodeToString(hasher.Sum(nil))), []byte(expectedDigest)) != 1 {
		_ = root.Remove(filename)
		switch {
		case copyErr != nil:
			return nil, fmt.Errorf("write staged attachment: %w", copyErr)
		case closeErr != nil:
			return nil, fmt.Errorf("close staged attachment: %w", closeErr)
		case count > maxAttachmentBytes:
			return nil, errors.New("attachment exceeded size limit")
		default:
			return nil, errors.New("attachment digest mismatch")
		}
	}
	return json.Marshal(stagedAttachment{Filename: filename, SHA256: expectedDigest, Bytes: count})
}

func sanitizeFilename(value string) (string, error) {
	value = strings.TrimSpace(value)
	if value == "" || value == "." || value == ".." || filepath.Base(value) != value || strings.ContainsAny(value, `/\`) {
		return "", errors.New("filename must be one path-free component")
	}
	var result strings.Builder
	for _, char := range value {
		switch {
		case unicode.IsLetter(char), unicode.IsDigit(char), char == '.', char == '-', char == '_':
			result.WriteRune(char)
		case unicode.IsSpace(char), unicode.IsPunct(char):
			result.WriteByte('_')
		default:
			return "", errors.New("filename contains unsupported characters")
		}
	}
	if result.Len() == 0 || result.Len() > 180 {
		return "", errors.New("filename length is invalid")
	}
	return result.String(), nil
}

func sha256Hex(value []byte) string {
	digest := sha256.Sum256(value)
	return hex.EncodeToString(digest[:])
}

func mustJSON(value any) json.RawMessage {
	encoded, err := json.Marshal(value)
	if err != nil {
		panic(err)
	}
	return encoded
}
