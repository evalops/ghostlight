package main

import (
	"errors"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

func TestFileStoreRoundTripAndDelete(t *testing.T) {
	path := filepath.Join(t.TempDir(), "sessions.json")
	store, err := NewFileStore(path)
	if err != nil {
		t.Fatalf("NewFileStore() error = %v", err)
	}

	wantViewerURL := "https://viewer.example.test"
	wantCreatedAt := time.Date(2026, time.August, 12, 9, 30, 0, 0, time.UTC)
	want, err := store.Create(wantViewerURL, wantCreatedAt)
	if err != nil {
		t.Fatalf("Create() error = %v", err)
	}
	if want.ID == "" {
		t.Fatal("Create() returned an empty id")
	}

	got, err := store.Get(want.ID)
	if err != nil {
		t.Fatalf("Get() error = %v", err)
	}
	if got != want {
		t.Fatalf("Get() = %#v, want %#v", got, want)
	}

	reopened, err := NewFileStore(path)
	if err != nil {
		t.Fatalf("NewFileStore() after write error = %v", err)
	}
	got, err = reopened.Get(want.ID)
	if err != nil {
		t.Fatalf("reopened.Get() error = %v", err)
	}
	if got != want {
		t.Fatalf("reopened.Get() = %#v, want %#v", got, want)
	}

	if err := reopened.Delete(want.ID); err != nil {
		t.Fatalf("Delete() error = %v", err)
	}
	if _, err := reopened.Get(want.ID); !errors.Is(err, ErrSessionNotFound) {
		t.Fatalf("Get() after Delete() error = %v, want ErrSessionNotFound", err)
	}

	reopenedAgain, err := NewFileStore(path)
	if err != nil {
		t.Fatalf("NewFileStore() after delete error = %v", err)
	}
	if _, err := reopenedAgain.Get(want.ID); !errors.Is(err, ErrSessionNotFound) {
		t.Fatalf("reopened Get() after Delete() error = %v, want ErrSessionNotFound", err)
	}
}

func TestFileStoreConcurrentCreate(t *testing.T) {
	store, err := NewFileStore(filepath.Join(t.TempDir(), "sessions.json"))
	if err != nil {
		t.Fatalf("NewFileStore() error = %v", err)
	}

	const count = 32
	created := make(chan Session, count)
	errs := make(chan error, count)
	var wg sync.WaitGroup
	for i := 0; i < count; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			session, err := store.Create("https://viewer.example.test", time.Now().UTC())
			if err != nil {
				errs <- err
				return
			}
			created <- session
		}()
	}
	wg.Wait()
	close(created)
	close(errs)

	for err := range errs {
		t.Fatalf("concurrent Create() error = %v", err)
	}

	ids := make(map[string]struct{}, count)
	for session := range created {
		if _, exists := ids[session.ID]; exists {
			t.Fatalf("duplicate session id %q", session.ID)
		}
		ids[session.ID] = struct{}{}
	}
	if len(ids) != count {
		t.Fatalf("created %d sessions, want %d", len(ids), count)
	}
}
