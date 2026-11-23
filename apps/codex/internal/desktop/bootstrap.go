// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package desktop

import (
	"crypto/sha256"
	_ "embed"
	"encoding/base64"
	"strings"
)

// The chooser's one page, style and script, the style and the script each
// allowed by its hash alone.
// The script keeps the run token from the first address's fragment in
// sessionStorage, private to this origin, and puts it back with each
// answer, since main may clear that storage while a Connect waits; it
// takes everything off the address, and sends the token with each
// request; it writes answers as text, never markup.
// What main says, the road and the notices, is read from an address that
// carries a run token alone, which main's own loads do and no page's can
// (a wrong one is refused above anything it says). It is kept in this
// entry of the history, where no page of another origin writes: a reload
// of main's load still shows it, and coming back to the entry by history
// (main refuses a page that move, and is not asked for the engine's own)
// shows the road and no notice.
// On the passkey road the script
// connects the CYFR elsewhere remembered by itself as the app starts,
// leaves a CYFR just connected to main, which opens it at its root, and
// asks main by addresses main alone answers to connect to another and,
// where main says the CYFR's page did not load, to open that CYFR again.
// That Try again and the passkey's way on each load the open CYFR's page
// with the kept sign-in, so each goes on (onward) only once a Connect at
// it, posted at the press, answers with next.
// With a CYFR open it goes on to the device's pages by itself only when
// it has nothing to tell (a notice main put in the address, or one
// cyfr's answer names): with a notice it stays, as it does on the
// passkey road, until the person takes a way on.
//
// The page, its style and its script are files of their own (assets/),
// embedded: the vocabulary check reads them as a person reads them. Each
// file's last newline is the file's, not the page's.
var (
	//go:embed assets/chooser.css
	chooserStyle string
	//go:embed assets/chooser.js
	chooserScript string
	//go:embed assets/chooser.html
	chooserMarkup string

	bootstrapStyle  = strings.TrimSuffix(chooserStyle, "\n")
	bootstrapScript = strings.TrimSuffix(chooserScript, "\n")
)

var bootstrapPolicy = "default-src 'none'; script-src " + hash(bootstrapScript) + "; style-src " + hash(bootstrapStyle) +
	"; connect-src 'self'; form-action 'none'; frame-ancestors 'none'; base-uri 'none'"

func hash(s string) string {
	sum := sha256.Sum256([]byte(s))
	return "'sha256-" + base64.StdEncoding.EncodeToString(sum[:]) + "'"
}

var bootstrapPage = `<!doctype html>
<html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>CYFR</title><style>` + bootstrapStyle + `</style>
` + strings.TrimSuffix(chooserMarkup, "\n") + `<script>` + bootstrapScript + `</script></html>`
