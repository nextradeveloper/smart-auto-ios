package net

import (
	"context"
	"encoding/json"
	stdnet "net"
	"testing"
	"time"
)

// The body has to match kh.b in the CarbitRide APK field for field: a head unit that
// reads a key we spelled differently learns nothing, and this command exists precisely
// to be understood.
func TestAppStatusBodyMatchesTheOfficialShape(t *testing.T) {
	body, err := buildAppStatusBody(PhoneScreen{Width: 1080, Height: 2400, Rotation: 0}, AppStatusMirrorLive)
	if err != nil {
		t.Fatalf("build body: %v", err)
	}
	var got map[string]any
	if err := json.Unmarshal(body, &got); err != nil {
		t.Fatalf("decode body: %v", err)
	}
	for _, key := range []string{"mode", "displayRotation", "width", "height", "enableAccessibility", "enableAOAHid"} {
		if _, ok := got[key]; !ok {
			t.Fatalf("body is missing %q: %s", key, body)
		}
	}
	if len(got) != 6 {
		t.Fatalf("body has %d keys, want the 6 kh.b writes: %s", len(got), body)
	}
}

// kh.b's constructor puts the long side in "height" when the phone is upright and in
// "width" when it is on its side, which is what rotation 1 and 3 mean.
func TestAppStatusReportsTheScreenTheWayTheRotationDoes(t *testing.T) {
	for _, tc := range []struct {
		name                  string
		rotation              int
		wantWidth, wantHeight float64
	}{
		{"upright", 0, 1080, 2400},
		{"rotated left", 1, 2400, 1080},
		{"upside down", 2, 1080, 2400},
		{"rotated right", 3, 2400, 1080},
	} {
		t.Run(tc.name, func(t *testing.T) {
			body, err := buildAppStatusBody(PhoneScreen{Width: 1080, Height: 2400, Rotation: tc.rotation}, AppStatusMirrorLive)
			if err != nil {
				t.Fatalf("build body: %v", err)
			}
			got := decodeNumbers(t, body)
			if got["width"] != tc.wantWidth || got["height"] != tc.wantHeight {
				t.Fatalf("size = %vx%v, want %vx%v", got["width"], got["height"], tc.wantWidth, tc.wantHeight)
			}
			if got["displayRotation"] != float64(tc.rotation) {
				t.Fatalf("displayRotation = %v, want %d", got["displayRotation"], tc.rotation)
			}
		})
	}
}

// kh.b.a(2) overrides the geometry it was constructed with: mode 2 always describes the
// phone upright. Getting this wrong would tell a dash the phone is landscape at the one
// moment the official app insists it is not.
func TestAppStatusBackgroundModeIsAlwaysUpright(t *testing.T) {
	body, err := buildAppStatusBody(PhoneScreen{Width: 1080, Height: 2400, Rotation: 3}, AppStatusBackground)
	if err != nil {
		t.Fatalf("build body: %v", err)
	}
	got := decodeNumbers(t, body)
	if got["displayRotation"] != 0 || got["width"] != 1080 || got["height"] != 2400 {
		t.Fatalf("mode 2 body = %s, want rotation 0 and 1080x2400", body)
	}
}

// enableAccessibility is the host's word that it acts on the dash's touches; it must
// follow TouchInput and never be claimed when the host did not say so.
func TestAppStatusClaimsTouchInputOnlyWhenTheHostDoes(t *testing.T) {
	for _, touch := range []bool{false, true} {
		body, err := buildAppStatusBody(PhoneScreen{Width: 1080, Height: 2400, TouchInput: touch}, AppStatusMirrorLive)
		if err != nil {
			t.Fatalf("build body: %v", err)
		}
		var got map[string]any
		if err := json.Unmarshal(body, &got); err != nil {
			t.Fatalf("decode body: %v", err)
		}
		if got["enableAccessibility"] != touch || got["enableAOAHid"] != false {
			t.Fatalf("touch=%v body = %s", touch, body)
		}
	}
}

// Off by default, and silent when off: every dashboard in the fleet that paints a
// picture today does it without ever having seen this command from us.
func TestAppStatusStaysOffUnlessAsked(t *testing.T) {
	control := NewPXCControl(":0", nil, nil)
	sent := 0
	control.OnAppStatus = func(int, error) { sent++ }
	control.SendAppStatus(AppStatusMirrorLive)
	if sent != 0 {
		t.Fatalf("OnAppStatus fired %d times with the notification off", sent)
	}
}

// A dash that says STREAM_START twice must not be told twice that the mirror went live -
// the same rule the page probe needed, for the same firmware.
func TestAppStatusSendsEachModeOnce(t *testing.T) {
	control := NewPXCControl(":0", nil, nil)
	control.SetAppStatusNotify(true)
	var modes []int
	control.OnAppStatus = func(mode int, err error) { modes = append(modes, mode) }

	control.SendAppStatus(AppStatusMirrorLive)
	control.SendAppStatus(AppStatusMirrorLive)
	control.SendAppStatus(AppStatusBackground)

	if len(modes) != 2 || modes[0] != AppStatusMirrorLive || modes[1] != AppStatusBackground {
		t.Fatalf("modes reported = %v, want one of each", modes)
	}
}

// The CFMOTO app only ever says mode 1, and the 1000 MT-X hangs up on a mode 2.
func TestAppStatusLiveOnlyNeverSendsBackground(t *testing.T) {
	control := NewPXCControl(":0", nil, nil)
	control.SetAppStatusNotify(true)
	control.SetAppStatusLiveOnly(true)
	var modes []int
	control.OnAppStatus = func(mode int, err error) { modes = append(modes, mode) }

	control.SendAppStatus(AppStatusBackground)
	control.SendAppStatus(AppStatusMirrorLive)

	if len(modes) != 1 || modes[0] != AppStatusMirrorLive {
		t.Fatalf("modes reported = %v, want only mode 1", modes)
	}
}

// decodeNumbers pulls the numeric fields out of a body that also carries booleans.
func decodeNumbers(t *testing.T, body []byte) map[string]float64 {
	t.Helper()
	var raw map[string]any
	if err := json.Unmarshal(body, &raw); err != nil {
		t.Fatalf("decode body: %v", err)
	}
	out := map[string]float64{}
	for key, value := range raw {
		if number, ok := value.(float64); ok {
			out[key] = number
		}
	}
	return out
}

// The official ZONTES app: FOREGROUND, the same mode every period, starting one period
// after the session is up, and none of the one-shot notifications.
func TestAppStatusRepeatSendsForegroundEveryPeriod(t *testing.T) {
	control := NewPXCControl(":0", nil, nil)
	control.SetAppStatusNotify(true)
	control.SetAppStatusRepeat(AppStatusBackground, true)
	control.SetPhoneScreen(PhoneScreen{Width: 1080, Height: 2640})
	control.appStatus.repeatEvery = 5 * time.Millisecond
	reports := make(chan int, 8)
	control.OnAppStatus = func(mode int, err error) {
		if err != nil {
			t.Errorf("app status reported %v", err)
		}
		reports <- mode
	}

	_, server := openControlChannel(t, control)
	control.SendAppStatus(AppStatusBackground) // the one-shot at CLIENT_INFO: must stay silent
	control.SendAppStatus(AppStatusMirrorLive) // the one-shot at STREAM_START: same
	control.StartAppStatusRepeat(0)
	control.StartAppStatusRepeat(0) // a second trigger must not start a second loop

	for i := 0; i < 3; i++ {
		got := readPXCResponse(t, server)
		if got.Command != PxcAppStatusForeground {
			t.Fatalf("frame %d command = 0x%x, want 0x%x (FOREGROUND)", i, got.Command, PxcAppStatusForeground)
		}
		numbers := decodeNumbers(t, got.Body)
		if numbers["mode"] != AppStatusBackground || numbers["width"] != 1080 || numbers["height"] != 2640 || numbers["displayRotation"] != 0 {
			t.Fatalf("frame %d body = %s, want mode 2 upright 1080x2640", i, got.Body)
		}
		var flags map[string]any
		_ = json.Unmarshal(got.Body, &flags)
		if flags["enableAOAHid"] != true {
			t.Fatalf("frame %d body = %s, want enableAOAHid true like the official Zontes app", i, got.Body)
		}
	}
	if mode := <-reports; mode != AppStatusBackground {
		t.Fatalf("first report mode = %d, want 2", mode)
	}
	select {
	case mode := <-reports:
		t.Fatalf("got a second report (mode %d); only the first send is reported", mode)
	default:
	}
	// A pipe write blocks until read: close our end so the loop's next write fails
	// instead of hanging Stop.
	_ = server.Close()
	stopControl(t, control)
}

func TestAppStatusRepeatNeedsTheNotificationOn(t *testing.T) {
	control := NewPXCControl(":0", nil, nil)
	control.SetAppStatusRepeat(AppStatusMirrorLive, true)
	control.appStatus.repeatEvery = time.Millisecond
	_, server := openControlChannel(t, control)

	control.StartAppStatusRepeat(0)

	if err := server.SetReadDeadline(time.Now().Add(50 * time.Millisecond)); err != nil {
		t.Fatal(err)
	}
	if _, err := server.Read(make([]byte, 1)); err == nil {
		t.Fatal("repeat sent something with the notification off")
	}
}

func stopControl(t *testing.T, control *PXCControl) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if err := control.Stop(ctx); err != nil {
		t.Fatalf("stop: %v", err)
	}
}

// On a Zontes dash both the app state and CHECK_SN_RESULT go on CAR_DATA, the official
// app's P2C socket, even when the dash asked CHECK_SN on CAR_CTRL.
func TestAppStatusRepeatAndCheckSnResultUseCarData(t *testing.T) {
	control := NewPXCControl(":0", nil, nil)
	control.SetAppStatusNotify(true)
	control.SetAppStatusRepeat(AppStatusBackground, true)
	control.appStatus.repeatEvery = time.Hour // only the first one matters here

	ctrlClient, ctrlServer := openControlChannel(t, control)
	dataClient, dataServer := stdnet.Pipe()
	t.Cleanup(func() { _ = dataClient.Close(); _ = dataServer.Close() })
	if err := dataServer.SetDeadline(time.Now().Add(2 * time.Second)); err != nil {
		t.Fatal(err)
	}
	go control.handleEvent(&PXCResponse{Command: PxcChannelCarData}, dataClient)
	if got := readPXCResponse(t, dataServer); got.Command != PxcChannelCarData+1 {
		t.Fatalf("CAR_DATA reply = 0x%x", got.Command)
	}
	if got := readPXCResponse(t, dataServer); got.Command != PxcAppStatusForeground {
		t.Fatalf("first frame on CAR_DATA = 0x%x, want FOREGROUND", got.Command)
	}

	go control.handleEvent(&PXCResponse{Command: PxcClientSet, Body: []byte(`{"client_set":"easy_conn","sn":"X"}`)}, ctrlClient)
	if got := readPXCResponse(t, ctrlServer); got.Command != PxcCheckSnAck {
		t.Fatalf("CHECK_SN ack on CAR_CTRL = 0x%x, want 0x%x", got.Command, PxcCheckSnAck)
	}
	if got := readPXCResponse(t, dataServer); got.Command != PxcCheckSnResult {
		t.Fatalf("CHECK_SN_RESULT went elsewhere: CAR_DATA got 0x%x", got.Command)
	}
	_ = dataServer.Close()
	_ = ctrlServer.Close()
	stopControl(t, control)
}
