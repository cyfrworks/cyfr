// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package setup

import (
	"bytes"
	"flag"
	"image"
	"image/color"
	"image/png"
	"os"
	"path/filepath"
	"testing"
)

var updateLogo = flag.Bool("update-logo", false, "write assets/logo.png from the shipped logo")

// logoSize is the side of the pages' logo, in pixels.
const logoSize = 512

// shippedLogo is the logo Prism serves, which the pages' copy is made from.
var shippedLogo = filepath.Join("..", "..", "..", "cyfr", "priv", "static", "images", "logo.png")

// The pages' logo is the shipped logo scaled to 512 pixels, pixel for
// pixel; `go test ./internal/setup -run TestLogo -update-logo` writes it
// again from the shipped one.
func TestLogoIsTheShippedLogoScaled(t *testing.T) {
	raw, err := os.ReadFile(shippedLogo)
	if err != nil {
		t.Fatal(err)
	}
	src, err := png.Decode(bytes.NewReader(raw))
	if err != nil {
		t.Fatal(err)
	}
	want := scale(src, logoSize)
	if *updateLogo {
		var buf bytes.Buffer
		enc := png.Encoder{CompressionLevel: png.BestCompression}
		if err := enc.Encode(&buf, want); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join("assets", "logo.png"), buf.Bytes(), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	data, err := assets.ReadFile("assets/logo.png")
	if err != nil {
		t.Fatal(err)
	}
	got, err := png.Decode(bytes.NewReader(data))
	if err != nil {
		t.Fatal(err)
	}
	if b := got.Bounds(); b.Dx() != logoSize || b.Dy() != logoSize {
		t.Fatalf("the pages' logo is %dx%d, want %dx%d", b.Dx(), b.Dy(), logoSize, logoSize)
	}
	for y := range logoSize {
		for x := range logoSize {
			if g, w := color.NRGBAModel.Convert(got.At(x, y)), want.NRGBAAt(x, y); g != w {
				t.Fatalf("the pages' logo differs from the shipped logo scaled at (%d, %d): %v, want %v; run the test with -update-logo", x, y, g, w)
			}
		}
	}
}

// scale is src, a square image, scaled to size × size by area averaging
// in premultiplied alpha, in integers alone so every platform derives the
// same pixels.
func scale(src image.Image, size int) *image.NRGBA {
	b := src.Bounds()
	n := b.Dx()
	dst := image.NewNRGBA(image.Rect(0, 0, size, size))
	// A destination pixel spans n units of 1/size source pixels on each
	// axis; source pixel i spans [i*size, (i+1)*size).
	spans := func(d int) (first int, weights []uint64) {
		lo, hi := d*n, (d+1)*n
		first = lo / size
		for i := first; i*size < hi; i++ {
			weights = append(weights, uint64(min(hi, (i+1)*size)-max(lo, i*size)))
		}
		return first, weights
	}
	total := uint64(n) * uint64(n)
	for dy := range size {
		y0, wy := spans(dy)
		for dx := range size {
			x0, wx := spans(dx)
			var r, g, bl, a uint64
			for j, yw := range wy {
				for i, xw := range wx {
					pr, pg, pb, pa := src.At(b.Min.X+x0+i, b.Min.Y+y0+j).RGBA()
					w := yw * xw
					r, g, bl, a = r+uint64(pr)*w, g+uint64(pg)*w, bl+uint64(pb)*w, a+uint64(pa)*w
				}
			}
			r, g, bl, a = (r+total/2)/total, (g+total/2)/total, (bl+total/2)/total, (a+total/2)/total
			c := color.RGBA64{R: uint16(r), G: uint16(g), B: uint16(bl), A: uint16(a)}
			dst.SetNRGBA(dx, dy, color.NRGBAModel.Convert(c).(color.NRGBA))
		}
	}
	return dst
}
