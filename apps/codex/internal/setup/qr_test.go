// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package setup

import (
	"fmt"
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

// The terminal's QR code is the same modules as the image, two rows per
// line, light as a block and dark as a space, inside a light quiet zone
// on every side, the last odd row's lower half light.
func TestQRText_DrawsTheModulesInsideTheQuietZone(t *testing.T) {
	text := "https://alice.example/devices/add#key=sv5QHby2ooLrBWLs_JOrjk8goRiwYWrrCDbE2RuiE0o"
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
	if len(lines) != (size+1)/2 {
		t.Fatalf("%d lines for %d rows", len(lines), size)
	}
	light := func(x, y int) bool {
		x, y = x-quietZone, y-quietZone
		return y < 0 || y >= len(m) || x < 0 || x >= len(m) || !m[y][x]
	}
	for i, line := range lines {
		cells := []rune(line)
		if len(cells) != size {
			t.Fatalf("line %d is %d wide, not %d", i, len(cells), size)
		}
		for x, c := range cells {
			top, bottom := light(x, 2*i), 2*i+1 >= size || light(x, 2*i+1)
			want := map[[2]bool]rune{{true, true}: '█', {true, false}: '▀', {false, true}: '▄', {false, false}: ' '}[[2]bool{top, bottom}]
			if c != want {
				t.Fatalf("line %d column %d is %q, want %q", i, x, c, want)
			}
		}
	}
	if !strings.HasPrefix(lines[0], strings.Repeat("█", size)) || !strings.HasPrefix(lines[len(lines)-1], strings.Repeat("█", size)) {
		t.Error("the quiet zone is not light above and below")
	}
}
