// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package desktop

import (
	"context"
	"crypto/subtle"
	_ "embed"
	"encoding/json"
	"errors"
	"io"
	"io/fs"
	"net/http"
	"os"
	"regexp"
	"strings"
	"time"

	"github.com/cyfr/codex/internal/shell"
	"github.com/cyfr/codex/internal/version"
)

// Update CYFR's one page, style and script, each allowed by its hash alone,
// as the rail's are. Main shows the page in a window of its own over the
// content, with the read token in its fragment: the page reads the offer
// (/update/read) and shows it, and its yes is a navigation to an address
// main alone answers (states.js ACTS), which then sends update with the
// offer's number. So the page holds no credential that starts anything,
// and nothing it says chooses the release, the folder or the yes.
var (
	//go:embed assets/update.css
	updateStyle string
	//go:embed assets/update.js
	updateScript string
	//go:embed assets/update.html
	updateMarkup string

	updateStyleText  = strings.TrimSuffix(updateStyle, "\n")
	updateScriptText = strings.TrimSuffix(updateScript, "\n")
)

var updatePolicy = "default-src 'none'; script-src " + hash(updateScriptText) + "; style-src " + hash(updateStyleText) +
	"; connect-src 'self'; form-action 'none'; frame-ancestors 'none'; base-uri 'none'"

var updatePage = `<!doctype html>
<html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>Update CYFR</title><style>` + updateStyleText + `</style>
` + strings.TrimSuffix(updateMarkup, "\n") + `<script>` + updateScriptText + `</script></html>`

// UpdateURL is Update CYFR's address main loads, the read token in its
// fragment.
func (s *Service) UpdateURL() string { return shell.Origin + "/update/#read=" + s.ReadToken }

// UpdateOffer is what Update CYFR shows: this app's release, the release
// a yes goes to and what that yes does (Step: "app", the app's own update
// as cyfr update makes it; "stack", this computer's own CYFR's, the change
// shown; none where no yes is offered), in sentences for the person, and
// the one line to run in a terminal where the app cannot make the update
// itself. ID numbers it among this run's offers.
type UpdateOffer struct {
	ID       uint64   `json:"offer"`
	App      string   `json:"app"`
	Target   string   `json:"target,omitempty"`
	Step     string   `json:"step,omitempty"`
	Says     []string `json:"says"`
	Terminal string   `json:"terminal,omitempty"`
}

// UpdatePlan is an offer and what its yes starts: the app's own cyfr with
// Args in Dir, the record's first line Header.
type UpdatePlan struct {
	UpdateOffer
	Dir    string
	Args   []string
	Header string
}

// updateRead is the page's read: the offer (none while it is worked out),
// whether an update runs, what the record holds and the sentence that
// sums it up, or why a yes started nothing; Seq is the change it shows, as
// the rail's list's is.
type updateRead struct {
	Offer   *UpdateOffer `json:"offer"`
	Running bool         `json:"running,omitempty"`
	Outcome string       `json:"outcome,omitempty"`
	Record  string       `json:"record,omitempty"`
	Refused string       `json:"refused,omitempty"`
	Seq     uint64       `json:"seq"`
}

// maxRecordShown bounds what of the record the page is given: its end,
// where the outcome is.
const maxRecordShown = 256 << 10

// updating is Update CYFR's state, under s.mu: the offer held, if any, and
// the work that makes it (generation counts each, so an offer worked out
// for a CYFR left meanwhile is dropped); the offer whose yes started a
// run, at most once each; whether that run, this cyfr's child, still
// runs; why a yes started nothing; whether the record was shown; whether
// the window closed, after which no offer is worked out until a page
// reads from its start: a read of the page closing, woken by its close,
// works out none for the next window to find; and the changes the page is
// shown.
type updating struct {
	offer      *UpdatePlan
	offers     uint64
	working    bool
	closed     bool
	generation uint64
	started    uint64
	running    bool
	refused    string
	shown      bool
	seq        uint64
}

// voidOffer drops the offer held, under s.mu: the CYFR selected changed,
// a lock came, or its run ended. The page reads the next.
func (s *Service) voidOffer() {
	s.update.offer = nil
	s.update.generation++
	s.update.seq++
	s.wake()
}

// project is the folder of this computer's own CYFR at home, as the list
// names it: "" for none.
func (s *Service) project(home string) string {
	list, err := s.Homes.Load()
	if err != nil {
		return ""
	}
	return list.Homes[home].Project
}

// updatePage serves Update CYFR's page and its one read, by the read
// token alone, as the rail's are: a read whose seen is the change shown
// now waits for the next, within chooserBound.
func (s *Service) updatePage(w http.ResponseWriter, r *http.Request) {
	h := w.Header()
	h.Set("Cache-Control", "no-store")
	h.Set("Referrer-Policy", "no-referrer")
	h.Set("X-Content-Type-Options", "nosniff")
	h.Set("X-Frame-Options", "DENY")
	h.Set("Content-Security-Policy", updatePolicy)
	if r.Host != shell.Listen {
		http.Error(w, "not this app's address", http.StatusMisdirectedRequest)
		return
	}
	if r.Method == http.MethodGet && r.URL.Path == "/update/" {
		h.Set("Content-Type", "text/html; charset=utf-8")
		_, _ = io.WriteString(w, updatePage)
		return
	}
	if r.URL.Path != "/update/read" || r.Method != http.MethodPost {
		http.NotFound(w, r)
		return
	}
	if r.Header.Get("Origin") != shell.Origin {
		http.Error(w, "not from this app's pages", http.StatusForbidden)
		return
	}
	if r.Header.Get("Content-Type") != "application/json" {
		http.Error(w, "JSON is expected", http.StatusUnsupportedMediaType)
		return
	}
	var req struct {
		Token string `json:"token"`
		Seen  uint64 `json:"seen,omitempty"`
	}
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<10))
	dec.DisallowUnknownFields()
	if dec.Decode(&req) != nil || dec.More() {
		http.Error(w, "JSON is expected", http.StatusBadRequest)
		return
	}
	if s.ReadToken == "" || subtle.ConstantTimeCompare([]byte(req.Token), []byte(s.ReadToken)) != 1 {
		http.Error(w, "not this app's page", http.StatusForbidden)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), chooserBound)
	defer cancel()
	if req.Seen == 0 {
		s.mu.Lock()
		s.update.closed = false
		s.mu.Unlock()
	}
	for {
		s.mu.Lock()
		if s.ended {
			s.mu.Unlock()
			http.Error(w, "This CYFR app has ended.", http.StatusServiceUnavailable)
			return
		}
		s.workOffer()
		seq, woken := s.update.seq+1, s.waitWoken()
		s.mu.Unlock()
		if seq != req.Seen {
			break
		}
		select {
		case <-woken:
		case <-ctx.Done():
			return
		}
	}
	h.Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(s.updateNow())
}

// workOffer begins working out the offer, under s.mu, where none is held
// and none is being worked out: Offer asks for the newest release and,
// for this computer's own CYFR, its change; it is not bounded by the read
// that began it.
func (s *Service) workOffer() {
	if s.update.offer != nil || s.update.working || s.update.closed || s.Offer == nil {
		return
	}
	s.update.working = true
	// This computer's own CYFR is the one open where its pages serve a
	// CYFR read from its folder (here).
	generation, own := s.update.generation, ""
	if s.here != nil && s.pages != nil {
		own = s.committed.Home
	}
	go func() {
		project := ""
		if own != "" {
			project = s.project(own)
		}
		plan := s.Offer(context.Background(), project)
		s.mu.Lock()
		defer s.mu.Unlock()
		s.update.working = false
		if s.update.generation != generation || s.ended {
			s.wake()
			return
		}
		s.update.offers++
		plan.ID = s.update.offers
		s.update.offer = &plan
		s.update.seq++
		s.wake()
	}()
}

// updateNow is the page's read now. The record it gives is marked shown,
// so the window's close removes it.
func (s *Service) updateNow() updateRead {
	record, _ := readRecord(s.UpdateRecord)
	s.mu.Lock()
	defer s.mu.Unlock()
	out := updateRead{Seq: s.update.seq + 1, Refused: s.update.refused}
	if s.update.offer != nil {
		offer := s.update.offer.UpdateOffer
		out.Offer = &offer
	}
	out.Running = s.update.running || (s.UpdateRuns != nil && s.UpdateRuns(recordProject(record)))
	if record != "" {
		out.Record = record
		out.Outcome = outcome(record, out.Running)
		s.update.shown = true
	}
	return out
}

// readRecord is the end of the record at path, "" where there is none.
func readRecord(path string) (string, error) {
	if path == "" {
		return "", nil
	}
	f, err := os.Open(path)
	if errors.Is(err, fs.ErrNotExist) {
		return "", nil
	}
	if err != nil {
		return "", err
	}
	defer f.Close()
	if info, err := f.Stat(); err == nil && info.Size() > maxRecordShown {
		_, _ = f.Seek(-maxRecordShown, io.SeekEnd)
	}
	data, err := io.ReadAll(io.LimitReader(f, maxRecordShown))
	return string(data), err
}

// The record's first line, which this cyfr writes before the run it
// starts: the release it goes to, and for this computer's own CYFR its
// folder.
var (
	appHeader   = regexp.MustCompile(`^Updating the CYFR app to release (\S+), as asked in the app`)
	stackHeader = regexp.MustCompile(`^Updating your CYFR in (.+) to release (\S+), as asked in the app`)
)

// AppHeader and StackHeader are the record's first line for an update of
// the app, and of this computer's own CYFR in folder, to target.
func AppHeader(target string, at time.Time) string {
	return "Updating the CYFR app to release " + target + ", as asked in the app at " + at.UTC().Format("2006-01-02 15:04 UTC") + "."
}

func StackHeader(folder, target string, at time.Time) string {
	return "Updating your CYFR in " + folder + " to release " + target + ", as asked in the app at " + at.UTC().Format("2006-01-02 15:04 UTC") + "."
}

// recordProject is the folder the record's update changes, "" for the
// app's.
func recordProject(record string) string {
	if m := stackHeader.FindStringSubmatch(firstLine(record)); m != nil {
		return m[1]
	}
	return ""
}

func firstLine(text string) string {
	line, _, _ := strings.Cut(text, "\n")
	return line
}

// outcome sums up the record in a sentence: still running; its refusal,
// the last line cyfr ended on with; the release the app went to, where
// this app, the one reading it, is that release; the release this
// computer's own CYFR went to, as the update's own report says it.
func outcome(record string, running bool) string {
	if running {
		return "CYFR is being updated."
	}
	refusal := ""
	for _, line := range strings.Split(record, "\n") {
		if said, ok := strings.CutPrefix(strings.TrimSpace(line), "Error: "); ok {
			refusal = said
		}
	}
	if refusal != "" {
		return refusal
	}
	if m := appHeader.FindStringSubmatch(firstLine(record)); m != nil && version.Version == m[1] {
		return "The CYFR app is release " + m[1] + "."
	}
	if m := stackHeader.FindStringSubmatch(firstLine(record)); m != nil && strings.Contains(record, "Updated to release "+m[2]+".") {
		return "Your CYFR in " + m[1] + " is release " + m[2] + "."
	}
	return "The update ended without saying how; what it said is below."
}

// StartUpdate is main's update: the person's yes to the offer numbered
// id. Only the offer held now, with a yes to give, starts, and only once:
// a yes to an offer dropped since (a late one) or to one started already
// starts nothing. Its run is the app's own cyfr, started by BeginUpdate
// with the record, made anew for it and readable by this account alone,
// as its output; once it ends the offer is dropped, and the page reads
// the next beside the record.
func (s *Service) StartUpdate(id uint64) {
	s.mu.Lock()
	defer s.mu.Unlock()
	p := s.update.offer
	if p == nil || p.ID != id || p.Step == "" || s.update.started == id || s.update.running || s.BeginUpdate == nil || s.ended {
		return
	}
	s.update.started = id
	s.update.refused = ""
	s.update.shown = false
	wait, err := s.beginRun(*p)
	if err != nil {
		s.update.refused = err.Error()
		s.update.seq++
		s.wake()
		return
	}
	s.update.running = true
	s.update.seq++
	s.wake()
	go func() {
		_ = wait()
		s.mu.Lock()
		defer s.mu.Unlock()
		s.update.running = false
		s.voidOffer()
	}()
}

// beginRun makes the record anew, its header first, and starts plan's run
// with it as its output.
func (s *Service) beginRun(p UpdatePlan) (func() error, error) {
	if err := os.Remove(s.UpdateRecord); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return nil, errors.New("The record of the last update could not be replaced (" + err.Error() + "); nothing was changed.")
	}
	f, err := os.OpenFile(s.UpdateRecord, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return nil, errors.New("The update's record could not be made (" + err.Error() + "); nothing was changed.")
	}
	defer f.Close()
	if _, err := io.WriteString(f, p.Header+"\n"); err != nil {
		return nil, errors.New("The update's record could not be written (" + err.Error() + "); nothing was changed.")
	}
	return s.BeginUpdate(p, f)
}

// UpdateClosed is main's update-closed: the window is gone, so a record it
// showed is removed, unless its update still runs; one it never showed
// stays for the next open. The offer held, and why a yes started nothing,
// go with the page.
func (s *Service) UpdateClosed() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.update.refused = ""
	s.update.closed = true
	if s.update.shown && !s.update.running && (s.UpdateRuns == nil || !s.UpdateRuns(s.recordProjectNow())) {
		_ = os.Remove(s.UpdateRecord)
		s.update.shown = false
	}
	s.voidOffer()
}

func (s *Service) recordProjectNow() string {
	record, _ := readRecord(s.UpdateRecord)
	return recordProject(record)
}

// RecordWaits is whether a record of an update waits to be shown, which
// ready says, so main opens Update CYFR at once.
func (s *Service) RecordWaits() bool {
	if s.UpdateRecord == "" {
		return false
	}
	_, err := os.Stat(s.UpdateRecord)
	return err == nil
}
