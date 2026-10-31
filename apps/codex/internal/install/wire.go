// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package install

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
)

// Event is one line the root entry writes on its standard output, one
// JSON object per line: an action starting or done, or the failure that
// stopped it.
type Event struct {
	Event   string  `json:"event"`
	Action  *Action `json:"action,omitempty"`
	Failure *Failed `json:"failure,omitempty"`
}

// The events.
const (
	EventStart  = "start"
	EventDone   = "done"
	EventFailed = "failed"
)

// Failed is an Apply error carried across the root entry's output, so the
// person's process words it with what it observes was completed.
type Failed struct {
	Kind     string    `json:"kind"`
	Lock     Lock      `json:"lock,omitempty"`
	Added    []Action  `json:"added,omitempty"`
	Decision *Decision `json:"decision,omitempty"`
	Package  string    `json:"package,omitempty"`
	Version  string    `json:"version,omitempty"`
	Archive  bool      `json:"archive,omitempty"`
	Action   *Action   `json:"action,omitempty"`
	Message  string    `json:"message,omitempty"`
}

// Fail encodes err.
func Fail(err error) *Failed {
	var lock LockError
	var stale StaleError
	var refused RefusedError
	var candidate CandidateError
	var step StepError
	switch {
	case errors.As(err, &lock):
		return &Failed{Kind: "lock", Lock: lock.Lock}
	case errors.As(err, &stale):
		return &Failed{Kind: "stale", Added: stale.Added}
	case errors.As(err, &refused):
		return &Failed{Kind: "refused", Decision: &refused.Decision}
	case errors.As(err, &candidate):
		return &Failed{Kind: "candidate", Package: candidate.Package, Version: candidate.Version, Archive: candidate.Archive}
	case errors.As(err, &step):
		return &Failed{Kind: "step", Action: &step.Action, Message: step.Err.Error()}
	case errors.Is(err, ErrInvalidPlan):
		return &Failed{Kind: "invalid", Message: err.Error()}
	}
	return &Failed{Kind: "other", Message: err.Error()}
}

// Err decodes the error f carries.
func (f Failed) Err() error {
	switch f.Kind {
	case "lock":
		return LockError{f.Lock}
	case "stale":
		return StaleError{f.Added}
	case "refused":
		if f.Decision != nil {
			return RefusedError{*f.Decision}
		}
	case "candidate":
		return CandidateError{Package: f.Package, Version: f.Version, Archive: f.Archive}
	case "step":
		if f.Action != nil {
			return StepError{*f.Action, errors.New(f.Message)}
		}
	case "invalid":
		return fmt.Errorf("%w (%s)", ErrInvalidPlan, f.Message)
	}
	return errors.New(f.Message)
}

// Emitter writes events.
type Emitter struct{ W io.Writer }

func (e Emitter) emit(ev Event) {
	line, _ := json.Marshal(ev)
	_, _ = e.W.Write(append(line, '\n'))
}

func (e Emitter) Start(a Action)   { e.emit(Event{Event: EventStart, Action: &a}) }
func (e Emitter) Done(a Action)    { e.emit(Event{Event: EventDone, Action: &a}) }
func (e Emitter) Failed(err error) { e.emit(Event{Event: EventFailed, Failure: Fail(err)}) }
