const s=sessionStorage,f=new URLSearchParams(location.hash.slice(1)),$=i=>document.getElementById(i);
const token=f.get("token")||s.getItem("token")||"",was=history.state||{},reloaded=(performance.getEntriesByType("navigation")[0]||{}).type==="reload";
const main=f.get("token")?{road:f.get("road"),told:(f.get("notice")||"").split(",")}:{road:was.road,told:reloaded&&was.told||[]},passkey=main.road==="passkey";
s.setItem("token",token);history.replaceState(main,"",location.pathname);
const notices={company:"This CYFR requires company sign-in. Open its address in a browser to continue. The CYFR app does not support company sign-in yet.",unanswered:"The CYFR at {CYFR} did not answer.",unforgotten:"The app locked, and could not clear the sign-in it kept on this computer. To clear it, press Connect to another CYFR, which clears it first.",uncleared:"The app could not clear the sign-in it kept on this computer, so it opened no other CYFR: try again."};
let asked=null,picks=0,started=false,epoch=0,run=0,found=false,busy=false;
const steps={files:"Getting CYFR's files",settings:"Writing its settings",images:"Downloading CYFR",start:"Starting CYFR"};
function say(t){$("notice").textContent=t||""}
function folder(a){if(a.folder){$("folder").textContent=a.folder;picks=a.picks||0;found=!!a.found;offer()}}
function offer(){$("go").hidden=busy||started||!found}
function checked(a){const d=a.docker||{},fix=d.commands||[];$("docker").textContent=!a.docker?a.error:d.ready?"Docker answers on this computer.":d.sentence+".";
$("commands").textContent=fix.map(c=>"sudo "+c).join("\n");$("run").hidden=$("commands").hidden=!fix.length;if(d.page)$("page").href=d.page;$("install").hidden=!d.page;$("check").hidden=!!d.ready;$("start").hidden=!d.ready}
function check(){$("docker").textContent="Checking whether Docker answers\u2026";$("run").hidden=$("commands").hidden=$("install").hidden=$("check").hidden=$("start").hidden=true;post("/bootstrap/docker",{}).then(checked)}
function progress(p){run=p.run||0;const running=!p.done&&!p.error;busy=running;if(p.done&&p.folder===$("folder").textContent)found=true;$("choose").hidden=true;$("setup").hidden=false;$("progress").hidden=false;
$("progress").textContent=["Setting up CYFR in "+p.folder].concat(p.steps.map(i=>steps[i]||i)).join("\n")+(running?"\u2026":"");
$("change").hidden=$("back").hidden=running||!!p.done;$("check").hidden=$("start").hidden=true;$("retry").hidden=!p.error;offer();
if(p.error||p.done)say(p.error?p.error+".":"CYFR is set up in "+p.folder+" and started."+(p.unrecorded?" "+p.unrecorded:""));
if(running)post("/bootstrap/setup",{seen:p.seq}).then(a=>a.setup?progress(a.setup):say(a.error));else if(p.done&&started){started=false;opening()}}
function begin(){started=true;say("");post("/bootstrap/start",{picks,run}).then(a=>{folder(a);if(a.setup)progress(a.setup);if(a.error)say(a.error)})}
function opening(){$("go").hidden=true;say("Opening CYFR\u2026");post("/bootstrap/open",{picks,run}).then(a=>{if(a.next)return location.replace(a.next);say(a.error||notices[a.notice]||"CYFR did not open.");$("go").hidden=false})}
function post(p,b){return fetch(p,{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify(Object.assign({token,epoch},b))}).then(r=>{s.setItem("token",token);return r.ok?r.json():{error:"This page is not the app's own. Quit the app and open it again."}},()=>({error:"The app's connection stopped. Quit it and open it again."}))}
function show(a,told){say(a.error||told);asked=a.confirm?a:null;const stay=!!(a.next&&(passkey||told));$("confirm").hidden=!asked;$("choose").hidden=!!asked||stay;$("road").hidden=!stay;
if(asked){$("named").textContent=a.cyfr;$("service").textContent=a.confirm}
if(stay){$("open").textContent=a.cyfr;$("passkey").hidden=$("either").hidden=$("another").hidden=!passkey;$("again").hidden=!passkey||!main.told.includes("unanswered");$("passkey").onclick=()=>onward(a.cyfr,a.cyfr+"/login");$("again").onclick=()=>onward(a.cyfr,"/bootstrap/again");$("words").onclick=()=>location.assign(a.next)}
else if(a.next)location.replace(a.next)}
function connected(a){if(!(passkey&&a.next))show(a,notices[a.notice])}
function onward(at,to){say("Connecting\u2026");post("/bootstrap/connect",{address:at}).then(a=>a.next?location.assign(to):say(a.error))}
function connect(address){say("Connecting\u2026");post("/bootstrap/connect",{address}).then(connected)}
post("/bootstrap/state",{}).then(a=>{epoch=a.epoch||0;if(a.cyfr)$("address").value=a.cyfr;folder(a);const told=main.told.map(n=>notices[n]).filter(Boolean).join(" ").replace("{CYFR}",a.cyfr||"");show(a,told);if(a.setup)progress(a.setup);else if(passkey&&a.resume&&!told)connect(a.resume)});
$("connect").addEventListener("submit",e=>{e.preventDefault();connect($("address").value)});
$("here").addEventListener("click",()=>{say("");$("choose").hidden=true;$("setup").hidden=false;check()});
$("check").addEventListener("click",check);
$("start").addEventListener("click",begin);
$("retry").addEventListener("click",begin);
$("go").addEventListener("click",opening);
$("back").addEventListener("click",()=>{$("setup").hidden=true;$("choose").hidden=false});
$("change").addEventListener("click",()=>{post("/bootstrap/folder",{picks}).then(a=>a.error?say(a.error):folder(a));location.assign("/bootstrap/pick?epoch="+epoch+"&pick="+picks)});
$("another").addEventListener("click",()=>location.assign("/bootstrap/another"));
$("approve").addEventListener("click",()=>{say("Connecting\u2026");post("/bootstrap/approve",{cyfr:asked.cyfr,directory:asked.confirm}).then(connected)});
$("decline").addEventListener("click",()=>{show({});say("Nothing was sent to that account service.")});
