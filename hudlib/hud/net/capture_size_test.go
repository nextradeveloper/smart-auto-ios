package net

import (
	"encoding/binary"
	"testing"
)

func captureRequest(width, height uint16) []byte {
	request := make([]byte, 30)
	binary.LittleEndian.PutUint16(request[0:2], width)
	binary.LittleEndian.PutUint16(request[2:4], height)
	binary.LittleEndian.PutUint32(request[8:12], mediaEncoderH264)
	request[29] = 0
	return request
}

func TestCaptureReplyEchoesTheDashWithoutAnOverride(t *testing.T) {
	payload := buildMediaCaptureAckPayloadSized(captureRequest(1280, 535), false, 0, 0)
	if w, h := binary.LittleEndian.Uint16(payload[4:6]), binary.LittleEndian.Uint16(payload[6:8]); w != 1280 || h != 528 {
		t.Fatalf("got %dx%d, want the aligned echo 1280x528", w, h)
	}
}

func TestCaptureReplyAnnouncesTheRelayedStreamSize(t *testing.T) {
	payload := buildMediaCaptureAckPayloadSized(captureRequest(1280, 535), false, 1920, 720)
	if w, h := binary.LittleEndian.Uint16(payload[4:6]), binary.LittleEndian.Uint16(payload[6:8]); w != 1920 || h != 720 {
		t.Fatalf("got %dx%d, want 1920x720", w, h)
	}
	if encoder := binary.LittleEndian.Uint32(payload[0:4]); encoder != mediaEncoderH264 {
		t.Fatalf("encoder %d, the override must not touch it", encoder)
	}
	if payload[8] != 0 {
		t.Fatalf("extended-protocol byte %d, must stay the dash's own", payload[8])
	}
}
