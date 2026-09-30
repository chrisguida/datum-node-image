// node-wizard: the first-boot setup page and status dashboard for the
// datum-node-image. It runs unprivileged, writes one JSON file that the
// datum-gateway NixOS module merges into the gateway's configuration, and
// reads the node and gateway over their local APIs.
package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"embed"
	"encoding/json"
	"encoding/pem"
	"errors"
	"flag"
	"fmt"
	"html/template"
	"log"
	"math/big"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	qrcode "github.com/skip2/go-qrcode"
)

//go:embed templates/*.html
var templateFS embed.FS

type config struct {
	StateDir        string
	GatewaySettings string
	PoolsFile       string
	DefaultPool     string
	BitcoindCookie  string
	BitcoindRPC     string
	BitcoindUnit    string
	GatewayUnit     string
	GatewayAPI      string
	GatewayKind     string
	StratumPort     int
	Listen          string
	HTTPListen      string
	ConsoleDevices  []string
	SetupCodeFile   string
	DashboardListen string
	SampleInterval  time.Duration
}

type gatewayChoice struct {
	Address string `json:"address"`
	Tag     string `json:"tag"`
	Pool    string `json:"pool"` // a pools.json key, "solo" or "custom"
	Host    string `json:"host,omitempty"`
	Port    int    `json:"port,omitempty"`
	Pubkey  string `json:"pubkey,omitempty"`
}

type state struct {
	SetupDone            bool           `json:"setup_done"`
	Password             passwordRecord `json:"password"`
	Language             string         `json:"language"`
	GatewayAdminPassword string         `json:"gateway_admin_password"`
	Gateway              gatewayChoice  `json:"gateway"`
	CreatedAt            time.Time      `json:"created_at"`
}

type poolEntry struct {
	Key    string `json:"-"`
	Name   string `json:"name"`
	Host   string `json:"host"`
	Port   int    `json:"port"`
	Pubkey string `json:"pubkey"`
	URL    string `json:"url"`   // per-miner page; {address} is substituted
	Stats  string `json:"stats"` // JSON endpoint in the ratum pool schema, if any
}

type App struct {
	cfg        config
	mu         sync.Mutex
	state      state
	setupCode  string
	pools      []poolEntry
	tmpl       *template.Template
	sessions   *sessions
	limiter    *limiter
	httpClient *http.Client
	hashrate   *hashrateLog
	poolCache  *poolStatsCache
}

type pageData struct {
	Lang          string
	Path          string
	CSRF          string
	Error         string
	Notice        string
	Host          string
	Pools         []poolEntry
	Form          map[string]string
	Status        *statusView
	AdminPassword string
	SetupDone     bool
	DashboardURL  string
	Pool          *poolStatsView
	HashrateSVG   template.HTML
}

func (p pageData) T(k string) string { return tr(p.Lang, k) }

type statusView struct {
	statusData
	ProgressPct string
	DiskFree    string
	Updated     string
	Synced      bool
	// the gateway cannot get a template while the node syncs; that is not a fault
	GatewayWaitingSync bool
}

var (
	tagPattern    = regexp.MustCompile(`^[A-Za-z0-9 ._-]{0,32}$`)
	pubkeyPattern = regexp.MustCompile(`^[0-9a-fA-F]{128}$`)
)

func main() {
	var cfg config
	var consoles string
	flag.StringVar(&cfg.StateDir, "state-dir", "/var/lib/node-wizard", "private state (password, TLS key, setup code)")
	flag.StringVar(&cfg.GatewaySettings, "gateway-settings", "/var/lib/datum-wizard/gateway-settings.json", "JSON file the datum-gateway module merges")
	flag.StringVar(&cfg.PoolsFile, "pools", "/etc/node-wizard/pools.json", "pinned pool list")
	flag.StringVar(&cfg.DefaultPool, "default-pool", "", "pool key preselected in the form")
	flag.StringVar(&cfg.BitcoindCookie, "bitcoind-cookie", "/var/lib/bitcoind-blake2b/.cookie", "bitcoind RPC cookie")
	flag.StringVar(&cfg.BitcoindRPC, "bitcoind-rpc", "http://127.0.0.1:8332", "bitcoind RPC URL")
	flag.StringVar(&cfg.BitcoindUnit, "bitcoind-unit", "bitcoind-blake2b.service", "")
	flag.StringVar(&cfg.GatewayUnit, "gateway-unit", "datum-gateway.service", "")
	flag.StringVar(&cfg.GatewayAPI, "gateway-api", "http://127.0.0.1:7152", "gateway dashboard URL")
	flag.StringVar(&cfg.GatewayKind, "gateway-kind", "c", "c (datum_gateway) or ratum")
	flag.IntVar(&cfg.StratumPort, "stratum-port", 23334, "")
	flag.StringVar(&cfg.Listen, "listen", ":443", "HTTPS listen address")
	flag.StringVar(&cfg.HTTPListen, "http-listen", ":80", "HTTP listen address (redirects to HTTPS); empty disables")
	flag.StringVar(&consoles, "console-devices", "/dev/tty1,/dev/ttyS0", "where to print the setup code")
	flag.StringVar(&cfg.SetupCodeFile, "setup-code-file", "", "file holding a pre-set setup code (e.g. from cloud-init); default <state-dir>/setup-code")
	flag.StringVar(&cfg.DashboardListen, "dashboard-listen", ":7443", "HTTPS listen address for the proxied gateway dashboard; empty disables")
	flag.DurationVar(&cfg.SampleInterval, "sample-interval", 60*time.Second, "how often the gateway hashrate is sampled for the chart")
	flag.Parse()
	if consoles != "" {
		cfg.ConsoleDevices = strings.Split(consoles, ",")
	}
	if cfg.SetupCodeFile == "" {
		cfg.SetupCodeFile = filepath.Join(cfg.StateDir, "setup-code")
	}

	if err := loadLocales(); err != nil {
		log.Fatal(err)
	}
	tmpl, err := template.ParseFS(templateFS, "templates/*.html")
	if err != nil {
		log.Fatal(err)
	}
	app := &App{
		cfg:        cfg,
		tmpl:       tmpl,
		sessions:   newSessions(),
		limiter:    newLimiter(),
		httpClient: &http.Client{Timeout: 5 * time.Second},
	}
	if err := os.MkdirAll(cfg.StateDir, 0o700); err != nil {
		log.Fatal(err)
	}
	if err := app.loadState(); err != nil {
		log.Fatal(err)
	}
	if err := app.loadPools(); err != nil {
		log.Printf("pools: %v (custom and solo remain available)", err)
	}
	if err := app.ensureSetupCode(); err != nil {
		log.Fatal(err)
	}
	certFile, keyFile, err := app.ensureTLS()
	if err != nil {
		log.Fatal(err)
	}
	app.hashrate = loadHashrateLog(filepath.Join(cfg.StateDir, "hashrate.json"))
	app.poolCache = newPoolStatsCache()
	go app.consoleLoop()
	go app.sampleLoop()
	if cfg.DashboardListen != "" {
		go app.serveDashboard(certFile, keyFile)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/", app.handleRoot)
	mux.HandleFunc("/setup", app.handleSetup)
	mux.HandleFunc("/login", app.handleLogin)
	mux.HandleFunc("/logout", app.handleLogout)
	mux.HandleFunc("/lang", app.handleLang)
	mux.HandleFunc("/status", app.requireAuth(app.handleStatus))
	mux.HandleFunc("/api/status", app.requireAuth(app.handleAPIStatus))
	mux.HandleFunc("/settings", app.requireAuth(app.handleSettings))
	mux.HandleFunc("/qr.png", app.requireAuth(app.handleQR))

	if cfg.HTTPListen != "" {
		go func() {
			redirect := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				host := r.Host
				if h, _, err := net.SplitHostPort(host); err == nil {
					host = h
				}
				if host == "" {
					host = primaryIP()
				}
				http.Redirect(w, r, "https://"+host+"/", http.StatusFound)
			})
			log.Printf("http redirect on %s", cfg.HTTPListen)
			if err := http.ListenAndServe(cfg.HTTPListen, redirect); err != nil {
				log.Printf("http listener: %v", err)
			}
		}()
	}

	srv := &http.Server{
		Addr:              cfg.Listen,
		Handler:           securityHeaders(mux),
		ReadHeaderTimeout: 10 * time.Second,
		TLSConfig:         &tls.Config{MinVersion: tls.VersionTLS12},
	}
	log.Printf("node-wizard listening on %s (setup done: %v)", cfg.Listen, app.state.SetupDone)
	log.Fatal(srv.ListenAndServeTLS(certFile, keyFile))
}

// ---- state --------------------------------------------------------------

func (a *App) statePath() string { return filepath.Join(a.cfg.StateDir, "state.json") }

func (a *App) loadState() error {
	b, err := os.ReadFile(a.statePath())
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	return json.Unmarshal(b, &a.state)
}

func (a *App) saveState() error {
	a.mu.Lock()
	b, err := json.MarshalIndent(a.state, "", "  ")
	a.mu.Unlock()
	if err != nil {
		return err
	}
	return atomicWrite(a.statePath(), b, 0o600)
}

func atomicWrite(path string, data []byte, mode os.FileMode) error {
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, mode); err != nil {
		return err
	}
	if err := os.Chmod(tmp, mode); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

func (a *App) setupDone() bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.state.SetupDone
}

func (a *App) loadPools() error {
	b, err := os.ReadFile(a.cfg.PoolsFile)
	if err != nil {
		return err
	}
	m := map[string]poolEntry{}
	if err := json.Unmarshal(b, &m); err != nil {
		return err
	}
	for k, p := range m {
		p.Key = k
		if p.Name == "" {
			p.Name = k
		}
		a.pools = append(a.pools, p)
	}
	sort.Slice(a.pools, func(i, j int) bool {
		if a.pools[i].Key == a.cfg.DefaultPool {
			return true
		}
		if a.pools[j].Key == a.cfg.DefaultPool {
			return false
		}
		return a.pools[i].Name < a.pools[j].Name
	})
	return nil
}

func (a *App) ensureSetupCode() error {
	if b, err := os.ReadFile(a.cfg.SetupCodeFile); err == nil {
		code := normalizeCode(string(b))
		if len(code) >= 6 {
			a.setupCode = code
			return nil
		}
	}
	a.setupCode = randomCode(8)
	return atomicWrite(a.cfg.SetupCodeFile, []byte(a.setupCode+"\n"), 0o600)
}

func normalizeCode(s string) string {
	var b strings.Builder
	for _, c := range strings.ToUpper(s) {
		if (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') {
			b.WriteRune(c)
		}
	}
	return b.String()
}

func (a *App) setupCodeDisplay() string {
	c := a.setupCode
	if len(c) == 8 {
		return c[:4] + "-" + c[4:]
	}
	return c
}

// ensureTLS writes a self-signed certificate on first start.
func (a *App) ensureTLS() (string, string, error) {
	certFile := filepath.Join(a.cfg.StateDir, "tls.crt")
	keyFile := filepath.Join(a.cfg.StateDir, "tls.key")
	if _, err := os.Stat(certFile); err == nil {
		if _, err := os.Stat(keyFile); err == nil {
			return certFile, keyFile, nil
		}
	}
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return "", "", err
	}
	serial, _ := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	tmplCert := &x509.Certificate{
		SerialNumber:          serial,
		Subject:               pkix.Name{CommonName: "blake2b-node"},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().AddDate(10, 0, 0),
		KeyUsage:              x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
		DNSNames:              []string{"blake2b-node"},
	}
	if addrs, err := net.InterfaceAddrs(); err == nil {
		for _, ad := range addrs {
			if ipn, ok := ad.(*net.IPNet); ok && !ipn.IP.IsLoopback() {
				tmplCert.IPAddresses = append(tmplCert.IPAddresses, ipn.IP)
			}
		}
	}
	der, err := x509.CreateCertificate(rand.Reader, tmplCert, tmplCert, &key.PublicKey, key)
	if err != nil {
		return "", "", err
	}
	keyDER, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		return "", "", err
	}
	if err := atomicWrite(certFile, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0o600); err != nil {
		return "", "", err
	}
	if err := atomicWrite(keyFile, pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: keyDER}), 0o600); err != nil {
		return "", "", err
	}
	return certFile, keyFile, nil
}

// writeGatewaySettings produces the runtime file the datum-gateway module merges.
func (a *App) writeGatewaySettings(st state) error {
	doc := map[string]any{
		"mining": map[string]any{
			"pool_address":           st.Gateway.Address,
			"coinbase_tag_secondary": st.Gateway.Tag,
		},
		"api": map[string]any{
			"admin_password": st.GatewayAdminPassword,
		},
	}
	switch st.Gateway.Pool {
	case "solo":
		doc["datum"] = map[string]any{"pool_host": "", "pooled_mining_only": false}
	default:
		doc["datum"] = map[string]any{
			"pool_host":          st.Gateway.Host,
			"pool_port":          st.Gateway.Port,
			"pool_pubkey":        st.Gateway.Pubkey,
			"pooled_mining_only": true,
		}
	}
	b, err := json.MarshalIndent(doc, "", "  ")
	if err != nil {
		return err
	}
	return atomicWrite(a.cfg.GatewaySettings, append(b, '\n'), 0o640)
}

// ---- http helpers ---------------------------------------------------------

func securityHeaders(h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Frame-Options", "DENY")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("Content-Security-Policy", "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; frame-ancestors 'none'")
		h.ServeHTTP(w, r)
	})
}

func setCookie(w http.ResponseWriter, name, value string, maxAge int, httpOnly bool) {
	http.SetCookie(w, &http.Cookie{
		Name: name, Value: value, Path: "/", MaxAge: maxAge,
		Secure: true, HttpOnly: httpOnly, SameSite: http.SameSiteStrictMode,
	})
}

func (a *App) authed(r *http.Request) bool {
	c, err := r.Cookie("session")
	return err == nil && a.sessions.valid(c.Value)
}

func (a *App) requireAuth(h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !a.setupDone() {
			http.Redirect(w, r, "/setup", http.StatusFound)
			return
		}
		if !a.authed(r) {
			http.Redirect(w, r, "/login", http.StatusFound)
			return
		}
		h(w, r)
	}
}

// csrf: double-submit cookie; the form field must equal the cookie.
func (a *App) csrfToken(w http.ResponseWriter, r *http.Request) string {
	if c, err := r.Cookie("csrf"); err == nil && len(c.Value) >= 16 {
		return c.Value
	}
	tok := randomToken(24)
	setCookie(w, "csrf", tok, 86400, true)
	return tok
}

func (a *App) csrfOK(r *http.Request) bool {
	c, err := r.Cookie("csrf")
	return err == nil && c.Value != "" && r.FormValue("csrf") == c.Value
}

func splitHostPort(s string) (string, string, error) { return net.SplitHostPort(s) }

func hostOnly(r *http.Request) string {
	h := r.Host
	if host, _, err := net.SplitHostPort(h); err == nil {
		h = host
	}
	if h == "" {
		h = primaryIP()
	}
	return h
}

func (a *App) page(w http.ResponseWriter, r *http.Request) pageData {
	a.mu.Lock()
	saved := a.state.Language
	done := a.state.SetupDone
	a.mu.Unlock()
	return pageData{
		Lang:      pickLang(r, saved),
		Path:      r.URL.Path,
		CSRF:      a.csrfToken(w, r),
		Host:      hostOnly(r),
		Pools:     a.pools,
		Form:      map[string]string{},
		SetupDone: done,
	}
}

func (a *App) render(w http.ResponseWriter, name string, pd pageData) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := a.tmpl.ExecuteTemplate(w, name, pd); err != nil {
		log.Printf("render %s: %v", name, err)
	}
}

// ---- handlers ---------------------------------------------------------------

func (a *App) handleRoot(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	switch {
	case !a.setupDone():
		http.Redirect(w, r, "/setup", http.StatusFound)
	case !a.authed(r):
		http.Redirect(w, r, "/login", http.StatusFound)
	default:
		http.Redirect(w, r, "/status", http.StatusFound)
	}
}

func (a *App) handleLang(w http.ResponseWriter, r *http.Request) {
	l := r.URL.Query().Get("l")
	next := r.URL.Query().Get("next")
	if !strings.HasPrefix(next, "/") || strings.HasPrefix(next, "//") {
		next = "/"
	}
	if validLang(l) {
		setCookie(w, "lang", l, 365*86400, false)
		if a.setupDone() && a.authed(r) {
			a.mu.Lock()
			a.state.Language = l
			a.mu.Unlock()
			_ = a.saveState()
		}
	}
	http.Redirect(w, r, next, http.StatusFound)
}

func (a *App) parseGatewayForm(r *http.Request, pd *pageData) (gatewayChoice, string) {
	var g gatewayChoice
	g.Address = strings.TrimSpace(r.FormValue("payout_address"))
	g.Tag = strings.TrimSpace(r.FormValue("tag"))
	g.Pool = r.FormValue("pool")
	pd.Form["payout_address"] = g.Address
	pd.Form["tag"] = g.Tag
	pd.Form["pool"] = g.Pool
	pd.Form["custom_host"] = strings.TrimSpace(r.FormValue("custom_host"))
	pd.Form["custom_port"] = strings.TrimSpace(r.FormValue("custom_port"))
	pd.Form["custom_pubkey"] = strings.TrimSpace(r.FormValue("custom_pubkey"))
	if err := validateAddress(g.Address); err != nil {
		return g, "err_address"
	}
	if !tagPattern.MatchString(g.Tag) {
		return g, "err_tag"
	}
	switch g.Pool {
	case "solo":
	case "custom":
		g.Host = pd.Form["custom_host"]
		port, err := strconv.Atoi(pd.Form["custom_port"])
		g.Port = port
		g.Pubkey = strings.ToLower(pd.Form["custom_pubkey"])
		if g.Host == "" || err != nil || port < 1 || port > 65535 || !pubkeyPattern.MatchString(g.Pubkey) {
			return g, "err_pool"
		}
	default:
		found := false
		for _, p := range a.pools {
			if p.Key == g.Pool {
				g.Host, g.Port, g.Pubkey = p.Host, p.Port, p.Pubkey
				found = true
			}
		}
		if !found {
			return g, "err_pool"
		}
	}
	return g, ""
}

func (a *App) handleSetup(w http.ResponseWriter, r *http.Request) {
	if a.setupDone() {
		http.Redirect(w, r, "/", http.StatusFound)
		return
	}
	pd := a.page(w, r)
	pd.Form["pool"] = a.cfg.DefaultPool
	if r.Method != http.MethodPost {
		a.render(w, "setup", pd)
		return
	}
	if !a.csrfOK(r) {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	key := "setup:" + clientIP(r)
	if !a.limiter.allowed(key) {
		pd.Error = pd.T("err_locked")
		a.render(w, "setup", pd)
		return
	}
	if l := r.FormValue("language"); validLang(l) {
		pd.Lang = l
		setCookie(w, "lang", l, 365*86400, false)
	}
	if normalizeCode(r.FormValue("setup_code")) != a.setupCode {
		a.limiter.fail(key, 5, 10*time.Minute)
		pd.Error = pd.T("err_code")
		a.render(w, "setup", pd)
		return
	}
	pw, pw2 := r.FormValue("password"), r.FormValue("password_confirm")
	if len(pw) < 8 {
		pd.Error = pd.T("err_password_short")
		a.render(w, "setup", pd)
		return
	}
	if pw != pw2 {
		pd.Error = pd.T("err_password_mismatch")
		a.render(w, "setup", pd)
		return
	}
	choice, errKey := a.parseGatewayForm(r, &pd)
	if errKey != "" {
		pd.Error = pd.T(errKey)
		a.render(w, "setup", pd)
		return
	}
	rec, err := hashPassword(pw)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	st := state{
		SetupDone:            true,
		Password:             rec,
		Language:             pd.Lang,
		GatewayAdminPassword: randomToken(18),
		Gateway:              choice,
		CreatedAt:            time.Now(),
	}
	if err := a.writeGatewaySettings(st); err != nil {
		log.Printf("gateway settings: %v", err)
		pd.Error = pd.T("err_write")
		a.render(w, "setup", pd)
		return
	}
	a.mu.Lock()
	a.state = st
	a.mu.Unlock()
	if err := a.saveState(); err != nil {
		log.Printf("state: %v", err)
	}
	a.limiter.reset(key)
	setCookie(w, "session", a.sessions.create(), 86400, true)
	log.Printf("setup completed from %s", clientIP(r))
	http.Redirect(w, r, "/status", http.StatusFound)
}

func (a *App) handleLogin(w http.ResponseWriter, r *http.Request) {
	if !a.setupDone() {
		http.Redirect(w, r, "/setup", http.StatusFound)
		return
	}
	pd := a.page(w, r)
	if r.Method != http.MethodPost {
		a.render(w, "login", pd)
		return
	}
	if !a.csrfOK(r) {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	key := "login:" + clientIP(r)
	if !a.limiter.allowed(key) {
		pd.Error = pd.T("err_locked")
		a.render(w, "login", pd)
		return
	}
	a.mu.Lock()
	ok := a.state.Password.verify(r.FormValue("password"))
	a.mu.Unlock()
	if !ok {
		a.limiter.fail(key, 5, 5*time.Minute)
		pd.Error = pd.T("err_login")
		a.render(w, "login", pd)
		return
	}
	a.limiter.reset(key)
	setCookie(w, "session", a.sessions.create(), 86400, true)
	http.Redirect(w, r, "/status", http.StatusFound)
}

func (a *App) handleLogout(w http.ResponseWriter, r *http.Request) {
	if c, err := r.Cookie("session"); err == nil {
		a.sessions.drop(c.Value)
	}
	setCookie(w, "session", "", -1, true)
	http.Redirect(w, r, "/login", http.StatusFound)
}

func (a *App) statusView(host string) *statusView {
	s := a.collectStatus(host)
	v := &statusView{statusData: s}
	v.ProgressPct = fmt.Sprintf("%.2f", s.Node.Progress*100)
	v.DiskFree = fmt.Sprintf("%.1f GB", s.DiskFreeGB)
	v.Updated = s.UpdatedAt.Format("15:04:05")
	v.Synced = !s.Node.IBD && s.Node.Headers > 0 && s.Node.Blocks >= s.Node.Headers
	if s.Node.IBD && strings.Contains(strings.ToLower(s.Gateway.Connection), "template") {
		v.GatewayWaitingSync = true
	}
	return v
}

func (a *App) handleStatus(w http.ResponseWriter, r *http.Request) {
	pd := a.page(w, r)
	pd.Status = a.statusView(pd.Host)
	pd.Pool = a.poolStatsView(pd.Lang)
	pd.HashrateSVG = a.hashrateSVG()
	pd.DashboardURL = a.dashboardURL(pd.Host)
	a.render(w, "status", pd)
}

func (a *App) handleAPIStatus(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(a.collectStatus(hostOnly(r)))
}

func (a *App) handleSettings(w http.ResponseWriter, r *http.Request) {
	pd := a.page(w, r)
	a.mu.Lock()
	g := a.state.Gateway
	pd.AdminPassword = a.state.GatewayAdminPassword
	a.mu.Unlock()
	pd.DashboardURL = a.dashboardURL(pd.Host)
	pd.Form["payout_address"] = g.Address
	pd.Form["tag"] = g.Tag
	pd.Form["pool"] = g.Pool
	if g.Pool == "custom" {
		pd.Form["custom_host"] = g.Host
		pd.Form["custom_port"] = strconv.Itoa(g.Port)
		pd.Form["custom_pubkey"] = g.Pubkey
	}
	if r.Method != http.MethodPost {
		a.render(w, "settings", pd)
		return
	}
	if !a.csrfOK(r) {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	switch r.FormValue("action") {
	case "gateway":
		choice, errKey := a.parseGatewayForm(r, &pd)
		if errKey != "" {
			pd.Error = pd.T(errKey)
			a.render(w, "settings", pd)
			return
		}
		a.mu.Lock()
		st := a.state
		st.Gateway = choice
		a.mu.Unlock()
		if err := a.writeGatewaySettings(st); err != nil {
			log.Printf("gateway settings: %v", err)
			pd.Error = pd.T("err_write")
			a.render(w, "settings", pd)
			return
		}
		a.mu.Lock()
		a.state.Gateway = choice
		a.mu.Unlock()
		_ = a.saveState()
		pd.Notice = pd.T("saved")
	case "password":
		a.mu.Lock()
		ok := a.state.Password.verify(r.FormValue("current_password"))
		a.mu.Unlock()
		pw, pw2 := r.FormValue("new_password"), r.FormValue("password_confirm")
		switch {
		case !ok:
			pd.Error = pd.T("err_login")
		case len(pw) < 8:
			pd.Error = pd.T("err_password_short")
		case pw != pw2:
			pd.Error = pd.T("err_password_mismatch")
		default:
			rec, err := hashPassword(pw)
			if err == nil {
				a.mu.Lock()
				a.state.Password = rec
				a.mu.Unlock()
				err = a.saveState()
			}
			if err != nil {
				pd.Error = pd.T("err_write")
			} else {
				pd.Notice = pd.T("password_changed")
			}
		}
	}
	a.render(w, "settings", pd)
}

func (a *App) handleQR(w http.ResponseWriter, r *http.Request) {
	text := fmt.Sprintf("stratum+tcp://%s:%d", hostOnly(r), a.cfg.StratumPort)
	png, err := qrcode.Encode(text, qrcode.Medium, 220)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "image/png")
	w.Header().Set("Cache-Control", "no-store")
	_, _ = w.Write(png)
}
