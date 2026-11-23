const s=sessionStorage,f=new URLSearchParams(location.hash.slice(1)),$=i=>document.getElementById(i);
const token=f.get("token")||s.getItem("token")||"",was=history.state||{},reloaded=(performance.getEntriesByType("navigation")[0]||{}).type==="reload";
const main=f.get("token")?{road:f.get("road"),told:(f.get("notice")||"").split(",")}:{road:was.road,told:reloaded&&was.told||[]},passkey=main.road==="passkey";
s.setItem("token",token);history.replaceState(main,"",location.pathname);
const notices={company:"This CYFR requires company sign-in. Open its address in a browser to continue. The CYFR app does not support company sign-in yet.",unanswered:"The CYFR at {CYFR} did not answer.",unforgotten:"The app locked, and could not clear the sign-in it kept on this computer. To clear it, press Connect to another CYFR, which clears it first.",uncleared:"The app could not clear the sign-in it kept on this computer, so it opened no other CYFR: try again."};
let asked=null,picks=0;
function say(t){$("notice").textContent=t||""}
function folder(a){if(a.folder){$("folder").textContent=a.folder;picks=a.picks||0}}
function post(p,b){return fetch(p,{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify(Object.assign({token},b))}).then(r=>{s.setItem("token",token);return r.ok?r.json():{error:"This page is not the app's own. Quit the app and open it again."}},()=>({error:"The app's connection stopped. Quit it and open it again."}))}
function show(a,told){say(a.error||told);asked=a.confirm?a:null;const stay=!!(a.next&&(passkey||told));$("confirm").hidden=!asked;$("choose").hidden=!!asked||stay;$("road").hidden=!stay;
if(asked){$("named").textContent=a.cyfr;$("service").textContent=a.confirm}
if(stay){$("open").textContent=a.cyfr;$("passkey").hidden=$("either").hidden=$("another").hidden=!passkey;$("again").hidden=!passkey||!main.told.includes("unanswered");$("passkey").onclick=()=>onward(a.cyfr,a.cyfr+"/login");$("again").onclick=()=>onward(a.cyfr,"/bootstrap/again");$("words").onclick=()=>location.assign(a.next)}
else if(a.next)location.replace(a.next)}
function connected(a){if(!(passkey&&a.next))show(a,notices[a.notice])}
function onward(at,to){say("Connecting\u2026");post("/bootstrap/connect",{address:at}).then(a=>a.next?location.assign(to):say(a.error))}
function connect(address){say("Connecting\u2026");post("/bootstrap/connect",{address}).then(connected)}
post("/bootstrap/state",{}).then(a=>{if(a.cyfr)$("address").value=a.cyfr;folder(a);const told=main.told.map(n=>notices[n]).filter(Boolean).join(" ").replace("{CYFR}",a.cyfr||"");show(a,told);if(passkey&&a.resume&&!told)connect(a.resume)});
$("connect").addEventListener("submit",e=>{e.preventDefault();connect($("address").value)});
$("change").addEventListener("click",()=>{post("/bootstrap/folder",{picks}).then(a=>a.error?say(a.error):folder(a));location.assign("/bootstrap/pick")});
$("another").addEventListener("click",()=>location.assign("/bootstrap/another"));
$("approve").addEventListener("click",()=>{say("Connecting\u2026");post("/bootstrap/approve",{cyfr:asked.cyfr,directory:asked.confirm}).then(connected)});
$("decline").addEventListener("click",()=>{show({});say("Nothing was sent to that account service.")});
