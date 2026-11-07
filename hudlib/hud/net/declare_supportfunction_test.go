package net

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestDeclareSupportFunctionEcho(t *testing.T) {
	kp, err := GenKeyPair()
	if err != nil {
		t.Fatal(err)
	}
	pc := &PhoneConfig{PxcVersion: "1.0.2"}
	s := NewPXCControl(":0", kp, pc)
	s.DeclareSupportFunction = true
	s.HudConfig = &HUDConfig{HUID: "abc", SupportFunction: 128}
	if err := s.buildPC(); err != nil {
		t.Fatal(err)
	}
	b, _ := json.Marshal(s.PhoneConfig)
	js := string(b)
	for _, want := range []string{`"supportFunction":128`, `"supportFunctionEx":0`, `"haveSysScreenInSetting":true`} {
		if !strings.Contains(js, want) {
			t.Fatalf("missing %s in %s", want, js)
		}
	}
	s2 := NewPXCControl(":0", kp, &PhoneConfig{})
	s2.HudConfig = &HUDConfig{HUID: "abc", SupportFunction: 128}
	_ = s2.buildPC()
	b2, _ := json.Marshal(s2.PhoneConfig)
	if strings.Contains(string(b2), "supportFunction") {
		t.Fatalf("default reply must not carry supportFunction: %s", b2)
	}
}
