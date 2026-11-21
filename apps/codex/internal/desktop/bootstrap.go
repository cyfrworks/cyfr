// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package desktop

import (
	"crypto/sha256"
	"encoding/base64"
)

// The chooser's one style and one script, each allowed by its hash alone.
// The script keeps the run token from the first address's fragment in
// sessionStorage, private to this origin, takes it off the address, and
// sends it with each request; it writes answers as text, never markup.
const (
	bootstrapStyle = `body{background:#0b1418;color:#e8f1f2;font:1.25rem system-ui,sans-serif;margin:0;display:grid;place-items:center;min-height:90vh}
main{max-width:34rem;padding:1rem}label{display:block;margin:1rem 0}input{display:block;width:100%;font:inherit;padding:.5rem;margin-top:.25rem;box-sizing:border-box}
button{font:inherit;padding:.5rem 1rem;margin:.5rem .5rem 0 0}.quiet{background:none;color:inherit;border:1px solid #567}.code{font-family:monospace;word-break:break-all}`
	bootstrapScript = `const s=sessionStorage,f=new URLSearchParams(location.hash.slice(1)),$=i=>document.getElementById(i);
if(f.get("token"))s.setItem("token",f.get("token"));history.replaceState(null,"",location.pathname);
let asked=null;
function say(t){$("notice").textContent=t||""}
function post(p,b){return fetch(p,{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify(Object.assign({token:s.getItem("token")||""},b))}).then(r=>r.ok?r.json():{error:"This page is not the app's own. Quit the app and open it again."},()=>({error:"The app's connection stopped. Quit it and open it again."}))}
function show(a){say(a.error);asked=a.confirm?a:null;$("confirm").hidden=!asked;$("choose").hidden=!!asked;
if(asked){$("home").textContent=a.home;$("service").textContent=a.confirm}if(a.next)location.replace(a.next)}
post("/bootstrap/state",{}).then(a=>{if(a.home)$("address").value=a.home;say(a.error)});
$("connect").addEventListener("submit",e=>{e.preventDefault();say("Connecting…");post("/bootstrap/connect",{address:$("address").value}).then(show)});
$("approve").addEventListener("click",()=>{say("Connecting…");post("/bootstrap/approve",{home:asked.home,directory:asked.confirm}).then(show)});
$("decline").addEventListener("click",()=>{show({});say("Nothing was sent to that account service.")});`
)

var bootstrapPolicy = "default-src 'none'; script-src " + hash(bootstrapScript) + "; style-src " + hash(bootstrapStyle) +
	"; connect-src 'self'; form-action 'none'; frame-ancestors 'none'; base-uri 'none'"

func hash(s string) string {
	sum := sha256.Sum256([]byte(s))
	return "'sha256-" + base64.StdEncoding.EncodeToString(sum[:]) + "'"
}

const bootstrapPage = `<!doctype html>
<html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>CYFR</title><style>` + bootstrapStyle + `</style>
<main>
<section id="choose">
<h1>Connect to a CYFR</h1>
<form id="connect"><label>Its address<input id="address" autocomplete="url" placeholder="https://cyfr.example.com" autofocus required></label>
<button>Connect</button></form>
<p>Setting up CYFR on this computer comes in the next version of this app.</p>
</section>
<section id="confirm" hidden>
<h1>Check the account service</h1>
<p>The CYFR at <b class="code" id="home"></b> signs you in at the account service</p>
<p class="code" id="service"></p>
<p>That is not cyfr.run. Go on only if you expected this address.</p>
<button id="approve">Go on</button><button id="decline" class="quiet">Cancel</button>
</section>
<p id="notice" role="status"></p>
</main><script>` + bootstrapScript + `</script></html>`
