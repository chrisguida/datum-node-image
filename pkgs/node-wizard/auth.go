package main

import (
	"crypto/pbkdf2"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"net"
	"net/http"
	"sync"
	"time"
)

const pbkdf2Iterations = 600000

type passwordRecord struct {
	Salt string `json:"salt"`
	Hash string `json:"hash"`
	Iter int    `json:"iter"`
}

func hashPassword(pw string) (passwordRecord, error) {
	salt := make([]byte, 16)
	if _, err := rand.Read(salt); err != nil {
		return passwordRecord{}, err
	}
	key, err := pbkdf2.Key(sha256.New, pw, salt, pbkdf2Iterations, 32)
	if err != nil {
		return passwordRecord{}, err
	}
	return passwordRecord{
		Salt: hex.EncodeToString(salt),
		Hash: hex.EncodeToString(key),
		Iter: pbkdf2Iterations,
	}, nil
}

func (r passwordRecord) verify(pw string) bool {
	salt, err := hex.DecodeString(r.Salt)
	if err != nil {
		return false
	}
	want, err := hex.DecodeString(r.Hash)
	if err != nil || len(want) == 0 {
		return false
	}
	iter := r.Iter
	if iter <= 0 {
		iter = pbkdf2Iterations
	}
	key, err := pbkdf2.Key(sha256.New, pw, salt, iter, len(want))
	if err != nil {
		return false
	}
	return subtle.ConstantTimeCompare(key, want) == 1
}

func randomToken(n int) string {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return base64.RawURLEncoding.EncodeToString(b)
}

// randomCode makes a setup code from an alphabet without look-alike characters.
func randomCode(n int) string {
	const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	for i := range b {
		b[i] = alphabet[int(b[i])%len(alphabet)]
	}
	return string(b)
}

// sessions are in memory only; a restart signs everyone out.
type sessions struct {
	mu sync.Mutex
	m  map[string]time.Time
}

func newSessions() *sessions { return &sessions{m: map[string]time.Time{}} }

func (s *sessions) create() string {
	tok := randomToken(32)
	s.mu.Lock()
	s.m[tok] = time.Now().Add(24 * time.Hour)
	s.mu.Unlock()
	return tok
}

func (s *sessions) valid(tok string) bool {
	if tok == "" {
		return false
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	exp, ok := s.m[tok]
	if !ok {
		return false
	}
	if time.Now().After(exp) {
		delete(s.m, tok)
		return false
	}
	return true
}

func (s *sessions) drop(tok string) {
	s.mu.Lock()
	delete(s.m, tok)
	s.mu.Unlock()
}

// limiter locks a key (client address) for a while after too many failures.
type limiter struct {
	mu    sync.Mutex
	fails map[string]*failRecord
}

type failRecord struct {
	count int
	until time.Time
}

func newLimiter() *limiter { return &limiter{fails: map[string]*failRecord{}} }

func (l *limiter) allowed(key string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	rec, ok := l.fails[key]
	if !ok {
		return true
	}
	if time.Now().After(rec.until) {
		if !rec.until.IsZero() {
			delete(l.fails, key)
			return true
		}
		return rec.count == 0 || true
	}
	return false
}

func (l *limiter) fail(key string, max int, lock time.Duration) {
	l.mu.Lock()
	defer l.mu.Unlock()
	rec, ok := l.fails[key]
	if !ok {
		rec = &failRecord{}
		l.fails[key] = rec
	}
	rec.count++
	if rec.count >= max {
		rec.until = time.Now().Add(lock)
		rec.count = 0
	}
}

func (l *limiter) reset(key string) {
	l.mu.Lock()
	delete(l.fails, key)
	l.mu.Unlock()
}

func clientIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}
