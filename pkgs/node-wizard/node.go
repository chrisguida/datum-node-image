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
	"sync"
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
	// the node did not answer in time; the values are the last ones it gave, AgeSeconds ago
	Stale      bool   `json:"stale"`
	AgeSeconds int    `json:"age_seconds,omitempty"`
	Error      string `json:"error,omitempty"`
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
	return a.rpcT(10*time.Second, method, params...)
}

// rpcT is rpc with its own time limit. While bitcoind validates the old history in the
// background it holds its main lock for seconds at a time, and getblockchaininfo waits for it.
func (a *App) rpcT(limit time.Duration, method string, params ...any) (json.RawMessage, error) {
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
	resp, err := (&http.Client{Timeout: limit}).Do(req)
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

// nodeCache holds the node's last answer. The node can take longer to answer than a page
// should take to load, so pages read this cache: a refresh runs in the background, a page
// waits a few seconds for it, and otherwise shows the last values with their age.
type nodeCache struct {
	mu       sync.Mutex
	st       nodeStatus
	at       time.Time // of the last answer; zero when there is none since the node last failed
	err      string
	timedOut bool
	inflight chan struct{}
}

const (
	nodeFresh    = 5 * time.Second  // an answer newer than this is served as it is
	nodeWait     = 4 * time.Second  // how long a page waits for a refresh
	nodeStale    = 30 * time.Second // an older answer is shown with its age
	nodeRPCLimit = 30 * time.Second // per call, in the background refresh
)

func isTimeout(err error) bool {
	var ne net.Error
	if errors.As(err, &ne) && ne.Timeout() {
		return true
	}
	return strings.Contains(err.Error(), "deadline exceeded") || strings.Contains(err.Error(), "timeout")
}

func (a *App) nodeStatus() nodeStatus {
	active := systemdActive(a.cfg.BitcoindUnit)
	c := &a.nodeCache
	c.mu.Lock()
	if c.inflight == nil && time.Since(c.at) > nodeFresh {
		ch := make(chan struct{})
		c.inflight = ch
		prev := c.st
		go func() {
			st, err := a.fetchNodeStatus(prev)
			c.mu.Lock()
			switch {
			case err == nil:
				c.st, c.at, c.err, c.timedOut = st, time.Now(), "", false
			case isTimeout(err):
				// a snapshot load or background validation holds bitcoind's main lock; keep the last answer
				c.err, c.timedOut = err.Error(), true
			default:
				c.st, c.at, c.err, c.timedOut = nodeStatus{}, time.Time{}, err.Error(), false
			}
			c.inflight = nil
			c.mu.Unlock()
			close(ch)
		}()
	}
	ch := c.inflight
	c.mu.Unlock()
	if ch != nil {
		select {
		case <-ch:
		case <-time.After(nodeWait):
		}
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	st := c.st
	st.Active = active
	switch {
	case c.at.IsZero():
		st.Error = c.err
		st.Busy = c.timedOut || (c.inflight != nil && c.err == "")
	case time.Since(c.at) > nodeStale:
		st.Stale = true
		st.AgeSeconds = int(time.Since(c.at).Seconds())
	}
	return st
}

// fetchNodeStatus asks the node. prev supplies the values of the two secondary calls when
// one of them fails after getblockchaininfo answered.
func (a *App) fetchNodeStatus(prev nodeStatus) (nodeStatus, error) {
	st := nodeStatus{Snapshot: prev.Snapshot, Background: prev.Background, Peers: prev.Peers}
	res, err := a.rpcT(nodeRPCLimit, "getblockchaininfo")
	if err != nil {
		return st, err
	}
	var bci struct {
		Headers  int64   `json:"headers"`
		Blocks   int64   `json:"blocks"`
		Progress float64 `json:"verificationprogress"`
		IBD      bool    `json:"initialblockdownload"`
	}
	if err := json.Unmarshal(res, &bci); err != nil {
		return st, err
	}
	st.Headers, st.Blocks, st.Progress, st.IBD = bci.Headers, bci.Blocks, bci.Progress, bci.IBD
	if res, err := a.rpcT(nodeRPCLimit, "getchainstates"); err == nil {
		var cs struct {
			Chainstates []struct {
				Blocks            int64  `json:"blocks"`
				SnapshotBlockhash string `json:"snapshot_blockhash"`
			} `json:"chainstates"`
		}
		if json.Unmarshal(res, &cs) == nil {
			st.Snapshot, st.Background = false, 0
		}
		if len(cs.Chainstates) == 2 {
			st.Snapshot = true
			for _, c := range cs.Chainstates {
				if c.SnapshotBlockhash == "" {
					st.Background = c.Blocks
				}
			}
		}
	}
	if res, err := a.rpcT(nodeRPCLimit, "getnetworkinfo"); err == nil {
		var ni struct {
			Connections int `json:"connections"`
		}
		if json.Unmarshal(res, &ni) == nil {
			st.Peers = ni.Connections
		}
	}
	return st, nil
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
		a.adoptPresetCode()
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
