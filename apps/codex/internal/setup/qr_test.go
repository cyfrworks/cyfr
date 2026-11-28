// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package setup

import (
	"fmt"
	"slices"
	"strings"
	"testing"
)

// A link is drawn as a QR code a reader finds: a square of 21+4k modules,
// the three finder patterns dark-ringed in its top-left, top-right and
// bottom-left corners with their light separators, the timing patterns
// alternating between them, and the dark module beside the bottom-left
// finder; the image draws each dark module once, inside a light quiet
// zone, and carries none of the link's text.
func TestQRSVGDrawsAQRCodeOfTheLink(t *testing.T) {
	for _, link := range []string{
		"https://login.tailscale.com/a/1a2b3c4d5e6f",
		"https://login.tailscale.com/a/" + strings.Repeat("f", 120),
	} {
		m, err := qrModules(link)
		if err != nil {
			t.Fatal(err)
		}
		n := len(m)
		if n < 21 || (n-21)%4 != 0 {
			t.Fatalf("the code is %d modules wide", n)
		}
		for _, corner := range [][2]int{{0, 0}, {n - 7, 0}, {0, n - 7}} {
			for dy := -1; dy <= 7; dy++ {
				for dx := -1; dx <= 7; dx++ {
					x, y := corner[0]+dx, corner[1]+dy
					if x < 0 || y < 0 || x >= n || y >= n {
						continue
					}
					ring := max(abs(dx-3), abs(dy-3))
					if want := ring != 2 && ring != 4; m[y][x] != want {
						t.Fatalf("%q: the finder at %v has module (%d, %d) dark=%v", link, corner, x, y, m[y][x])
					}
				}
			}
		}
		for i := 8; i < n-8; i++ {
			if m[6][i] != (i%2 == 0) || m[i][6] != (i%2 == 0) {
				t.Fatalf("%q: the timing patterns break at %d", link, i)
			}
		}
		if !m[n-8][8] {
			t.Errorf("%q: the dark module is light", link)
		}
		svg, err := QRSVG(link)
		if err != nil {
			t.Fatal(err)
		}
		dark := 0
		for _, row := range m {
			for _, d := range row {
				if d {
					dark++
				}
			}
		}
		size := n + 2*quietZone
		if strings.Count(svg, "h1v1h-1z") != dark || !strings.Contains(svg, fmt.Sprintf(`viewBox="0 0 %d %d"`, size, size)) || !strings.Contains(svg, fmt.Sprintf("M%d %dh1v1h-1z", quietZone, quietZone)) {
			t.Errorf("%q: the image does not draw the %d dark modules inside the quiet zone:\n%s", link, dark, svg)
		}
		if strings.Contains(svg, "tailscale") || strings.Contains(svg, "<script") || strings.Contains(svg, "<text") {
			t.Errorf("%q: the image carries text of its own", link)
		}
	}
}

func abs(v int) int {
	if v < 0 {
		return -v
	}
	return v
}

// A terminal's QR code is the same code as the image's, read back from
// its half blocks: a line per two module rows, a cell per module column,
// the quiet zone light all round, and each module light exactly where the
// code's is light, so a camera reads it as it reads the image. Text no
// code holds is refused.
func TestQRTextDrawsTheCodeWithAQuietZone(t *testing.T) {
	for _, text := range []string{"https://cyfr.example.com", "http://localhost:4000", "https://" + strings.Repeat("a", 60) + ".example.com"} {
		m, err := qrModules(text)
		if err != nil {
			t.Fatal(err)
		}
		drawn, err := QRText(text)
		if err != nil {
			t.Fatal(err)
		}
		size := len(m) + 2*quietZone
		lines := strings.Split(strings.TrimSuffix(drawn, "\n"), "\n")
		if !strings.HasSuffix(drawn, "\n") || len(lines) != (size+1)/2 {
			t.Fatalf("%q: %d lines for %d module rows", text, len(lines), size)
		}
		light := make([][]bool, len(lines)*2)
		for y, line := range lines {
			cells := []rune(line)
			if len(cells) != size {
				t.Fatalf("%q: line %d is %d cells, want %d", text, y, len(cells), size)
			}
			light[2*y], light[2*y+1] = make([]bool, size), make([]bool, size)
			for x, c := range cells {
				switch c {
				case '█':
					light[2*y][x], light[2*y+1][x] = true, true
				case '▀':
					light[2*y][x] = true
				case '▄':
					light[2*y+1][x] = true
				case ' ':
				default:
					t.Fatalf("%q: line %d draws %q", text, y, c)
				}
			}
		}
		for y := 0; y < size; y++ {
			for x := 0; x < size; x++ {
				want := true
				if mx, my := x-quietZone, y-quietZone; mx >= 0 && my >= 0 && mx < len(m) && my < len(m) {
					want = !m[my][mx]
				}
				if light[y][x] != want {
					t.Fatalf("%q: module (%d, %d) is light=%v, want %v", text, x, y, light[y][x], want)
				}
			}
		}
		// The row past an odd size is no module and draws nothing.
		if size%2 == 1 && slices.Contains(light[size], true) {
			t.Errorf("%q: the half row past the code is drawn", text)
		}
	}
	if _, err := QRText(strings.Repeat("x", 4000)); err == nil {
		t.Error("text no QR code holds is drawn")
	}
}
