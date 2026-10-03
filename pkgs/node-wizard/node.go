package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"html"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"
)

type nodeStatus struct {
	Active   string  `json:"active"`
	Headers  int64   `json:"headers"`
	Blocks   int64   `json:"blocks"`
	Progress float64 `json:"progress"`
	IBD      bool    `json:"ibd"`
	Peers    int     `json:"peers"`
	// assumeutxo: a snapshot chainstate is active while the full history validates behind it
	Snapshot   bool  `json:"snapshot"`
	Background int64 `json:"background_blocks"`
	Busy     bool    `json:"busy"`
	Error    string  `json:"error,omitempty"`
}

type gatewayStatus struct {
	Active         string `json:"active"`
	Waiting        bool   `json:"waiting_for_address"`
	Connection     string `json:"connection"`
	Hashrate       string `json:"hashrate"`
	Workers        int    `json:"workers"`
	SharesAccepted string `json:"shares_accepted"`
	SharesRejected string `json:"shares_rejected"`
	Error          string `json:"error,omitempty"`
}

type fastStartStatus struct {
	Phase     string `json:"phase"`
	Percent   int    `json:"percent"`
	Detail    string `json:"detail"`
	UpdatedAt int64  `json:"updated_at"`
}

type statusData struct {
	FastStart  *fastStartStatus `json:"fast_start,omitempty"`
	Node       nodeStatus    `json:"node"`
	Gateway    gatewayStatus `json:"gateway"`
	DiskFreeGB float64       `json:"disk_free_gb"`
	StratumURL string        `json:"stratum_url"`
	UpdatedAt  time.Time     `json:"updated_at"`
}

func systemdActive(unit string) string {
	out, _ := exec.Command("systemctl", "is-active", unit).Output()
	s := strings.TrimSpace(string(out))
	if s == "" {
		return "unknown"
	}
	return s
}

// rpc calls bitcoind with the cookie the node profile makes group-readable.
func (a *App) rpc(method string, params ...any) (json.RawMessage, error) {
	cookie, err := os.ReadFile(a.cfg.BitcoindCookie)
	if err != nil {
		return nil, fmt.Errorf("cookie: %w", err)
	}
	user, pass, ok := strings.Cut(strings.TrimSpace(string(cookie)), ":")
	if !ok {
		return nil, errors.New("malformed cookie")
	}
	if params == nil {
		params = []any{}
	}
	body, _ := json.Marshal(map[string]any{"jsonrpc": "1.0", "id": "node-wizard", "method": method, "params": params})
	req, err := http.NewRequest(http.MethodPost, a.cfg.BitcoindRPC, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.SetBasicAuth(user, pass)
	req.Header.Set("Content-Type", "application/json")
	resp, err := a.httpClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	var out struct {
		Result json.RawMessage `json:"result"`
		Error  *struct {
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&out); err != nil {
		return nil, err
	}
	if out.Error != nil {
		return nil, errors.New(out.Error.Message)
	}
	return out.Result, nil
}

func (a *App) nodeStatus() nodeStatus {
	st := nodeStatus{Active: systemdActive(a.cfg.BitcoindUnit)}
	res, err := a.rpc("getblockchaininfo")
	if err != nil {
		// a snapshot load holds bitcoind's main lock during its flushes; RPC calls then time out
		if strings.Contains(err.Error(), "deadline exceeded") || strings.Contains(err.Error(), "timeout") {
			st.Busy = true
		}
		st.Error = err.Error()
		return st
	}
	var bci struct {
		Headers  int64   `json:"headers"`
		Blocks   int64   `json:"blocks"`
		Progress float64 `json:"verificationprogress"`
		IBD      bool    `json:"initialblockdownload"`
	}
	if err := json.Unmarshal(res, &bci); err != nil {
		st.Error = err.Error()
		return st
	}
	st.Headers, st.Blocks, st.Progress, st.IBD = bci.Headers, bci.Blocks, bci.Progress, bci.IBD
	if res, err := a.rpc("getchainstates"); err == nil {
		var cs struct {
			Chainstates []struct {
				Blocks            int64  `json:"blocks"`
				SnapshotBlockhash string `json:"snapshot_blockhash"`
			} `json:"chainstates"`
		}
		if json.Unmarshal(res, &cs) == nil && len(cs.Chainstates) == 2 {
			st.Snapshot = true
			for _, c := range cs.Chainstates {
				if c.SnapshotBlockhash == "" {
					st.Background = c.Blocks
				}
			}
		}
	}
	if res, err := a.rpc("getnetworkinfo"); err == nil {
		var ni struct {
			Connections int `json:"connections"`
		}
		if json.Unmarshal(res, &ni) == nil {
			st.Peers = ni.Connections
		}
	}
	return st
}

func (a *App) gatewayStatus() gatewayStatus {
	st := gatewayStatus{Active: systemdActive(a.cfg.GatewayUnit)}
	if st.Active != "active" {
		a.mu.Lock()
		st.Waiting = a.state.Gateway.Address == ""
		a.mu.Unlock()
		return st
	}
	if a.cfg.GatewayKind == "ratum" {
		a.ratumStatus(&st)
	} else {
		a.cGatewayStatus(&st)
	}
	return st
}

// ratumStatus reads ratum-gateway's /stats.json (public part, no login).
func (a *App) ratumStatus(st *gatewayStatus) {
	resp, err := a.httpClient.Get(a.cfg.GatewayAPI + "/stats.json")
	if err != nil {
		st.Error = err.Error()
		return
	}
	defer resp.Body.Close()
	var m map[string]any
	if err := json.NewDecoder(io.LimitReader(resp.Body, 4<<20)).Decode(&m); err != nil {
		st.Error = err.Error()
		return
	}
	if s, ok := m["status"].(string); ok {
		st.Connection = s
	}
	st.SharesAccepted = tallyString(m["shares_accepted"])
	st.SharesRejected = tallyString(m["shares_rejected"])
	if h, ok := m["hashrate"].(map[string]any); ok {
		if hist, ok := h["history"].([]any); ok && len(hist) > 0 {
			st.Hashrate = hashrateString(hist[len(hist)-1])
		}
	}
	for _, key := range []string{"stratum", "summary"} {
		if s, ok := m[key].(map[string]any); ok {
			for _, k := range []string{"connections", "clients", "subscribed"} {
				if v, ok := s[k].(float64); ok {
					st.Workers = int(v)
					break
				}
			}
		}
	}
}

func tallyString(v any) string {
	m, ok := v.(map[string]any)
	if !ok {
		return ""
	}
	if c, ok := m["count"].(float64); ok {
		return strconv.FormatInt(int64(c), 10)
	}
	return ""
}

func hashrateString(v any) string {
	switch x := v.(type) {
	case float64:
		return fmt.Sprintf("%.2f TH/s", x)
	case map[string]any:
		for _, k := range []string{"ths", "hashrate_ths", "hashrate", "value"} {
			if f, ok := x[k].(float64); ok {
				return fmt.Sprintf("%.2f TH/s", f)
			}
		}
	}
	return ""
}

var (
	cLabelRe = regexp.MustCompile(`(?s)<td class="label">([^<]+)</td>\s*<td[^>]*>(.*?)</td>`)
	tagRe    = regexp.MustCompile(`<[^>]*>`)
)

// cGatewayStatus scrapes the C gateway's dashboard, which has no JSON endpoint.
func (a *App) cGatewayStatus(st *gatewayStatus) {
	resp, err := a.httpClient.Get(a.cfg.GatewayAPI + "/")
	if err != nil {
		st.Error = err.Error()
		return
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		st.Error = err.Error()
		return
	}
	vals := map[string]string{}
	for _, m := range cLabelRe.FindAllStringSubmatch(string(b), -1) {
		vals[strings.TrimSpace(m[1])] = strings.TrimSpace(html.UnescapeString(tagRe.ReplaceAllString(m[2], "")))
	}
	st.Connection = vals["Status:"]
	st.Hashrate = vals["Estimated Hashrate:"]
	st.SharesAccepted = vals["Pool Shares Accepted:"]
	st.SharesRejected = vals["Pool Shares Rejected:"]
	if n, err := strconv.Atoi(vals["Total Connections:"]); err == nil {
		st.Workers = n
	}
}

func diskFreeGB(path string) float64 {
	var fs syscall.Statfs_t
	if err := syscall.Statfs(path, &fs); err != nil {
		return 0
	}
	return float64(fs.Bavail) * float64(fs.Bsize) / 1e9
}

func (a *App) fastStartStatus() *fastStartStatus {
	if a.cfg.FastStartFile == "" {
		return nil
	}
	b, err := os.ReadFile(a.cfg.FastStartFile)
	if err != nil {
		return nil
	}
	var f fastStartStatus
	if json.Unmarshal(b, &f) != nil {
		return nil
	}
	return &f
}

// fastStartLine is the one sentence the status page shows for the fast start.
func fastStartLine(lang string, s statusData) string {
	f := s.FastStart
	if f == nil {
		if s.Node.Snapshot {
			return fmt.Sprintf(tr(lang, "fs_background"), s.Node.Background)
		}
		return ""
	}
	switch f.Phase {
	case "headers":
		return tr(lang, "fs_headers")
	case "downloading":
		return fmt.Sprintf(tr(lang, "fs_downloading"), f.Percent)
	case "verifying":
		return tr(lang, "fs_verifying")
	case "loading":
		return fmt.Sprintf(tr(lang, "fs_loading"), f.Percent)
	case "catching_up", "done":
		if s.Node.Snapshot {
			return fmt.Sprintf(tr(lang, "fs_background"), s.Node.Background)
		}
		if s.Node.IBD {
			return tr(lang, "fs_catching_up")
		}
		return ""
	case "failed":
		return fmt.Sprintf(tr(lang, "fs_failed"), f.Detail)
	}
	return ""
}

func (a *App) collectStatus(host string) statusData {
	return statusData{
		FastStart:  a.fastStartStatus(),
		Node:       a.nodeStatus(),
		Gateway:    a.gatewayStatus(),
		DiskFreeGB: diskFreeGB("/var/lib"),
		StratumURL: fmt.Sprintf("stratum+tcp://%s:%d", host, a.cfg.StratumPort),
		UpdatedAt:  time.Now(),
	}
}

// primaryIP picks the address a person would type: a public IPv4 first, then any private one.
func primaryIP() string {
	addrs, err := net.InterfaceAddrs()
	if err != nil {
		return "<server-ip>"
	}
	private := ""
	for _, ad := range addrs {
		ipn, ok := ad.(*net.IPNet)
		if !ok {
			continue
		}
		ip := ipn.IP.To4()
		if ip == nil || ip.IsLoopback() || ip.IsLinkLocalUnicast() {
			continue
		}
		if ip.IsPrivate() {
			if private == "" {
				private = ip.String()
			}
			continue
		}
		return ip.String()
	}
	if private != "" {
		return private
	}
	return "<server-ip>"
}

// consoleLoop prints the setup code on the machine's consoles until setup is done,
// so a person with only the provider's web console can find it.
func (a *App) consoleLoop() {
	for {
		a.mu.Lock()
		done := a.state.SetupDone
		a.mu.Unlock()
		if done {
			return
		}
		msg := fmt.Sprintf("\r\n\r\n================ NODE SETUP ================\r\n"+
			"  Open in a browser:  https://%s/\r\n"+
			"  SETUP CODE:         %s\r\n"+
			"============================================\r\n\r\n",
			primaryIP(), a.setupCodeDisplay())
		for _, dev := range a.cfg.ConsoleDevices {
			f, err := os.OpenFile(dev, os.O_WRONLY|syscall.O_NOCTTY, 0)
			if err != nil {
				continue
			}
			_, _ = f.WriteString(msg)
			_ = f.Close()
		}
		time.Sleep(60 * time.Second)
	}
}
