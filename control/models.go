package main

import (
	"encoding/json"
	"time"
)

const schemaVersion = 2

type Workspace struct {
	ID        string    `json:"id"`
	Name      string    `json:"name"`
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
}

type BrowserSession struct {
	ID              string            `json:"id"`
	WorkspaceID     string            `json:"workspace_id"`
	Name            string            `json:"name"`
	Revision        int64             `json:"revision"`
	RuntimeState    string            `json:"runtime_state"`
	Tabs            []BrowserTab      `json:"tabs"`
	ActiveTabID     string            `json:"active_tab_id,omitempty"`
	Controller      *ControllerLease  `json:"controller,omitempty"`
	Stream          *StreamConnection `json:"stream,omitempty"`
	CommandReceipts []BrowserCommand  `json:"command_receipts,omitempty"`
	LastHeartbeat   *time.Time        `json:"last_heartbeat,omitempty"`
	CreatedAt       time.Time         `json:"created_at"`
	UpdatedAt       time.Time         `json:"updated_at"`
}

type BrowserTab struct {
	ID         string `json:"id"`
	Title      string `json:"title,omitempty"`
	URL        string `json:"url"`
	FaviconURL string `json:"favicon_url,omitempty"`
	Active     bool   `json:"active"`
	Loading    bool   `json:"loading"`
	Audible    bool   `json:"audible"`
	Discarded  bool   `json:"discarded"`
	WindowID   int    `json:"window_id"`
	Index      int    `json:"index"`
}

type ControllerLease struct {
	ID         string    `json:"id"`
	SessionID  string    `json:"session_id"`
	ClientID   string    `json:"client_id"`
	Token      string    `json:"token,omitempty"`
	Epoch      int64     `json:"epoch"`
	ExpiresAt  time.Time `json:"expires_at"`
	RenewAfter time.Time `json:"renew_after"`
}

type StreamConnection struct {
	ID         string    `json:"id"`
	SessionID  string    `json:"session_id"`
	URL        string    `json:"url"`
	State      string    `json:"state"`
	ExpiresAt  time.Time `json:"expires_at"`
	CreatedAt  time.Time `json:"created_at"`
	Capability string    `json:"capability,omitempty"`
}

type WorkspaceShortcut struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	URL      string `json:"url"`
	Position int    `json:"position"`
}

type WorkspacePreferences struct {
	WorkspaceID string              `json:"workspace_id"`
	SearchURL   string              `json:"search_url"`
	Shortcuts   []WorkspaceShortcut `json:"shortcuts"`
	RecentURLs  []string            `json:"recent_urls"`
	UpdatedAt   time.Time           `json:"updated_at"`
}

type Attachment struct {
	ID          string    `json:"id"`
	SessionID   string    `json:"session_id"`
	Filename    string    `json:"filename"`
	ContentType string    `json:"content_type"`
	Size        int64     `json:"size"`
	Digest      string    `json:"digest"`
	CreatedAt   time.Time `json:"created_at"`
}

type BrowserCommand struct {
	ID                string          `json:"id"`
	Sequence          int64           `json:"sequence"`
	SessionID         string          `json:"session_id"`
	Type              string          `json:"type"`
	URL               string          `json:"url,omitempty"`
	TabID             string          `json:"tab_id,omitempty"`
	AttachmentID      string          `json:"attachment_id,omitempty"`
	ExpectedRevision  int64           `json:"expected_revision"`
	LeaseEpoch        int64           `json:"lease_epoch"`
	State             string          `json:"state"`
	ErrorCode         string          `json:"error_code,omitempty"`
	Error             string          `json:"error,omitempty"`
	Result            json.RawMessage `json:"result,omitempty"`
	ResultingRevision *int64          `json:"resulting_revision,omitempty"`
	AcknowledgedAt    *time.Time      `json:"acknowledged_at,omitempty"`
	CompletedAt       *time.Time      `json:"completed_at,omitempty"`
	CreatedAt         time.Time       `json:"created_at"`
}
