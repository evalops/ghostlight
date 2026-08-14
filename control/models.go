package main

import (
	"encoding/json"
	"time"
)

const schemaVersion = 7

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

type ViewerCredential struct {
	Type      string    `json:"type"`
	Name      string    `json:"name,omitempty"`
	Value     string    `json:"value"`
	Path      string    `json:"path,omitempty"`
	Secure    bool      `json:"secure,omitempty"`
	HTTPOnly  bool      `json:"http_only,omitempty"`
	SameSite  string    `json:"same_site,omitempty"`
	ExpiresAt time.Time `json:"expires_at"`
}

type ViewerBootstrap struct {
	StreamID         string           `json:"stream_id"`
	ViewerURL        string           `json:"viewer_url"`
	ViewerCredential ViewerCredential `json:"viewer_credential"`
	ExpiresAt        time.Time        `json:"expires_at"`
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

// ActivitySpace stores only safe destinations and product metadata. Website
// identity and page state remain owned by the single Chromium profile.
type ActivitySpace struct {
	ID                         string             `json:"id"`
	WorkspaceID                string             `json:"workspace_id"`
	Name                       string             `json:"name"`
	State                      string             `json:"state"`
	Revision                   int64              `json:"revision"`
	Tabs                       []ActivitySpaceTab `json:"tabs"`
	ActivePosition             int                `json:"active_position"`
	HomePreferencesWorkspaceID string             `json:"home_preferences_workspace_id"`
	PendingHandoffIDs          []string           `json:"pending_handoff_ids"`
	CreatedAt                  time.Time          `json:"created_at"`
	UpdatedAt                  time.Time          `json:"updated_at"`
}

type ActivitySpaceTab struct {
	URL      string `json:"url"`
	Position int    `json:"position"`
}

type ActivitySpaceActivation struct {
	Space   ActivitySpace  `json:"space"`
	Command BrowserCommand `json:"command"`
}

type ContinuityOverview struct {
	Resume      []ActivitySpace  `json:"resume"`
	Browse      ContinuityBrowse `json:"browse"`
	Send        []ChromeHandoff  `json:"send"`
	GeneratedAt time.Time        `json:"generated_at"`
}

type ContinuityBrowse struct {
	Authority   string              `json:"authority"`
	Bookmarks   []ChromeLibraryItem `json:"bookmarks"`
	ReadingList []ChromeLibraryItem `json:"reading_list"`
}

type ContinuityIntentReceipt struct {
	Verb      string         `json:"verb"`
	Adapter   string         `json:"adapter"`
	Authority string         `json:"authority"`
	ExpiresAt time.Time      `json:"expires_at"`
	Space     *ActivitySpace `json:"space,omitempty"`
	Command   BrowserCommand `json:"command"`
}

type NativeClientEnrollment struct {
	PairingCapability string    `json:"pairing_capability,omitempty"`
	ClientName        string    `json:"client_name"`
	ExpiresAt         time.Time `json:"expires_at"`
}

type NativeClient struct {
	ID         string     `json:"id"`
	Name       string     `json:"name"`
	Scope      string     `json:"scope"`
	CreatedAt  time.Time  `json:"created_at"`
	LastSeenAt time.Time  `json:"last_seen_at"`
	RevokedAt  *time.Time `json:"revoked_at,omitempty"`
}

type NativeClientCredential struct {
	Client      NativeClient `json:"client"`
	ClientToken string       `json:"client_token"`
}

type ChromePairing struct {
	PairingCode string    `json:"pairing_code,omitempty"`
	WorkspaceID string    `json:"workspace_id"`
	DeviceName  string    `json:"device_name"`
	ExpiresAt   time.Time `json:"expires_at"`
}

type ChromeDevice struct {
	ID          string     `json:"id"`
	WorkspaceID string     `json:"workspace_id"`
	Name        string     `json:"name"`
	Scope       string     `json:"scope"`
	CreatedAt   time.Time  `json:"created_at"`
	LastSeenAt  time.Time  `json:"last_seen_at"`
	RevokedAt   *time.Time `json:"revoked_at,omitempty"`
}

type ChromeDeviceCredential struct {
	Device      ChromeDevice `json:"device"`
	DeviceToken string       `json:"device_token"`
}

type ChromeHandoff struct {
	ID          string    `json:"id"`
	WorkspaceID string    `json:"workspace_id"`
	DeviceID    string    `json:"device_id"`
	DeviceName  string    `json:"device_name"`
	Title       string    `json:"title,omitempty"`
	URL         string    `json:"url"`
	GroupID     string    `json:"group_id,omitempty"`
	Position    int       `json:"position,omitempty"`
	State       string    `json:"state"`
	CreatedAt   time.Time `json:"created_at"`
	UpdatedAt   time.Time `json:"updated_at"`
}

type ChromeLibraryItem struct {
	Kind             string `json:"kind"`
	ExternalID       string `json:"external_id"`
	ParentExternalID string `json:"parent_external_id,omitempty"`
	Title            string `json:"title,omitempty"`
	URL              string `json:"url,omitempty"`
	Position         int    `json:"position"`
	Read             bool   `json:"read"`
	DeviceID         string `json:"device_id,omitempty"`
	DeviceName       string `json:"device_name,omitempty"`
}

type ChromeLibrarySnapshotReceipt struct {
	Kind       string    `json:"kind"`
	Revision   int64     `json:"revision"`
	ItemCount  int       `json:"item_count"`
	ReceivedAt time.Time `json:"received_at"`
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
	SpaceID           string          `json:"space_id,omitempty"`
	Destinations      []string        `json:"destinations,omitempty"`
	ActivePosition    int             `json:"active_position,omitempty"`
	ContinuityVerb    string          `json:"continuity_verb,omitempty"`
	ContinuityAdapter string          `json:"continuity_adapter,omitempty"`
	ContinuityExpiry  *time.Time      `json:"continuity_expires_at,omitempty"`
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
