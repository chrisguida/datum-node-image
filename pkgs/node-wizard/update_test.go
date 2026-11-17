package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestNewerRelease(t *testing.T) {
	rels := []releaseView{
		{Tag: "v2026.11.1-rc4", Prerelease: true},
		{Tag: "v2026.11.1-rc3", Prerelease: true},
		{Tag: "v2026.10.1"},
		{Tag: "nightly"},
	}
	cases := []struct{ running, want string }{
		{"v2026.11.1-rc3", "v2026.11.1-rc4"}, // a candidate is offered the next candidate
		{"v2026.11.1-rc4", ""},               // nothing newer
		{"v2026.11.1", ""},                   // the final is newer than its candidates
		{"v2026.10.1", ""},                   // a final release is not pointed at candidates
		{"v2026.9.2", "v2026.10.1"},          // month compares as a number
		{"v2026.10.1-rc1", "v2026.11.1-rc4"},
		{"", ""}, {"unknown", ""},
	}
	for _, c := range cases {
		if got := newerRelease(c.running, rels); got != c.want {
			t.Errorf("newerRelease(%q) = %q, want %q", c.running, got, c.want)
		}
	}
	if got := newerRelease("v2026.11.1-rc4", append(rels, releaseView{Tag: "v2026.11.1"})); got != "v2026.11.1" {
		t.Errorf("a candidate is offered its final release, got %q", got)
	}
}

func TestRebootRequired(t *testing.T) {
	dir := t.TempDir()
	old := systemLinks
	defer func() { systemLinks = old }()
	systemLinks = [2]string{filepath.Join(dir, "booted"), filepath.Join(dir, "current")}
	if rebootRequired() {
		t.Error("no links: no reboot")
	}
	link := func(sys, kernel string) {
		_ = os.MkdirAll(filepath.Join(dir, sys), 0o755)
		for _, f := range []string{"kernel", "kernel-modules"} {
			_ = os.Remove(filepath.Join(dir, sys, f))
			if err := os.Symlink("/nix/store/"+kernel+"/"+f, filepath.Join(dir, sys, f)); err != nil {
				t.Fatal(err)
			}
		}
	}
	link("booted", "linux-6.18.63")
	link("current", "linux-6.18.63")
	if rebootRequired() {
		t.Error("same kernel: no reboot")
	}
	link("current", "linux-6.18.70")
	if !rebootRequired() {
		t.Error("another kernel: reboot")
	}
}

func TestAdoptPresetCode(t *testing.T) {
	dir := t.TempDir()
	a := &App{cfg: config{SetupCodeFile: filepath.Join(dir, "setup-code"), SetupCodePreset: filepath.Join(dir, "preset")}}
	if err := a.ensureSetupCode(); err != nil {
		t.Fatal(err)
	}
	generated := a.currentSetupCode()
	a.adoptPresetCode() // no preset file
	if a.currentSetupCode() != generated {
		t.Error("code changed without a preset")
	}
	_ = os.WriteFile(a.cfg.SetupCodePreset, []byte("ab1\n"), 0o644) // too short
	a.adoptPresetCode()
	if a.currentSetupCode() != generated {
		t.Error("a short preset was taken")
	}
	_ = os.WriteFile(a.cfg.SetupCodePreset, []byte(" my-code-2026\n"), 0o644)
	a.adoptPresetCode()
	if got := a.currentSetupCode(); got != "MYCODE2026" {
		t.Errorf("preset not taken: %q", got)
	}
	if b, _ := os.ReadFile(a.cfg.SetupCodeFile); string(b) != "MYCODE2026\n" {
		t.Errorf("preset not saved: %q", b)
	}
	a.state.SetupDone = true
	_ = os.WriteFile(a.cfg.SetupCodePreset, []byte("another-code\n"), 0o644)
	a.adoptPresetCode()
	if a.currentSetupCode() != "MYCODE2026" {
		t.Error("preset taken after setup")
	}
}
