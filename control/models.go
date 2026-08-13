package main

import "time"

const schemaVersion = 1

type Workspace struct {
	ID        string    `json:"id"`
	Name      string    `json:"name"`
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
}

type BrowserSession struct {
	ID            string            `json:"id"`
	WorkspaceID   string            `json:"workspace_id"`
	Name          string            `json:"name"`
	Revision      int64             `json:"revision"`
	RuntimeState  string            `json:"runtime_state"`
	Tabs          []BrowserTab      `json:"tabs"`
	ActiveTabID   string            `json:"active_tab_id,omitempty"`
	Controller    *ControllerLease  `json:"controller,omitempty"`
	Stream        *StreamConnection `json:"stream,omitempty"`
	LastHeartbeat *time.Time        `json:"last_heartbeat,omitempty"`
	CreatedAt     time.Time         `json:"created_at"`
	UpdatedAt     time.Time         `json:"updated_at"`
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
	ID        string    `json:"id"`
	SessionID string    `json:"session_id"`
	URL       string    `json:"url"`
	State     string    `json:"state"`
	ExpiresAt time.Time `json:"expires_at"`
	CreatedAt time.Time `json:"created_at"`
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
	ID               string    `json:"id"`
	Sequence         int64     `json:"sequence"`
	SessionID        string    `json:"session_id"`
	Type             string    `json:"type"`
	URL              string    `json:"url,omitempty"`
	TabID            string    `json:"tab_id,omitempty"`
	AttachmentID     string    `json:"attachment_id,omitempty"`
	ExpectedRevision int64     `json:"expected_revision"`
	LeaseEpoch       int64     `json:"lease_epoch"`
	State            string    `json:"state"`
	CreatedAt        time.Time `json:"created_at"`
}
