// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Package logx writes cyfr-spawn's log lines to stderr: plain text, or one
// JSON object per line when CYFR_LOG_FORMAT=json, in the shape the bridge
// uses. Lines never carry environment values or backend output.
package logx

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"sync"
	"time"
)

// Logger writes leveled lines for one component.
type Logger struct {
	mu        sync.Mutex
	out       io.Writer
	json      bool
	component string
}

// New returns a logger for component writing to stderr, in the format
// CYFR_LOG_FORMAT selects.
func New(component string) *Logger {
	return NewWriter(os.Stderr, component, os.Getenv("CYFR_LOG_FORMAT") == "json")
}

// NewWriter returns a logger writing to out.
func NewWriter(out io.Writer, component string, asJSON bool) *Logger {
	return &Logger{out: out, json: asJSON, component: component}
}

// Info logs an informational line.
func (l *Logger) Info(format string, args ...any) { l.write("info", format, args...) }

// Warn logs a warning.
func (l *Logger) Warn(format string, args ...any) { l.write("warning", format, args...) }

// Error logs an error.
func (l *Logger) Error(format string, args ...any) { l.write("error", format, args...) }

func (l *Logger) write(level, format string, args ...any) {
	message := fmt.Sprintf(format, args...)
	var line []byte
	if l.json {
		line, _ = json.Marshal(map[string]string{
			"timestamp": time.Now().UTC().Format(time.RFC3339Nano),
			"level":     level,
			"message":   message,
			"service":   l.component,
		})
		line = append(line, '\n')
	} else {
		line = []byte(fmt.Sprintf("[%s] %s: %s\n", l.component, level, message))
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	_, _ = l.out.Write(line)
}
