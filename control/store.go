package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"
)

var ErrSessionNotFound = errors.New("session not found")

type Session struct {
	ID        string    `json:"id"`
	ViewerURL string    `json:"viewer_url"`
	CreatedAt time.Time `json:"created_at"`
}

type FileStore struct {
	mu       sync.RWMutex
	path     string
	sessions map[string]Session
}

func NewFileStore(path string) (*FileStore, error) {
	if path == "" {
		return nil, errors.New("session store path is empty")
	}

	store := &FileStore{
		path:     path,
		sessions: make(map[string]Session),
	}

	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return store, nil
	}
	if err != nil {
		return nil, fmt.Errorf("read session store: %w", err)
	}
	if len(data) == 0 {
		return store, nil
	}
	if err := json.Unmarshal(data, &store.sessions); err != nil {
		return nil, fmt.Errorf("decode session store: %w", err)
	}
	if store.sessions == nil {
		store.sessions = make(map[string]Session)
	}
	return store, nil
}

func (s *FileStore) Create(viewerURL string, createdAt time.Time) (Session, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	if createdAt.IsZero() {
		createdAt = time.Now().UTC()
	} else {
		createdAt = createdAt.UTC()
	}

	for attempt := 0; attempt < 3; attempt++ {
		id, err := newSessionID()
		if err != nil {
			return Session{}, fmt.Errorf("generate session id: %w", err)
		}
		if _, exists := s.sessions[id]; exists {
			continue
		}

		session := Session{ID: id, ViewerURL: viewerURL, CreatedAt: createdAt}
		s.sessions[id] = session
		if err := s.persistLocked(); err != nil {
			delete(s.sessions, id)
			return Session{}, fmt.Errorf("persist created session: %w", err)
		}
		return session, nil
	}

	return Session{}, errors.New("could not generate a unique session id")
}

func (s *FileStore) Get(id string) (Session, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	session, ok := s.sessions[id]
	if !ok {
		return Session{}, ErrSessionNotFound
	}
	return session, nil
}

func (s *FileStore) Delete(id string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	session, ok := s.sessions[id]
	if !ok {
		return ErrSessionNotFound
	}
	delete(s.sessions, id)
	if err := s.persistLocked(); err != nil {
		s.sessions[id] = session
		return fmt.Errorf("persist deleted session: %w", err)
	}
	return nil
}

func (s *FileStore) persistLocked() error {
	data, err := json.MarshalIndent(s.sessions, "", "  ")
	if err != nil {
		return err
	}
	data = append(data, '\n')

	dir := filepath.Dir(s.path)
	if err := os.MkdirAll(dir, 0o750); err != nil {
		return err
	}
	temporary, err := os.CreateTemp(dir, "."+filepath.Base(s.path)+".tmp-")
	if err != nil {
		return err
	}
	temporaryName := temporary.Name()
	defer os.Remove(temporaryName)

	if _, err := temporary.Write(data); err != nil {
		_ = temporary.Close()
		return err
	}
	if err := temporary.Sync(); err != nil {
		_ = temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	if err := os.Rename(temporaryName, s.path); err != nil {
		return err
	}

	if directory, err := os.Open(dir); err == nil {
		_ = directory.Sync()
		_ = directory.Close()
	}
	return nil
}

func newSessionID() (string, error) {
	var raw [16]byte
	if _, err := rand.Read(raw[:]); err != nil {
		return "", err
	}
	raw[6] = (raw[6] & 0x0f) | 0x40
	raw[8] = (raw[8] & 0x3f) | 0x80
	encoded := hex.EncodeToString(raw[:])
	return encoded[0:8] + "-" + encoded[8:12] + "-" + encoded[12:16] + "-" + encoded[16:20] + "-" + encoded[20:32], nil
}
