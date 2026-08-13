package main

import (
	"context"
	"crypto/subtle"
	"database/sql"
	"errors"
)

func (s *sqliteStore) replaceChromeLibrary(ctx context.Context, device ChromeDevice, kind string, revision int64, requestHash string, items []ChromeLibraryItem) (ChromeLibrarySnapshotReceipt, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return ChromeLibrarySnapshotReceipt{}, err
	}
	defer tx.Rollback()
	var currentRevision int64
	var currentHash, received string
	err = tx.QueryRowContext(ctx, `SELECT revision,request_hash,received_at FROM chrome_library_snapshots WHERE device_id=? AND kind=?`, device.ID, kind).Scan(&currentRevision, &currentHash, &received)
	if err == nil {
		if revision < currentRevision {
			return ChromeLibrarySnapshotReceipt{}, errStaleRevision
		}
		if revision == currentRevision {
			if subtle.ConstantTimeCompare([]byte(currentHash), []byte(requestHash)) != 1 {
				return ChromeLibrarySnapshotReceipt{}, errIdempotencyKey
			}
			stamp, _ := parseTime(received)
			return ChromeLibrarySnapshotReceipt{Kind: kind, Revision: revision, ItemCount: len(items), ReceivedAt: stamp}, nil
		}
	} else if !errors.Is(err, sql.ErrNoRows) {
		return ChromeLibrarySnapshotReceipt{}, err
	}

	if _, err := tx.ExecContext(ctx, `DELETE FROM chrome_library_items WHERE device_id=? AND kind=?`, device.ID, kind); err != nil {
		return ChromeLibrarySnapshotReceipt{}, err
	}
	statement, err := tx.PrepareContext(ctx, `INSERT INTO chrome_library_items(device_id,workspace_id,kind,external_id,parent_external_id,title,url,position,is_read) VALUES(?,?,?,?,?,?,?,?,?)`)
	if err != nil {
		return ChromeLibrarySnapshotReceipt{}, err
	}
	defer statement.Close()
	for _, item := range items {
		if _, err := statement.ExecContext(ctx, device.ID, device.WorkspaceID, kind, item.ExternalID, item.ParentExternalID, item.Title, item.URL, item.Position, item.Read); err != nil {
			return ChromeLibrarySnapshotReceipt{}, err
		}
	}
	now := s.now().UTC()
	_, err = tx.ExecContext(ctx, `INSERT INTO chrome_library_snapshots(device_id,kind,revision,request_hash,item_count,received_at) VALUES(?,?,?,?,?,?) ON CONFLICT(device_id,kind) DO UPDATE SET revision=excluded.revision,request_hash=excluded.request_hash,item_count=excluded.item_count,received_at=excluded.received_at`, device.ID, kind, revision, requestHash, len(items), formatTime(now))
	if err != nil {
		return ChromeLibrarySnapshotReceipt{}, err
	}
	if _, err := tx.ExecContext(ctx, `UPDATE chrome_devices SET last_seen_at=? WHERE id=? AND revoked_at IS NULL`, formatTime(now), device.ID); err != nil {
		return ChromeLibrarySnapshotReceipt{}, err
	}
	if err := tx.Commit(); err != nil {
		return ChromeLibrarySnapshotReceipt{}, err
	}
	return ChromeLibrarySnapshotReceipt{Kind: kind, Revision: revision, ItemCount: len(items), ReceivedAt: now}, nil
}

func (s *sqliteStore) listChromeLibrary(ctx context.Context, workspaceID, kind string) ([]ChromeLibraryItem, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT i.kind,i.external_id,i.parent_external_id,i.title,i.url,i.position,i.is_read,i.device_id,d.name FROM chrome_library_items i JOIN chrome_devices d ON d.id=i.device_id WHERE i.workspace_id=? AND i.kind=? AND d.revoked_at IS NULL ORDER BY d.name,i.parent_external_id,i.position,i.external_id`, workspaceID, kind)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := []ChromeLibraryItem{}
	for rows.Next() {
		var item ChromeLibraryItem
		if err := rows.Scan(&item.Kind, &item.ExternalID, &item.ParentExternalID, &item.Title, &item.URL, &item.Position, &item.Read, &item.DeviceID, &item.DeviceName); err != nil {
			return nil, err
		}
		items = append(items, item)
	}
	return items, rows.Err()
}
