package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
)

// poolStats is what the pool says about this node's address. The ratum-based
// pools (OmegaPool, Paperclip) publish one JSON document with the same shape;
// pools without a known endpoint only get a link.
type poolStats struct {
	Name            string
	URL             string
	HasStats        bool
	Error           string
	InWindow        bool
	SharePct        float64
	YourHashrate    string
	PayoutPerBlock  string
	Payable         bool
	PoolHashrate    string
	NetworkShare    string
	FeePct          string
	BlocksFound     int64
	LuckPct         float64
	LastBlockHeight int64
	LastBlockAt     time.Time
	FetchedAt       time.Time
}

type poolStatsCache struct {
	mu  sync.Mutex
	key string
	at  time.Time
	val *poolStats
}

func newPoolStatsCache() *poolStatsCache { return &poolStatsCache{} }

func (a *App) poolStats() *poolStats {
	a.mu.Lock()
	g := a.state.Gateway
	a.mu.Unlock()
	if g.Pool == "" || g.Pool == "solo" || g.Pool == "custom" {
		return nil
	}
	var entry *poolEntry
	for i := range a.pools {
		if a.pools[i].Key == g.Pool {
			entry = &a.pools[i]
		}
	}
	if entry == nil {
		return nil
	}
	ps := &poolStats{Name: entry.Name, URL: strings.ReplaceAll(entry.URL, "{address}", g.Address)}
	if entry.Stats == "" {
		return ps
	}
	ps.HasStats = true
	key := entry.Stats + "|" + g.Address
	a.poolCache.mu.Lock()
	if a.poolCache.key == key && a.poolCache.val != nil && time.Since(a.poolCache.at) < time.Minute {
		v := *a.poolCache.val
		a.poolCache.mu.Unlock()
		return &v
	}
	a.poolCache.mu.Unlock()
	if entry.Schema == "lazarus" {
		fillLazarusStats(ps, entry.Stats, g.Address)
	} else {
		fillPoolStats(ps, entry.Stats, g.Address)
	}
	a.poolCache.mu.Lock()
	a.poolCache.key, a.poolCache.at, a.poolCache.val = key, time.Now(), ps
	a.poolCache.mu.Unlock()
	return ps
}

func fillPoolStats(ps *poolStats, url, address string) {
	client := &http.Client{Timeout: 8 * time.Second}
	resp, err := client.Get(url)
	if err != nil {
		ps.Error = err.Error()
		return
	}
	defer resp.Body.Close()
	var doc map[string]any
	if err := json.NewDecoder(io.LimitReader(resp.Body, 8<<20)).Decode(&doc); err != nil {
		ps.Error = err.Error()
		return
	}
	root := doc
	if s, ok := doc["stats"].(map[string]any); ok {
		root = s
	}
	ps.FetchedAt = time.Now()
	if pool, ok := root["pool"].(map[string]any); ok {
		if f, ok := pool["fee_bps"].(float64); ok {
			ps.FeePct = strconv.FormatFloat(f/100, 'f', -1, 64) + "%"
		}
	}
	if hr, ok := root["hashrate"].(map[string]any); ok {
		if f, ok := hr["pool_hs"].(float64); ok {
			ps.PoolHashrate = fmtHashrate(f)
		}
		if f, ok := hr["pool_share"].(float64); ok {
			ps.NetworkShare = fmt.Sprintf("%.2f%%", f*100)
		}
	}
	if bl, ok := root["blocks"].(map[string]any); ok {
		if f, ok := bl["found"].(float64); ok {
			ps.BlocksFound = int64(f)
		}
		if f, ok := bl["luck_percent"].(float64); ok {
			ps.LuckPct = f
		}
		if rec, ok := bl["recent"].([]any); ok {
			for _, r := range rec {
				b, ok := r.(map[string]any)
				if !ok {
					continue
				}
				h, _ := b["height"].(float64)
				if int64(h) > ps.LastBlockHeight {
					ps.LastBlockHeight = int64(h)
					if t, ok := b["found_at"].(float64); ok {
						ps.LastBlockAt = time.Unix(int64(t), 0)
					}
				}
			}
		}
	}
	if w, ok := root["window"].(map[string]any); ok {
		if miners, ok := w["miners"].([]any); ok {
			for _, m := range miners {
				mm, ok := m.(map[string]any)
				if !ok {
					continue
				}
				if id, _ := mm["identity"].(string); !strings.EqualFold(id, address) {
					continue
				}
				ps.InWindow = true
				if f, ok := mm["share_percent"].(float64); ok {
					ps.SharePct = f
				}
				if f, ok := mm["hashrate_hs"].(float64); ok {
					ps.YourHashrate = fmtHashrate(f)
				}
				if f, ok := mm["payout_sats"].(float64); ok {
					ps.PayoutPerBlock = fmtCoins(int64(f))
				}
				if b, ok := mm["payable"].(bool); ok {
					ps.Payable = b
				}
				break
			}
		}
	}
}

func getJSON(client *http.Client, url string) (map[string]any, error) {
	resp, err := client.Get(url)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	var m map[string]any
	if err := json.NewDecoder(io.LimitReader(resp.Body, 8<<20)).Decode(&m); err != nil {
		return nil, err
	}
	return m, nil
}

func num(m map[string]any, key string) (float64, bool) {
	f, ok := m[key].(float64)
	return f, ok
}

// fillLazarusStats reads Lazarus's own API: /pool, /miner/<address>, /blocks.
func fillLazarusStats(ps *poolStats, base, address string) {
	client := &http.Client{Timeout: 8 * time.Second}
	base = strings.TrimRight(base, "/")
	pool, err := getJSON(client, base+"/pool")
	if err != nil {
		ps.Error = err.Error()
		return
	}
	ps.FetchedAt = time.Now()
	if f, ok := num(pool, "pool_hr_ghs"); ok {
		ps.PoolHashrate = fmtHashrate(f * 1e9)
	}
	if f, ok := num(pool, "pool_share"); ok {
		ps.NetworkShare = fmt.Sprintf("%.2f%%", f*100)
	}
	if f, ok := num(pool, "blocks_found"); ok {
		ps.BlocksFound = int64(f)
	}
	if f, ok := num(pool, "luck_percent"); ok {
		ps.LuckPct = f
	}
	if fees, ok := pool["fees"].(map[string]any); ok {
		if f, ok := num(fees, "datum_percent"); ok {
			ps.FeePct = strconv.FormatFloat(f, 'f', -1, 64) + "%"
		}
	}
	if blocks, err := getJSON(client, base+"/blocks"); err == nil {
		if list, ok := blocks["blocks"].([]any); ok {
			for _, b := range list {
				bm, ok := b.(map[string]any)
				if !ok {
					continue
				}
				if p, _ := bm["pool"].(string); !strings.EqualFold(p, "Lazarus") {
					continue
				}
				if h, ok := num(bm, "height"); ok && int64(h) > ps.LastBlockHeight {
					ps.LastBlockHeight = int64(h)
					if t, ok := num(bm, "timestamp"); ok {
						ps.LastBlockAt = time.Unix(int64(t), 0)
					}
				}
			}
		}
	}
	miner, err := getJSON(client, base+"/miner/"+address)
	if err != nil {
		return
	}
	if known, _ := miner["known"].(bool); !known {
		return
	}
	if f, ok := num(miner, "window_percent"); ok && f > 0 {
		ps.InWindow = true
		ps.SharePct = f
	}
	if f, ok := num(miner, "hr_ghs"); ok {
		ps.YourHashrate = fmtHashrate(f * 1e9)
	}
	if f, ok := num(miner, "window_sats"); ok {
		ps.PayoutPerBlock = fmtCoins(int64(f))
	}
	if online, ok := miner["online"].(bool); ok {
		ps.Payable = online
	}
}

func fmtHashrate(hs float64) string {
	units := []string{"H/s", "KH/s", "MH/s", "GH/s", "TH/s", "PH/s", "EH/s"}
	i := 0
	for hs >= 1000 && i < len(units)-1 {
		hs /= 1000
		i++
	}
	return fmt.Sprintf("%.2f %s", hs, units[i])
}

func fmtCoins(sats int64) string {
	return strconv.FormatFloat(float64(sats)/1e8, 'f', 8, 64)
}

// poolStatsView is the pool card with every value already formatted for the page.
type poolStatsView struct {
	Name, URL    string
	HasStats     bool
	Error        string
	InWindow     bool
	Share        string
	YourHashrate string
	Payout       string
	PoolHashrate string
	NetworkShare string
	Fee          string
	Blocks       string
	LastBlock    string
}

func (a *App) poolStatsView(lang string) *poolStatsView {
	ps := a.poolStats()
	if ps == nil {
		return nil
	}
	v := &poolStatsView{
		Name: ps.Name, URL: ps.URL, HasStats: ps.HasStats, Error: ps.Error, InWindow: ps.InWindow,
		Share:        fmt.Sprintf("%.2f%%", ps.SharePct),
		YourHashrate: ps.YourHashrate,
		Payout:       ps.PayoutPerBlock,
		PoolHashrate: ps.PoolHashrate,
		NetworkShare: ps.NetworkShare,
		Fee:          ps.FeePct,
	}
	if ps.BlocksFound > 0 {
		v.Blocks = fmt.Sprintf("%d (%.0f%% %s)", ps.BlocksFound, ps.LuckPct, tr(lang, "luck"))
	}
	if ps.LastBlockHeight > 0 {
		v.LastBlock = fmt.Sprintf("%d, %s", ps.LastBlockHeight, ago(lang, time.Since(ps.LastBlockAt)))
	}
	return v
}

func ago(lang string, d time.Duration) string {
	switch {
	case d < time.Hour:
		return fmt.Sprintf(tr(lang, "min_ago"), int(d.Minutes()))
	case d < 48*time.Hour:
		return fmt.Sprintf(tr(lang, "hours_ago"), int(d.Hours()))
	default:
		return fmt.Sprintf(tr(lang, "days_ago"), int(d.Hours()/24))
	}
}
