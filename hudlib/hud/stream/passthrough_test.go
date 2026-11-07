package stream

import (
	"bytes"
	"sync/atomic"
	"testing"
	"time"
)

var (
	ptIDR = []byte{0, 0, 0, 1, 0x67, 0x64, 0, 0, 0, 0, 0, 1, 0x68, 0xEE, 0, 0, 0, 1, 0x65, 0x88}
	ptP1  = []byte{0, 0, 0, 1, 0x41, 0x01}
	ptP2  = []byte{0, 0, 0, 1, 0x41, 0x02}
)

func newPassthrough(t *testing.T, capacity int) (*LiveStreamSource, *atomic.Int32) {
	t.Helper()
	requests := &atomic.Int32{}
	src := NewLiveStreamSource(30, 3*time.Second, capacity)
	src.SetPassthrough(func() { requests.Add(1) })
	return src, requests
}

func waitFor(t *testing.T, counter *atomic.Int32, want int32) {
	t.Helper()
	deadline := time.Now().Add(time.Second)
	for counter.Load() < want {
		if time.Now().After(deadline) {
			t.Fatalf("IDR requests = %d, want at least %d", counter.Load(), want)
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func TestPassthroughAsksForIDRUntilOneArrives(t *testing.T) {
	src, requests := newPassthrough(t, 8)
	src.PushFrame(ptP1)
	waitFor(t, requests, 1)
	if frame, _ := src.NextFrame(time.Now()); frame != nil {
		t.Fatalf("a P-frame before any IDR must not reach the dash, got %x", frame)
	}
	src.PushFrame(ptIDR)
	if frame, _ := src.NextFrame(time.Now()); !bytes.Equal(frame, ptIDR) {
		t.Fatalf("expected the IDR, got %x", frame)
	}
}

func TestPassthroughHandsOverEveryQueuedFrameInOnePoll(t *testing.T) {
	src, _ := newPassthrough(t, 8)
	src.PushFrame(ptIDR)
	src.PushFrame(ptP1)
	src.PushFrame(ptP2)
	frame, _ := src.NextFrame(time.Now())
	want := append(append(append([]byte{}, ptIDR...), ptP1...), ptP2...)
	if !bytes.Equal(frame, want) {
		t.Fatalf("poll returned %x, want all three AUs %x", frame, want)
	}
	if frame, _ := src.NextFrame(time.Now()); frame != nil {
		t.Fatalf("an empty predictive queue must answer idle, got %x", frame)
	}
}

func TestPassthroughIgnoresTheIdleTimeout(t *testing.T) {
	src, _ := newPassthrough(t, 8)
	src.PushFrame(ptIDR)
	_, _ = src.NextFrame(time.Now())
	later := time.Now().Add(10 * time.Second)
	if !src.IsActive(later) {
		t.Fatal("a still CarPlay screen must not deactivate the live source")
	}
	src.PushFrame(ptP1)
	if frame, _ := src.NextFrame(later); !bytes.Equal(frame, ptP1) {
		t.Fatalf("the P-frame after a long still must still be delivered, got %x", frame)
	}
}

func TestPassthroughOverflowRestartsAtAnIDR(t *testing.T) {
	src, requests := newPassthrough(t, 3)
	src.PushFrame(ptIDR)
	src.PushFrame(ptP1)
	src.PushFrame(ptP2)
	src.PushFrame(ptP1) // overflow: nothing may be dropped selectively
	waitFor(t, requests, 1)
	if frame, _ := src.NextFrame(time.Now()); frame != nil {
		t.Fatalf("after an overflow the queue must wait for an IDR, got %x", frame)
	}
	src.PushFrame(ptIDR)
	if frame, _ := src.NextFrame(time.Now()); !bytes.Equal(frame, ptIDR) {
		t.Fatalf("expected the new IDR, got %x", frame)
	}
}

func TestPassthroughStreamRestartAsksForIDR(t *testing.T) {
	src, requests := newPassthrough(t, 8)
	src.PushFrame(ptIDR)
	src.PrepareForConsumer()
	waitFor(t, requests, 1)
}

func TestDefaultSourceKeepsDroppingTheOldest(t *testing.T) {
	src := NewLiveStreamSource(30, 3*time.Second, 2)
	src.PushFrame(ptIDR)
	src.PushFrame(ptP1)
	src.PushFrame(ptP2)
	if frame, _ := src.NextFrame(time.Now()); !bytes.Equal(frame, ptP1) {
		t.Fatalf("encoder-fed sessions keep their old one-AU-per-poll behaviour, got %x", frame)
	}
}
