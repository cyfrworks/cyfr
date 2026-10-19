// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package setup

import (
	"fmt"
	"strings"

	"github.com/boombuler/barcode/qr"
)

// quietZone is the light border around a QR code, in modules, that a
// reader needs to find it.
const quietZone = 4

// QRSVG is text as a QR code (error correction M), drawn as an SVG image
// of one dark path on a light square, one unit per module. The image
// carries no text of its own.
func QRSVG(text string) (string, error) {
	m, err := qrModules(text)
	if err != nil {
		return "", err
	}
	size := len(m) + 2*quietZone
	var path strings.Builder
	for y, row := range m {
		for x, dark := range row {
			if dark {
				fmt.Fprintf(&path, "M%d %dh1v1h-1z", x+quietZone, y+quietZone)
			}
		}
	}
	return fmt.Sprintf(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %d %d" shape-rendering="crispEdges"><rect width="%d" height="%d" fill="#fff"/><path fill="#000" d="%s"/></svg>`, size, size, size, size, path.String()), nil
}

// qrModules is text's QR code as its modules, rows top to bottom, true
// for a dark module.
func qrModules(text string) ([][]bool, error) {
	code, err := qr.Encode(text, qr.M, qr.Auto)
	if err != nil {
		return nil, fmt.Errorf("the approval link does not fit a QR code: %w", err)
	}
	b := code.Bounds()
	m := make([][]bool, b.Dy())
	for y := range m {
		m[y] = make([]bool, b.Dx())
		for x := range m[y] {
			r, g, bl, _ := code.At(b.Min.X+x, b.Min.Y+y).RGBA()
			m[y][x] = r+g+bl < 3*0x8000
		}
	}
	return m, nil
}
