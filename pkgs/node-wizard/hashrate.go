package main

import (
	"encoding/json"
	"fmt"
	"html/template"
	"os"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

// hashrateLog keeps one gateway hashrate sample per minute for a day and draws
// it as an inline SVG, so the status page has a history without any script.
type hrSample struct {
	T int64   `json:"t"` // unix seconds
	V float64 `json:"v"` // TH/s
}

type hashrateLog struct {
	mu      sync.Mutex
	path    string
	samples []hrSample
	dirty   int
}

const hrKeep = 24 * 60

func loadHashrateLog(path string) *hashrateLog {
	h := &hashrateLog{path: path}
	if b, err := os.ReadFile(path); err == nil {
		_ = json.Unmarshal(b, &h.samples)
	}
	return h
}

func (h *hashrateLog) add(v float64) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.samples = append(h.samples, hrSample{T: time.Now().Unix(), V: v})
	if len(h.samples) > hrKeep {
		h.samples = h.samples[len(h.samples)-hrKeep:]
	}
	h.dirty++
	if h.dirty >= 5 {
		h.dirty = 0
		if b, err := json.Marshal(h.samples); err == nil {
			_ = atomicWrite(h.path, b, 0o600)
		}
	}
}

func (h *hashrateLog) last24h() []hrSample {
	cutoff := time.Now().Add(-24 * time.Hour).Unix()
	h.mu.Lock()
	defer h.mu.Unlock()
	out := make([]hrSample, 0, len(h.samples))
	for _, s := range h.samples {
		if s.T >= cutoff {
			out = append(out, s)
		}
	}
	return out
}

var hrPattern = regexp.MustCompile(`^\s*([0-9]+(?:\.[0-9]+)?)\s*([KMGTPE]?)[hH]`)

// parseHashrateTHs reads "12.34 Th/sec" (C gateway) or "12.34 TH/s" (ours) as TH/s.
func parseHashrateTHs(s string) (float64, bool) {
	m := hrPattern.FindStringSubmatch(s)
	if m == nil {
		return 0, false
	}
	v, err := strconv.ParseFloat(m[1], 64)
	if err != nil {
		return 0, false
	}
	switch strings.ToUpper(m[2]) {
	case "":
		v /= 1e12
	case "K":
		v /= 1e9
	case "M":
		v /= 1e6
	case "G":
		v /= 1e3
	case "T":
	case "P":
		v *= 1e3
	case "E":
		v *= 1e6
	}
	return v, true
}

func (a *App) sampleLoop() {
	for {
		time.Sleep(a.cfg.SampleInterval)
		v := 0.0
		if systemdActive(a.cfg.GatewayUnit) == "active" {
			st := a.gatewayStatus()
			if f, ok := parseHashrateTHs(st.Hashrate); ok {
				v = f
			}
		}
		a.hashrate.add(v)
	}
}

// hashrateSVG draws the last 24 hours; empty until there are two samples.
func (a *App) hashrateSVG() template.HTML {
	samples := a.hashrate.last24h()
	if len(samples) < 2 {
		return ""
	}
	const w, h, padL, padR, padT, padB = 600.0, 140.0, 8.0, 8.0, 18.0, 18.0
	now := float64(time.Now().Unix())
	start := now - 24*3600
	max := 0.0
	for _, s := range samples {
		if s.V > max {
			max = s.V
		}
	}
	if max <= 0 {
		max = 1
	}
	var pts strings.Builder
	for i, s := range samples {
		x := padL + (float64(s.T)-start)/(24*3600)*(w-padL-padR)
		y := padT + (1-s.V/max)*(h-padT-padB)
		if i > 0 {
			pts.WriteByte(' ')
		}
		fmt.Fprintf(&pts, "%.1f,%.1f", x, y)
	}
	last := samples[len(samples)-1].V
	svg := fmt.Sprintf(`<svg viewBox="0 0 %.0f %.0f" width="100%%" role="img" aria-label="hashrate" style="display:block;background:#f5f6f8;border-radius:8px">`+
		`<line x1="%.0f" y1="%.0f" x2="%.0f" y2="%.0f" stroke="#c9ced6" stroke-width="1"/>`+
		`<polyline fill="none" stroke="#2c6bed" stroke-width="2" points="%s"/>`+
		`<text x="%.0f" y="13" font-size="11" fill="#5b6470">%.2f TH/s</text>`+
		`<text x="%.0f" y="%.0f" font-size="11" fill="#5b6470" text-anchor="end">%.2f TH/s</text>`+
		`</svg>`,
		w, h,
		padL, h-padB, w-padR, h-padB,
		pts.String(),
		padL, max,
		w-padR, h-4, last)
	return template.HTML(svg)
}
