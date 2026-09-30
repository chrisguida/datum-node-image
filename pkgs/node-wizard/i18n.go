package main

import (
	"embed"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
)

//go:embed locales/*.json
var localeFS embed.FS

var languages = []string{"zh-CN", "en"}

var locales = map[string]map[string]string{}

func loadLocales() error {
	for _, l := range languages {
		b, err := localeFS.ReadFile("locales/" + l + ".json")
		if err != nil {
			return err
		}
		m := map[string]string{}
		if err := json.Unmarshal(b, &m); err != nil {
			return fmt.Errorf("locale %s: %w", l, err)
		}
		locales[l] = m
	}
	return nil
}

func validLang(l string) bool {
	_, ok := locales[l]
	return ok
}

// pickLang: explicit cookie, else the browser's Accept-Language, else English.
func pickLang(r *http.Request, fallback string) string {
	if c, err := r.Cookie("lang"); err == nil && validLang(c.Value) {
		return c.Value
	}
	if validLang(fallback) && fallback != "" {
		// a saved preference (state) beats Accept-Language
		return fallback
	}
	al := strings.ToLower(r.Header.Get("Accept-Language"))
	if strings.Contains(al, "zh") {
		return "zh-CN"
	}
	return "en"
}

func tr(lang, key string) string {
	if v, ok := locales[lang][key]; ok {
		return v
	}
	if v, ok := locales["en"][key]; ok {
		return v
	}
	return key
}
