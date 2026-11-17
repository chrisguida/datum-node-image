package main

// The Update page: which Bitcoin Knots build runs (and switching it), and
// updating the whole image to a signed release tag. The wizard itself only
// writes two small files in its settings directory and asks systemd, through
// a polkit rule scoped to two units, to restart the node or start the updater.

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// ---- files the NixOS modules write -----------------------------------------------------

// /etc/datum-node-image/knots-builds.json
type knotsBuildInfo struct {
	Version           string  `json:"version"`
	AssumeutxoHeights []int64 `json:"assumeutxoHeights"`
	Store             string  `json:"store"`
}

type knotsBuildsFile struct {
	Default  string                    `json:"default"`
	Selector string                    `json:"selector"`
	Builds   map[string]knotsBuildInfo `json:"builds"`
}

// /etc/datum-node-image/image.json
type imageInfo struct {
	Version           string `json:"version"` // the release this image is, from the changelog; "" before v2026.11.1-rc4
	Rev               string `json:"rev"`
	Variant           string `json:"variant"`
	SnapshotHeight    int64  `json:"snapshotHeight"`
	SnapshotBlockhash string `json:"snapshotBlockhash"`
}

// /var/lib/node-updater/status
type updaterStatus struct {
	State     string `json:"state"`
	Message   string `json:"message"`
	Tag       string `json:"tag"`
	Timestamp int64  `json:"timestamp"`
}

var releaseTagPattern = regexp.MustCompile(`^v[0-9A-Za-z._-]{1,63}$`)

func readJSONFile(path string, v any) error {
	b, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	return json.Unmarshal(b, v)
}

func (a *App) knotsBuilds() (knotsBuildsFile, error) {
	var kb knotsBuildsFile
	if a.cfg.KnotsBuildsFile == "" {
		return kb, errors.New("no knots-builds file configured")
	}
	err := readJSONFile(a.cfg.KnotsBuildsFile, &kb)
	if err == nil && kb.Builds == nil {
		kb.Builds = map[string]knotsBuildInfo{}
	}
	return kb, err
}

func (a *App) imageInfo() imageInfo {
	var img imageInfo
	if a.cfg.ImageInfoFile != "" {
		_ = readJSONFile(a.cfg.ImageInfoFile, &img)
	}
	if img.Rev == "" {
		img.Rev = "unknown"
	}
	if img.Variant == "" {
		img.Variant = "unknown"
	}
	return img
}

func firstLine(path string) string {
	b, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	line, _, _ := strings.Cut(string(b), "\n")
	return strings.TrimSpace(line)
}

// selectedKnotsBuild is what the selector file names (the build the next start runs).
func (a *App) selectedKnotsBuild(kb knotsBuildsFile) string {
	if name := firstLine(a.cfg.KnotsSelectorFile); name != "" {
		if _, ok := kb.Builds[name]; ok {
			return name
		}
	}
	return kb.Default
}

// runningKnotsBuild is what bitcoind's wrapper recorded when the service started; ok is
// false when the node is not running (the runtime directory is gone with it).
func (a *App) runningKnotsBuild(kb knotsBuildsFile) (string, bool) {
	if name := firstLine(a.cfg.KnotsRunningFile); name != "" {
		if _, ok := kb.Builds[name]; ok {
			return name, true
		}
	}
	return "", false
}

// ---- the node's snapshot state ----------------------------------------------------------

type snapshotState struct {
	Reachable bool   // getchainstates answered
	Active    bool   // a snapshot chainstate exists on disk
	Validated bool   // its background validation has finished (one restart removes it)
	Blockhash string // the snapshot's base block
	Height    int64  // 0 when unknown
}

// snapCache keeps the last snapshot state the node reported, for the minutes in which the node
// is too slow to answer. The state only moves forward (active, validated, gone), so an old
// answer never offers a switch that a fresh one would refuse.
type snapCache struct {
	mu sync.Mutex
	st snapshotState
	at time.Time
}

func (a *App) snapshotState(img imageInfo) snapshotState {
	st := a.fetchSnapshotState(img)
	c := &a.snapCache
	c.mu.Lock()
	defer c.mu.Unlock()
	if st.Reachable {
		c.st, c.at = st, time.Now()
		return st
	}
	if !c.at.IsZero() && time.Since(c.at) < 15*time.Minute && systemdActive(a.cfg.BitcoindUnit) == "active" {
		return c.st
	}
	return st
}

func (a *App) fetchSnapshotState(img imageInfo) snapshotState {
	var st snapshotState
	res, err := a.rpc("getchainstates")
	if err != nil {
		return st
	}
	var cs struct {
		Chainstates []struct {
			SnapshotBlockhash string `json:"snapshot_blockhash"`
			Validated         bool   `json:"validated"`
		} `json:"chainstates"`
	}
	if json.Unmarshal(res, &cs) != nil {
		return st
	}
	st.Reachable = true
	for _, c := range cs.Chainstates {
		if c.SnapshotBlockhash != "" {
			st.Active = true
			st.Blockhash = c.SnapshotBlockhash
			st.Validated = c.Validated
		}
	}
	if !st.Active {
		return st
	}
	// the header of the snapshot block is always known to the node
	if res, err := a.rpc("getblockheader", st.Blockhash); err == nil {
		var h struct {
			Height int64 `json:"height"`
		}
		if json.Unmarshal(res, &h) == nil && h.Height > 0 {
			st.Height = h.Height
		}
	}
	if st.Height == 0 && img.SnapshotBlockhash != "" && strings.EqualFold(img.SnapshotBlockhash, st.Blockhash) {
		st.Height = img.SnapshotHeight
	}
	return st
}

func hasHeight(b knotsBuildInfo, h int64) bool {
	for _, x := range b.AssumeutxoHeights {
		if x == h {
			return true
		}
	}
	return false
}

// switchGuard decides whether a build may be switched to right now. A node that started
// from a snapshot keeps a snapshot chainstate until the background validation finishes and
// it restarts once; in that time only a build whose chainparams carry the snapshot can
// start (Knots otherwise stops with "Assumeutxo data not found for the given blockhash").
func switchGuard(lang string, b knotsBuildInfo, snap snapshotState, img imageInfo) (bool, string) {
	switch {
	case !snap.Reachable:
		// unknown state: offer only what is safe under the image's own snapshot
		if img.SnapshotHeight > 0 {
			if hasHeight(b, img.SnapshotHeight) {
				return true, ""
			}
			return false, fmt.Sprintf(tr(lang, "knots_guard_unreachable"), img.SnapshotHeight)
		}
		return false, tr(lang, "knots_guard_unknown")
	case !snap.Active:
		return true, ""
	case snap.Height == 0:
		return false, tr(lang, "knots_guard_unknown")
	case hasHeight(b, snap.Height):
		return true, ""
	default:
		return false, fmt.Sprintf(tr(lang, "knots_guard"), snap.Height)
	}
}

// ---- releases (GitHub API, cached) ------------------------------------------------------

type releaseView struct {
	Tag        string
	Name       string
	Date       string
	Notes      string
	URL        string
	Prerelease bool
}

type releaseCache struct {
	mu         sync.Mutex
	at         time.Time
	val        []releaseView
	err        string
	errAt      time.Time
	refreshing bool
}

// releasesCached is releases for pages that must not wait for GitHub: it returns what is
// known now and refreshes in the background when that is older than ten minutes.
func (a *App) releasesCached() []releaseView {
	if a.cfg.ReleasesURL == "" {
		return nil
	}
	c := a.releaseCache
	c.mu.Lock()
	defer c.mu.Unlock()
	if !c.refreshing && time.Since(c.at) > 10*time.Minute && time.Since(c.errAt) > 2*time.Minute {
		c.refreshing = true
		go func() {
			val, err := fetchReleases(a.cfg.ReleasesURL)
			c.mu.Lock()
			if err != nil {
				c.err, c.errAt = err.Error(), time.Now()
			} else {
				c.val, c.at, c.err = val, time.Now(), ""
			}
			c.refreshing = false
			c.mu.Unlock()
		}()
	}
	return c.val
}

// relVersion is a release tag vYEAR.MONTH.N or vYEAR.MONTH.N-rcK; a final release sorts
// after its candidates.
type relVersion struct{ y, m, n, rc int }

var relVersionPattern = regexp.MustCompile(`^v(\d{1,9})\.(\d{1,9})\.(\d{1,9})(?:-rc(\d{1,9}))?$`)

func parseRelVersion(s string) (relVersion, bool) {
	m := relVersionPattern.FindStringSubmatch(s)
	if m == nil {
		return relVersion{}, false
	}
	v := relVersion{rc: 1 << 30}
	v.y, _ = strconv.Atoi(m[1])
	v.m, _ = strconv.Atoi(m[2])
	v.n, _ = strconv.Atoi(m[3])
	if m[4] != "" {
		v.rc, _ = strconv.Atoi(m[4])
	}
	return v, true
}

func (v relVersion) less(o relVersion) bool {
	a, b := [4]int{v.y, v.m, v.n, v.rc}, [4]int{o.y, o.m, o.n, o.rc}
	for i := range a {
		if a[i] != b[i] {
			return a[i] < b[i]
		}
	}
	return false
}

// newerRelease names the newest published release that is newer than the running one, or "".
// A node on a final release is not pointed at release candidates.
func newerRelease(running string, rels []releaseView) string {
	cur, ok := parseRelVersion(running)
	if !ok {
		return ""
	}
	onCandidate := cur.rc != 1<<30
	best, tag := cur, ""
	for _, r := range rels {
		v, ok := parseRelVersion(r.Tag)
		if !ok || (r.Prerelease && !onCandidate) {
			continue
		}
		if best.less(v) {
			best, tag = v, r.Tag
		}
	}
	return tag
}

// rebootRequired reports whether the installed system has another kernel than the running one:
// an update switches everything but the kernel, which waits for a reboot.
var systemLinks = [2]string{"/run/booted-system", "/run/current-system"}

func rebootRequired() bool {
	for _, f := range []string{"kernel", "kernel-modules"} {
		booted, err1 := os.Readlink(systemLinks[0] + "/" + f)
		current, err2 := os.Readlink(systemLinks[1] + "/" + f)
		if err1 == nil && err2 == nil && booted != current {
			return true
		}
	}
	return false
}

// releases lists the repository's releases; the result is cached for ten minutes, a
// failure for two, and a failure keeps showing the last good list.
func (a *App) releases() ([]releaseView, string) {
	if a.cfg.ReleasesURL == "" {
		return nil, ""
	}
	c := a.releaseCache
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.val != nil && time.Since(c.at) < 10*time.Minute {
		return c.val, ""
	}
	if c.err != "" && time.Since(c.errAt) < 2*time.Minute {
		return c.val, c.err
	}
	val, err := fetchReleases(a.cfg.ReleasesURL)
	if err != nil {
		c.err, c.errAt = err.Error(), time.Now()
		return c.val, c.err
	}
	c.val, c.at, c.err = val, time.Now(), ""
	return val, ""
}

func fetchReleases(url string) ([]releaseView, error) {
	client := &http.Client{Timeout: 10 * time.Second}
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("User-Agent", "node-wizard")
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	var raw []struct {
		Tag         string `json:"tag_name"`
		Name        string `json:"name"`
		Body        string `json:"body"`
		URL         string `json:"html_url"`
		PublishedAt string `json:"published_at"`
		Draft       bool   `json:"draft"`
		Prerelease  bool   `json:"prerelease"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 4<<20)).Decode(&raw); err != nil {
		return nil, err
	}
	out := []releaseView{}
	for _, r := range raw {
		if r.Draft || !releaseTagPattern.MatchString(r.Tag) {
			continue
		}
		v := releaseView{Tag: r.Tag, Name: r.Name, URL: r.URL, Prerelease: r.Prerelease, Notes: notesExcerpt(r.Body)}
		if t, err := time.Parse(time.RFC3339, r.PublishedAt); err == nil {
			v.Date = t.UTC().Format("2006-01-02")
		}
		out = append(out, v)
		if len(out) >= 10 {
			break
		}
	}
	return out, nil
}

// notesExcerpt keeps the first few non-empty lines of the release notes.
func notesExcerpt(body string) string {
	var lines []string
	for _, l := range strings.Split(strings.ReplaceAll(body, "\r\n", "\n"), "\n") {
		l = strings.TrimSpace(l)
		if l == "" {
			continue
		}
		lines = append(lines, l)
		if len(lines) == 4 {
			break
		}
	}
	s := strings.Join(lines, "\n")
	if len(s) > 400 {
		s = s[:400] + "…"
	}
	return s
}

// ---- the updater's status ---------------------------------------------------------------

// updaterRunning: a oneshot is "activating" for as long as its ExecStart runs.
func (a *App) updaterRunning() bool {
	s := systemdActive(a.cfg.UpdaterUnit)
	return s == "active" || s == "activating" || s == "reloading"
}

func (a *App) updaterStatus(lang string) (updaterStatus, string, bool) {
	var st updaterStatus
	if a.cfg.UpdaterStatusFile != "" {
		_ = readJSONFile(a.cfg.UpdaterStatusFile, &st)
	}
	if st.State == "" {
		st.State = "idle"
	}
	running := a.updaterRunning()
	if running {
		st.State = "running"
	} else if st.State == "running" {
		// the file says running but nothing is: the updater died mid-way
		st.State = "failed"
		st.Message = tr(lang, "updater_died")
	}
	logTail := ""
	if a.cfg.UpdaterLogFile != "" {
		if b, err := os.ReadFile(a.cfg.UpdaterLogFile); err == nil {
			logTail = tailLines(string(b), 80)
		}
	}
	return st, logTail, running
}

func tailLines(s string, n int) string {
	lines := strings.Split(strings.TrimRight(s, "\n"), "\n")
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	return strings.Join(lines, "\n")
}

// systemctl asks systemd over D-Bus; the polkit rule in modules/node-wizard.nix allows
// exactly the node restart and the updater start for this user.
func systemctl(args ...string) error {
	out, err := exec.Command("systemctl", args...).CombinedOutput()
	if err != nil {
		msg := strings.TrimSpace(string(out))
		if msg == "" {
			msg = err.Error()
		}
		return errors.New(msg)
	}
	return nil
}

// ---- the page ---------------------------------------------------------------------------

type knotsBuildView struct {
	Name      string
	Version   string
	Heights   string
	Store     string
	Running   bool
	Selected  bool
	CanSwitch bool
	Reason    string
}

type updateView struct {
	Version     string
	Rev         string
	Variant     string
	SnapshotPin string
	Error       string // knots-builds.json unreadable

	Running      knotsBuildView
	RunningKnown bool
	Selected     string
	SnapshotLine string
	Others       []knotsBuildView

	Status        updaterStatus
	StateLabel    string
	StatusTime    string
	Log           string
	UpdaterActive bool

	Releases      []releaseView
	ReleasesError string
}

func heightsString(h []int64) string {
	if len(h) == 0 {
		return "–"
	}
	parts := make([]string, len(h))
	for i, x := range h {
		parts[i] = strconv.FormatInt(x, 10)
	}
	return strings.Join(parts, ", ")
}

func snapshotLine(lang string, snap snapshotState) string {
	switch {
	case !snap.Reachable:
		return tr(lang, "snap_unreachable")
	case !snap.Active:
		return tr(lang, "snap_none")
	case snap.Height == 0:
		return fmt.Sprintf(tr(lang, "snap_unknown"), snap.Blockhash)
	case snap.Validated:
		return fmt.Sprintf(tr(lang, "snap_validated"), snap.Height)
	default:
		return fmt.Sprintf(tr(lang, "snap_active"), snap.Height)
	}
}

func stateLabel(lang, state string) string {
	switch state {
	case "idle", "running", "ok", "failed":
		return tr(lang, "state_"+state)
	}
	return state
}

func (a *App) updateView(lang string) *updateView {
	img := a.imageInfo()
	v := &updateView{Version: img.Version, Rev: img.Rev, Variant: img.Variant}
	if img.SnapshotHeight > 0 {
		v.SnapshotPin = fmt.Sprintf("%d (%s)", img.SnapshotHeight, img.SnapshotBlockhash)
	}

	kb, err := a.knotsBuilds()
	if err != nil {
		v.Error = err.Error()
	} else {
		snap := a.snapshotState(img)
		v.SnapshotLine = snapshotLine(lang, snap)
		v.Selected = a.selectedKnotsBuild(kb)
		runningName, known := a.runningKnotsBuild(kb)
		if !known {
			runningName = v.Selected
		}
		v.RunningKnown = known
		mk := func(name string) knotsBuildView {
			b := kb.Builds[name]
			return knotsBuildView{
				Name: name, Version: b.Version, Heights: heightsString(b.AssumeutxoHeights), Store: b.Store,
				Running: known && name == runningName, Selected: name == v.Selected,
			}
		}
		v.Running = mk(runningName)
		names := make([]string, 0, len(kb.Builds))
		for n := range kb.Builds {
			if n != runningName {
				names = append(names, n)
			}
		}
		sort.Strings(names)
		for _, n := range names {
			bv := mk(n)
			bv.CanSwitch, bv.Reason = switchGuard(lang, kb.Builds[n], snap, img)
			v.Others = append(v.Others, bv)
		}
	}

	st, logTail, running := a.updaterStatus(lang)
	v.Status, v.Log, v.UpdaterActive = st, logTail, running
	v.StateLabel = stateLabel(lang, st.State)
	if st.Timestamp > 0 {
		v.StatusTime = time.Unix(st.Timestamp, 0).UTC().Format("2006-01-02 15:04 UTC")
	}
	v.Releases, v.ReleasesError = a.releases()
	return v
}

func (a *App) handleUpdate(w http.ResponseWriter, r *http.Request) {
	pd := a.page(w, r)
	if r.Method == http.MethodPost {
		if !a.csrfOK(r) {
			http.Error(w, "bad request", http.StatusBadRequest)
			return
		}
		switch r.FormValue("action") {
		case "switch":
			a.doSwitch(r, &pd)
		case "update":
			a.doUpdate(r, &pd)
		}
	}
	pd.Update = a.updateView(pd.Lang)
	pd.RebootRequired = rebootRequired()
	a.render(w, "update", pd)
}

// doSwitch writes the selector and restarts the node; the guard is checked again here,
// not only when the page was drawn.
func (a *App) doSwitch(r *http.Request, pd *pageData) {
	name := strings.TrimSpace(r.FormValue("build"))
	kb, err := a.knotsBuilds()
	if err != nil {
		pd.Error = err.Error()
		return
	}
	b, ok := kb.Builds[name]
	if !ok {
		pd.Error = pd.T("err_build")
		return
	}
	img := a.imageInfo()
	if ok, _ := switchGuard(pd.Lang, b, a.snapshotState(img), img); !ok {
		pd.Error = pd.T("err_guard")
		return
	}
	if err := atomicWrite(a.cfg.KnotsSelectorFile, []byte(name+"\n"), 0o644); err != nil {
		pd.Error = pd.T("err_write")
		return
	}
	if err := systemctl("restart", "--no-block", a.cfg.BitcoindUnit); err != nil {
		pd.Error = fmt.Sprintf(pd.T("err_restart"), err)
		return
	}
	pd.Notice = fmt.Sprintf(pd.T("knots_switched"), name)
}

func (a *App) doUpdate(r *http.Request, pd *pageData) {
	tag := strings.TrimSpace(r.FormValue("tag"))
	pd.Form["tag"] = tag
	if !releaseTagPattern.MatchString(tag) {
		pd.Error = pd.T("err_release_tag")
		return
	}
	if a.updaterRunning() {
		pd.Error = pd.T("err_update_running")
		return
	}
	if err := atomicWrite(a.cfg.UpdateRequestFile, []byte(tag+"\n"), 0o644); err != nil {
		pd.Error = pd.T("err_write")
		return
	}
	if err := systemctl("start", "--no-block", a.cfg.UpdaterUnit); err != nil {
		pd.Error = fmt.Sprintf(pd.T("err_start_update"), err)
		return
	}
	pd.Notice = fmt.Sprintf(pd.T("update_started"), tag)
}

func (a *App) handleAPIUpdateStatus(w http.ResponseWriter, r *http.Request) {
	a.mu.Lock()
	saved := a.state.Language
	a.mu.Unlock()
	st, logTail, running := a.updaterStatus(pickLang(r, saved))
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	_ = json.NewEncoder(w).Encode(map[string]any{
		"status": st,
		"log":    logTail,
		"active": running,
	})
}
