// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package brainwire

import (
	"bufio"
	"bytes"
	"errors"
	"io"
)

// ErrLineTooLong is a line past its reader's bound.
var ErrLineTooLong = errors.New("a line past its bound")

// LineReader reads newline-ended lines of at most max bytes.
type LineReader struct {
	r   *bufio.Reader
	max int
}

// NewLineReader reads lines of r, each of at most max bytes.
func NewLineReader(r io.Reader, max int) *LineReader {
	return &LineReader{r: bufio.NewReaderSize(r, 64<<10), max: max}
}

// Next is the next line without its newline: a last line with none is a
// line, and one past the bound is ErrLineTooLong.
func (l *LineReader) Next() ([]byte, error) {
	var line []byte
	for {
		chunk, err := l.r.ReadSlice('\n')
		line = append(line, chunk...)
		if len(line) > l.max+1 {
			return nil, ErrLineTooLong
		}
		switch {
		case err == nil:
			return bytes.TrimSuffix(line, []byte("\n")), nil
		case errors.Is(err, bufio.ErrBufferFull):
			continue
		case len(line) > 0:
			return line, err
		default:
			return nil, err
		}
	}
}

// readLines hands each line of `in` to `lines`, closing it at the end; a
// line past `max` is handed as one of nil bytes, after which nothing more
// is read.
func readLines(in io.Reader, max int, lines chan<- []byte) {
	defer close(lines)
	reader := NewLineReader(in, max)
	for {
		line, err := reader.Next()
		if line != nil || errors.Is(err, ErrLineTooLong) {
			lines <- line
		}
		if err != nil {
			return
		}
	}
}
