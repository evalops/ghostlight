package main

import (
	"net"
	"os"
	"syscall"
	"testing"
	"time"
)

func TestRunShutsDownOnSignal(t *testing.T) {
	t.Setenv(viewerURLEnvironment, "https://viewer.example.test")
	t.Setenv(viewerHealthURLEnvironment, "")
	t.Setenv(listenAddrEnvironment, "127.0.0.1:0")
	t.Setenv(stateDirEnvironment, t.TempDir())
	t.Setenv(attachmentDirEnvironment, t.TempDir())
	t.Setenv(apiTokenEnvironment, "api-test-token")
	t.Setenv(bridgeTokenEnvironment, "bridge-test-token")
	t.Setenv(viewerPasswordEnvironment, "viewer-test-secret")

	signals := make(chan os.Signal, 1)
	ready := make(chan struct{})
	runErrors := make(chan error, 1)
	go func() { runErrors <- runWithSignals(signals, ready) }()
	select {
	case <-ready:
	case err := <-runErrors:
		t.Fatalf("runWithSignals() exited before ready: %v", err)
	case <-time.After(2 * shutdownTimeout):
		t.Fatal("runWithSignals() did not become ready")
	}
	signals <- syscall.SIGTERM

	select {
	case err := <-runErrors:
		if err != nil {
			t.Fatalf("runWithSignals() after SIGTERM error = %v, want nil", err)
		}
	case <-time.After(2 * shutdownTimeout):
		t.Fatal("runWithSignals() did not exit after SIGTERM")
	}
}

func TestRunFailsOnUnusableListenAddr(t *testing.T) {
	// Occupy a port so run() fails to bind and returns an error promptly.
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("net.Listen() error = %v", err)
	}
	defer listener.Close()
	t.Setenv(viewerURLEnvironment, "https://viewer.example.test")
	t.Setenv(viewerHealthURLEnvironment, "")
	t.Setenv(listenAddrEnvironment, listener.Addr().String())
	t.Setenv(stateDirEnvironment, t.TempDir())
	t.Setenv(attachmentDirEnvironment, t.TempDir())
	t.Setenv(apiTokenEnvironment, "api-test-token")
	t.Setenv(bridgeTokenEnvironment, "bridge-test-token")
	t.Setenv(viewerPasswordEnvironment, "viewer-test-secret")
	if err := run(); err == nil {
		t.Fatal("run() with occupied listen address returned nil error")
	}
}
