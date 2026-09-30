package main

import (
	"crypto/tls"
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"time"
)

// serveDashboard exposes the gateway's own dashboard (loopback HTTP) on a
// second HTTPS port, only to a browser that holds a wizard session. The
// gateway's protected pages still ask for its admin password, which the
// wizard shows under Settings > Advanced.
func (a *App) serveDashboard(certFile, keyFile string) {
	target, err := url.Parse(a.cfg.GatewayAPI)
	if err != nil {
		log.Printf("dashboard: %v", err)
		return
	}
	proxy := httputil.NewSingleHostReverseProxy(target)
	director := proxy.Director
	proxy.Director = func(r *http.Request) {
		director(r)
		r.Host = target.Host
		r.Header.Del("Cookie") // the wizard session is not the gateway's business
	}
	h := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !a.setupDone() || !a.authed(r) {
			http.Redirect(w, r, "https://"+hostOnly(r)+"/login", http.StatusFound)
			return
		}
		proxy.ServeHTTP(w, r)
	})
	srv := &http.Server{
		Addr:              a.cfg.DashboardListen,
		Handler:           h,
		ReadHeaderTimeout: 10 * time.Second,
		TLSConfig:         &tls.Config{MinVersion: tls.VersionTLS12},
	}
	log.Printf("gateway dashboard proxy on %s -> %s", a.cfg.DashboardListen, a.cfg.GatewayAPI)
	if err := srv.ListenAndServeTLS(certFile, keyFile); err != nil {
		log.Printf("dashboard listener: %v", err)
	}
}

func (a *App) dashboardURL(host string) string {
	if a.cfg.DashboardListen == "" {
		return ""
	}
	_, port, err := splitHostPort(a.cfg.DashboardListen)
	if err != nil || port == "" {
		return ""
	}
	return "https://" + host + ":" + port + "/"
}
