// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package shell

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"sync"

	"github.com/cyfr/codex/internal/account"
)

// DeviceDir is this user's device folder, ~/.cyfr/device, made when it is
// not there and kept private to this account each time it is used
// (privateFolder): the key's record (holder.json), the account being made
// beside it, and the list of CYFRs (homes.json) of every road this user's
// CYFR app or screen takes: one key for the user, admitted at each CYFR
// on its own.
func DeviceDir() (string, error) {
	dir, err := DeviceFolder()
	if err != nil {
		return "", err
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", err
	}
	if err := privateFolder(dir); err != nil {
		return "", fmt.Errorf("%s is not this account's alone (%v)", dir, err)
	}
	return dir, nil
}

// DeviceFolder is DeviceDir's path, made or not.
func DeviceFolder() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, ".cyfr", "device"), nil
}

// ClientRecord is this device's standing at one CYFR of the list (Homes):
// the folder a CYFR on this computer is set up in (Project), the account
// service's directory approved for a CYFR elsewhere (Directory), and the
// client that CYFR admitted this device's key as, with the certificate it
// connects under there. Generation is the list's count of changes
// (HomeList.Generations) when this entry came to be or its admission last
// changed: a writer bound to another writes nothing. Ceremonies are the
// account services' origins the app was let keep a ceremony's storage for
// at this CYFR, every one of which a Forget erases; Forgetting marks an
// entry being forgotten, which nothing opens, adds again or renews until
// it is gone.
type ClientRecord struct {
	Project     string          `json:"project,omitempty"`
	Directory   string          `json:"directory,omitempty"`
	ClientID    string          `json:"client_id,omitempty"`
	Certificate json.RawMessage `json:"certificate,omitempty"`
	Generation  uint64          `json:"generation"`
	Ceremonies  []string        `json:"ceremonies,omitempty"`
	Forgetting  bool            `json:"forgetting,omitempty"`
}

// errForgetting refuses a selection of an entry being forgotten.
func errForgetting(home string) error {
	return fmt.Errorf("%s is being forgotten on this computer", home)
}

// ClientStore keeps this device's ClientRecord at one CYFR. Update reads
// the record, lets change edit it and writes it in one step, when change
// answers true, so no writer saves a copy read before another's write.
type ClientStore interface {
	Load() (ClientRecord, error)
	Update(change func(*ClientRecord) bool) error
}

// HomesVersion is the one version of the list's file; a file of another
// is refused, never rewritten.
const HomesVersion = 1

// HomeList is the list of CYFRs as its file holds it: each by its address
// in its one spelling (account.CanonicalHome), the one whose selection
// was committed last, if any, and Generations, a count that only goes up,
// moved by every entry coming to be or going and every change of an
// entry's admission (its client, or whether it holds a certificate). Gone
// is that count as each address's entry went, so an address whose entry
// came and went since a writer read it is not the address it read.
type HomeList struct {
	Version     int                     `json:"version"`
	Homes       map[string]ClientRecord `json:"homes"`
	Last        string                  `json:"last,omitempty"`
	Generations uint64                  `json:"generations"`
	Gone        map[string]uint64       `json:"gone,omitempty"`
}

// at is the count as the list holds it for home: its entry's, the count as
// its last entry went, or 0 for an address that never had one.
func (l *HomeList) at(home string) uint64 {
	if rec, held := l.Homes[home]; held {
		return rec.Generation
	}
	return l.Gone[home]
}

// remove takes the entry at home out of the list, moving the count.
func (l *HomeList) remove(home string) {
	if _, held := l.Homes[home]; !held {
		return
	}
	delete(l.Homes, home)
	l.Generations++
	if l.Gone == nil {
		l.Gone = map[string]uint64{}
	}
	l.Gone[home] = l.Generations
	if l.Last == home {
		l.Last = ""
	}
}

// admitted is whether change from a to b is a change of admission: another
// client, or a certificate held where none was, or none where one was. A
// renewal, a new certificate for the same client, is none.
func admitted(a, b ClientRecord) bool {
	return a.ClientID != b.ClientID || (len(a.Certificate) == 0) != (len(b.Certificate) == 0)
}

// Homes keeps this user's list of CYFRs in a file of its own, private to
// its owner: homes.json in the device folder (DeviceDir). Only the process
// holding the shell's listener writes it. A file that is not such a list
// is refused, and never written over.
type Homes string

// Load reads the list; none is an empty one.
func (f Homes) Load() (HomeList, error) {
	l := HomeList{Version: HomesVersion, Homes: map[string]ClientRecord{}}
	raw, err := os.ReadFile(string(f))
	if errors.Is(err, fs.ErrNotExist) {
		return l, nil
	}
	if err != nil {
		return l, err
	}
	var read HomeList
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	if dec.Decode(&read) != nil || dec.Decode(new(json.RawMessage)) != io.EOF {
		return l, fmt.Errorf("%s is not a list of CYFRs", f)
	}
	if read.Version != HomesVersion {
		return l, fmt.Errorf("%s is a list of CYFRs of version %d, which this program does not read", f, read.Version)
	}
	if read.Homes == nil {
		read.Homes = map[string]ClientRecord{}
	}
	for home, rec := range read.Homes {
		if canonical, ok := account.CanonicalHome(home); !ok || canonical != home || rec.Generation == 0 ||
			rec.Generation > read.Generations || rec.Project != "" && !filepath.IsAbs(rec.Project) {
			return l, fmt.Errorf("%s holds an entry it cannot read, %q", f, home)
		}
	}
	for home, gone := range read.Gone {
		if _, held := read.Homes[home]; held || gone == 0 || gone > read.Generations {
			return l, fmt.Errorf("%s holds an entry it cannot read, %q", f, home)
		}
	}
	if _, ok := read.Homes[read.Last]; read.Last != "" && !ok {
		return l, fmt.Errorf("%s names a last CYFR it does not hold", f)
	}
	return read, nil
}

// homesLocks holds one lock a list's path: every writer of a list in this
// process takes it, and only the process holding the shell's listener
// writes one.
var homesLocks sync.Map

// Update reads the list, lets change edit it and, when change answers
// true, writes it in one step, all under the list's one lock. A list that
// cannot be read is left as it is.
func (f Homes) Update(change func(*HomeList) bool) error {
	l, _ := homesLocks.LoadOrStore(string(f), &sync.Mutex{})
	mu := l.(*sync.Mutex)
	mu.Lock()
	defer mu.Unlock()
	list, err := f.Load()
	if err != nil {
		return err
	}
	if !change(&list) {
		return nil
	}
	return writeJSON(string(f), list)
}

// add puts rec in the list at home as a new entry, moving the count.
func (l *HomeList) add(home string, rec ClientRecord) ClientRecord {
	l.Generations++
	rec.Generation = l.Generations
	l.Homes[home] = rec
	delete(l.Gone, home)
	return rec
}

// Selection is a CYFR of the list, by its address, being selected: it reads
// as that CYFR's entry, with the client and certificate the entry holds.
// Until the selection is committed (the app opened it) or the CYFR admits
// this device, an entry the list does not hold yet is not added, and every
// change the shell makes (a refused first hello's forget among them) stays
// in memory. Once bound to an entry it writes that entry alone, and only
// while the list holds that same one.
type Selection struct {
	file Homes
	home string
	mu   sync.Mutex
	rec  ClientRecord
	// bound is the list's count for home as the selection read it, or as
	// its own last write left it: it writes only while that is so.
	bound uint64
	// approved is whether the directory in rec was approved in this
	// selection (or is cyfr.run), rather than taken from an approval the
	// entry held, which may have ended since.
	approved bool
}

// Row is how a selection began: from an entry of the list a person
// pressed, as the list held it then (its count, from Row), or from an
// address a person typed (Typed). A selection begun from a row is bound to
// that entry from the press on, so its every write, the commit's and an
// admission's, is refused once the list no longer holds that same entry,
// whatever ended it meanwhile: it updates its row and never adds one. Only
// a selection begun from an address adds an entry.
type Row uint64

// Typed is the beginning of a selection of an address a person typed.
const Typed Row = 0

// Row is the entry at home as a person pressed it: refused where the list
// holds none there, or holds one being forgotten.
func (f Homes) Row(home string) (Row, error) {
	l, err := f.Load()
	if err != nil {
		return Typed, err
	}
	switch rec, held := l.Homes[home]; {
	case !held:
		return Typed, errUnkept
	case rec.Forgetting:
		return Typed, errForgetting(home)
	default:
		return Row(rec.Generation), nil
	}
}

// errUnkept refuses a selection begun from a row the list holds no more.
var errUnkept = errors.New("this computer no longer keeps it")

// IsUnkept is whether err refused a row the list holds no more.
func IsUnkept(err error) bool { return errors.Is(err, errUnkept) }

// begin is the count a selection begun from from, at home in l, is bound
// to: the row's own, refused where the list's entry there is another now.
func (l *HomeList) begin(home string, from Row) (uint64, error) {
	at := l.at(home)
	if from != Typed && at != uint64(from) {
		return 0, errUnkept
	}
	return at, nil
}

// Select begins selecting home, a remote CYFR's origin, with directory the
// account service for it, approved in this selection or not, from a row or
// an address typed (Row); it writes nothing. An address the list holds as
// a folder's CYFR is refused: a folder's entry never becomes one
// elsewhere.
func (f Homes) Select(home, directory string, approved bool, from Row) (*Selection, error) {
	l, err := f.Load()
	if err != nil {
		return nil, err
	}
	bound, err := l.begin(home, from)
	if err != nil {
		return nil, err
	}
	rec, held := l.Homes[home]
	switch {
	case held && rec.Forgetting:
		return nil, errForgetting(home)
	case held && rec.Project != "":
		return nil, fmt.Errorf("this computer lists %s as the CYFR in %s, not as one elsewhere", home, rec.Project)
	}
	rec.Directory = directory
	return &Selection{file: f, home: home, rec: rec, approved: approved, bound: bound}, nil
}

// SelectLocal begins selecting the CYFR at home set up in project, a local
// project's absolute directory, from a row or an address (Row). Its
// account service is that project's own setting, so the entry keeps no
// approval of one; it writes nothing. An address the list holds as a CYFR
// elsewhere, or as another folder's, is refused.
func (f Homes) SelectLocal(home, project string, from Row) (*Selection, error) {
	l, err := f.Load()
	if err != nil {
		return nil, err
	}
	bound, err := l.begin(home, from)
	if err != nil {
		return nil, err
	}
	rec, held := l.Homes[home]
	switch {
	case held && rec.Forgetting:
		return nil, errForgetting(home)
	case held && rec.Project == "":
		return nil, fmt.Errorf("this computer lists %s as a CYFR elsewhere, not as the one in %s", home, project)
	case held && rec.Project != project:
		return nil, fmt.Errorf("this computer lists %s as the CYFR in %s, not as the one in %s", home, rec.Project, project)
	}
	rec.Project, rec.Directory = project, ""
	return &Selection{file: f, home: home, rec: rec, approved: true, bound: bound}, nil
}

// Entry is the selection of whatever the list holds at home, as it holds
// it: a shell given no ClientStore keeps its standing there.
func (f Homes) Entry(home string) (*Selection, error) {
	l, err := f.Load()
	if err != nil {
		return nil, err
	}
	return &Selection{file: f, home: home, rec: l.Homes[home], bound: l.at(home)}, nil
}

// Load is the selected CYFR's record.
func (s *Selection) Load() (ClientRecord, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.rec, nil
}

// Update applies change to the selected CYFR's record, and to its entry
// while nothing about its address changed since the selection read it or
// last wrote it (bound): to the entry the list holds, or, where it holds
// none and the change is an admission (a client and the certificate this
// CYFR issued it), as the entry it adds. An admission moves the list's
// count, and the selection is bound to its own write once that write is
// on disk: a write that failed leaves it bound as it was, so a retry
// writes.
func (s *Selection) Update(change func(*ClientRecord) bool) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	change(&s.rec)
	var written *ClientRecord
	err := s.file.Update(func(l *HomeList) bool {
		if l.at(s.home) != s.bound {
			return false
		}
		cur, held := l.Homes[s.home]
		switch {
		case held && cur.Forgetting:
			return false
		case held:
			before := cur
			if !change(&cur) {
				return false
			}
			cur.Generation = before.Generation
			if admitted(before, cur) {
				l.Generations++
				cur.Generation = l.Generations
			}
			l.Homes[s.home] = cur
			written = &cur
			return true
		case s.rec.ClientID != "" && len(s.rec.Certificate) != 0:
			added := l.add(s.home, s.rec)
			written = &added
			return true
		}
		return false
	})
	if err == nil && written != nil {
		s.bind(*written)
	}
	return err
}

// bind binds the selection to its entry as its own write left it on disk.
func (s *Selection) bind(written ClientRecord) {
	s.bound, s.rec.Generation = written.Generation, written.Generation
}

// Commit writes the selection once the app opened it: its entry is added
// where the list holds none at its address, or kept, with the account
// service's address written only when this selection approved it (one it
// took from the entry stays as the entry holds it now, ended or not),
// ceremony, an account service's origin, among those a Forget erases
// ("" adds none), and it is the CYFR selected last. An address whose
// entry came, went or was admitted anew since the selection read it, or
// whose entry is being forgotten, refuses it.
func (s *Selection) Commit(ceremony string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	var refused error
	var added *ClientRecord
	err := s.file.Update(func(l *HomeList) bool {
		if l.at(s.home) != s.bound {
			refused = fmt.Errorf("this computer's list changed at %s meanwhile", s.home)
			return false
		}
		cur, held := l.Homes[s.home]
		switch {
		case held && cur.Forgetting:
			refused = errForgetting(s.home)
			return false
		case held:
			if s.approved && cur.Project == "" {
				cur.Directory = s.rec.Directory
			}
		default:
			rec := ClientRecord{Project: s.rec.Project, ClientID: s.rec.ClientID, Certificate: s.rec.Certificate}
			if s.approved {
				rec.Directory = s.rec.Directory
			}
			cur = l.add(s.home, rec)
			added = &cur
		}
		if ceremony != "" && !slices.Contains(cur.Ceremonies, ceremony) {
			cur.Ceremonies = append(cur.Ceremonies, ceremony)
		}
		l.Homes[s.home] = cur
		l.Last = s.home
		return true
	})
	if err == nil && added != nil {
		s.bind(*added)
	}
	return errors.Join(err, refused)
}

// EndApproval forgets the account service approved for home unless it is
// keep, the address the CYFR names now: an approval stands only while the
// CYFR names it.
func (f Homes) EndApproval(home, keep string) error {
	return f.Update(func(l *HomeList) bool {
		c, held := l.Homes[home]
		if !held || c.Project != "" || c.Directory == "" || c.Directory == keep {
			return false
		}
		c.Directory = ""
		l.Homes[home] = c
		return true
	})
}

// Forgetting marks the entry at home as being forgotten, and no longer the
// CYFR selected last: from here nothing opens it, adds it again or renews
// it, until Forgotten removes it. It answers the entry as it stands, and
// false where the list holds none at home.
func (f Homes) Forgetting(home string) (ClientRecord, bool, error) {
	var rec ClientRecord
	var held bool
	err := f.Update(func(l *HomeList) bool {
		rec, held = l.Homes[home]
		if !held {
			return false
		}
		rec.Forgetting = true
		l.Homes[home] = rec
		if l.Last == home {
			l.Last = ""
		}
		return true
	})
	return rec, held && err == nil, err
}

// Forgotten removes the entry at home, numbered generation, once every
// store a Forget erases is erased; another entry there is left.
func (f Homes) Forgotten(home string, generation uint64) error {
	return f.Update(func(l *HomeList) bool {
		rec, held := l.Homes[home]
		if !held || rec.Generation != generation || !rec.Forgetting {
			return false
		}
		l.remove(home)
		return true
	})
}
