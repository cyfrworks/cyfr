// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package desktop

import (
	"context"
	"crypto/subtle"
	_ "embed"
	"encoding/json"
	"io"
	"net/http"
	"slices"
	"strings"

	"github.com/cyfr/codex/internal/shell"
)

// The rail's one page, style and script, each allowed by its hash alone,
// files of their own (assets/) that the vocabulary check reads. The page
// is the app's list of CYFRs beside the open one: main loads it, with the
// read token in its fragment, in a view of its own beside the content.
// What it does is read the list (/rail/list) and show it; every press is
// a navigation to an address main alone answers (states.js ACTS), never
// loaded, so the rail holds no credential that changes anything.
var (
	//go:embed assets/rail.css
	railStyle string
	//go:embed assets/rail.js
	railScript string
	//go:embed assets/rail.html
	railMarkup string

	railStyleText  = strings.TrimSuffix(railStyle, "\n")
	railScriptText = strings.TrimSuffix(railScript, "\n")
)

var railPolicy = "default-src 'none'; script-src " + hash(railScriptText) + "; style-src " + hash(railStyleText) +
	"; connect-src 'self'; form-action 'none'; frame-ancestors 'none'; base-uri 'none'"

var railPage = `<!doctype html>
<html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>CYFR</title><style>` + railStyleText + `</style>
` + strings.TrimSuffix(railMarkup, "\n") + `<script>` + railScriptText + `</script></html>`

// RailURL is the rail's address main loads, the read token in its
// fragment, which no request carries but the rail's own reads.
func (s *Service) RailURL() string { return shell.Origin + "/rail/#read=" + s.ReadToken }

// RailCYFR is one CYFR of the list as the rail shows it: its address, the
// folder it is set up in when it is one on this computer, whether it is
// the one open, and whether it is being forgotten and whether its last
// erase failed (Retry forgets again).
type RailCYFR struct {
	Home       string `json:"cyfr"`
	Folder     string `json:"folder,omitempty"`
	Open       bool   `json:"open,omitempty"`
	Forgetting bool   `json:"forgetting,omitempty"`
	Failed     bool   `json:"failed,omitempty"`
}

// railList is the rail's answer: the list in its order, and the change it
// shows, from 1, which the rail's next read names as seen (none, 0, is
// answered at once).
type railList struct {
	CYFRs []RailCYFR `json:"cyfrs"`
	Seq   uint64     `json:"seq"`
	Error string     `json:"error,omitempty"`
}

// rail serves the rail's page and its one read. A read carries the read
// token, which authorizes this read and nothing else: no route of the
// chooser's takes it (bootstrap), and the rail has no other. A read whose
// seen is the change shown now waits for the next change, a lock or the
// service's end, within chooserBound.
func (s *Service) rail(w http.ResponseWriter, r *http.Request) {
	h := w.Header()
	h.Set("Cache-Control", "no-store")
	h.Set("Referrer-Policy", "no-referrer")
	h.Set("X-Content-Type-Options", "nosniff")
	h.Set("X-Frame-Options", "DENY")
	h.Set("Content-Security-Policy", railPolicy)
	if r.Host != shell.Listen {
		http.Error(w, "not this app's address", http.StatusMisdirectedRequest)
		return
	}
	if r.Method == http.MethodGet && r.URL.Path == "/rail/" {
		h.Set("Content-Type", "text/html; charset=utf-8")
		_, _ = io.WriteString(w, railPage)
		return
	}
	if r.URL.Path != "/rail/list" || r.Method != http.MethodPost {
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
		http.Error(w, "not this app's rail", http.StatusForbidden)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), chooserBound)
	defer cancel()
	for {
		s.mu.Lock()
		seq, ended, woken := s.listed+1, s.ended, s.waitWoken()
		s.mu.Unlock()
		if ended {
			http.Error(w, "This CYFR app has ended.", http.StatusServiceUnavailable)
			return
		}
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
	_ = json.NewEncoder(w).Encode(s.railNow())
}

// railNow is the list as the rail shows it now: its folders' CYFRs and
// those elsewhere, each by its address, in that address's order. Reading
// it asks nothing of any CYFR or of Docker.
func (s *Service) railNow() railList {
	list, err := s.Homes.Load()
	s.mu.Lock()
	defer s.mu.Unlock()
	out := railList{CYFRs: []RailCYFR{}, Seq: s.listed + 1}
	if err != nil {
		out.Error = "This computer's list of CYFRs could not be read (" + err.Error() + ")."
		return out
	}
	for home, rec := range list.Homes {
		out.CYFRs = append(out.CYFRs, RailCYFR{Home: home, Folder: rec.Project, Open: s.pages != nil && s.committed.Home == home,
			Forgetting: rec.Forgetting, Failed: s.unerased[home]})
	}
	slices.SortFunc(out.CYFRs, func(a, b RailCYFR) int { return strings.Compare(a.Home, b.Home) })
	return out
}

// changed says the list changed to every rail reading it, under s.mu.
func (s *Service) changed() {
	s.listed++
	s.wake()
}

// erasing is one store an erase asked main to clear, for the entry being
// forgotten that is numbered generation.
type erasing struct {
	home, account string
	generation    uint64
}

// Forget forgets the CYFR at home on this computer, main's forget, which
// main sends once it left that CYFR: the entry is marked being forgotten
// (shell.Homes.Forgetting), so nothing opens it from here, and main is
// asked to erase its content storage and each ceremony's storage the
// entry recorded; once every one is erased the entry is removed. A CYFR
// open, or one the list does not hold, is not forgotten. Forget again
// (Retry, or the next start's resume) asks for every erase again.
func (s *Service) Forget(home string) {
	s.mu.Lock()
	open := s.pages != nil && s.committed.Home == home
	s.mu.Unlock()
	if open {
		return
	}
	rec, held, err := s.Homes.Forgetting(home)
	s.mu.Lock()
	defer s.mu.Unlock()
	if err != nil || !held {
		s.changed()
		return
	}
	delete(s.unerased, home)
	for id, e := range s.erases {
		if e.home == home {
			delete(s.erases, id)
		}
	}
	for _, account := range append([]string{""}, rec.Ceremonies...) {
		s.eraseID++
		if s.erases == nil {
			s.erases = map[uint64]erasing{}
		}
		s.erases[s.eraseID] = erasing{home: home, account: account, generation: rec.Generation}
		s.Tell(Message{Type: TypeErase, ID: s.eraseID, Home: home, Account: account})
	}
	s.changed()
}

// Erased is main's erased for id: an erase not waiting changes nothing.
// One that failed leaves the entry being forgotten, its failure shown on
// the rail; the last of an entry's to succeed removes it.
func (s *Service) Erased(id uint64, ok bool) {
	s.mu.Lock()
	e, waiting := s.erases[id]
	if !waiting {
		s.mu.Unlock()
		return
	}
	delete(s.erases, id)
	if !ok {
		if s.unerased == nil {
			s.unerased = map[string]bool{}
		}
		s.unerased[e.home] = true
		s.changed()
		s.mu.Unlock()
		return
	}
	left := false
	for _, other := range s.erases {
		left = left || other.home == e.home
	}
	failed := s.unerased[e.home]
	s.mu.Unlock()
	if left || failed {
		return
	}
	err := s.Homes.Forgotten(e.home, e.generation)
	s.mu.Lock()
	if err != nil {
		if s.unerased == nil {
			s.unerased = map[string]bool{}
		}
		s.unerased[e.home] = true
	}
	s.changed()
	s.mu.Unlock()
}

// resumeForgets forgets again, at the service's start, every entry a
// Forget that did not finish left marked.
func (s *Service) resumeForgets() {
	list, err := s.Homes.Load()
	if err != nil {
		return
	}
	homes := []string{}
	for home, rec := range list.Homes {
		if rec.Forgetting {
			homes = append(homes, home)
		}
	}
	slices.Sort(homes)
	for _, home := range homes {
		s.Forget(home)
	}
}
