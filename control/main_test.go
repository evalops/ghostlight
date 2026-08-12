package main

import (
	"net"
	"syscall"
	"testing"
	"time"
)

func TestRunShutsDownOnSignal(t *testing.T) {
	t.Setenv(viewerURLEnvironment, "https://viewer.example.test")
	t.Setenv(viewerHealthURLEnvironment, "")
	t.Setenv(listenAddrEnvironment, "127.0.0.1:0")

	runErrors := make(chan error, 1)
	go func() { runErrors <- run() }()

	// signal.Notify is registered before Serve starts, so a short delay is
	// enough to guarantee the signal is caught instead of killing the test.
	time.Sleep(250 * time.Millisecond)
	select {
	case err := <-runErrors:
		t.Fatalf("run() exited before signal: %v", err)
	default:
	}
	if err := syscall.Kill(syscall.Getpid(), syscall.SIGTERM); err != nil {
		t.Fatalf("send SIGTERM: %v", err)
	}

	select {
	case err := <-runErrors:
		if err != nil {
			t.Fatalf("run() after SIGTERM error = %v, want nil", err)
		}
	case <-time.After(2 * shutdownTimeout):
		t.Fatal("run() did not exit after SIGTERM")
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
	if err := run(); err == nil {
		t.Fatal("run() with occupied listen address returned nil error")
	}
}
