(function(){const t=document.createElement("link").relList;if(t&&t.supports&&t.supports("modulepreload"))return;for(const l of document.querySelectorAll('link[rel="modulepreload"]'))a(l);new MutationObserver(l=>{for(const u of l)if(u.type==="childList")for(const h of u.addedNodes)h.tagName==="LINK"&&h.rel==="modulepreload"&&a(h)}).observe(document,{childList:!0,subtree:!0});function i(l){const u={};return l.integrity&&(u.integrity=l.integrity),l.referrerPolicy&&(u.referrerPolicy=l.referrerPolicy),l.crossOrigin==="use-credentials"?u.credentials="include":l.crossOrigin==="anonymous"?u.credentials="omit":u.credentials="same-origin",u}function a(l){if(l.ep)return;l.ep=!0;const u=i(l);fetch(l.href,u)}})();(function(){const o=document.createElement("link").relList;if(o&&o.supports&&o.supports("modulepreload"))return;for(const a of document.querySelectorAll('link[rel="modulepreload"]'))i(a);new MutationObserver(a=>{for(const l of a)if(l.type==="childList")for(const u of l.addedNodes)u.tagName==="LINK"&&u.rel==="modulepreload"&&i(u)}).observe(document,{childList:!0,subtree:!0});function t(a){const l={};return a.integrity&&(l.integrity=a.integrity),a.referrerPolicy&&(l.referrerPolicy=a.referrerPolicy),a.crossOrigin==="use-credentials"?l.credentials="include":a.crossOrigin==="anonymous"?l.credentials="omit":l.credentials="same-origin",l}function i(a){if(a.ep)return;a.ep=!0;const l=t(a);fetch(a.href,l)}})();var iv={exports:{}},_o={};/**
* @license React
* react-jsx-runtime.production.js
*
* Copyright (c) Meta Platforms, Inc. and affiliates.
*
* This source code is licensed under the MIT license found in the
* LICENSE file in the root directory of this source tree.
*/var nv;function ix(){if(nv)return _o;nv=1;var o=Symbol.for("react.transitional.element"),t=Symbol.for("react.fragment");function i(a,l,u){var h=null;if(u!==void 0&&(h=""+u),l.key!==void 0&&(h=""+l.key),"key"in l){u={};for(var f in l)f!=="key"&&(u[f]=l[f])}else u=l;return l=u.ref,{$$typeof:o,type:a,key:h,ref:l!==void 0?l:null,props:u}}return _o.Fragment=t,_o.jsx=i,_o.jsxs=i,_o}var av;function nx(){return av||(av=1,iv.exports=ix()),iv.exports}var nn=nx(),sv={exports:{}},et={};/**
* @license React
* react.production.js
*
* Copyright (c) Meta Platforms, Inc. and affiliates.
*
* This source code is licensed under the MIT license found in the
* LICENSE file in the root directory of this source tree.
*/var ov;function ax(){if(ov)return et;ov=1;var o=Symbol.for("react.transitional.element"),t=Symbol.for("react.portal"),i=Symbol.for("react.fragment"),a=Symbol.for("react.strict_mode"),l=Symbol.for("react.profiler"),u=Symbol.for("react.consumer"),h=Symbol.for("react.context"),f=Symbol.for("react.forward_ref"),m=Symbol.for("react.suspense"),p=Symbol.for("react.memo"),_=Symbol.for("react.lazy"),y=Symbol.for("react.activity"),x=Symbol.iterator;function b(O){return O===null||typeof O!="object"?null:(O=x&&O[x]||O["@@iterator"],typeof O=="function"?O:null)}var R={isMounted:function(){return!1},enqueueForceUpdate:function(){},enqueueReplaceState:function(){},enqueueSetState:function(){}},A=Object.assign,S={};function v(O,ie,xe){this.props=O,this.context=ie,this.refs=S,this.updater=xe||R}v.prototype.isReactComponent={},v.prototype.setState=function(O,ie){if(typeof O!="object"&&typeof O!="function"&&O!=null)throw Error("takes an object of state variables to update or a function which returns an object of state variables.");this.updater.enqueueSetState(this,O,ie,"setState")},v.prototype.forceUpdate=function(O){this.updater.enqueueForceUpdate(this,O,"forceUpdate")};function D(){}D.prototype=v.prototype;function L(O,ie,xe){this.props=O,this.context=ie,this.refs=S,this.updater=xe||R}var C=L.prototype=new D;C.constructor=L,A(C,v.prototype),C.isPureReactComponent=!0;var G=Array.isArray;function k(){}var I={H:null,A:null,T:null,S:null},H=Object.prototype.hasOwnProperty;function P(O,ie,xe){var Q=xe.ref;return{$$typeof:o,type:O,key:ie,ref:Q!==void 0?Q:null,props:xe}}function w(O,ie){return P(O.type,ie,O.props)}function F(O){return typeof O=="object"&&O!==null&&O.$$typeof===o}function te(O){var ie={"=":"=0",":":"=2"};return"$"+O.replace(/[=:]/g,function(xe){return ie[xe]})}var se=/\/+/g;function ce(O,ie){return typeof O=="object"&&O!==null&&O.key!=null?te(""+O.key):ie.toString(36)}function ve(O){switch(O.status){case"fulfilled":return O.value;case"rejected":throw O.reason;default:switch(typeof O.status=="string"?O.then(k,k):(O.status="pending",O.then(function(ie){O.status==="pending"&&(O.status="fulfilled",O.value=ie)},function(ie){O.status==="pending"&&(O.status="rejected",O.reason=ie)})),O.status){case"fulfilled":return O.value;case"rejected":throw O.reason}}throw O}function N(O,ie,xe,Q,ue){var Me=typeof O;(Me==="undefined"||Me==="boolean")&&(O=null);var ye=!1;if(O===null)ye=!0;else switch(Me){case"bigint":case"string":case"number":ye=!0;break;case"object":switch(O.$$typeof){case o:case t:ye=!0;break;case _:return ye=O._init,N(ye(O._payload),ie,xe,Q,ue)}}if(ye)return ue=ue(O),ye=Q===""?"."+ce(O,0):Q,G(ue)?(xe="",ye!=null&&(xe=ye.replace(se,"$&/")+"/"),N(ue,ie,xe,"",function(tt){return tt})):ue!=null&&(F(ue)&&(ue=w(ue,xe+(ue.key==null||O&&O.key===ue.key?"":(""+ue.key).replace(se,"$&/")+"/")+ye)),ie.push(ue)),1;ye=0;var ke=Q===""?".":Q+":";if(G(O))for(var Fe=0;Fe<O.length;Fe++)Q=O[Fe],Me=ke+ce(Q,Fe),ye+=N(Q,ie,xe,Me,ue);else if(Fe=b(O),typeof Fe=="function")for(O=Fe.call(O),Fe=0;!(Q=O.next()).done;)Q=Q.value,Me=ke+ce(Q,Fe++),ye+=N(Q,ie,xe,Me,ue);else if(Me==="object"){if(typeof O.then=="function")return N(ve(O),ie,xe,Q,ue);throw ie=String(O),Error("Objects are not valid as a React child (found: "+(ie==="[object Object]"?"object with keys {"+Object.keys(O).join(", ")+"}":ie)+"). If you meant to render a collection of children, use an array instead.")}return ye}function K(O,ie,xe){if(O==null)return O;var Q=[],ue=0;return N(O,Q,"","",function(Me){return ie.call(xe,Me,ue++)}),Q}function q(O){if(O._status===-1){var ie=O._result;ie=ie(),ie.then(function(xe){(O._status===0||O._status===-1)&&(O._status=1,O._result=xe)},function(xe){(O._status===0||O._status===-1)&&(O._status=2,O._result=xe)}),O._status===-1&&(O._status=0,O._result=ie)}if(O._status===1)return O._result.default;throw O._result}var ge=typeof reportError=="function"?reportError:function(O){if(typeof window=="object"&&typeof window.ErrorEvent=="function"){var ie=new window.ErrorEvent("error",{bubbles:!0,cancelable:!0,message:typeof O=="object"&&O!==null&&typeof O.message=="string"?String(O.message):String(O),error:O});if(!window.dispatchEvent(ie))return}else if(typeof process=="object"&&typeof process.emit=="function"){process.emit("uncaughtException",O);return}console.error(O)},we={map:K,forEach:function(O,ie,xe){K(O,function(){ie.apply(this,arguments)},xe)},count:function(O){var ie=0;return K(O,function(){ie++}),ie},toArray:function(O){return K(O,function(ie){return ie})||[]},only:function(O){if(!F(O))throw Error("React.Children.only expected to receive a single React element child.");return O}};return et.Activity=y,et.Children=we,et.Component=v,et.Fragment=i,et.Profiler=l,et.PureComponent=L,et.StrictMode=a,et.Suspense=m,et.__CLIENT_INTERNALS_DO_NOT_USE_OR_WARN_USERS_THEY_CANNOT_UPGRADE=I,et.__COMPILER_RUNTIME={__proto__:null,c:function(O){return I.H.useMemoCache(O)}},et.cache=function(O){return function(){return O.apply(null,arguments)}},et.cacheSignal=function(){return null},et.cloneElement=function(O,ie,xe){if(O==null)throw Error("The argument must be a React element, but you passed "+O+".");var Q=A({},O.props),ue=O.key;if(ie!=null)for(Me in ie.key!==void 0&&(ue=""+ie.key),ie)!H.call(ie,Me)||Me==="key"||Me==="__self"||Me==="__source"||Me==="ref"&&ie.ref===void 0||(Q[Me]=ie[Me]);var Me=arguments.length-2;if(Me===1)Q.children=xe;else if(1<Me){for(var ye=Array(Me),ke=0;ke<Me;ke++)ye[ke]=arguments[ke+2];Q.children=ye}return P(O.type,ue,Q)},et.createContext=function(O){return O={$$typeof:h,_currentValue:O,_currentValue2:O,_threadCount:0,Provider:null,Consumer:null},O.Provider=O,O.Consumer={$$typeof:u,_context:O},O},et.createElement=function(O,ie,xe){var Q,ue={},Me=null;if(ie!=null)for(Q in ie.key!==void 0&&(Me=""+ie.key),ie)H.call(ie,Q)&&Q!=="key"&&Q!=="__self"&&Q!=="__source"&&(ue[Q]=ie[Q]);var ye=arguments.length-2;if(ye===1)ue.children=xe;else if(1<ye){for(var ke=Array(ye),Fe=0;Fe<ye;Fe++)ke[Fe]=arguments[Fe+2];ue.children=ke}if(O&&O.defaultProps)for(Q in ye=O.defaultProps,ye)ue[Q]===void 0&&(ue[Q]=ye[Q]);return P(O,Me,ue)},et.createRef=function(){return{current:null}},et.forwardRef=function(O){return{$$typeof:f,render:O}},et.isValidElement=F,et.lazy=function(O){return{$$typeof:_,_payload:{_status:-1,_result:O},_init:q}},et.memo=function(O,ie){return{$$typeof:p,type:O,compare:ie===void 0?null:ie}},et.startTransition=function(O){var ie=I.T,xe={};I.T=xe;try{var Q=O(),ue=I.S;ue!==null&&ue(xe,Q),typeof Q=="object"&&Q!==null&&typeof Q.then=="function"&&Q.then(k,ge)}catch(Me){ge(Me)}finally{ie!==null&&xe.types!==null&&(ie.types=xe.types),I.T=ie}},et.unstable_useCacheRefresh=function(){return I.H.useCacheRefresh()},et.use=function(O){return I.H.use(O)},et.useActionState=function(O,ie,xe){return I.H.useActionState(O,ie,xe)},et.useCallback=function(O,ie){return I.H.useCallback(O,ie)},et.useContext=function(O){return I.H.useContext(O)},et.useDebugValue=function(){},et.useDeferredValue=function(O,ie){return I.H.useDeferredValue(O,ie)},et.useEffect=function(O,ie){return I.H.useEffect(O,ie)},et.useEffectEvent=function(O){return I.H.useEffectEvent(O)},et.useId=function(){return I.H.useId()},et.useImperativeHandle=function(O,ie,xe){return I.H.useImperativeHandle(O,ie,xe)},et.useInsertionEffect=function(O,ie){return I.H.useInsertionEffect(O,ie)},et.useLayoutEffect=function(O,ie){return I.H.useLayoutEffect(O,ie)},et.useMemo=function(O,ie){return I.H.useMemo(O,ie)},et.useOptimistic=function(O,ie){return I.H.useOptimistic(O,ie)},et.useReducer=function(O,ie,xe){return I.H.useReducer(O,ie,xe)},et.useRef=function(O){return I.H.useRef(O)},et.useState=function(O){return I.H.useState(O)},et.useSyncExternalStore=function(O,ie,xe){return I.H.useSyncExternalStore(O,ie,xe)},et.useTransition=function(){return I.H.useTransition()},et.version="19.2.4",et}var lv;function nf(){return lv||(lv=1,sv.exports=ax()),sv.exports}var mc=nf(),Nd={exports:{}},yo={},cv={exports:{}},uv={};/**
* @license React
* scheduler.production.js
*
* Copyright (c) Meta Platforms, Inc. and affiliates.
*
* This source code is licensed under the MIT license found in the
* LICENSE file in the root directory of this source tree.
*/var dv;function sx(){return dv||(dv=1,(function(o){function t(N,K){var q=N.length;N.push(K);e:for(;0<q;){var ge=q-1>>>1,we=N[ge];if(0<l(we,K))N[ge]=K,N[q]=we,q=ge;else break e}}function i(N){return N.length===0?null:N[0]}function a(N){if(N.length===0)return null;var K=N[0],q=N.pop();if(q!==K){N[0]=q;e:for(var ge=0,we=N.length,O=we>>>1;ge<O;){var ie=2*(ge+1)-1,xe=N[ie],Q=ie+1,ue=N[Q];if(0>l(xe,q))Q<we&&0>l(ue,xe)?(N[ge]=ue,N[Q]=q,ge=Q):(N[ge]=xe,N[ie]=q,ge=ie);else if(Q<we&&0>l(ue,q))N[ge]=ue,N[Q]=q,ge=Q;else break e}}return K}function l(N,K){var q=N.sortIndex-K.sortIndex;return q!==0?q:N.id-K.id}if(o.unstable_now=void 0,typeof performance=="object"&&typeof performance.now=="function"){var u=performance;o.unstable_now=function(){return u.now()}}else{var h=Date,f=h.now();o.unstable_now=function(){return h.now()-f}}var m=[],p=[],_=1,y=null,x=3,b=!1,R=!1,A=!1,S=!1,v=typeof setTimeout=="function"?setTimeout:null,D=typeof clearTimeout=="function"?clearTimeout:null,L=typeof setImmediate<"u"?setImmediate:null;function C(N){for(var K=i(p);K!==null;){if(K.callback===null)a(p);else if(K.startTime<=N)a(p),K.sortIndex=K.expirationTime,t(m,K);else break;K=i(p)}}function G(N){if(A=!1,C(N),!R)if(i(m)!==null)R=!0,k||(k=!0,te());else{var K=i(p);K!==null&&ve(G,K.startTime-N)}}var k=!1,I=-1,H=5,P=-1;function w(){return S?!0:!(o.unstable_now()-P<H)}function F(){if(S=!1,k){var N=o.unstable_now();P=N;var K=!0;try{e:{R=!1,A&&(A=!1,D(I),I=-1),b=!0;var q=x;try{t:{for(C(N),y=i(m);y!==null&&!(y.expirationTime>N&&w());){var ge=y.callback;if(typeof ge=="function"){y.callback=null,x=y.priorityLevel;var we=ge(y.expirationTime<=N);if(N=o.unstable_now(),typeof we=="function"){y.callback=we,C(N),K=!0;break t}y===i(m)&&a(m),C(N)}else a(m);y=i(m)}if(y!==null)K=!0;else{var O=i(p);O!==null&&ve(G,O.startTime-N),K=!1}}break e}finally{y=null,x=q,b=!1}K=void 0}}finally{K?te():k=!1}}}var te;if(typeof L=="function")te=function(){L(F)};else if(typeof MessageChannel<"u"){var se=new MessageChannel,ce=se.port2;se.port1.onmessage=F,te=function(){ce.postMessage(null)}}else te=function(){v(F,0)};function ve(N,K){I=v(function(){N(o.unstable_now())},K)}o.unstable_IdlePriority=5,o.unstable_ImmediatePriority=1,o.unstable_LowPriority=4,o.unstable_NormalPriority=3,o.unstable_Profiling=null,o.unstable_UserBlockingPriority=2,o.unstable_cancelCallback=function(N){N.callback=null},o.unstable_forceFrameRate=function(N){0>N||125<N?console.error("forceFrameRate takes a positive int between 0 and 125, forcing frame rates higher than 125 fps is not supported"):H=0<N?Math.floor(1e3/N):5},o.unstable_getCurrentPriorityLevel=function(){return x},o.unstable_next=function(N){switch(x){case 1:case 2:case 3:var K=3;break;default:K=x}var q=x;x=K;try{return N()}finally{x=q}},o.unstable_requestPaint=function(){S=!0},o.unstable_runWithPriority=function(N,K){switch(N){case 1:case 2:case 3:case 4:case 5:break;default:N=3}var q=x;x=N;try{return K()}finally{x=q}},o.unstable_scheduleCallback=function(N,K,q){var ge=o.unstable_now();switch(typeof q=="object"&&q!==null?(q=q.delay,q=typeof q=="number"&&0<q?ge+q:ge):q=ge,N){case 1:var we=-1;break;case 2:we=250;break;case 5:we=1073741823;break;case 4:we=1e4;break;default:we=5e3}return we=q+we,N={id:_++,callback:K,priorityLevel:N,startTime:q,expirationTime:we,sortIndex:-1},q>ge?(N.sortIndex=q,t(p,N),i(m)===null&&N===i(p)&&(A?(D(I),I=-1):A=!0,ve(G,q-ge))):(N.sortIndex=we,t(m,N),R||b||(R=!0,k||(k=!0,te()))),N},o.unstable_shouldYield=w,o.unstable_wrapCallback=function(N){var K=x;return function(){var q=x;x=K;try{return N.apply(this,arguments)}finally{x=q}}}})(uv)),uv}var hv;function ox(){return hv||(hv=1,cv.exports=sx()),cv.exports}var Od={exports:{}},xr={};/**
* @license React
* react-dom.production.js
*
* Copyright (c) Meta Platforms, Inc. and affiliates.
*
* This source code is licensed under the MIT license found in the
* LICENSE file in the root directory of this source tree.
*/var fv;function lx(){if(fv)return xr;fv=1;var o=nf();function t(m){var p="https://react.dev/errors/"+m;if(1<arguments.length){p+="?args[]="+encodeURIComponent(arguments[1]);for(var _=2;_<arguments.length;_++)p+="&args[]="+encodeURIComponent(arguments[_])}return"Minified React error #"+m+"; visit "+p+" for the full message or use the non-minified dev environment for full errors and additional helpful warnings."}function i(){}var a={d:{f:i,r:function(){throw Error(t(522))},D:i,C:i,L:i,m:i,X:i,S:i,M:i},p:0,findDOMNode:null},l=Symbol.for("react.portal");function u(m,p,_){var y=3<arguments.length&&arguments[3]!==void 0?arguments[3]:null;return{$$typeof:l,key:y==null?null:""+y,children:m,containerInfo:p,implementation:_}}var h=o.__CLIENT_INTERNALS_DO_NOT_USE_OR_WARN_USERS_THEY_CANNOT_UPGRADE;function f(m,p){if(m==="font")return"";if(typeof p=="string")return p==="use-credentials"?p:""}return xr.__DOM_INTERNALS_DO_NOT_USE_OR_WARN_USERS_THEY_CANNOT_UPGRADE=a,xr.createPortal=function(m,p){var _=2<arguments.length&&arguments[2]!==void 0?arguments[2]:null;if(!p||p.nodeType!==1&&p.nodeType!==9&&p.nodeType!==11)throw Error(t(299));return u(m,p,null,_)},xr.flushSync=function(m){var p=h.T,_=a.p;try{if(h.T=null,a.p=2,m)return m()}finally{h.T=p,a.p=_,a.d.f()}},xr.preconnect=function(m,p){typeof m=="string"&&(p?(p=p.crossOrigin,p=typeof p=="string"?p==="use-credentials"?p:"":void 0):p=null,a.d.C(m,p))},xr.prefetchDNS=function(m){typeof m=="string"&&a.d.D(m)},xr.preinit=function(m,p){if(typeof m=="string"&&p&&typeof p.as=="string"){var _=p.as,y=f(_,p.crossOrigin),x=typeof p.integrity=="string"?p.integrity:void 0,b=typeof p.fetchPriority=="string"?p.fetchPriority:void 0;_==="style"?a.d.S(m,typeof p.precedence=="string"?p.precedence:void 0,{crossOrigin:y,integrity:x,fetchPriority:b}):_==="script"&&a.d.X(m,{crossOrigin:y,integrity:x,fetchPriority:b,nonce:typeof p.nonce=="string"?p.nonce:void 0})}},xr.preinitModule=function(m,p){if(typeof m=="string")if(typeof p=="object"&&p!==null){if(p.as==null||p.as==="script"){var _=f(p.as,p.crossOrigin);a.d.M(m,{crossOrigin:_,integrity:typeof p.integrity=="string"?p.integrity:void 0,nonce:typeof p.nonce=="string"?p.nonce:void 0})}}else p==null&&a.d.M(m)},xr.preload=function(m,p){if(typeof m=="string"&&typeof p=="object"&&p!==null&&typeof p.as=="string"){var _=p.as,y=f(_,p.crossOrigin);a.d.L(m,_,{crossOrigin:y,integrity:typeof p.integrity=="string"?p.integrity:void 0,nonce:typeof p.nonce=="string"?p.nonce:void 0,type:typeof p.type=="string"?p.type:void 0,fetchPriority:typeof p.fetchPriority=="string"?p.fetchPriority:void 0,referrerPolicy:typeof p.referrerPolicy=="string"?p.referrerPolicy:void 0,imageSrcSet:typeof p.imageSrcSet=="string"?p.imageSrcSet:void 0,imageSizes:typeof p.imageSizes=="string"?p.imageSizes:void 0,media:typeof p.media=="string"?p.media:void 0})}},xr.preloadModule=function(m,p){if(typeof m=="string")if(p){var _=f(p.as,p.crossOrigin);a.d.m(m,{as:typeof p.as=="string"&&p.as!=="script"?p.as:void 0,crossOrigin:_,integrity:typeof p.integrity=="string"?p.integrity:void 0})}else a.d.m(m)},xr.requestFormReset=function(m){a.d.r(m)},xr.unstable_batchedUpdates=function(m,p){return m(p)},xr.useFormState=function(m,p,_){return h.H.useFormState(m,p,_)},xr.useFormStatus=function(){return h.H.useHostTransitionStatus()},xr.version="19.2.4",xr}var pv;function cx(){if(pv)return Od.exports;pv=1;function o(){if(!(typeof __REACT_DEVTOOLS_GLOBAL_HOOK__>"u"||typeof __REACT_DEVTOOLS_GLOBAL_HOOK__.checkDCE!="function"))try{__REACT_DEVTOOLS_GLOBAL_HOOK__.checkDCE(o)}catch(t){console.error(t)}}return o(),Od.exports=lx(),Od.exports}/**
* @license React
* react-dom-client.production.js
*
* Copyright (c) Meta Platforms, Inc. and affiliates.
*
* This source code is licensed under the MIT license found in the
* LICENSE file in the root directory of this source tree.
*/var mv;function ux(){if(mv)return yo;mv=1;var o=ox(),t=nf(),i=cx();function a(e){var r="https://react.dev/errors/"+e;if(1<arguments.length){r+="?args[]="+encodeURIComponent(arguments[1]);for(var n=2;n<arguments.length;n++)r+="&args[]="+encodeURIComponent(arguments[n])}return"Minified React error #"+e+"; visit "+r+" for the full message or use the non-minified dev environment for full errors and additional helpful warnings."}function l(e){return!(!e||e.nodeType!==1&&e.nodeType!==9&&e.nodeType!==11)}function u(e){var r=e,n=e;if(e.alternate)for(;r.return;)r=r.return;else{e=r;do r=e,(r.flags&4098)!==0&&(n=r.return),e=r.return;while(e)}return r.tag===3?n:null}function h(e){if(e.tag===13){var r=e.memoizedState;if(r===null&&(e=e.alternate,e!==null&&(r=e.memoizedState)),r!==null)return r.dehydrated}return null}function f(e){if(e.tag===31){var r=e.memoizedState;if(r===null&&(e=e.alternate,e!==null&&(r=e.memoizedState)),r!==null)return r.dehydrated}return null}function m(e){if(u(e)!==e)throw Error(a(188))}function p(e){var r=e.alternate;if(!r){if(r=u(e),r===null)throw Error(a(188));return r!==e?null:e}for(var n=e,s=r;;){var c=n.return;if(c===null)break;var d=c.alternate;if(d===null){if(s=c.return,s!==null){n=s;continue}break}if(c.child===d.child){for(d=c.child;d;){if(d===n)return m(c),e;if(d===s)return m(c),r;d=d.sibling}throw Error(a(188))}if(n.return!==s.return)n=c,s=d;else{for(var g=!1,M=c.child;M;){if(M===n){g=!0,n=c,s=d;break}if(M===s){g=!0,s=c,n=d;break}M=M.sibling}if(!g){for(M=d.child;M;){if(M===n){g=!0,n=d,s=c;break}if(M===s){g=!0,s=d,n=c;break}M=M.sibling}if(!g)throw Error(a(189))}}if(n.alternate!==s)throw Error(a(190))}if(n.tag!==3)throw Error(a(188));return n.stateNode.current===n?e:r}function _(e){var r=e.tag;if(r===5||r===26||r===27||r===6)return e;for(e=e.child;e!==null;){if(r=_(e),r!==null)return r;e=e.sibling}return null}var y=Object.assign,x=Symbol.for("react.element"),b=Symbol.for("react.transitional.element"),R=Symbol.for("react.portal"),A=Symbol.for("react.fragment"),S=Symbol.for("react.strict_mode"),v=Symbol.for("react.profiler"),D=Symbol.for("react.consumer"),L=Symbol.for("react.context"),C=Symbol.for("react.forward_ref"),G=Symbol.for("react.suspense"),k=Symbol.for("react.suspense_list"),I=Symbol.for("react.memo"),H=Symbol.for("react.lazy"),P=Symbol.for("react.activity"),w=Symbol.for("react.memo_cache_sentinel"),F=Symbol.iterator;function te(e){return e===null||typeof e!="object"?null:(e=F&&e[F]||e["@@iterator"],typeof e=="function"?e:null)}var se=Symbol.for("react.client.reference");function ce(e){if(e==null)return null;if(typeof e=="function")return e.$$typeof===se?null:e.displayName||e.name||null;if(typeof e=="string")return e;switch(e){case A:return"Fragment";case v:return"Profiler";case S:return"StrictMode";case G:return"Suspense";case k:return"SuspenseList";case P:return"Activity"}if(typeof e=="object")switch(e.$$typeof){case R:return"Portal";case L:return e.displayName||"Context";case D:return(e._context.displayName||"Context")+".Consumer";case C:var r=e.render;return e=e.displayName,e||(e=r.displayName||r.name||"",e=e!==""?"ForwardRef("+e+")":"ForwardRef"),e;case I:return r=e.displayName||null,r!==null?r:ce(e.type)||"Memo";case H:r=e._payload,e=e._init;try{return ce(e(r))}catch{}}return null}var ve=Array.isArray,N=t.__CLIENT_INTERNALS_DO_NOT_USE_OR_WARN_USERS_THEY_CANNOT_UPGRADE,K=i.__DOM_INTERNALS_DO_NOT_USE_OR_WARN_USERS_THEY_CANNOT_UPGRADE,q={pending:!1,data:null,method:null,action:null},ge=[],we=-1;function O(e){return{current:e}}function ie(e){0>we||(e.current=ge[we],ge[we]=null,we--)}function xe(e,r){we++,ge[we]=e.current,e.current=r}var Q=O(null),ue=O(null),Me=O(null),ye=O(null);function ke(e,r){switch(xe(Me,r),xe(ue,e),xe(Q,null),r.nodeType){case 9:case 11:e=(e=r.documentElement)&&(e=e.namespaceURI)?Tg(e):0;break;default:if(e=r.tagName,r=r.namespaceURI)r=Tg(r),e=Rg(r,e);else switch(e){case"svg":e=1;break;case"math":e=2;break;default:e=0}}ie(Q),xe(Q,e)}function Fe(){ie(Q),ie(ue),ie(Me)}function tt(e){e.memoizedState!==null&&xe(ye,e);var r=Q.current,n=Rg(r,e.type);r!==n&&(xe(ue,e),xe(Q,n))}function Lt(e){ue.current===e&&(ie(Q),ie(ue)),ye.current===e&&(ie(ye),po._currentValue=q)}var ut,Vt;function B(e){if(ut===void 0)try{throw Error()}catch(n){var r=n.stack.trim().match(/\n( *(at )?)/);ut=r&&r[1]||"",Vt=-1<n.stack.indexOf(`
    at`)?" (<anonymous>)":-1<n.stack.indexOf("@")?"@unknown:0:0":""}return`
`+ut+e+Vt}var _r=!1;function dt(e,r){if(!e||_r)return"";_r=!0;var n=Error.prepareStackTrace;Error.prepareStackTrace=void 0;try{var s={DetermineComponentFrameRoot:function(){try{if(r){var me=function(){throw Error()};if(Object.defineProperty(me.prototype,"props",{set:function(){throw Error()}}),typeof Reflect=="object"&&Reflect.construct){try{Reflect.construct(me,[])}catch(oe){var re=oe}Reflect.construct(e,[],me)}else{try{me.call()}catch(oe){re=oe}e.call(me.prototype)}}else{try{throw Error()}catch(oe){re=oe}(me=e())&&typeof me.catch=="function"&&me.catch(function(){})}}catch(oe){if(oe&&re&&typeof oe.stack=="string")return[oe.stack,re.stack]}return[null,null]}};s.DetermineComponentFrameRoot.displayName="DetermineComponentFrameRoot";var c=Object.getOwnPropertyDescriptor(s.DetermineComponentFrameRoot,"name");c&&c.configurable&&Object.defineProperty(s.DetermineComponentFrameRoot,"name",{value:"DetermineComponentFrameRoot"});var d=s.DetermineComponentFrameRoot(),g=d[0],M=d[1];if(g&&M){var z=g.split(`
`),J=M.split(`
`);for(c=s=0;s<z.length&&!z[s].includes("DetermineComponentFrameRoot");)s++;for(;c<J.length&&!J[c].includes("DetermineComponentFrameRoot");)c++;if(s===z.length||c===J.length)for(s=z.length-1,c=J.length-1;1<=s&&0<=c&&z[s]!==J[c];)c--;for(;1<=s&&0<=c;s--,c--)if(z[s]!==J[c]){if(s!==1||c!==1)do if(s--,c--,0>c||z[s]!==J[c]){var de=`
`+z[s].replace(" at new "," at ");return e.displayName&&de.includes("<anonymous>")&&(de=de.replace("<anonymous>",e.displayName)),de}while(1<=s&&0<=c);break}}}finally{_r=!1,Error.prepareStackTrace=n}return(n=e?e.displayName||e.name:"")?B(n):""}function pt(e,r){switch(e.tag){case 26:case 27:case 5:return B(e.type);case 16:return B("Lazy");case 13:return e.child!==r&&r!==null?B("Suspense Fallback"):B("Suspense");case 19:return B("SuspenseList");case 0:case 15:return dt(e.type,!1);case 11:return dt(e.type.render,!1);case 1:return dt(e.type,!0);case 31:return B("Activity");default:return""}}function Ge(e){try{var r="",n=null;do r+=pt(e,n),n=e,e=e.return;while(e);return r}catch(s){return`
Error generating stack: `+s.message+`
`+s.stack}}var Ct=Object.prototype.hasOwnProperty,Ve=o.unstable_scheduleCallback,U=o.unstable_cancelCallback,E=o.unstable_shouldYield,ee=o.unstable_requestPaint,he=o.unstable_now,be=o.unstable_getCurrentPriorityLevel,pe=o.unstable_ImmediatePriority,Be=o.unstable_UserBlockingPriority,Ce=o.unstable_NormalPriority,$e=o.unstable_LowPriority,Ye=o.unstable_IdlePriority,Ee=o.log,Ne=o.unstable_setDisableYieldValue,Xe=null,He=null;function Ue(e){if(typeof Ee=="function"&&Ne(e),He&&typeof He.setStrictMode=="function")try{He.setStrictMode(Xe,e)}catch{}}var Ke=Math.clz32?Math.clz32:j,rt=Math.log,Ut=Math.LN2;function j(e){return e>>>=0,e===0?32:31-(rt(e)/Ut|0)|0}var Ae=256,le=262144,_e=4194304;function Re(e){var r=e&42;if(r!==0)return r;switch(e&-e){case 1:return 1;case 2:return 2;case 4:return 4;case 8:return 8;case 16:return 16;case 32:return 32;case 64:return 64;case 128:return 128;case 256:case 512:case 1024:case 2048:case 4096:case 8192:case 16384:case 32768:case 65536:case 131072:return e&261888;case 262144:case 524288:case 1048576:case 2097152:return e&3932160;case 4194304:case 8388608:case 16777216:case 33554432:return e&62914560;case 67108864:return 67108864;case 134217728:return 134217728;case 268435456:return 268435456;case 536870912:return 536870912;case 1073741824:return 0;default:return e}}function Te(e,r,n){var s=e.pendingLanes;if(s===0)return 0;var c=0,d=e.suspendedLanes,g=e.pingedLanes;e=e.warmLanes;var M=s&134217727;return M!==0?(s=M&~d,s!==0?c=Re(s):(g&=M,g!==0?c=Re(g):n||(n=M&~e,n!==0&&(c=Re(n))))):(M=s&~d,M!==0?c=Re(M):g!==0?c=Re(g):n||(n=s&~e,n!==0&&(c=Re(n)))),c===0?0:r!==0&&r!==c&&(r&d)===0&&(d=c&-c,n=r&-r,d>=n||d===32&&(n&4194048)!==0)?r:c}function st(e,r){return(e.pendingLanes&~(e.suspendedLanes&~e.pingedLanes)&r)===0}function Gt(e,r){switch(e){case 1:case 2:case 4:case 8:case 64:return r+250;case 16:case 32:case 128:case 256:case 512:case 1024:case 2048:case 4096:case 8192:case 16384:case 32768:case 65536:case 131072:case 262144:case 524288:case 1048576:case 2097152:return r+5e3;case 4194304:case 8388608:case 16777216:case 33554432:return-1;case 67108864:case 134217728:case 268435456:case 536870912:case 1073741824:return-1;default:return-1}}function nr(){var e=_e;return _e<<=1,(_e&62914560)===0&&(_e=4194304),e}function bt(e){for(var r=[],n=0;31>n;n++)r.push(e);return r}function ur(e,r){e.pendingLanes|=r,r!==268435456&&(e.suspendedLanes=0,e.pingedLanes=0,e.warmLanes=0)}function oi(e,r,n,s,c,d){var g=e.pendingLanes;e.pendingLanes=n,e.suspendedLanes=0,e.pingedLanes=0,e.warmLanes=0,e.expiredLanes&=n,e.entangledLanes&=n,e.errorRecoveryDisabledLanes&=n,e.shellSuspendCounter=0;var M=e.entanglements,z=e.expirationTimes,J=e.hiddenUpdates;for(n=g&~n;0<n;){var de=31-Ke(n),me=1<<de;M[de]=0,z[de]=-1;var re=J[de];if(re!==null)for(J[de]=null,de=0;de<re.length;de++){var oe=re[de];oe!==null&&(oe.lane&=-536870913)}n&=~me}s!==0&&ws(e,s,0),d!==0&&c===0&&e.tag!==0&&(e.suspendedLanes|=d&~(g&~r))}function ws(e,r,n){e.pendingLanes|=r,e.suspendedLanes&=~r;var s=31-Ke(r);e.entangledLanes|=r,e.entanglements[s]=e.entanglements[s]|1073741824|n&261930}function Ts(e,r){var n=e.entangledLanes|=r;for(e=e.entanglements;n;){var s=31-Ke(n),c=1<<s;c&r|e[s]&r&&(e[s]|=r),n&=~c}}function bi(e,r){var n=r&-r;return n=(n&42)!==0?1:Gn(n),(n&(e.suspendedLanes|r))!==0?0:n}function Gn(e){switch(e){case 2:e=1;break;case 8:e=4;break;case 32:e=16;break;case 256:case 512:case 1024:case 2048:case 4096:case 8192:case 16384:case 32768:case 65536:case 131072:case 262144:case 524288:case 1048576:case 2097152:case 4194304:case 8388608:case 16777216:case 33554432:e=128;break;case 268435456:e=134217728;break;default:e=0}return e}function ba(e){return e&=-e,2<e?8<e?(e&134217727)!==0?32:268435456:8:2}function Rs(){var e=K.p;return e!==0?e:(e=window.event,e===void 0?32:$g(e.type))}function Wn(e,r){var n=K.p;try{return K.p=e,r()}finally{K.p=n}}var li=Math.random().toString(36).slice(2),qt="__reactFiber$"+li,dr="__reactProps$"+li,Di="__reactContainer$"+li,Cs="__reactEvents$"+li,Ac="__reactListeners$"+li,Pc="__reactHandles$"+li,ko="__reactResources$"+li,jn="__reactMarker$"+li;function As(e){delete e[qt],delete e[dr],delete e[Cs],delete e[Ac],delete e[Pc]}function T(e){var r=e[qt];if(r)return r;for(var n=e.parentNode;n;){if(r=n[Di]||n[qt]){if(n=r.alternate,r.child!==null||n!==null&&n.child!==null)for(e=Ig(e);e!==null;){if(n=e[qt])return n;e=Ig(e)}return r}e=n,n=e.parentNode}return null}function X(e){if(e=e[qt]||e[Di]){var r=e.tag;if(r===5||r===6||r===13||r===31||r===26||r===27||r===3)return e}return null}function ne(e){var r=e.tag;if(r===5||r===26||r===27||r===6)return e.stateNode;throw Error(a(33))}function ae(e){var r=e[ko];return r||(r=e[ko]={hoistableStyles:new Map,hoistableScripts:new Map}),r}function W(e){e[jn]=!0}var Se=new Set,De={};function Pe(e,r){Ie(e,r),Ie(e+"Capture",r)}function Ie(e,r){for(De[e]=r,e=0;e<r.length;e++)Se.add(r[e])}var Je=RegExp("^[:A-Z_a-z\\u00C0-\\u00D6\\u00D8-\\u00F6\\u00F8-\\u02FF\\u0370-\\u037D\\u037F-\\u1FFF\\u200C-\\u200D\\u2070-\\u218F\\u2C00-\\u2FEF\\u3001-\\uD7FF\\uF900-\\uFDCF\\uFDF0-\\uFFFD][:A-Z_a-z\\u00C0-\\u00D6\\u00D8-\\u00F6\\u00F8-\\u02FF\\u0370-\\u037D\\u037F-\\u1FFF\\u200C-\\u200D\\u2070-\\u218F\\u2C00-\\u2FEF\\u3001-\\uD7FF\\uF900-\\uFDCF\\uFDF0-\\uFFFD\\-.0-9\\u00B7\\u0300-\\u036F\\u203F-\\u2040]*$"),qe={},Ze={};function yt(e){return Ct.call(Ze,e)?!0:Ct.call(qe,e)?!1:Je.test(e)?Ze[e]=!0:(qe[e]=!0,!1)}function Mt(e,r,n){if(yt(r))if(n===null)e.removeAttribute(r);else{switch(typeof n){case"undefined":case"function":case"symbol":e.removeAttribute(r);return;case"boolean":var s=r.toLowerCase().slice(0,5);if(s!=="data-"&&s!=="aria-"){e.removeAttribute(r);return}}e.setAttribute(r,""+n)}}function Wt(e,r,n){if(n===null)e.removeAttribute(r);else{switch(typeof n){case"undefined":case"function":case"symbol":case"boolean":e.removeAttribute(r);return}e.setAttribute(r,""+n)}}function ct(e,r,n,s){if(s===null)e.removeAttribute(n);else{switch(typeof s){case"undefined":case"function":case"symbol":case"boolean":e.removeAttribute(n);return}e.setAttributeNS(r,n,""+s)}}function lt(e){switch(typeof e){case"bigint":case"boolean":case"number":case"string":case"undefined":return e;case"object":return e;default:return""}}function je(e){var r=e.type;return(e=e.nodeName)&&e.toLowerCase()==="input"&&(r==="checkbox"||r==="radio")}function hr(e,r,n){var s=Object.getOwnPropertyDescriptor(e.constructor.prototype,r);if(!e.hasOwnProperty(r)&&typeof s<"u"&&typeof s.get=="function"&&typeof s.set=="function"){var c=s.get,d=s.set;return Object.defineProperty(e,r,{configurable:!0,get:function(){return c.call(this)},set:function(g){n=""+g,d.call(this,g)}}),Object.defineProperty(e,r,{enumerable:s.enumerable}),{getValue:function(){return n},setValue:function(g){n=""+g},stopTracking:function(){e._valueTracker=null,delete e[r]}}}}function ci(e){if(!e._valueTracker){var r=je(e)?"checked":"value";e._valueTracker=hr(e,r,""+e[r])}}function Ar(e){if(!e)return!1;var r=e._valueTracker;if(!r)return!0;var n=r.getValue(),s="";return e&&(s=je(e)?e.checked?"true":"false":e.value),e=s,e!==n?(r.setValue(e),!0):!1}function ui(e){if(e=e||(typeof document<"u"?document:void 0),typeof e>"u")return null;try{return e.activeElement||e.body}catch{return e.body}}var wr=/[\n"\\]/g;function fr(e){return e.replace(wr,function(r){return"\\"+r.charCodeAt(0).toString(16)+" "})}function Dt(e,r,n,s,c,d,g,M){e.name="",g!=null&&typeof g!="function"&&typeof g!="symbol"&&typeof g!="boolean"?e.type=g:e.removeAttribute("type"),r!=null?g==="number"?(r===0&&e.value===""||e.value!=r)&&(e.value=""+lt(r)):e.value!==""+lt(r)&&(e.value=""+lt(r)):g!=="submit"&&g!=="reset"||e.removeAttribute("value"),r!=null?yr(e,g,lt(r)):n!=null?yr(e,g,lt(n)):s!=null&&e.removeAttribute("value"),c==null&&d!=null&&(e.defaultChecked=!!d),c!=null&&(e.checked=c&&typeof c!="function"&&typeof c!="symbol"),M!=null&&typeof M!="function"&&typeof M!="symbol"&&typeof M!="boolean"?e.name=""+lt(M):e.removeAttribute("name")}function Tr(e,r,n,s,c,d,g,M){if(d!=null&&typeof d!="function"&&typeof d!="symbol"&&typeof d!="boolean"&&(e.type=d),r!=null||n!=null){if(!(d!=="submit"&&d!=="reset"||r!=null)){ci(e);return}n=n!=null?""+lt(n):"",r=r!=null?""+lt(r):n,M||r===e.value||(e.value=r),e.defaultValue=r}s=s??c,s=typeof s!="function"&&typeof s!="symbol"&&!!s,e.checked=M?e.checked:!!s,e.defaultChecked=!!s,g!=null&&typeof g!="function"&&typeof g!="symbol"&&typeof g!="boolean"&&(e.name=g),ci(e)}function yr(e,r,n){r==="number"&&ui(e.ownerDocument)===e||e.defaultValue===""+n||(e.defaultValue=""+n)}function jt(e,r,n,s){if(e=e.options,r){r={};for(var c=0;c<n.length;c++)r["$"+n[c]]=!0;for(n=0;n<e.length;n++)c=r.hasOwnProperty("$"+e[n].value),e[n].selected!==c&&(e[n].selected=c),c&&s&&(e[n].defaultSelected=!0)}else{for(n=""+lt(n),r=null,c=0;c<e.length;c++){if(e[c].value===n){e[c].selected=!0,s&&(e[c].defaultSelected=!0);return}r!==null||e[c].disabled||(r=e[c])}r!==null&&(r.selected=!0)}}function Pr(e,r,n){if(r!=null&&(r=""+lt(r),r!==e.value&&(e.value=r),n==null)){e.defaultValue!==r&&(e.defaultValue=r);return}e.defaultValue=n!=null?""+lt(n):""}function Ma(e,r,n,s){if(r==null){if(s!=null){if(n!=null)throw Error(a(92));if(ve(s)){if(1<s.length)throw Error(a(93));s=s[0]}n=s}n==null&&(n=""),r=n}n=lt(r),e.defaultValue=n,s=e.textContent,s===n&&s!==""&&s!==null&&(e.value=s),ci(e)}function Lr(e,r){if(r){var n=e.firstChild;if(n&&n===e.lastChild&&n.nodeType===3){n.nodeValue=r;return}}e.textContent=r}var Z_=new Set("animationIterationCount aspectRatio borderImageOutset borderImageSlice borderImageWidth boxFlex boxFlexGroup boxOrdinalGroup columnCount columns flex flexGrow flexPositive flexShrink flexNegative flexOrder gridArea gridRow gridRowEnd gridRowSpan gridRowStart gridColumn gridColumnEnd gridColumnSpan gridColumnStart fontWeight lineClamp lineHeight opacity order orphans scale tabSize widows zIndex zoom fillOpacity floodOpacity stopOpacity strokeDasharray strokeDashoffset strokeMiterlimit strokeOpacity strokeWidth MozAnimationIterationCount MozBoxFlex MozBoxFlexGroup MozLineClamp msAnimationIterationCount msFlex msZoom msFlexGrow msFlexNegative msFlexOrder msFlexPositive msFlexShrink msGridColumn msGridColumnSpan msGridRow msGridRowSpan WebkitAnimationIterationCount WebkitBoxFlex WebKitBoxFlexGroup WebkitBoxOrdinalGroup WebkitColumnCount WebkitColumns WebkitFlex WebkitFlexGrow WebkitFlexPositive WebkitFlexShrink WebkitLineClamp".split(" "));function Mf(e,r,n){var s=r.indexOf("--")===0;n==null||typeof n=="boolean"||n===""?s?e.setProperty(r,""):r==="float"?e.cssFloat="":e[r]="":s?e.setProperty(r,n):typeof n!="number"||n===0||Z_.has(r)?r==="float"?e.cssFloat=n:e[r]=(""+n).trim():e[r]=n+"px"}function Ef(e,r,n){if(r!=null&&typeof r!="object")throw Error(a(62));if(e=e.style,n!=null){for(var s in n)!n.hasOwnProperty(s)||r!=null&&r.hasOwnProperty(s)||(s.indexOf("--")===0?e.setProperty(s,""):s==="float"?e.cssFloat="":e[s]="");for(var c in r)s=r[c],r.hasOwnProperty(c)&&n[c]!==s&&Mf(e,c,s)}else for(var d in r)r.hasOwnProperty(d)&&Mf(e,d,r[d])}function Lc(e){if(e.indexOf("-")===-1)return!1;switch(e){case"annotation-xml":case"color-profile":case"font-face":case"font-face-src":case"font-face-uri":case"font-face-format":case"font-face-name":case"missing-glyph":return!1;default:return!0}}var J_=new Map([["acceptCharset","accept-charset"],["htmlFor","for"],["httpEquiv","http-equiv"],["crossOrigin","crossorigin"],["accentHeight","accent-height"],["alignmentBaseline","alignment-baseline"],["arabicForm","arabic-form"],["baselineShift","baseline-shift"],["capHeight","cap-height"],["clipPath","clip-path"],["clipRule","clip-rule"],["colorInterpolation","color-interpolation"],["colorInterpolationFilters","color-interpolation-filters"],["colorProfile","color-profile"],["colorRendering","color-rendering"],["dominantBaseline","dominant-baseline"],["enableBackground","enable-background"],["fillOpacity","fill-opacity"],["fillRule","fill-rule"],["floodColor","flood-color"],["floodOpacity","flood-opacity"],["fontFamily","font-family"],["fontSize","font-size"],["fontSizeAdjust","font-size-adjust"],["fontStretch","font-stretch"],["fontStyle","font-style"],["fontVariant","font-variant"],["fontWeight","font-weight"],["glyphName","glyph-name"],["glyphOrientationHorizontal","glyph-orientation-horizontal"],["glyphOrientationVertical","glyph-orientation-vertical"],["horizAdvX","horiz-adv-x"],["horizOriginX","horiz-origin-x"],["imageRendering","image-rendering"],["letterSpacing","letter-spacing"],["lightingColor","lighting-color"],["markerEnd","marker-end"],["markerMid","marker-mid"],["markerStart","marker-start"],["overlinePosition","overline-position"],["overlineThickness","overline-thickness"],["paintOrder","paint-order"],["panose-1","panose-1"],["pointerEvents","pointer-events"],["renderingIntent","rendering-intent"],["shapeRendering","shape-rendering"],["stopColor","stop-color"],["stopOpacity","stop-opacity"],["strikethroughPosition","strikethrough-position"],["strikethroughThickness","strikethrough-thickness"],["strokeDasharray","stroke-dasharray"],["strokeDashoffset","stroke-dashoffset"],["strokeLinecap","stroke-linecap"],["strokeLinejoin","stroke-linejoin"],["strokeMiterlimit","stroke-miterlimit"],["strokeOpacity","stroke-opacity"],["strokeWidth","stroke-width"],["textAnchor","text-anchor"],["textDecoration","text-decoration"],["textRendering","text-rendering"],["transformOrigin","transform-origin"],["underlinePosition","underline-position"],["underlineThickness","underline-thickness"],["unicodeBidi","unicode-bidi"],["unicodeRange","unicode-range"],["unitsPerEm","units-per-em"],["vAlphabetic","v-alphabetic"],["vHanging","v-hanging"],["vIdeographic","v-ideographic"],["vMathematical","v-mathematical"],["vectorEffect","vector-effect"],["vertAdvY","vert-adv-y"],["vertOriginX","vert-origin-x"],["vertOriginY","vert-origin-y"],["wordSpacing","word-spacing"],["writingMode","writing-mode"],["xmlnsXlink","xmlns:xlink"],["xHeight","x-height"]]),e0=/^[\u0000-\u001F ]*j[\r\n\t]*a[\r\n\t]*v[\r\n\t]*a[\r\n\t]*s[\r\n\t]*c[\r\n\t]*r[\r\n\t]*i[\r\n\t]*p[\r\n\t]*t[\r\n\t]*:/i;function Fo(e){return e0.test(""+e)?"javascript:throw new Error('React has blocked a javascript: URL as a security precaution.')":e}function Ii(){}var Uc=null;function Dc(e){return e=e.target||e.srcElement||window,e.correspondingUseElement&&(e=e.correspondingUseElement),e.nodeType===3?e.parentNode:e}var Ea=null,wa=null;function wf(e){var r=X(e);if(r&&(e=r.stateNode)){var n=e[dr]||null;e:switch(e=r.stateNode,r.type){case"input":if(Dt(e,n.value,n.defaultValue,n.defaultValue,n.checked,n.defaultChecked,n.type,n.name),r=n.name,n.type==="radio"&&r!=null){for(n=e;n.parentNode;)n=n.parentNode;for(n=n.querySelectorAll('input[name="'+fr(""+r)+'"][type="radio"]'),r=0;r<n.length;r++){var s=n[r];if(s!==e&&s.form===e.form){var c=s[dr]||null;if(!c)throw Error(a(90));Dt(s,c.value,c.defaultValue,c.defaultValue,c.checked,c.defaultChecked,c.type,c.name)}}for(r=0;r<n.length;r++)s=n[r],s.form===e.form&&Ar(s)}break e;case"textarea":Pr(e,n.value,n.defaultValue);break e;case"select":r=n.value,r!=null&&jt(e,!!n.multiple,r,!1)}}}var Ic=!1;function Tf(e,r,n){if(Ic)return e(r,n);Ic=!0;try{var s=e(r);return s}finally{if(Ic=!1,(Ea!==null||wa!==null)&&(wl(),Ea&&(r=Ea,e=wa,wa=Ea=null,wf(r),e)))for(r=0;r<e.length;r++)wf(e[r])}}function Ps(e,r){var n=e.stateNode;if(n===null)return null;var s=n[dr]||null;if(s===null)return null;n=s[r];e:switch(r){case"onClick":case"onClickCapture":case"onDoubleClick":case"onDoubleClickCapture":case"onMouseDown":case"onMouseDownCapture":case"onMouseMove":case"onMouseMoveCapture":case"onMouseUp":case"onMouseUpCapture":case"onMouseEnter":(s=!s.disabled)||(e=e.type,s=!(e==="button"||e==="input"||e==="select"||e==="textarea")),e=!s;break e;default:e=!1}if(e)return null;if(n&&typeof n!="function")throw Error(a(231,r,typeof n));return n}var Ni=!(typeof window>"u"||typeof window.document>"u"||typeof window.document.createElement>"u"),Nc=!1;if(Ni)try{var Ls={};Object.defineProperty(Ls,"passive",{get:function(){Nc=!0}}),window.addEventListener("test",Ls,Ls),window.removeEventListener("test",Ls,Ls)}catch{Nc=!1}var cn=null,Oc=null,zo=null;function Rf(){if(zo)return zo;var e,r=Oc,n=r.length,s,c="value"in cn?cn.value:cn.textContent,d=c.length;for(e=0;e<n&&r[e]===c[e];e++);var g=n-e;for(s=1;s<=g&&r[n-s]===c[d-s];s++);return zo=c.slice(e,1<s?1-s:void 0)}function Bo(e){var r=e.keyCode;return"charCode"in e?(e=e.charCode,e===0&&r===13&&(e=13)):e=r,e===10&&(e=13),32<=e||e===13?e:0}function Ho(){return!0}function Cf(){return!1}function Ur(e){function r(n,s,c,d,g){this._reactName=n,this._targetInst=c,this.type=s,this.nativeEvent=d,this.target=g,this.currentTarget=null;for(var M in e)e.hasOwnProperty(M)&&(n=e[M],this[M]=n?n(d):d[M]);return this.isDefaultPrevented=(d.defaultPrevented!=null?d.defaultPrevented:d.returnValue===!1)?Ho:Cf,this.isPropagationStopped=Cf,this}return y(r.prototype,{preventDefault:function(){this.defaultPrevented=!0;var n=this.nativeEvent;n&&(n.preventDefault?n.preventDefault():typeof n.returnValue!="unknown"&&(n.returnValue=!1),this.isDefaultPrevented=Ho)},stopPropagation:function(){var n=this.nativeEvent;n&&(n.stopPropagation?n.stopPropagation():typeof n.cancelBubble!="unknown"&&(n.cancelBubble=!0),this.isPropagationStopped=Ho)},persist:function(){},isPersistent:Ho}),r}var Xn={eventPhase:0,bubbles:0,cancelable:0,timeStamp:function(e){return e.timeStamp||Date.now()},defaultPrevented:0,isTrusted:0},Vo=Ur(Xn),Us=y({},Xn,{view:0,detail:0}),t0=Ur(Us),kc,Fc,Ds,Go=y({},Us,{screenX:0,screenY:0,clientX:0,clientY:0,pageX:0,pageY:0,ctrlKey:0,shiftKey:0,altKey:0,metaKey:0,getModifierState:Bc,button:0,buttons:0,relatedTarget:function(e){return e.relatedTarget===void 0?e.fromElement===e.srcElement?e.toElement:e.fromElement:e.relatedTarget},movementX:function(e){return"movementX"in e?e.movementX:(e!==Ds&&(Ds&&e.type==="mousemove"?(kc=e.screenX-Ds.screenX,Fc=e.screenY-Ds.screenY):Fc=kc=0,Ds=e),kc)},movementY:function(e){return"movementY"in e?e.movementY:Fc}}),Af=Ur(Go),r0=y({},Go,{dataTransfer:0}),i0=Ur(r0),n0=y({},Us,{relatedTarget:0}),zc=Ur(n0),a0=y({},Xn,{animationName:0,elapsedTime:0,pseudoElement:0}),s0=Ur(a0),o0=y({},Xn,{clipboardData:function(e){return"clipboardData"in e?e.clipboardData:window.clipboardData}}),l0=Ur(o0),c0=y({},Xn,{data:0}),Pf=Ur(c0),u0={Esc:"Escape",Spacebar:" ",Left:"ArrowLeft",Up:"ArrowUp",Right:"ArrowRight",Down:"ArrowDown",Del:"Delete",Win:"OS",Menu:"ContextMenu",Apps:"ContextMenu",Scroll:"ScrollLock",MozPrintableKey:"Unidentified"},d0={8:"Backspace",9:"Tab",12:"Clear",13:"Enter",16:"Shift",17:"Control",18:"Alt",19:"Pause",20:"CapsLock",27:"Escape",32:" ",33:"PageUp",34:"PageDown",35:"End",36:"Home",37:"ArrowLeft",38:"ArrowUp",39:"ArrowRight",40:"ArrowDown",45:"Insert",46:"Delete",112:"F1",113:"F2",114:"F3",115:"F4",116:"F5",117:"F6",118:"F7",119:"F8",120:"F9",121:"F10",122:"F11",123:"F12",144:"NumLock",145:"ScrollLock",224:"Meta"},h0={Alt:"altKey",Control:"ctrlKey",Meta:"metaKey",Shift:"shiftKey"};function f0(e){var r=this.nativeEvent;return r.getModifierState?r.getModifierState(e):(e=h0[e])?!!r[e]:!1}function Bc(){return f0}var p0=y({},Us,{key:function(e){if(e.key){var r=u0[e.key]||e.key;if(r!=="Unidentified")return r}return e.type==="keypress"?(e=Bo(e),e===13?"Enter":String.fromCharCode(e)):e.type==="keydown"||e.type==="keyup"?d0[e.keyCode]||"Unidentified":""},code:0,location:0,ctrlKey:0,shiftKey:0,altKey:0,metaKey:0,repeat:0,locale:0,getModifierState:Bc,charCode:function(e){return e.type==="keypress"?Bo(e):0},keyCode:function(e){return e.type==="keydown"||e.type==="keyup"?e.keyCode:0},which:function(e){return e.type==="keypress"?Bo(e):e.type==="keydown"||e.type==="keyup"?e.keyCode:0}}),m0=Ur(p0),g0=y({},Go,{pointerId:0,width:0,height:0,pressure:0,tangentialPressure:0,tiltX:0,tiltY:0,twist:0,pointerType:0,isPrimary:0}),Lf=Ur(g0),v0=y({},Us,{touches:0,targetTouches:0,changedTouches:0,altKey:0,metaKey:0,ctrlKey:0,shiftKey:0,getModifierState:Bc}),_0=Ur(v0),y0=y({},Xn,{propertyName:0,elapsedTime:0,pseudoElement:0}),x0=Ur(y0),S0=y({},Go,{deltaX:function(e){return"deltaX"in e?e.deltaX:"wheelDeltaX"in e?-e.wheelDeltaX:0},deltaY:function(e){return"deltaY"in e?e.deltaY:"wheelDeltaY"in e?-e.wheelDeltaY:"wheelDelta"in e?-e.wheelDelta:0},deltaZ:0,deltaMode:0}),b0=Ur(S0),M0=y({},Xn,{newState:0,oldState:0}),E0=Ur(M0),w0=[9,13,27,32],Hc=Ni&&"CompositionEvent"in window,Is=null;Ni&&"documentMode"in document&&(Is=document.documentMode);var T0=Ni&&"TextEvent"in window&&!Is,Uf=Ni&&(!Hc||Is&&8<Is&&11>=Is),Df=" ",If=!1;function Nf(e,r){switch(e){case"keyup":return w0.indexOf(r.keyCode)!==-1;case"keydown":return r.keyCode!==229;case"keypress":case"mousedown":case"focusout":return!0;default:return!1}}function Of(e){return e=e.detail,typeof e=="object"&&"data"in e?e.data:null}var Ta=!1;function R0(e,r){switch(e){case"compositionend":return Of(r);case"keypress":return r.which!==32?null:(If=!0,Df);case"textInput":return e=r.data,e===Df&&If?null:e;default:return null}}function C0(e,r){if(Ta)return e==="compositionend"||!Hc&&Nf(e,r)?(e=Rf(),zo=Oc=cn=null,Ta=!1,e):null;switch(e){case"paste":return null;case"keypress":if(!(r.ctrlKey||r.altKey||r.metaKey)||r.ctrlKey&&r.altKey){if(r.char&&1<r.char.length)return r.char;if(r.which)return String.fromCharCode(r.which)}return null;case"compositionend":return Uf&&r.locale!=="ko"?null:r.data;default:return null}}var A0={color:!0,date:!0,datetime:!0,"datetime-local":!0,email:!0,month:!0,number:!0,password:!0,range:!0,search:!0,tel:!0,text:!0,time:!0,url:!0,week:!0};function kf(e){var r=e&&e.nodeName&&e.nodeName.toLowerCase();return r==="input"?!!A0[e.type]:r==="textarea"}function Ff(e,r,n,s){Ea?wa?wa.push(s):wa=[s]:Ea=s,r=Ul(r,"onChange"),0<r.length&&(n=new Vo("onChange","change",null,n,s),e.push({event:n,listeners:r}))}var Ns=null,Os=null;function P0(e){xg(e,0)}function Wo(e){var r=ne(e);if(Ar(r))return e}function zf(e,r){if(e==="change")return r}var Bf=!1;if(Ni){var Vc;if(Ni){var Gc="oninput"in document;if(!Gc){var Hf=document.createElement("div");Hf.setAttribute("oninput","return;"),Gc=typeof Hf.oninput=="function"}Vc=Gc}else Vc=!1;Bf=Vc&&(!document.documentMode||9<document.documentMode)}function Vf(){Ns&&(Ns.detachEvent("onpropertychange",Gf),Os=Ns=null)}function Gf(e){if(e.propertyName==="value"&&Wo(Os)){var r=[];Ff(r,Os,e,Dc(e)),Tf(P0,r)}}function L0(e,r,n){e==="focusin"?(Vf(),Ns=r,Os=n,Ns.attachEvent("onpropertychange",Gf)):e==="focusout"&&Vf()}function U0(e){if(e==="selectionchange"||e==="keyup"||e==="keydown")return Wo(Os)}function D0(e,r){if(e==="click")return Wo(r)}function I0(e,r){if(e==="input"||e==="change")return Wo(r)}function N0(e,r){return e===r&&(e!==0||1/e===1/r)||e!==e&&r!==r}var Hr=typeof Object.is=="function"?Object.is:N0;function ks(e,r){if(Hr(e,r))return!0;if(typeof e!="object"||e===null||typeof r!="object"||r===null)return!1;var n=Object.keys(e),s=Object.keys(r);if(n.length!==s.length)return!1;for(s=0;s<n.length;s++){var c=n[s];if(!Ct.call(r,c)||!Hr(e[c],r[c]))return!1}return!0}function Wf(e){for(;e&&e.firstChild;)e=e.firstChild;return e}function jf(e,r){var n=Wf(e);e=0;for(var s;n;){if(n.nodeType===3){if(s=e+n.textContent.length,e<=r&&s>=r)return{node:n,offset:r-e};e=s}e:{for(;n;){if(n.nextSibling){n=n.nextSibling;break e}n=n.parentNode}n=void 0}n=Wf(n)}}function Xf(e,r){return e&&r?e===r?!0:e&&e.nodeType===3?!1:r&&r.nodeType===3?Xf(e,r.parentNode):"contains"in e?e.contains(r):e.compareDocumentPosition?!!(e.compareDocumentPosition(r)&16):!1:!1}function Yf(e){e=e!=null&&e.ownerDocument!=null&&e.ownerDocument.defaultView!=null?e.ownerDocument.defaultView:window;for(var r=ui(e.document);r instanceof e.HTMLIFrameElement;){try{var n=typeof r.contentWindow.location.href=="string"}catch{n=!1}if(n)e=r.contentWindow;else break;r=ui(e.document)}return r}function Wc(e){var r=e&&e.nodeName&&e.nodeName.toLowerCase();return r&&(r==="input"&&(e.type==="text"||e.type==="search"||e.type==="tel"||e.type==="url"||e.type==="password")||r==="textarea"||e.contentEditable==="true")}var O0=Ni&&"documentMode"in document&&11>=document.documentMode,Ra=null,jc=null,Fs=null,Xc=!1;function qf(e,r,n){var s=n.window===n?n.document:n.nodeType===9?n:n.ownerDocument;Xc||Ra==null||Ra!==ui(s)||(s=Ra,"selectionStart"in s&&Wc(s)?s={start:s.selectionStart,end:s.selectionEnd}:(s=(s.ownerDocument&&s.ownerDocument.defaultView||window).getSelection(),s={anchorNode:s.anchorNode,anchorOffset:s.anchorOffset,focusNode:s.focusNode,focusOffset:s.focusOffset}),Fs&&ks(Fs,s)||(Fs=s,s=Ul(jc,"onSelect"),0<s.length&&(r=new Vo("onSelect","select",null,r,n),e.push({event:r,listeners:s}),r.target=Ra)))}function Yn(e,r){var n={};return n[e.toLowerCase()]=r.toLowerCase(),n["Webkit"+e]="webkit"+r,n["Moz"+e]="moz"+r,n}var Ca={animationend:Yn("Animation","AnimationEnd"),animationiteration:Yn("Animation","AnimationIteration"),animationstart:Yn("Animation","AnimationStart"),transitionrun:Yn("Transition","TransitionRun"),transitionstart:Yn("Transition","TransitionStart"),transitioncancel:Yn("Transition","TransitionCancel"),transitionend:Yn("Transition","TransitionEnd")},Yc={},Qf={};Ni&&(Qf=document.createElement("div").style,"AnimationEvent"in window||(delete Ca.animationend.animation,delete Ca.animationiteration.animation,delete Ca.animationstart.animation),"TransitionEvent"in window||delete Ca.transitionend.transition);function qn(e){if(Yc[e])return Yc[e];if(!Ca[e])return e;var r=Ca[e],n;for(n in r)if(r.hasOwnProperty(n)&&n in Qf)return Yc[e]=r[n];return e}var $f=qn("animationend"),Kf=qn("animationiteration"),Zf=qn("animationstart"),k0=qn("transitionrun"),F0=qn("transitionstart"),z0=qn("transitioncancel"),Jf=qn("transitionend"),ep=new Map,qc="abort auxClick beforeToggle cancel canPlay canPlayThrough click close contextMenu copy cut drag dragEnd dragEnter dragExit dragLeave dragOver dragStart drop durationChange emptied encrypted ended error gotPointerCapture input invalid keyDown keyPress keyUp load loadedData loadedMetadata loadStart lostPointerCapture mouseDown mouseMove mouseOut mouseOver mouseUp paste pause play playing pointerCancel pointerDown pointerMove pointerOut pointerOver pointerUp progress rateChange reset resize seeked seeking stalled submit suspend timeUpdate touchCancel touchEnd touchStart volumeChange scroll toggle touchMove waiting wheel".split(" ");qc.push("scrollEnd");function di(e,r){ep.set(e,r),Pe(r,[e])}var jo=typeof reportError=="function"?reportError:function(e){if(typeof window=="object"&&typeof window.ErrorEvent=="function"){var r=new window.ErrorEvent("error",{bubbles:!0,cancelable:!0,message:typeof e=="object"&&e!==null&&typeof e.message=="string"?String(e.message):String(e),error:e});if(!window.dispatchEvent(r))return}else if(typeof process=="object"&&typeof process.emit=="function"){process.emit("uncaughtException",e);return}console.error(e)},Kr=[],Aa=0,Qc=0;function Xo(){for(var e=Aa,r=Qc=Aa=0;r<e;){var n=Kr[r];Kr[r++]=null;var s=Kr[r];Kr[r++]=null;var c=Kr[r];Kr[r++]=null;var d=Kr[r];if(Kr[r++]=null,s!==null&&c!==null){var g=s.pending;g===null?c.next=c:(c.next=g.next,g.next=c),s.pending=c}d!==0&&tp(n,c,d)}}function Yo(e,r,n,s){Kr[Aa++]=e,Kr[Aa++]=r,Kr[Aa++]=n,Kr[Aa++]=s,Qc|=s,e.lanes|=s,e=e.alternate,e!==null&&(e.lanes|=s)}function $c(e,r,n,s){return Yo(e,r,n,s),qo(e)}function Qn(e,r){return Yo(e,null,null,r),qo(e)}function tp(e,r,n){e.lanes|=n;var s=e.alternate;s!==null&&(s.lanes|=n);for(var c=!1,d=e.return;d!==null;)d.childLanes|=n,s=d.alternate,s!==null&&(s.childLanes|=n),d.tag===22&&(e=d.stateNode,e===null||e._visibility&1||(c=!0)),e=d,d=d.return;return e.tag===3?(d=e.stateNode,c&&r!==null&&(c=31-Ke(n),e=d.hiddenUpdates,s=e[c],s===null?e[c]=[r]:s.push(r),r.lane=n|536870912),d):null}function qo(e){if(50<so)throw so=0,ad=null,Error(a(185));for(var r=e.return;r!==null;)e=r,r=e.return;return e.tag===3?e.stateNode:null}var Pa={};function B0(e,r,n,s){this.tag=e,this.key=n,this.sibling=this.child=this.return=this.stateNode=this.type=this.elementType=null,this.index=0,this.refCleanup=this.ref=null,this.pendingProps=r,this.dependencies=this.memoizedState=this.updateQueue=this.memoizedProps=null,this.mode=s,this.subtreeFlags=this.flags=0,this.deletions=null,this.childLanes=this.lanes=0,this.alternate=null}function Vr(e,r,n,s){return new B0(e,r,n,s)}function Kc(e){return e=e.prototype,!(!e||!e.isReactComponent)}function Oi(e,r){var n=e.alternate;return n===null?(n=Vr(e.tag,r,e.key,e.mode),n.elementType=e.elementType,n.type=e.type,n.stateNode=e.stateNode,n.alternate=e,e.alternate=n):(n.pendingProps=r,n.type=e.type,n.flags=0,n.subtreeFlags=0,n.deletions=null),n.flags=e.flags&65011712,n.childLanes=e.childLanes,n.lanes=e.lanes,n.child=e.child,n.memoizedProps=e.memoizedProps,n.memoizedState=e.memoizedState,n.updateQueue=e.updateQueue,r=e.dependencies,n.dependencies=r===null?null:{lanes:r.lanes,firstContext:r.firstContext},n.sibling=e.sibling,n.index=e.index,n.ref=e.ref,n.refCleanup=e.refCleanup,n}function rp(e,r){e.flags&=65011714;var n=e.alternate;return n===null?(e.childLanes=0,e.lanes=r,e.child=null,e.subtreeFlags=0,e.memoizedProps=null,e.memoizedState=null,e.updateQueue=null,e.dependencies=null,e.stateNode=null):(e.childLanes=n.childLanes,e.lanes=n.lanes,e.child=n.child,e.subtreeFlags=0,e.deletions=null,e.memoizedProps=n.memoizedProps,e.memoizedState=n.memoizedState,e.updateQueue=n.updateQueue,e.type=n.type,r=n.dependencies,e.dependencies=r===null?null:{lanes:r.lanes,firstContext:r.firstContext}),e}function Qo(e,r,n,s,c,d){var g=0;if(s=e,typeof e=="function")Kc(e)&&(g=1);else if(typeof e=="string")g=jy(e,n,Q.current)?26:e==="html"||e==="head"||e==="body"?27:5;else e:switch(e){case P:return e=Vr(31,n,r,c),e.elementType=P,e.lanes=d,e;case A:return $n(n.children,c,d,r);case S:g=8,c|=24;break;case v:return e=Vr(12,n,r,c|2),e.elementType=v,e.lanes=d,e;case G:return e=Vr(13,n,r,c),e.elementType=G,e.lanes=d,e;case k:return e=Vr(19,n,r,c),e.elementType=k,e.lanes=d,e;default:if(typeof e=="object"&&e!==null)switch(e.$$typeof){case L:g=10;break e;case D:g=9;break e;case C:g=11;break e;case I:g=14;break e;case H:g=16,s=null;break e}g=29,n=Error(a(130,e===null?"null":typeof e,"")),s=null}return r=Vr(g,n,r,c),r.elementType=e,r.type=s,r.lanes=d,r}function $n(e,r,n,s){return e=Vr(7,e,s,r),e.lanes=n,e}function Zc(e,r,n){return e=Vr(6,e,null,r),e.lanes=n,e}function ip(e){var r=Vr(18,null,null,0);return r.stateNode=e,r}function Jc(e,r,n){return r=Vr(4,e.children!==null?e.children:[],e.key,r),r.lanes=n,r.stateNode={containerInfo:e.containerInfo,pendingChildren:null,implementation:e.implementation},r}var np=new WeakMap;function Zr(e,r){if(typeof e=="object"&&e!==null){var n=np.get(e);return n!==void 0?n:(r={value:e,source:r,stack:Ge(r)},np.set(e,r),r)}return{value:e,source:r,stack:Ge(r)}}var La=[],Ua=0,$o=null,zs=0,Jr=[],ei=0,un=null,Mi=1,Ei="";function ki(e,r){La[Ua++]=zs,La[Ua++]=$o,$o=e,zs=r}function ap(e,r,n){Jr[ei++]=Mi,Jr[ei++]=Ei,Jr[ei++]=un,un=e;var s=Mi;e=Ei;var c=32-Ke(s)-1;s&=~(1<<c),n+=1;var d=32-Ke(r)+c;if(30<d){var g=c-c%5;d=(s&(1<<g)-1).toString(32),s>>=g,c-=g,Mi=1<<32-Ke(r)+c|n<<c|s,Ei=d+e}else Mi=1<<d|n<<c|s,Ei=e}function eu(e){e.return!==null&&(ki(e,1),ap(e,1,0))}function tu(e){for(;e===$o;)$o=La[--Ua],La[Ua]=null,zs=La[--Ua],La[Ua]=null;for(;e===un;)un=Jr[--ei],Jr[ei]=null,Ei=Jr[--ei],Jr[ei]=null,Mi=Jr[--ei],Jr[ei]=null}function sp(e,r){Jr[ei++]=Mi,Jr[ei++]=Ei,Jr[ei++]=un,Mi=r.id,Ei=r.overflow,un=e}var pr=null,Bt=null,vt=!1,dn=null,ti=!1,ru=Error(a(519));function hn(e){var r=Error(a(418,1<arguments.length&&arguments[1]!==void 0&&arguments[1]?"text":"HTML",""));throw Bs(Zr(r,e)),ru}function op(e){var r=e.stateNode,n=e.type,s=e.memoizedProps;switch(r[qt]=e,r[dr]=s,n){case"dialog":ft("cancel",r),ft("close",r);break;case"iframe":case"object":case"embed":ft("load",r);break;case"video":case"audio":for(n=0;n<lo.length;n++)ft(lo[n],r);break;case"source":ft("error",r);break;case"img":case"image":case"link":ft("error",r),ft("load",r);break;case"details":ft("toggle",r);break;case"input":ft("invalid",r),Tr(r,s.value,s.defaultValue,s.checked,s.defaultChecked,s.type,s.name,!0);break;case"select":ft("invalid",r);break;case"textarea":ft("invalid",r),Ma(r,s.value,s.defaultValue,s.children)}n=s.children,typeof n!="string"&&typeof n!="number"&&typeof n!="bigint"||r.textContent===""+n||s.suppressHydrationWarning===!0||Eg(r.textContent,n)?(s.popover!=null&&(ft("beforetoggle",r),ft("toggle",r)),s.onScroll!=null&&ft("scroll",r),s.onScrollEnd!=null&&ft("scrollend",r),s.onClick!=null&&(r.onclick=Ii),r=!0):r=!1,r||hn(e,!0)}function lp(e){for(pr=e.return;pr;)switch(pr.tag){case 5:case 31:case 13:ti=!1;return;case 27:case 3:ti=!0;return;default:pr=pr.return}}function Da(e){if(e!==pr)return!1;if(!vt)return lp(e),vt=!0,!1;var r=e.tag,n;if((n=r!==3&&r!==27)&&((n=r===5)&&(n=e.type,n=!(n!=="form"&&n!=="button")||xd(e.type,e.memoizedProps)),n=!n),n&&Bt&&hn(e),lp(e),r===13){if(e=e.memoizedState,e=e!==null?e.dehydrated:null,!e)throw Error(a(317));Bt=Dg(e)}else if(r===31){if(e=e.memoizedState,e=e!==null?e.dehydrated:null,!e)throw Error(a(317));Bt=Dg(e)}else r===27?(r=Bt,Tn(e.type)?(e=wd,wd=null,Bt=e):Bt=r):Bt=pr?ri(e.stateNode.nextSibling):null;return!0}function Kn(){Bt=pr=null,vt=!1}function iu(){var e=dn;return e!==null&&(Or===null?Or=e:Or.push.apply(Or,e),dn=null),e}function Bs(e){dn===null?dn=[e]:dn.push(e)}var nu=O(null),Zn=null,Fi=null;function fn(e,r,n){xe(nu,r._currentValue),r._currentValue=n}function zi(e){e._currentValue=nu.current,ie(nu)}function au(e,r,n){for(;e!==null;){var s=e.alternate;if((e.childLanes&r)!==r?(e.childLanes|=r,s!==null&&(s.childLanes|=r)):s!==null&&(s.childLanes&r)!==r&&(s.childLanes|=r),e===n)break;e=e.return}}function su(e,r,n,s){var c=e.child;for(c!==null&&(c.return=e);c!==null;){var d=c.dependencies;if(d!==null){var g=c.child;d=d.firstContext;e:for(;d!==null;){var M=d;d=c;for(var z=0;z<r.length;z++)if(M.context===r[z]){d.lanes|=n,M=d.alternate,M!==null&&(M.lanes|=n),au(d.return,n,e),s||(g=null);break e}d=M.next}}else if(c.tag===18){if(g=c.return,g===null)throw Error(a(341));g.lanes|=n,d=g.alternate,d!==null&&(d.lanes|=n),au(g,n,e),g=null}else g=c.child;if(g!==null)g.return=c;else for(g=c;g!==null;){if(g===e){g=null;break}if(c=g.sibling,c!==null){c.return=g.return,g=c;break}g=g.return}c=g}}function Ia(e,r,n,s){e=null;for(var c=r,d=!1;c!==null;){if(!d){if((c.flags&524288)!==0)d=!0;else if((c.flags&262144)!==0)break}if(c.tag===10){var g=c.alternate;if(g===null)throw Error(a(387));if(g=g.memoizedProps,g!==null){var M=c.type;Hr(c.pendingProps.value,g.value)||(e!==null?e.push(M):e=[M])}}else if(c===ye.current){if(g=c.alternate,g===null)throw Error(a(387));g.memoizedState.memoizedState!==c.memoizedState.memoizedState&&(e!==null?e.push(po):e=[po])}c=c.return}e!==null&&su(r,e,n,s),r.flags|=262144}function Ko(e){for(e=e.firstContext;e!==null;){if(!Hr(e.context._currentValue,e.memoizedValue))return!0;e=e.next}return!1}function Jn(e){Zn=e,Fi=null,e=e.dependencies,e!==null&&(e.firstContext=null)}function mr(e){return cp(Zn,e)}function Zo(e,r){return Zn===null&&Jn(e),cp(e,r)}function cp(e,r){var n=r._currentValue;if(r={context:r,memoizedValue:n,next:null},Fi===null){if(e===null)throw Error(a(308));Fi=r,e.dependencies={lanes:0,firstContext:r},e.flags|=524288}else Fi=Fi.next=r;return n}var H0=typeof AbortController<"u"?AbortController:function(){var e=[],r=this.signal={aborted:!1,addEventListener:function(n,s){e.push(s)}};this.abort=function(){r.aborted=!0,e.forEach(function(n){return n()})}},V0=o.unstable_scheduleCallback,G0=o.unstable_NormalPriority,Jt={$$typeof:L,Consumer:null,Provider:null,_currentValue:null,_currentValue2:null,_threadCount:0};function ou(){return{controller:new H0,data:new Map,refCount:0}}function Hs(e){e.refCount--,e.refCount===0&&V0(G0,function(){e.controller.abort()})}var Vs=null,lu=0,Na=0,Oa=null;function W0(e,r){if(Vs===null){var n=Vs=[];lu=0,Na=dd(),Oa={status:"pending",value:void 0,then:function(s){n.push(s)}}}return lu++,r.then(up,up),r}function up(){if(--lu===0&&Vs!==null){Oa!==null&&(Oa.status="fulfilled");var e=Vs;Vs=null,Na=0,Oa=null;for(var r=0;r<e.length;r++)(0,e[r])()}}function j0(e,r){var n=[],s={status:"pending",value:null,reason:null,then:function(c){n.push(c)}};return e.then(function(){s.status="fulfilled",s.value=r;for(var c=0;c<n.length;c++)(0,n[c])(r)},function(c){for(s.status="rejected",s.reason=c,c=0;c<n.length;c++)(0,n[c])(void 0)}),s}var dp=N.S;N.S=function(e,r){qm=he(),typeof r=="object"&&r!==null&&typeof r.then=="function"&&W0(e,r),dp!==null&&dp(e,r)};var ea=O(null);function cu(){var e=ea.current;return e!==null?e:zt.pooledCache}function Jo(e,r){r===null?xe(ea,ea.current):xe(ea,r.pool)}function hp(){var e=cu();return e===null?null:{parent:Jt._currentValue,pool:e}}var ka=Error(a(460)),uu=Error(a(474)),el=Error(a(542)),tl={then:function(){}};function fp(e){return e=e.status,e==="fulfilled"||e==="rejected"}function pp(e,r,n){switch(n=e[n],n===void 0?e.push(r):n!==r&&(r.then(Ii,Ii),r=n),r.status){case"fulfilled":return r.value;case"rejected":throw e=r.reason,gp(e),e;default:if(typeof r.status=="string")r.then(Ii,Ii);else{if(e=zt,e!==null&&100<e.shellSuspendCounter)throw Error(a(482));e=r,e.status="pending",e.then(function(s){if(r.status==="pending"){var c=r;c.status="fulfilled",c.value=s}},function(s){if(r.status==="pending"){var c=r;c.status="rejected",c.reason=s}})}switch(r.status){case"fulfilled":return r.value;case"rejected":throw e=r.reason,gp(e),e}throw ra=r,ka}}function ta(e){try{var r=e._init;return r(e._payload)}catch(n){throw n!==null&&typeof n=="object"&&typeof n.then=="function"?(ra=n,ka):n}}var ra=null;function mp(){if(ra===null)throw Error(a(459));var e=ra;return ra=null,e}function gp(e){if(e===ka||e===el)throw Error(a(483))}var Fa=null,Gs=0;function rl(e){var r=Gs;return Gs+=1,Fa===null&&(Fa=[]),pp(Fa,e,r)}function Ws(e,r){r=r.props.ref,e.ref=r!==void 0?r:null}function il(e,r){throw r.$$typeof===x?Error(a(525)):(e=Object.prototype.toString.call(r),Error(a(31,e==="[object Object]"?"object with keys {"+Object.keys(r).join(", ")+"}":e)))}function vp(e){function r(Y,V){if(e){var Z=Y.deletions;Z===null?(Y.deletions=[V],Y.flags|=16):Z.push(V)}}function n(Y,V){if(!e)return null;for(;V!==null;)r(Y,V),V=V.sibling;return null}function s(Y){for(var V=new Map;Y!==null;)Y.key!==null?V.set(Y.key,Y):V.set(Y.index,Y),Y=Y.sibling;return V}function c(Y,V){return Y=Oi(Y,V),Y.index=0,Y.sibling=null,Y}function d(Y,V,Z){return Y.index=Z,e?(Z=Y.alternate,Z!==null?(Z=Z.index,Z<V?(Y.flags|=67108866,V):Z):(Y.flags|=67108866,V)):(Y.flags|=1048576,V)}function g(Y){return e&&Y.alternate===null&&(Y.flags|=67108866),Y}function M(Y,V,Z,fe){return V===null||V.tag!==6?(V=Zc(Z,Y.mode,fe),V.return=Y,V):(V=c(V,Z),V.return=Y,V)}function z(Y,V,Z,fe){var We=Z.type;return We===A?de(Y,V,Z.props.children,fe,Z.key):V!==null&&(V.elementType===We||typeof We=="object"&&We!==null&&We.$$typeof===H&&ta(We)===V.type)?(V=c(V,Z.props),Ws(V,Z),V.return=Y,V):(V=Qo(Z.type,Z.key,Z.props,null,Y.mode,fe),Ws(V,Z),V.return=Y,V)}function J(Y,V,Z,fe){return V===null||V.tag!==4||V.stateNode.containerInfo!==Z.containerInfo||V.stateNode.implementation!==Z.implementation?(V=Jc(Z,Y.mode,fe),V.return=Y,V):(V=c(V,Z.children||[]),V.return=Y,V)}function de(Y,V,Z,fe,We){return V===null||V.tag!==7?(V=$n(Z,Y.mode,fe,We),V.return=Y,V):(V=c(V,Z),V.return=Y,V)}function me(Y,V,Z){if(typeof V=="string"&&V!==""||typeof V=="number"||typeof V=="bigint")return V=Zc(""+V,Y.mode,Z),V.return=Y,V;if(typeof V=="object"&&V!==null){switch(V.$$typeof){case b:return Z=Qo(V.type,V.key,V.props,null,Y.mode,Z),Ws(Z,V),Z.return=Y,Z;case R:return V=Jc(V,Y.mode,Z),V.return=Y,V;case H:return V=ta(V),me(Y,V,Z)}if(ve(V)||te(V))return V=$n(V,Y.mode,Z,null),V.return=Y,V;if(typeof V.then=="function")return me(Y,rl(V),Z);if(V.$$typeof===L)return me(Y,Zo(Y,V),Z);il(Y,V)}return null}function re(Y,V,Z,fe){var We=V!==null?V.key:null;if(typeof Z=="string"&&Z!==""||typeof Z=="number"||typeof Z=="bigint")return We!==null?null:M(Y,V,""+Z,fe);if(typeof Z=="object"&&Z!==null){switch(Z.$$typeof){case b:return Z.key===We?z(Y,V,Z,fe):null;case R:return Z.key===We?J(Y,V,Z,fe):null;case H:return Z=ta(Z),re(Y,V,Z,fe)}if(ve(Z)||te(Z))return We!==null?null:de(Y,V,Z,fe,null);if(typeof Z.then=="function")return re(Y,V,rl(Z),fe);if(Z.$$typeof===L)return re(Y,V,Zo(Y,Z),fe);il(Y,Z)}return null}function oe(Y,V,Z,fe,We){if(typeof fe=="string"&&fe!==""||typeof fe=="number"||typeof fe=="bigint")return Y=Y.get(Z)||null,M(V,Y,""+fe,We);if(typeof fe=="object"&&fe!==null){switch(fe.$$typeof){case b:return Y=Y.get(fe.key===null?Z:fe.key)||null,z(V,Y,fe,We);case R:return Y=Y.get(fe.key===null?Z:fe.key)||null,J(V,Y,fe,We);case H:return fe=ta(fe),oe(Y,V,Z,fe,We)}if(ve(fe)||te(fe))return Y=Y.get(Z)||null,de(V,Y,fe,We,null);if(typeof fe.then=="function")return oe(Y,V,Z,rl(fe),We);if(fe.$$typeof===L)return oe(Y,V,Z,Zo(V,fe),We);il(V,fe)}return null}function Oe(Y,V,Z,fe){for(var We=null,Et=null,ze=V,nt=V=0,gt=null;ze!==null&&nt<Z.length;nt++){ze.index>nt?(gt=ze,ze=null):gt=ze.sibling;var wt=re(Y,ze,Z[nt],fe);if(wt===null){ze===null&&(ze=gt);break}e&&ze&&wt.alternate===null&&r(Y,ze),V=d(wt,V,nt),Et===null?We=wt:Et.sibling=wt,Et=wt,ze=gt}if(nt===Z.length)return n(Y,ze),vt&&ki(Y,nt),We;if(ze===null){for(;nt<Z.length;nt++)ze=me(Y,Z[nt],fe),ze!==null&&(V=d(ze,V,nt),Et===null?We=ze:Et.sibling=ze,Et=ze);return vt&&ki(Y,nt),We}for(ze=s(ze);nt<Z.length;nt++)gt=oe(ze,Y,nt,Z[nt],fe),gt!==null&&(e&&gt.alternate!==null&&ze.delete(gt.key===null?nt:gt.key),V=d(gt,V,nt),Et===null?We=gt:Et.sibling=gt,Et=gt);return e&&ze.forEach(function(Ln){return r(Y,Ln)}),vt&&ki(Y,nt),We}function Qe(Y,V,Z,fe){if(Z==null)throw Error(a(151));for(var We=null,Et=null,ze=V,nt=V=0,gt=null,wt=Z.next();ze!==null&&!wt.done;nt++,wt=Z.next()){ze.index>nt?(gt=ze,ze=null):gt=ze.sibling;var Ln=re(Y,ze,wt.value,fe);if(Ln===null){ze===null&&(ze=gt);break}e&&ze&&Ln.alternate===null&&r(Y,ze),V=d(Ln,V,nt),Et===null?We=Ln:Et.sibling=Ln,Et=Ln,ze=gt}if(wt.done)return n(Y,ze),vt&&ki(Y,nt),We;if(ze===null){for(;!wt.done;nt++,wt=Z.next())wt=me(Y,wt.value,fe),wt!==null&&(V=d(wt,V,nt),Et===null?We=wt:Et.sibling=wt,Et=wt);return vt&&ki(Y,nt),We}for(ze=s(ze);!wt.done;nt++,wt=Z.next())wt=oe(ze,Y,nt,wt.value,fe),wt!==null&&(e&&wt.alternate!==null&&ze.delete(wt.key===null?nt:wt.key),V=d(wt,V,nt),Et===null?We=wt:Et.sibling=wt,Et=wt);return e&&ze.forEach(function(rx){return r(Y,rx)}),vt&&ki(Y,nt),We}function Ot(Y,V,Z,fe){if(typeof Z=="object"&&Z!==null&&Z.type===A&&Z.key===null&&(Z=Z.props.children),typeof Z=="object"&&Z!==null){switch(Z.$$typeof){case b:e:{for(var We=Z.key;V!==null;){if(V.key===We){if(We=Z.type,We===A){if(V.tag===7){n(Y,V.sibling),fe=c(V,Z.props.children),fe.return=Y,Y=fe;break e}}else if(V.elementType===We||typeof We=="object"&&We!==null&&We.$$typeof===H&&ta(We)===V.type){n(Y,V.sibling),fe=c(V,Z.props),Ws(fe,Z),fe.return=Y,Y=fe;break e}n(Y,V);break}else r(Y,V);V=V.sibling}Z.type===A?(fe=$n(Z.props.children,Y.mode,fe,Z.key),fe.return=Y,Y=fe):(fe=Qo(Z.type,Z.key,Z.props,null,Y.mode,fe),Ws(fe,Z),fe.return=Y,Y=fe)}return g(Y);case R:e:{for(We=Z.key;V!==null;){if(V.key===We)if(V.tag===4&&V.stateNode.containerInfo===Z.containerInfo&&V.stateNode.implementation===Z.implementation){n(Y,V.sibling),fe=c(V,Z.children||[]),fe.return=Y,Y=fe;break e}else{n(Y,V);break}else r(Y,V);V=V.sibling}fe=Jc(Z,Y.mode,fe),fe.return=Y,Y=fe}return g(Y);case H:return Z=ta(Z),Ot(Y,V,Z,fe)}if(ve(Z))return Oe(Y,V,Z,fe);if(te(Z)){if(We=te(Z),typeof We!="function")throw Error(a(150));return Z=We.call(Z),Qe(Y,V,Z,fe)}if(typeof Z.then=="function")return Ot(Y,V,rl(Z),fe);if(Z.$$typeof===L)return Ot(Y,V,Zo(Y,Z),fe);il(Y,Z)}return typeof Z=="string"&&Z!==""||typeof Z=="number"||typeof Z=="bigint"?(Z=""+Z,V!==null&&V.tag===6?(n(Y,V.sibling),fe=c(V,Z),fe.return=Y,Y=fe):(n(Y,V),fe=Zc(Z,Y.mode,fe),fe.return=Y,Y=fe),g(Y)):n(Y,V)}return function(Y,V,Z,fe){try{Gs=0;var We=Ot(Y,V,Z,fe);return Fa=null,We}catch(ze){if(ze===ka||ze===el)throw ze;var Et=Vr(29,ze,null,Y.mode);return Et.lanes=fe,Et.return=Y,Et}finally{}}}var ia=vp(!0),_p=vp(!1),pn=!1;function du(e){e.updateQueue={baseState:e.memoizedState,firstBaseUpdate:null,lastBaseUpdate:null,shared:{pending:null,lanes:0,hiddenCallbacks:null},callbacks:null}}function hu(e,r){e=e.updateQueue,r.updateQueue===e&&(r.updateQueue={baseState:e.baseState,firstBaseUpdate:e.firstBaseUpdate,lastBaseUpdate:e.lastBaseUpdate,shared:e.shared,callbacks:null})}function mn(e){return{lane:e,tag:0,payload:null,callback:null,next:null}}function gn(e,r,n){var s=e.updateQueue;if(s===null)return null;if(s=s.shared,(Rt&2)!==0){var c=s.pending;return c===null?r.next=r:(r.next=c.next,c.next=r),s.pending=r,r=qo(e),tp(e,null,n),r}return Yo(e,s,r,n),qo(e)}function js(e,r,n){if(r=r.updateQueue,r!==null&&(r=r.shared,(n&4194048)!==0)){var s=r.lanes;s&=e.pendingLanes,n|=s,r.lanes=n,Ts(e,n)}}function fu(e,r){var n=e.updateQueue,s=e.alternate;if(s!==null&&(s=s.updateQueue,n===s)){var c=null,d=null;if(n=n.firstBaseUpdate,n!==null){do{var g={lane:n.lane,tag:n.tag,payload:n.payload,callback:null,next:null};d===null?c=d=g:d=d.next=g,n=n.next}while(n!==null);d===null?c=d=r:d=d.next=r}else c=d=r;n={baseState:s.baseState,firstBaseUpdate:c,lastBaseUpdate:d,shared:s.shared,callbacks:s.callbacks},e.updateQueue=n;return}e=n.lastBaseUpdate,e===null?n.firstBaseUpdate=r:e.next=r,n.lastBaseUpdate=r}var pu=!1;function Xs(){if(pu){var e=Oa;if(e!==null)throw e}}function Ys(e,r,n,s){pu=!1;var c=e.updateQueue;pn=!1;var d=c.firstBaseUpdate,g=c.lastBaseUpdate,M=c.shared.pending;if(M!==null){c.shared.pending=null;var z=M,J=z.next;z.next=null,g===null?d=J:g.next=J,g=z;var de=e.alternate;de!==null&&(de=de.updateQueue,M=de.lastBaseUpdate,M!==g&&(M===null?de.firstBaseUpdate=J:M.next=J,de.lastBaseUpdate=z))}if(d!==null){var me=c.baseState;g=0,de=J=z=null,M=d;do{var re=M.lane&-536870913,oe=re!==M.lane;if(oe?(mt&re)===re:(s&re)===re){re!==0&&re===Na&&(pu=!0),de!==null&&(de=de.next={lane:0,tag:M.tag,payload:M.payload,callback:null,next:null});e:{var Oe=e,Qe=M;re=r;var Ot=n;switch(Qe.tag){case 1:if(Oe=Qe.payload,typeof Oe=="function"){me=Oe.call(Ot,me,re);break e}me=Oe;break e;case 3:Oe.flags=Oe.flags&-65537|128;case 0:if(Oe=Qe.payload,re=typeof Oe=="function"?Oe.call(Ot,me,re):Oe,re==null)break e;me=y({},me,re);break e;case 2:pn=!0}}re=M.callback,re!==null&&(e.flags|=64,oe&&(e.flags|=8192),oe=c.callbacks,oe===null?c.callbacks=[re]:oe.push(re))}else oe={lane:re,tag:M.tag,payload:M.payload,callback:M.callback,next:null},de===null?(J=de=oe,z=me):de=de.next=oe,g|=re;if(M=M.next,M===null){if(M=c.shared.pending,M===null)break;oe=M,M=oe.next,oe.next=null,c.lastBaseUpdate=oe,c.shared.pending=null}}while(!0);de===null&&(z=me),c.baseState=z,c.firstBaseUpdate=J,c.lastBaseUpdate=de,d===null&&(c.shared.lanes=0),Sn|=g,e.lanes=g,e.memoizedState=me}}function yp(e,r){if(typeof e!="function")throw Error(a(191,e));e.call(r)}function xp(e,r){var n=e.callbacks;if(n!==null)for(e.callbacks=null,e=0;e<n.length;e++)yp(n[e],r)}var za=O(null),nl=O(0);function Sp(e,r){e=qi,xe(nl,e),xe(za,r),qi=e|r.baseLanes}function mu(){xe(nl,qi),xe(za,za.current)}function gu(){qi=nl.current,ie(za),ie(nl)}var Gr=O(null),hi=null;function vn(e){var r=e.alternate;xe(Kt,Kt.current&1),xe(Gr,e),hi===null&&(r===null||za.current!==null||r.memoizedState!==null)&&(hi=e)}function vu(e){xe(Kt,Kt.current),xe(Gr,e),hi===null&&(hi=e)}function bp(e){e.tag===22?(xe(Kt,Kt.current),xe(Gr,e),hi===null&&(hi=e)):_n()}function _n(){xe(Kt,Kt.current),xe(Gr,Gr.current)}function Wr(e){ie(Gr),hi===e&&(hi=null),ie(Kt)}var Kt=O(0);function al(e){for(var r=e;r!==null;){if(r.tag===13){var n=r.memoizedState;if(n!==null&&(n=n.dehydrated,n===null||Md(n)||Ed(n)))return r}else if(r.tag===19&&(r.memoizedProps.revealOrder==="forwards"||r.memoizedProps.revealOrder==="backwards"||r.memoizedProps.revealOrder==="unstable_legacy-backwards"||r.memoizedProps.revealOrder==="together")){if((r.flags&128)!==0)return r}else if(r.child!==null){r.child.return=r,r=r.child;continue}if(r===e)break;for(;r.sibling===null;){if(r.return===null||r.return===e)return null;r=r.return}r.sibling.return=r.return,r=r.sibling}return null}var Bi=0,it=null,It=null,er=null,sl=!1,Ba=!1,na=!1,ol=0,qs=0,Ha=null,X0=0;function Qt(){throw Error(a(321))}function _u(e,r){if(r===null)return!1;for(var n=0;n<r.length&&n<e.length;n++)if(!Hr(e[n],r[n]))return!1;return!0}function yu(e,r,n,s,c,d){return Bi=d,it=r,r.memoizedState=null,r.updateQueue=null,r.lanes=0,N.H=e===null||e.memoizedState===null?am:Iu,na=!1,d=n(s,c),na=!1,Ba&&(d=Ep(r,n,s,c)),Mp(e),d}function Mp(e){N.H=Ks;var r=It!==null&&It.next!==null;if(Bi=0,er=It=it=null,sl=!1,qs=0,Ha=null,r)throw Error(a(300));e===null||tr||(e=e.dependencies,e!==null&&Ko(e)&&(tr=!0))}function Ep(e,r,n,s){it=e;var c=0;do{if(Ba&&(Ha=null),qs=0,Ba=!1,25<=c)throw Error(a(301));if(c+=1,er=It=null,e.updateQueue!=null){var d=e.updateQueue;d.lastEffect=null,d.events=null,d.stores=null,d.memoCache!=null&&(d.memoCache.index=0)}N.H=sm,d=r(n,s)}while(Ba);return d}function Y0(){var e=N.H,r=e.useState()[0];return r=typeof r.then=="function"?Qs(r):r,e=e.useState()[0],(It!==null?It.memoizedState:null)!==e&&(it.flags|=1024),r}function xu(){var e=ol!==0;return ol=0,e}function Su(e,r,n){r.updateQueue=e.updateQueue,r.flags&=-2053,e.lanes&=~n}function bu(e){if(sl){for(e=e.memoizedState;e!==null;){var r=e.queue;r!==null&&(r.pending=null),e=e.next}sl=!1}Bi=0,er=It=it=null,Ba=!1,qs=ol=0,Ha=null}function Rr(){var e={memoizedState:null,baseState:null,baseQueue:null,queue:null,next:null};return er===null?it.memoizedState=er=e:er=er.next=e,er}function Zt(){if(It===null){var e=it.alternate;e=e!==null?e.memoizedState:null}else e=It.next;var r=er===null?it.memoizedState:er.next;if(r!==null)er=r,It=e;else{if(e===null)throw it.alternate===null?Error(a(467)):Error(a(310));It=e,e={memoizedState:It.memoizedState,baseState:It.baseState,baseQueue:It.baseQueue,queue:It.queue,next:null},er===null?it.memoizedState=er=e:er=er.next=e}return er}function ll(){return{lastEffect:null,events:null,stores:null,memoCache:null}}function Qs(e){var r=qs;return qs+=1,Ha===null&&(Ha=[]),e=pp(Ha,e,r),r=it,(er===null?r.memoizedState:er.next)===null&&(r=r.alternate,N.H=r===null||r.memoizedState===null?am:Iu),e}function cl(e){if(e!==null&&typeof e=="object"){if(typeof e.then=="function")return Qs(e);if(e.$$typeof===L)return mr(e)}throw Error(a(438,String(e)))}function Mu(e){var r=null,n=it.updateQueue;if(n!==null&&(r=n.memoCache),r==null){var s=it.alternate;s!==null&&(s=s.updateQueue,s!==null&&(s=s.memoCache,s!=null&&(r={data:s.data.map(function(c){return c.slice()}),index:0})))}if(r==null&&(r={data:[],index:0}),n===null&&(n=ll(),it.updateQueue=n),n.memoCache=r,n=r.data[r.index],n===void 0)for(n=r.data[r.index]=Array(e),s=0;s<e;s++)n[s]=w;return r.index++,n}function Hi(e,r){return typeof r=="function"?r(e):r}function ul(e){var r=Zt();return Eu(r,It,e)}function Eu(e,r,n){var s=e.queue;if(s===null)throw Error(a(311));s.lastRenderedReducer=n;var c=e.baseQueue,d=s.pending;if(d!==null){if(c!==null){var g=c.next;c.next=d.next,d.next=g}r.baseQueue=c=d,s.pending=null}if(d=e.baseState,c===null)e.memoizedState=d;else{r=c.next;var M=g=null,z=null,J=r,de=!1;do{var me=J.lane&-536870913;if(me!==J.lane?(mt&me)===me:(Bi&me)===me){var re=J.revertLane;if(re===0)z!==null&&(z=z.next={lane:0,revertLane:0,gesture:null,action:J.action,hasEagerState:J.hasEagerState,eagerState:J.eagerState,next:null}),me===Na&&(de=!0);else if((Bi&re)===re){J=J.next,re===Na&&(de=!0);continue}else me={lane:0,revertLane:J.revertLane,gesture:null,action:J.action,hasEagerState:J.hasEagerState,eagerState:J.eagerState,next:null},z===null?(M=z=me,g=d):z=z.next=me,it.lanes|=re,Sn|=re;me=J.action,na&&n(d,me),d=J.hasEagerState?J.eagerState:n(d,me)}else re={lane:me,revertLane:J.revertLane,gesture:J.gesture,action:J.action,hasEagerState:J.hasEagerState,eagerState:J.eagerState,next:null},z===null?(M=z=re,g=d):z=z.next=re,it.lanes|=me,Sn|=me;J=J.next}while(J!==null&&J!==r);if(z===null?g=d:z.next=M,!Hr(d,e.memoizedState)&&(tr=!0,de&&(n=Oa,n!==null)))throw n;e.memoizedState=d,e.baseState=g,e.baseQueue=z,s.lastRenderedState=d}return c===null&&(s.lanes=0),[e.memoizedState,s.dispatch]}function wu(e){var r=Zt(),n=r.queue;if(n===null)throw Error(a(311));n.lastRenderedReducer=e;var s=n.dispatch,c=n.pending,d=r.memoizedState;if(c!==null){n.pending=null;var g=c=c.next;do d=e(d,g.action),g=g.next;while(g!==c);Hr(d,r.memoizedState)||(tr=!0),r.memoizedState=d,r.baseQueue===null&&(r.baseState=d),n.lastRenderedState=d}return[d,s]}function wp(e,r,n){var s=it,c=Zt(),d=vt;if(d){if(n===void 0)throw Error(a(407));n=n()}else n=r();var g=!Hr((It||c).memoizedState,n);if(g&&(c.memoizedState=n,tr=!0),c=c.queue,Cu(Cp.bind(null,s,c,e),[e]),c.getSnapshot!==r||g||er!==null&&er.memoizedState.tag&1){if(s.flags|=2048,Va(9,{destroy:void 0},Rp.bind(null,s,c,n,r),null),zt===null)throw Error(a(349));d||(Bi&127)!==0||Tp(s,r,n)}return n}function Tp(e,r,n){e.flags|=16384,e={getSnapshot:r,value:n},r=it.updateQueue,r===null?(r=ll(),it.updateQueue=r,r.stores=[e]):(n=r.stores,n===null?r.stores=[e]:n.push(e))}function Rp(e,r,n,s){r.value=n,r.getSnapshot=s,Ap(r)&&Pp(e)}function Cp(e,r,n){return n(function(){Ap(r)&&Pp(e)})}function Ap(e){var r=e.getSnapshot;e=e.value;try{var n=r();return!Hr(e,n)}catch{return!0}}function Pp(e){var r=Qn(e,2);r!==null&&kr(r,e,2)}function Tu(e){var r=Rr();if(typeof e=="function"){var n=e;if(e=n(),na){Ue(!0);try{n()}finally{Ue(!1)}}}return r.memoizedState=r.baseState=e,r.queue={pending:null,lanes:0,dispatch:null,lastRenderedReducer:Hi,lastRenderedState:e},r}function Lp(e,r,n,s){return e.baseState=n,Eu(e,It,typeof s=="function"?s:Hi)}function q0(e,r,n,s,c){if(fl(e))throw Error(a(485));if(e=r.action,e!==null){var d={payload:c,action:e,next:null,isTransition:!0,status:"pending",value:null,reason:null,listeners:[],then:function(g){d.listeners.push(g)}};N.T!==null?n(!0):d.isTransition=!1,s(d),n=r.pending,n===null?(d.next=r.pending=d,Up(r,d)):(d.next=n.next,r.pending=n.next=d)}}function Up(e,r){var n=r.action,s=r.payload,c=e.state;if(r.isTransition){var d=N.T,g={};N.T=g;try{var M=n(c,s),z=N.S;z!==null&&z(g,M),Dp(e,r,M)}catch(J){Ru(e,r,J)}finally{d!==null&&g.types!==null&&(d.types=g.types),N.T=d}}else try{d=n(c,s),Dp(e,r,d)}catch(J){Ru(e,r,J)}}function Dp(e,r,n){n!==null&&typeof n=="object"&&typeof n.then=="function"?n.then(function(s){Ip(e,r,s)},function(s){return Ru(e,r,s)}):Ip(e,r,n)}function Ip(e,r,n){r.status="fulfilled",r.value=n,Np(r),e.state=n,r=e.pending,r!==null&&(n=r.next,n===r?e.pending=null:(n=n.next,r.next=n,Up(e,n)))}function Ru(e,r,n){var s=e.pending;if(e.pending=null,s!==null){s=s.next;do r.status="rejected",r.reason=n,Np(r),r=r.next;while(r!==s)}e.action=null}function Np(e){e=e.listeners;for(var r=0;r<e.length;r++)(0,e[r])()}function Op(e,r){return r}function kp(e,r){if(vt){var n=zt.formState;if(n!==null){e:{var s=it;if(vt){if(Bt){t:{for(var c=Bt,d=ti;c.nodeType!==8;){if(!d){c=null;break t}if(c=ri(c.nextSibling),c===null){c=null;break t}}d=c.data,c=d==="F!"||d==="F"?c:null}if(c){Bt=ri(c.nextSibling),s=c.data==="F!";break e}}hn(s)}s=!1}s&&(r=n[0])}}return n=Rr(),n.memoizedState=n.baseState=r,s={pending:null,lanes:0,dispatch:null,lastRenderedReducer:Op,lastRenderedState:r},n.queue=s,n=rm.bind(null,it,s),s.dispatch=n,s=Tu(!1),d=Du.bind(null,it,!1,s.queue),s=Rr(),c={state:r,dispatch:null,action:e,pending:null},s.queue=c,n=q0.bind(null,it,c,d,n),c.dispatch=n,s.memoizedState=e,[r,n,!1]}function Fp(e){var r=Zt();return zp(r,It,e)}function zp(e,r,n){if(r=Eu(e,r,Op)[0],e=ul(Hi)[0],typeof r=="object"&&r!==null&&typeof r.then=="function")try{var s=Qs(r)}catch(g){throw g===ka?el:g}else s=r;r=Zt();var c=r.queue,d=c.dispatch;return n!==r.memoizedState&&(it.flags|=2048,Va(9,{destroy:void 0},Q0.bind(null,c,n),null)),[s,d,e]}function Q0(e,r){e.action=r}function Bp(e){var r=Zt(),n=It;if(n!==null)return zp(r,n,e);Zt(),r=r.memoizedState,n=Zt();var s=n.queue.dispatch;return n.memoizedState=e,[r,s,!1]}function Va(e,r,n,s){return e={tag:e,create:n,deps:s,inst:r,next:null},r=it.updateQueue,r===null&&(r=ll(),it.updateQueue=r),n=r.lastEffect,n===null?r.lastEffect=e.next=e:(s=n.next,n.next=e,e.next=s,r.lastEffect=e),e}function Hp(){return Zt().memoizedState}function dl(e,r,n,s){var c=Rr();it.flags|=e,c.memoizedState=Va(1|r,{destroy:void 0},n,s===void 0?null:s)}function hl(e,r,n,s){var c=Zt();s=s===void 0?null:s;var d=c.memoizedState.inst;It!==null&&s!==null&&_u(s,It.memoizedState.deps)?c.memoizedState=Va(r,d,n,s):(it.flags|=e,c.memoizedState=Va(1|r,d,n,s))}function Vp(e,r){dl(8390656,8,e,r)}function Cu(e,r){hl(2048,8,e,r)}function $0(e){it.flags|=4;var r=it.updateQueue;if(r===null)r=ll(),it.updateQueue=r,r.events=[e];else{var n=r.events;n===null?r.events=[e]:n.push(e)}}function Gp(e){var r=Zt().memoizedState;return $0({ref:r,nextImpl:e}),function(){if((Rt&2)!==0)throw Error(a(440));return r.impl.apply(void 0,arguments)}}function Wp(e,r){return hl(4,2,e,r)}function jp(e,r){return hl(4,4,e,r)}function Xp(e,r){if(typeof r=="function"){e=e();var n=r(e);return function(){typeof n=="function"?n():r(null)}}if(r!=null)return e=e(),r.current=e,function(){r.current=null}}function Yp(e,r,n){n=n!=null?n.concat([e]):null,hl(4,4,Xp.bind(null,r,e),n)}function Au(){}function qp(e,r){var n=Zt();r=r===void 0?null:r;var s=n.memoizedState;return r!==null&&_u(r,s[1])?s[0]:(n.memoizedState=[e,r],e)}function Qp(e,r){var n=Zt();r=r===void 0?null:r;var s=n.memoizedState;if(r!==null&&_u(r,s[1]))return s[0];if(s=e(),na){Ue(!0);try{e()}finally{Ue(!1)}}return n.memoizedState=[s,r],s}function Pu(e,r,n){return n===void 0||(Bi&1073741824)!==0&&(mt&261930)===0?e.memoizedState=r:(e.memoizedState=n,e=$m(),it.lanes|=e,Sn|=e,n)}function $p(e,r,n,s){return Hr(n,r)?n:za.current!==null?(e=Pu(e,n,s),Hr(e,r)||(tr=!0),e):(Bi&42)===0||(Bi&1073741824)!==0&&(mt&261930)===0?(tr=!0,e.memoizedState=n):(e=$m(),it.lanes|=e,Sn|=e,r)}function Kp(e,r,n,s,c){var d=K.p;K.p=d!==0&&8>d?d:8;var g=N.T,M={};N.T=M,Du(e,!1,r,n);try{var z=c(),J=N.S;if(J!==null&&J(M,z),z!==null&&typeof z=="object"&&typeof z.then=="function"){var de=j0(z,s);$s(e,r,de,Yr(e))}else $s(e,r,s,Yr(e))}catch(me){$s(e,r,{then:function(){},status:"rejected",reason:me},Yr())}finally{K.p=d,g!==null&&M.types!==null&&(g.types=M.types),N.T=g}}function K0(){}function Lu(e,r,n,s){if(e.tag!==5)throw Error(a(476));var c=Zp(e).queue;Kp(e,c,r,q,n===null?K0:function(){return Jp(e),n(s)})}function Zp(e){var r=e.memoizedState;if(r!==null)return r;r={memoizedState:q,baseState:q,baseQueue:null,queue:{pending:null,lanes:0,dispatch:null,lastRenderedReducer:Hi,lastRenderedState:q},next:null};var n={};return r.next={memoizedState:n,baseState:n,baseQueue:null,queue:{pending:null,lanes:0,dispatch:null,lastRenderedReducer:Hi,lastRenderedState:n},next:null},e.memoizedState=r,e=e.alternate,e!==null&&(e.memoizedState=r),r}function Jp(e){var r=Zp(e);r.next===null&&(r=e.alternate.memoizedState),$s(e,r.next.queue,{},Yr())}function Uu(){return mr(po)}function em(){return Zt().memoizedState}function tm(){return Zt().memoizedState}function Z0(e){for(var r=e.return;r!==null;){switch(r.tag){case 24:case 3:var n=Yr();e=mn(n);var s=gn(r,e,n);s!==null&&(kr(s,r,n),js(s,r,n)),r={cache:ou()},e.payload=r;return}r=r.return}}function J0(e,r,n){var s=Yr();n={lane:s,revertLane:0,gesture:null,action:n,hasEagerState:!1,eagerState:null,next:null},fl(e)?im(r,n):(n=$c(e,r,n,s),n!==null&&(kr(n,e,s),nm(n,r,s)))}function rm(e,r,n){var s=Yr();$s(e,r,n,s)}function $s(e,r,n,s){var c={lane:s,revertLane:0,gesture:null,action:n,hasEagerState:!1,eagerState:null,next:null};if(fl(e))im(r,c);else{var d=e.alternate;if(e.lanes===0&&(d===null||d.lanes===0)&&(d=r.lastRenderedReducer,d!==null))try{var g=r.lastRenderedState,M=d(g,n);if(c.hasEagerState=!0,c.eagerState=M,Hr(M,g))return Yo(e,r,c,0),zt===null&&Xo(),!1}catch{}finally{}if(n=$c(e,r,c,s),n!==null)return kr(n,e,s),nm(n,r,s),!0}return!1}function Du(e,r,n,s){if(s={lane:2,revertLane:dd(),gesture:null,action:s,hasEagerState:!1,eagerState:null,next:null},fl(e)){if(r)throw Error(a(479))}else r=$c(e,n,s,2),r!==null&&kr(r,e,2)}function fl(e){var r=e.alternate;return e===it||r!==null&&r===it}function im(e,r){Ba=sl=!0;var n=e.pending;n===null?r.next=r:(r.next=n.next,n.next=r),e.pending=r}function nm(e,r,n){if((n&4194048)!==0){var s=r.lanes;s&=e.pendingLanes,n|=s,r.lanes=n,Ts(e,n)}}var Ks={readContext:mr,use:cl,useCallback:Qt,useContext:Qt,useEffect:Qt,useImperativeHandle:Qt,useLayoutEffect:Qt,useInsertionEffect:Qt,useMemo:Qt,useReducer:Qt,useRef:Qt,useState:Qt,useDebugValue:Qt,useDeferredValue:Qt,useTransition:Qt,useSyncExternalStore:Qt,useId:Qt,useHostTransitionStatus:Qt,useFormState:Qt,useActionState:Qt,useOptimistic:Qt,useMemoCache:Qt,useCacheRefresh:Qt};Ks.useEffectEvent=Qt;var am={readContext:mr,use:cl,useCallback:function(e,r){return Rr().memoizedState=[e,r===void 0?null:r],e},useContext:mr,useEffect:Vp,useImperativeHandle:function(e,r,n){n=n!=null?n.concat([e]):null,dl(4194308,4,Xp.bind(null,r,e),n)},useLayoutEffect:function(e,r){return dl(4194308,4,e,r)},useInsertionEffect:function(e,r){dl(4,2,e,r)},useMemo:function(e,r){var n=Rr();r=r===void 0?null:r;var s=e();if(na){Ue(!0);try{e()}finally{Ue(!1)}}return n.memoizedState=[s,r],s},useReducer:function(e,r,n){var s=Rr();if(n!==void 0){var c=n(r);if(na){Ue(!0);try{n(r)}finally{Ue(!1)}}}else c=r;return s.memoizedState=s.baseState=c,e={pending:null,lanes:0,dispatch:null,lastRenderedReducer:e,lastRenderedState:c},s.queue=e,e=e.dispatch=J0.bind(null,it,e),[s.memoizedState,e]},useRef:function(e){var r=Rr();return e={current:e},r.memoizedState=e},useState:function(e){e=Tu(e);var r=e.queue,n=rm.bind(null,it,r);return r.dispatch=n,[e.memoizedState,n]},useDebugValue:Au,useDeferredValue:function(e,r){var n=Rr();return Pu(n,e,r)},useTransition:function(){var e=Tu(!1);return e=Kp.bind(null,it,e.queue,!0,!1),Rr().memoizedState=e,[!1,e]},useSyncExternalStore:function(e,r,n){var s=it,c=Rr();if(vt){if(n===void 0)throw Error(a(407));n=n()}else{if(n=r(),zt===null)throw Error(a(349));(mt&127)!==0||Tp(s,r,n)}c.memoizedState=n;var d={value:n,getSnapshot:r};return c.queue=d,Vp(Cp.bind(null,s,d,e),[e]),s.flags|=2048,Va(9,{destroy:void 0},Rp.bind(null,s,d,n,r),null),n},useId:function(){var e=Rr(),r=zt.identifierPrefix;if(vt){var n=Ei,s=Mi;n=(s&~(1<<32-Ke(s)-1)).toString(32)+n,r="_"+r+"R_"+n,n=ol++,0<n&&(r+="H"+n.toString(32)),r+="_"}else n=X0++,r="_"+r+"r_"+n.toString(32)+"_";return e.memoizedState=r},useHostTransitionStatus:Uu,useFormState:kp,useActionState:kp,useOptimistic:function(e){var r=Rr();r.memoizedState=r.baseState=e;var n={pending:null,lanes:0,dispatch:null,lastRenderedReducer:null,lastRenderedState:null};return r.queue=n,r=Du.bind(null,it,!0,n),n.dispatch=r,[e,r]},useMemoCache:Mu,useCacheRefresh:function(){return Rr().memoizedState=Z0.bind(null,it)},useEffectEvent:function(e){var r=Rr(),n={impl:e};return r.memoizedState=n,function(){if((Rt&2)!==0)throw Error(a(440));return n.impl.apply(void 0,arguments)}}},Iu={readContext:mr,use:cl,useCallback:qp,useContext:mr,useEffect:Cu,useImperativeHandle:Yp,useInsertionEffect:Wp,useLayoutEffect:jp,useMemo:Qp,useReducer:ul,useRef:Hp,useState:function(){return ul(Hi)},useDebugValue:Au,useDeferredValue:function(e,r){var n=Zt();return $p(n,It.memoizedState,e,r)},useTransition:function(){var e=ul(Hi)[0],r=Zt().memoizedState;return[typeof e=="boolean"?e:Qs(e),r]},useSyncExternalStore:wp,useId:em,useHostTransitionStatus:Uu,useFormState:Fp,useActionState:Fp,useOptimistic:function(e,r){var n=Zt();return Lp(n,It,e,r)},useMemoCache:Mu,useCacheRefresh:tm};Iu.useEffectEvent=Gp;var sm={readContext:mr,use:cl,useCallback:qp,useContext:mr,useEffect:Cu,useImperativeHandle:Yp,useInsertionEffect:Wp,useLayoutEffect:jp,useMemo:Qp,useReducer:wu,useRef:Hp,useState:function(){return wu(Hi)},useDebugValue:Au,useDeferredValue:function(e,r){var n=Zt();return It===null?Pu(n,e,r):$p(n,It.memoizedState,e,r)},useTransition:function(){var e=wu(Hi)[0],r=Zt().memoizedState;return[typeof e=="boolean"?e:Qs(e),r]},useSyncExternalStore:wp,useId:em,useHostTransitionStatus:Uu,useFormState:Bp,useActionState:Bp,useOptimistic:function(e,r){var n=Zt();return It!==null?Lp(n,It,e,r):(n.baseState=e,[e,n.queue.dispatch])},useMemoCache:Mu,useCacheRefresh:tm};sm.useEffectEvent=Gp;function Nu(e,r,n,s){r=e.memoizedState,n=n(s,r),n=n==null?r:y({},r,n),e.memoizedState=n,e.lanes===0&&(e.updateQueue.baseState=n)}var Ou={enqueueSetState:function(e,r,n){e=e._reactInternals;var s=Yr(),c=mn(s);c.payload=r,n!=null&&(c.callback=n),r=gn(e,c,s),r!==null&&(kr(r,e,s),js(r,e,s))},enqueueReplaceState:function(e,r,n){e=e._reactInternals;var s=Yr(),c=mn(s);c.tag=1,c.payload=r,n!=null&&(c.callback=n),r=gn(e,c,s),r!==null&&(kr(r,e,s),js(r,e,s))},enqueueForceUpdate:function(e,r){e=e._reactInternals;var n=Yr(),s=mn(n);s.tag=2,r!=null&&(s.callback=r),r=gn(e,s,n),r!==null&&(kr(r,e,n),js(r,e,n))}};function om(e,r,n,s,c,d,g){return e=e.stateNode,typeof e.shouldComponentUpdate=="function"?e.shouldComponentUpdate(s,d,g):r.prototype&&r.prototype.isPureReactComponent?!ks(n,s)||!ks(c,d):!0}function lm(e,r,n,s){e=r.state,typeof r.componentWillReceiveProps=="function"&&r.componentWillReceiveProps(n,s),typeof r.UNSAFE_componentWillReceiveProps=="function"&&r.UNSAFE_componentWillReceiveProps(n,s),r.state!==e&&Ou.enqueueReplaceState(r,r.state,null)}function aa(e,r){var n=r;if("ref"in r){n={};for(var s in r)s!=="ref"&&(n[s]=r[s])}if(e=e.defaultProps){n===r&&(n=y({},n));for(var c in e)n[c]===void 0&&(n[c]=e[c])}return n}function cm(e){jo(e)}function um(e){console.error(e)}function dm(e){jo(e)}function pl(e,r){try{var n=e.onUncaughtError;n(r.value,{componentStack:r.stack})}catch(s){setTimeout(function(){throw s})}}function hm(e,r,n){try{var s=e.onCaughtError;s(n.value,{componentStack:n.stack,errorBoundary:r.tag===1?r.stateNode:null})}catch(c){setTimeout(function(){throw c})}}function ku(e,r,n){return n=mn(n),n.tag=3,n.payload={element:null},n.callback=function(){pl(e,r)},n}function fm(e){return e=mn(e),e.tag=3,e}function pm(e,r,n,s){var c=n.type.getDerivedStateFromError;if(typeof c=="function"){var d=s.value;e.payload=function(){return c(d)},e.callback=function(){hm(r,n,s)}}var g=n.stateNode;g!==null&&typeof g.componentDidCatch=="function"&&(e.callback=function(){hm(r,n,s),typeof c!="function"&&(bn===null?bn=new Set([this]):bn.add(this));var M=s.stack;this.componentDidCatch(s.value,{componentStack:M!==null?M:""})})}function ey(e,r,n,s,c){if(n.flags|=32768,s!==null&&typeof s=="object"&&typeof s.then=="function"){if(r=n.alternate,r!==null&&Ia(r,n,c,!0),n=Gr.current,n!==null){switch(n.tag){case 31:case 13:return hi===null?Tl():n.alternate===null&&$t===0&&($t=3),n.flags&=-257,n.flags|=65536,n.lanes=c,s===tl?n.flags|=16384:(r=n.updateQueue,r===null?n.updateQueue=new Set([s]):r.add(s),ld(e,s,c)),!1;case 22:return n.flags|=65536,s===tl?n.flags|=16384:(r=n.updateQueue,r===null?(r={transitions:null,markerInstances:null,retryQueue:new Set([s])},n.updateQueue=r):(n=r.retryQueue,n===null?r.retryQueue=new Set([s]):n.add(s)),ld(e,s,c)),!1}throw Error(a(435,n.tag))}return ld(e,s,c),Tl(),!1}if(vt)return r=Gr.current,r!==null?((r.flags&65536)===0&&(r.flags|=256),r.flags|=65536,r.lanes=c,s!==ru&&(e=Error(a(422),{cause:s}),Bs(Zr(e,n)))):(s!==ru&&(r=Error(a(423),{cause:s}),Bs(Zr(r,n))),e=e.current.alternate,e.flags|=65536,c&=-c,e.lanes|=c,s=Zr(s,n),c=ku(e.stateNode,s,c),fu(e,c),$t!==4&&($t=2)),!1;var d=Error(a(520),{cause:s});if(d=Zr(d,n),ao===null?ao=[d]:ao.push(d),$t!==4&&($t=2),r===null)return!0;s=Zr(s,n),n=r;do{switch(n.tag){case 3:return n.flags|=65536,e=c&-c,n.lanes|=e,e=ku(n.stateNode,s,e),fu(n,e),!1;case 1:if(r=n.type,d=n.stateNode,(n.flags&128)===0&&(typeof r.getDerivedStateFromError=="function"||d!==null&&typeof d.componentDidCatch=="function"&&(bn===null||!bn.has(d))))return n.flags|=65536,c&=-c,n.lanes|=c,c=fm(c),pm(c,e,n,s),fu(n,c),!1}n=n.return}while(n!==null);return!1}var Fu=Error(a(461)),tr=!1;function gr(e,r,n,s){r.child=e===null?_p(r,null,n,s):ia(r,e.child,n,s)}function mm(e,r,n,s,c){n=n.render;var d=r.ref;if("ref"in s){var g={};for(var M in s)M!=="ref"&&(g[M]=s[M])}else g=s;return Jn(r),s=yu(e,r,n,g,d,c),M=xu(),e!==null&&!tr?(Su(e,r,c),Vi(e,r,c)):(vt&&M&&eu(r),r.flags|=1,gr(e,r,s,c),r.child)}function gm(e,r,n,s,c){if(e===null){var d=n.type;return typeof d=="function"&&!Kc(d)&&d.defaultProps===void 0&&n.compare===null?(r.tag=15,r.type=d,vm(e,r,d,s,c)):(e=Qo(n.type,null,s,r,r.mode,c),e.ref=r.ref,e.return=r,r.child=e)}if(d=e.child,!Xu(e,c)){var g=d.memoizedProps;if(n=n.compare,n=n!==null?n:ks,n(g,s)&&e.ref===r.ref)return Vi(e,r,c)}return r.flags|=1,e=Oi(d,s),e.ref=r.ref,e.return=r,r.child=e}function vm(e,r,n,s,c){if(e!==null){var d=e.memoizedProps;if(ks(d,s)&&e.ref===r.ref)if(tr=!1,r.pendingProps=s=d,Xu(e,c))(e.flags&131072)!==0&&(tr=!0);else return r.lanes=e.lanes,Vi(e,r,c)}return zu(e,r,n,s,c)}function _m(e,r,n,s){var c=s.children,d=e!==null?e.memoizedState:null;if(e===null&&r.stateNode===null&&(r.stateNode={_visibility:1,_pendingMarkers:null,_retryCache:null,_transitions:null}),s.mode==="hidden"){if((r.flags&128)!==0){if(d=d!==null?d.baseLanes|n:n,e!==null){for(s=r.child=e.child,c=0;s!==null;)c=c|s.lanes|s.childLanes,s=s.sibling;s=c&~d}else s=0,r.child=null;return ym(e,r,d,n,s)}if((n&536870912)!==0)r.memoizedState={baseLanes:0,cachePool:null},e!==null&&Jo(r,d!==null?d.cachePool:null),d!==null?Sp(r,d):mu(),bp(r);else return s=r.lanes=536870912,ym(e,r,d!==null?d.baseLanes|n:n,n,s)}else d!==null?(Jo(r,d.cachePool),Sp(r,d),_n(),r.memoizedState=null):(e!==null&&Jo(r,null),mu(),_n());return gr(e,r,c,n),r.child}function Zs(e,r){return e!==null&&e.tag===22||r.stateNode!==null||(r.stateNode={_visibility:1,_pendingMarkers:null,_retryCache:null,_transitions:null}),r.sibling}function ym(e,r,n,s,c){var d=cu();return d=d===null?null:{parent:Jt._currentValue,pool:d},r.memoizedState={baseLanes:n,cachePool:d},e!==null&&Jo(r,null),mu(),bp(r),e!==null&&Ia(e,r,s,!0),r.childLanes=c,null}function ml(e,r){return r=vl({mode:r.mode,children:r.children},e.mode),r.ref=e.ref,e.child=r,r.return=e,r}function xm(e,r,n){return ia(r,e.child,null,n),e=ml(r,r.pendingProps),e.flags|=2,Wr(r),r.memoizedState=null,e}function ty(e,r,n){var s=r.pendingProps,c=(r.flags&128)!==0;if(r.flags&=-129,e===null){if(vt){if(s.mode==="hidden")return e=ml(r,s),r.lanes=536870912,Zs(null,e);if(vu(r),(e=Bt)?(e=Ug(e,ti),e=e!==null&&e.data==="&"?e:null,e!==null&&(r.memoizedState={dehydrated:e,treeContext:un!==null?{id:Mi,overflow:Ei}:null,retryLane:536870912,hydrationErrors:null},n=ip(e),n.return=r,r.child=n,pr=r,Bt=null)):e=null,e===null)throw hn(r);return r.lanes=536870912,null}return ml(r,s)}var d=e.memoizedState;if(d!==null){var g=d.dehydrated;if(vu(r),c)if(r.flags&256)r.flags&=-257,r=xm(e,r,n);else if(r.memoizedState!==null)r.child=e.child,r.flags|=128,r=null;else throw Error(a(558));else if(tr||Ia(e,r,n,!1),c=(n&e.childLanes)!==0,tr||c){if(s=zt,s!==null&&(g=bi(s,n),g!==0&&g!==d.retryLane))throw d.retryLane=g,Qn(e,g),kr(s,e,g),Fu;Tl(),r=xm(e,r,n)}else e=d.treeContext,Bt=ri(g.nextSibling),pr=r,vt=!0,dn=null,ti=!1,e!==null&&sp(r,e),r=ml(r,s),r.flags|=4096;return r}return e=Oi(e.child,{mode:s.mode,children:s.children}),e.ref=r.ref,r.child=e,e.return=r,e}function gl(e,r){var n=r.ref;if(n===null)e!==null&&e.ref!==null&&(r.flags|=4194816);else{if(typeof n!="function"&&typeof n!="object")throw Error(a(284));(e===null||e.ref!==n)&&(r.flags|=4194816)}}function zu(e,r,n,s,c){return Jn(r),n=yu(e,r,n,s,void 0,c),s=xu(),e!==null&&!tr?(Su(e,r,c),Vi(e,r,c)):(vt&&s&&eu(r),r.flags|=1,gr(e,r,n,c),r.child)}function Sm(e,r,n,s,c,d){return Jn(r),r.updateQueue=null,n=Ep(r,s,n,c),Mp(e),s=xu(),e!==null&&!tr?(Su(e,r,d),Vi(e,r,d)):(vt&&s&&eu(r),r.flags|=1,gr(e,r,n,d),r.child)}function bm(e,r,n,s,c){if(Jn(r),r.stateNode===null){var d=Pa,g=n.contextType;typeof g=="object"&&g!==null&&(d=mr(g)),d=new n(s,d),r.memoizedState=d.state!==null&&d.state!==void 0?d.state:null,d.updater=Ou,r.stateNode=d,d._reactInternals=r,d=r.stateNode,d.props=s,d.state=r.memoizedState,d.refs={},du(r),g=n.contextType,d.context=typeof g=="object"&&g!==null?mr(g):Pa,d.state=r.memoizedState,g=n.getDerivedStateFromProps,typeof g=="function"&&(Nu(r,n,g,s),d.state=r.memoizedState),typeof n.getDerivedStateFromProps=="function"||typeof d.getSnapshotBeforeUpdate=="function"||typeof d.UNSAFE_componentWillMount!="function"&&typeof d.componentWillMount!="function"||(g=d.state,typeof d.componentWillMount=="function"&&d.componentWillMount(),typeof d.UNSAFE_componentWillMount=="function"&&d.UNSAFE_componentWillMount(),g!==d.state&&Ou.enqueueReplaceState(d,d.state,null),Ys(r,s,d,c),Xs(),d.state=r.memoizedState),typeof d.componentDidMount=="function"&&(r.flags|=4194308),s=!0}else if(e===null){d=r.stateNode;var M=r.memoizedProps,z=aa(n,M);d.props=z;var J=d.context,de=n.contextType;g=Pa,typeof de=="object"&&de!==null&&(g=mr(de));var me=n.getDerivedStateFromProps;de=typeof me=="function"||typeof d.getSnapshotBeforeUpdate=="function",M=r.pendingProps!==M,de||typeof d.UNSAFE_componentWillReceiveProps!="function"&&typeof d.componentWillReceiveProps!="function"||(M||J!==g)&&lm(r,d,s,g),pn=!1;var re=r.memoizedState;d.state=re,Ys(r,s,d,c),Xs(),J=r.memoizedState,M||re!==J||pn?(typeof me=="function"&&(Nu(r,n,me,s),J=r.memoizedState),(z=pn||om(r,n,z,s,re,J,g))?(de||typeof d.UNSAFE_componentWillMount!="function"&&typeof d.componentWillMount!="function"||(typeof d.componentWillMount=="function"&&d.componentWillMount(),typeof d.UNSAFE_componentWillMount=="function"&&d.UNSAFE_componentWillMount()),typeof d.componentDidMount=="function"&&(r.flags|=4194308)):(typeof d.componentDidMount=="function"&&(r.flags|=4194308),r.memoizedProps=s,r.memoizedState=J),d.props=s,d.state=J,d.context=g,s=z):(typeof d.componentDidMount=="function"&&(r.flags|=4194308),s=!1)}else{d=r.stateNode,hu(e,r),g=r.memoizedProps,de=aa(n,g),d.props=de,me=r.pendingProps,re=d.context,J=n.contextType,z=Pa,typeof J=="object"&&J!==null&&(z=mr(J)),M=n.getDerivedStateFromProps,(J=typeof M=="function"||typeof d.getSnapshotBeforeUpdate=="function")||typeof d.UNSAFE_componentWillReceiveProps!="function"&&typeof d.componentWillReceiveProps!="function"||(g!==me||re!==z)&&lm(r,d,s,z),pn=!1,re=r.memoizedState,d.state=re,Ys(r,s,d,c),Xs();var oe=r.memoizedState;g!==me||re!==oe||pn||e!==null&&e.dependencies!==null&&Ko(e.dependencies)?(typeof M=="function"&&(Nu(r,n,M,s),oe=r.memoizedState),(de=pn||om(r,n,de,s,re,oe,z)||e!==null&&e.dependencies!==null&&Ko(e.dependencies))?(J||typeof d.UNSAFE_componentWillUpdate!="function"&&typeof d.componentWillUpdate!="function"||(typeof d.componentWillUpdate=="function"&&d.componentWillUpdate(s,oe,z),typeof d.UNSAFE_componentWillUpdate=="function"&&d.UNSAFE_componentWillUpdate(s,oe,z)),typeof d.componentDidUpdate=="function"&&(r.flags|=4),typeof d.getSnapshotBeforeUpdate=="function"&&(r.flags|=1024)):(typeof d.componentDidUpdate!="function"||g===e.memoizedProps&&re===e.memoizedState||(r.flags|=4),typeof d.getSnapshotBeforeUpdate!="function"||g===e.memoizedProps&&re===e.memoizedState||(r.flags|=1024),r.memoizedProps=s,r.memoizedState=oe),d.props=s,d.state=oe,d.context=z,s=de):(typeof d.componentDidUpdate!="function"||g===e.memoizedProps&&re===e.memoizedState||(r.flags|=4),typeof d.getSnapshotBeforeUpdate!="function"||g===e.memoizedProps&&re===e.memoizedState||(r.flags|=1024),s=!1)}return d=s,gl(e,r),s=(r.flags&128)!==0,d||s?(d=r.stateNode,n=s&&typeof n.getDerivedStateFromError!="function"?null:d.render(),r.flags|=1,e!==null&&s?(r.child=ia(r,e.child,null,c),r.child=ia(r,null,n,c)):gr(e,r,n,c),r.memoizedState=d.state,e=r.child):e=Vi(e,r,c),e}function Mm(e,r,n,s){return Kn(),r.flags|=256,gr(e,r,n,s),r.child}var Bu={dehydrated:null,treeContext:null,retryLane:0,hydrationErrors:null};function Hu(e){return{baseLanes:e,cachePool:hp()}}function Vu(e,r,n){return e=e!==null?e.childLanes&~n:0,r&&(e|=Xr),e}function Em(e,r,n){var s=r.pendingProps,c=!1,d=(r.flags&128)!==0,g;if((g=d)||(g=e!==null&&e.memoizedState===null?!1:(Kt.current&2)!==0),g&&(c=!0,r.flags&=-129),g=(r.flags&32)!==0,r.flags&=-33,e===null){if(vt){if(c?vn(r):_n(),(e=Bt)?(e=Ug(e,ti),e=e!==null&&e.data!=="&"?e:null,e!==null&&(r.memoizedState={dehydrated:e,treeContext:un!==null?{id:Mi,overflow:Ei}:null,retryLane:536870912,hydrationErrors:null},n=ip(e),n.return=r,r.child=n,pr=r,Bt=null)):e=null,e===null)throw hn(r);return Ed(e)?r.lanes=32:r.lanes=536870912,null}var M=s.children;return s=s.fallback,c?(_n(),c=r.mode,M=vl({mode:"hidden",children:M},c),s=$n(s,c,n,null),M.return=r,s.return=r,M.sibling=s,r.child=M,s=r.child,s.memoizedState=Hu(n),s.childLanes=Vu(e,g,n),r.memoizedState=Bu,Zs(null,s)):(vn(r),Gu(r,M))}var z=e.memoizedState;if(z!==null&&(M=z.dehydrated,M!==null)){if(d)r.flags&256?(vn(r),r.flags&=-257,r=Wu(e,r,n)):r.memoizedState!==null?(_n(),r.child=e.child,r.flags|=128,r=null):(_n(),M=s.fallback,c=r.mode,s=vl({mode:"visible",children:s.children},c),M=$n(M,c,n,null),M.flags|=2,s.return=r,M.return=r,s.sibling=M,r.child=s,ia(r,e.child,null,n),s=r.child,s.memoizedState=Hu(n),s.childLanes=Vu(e,g,n),r.memoizedState=Bu,r=Zs(null,s));else if(vn(r),Ed(M)){if(g=M.nextSibling&&M.nextSibling.dataset,g)var J=g.dgst;g=J,s=Error(a(419)),s.stack="",s.digest=g,Bs({value:s,source:null,stack:null}),r=Wu(e,r,n)}else if(tr||Ia(e,r,n,!1),g=(n&e.childLanes)!==0,tr||g){if(g=zt,g!==null&&(s=bi(g,n),s!==0&&s!==z.retryLane))throw z.retryLane=s,Qn(e,s),kr(g,e,s),Fu;Md(M)||Tl(),r=Wu(e,r,n)}else Md(M)?(r.flags|=192,r.child=e.child,r=null):(e=z.treeContext,Bt=ri(M.nextSibling),pr=r,vt=!0,dn=null,ti=!1,e!==null&&sp(r,e),r=Gu(r,s.children),r.flags|=4096);return r}return c?(_n(),M=s.fallback,c=r.mode,z=e.child,J=z.sibling,s=Oi(z,{mode:"hidden",children:s.children}),s.subtreeFlags=z.subtreeFlags&65011712,J!==null?M=Oi(J,M):(M=$n(M,c,n,null),M.flags|=2),M.return=r,s.return=r,s.sibling=M,r.child=s,Zs(null,s),s=r.child,M=e.child.memoizedState,M===null?M=Hu(n):(c=M.cachePool,c!==null?(z=Jt._currentValue,c=c.parent!==z?{parent:z,pool:z}:c):c=hp(),M={baseLanes:M.baseLanes|n,cachePool:c}),s.memoizedState=M,s.childLanes=Vu(e,g,n),r.memoizedState=Bu,Zs(e.child,s)):(vn(r),n=e.child,e=n.sibling,n=Oi(n,{mode:"visible",children:s.children}),n.return=r,n.sibling=null,e!==null&&(g=r.deletions,g===null?(r.deletions=[e],r.flags|=16):g.push(e)),r.child=n,r.memoizedState=null,n)}function Gu(e,r){return r=vl({mode:"visible",children:r},e.mode),r.return=e,e.child=r}function vl(e,r){return e=Vr(22,e,null,r),e.lanes=0,e}function Wu(e,r,n){return ia(r,e.child,null,n),e=Gu(r,r.pendingProps.children),e.flags|=2,r.memoizedState=null,e}function wm(e,r,n){e.lanes|=r;var s=e.alternate;s!==null&&(s.lanes|=r),au(e.return,r,n)}function ju(e,r,n,s,c,d){var g=e.memoizedState;g===null?e.memoizedState={isBackwards:r,rendering:null,renderingStartTime:0,last:s,tail:n,tailMode:c,treeForkCount:d}:(g.isBackwards=r,g.rendering=null,g.renderingStartTime=0,g.last=s,g.tail=n,g.tailMode=c,g.treeForkCount=d)}function Tm(e,r,n){var s=r.pendingProps,c=s.revealOrder,d=s.tail;s=s.children;var g=Kt.current,M=(g&2)!==0;if(M?(g=g&1|2,r.flags|=128):g&=1,xe(Kt,g),gr(e,r,s,n),s=vt?zs:0,!M&&e!==null&&(e.flags&128)!==0)e:for(e=r.child;e!==null;){if(e.tag===13)e.memoizedState!==null&&wm(e,n,r);else if(e.tag===19)wm(e,n,r);else if(e.child!==null){e.child.return=e,e=e.child;continue}if(e===r)break e;for(;e.sibling===null;){if(e.return===null||e.return===r)break e;e=e.return}e.sibling.return=e.return,e=e.sibling}switch(c){case"forwards":for(n=r.child,c=null;n!==null;)e=n.alternate,e!==null&&al(e)===null&&(c=n),n=n.sibling;n=c,n===null?(c=r.child,r.child=null):(c=n.sibling,n.sibling=null),ju(r,!1,c,n,d,s);break;case"backwards":case"unstable_legacy-backwards":for(n=null,c=r.child,r.child=null;c!==null;){if(e=c.alternate,e!==null&&al(e)===null){r.child=c;break}e=c.sibling,c.sibling=n,n=c,c=e}ju(r,!0,n,null,d,s);break;case"together":ju(r,!1,null,null,void 0,s);break;default:r.memoizedState=null}return r.child}function Vi(e,r,n){if(e!==null&&(r.dependencies=e.dependencies),Sn|=r.lanes,(n&r.childLanes)===0)if(e!==null){if(Ia(e,r,n,!1),(n&r.childLanes)===0)return null}else return null;if(e!==null&&r.child!==e.child)throw Error(a(153));if(r.child!==null){for(e=r.child,n=Oi(e,e.pendingProps),r.child=n,n.return=r;e.sibling!==null;)e=e.sibling,n=n.sibling=Oi(e,e.pendingProps),n.return=r;n.sibling=null}return r.child}function Xu(e,r){return(e.lanes&r)!==0?!0:(e=e.dependencies,!!(e!==null&&Ko(e)))}function ry(e,r,n){switch(r.tag){case 3:ke(r,r.stateNode.containerInfo),fn(r,Jt,e.memoizedState.cache),Kn();break;case 27:case 5:tt(r);break;case 4:ke(r,r.stateNode.containerInfo);break;case 10:fn(r,r.type,r.memoizedProps.value);break;case 31:if(r.memoizedState!==null)return r.flags|=128,vu(r),null;break;case 13:var s=r.memoizedState;if(s!==null)return s.dehydrated!==null?(vn(r),r.flags|=128,null):(n&r.child.childLanes)!==0?Em(e,r,n):(vn(r),e=Vi(e,r,n),e!==null?e.sibling:null);vn(r);break;case 19:var c=(e.flags&128)!==0;if(s=(n&r.childLanes)!==0,s||(Ia(e,r,n,!1),s=(n&r.childLanes)!==0),c){if(s)return Tm(e,r,n);r.flags|=128}if(c=r.memoizedState,c!==null&&(c.rendering=null,c.tail=null,c.lastEffect=null),xe(Kt,Kt.current),s)break;return null;case 22:return r.lanes=0,_m(e,r,n,r.pendingProps);case 24:fn(r,Jt,e.memoizedState.cache)}return Vi(e,r,n)}function Rm(e,r,n){if(e!==null)if(e.memoizedProps!==r.pendingProps)tr=!0;else{if(!Xu(e,n)&&(r.flags&128)===0)return tr=!1,ry(e,r,n);tr=(e.flags&131072)!==0}else tr=!1,vt&&(r.flags&1048576)!==0&&ap(r,zs,r.index);switch(r.lanes=0,r.tag){case 16:e:{var s=r.pendingProps;if(e=ta(r.elementType),r.type=e,typeof e=="function")Kc(e)?(s=aa(e,s),r.tag=1,r=bm(null,r,e,s,n)):(r.tag=0,r=zu(null,r,e,s,n));else{if(e!=null){var c=e.$$typeof;if(c===C){r.tag=11,r=mm(null,r,e,s,n);break e}else if(c===I){r.tag=14,r=gm(null,r,e,s,n);break e}}throw r=ce(e)||e,Error(a(306,r,""))}}return r;case 0:return zu(e,r,r.type,r.pendingProps,n);case 1:return s=r.type,c=aa(s,r.pendingProps),bm(e,r,s,c,n);case 3:e:{if(ke(r,r.stateNode.containerInfo),e===null)throw Error(a(387));s=r.pendingProps;var d=r.memoizedState;c=d.element,hu(e,r),Ys(r,s,null,n);var g=r.memoizedState;if(s=g.cache,fn(r,Jt,s),s!==d.cache&&su(r,[Jt],n,!0),Xs(),s=g.element,d.isDehydrated)if(d={element:s,isDehydrated:!1,cache:g.cache},r.updateQueue.baseState=d,r.memoizedState=d,r.flags&256){r=Mm(e,r,s,n);break e}else if(s!==c){c=Zr(Error(a(424)),r),Bs(c),r=Mm(e,r,s,n);break e}else{switch(e=r.stateNode.containerInfo,e.nodeType){case 9:e=e.body;break;default:e=e.nodeName==="HTML"?e.ownerDocument.body:e}for(Bt=ri(e.firstChild),pr=r,vt=!0,dn=null,ti=!0,n=_p(r,null,s,n),r.child=n;n;)n.flags=n.flags&-3|4096,n=n.sibling}else{if(Kn(),s===c){r=Vi(e,r,n);break e}gr(e,r,s,n)}r=r.child}return r;case 26:return gl(e,r),e===null?(n=Fg(r.type,null,r.pendingProps,null))?r.memoizedState=n:vt||(n=r.type,e=r.pendingProps,s=Dl(Me.current).createElement(n),s[qt]=r,s[dr]=e,vr(s,n,e),W(s),r.stateNode=s):r.memoizedState=Fg(r.type,e.memoizedProps,r.pendingProps,e.memoizedState),null;case 27:return tt(r),e===null&&vt&&(s=r.stateNode=Ng(r.type,r.pendingProps,Me.current),pr=r,ti=!0,c=Bt,Tn(r.type)?(wd=c,Bt=ri(s.firstChild)):Bt=c),gr(e,r,r.pendingProps.children,n),gl(e,r),e===null&&(r.flags|=4194304),r.child;case 5:return e===null&&vt&&((c=s=Bt)&&(s=Uy(s,r.type,r.pendingProps,ti),s!==null?(r.stateNode=s,pr=r,Bt=ri(s.firstChild),ti=!1,c=!0):c=!1),c||hn(r)),tt(r),c=r.type,d=r.pendingProps,g=e!==null?e.memoizedProps:null,s=d.children,xd(c,d)?s=null:g!==null&&xd(c,g)&&(r.flags|=32),r.memoizedState!==null&&(c=yu(e,r,Y0,null,null,n),po._currentValue=c),gl(e,r),gr(e,r,s,n),r.child;case 6:return e===null&&vt&&((e=n=Bt)&&(n=Dy(n,r.pendingProps,ti),n!==null?(r.stateNode=n,pr=r,Bt=null,e=!0):e=!1),e||hn(r)),null;case 13:return Em(e,r,n);case 4:return ke(r,r.stateNode.containerInfo),s=r.pendingProps,e===null?r.child=ia(r,null,s,n):gr(e,r,s,n),r.child;case 11:return mm(e,r,r.type,r.pendingProps,n);case 7:return gr(e,r,r.pendingProps,n),r.child;case 8:return gr(e,r,r.pendingProps.children,n),r.child;case 12:return gr(e,r,r.pendingProps.children,n),r.child;case 10:return s=r.pendingProps,fn(r,r.type,s.value),gr(e,r,s.children,n),r.child;case 9:return c=r.type._context,s=r.pendingProps.children,Jn(r),c=mr(c),s=s(c),r.flags|=1,gr(e,r,s,n),r.child;case 14:return gm(e,r,r.type,r.pendingProps,n);case 15:return vm(e,r,r.type,r.pendingProps,n);case 19:return Tm(e,r,n);case 31:return ty(e,r,n);case 22:return _m(e,r,n,r.pendingProps);case 24:return Jn(r),s=mr(Jt),e===null?(c=cu(),c===null&&(c=zt,d=ou(),c.pooledCache=d,d.refCount++,d!==null&&(c.pooledCacheLanes|=n),c=d),r.memoizedState={parent:s,cache:c},du(r),fn(r,Jt,c)):((e.lanes&n)!==0&&(hu(e,r),Ys(r,null,null,n),Xs()),c=e.memoizedState,d=r.memoizedState,c.parent!==s?(c={parent:s,cache:s},r.memoizedState=c,r.lanes===0&&(r.memoizedState=r.updateQueue.baseState=c),fn(r,Jt,s)):(s=d.cache,fn(r,Jt,s),s!==c.cache&&su(r,[Jt],n,!0))),gr(e,r,r.pendingProps.children,n),r.child;case 29:throw r.pendingProps}throw Error(a(156,r.tag))}function Gi(e){e.flags|=4}function Yu(e,r,n,s,c){if((r=(e.mode&32)!==0)&&(r=!1),r){if(e.flags|=16777216,(c&335544128)===c)if(e.stateNode.complete)e.flags|=8192;else if(eg())e.flags|=8192;else throw ra=tl,uu}else e.flags&=-16777217}function Cm(e,r){if(r.type!=="stylesheet"||(r.state.loading&4)!==0)e.flags&=-16777217;else if(e.flags|=16777216,!Gg(r))if(eg())e.flags|=8192;else throw ra=tl,uu}function _l(e,r){r!==null&&(e.flags|=4),e.flags&16384&&(r=e.tag!==22?nr():536870912,e.lanes|=r,Xa|=r)}function Js(e,r){if(!vt)switch(e.tailMode){case"hidden":r=e.tail;for(var n=null;r!==null;)r.alternate!==null&&(n=r),r=r.sibling;n===null?e.tail=null:n.sibling=null;break;case"collapsed":n=e.tail;for(var s=null;n!==null;)n.alternate!==null&&(s=n),n=n.sibling;s===null?r||e.tail===null?e.tail=null:e.tail.sibling=null:s.sibling=null}}function Ht(e){var r=e.alternate!==null&&e.alternate.child===e.child,n=0,s=0;if(r)for(var c=e.child;c!==null;)n|=c.lanes|c.childLanes,s|=c.subtreeFlags&65011712,s|=c.flags&65011712,c.return=e,c=c.sibling;else for(c=e.child;c!==null;)n|=c.lanes|c.childLanes,s|=c.subtreeFlags,s|=c.flags,c.return=e,c=c.sibling;return e.subtreeFlags|=s,e.childLanes=n,r}function iy(e,r,n){var s=r.pendingProps;switch(tu(r),r.tag){case 16:case 15:case 0:case 11:case 7:case 8:case 12:case 9:case 14:return Ht(r),null;case 1:return Ht(r),null;case 3:return n=r.stateNode,s=null,e!==null&&(s=e.memoizedState.cache),r.memoizedState.cache!==s&&(r.flags|=2048),zi(Jt),Fe(),n.pendingContext&&(n.context=n.pendingContext,n.pendingContext=null),(e===null||e.child===null)&&(Da(r)?Gi(r):e===null||e.memoizedState.isDehydrated&&(r.flags&256)===0||(r.flags|=1024,iu())),Ht(r),null;case 26:var c=r.type,d=r.memoizedState;return e===null?(Gi(r),d!==null?(Ht(r),Cm(r,d)):(Ht(r),Yu(r,c,null,s,n))):d?d!==e.memoizedState?(Gi(r),Ht(r),Cm(r,d)):(Ht(r),r.flags&=-16777217):(e=e.memoizedProps,e!==s&&Gi(r),Ht(r),Yu(r,c,e,s,n)),null;case 27:if(Lt(r),n=Me.current,c=r.type,e!==null&&r.stateNode!=null)e.memoizedProps!==s&&Gi(r);else{if(!s){if(r.stateNode===null)throw Error(a(166));return Ht(r),null}e=Q.current,Da(r)?op(r):(e=Ng(c,s,n),r.stateNode=e,Gi(r))}return Ht(r),null;case 5:if(Lt(r),c=r.type,e!==null&&r.stateNode!=null)e.memoizedProps!==s&&Gi(r);else{if(!s){if(r.stateNode===null)throw Error(a(166));return Ht(r),null}if(d=Q.current,Da(r))op(r);else{var g=Dl(Me.current);switch(d){case 1:d=g.createElementNS("http://www.w3.org/2000/svg",c);break;case 2:d=g.createElementNS("http://www.w3.org/1998/Math/MathML",c);break;default:switch(c){case"svg":d=g.createElementNS("http://www.w3.org/2000/svg",c);break;case"math":d=g.createElementNS("http://www.w3.org/1998/Math/MathML",c);break;case"script":d=g.createElement("div"),d.innerHTML="<script><\/script>",d=d.removeChild(d.firstChild);break;case"select":d=typeof s.is=="string"?g.createElement("select",{is:s.is}):g.createElement("select"),s.multiple?d.multiple=!0:s.size&&(d.size=s.size);break;default:d=typeof s.is=="string"?g.createElement(c,{is:s.is}):g.createElement(c)}}d[qt]=r,d[dr]=s;e:for(g=r.child;g!==null;){if(g.tag===5||g.tag===6)d.appendChild(g.stateNode);else if(g.tag!==4&&g.tag!==27&&g.child!==null){g.child.return=g,g=g.child;continue}if(g===r)break e;for(;g.sibling===null;){if(g.return===null||g.return===r)break e;g=g.return}g.sibling.return=g.return,g=g.sibling}r.stateNode=d;e:switch(vr(d,c,s),c){case"button":case"input":case"select":case"textarea":s=!!s.autoFocus;break e;case"img":s=!0;break e;default:s=!1}s&&Gi(r)}}return Ht(r),Yu(r,r.type,e===null?null:e.memoizedProps,r.pendingProps,n),null;case 6:if(e&&r.stateNode!=null)e.memoizedProps!==s&&Gi(r);else{if(typeof s!="string"&&r.stateNode===null)throw Error(a(166));if(e=Me.current,Da(r)){if(e=r.stateNode,n=r.memoizedProps,s=null,c=pr,c!==null)switch(c.tag){case 27:case 5:s=c.memoizedProps}e[qt]=r,e=!!(e.nodeValue===n||s!==null&&s.suppressHydrationWarning===!0||Eg(e.nodeValue,n)),e||hn(r,!0)}else e=Dl(e).createTextNode(s),e[qt]=r,r.stateNode=e}return Ht(r),null;case 31:if(n=r.memoizedState,e===null||e.memoizedState!==null){if(s=Da(r),n!==null){if(e===null){if(!s)throw Error(a(318));if(e=r.memoizedState,e=e!==null?e.dehydrated:null,!e)throw Error(a(557));e[qt]=r}else Kn(),(r.flags&128)===0&&(r.memoizedState=null),r.flags|=4;Ht(r),e=!1}else n=iu(),e!==null&&e.memoizedState!==null&&(e.memoizedState.hydrationErrors=n),e=!0;if(!e)return r.flags&256?(Wr(r),r):(Wr(r),null);if((r.flags&128)!==0)throw Error(a(558))}return Ht(r),null;case 13:if(s=r.memoizedState,e===null||e.memoizedState!==null&&e.memoizedState.dehydrated!==null){if(c=Da(r),s!==null&&s.dehydrated!==null){if(e===null){if(!c)throw Error(a(318));if(c=r.memoizedState,c=c!==null?c.dehydrated:null,!c)throw Error(a(317));c[qt]=r}else Kn(),(r.flags&128)===0&&(r.memoizedState=null),r.flags|=4;Ht(r),c=!1}else c=iu(),e!==null&&e.memoizedState!==null&&(e.memoizedState.hydrationErrors=c),c=!0;if(!c)return r.flags&256?(Wr(r),r):(Wr(r),null)}return Wr(r),(r.flags&128)!==0?(r.lanes=n,r):(n=s!==null,e=e!==null&&e.memoizedState!==null,n&&(s=r.child,c=null,s.alternate!==null&&s.alternate.memoizedState!==null&&s.alternate.memoizedState.cachePool!==null&&(c=s.alternate.memoizedState.cachePool.pool),d=null,s.memoizedState!==null&&s.memoizedState.cachePool!==null&&(d=s.memoizedState.cachePool.pool),d!==c&&(s.flags|=2048)),n!==e&&n&&(r.child.flags|=8192),_l(r,r.updateQueue),Ht(r),null);case 4:return Fe(),e===null&&md(r.stateNode.containerInfo),Ht(r),null;case 10:return zi(r.type),Ht(r),null;case 19:if(ie(Kt),s=r.memoizedState,s===null)return Ht(r),null;if(c=(r.flags&128)!==0,d=s.rendering,d===null)if(c)Js(s,!1);else{if($t!==0||e!==null&&(e.flags&128)!==0)for(e=r.child;e!==null;){if(d=al(e),d!==null){for(r.flags|=128,Js(s,!1),e=d.updateQueue,r.updateQueue=e,_l(r,e),r.subtreeFlags=0,e=n,n=r.child;n!==null;)rp(n,e),n=n.sibling;return xe(Kt,Kt.current&1|2),vt&&ki(r,s.treeForkCount),r.child}e=e.sibling}s.tail!==null&&he()>Ml&&(r.flags|=128,c=!0,Js(s,!1),r.lanes=4194304)}else{if(!c)if(e=al(d),e!==null){if(r.flags|=128,c=!0,e=e.updateQueue,r.updateQueue=e,_l(r,e),Js(s,!0),s.tail===null&&s.tailMode==="hidden"&&!d.alternate&&!vt)return Ht(r),null}else 2*he()-s.renderingStartTime>Ml&&n!==536870912&&(r.flags|=128,c=!0,Js(s,!1),r.lanes=4194304);s.isBackwards?(d.sibling=r.child,r.child=d):(e=s.last,e!==null?e.sibling=d:r.child=d,s.last=d)}return s.tail!==null?(e=s.tail,s.rendering=e,s.tail=e.sibling,s.renderingStartTime=he(),e.sibling=null,n=Kt.current,xe(Kt,c?n&1|2:n&1),vt&&ki(r,s.treeForkCount),e):(Ht(r),null);case 22:case 23:return Wr(r),gu(),s=r.memoizedState!==null,e!==null?e.memoizedState!==null!==s&&(r.flags|=8192):s&&(r.flags|=8192),s?(n&536870912)!==0&&(r.flags&128)===0&&(Ht(r),r.subtreeFlags&6&&(r.flags|=8192)):Ht(r),n=r.updateQueue,n!==null&&_l(r,n.retryQueue),n=null,e!==null&&e.memoizedState!==null&&e.memoizedState.cachePool!==null&&(n=e.memoizedState.cachePool.pool),s=null,r.memoizedState!==null&&r.memoizedState.cachePool!==null&&(s=r.memoizedState.cachePool.pool),s!==n&&(r.flags|=2048),e!==null&&ie(ea),null;case 24:return n=null,e!==null&&(n=e.memoizedState.cache),r.memoizedState.cache!==n&&(r.flags|=2048),zi(Jt),Ht(r),null;case 25:return null;case 30:return null}throw Error(a(156,r.tag))}function ny(e,r){switch(tu(r),r.tag){case 1:return e=r.flags,e&65536?(r.flags=e&-65537|128,r):null;case 3:return zi(Jt),Fe(),e=r.flags,(e&65536)!==0&&(e&128)===0?(r.flags=e&-65537|128,r):null;case 26:case 27:case 5:return Lt(r),null;case 31:if(r.memoizedState!==null){if(Wr(r),r.alternate===null)throw Error(a(340));Kn()}return e=r.flags,e&65536?(r.flags=e&-65537|128,r):null;case 13:if(Wr(r),e=r.memoizedState,e!==null&&e.dehydrated!==null){if(r.alternate===null)throw Error(a(340));Kn()}return e=r.flags,e&65536?(r.flags=e&-65537|128,r):null;case 19:return ie(Kt),null;case 4:return Fe(),null;case 10:return zi(r.type),null;case 22:case 23:return Wr(r),gu(),e!==null&&ie(ea),e=r.flags,e&65536?(r.flags=e&-65537|128,r):null;case 24:return zi(Jt),null;case 25:return null;default:return null}}function Am(e,r){switch(tu(r),r.tag){case 3:zi(Jt),Fe();break;case 26:case 27:case 5:Lt(r);break;case 4:Fe();break;case 31:r.memoizedState!==null&&Wr(r);break;case 13:Wr(r);break;case 19:ie(Kt);break;case 10:zi(r.type);break;case 22:case 23:Wr(r),gu(),e!==null&&ie(ea);break;case 24:zi(Jt)}}function eo(e,r){try{var n=r.updateQueue,s=n!==null?n.lastEffect:null;if(s!==null){var c=s.next;n=c;do{if((n.tag&e)===e){s=void 0;var d=n.create,g=n.inst;s=d(),g.destroy=s}n=n.next}while(n!==c)}}catch(M){Pt(r,r.return,M)}}function yn(e,r,n){try{var s=r.updateQueue,c=s!==null?s.lastEffect:null;if(c!==null){var d=c.next;s=d;do{if((s.tag&e)===e){var g=s.inst,M=g.destroy;if(M!==void 0){g.destroy=void 0,c=r;var z=n,J=M;try{J()}catch(de){Pt(c,z,de)}}}s=s.next}while(s!==d)}}catch(de){Pt(r,r.return,de)}}function Pm(e){var r=e.updateQueue;if(r!==null){var n=e.stateNode;try{xp(r,n)}catch(s){Pt(e,e.return,s)}}}function Lm(e,r,n){n.props=aa(e.type,e.memoizedProps),n.state=e.memoizedState;try{n.componentWillUnmount()}catch(s){Pt(e,r,s)}}function to(e,r){try{var n=e.ref;if(n!==null){switch(e.tag){case 26:case 27:case 5:var s=e.stateNode;break;case 30:s=e.stateNode;break;default:s=e.stateNode}typeof n=="function"?e.refCleanup=n(s):n.current=s}}catch(c){Pt(e,r,c)}}function wi(e,r){var n=e.ref,s=e.refCleanup;if(n!==null)if(typeof s=="function")try{s()}catch(c){Pt(e,r,c)}finally{e.refCleanup=null,e=e.alternate,e!=null&&(e.refCleanup=null)}else if(typeof n=="function")try{n(null)}catch(c){Pt(e,r,c)}else n.current=null}function Um(e){var r=e.type,n=e.memoizedProps,s=e.stateNode;try{e:switch(r){case"button":case"input":case"select":case"textarea":n.autoFocus&&s.focus();break e;case"img":n.src?s.src=n.src:n.srcSet&&(s.srcset=n.srcSet)}}catch(c){Pt(e,e.return,c)}}function qu(e,r,n){try{var s=e.stateNode;Ty(s,e.type,n,r),s[dr]=r}catch(c){Pt(e,e.return,c)}}function Dm(e){return e.tag===5||e.tag===3||e.tag===26||e.tag===27&&Tn(e.type)||e.tag===4}function Qu(e){e:for(;;){for(;e.sibling===null;){if(e.return===null||Dm(e.return))return null;e=e.return}for(e.sibling.return=e.return,e=e.sibling;e.tag!==5&&e.tag!==6&&e.tag!==18;){if(e.tag===27&&Tn(e.type)||e.flags&2||e.child===null||e.tag===4)continue e;e.child.return=e,e=e.child}if(!(e.flags&2))return e.stateNode}}function $u(e,r,n){var s=e.tag;if(s===5||s===6)e=e.stateNode,r?(n.nodeType===9?n.body:n.nodeName==="HTML"?n.ownerDocument.body:n).insertBefore(e,r):(r=n.nodeType===9?n.body:n.nodeName==="HTML"?n.ownerDocument.body:n,r.appendChild(e),n=n._reactRootContainer,n!=null||r.onclick!==null||(r.onclick=Ii));else if(s!==4&&(s===27&&Tn(e.type)&&(n=e.stateNode,r=null),e=e.child,e!==null))for($u(e,r,n),e=e.sibling;e!==null;)$u(e,r,n),e=e.sibling}function yl(e,r,n){var s=e.tag;if(s===5||s===6)e=e.stateNode,r?n.insertBefore(e,r):n.appendChild(e);else if(s!==4&&(s===27&&Tn(e.type)&&(n=e.stateNode),e=e.child,e!==null))for(yl(e,r,n),e=e.sibling;e!==null;)yl(e,r,n),e=e.sibling}function Im(e){var r=e.stateNode,n=e.memoizedProps;try{for(var s=e.type,c=r.attributes;c.length;)r.removeAttributeNode(c[0]);vr(r,s,n),r[qt]=e,r[dr]=n}catch(d){Pt(e,e.return,d)}}var Wi=!1,rr=!1,Ku=!1,Nm=typeof WeakSet=="function"?WeakSet:Set,lr=null;function ay(e,r){if(e=e.containerInfo,_d=Bl,e=Yf(e),Wc(e)){if("selectionStart"in e)var n={start:e.selectionStart,end:e.selectionEnd};else e:{n=(n=e.ownerDocument)&&n.defaultView||window;var s=n.getSelection&&n.getSelection();if(s&&s.rangeCount!==0){n=s.anchorNode;var c=s.anchorOffset,d=s.focusNode;s=s.focusOffset;try{n.nodeType,d.nodeType}catch{n=null;break e}var g=0,M=-1,z=-1,J=0,de=0,me=e,re=null;t:for(;;){for(var oe;me!==n||c!==0&&me.nodeType!==3||(M=g+c),me!==d||s!==0&&me.nodeType!==3||(z=g+s),me.nodeType===3&&(g+=me.nodeValue.length),(oe=me.firstChild)!==null;)re=me,me=oe;for(;;){if(me===e)break t;if(re===n&&++J===c&&(M=g),re===d&&++de===s&&(z=g),(oe=me.nextSibling)!==null)break;me=re,re=me.parentNode}me=oe}n=M===-1||z===-1?null:{start:M,end:z}}else n=null}n=n||{start:0,end:0}}else n=null;for(yd={focusedElem:e,selectionRange:n},Bl=!1,lr=r;lr!==null;)if(r=lr,e=r.child,(r.subtreeFlags&1028)!==0&&e!==null)e.return=r,lr=e;else for(;lr!==null;){switch(r=lr,d=r.alternate,e=r.flags,r.tag){case 0:if((e&4)!==0&&(e=r.updateQueue,e=e!==null?e.events:null,e!==null))for(n=0;n<e.length;n++)c=e[n],c.ref.impl=c.nextImpl;break;case 11:case 15:break;case 1:if((e&1024)!==0&&d!==null){e=void 0,n=r,c=d.memoizedProps,d=d.memoizedState,s=n.stateNode;try{var Oe=aa(n.type,c);e=s.getSnapshotBeforeUpdate(Oe,d),s.__reactInternalSnapshotBeforeUpdate=e}catch(Qe){Pt(n,n.return,Qe)}}break;case 3:if((e&1024)!==0){if(e=r.stateNode.containerInfo,n=e.nodeType,n===9)bd(e);else if(n===1)switch(e.nodeName){case"HEAD":case"HTML":case"BODY":bd(e);break;default:e.textContent=""}}break;case 5:case 26:case 27:case 6:case 4:case 17:break;default:if((e&1024)!==0)throw Error(a(163))}if(e=r.sibling,e!==null){e.return=r.return,lr=e;break}lr=r.return}}function Om(e,r,n){var s=n.flags;switch(n.tag){case 0:case 11:case 15:Xi(e,n),s&4&&eo(5,n);break;case 1:if(Xi(e,n),s&4)if(e=n.stateNode,r===null)try{e.componentDidMount()}catch(g){Pt(n,n.return,g)}else{var c=aa(n.type,r.memoizedProps);r=r.memoizedState;try{e.componentDidUpdate(c,r,e.__reactInternalSnapshotBeforeUpdate)}catch(g){Pt(n,n.return,g)}}s&64&&Pm(n),s&512&&to(n,n.return);break;case 3:if(Xi(e,n),s&64&&(e=n.updateQueue,e!==null)){if(r=null,n.child!==null)switch(n.child.tag){case 27:case 5:r=n.child.stateNode;break;case 1:r=n.child.stateNode}try{xp(e,r)}catch(g){Pt(n,n.return,g)}}break;case 27:r===null&&s&4&&Im(n);case 26:case 5:Xi(e,n),r===null&&s&4&&Um(n),s&512&&to(n,n.return);break;case 12:Xi(e,n);break;case 31:Xi(e,n),s&4&&zm(e,n);break;case 13:Xi(e,n),s&4&&Bm(e,n),s&64&&(e=n.memoizedState,e!==null&&(e=e.dehydrated,e!==null&&(n=py.bind(null,n),Iy(e,n))));break;case 22:if(s=n.memoizedState!==null||Wi,!s){r=r!==null&&r.memoizedState!==null||rr,c=Wi;var d=rr;Wi=s,(rr=r)&&!d?Yi(e,n,(n.subtreeFlags&8772)!==0):Xi(e,n),Wi=c,rr=d}break;case 30:break;default:Xi(e,n)}}function km(e){var r=e.alternate;r!==null&&(e.alternate=null,km(r)),e.child=null,e.deletions=null,e.sibling=null,e.tag===5&&(r=e.stateNode,r!==null&&As(r)),e.stateNode=null,e.return=null,e.dependencies=null,e.memoizedProps=null,e.memoizedState=null,e.pendingProps=null,e.stateNode=null,e.updateQueue=null}var Xt=null,Dr=!1;function ji(e,r,n){for(n=n.child;n!==null;)Fm(e,r,n),n=n.sibling}function Fm(e,r,n){if(He&&typeof He.onCommitFiberUnmount=="function")try{He.onCommitFiberUnmount(Xe,n)}catch{}switch(n.tag){case 26:rr||wi(n,r),ji(e,r,n),n.memoizedState?n.memoizedState.count--:n.stateNode&&(n=n.stateNode,n.parentNode.removeChild(n));break;case 27:rr||wi(n,r);var s=Xt,c=Dr;Tn(n.type)&&(Xt=n.stateNode,Dr=!1),ji(e,r,n),uo(n.stateNode),Xt=s,Dr=c;break;case 5:rr||wi(n,r);case 6:if(s=Xt,c=Dr,Xt=null,ji(e,r,n),Xt=s,Dr=c,Xt!==null)if(Dr)try{(Xt.nodeType===9?Xt.body:Xt.nodeName==="HTML"?Xt.ownerDocument.body:Xt).removeChild(n.stateNode)}catch(d){Pt(n,r,d)}else try{Xt.removeChild(n.stateNode)}catch(d){Pt(n,r,d)}break;case 18:Xt!==null&&(Dr?(e=Xt,Pg(e.nodeType===9?e.body:e.nodeName==="HTML"?e.ownerDocument.body:e,n.stateNode),es(e)):Pg(Xt,n.stateNode));break;case 4:s=Xt,c=Dr,Xt=n.stateNode.containerInfo,Dr=!0,ji(e,r,n),Xt=s,Dr=c;break;case 0:case 11:case 14:case 15:yn(2,n,r),rr||yn(4,n,r),ji(e,r,n);break;case 1:rr||(wi(n,r),s=n.stateNode,typeof s.componentWillUnmount=="function"&&Lm(n,r,s)),ji(e,r,n);break;case 21:ji(e,r,n);break;case 22:rr=(s=rr)||n.memoizedState!==null,ji(e,r,n),rr=s;break;default:ji(e,r,n)}}function zm(e,r){if(r.memoizedState===null&&(e=r.alternate,e!==null&&(e=e.memoizedState,e!==null))){e=e.dehydrated;try{es(e)}catch(n){Pt(r,r.return,n)}}}function Bm(e,r){if(r.memoizedState===null&&(e=r.alternate,e!==null&&(e=e.memoizedState,e!==null&&(e=e.dehydrated,e!==null))))try{es(e)}catch(n){Pt(r,r.return,n)}}function sy(e){switch(e.tag){case 31:case 13:case 19:var r=e.stateNode;return r===null&&(r=e.stateNode=new Nm),r;case 22:return e=e.stateNode,r=e._retryCache,r===null&&(r=e._retryCache=new Nm),r;default:throw Error(a(435,e.tag))}}function xl(e,r){var n=sy(e);r.forEach(function(s){if(!n.has(s)){n.add(s);var c=my.bind(null,e,s);s.then(c,c)}})}function Ir(e,r){var n=r.deletions;if(n!==null)for(var s=0;s<n.length;s++){var c=n[s],d=e,g=r,M=g;e:for(;M!==null;){switch(M.tag){case 27:if(Tn(M.type)){Xt=M.stateNode,Dr=!1;break e}break;case 5:Xt=M.stateNode,Dr=!1;break e;case 3:case 4:Xt=M.stateNode.containerInfo,Dr=!0;break e}M=M.return}if(Xt===null)throw Error(a(160));Fm(d,g,c),Xt=null,Dr=!1,d=c.alternate,d!==null&&(d.return=null),c.return=null}if(r.subtreeFlags&13886)for(r=r.child;r!==null;)Hm(r,e),r=r.sibling}var fi=null;function Hm(e,r){var n=e.alternate,s=e.flags;switch(e.tag){case 0:case 11:case 14:case 15:Ir(r,e),Nr(e),s&4&&(yn(3,e,e.return),eo(3,e),yn(5,e,e.return));break;case 1:Ir(r,e),Nr(e),s&512&&(rr||n===null||wi(n,n.return)),s&64&&Wi&&(e=e.updateQueue,e!==null&&(s=e.callbacks,s!==null&&(n=e.shared.hiddenCallbacks,e.shared.hiddenCallbacks=n===null?s:n.concat(s))));break;case 26:var c=fi;if(Ir(r,e),Nr(e),s&512&&(rr||n===null||wi(n,n.return)),s&4){var d=n!==null?n.memoizedState:null;if(s=e.memoizedState,n===null)if(s===null)if(e.stateNode===null){e:{s=e.type,n=e.memoizedProps,c=c.ownerDocument||c;t:switch(s){case"title":d=c.getElementsByTagName("title")[0],(!d||d[jn]||d[qt]||d.namespaceURI==="http://www.w3.org/2000/svg"||d.hasAttribute("itemprop"))&&(d=c.createElement(s),c.head.insertBefore(d,c.querySelector("head > title"))),vr(d,s,n),d[qt]=e,W(d),s=d;break e;case"link":var g=Hg("link","href",c).get(s+(n.href||""));if(g){for(var M=0;M<g.length;M++)if(d=g[M],d.getAttribute("href")===(n.href==null||n.href===""?null:n.href)&&d.getAttribute("rel")===(n.rel==null?null:n.rel)&&d.getAttribute("title")===(n.title==null?null:n.title)&&d.getAttribute("crossorigin")===(n.crossOrigin==null?null:n.crossOrigin)){g.splice(M,1);break t}}d=c.createElement(s),vr(d,s,n),c.head.appendChild(d);break;case"meta":if(g=Hg("meta","content",c).get(s+(n.content||""))){for(M=0;M<g.length;M++)if(d=g[M],d.getAttribute("content")===(n.content==null?null:""+n.content)&&d.getAttribute("name")===(n.name==null?null:n.name)&&d.getAttribute("property")===(n.property==null?null:n.property)&&d.getAttribute("http-equiv")===(n.httpEquiv==null?null:n.httpEquiv)&&d.getAttribute("charset")===(n.charSet==null?null:n.charSet)){g.splice(M,1);break t}}d=c.createElement(s),vr(d,s,n),c.head.appendChild(d);break;default:throw Error(a(468,s))}d[qt]=e,W(d),s=d}e.stateNode=s}else Vg(c,e.type,e.stateNode);else e.stateNode=Bg(c,s,e.memoizedProps);else d!==s?(d===null?n.stateNode!==null&&(n=n.stateNode,n.parentNode.removeChild(n)):d.count--,s===null?Vg(c,e.type,e.stateNode):Bg(c,s,e.memoizedProps)):s===null&&e.stateNode!==null&&qu(e,e.memoizedProps,n.memoizedProps)}break;case 27:Ir(r,e),Nr(e),s&512&&(rr||n===null||wi(n,n.return)),n!==null&&s&4&&qu(e,e.memoizedProps,n.memoizedProps);break;case 5:if(Ir(r,e),Nr(e),s&512&&(rr||n===null||wi(n,n.return)),e.flags&32){c=e.stateNode;try{Lr(c,"")}catch(Oe){Pt(e,e.return,Oe)}}s&4&&e.stateNode!=null&&(c=e.memoizedProps,qu(e,c,n!==null?n.memoizedProps:c)),s&1024&&(Ku=!0);break;case 6:if(Ir(r,e),Nr(e),s&4){if(e.stateNode===null)throw Error(a(162));s=e.memoizedProps,n=e.stateNode;try{n.nodeValue=s}catch(Oe){Pt(e,e.return,Oe)}}break;case 3:if(Ol=null,c=fi,fi=Il(r.containerInfo),Ir(r,e),fi=c,Nr(e),s&4&&n!==null&&n.memoizedState.isDehydrated)try{es(r.containerInfo)}catch(Oe){Pt(e,e.return,Oe)}Ku&&(Ku=!1,Vm(e));break;case 4:s=fi,fi=Il(e.stateNode.containerInfo),Ir(r,e),Nr(e),fi=s;break;case 12:Ir(r,e),Nr(e);break;case 31:Ir(r,e),Nr(e),s&4&&(s=e.updateQueue,s!==null&&(e.updateQueue=null,xl(e,s)));break;case 13:Ir(r,e),Nr(e),e.child.flags&8192&&e.memoizedState!==null!=(n!==null&&n.memoizedState!==null)&&(bl=he()),s&4&&(s=e.updateQueue,s!==null&&(e.updateQueue=null,xl(e,s)));break;case 22:c=e.memoizedState!==null;var z=n!==null&&n.memoizedState!==null,J=Wi,de=rr;if(Wi=J||c,rr=de||z,Ir(r,e),rr=de,Wi=J,Nr(e),s&8192)e:for(r=e.stateNode,r._visibility=c?r._visibility&-2:r._visibility|1,c&&(n===null||z||Wi||rr||sa(e)),n=null,r=e;;){if(r.tag===5||r.tag===26){if(n===null){z=n=r;try{if(d=z.stateNode,c)g=d.style,typeof g.setProperty=="function"?g.setProperty("display","none","important"):g.display="none";else{M=z.stateNode;var me=z.memoizedProps.style,re=me!=null&&me.hasOwnProperty("display")?me.display:null;M.style.display=re==null||typeof re=="boolean"?"":(""+re).trim()}}catch(Oe){Pt(z,z.return,Oe)}}}else if(r.tag===6){if(n===null){z=r;try{z.stateNode.nodeValue=c?"":z.memoizedProps}catch(Oe){Pt(z,z.return,Oe)}}}else if(r.tag===18){if(n===null){z=r;try{var oe=z.stateNode;c?Lg(oe,!0):Lg(z.stateNode,!1)}catch(Oe){Pt(z,z.return,Oe)}}}else if((r.tag!==22&&r.tag!==23||r.memoizedState===null||r===e)&&r.child!==null){r.child.return=r,r=r.child;continue}if(r===e)break e;for(;r.sibling===null;){if(r.return===null||r.return===e)break e;n===r&&(n=null),r=r.return}n===r&&(n=null),r.sibling.return=r.return,r=r.sibling}s&4&&(s=e.updateQueue,s!==null&&(n=s.retryQueue,n!==null&&(s.retryQueue=null,xl(e,n))));break;case 19:Ir(r,e),Nr(e),s&4&&(s=e.updateQueue,s!==null&&(e.updateQueue=null,xl(e,s)));break;case 30:break;case 21:break;default:Ir(r,e),Nr(e)}}function Nr(e){var r=e.flags;if(r&2){try{for(var n,s=e.return;s!==null;){if(Dm(s)){n=s;break}s=s.return}if(n==null)throw Error(a(160));switch(n.tag){case 27:var c=n.stateNode,d=Qu(e);yl(e,d,c);break;case 5:var g=n.stateNode;n.flags&32&&(Lr(g,""),n.flags&=-33);var M=Qu(e);yl(e,M,g);break;case 3:case 4:var z=n.stateNode.containerInfo,J=Qu(e);$u(e,J,z);break;default:throw Error(a(161))}}catch(de){Pt(e,e.return,de)}e.flags&=-3}r&4096&&(e.flags&=-4097)}function Vm(e){if(e.subtreeFlags&1024)for(e=e.child;e!==null;){var r=e;Vm(r),r.tag===5&&r.flags&1024&&r.stateNode.reset(),e=e.sibling}}function Xi(e,r){if(r.subtreeFlags&8772)for(r=r.child;r!==null;)Om(e,r.alternate,r),r=r.sibling}function sa(e){for(e=e.child;e!==null;){var r=e;switch(r.tag){case 0:case 11:case 14:case 15:yn(4,r,r.return),sa(r);break;case 1:wi(r,r.return);var n=r.stateNode;typeof n.componentWillUnmount=="function"&&Lm(r,r.return,n),sa(r);break;case 27:uo(r.stateNode);case 26:case 5:wi(r,r.return),sa(r);break;case 22:r.memoizedState===null&&sa(r);break;case 30:sa(r);break;default:sa(r)}e=e.sibling}}function Yi(e,r,n){for(n=n&&(r.subtreeFlags&8772)!==0,r=r.child;r!==null;){var s=r.alternate,c=e,d=r,g=d.flags;switch(d.tag){case 0:case 11:case 15:Yi(c,d,n),eo(4,d);break;case 1:if(Yi(c,d,n),s=d,c=s.stateNode,typeof c.componentDidMount=="function")try{c.componentDidMount()}catch(J){Pt(s,s.return,J)}if(s=d,c=s.updateQueue,c!==null){var M=s.stateNode;try{var z=c.shared.hiddenCallbacks;if(z!==null)for(c.shared.hiddenCallbacks=null,c=0;c<z.length;c++)yp(z[c],M)}catch(J){Pt(s,s.return,J)}}n&&g&64&&Pm(d),to(d,d.return);break;case 27:Im(d);case 26:case 5:Yi(c,d,n),n&&s===null&&g&4&&Um(d),to(d,d.return);break;case 12:Yi(c,d,n);break;case 31:Yi(c,d,n),n&&g&4&&zm(c,d);break;case 13:Yi(c,d,n),n&&g&4&&Bm(c,d);break;case 22:d.memoizedState===null&&Yi(c,d,n),to(d,d.return);break;case 30:break;default:Yi(c,d,n)}r=r.sibling}}function Zu(e,r){var n=null;e!==null&&e.memoizedState!==null&&e.memoizedState.cachePool!==null&&(n=e.memoizedState.cachePool.pool),e=null,r.memoizedState!==null&&r.memoizedState.cachePool!==null&&(e=r.memoizedState.cachePool.pool),e!==n&&(e!=null&&e.refCount++,n!=null&&Hs(n))}function Ju(e,r){e=null,r.alternate!==null&&(e=r.alternate.memoizedState.cache),r=r.memoizedState.cache,r!==e&&(r.refCount++,e!=null&&Hs(e))}function pi(e,r,n,s){if(r.subtreeFlags&10256)for(r=r.child;r!==null;)Gm(e,r,n,s),r=r.sibling}function Gm(e,r,n,s){var c=r.flags;switch(r.tag){case 0:case 11:case 15:pi(e,r,n,s),c&2048&&eo(9,r);break;case 1:pi(e,r,n,s);break;case 3:pi(e,r,n,s),c&2048&&(e=null,r.alternate!==null&&(e=r.alternate.memoizedState.cache),r=r.memoizedState.cache,r!==e&&(r.refCount++,e!=null&&Hs(e)));break;case 12:if(c&2048){pi(e,r,n,s),e=r.stateNode;try{var d=r.memoizedProps,g=d.id,M=d.onPostCommit;typeof M=="function"&&M(g,r.alternate===null?"mount":"update",e.passiveEffectDuration,-0)}catch(z){Pt(r,r.return,z)}}else pi(e,r,n,s);break;case 31:pi(e,r,n,s);break;case 13:pi(e,r,n,s);break;case 23:break;case 22:d=r.stateNode,g=r.alternate,r.memoizedState!==null?d._visibility&2?pi(e,r,n,s):ro(e,r):d._visibility&2?pi(e,r,n,s):(d._visibility|=2,Ga(e,r,n,s,(r.subtreeFlags&10256)!==0||!1)),c&2048&&Zu(g,r);break;case 24:pi(e,r,n,s),c&2048&&Ju(r.alternate,r);break;default:pi(e,r,n,s)}}function Ga(e,r,n,s,c){for(c=c&&((r.subtreeFlags&10256)!==0||!1),r=r.child;r!==null;){var d=e,g=r,M=n,z=s,J=g.flags;switch(g.tag){case 0:case 11:case 15:Ga(d,g,M,z,c),eo(8,g);break;case 23:break;case 22:var de=g.stateNode;g.memoizedState!==null?de._visibility&2?Ga(d,g,M,z,c):ro(d,g):(de._visibility|=2,Ga(d,g,M,z,c)),c&&J&2048&&Zu(g.alternate,g);break;case 24:Ga(d,g,M,z,c),c&&J&2048&&Ju(g.alternate,g);break;default:Ga(d,g,M,z,c)}r=r.sibling}}function ro(e,r){if(r.subtreeFlags&10256)for(r=r.child;r!==null;){var n=e,s=r,c=s.flags;switch(s.tag){case 22:ro(n,s),c&2048&&Zu(s.alternate,s);break;case 24:ro(n,s),c&2048&&Ju(s.alternate,s);break;default:ro(n,s)}r=r.sibling}}var io=8192;function Wa(e,r,n){if(e.subtreeFlags&io)for(e=e.child;e!==null;)Wm(e,r,n),e=e.sibling}function Wm(e,r,n){switch(e.tag){case 26:Wa(e,r,n),e.flags&io&&e.memoizedState!==null&&Xy(n,fi,e.memoizedState,e.memoizedProps);break;case 5:Wa(e,r,n);break;case 3:case 4:var s=fi;fi=Il(e.stateNode.containerInfo),Wa(e,r,n),fi=s;break;case 22:e.memoizedState===null&&(s=e.alternate,s!==null&&s.memoizedState!==null?(s=io,io=16777216,Wa(e,r,n),io=s):Wa(e,r,n));break;default:Wa(e,r,n)}}function jm(e){var r=e.alternate;if(r!==null&&(e=r.child,e!==null)){r.child=null;do r=e.sibling,e.sibling=null,e=r;while(e!==null)}}function no(e){var r=e.deletions;if((e.flags&16)!==0){if(r!==null)for(var n=0;n<r.length;n++){var s=r[n];lr=s,Ym(s,e)}jm(e)}if(e.subtreeFlags&10256)for(e=e.child;e!==null;)Xm(e),e=e.sibling}function Xm(e){switch(e.tag){case 0:case 11:case 15:no(e),e.flags&2048&&yn(9,e,e.return);break;case 3:no(e);break;case 12:no(e);break;case 22:var r=e.stateNode;e.memoizedState!==null&&r._visibility&2&&(e.return===null||e.return.tag!==13)?(r._visibility&=-3,Sl(e)):no(e);break;default:no(e)}}function Sl(e){var r=e.deletions;if((e.flags&16)!==0){if(r!==null)for(var n=0;n<r.length;n++){var s=r[n];lr=s,Ym(s,e)}jm(e)}for(e=e.child;e!==null;){switch(r=e,r.tag){case 0:case 11:case 15:yn(8,r,r.return),Sl(r);break;case 22:n=r.stateNode,n._visibility&2&&(n._visibility&=-3,Sl(r));break;default:Sl(r)}e=e.sibling}}function Ym(e,r){for(;lr!==null;){var n=lr;switch(n.tag){case 0:case 11:case 15:yn(8,n,r);break;case 23:case 22:if(n.memoizedState!==null&&n.memoizedState.cachePool!==null){var s=n.memoizedState.cachePool.pool;s!=null&&s.refCount++}break;case 24:Hs(n.memoizedState.cache)}if(s=n.child,s!==null)s.return=n,lr=s;else e:for(n=e;lr!==null;){s=lr;var c=s.sibling,d=s.return;if(km(s),s===n){lr=null;break e}if(c!==null){c.return=d,lr=c;break e}lr=d}}}var oy={getCacheForType:function(e){var r=mr(Jt),n=r.data.get(e);return n===void 0&&(n=e(),r.data.set(e,n)),n},cacheSignal:function(){return mr(Jt).controller.signal}},ly=typeof WeakMap=="function"?WeakMap:Map,Rt=0,zt=null,ht=null,mt=0,At=0,jr=null,xn=!1,ja=!1,ed=!1,qi=0,$t=0,Sn=0,oa=0,td=0,Xr=0,Xa=0,ao=null,Or=null,rd=!1,bl=0,qm=0,Ml=1/0,El=null,bn=null,ar=0,Mn=null,Ya=null,Qi=0,id=0,nd=null,Qm=null,so=0,ad=null;function Yr(){return(Rt&2)!==0&&mt!==0?mt&-mt:N.T!==null?dd():Rs()}function $m(){if(Xr===0)if((mt&536870912)===0||vt){var e=le;le<<=1,(le&3932160)===0&&(le=262144),Xr=e}else Xr=536870912;return e=Gr.current,e!==null&&(e.flags|=32),Xr}function kr(e,r,n){(e===zt&&(At===2||At===9)||e.cancelPendingCommit!==null)&&(qa(e,0),En(e,mt,Xr,!1)),ur(e,n),((Rt&2)===0||e!==zt)&&(e===zt&&((Rt&2)===0&&(oa|=n),$t===4&&En(e,mt,Xr,!1)),Ti(e))}function Km(e,r,n){if((Rt&6)!==0)throw Error(a(327));var s=!n&&(r&127)===0&&(r&e.expiredLanes)===0||st(e,r),c=s?dy(e,r):od(e,r,!0),d=s;do{if(c===0){ja&&!s&&En(e,r,0,!1);break}else{if(n=e.current.alternate,d&&!cy(n)){c=od(e,r,!1),d=!1;continue}if(c===2){if(d=r,e.errorRecoveryDisabledLanes&d)var g=0;else g=e.pendingLanes&-536870913,g=g!==0?g:g&536870912?536870912:0;if(g!==0){r=g;e:{var M=e;c=ao;var z=M.current.memoizedState.isDehydrated;if(z&&(qa(M,g).flags|=256),g=od(M,g,!1),g!==2){if(ed&&!z){M.errorRecoveryDisabledLanes|=d,oa|=d,c=4;break e}d=Or,Or=c,d!==null&&(Or===null?Or=d:Or.push.apply(Or,d))}c=g}if(d=!1,c!==2)continue}}if(c===1){qa(e,0),En(e,r,0,!0);break}e:{switch(s=e,d=c,d){case 0:case 1:throw Error(a(345));case 4:if((r&4194048)!==r)break;case 6:En(s,r,Xr,!xn);break e;case 2:Or=null;break;case 3:case 5:break;default:throw Error(a(329))}if((r&62914560)===r&&(c=bl+300-he(),10<c)){if(En(s,r,Xr,!xn),Te(s,0,!0)!==0)break e;Qi=r,s.timeoutHandle=Cg(Zm.bind(null,s,n,Or,El,rd,r,Xr,oa,Xa,xn,d,"Throttled",-0,0),c);break e}Zm(s,n,Or,El,rd,r,Xr,oa,Xa,xn,d,null,-0,0)}}break}while(!0);Ti(e)}function Zm(e,r,n,s,c,d,g,M,z,J,de,me,re,oe){if(e.timeoutHandle=-1,me=r.subtreeFlags,me&8192||(me&16785408)===16785408){me={stylesheets:null,count:0,imgCount:0,imgBytes:0,suspenseyImages:[],waitingForImages:!0,waitingForViewTransition:!1,unsuspend:Ii},Wm(r,d,me);var Oe=(d&62914560)===d?bl-he():(d&4194048)===d?qm-he():0;if(Oe=Yy(me,Oe),Oe!==null){Qi=d,e.cancelPendingCommit=Oe(sg.bind(null,e,r,d,n,s,c,g,M,z,de,me,null,re,oe)),En(e,d,g,!J);return}}sg(e,r,d,n,s,c,g,M,z)}function cy(e){for(var r=e;;){var n=r.tag;if((n===0||n===11||n===15)&&r.flags&16384&&(n=r.updateQueue,n!==null&&(n=n.stores,n!==null)))for(var s=0;s<n.length;s++){var c=n[s],d=c.getSnapshot;c=c.value;try{if(!Hr(d(),c))return!1}catch{return!1}}if(n=r.child,r.subtreeFlags&16384&&n!==null)n.return=r,r=n;else{if(r===e)break;for(;r.sibling===null;){if(r.return===null||r.return===e)return!0;r=r.return}r.sibling.return=r.return,r=r.sibling}}return!0}function En(e,r,n,s){r&=~td,r&=~oa,e.suspendedLanes|=r,e.pingedLanes&=~r,s&&(e.warmLanes|=r),s=e.expirationTimes;for(var c=r;0<c;){var d=31-Ke(c),g=1<<d;s[d]=-1,c&=~g}n!==0&&ws(e,n,r)}function wl(){return(Rt&6)===0?(oo(0),!1):!0}function sd(){if(ht!==null){if(At===0)var e=ht.return;else e=ht,Fi=Zn=null,bu(e),Fa=null,Gs=0,e=ht;for(;e!==null;)Am(e.alternate,e),e=e.return;ht=null}}function qa(e,r){var n=e.timeoutHandle;n!==-1&&(e.timeoutHandle=-1,Ay(n)),n=e.cancelPendingCommit,n!==null&&(e.cancelPendingCommit=null,n()),Qi=0,sd(),zt=e,ht=n=Oi(e.current,null),mt=r,At=0,jr=null,xn=!1,ja=st(e,r),ed=!1,Xa=Xr=td=oa=Sn=$t=0,Or=ao=null,rd=!1,(r&8)!==0&&(r|=r&32);var s=e.entangledLanes;if(s!==0)for(e=e.entanglements,s&=r;0<s;){var c=31-Ke(s),d=1<<c;r|=e[c],s&=~d}return qi=r,Xo(),n}function Jm(e,r){it=null,N.H=Ks,r===ka||r===el?(r=mp(),At=3):r===uu?(r=mp(),At=4):At=r===Fu?8:r!==null&&typeof r=="object"&&typeof r.then=="function"?6:1,jr=r,ht===null&&($t=1,pl(e,Zr(r,e.current)))}function eg(){var e=Gr.current;return e===null?!0:(mt&4194048)===mt?hi===null:(mt&62914560)===mt||(mt&536870912)!==0?e===hi:!1}function tg(){var e=N.H;return N.H=Ks,e===null?Ks:e}function rg(){var e=N.A;return N.A=oy,e}function Tl(){$t=4,xn||(mt&4194048)!==mt&&Gr.current!==null||(ja=!0),(Sn&134217727)===0&&(oa&134217727)===0||zt===null||En(zt,mt,Xr,!1)}function od(e,r,n){var s=Rt;Rt|=2;var c=tg(),d=rg();(zt!==e||mt!==r)&&(El=null,qa(e,r)),r=!1;var g=$t;e:do try{if(At!==0&&ht!==null){var M=ht,z=jr;switch(At){case 8:sd(),g=6;break e;case 3:case 2:case 9:case 6:Gr.current===null&&(r=!0);var J=At;if(At=0,jr=null,Qa(e,M,z,J),n&&ja){g=0;break e}break;default:J=At,At=0,jr=null,Qa(e,M,z,J)}}uy(),g=$t;break}catch(de){Jm(e,de)}while(!0);return r&&e.shellSuspendCounter++,Fi=Zn=null,Rt=s,N.H=c,N.A=d,ht===null&&(zt=null,mt=0,Xo()),g}function uy(){for(;ht!==null;)ig(ht)}function dy(e,r){var n=Rt;Rt|=2;var s=tg(),c=rg();zt!==e||mt!==r?(El=null,Ml=he()+500,qa(e,r)):ja=st(e,r);e:do try{if(At!==0&&ht!==null){r=ht;var d=jr;t:switch(At){case 1:At=0,jr=null,Qa(e,r,d,1);break;case 2:case 9:if(fp(d)){At=0,jr=null,ng(r);break}r=function(){At!==2&&At!==9||zt!==e||(At=7),Ti(e)},d.then(r,r);break e;case 3:At=7;break e;case 4:At=5;break e;case 7:fp(d)?(At=0,jr=null,ng(r)):(At=0,jr=null,Qa(e,r,d,7));break;case 5:var g=null;switch(ht.tag){case 26:g=ht.memoizedState;case 5:case 27:var M=ht;if(g?Gg(g):M.stateNode.complete){At=0,jr=null;var z=M.sibling;if(z!==null)ht=z;else{var J=M.return;J!==null?(ht=J,Rl(J)):ht=null}break t}}At=0,jr=null,Qa(e,r,d,5);break;case 6:At=0,jr=null,Qa(e,r,d,6);break;case 8:sd(),$t=6;break e;default:throw Error(a(462))}}hy();break}catch(de){Jm(e,de)}while(!0);return Fi=Zn=null,N.H=s,N.A=c,Rt=n,ht!==null?0:(zt=null,mt=0,Xo(),$t)}function hy(){for(;ht!==null&&!E();)ig(ht)}function ig(e){var r=Rm(e.alternate,e,qi);e.memoizedProps=e.pendingProps,r===null?Rl(e):ht=r}function ng(e){var r=e,n=r.alternate;switch(r.tag){case 15:case 0:r=Sm(n,r,r.pendingProps,r.type,void 0,mt);break;case 11:r=Sm(n,r,r.pendingProps,r.type.render,r.ref,mt);break;case 5:bu(r);default:Am(n,r),r=ht=rp(r,qi),r=Rm(n,r,qi)}e.memoizedProps=e.pendingProps,r===null?Rl(e):ht=r}function Qa(e,r,n,s){Fi=Zn=null,bu(r),Fa=null,Gs=0;var c=r.return;try{if(ey(e,c,r,n,mt)){$t=1,pl(e,Zr(n,e.current)),ht=null;return}}catch(d){if(c!==null)throw ht=c,d;$t=1,pl(e,Zr(n,e.current)),ht=null;return}r.flags&32768?(vt||s===1?e=!0:ja||(mt&536870912)!==0?e=!1:(xn=e=!0,(s===2||s===9||s===3||s===6)&&(s=Gr.current,s!==null&&s.tag===13&&(s.flags|=16384))),ag(r,e)):Rl(r)}function Rl(e){var r=e;do{if((r.flags&32768)!==0){ag(r,xn);return}e=r.return;var n=iy(r.alternate,r,qi);if(n!==null){ht=n;return}if(r=r.sibling,r!==null){ht=r;return}ht=r=e}while(r!==null);$t===0&&($t=5)}function ag(e,r){do{var n=ny(e.alternate,e);if(n!==null){n.flags&=32767,ht=n;return}if(n=e.return,n!==null&&(n.flags|=32768,n.subtreeFlags=0,n.deletions=null),!r&&(e=e.sibling,e!==null)){ht=e;return}ht=e=n}while(e!==null);$t=6,ht=null}function sg(e,r,n,s,c,d,g,M,z){e.cancelPendingCommit=null;do Cl();while(ar!==0);if((Rt&6)!==0)throw Error(a(327));if(r!==null){if(r===e.current)throw Error(a(177));if(d=r.lanes|r.childLanes,d|=Qc,oi(e,n,d,g,M,z),e===zt&&(ht=zt=null,mt=0),Ya=r,Mn=e,Qi=n,id=d,nd=c,Qm=s,(r.subtreeFlags&10256)!==0||(r.flags&10256)!==0?(e.callbackNode=null,e.callbackPriority=0,gy(Ce,function(){return dg(),null})):(e.callbackNode=null,e.callbackPriority=0),s=(r.flags&13878)!==0,(r.subtreeFlags&13878)!==0||s){s=N.T,N.T=null,c=K.p,K.p=2,g=Rt,Rt|=4;try{ay(e,r,n)}finally{Rt=g,K.p=c,N.T=s}}ar=1,og(),lg(),cg()}}function og(){if(ar===1){ar=0;var e=Mn,r=Ya,n=(r.flags&13878)!==0;if((r.subtreeFlags&13878)!==0||n){n=N.T,N.T=null;var s=K.p;K.p=2;var c=Rt;Rt|=4;try{Hm(r,e);var d=yd,g=Yf(e.containerInfo),M=d.focusedElem,z=d.selectionRange;if(g!==M&&M&&M.ownerDocument&&Xf(M.ownerDocument.documentElement,M)){if(z!==null&&Wc(M)){var J=z.start,de=z.end;if(de===void 0&&(de=J),"selectionStart"in M)M.selectionStart=J,M.selectionEnd=Math.min(de,M.value.length);else{var me=M.ownerDocument||document,re=me&&me.defaultView||window;if(re.getSelection){var oe=re.getSelection(),Oe=M.textContent.length,Qe=Math.min(z.start,Oe),Ot=z.end===void 0?Qe:Math.min(z.end,Oe);!oe.extend&&Qe>Ot&&(g=Ot,Ot=Qe,Qe=g);var Y=jf(M,Qe),V=jf(M,Ot);if(Y&&V&&(oe.rangeCount!==1||oe.anchorNode!==Y.node||oe.anchorOffset!==Y.offset||oe.focusNode!==V.node||oe.focusOffset!==V.offset)){var Z=me.createRange();Z.setStart(Y.node,Y.offset),oe.removeAllRanges(),Qe>Ot?(oe.addRange(Z),oe.extend(V.node,V.offset)):(Z.setEnd(V.node,V.offset),oe.addRange(Z))}}}}for(me=[],oe=M;oe=oe.parentNode;)oe.nodeType===1&&me.push({element:oe,left:oe.scrollLeft,top:oe.scrollTop});for(typeof M.focus=="function"&&M.focus(),M=0;M<me.length;M++){var fe=me[M];fe.element.scrollLeft=fe.left,fe.element.scrollTop=fe.top}}Bl=!!_d,yd=_d=null}finally{Rt=c,K.p=s,N.T=n}}e.current=r,ar=2}}function lg(){if(ar===2){ar=0;var e=Mn,r=Ya,n=(r.flags&8772)!==0;if((r.subtreeFlags&8772)!==0||n){n=N.T,N.T=null;var s=K.p;K.p=2;var c=Rt;Rt|=4;try{Om(e,r.alternate,r)}finally{Rt=c,K.p=s,N.T=n}}ar=3}}function cg(){if(ar===4||ar===3){ar=0,ee();var e=Mn,r=Ya,n=Qi,s=Qm;(r.subtreeFlags&10256)!==0||(r.flags&10256)!==0?ar=5:(ar=0,Ya=Mn=null,ug(e,e.pendingLanes));var c=e.pendingLanes;if(c===0&&(bn=null),ba(n),r=r.stateNode,He&&typeof He.onCommitFiberRoot=="function")try{He.onCommitFiberRoot(Xe,r,void 0,(r.current.flags&128)===128)}catch{}if(s!==null){r=N.T,c=K.p,K.p=2,N.T=null;try{for(var d=e.onRecoverableError,g=0;g<s.length;g++){var M=s[g];d(M.value,{componentStack:M.stack})}}finally{N.T=r,K.p=c}}(Qi&3)!==0&&Cl(),Ti(e),c=e.pendingLanes,(n&261930)!==0&&(c&42)!==0?e===ad?so++:(so=0,ad=e):so=0,oo(0)}}function ug(e,r){(e.pooledCacheLanes&=r)===0&&(r=e.pooledCache,r!=null&&(e.pooledCache=null,Hs(r)))}function Cl(){return og(),lg(),cg(),dg()}function dg(){if(ar!==5)return!1;var e=Mn,r=id;id=0;var n=ba(Qi),s=N.T,c=K.p;try{K.p=32>n?32:n,N.T=null,n=nd,nd=null;var d=Mn,g=Qi;if(ar=0,Ya=Mn=null,Qi=0,(Rt&6)!==0)throw Error(a(331));var M=Rt;if(Rt|=4,Xm(d.current),Gm(d,d.current,g,n),Rt=M,oo(0,!1),He&&typeof He.onPostCommitFiberRoot=="function")try{He.onPostCommitFiberRoot(Xe,d)}catch{}return!0}finally{K.p=c,N.T=s,ug(e,r)}}function hg(e,r,n){r=Zr(n,r),r=ku(e.stateNode,r,2),e=gn(e,r,2),e!==null&&(ur(e,2),Ti(e))}function Pt(e,r,n){if(e.tag===3)hg(e,e,n);else for(;r!==null;){if(r.tag===3){hg(r,e,n);break}else if(r.tag===1){var s=r.stateNode;if(typeof r.type.getDerivedStateFromError=="function"||typeof s.componentDidCatch=="function"&&(bn===null||!bn.has(s))){e=Zr(n,e),n=fm(2),s=gn(r,n,2),s!==null&&(pm(n,s,r,e),ur(s,2),Ti(s));break}}r=r.return}}function ld(e,r,n){var s=e.pingCache;if(s===null){s=e.pingCache=new ly;var c=new Set;s.set(r,c)}else c=s.get(r),c===void 0&&(c=new Set,s.set(r,c));c.has(n)||(ed=!0,c.add(n),e=fy.bind(null,e,r,n),r.then(e,e))}function fy(e,r,n){var s=e.pingCache;s!==null&&s.delete(r),e.pingedLanes|=e.suspendedLanes&n,e.warmLanes&=~n,zt===e&&(mt&n)===n&&($t===4||$t===3&&(mt&62914560)===mt&&300>he()-bl?(Rt&2)===0&&qa(e,0):td|=n,Xa===mt&&(Xa=0)),Ti(e)}function fg(e,r){r===0&&(r=nr()),e=Qn(e,r),e!==null&&(ur(e,r),Ti(e))}function py(e){var r=e.memoizedState,n=0;r!==null&&(n=r.retryLane),fg(e,n)}function my(e,r){var n=0;switch(e.tag){case 31:case 13:var s=e.stateNode,c=e.memoizedState;c!==null&&(n=c.retryLane);break;case 19:s=e.stateNode;break;case 22:s=e.stateNode._retryCache;break;default:throw Error(a(314))}s!==null&&s.delete(r),fg(e,n)}function gy(e,r){return Ve(e,r)}var Al=null,$a=null,cd=!1,Pl=!1,ud=!1,wn=0;function Ti(e){e!==$a&&e.next===null&&($a===null?Al=$a=e:$a=$a.next=e),Pl=!0,cd||(cd=!0,_y())}function oo(e,r){if(!ud&&Pl){ud=!0;do for(var n=!1,s=Al;s!==null;){if(e!==0){var c=s.pendingLanes;if(c===0)var d=0;else{var g=s.suspendedLanes,M=s.pingedLanes;d=(1<<31-Ke(42|e)+1)-1,d&=c&~(g&~M),d=d&201326741?d&201326741|1:d?d|2:0}d!==0&&(n=!0,vg(s,d))}else d=mt,d=Te(s,s===zt?d:0,s.cancelPendingCommit!==null||s.timeoutHandle!==-1),(d&3)===0||st(s,d)||(n=!0,vg(s,d));s=s.next}while(n);ud=!1}}function vy(){pg()}function pg(){Pl=cd=!1;var e=0;wn!==0&&Cy()&&(e=wn);for(var r=he(),n=null,s=Al;s!==null;){var c=s.next,d=mg(s,r);d===0?(s.next=null,n===null?Al=c:n.next=c,c===null&&($a=n)):(n=s,(e!==0||(d&3)!==0)&&(Pl=!0)),s=c}ar!==0&&ar!==5||oo(e),wn!==0&&(wn=0)}function mg(e,r){for(var n=e.suspendedLanes,s=e.pingedLanes,c=e.expirationTimes,d=e.pendingLanes&-62914561;0<d;){var g=31-Ke(d),M=1<<g,z=c[g];z===-1?((M&n)===0||(M&s)!==0)&&(c[g]=Gt(M,r)):z<=r&&(e.expiredLanes|=M),d&=~M}if(r=zt,n=mt,n=Te(e,e===r?n:0,e.cancelPendingCommit!==null||e.timeoutHandle!==-1),s=e.callbackNode,n===0||e===r&&(At===2||At===9)||e.cancelPendingCommit!==null)return s!==null&&s!==null&&U(s),e.callbackNode=null,e.callbackPriority=0;if((n&3)===0||st(e,n)){if(r=n&-n,r===e.callbackPriority)return r;switch(s!==null&&U(s),ba(n)){case 2:case 8:n=Be;break;case 32:n=Ce;break;case 268435456:n=Ye;break;default:n=Ce}return s=gg.bind(null,e),n=Ve(n,s),e.callbackPriority=r,e.callbackNode=n,r}return s!==null&&s!==null&&U(s),e.callbackPriority=2,e.callbackNode=null,2}function gg(e,r){if(ar!==0&&ar!==5)return e.callbackNode=null,e.callbackPriority=0,null;var n=e.callbackNode;if(Cl()&&e.callbackNode!==n)return null;var s=mt;return s=Te(e,e===zt?s:0,e.cancelPendingCommit!==null||e.timeoutHandle!==-1),s===0?null:(Km(e,s,r),mg(e,he()),e.callbackNode!=null&&e.callbackNode===n?gg.bind(null,e):null)}function vg(e,r){if(Cl())return null;Km(e,r,!0)}function _y(){Py(function(){(Rt&6)!==0?Ve(pe,vy):pg()})}function dd(){if(wn===0){var e=Na;e===0&&(e=Ae,Ae<<=1,(Ae&261888)===0&&(Ae=256)),wn=e}return wn}function _g(e){return e==null||typeof e=="symbol"||typeof e=="boolean"?null:typeof e=="function"?e:Fo(""+e)}function yg(e,r){var n=r.ownerDocument.createElement("input");return n.name=r.name,n.value=r.value,e.id&&n.setAttribute("form",e.id),r.parentNode.insertBefore(n,r),e=new FormData(e),n.parentNode.removeChild(n),e}function yy(e,r,n,s,c){if(r==="submit"&&n&&n.stateNode===c){var d=_g((c[dr]||null).action),g=s.submitter;g&&(r=(r=g[dr]||null)?_g(r.formAction):g.getAttribute("formAction"),r!==null&&(d=r,g=null));var M=new Vo("action","action",null,s,c);e.push({event:M,listeners:[{instance:null,listener:function(){if(s.defaultPrevented){if(wn!==0){var z=g?yg(c,g):new FormData(c);Lu(n,{pending:!0,data:z,method:c.method,action:d},null,z)}}else typeof d=="function"&&(M.preventDefault(),z=g?yg(c,g):new FormData(c),Lu(n,{pending:!0,data:z,method:c.method,action:d},d,z))},currentTarget:c}]})}}for(var hd=0;hd<qc.length;hd++){var fd=qc[hd],xy=fd.toLowerCase(),Sy=fd[0].toUpperCase()+fd.slice(1);di(xy,"on"+Sy)}di($f,"onAnimationEnd"),di(Kf,"onAnimationIteration"),di(Zf,"onAnimationStart"),di("dblclick","onDoubleClick"),di("focusin","onFocus"),di("focusout","onBlur"),di(k0,"onTransitionRun"),di(F0,"onTransitionStart"),di(z0,"onTransitionCancel"),di(Jf,"onTransitionEnd"),Ie("onMouseEnter",["mouseout","mouseover"]),Ie("onMouseLeave",["mouseout","mouseover"]),Ie("onPointerEnter",["pointerout","pointerover"]),Ie("onPointerLeave",["pointerout","pointerover"]),Pe("onChange","change click focusin focusout input keydown keyup selectionchange".split(" ")),Pe("onSelect","focusout contextmenu dragend focusin keydown keyup mousedown mouseup selectionchange".split(" ")),Pe("onBeforeInput",["compositionend","keypress","textInput","paste"]),Pe("onCompositionEnd","compositionend focusout keydown keypress keyup mousedown".split(" ")),Pe("onCompositionStart","compositionstart focusout keydown keypress keyup mousedown".split(" ")),Pe("onCompositionUpdate","compositionupdate focusout keydown keypress keyup mousedown".split(" "));var lo="abort canplay canplaythrough durationchange emptied encrypted ended error loadeddata loadedmetadata loadstart pause play playing progress ratechange resize seeked seeking stalled suspend timeupdate volumechange waiting".split(" "),by=new Set("beforetoggle cancel close invalid load scroll scrollend toggle".split(" ").concat(lo));function xg(e,r){r=(r&4)!==0;for(var n=0;n<e.length;n++){var s=e[n],c=s.event;s=s.listeners;e:{var d=void 0;if(r)for(var g=s.length-1;0<=g;g--){var M=s[g],z=M.instance,J=M.currentTarget;if(M=M.listener,z!==d&&c.isPropagationStopped())break e;d=M,c.currentTarget=J;try{d(c)}catch(de){jo(de)}c.currentTarget=null,d=z}else for(g=0;g<s.length;g++){if(M=s[g],z=M.instance,J=M.currentTarget,M=M.listener,z!==d&&c.isPropagationStopped())break e;d=M,c.currentTarget=J;try{d(c)}catch(de){jo(de)}c.currentTarget=null,d=z}}}}function ft(e,r){var n=r[Cs];n===void 0&&(n=r[Cs]=new Set);var s=e+"__bubble";n.has(s)||(Sg(r,e,2,!1),n.add(s))}function pd(e,r,n){var s=0;r&&(s|=4),Sg(n,e,s,r)}var Ll="_reactListening"+Math.random().toString(36).slice(2);function md(e){if(!e[Ll]){e[Ll]=!0,Se.forEach(function(n){n!=="selectionchange"&&(by.has(n)||pd(n,!1,e),pd(n,!0,e))});var r=e.nodeType===9?e:e.ownerDocument;r===null||r[Ll]||(r[Ll]=!0,pd("selectionchange",!1,r))}}function Sg(e,r,n,s){switch($g(r)){case 2:var c=$y;break;case 8:c=Ky;break;default:c=Pd}n=c.bind(null,r,n,e),c=void 0,!Nc||r!=="touchstart"&&r!=="touchmove"&&r!=="wheel"||(c=!0),s?c!==void 0?e.addEventListener(r,n,{capture:!0,passive:c}):e.addEventListener(r,n,!0):c!==void 0?e.addEventListener(r,n,{passive:c}):e.addEventListener(r,n,!1)}function gd(e,r,n,s,c){var d=s;if((r&1)===0&&(r&2)===0&&s!==null)e:for(;;){if(s===null)return;var g=s.tag;if(g===3||g===4){var M=s.stateNode.containerInfo;if(M===c)break;if(g===4)for(g=s.return;g!==null;){var z=g.tag;if((z===3||z===4)&&g.stateNode.containerInfo===c)return;g=g.return}for(;M!==null;){if(g=T(M),g===null)return;if(z=g.tag,z===5||z===6||z===26||z===27){s=d=g;continue e}M=M.parentNode}}s=s.return}Tf(function(){var J=d,de=Dc(n),me=[];e:{var re=ep.get(e);if(re!==void 0){var oe=Vo,Oe=e;switch(e){case"keypress":if(Bo(n)===0)break e;case"keydown":case"keyup":oe=m0;break;case"focusin":Oe="focus",oe=zc;break;case"focusout":Oe="blur",oe=zc;break;case"beforeblur":case"afterblur":oe=zc;break;case"click":if(n.button===2)break e;case"auxclick":case"dblclick":case"mousedown":case"mousemove":case"mouseup":case"mouseout":case"mouseover":case"contextmenu":oe=Af;break;case"drag":case"dragend":case"dragenter":case"dragexit":case"dragleave":case"dragover":case"dragstart":case"drop":oe=i0;break;case"touchcancel":case"touchend":case"touchmove":case"touchstart":oe=_0;break;case $f:case Kf:case Zf:oe=s0;break;case Jf:oe=x0;break;case"scroll":case"scrollend":oe=t0;break;case"wheel":oe=b0;break;case"copy":case"cut":case"paste":oe=l0;break;case"gotpointercapture":case"lostpointercapture":case"pointercancel":case"pointerdown":case"pointermove":case"pointerout":case"pointerover":case"pointerup":oe=Lf;break;case"toggle":case"beforetoggle":oe=E0}var Qe=(r&4)!==0,Ot=!Qe&&(e==="scroll"||e==="scrollend"),Y=Qe?re!==null?re+"Capture":null:re;Qe=[];for(var V=J,Z;V!==null;){var fe=V;if(Z=fe.stateNode,fe=fe.tag,fe!==5&&fe!==26&&fe!==27||Z===null||Y===null||(fe=Ps(V,Y),fe!=null&&Qe.push(co(V,fe,Z))),Ot)break;V=V.return}0<Qe.length&&(re=new oe(re,Oe,null,n,de),me.push({event:re,listeners:Qe}))}}if((r&7)===0){e:{if(re=e==="mouseover"||e==="pointerover",oe=e==="mouseout"||e==="pointerout",re&&n!==Uc&&(Oe=n.relatedTarget||n.fromElement)&&(T(Oe)||Oe[Di]))break e;if((oe||re)&&(re=de.window===de?de:(re=de.ownerDocument)?re.defaultView||re.parentWindow:window,oe?(Oe=n.relatedTarget||n.toElement,oe=J,Oe=Oe?T(Oe):null,Oe!==null&&(Ot=u(Oe),Qe=Oe.tag,Oe!==Ot||Qe!==5&&Qe!==27&&Qe!==6)&&(Oe=null)):(oe=null,Oe=J),oe!==Oe)){if(Qe=Af,fe="onMouseLeave",Y="onMouseEnter",V="mouse",(e==="pointerout"||e==="pointerover")&&(Qe=Lf,fe="onPointerLeave",Y="onPointerEnter",V="pointer"),Ot=oe==null?re:ne(oe),Z=Oe==null?re:ne(Oe),re=new Qe(fe,V+"leave",oe,n,de),re.target=Ot,re.relatedTarget=Z,fe=null,T(de)===J&&(Qe=new Qe(Y,V+"enter",Oe,n,de),Qe.target=Z,Qe.relatedTarget=Ot,fe=Qe),Ot=fe,oe&&Oe)t:{for(Qe=My,Y=oe,V=Oe,Z=0,fe=Y;fe;fe=Qe(fe))Z++;fe=0;for(var We=V;We;We=Qe(We))fe++;for(;0<Z-fe;)Y=Qe(Y),Z--;for(;0<fe-Z;)V=Qe(V),fe--;for(;Z--;){if(Y===V||V!==null&&Y===V.alternate){Qe=Y;break t}Y=Qe(Y),V=Qe(V)}Qe=null}else Qe=null;oe!==null&&bg(me,re,oe,Qe,!1),Oe!==null&&Ot!==null&&bg(me,Ot,Oe,Qe,!0)}}e:{if(re=J?ne(J):window,oe=re.nodeName&&re.nodeName.toLowerCase(),oe==="select"||oe==="input"&&re.type==="file")var Et=zf;else if(kf(re))if(Bf)Et=I0;else{Et=U0;var ze=L0}else oe=re.nodeName,!oe||oe.toLowerCase()!=="input"||re.type!=="checkbox"&&re.type!=="radio"?J&&Lc(J.elementType)&&(Et=zf):Et=D0;if(Et&&(Et=Et(e,J))){Ff(me,Et,n,de);break e}ze&&ze(e,re,J),e==="focusout"&&J&&re.type==="number"&&J.memoizedProps.value!=null&&yr(re,"number",re.value)}switch(ze=J?ne(J):window,e){case"focusin":(kf(ze)||ze.contentEditable==="true")&&(Ra=ze,jc=J,Fs=null);break;case"focusout":Fs=jc=Ra=null;break;case"mousedown":Xc=!0;break;case"contextmenu":case"mouseup":case"dragend":Xc=!1,qf(me,n,de);break;case"selectionchange":if(O0)break;case"keydown":case"keyup":qf(me,n,de)}var nt;if(Hc)e:{switch(e){case"compositionstart":var gt="onCompositionStart";break e;case"compositionend":gt="onCompositionEnd";break e;case"compositionupdate":gt="onCompositionUpdate";break e}gt=void 0}else Ta?Nf(e,n)&&(gt="onCompositionEnd"):e==="keydown"&&n.keyCode===229&&(gt="onCompositionStart");gt&&(Uf&&n.locale!=="ko"&&(Ta||gt!=="onCompositionStart"?gt==="onCompositionEnd"&&Ta&&(nt=Rf()):(cn=de,Oc="value"in cn?cn.value:cn.textContent,Ta=!0)),ze=Ul(J,gt),0<ze.length&&(gt=new Pf(gt,e,null,n,de),me.push({event:gt,listeners:ze}),nt?gt.data=nt:(nt=Of(n),nt!==null&&(gt.data=nt)))),(nt=T0?R0(e,n):C0(e,n))&&(gt=Ul(J,"onBeforeInput"),0<gt.length&&(ze=new Pf("onBeforeInput","beforeinput",null,n,de),me.push({event:ze,listeners:gt}),ze.data=nt)),yy(me,e,J,n,de)}xg(me,r)})}function co(e,r,n){return{instance:e,listener:r,currentTarget:n}}function Ul(e,r){for(var n=r+"Capture",s=[];e!==null;){var c=e,d=c.stateNode;if(c=c.tag,c!==5&&c!==26&&c!==27||d===null||(c=Ps(e,n),c!=null&&s.unshift(co(e,c,d)),c=Ps(e,r),c!=null&&s.push(co(e,c,d))),e.tag===3)return s;e=e.return}return[]}function My(e){if(e===null)return null;do e=e.return;while(e&&e.tag!==5&&e.tag!==27);return e||null}function bg(e,r,n,s,c){for(var d=r._reactName,g=[];n!==null&&n!==s;){var M=n,z=M.alternate,J=M.stateNode;if(M=M.tag,z!==null&&z===s)break;M!==5&&M!==26&&M!==27||J===null||(z=J,c?(J=Ps(n,d),J!=null&&g.unshift(co(n,J,z))):c||(J=Ps(n,d),J!=null&&g.push(co(n,J,z)))),n=n.return}g.length!==0&&e.push({event:r,listeners:g})}var Ey=/\r\n?/g,wy=/\u0000|\uFFFD/g;function Mg(e){return(typeof e=="string"?e:""+e).replace(Ey,`
`).replace(wy,"")}function Eg(e,r){return r=Mg(r),Mg(e)===r}function Nt(e,r,n,s,c,d){switch(n){case"children":typeof s=="string"?r==="body"||r==="textarea"&&s===""||Lr(e,s):(typeof s=="number"||typeof s=="bigint")&&r!=="body"&&Lr(e,""+s);break;case"className":Wt(e,"class",s);break;case"tabIndex":Wt(e,"tabindex",s);break;case"dir":case"role":case"viewBox":case"width":case"height":Wt(e,n,s);break;case"style":Ef(e,s,d);break;case"data":if(r!=="object"){Wt(e,"data",s);break}case"src":case"href":if(s===""&&(r!=="a"||n!=="href")){e.removeAttribute(n);break}if(s==null||typeof s=="function"||typeof s=="symbol"||typeof s=="boolean"){e.removeAttribute(n);break}s=Fo(""+s),e.setAttribute(n,s);break;case"action":case"formAction":if(typeof s=="function"){e.setAttribute(n,"javascript:throw new Error('A React form was unexpectedly submitted. If you called form.submit() manually, consider using form.requestSubmit() instead. If you\\'re trying to use event.stopPropagation() in a submit event handler, consider also calling event.preventDefault().')");break}else typeof d=="function"&&(n==="formAction"?(r!=="input"&&Nt(e,r,"name",c.name,c,null),Nt(e,r,"formEncType",c.formEncType,c,null),Nt(e,r,"formMethod",c.formMethod,c,null),Nt(e,r,"formTarget",c.formTarget,c,null)):(Nt(e,r,"encType",c.encType,c,null),Nt(e,r,"method",c.method,c,null),Nt(e,r,"target",c.target,c,null)));if(s==null||typeof s=="symbol"||typeof s=="boolean"){e.removeAttribute(n);break}s=Fo(""+s),e.setAttribute(n,s);break;case"onClick":s!=null&&(e.onclick=Ii);break;case"onScroll":s!=null&&ft("scroll",e);break;case"onScrollEnd":s!=null&&ft("scrollend",e);break;case"dangerouslySetInnerHTML":if(s!=null){if(typeof s!="object"||!("__html"in s))throw Error(a(61));if(n=s.__html,n!=null){if(c.children!=null)throw Error(a(60));e.innerHTML=n}}break;case"multiple":e.multiple=s&&typeof s!="function"&&typeof s!="symbol";break;case"muted":e.muted=s&&typeof s!="function"&&typeof s!="symbol";break;case"suppressContentEditableWarning":case"suppressHydrationWarning":case"defaultValue":case"defaultChecked":case"innerHTML":case"ref":break;case"autoFocus":break;case"xlinkHref":if(s==null||typeof s=="function"||typeof s=="boolean"||typeof s=="symbol"){e.removeAttribute("xlink:href");break}n=Fo(""+s),e.setAttributeNS("http://www.w3.org/1999/xlink","xlink:href",n);break;case"contentEditable":case"spellCheck":case"draggable":case"value":case"autoReverse":case"externalResourcesRequired":case"focusable":case"preserveAlpha":s!=null&&typeof s!="function"&&typeof s!="symbol"?e.setAttribute(n,""+s):e.removeAttribute(n);break;case"inert":case"allowFullScreen":case"async":case"autoPlay":case"controls":case"default":case"defer":case"disabled":case"disablePictureInPicture":case"disableRemotePlayback":case"formNoValidate":case"hidden":case"loop":case"noModule":case"noValidate":case"open":case"playsInline":case"readOnly":case"required":case"reversed":case"scoped":case"seamless":case"itemScope":s&&typeof s!="function"&&typeof s!="symbol"?e.setAttribute(n,""):e.removeAttribute(n);break;case"capture":case"download":s===!0?e.setAttribute(n,""):s!==!1&&s!=null&&typeof s!="function"&&typeof s!="symbol"?e.setAttribute(n,s):e.removeAttribute(n);break;case"cols":case"rows":case"size":case"span":s!=null&&typeof s!="function"&&typeof s!="symbol"&&!isNaN(s)&&1<=s?e.setAttribute(n,s):e.removeAttribute(n);break;case"rowSpan":case"start":s==null||typeof s=="function"||typeof s=="symbol"||isNaN(s)?e.removeAttribute(n):e.setAttribute(n,s);break;case"popover":ft("beforetoggle",e),ft("toggle",e),Mt(e,"popover",s);break;case"xlinkActuate":ct(e,"http://www.w3.org/1999/xlink","xlink:actuate",s);break;case"xlinkArcrole":ct(e,"http://www.w3.org/1999/xlink","xlink:arcrole",s);break;case"xlinkRole":ct(e,"http://www.w3.org/1999/xlink","xlink:role",s);break;case"xlinkShow":ct(e,"http://www.w3.org/1999/xlink","xlink:show",s);break;case"xlinkTitle":ct(e,"http://www.w3.org/1999/xlink","xlink:title",s);break;case"xlinkType":ct(e,"http://www.w3.org/1999/xlink","xlink:type",s);break;case"xmlBase":ct(e,"http://www.w3.org/XML/1998/namespace","xml:base",s);break;case"xmlLang":ct(e,"http://www.w3.org/XML/1998/namespace","xml:lang",s);break;case"xmlSpace":ct(e,"http://www.w3.org/XML/1998/namespace","xml:space",s);break;case"is":Mt(e,"is",s);break;case"innerText":case"textContent":break;default:(!(2<n.length)||n[0]!=="o"&&n[0]!=="O"||n[1]!=="n"&&n[1]!=="N")&&(n=J_.get(n)||n,Mt(e,n,s))}}function vd(e,r,n,s,c,d){switch(n){case"style":Ef(e,s,d);break;case"dangerouslySetInnerHTML":if(s!=null){if(typeof s!="object"||!("__html"in s))throw Error(a(61));if(n=s.__html,n!=null){if(c.children!=null)throw Error(a(60));e.innerHTML=n}}break;case"children":typeof s=="string"?Lr(e,s):(typeof s=="number"||typeof s=="bigint")&&Lr(e,""+s);break;case"onScroll":s!=null&&ft("scroll",e);break;case"onScrollEnd":s!=null&&ft("scrollend",e);break;case"onClick":s!=null&&(e.onclick=Ii);break;case"suppressContentEditableWarning":case"suppressHydrationWarning":case"innerHTML":case"ref":break;case"innerText":case"textContent":break;default:if(!De.hasOwnProperty(n))e:{if(n[0]==="o"&&n[1]==="n"&&(c=n.endsWith("Capture"),r=n.slice(2,c?n.length-7:void 0),d=e[dr]||null,d=d!=null?d[n]:null,typeof d=="function"&&e.removeEventListener(r,d,c),typeof s=="function")){typeof d!="function"&&d!==null&&(n in e?e[n]=null:e.hasAttribute(n)&&e.removeAttribute(n)),e.addEventListener(r,s,c);break e}n in e?e[n]=s:s===!0?e.setAttribute(n,""):Mt(e,n,s)}}}function vr(e,r,n){switch(r){case"div":case"span":case"svg":case"path":case"a":case"g":case"p":case"li":break;case"img":ft("error",e),ft("load",e);var s=!1,c=!1,d;for(d in n)if(n.hasOwnProperty(d)){var g=n[d];if(g!=null)switch(d){case"src":s=!0;break;case"srcSet":c=!0;break;case"children":case"dangerouslySetInnerHTML":throw Error(a(137,r));default:Nt(e,r,d,g,n,null)}}c&&Nt(e,r,"srcSet",n.srcSet,n,null),s&&Nt(e,r,"src",n.src,n,null);return;case"input":ft("invalid",e);var M=d=g=c=null,z=null,J=null;for(s in n)if(n.hasOwnProperty(s)){var de=n[s];if(de!=null)switch(s){case"name":c=de;break;case"type":g=de;break;case"checked":z=de;break;case"defaultChecked":J=de;break;case"value":d=de;break;case"defaultValue":M=de;break;case"children":case"dangerouslySetInnerHTML":if(de!=null)throw Error(a(137,r));break;default:Nt(e,r,s,de,n,null)}}Tr(e,d,M,z,J,g,c,!1);return;case"select":ft("invalid",e),s=g=d=null;for(c in n)if(n.hasOwnProperty(c)&&(M=n[c],M!=null))switch(c){case"value":d=M;break;case"defaultValue":g=M;break;case"multiple":s=M;default:Nt(e,r,c,M,n,null)}r=d,n=g,e.multiple=!!s,r!=null?jt(e,!!s,r,!1):n!=null&&jt(e,!!s,n,!0);return;case"textarea":ft("invalid",e),d=c=s=null;for(g in n)if(n.hasOwnProperty(g)&&(M=n[g],M!=null))switch(g){case"value":s=M;break;case"defaultValue":c=M;break;case"children":d=M;break;case"dangerouslySetInnerHTML":if(M!=null)throw Error(a(91));break;default:Nt(e,r,g,M,n,null)}Ma(e,s,c,d);return;case"option":for(z in n)if(n.hasOwnProperty(z)&&(s=n[z],s!=null))switch(z){case"selected":e.selected=s&&typeof s!="function"&&typeof s!="symbol";break;default:Nt(e,r,z,s,n,null)}return;case"dialog":ft("beforetoggle",e),ft("toggle",e),ft("cancel",e),ft("close",e);break;case"iframe":case"object":ft("load",e);break;case"video":case"audio":for(s=0;s<lo.length;s++)ft(lo[s],e);break;case"image":ft("error",e),ft("load",e);break;case"details":ft("toggle",e);break;case"embed":case"source":case"link":ft("error",e),ft("load",e);case"area":case"base":case"br":case"col":case"hr":case"keygen":case"meta":case"param":case"track":case"wbr":case"menuitem":for(J in n)if(n.hasOwnProperty(J)&&(s=n[J],s!=null))switch(J){case"children":case"dangerouslySetInnerHTML":throw Error(a(137,r));default:Nt(e,r,J,s,n,null)}return;default:if(Lc(r)){for(de in n)n.hasOwnProperty(de)&&(s=n[de],s!==void 0&&vd(e,r,de,s,n,void 0));return}}for(M in n)n.hasOwnProperty(M)&&(s=n[M],s!=null&&Nt(e,r,M,s,n,null))}function Ty(e,r,n,s){switch(r){case"div":case"span":case"svg":case"path":case"a":case"g":case"p":case"li":break;case"input":var c=null,d=null,g=null,M=null,z=null,J=null,de=null;for(oe in n){var me=n[oe];if(n.hasOwnProperty(oe)&&me!=null)switch(oe){case"checked":break;case"value":break;case"defaultValue":z=me;default:s.hasOwnProperty(oe)||Nt(e,r,oe,null,s,me)}}for(var re in s){var oe=s[re];if(me=n[re],s.hasOwnProperty(re)&&(oe!=null||me!=null))switch(re){case"type":d=oe;break;case"name":c=oe;break;case"checked":J=oe;break;case"defaultChecked":de=oe;break;case"value":g=oe;break;case"defaultValue":M=oe;break;case"children":case"dangerouslySetInnerHTML":if(oe!=null)throw Error(a(137,r));break;default:oe!==me&&Nt(e,r,re,oe,s,me)}}Dt(e,g,M,z,J,de,d,c);return;case"select":oe=g=M=re=null;for(d in n)if(z=n[d],n.hasOwnProperty(d)&&z!=null)switch(d){case"value":break;case"multiple":oe=z;default:s.hasOwnProperty(d)||Nt(e,r,d,null,s,z)}for(c in s)if(d=s[c],z=n[c],s.hasOwnProperty(c)&&(d!=null||z!=null))switch(c){case"value":re=d;break;case"defaultValue":M=d;break;case"multiple":g=d;default:d!==z&&Nt(e,r,c,d,s,z)}r=M,n=g,s=oe,re!=null?jt(e,!!n,re,!1):!!s!=!!n&&(r!=null?jt(e,!!n,r,!0):jt(e,!!n,n?[]:"",!1));return;case"textarea":oe=re=null;for(M in n)if(c=n[M],n.hasOwnProperty(M)&&c!=null&&!s.hasOwnProperty(M))switch(M){case"value":break;case"children":break;default:Nt(e,r,M,null,s,c)}for(g in s)if(c=s[g],d=n[g],s.hasOwnProperty(g)&&(c!=null||d!=null))switch(g){case"value":re=c;break;case"defaultValue":oe=c;break;case"children":break;case"dangerouslySetInnerHTML":if(c!=null)throw Error(a(91));break;default:c!==d&&Nt(e,r,g,c,s,d)}Pr(e,re,oe);return;case"option":for(var Oe in n)if(re=n[Oe],n.hasOwnProperty(Oe)&&re!=null&&!s.hasOwnProperty(Oe))switch(Oe){case"selected":e.selected=!1;break;default:Nt(e,r,Oe,null,s,re)}for(z in s)if(re=s[z],oe=n[z],s.hasOwnProperty(z)&&re!==oe&&(re!=null||oe!=null))switch(z){case"selected":e.selected=re&&typeof re!="function"&&typeof re!="symbol";break;default:Nt(e,r,z,re,s,oe)}return;case"img":case"link":case"area":case"base":case"br":case"col":case"embed":case"hr":case"keygen":case"meta":case"param":case"source":case"track":case"wbr":case"menuitem":for(var Qe in n)re=n[Qe],n.hasOwnProperty(Qe)&&re!=null&&!s.hasOwnProperty(Qe)&&Nt(e,r,Qe,null,s,re);for(J in s)if(re=s[J],oe=n[J],s.hasOwnProperty(J)&&re!==oe&&(re!=null||oe!=null))switch(J){case"children":case"dangerouslySetInnerHTML":if(re!=null)throw Error(a(137,r));break;default:Nt(e,r,J,re,s,oe)}return;default:if(Lc(r)){for(var Ot in n)re=n[Ot],n.hasOwnProperty(Ot)&&re!==void 0&&!s.hasOwnProperty(Ot)&&vd(e,r,Ot,void 0,s,re);for(de in s)re=s[de],oe=n[de],!s.hasOwnProperty(de)||re===oe||re===void 0&&oe===void 0||vd(e,r,de,re,s,oe);return}}for(var Y in n)re=n[Y],n.hasOwnProperty(Y)&&re!=null&&!s.hasOwnProperty(Y)&&Nt(e,r,Y,null,s,re);for(me in s)re=s[me],oe=n[me],!s.hasOwnProperty(me)||re===oe||re==null&&oe==null||Nt(e,r,me,re,s,oe)}function wg(e){switch(e){case"css":case"script":case"font":case"img":case"image":case"input":case"link":return!0;default:return!1}}function Ry(){if(typeof performance.getEntriesByType=="function"){for(var e=0,r=0,n=performance.getEntriesByType("resource"),s=0;s<n.length;s++){var c=n[s],d=c.transferSize,g=c.initiatorType,M=c.duration;if(d&&M&&wg(g)){for(g=0,M=c.responseEnd,s+=1;s<n.length;s++){var z=n[s],J=z.startTime;if(J>M)break;var de=z.transferSize,me=z.initiatorType;de&&wg(me)&&(z=z.responseEnd,g+=de*(z<M?1:(M-J)/(z-J)))}if(--s,r+=8*(d+g)/(c.duration/1e3),e++,10<e)break}}if(0<e)return r/e/1e6}return navigator.connection&&(e=navigator.connection.downlink,typeof e=="number")?e:5}var _d=null,yd=null;function Dl(e){return e.nodeType===9?e:e.ownerDocument}function Tg(e){switch(e){case"http://www.w3.org/2000/svg":return 1;case"http://www.w3.org/1998/Math/MathML":return 2;default:return 0}}function Rg(e,r){if(e===0)switch(r){case"svg":return 1;case"math":return 2;default:return 0}return e===1&&r==="foreignObject"?0:e}function xd(e,r){return e==="textarea"||e==="noscript"||typeof r.children=="string"||typeof r.children=="number"||typeof r.children=="bigint"||typeof r.dangerouslySetInnerHTML=="object"&&r.dangerouslySetInnerHTML!==null&&r.dangerouslySetInnerHTML.__html!=null}var Sd=null;function Cy(){var e=window.event;return e&&e.type==="popstate"?e===Sd?!1:(Sd=e,!0):(Sd=null,!1)}var Cg=typeof setTimeout=="function"?setTimeout:void 0,Ay=typeof clearTimeout=="function"?clearTimeout:void 0,Ag=typeof Promise=="function"?Promise:void 0,Py=typeof queueMicrotask=="function"?queueMicrotask:typeof Ag<"u"?function(e){return Ag.resolve(null).then(e).catch(Ly)}:Cg;function Ly(e){setTimeout(function(){throw e})}function Tn(e){return e==="head"}function Pg(e,r){var n=r,s=0;do{var c=n.nextSibling;if(e.removeChild(n),c&&c.nodeType===8)if(n=c.data,n==="/$"||n==="/&"){if(s===0){e.removeChild(c),es(r);return}s--}else if(n==="$"||n==="$?"||n==="$~"||n==="$!"||n==="&")s++;else if(n==="html")uo(e.ownerDocument.documentElement);else if(n==="head"){n=e.ownerDocument.head,uo(n);for(var d=n.firstChild;d;){var g=d.nextSibling,M=d.nodeName;d[jn]||M==="SCRIPT"||M==="STYLE"||M==="LINK"&&d.rel.toLowerCase()==="stylesheet"||n.removeChild(d),d=g}}else n==="body"&&uo(e.ownerDocument.body);n=c}while(n);es(r)}function Lg(e,r){var n=e;e=0;do{var s=n.nextSibling;if(n.nodeType===1?r?(n._stashedDisplay=n.style.display,n.style.display="none"):(n.style.display=n._stashedDisplay||"",n.getAttribute("style")===""&&n.removeAttribute("style")):n.nodeType===3&&(r?(n._stashedText=n.nodeValue,n.nodeValue=""):n.nodeValue=n._stashedText||""),s&&s.nodeType===8)if(n=s.data,n==="/$"){if(e===0)break;e--}else n!=="$"&&n!=="$?"&&n!=="$~"&&n!=="$!"||e++;n=s}while(n)}function bd(e){var r=e.firstChild;for(r&&r.nodeType===10&&(r=r.nextSibling);r;){var n=r;switch(r=r.nextSibling,n.nodeName){case"HTML":case"HEAD":case"BODY":bd(n),As(n);continue;case"SCRIPT":case"STYLE":continue;case"LINK":if(n.rel.toLowerCase()==="stylesheet")continue}e.removeChild(n)}}function Uy(e,r,n,s){for(;e.nodeType===1;){var c=n;if(e.nodeName.toLowerCase()!==r.toLowerCase()){if(!s&&(e.nodeName!=="INPUT"||e.type!=="hidden"))break}else if(s){if(!e[jn])switch(r){case"meta":if(!e.hasAttribute("itemprop"))break;return e;case"link":if(d=e.getAttribute("rel"),d==="stylesheet"&&e.hasAttribute("data-precedence")||d!==c.rel||e.getAttribute("href")!==(c.href==null||c.href===""?null:c.href)||e.getAttribute("crossorigin")!==(c.crossOrigin==null?null:c.crossOrigin)||e.getAttribute("title")!==(c.title==null?null:c.title))break;return e;case"style":if(e.hasAttribute("data-precedence"))break;return e;case"script":if(d=e.getAttribute("src"),(d!==(c.src==null?null:c.src)||e.getAttribute("type")!==(c.type==null?null:c.type)||e.getAttribute("crossorigin")!==(c.crossOrigin==null?null:c.crossOrigin))&&d&&e.hasAttribute("async")&&!e.hasAttribute("itemprop"))break;return e;default:return e}}else if(r==="input"&&e.type==="hidden"){var d=c.name==null?null:""+c.name;if(c.type==="hidden"&&e.getAttribute("name")===d)return e}else return e;if(e=ri(e.nextSibling),e===null)break}return null}function Dy(e,r,n){if(r==="")return null;for(;e.nodeType!==3;)if((e.nodeType!==1||e.nodeName!=="INPUT"||e.type!=="hidden")&&!n||(e=ri(e.nextSibling),e===null))return null;return e}function Ug(e,r){for(;e.nodeType!==8;)if((e.nodeType!==1||e.nodeName!=="INPUT"||e.type!=="hidden")&&!r||(e=ri(e.nextSibling),e===null))return null;return e}function Md(e){return e.data==="$?"||e.data==="$~"}function Ed(e){return e.data==="$!"||e.data==="$?"&&e.ownerDocument.readyState!=="loading"}function Iy(e,r){var n=e.ownerDocument;if(e.data==="$~")e._reactRetry=r;else if(e.data!=="$?"||n.readyState!=="loading")r();else{var s=function(){r(),n.removeEventListener("DOMContentLoaded",s)};n.addEventListener("DOMContentLoaded",s),e._reactRetry=s}}function ri(e){for(;e!=null;e=e.nextSibling){var r=e.nodeType;if(r===1||r===3)break;if(r===8){if(r=e.data,r==="$"||r==="$!"||r==="$?"||r==="$~"||r==="&"||r==="F!"||r==="F")break;if(r==="/$"||r==="/&")return null}}return e}var wd=null;function Dg(e){e=e.nextSibling;for(var r=0;e;){if(e.nodeType===8){var n=e.data;if(n==="/$"||n==="/&"){if(r===0)return ri(e.nextSibling);r--}else n!=="$"&&n!=="$!"&&n!=="$?"&&n!=="$~"&&n!=="&"||r++}e=e.nextSibling}return null}function Ig(e){e=e.previousSibling;for(var r=0;e;){if(e.nodeType===8){var n=e.data;if(n==="$"||n==="$!"||n==="$?"||n==="$~"||n==="&"){if(r===0)return e;r--}else n!=="/$"&&n!=="/&"||r++}e=e.previousSibling}return null}function Ng(e,r,n){switch(r=Dl(n),e){case"html":if(e=r.documentElement,!e)throw Error(a(452));return e;case"head":if(e=r.head,!e)throw Error(a(453));return e;case"body":if(e=r.body,!e)throw Error(a(454));return e;default:throw Error(a(451))}}function uo(e){for(var r=e.attributes;r.length;)e.removeAttributeNode(r[0]);As(e)}var ii=new Map,Og=new Set;function Il(e){return typeof e.getRootNode=="function"?e.getRootNode():e.nodeType===9?e:e.ownerDocument}var $i=K.d;K.d={f:Ny,r:Oy,D:ky,C:Fy,L:zy,m:By,X:Vy,S:Hy,M:Gy};function Ny(){var e=$i.f(),r=wl();return e||r}function Oy(e){var r=X(e);r!==null&&r.tag===5&&r.type==="form"?Jp(r):$i.r(e)}var Ka=typeof document>"u"?null:document;function kg(e,r,n){var s=Ka;if(s&&typeof r=="string"&&r){var c=fr(r);c='link[rel="'+e+'"][href="'+c+'"]',typeof n=="string"&&(c+='[crossorigin="'+n+'"]'),Og.has(c)||(Og.add(c),e={rel:e,crossOrigin:n,href:r},s.querySelector(c)===null&&(r=s.createElement("link"),vr(r,"link",e),W(r),s.head.appendChild(r)))}}function ky(e){$i.D(e),kg("dns-prefetch",e,null)}function Fy(e,r){$i.C(e,r),kg("preconnect",e,r)}function zy(e,r,n){$i.L(e,r,n);var s=Ka;if(s&&e&&r){var c='link[rel="preload"][as="'+fr(r)+'"]';r==="image"&&n&&n.imageSrcSet?(c+='[imagesrcset="'+fr(n.imageSrcSet)+'"]',typeof n.imageSizes=="string"&&(c+='[imagesizes="'+fr(n.imageSizes)+'"]')):c+='[href="'+fr(e)+'"]';var d=c;switch(r){case"style":d=Za(e);break;case"script":d=Ja(e)}ii.has(d)||(e=y({rel:"preload",href:r==="image"&&n&&n.imageSrcSet?void 0:e,as:r},n),ii.set(d,e),s.querySelector(c)!==null||r==="style"&&s.querySelector(ho(d))||r==="script"&&s.querySelector(fo(d))||(r=s.createElement("link"),vr(r,"link",e),W(r),s.head.appendChild(r)))}}function By(e,r){$i.m(e,r);var n=Ka;if(n&&e){var s=r&&typeof r.as=="string"?r.as:"script",c='link[rel="modulepreload"][as="'+fr(s)+'"][href="'+fr(e)+'"]',d=c;switch(s){case"audioworklet":case"paintworklet":case"serviceworker":case"sharedworker":case"worker":case"script":d=Ja(e)}if(!ii.has(d)&&(e=y({rel:"modulepreload",href:e},r),ii.set(d,e),n.querySelector(c)===null)){switch(s){case"audioworklet":case"paintworklet":case"serviceworker":case"sharedworker":case"worker":case"script":if(n.querySelector(fo(d)))return}s=n.createElement("link"),vr(s,"link",e),W(s),n.head.appendChild(s)}}}function Hy(e,r,n){$i.S(e,r,n);var s=Ka;if(s&&e){var c=ae(s).hoistableStyles,d=Za(e);r=r||"default";var g=c.get(d);if(!g){var M={loading:0,preload:null};if(g=s.querySelector(ho(d)))M.loading=5;else{e=y({rel:"stylesheet",href:e,"data-precedence":r},n),(n=ii.get(d))&&Td(e,n);var z=g=s.createElement("link");W(z),vr(z,"link",e),z._p=new Promise(function(J,de){z.onload=J,z.onerror=de}),z.addEventListener("load",function(){M.loading|=1}),z.addEventListener("error",function(){M.loading|=2}),M.loading|=4,Nl(g,r,s)}g={type:"stylesheet",instance:g,count:1,state:M},c.set(d,g)}}}function Vy(e,r){$i.X(e,r);var n=Ka;if(n&&e){var s=ae(n).hoistableScripts,c=Ja(e),d=s.get(c);d||(d=n.querySelector(fo(c)),d||(e=y({src:e,async:!0},r),(r=ii.get(c))&&Rd(e,r),d=n.createElement("script"),W(d),vr(d,"link",e),n.head.appendChild(d)),d={type:"script",instance:d,count:1,state:null},s.set(c,d))}}function Gy(e,r){$i.M(e,r);var n=Ka;if(n&&e){var s=ae(n).hoistableScripts,c=Ja(e),d=s.get(c);d||(d=n.querySelector(fo(c)),d||(e=y({src:e,async:!0,type:"module"},r),(r=ii.get(c))&&Rd(e,r),d=n.createElement("script"),W(d),vr(d,"link",e),n.head.appendChild(d)),d={type:"script",instance:d,count:1,state:null},s.set(c,d))}}function Fg(e,r,n,s){var c=(c=Me.current)?Il(c):null;if(!c)throw Error(a(446));switch(e){case"meta":case"title":return null;case"style":return typeof n.precedence=="string"&&typeof n.href=="string"?(r=Za(n.href),n=ae(c).hoistableStyles,s=n.get(r),s||(s={type:"style",instance:null,count:0,state:null},n.set(r,s)),s):{type:"void",instance:null,count:0,state:null};case"link":if(n.rel==="stylesheet"&&typeof n.href=="string"&&typeof n.precedence=="string"){e=Za(n.href);var d=ae(c).hoistableStyles,g=d.get(e);if(g||(c=c.ownerDocument||c,g={type:"stylesheet",instance:null,count:0,state:{loading:0,preload:null}},d.set(e,g),(d=c.querySelector(ho(e)))&&!d._p&&(g.instance=d,g.state.loading=5),ii.has(e)||(n={rel:"preload",as:"style",href:n.href,crossOrigin:n.crossOrigin,integrity:n.integrity,media:n.media,hrefLang:n.hrefLang,referrerPolicy:n.referrerPolicy},ii.set(e,n),d||Wy(c,e,n,g.state))),r&&s===null)throw Error(a(528,""));return g}if(r&&s!==null)throw Error(a(529,""));return null;case"script":return r=n.async,n=n.src,typeof n=="string"&&r&&typeof r!="function"&&typeof r!="symbol"?(r=Ja(n),n=ae(c).hoistableScripts,s=n.get(r),s||(s={type:"script",instance:null,count:0,state:null},n.set(r,s)),s):{type:"void",instance:null,count:0,state:null};default:throw Error(a(444,e))}}function Za(e){return'href="'+fr(e)+'"'}function ho(e){return'link[rel="stylesheet"]['+e+"]"}function zg(e){return y({},e,{"data-precedence":e.precedence,precedence:null})}function Wy(e,r,n,s){e.querySelector('link[rel="preload"][as="style"]['+r+"]")?s.loading=1:(r=e.createElement("link"),s.preload=r,r.addEventListener("load",function(){return s.loading|=1}),r.addEventListener("error",function(){return s.loading|=2}),vr(r,"link",n),W(r),e.head.appendChild(r))}function Ja(e){return'[src="'+fr(e)+'"]'}function fo(e){return"script[async]"+e}function Bg(e,r,n){if(r.count++,r.instance===null)switch(r.type){case"style":var s=e.querySelector('style[data-href~="'+fr(n.href)+'"]');if(s)return r.instance=s,W(s),s;var c=y({},n,{"data-href":n.href,"data-precedence":n.precedence,href:null,precedence:null});return s=(e.ownerDocument||e).createElement("style"),W(s),vr(s,"style",c),Nl(s,n.precedence,e),r.instance=s;case"stylesheet":c=Za(n.href);var d=e.querySelector(ho(c));if(d)return r.state.loading|=4,r.instance=d,W(d),d;s=zg(n),(c=ii.get(c))&&Td(s,c),d=(e.ownerDocument||e).createElement("link"),W(d);var g=d;return g._p=new Promise(function(M,z){g.onload=M,g.onerror=z}),vr(d,"link",s),r.state.loading|=4,Nl(d,n.precedence,e),r.instance=d;case"script":return d=Ja(n.src),(c=e.querySelector(fo(d)))?(r.instance=c,W(c),c):(s=n,(c=ii.get(d))&&(s=y({},n),Rd(s,c)),e=e.ownerDocument||e,c=e.createElement("script"),W(c),vr(c,"link",s),e.head.appendChild(c),r.instance=c);case"void":return null;default:throw Error(a(443,r.type))}else r.type==="stylesheet"&&(r.state.loading&4)===0&&(s=r.instance,r.state.loading|=4,Nl(s,n.precedence,e));return r.instance}function Nl(e,r,n){for(var s=n.querySelectorAll('link[rel="stylesheet"][data-precedence],style[data-precedence]'),c=s.length?s[s.length-1]:null,d=c,g=0;g<s.length;g++){var M=s[g];if(M.dataset.precedence===r)d=M;else if(d!==c)break}d?d.parentNode.insertBefore(e,d.nextSibling):(r=n.nodeType===9?n.head:n,r.insertBefore(e,r.firstChild))}function Td(e,r){e.crossOrigin==null&&(e.crossOrigin=r.crossOrigin),e.referrerPolicy==null&&(e.referrerPolicy=r.referrerPolicy),e.title==null&&(e.title=r.title)}function Rd(e,r){e.crossOrigin==null&&(e.crossOrigin=r.crossOrigin),e.referrerPolicy==null&&(e.referrerPolicy=r.referrerPolicy),e.integrity==null&&(e.integrity=r.integrity)}var Ol=null;function Hg(e,r,n){if(Ol===null){var s=new Map,c=Ol=new Map;c.set(n,s)}else c=Ol,s=c.get(n),s||(s=new Map,c.set(n,s));if(s.has(e))return s;for(s.set(e,null),n=n.getElementsByTagName(e),c=0;c<n.length;c++){var d=n[c];if(!(d[jn]||d[qt]||e==="link"&&d.getAttribute("rel")==="stylesheet")&&d.namespaceURI!=="http://www.w3.org/2000/svg"){var g=d.getAttribute(r)||"";g=e+g;var M=s.get(g);M?M.push(d):s.set(g,[d])}}return s}function Vg(e,r,n){e=e.ownerDocument||e,e.head.insertBefore(n,r==="title"?e.querySelector("head > title"):null)}function jy(e,r,n){if(n===1||r.itemProp!=null)return!1;switch(e){case"meta":case"title":return!0;case"style":if(typeof r.precedence!="string"||typeof r.href!="string"||r.href==="")break;return!0;case"link":if(typeof r.rel!="string"||typeof r.href!="string"||r.href===""||r.onLoad||r.onError)break;switch(r.rel){case"stylesheet":return e=r.disabled,typeof r.precedence=="string"&&e==null;default:return!0}case"script":if(r.async&&typeof r.async!="function"&&typeof r.async!="symbol"&&!r.onLoad&&!r.onError&&r.src&&typeof r.src=="string")return!0}return!1}function Gg(e){return!(e.type==="stylesheet"&&(e.state.loading&3)===0)}function Xy(e,r,n,s){if(n.type==="stylesheet"&&(typeof s.media!="string"||matchMedia(s.media).matches!==!1)&&(n.state.loading&4)===0){if(n.instance===null){var c=Za(s.href),d=r.querySelector(ho(c));if(d){r=d._p,r!==null&&typeof r=="object"&&typeof r.then=="function"&&(e.count++,e=kl.bind(e),r.then(e,e)),n.state.loading|=4,n.instance=d,W(d);return}d=r.ownerDocument||r,s=zg(s),(c=ii.get(c))&&Td(s,c),d=d.createElement("link"),W(d);var g=d;g._p=new Promise(function(M,z){g.onload=M,g.onerror=z}),vr(d,"link",s),n.instance=d}e.stylesheets===null&&(e.stylesheets=new Map),e.stylesheets.set(n,r),(r=n.state.preload)&&(n.state.loading&3)===0&&(e.count++,n=kl.bind(e),r.addEventListener("load",n),r.addEventListener("error",n))}}var Cd=0;function Yy(e,r){return e.stylesheets&&e.count===0&&zl(e,e.stylesheets),0<e.count||0<e.imgCount?function(n){var s=setTimeout(function(){if(e.stylesheets&&zl(e,e.stylesheets),e.unsuspend){var d=e.unsuspend;e.unsuspend=null,d()}},6e4+r);0<e.imgBytes&&Cd===0&&(Cd=62500*Ry());var c=setTimeout(function(){if(e.waitingForImages=!1,e.count===0&&(e.stylesheets&&zl(e,e.stylesheets),e.unsuspend)){var d=e.unsuspend;e.unsuspend=null,d()}},(e.imgBytes>Cd?50:800)+r);return e.unsuspend=n,function(){e.unsuspend=null,clearTimeout(s),clearTimeout(c)}}:null}function kl(){if(this.count--,this.count===0&&(this.imgCount===0||!this.waitingForImages)){if(this.stylesheets)zl(this,this.stylesheets);else if(this.unsuspend){var e=this.unsuspend;this.unsuspend=null,e()}}}var Fl=null;function zl(e,r){e.stylesheets=null,e.unsuspend!==null&&(e.count++,Fl=new Map,r.forEach(qy,e),Fl=null,kl.call(e))}function qy(e,r){if(!(r.state.loading&4)){var n=Fl.get(e);if(n)var s=n.get(null);else{n=new Map,Fl.set(e,n);for(var c=e.querySelectorAll("link[data-precedence],style[data-precedence]"),d=0;d<c.length;d++){var g=c[d];(g.nodeName==="LINK"||g.getAttribute("media")!=="not all")&&(n.set(g.dataset.precedence,g),s=g)}s&&n.set(null,s)}c=r.instance,g=c.getAttribute("data-precedence"),d=n.get(g)||s,d===s&&n.set(null,c),n.set(g,c),this.count++,s=kl.bind(this),c.addEventListener("load",s),c.addEventListener("error",s),d?d.parentNode.insertBefore(c,d.nextSibling):(e=e.nodeType===9?e.head:e,e.insertBefore(c,e.firstChild)),r.state.loading|=4}}var po={$$typeof:L,Provider:null,Consumer:null,_currentValue:q,_currentValue2:q,_threadCount:0};function Qy(e,r,n,s,c,d,g,M,z){this.tag=1,this.containerInfo=e,this.pingCache=this.current=this.pendingChildren=null,this.timeoutHandle=-1,this.callbackNode=this.next=this.pendingContext=this.context=this.cancelPendingCommit=null,this.callbackPriority=0,this.expirationTimes=bt(-1),this.entangledLanes=this.shellSuspendCounter=this.errorRecoveryDisabledLanes=this.expiredLanes=this.warmLanes=this.pingedLanes=this.suspendedLanes=this.pendingLanes=0,this.entanglements=bt(0),this.hiddenUpdates=bt(null),this.identifierPrefix=s,this.onUncaughtError=c,this.onCaughtError=d,this.onRecoverableError=g,this.pooledCache=null,this.pooledCacheLanes=0,this.formState=z,this.incompleteTransitions=new Map}function Wg(e,r,n,s,c,d,g,M,z,J,de,me){return e=new Qy(e,r,n,g,z,J,de,me,M),r=1,d===!0&&(r|=24),d=Vr(3,null,null,r),e.current=d,d.stateNode=e,r=ou(),r.refCount++,e.pooledCache=r,r.refCount++,d.memoizedState={element:s,isDehydrated:n,cache:r},du(d),e}function jg(e){return e?(e=Pa,e):Pa}function Xg(e,r,n,s,c,d){c=jg(c),s.context===null?s.context=c:s.pendingContext=c,s=mn(r),s.payload={element:n},d=d===void 0?null:d,d!==null&&(s.callback=d),n=gn(e,s,r),n!==null&&(kr(n,e,r),js(n,e,r))}function Yg(e,r){if(e=e.memoizedState,e!==null&&e.dehydrated!==null){var n=e.retryLane;e.retryLane=n!==0&&n<r?n:r}}function Ad(e,r){Yg(e,r),(e=e.alternate)&&Yg(e,r)}function qg(e){if(e.tag===13||e.tag===31){var r=Qn(e,67108864);r!==null&&kr(r,e,67108864),Ad(e,67108864)}}function Qg(e){if(e.tag===13||e.tag===31){var r=Yr();r=Gn(r);var n=Qn(e,r);n!==null&&kr(n,e,r),Ad(e,r)}}var Bl=!0;function $y(e,r,n,s){var c=N.T;N.T=null;var d=K.p;try{K.p=2,Pd(e,r,n,s)}finally{K.p=d,N.T=c}}function Ky(e,r,n,s){var c=N.T;N.T=null;var d=K.p;try{K.p=8,Pd(e,r,n,s)}finally{K.p=d,N.T=c}}function Pd(e,r,n,s){if(Bl){var c=Ld(s);if(c===null)gd(e,r,s,Hl,n),Kg(e,s);else if(Jy(c,e,r,n,s))s.stopPropagation();else if(Kg(e,s),r&4&&-1<Zy.indexOf(e)){for(;c!==null;){var d=X(c);if(d!==null)switch(d.tag){case 3:if(d=d.stateNode,d.current.memoizedState.isDehydrated){var g=Re(d.pendingLanes);if(g!==0){var M=d;for(M.pendingLanes|=2,M.entangledLanes|=2;g;){var z=1<<31-Ke(g);M.entanglements[1]|=z,g&=~z}Ti(d),(Rt&6)===0&&(Ml=he()+500,oo(0))}}break;case 31:case 13:M=Qn(d,2),M!==null&&kr(M,d,2),wl(),Ad(d,2)}if(d=Ld(s),d===null&&gd(e,r,s,Hl,n),d===c)break;c=d}c!==null&&s.stopPropagation()}else gd(e,r,s,null,n)}}function Ld(e){return e=Dc(e),Ud(e)}var Hl=null;function Ud(e){if(Hl=null,e=T(e),e!==null){var r=u(e);if(r===null)e=null;else{var n=r.tag;if(n===13){if(e=h(r),e!==null)return e;e=null}else if(n===31){if(e=f(r),e!==null)return e;e=null}else if(n===3){if(r.stateNode.current.memoizedState.isDehydrated)return r.tag===3?r.stateNode.containerInfo:null;e=null}else r!==e&&(e=null)}}return Hl=e,null}function $g(e){switch(e){case"beforetoggle":case"cancel":case"click":case"close":case"contextmenu":case"copy":case"cut":case"auxclick":case"dblclick":case"dragend":case"dragstart":case"drop":case"focusin":case"focusout":case"input":case"invalid":case"keydown":case"keypress":case"keyup":case"mousedown":case"mouseup":case"paste":case"pause":case"play":case"pointercancel":case"pointerdown":case"pointerup":case"ratechange":case"reset":case"resize":case"seeked":case"submit":case"toggle":case"touchcancel":case"touchend":case"touchstart":case"volumechange":case"change":case"selectionchange":case"textInput":case"compositionstart":case"compositionend":case"compositionupdate":case"beforeblur":case"afterblur":case"beforeinput":case"blur":case"fullscreenchange":case"focus":case"hashchange":case"popstate":case"select":case"selectstart":return 2;case"drag":case"dragenter":case"dragexit":case"dragleave":case"dragover":case"mousemove":case"mouseout":case"mouseover":case"pointermove":case"pointerout":case"pointerover":case"scroll":case"touchmove":case"wheel":case"mouseenter":case"mouseleave":case"pointerenter":case"pointerleave":return 8;case"message":switch(be()){case pe:return 2;case Be:return 8;case Ce:case $e:return 32;case Ye:return 268435456;default:return 32}default:return 32}}var Dd=!1,Rn=null,Cn=null,An=null,mo=new Map,go=new Map,Pn=[],Zy="mousedown mouseup touchcancel touchend touchstart auxclick dblclick pointercancel pointerdown pointerup dragend dragstart drop compositionend compositionstart keydown keypress keyup input textInput copy cut paste click change contextmenu reset".split(" ");function Kg(e,r){switch(e){case"focusin":case"focusout":Rn=null;break;case"dragenter":case"dragleave":Cn=null;break;case"mouseover":case"mouseout":An=null;break;case"pointerover":case"pointerout":mo.delete(r.pointerId);break;case"gotpointercapture":case"lostpointercapture":go.delete(r.pointerId)}}function vo(e,r,n,s,c,d){return e===null||e.nativeEvent!==d?(e={blockedOn:r,domEventName:n,eventSystemFlags:s,nativeEvent:d,targetContainers:[c]},r!==null&&(r=X(r),r!==null&&qg(r)),e):(e.eventSystemFlags|=s,r=e.targetContainers,c!==null&&r.indexOf(c)===-1&&r.push(c),e)}function Jy(e,r,n,s,c){switch(r){case"focusin":return Rn=vo(Rn,e,r,n,s,c),!0;case"dragenter":return Cn=vo(Cn,e,r,n,s,c),!0;case"mouseover":return An=vo(An,e,r,n,s,c),!0;case"pointerover":var d=c.pointerId;return mo.set(d,vo(mo.get(d)||null,e,r,n,s,c)),!0;case"gotpointercapture":return d=c.pointerId,go.set(d,vo(go.get(d)||null,e,r,n,s,c)),!0}return!1}function Zg(e){var r=T(e.target);if(r!==null){var n=u(r);if(n!==null){if(r=n.tag,r===13){if(r=h(n),r!==null){e.blockedOn=r,Wn(e.priority,function(){Qg(n)});return}}else if(r===31){if(r=f(n),r!==null){e.blockedOn=r,Wn(e.priority,function(){Qg(n)});return}}else if(r===3&&n.stateNode.current.memoizedState.isDehydrated){e.blockedOn=n.tag===3?n.stateNode.containerInfo:null;return}}}e.blockedOn=null}function Vl(e){if(e.blockedOn!==null)return!1;for(var r=e.targetContainers;0<r.length;){var n=Ld(e.nativeEvent);if(n===null){n=e.nativeEvent;var s=new n.constructor(n.type,n);Uc=s,n.target.dispatchEvent(s),Uc=null}else return r=X(n),r!==null&&qg(r),e.blockedOn=n,!1;r.shift()}return!0}function Jg(e,r,n){Vl(e)&&n.delete(r)}function ex(){Dd=!1,Rn!==null&&Vl(Rn)&&(Rn=null),Cn!==null&&Vl(Cn)&&(Cn=null),An!==null&&Vl(An)&&(An=null),mo.forEach(Jg),go.forEach(Jg)}function Gl(e,r){e.blockedOn===r&&(e.blockedOn=null,Dd||(Dd=!0,o.unstable_scheduleCallback(o.unstable_NormalPriority,ex)))}var Wl=null;function ev(e){Wl!==e&&(Wl=e,o.unstable_scheduleCallback(o.unstable_NormalPriority,function(){Wl===e&&(Wl=null);for(var r=0;r<e.length;r+=3){var n=e[r],s=e[r+1],c=e[r+2];if(typeof s!="function"){if(Ud(s||n)===null)continue;break}var d=X(n);d!==null&&(e.splice(r,3),r-=3,Lu(d,{pending:!0,data:c,method:n.method,action:s},s,c))}}))}function es(e){function r(z){return Gl(z,e)}Rn!==null&&Gl(Rn,e),Cn!==null&&Gl(Cn,e),An!==null&&Gl(An,e),mo.forEach(r),go.forEach(r);for(var n=0;n<Pn.length;n++){var s=Pn[n];s.blockedOn===e&&(s.blockedOn=null)}for(;0<Pn.length&&(n=Pn[0],n.blockedOn===null);)Zg(n),n.blockedOn===null&&Pn.shift();if(n=(e.ownerDocument||e).$$reactFormReplay,n!=null)for(s=0;s<n.length;s+=3){var c=n[s],d=n[s+1],g=c[dr]||null;if(typeof d=="function")g||ev(n);else if(g){var M=null;if(d&&d.hasAttribute("formAction")){if(c=d,g=d[dr]||null)M=g.formAction;else if(Ud(c)!==null)continue}else M=g.action;typeof M=="function"?n[s+1]=M:(n.splice(s,3),s-=3),ev(n)}}}function tv(){function e(d){d.canIntercept&&d.info==="react-transition"&&d.intercept({handler:function(){return new Promise(function(g){return c=g})},focusReset:"manual",scroll:"manual"})}function r(){c!==null&&(c(),c=null),s||setTimeout(n,20)}function n(){if(!s&&!navigation.transition){var d=navigation.currentEntry;d&&d.url!=null&&navigation.navigate(d.url,{state:d.getState(),info:"react-transition",history:"replace"})}}if(typeof navigation=="object"){var s=!1,c=null;return navigation.addEventListener("navigate",e),navigation.addEventListener("navigatesuccess",r),navigation.addEventListener("navigateerror",r),setTimeout(n,100),function(){s=!0,navigation.removeEventListener("navigate",e),navigation.removeEventListener("navigatesuccess",r),navigation.removeEventListener("navigateerror",r),c!==null&&(c(),c=null)}}}function Id(e){this._internalRoot=e}jl.prototype.render=Id.prototype.render=function(e){var r=this._internalRoot;if(r===null)throw Error(a(409));var n=r.current,s=Yr();Xg(n,s,e,r,null,null)},jl.prototype.unmount=Id.prototype.unmount=function(){var e=this._internalRoot;if(e!==null){this._internalRoot=null;var r=e.containerInfo;Xg(e.current,2,null,e,null,null),wl(),r[Di]=null}};function jl(e){this._internalRoot=e}jl.prototype.unstable_scheduleHydration=function(e){if(e){var r=Rs();e={blockedOn:null,target:e,priority:r};for(var n=0;n<Pn.length&&r!==0&&r<Pn[n].priority;n++);Pn.splice(n,0,e),n===0&&Zg(e)}};var rv=t.version;if(rv!=="19.2.4")throw Error(a(527,rv,"19.2.4"));K.findDOMNode=function(e){var r=e._reactInternals;if(r===void 0)throw typeof e.render=="function"?Error(a(188)):(e=Object.keys(e).join(","),Error(a(268,e)));return e=p(r),e=e!==null?_(e):null,e=e===null?null:e.stateNode,e};var tx={bundleType:0,version:"19.2.4",rendererPackageName:"react-dom",currentDispatcherRef:N,reconcilerVersion:"19.2.4"};if(typeof __REACT_DEVTOOLS_GLOBAL_HOOK__<"u"){var Xl=__REACT_DEVTOOLS_GLOBAL_HOOK__;if(!Xl.isDisabled&&Xl.supportsFiber)try{Xe=Xl.inject(tx),He=Xl}catch{}}return yo.createRoot=function(e,r){if(!l(e))throw Error(a(299));var n=!1,s="",c=cm,d=um,g=dm;return r!=null&&(r.unstable_strictMode===!0&&(n=!0),r.identifierPrefix!==void 0&&(s=r.identifierPrefix),r.onUncaughtError!==void 0&&(c=r.onUncaughtError),r.onCaughtError!==void 0&&(d=r.onCaughtError),r.onRecoverableError!==void 0&&(g=r.onRecoverableError)),r=Wg(e,1,!1,null,null,n,s,null,c,d,g,tv),e[Di]=r.current,md(e),new Id(r)},yo.hydrateRoot=function(e,r,n){if(!l(e))throw Error(a(299));var s=!1,c="",d=cm,g=um,M=dm,z=null;return n!=null&&(n.unstable_strictMode===!0&&(s=!0),n.identifierPrefix!==void 0&&(c=n.identifierPrefix),n.onUncaughtError!==void 0&&(d=n.onUncaughtError),n.onCaughtError!==void 0&&(g=n.onCaughtError),n.onRecoverableError!==void 0&&(M=n.onRecoverableError),n.formState!==void 0&&(z=n.formState)),r=Wg(e,1,!0,r,n??null,s,c,z,d,g,M,tv),r.context=jg(null),n=r.current,s=Yr(),s=Gn(s),c=mn(s),c.callback=null,gn(n,c,s),n=s,r.current.lanes=n,ur(r,n),Ti(r),e[Di]=r.current,md(e),new jl(r)},yo.version="19.2.4",yo}var gv;function dx(){if(gv)return Nd.exports;gv=1;function o(){if(!(typeof __REACT_DEVTOOLS_GLOBAL_HOOK__>"u"||typeof __REACT_DEVTOOLS_GLOBAL_HOOK__.checkDCE!="function"))try{__REACT_DEVTOOLS_GLOBAL_HOOK__.checkDCE(o)}catch(t){console.error(t)}}return o(),Nd.exports=ux(),Nd.exports}var hx=dx();/**
* @license
* Copyright 2010-2025 Three.js Authors
* SPDX-License-Identifier: MIT
*/const af="176",fx=0,vv=1,px=2,x_=1,S_=2,rn=3,Hn=0,zr=1,an=2,zn=0,gs=1,_v=2,yv=3,xv=4,mx=5,ga=100,gx=101,vx=102,_x=103,yx=104,xx=200,Sx=201,bx=202,Mx=203,gh=204,vh=205,Ex=206,wx=207,Tx=208,Rx=209,Cx=210,Ax=211,Px=212,Lx=213,Ux=214,_h=0,yh=1,xh=2,_s=3,Sh=4,bh=5,Mh=6,Eh=7,b_=0,Dx=1,Ix=2,Bn=0,Nx=1,Ox=2,kx=3,M_=4,Fx=5,zx=6,Bx=7,E_=300,ys=301,xs=302,wh=303,Th=304,Tc=306,Rh=1e3,_a=1001,Ch=1002,Si=1003,Hx=1004,Yl=1005,Ci=1006,kd=1007,ya=1008,Pi=1009,w_=1010,T_=1011,Ro=1012,sf=1013,xa=1014,sn=1015,Lo=1016,of=1017,lf=1018,Co=1020,R_=35902,C_=1021,A_=1022,xi=1023,Ao=1026,Po=1027,P_=1028,cf=1029,L_=1030,uf=1031,df=1033,gc=33776,vc=33777,_c=33778,yc=33779,Ah=35840,Ph=35841,Lh=35842,Uh=35843,Dh=36196,Ih=37492,Nh=37496,Oh=37808,kh=37809,Fh=37810,zh=37811,Bh=37812,Hh=37813,Vh=37814,Gh=37815,Wh=37816,jh=37817,Xh=37818,Yh=37819,qh=37820,Qh=37821,xc=36492,$h=36494,Kh=36495,U_=36283,Zh=36284,Jh=36285,ef=36286,Vx=3200,Gx=3201,D_=0,Wx=1,Fn="",ai="srgb",Ss="srgb-linear",Mc="linear",kt="srgb",ts=7680,Sv=519,jx=512,Xx=513,Yx=514,I_=515,qx=516,Qx=517,$x=518,Kx=519,bv=35044,Mv="300 es",on=2e3,Ec=2001;class Ms{addEventListener(t,i){this._listeners===void 0&&(this._listeners={});const a=this._listeners;a[t]===void 0&&(a[t]=[]),a[t].indexOf(i)===-1&&a[t].push(i)}hasEventListener(t,i){const a=this._listeners;return a===void 0?!1:a[t]!==void 0&&a[t].indexOf(i)!==-1}removeEventListener(t,i){const a=this._listeners;if(a===void 0)return;const l=a[t];if(l!==void 0){const u=l.indexOf(i);u!==-1&&l.splice(u,1)}}dispatchEvent(t){const i=this._listeners;if(i===void 0)return;const a=i[t.type];if(a!==void 0){t.target=this;const l=a.slice(0);for(let u=0,h=l.length;u<h;u++)l[u].call(this,t);t.target=null}}}const Sr=["00","01","02","03","04","05","06","07","08","09","0a","0b","0c","0d","0e","0f","10","11","12","13","14","15","16","17","18","19","1a","1b","1c","1d","1e","1f","20","21","22","23","24","25","26","27","28","29","2a","2b","2c","2d","2e","2f","30","31","32","33","34","35","36","37","38","39","3a","3b","3c","3d","3e","3f","40","41","42","43","44","45","46","47","48","49","4a","4b","4c","4d","4e","4f","50","51","52","53","54","55","56","57","58","59","5a","5b","5c","5d","5e","5f","60","61","62","63","64","65","66","67","68","69","6a","6b","6c","6d","6e","6f","70","71","72","73","74","75","76","77","78","79","7a","7b","7c","7d","7e","7f","80","81","82","83","84","85","86","87","88","89","8a","8b","8c","8d","8e","8f","90","91","92","93","94","95","96","97","98","99","9a","9b","9c","9d","9e","9f","a0","a1","a2","a3","a4","a5","a6","a7","a8","a9","aa","ab","ac","ad","ae","af","b0","b1","b2","b3","b4","b5","b6","b7","b8","b9","ba","bb","bc","bd","be","bf","c0","c1","c2","c3","c4","c5","c6","c7","c8","c9","ca","cb","cc","cd","ce","cf","d0","d1","d2","d3","d4","d5","d6","d7","d8","d9","da","db","dc","dd","de","df","e0","e1","e2","e3","e4","e5","e6","e7","e8","e9","ea","eb","ec","ed","ee","ef","f0","f1","f2","f3","f4","f5","f6","f7","f8","f9","fa","fb","fc","fd","fe","ff"],Fd=Math.PI/180,tf=180/Math.PI;function Uo(){const o=Math.random()*4294967295|0,t=Math.random()*4294967295|0,i=Math.random()*4294967295|0,a=Math.random()*4294967295|0;return(Sr[o&255]+Sr[o>>8&255]+Sr[o>>16&255]+Sr[o>>24&255]+"-"+Sr[t&255]+Sr[t>>8&255]+"-"+Sr[t>>16&15|64]+Sr[t>>24&255]+"-"+Sr[i&63|128]+Sr[i>>8&255]+"-"+Sr[i>>16&255]+Sr[i>>24&255]+Sr[a&255]+Sr[a>>8&255]+Sr[a>>16&255]+Sr[a>>24&255]).toLowerCase()}function _t(o,t,i){return Math.max(t,Math.min(i,o))}function Zx(o,t){return(o%t+t)%t}function zd(o,t,i){return(1-i)*o+i*t}function xo(o,t){switch(t.constructor){case Float32Array:return o;case Uint32Array:return o/4294967295;case Uint16Array:return o/65535;case Uint8Array:return o/255;case Int32Array:return Math.max(o/2147483647,-1);case Int16Array:return Math.max(o/32767,-1);case Int8Array:return Math.max(o/127,-1);default:throw new Error("Invalid component type.")}}function Fr(o,t){switch(t.constructor){case Float32Array:return o;case Uint32Array:return Math.round(o*4294967295);case Uint16Array:return Math.round(o*65535);case Uint8Array:return Math.round(o*255);case Int32Array:return Math.round(o*2147483647);case Int16Array:return Math.round(o*32767);case Int8Array:return Math.round(o*127);default:throw new Error("Invalid component type.")}}class St{constructor(t=0,i=0){St.prototype.isVector2=!0,this.x=t,this.y=i}get width(){return this.x}set width(t){this.x=t}get height(){return this.y}set height(t){this.y=t}set(t,i){return this.x=t,this.y=i,this}setScalar(t){return this.x=t,this.y=t,this}setX(t){return this.x=t,this}setY(t){return this.y=t,this}setComponent(t,i){switch(t){case 0:this.x=i;break;case 1:this.y=i;break;default:throw new Error("index is out of range: "+t)}return this}getComponent(t){switch(t){case 0:return this.x;case 1:return this.y;default:throw new Error("index is out of range: "+t)}}clone(){return new this.constructor(this.x,this.y)}copy(t){return this.x=t.x,this.y=t.y,this}add(t){return this.x+=t.x,this.y+=t.y,this}addScalar(t){return this.x+=t,this.y+=t,this}addVectors(t,i){return this.x=t.x+i.x,this.y=t.y+i.y,this}addScaledVector(t,i){return this.x+=t.x*i,this.y+=t.y*i,this}sub(t){return this.x-=t.x,this.y-=t.y,this}subScalar(t){return this.x-=t,this.y-=t,this}subVectors(t,i){return this.x=t.x-i.x,this.y=t.y-i.y,this}multiply(t){return this.x*=t.x,this.y*=t.y,this}multiplyScalar(t){return this.x*=t,this.y*=t,this}divide(t){return this.x/=t.x,this.y/=t.y,this}divideScalar(t){return this.multiplyScalar(1/t)}applyMatrix3(t){const i=this.x,a=this.y,l=t.elements;return this.x=l[0]*i+l[3]*a+l[6],this.y=l[1]*i+l[4]*a+l[7],this}min(t){return this.x=Math.min(this.x,t.x),this.y=Math.min(this.y,t.y),this}max(t){return this.x=Math.max(this.x,t.x),this.y=Math.max(this.y,t.y),this}clamp(t,i){return this.x=_t(this.x,t.x,i.x),this.y=_t(this.y,t.y,i.y),this}clampScalar(t,i){return this.x=_t(this.x,t,i),this.y=_t(this.y,t,i),this}clampLength(t,i){const a=this.length();return this.divideScalar(a||1).multiplyScalar(_t(a,t,i))}floor(){return this.x=Math.floor(this.x),this.y=Math.floor(this.y),this}ceil(){return this.x=Math.ceil(this.x),this.y=Math.ceil(this.y),this}round(){return this.x=Math.round(this.x),this.y=Math.round(this.y),this}roundToZero(){return this.x=Math.trunc(this.x),this.y=Math.trunc(this.y),this}negate(){return this.x=-this.x,this.y=-this.y,this}dot(t){return this.x*t.x+this.y*t.y}cross(t){return this.x*t.y-this.y*t.x}lengthSq(){return this.x*this.x+this.y*this.y}length(){return Math.sqrt(this.x*this.x+this.y*this.y)}manhattanLength(){return Math.abs(this.x)+Math.abs(this.y)}normalize(){return this.divideScalar(this.length()||1)}angle(){return Math.atan2(-this.y,-this.x)+Math.PI}angleTo(t){const i=Math.sqrt(this.lengthSq()*t.lengthSq());if(i===0)return Math.PI/2;const a=this.dot(t)/i;return Math.acos(_t(a,-1,1))}distanceTo(t){return Math.sqrt(this.distanceToSquared(t))}distanceToSquared(t){const i=this.x-t.x,a=this.y-t.y;return i*i+a*a}manhattanDistanceTo(t){return Math.abs(this.x-t.x)+Math.abs(this.y-t.y)}setLength(t){return this.normalize().multiplyScalar(t)}lerp(t,i){return this.x+=(t.x-this.x)*i,this.y+=(t.y-this.y)*i,this}lerpVectors(t,i,a){return this.x=t.x+(i.x-t.x)*a,this.y=t.y+(i.y-t.y)*a,this}equals(t){return t.x===this.x&&t.y===this.y}fromArray(t,i=0){return this.x=t[i],this.y=t[i+1],this}toArray(t=[],i=0){return t[i]=this.x,t[i+1]=this.y,t}fromBufferAttribute(t,i){return this.x=t.getX(i),this.y=t.getY(i),this}rotateAround(t,i){const a=Math.cos(i),l=Math.sin(i),u=this.x-t.x,h=this.y-t.y;return this.x=u*a-h*l+t.x,this.y=u*l+h*a+t.y,this}random(){return this.x=Math.random(),this.y=Math.random(),this}*[Symbol.iterator](){yield this.x,yield this.y}}class at{constructor(t,i,a,l,u,h,f,m,p){at.prototype.isMatrix3=!0,this.elements=[1,0,0,0,1,0,0,0,1],t!==void 0&&this.set(t,i,a,l,u,h,f,m,p)}set(t,i,a,l,u,h,f,m,p){const _=this.elements;return _[0]=t,_[1]=l,_[2]=f,_[3]=i,_[4]=u,_[5]=m,_[6]=a,_[7]=h,_[8]=p,this}identity(){return this.set(1,0,0,0,1,0,0,0,1),this}copy(t){const i=this.elements,a=t.elements;return i[0]=a[0],i[1]=a[1],i[2]=a[2],i[3]=a[3],i[4]=a[4],i[5]=a[5],i[6]=a[6],i[7]=a[7],i[8]=a[8],this}extractBasis(t,i,a){return t.setFromMatrix3Column(this,0),i.setFromMatrix3Column(this,1),a.setFromMatrix3Column(this,2),this}setFromMatrix4(t){const i=t.elements;return this.set(i[0],i[4],i[8],i[1],i[5],i[9],i[2],i[6],i[10]),this}multiply(t){return this.multiplyMatrices(this,t)}premultiply(t){return this.multiplyMatrices(t,this)}multiplyMatrices(t,i){const a=t.elements,l=i.elements,u=this.elements,h=a[0],f=a[3],m=a[6],p=a[1],_=a[4],y=a[7],x=a[2],b=a[5],R=a[8],A=l[0],S=l[3],v=l[6],D=l[1],L=l[4],C=l[7],G=l[2],k=l[5],I=l[8];return u[0]=h*A+f*D+m*G,u[3]=h*S+f*L+m*k,u[6]=h*v+f*C+m*I,u[1]=p*A+_*D+y*G,u[4]=p*S+_*L+y*k,u[7]=p*v+_*C+y*I,u[2]=x*A+b*D+R*G,u[5]=x*S+b*L+R*k,u[8]=x*v+b*C+R*I,this}multiplyScalar(t){const i=this.elements;return i[0]*=t,i[3]*=t,i[6]*=t,i[1]*=t,i[4]*=t,i[7]*=t,i[2]*=t,i[5]*=t,i[8]*=t,this}determinant(){const t=this.elements,i=t[0],a=t[1],l=t[2],u=t[3],h=t[4],f=t[5],m=t[6],p=t[7],_=t[8];return i*h*_-i*f*p-a*u*_+a*f*m+l*u*p-l*h*m}invert(){const t=this.elements,i=t[0],a=t[1],l=t[2],u=t[3],h=t[4],f=t[5],m=t[6],p=t[7],_=t[8],y=_*h-f*p,x=f*m-_*u,b=p*u-h*m,R=i*y+a*x+l*b;if(R===0)return this.set(0,0,0,0,0,0,0,0,0);const A=1/R;return t[0]=y*A,t[1]=(l*p-_*a)*A,t[2]=(f*a-l*h)*A,t[3]=x*A,t[4]=(_*i-l*m)*A,t[5]=(l*u-f*i)*A,t[6]=b*A,t[7]=(a*m-p*i)*A,t[8]=(h*i-a*u)*A,this}transpose(){let t;const i=this.elements;return t=i[1],i[1]=i[3],i[3]=t,t=i[2],i[2]=i[6],i[6]=t,t=i[5],i[5]=i[7],i[7]=t,this}getNormalMatrix(t){return this.setFromMatrix4(t).invert().transpose()}transposeIntoArray(t){const i=this.elements;return t[0]=i[0],t[1]=i[3],t[2]=i[6],t[3]=i[1],t[4]=i[4],t[5]=i[7],t[6]=i[2],t[7]=i[5],t[8]=i[8],this}setUvTransform(t,i,a,l,u,h,f){const m=Math.cos(u),p=Math.sin(u);return this.set(a*m,a*p,-a*(m*h+p*f)+h+t,-l*p,l*m,-l*(-p*h+m*f)+f+i,0,0,1),this}scale(t,i){return this.premultiply(Bd.makeScale(t,i)),this}rotate(t){return this.premultiply(Bd.makeRotation(-t)),this}translate(t,i){return this.premultiply(Bd.makeTranslation(t,i)),this}makeTranslation(t,i){return t.isVector2?this.set(1,0,t.x,0,1,t.y,0,0,1):this.set(1,0,t,0,1,i,0,0,1),this}makeRotation(t){const i=Math.cos(t),a=Math.sin(t);return this.set(i,-a,0,a,i,0,0,0,1),this}makeScale(t,i){return this.set(t,0,0,0,i,0,0,0,1),this}equals(t){const i=this.elements,a=t.elements;for(let l=0;l<9;l++)if(i[l]!==a[l])return!1;return!0}fromArray(t,i=0){for(let a=0;a<9;a++)this.elements[a]=t[a+i];return this}toArray(t=[],i=0){const a=this.elements;return t[i]=a[0],t[i+1]=a[1],t[i+2]=a[2],t[i+3]=a[3],t[i+4]=a[4],t[i+5]=a[5],t[i+6]=a[6],t[i+7]=a[7],t[i+8]=a[8],t}clone(){return new this.constructor().fromArray(this.elements)}}const Bd=new at;function N_(o){for(let t=o.length-1;t>=0;--t)if(o[t]>=65535)return!0;return!1}function wc(o){return document.createElementNS("http://www.w3.org/1999/xhtml",o)}function Jx(){const o=wc("canvas");return o.style.display="block",o}const Ev={};function Sc(o){o in Ev||(Ev[o]=!0,console.warn(o))}function eS(o,t,i){return new Promise(function(a,l){function u(){switch(o.clientWaitSync(t,o.SYNC_FLUSH_COMMANDS_BIT,0)){case o.WAIT_FAILED:l();break;case o.TIMEOUT_EXPIRED:setTimeout(u,i);break;default:a()}}setTimeout(u,i)})}function tS(o){const t=o.elements;t[2]=.5*t[2]+.5*t[3],t[6]=.5*t[6]+.5*t[7],t[10]=.5*t[10]+.5*t[11],t[14]=.5*t[14]+.5*t[15]}function rS(o){const t=o.elements;t[11]===-1?(t[10]=-t[10]-1,t[14]=-t[14]):(t[10]=-t[10],t[14]=-t[14]+1)}const wv=new at().set(.4123908,.3575843,.1804808,.212639,.7151687,.0721923,.0193308,.1191948,.9505322),Tv=new at().set(3.2409699,-1.5373832,-.4986108,-.9692436,1.8759675,.0415551,.0556301,-.203977,1.0569715);function iS(){const o={enabled:!0,workingColorSpace:Ss,spaces:{},convert:function(l,u,h){return this.enabled===!1||u===h||!u||!h||(this.spaces[u].transfer===kt&&(l.r=ln(l.r),l.g=ln(l.g),l.b=ln(l.b)),this.spaces[u].primaries!==this.spaces[h].primaries&&(l.applyMatrix3(this.spaces[u].toXYZ),l.applyMatrix3(this.spaces[h].fromXYZ)),this.spaces[h].transfer===kt&&(l.r=vs(l.r),l.g=vs(l.g),l.b=vs(l.b))),l},fromWorkingColorSpace:function(l,u){return this.convert(l,this.workingColorSpace,u)},toWorkingColorSpace:function(l,u){return this.convert(l,u,this.workingColorSpace)},getPrimaries:function(l){return this.spaces[l].primaries},getTransfer:function(l){return l===Fn?Mc:this.spaces[l].transfer},getLuminanceCoefficients:function(l,u=this.workingColorSpace){return l.fromArray(this.spaces[u].luminanceCoefficients)},define:function(l){Object.assign(this.spaces,l)},_getMatrix:function(l,u,h){return l.copy(this.spaces[u].toXYZ).multiply(this.spaces[h].fromXYZ)},_getDrawingBufferColorSpace:function(l){return this.spaces[l].outputColorSpaceConfig.drawingBufferColorSpace},_getUnpackColorSpace:function(l=this.workingColorSpace){return this.spaces[l].workingColorSpaceConfig.unpackColorSpace}},t=[.64,.33,.3,.6,.15,.06],i=[.2126,.7152,.0722],a=[.3127,.329];return o.define({[Ss]:{primaries:t,whitePoint:a,transfer:Mc,toXYZ:wv,fromXYZ:Tv,luminanceCoefficients:i,workingColorSpaceConfig:{unpackColorSpace:ai},outputColorSpaceConfig:{drawingBufferColorSpace:ai}},[ai]:{primaries:t,whitePoint:a,transfer:kt,toXYZ:wv,fromXYZ:Tv,luminanceCoefficients:i,outputColorSpaceConfig:{drawingBufferColorSpace:ai}}}),o}const Tt=iS();function ln(o){return o<.04045?o*.0773993808:Math.pow(o*.9478672986+.0521327014,2.4)}function vs(o){return o<.0031308?o*12.92:1.055*Math.pow(o,.41666)-.055}let rs;class nS{static getDataURL(t,i="image/png"){if(/^data:/i.test(t.src)||typeof HTMLCanvasElement>"u")return t.src;let a;if(t instanceof HTMLCanvasElement)a=t;else{rs===void 0&&(rs=wc("canvas")),rs.width=t.width,rs.height=t.height;const l=rs.getContext("2d");t instanceof ImageData?l.putImageData(t,0,0):l.drawImage(t,0,0,t.width,t.height),a=rs}return a.toDataURL(i)}static sRGBToLinear(t){if(typeof HTMLImageElement<"u"&&t instanceof HTMLImageElement||typeof HTMLCanvasElement<"u"&&t instanceof HTMLCanvasElement||typeof ImageBitmap<"u"&&t instanceof ImageBitmap){const i=wc("canvas");i.width=t.width,i.height=t.height;const a=i.getContext("2d");a.drawImage(t,0,0,t.width,t.height);const l=a.getImageData(0,0,t.width,t.height),u=l.data;for(let h=0;h<u.length;h++)u[h]=ln(u[h]/255)*255;return a.putImageData(l,0,0),i}else if(t.data){const i=t.data.slice(0);for(let a=0;a<i.length;a++)i instanceof Uint8Array||i instanceof Uint8ClampedArray?i[a]=Math.floor(ln(i[a]/255)*255):i[a]=ln(i[a]);return{data:i,width:t.width,height:t.height}}else return console.warn("THREE.ImageUtils.sRGBToLinear(): Unsupported image type. No color space conversion applied."),t}}let aS=0;class hf{constructor(t=null){this.isSource=!0,Object.defineProperty(this,"id",{value:aS++}),this.uuid=Uo(),this.data=t,this.dataReady=!0,this.version=0}set needsUpdate(t){t===!0&&this.version++}toJSON(t){const i=t===void 0||typeof t=="string";if(!i&&t.images[this.uuid]!==void 0)return t.images[this.uuid];const a={uuid:this.uuid,url:""},l=this.data;if(l!==null){let u;if(Array.isArray(l)){u=[];for(let h=0,f=l.length;h<f;h++)l[h].isDataTexture?u.push(Hd(l[h].image)):u.push(Hd(l[h]))}else u=Hd(l);a.url=u}return i||(t.images[this.uuid]=a),a}}function Hd(o){return typeof HTMLImageElement<"u"&&o instanceof HTMLImageElement||typeof HTMLCanvasElement<"u"&&o instanceof HTMLCanvasElement||typeof ImageBitmap<"u"&&o instanceof ImageBitmap?nS.getDataURL(o):o.data?{data:Array.from(o.data),width:o.width,height:o.height,type:o.data.constructor.name}:(console.warn("THREE.Texture: Unable to serialize Texture."),{})}let sS=0;class Br extends Ms{constructor(t=Br.DEFAULT_IMAGE,i=Br.DEFAULT_MAPPING,a=_a,l=_a,u=Ci,h=ya,f=xi,m=Pi,p=Br.DEFAULT_ANISOTROPY,_=Fn){super(),this.isTexture=!0,Object.defineProperty(this,"id",{value:sS++}),this.uuid=Uo(),this.name="",this.source=new hf(t),this.mipmaps=[],this.mapping=i,this.channel=0,this.wrapS=a,this.wrapT=l,this.magFilter=u,this.minFilter=h,this.anisotropy=p,this.format=f,this.internalFormat=null,this.type=m,this.offset=new St(0,0),this.repeat=new St(1,1),this.center=new St(0,0),this.rotation=0,this.matrixAutoUpdate=!0,this.matrix=new at,this.generateMipmaps=!0,this.premultiplyAlpha=!1,this.flipY=!0,this.unpackAlignment=4,this.colorSpace=_,this.userData={},this.version=0,this.onUpdate=null,this.renderTarget=null,this.isRenderTargetTexture=!1,this.isTextureArray=!1,this.pmremVersion=0}get image(){return this.source.data}set image(t=null){this.source.data=t}updateMatrix(){this.matrix.setUvTransform(this.offset.x,this.offset.y,this.repeat.x,this.repeat.y,this.rotation,this.center.x,this.center.y)}clone(){return new this.constructor().copy(this)}copy(t){return this.name=t.name,this.source=t.source,this.mipmaps=t.mipmaps.slice(0),this.mapping=t.mapping,this.channel=t.channel,this.wrapS=t.wrapS,this.wrapT=t.wrapT,this.magFilter=t.magFilter,this.minFilter=t.minFilter,this.anisotropy=t.anisotropy,this.format=t.format,this.internalFormat=t.internalFormat,this.type=t.type,this.offset.copy(t.offset),this.repeat.copy(t.repeat),this.center.copy(t.center),this.rotation=t.rotation,this.matrixAutoUpdate=t.matrixAutoUpdate,this.matrix.copy(t.matrix),this.generateMipmaps=t.generateMipmaps,this.premultiplyAlpha=t.premultiplyAlpha,this.flipY=t.flipY,this.unpackAlignment=t.unpackAlignment,this.colorSpace=t.colorSpace,this.renderTarget=t.renderTarget,this.isRenderTargetTexture=t.isRenderTargetTexture,this.isTextureArray=t.isTextureArray,this.userData=JSON.parse(JSON.stringify(t.userData)),this.needsUpdate=!0,this}toJSON(t){const i=t===void 0||typeof t=="string";if(!i&&t.textures[this.uuid]!==void 0)return t.textures[this.uuid];const a={metadata:{version:4.6,type:"Texture",generator:"Texture.toJSON"},uuid:this.uuid,name:this.name,image:this.source.toJSON(t).uuid,mapping:this.mapping,channel:this.channel,repeat:[this.repeat.x,this.repeat.y],offset:[this.offset.x,this.offset.y],center:[this.center.x,this.center.y],rotation:this.rotation,wrap:[this.wrapS,this.wrapT],format:this.format,internalFormat:this.internalFormat,type:this.type,colorSpace:this.colorSpace,minFilter:this.minFilter,magFilter:this.magFilter,anisotropy:this.anisotropy,flipY:this.flipY,generateMipmaps:this.generateMipmaps,premultiplyAlpha:this.premultiplyAlpha,unpackAlignment:this.unpackAlignment};return Object.keys(this.userData).length>0&&(a.userData=this.userData),i||(t.textures[this.uuid]=a),a}dispose(){this.dispatchEvent({type:"dispose"})}transformUv(t){if(this.mapping!==E_)return t;if(t.applyMatrix3(this.matrix),t.x<0||t.x>1)switch(this.wrapS){case Rh:t.x=t.x-Math.floor(t.x);break;case _a:t.x=t.x<0?0:1;break;case Ch:Math.abs(Math.floor(t.x)%2)===1?t.x=Math.ceil(t.x)-t.x:t.x=t.x-Math.floor(t.x);break}if(t.y<0||t.y>1)switch(this.wrapT){case Rh:t.y=t.y-Math.floor(t.y);break;case _a:t.y=t.y<0?0:1;break;case Ch:Math.abs(Math.floor(t.y)%2)===1?t.y=Math.ceil(t.y)-t.y:t.y=t.y-Math.floor(t.y);break}return this.flipY&&(t.y=1-t.y),t}set needsUpdate(t){t===!0&&(this.version++,this.source.needsUpdate=!0)}set needsPMREMUpdate(t){t===!0&&this.pmremVersion++}}Br.DEFAULT_IMAGE=null;Br.DEFAULT_MAPPING=E_;Br.DEFAULT_ANISOTROPY=1;class Ft{constructor(t=0,i=0,a=0,l=1){Ft.prototype.isVector4=!0,this.x=t,this.y=i,this.z=a,this.w=l}get width(){return this.z}set width(t){this.z=t}get height(){return this.w}set height(t){this.w=t}set(t,i,a,l){return this.x=t,this.y=i,this.z=a,this.w=l,this}setScalar(t){return this.x=t,this.y=t,this.z=t,this.w=t,this}setX(t){return this.x=t,this}setY(t){return this.y=t,this}setZ(t){return this.z=t,this}setW(t){return this.w=t,this}setComponent(t,i){switch(t){case 0:this.x=i;break;case 1:this.y=i;break;case 2:this.z=i;break;case 3:this.w=i;break;default:throw new Error("index is out of range: "+t)}return this}getComponent(t){switch(t){case 0:return this.x;case 1:return this.y;case 2:return this.z;case 3:return this.w;default:throw new Error("index is out of range: "+t)}}clone(){return new this.constructor(this.x,this.y,this.z,this.w)}copy(t){return this.x=t.x,this.y=t.y,this.z=t.z,this.w=t.w!==void 0?t.w:1,this}add(t){return this.x+=t.x,this.y+=t.y,this.z+=t.z,this.w+=t.w,this}addScalar(t){return this.x+=t,this.y+=t,this.z+=t,this.w+=t,this}addVectors(t,i){return this.x=t.x+i.x,this.y=t.y+i.y,this.z=t.z+i.z,this.w=t.w+i.w,this}addScaledVector(t,i){return this.x+=t.x*i,this.y+=t.y*i,this.z+=t.z*i,this.w+=t.w*i,this}sub(t){return this.x-=t.x,this.y-=t.y,this.z-=t.z,this.w-=t.w,this}subScalar(t){return this.x-=t,this.y-=t,this.z-=t,this.w-=t,this}subVectors(t,i){return this.x=t.x-i.x,this.y=t.y-i.y,this.z=t.z-i.z,this.w=t.w-i.w,this}multiply(t){return this.x*=t.x,this.y*=t.y,this.z*=t.z,this.w*=t.w,this}multiplyScalar(t){return this.x*=t,this.y*=t,this.z*=t,this.w*=t,this}applyMatrix4(t){const i=this.x,a=this.y,l=this.z,u=this.w,h=t.elements;return this.x=h[0]*i+h[4]*a+h[8]*l+h[12]*u,this.y=h[1]*i+h[5]*a+h[9]*l+h[13]*u,this.z=h[2]*i+h[6]*a+h[10]*l+h[14]*u,this.w=h[3]*i+h[7]*a+h[11]*l+h[15]*u,this}divide(t){return this.x/=t.x,this.y/=t.y,this.z/=t.z,this.w/=t.w,this}divideScalar(t){return this.multiplyScalar(1/t)}setAxisAngleFromQuaternion(t){this.w=2*Math.acos(t.w);const i=Math.sqrt(1-t.w*t.w);return i<1e-4?(this.x=1,this.y=0,this.z=0):(this.x=t.x/i,this.y=t.y/i,this.z=t.z/i),this}setAxisAngleFromRotationMatrix(t){let i,a,l,u;const h=t.elements,f=h[0],m=h[4],p=h[8],_=h[1],y=h[5],x=h[9],b=h[2],R=h[6],A=h[10];if(Math.abs(m-_)<.01&&Math.abs(p-b)<.01&&Math.abs(x-R)<.01){if(Math.abs(m+_)<.1&&Math.abs(p+b)<.1&&Math.abs(x+R)<.1&&Math.abs(f+y+A-3)<.1)return this.set(1,0,0,0),this;i=Math.PI;const v=(f+1)/2,D=(y+1)/2,L=(A+1)/2,C=(m+_)/4,G=(p+b)/4,k=(x+R)/4;return v>D&&v>L?v<.01?(a=0,l=.707106781,u=.707106781):(a=Math.sqrt(v),l=C/a,u=G/a):D>L?D<.01?(a=.707106781,l=0,u=.707106781):(l=Math.sqrt(D),a=C/l,u=k/l):L<.01?(a=.707106781,l=.707106781,u=0):(u=Math.sqrt(L),a=G/u,l=k/u),this.set(a,l,u,i),this}let S=Math.sqrt((R-x)*(R-x)+(p-b)*(p-b)+(_-m)*(_-m));return Math.abs(S)<.001&&(S=1),this.x=(R-x)/S,this.y=(p-b)/S,this.z=(_-m)/S,this.w=Math.acos((f+y+A-1)/2),this}setFromMatrixPosition(t){const i=t.elements;return this.x=i[12],this.y=i[13],this.z=i[14],this.w=i[15],this}min(t){return this.x=Math.min(this.x,t.x),this.y=Math.min(this.y,t.y),this.z=Math.min(this.z,t.z),this.w=Math.min(this.w,t.w),this}max(t){return this.x=Math.max(this.x,t.x),this.y=Math.max(this.y,t.y),this.z=Math.max(this.z,t.z),this.w=Math.max(this.w,t.w),this}clamp(t,i){return this.x=_t(this.x,t.x,i.x),this.y=_t(this.y,t.y,i.y),this.z=_t(this.z,t.z,i.z),this.w=_t(this.w,t.w,i.w),this}clampScalar(t,i){return this.x=_t(this.x,t,i),this.y=_t(this.y,t,i),this.z=_t(this.z,t,i),this.w=_t(this.w,t,i),this}clampLength(t,i){const a=this.length();return this.divideScalar(a||1).multiplyScalar(_t(a,t,i))}floor(){return this.x=Math.floor(this.x),this.y=Math.floor(this.y),this.z=Math.floor(this.z),this.w=Math.floor(this.w),this}ceil(){return this.x=Math.ceil(this.x),this.y=Math.ceil(this.y),this.z=Math.ceil(this.z),this.w=Math.ceil(this.w),this}round(){return this.x=Math.round(this.x),this.y=Math.round(this.y),this.z=Math.round(this.z),this.w=Math.round(this.w),this}roundToZero(){return this.x=Math.trunc(this.x),this.y=Math.trunc(this.y),this.z=Math.trunc(this.z),this.w=Math.trunc(this.w),this}negate(){return this.x=-this.x,this.y=-this.y,this.z=-this.z,this.w=-this.w,this}dot(t){return this.x*t.x+this.y*t.y+this.z*t.z+this.w*t.w}lengthSq(){return this.x*this.x+this.y*this.y+this.z*this.z+this.w*this.w}length(){return Math.sqrt(this.x*this.x+this.y*this.y+this.z*this.z+this.w*this.w)}manhattanLength(){return Math.abs(this.x)+Math.abs(this.y)+Math.abs(this.z)+Math.abs(this.w)}normalize(){return this.divideScalar(this.length()||1)}setLength(t){return this.normalize().multiplyScalar(t)}lerp(t,i){return this.x+=(t.x-this.x)*i,this.y+=(t.y-this.y)*i,this.z+=(t.z-this.z)*i,this.w+=(t.w-this.w)*i,this}lerpVectors(t,i,a){return this.x=t.x+(i.x-t.x)*a,this.y=t.y+(i.y-t.y)*a,this.z=t.z+(i.z-t.z)*a,this.w=t.w+(i.w-t.w)*a,this}equals(t){return t.x===this.x&&t.y===this.y&&t.z===this.z&&t.w===this.w}fromArray(t,i=0){return this.x=t[i],this.y=t[i+1],this.z=t[i+2],this.w=t[i+3],this}toArray(t=[],i=0){return t[i]=this.x,t[i+1]=this.y,t[i+2]=this.z,t[i+3]=this.w,t}fromBufferAttribute(t,i){return this.x=t.getX(i),this.y=t.getY(i),this.z=t.getZ(i),this.w=t.getW(i),this}random(){return this.x=Math.random(),this.y=Math.random(),this.z=Math.random(),this.w=Math.random(),this}*[Symbol.iterator](){yield this.x,yield this.y,yield this.z,yield this.w}}class oS extends Ms{constructor(t=1,i=1,a={}){super(),this.isRenderTarget=!0,this.width=t,this.height=i,this.depth=a.depth?a.depth:1,this.scissor=new Ft(0,0,t,i),this.scissorTest=!1,this.viewport=new Ft(0,0,t,i);const l={width:t,height:i,depth:this.depth};a=Object.assign({generateMipmaps:!1,internalFormat:null,minFilter:Ci,depthBuffer:!0,stencilBuffer:!1,resolveDepthBuffer:!0,resolveStencilBuffer:!0,depthTexture:null,samples:0,count:1,multiview:!1},a);const u=new Br(l,a.mapping,a.wrapS,a.wrapT,a.magFilter,a.minFilter,a.format,a.type,a.anisotropy,a.colorSpace);u.flipY=!1,u.generateMipmaps=a.generateMipmaps,u.internalFormat=a.internalFormat,this.textures=[];const h=a.count;for(let f=0;f<h;f++)this.textures[f]=u.clone(),this.textures[f].isRenderTargetTexture=!0,this.textures[f].renderTarget=this;this.depthBuffer=a.depthBuffer,this.stencilBuffer=a.stencilBuffer,this.resolveDepthBuffer=a.resolveDepthBuffer,this.resolveStencilBuffer=a.resolveStencilBuffer,this._depthTexture=null,this.depthTexture=a.depthTexture,this.samples=a.samples,this.multiview=a.multiview}get texture(){return this.textures[0]}set texture(t){this.textures[0]=t}set depthTexture(t){this._depthTexture!==null&&(this._depthTexture.renderTarget=null),t!==null&&(t.renderTarget=this),this._depthTexture=t}get depthTexture(){return this._depthTexture}setSize(t,i,a=1){if(this.width!==t||this.height!==i||this.depth!==a){this.width=t,this.height=i,this.depth=a;for(let l=0,u=this.textures.length;l<u;l++)this.textures[l].image.width=t,this.textures[l].image.height=i,this.textures[l].image.depth=a;this.dispose()}this.viewport.set(0,0,t,i),this.scissor.set(0,0,t,i)}clone(){return new this.constructor().copy(this)}copy(t){this.width=t.width,this.height=t.height,this.depth=t.depth,this.scissor.copy(t.scissor),this.scissorTest=t.scissorTest,this.viewport.copy(t.viewport),this.textures.length=0;for(let i=0,a=t.textures.length;i<a;i++){this.textures[i]=t.textures[i].clone(),this.textures[i].isRenderTargetTexture=!0,this.textures[i].renderTarget=this;const l=Object.assign({},t.textures[i].image);this.textures[i].source=new hf(l)}return this.depthBuffer=t.depthBuffer,this.stencilBuffer=t.stencilBuffer,this.resolveDepthBuffer=t.resolveDepthBuffer,this.resolveStencilBuffer=t.resolveStencilBuffer,t.depthTexture!==null&&(this.depthTexture=t.depthTexture.clone()),this.samples=t.samples,this}dispose(){this.dispatchEvent({type:"dispose"})}}class Sa extends oS{constructor(t=1,i=1,a={}){super(t,i,a),this.isWebGLRenderTarget=!0}}class O_ extends Br{constructor(t=null,i=1,a=1,l=1){super(null),this.isDataArrayTexture=!0,this.image={data:t,width:i,height:a,depth:l},this.magFilter=Si,this.minFilter=Si,this.wrapR=_a,this.generateMipmaps=!1,this.flipY=!1,this.unpackAlignment=1,this.layerUpdates=new Set}addLayerUpdate(t){this.layerUpdates.add(t)}clearLayerUpdates(){this.layerUpdates.clear()}}class lS extends Br{constructor(t=null,i=1,a=1,l=1){super(null),this.isData3DTexture=!0,this.image={data:t,width:i,height:a,depth:l},this.magFilter=Si,this.minFilter=Si,this.wrapR=_a,this.generateMipmaps=!1,this.flipY=!1,this.unpackAlignment=1}}class Do{constructor(t=0,i=0,a=0,l=1){this.isQuaternion=!0,this._x=t,this._y=i,this._z=a,this._w=l}static slerpFlat(t,i,a,l,u,h,f){let m=a[l+0],p=a[l+1],_=a[l+2],y=a[l+3];const x=u[h+0],b=u[h+1],R=u[h+2],A=u[h+3];if(f===0){t[i+0]=m,t[i+1]=p,t[i+2]=_,t[i+3]=y;return}if(f===1){t[i+0]=x,t[i+1]=b,t[i+2]=R,t[i+3]=A;return}if(y!==A||m!==x||p!==b||_!==R){let S=1-f;const v=m*x+p*b+_*R+y*A,D=v>=0?1:-1,L=1-v*v;if(L>Number.EPSILON){const G=Math.sqrt(L),k=Math.atan2(G,v*D);S=Math.sin(S*k)/G,f=Math.sin(f*k)/G}const C=f*D;if(m=m*S+x*C,p=p*S+b*C,_=_*S+R*C,y=y*S+A*C,S===1-f){const G=1/Math.sqrt(m*m+p*p+_*_+y*y);m*=G,p*=G,_*=G,y*=G}}t[i]=m,t[i+1]=p,t[i+2]=_,t[i+3]=y}static multiplyQuaternionsFlat(t,i,a,l,u,h){const f=a[l],m=a[l+1],p=a[l+2],_=a[l+3],y=u[h],x=u[h+1],b=u[h+2],R=u[h+3];return t[i]=f*R+_*y+m*b-p*x,t[i+1]=m*R+_*x+p*y-f*b,t[i+2]=p*R+_*b+f*x-m*y,t[i+3]=_*R-f*y-m*x-p*b,t}get x(){return this._x}set x(t){this._x=t,this._onChangeCallback()}get y(){return this._y}set y(t){this._y=t,this._onChangeCallback()}get z(){return this._z}set z(t){this._z=t,this._onChangeCallback()}get w(){return this._w}set w(t){this._w=t,this._onChangeCallback()}set(t,i,a,l){return this._x=t,this._y=i,this._z=a,this._w=l,this._onChangeCallback(),this}clone(){return new this.constructor(this._x,this._y,this._z,this._w)}copy(t){return this._x=t.x,this._y=t.y,this._z=t.z,this._w=t.w,this._onChangeCallback(),this}setFromEuler(t,i=!0){const a=t._x,l=t._y,u=t._z,h=t._order,f=Math.cos,m=Math.sin,p=f(a/2),_=f(l/2),y=f(u/2),x=m(a/2),b=m(l/2),R=m(u/2);switch(h){case"XYZ":this._x=x*_*y+p*b*R,this._y=p*b*y-x*_*R,this._z=p*_*R+x*b*y,this._w=p*_*y-x*b*R;break;case"YXZ":this._x=x*_*y+p*b*R,this._y=p*b*y-x*_*R,this._z=p*_*R-x*b*y,this._w=p*_*y+x*b*R;break;case"ZXY":this._x=x*_*y-p*b*R,this._y=p*b*y+x*_*R,this._z=p*_*R+x*b*y,this._w=p*_*y-x*b*R;break;case"ZYX":this._x=x*_*y-p*b*R,this._y=p*b*y+x*_*R,this._z=p*_*R-x*b*y,this._w=p*_*y+x*b*R;break;case"YZX":this._x=x*_*y+p*b*R,this._y=p*b*y+x*_*R,this._z=p*_*R-x*b*y,this._w=p*_*y-x*b*R;break;case"XZY":this._x=x*_*y-p*b*R,this._y=p*b*y-x*_*R,this._z=p*_*R+x*b*y,this._w=p*_*y+x*b*R;break;default:console.warn("THREE.Quaternion: .setFromEuler() encountered an unknown order: "+h)}return i===!0&&this._onChangeCallback(),this}setFromAxisAngle(t,i){const a=i/2,l=Math.sin(a);return this._x=t.x*l,this._y=t.y*l,this._z=t.z*l,this._w=Math.cos(a),this._onChangeCallback(),this}setFromRotationMatrix(t){const i=t.elements,a=i[0],l=i[4],u=i[8],h=i[1],f=i[5],m=i[9],p=i[2],_=i[6],y=i[10],x=a+f+y;if(x>0){const b=.5/Math.sqrt(x+1);this._w=.25/b,this._x=(_-m)*b,this._y=(u-p)*b,this._z=(h-l)*b}else if(a>f&&a>y){const b=2*Math.sqrt(1+a-f-y);this._w=(_-m)/b,this._x=.25*b,this._y=(l+h)/b,this._z=(u+p)/b}else if(f>y){const b=2*Math.sqrt(1+f-a-y);this._w=(u-p)/b,this._x=(l+h)/b,this._y=.25*b,this._z=(m+_)/b}else{const b=2*Math.sqrt(1+y-a-f);this._w=(h-l)/b,this._x=(u+p)/b,this._y=(m+_)/b,this._z=.25*b}return this._onChangeCallback(),this}setFromUnitVectors(t,i){let a=t.dot(i)+1;return a<Number.EPSILON?(a=0,Math.abs(t.x)>Math.abs(t.z)?(this._x=-t.y,this._y=t.x,this._z=0,this._w=a):(this._x=0,this._y=-t.z,this._z=t.y,this._w=a)):(this._x=t.y*i.z-t.z*i.y,this._y=t.z*i.x-t.x*i.z,this._z=t.x*i.y-t.y*i.x,this._w=a),this.normalize()}angleTo(t){return 2*Math.acos(Math.abs(_t(this.dot(t),-1,1)))}rotateTowards(t,i){const a=this.angleTo(t);if(a===0)return this;const l=Math.min(1,i/a);return this.slerp(t,l),this}identity(){return this.set(0,0,0,1)}invert(){return this.conjugate()}conjugate(){return this._x*=-1,this._y*=-1,this._z*=-1,this._onChangeCallback(),this}dot(t){return this._x*t._x+this._y*t._y+this._z*t._z+this._w*t._w}lengthSq(){return this._x*this._x+this._y*this._y+this._z*this._z+this._w*this._w}length(){return Math.sqrt(this._x*this._x+this._y*this._y+this._z*this._z+this._w*this._w)}normalize(){let t=this.length();return t===0?(this._x=0,this._y=0,this._z=0,this._w=1):(t=1/t,this._x=this._x*t,this._y=this._y*t,this._z=this._z*t,this._w=this._w*t),this._onChangeCallback(),this}multiply(t){return this.multiplyQuaternions(this,t)}premultiply(t){return this.multiplyQuaternions(t,this)}multiplyQuaternions(t,i){const a=t._x,l=t._y,u=t._z,h=t._w,f=i._x,m=i._y,p=i._z,_=i._w;return this._x=a*_+h*f+l*p-u*m,this._y=l*_+h*m+u*f-a*p,this._z=u*_+h*p+a*m-l*f,this._w=h*_-a*f-l*m-u*p,this._onChangeCallback(),this}slerp(t,i){if(i===0)return this;if(i===1)return this.copy(t);const a=this._x,l=this._y,u=this._z,h=this._w;let f=h*t._w+a*t._x+l*t._y+u*t._z;if(f<0?(this._w=-t._w,this._x=-t._x,this._y=-t._y,this._z=-t._z,f=-f):this.copy(t),f>=1)return this._w=h,this._x=a,this._y=l,this._z=u,this;const m=1-f*f;if(m<=Number.EPSILON){const b=1-i;return this._w=b*h+i*this._w,this._x=b*a+i*this._x,this._y=b*l+i*this._y,this._z=b*u+i*this._z,this.normalize(),this}const p=Math.sqrt(m),_=Math.atan2(p,f),y=Math.sin((1-i)*_)/p,x=Math.sin(i*_)/p;return this._w=h*y+this._w*x,this._x=a*y+this._x*x,this._y=l*y+this._y*x,this._z=u*y+this._z*x,this._onChangeCallback(),this}slerpQuaternions(t,i,a){return this.copy(t).slerp(i,a)}random(){const t=2*Math.PI*Math.random(),i=2*Math.PI*Math.random(),a=Math.random(),l=Math.sqrt(1-a),u=Math.sqrt(a);return this.set(l*Math.sin(t),l*Math.cos(t),u*Math.sin(i),u*Math.cos(i))}equals(t){return t._x===this._x&&t._y===this._y&&t._z===this._z&&t._w===this._w}fromArray(t,i=0){return this._x=t[i],this._y=t[i+1],this._z=t[i+2],this._w=t[i+3],this._onChangeCallback(),this}toArray(t=[],i=0){return t[i]=this._x,t[i+1]=this._y,t[i+2]=this._z,t[i+3]=this._w,t}fromBufferAttribute(t,i){return this._x=t.getX(i),this._y=t.getY(i),this._z=t.getZ(i),this._w=t.getW(i),this._onChangeCallback(),this}toJSON(){return this.toArray()}_onChange(t){return this._onChangeCallback=t,this}_onChangeCallback(){}*[Symbol.iterator](){yield this._x,yield this._y,yield this._z,yield this._w}}class ${constructor(t=0,i=0,a=0){$.prototype.isVector3=!0,this.x=t,this.y=i,this.z=a}set(t,i,a){return a===void 0&&(a=this.z),this.x=t,this.y=i,this.z=a,this}setScalar(t){return this.x=t,this.y=t,this.z=t,this}setX(t){return this.x=t,this}setY(t){return this.y=t,this}setZ(t){return this.z=t,this}setComponent(t,i){switch(t){case 0:this.x=i;break;case 1:this.y=i;break;case 2:this.z=i;break;default:throw new Error("index is out of range: "+t)}return this}getComponent(t){switch(t){case 0:return this.x;case 1:return this.y;case 2:return this.z;default:throw new Error("index is out of range: "+t)}}clone(){return new this.constructor(this.x,this.y,this.z)}copy(t){return this.x=t.x,this.y=t.y,this.z=t.z,this}add(t){return this.x+=t.x,this.y+=t.y,this.z+=t.z,this}addScalar(t){return this.x+=t,this.y+=t,this.z+=t,this}addVectors(t,i){return this.x=t.x+i.x,this.y=t.y+i.y,this.z=t.z+i.z,this}addScaledVector(t,i){return this.x+=t.x*i,this.y+=t.y*i,this.z+=t.z*i,this}sub(t){return this.x-=t.x,this.y-=t.y,this.z-=t.z,this}subScalar(t){return this.x-=t,this.y-=t,this.z-=t,this}subVectors(t,i){return this.x=t.x-i.x,this.y=t.y-i.y,this.z=t.z-i.z,this}multiply(t){return this.x*=t.x,this.y*=t.y,this.z*=t.z,this}multiplyScalar(t){return this.x*=t,this.y*=t,this.z*=t,this}multiplyVectors(t,i){return this.x=t.x*i.x,this.y=t.y*i.y,this.z=t.z*i.z,this}applyEuler(t){return this.applyQuaternion(Rv.setFromEuler(t))}applyAxisAngle(t,i){return this.applyQuaternion(Rv.setFromAxisAngle(t,i))}applyMatrix3(t){const i=this.x,a=this.y,l=this.z,u=t.elements;return this.x=u[0]*i+u[3]*a+u[6]*l,this.y=u[1]*i+u[4]*a+u[7]*l,this.z=u[2]*i+u[5]*a+u[8]*l,this}applyNormalMatrix(t){return this.applyMatrix3(t).normalize()}applyMatrix4(t){const i=this.x,a=this.y,l=this.z,u=t.elements,h=1/(u[3]*i+u[7]*a+u[11]*l+u[15]);return this.x=(u[0]*i+u[4]*a+u[8]*l+u[12])*h,this.y=(u[1]*i+u[5]*a+u[9]*l+u[13])*h,this.z=(u[2]*i+u[6]*a+u[10]*l+u[14])*h,this}applyQuaternion(t){const i=this.x,a=this.y,l=this.z,u=t.x,h=t.y,f=t.z,m=t.w,p=2*(h*l-f*a),_=2*(f*i-u*l),y=2*(u*a-h*i);return this.x=i+m*p+h*y-f*_,this.y=a+m*_+f*p-u*y,this.z=l+m*y+u*_-h*p,this}project(t){return this.applyMatrix4(t.matrixWorldInverse).applyMatrix4(t.projectionMatrix)}unproject(t){return this.applyMatrix4(t.projectionMatrixInverse).applyMatrix4(t.matrixWorld)}transformDirection(t){const i=this.x,a=this.y,l=this.z,u=t.elements;return this.x=u[0]*i+u[4]*a+u[8]*l,this.y=u[1]*i+u[5]*a+u[9]*l,this.z=u[2]*i+u[6]*a+u[10]*l,this.normalize()}divide(t){return this.x/=t.x,this.y/=t.y,this.z/=t.z,this}divideScalar(t){return this.multiplyScalar(1/t)}min(t){return this.x=Math.min(this.x,t.x),this.y=Math.min(this.y,t.y),this.z=Math.min(this.z,t.z),this}max(t){return this.x=Math.max(this.x,t.x),this.y=Math.max(this.y,t.y),this.z=Math.max(this.z,t.z),this}clamp(t,i){return this.x=_t(this.x,t.x,i.x),this.y=_t(this.y,t.y,i.y),this.z=_t(this.z,t.z,i.z),this}clampScalar(t,i){return this.x=_t(this.x,t,i),this.y=_t(this.y,t,i),this.z=_t(this.z,t,i),this}clampLength(t,i){const a=this.length();return this.divideScalar(a||1).multiplyScalar(_t(a,t,i))}floor(){return this.x=Math.floor(this.x),this.y=Math.floor(this.y),this.z=Math.floor(this.z),this}ceil(){return this.x=Math.ceil(this.x),this.y=Math.ceil(this.y),this.z=Math.ceil(this.z),this}round(){return this.x=Math.round(this.x),this.y=Math.round(this.y),this.z=Math.round(this.z),this}roundToZero(){return this.x=Math.trunc(this.x),this.y=Math.trunc(this.y),this.z=Math.trunc(this.z),this}negate(){return this.x=-this.x,this.y=-this.y,this.z=-this.z,this}dot(t){return this.x*t.x+this.y*t.y+this.z*t.z}lengthSq(){return this.x*this.x+this.y*this.y+this.z*this.z}length(){return Math.sqrt(this.x*this.x+this.y*this.y+this.z*this.z)}manhattanLength(){return Math.abs(this.x)+Math.abs(this.y)+Math.abs(this.z)}normalize(){return this.divideScalar(this.length()||1)}setLength(t){return this.normalize().multiplyScalar(t)}lerp(t,i){return this.x+=(t.x-this.x)*i,this.y+=(t.y-this.y)*i,this.z+=(t.z-this.z)*i,this}lerpVectors(t,i,a){return this.x=t.x+(i.x-t.x)*a,this.y=t.y+(i.y-t.y)*a,this.z=t.z+(i.z-t.z)*a,this}cross(t){return this.crossVectors(this,t)}crossVectors(t,i){const a=t.x,l=t.y,u=t.z,h=i.x,f=i.y,m=i.z;return this.x=l*m-u*f,this.y=u*h-a*m,this.z=a*f-l*h,this}projectOnVector(t){const i=t.lengthSq();if(i===0)return this.set(0,0,0);const a=t.dot(this)/i;return this.copy(t).multiplyScalar(a)}projectOnPlane(t){return Vd.copy(this).projectOnVector(t),this.sub(Vd)}reflect(t){return this.sub(Vd.copy(t).multiplyScalar(2*this.dot(t)))}angleTo(t){const i=Math.sqrt(this.lengthSq()*t.lengthSq());if(i===0)return Math.PI/2;const a=this.dot(t)/i;return Math.acos(_t(a,-1,1))}distanceTo(t){return Math.sqrt(this.distanceToSquared(t))}distanceToSquared(t){const i=this.x-t.x,a=this.y-t.y,l=this.z-t.z;return i*i+a*a+l*l}manhattanDistanceTo(t){return Math.abs(this.x-t.x)+Math.abs(this.y-t.y)+Math.abs(this.z-t.z)}setFromSpherical(t){return this.setFromSphericalCoords(t.radius,t.phi,t.theta)}setFromSphericalCoords(t,i,a){const l=Math.sin(i)*t;return this.x=l*Math.sin(a),this.y=Math.cos(i)*t,this.z=l*Math.cos(a),this}setFromCylindrical(t){return this.setFromCylindricalCoords(t.radius,t.theta,t.y)}setFromCylindricalCoords(t,i,a){return this.x=t*Math.sin(i),this.y=a,this.z=t*Math.cos(i),this}setFromMatrixPosition(t){const i=t.elements;return this.x=i[12],this.y=i[13],this.z=i[14],this}setFromMatrixScale(t){const i=this.setFromMatrixColumn(t,0).length(),a=this.setFromMatrixColumn(t,1).length(),l=this.setFromMatrixColumn(t,2).length();return this.x=i,this.y=a,this.z=l,this}setFromMatrixColumn(t,i){return this.fromArray(t.elements,i*4)}setFromMatrix3Column(t,i){return this.fromArray(t.elements,i*3)}setFromEuler(t){return this.x=t._x,this.y=t._y,this.z=t._z,this}setFromColor(t){return this.x=t.r,this.y=t.g,this.z=t.b,this}equals(t){return t.x===this.x&&t.y===this.y&&t.z===this.z}fromArray(t,i=0){return this.x=t[i],this.y=t[i+1],this.z=t[i+2],this}toArray(t=[],i=0){return t[i]=this.x,t[i+1]=this.y,t[i+2]=this.z,t}fromBufferAttribute(t,i){return this.x=t.getX(i),this.y=t.getY(i),this.z=t.getZ(i),this}random(){return this.x=Math.random(),this.y=Math.random(),this.z=Math.random(),this}randomDirection(){const t=Math.random()*Math.PI*2,i=Math.random()*2-1,a=Math.sqrt(1-i*i);return this.x=a*Math.cos(t),this.y=i,this.z=a*Math.sin(t),this}*[Symbol.iterator](){yield this.x,yield this.y,yield this.z}}const Vd=new $,Rv=new Do;class Io{constructor(t=new $(1/0,1/0,1/0),i=new $(-1/0,-1/0,-1/0)){this.isBox3=!0,this.min=t,this.max=i}set(t,i){return this.min.copy(t),this.max.copy(i),this}setFromArray(t){this.makeEmpty();for(let i=0,a=t.length;i<a;i+=3)this.expandByPoint(mi.fromArray(t,i));return this}setFromBufferAttribute(t){this.makeEmpty();for(let i=0,a=t.count;i<a;i++)this.expandByPoint(mi.fromBufferAttribute(t,i));return this}setFromPoints(t){this.makeEmpty();for(let i=0,a=t.length;i<a;i++)this.expandByPoint(t[i]);return this}setFromCenterAndSize(t,i){const a=mi.copy(i).multiplyScalar(.5);return this.min.copy(t).sub(a),this.max.copy(t).add(a),this}setFromObject(t,i=!1){return this.makeEmpty(),this.expandByObject(t,i)}clone(){return new this.constructor().copy(this)}copy(t){return this.min.copy(t.min),this.max.copy(t.max),this}makeEmpty(){return this.min.x=this.min.y=this.min.z=1/0,this.max.x=this.max.y=this.max.z=-1/0,this}isEmpty(){return this.max.x<this.min.x||this.max.y<this.min.y||this.max.z<this.min.z}getCenter(t){return this.isEmpty()?t.set(0,0,0):t.addVectors(this.min,this.max).multiplyScalar(.5)}getSize(t){return this.isEmpty()?t.set(0,0,0):t.subVectors(this.max,this.min)}expandByPoint(t){return this.min.min(t),this.max.max(t),this}expandByVector(t){return this.min.sub(t),this.max.add(t),this}expandByScalar(t){return this.min.addScalar(-t),this.max.addScalar(t),this}expandByObject(t,i=!1){t.updateWorldMatrix(!1,!1);const a=t.geometry;if(a!==void 0){const u=a.getAttribute("position");if(i===!0&&u!==void 0&&t.isInstancedMesh!==!0)for(let h=0,f=u.count;h<f;h++)t.isMesh===!0?t.getVertexPosition(h,mi):mi.fromBufferAttribute(u,h),mi.applyMatrix4(t.matrixWorld),this.expandByPoint(mi);else t.boundingBox!==void 0?(t.boundingBox===null&&t.computeBoundingBox(),ql.copy(t.boundingBox)):(a.boundingBox===null&&a.computeBoundingBox(),ql.copy(a.boundingBox)),ql.applyMatrix4(t.matrixWorld),this.union(ql)}const l=t.children;for(let u=0,h=l.length;u<h;u++)this.expandByObject(l[u],i);return this}containsPoint(t){return t.x>=this.min.x&&t.x<=this.max.x&&t.y>=this.min.y&&t.y<=this.max.y&&t.z>=this.min.z&&t.z<=this.max.z}containsBox(t){return this.min.x<=t.min.x&&t.max.x<=this.max.x&&this.min.y<=t.min.y&&t.max.y<=this.max.y&&this.min.z<=t.min.z&&t.max.z<=this.max.z}getParameter(t,i){return i.set((t.x-this.min.x)/(this.max.x-this.min.x),(t.y-this.min.y)/(this.max.y-this.min.y),(t.z-this.min.z)/(this.max.z-this.min.z))}intersectsBox(t){return t.max.x>=this.min.x&&t.min.x<=this.max.x&&t.max.y>=this.min.y&&t.min.y<=this.max.y&&t.max.z>=this.min.z&&t.min.z<=this.max.z}intersectsSphere(t){return this.clampPoint(t.center,mi),mi.distanceToSquared(t.center)<=t.radius*t.radius}intersectsPlane(t){let i,a;return t.normal.x>0?(i=t.normal.x*this.min.x,a=t.normal.x*this.max.x):(i=t.normal.x*this.max.x,a=t.normal.x*this.min.x),t.normal.y>0?(i+=t.normal.y*this.min.y,a+=t.normal.y*this.max.y):(i+=t.normal.y*this.max.y,a+=t.normal.y*this.min.y),t.normal.z>0?(i+=t.normal.z*this.min.z,a+=t.normal.z*this.max.z):(i+=t.normal.z*this.max.z,a+=t.normal.z*this.min.z),i<=-t.constant&&a>=-t.constant}intersectsTriangle(t){if(this.isEmpty())return!1;this.getCenter(So),Ql.subVectors(this.max,So),is.subVectors(t.a,So),ns.subVectors(t.b,So),as.subVectors(t.c,So),Un.subVectors(ns,is),Dn.subVectors(as,ns),la.subVectors(is,as);let i=[0,-Un.z,Un.y,0,-Dn.z,Dn.y,0,-la.z,la.y,Un.z,0,-Un.x,Dn.z,0,-Dn.x,la.z,0,-la.x,-Un.y,Un.x,0,-Dn.y,Dn.x,0,-la.y,la.x,0];return!Gd(i,is,ns,as,Ql)||(i=[1,0,0,0,1,0,0,0,1],!Gd(i,is,ns,as,Ql))?!1:($l.crossVectors(Un,Dn),i=[$l.x,$l.y,$l.z],Gd(i,is,ns,as,Ql))}clampPoint(t,i){return i.copy(t).clamp(this.min,this.max)}distanceToPoint(t){return this.clampPoint(t,mi).distanceTo(t)}getBoundingSphere(t){return this.isEmpty()?t.makeEmpty():(this.getCenter(t.center),t.radius=this.getSize(mi).length()*.5),t}intersect(t){return this.min.max(t.min),this.max.min(t.max),this.isEmpty()&&this.makeEmpty(),this}union(t){return this.min.min(t.min),this.max.max(t.max),this}applyMatrix4(t){return this.isEmpty()?this:(Ki[0].set(this.min.x,this.min.y,this.min.z).applyMatrix4(t),Ki[1].set(this.min.x,this.min.y,this.max.z).applyMatrix4(t),Ki[2].set(this.min.x,this.max.y,this.min.z).applyMatrix4(t),Ki[3].set(this.min.x,this.max.y,this.max.z).applyMatrix4(t),Ki[4].set(this.max.x,this.min.y,this.min.z).applyMatrix4(t),Ki[5].set(this.max.x,this.min.y,this.max.z).applyMatrix4(t),Ki[6].set(this.max.x,this.max.y,this.min.z).applyMatrix4(t),Ki[7].set(this.max.x,this.max.y,this.max.z).applyMatrix4(t),this.setFromPoints(Ki),this)}translate(t){return this.min.add(t),this.max.add(t),this}equals(t){return t.min.equals(this.min)&&t.max.equals(this.max)}}const Ki=[new $,new $,new $,new $,new $,new $,new $,new $],mi=new $,ql=new Io,is=new $,ns=new $,as=new $,Un=new $,Dn=new $,la=new $,So=new $,Ql=new $,$l=new $,ca=new $;function Gd(o,t,i,a,l){for(let u=0,h=o.length-3;u<=h;u+=3){ca.fromArray(o,u);const f=l.x*Math.abs(ca.x)+l.y*Math.abs(ca.y)+l.z*Math.abs(ca.z),m=t.dot(ca),p=i.dot(ca),_=a.dot(ca);if(Math.max(-Math.max(m,p,_),Math.min(m,p,_))>f)return!1}return!0}const cS=new Io,bo=new $,Wd=new $;class ff{constructor(t=new $,i=-1){this.isSphere=!0,this.center=t,this.radius=i}set(t,i){return this.center.copy(t),this.radius=i,this}setFromPoints(t,i){const a=this.center;i!==void 0?a.copy(i):cS.setFromPoints(t).getCenter(a);let l=0;for(let u=0,h=t.length;u<h;u++)l=Math.max(l,a.distanceToSquared(t[u]));return this.radius=Math.sqrt(l),this}copy(t){return this.center.copy(t.center),this.radius=t.radius,this}isEmpty(){return this.radius<0}makeEmpty(){return this.center.set(0,0,0),this.radius=-1,this}containsPoint(t){return t.distanceToSquared(this.center)<=this.radius*this.radius}distanceToPoint(t){return t.distanceTo(this.center)-this.radius}intersectsSphere(t){const i=this.radius+t.radius;return t.center.distanceToSquared(this.center)<=i*i}intersectsBox(t){return t.intersectsSphere(this)}intersectsPlane(t){return Math.abs(t.distanceToPoint(this.center))<=this.radius}clampPoint(t,i){const a=this.center.distanceToSquared(t);return i.copy(t),a>this.radius*this.radius&&(i.sub(this.center).normalize(),i.multiplyScalar(this.radius).add(this.center)),i}getBoundingBox(t){return this.isEmpty()?(t.makeEmpty(),t):(t.set(this.center,this.center),t.expandByScalar(this.radius),t)}applyMatrix4(t){return this.center.applyMatrix4(t),this.radius=this.radius*t.getMaxScaleOnAxis(),this}translate(t){return this.center.add(t),this}expandByPoint(t){if(this.isEmpty())return this.center.copy(t),this.radius=0,this;bo.subVectors(t,this.center);const i=bo.lengthSq();if(i>this.radius*this.radius){const a=Math.sqrt(i),l=(a-this.radius)*.5;this.center.addScaledVector(bo,l/a),this.radius+=l}return this}union(t){return t.isEmpty()?this:this.isEmpty()?(this.copy(t),this):(this.center.equals(t.center)===!0?this.radius=Math.max(this.radius,t.radius):(Wd.subVectors(t.center,this.center).setLength(t.radius),this.expandByPoint(bo.copy(t.center).add(Wd)),this.expandByPoint(bo.copy(t.center).sub(Wd))),this)}equals(t){return t.center.equals(this.center)&&t.radius===this.radius}clone(){return new this.constructor().copy(this)}}const Zi=new $,jd=new $,Kl=new $,In=new $,Xd=new $,Zl=new $,Yd=new $;class uS{constructor(t=new $,i=new $(0,0,-1)){this.origin=t,this.direction=i}set(t,i){return this.origin.copy(t),this.direction.copy(i),this}copy(t){return this.origin.copy(t.origin),this.direction.copy(t.direction),this}at(t,i){return i.copy(this.origin).addScaledVector(this.direction,t)}lookAt(t){return this.direction.copy(t).sub(this.origin).normalize(),this}recast(t){return this.origin.copy(this.at(t,Zi)),this}closestPointToPoint(t,i){i.subVectors(t,this.origin);const a=i.dot(this.direction);return a<0?i.copy(this.origin):i.copy(this.origin).addScaledVector(this.direction,a)}distanceToPoint(t){return Math.sqrt(this.distanceSqToPoint(t))}distanceSqToPoint(t){const i=Zi.subVectors(t,this.origin).dot(this.direction);return i<0?this.origin.distanceToSquared(t):(Zi.copy(this.origin).addScaledVector(this.direction,i),Zi.distanceToSquared(t))}distanceSqToSegment(t,i,a,l){jd.copy(t).add(i).multiplyScalar(.5),Kl.copy(i).sub(t).normalize(),In.copy(this.origin).sub(jd);const u=t.distanceTo(i)*.5,h=-this.direction.dot(Kl),f=In.dot(this.direction),m=-In.dot(Kl),p=In.lengthSq(),_=Math.abs(1-h*h);let y,x,b,R;if(_>0)if(y=h*m-f,x=h*f-m,R=u*_,y>=0)if(x>=-R)if(x<=R){const A=1/_;y*=A,x*=A,b=y*(y+h*x+2*f)+x*(h*y+x+2*m)+p}else x=u,y=Math.max(0,-(h*x+f)),b=-y*y+x*(x+2*m)+p;else x=-u,y=Math.max(0,-(h*x+f)),b=-y*y+x*(x+2*m)+p;else x<=-R?(y=Math.max(0,-(-h*u+f)),x=y>0?-u:Math.min(Math.max(-u,-m),u),b=-y*y+x*(x+2*m)+p):x<=R?(y=0,x=Math.min(Math.max(-u,-m),u),b=x*(x+2*m)+p):(y=Math.max(0,-(h*u+f)),x=y>0?u:Math.min(Math.max(-u,-m),u),b=-y*y+x*(x+2*m)+p);else x=h>0?-u:u,y=Math.max(0,-(h*x+f)),b=-y*y+x*(x+2*m)+p;return a&&a.copy(this.origin).addScaledVector(this.direction,y),l&&l.copy(jd).addScaledVector(Kl,x),b}intersectSphere(t,i){Zi.subVectors(t.center,this.origin);const a=Zi.dot(this.direction),l=Zi.dot(Zi)-a*a,u=t.radius*t.radius;if(l>u)return null;const h=Math.sqrt(u-l),f=a-h,m=a+h;return m<0?null:f<0?this.at(m,i):this.at(f,i)}intersectsSphere(t){return this.distanceSqToPoint(t.center)<=t.radius*t.radius}distanceToPlane(t){const i=t.normal.dot(this.direction);if(i===0)return t.distanceToPoint(this.origin)===0?0:null;const a=-(this.origin.dot(t.normal)+t.constant)/i;return a>=0?a:null}intersectPlane(t,i){const a=this.distanceToPlane(t);return a===null?null:this.at(a,i)}intersectsPlane(t){const i=t.distanceToPoint(this.origin);return i===0||t.normal.dot(this.direction)*i<0}intersectBox(t,i){let a,l,u,h,f,m;const p=1/this.direction.x,_=1/this.direction.y,y=1/this.direction.z,x=this.origin;return p>=0?(a=(t.min.x-x.x)*p,l=(t.max.x-x.x)*p):(a=(t.max.x-x.x)*p,l=(t.min.x-x.x)*p),_>=0?(u=(t.min.y-x.y)*_,h=(t.max.y-x.y)*_):(u=(t.max.y-x.y)*_,h=(t.min.y-x.y)*_),a>h||u>l||((u>a||isNaN(a))&&(a=u),(h<l||isNaN(l))&&(l=h),y>=0?(f=(t.min.z-x.z)*y,m=(t.max.z-x.z)*y):(f=(t.max.z-x.z)*y,m=(t.min.z-x.z)*y),a>m||f>l)||((f>a||a!==a)&&(a=f),(m<l||l!==l)&&(l=m),l<0)?null:this.at(a>=0?a:l,i)}intersectsBox(t){return this.intersectBox(t,Zi)!==null}intersectTriangle(t,i,a,l,u){Xd.subVectors(i,t),Zl.subVectors(a,t),Yd.crossVectors(Xd,Zl);let h=this.direction.dot(Yd),f;if(h>0){if(l)return null;f=1}else if(h<0)f=-1,h=-h;else return null;In.subVectors(this.origin,t);const m=f*this.direction.dot(Zl.crossVectors(In,Zl));if(m<0)return null;const p=f*this.direction.dot(Xd.cross(In));if(p<0||m+p>h)return null;const _=-f*In.dot(Yd);return _<0?null:this.at(_/h,u)}applyMatrix4(t){return this.origin.applyMatrix4(t),this.direction.transformDirection(t),this}equals(t){return t.origin.equals(this.origin)&&t.direction.equals(this.direction)}clone(){return new this.constructor().copy(this)}}class Yt{constructor(t,i,a,l,u,h,f,m,p,_,y,x,b,R,A,S){Yt.prototype.isMatrix4=!0,this.elements=[1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1],t!==void 0&&this.set(t,i,a,l,u,h,f,m,p,_,y,x,b,R,A,S)}set(t,i,a,l,u,h,f,m,p,_,y,x,b,R,A,S){const v=this.elements;return v[0]=t,v[4]=i,v[8]=a,v[12]=l,v[1]=u,v[5]=h,v[9]=f,v[13]=m,v[2]=p,v[6]=_,v[10]=y,v[14]=x,v[3]=b,v[7]=R,v[11]=A,v[15]=S,this}identity(){return this.set(1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1),this}clone(){return new Yt().fromArray(this.elements)}copy(t){const i=this.elements,a=t.elements;return i[0]=a[0],i[1]=a[1],i[2]=a[2],i[3]=a[3],i[4]=a[4],i[5]=a[5],i[6]=a[6],i[7]=a[7],i[8]=a[8],i[9]=a[9],i[10]=a[10],i[11]=a[11],i[12]=a[12],i[13]=a[13],i[14]=a[14],i[15]=a[15],this}copyPosition(t){const i=this.elements,a=t.elements;return i[12]=a[12],i[13]=a[13],i[14]=a[14],this}setFromMatrix3(t){const i=t.elements;return this.set(i[0],i[3],i[6],0,i[1],i[4],i[7],0,i[2],i[5],i[8],0,0,0,0,1),this}extractBasis(t,i,a){return t.setFromMatrixColumn(this,0),i.setFromMatrixColumn(this,1),a.setFromMatrixColumn(this,2),this}makeBasis(t,i,a){return this.set(t.x,i.x,a.x,0,t.y,i.y,a.y,0,t.z,i.z,a.z,0,0,0,0,1),this}extractRotation(t){const i=this.elements,a=t.elements,l=1/ss.setFromMatrixColumn(t,0).length(),u=1/ss.setFromMatrixColumn(t,1).length(),h=1/ss.setFromMatrixColumn(t,2).length();return i[0]=a[0]*l,i[1]=a[1]*l,i[2]=a[2]*l,i[3]=0,i[4]=a[4]*u,i[5]=a[5]*u,i[6]=a[6]*u,i[7]=0,i[8]=a[8]*h,i[9]=a[9]*h,i[10]=a[10]*h,i[11]=0,i[12]=0,i[13]=0,i[14]=0,i[15]=1,this}makeRotationFromEuler(t){const i=this.elements,a=t.x,l=t.y,u=t.z,h=Math.cos(a),f=Math.sin(a),m=Math.cos(l),p=Math.sin(l),_=Math.cos(u),y=Math.sin(u);if(t.order==="XYZ"){const x=h*_,b=h*y,R=f*_,A=f*y;i[0]=m*_,i[4]=-m*y,i[8]=p,i[1]=b+R*p,i[5]=x-A*p,i[9]=-f*m,i[2]=A-x*p,i[6]=R+b*p,i[10]=h*m}else if(t.order==="YXZ"){const x=m*_,b=m*y,R=p*_,A=p*y;i[0]=x+A*f,i[4]=R*f-b,i[8]=h*p,i[1]=h*y,i[5]=h*_,i[9]=-f,i[2]=b*f-R,i[6]=A+x*f,i[10]=h*m}else if(t.order==="ZXY"){const x=m*_,b=m*y,R=p*_,A=p*y;i[0]=x-A*f,i[4]=-h*y,i[8]=R+b*f,i[1]=b+R*f,i[5]=h*_,i[9]=A-x*f,i[2]=-h*p,i[6]=f,i[10]=h*m}else if(t.order==="ZYX"){const x=h*_,b=h*y,R=f*_,A=f*y;i[0]=m*_,i[4]=R*p-b,i[8]=x*p+A,i[1]=m*y,i[5]=A*p+x,i[9]=b*p-R,i[2]=-p,i[6]=f*m,i[10]=h*m}else if(t.order==="YZX"){const x=h*m,b=h*p,R=f*m,A=f*p;i[0]=m*_,i[4]=A-x*y,i[8]=R*y+b,i[1]=y,i[5]=h*_,i[9]=-f*_,i[2]=-p*_,i[6]=b*y+R,i[10]=x-A*y}else if(t.order==="XZY"){const x=h*m,b=h*p,R=f*m,A=f*p;i[0]=m*_,i[4]=-y,i[8]=p*_,i[1]=x*y+A,i[5]=h*_,i[9]=b*y-R,i[2]=R*y-b,i[6]=f*_,i[10]=A*y+x}return i[3]=0,i[7]=0,i[11]=0,i[12]=0,i[13]=0,i[14]=0,i[15]=1,this}makeRotationFromQuaternion(t){return this.compose(dS,t,hS)}lookAt(t,i,a){const l=this.elements;return qr.subVectors(t,i),qr.lengthSq()===0&&(qr.z=1),qr.normalize(),Nn.crossVectors(a,qr),Nn.lengthSq()===0&&(Math.abs(a.z)===1?qr.x+=1e-4:qr.z+=1e-4,qr.normalize(),Nn.crossVectors(a,qr)),Nn.normalize(),Jl.crossVectors(qr,Nn),l[0]=Nn.x,l[4]=Jl.x,l[8]=qr.x,l[1]=Nn.y,l[5]=Jl.y,l[9]=qr.y,l[2]=Nn.z,l[6]=Jl.z,l[10]=qr.z,this}multiply(t){return this.multiplyMatrices(this,t)}premultiply(t){return this.multiplyMatrices(t,this)}multiplyMatrices(t,i){const a=t.elements,l=i.elements,u=this.elements,h=a[0],f=a[4],m=a[8],p=a[12],_=a[1],y=a[5],x=a[9],b=a[13],R=a[2],A=a[6],S=a[10],v=a[14],D=a[3],L=a[7],C=a[11],G=a[15],k=l[0],I=l[4],H=l[8],P=l[12],w=l[1],F=l[5],te=l[9],se=l[13],ce=l[2],ve=l[6],N=l[10],K=l[14],q=l[3],ge=l[7],we=l[11],O=l[15];return u[0]=h*k+f*w+m*ce+p*q,u[4]=h*I+f*F+m*ve+p*ge,u[8]=h*H+f*te+m*N+p*we,u[12]=h*P+f*se+m*K+p*O,u[1]=_*k+y*w+x*ce+b*q,u[5]=_*I+y*F+x*ve+b*ge,u[9]=_*H+y*te+x*N+b*we,u[13]=_*P+y*se+x*K+b*O,u[2]=R*k+A*w+S*ce+v*q,u[6]=R*I+A*F+S*ve+v*ge,u[10]=R*H+A*te+S*N+v*we,u[14]=R*P+A*se+S*K+v*O,u[3]=D*k+L*w+C*ce+G*q,u[7]=D*I+L*F+C*ve+G*ge,u[11]=D*H+L*te+C*N+G*we,u[15]=D*P+L*se+C*K+G*O,this}multiplyScalar(t){const i=this.elements;return i[0]*=t,i[4]*=t,i[8]*=t,i[12]*=t,i[1]*=t,i[5]*=t,i[9]*=t,i[13]*=t,i[2]*=t,i[6]*=t,i[10]*=t,i[14]*=t,i[3]*=t,i[7]*=t,i[11]*=t,i[15]*=t,this}determinant(){const t=this.elements,i=t[0],a=t[4],l=t[8],u=t[12],h=t[1],f=t[5],m=t[9],p=t[13],_=t[2],y=t[6],x=t[10],b=t[14],R=t[3],A=t[7],S=t[11],v=t[15];return R*(+u*m*y-l*p*y-u*f*x+a*p*x+l*f*b-a*m*b)+A*(+i*m*b-i*p*x+u*h*x-l*h*b+l*p*_-u*m*_)+S*(+i*p*y-i*f*b-u*h*y+a*h*b+u*f*_-a*p*_)+v*(-l*f*_-i*m*y+i*f*x+l*h*y-a*h*x+a*m*_)}transpose(){const t=this.elements;let i;return i=t[1],t[1]=t[4],t[4]=i,i=t[2],t[2]=t[8],t[8]=i,i=t[6],t[6]=t[9],t[9]=i,i=t[3],t[3]=t[12],t[12]=i,i=t[7],t[7]=t[13],t[13]=i,i=t[11],t[11]=t[14],t[14]=i,this}setPosition(t,i,a){const l=this.elements;return t.isVector3?(l[12]=t.x,l[13]=t.y,l[14]=t.z):(l[12]=t,l[13]=i,l[14]=a),this}invert(){const t=this.elements,i=t[0],a=t[1],l=t[2],u=t[3],h=t[4],f=t[5],m=t[6],p=t[7],_=t[8],y=t[9],x=t[10],b=t[11],R=t[12],A=t[13],S=t[14],v=t[15],D=y*S*p-A*x*p+A*m*b-f*S*b-y*m*v+f*x*v,L=R*x*p-_*S*p-R*m*b+h*S*b+_*m*v-h*x*v,C=_*A*p-R*y*p+R*f*b-h*A*b-_*f*v+h*y*v,G=R*y*m-_*A*m-R*f*x+h*A*x+_*f*S-h*y*S,k=i*D+a*L+l*C+u*G;if(k===0)return this.set(0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0);const I=1/k;return t[0]=D*I,t[1]=(A*x*u-y*S*u-A*l*b+a*S*b+y*l*v-a*x*v)*I,t[2]=(f*S*u-A*m*u+A*l*p-a*S*p-f*l*v+a*m*v)*I,t[3]=(y*m*u-f*x*u-y*l*p+a*x*p+f*l*b-a*m*b)*I,t[4]=L*I,t[5]=(_*S*u-R*x*u+R*l*b-i*S*b-_*l*v+i*x*v)*I,t[6]=(R*m*u-h*S*u-R*l*p+i*S*p+h*l*v-i*m*v)*I,t[7]=(h*x*u-_*m*u+_*l*p-i*x*p-h*l*b+i*m*b)*I,t[8]=C*I,t[9]=(R*y*u-_*A*u-R*a*b+i*A*b+_*a*v-i*y*v)*I,t[10]=(h*A*u-R*f*u+R*a*p-i*A*p-h*a*v+i*f*v)*I,t[11]=(_*f*u-h*y*u-_*a*p+i*y*p+h*a*b-i*f*b)*I,t[12]=G*I,t[13]=(_*A*l-R*y*l+R*a*x-i*A*x-_*a*S+i*y*S)*I,t[14]=(R*f*l-h*A*l-R*a*m+i*A*m+h*a*S-i*f*S)*I,t[15]=(h*y*l-_*f*l+_*a*m-i*y*m-h*a*x+i*f*x)*I,this}scale(t){const i=this.elements,a=t.x,l=t.y,u=t.z;return i[0]*=a,i[4]*=l,i[8]*=u,i[1]*=a,i[5]*=l,i[9]*=u,i[2]*=a,i[6]*=l,i[10]*=u,i[3]*=a,i[7]*=l,i[11]*=u,this}getMaxScaleOnAxis(){const t=this.elements,i=t[0]*t[0]+t[1]*t[1]+t[2]*t[2],a=t[4]*t[4]+t[5]*t[5]+t[6]*t[6],l=t[8]*t[8]+t[9]*t[9]+t[10]*t[10];return Math.sqrt(Math.max(i,a,l))}makeTranslation(t,i,a){return t.isVector3?this.set(1,0,0,t.x,0,1,0,t.y,0,0,1,t.z,0,0,0,1):this.set(1,0,0,t,0,1,0,i,0,0,1,a,0,0,0,1),this}makeRotationX(t){const i=Math.cos(t),a=Math.sin(t);return this.set(1,0,0,0,0,i,-a,0,0,a,i,0,0,0,0,1),this}makeRotationY(t){const i=Math.cos(t),a=Math.sin(t);return this.set(i,0,a,0,0,1,0,0,-a,0,i,0,0,0,0,1),this}makeRotationZ(t){const i=Math.cos(t),a=Math.sin(t);return this.set(i,-a,0,0,a,i,0,0,0,0,1,0,0,0,0,1),this}makeRotationAxis(t,i){const a=Math.cos(i),l=Math.sin(i),u=1-a,h=t.x,f=t.y,m=t.z,p=u*h,_=u*f;return this.set(p*h+a,p*f-l*m,p*m+l*f,0,p*f+l*m,_*f+a,_*m-l*h,0,p*m-l*f,_*m+l*h,u*m*m+a,0,0,0,0,1),this}makeScale(t,i,a){return this.set(t,0,0,0,0,i,0,0,0,0,a,0,0,0,0,1),this}makeShear(t,i,a,l,u,h){return this.set(1,a,u,0,t,1,h,0,i,l,1,0,0,0,0,1),this}compose(t,i,a){const l=this.elements,u=i._x,h=i._y,f=i._z,m=i._w,p=u+u,_=h+h,y=f+f,x=u*p,b=u*_,R=u*y,A=h*_,S=h*y,v=f*y,D=m*p,L=m*_,C=m*y,G=a.x,k=a.y,I=a.z;return l[0]=(1-(A+v))*G,l[1]=(b+C)*G,l[2]=(R-L)*G,l[3]=0,l[4]=(b-C)*k,l[5]=(1-(x+v))*k,l[6]=(S+D)*k,l[7]=0,l[8]=(R+L)*I,l[9]=(S-D)*I,l[10]=(1-(x+A))*I,l[11]=0,l[12]=t.x,l[13]=t.y,l[14]=t.z,l[15]=1,this}decompose(t,i,a){const l=this.elements;let u=ss.set(l[0],l[1],l[2]).length();const h=ss.set(l[4],l[5],l[6]).length(),f=ss.set(l[8],l[9],l[10]).length();this.determinant()<0&&(u=-u),t.x=l[12],t.y=l[13],t.z=l[14],gi.copy(this);const m=1/u,p=1/h,_=1/f;return gi.elements[0]*=m,gi.elements[1]*=m,gi.elements[2]*=m,gi.elements[4]*=p,gi.elements[5]*=p,gi.elements[6]*=p,gi.elements[8]*=_,gi.elements[9]*=_,gi.elements[10]*=_,i.setFromRotationMatrix(gi),a.x=u,a.y=h,a.z=f,this}makePerspective(t,i,a,l,u,h,f=on){const m=this.elements,p=2*u/(i-t),_=2*u/(a-l),y=(i+t)/(i-t),x=(a+l)/(a-l);let b,R;if(f===on)b=-(h+u)/(h-u),R=-2*h*u/(h-u);else if(f===Ec)b=-h/(h-u),R=-h*u/(h-u);else throw new Error("THREE.Matrix4.makePerspective(): Invalid coordinate system: "+f);return m[0]=p,m[4]=0,m[8]=y,m[12]=0,m[1]=0,m[5]=_,m[9]=x,m[13]=0,m[2]=0,m[6]=0,m[10]=b,m[14]=R,m[3]=0,m[7]=0,m[11]=-1,m[15]=0,this}makeOrthographic(t,i,a,l,u,h,f=on){const m=this.elements,p=1/(i-t),_=1/(a-l),y=1/(h-u),x=(i+t)*p,b=(a+l)*_;let R,A;if(f===on)R=(h+u)*y,A=-2*y;else if(f===Ec)R=u*y,A=-1*y;else throw new Error("THREE.Matrix4.makeOrthographic(): Invalid coordinate system: "+f);return m[0]=2*p,m[4]=0,m[8]=0,m[12]=-x,m[1]=0,m[5]=2*_,m[9]=0,m[13]=-b,m[2]=0,m[6]=0,m[10]=A,m[14]=-R,m[3]=0,m[7]=0,m[11]=0,m[15]=1,this}equals(t){const i=this.elements,a=t.elements;for(let l=0;l<16;l++)if(i[l]!==a[l])return!1;return!0}fromArray(t,i=0){for(let a=0;a<16;a++)this.elements[a]=t[a+i];return this}toArray(t=[],i=0){const a=this.elements;return t[i]=a[0],t[i+1]=a[1],t[i+2]=a[2],t[i+3]=a[3],t[i+4]=a[4],t[i+5]=a[5],t[i+6]=a[6],t[i+7]=a[7],t[i+8]=a[8],t[i+9]=a[9],t[i+10]=a[10],t[i+11]=a[11],t[i+12]=a[12],t[i+13]=a[13],t[i+14]=a[14],t[i+15]=a[15],t}}const ss=new $,gi=new Yt,dS=new $(0,0,0),hS=new $(1,1,1),Nn=new $,Jl=new $,qr=new $,Cv=new Yt,Av=new Do;class Li{constructor(t=0,i=0,a=0,l=Li.DEFAULT_ORDER){this.isEuler=!0,this._x=t,this._y=i,this._z=a,this._order=l}get x(){return this._x}set x(t){this._x=t,this._onChangeCallback()}get y(){return this._y}set y(t){this._y=t,this._onChangeCallback()}get z(){return this._z}set z(t){this._z=t,this._onChangeCallback()}get order(){return this._order}set order(t){this._order=t,this._onChangeCallback()}set(t,i,a,l=this._order){return this._x=t,this._y=i,this._z=a,this._order=l,this._onChangeCallback(),this}clone(){return new this.constructor(this._x,this._y,this._z,this._order)}copy(t){return this._x=t._x,this._y=t._y,this._z=t._z,this._order=t._order,this._onChangeCallback(),this}setFromRotationMatrix(t,i=this._order,a=!0){const l=t.elements,u=l[0],h=l[4],f=l[8],m=l[1],p=l[5],_=l[9],y=l[2],x=l[6],b=l[10];switch(i){case"XYZ":this._y=Math.asin(_t(f,-1,1)),Math.abs(f)<.9999999?(this._x=Math.atan2(-_,b),this._z=Math.atan2(-h,u)):(this._x=Math.atan2(x,p),this._z=0);break;case"YXZ":this._x=Math.asin(-_t(_,-1,1)),Math.abs(_)<.9999999?(this._y=Math.atan2(f,b),this._z=Math.atan2(m,p)):(this._y=Math.atan2(-y,u),this._z=0);break;case"ZXY":this._x=Math.asin(_t(x,-1,1)),Math.abs(x)<.9999999?(this._y=Math.atan2(-y,b),this._z=Math.atan2(-h,p)):(this._y=0,this._z=Math.atan2(m,u));break;case"ZYX":this._y=Math.asin(-_t(y,-1,1)),Math.abs(y)<.9999999?(this._x=Math.atan2(x,b),this._z=Math.atan2(m,u)):(this._x=0,this._z=Math.atan2(-h,p));break;case"YZX":this._z=Math.asin(_t(m,-1,1)),Math.abs(m)<.9999999?(this._x=Math.atan2(-_,p),this._y=Math.atan2(-y,u)):(this._x=0,this._y=Math.atan2(f,b));break;case"XZY":this._z=Math.asin(-_t(h,-1,1)),Math.abs(h)<.9999999?(this._x=Math.atan2(x,p),this._y=Math.atan2(f,u)):(this._x=Math.atan2(-_,b),this._y=0);break;default:console.warn("THREE.Euler: .setFromRotationMatrix() encountered an unknown order: "+i)}return this._order=i,a===!0&&this._onChangeCallback(),this}setFromQuaternion(t,i,a){return Cv.makeRotationFromQuaternion(t),this.setFromRotationMatrix(Cv,i,a)}setFromVector3(t,i=this._order){return this.set(t.x,t.y,t.z,i)}reorder(t){return Av.setFromEuler(this),this.setFromQuaternion(Av,t)}equals(t){return t._x===this._x&&t._y===this._y&&t._z===this._z&&t._order===this._order}fromArray(t){return this._x=t[0],this._y=t[1],this._z=t[2],t[3]!==void 0&&(this._order=t[3]),this._onChangeCallback(),this}toArray(t=[],i=0){return t[i]=this._x,t[i+1]=this._y,t[i+2]=this._z,t[i+3]=this._order,t}_onChange(t){return this._onChangeCallback=t,this}_onChangeCallback(){}*[Symbol.iterator](){yield this._x,yield this._y,yield this._z,yield this._order}}Li.DEFAULT_ORDER="XYZ";class k_{constructor(){this.mask=1}set(t){this.mask=(1<<t|0)>>>0}enable(t){this.mask|=1<<t|0}enableAll(){this.mask=-1}toggle(t){this.mask^=1<<t|0}disable(t){this.mask&=~(1<<t|0)}disableAll(){this.mask=0}test(t){return(this.mask&t.mask)!==0}isEnabled(t){return(this.mask&(1<<t|0))!==0}}let fS=0;const Pv=new $,os=new Do,Ji=new Yt,ec=new $,Mo=new $,pS=new $,mS=new Do,Lv=new $(1,0,0),Uv=new $(0,1,0),Dv=new $(0,0,1),Iv={type:"added"},gS={type:"removed"},ls={type:"childadded",child:null},qd={type:"childremoved",child:null};class Mr extends Ms{constructor(){super(),this.isObject3D=!0,Object.defineProperty(this,"id",{value:fS++}),this.uuid=Uo(),this.name="",this.type="Object3D",this.parent=null,this.children=[],this.up=Mr.DEFAULT_UP.clone();const t=new $,i=new Li,a=new Do,l=new $(1,1,1);function u(){a.setFromEuler(i,!1)}function h(){i.setFromQuaternion(a,void 0,!1)}i._onChange(u),a._onChange(h),Object.defineProperties(this,{position:{configurable:!0,enumerable:!0,value:t},rotation:{configurable:!0,enumerable:!0,value:i},quaternion:{configurable:!0,enumerable:!0,value:a},scale:{configurable:!0,enumerable:!0,value:l},modelViewMatrix:{value:new Yt},normalMatrix:{value:new at}}),this.matrix=new Yt,this.matrixWorld=new Yt,this.matrixAutoUpdate=Mr.DEFAULT_MATRIX_AUTO_UPDATE,this.matrixWorldAutoUpdate=Mr.DEFAULT_MATRIX_WORLD_AUTO_UPDATE,this.matrixWorldNeedsUpdate=!1,this.layers=new k_,this.visible=!0,this.castShadow=!1,this.receiveShadow=!1,this.frustumCulled=!0,this.renderOrder=0,this.animations=[],this.customDepthMaterial=void 0,this.customDistanceMaterial=void 0,this.userData={}}onBeforeShadow(){}onAfterShadow(){}onBeforeRender(){}onAfterRender(){}applyMatrix4(t){this.matrixAutoUpdate&&this.updateMatrix(),this.matrix.premultiply(t),this.matrix.decompose(this.position,this.quaternion,this.scale)}applyQuaternion(t){return this.quaternion.premultiply(t),this}setRotationFromAxisAngle(t,i){this.quaternion.setFromAxisAngle(t,i)}setRotationFromEuler(t){this.quaternion.setFromEuler(t,!0)}setRotationFromMatrix(t){this.quaternion.setFromRotationMatrix(t)}setRotationFromQuaternion(t){this.quaternion.copy(t)}rotateOnAxis(t,i){return os.setFromAxisAngle(t,i),this.quaternion.multiply(os),this}rotateOnWorldAxis(t,i){return os.setFromAxisAngle(t,i),this.quaternion.premultiply(os),this}rotateX(t){return this.rotateOnAxis(Lv,t)}rotateY(t){return this.rotateOnAxis(Uv,t)}rotateZ(t){return this.rotateOnAxis(Dv,t)}translateOnAxis(t,i){return Pv.copy(t).applyQuaternion(this.quaternion),this.position.add(Pv.multiplyScalar(i)),this}translateX(t){return this.translateOnAxis(Lv,t)}translateY(t){return this.translateOnAxis(Uv,t)}translateZ(t){return this.translateOnAxis(Dv,t)}localToWorld(t){return this.updateWorldMatrix(!0,!1),t.applyMatrix4(this.matrixWorld)}worldToLocal(t){return this.updateWorldMatrix(!0,!1),t.applyMatrix4(Ji.copy(this.matrixWorld).invert())}lookAt(t,i,a){t.isVector3?ec.copy(t):ec.set(t,i,a);const l=this.parent;this.updateWorldMatrix(!0,!1),Mo.setFromMatrixPosition(this.matrixWorld),this.isCamera||this.isLight?Ji.lookAt(Mo,ec,this.up):Ji.lookAt(ec,Mo,this.up),this.quaternion.setFromRotationMatrix(Ji),l&&(Ji.extractRotation(l.matrixWorld),os.setFromRotationMatrix(Ji),this.quaternion.premultiply(os.invert()))}add(t){if(arguments.length>1){for(let i=0;i<arguments.length;i++)this.add(arguments[i]);return this}return t===this?(console.error("THREE.Object3D.add: object can't be added as a child of itself.",t),this):(t&&t.isObject3D?(t.removeFromParent(),t.parent=this,this.children.push(t),t.dispatchEvent(Iv),ls.child=t,this.dispatchEvent(ls),ls.child=null):console.error("THREE.Object3D.add: object not an instance of THREE.Object3D.",t),this)}remove(t){if(arguments.length>1){for(let a=0;a<arguments.length;a++)this.remove(arguments[a]);return this}const i=this.children.indexOf(t);return i!==-1&&(t.parent=null,this.children.splice(i,1),t.dispatchEvent(gS),qd.child=t,this.dispatchEvent(qd),qd.child=null),this}removeFromParent(){const t=this.parent;return t!==null&&t.remove(this),this}clear(){return this.remove(...this.children)}attach(t){return this.updateWorldMatrix(!0,!1),Ji.copy(this.matrixWorld).invert(),t.parent!==null&&(t.parent.updateWorldMatrix(!0,!1),Ji.multiply(t.parent.matrixWorld)),t.applyMatrix4(Ji),t.removeFromParent(),t.parent=this,this.children.push(t),t.updateWorldMatrix(!1,!0),t.dispatchEvent(Iv),ls.child=t,this.dispatchEvent(ls),ls.child=null,this}getObjectById(t){return this.getObjectByProperty("id",t)}getObjectByName(t){return this.getObjectByProperty("name",t)}getObjectByProperty(t,i){if(this[t]===i)return this;for(let a=0,l=this.children.length;a<l;a++){const u=this.children[a].getObjectByProperty(t,i);if(u!==void 0)return u}}getObjectsByProperty(t,i,a=[]){this[t]===i&&a.push(this);const l=this.children;for(let u=0,h=l.length;u<h;u++)l[u].getObjectsByProperty(t,i,a);return a}getWorldPosition(t){return this.updateWorldMatrix(!0,!1),t.setFromMatrixPosition(this.matrixWorld)}getWorldQuaternion(t){return this.updateWorldMatrix(!0,!1),this.matrixWorld.decompose(Mo,t,pS),t}getWorldScale(t){return this.updateWorldMatrix(!0,!1),this.matrixWorld.decompose(Mo,mS,t),t}getWorldDirection(t){this.updateWorldMatrix(!0,!1);const i=this.matrixWorld.elements;return t.set(i[8],i[9],i[10]).normalize()}raycast(){}traverse(t){t(this);const i=this.children;for(let a=0,l=i.length;a<l;a++)i[a].traverse(t)}traverseVisible(t){if(this.visible===!1)return;t(this);const i=this.children;for(let a=0,l=i.length;a<l;a++)i[a].traverseVisible(t)}traverseAncestors(t){const i=this.parent;i!==null&&(t(i),i.traverseAncestors(t))}updateMatrix(){this.matrix.compose(this.position,this.quaternion,this.scale),this.matrixWorldNeedsUpdate=!0}updateMatrixWorld(t){this.matrixAutoUpdate&&this.updateMatrix(),(this.matrixWorldNeedsUpdate||t)&&(this.matrixWorldAutoUpdate===!0&&(this.parent===null?this.matrixWorld.copy(this.matrix):this.matrixWorld.multiplyMatrices(this.parent.matrixWorld,this.matrix)),this.matrixWorldNeedsUpdate=!1,t=!0);const i=this.children;for(let a=0,l=i.length;a<l;a++)i[a].updateMatrixWorld(t)}updateWorldMatrix(t,i){const a=this.parent;if(t===!0&&a!==null&&a.updateWorldMatrix(!0,!1),this.matrixAutoUpdate&&this.updateMatrix(),this.matrixWorldAutoUpdate===!0&&(this.parent===null?this.matrixWorld.copy(this.matrix):this.matrixWorld.multiplyMatrices(this.parent.matrixWorld,this.matrix)),i===!0){const l=this.children;for(let u=0,h=l.length;u<h;u++)l[u].updateWorldMatrix(!1,!0)}}toJSON(t){const i=t===void 0||typeof t=="string",a={};i&&(t={geometries:{},materials:{},textures:{},images:{},shapes:{},skeletons:{},animations:{},nodes:{}},a.metadata={version:4.6,type:"Object",generator:"Object3D.toJSON"});const l={};l.uuid=this.uuid,l.type=this.type,this.name!==""&&(l.name=this.name),this.castShadow===!0&&(l.castShadow=!0),this.receiveShadow===!0&&(l.receiveShadow=!0),this.visible===!1&&(l.visible=!1),this.frustumCulled===!1&&(l.frustumCulled=!1),this.renderOrder!==0&&(l.renderOrder=this.renderOrder),Object.keys(this.userData).length>0&&(l.userData=this.userData),l.layers=this.layers.mask,l.matrix=this.matrix.toArray(),l.up=this.up.toArray(),this.matrixAutoUpdate===!1&&(l.matrixAutoUpdate=!1),this.isInstancedMesh&&(l.type="InstancedMesh",l.count=this.count,l.instanceMatrix=this.instanceMatrix.toJSON(),this.instanceColor!==null&&(l.instanceColor=this.instanceColor.toJSON())),this.isBatchedMesh&&(l.type="BatchedMesh",l.perObjectFrustumCulled=this.perObjectFrustumCulled,l.sortObjects=this.sortObjects,l.drawRanges=this._drawRanges,l.reservedRanges=this._reservedRanges,l.geometryInfo=this._geometryInfo.map(f=>({...f,boundingBox:f.boundingBox?{min:f.boundingBox.min.toArray(),max:f.boundingBox.max.toArray()}:void 0,boundingSphere:f.boundingSphere?{radius:f.boundingSphere.radius,center:f.boundingSphere.center.toArray()}:void 0})),l.instanceInfo=this._instanceInfo.map(f=>({...f})),l.availableInstanceIds=this._availableInstanceIds.slice(),l.availableGeometryIds=this._availableGeometryIds.slice(),l.nextIndexStart=this._nextIndexStart,l.nextVertexStart=this._nextVertexStart,l.geometryCount=this._geometryCount,l.maxInstanceCount=this._maxInstanceCount,l.maxVertexCount=this._maxVertexCount,l.maxIndexCount=this._maxIndexCount,l.geometryInitialized=this._geometryInitialized,l.matricesTexture=this._matricesTexture.toJSON(t),l.indirectTexture=this._indirectTexture.toJSON(t),this._colorsTexture!==null&&(l.colorsTexture=this._colorsTexture.toJSON(t)),this.boundingSphere!==null&&(l.boundingSphere={center:this.boundingSphere.center.toArray(),radius:this.boundingSphere.radius}),this.boundingBox!==null&&(l.boundingBox={min:this.boundingBox.min.toArray(),max:this.boundingBox.max.toArray()}));function u(f,m){return f[m.uuid]===void 0&&(f[m.uuid]=m.toJSON(t)),m.uuid}if(this.isScene)this.background&&(this.background.isColor?l.background=this.background.toJSON():this.background.isTexture&&(l.background=this.background.toJSON(t).uuid)),this.environment&&this.environment.isTexture&&this.environment.isRenderTargetTexture!==!0&&(l.environment=this.environment.toJSON(t).uuid);else if(this.isMesh||this.isLine||this.isPoints){l.geometry=u(t.geometries,this.geometry);const f=this.geometry.parameters;if(f!==void 0&&f.shapes!==void 0){const m=f.shapes;if(Array.isArray(m))for(let p=0,_=m.length;p<_;p++){const y=m[p];u(t.shapes,y)}else u(t.shapes,m)}}if(this.isSkinnedMesh&&(l.bindMode=this.bindMode,l.bindMatrix=this.bindMatrix.toArray(),this.skeleton!==void 0&&(u(t.skeletons,this.skeleton),l.skeleton=this.skeleton.uuid)),this.material!==void 0)if(Array.isArray(this.material)){const f=[];for(let m=0,p=this.material.length;m<p;m++)f.push(u(t.materials,this.material[m]));l.material=f}else l.material=u(t.materials,this.material);if(this.children.length>0){l.children=[];for(let f=0;f<this.children.length;f++)l.children.push(this.children[f].toJSON(t).object)}if(this.animations.length>0){l.animations=[];for(let f=0;f<this.animations.length;f++){const m=this.animations[f];l.animations.push(u(t.animations,m))}}if(i){const f=h(t.geometries),m=h(t.materials),p=h(t.textures),_=h(t.images),y=h(t.shapes),x=h(t.skeletons),b=h(t.animations),R=h(t.nodes);f.length>0&&(a.geometries=f),m.length>0&&(a.materials=m),p.length>0&&(a.textures=p),_.length>0&&(a.images=_),y.length>0&&(a.shapes=y),x.length>0&&(a.skeletons=x),b.length>0&&(a.animations=b),R.length>0&&(a.nodes=R)}return a.object=l,a;function h(f){const m=[];for(const p in f){const _=f[p];delete _.metadata,m.push(_)}return m}}clone(t){return new this.constructor().copy(this,t)}copy(t,i=!0){if(this.name=t.name,this.up.copy(t.up),this.position.copy(t.position),this.rotation.order=t.rotation.order,this.quaternion.copy(t.quaternion),this.scale.copy(t.scale),this.matrix.copy(t.matrix),this.matrixWorld.copy(t.matrixWorld),this.matrixAutoUpdate=t.matrixAutoUpdate,this.matrixWorldAutoUpdate=t.matrixWorldAutoUpdate,this.matrixWorldNeedsUpdate=t.matrixWorldNeedsUpdate,this.layers.mask=t.layers.mask,this.visible=t.visible,this.castShadow=t.castShadow,this.receiveShadow=t.receiveShadow,this.frustumCulled=t.frustumCulled,this.renderOrder=t.renderOrder,this.animations=t.animations.slice(),this.userData=JSON.parse(JSON.stringify(t.userData)),i===!0)for(let a=0;a<t.children.length;a++){const l=t.children[a];this.add(l.clone())}return this}}Mr.DEFAULT_UP=new $(0,1,0);Mr.DEFAULT_MATRIX_AUTO_UPDATE=!0;Mr.DEFAULT_MATRIX_WORLD_AUTO_UPDATE=!0;const vi=new $,en=new $,Qd=new $,tn=new $,cs=new $,us=new $,Nv=new $,$d=new $,Kd=new $,Zd=new $,Jd=new Ft,eh=new Ft,th=new Ft;class yi{constructor(t=new $,i=new $,a=new $){this.a=t,this.b=i,this.c=a}static getNormal(t,i,a,l){l.subVectors(a,i),vi.subVectors(t,i),l.cross(vi);const u=l.lengthSq();return u>0?l.multiplyScalar(1/Math.sqrt(u)):l.set(0,0,0)}static getBarycoord(t,i,a,l,u){vi.subVectors(l,i),en.subVectors(a,i),Qd.subVectors(t,i);const h=vi.dot(vi),f=vi.dot(en),m=vi.dot(Qd),p=en.dot(en),_=en.dot(Qd),y=h*p-f*f;if(y===0)return u.set(0,0,0),null;const x=1/y,b=(p*m-f*_)*x,R=(h*_-f*m)*x;return u.set(1-b-R,R,b)}static containsPoint(t,i,a,l){return this.getBarycoord(t,i,a,l,tn)===null?!1:tn.x>=0&&tn.y>=0&&tn.x+tn.y<=1}static getInterpolation(t,i,a,l,u,h,f,m){return this.getBarycoord(t,i,a,l,tn)===null?(m.x=0,m.y=0,"z"in m&&(m.z=0),"w"in m&&(m.w=0),null):(m.setScalar(0),m.addScaledVector(u,tn.x),m.addScaledVector(h,tn.y),m.addScaledVector(f,tn.z),m)}static getInterpolatedAttribute(t,i,a,l,u,h){return Jd.setScalar(0),eh.setScalar(0),th.setScalar(0),Jd.fromBufferAttribute(t,i),eh.fromBufferAttribute(t,a),th.fromBufferAttribute(t,l),h.setScalar(0),h.addScaledVector(Jd,u.x),h.addScaledVector(eh,u.y),h.addScaledVector(th,u.z),h}static isFrontFacing(t,i,a,l){return vi.subVectors(a,i),en.subVectors(t,i),vi.cross(en).dot(l)<0}set(t,i,a){return this.a.copy(t),this.b.copy(i),this.c.copy(a),this}setFromPointsAndIndices(t,i,a,l){return this.a.copy(t[i]),this.b.copy(t[a]),this.c.copy(t[l]),this}setFromAttributeAndIndices(t,i,a,l){return this.a.fromBufferAttribute(t,i),this.b.fromBufferAttribute(t,a),this.c.fromBufferAttribute(t,l),this}clone(){return new this.constructor().copy(this)}copy(t){return this.a.copy(t.a),this.b.copy(t.b),this.c.copy(t.c),this}getArea(){return vi.subVectors(this.c,this.b),en.subVectors(this.a,this.b),vi.cross(en).length()*.5}getMidpoint(t){return t.addVectors(this.a,this.b).add(this.c).multiplyScalar(1/3)}getNormal(t){return yi.getNormal(this.a,this.b,this.c,t)}getPlane(t){return t.setFromCoplanarPoints(this.a,this.b,this.c)}getBarycoord(t,i){return yi.getBarycoord(t,this.a,this.b,this.c,i)}getInterpolation(t,i,a,l,u){return yi.getInterpolation(t,this.a,this.b,this.c,i,a,l,u)}containsPoint(t){return yi.containsPoint(t,this.a,this.b,this.c)}isFrontFacing(t){return yi.isFrontFacing(this.a,this.b,this.c,t)}intersectsBox(t){return t.intersectsTriangle(this)}closestPointToPoint(t,i){const a=this.a,l=this.b,u=this.c;let h,f;cs.subVectors(l,a),us.subVectors(u,a),$d.subVectors(t,a);const m=cs.dot($d),p=us.dot($d);if(m<=0&&p<=0)return i.copy(a);Kd.subVectors(t,l);const _=cs.dot(Kd),y=us.dot(Kd);if(_>=0&&y<=_)return i.copy(l);const x=m*y-_*p;if(x<=0&&m>=0&&_<=0)return h=m/(m-_),i.copy(a).addScaledVector(cs,h);Zd.subVectors(t,u);const b=cs.dot(Zd),R=us.dot(Zd);if(R>=0&&b<=R)return i.copy(u);const A=b*p-m*R;if(A<=0&&p>=0&&R<=0)return f=p/(p-R),i.copy(a).addScaledVector(us,f);const S=_*R-b*y;if(S<=0&&y-_>=0&&b-R>=0)return Nv.subVectors(u,l),f=(y-_)/(y-_+(b-R)),i.copy(l).addScaledVector(Nv,f);const v=1/(S+A+x);return h=A*v,f=x*v,i.copy(a).addScaledVector(cs,h).addScaledVector(us,f)}equals(t){return t.a.equals(this.a)&&t.b.equals(this.b)&&t.c.equals(this.c)}}const F_={aliceblue:15792383,antiquewhite:16444375,aqua:65535,aquamarine:8388564,azure:15794175,beige:16119260,bisque:16770244,black:0,blanchedalmond:16772045,blue:255,blueviolet:9055202,brown:10824234,burlywood:14596231,cadetblue:6266528,chartreuse:8388352,chocolate:13789470,coral:16744272,cornflowerblue:6591981,cornsilk:16775388,crimson:14423100,cyan:65535,darkblue:139,darkcyan:35723,darkgoldenrod:12092939,darkgray:11119017,darkgreen:25600,darkgrey:11119017,darkkhaki:12433259,darkmagenta:9109643,darkolivegreen:5597999,darkorange:16747520,darkorchid:10040012,darkred:9109504,darksalmon:15308410,darkseagreen:9419919,darkslateblue:4734347,darkslategray:3100495,darkslategrey:3100495,darkturquoise:52945,darkviolet:9699539,deeppink:16716947,deepskyblue:49151,dimgray:6908265,dimgrey:6908265,dodgerblue:2003199,firebrick:11674146,floralwhite:16775920,forestgreen:2263842,fuchsia:16711935,gainsboro:14474460,ghostwhite:16316671,gold:16766720,goldenrod:14329120,gray:8421504,green:32768,greenyellow:11403055,grey:8421504,honeydew:15794160,hotpink:16738740,indianred:13458524,indigo:4915330,ivory:16777200,khaki:15787660,lavender:15132410,lavenderblush:16773365,lawngreen:8190976,lemonchiffon:16775885,lightblue:11393254,lightcoral:15761536,lightcyan:14745599,lightgoldenrodyellow:16448210,lightgray:13882323,lightgreen:9498256,lightgrey:13882323,lightpink:16758465,lightsalmon:16752762,lightseagreen:2142890,lightskyblue:8900346,lightslategray:7833753,lightslategrey:7833753,lightsteelblue:11584734,lightyellow:16777184,lime:65280,limegreen:3329330,linen:16445670,magenta:16711935,maroon:8388608,mediumaquamarine:6737322,mediumblue:205,mediumorchid:12211667,mediumpurple:9662683,mediumseagreen:3978097,mediumslateblue:8087790,mediumspringgreen:64154,mediumturquoise:4772300,mediumvioletred:13047173,midnightblue:1644912,mintcream:16121850,mistyrose:16770273,moccasin:16770229,navajowhite:16768685,navy:128,oldlace:16643558,olive:8421376,olivedrab:7048739,orange:16753920,orangered:16729344,orchid:14315734,palegoldenrod:15657130,palegreen:10025880,paleturquoise:11529966,palevioletred:14381203,papayawhip:16773077,peachpuff:16767673,peru:13468991,pink:16761035,plum:14524637,powderblue:11591910,purple:8388736,rebeccapurple:6697881,red:16711680,rosybrown:12357519,royalblue:4286945,saddlebrown:9127187,salmon:16416882,sandybrown:16032864,seagreen:3050327,seashell:16774638,sienna:10506797,silver:12632256,skyblue:8900331,slateblue:6970061,slategray:7372944,slategrey:7372944,snow:16775930,springgreen:65407,steelblue:4620980,tan:13808780,teal:32896,thistle:14204888,tomato:16737095,turquoise:4251856,violet:15631086,wheat:16113331,white:16777215,whitesmoke:16119285,yellow:16776960,yellowgreen:10145074},On={h:0,s:0,l:0},tc={h:0,s:0,l:0};function rh(o,t,i){return i<0&&(i+=1),i>1&&(i-=1),i<1/6?o+(t-o)*6*i:i<1/2?t:i<2/3?o+(t-o)*6*(2/3-i):o}class xt{constructor(t,i,a){return this.isColor=!0,this.r=1,this.g=1,this.b=1,this.set(t,i,a)}set(t,i,a){if(i===void 0&&a===void 0){const l=t;l&&l.isColor?this.copy(l):typeof l=="number"?this.setHex(l):typeof l=="string"&&this.setStyle(l)}else this.setRGB(t,i,a);return this}setScalar(t){return this.r=t,this.g=t,this.b=t,this}setHex(t,i=ai){return t=Math.floor(t),this.r=(t>>16&255)/255,this.g=(t>>8&255)/255,this.b=(t&255)/255,Tt.toWorkingColorSpace(this,i),this}setRGB(t,i,a,l=Tt.workingColorSpace){return this.r=t,this.g=i,this.b=a,Tt.toWorkingColorSpace(this,l),this}setHSL(t,i,a,l=Tt.workingColorSpace){if(t=Zx(t,1),i=_t(i,0,1),a=_t(a,0,1),i===0)this.r=this.g=this.b=a;else{const u=a<=.5?a*(1+i):a+i-a*i,h=2*a-u;this.r=rh(h,u,t+1/3),this.g=rh(h,u,t),this.b=rh(h,u,t-1/3)}return Tt.toWorkingColorSpace(this,l),this}setStyle(t,i=ai){function a(u){u!==void 0&&parseFloat(u)<1&&console.warn("THREE.Color: Alpha component of "+t+" will be ignored.")}let l;if(l=/^(\w+)\(([^\)]*)\)/.exec(t)){let u;const h=l[1],f=l[2];switch(h){case"rgb":case"rgba":if(u=/^\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*(?:,\s*(\d*\.?\d+)\s*)?$/.exec(f))return a(u[4]),this.setRGB(Math.min(255,parseInt(u[1],10))/255,Math.min(255,parseInt(u[2],10))/255,Math.min(255,parseInt(u[3],10))/255,i);if(u=/^\s*(\d+)\%\s*,\s*(\d+)\%\s*,\s*(\d+)\%\s*(?:,\s*(\d*\.?\d+)\s*)?$/.exec(f))return a(u[4]),this.setRGB(Math.min(100,parseInt(u[1],10))/100,Math.min(100,parseInt(u[2],10))/100,Math.min(100,parseInt(u[3],10))/100,i);break;case"hsl":case"hsla":if(u=/^\s*(\d*\.?\d+)\s*,\s*(\d*\.?\d+)\%\s*,\s*(\d*\.?\d+)\%\s*(?:,\s*(\d*\.?\d+)\s*)?$/.exec(f))return a(u[4]),this.setHSL(parseFloat(u[1])/360,parseFloat(u[2])/100,parseFloat(u[3])/100,i);break;default:console.warn("THREE.Color: Unknown color model "+t)}}else if(l=/^\#([A-Fa-f\d]+)$/.exec(t)){const u=l[1],h=u.length;if(h===3)return this.setRGB(parseInt(u.charAt(0),16)/15,parseInt(u.charAt(1),16)/15,parseInt(u.charAt(2),16)/15,i);if(h===6)return this.setHex(parseInt(u,16),i);console.warn("THREE.Color: Invalid hex color "+t)}else if(t&&t.length>0)return this.setColorName(t,i);return this}setColorName(t,i=ai){const a=F_[t.toLowerCase()];return a!==void 0?this.setHex(a,i):console.warn("THREE.Color: Unknown color "+t),this}clone(){return new this.constructor(this.r,this.g,this.b)}copy(t){return this.r=t.r,this.g=t.g,this.b=t.b,this}copySRGBToLinear(t){return this.r=ln(t.r),this.g=ln(t.g),this.b=ln(t.b),this}copyLinearToSRGB(t){return this.r=vs(t.r),this.g=vs(t.g),this.b=vs(t.b),this}convertSRGBToLinear(){return this.copySRGBToLinear(this),this}convertLinearToSRGB(){return this.copyLinearToSRGB(this),this}getHex(t=ai){return Tt.fromWorkingColorSpace(br.copy(this),t),Math.round(_t(br.r*255,0,255))*65536+Math.round(_t(br.g*255,0,255))*256+Math.round(_t(br.b*255,0,255))}getHexString(t=ai){return("000000"+this.getHex(t).toString(16)).slice(-6)}getHSL(t,i=Tt.workingColorSpace){Tt.fromWorkingColorSpace(br.copy(this),i);const a=br.r,l=br.g,u=br.b,h=Math.max(a,l,u),f=Math.min(a,l,u);let m,p;const _=(f+h)/2;if(f===h)m=0,p=0;else{const y=h-f;switch(p=_<=.5?y/(h+f):y/(2-h-f),h){case a:m=(l-u)/y+(l<u?6:0);break;case l:m=(u-a)/y+2;break;case u:m=(a-l)/y+4;break}m/=6}return t.h=m,t.s=p,t.l=_,t}getRGB(t,i=Tt.workingColorSpace){return Tt.fromWorkingColorSpace(br.copy(this),i),t.r=br.r,t.g=br.g,t.b=br.b,t}getStyle(t=ai){Tt.fromWorkingColorSpace(br.copy(this),t);const i=br.r,a=br.g,l=br.b;return t!==ai?`color(${t} ${i.toFixed(3)} ${a.toFixed(3)} ${l.toFixed(3)})`:`rgb(${Math.round(i*255)},${Math.round(a*255)},${Math.round(l*255)})`}offsetHSL(t,i,a){return this.getHSL(On),this.setHSL(On.h+t,On.s+i,On.l+a)}add(t){return this.r+=t.r,this.g+=t.g,this.b+=t.b,this}addColors(t,i){return this.r=t.r+i.r,this.g=t.g+i.g,this.b=t.b+i.b,this}addScalar(t){return this.r+=t,this.g+=t,this.b+=t,this}sub(t){return this.r=Math.max(0,this.r-t.r),this.g=Math.max(0,this.g-t.g),this.b=Math.max(0,this.b-t.b),this}multiply(t){return this.r*=t.r,this.g*=t.g,this.b*=t.b,this}multiplyScalar(t){return this.r*=t,this.g*=t,this.b*=t,this}lerp(t,i){return this.r+=(t.r-this.r)*i,this.g+=(t.g-this.g)*i,this.b+=(t.b-this.b)*i,this}lerpColors(t,i,a){return this.r=t.r+(i.r-t.r)*a,this.g=t.g+(i.g-t.g)*a,this.b=t.b+(i.b-t.b)*a,this}lerpHSL(t,i){this.getHSL(On),t.getHSL(tc);const a=zd(On.h,tc.h,i),l=zd(On.s,tc.s,i),u=zd(On.l,tc.l,i);return this.setHSL(a,l,u),this}setFromVector3(t){return this.r=t.x,this.g=t.y,this.b=t.z,this}applyMatrix3(t){const i=this.r,a=this.g,l=this.b,u=t.elements;return this.r=u[0]*i+u[3]*a+u[6]*l,this.g=u[1]*i+u[4]*a+u[7]*l,this.b=u[2]*i+u[5]*a+u[8]*l,this}equals(t){return t.r===this.r&&t.g===this.g&&t.b===this.b}fromArray(t,i=0){return this.r=t[i],this.g=t[i+1],this.b=t[i+2],this}toArray(t=[],i=0){return t[i]=this.r,t[i+1]=this.g,t[i+2]=this.b,t}fromBufferAttribute(t,i){return this.r=t.getX(i),this.g=t.getY(i),this.b=t.getZ(i),this}toJSON(){return this.getHex()}*[Symbol.iterator](){yield this.r,yield this.g,yield this.b}}const br=new xt;xt.NAMES=F_;let vS=0;class No extends Ms{constructor(){super(),this.isMaterial=!0,Object.defineProperty(this,"id",{value:vS++}),this.uuid=Uo(),this.name="",this.type="Material",this.blending=gs,this.side=Hn,this.vertexColors=!1,this.opacity=1,this.transparent=!1,this.alphaHash=!1,this.blendSrc=gh,this.blendDst=vh,this.blendEquation=ga,this.blendSrcAlpha=null,this.blendDstAlpha=null,this.blendEquationAlpha=null,this.blendColor=new xt(0,0,0),this.blendAlpha=0,this.depthFunc=_s,this.depthTest=!0,this.depthWrite=!0,this.stencilWriteMask=255,this.stencilFunc=Sv,this.stencilRef=0,this.stencilFuncMask=255,this.stencilFail=ts,this.stencilZFail=ts,this.stencilZPass=ts,this.stencilWrite=!1,this.clippingPlanes=null,this.clipIntersection=!1,this.clipShadows=!1,this.shadowSide=null,this.colorWrite=!0,this.precision=null,this.polygonOffset=!1,this.polygonOffsetFactor=0,this.polygonOffsetUnits=0,this.dithering=!1,this.alphaToCoverage=!1,this.premultipliedAlpha=!1,this.forceSinglePass=!1,this.allowOverride=!0,this.visible=!0,this.toneMapped=!0,this.userData={},this.version=0,this._alphaTest=0}get alphaTest(){return this._alphaTest}set alphaTest(t){this._alphaTest>0!=t>0&&this.version++,this._alphaTest=t}onBeforeRender(){}onBeforeCompile(){}customProgramCacheKey(){return this.onBeforeCompile.toString()}setValues(t){if(t!==void 0)for(const i in t){const a=t[i];if(a===void 0){console.warn(`THREE.Material: parameter '${i}' has value of undefined.`);continue}const l=this[i];if(l===void 0){console.warn(`THREE.Material: '${i}' is not a property of THREE.${this.type}.`);continue}l&&l.isColor?l.set(a):l&&l.isVector3&&a&&a.isVector3?l.copy(a):this[i]=a}}toJSON(t){const i=t===void 0||typeof t=="string";i&&(t={textures:{},images:{}});const a={metadata:{version:4.6,type:"Material",generator:"Material.toJSON"}};a.uuid=this.uuid,a.type=this.type,this.name!==""&&(a.name=this.name),this.color&&this.color.isColor&&(a.color=this.color.getHex()),this.roughness!==void 0&&(a.roughness=this.roughness),this.metalness!==void 0&&(a.metalness=this.metalness),this.sheen!==void 0&&(a.sheen=this.sheen),this.sheenColor&&this.sheenColor.isColor&&(a.sheenColor=this.sheenColor.getHex()),this.sheenRoughness!==void 0&&(a.sheenRoughness=this.sheenRoughness),this.emissive&&this.emissive.isColor&&(a.emissive=this.emissive.getHex()),this.emissiveIntensity!==void 0&&this.emissiveIntensity!==1&&(a.emissiveIntensity=this.emissiveIntensity),this.specular&&this.specular.isColor&&(a.specular=this.specular.getHex()),this.specularIntensity!==void 0&&(a.specularIntensity=this.specularIntensity),this.specularColor&&this.specularColor.isColor&&(a.specularColor=this.specularColor.getHex()),this.shininess!==void 0&&(a.shininess=this.shininess),this.clearcoat!==void 0&&(a.clearcoat=this.clearcoat),this.clearcoatRoughness!==void 0&&(a.clearcoatRoughness=this.clearcoatRoughness),this.clearcoatMap&&this.clearcoatMap.isTexture&&(a.clearcoatMap=this.clearcoatMap.toJSON(t).uuid),this.clearcoatRoughnessMap&&this.clearcoatRoughnessMap.isTexture&&(a.clearcoatRoughnessMap=this.clearcoatRoughnessMap.toJSON(t).uuid),this.clearcoatNormalMap&&this.clearcoatNormalMap.isTexture&&(a.clearcoatNormalMap=this.clearcoatNormalMap.toJSON(t).uuid,a.clearcoatNormalScale=this.clearcoatNormalScale.toArray()),this.dispersion!==void 0&&(a.dispersion=this.dispersion),this.iridescence!==void 0&&(a.iridescence=this.iridescence),this.iridescenceIOR!==void 0&&(a.iridescenceIOR=this.iridescenceIOR),this.iridescenceThicknessRange!==void 0&&(a.iridescenceThicknessRange=this.iridescenceThicknessRange),this.iridescenceMap&&this.iridescenceMap.isTexture&&(a.iridescenceMap=this.iridescenceMap.toJSON(t).uuid),this.iridescenceThicknessMap&&this.iridescenceThicknessMap.isTexture&&(a.iridescenceThicknessMap=this.iridescenceThicknessMap.toJSON(t).uuid),this.anisotropy!==void 0&&(a.anisotropy=this.anisotropy),this.anisotropyRotation!==void 0&&(a.anisotropyRotation=this.anisotropyRotation),this.anisotropyMap&&this.anisotropyMap.isTexture&&(a.anisotropyMap=this.anisotropyMap.toJSON(t).uuid),this.map&&this.map.isTexture&&(a.map=this.map.toJSON(t).uuid),this.matcap&&this.matcap.isTexture&&(a.matcap=this.matcap.toJSON(t).uuid),this.alphaMap&&this.alphaMap.isTexture&&(a.alphaMap=this.alphaMap.toJSON(t).uuid),this.lightMap&&this.lightMap.isTexture&&(a.lightMap=this.lightMap.toJSON(t).uuid,a.lightMapIntensity=this.lightMapIntensity),this.aoMap&&this.aoMap.isTexture&&(a.aoMap=this.aoMap.toJSON(t).uuid,a.aoMapIntensity=this.aoMapIntensity),this.bumpMap&&this.bumpMap.isTexture&&(a.bumpMap=this.bumpMap.toJSON(t).uuid,a.bumpScale=this.bumpScale),this.normalMap&&this.normalMap.isTexture&&(a.normalMap=this.normalMap.toJSON(t).uuid,a.normalMapType=this.normalMapType,a.normalScale=this.normalScale.toArray()),this.displacementMap&&this.displacementMap.isTexture&&(a.displacementMap=this.displacementMap.toJSON(t).uuid,a.displacementScale=this.displacementScale,a.displacementBias=this.displacementBias),this.roughnessMap&&this.roughnessMap.isTexture&&(a.roughnessMap=this.roughnessMap.toJSON(t).uuid),this.metalnessMap&&this.metalnessMap.isTexture&&(a.metalnessMap=this.metalnessMap.toJSON(t).uuid),this.emissiveMap&&this.emissiveMap.isTexture&&(a.emissiveMap=this.emissiveMap.toJSON(t).uuid),this.specularMap&&this.specularMap.isTexture&&(a.specularMap=this.specularMap.toJSON(t).uuid),this.specularIntensityMap&&this.specularIntensityMap.isTexture&&(a.specularIntensityMap=this.specularIntensityMap.toJSON(t).uuid),this.specularColorMap&&this.specularColorMap.isTexture&&(a.specularColorMap=this.specularColorMap.toJSON(t).uuid),this.envMap&&this.envMap.isTexture&&(a.envMap=this.envMap.toJSON(t).uuid,this.combine!==void 0&&(a.combine=this.combine)),this.envMapRotation!==void 0&&(a.envMapRotation=this.envMapRotation.toArray()),this.envMapIntensity!==void 0&&(a.envMapIntensity=this.envMapIntensity),this.reflectivity!==void 0&&(a.reflectivity=this.reflectivity),this.refractionRatio!==void 0&&(a.refractionRatio=this.refractionRatio),this.gradientMap&&this.gradientMap.isTexture&&(a.gradientMap=this.gradientMap.toJSON(t).uuid),this.transmission!==void 0&&(a.transmission=this.transmission),this.transmissionMap&&this.transmissionMap.isTexture&&(a.transmissionMap=this.transmissionMap.toJSON(t).uuid),this.thickness!==void 0&&(a.thickness=this.thickness),this.thicknessMap&&this.thicknessMap.isTexture&&(a.thicknessMap=this.thicknessMap.toJSON(t).uuid),this.attenuationDistance!==void 0&&this.attenuationDistance!==1/0&&(a.attenuationDistance=this.attenuationDistance),this.attenuationColor!==void 0&&(a.attenuationColor=this.attenuationColor.getHex()),this.size!==void 0&&(a.size=this.size),this.shadowSide!==null&&(a.shadowSide=this.shadowSide),this.sizeAttenuation!==void 0&&(a.sizeAttenuation=this.sizeAttenuation),this.blending!==gs&&(a.blending=this.blending),this.side!==Hn&&(a.side=this.side),this.vertexColors===!0&&(a.vertexColors=!0),this.opacity<1&&(a.opacity=this.opacity),this.transparent===!0&&(a.transparent=!0),this.blendSrc!==gh&&(a.blendSrc=this.blendSrc),this.blendDst!==vh&&(a.blendDst=this.blendDst),this.blendEquation!==ga&&(a.blendEquation=this.blendEquation),this.blendSrcAlpha!==null&&(a.blendSrcAlpha=this.blendSrcAlpha),this.blendDstAlpha!==null&&(a.blendDstAlpha=this.blendDstAlpha),this.blendEquationAlpha!==null&&(a.blendEquationAlpha=this.blendEquationAlpha),this.blendColor&&this.blendColor.isColor&&(a.blendColor=this.blendColor.getHex()),this.blendAlpha!==0&&(a.blendAlpha=this.blendAlpha),this.depthFunc!==_s&&(a.depthFunc=this.depthFunc),this.depthTest===!1&&(a.depthTest=this.depthTest),this.depthWrite===!1&&(a.depthWrite=this.depthWrite),this.colorWrite===!1&&(a.colorWrite=this.colorWrite),this.stencilWriteMask!==255&&(a.stencilWriteMask=this.stencilWriteMask),this.stencilFunc!==Sv&&(a.stencilFunc=this.stencilFunc),this.stencilRef!==0&&(a.stencilRef=this.stencilRef),this.stencilFuncMask!==255&&(a.stencilFuncMask=this.stencilFuncMask),this.stencilFail!==ts&&(a.stencilFail=this.stencilFail),this.stencilZFail!==ts&&(a.stencilZFail=this.stencilZFail),this.stencilZPass!==ts&&(a.stencilZPass=this.stencilZPass),this.stencilWrite===!0&&(a.stencilWrite=this.stencilWrite),this.rotation!==void 0&&this.rotation!==0&&(a.rotation=this.rotation),this.polygonOffset===!0&&(a.polygonOffset=!0),this.polygonOffsetFactor!==0&&(a.polygonOffsetFactor=this.polygonOffsetFactor),this.polygonOffsetUnits!==0&&(a.polygonOffsetUnits=this.polygonOffsetUnits),this.linewidth!==void 0&&this.linewidth!==1&&(a.linewidth=this.linewidth),this.dashSize!==void 0&&(a.dashSize=this.dashSize),this.gapSize!==void 0&&(a.gapSize=this.gapSize),this.scale!==void 0&&(a.scale=this.scale),this.dithering===!0&&(a.dithering=!0),this.alphaTest>0&&(a.alphaTest=this.alphaTest),this.alphaHash===!0&&(a.alphaHash=!0),this.alphaToCoverage===!0&&(a.alphaToCoverage=!0),this.premultipliedAlpha===!0&&(a.premultipliedAlpha=!0),this.forceSinglePass===!0&&(a.forceSinglePass=!0),this.wireframe===!0&&(a.wireframe=!0),this.wireframeLinewidth>1&&(a.wireframeLinewidth=this.wireframeLinewidth),this.wireframeLinecap!=="round"&&(a.wireframeLinecap=this.wireframeLinecap),this.wireframeLinejoin!=="round"&&(a.wireframeLinejoin=this.wireframeLinejoin),this.flatShading===!0&&(a.flatShading=!0),this.visible===!1&&(a.visible=!1),this.toneMapped===!1&&(a.toneMapped=!1),this.fog===!1&&(a.fog=!1),Object.keys(this.userData).length>0&&(a.userData=this.userData);function l(u){const h=[];for(const f in u){const m=u[f];delete m.metadata,h.push(m)}return h}if(i){const u=l(t.textures),h=l(t.images);u.length>0&&(a.textures=u),h.length>0&&(a.images=h)}return a}clone(){return new this.constructor().copy(this)}copy(t){this.name=t.name,this.blending=t.blending,this.side=t.side,this.vertexColors=t.vertexColors,this.opacity=t.opacity,this.transparent=t.transparent,this.blendSrc=t.blendSrc,this.blendDst=t.blendDst,this.blendEquation=t.blendEquation,this.blendSrcAlpha=t.blendSrcAlpha,this.blendDstAlpha=t.blendDstAlpha,this.blendEquationAlpha=t.blendEquationAlpha,this.blendColor.copy(t.blendColor),this.blendAlpha=t.blendAlpha,this.depthFunc=t.depthFunc,this.depthTest=t.depthTest,this.depthWrite=t.depthWrite,this.stencilWriteMask=t.stencilWriteMask,this.stencilFunc=t.stencilFunc,this.stencilRef=t.stencilRef,this.stencilFuncMask=t.stencilFuncMask,this.stencilFail=t.stencilFail,this.stencilZFail=t.stencilZFail,this.stencilZPass=t.stencilZPass,this.stencilWrite=t.stencilWrite;const i=t.clippingPlanes;let a=null;if(i!==null){const l=i.length;a=new Array(l);for(let u=0;u!==l;++u)a[u]=i[u].clone()}return this.clippingPlanes=a,this.clipIntersection=t.clipIntersection,this.clipShadows=t.clipShadows,this.shadowSide=t.shadowSide,this.colorWrite=t.colorWrite,this.precision=t.precision,this.polygonOffset=t.polygonOffset,this.polygonOffsetFactor=t.polygonOffsetFactor,this.polygonOffsetUnits=t.polygonOffsetUnits,this.dithering=t.dithering,this.alphaTest=t.alphaTest,this.alphaHash=t.alphaHash,this.alphaToCoverage=t.alphaToCoverage,this.premultipliedAlpha=t.premultipliedAlpha,this.forceSinglePass=t.forceSinglePass,this.visible=t.visible,this.toneMapped=t.toneMapped,this.userData=JSON.parse(JSON.stringify(t.userData)),this}dispose(){this.dispatchEvent({type:"dispose"})}set needsUpdate(t){t===!0&&this.version++}}class pf extends No{constructor(t){super(),this.isMeshBasicMaterial=!0,this.type="MeshBasicMaterial",this.color=new xt(16777215),this.map=null,this.lightMap=null,this.lightMapIntensity=1,this.aoMap=null,this.aoMapIntensity=1,this.specularMap=null,this.alphaMap=null,this.envMap=null,this.envMapRotation=new Li,this.combine=b_,this.reflectivity=1,this.refractionRatio=.98,this.wireframe=!1,this.wireframeLinewidth=1,this.wireframeLinecap="round",this.wireframeLinejoin="round",this.fog=!0,this.setValues(t)}copy(t){return super.copy(t),this.color.copy(t.color),this.map=t.map,this.lightMap=t.lightMap,this.lightMapIntensity=t.lightMapIntensity,this.aoMap=t.aoMap,this.aoMapIntensity=t.aoMapIntensity,this.specularMap=t.specularMap,this.alphaMap=t.alphaMap,this.envMap=t.envMap,this.envMapRotation.copy(t.envMapRotation),this.combine=t.combine,this.reflectivity=t.reflectivity,this.refractionRatio=t.refractionRatio,this.wireframe=t.wireframe,this.wireframeLinewidth=t.wireframeLinewidth,this.wireframeLinecap=t.wireframeLinecap,this.wireframeLinejoin=t.wireframeLinejoin,this.fog=t.fog,this}}const ir=new $,rc=new St;let _S=0;class Ai{constructor(t,i,a=!1){if(Array.isArray(t))throw new TypeError("THREE.BufferAttribute: array should be a Typed Array.");this.isBufferAttribute=!0,Object.defineProperty(this,"id",{value:_S++}),this.name="",this.array=t,this.itemSize=i,this.count=t!==void 0?t.length/i:0,this.normalized=a,this.usage=bv,this.updateRanges=[],this.gpuType=sn,this.version=0}onUploadCallback(){}set needsUpdate(t){t===!0&&this.version++}setUsage(t){return this.usage=t,this}addUpdateRange(t,i){this.updateRanges.push({start:t,count:i})}clearUpdateRanges(){this.updateRanges.length=0}copy(t){return this.name=t.name,this.array=new t.array.constructor(t.array),this.itemSize=t.itemSize,this.count=t.count,this.normalized=t.normalized,this.usage=t.usage,this.gpuType=t.gpuType,this}copyAt(t,i,a){t*=this.itemSize,a*=i.itemSize;for(let l=0,u=this.itemSize;l<u;l++)this.array[t+l]=i.array[a+l];return this}copyArray(t){return this.array.set(t),this}applyMatrix3(t){if(this.itemSize===2)for(let i=0,a=this.count;i<a;i++)rc.fromBufferAttribute(this,i),rc.applyMatrix3(t),this.setXY(i,rc.x,rc.y);else if(this.itemSize===3)for(let i=0,a=this.count;i<a;i++)ir.fromBufferAttribute(this,i),ir.applyMatrix3(t),this.setXYZ(i,ir.x,ir.y,ir.z);return this}applyMatrix4(t){for(let i=0,a=this.count;i<a;i++)ir.fromBufferAttribute(this,i),ir.applyMatrix4(t),this.setXYZ(i,ir.x,ir.y,ir.z);return this}applyNormalMatrix(t){for(let i=0,a=this.count;i<a;i++)ir.fromBufferAttribute(this,i),ir.applyNormalMatrix(t),this.setXYZ(i,ir.x,ir.y,ir.z);return this}transformDirection(t){for(let i=0,a=this.count;i<a;i++)ir.fromBufferAttribute(this,i),ir.transformDirection(t),this.setXYZ(i,ir.x,ir.y,ir.z);return this}set(t,i=0){return this.array.set(t,i),this}getComponent(t,i){let a=this.array[t*this.itemSize+i];return this.normalized&&(a=xo(a,this.array)),a}setComponent(t,i,a){return this.normalized&&(a=Fr(a,this.array)),this.array[t*this.itemSize+i]=a,this}getX(t){let i=this.array[t*this.itemSize];return this.normalized&&(i=xo(i,this.array)),i}setX(t,i){return this.normalized&&(i=Fr(i,this.array)),this.array[t*this.itemSize]=i,this}getY(t){let i=this.array[t*this.itemSize+1];return this.normalized&&(i=xo(i,this.array)),i}setY(t,i){return this.normalized&&(i=Fr(i,this.array)),this.array[t*this.itemSize+1]=i,this}getZ(t){let i=this.array[t*this.itemSize+2];return this.normalized&&(i=xo(i,this.array)),i}setZ(t,i){return this.normalized&&(i=Fr(i,this.array)),this.array[t*this.itemSize+2]=i,this}getW(t){let i=this.array[t*this.itemSize+3];return this.normalized&&(i=xo(i,this.array)),i}setW(t,i){return this.normalized&&(i=Fr(i,this.array)),this.array[t*this.itemSize+3]=i,this}setXY(t,i,a){return t*=this.itemSize,this.normalized&&(i=Fr(i,this.array),a=Fr(a,this.array)),this.array[t+0]=i,this.array[t+1]=a,this}setXYZ(t,i,a,l){return t*=this.itemSize,this.normalized&&(i=Fr(i,this.array),a=Fr(a,this.array),l=Fr(l,this.array)),this.array[t+0]=i,this.array[t+1]=a,this.array[t+2]=l,this}setXYZW(t,i,a,l,u){return t*=this.itemSize,this.normalized&&(i=Fr(i,this.array),a=Fr(a,this.array),l=Fr(l,this.array),u=Fr(u,this.array)),this.array[t+0]=i,this.array[t+1]=a,this.array[t+2]=l,this.array[t+3]=u,this}onUpload(t){return this.onUploadCallback=t,this}clone(){return new this.constructor(this.array,this.itemSize).copy(this)}toJSON(){const t={itemSize:this.itemSize,type:this.array.constructor.name,array:Array.from(this.array),normalized:this.normalized};return this.name!==""&&(t.name=this.name),this.usage!==bv&&(t.usage=this.usage),t}}class z_ extends Ai{constructor(t,i,a){super(new Uint16Array(t),i,a)}}class B_ extends Ai{constructor(t,i,a){super(new Uint32Array(t),i,a)}}class Er extends Ai{constructor(t,i,a){super(new Float32Array(t),i,a)}}let yS=0;const ni=new Yt,ih=new Mr,ds=new $,Qr=new Io,Eo=new Io,cr=new $;class Ui extends Ms{constructor(){super(),this.isBufferGeometry=!0,Object.defineProperty(this,"id",{value:yS++}),this.uuid=Uo(),this.name="",this.type="BufferGeometry",this.index=null,this.indirect=null,this.attributes={},this.morphAttributes={},this.morphTargetsRelative=!1,this.groups=[],this.boundingBox=null,this.boundingSphere=null,this.drawRange={start:0,count:1/0},this.userData={}}getIndex(){return this.index}setIndex(t){return Array.isArray(t)?this.index=new(N_(t)?B_:z_)(t,1):this.index=t,this}setIndirect(t){return this.indirect=t,this}getIndirect(){return this.indirect}getAttribute(t){return this.attributes[t]}setAttribute(t,i){return this.attributes[t]=i,this}deleteAttribute(t){return delete this.attributes[t],this}hasAttribute(t){return this.attributes[t]!==void 0}addGroup(t,i,a=0){this.groups.push({start:t,count:i,materialIndex:a})}clearGroups(){this.groups=[]}setDrawRange(t,i){this.drawRange.start=t,this.drawRange.count=i}applyMatrix4(t){const i=this.attributes.position;i!==void 0&&(i.applyMatrix4(t),i.needsUpdate=!0);const a=this.attributes.normal;if(a!==void 0){const u=new at().getNormalMatrix(t);a.applyNormalMatrix(u),a.needsUpdate=!0}const l=this.attributes.tangent;return l!==void 0&&(l.transformDirection(t),l.needsUpdate=!0),this.boundingBox!==null&&this.computeBoundingBox(),this.boundingSphere!==null&&this.computeBoundingSphere(),this}applyQuaternion(t){return ni.makeRotationFromQuaternion(t),this.applyMatrix4(ni),this}rotateX(t){return ni.makeRotationX(t),this.applyMatrix4(ni),this}rotateY(t){return ni.makeRotationY(t),this.applyMatrix4(ni),this}rotateZ(t){return ni.makeRotationZ(t),this.applyMatrix4(ni),this}translate(t,i,a){return ni.makeTranslation(t,i,a),this.applyMatrix4(ni),this}scale(t,i,a){return ni.makeScale(t,i,a),this.applyMatrix4(ni),this}lookAt(t){return ih.lookAt(t),ih.updateMatrix(),this.applyMatrix4(ih.matrix),this}center(){return this.computeBoundingBox(),this.boundingBox.getCenter(ds).negate(),this.translate(ds.x,ds.y,ds.z),this}setFromPoints(t){const i=this.getAttribute("position");if(i===void 0){const a=[];for(let l=0,u=t.length;l<u;l++){const h=t[l];a.push(h.x,h.y,h.z||0)}this.setAttribute("position",new Er(a,3))}else{const a=Math.min(t.length,i.count);for(let l=0;l<a;l++){const u=t[l];i.setXYZ(l,u.x,u.y,u.z||0)}t.length>i.count&&console.warn("THREE.BufferGeometry: Buffer size too small for points data. Use .dispose() and create a new geometry."),i.needsUpdate=!0}return this}computeBoundingBox(){this.boundingBox===null&&(this.boundingBox=new Io);const t=this.attributes.position,i=this.morphAttributes.position;if(t&&t.isGLBufferAttribute){console.error("THREE.BufferGeometry.computeBoundingBox(): GLBufferAttribute requires a manual bounding box.",this),this.boundingBox.set(new $(-1/0,-1/0,-1/0),new $(1/0,1/0,1/0));return}if(t!==void 0){if(this.boundingBox.setFromBufferAttribute(t),i)for(let a=0,l=i.length;a<l;a++){const u=i[a];Qr.setFromBufferAttribute(u),this.morphTargetsRelative?(cr.addVectors(this.boundingBox.min,Qr.min),this.boundingBox.expandByPoint(cr),cr.addVectors(this.boundingBox.max,Qr.max),this.boundingBox.expandByPoint(cr)):(this.boundingBox.expandByPoint(Qr.min),this.boundingBox.expandByPoint(Qr.max))}}else this.boundingBox.makeEmpty();(isNaN(this.boundingBox.min.x)||isNaN(this.boundingBox.min.y)||isNaN(this.boundingBox.min.z))&&console.error('THREE.BufferGeometry.computeBoundingBox(): Computed min/max have NaN values. The "position" attribute is likely to have NaN values.',this)}computeBoundingSphere(){this.boundingSphere===null&&(this.boundingSphere=new ff);const t=this.attributes.position,i=this.morphAttributes.position;if(t&&t.isGLBufferAttribute){console.error("THREE.BufferGeometry.computeBoundingSphere(): GLBufferAttribute requires a manual bounding sphere.",this),this.boundingSphere.set(new $,1/0);return}if(t){const a=this.boundingSphere.center;if(Qr.setFromBufferAttribute(t),i)for(let u=0,h=i.length;u<h;u++){const f=i[u];Eo.setFromBufferAttribute(f),this.morphTargetsRelative?(cr.addVectors(Qr.min,Eo.min),Qr.expandByPoint(cr),cr.addVectors(Qr.max,Eo.max),Qr.expandByPoint(cr)):(Qr.expandByPoint(Eo.min),Qr.expandByPoint(Eo.max))}Qr.getCenter(a);let l=0;for(let u=0,h=t.count;u<h;u++)cr.fromBufferAttribute(t,u),l=Math.max(l,a.distanceToSquared(cr));if(i)for(let u=0,h=i.length;u<h;u++){const f=i[u],m=this.morphTargetsRelative;for(let p=0,_=f.count;p<_;p++)cr.fromBufferAttribute(f,p),m&&(ds.fromBufferAttribute(t,p),cr.add(ds)),l=Math.max(l,a.distanceToSquared(cr))}this.boundingSphere.radius=Math.sqrt(l),isNaN(this.boundingSphere.radius)&&console.error('THREE.BufferGeometry.computeBoundingSphere(): Computed radius is NaN. The "position" attribute is likely to have NaN values.',this)}}computeTangents(){const t=this.index,i=this.attributes;if(t===null||i.position===void 0||i.normal===void 0||i.uv===void 0){console.error("THREE.BufferGeometry: .computeTangents() failed. Missing required attributes (index, position, normal or uv)");return}const a=i.position,l=i.normal,u=i.uv;this.hasAttribute("tangent")===!1&&this.setAttribute("tangent",new Ai(new Float32Array(4*a.count),4));const h=this.getAttribute("tangent"),f=[],m=[];for(let H=0;H<a.count;H++)f[H]=new $,m[H]=new $;const p=new $,_=new $,y=new $,x=new St,b=new St,R=new St,A=new $,S=new $;function v(H,P,w){p.fromBufferAttribute(a,H),_.fromBufferAttribute(a,P),y.fromBufferAttribute(a,w),x.fromBufferAttribute(u,H),b.fromBufferAttribute(u,P),R.fromBufferAttribute(u,w),_.sub(p),y.sub(p),b.sub(x),R.sub(x);const F=1/(b.x*R.y-R.x*b.y);isFinite(F)&&(A.copy(_).multiplyScalar(R.y).addScaledVector(y,-b.y).multiplyScalar(F),S.copy(y).multiplyScalar(b.x).addScaledVector(_,-R.x).multiplyScalar(F),f[H].add(A),f[P].add(A),f[w].add(A),m[H].add(S),m[P].add(S),m[w].add(S))}let D=this.groups;D.length===0&&(D=[{start:0,count:t.count}]);for(let H=0,P=D.length;H<P;++H){const w=D[H],F=w.start,te=w.count;for(let se=F,ce=F+te;se<ce;se+=3)v(t.getX(se+0),t.getX(se+1),t.getX(se+2))}const L=new $,C=new $,G=new $,k=new $;function I(H){G.fromBufferAttribute(l,H),k.copy(G);const P=f[H];L.copy(P),L.sub(G.multiplyScalar(G.dot(P))).normalize(),C.crossVectors(k,P);const w=C.dot(m[H])<0?-1:1;h.setXYZW(H,L.x,L.y,L.z,w)}for(let H=0,P=D.length;H<P;++H){const w=D[H],F=w.start,te=w.count;for(let se=F,ce=F+te;se<ce;se+=3)I(t.getX(se+0)),I(t.getX(se+1)),I(t.getX(se+2))}}computeVertexNormals(){const t=this.index,i=this.getAttribute("position");if(i!==void 0){let a=this.getAttribute("normal");if(a===void 0)a=new Ai(new Float32Array(i.count*3),3),this.setAttribute("normal",a);else for(let x=0,b=a.count;x<b;x++)a.setXYZ(x,0,0,0);const l=new $,u=new $,h=new $,f=new $,m=new $,p=new $,_=new $,y=new $;if(t)for(let x=0,b=t.count;x<b;x+=3){const R=t.getX(x+0),A=t.getX(x+1),S=t.getX(x+2);l.fromBufferAttribute(i,R),u.fromBufferAttribute(i,A),h.fromBufferAttribute(i,S),_.subVectors(h,u),y.subVectors(l,u),_.cross(y),f.fromBufferAttribute(a,R),m.fromBufferAttribute(a,A),p.fromBufferAttribute(a,S),f.add(_),m.add(_),p.add(_),a.setXYZ(R,f.x,f.y,f.z),a.setXYZ(A,m.x,m.y,m.z),a.setXYZ(S,p.x,p.y,p.z)}else for(let x=0,b=i.count;x<b;x+=3)l.fromBufferAttribute(i,x+0),u.fromBufferAttribute(i,x+1),h.fromBufferAttribute(i,x+2),_.subVectors(h,u),y.subVectors(l,u),_.cross(y),a.setXYZ(x+0,_.x,_.y,_.z),a.setXYZ(x+1,_.x,_.y,_.z),a.setXYZ(x+2,_.x,_.y,_.z);this.normalizeNormals(),a.needsUpdate=!0}}normalizeNormals(){const t=this.attributes.normal;for(let i=0,a=t.count;i<a;i++)cr.fromBufferAttribute(t,i),cr.normalize(),t.setXYZ(i,cr.x,cr.y,cr.z)}toNonIndexed(){function t(f,m){const p=f.array,_=f.itemSize,y=f.normalized,x=new p.constructor(m.length*_);let b=0,R=0;for(let A=0,S=m.length;A<S;A++){f.isInterleavedBufferAttribute?b=m[A]*f.data.stride+f.offset:b=m[A]*_;for(let v=0;v<_;v++)x[R++]=p[b++]}return new Ai(x,_,y)}if(this.index===null)return console.warn("THREE.BufferGeometry.toNonIndexed(): BufferGeometry is already non-indexed."),this;const i=new Ui,a=this.index.array,l=this.attributes;for(const f in l){const m=l[f],p=t(m,a);i.setAttribute(f,p)}const u=this.morphAttributes;for(const f in u){const m=[],p=u[f];for(let _=0,y=p.length;_<y;_++){const x=p[_],b=t(x,a);m.push(b)}i.morphAttributes[f]=m}i.morphTargetsRelative=this.morphTargetsRelative;const h=this.groups;for(let f=0,m=h.length;f<m;f++){const p=h[f];i.addGroup(p.start,p.count,p.materialIndex)}return i}toJSON(){const t={metadata:{version:4.6,type:"BufferGeometry",generator:"BufferGeometry.toJSON"}};if(t.uuid=this.uuid,t.type=this.type,this.name!==""&&(t.name=this.name),Object.keys(this.userData).length>0&&(t.userData=this.userData),this.parameters!==void 0){const m=this.parameters;for(const p in m)m[p]!==void 0&&(t[p]=m[p]);return t}t.data={attributes:{}};const i=this.index;i!==null&&(t.data.index={type:i.array.constructor.name,array:Array.prototype.slice.call(i.array)});const a=this.attributes;for(const m in a){const p=a[m];t.data.attributes[m]=p.toJSON(t.data)}const l={};let u=!1;for(const m in this.morphAttributes){const p=this.morphAttributes[m],_=[];for(let y=0,x=p.length;y<x;y++){const b=p[y];_.push(b.toJSON(t.data))}_.length>0&&(l[m]=_,u=!0)}u&&(t.data.morphAttributes=l,t.data.morphTargetsRelative=this.morphTargetsRelative);const h=this.groups;h.length>0&&(t.data.groups=JSON.parse(JSON.stringify(h)));const f=this.boundingSphere;return f!==null&&(t.data.boundingSphere={center:f.center.toArray(),radius:f.radius}),t}clone(){return new this.constructor().copy(this)}copy(t){this.index=null,this.attributes={},this.morphAttributes={},this.groups=[],this.boundingBox=null,this.boundingSphere=null;const i={};this.name=t.name;const a=t.index;a!==null&&this.setIndex(a.clone());const l=t.attributes;for(const p in l){const _=l[p];this.setAttribute(p,_.clone(i))}const u=t.morphAttributes;for(const p in u){const _=[],y=u[p];for(let x=0,b=y.length;x<b;x++)_.push(y[x].clone(i));this.morphAttributes[p]=_}this.morphTargetsRelative=t.morphTargetsRelative;const h=t.groups;for(let p=0,_=h.length;p<_;p++){const y=h[p];this.addGroup(y.start,y.count,y.materialIndex)}const f=t.boundingBox;f!==null&&(this.boundingBox=f.clone());const m=t.boundingSphere;return m!==null&&(this.boundingSphere=m.clone()),this.drawRange.start=t.drawRange.start,this.drawRange.count=t.drawRange.count,this.userData=t.userData,this}dispose(){this.dispatchEvent({type:"dispose"})}}const Ov=new Yt,ua=new uS,ic=new ff,kv=new $,nc=new $,ac=new $,sc=new $,nh=new $,oc=new $,Fv=new $,lc=new $;class si extends Mr{constructor(t=new Ui,i=new pf){super(),this.isMesh=!0,this.type="Mesh",this.geometry=t,this.material=i,this.morphTargetDictionary=void 0,this.morphTargetInfluences=void 0,this.updateMorphTargets()}copy(t,i){return super.copy(t,i),t.morphTargetInfluences!==void 0&&(this.morphTargetInfluences=t.morphTargetInfluences.slice()),t.morphTargetDictionary!==void 0&&(this.morphTargetDictionary=Object.assign({},t.morphTargetDictionary)),this.material=Array.isArray(t.material)?t.material.slice():t.material,this.geometry=t.geometry,this}updateMorphTargets(){const t=this.geometry.morphAttributes,i=Object.keys(t);if(i.length>0){const a=t[i[0]];if(a!==void 0){this.morphTargetInfluences=[],this.morphTargetDictionary={};for(let l=0,u=a.length;l<u;l++){const h=a[l].name||String(l);this.morphTargetInfluences.push(0),this.morphTargetDictionary[h]=l}}}}getVertexPosition(t,i){const a=this.geometry,l=a.attributes.position,u=a.morphAttributes.position,h=a.morphTargetsRelative;i.fromBufferAttribute(l,t);const f=this.morphTargetInfluences;if(u&&f){oc.set(0,0,0);for(let m=0,p=u.length;m<p;m++){const _=f[m],y=u[m];_!==0&&(nh.fromBufferAttribute(y,t),h?oc.addScaledVector(nh,_):oc.addScaledVector(nh.sub(i),_))}i.add(oc)}return i}raycast(t,i){const a=this.geometry,l=this.material,u=this.matrixWorld;l!==void 0&&(a.boundingSphere===null&&a.computeBoundingSphere(),ic.copy(a.boundingSphere),ic.applyMatrix4(u),ua.copy(t.ray).recast(t.near),!(ic.containsPoint(ua.origin)===!1&&(ua.intersectSphere(ic,kv)===null||ua.origin.distanceToSquared(kv)>(t.far-t.near)**2))&&(Ov.copy(u).invert(),ua.copy(t.ray).applyMatrix4(Ov),!(a.boundingBox!==null&&ua.intersectsBox(a.boundingBox)===!1)&&this._computeIntersections(t,i,ua)))}_computeIntersections(t,i,a){let l;const u=this.geometry,h=this.material,f=u.index,m=u.attributes.position,p=u.attributes.uv,_=u.attributes.uv1,y=u.attributes.normal,x=u.groups,b=u.drawRange;if(f!==null)if(Array.isArray(h))for(let R=0,A=x.length;R<A;R++){const S=x[R],v=h[S.materialIndex],D=Math.max(S.start,b.start),L=Math.min(f.count,Math.min(S.start+S.count,b.start+b.count));for(let C=D,G=L;C<G;C+=3){const k=f.getX(C),I=f.getX(C+1),H=f.getX(C+2);l=cc(this,v,t,a,p,_,y,k,I,H),l&&(l.faceIndex=Math.floor(C/3),l.face.materialIndex=S.materialIndex,i.push(l))}}else{const R=Math.max(0,b.start),A=Math.min(f.count,b.start+b.count);for(let S=R,v=A;S<v;S+=3){const D=f.getX(S),L=f.getX(S+1),C=f.getX(S+2);l=cc(this,h,t,a,p,_,y,D,L,C),l&&(l.faceIndex=Math.floor(S/3),i.push(l))}}else if(m!==void 0)if(Array.isArray(h))for(let R=0,A=x.length;R<A;R++){const S=x[R],v=h[S.materialIndex],D=Math.max(S.start,b.start),L=Math.min(m.count,Math.min(S.start+S.count,b.start+b.count));for(let C=D,G=L;C<G;C+=3){const k=C,I=C+1,H=C+2;l=cc(this,v,t,a,p,_,y,k,I,H),l&&(l.faceIndex=Math.floor(C/3),l.face.materialIndex=S.materialIndex,i.push(l))}}else{const R=Math.max(0,b.start),A=Math.min(m.count,b.start+b.count);for(let S=R,v=A;S<v;S+=3){const D=S,L=S+1,C=S+2;l=cc(this,h,t,a,p,_,y,D,L,C),l&&(l.faceIndex=Math.floor(S/3),i.push(l))}}}}function xS(o,t,i,a,l,u,h,f){let m;if(t.side===zr?m=a.intersectTriangle(h,u,l,!0,f):m=a.intersectTriangle(l,u,h,t.side===Hn,f),m===null)return null;lc.copy(f),lc.applyMatrix4(o.matrixWorld);const p=i.ray.origin.distanceTo(lc);return p<i.near||p>i.far?null:{distance:p,point:lc.clone(),object:o}}function cc(o,t,i,a,l,u,h,f,m,p){o.getVertexPosition(f,nc),o.getVertexPosition(m,ac),o.getVertexPosition(p,sc);const _=xS(o,t,i,a,nc,ac,sc,Fv);if(_){const y=new $;yi.getBarycoord(Fv,nc,ac,sc,y),l&&(_.uv=yi.getInterpolatedAttribute(l,f,m,p,y,new St)),u&&(_.uv1=yi.getInterpolatedAttribute(u,f,m,p,y,new St)),h&&(_.normal=yi.getInterpolatedAttribute(h,f,m,p,y,new $),_.normal.dot(a.direction)>0&&_.normal.multiplyScalar(-1));const x={a:f,b:m,c:p,normal:new $,materialIndex:0};yi.getNormal(nc,ac,sc,x.normal),_.face=x,_.barycoord=y}return _}class Oo extends Ui{constructor(t=1,i=1,a=1,l=1,u=1,h=1){super(),this.type="BoxGeometry",this.parameters={width:t,height:i,depth:a,widthSegments:l,heightSegments:u,depthSegments:h};const f=this;l=Math.floor(l),u=Math.floor(u),h=Math.floor(h);const m=[],p=[],_=[],y=[];let x=0,b=0;R("z","y","x",-1,-1,a,i,t,h,u,0),R("z","y","x",1,-1,a,i,-t,h,u,1),R("x","z","y",1,1,t,a,i,l,h,2),R("x","z","y",1,-1,t,a,-i,l,h,3),R("x","y","z",1,-1,t,i,a,l,u,4),R("x","y","z",-1,-1,t,i,-a,l,u,5),this.setIndex(m),this.setAttribute("position",new Er(p,3)),this.setAttribute("normal",new Er(_,3)),this.setAttribute("uv",new Er(y,2));function R(A,S,v,D,L,C,G,k,I,H,P){const w=C/I,F=G/H,te=C/2,se=G/2,ce=k/2,ve=I+1,N=H+1;let K=0,q=0;const ge=new $;for(let we=0;we<N;we++){const O=we*F-se;for(let ie=0;ie<ve;ie++){const xe=ie*w-te;ge[A]=xe*D,ge[S]=O*L,ge[v]=ce,p.push(ge.x,ge.y,ge.z),ge[A]=0,ge[S]=0,ge[v]=k>0?1:-1,_.push(ge.x,ge.y,ge.z),y.push(ie/I),y.push(1-we/H),K+=1}}for(let we=0;we<H;we++)for(let O=0;O<I;O++){const ie=x+O+ve*we,xe=x+O+ve*(we+1),Q=x+(O+1)+ve*(we+1),ue=x+(O+1)+ve*we;m.push(ie,xe,ue),m.push(xe,Q,ue),q+=6}f.addGroup(b,q,P),b+=q,x+=K}}copy(t){return super.copy(t),this.parameters=Object.assign({},t.parameters),this}static fromJSON(t){return new Oo(t.width,t.height,t.depth,t.widthSegments,t.heightSegments,t.depthSegments)}}function bs(o){const t={};for(const i in o){t[i]={};for(const a in o[i]){const l=o[i][a];l&&(l.isColor||l.isMatrix3||l.isMatrix4||l.isVector2||l.isVector3||l.isVector4||l.isTexture||l.isQuaternion)?l.isRenderTargetTexture?(console.warn("UniformsUtils: Textures of render targets cannot be cloned via cloneUniforms() or mergeUniforms()."),t[i][a]=null):t[i][a]=l.clone():Array.isArray(l)?t[i][a]=l.slice():t[i][a]=l}}return t}function Cr(o){const t={};for(let i=0;i<o.length;i++){const a=bs(o[i]);for(const l in a)t[l]=a[l]}return t}function SS(o){const t=[];for(let i=0;i<o.length;i++)t.push(o[i].clone());return t}function H_(o){const t=o.getRenderTarget();return t===null?o.outputColorSpace:t.isXRRenderTarget===!0?t.texture.colorSpace:Tt.workingColorSpace}const bS={clone:bs,merge:Cr};var MS=`void main() {
	gl_Position = projectionMatrix * modelViewMatrix * vec4( position, 1.0 );
}`,ES=`void main() {
	gl_FragColor = vec4( 1.0, 0.0, 0.0, 1.0 );
}`;class Vn extends No{constructor(t){super(),this.isShaderMaterial=!0,this.type="ShaderMaterial",this.defines={},this.uniforms={},this.uniformsGroups=[],this.vertexShader=MS,this.fragmentShader=ES,this.linewidth=1,this.wireframe=!1,this.wireframeLinewidth=1,this.fog=!1,this.lights=!1,this.clipping=!1,this.forceSinglePass=!0,this.extensions={clipCullDistance:!1,multiDraw:!1},this.defaultAttributeValues={color:[1,1,1],uv:[0,0],uv1:[0,0]},this.index0AttributeName=void 0,this.uniformsNeedUpdate=!1,this.glslVersion=null,t!==void 0&&this.setValues(t)}copy(t){return super.copy(t),this.fragmentShader=t.fragmentShader,this.vertexShader=t.vertexShader,this.uniforms=bs(t.uniforms),this.uniformsGroups=SS(t.uniformsGroups),this.defines=Object.assign({},t.defines),this.wireframe=t.wireframe,this.wireframeLinewidth=t.wireframeLinewidth,this.fog=t.fog,this.lights=t.lights,this.clipping=t.clipping,this.extensions=Object.assign({},t.extensions),this.glslVersion=t.glslVersion,this}toJSON(t){const i=super.toJSON(t);i.glslVersion=this.glslVersion,i.uniforms={};for(const l in this.uniforms){const u=this.uniforms[l].value;u&&u.isTexture?i.uniforms[l]={type:"t",value:u.toJSON(t).uuid}:u&&u.isColor?i.uniforms[l]={type:"c",value:u.getHex()}:u&&u.isVector2?i.uniforms[l]={type:"v2",value:u.toArray()}:u&&u.isVector3?i.uniforms[l]={type:"v3",value:u.toArray()}:u&&u.isVector4?i.uniforms[l]={type:"v4",value:u.toArray()}:u&&u.isMatrix3?i.uniforms[l]={type:"m3",value:u.toArray()}:u&&u.isMatrix4?i.uniforms[l]={type:"m4",value:u.toArray()}:i.uniforms[l]={value:u}}Object.keys(this.defines).length>0&&(i.defines=this.defines),i.vertexShader=this.vertexShader,i.fragmentShader=this.fragmentShader,i.lights=this.lights,i.clipping=this.clipping;const a={};for(const l in this.extensions)this.extensions[l]===!0&&(a[l]=!0);return Object.keys(a).length>0&&(i.extensions=a),i}}class V_ extends Mr{constructor(){super(),this.isCamera=!0,this.type="Camera",this.matrixWorldInverse=new Yt,this.projectionMatrix=new Yt,this.projectionMatrixInverse=new Yt,this.coordinateSystem=on}copy(t,i){return super.copy(t,i),this.matrixWorldInverse.copy(t.matrixWorldInverse),this.projectionMatrix.copy(t.projectionMatrix),this.projectionMatrixInverse.copy(t.projectionMatrixInverse),this.coordinateSystem=t.coordinateSystem,this}getWorldDirection(t){return super.getWorldDirection(t).negate()}updateMatrixWorld(t){super.updateMatrixWorld(t),this.matrixWorldInverse.copy(this.matrixWorld).invert()}updateWorldMatrix(t,i){super.updateWorldMatrix(t,i),this.matrixWorldInverse.copy(this.matrixWorld).invert()}clone(){return new this.constructor().copy(this)}}const kn=new $,zv=new St,Bv=new St;class $r extends V_{constructor(t=50,i=1,a=.1,l=2e3){super(),this.isPerspectiveCamera=!0,this.type="PerspectiveCamera",this.fov=t,this.zoom=1,this.near=a,this.far=l,this.focus=10,this.aspect=i,this.view=null,this.filmGauge=35,this.filmOffset=0,this.updateProjectionMatrix()}copy(t,i){return super.copy(t,i),this.fov=t.fov,this.zoom=t.zoom,this.near=t.near,this.far=t.far,this.focus=t.focus,this.aspect=t.aspect,this.view=t.view===null?null:Object.assign({},t.view),this.filmGauge=t.filmGauge,this.filmOffset=t.filmOffset,this}setFocalLength(t){const i=.5*this.getFilmHeight()/t;this.fov=tf*2*Math.atan(i),this.updateProjectionMatrix()}getFocalLength(){const t=Math.tan(Fd*.5*this.fov);return .5*this.getFilmHeight()/t}getEffectiveFOV(){return tf*2*Math.atan(Math.tan(Fd*.5*this.fov)/this.zoom)}getFilmWidth(){return this.filmGauge*Math.min(this.aspect,1)}getFilmHeight(){return this.filmGauge/Math.max(this.aspect,1)}getViewBounds(t,i,a){kn.set(-1,-1,.5).applyMatrix4(this.projectionMatrixInverse),i.set(kn.x,kn.y).multiplyScalar(-t/kn.z),kn.set(1,1,.5).applyMatrix4(this.projectionMatrixInverse),a.set(kn.x,kn.y).multiplyScalar(-t/kn.z)}getViewSize(t,i){return this.getViewBounds(t,zv,Bv),i.subVectors(Bv,zv)}setViewOffset(t,i,a,l,u,h){this.aspect=t/i,this.view===null&&(this.view={enabled:!0,fullWidth:1,fullHeight:1,offsetX:0,offsetY:0,width:1,height:1}),this.view.enabled=!0,this.view.fullWidth=t,this.view.fullHeight=i,this.view.offsetX=a,this.view.offsetY=l,this.view.width=u,this.view.height=h,this.updateProjectionMatrix()}clearViewOffset(){this.view!==null&&(this.view.enabled=!1),this.updateProjectionMatrix()}updateProjectionMatrix(){const t=this.near;let i=t*Math.tan(Fd*.5*this.fov)/this.zoom,a=2*i,l=this.aspect*a,u=-.5*l;const h=this.view;if(this.view!==null&&this.view.enabled){const m=h.fullWidth,p=h.fullHeight;u+=h.offsetX*l/m,i-=h.offsetY*a/p,l*=h.width/m,a*=h.height/p}const f=this.filmOffset;f!==0&&(u+=t*f/this.getFilmWidth()),this.projectionMatrix.makePerspective(u,u+l,i,i-a,t,this.far,this.coordinateSystem),this.projectionMatrixInverse.copy(this.projectionMatrix).invert()}toJSON(t){const i=super.toJSON(t);return i.object.fov=this.fov,i.object.zoom=this.zoom,i.object.near=this.near,i.object.far=this.far,i.object.focus=this.focus,i.object.aspect=this.aspect,this.view!==null&&(i.object.view=Object.assign({},this.view)),i.object.filmGauge=this.filmGauge,i.object.filmOffset=this.filmOffset,i}}const hs=-90,fs=1;class wS extends Mr{constructor(t,i,a){super(),this.type="CubeCamera",this.renderTarget=a,this.coordinateSystem=null,this.activeMipmapLevel=0;const l=new $r(hs,fs,t,i);l.layers=this.layers,this.add(l);const u=new $r(hs,fs,t,i);u.layers=this.layers,this.add(u);const h=new $r(hs,fs,t,i);h.layers=this.layers,this.add(h);const f=new $r(hs,fs,t,i);f.layers=this.layers,this.add(f);const m=new $r(hs,fs,t,i);m.layers=this.layers,this.add(m);const p=new $r(hs,fs,t,i);p.layers=this.layers,this.add(p)}updateCoordinateSystem(){const t=this.coordinateSystem,i=this.children.concat(),[a,l,u,h,f,m]=i;for(const p of i)this.remove(p);if(t===on)a.up.set(0,1,0),a.lookAt(1,0,0),l.up.set(0,1,0),l.lookAt(-1,0,0),u.up.set(0,0,-1),u.lookAt(0,1,0),h.up.set(0,0,1),h.lookAt(0,-1,0),f.up.set(0,1,0),f.lookAt(0,0,1),m.up.set(0,1,0),m.lookAt(0,0,-1);else if(t===Ec)a.up.set(0,-1,0),a.lookAt(-1,0,0),l.up.set(0,-1,0),l.lookAt(1,0,0),u.up.set(0,0,1),u.lookAt(0,1,0),h.up.set(0,0,-1),h.lookAt(0,-1,0),f.up.set(0,-1,0),f.lookAt(0,0,1),m.up.set(0,-1,0),m.lookAt(0,0,-1);else throw new Error("THREE.CubeCamera.updateCoordinateSystem(): Invalid coordinate system: "+t);for(const p of i)this.add(p),p.updateMatrixWorld()}update(t,i){this.parent===null&&this.updateMatrixWorld();const{renderTarget:a,activeMipmapLevel:l}=this;this.coordinateSystem!==t.coordinateSystem&&(this.coordinateSystem=t.coordinateSystem,this.updateCoordinateSystem());const[u,h,f,m,p,_]=this.children,y=t.getRenderTarget(),x=t.getActiveCubeFace(),b=t.getActiveMipmapLevel(),R=t.xr.enabled;t.xr.enabled=!1;const A=a.texture.generateMipmaps;a.texture.generateMipmaps=!1,t.setRenderTarget(a,0,l),t.render(i,u),t.setRenderTarget(a,1,l),t.render(i,h),t.setRenderTarget(a,2,l),t.render(i,f),t.setRenderTarget(a,3,l),t.render(i,m),t.setRenderTarget(a,4,l),t.render(i,p),a.texture.generateMipmaps=A,t.setRenderTarget(a,5,l),t.render(i,_),t.setRenderTarget(y,x,b),t.xr.enabled=R,a.texture.needsPMREMUpdate=!0}}class G_ extends Br{constructor(t=[],i=ys,a,l,u,h,f,m,p,_){super(t,i,a,l,u,h,f,m,p,_),this.isCubeTexture=!0,this.flipY=!1}get images(){return this.image}set images(t){this.image=t}}class TS extends Sa{constructor(t=1,i={}){super(t,t,i),this.isWebGLCubeRenderTarget=!0;const a={width:t,height:t,depth:1},l=[a,a,a,a,a,a];this.texture=new G_(l,i.mapping,i.wrapS,i.wrapT,i.magFilter,i.minFilter,i.format,i.type,i.anisotropy,i.colorSpace),this.texture.isRenderTargetTexture=!0,this.texture.generateMipmaps=i.generateMipmaps!==void 0?i.generateMipmaps:!1,this.texture.minFilter=i.minFilter!==void 0?i.minFilter:Ci}fromEquirectangularTexture(t,i){this.texture.type=i.type,this.texture.colorSpace=i.colorSpace,this.texture.generateMipmaps=i.generateMipmaps,this.texture.minFilter=i.minFilter,this.texture.magFilter=i.magFilter;const a={uniforms:{tEquirect:{value:null}},vertexShader:`

				varying vec3 vWorldDirection;

				vec3 transformDirection( in vec3 dir, in mat4 matrix ) {

					return normalize( ( matrix * vec4( dir, 0.0 ) ).xyz );

				}

				void main() {

					vWorldDirection = transformDirection( position, modelMatrix );

					#include <begin_vertex>
					#include <project_vertex>

				}
			`,fragmentShader:`

				uniform sampler2D tEquirect;

				varying vec3 vWorldDirection;

				#include <common>

				void main() {

					vec3 direction = normalize( vWorldDirection );

					vec2 sampleUV = equirectUv( direction );

					gl_FragColor = texture2D( tEquirect, sampleUV );

				}
			`},l=new Oo(5,5,5),u=new Vn({name:"CubemapFromEquirect",uniforms:bs(a.uniforms),vertexShader:a.vertexShader,fragmentShader:a.fragmentShader,side:zr,blending:zn});u.uniforms.tEquirect.value=i;const h=new si(l,u),f=i.minFilter;return i.minFilter===ya&&(i.minFilter=Ci),new wS(1,10,this).update(t,h),i.minFilter=f,h.geometry.dispose(),h.material.dispose(),this}clear(t,i=!0,a=!0,l=!0){const u=t.getRenderTarget();for(let h=0;h<6;h++)t.setRenderTarget(this,h),t.clear(i,a,l);t.setRenderTarget(u)}}class uc extends Mr{constructor(){super(),this.isGroup=!0,this.type="Group"}}const RS={type:"move"};class ah{constructor(){this._targetRay=null,this._grip=null,this._hand=null}getHandSpace(){return this._hand===null&&(this._hand=new uc,this._hand.matrixAutoUpdate=!1,this._hand.visible=!1,this._hand.joints={},this._hand.inputState={pinching:!1}),this._hand}getTargetRaySpace(){return this._targetRay===null&&(this._targetRay=new uc,this._targetRay.matrixAutoUpdate=!1,this._targetRay.visible=!1,this._targetRay.hasLinearVelocity=!1,this._targetRay.linearVelocity=new $,this._targetRay.hasAngularVelocity=!1,this._targetRay.angularVelocity=new $),this._targetRay}getGripSpace(){return this._grip===null&&(this._grip=new uc,this._grip.matrixAutoUpdate=!1,this._grip.visible=!1,this._grip.hasLinearVelocity=!1,this._grip.linearVelocity=new $,this._grip.hasAngularVelocity=!1,this._grip.angularVelocity=new $),this._grip}dispatchEvent(t){return this._targetRay!==null&&this._targetRay.dispatchEvent(t),this._grip!==null&&this._grip.dispatchEvent(t),this._hand!==null&&this._hand.dispatchEvent(t),this}connect(t){if(t&&t.hand){const i=this._hand;if(i)for(const a of t.hand.values())this._getHandJoint(i,a)}return this.dispatchEvent({type:"connected",data:t}),this}disconnect(t){return this.dispatchEvent({type:"disconnected",data:t}),this._targetRay!==null&&(this._targetRay.visible=!1),this._grip!==null&&(this._grip.visible=!1),this._hand!==null&&(this._hand.visible=!1),this}update(t,i,a){let l=null,u=null,h=null;const f=this._targetRay,m=this._grip,p=this._hand;if(t&&i.session.visibilityState!=="visible-blurred"){if(p&&t.hand){h=!0;for(const A of t.hand.values()){const S=i.getJointPose(A,a),v=this._getHandJoint(p,A);S!==null&&(v.matrix.fromArray(S.transform.matrix),v.matrix.decompose(v.position,v.rotation,v.scale),v.matrixWorldNeedsUpdate=!0,v.jointRadius=S.radius),v.visible=S!==null}const _=p.joints["index-finger-tip"],y=p.joints["thumb-tip"],x=_.position.distanceTo(y.position),b=.02,R=.005;p.inputState.pinching&&x>b+R?(p.inputState.pinching=!1,this.dispatchEvent({type:"pinchend",handedness:t.handedness,target:this})):!p.inputState.pinching&&x<=b-R&&(p.inputState.pinching=!0,this.dispatchEvent({type:"pinchstart",handedness:t.handedness,target:this}))}else m!==null&&t.gripSpace&&(u=i.getPose(t.gripSpace,a),u!==null&&(m.matrix.fromArray(u.transform.matrix),m.matrix.decompose(m.position,m.rotation,m.scale),m.matrixWorldNeedsUpdate=!0,u.linearVelocity?(m.hasLinearVelocity=!0,m.linearVelocity.copy(u.linearVelocity)):m.hasLinearVelocity=!1,u.angularVelocity?(m.hasAngularVelocity=!0,m.angularVelocity.copy(u.angularVelocity)):m.hasAngularVelocity=!1));f!==null&&(l=i.getPose(t.targetRaySpace,a),l===null&&u!==null&&(l=u),l!==null&&(f.matrix.fromArray(l.transform.matrix),f.matrix.decompose(f.position,f.rotation,f.scale),f.matrixWorldNeedsUpdate=!0,l.linearVelocity?(f.hasLinearVelocity=!0,f.linearVelocity.copy(l.linearVelocity)):f.hasLinearVelocity=!1,l.angularVelocity?(f.hasAngularVelocity=!0,f.angularVelocity.copy(l.angularVelocity)):f.hasAngularVelocity=!1,this.dispatchEvent(RS)))}return f!==null&&(f.visible=l!==null),m!==null&&(m.visible=u!==null),p!==null&&(p.visible=h!==null),this}_getHandJoint(t,i){if(t.joints[i.jointName]===void 0){const a=new uc;a.matrixAutoUpdate=!1,a.visible=!1,t.joints[i.jointName]=a,t.add(a)}return t.joints[i.jointName]}}class mf{constructor(t,i=25e-5){this.isFogExp2=!0,this.name="",this.color=new xt(t),this.density=i}clone(){return new mf(this.color,this.density)}toJSON(){return{type:"FogExp2",name:this.name,color:this.color.getHex(),density:this.density}}}class CS extends Mr{constructor(){super(),this.isScene=!0,this.type="Scene",this.background=null,this.environment=null,this.fog=null,this.backgroundBlurriness=0,this.backgroundIntensity=1,this.backgroundRotation=new Li,this.environmentIntensity=1,this.environmentRotation=new Li,this.overrideMaterial=null,typeof __THREE_DEVTOOLS__<"u"&&__THREE_DEVTOOLS__.dispatchEvent(new CustomEvent("observe",{detail:this}))}copy(t,i){return super.copy(t,i),t.background!==null&&(this.background=t.background.clone()),t.environment!==null&&(this.environment=t.environment.clone()),t.fog!==null&&(this.fog=t.fog.clone()),this.backgroundBlurriness=t.backgroundBlurriness,this.backgroundIntensity=t.backgroundIntensity,this.backgroundRotation.copy(t.backgroundRotation),this.environmentIntensity=t.environmentIntensity,this.environmentRotation.copy(t.environmentRotation),t.overrideMaterial!==null&&(this.overrideMaterial=t.overrideMaterial.clone()),this.matrixAutoUpdate=t.matrixAutoUpdate,this}toJSON(t){const i=super.toJSON(t);return this.fog!==null&&(i.object.fog=this.fog.toJSON()),this.backgroundBlurriness>0&&(i.object.backgroundBlurriness=this.backgroundBlurriness),this.backgroundIntensity!==1&&(i.object.backgroundIntensity=this.backgroundIntensity),i.object.backgroundRotation=this.backgroundRotation.toArray(),this.environmentIntensity!==1&&(i.object.environmentIntensity=this.environmentIntensity),i.object.environmentRotation=this.environmentRotation.toArray(),i}}const sh=new $,AS=new $,PS=new at;class pa{constructor(t=new $(1,0,0),i=0){this.isPlane=!0,this.normal=t,this.constant=i}set(t,i){return this.normal.copy(t),this.constant=i,this}setComponents(t,i,a,l){return this.normal.set(t,i,a),this.constant=l,this}setFromNormalAndCoplanarPoint(t,i){return this.normal.copy(t),this.constant=-i.dot(this.normal),this}setFromCoplanarPoints(t,i,a){const l=sh.subVectors(a,i).cross(AS.subVectors(t,i)).normalize();return this.setFromNormalAndCoplanarPoint(l,t),this}copy(t){return this.normal.copy(t.normal),this.constant=t.constant,this}normalize(){const t=1/this.normal.length();return this.normal.multiplyScalar(t),this.constant*=t,this}negate(){return this.constant*=-1,this.normal.negate(),this}distanceToPoint(t){return this.normal.dot(t)+this.constant}distanceToSphere(t){return this.distanceToPoint(t.center)-t.radius}projectPoint(t,i){return i.copy(t).addScaledVector(this.normal,-this.distanceToPoint(t))}intersectLine(t,i){const a=t.delta(sh),l=this.normal.dot(a);if(l===0)return this.distanceToPoint(t.start)===0?i.copy(t.start):null;const u=-(t.start.dot(this.normal)+this.constant)/l;return u<0||u>1?null:i.copy(t.start).addScaledVector(a,u)}intersectsLine(t){const i=this.distanceToPoint(t.start),a=this.distanceToPoint(t.end);return i<0&&a>0||a<0&&i>0}intersectsBox(t){return t.intersectsPlane(this)}intersectsSphere(t){return t.intersectsPlane(this)}coplanarPoint(t){return t.copy(this.normal).multiplyScalar(-this.constant)}applyMatrix4(t,i){const a=i||PS.getNormalMatrix(t),l=this.coplanarPoint(sh).applyMatrix4(t),u=this.normal.applyMatrix3(a).normalize();return this.constant=-l.dot(u),this}translate(t){return this.constant-=t.dot(this.normal),this}equals(t){return t.normal.equals(this.normal)&&t.constant===this.constant}clone(){return new this.constructor().copy(this)}}const da=new ff,dc=new $;class gf{constructor(t=new pa,i=new pa,a=new pa,l=new pa,u=new pa,h=new pa){this.planes=[t,i,a,l,u,h]}set(t,i,a,l,u,h){const f=this.planes;return f[0].copy(t),f[1].copy(i),f[2].copy(a),f[3].copy(l),f[4].copy(u),f[5].copy(h),this}copy(t){const i=this.planes;for(let a=0;a<6;a++)i[a].copy(t.planes[a]);return this}setFromProjectionMatrix(t,i=on){const a=this.planes,l=t.elements,u=l[0],h=l[1],f=l[2],m=l[3],p=l[4],_=l[5],y=l[6],x=l[7],b=l[8],R=l[9],A=l[10],S=l[11],v=l[12],D=l[13],L=l[14],C=l[15];if(a[0].setComponents(m-u,x-p,S-b,C-v).normalize(),a[1].setComponents(m+u,x+p,S+b,C+v).normalize(),a[2].setComponents(m+h,x+_,S+R,C+D).normalize(),a[3].setComponents(m-h,x-_,S-R,C-D).normalize(),a[4].setComponents(m-f,x-y,S-A,C-L).normalize(),i===on)a[5].setComponents(m+f,x+y,S+A,C+L).normalize();else if(i===Ec)a[5].setComponents(f,y,A,L).normalize();else throw new Error("THREE.Frustum.setFromProjectionMatrix(): Invalid coordinate system: "+i);return this}intersectsObject(t){if(t.boundingSphere!==void 0)t.boundingSphere===null&&t.computeBoundingSphere(),da.copy(t.boundingSphere).applyMatrix4(t.matrixWorld);else{const i=t.geometry;i.boundingSphere===null&&i.computeBoundingSphere(),da.copy(i.boundingSphere).applyMatrix4(t.matrixWorld)}return this.intersectsSphere(da)}intersectsSprite(t){return da.center.set(0,0,0),da.radius=.7071067811865476,da.applyMatrix4(t.matrixWorld),this.intersectsSphere(da)}intersectsSphere(t){const i=this.planes,a=t.center,l=-t.radius;for(let u=0;u<6;u++)if(i[u].distanceToPoint(a)<l)return!1;return!0}intersectsBox(t){const i=this.planes;for(let a=0;a<6;a++){const l=i[a];if(dc.x=l.normal.x>0?t.max.x:t.min.x,dc.y=l.normal.y>0?t.max.y:t.min.y,dc.z=l.normal.z>0?t.max.z:t.min.z,l.distanceToPoint(dc)<0)return!1}return!0}containsPoint(t){const i=this.planes;for(let a=0;a<6;a++)if(i[a].distanceToPoint(t)<0)return!1;return!0}clone(){return new this.constructor().copy(this)}}class W_ extends Br{constructor(t,i,a=xa,l,u,h,f=Si,m=Si,p,_=Ao){if(_!==Ao&&_!==Po)throw new Error("DepthTexture format must be either THREE.DepthFormat or THREE.DepthStencilFormat");super(null,l,u,h,f,m,_,a,p),this.isDepthTexture=!0,this.image={width:t,height:i},this.flipY=!1,this.generateMipmaps=!1,this.compareFunction=null}copy(t){return super.copy(t),this.source=new hf(Object.assign({},t.image)),this.compareFunction=t.compareFunction,this}toJSON(t){const i=super.toJSON(t);return this.compareFunction!==null&&(i.compareFunction=this.compareFunction),i}}class vf extends Ui{constructor(t=[],i=[],a=1,l=0){super(),this.type="PolyhedronGeometry",this.parameters={vertices:t,indices:i,radius:a,detail:l};const u=[],h=[];f(l),p(a),_(),this.setAttribute("position",new Er(u,3)),this.setAttribute("normal",new Er(u.slice(),3)),this.setAttribute("uv",new Er(h,2)),l===0?this.computeVertexNormals():this.normalizeNormals();function f(D){const L=new $,C=new $,G=new $;for(let k=0;k<i.length;k+=3)b(i[k+0],L),b(i[k+1],C),b(i[k+2],G),m(L,C,G,D)}function m(D,L,C,G){const k=G+1,I=[];for(let H=0;H<=k;H++){I[H]=[];const P=D.clone().lerp(C,H/k),w=L.clone().lerp(C,H/k),F=k-H;for(let te=0;te<=F;te++)te===0&&H===k?I[H][te]=P:I[H][te]=P.clone().lerp(w,te/F)}for(let H=0;H<k;H++)for(let P=0;P<2*(k-H)-1;P++){const w=Math.floor(P/2);P%2===0?(x(I[H][w+1]),x(I[H+1][w]),x(I[H][w])):(x(I[H][w+1]),x(I[H+1][w+1]),x(I[H+1][w]))}}function p(D){const L=new $;for(let C=0;C<u.length;C+=3)L.x=u[C+0],L.y=u[C+1],L.z=u[C+2],L.normalize().multiplyScalar(D),u[C+0]=L.x,u[C+1]=L.y,u[C+2]=L.z}function _(){const D=new $;for(let L=0;L<u.length;L+=3){D.x=u[L+0],D.y=u[L+1],D.z=u[L+2];const C=S(D)/2/Math.PI+.5,G=v(D)/Math.PI+.5;h.push(C,1-G)}R(),y()}function y(){for(let D=0;D<h.length;D+=6){const L=h[D+0],C=h[D+2],G=h[D+4],k=Math.max(L,C,G),I=Math.min(L,C,G);k>.9&&I<.1&&(L<.2&&(h[D+0]+=1),C<.2&&(h[D+2]+=1),G<.2&&(h[D+4]+=1))}}function x(D){u.push(D.x,D.y,D.z)}function b(D,L){const C=D*3;L.x=t[C+0],L.y=t[C+1],L.z=t[C+2]}function R(){const D=new $,L=new $,C=new $,G=new $,k=new St,I=new St,H=new St;for(let P=0,w=0;P<u.length;P+=9,w+=6){D.set(u[P+0],u[P+1],u[P+2]),L.set(u[P+3],u[P+4],u[P+5]),C.set(u[P+6],u[P+7],u[P+8]),k.set(h[w+0],h[w+1]),I.set(h[w+2],h[w+3]),H.set(h[w+4],h[w+5]),G.copy(D).add(L).add(C).divideScalar(3);const F=S(G);A(k,w+0,D,F),A(I,w+2,L,F),A(H,w+4,C,F)}}function A(D,L,C,G){G<0&&D.x===1&&(h[L]=D.x-1),C.x===0&&C.z===0&&(h[L]=G/2/Math.PI+.5)}function S(D){return Math.atan2(D.z,-D.x)}function v(D){return Math.atan2(-D.y,Math.sqrt(D.x*D.x+D.z*D.z))}}copy(t){return super.copy(t),this.parameters=Object.assign({},t.parameters),this}static fromJSON(t){return new vf(t.vertices,t.indices,t.radius,t.details)}}class _f extends vf{constructor(t=1,i=0){const a=(1+Math.sqrt(5))/2,l=[-1,a,0,1,a,0,-1,-a,0,1,-a,0,0,-1,a,0,1,a,0,-1,-a,0,1,-a,a,0,-1,a,0,1,-a,0,-1,-a,0,1],u=[0,11,5,0,5,1,0,1,7,0,7,10,0,10,11,1,5,9,5,11,4,11,10,2,10,7,6,7,1,8,3,9,4,3,4,2,3,2,6,3,6,8,3,8,9,4,9,5,2,4,11,6,2,10,8,6,7,9,8,1];super(l,u,t,i),this.type="IcosahedronGeometry",this.parameters={radius:t,detail:i}}static fromJSON(t){return new _f(t.radius,t.detail)}}class Rc extends Ui{constructor(t=1,i=1,a=1,l=1){super(),this.type="PlaneGeometry",this.parameters={width:t,height:i,widthSegments:a,heightSegments:l};const u=t/2,h=i/2,f=Math.floor(a),m=Math.floor(l),p=f+1,_=m+1,y=t/f,x=i/m,b=[],R=[],A=[],S=[];for(let v=0;v<_;v++){const D=v*x-h;for(let L=0;L<p;L++){const C=L*y-u;R.push(C,-D,0),A.push(0,0,1),S.push(L/f),S.push(1-v/m)}}for(let v=0;v<m;v++)for(let D=0;D<f;D++){const L=D+p*v,C=D+p*(v+1),G=D+1+p*(v+1),k=D+1+p*v;b.push(L,C,k),b.push(C,G,k)}this.setIndex(b),this.setAttribute("position",new Er(R,3)),this.setAttribute("normal",new Er(A,3)),this.setAttribute("uv",new Er(S,2))}copy(t){return super.copy(t),this.parameters=Object.assign({},t.parameters),this}static fromJSON(t){return new Rc(t.width,t.height,t.widthSegments,t.heightSegments)}}class yf extends Ui{constructor(t=1,i=32,a=16,l=0,u=Math.PI*2,h=0,f=Math.PI){super(),this.type="SphereGeometry",this.parameters={radius:t,widthSegments:i,heightSegments:a,phiStart:l,phiLength:u,thetaStart:h,thetaLength:f},i=Math.max(3,Math.floor(i)),a=Math.max(2,Math.floor(a));const m=Math.min(h+f,Math.PI);let p=0;const _=[],y=new $,x=new $,b=[],R=[],A=[],S=[];for(let v=0;v<=a;v++){const D=[],L=v/a;let C=0;v===0&&h===0?C=.5/i:v===a&&m===Math.PI&&(C=-.5/i);for(let G=0;G<=i;G++){const k=G/i;y.x=-t*Math.cos(l+k*u)*Math.sin(h+L*f),y.y=t*Math.cos(h+L*f),y.z=t*Math.sin(l+k*u)*Math.sin(h+L*f),R.push(y.x,y.y,y.z),x.copy(y).normalize(),A.push(x.x,x.y,x.z),S.push(k+C,1-L),D.push(p++)}_.push(D)}for(let v=0;v<a;v++)for(let D=0;D<i;D++){const L=_[v][D+1],C=_[v][D],G=_[v+1][D],k=_[v+1][D+1];(v!==0||h>0)&&b.push(L,C,k),(v!==a-1||m<Math.PI)&&b.push(C,G,k)}this.setIndex(b),this.setAttribute("position",new Er(R,3)),this.setAttribute("normal",new Er(A,3)),this.setAttribute("uv",new Er(S,2))}copy(t){return super.copy(t),this.parameters=Object.assign({},t.parameters),this}static fromJSON(t){return new yf(t.radius,t.widthSegments,t.heightSegments,t.phiStart,t.phiLength,t.thetaStart,t.thetaLength)}}class xf extends Ui{constructor(t=1,i=.4,a=64,l=8,u=2,h=3){super(),this.type="TorusKnotGeometry",this.parameters={radius:t,tube:i,tubularSegments:a,radialSegments:l,p:u,q:h},a=Math.floor(a),l=Math.floor(l);const f=[],m=[],p=[],_=[],y=new $,x=new $,b=new $,R=new $,A=new $,S=new $,v=new $;for(let L=0;L<=a;++L){const C=L/a*u*Math.PI*2;D(C,u,h,t,b),D(C+.01,u,h,t,R),S.subVectors(R,b),v.addVectors(R,b),A.crossVectors(S,v),v.crossVectors(A,S),A.normalize(),v.normalize();for(let G=0;G<=l;++G){const k=G/l*Math.PI*2,I=-i*Math.cos(k),H=i*Math.sin(k);y.x=b.x+(I*v.x+H*A.x),y.y=b.y+(I*v.y+H*A.y),y.z=b.z+(I*v.z+H*A.z),m.push(y.x,y.y,y.z),x.subVectors(y,b).normalize(),p.push(x.x,x.y,x.z),_.push(L/a),_.push(G/l)}}for(let L=1;L<=a;L++)for(let C=1;C<=l;C++){const G=(l+1)*(L-1)+(C-1),k=(l+1)*L+(C-1),I=(l+1)*L+C,H=(l+1)*(L-1)+C;f.push(G,k,H),f.push(k,I,H)}this.setIndex(f),this.setAttribute("position",new Er(m,3)),this.setAttribute("normal",new Er(p,3)),this.setAttribute("uv",new Er(_,2));function D(L,C,G,k,I){const H=Math.cos(L),P=Math.sin(L),w=G/C*L,F=Math.cos(w);I.x=k*(2+F)*.5*H,I.y=k*(2+F)*P*.5,I.z=k*Math.sin(w)*.5}}copy(t){return super.copy(t),this.parameters=Object.assign({},t.parameters),this}static fromJSON(t){return new xf(t.radius,t.tube,t.tubularSegments,t.radialSegments,t.p,t.q)}}class Hv extends No{constructor(t){super(),this.isMeshStandardMaterial=!0,this.type="MeshStandardMaterial",this.defines={STANDARD:""},this.color=new xt(16777215),this.roughness=1,this.metalness=0,this.map=null,this.lightMap=null,this.lightMapIntensity=1,this.aoMap=null,this.aoMapIntensity=1,this.emissive=new xt(0),this.emissiveIntensity=1,this.emissiveMap=null,this.bumpMap=null,this.bumpScale=1,this.normalMap=null,this.normalMapType=D_,this.normalScale=new St(1,1),this.displacementMap=null,this.displacementScale=1,this.displacementBias=0,this.roughnessMap=null,this.metalnessMap=null,this.alphaMap=null,this.envMap=null,this.envMapRotation=new Li,this.envMapIntensity=1,this.wireframe=!1,this.wireframeLinewidth=1,this.wireframeLinecap="round",this.wireframeLinejoin="round",this.flatShading=!1,this.fog=!0,this.setValues(t)}copy(t){return super.copy(t),this.defines={STANDARD:""},this.color.copy(t.color),this.roughness=t.roughness,this.metalness=t.metalness,this.map=t.map,this.lightMap=t.lightMap,this.lightMapIntensity=t.lightMapIntensity,this.aoMap=t.aoMap,this.aoMapIntensity=t.aoMapIntensity,this.emissive.copy(t.emissive),this.emissiveMap=t.emissiveMap,this.emissiveIntensity=t.emissiveIntensity,this.bumpMap=t.bumpMap,this.bumpScale=t.bumpScale,this.normalMap=t.normalMap,this.normalMapType=t.normalMapType,this.normalScale.copy(t.normalScale),this.displacementMap=t.displacementMap,this.displacementScale=t.displacementScale,this.displacementBias=t.displacementBias,this.roughnessMap=t.roughnessMap,this.metalnessMap=t.metalnessMap,this.alphaMap=t.alphaMap,this.envMap=t.envMap,this.envMapRotation.copy(t.envMapRotation),this.envMapIntensity=t.envMapIntensity,this.wireframe=t.wireframe,this.wireframeLinewidth=t.wireframeLinewidth,this.wireframeLinecap=t.wireframeLinecap,this.wireframeLinejoin=t.wireframeLinejoin,this.flatShading=t.flatShading,this.fog=t.fog,this}}class LS extends No{constructor(t){super(),this.isMeshDepthMaterial=!0,this.type="MeshDepthMaterial",this.depthPacking=Vx,this.map=null,this.alphaMap=null,this.displacementMap=null,this.displacementScale=1,this.displacementBias=0,this.wireframe=!1,this.wireframeLinewidth=1,this.setValues(t)}copy(t){return super.copy(t),this.depthPacking=t.depthPacking,this.map=t.map,this.alphaMap=t.alphaMap,this.displacementMap=t.displacementMap,this.displacementScale=t.displacementScale,this.displacementBias=t.displacementBias,this.wireframe=t.wireframe,this.wireframeLinewidth=t.wireframeLinewidth,this}}class US extends No{constructor(t){super(),this.isMeshDistanceMaterial=!0,this.type="MeshDistanceMaterial",this.map=null,this.alphaMap=null,this.displacementMap=null,this.displacementScale=1,this.displacementBias=0,this.setValues(t)}copy(t){return super.copy(t),this.map=t.map,this.alphaMap=t.alphaMap,this.displacementMap=t.displacementMap,this.displacementScale=t.displacementScale,this.displacementBias=t.displacementBias,this}}class Sf extends Mr{constructor(t,i=1){super(),this.isLight=!0,this.type="Light",this.color=new xt(t),this.intensity=i}dispose(){}copy(t,i){return super.copy(t,i),this.color.copy(t.color),this.intensity=t.intensity,this}toJSON(t){const i=super.toJSON(t);return i.object.color=this.color.getHex(),i.object.intensity=this.intensity,this.groundColor!==void 0&&(i.object.groundColor=this.groundColor.getHex()),this.distance!==void 0&&(i.object.distance=this.distance),this.angle!==void 0&&(i.object.angle=this.angle),this.decay!==void 0&&(i.object.decay=this.decay),this.penumbra!==void 0&&(i.object.penumbra=this.penumbra),this.shadow!==void 0&&(i.object.shadow=this.shadow.toJSON()),this.target!==void 0&&(i.object.target=this.target.uuid),i}}const oh=new Yt,Vv=new $,Gv=new $;class j_{constructor(t){this.camera=t,this.intensity=1,this.bias=0,this.normalBias=0,this.radius=1,this.blurSamples=8,this.mapSize=new St(512,512),this.mapType=Pi,this.map=null,this.mapPass=null,this.matrix=new Yt,this.autoUpdate=!0,this.needsUpdate=!1,this._frustum=new gf,this._frameExtents=new St(1,1),this._viewportCount=1,this._viewports=[new Ft(0,0,1,1)]}getViewportCount(){return this._viewportCount}getFrustum(){return this._frustum}updateMatrices(t){const i=this.camera,a=this.matrix;Vv.setFromMatrixPosition(t.matrixWorld),i.position.copy(Vv),Gv.setFromMatrixPosition(t.target.matrixWorld),i.lookAt(Gv),i.updateMatrixWorld(),oh.multiplyMatrices(i.projectionMatrix,i.matrixWorldInverse),this._frustum.setFromProjectionMatrix(oh),a.set(.5,0,0,.5,0,.5,0,.5,0,0,.5,.5,0,0,0,1),a.multiply(oh)}getViewport(t){return this._viewports[t]}getFrameExtents(){return this._frameExtents}dispose(){this.map&&this.map.dispose(),this.mapPass&&this.mapPass.dispose()}copy(t){return this.camera=t.camera.clone(),this.intensity=t.intensity,this.bias=t.bias,this.radius=t.radius,this.autoUpdate=t.autoUpdate,this.needsUpdate=t.needsUpdate,this.normalBias=t.normalBias,this.blurSamples=t.blurSamples,this.mapSize.copy(t.mapSize),this}clone(){return new this.constructor().copy(this)}toJSON(){const t={};return this.intensity!==1&&(t.intensity=this.intensity),this.bias!==0&&(t.bias=this.bias),this.normalBias!==0&&(t.normalBias=this.normalBias),this.radius!==1&&(t.radius=this.radius),(this.mapSize.x!==512||this.mapSize.y!==512)&&(t.mapSize=this.mapSize.toArray()),t.camera=this.camera.toJSON(!1).object,delete t.camera.matrix,t}}const Wv=new Yt,wo=new $,lh=new $;class DS extends j_{constructor(){super(new $r(90,1,.5,500)),this.isPointLightShadow=!0,this._frameExtents=new St(4,2),this._viewportCount=6,this._viewports=[new Ft(2,1,1,1),new Ft(0,1,1,1),new Ft(3,1,1,1),new Ft(1,1,1,1),new Ft(3,0,1,1),new Ft(1,0,1,1)],this._cubeDirections=[new $(1,0,0),new $(-1,0,0),new $(0,0,1),new $(0,0,-1),new $(0,1,0),new $(0,-1,0)],this._cubeUps=[new $(0,1,0),new $(0,1,0),new $(0,1,0),new $(0,1,0),new $(0,0,1),new $(0,0,-1)]}updateMatrices(t,i=0){const a=this.camera,l=this.matrix,u=t.distance||a.far;u!==a.far&&(a.far=u,a.updateProjectionMatrix()),wo.setFromMatrixPosition(t.matrixWorld),a.position.copy(wo),lh.copy(a.position),lh.add(this._cubeDirections[i]),a.up.copy(this._cubeUps[i]),a.lookAt(lh),a.updateMatrixWorld(),l.makeTranslation(-wo.x,-wo.y,-wo.z),Wv.multiplyMatrices(a.projectionMatrix,a.matrixWorldInverse),this._frustum.setFromProjectionMatrix(Wv)}}class ch extends Sf{constructor(t,i,a=0,l=2){super(t,i),this.isPointLight=!0,this.type="PointLight",this.distance=a,this.decay=l,this.shadow=new DS}get power(){return this.intensity*4*Math.PI}set power(t){this.intensity=t/(4*Math.PI)}dispose(){this.shadow.dispose()}copy(t,i){return super.copy(t,i),this.distance=t.distance,this.decay=t.decay,this.shadow=t.shadow.clone(),this}}class X_ extends V_{constructor(t=-1,i=1,a=1,l=-1,u=.1,h=2e3){super(),this.isOrthographicCamera=!0,this.type="OrthographicCamera",this.zoom=1,this.view=null,this.left=t,this.right=i,this.top=a,this.bottom=l,this.near=u,this.far=h,this.updateProjectionMatrix()}copy(t,i){return super.copy(t,i),this.left=t.left,this.right=t.right,this.top=t.top,this.bottom=t.bottom,this.near=t.near,this.far=t.far,this.zoom=t.zoom,this.view=t.view===null?null:Object.assign({},t.view),this}setViewOffset(t,i,a,l,u,h){this.view===null&&(this.view={enabled:!0,fullWidth:1,fullHeight:1,offsetX:0,offsetY:0,width:1,height:1}),this.view.enabled=!0,this.view.fullWidth=t,this.view.fullHeight=i,this.view.offsetX=a,this.view.offsetY=l,this.view.width=u,this.view.height=h,this.updateProjectionMatrix()}clearViewOffset(){this.view!==null&&(this.view.enabled=!1),this.updateProjectionMatrix()}updateProjectionMatrix(){const t=(this.right-this.left)/(2*this.zoom),i=(this.top-this.bottom)/(2*this.zoom),a=(this.right+this.left)/2,l=(this.top+this.bottom)/2;let u=a-t,h=a+t,f=l+i,m=l-i;if(this.view!==null&&this.view.enabled){const p=(this.right-this.left)/this.view.fullWidth/this.zoom,_=(this.top-this.bottom)/this.view.fullHeight/this.zoom;u+=p*this.view.offsetX,h=u+p*this.view.width,f-=_*this.view.offsetY,m=f-_*this.view.height}this.projectionMatrix.makeOrthographic(u,h,f,m,this.near,this.far,this.coordinateSystem),this.projectionMatrixInverse.copy(this.projectionMatrix).invert()}toJSON(t){const i=super.toJSON(t);return i.object.zoom=this.zoom,i.object.left=this.left,i.object.right=this.right,i.object.top=this.top,i.object.bottom=this.bottom,i.object.near=this.near,i.object.far=this.far,this.view!==null&&(i.object.view=Object.assign({},this.view)),i}}class IS extends j_{constructor(){super(new X_(-5,5,5,-5,.5,500)),this.isDirectionalLightShadow=!0}}class NS extends Sf{constructor(t,i){super(t,i),this.isDirectionalLight=!0,this.type="DirectionalLight",this.position.copy(Mr.DEFAULT_UP),this.updateMatrix(),this.target=new Mr,this.shadow=new IS}dispose(){this.shadow.dispose()}copy(t){return super.copy(t),this.target=t.target.clone(),this.shadow=t.shadow.clone(),this}}class OS extends Sf{constructor(t,i){super(t,i),this.isAmbientLight=!0,this.type="AmbientLight"}}class kS extends $r{constructor(t=[]){super(),this.isArrayCamera=!0,this.isMultiViewCamera=!1,this.cameras=t}}class FS{constructor(t=!0){this.autoStart=t,this.startTime=0,this.oldTime=0,this.elapsedTime=0,this.running=!1}start(){this.startTime=jv(),this.oldTime=this.startTime,this.elapsedTime=0,this.running=!0}stop(){this.getElapsedTime(),this.running=!1,this.autoStart=!1}getElapsedTime(){return this.getDelta(),this.elapsedTime}getDelta(){let t=0;if(this.autoStart&&!this.running)return this.start(),0;if(this.running){const i=jv();t=(i-this.oldTime)/1e3,this.oldTime=i,this.elapsedTime+=t}return t}}function jv(){return performance.now()}function Xv(o,t,i,a){const l=zS(a);switch(i){case C_:return o*t;case P_:return o*t/l.components*l.byteLength;case cf:return o*t/l.components*l.byteLength;case L_:return o*t*2/l.components*l.byteLength;case uf:return o*t*2/l.components*l.byteLength;case A_:return o*t*3/l.components*l.byteLength;case xi:return o*t*4/l.components*l.byteLength;case df:return o*t*4/l.components*l.byteLength;case gc:case vc:return Math.floor((o+3)/4)*Math.floor((t+3)/4)*8;case _c:case yc:return Math.floor((o+3)/4)*Math.floor((t+3)/4)*16;case Ph:case Uh:return Math.max(o,16)*Math.max(t,8)/4;case Ah:case Lh:return Math.max(o,8)*Math.max(t,8)/2;case Dh:case Ih:return Math.floor((o+3)/4)*Math.floor((t+3)/4)*8;case Nh:return Math.floor((o+3)/4)*Math.floor((t+3)/4)*16;case Oh:return Math.floor((o+3)/4)*Math.floor((t+3)/4)*16;case kh:return Math.floor((o+4)/5)*Math.floor((t+3)/4)*16;case Fh:return Math.floor((o+4)/5)*Math.floor((t+4)/5)*16;case zh:return Math.floor((o+5)/6)*Math.floor((t+4)/5)*16;case Bh:return Math.floor((o+5)/6)*Math.floor((t+5)/6)*16;case Hh:return Math.floor((o+7)/8)*Math.floor((t+4)/5)*16;case Vh:return Math.floor((o+7)/8)*Math.floor((t+5)/6)*16;case Gh:return Math.floor((o+7)/8)*Math.floor((t+7)/8)*16;case Wh:return Math.floor((o+9)/10)*Math.floor((t+4)/5)*16;case jh:return Math.floor((o+9)/10)*Math.floor((t+5)/6)*16;case Xh:return Math.floor((o+9)/10)*Math.floor((t+7)/8)*16;case Yh:return Math.floor((o+9)/10)*Math.floor((t+9)/10)*16;case qh:return Math.floor((o+11)/12)*Math.floor((t+9)/10)*16;case Qh:return Math.floor((o+11)/12)*Math.floor((t+11)/12)*16;case xc:case $h:case Kh:return Math.ceil(o/4)*Math.ceil(t/4)*16;case U_:case Zh:return Math.ceil(o/4)*Math.ceil(t/4)*8;case Jh:case ef:return Math.ceil(o/4)*Math.ceil(t/4)*16}throw new Error(`Unable to determine texture byte length for ${i} format.`)}function zS(o){switch(o){case Pi:case w_:return{byteLength:1,components:1};case Ro:case T_:case Lo:return{byteLength:2,components:1};case of:case lf:return{byteLength:2,components:4};case xa:case sf:case sn:return{byteLength:4,components:1};case R_:return{byteLength:4,components:3}}throw new Error(`Unknown texture type ${o}.`)}typeof __THREE_DEVTOOLS__<"u"&&__THREE_DEVTOOLS__.dispatchEvent(new CustomEvent("register",{detail:{revision:af}}));typeof window<"u"&&(window.__THREE__?console.warn("WARNING: Multiple instances of Three.js being imported."):window.__THREE__=af);/**
* @license
* Copyright 2010-2025 Three.js Authors
* SPDX-License-Identifier: MIT
*/function Y_(){let o=null,t=!1,i=null,a=null;function l(u,h){i(u,h),a=o.requestAnimationFrame(l)}return{start:function(){t!==!0&&i!==null&&(a=o.requestAnimationFrame(l),t=!0)},stop:function(){o.cancelAnimationFrame(a),t=!1},setAnimationLoop:function(u){i=u},setContext:function(u){o=u}}}function BS(o){const t=new WeakMap;function i(f,m){const p=f.array,_=f.usage,y=p.byteLength,x=o.createBuffer();o.bindBuffer(m,x),o.bufferData(m,p,_),f.onUploadCallback();let b;if(p instanceof Float32Array)b=o.FLOAT;else if(p instanceof Uint16Array)f.isFloat16BufferAttribute?b=o.HALF_FLOAT:b=o.UNSIGNED_SHORT;else if(p instanceof Int16Array)b=o.SHORT;else if(p instanceof Uint32Array)b=o.UNSIGNED_INT;else if(p instanceof Int32Array)b=o.INT;else if(p instanceof Int8Array)b=o.BYTE;else if(p instanceof Uint8Array)b=o.UNSIGNED_BYTE;else if(p instanceof Uint8ClampedArray)b=o.UNSIGNED_BYTE;else throw new Error("THREE.WebGLAttributes: Unsupported buffer data format: "+p);return{buffer:x,type:b,bytesPerElement:p.BYTES_PER_ELEMENT,version:f.version,size:y}}function a(f,m,p){const _=m.array,y=m.updateRanges;if(o.bindBuffer(p,f),y.length===0)o.bufferSubData(p,0,_);else{y.sort((b,R)=>b.start-R.start);let x=0;for(let b=1;b<y.length;b++){const R=y[x],A=y[b];A.start<=R.start+R.count+1?R.count=Math.max(R.count,A.start+A.count-R.start):(++x,y[x]=A)}y.length=x+1;for(let b=0,R=y.length;b<R;b++){const A=y[b];o.bufferSubData(p,A.start*_.BYTES_PER_ELEMENT,_,A.start,A.count)}m.clearUpdateRanges()}m.onUploadCallback()}function l(f){return f.isInterleavedBufferAttribute&&(f=f.data),t.get(f)}function u(f){f.isInterleavedBufferAttribute&&(f=f.data);const m=t.get(f);m&&(o.deleteBuffer(m.buffer),t.delete(f))}function h(f,m){if(f.isInterleavedBufferAttribute&&(f=f.data),f.isGLBufferAttribute){const _=t.get(f);(!_||_.version<f.version)&&t.set(f,{buffer:f.buffer,type:f.type,bytesPerElement:f.elementSize,version:f.version});return}const p=t.get(f);if(p===void 0)t.set(f,i(f,m));else if(p.version<f.version){if(p.size!==f.array.byteLength)throw new Error("THREE.WebGLAttributes: The size of the buffer attribute's array buffer does not match the original size. Resizing buffer attributes is not supported.");a(p.buffer,f,m),p.version=f.version}}return{get:l,remove:u,update:h}}var HS=`#ifdef USE_ALPHAHASH
	if ( diffuseColor.a < getAlphaHashThreshold( vPosition ) ) discard;
#endif`,VS=`#ifdef USE_ALPHAHASH
	const float ALPHA_HASH_SCALE = 0.05;
	float hash2D( vec2 value ) {
		return fract( 1.0e4 * sin( 17.0 * value.x + 0.1 * value.y ) * ( 0.1 + abs( sin( 13.0 * value.y + value.x ) ) ) );
	}
	float hash3D( vec3 value ) {
		return hash2D( vec2( hash2D( value.xy ), value.z ) );
	}
	float getAlphaHashThreshold( vec3 position ) {
		float maxDeriv = max(
			length( dFdx( position.xyz ) ),
			length( dFdy( position.xyz ) )
		);
		float pixScale = 1.0 / ( ALPHA_HASH_SCALE * maxDeriv );
		vec2 pixScales = vec2(
			exp2( floor( log2( pixScale ) ) ),
			exp2( ceil( log2( pixScale ) ) )
		);
		vec2 alpha = vec2(
			hash3D( floor( pixScales.x * position.xyz ) ),
			hash3D( floor( pixScales.y * position.xyz ) )
		);
		float lerpFactor = fract( log2( pixScale ) );
		float x = ( 1.0 - lerpFactor ) * alpha.x + lerpFactor * alpha.y;
		float a = min( lerpFactor, 1.0 - lerpFactor );
		vec3 cases = vec3(
			x * x / ( 2.0 * a * ( 1.0 - a ) ),
			( x - 0.5 * a ) / ( 1.0 - a ),
			1.0 - ( ( 1.0 - x ) * ( 1.0 - x ) / ( 2.0 * a * ( 1.0 - a ) ) )
		);
		float threshold = ( x < ( 1.0 - a ) )
			? ( ( x < a ) ? cases.x : cases.y )
			: cases.z;
		return clamp( threshold , 1.0e-6, 1.0 );
	}
#endif`,GS=`#ifdef USE_ALPHAMAP
	diffuseColor.a *= texture2D( alphaMap, vAlphaMapUv ).g;
#endif`,WS=`#ifdef USE_ALPHAMAP
	uniform sampler2D alphaMap;
#endif`,jS=`#ifdef USE_ALPHATEST
	#ifdef ALPHA_TO_COVERAGE
	diffuseColor.a = smoothstep( alphaTest, alphaTest + fwidth( diffuseColor.a ), diffuseColor.a );
	if ( diffuseColor.a == 0.0 ) discard;
	#else
	if ( diffuseColor.a < alphaTest ) discard;
	#endif
#endif`,XS=`#ifdef USE_ALPHATEST
	uniform float alphaTest;
#endif`,YS=`#ifdef USE_AOMAP
	float ambientOcclusion = ( texture2D( aoMap, vAoMapUv ).r - 1.0 ) * aoMapIntensity + 1.0;
	reflectedLight.indirectDiffuse *= ambientOcclusion;
	#if defined( USE_CLEARCOAT ) 
		clearcoatSpecularIndirect *= ambientOcclusion;
	#endif
	#if defined( USE_SHEEN ) 
		sheenSpecularIndirect *= ambientOcclusion;
	#endif
	#if defined( USE_ENVMAP ) && defined( STANDARD )
		float dotNV = saturate( dot( geometryNormal, geometryViewDir ) );
		reflectedLight.indirectSpecular *= computeSpecularOcclusion( dotNV, ambientOcclusion, material.roughness );
	#endif
#endif`,qS=`#ifdef USE_AOMAP
	uniform sampler2D aoMap;
	uniform float aoMapIntensity;
#endif`,QS=`#ifdef USE_BATCHING
	#if ! defined( GL_ANGLE_multi_draw )
	#define gl_DrawID _gl_DrawID
	uniform int _gl_DrawID;
	#endif
	uniform highp sampler2D batchingTexture;
	uniform highp usampler2D batchingIdTexture;
	mat4 getBatchingMatrix( const in float i ) {
		int size = textureSize( batchingTexture, 0 ).x;
		int j = int( i ) * 4;
		int x = j % size;
		int y = j / size;
		vec4 v1 = texelFetch( batchingTexture, ivec2( x, y ), 0 );
		vec4 v2 = texelFetch( batchingTexture, ivec2( x + 1, y ), 0 );
		vec4 v3 = texelFetch( batchingTexture, ivec2( x + 2, y ), 0 );
		vec4 v4 = texelFetch( batchingTexture, ivec2( x + 3, y ), 0 );
		return mat4( v1, v2, v3, v4 );
	}
	float getIndirectIndex( const in int i ) {
		int size = textureSize( batchingIdTexture, 0 ).x;
		int x = i % size;
		int y = i / size;
		return float( texelFetch( batchingIdTexture, ivec2( x, y ), 0 ).r );
	}
#endif
#ifdef USE_BATCHING_COLOR
	uniform sampler2D batchingColorTexture;
	vec3 getBatchingColor( const in float i ) {
		int size = textureSize( batchingColorTexture, 0 ).x;
		int j = int( i );
		int x = j % size;
		int y = j / size;
		return texelFetch( batchingColorTexture, ivec2( x, y ), 0 ).rgb;
	}
#endif`,$S=`#ifdef USE_BATCHING
	mat4 batchingMatrix = getBatchingMatrix( getIndirectIndex( gl_DrawID ) );
#endif`,KS=`vec3 transformed = vec3( position );
#ifdef USE_ALPHAHASH
	vPosition = vec3( position );
#endif`,ZS=`vec3 objectNormal = vec3( normal );
#ifdef USE_TANGENT
	vec3 objectTangent = vec3( tangent.xyz );
#endif`,JS=`float G_BlinnPhong_Implicit( ) {
	return 0.25;
}
float D_BlinnPhong( const in float shininess, const in float dotNH ) {
	return RECIPROCAL_PI * ( shininess * 0.5 + 1.0 ) * pow( dotNH, shininess );
}
vec3 BRDF_BlinnPhong( const in vec3 lightDir, const in vec3 viewDir, const in vec3 normal, const in vec3 specularColor, const in float shininess ) {
	vec3 halfDir = normalize( lightDir + viewDir );
	float dotNH = saturate( dot( normal, halfDir ) );
	float dotVH = saturate( dot( viewDir, halfDir ) );
	vec3 F = F_Schlick( specularColor, 1.0, dotVH );
	float G = G_BlinnPhong_Implicit( );
	float D = D_BlinnPhong( shininess, dotNH );
	return F * ( G * D );
} // validated`,eb=`#ifdef USE_IRIDESCENCE
	const mat3 XYZ_TO_REC709 = mat3(
		 3.2404542, -0.9692660,  0.0556434,
		-1.5371385,  1.8760108, -0.2040259,
		-0.4985314,  0.0415560,  1.0572252
	);
	vec3 Fresnel0ToIor( vec3 fresnel0 ) {
		vec3 sqrtF0 = sqrt( fresnel0 );
		return ( vec3( 1.0 ) + sqrtF0 ) / ( vec3( 1.0 ) - sqrtF0 );
	}
	vec3 IorToFresnel0( vec3 transmittedIor, float incidentIor ) {
		return pow2( ( transmittedIor - vec3( incidentIor ) ) / ( transmittedIor + vec3( incidentIor ) ) );
	}
	float IorToFresnel0( float transmittedIor, float incidentIor ) {
		return pow2( ( transmittedIor - incidentIor ) / ( transmittedIor + incidentIor ));
	}
	vec3 evalSensitivity( float OPD, vec3 shift ) {
		float phase = 2.0 * PI * OPD * 1.0e-9;
		vec3 val = vec3( 5.4856e-13, 4.4201e-13, 5.2481e-13 );
		vec3 pos = vec3( 1.6810e+06, 1.7953e+06, 2.2084e+06 );
		vec3 var = vec3( 4.3278e+09, 9.3046e+09, 6.6121e+09 );
		vec3 xyz = val * sqrt( 2.0 * PI * var ) * cos( pos * phase + shift ) * exp( - pow2( phase ) * var );
		xyz.x += 9.7470e-14 * sqrt( 2.0 * PI * 4.5282e+09 ) * cos( 2.2399e+06 * phase + shift[ 0 ] ) * exp( - 4.5282e+09 * pow2( phase ) );
		xyz /= 1.0685e-7;
		vec3 rgb = XYZ_TO_REC709 * xyz;
		return rgb;
	}
	vec3 evalIridescence( float outsideIOR, float eta2, float cosTheta1, float thinFilmThickness, vec3 baseF0 ) {
		vec3 I;
		float iridescenceIOR = mix( outsideIOR, eta2, smoothstep( 0.0, 0.03, thinFilmThickness ) );
		float sinTheta2Sq = pow2( outsideIOR / iridescenceIOR ) * ( 1.0 - pow2( cosTheta1 ) );
		float cosTheta2Sq = 1.0 - sinTheta2Sq;
		if ( cosTheta2Sq < 0.0 ) {
			return vec3( 1.0 );
		}
		float cosTheta2 = sqrt( cosTheta2Sq );
		float R0 = IorToFresnel0( iridescenceIOR, outsideIOR );
		float R12 = F_Schlick( R0, 1.0, cosTheta1 );
		float T121 = 1.0 - R12;
		float phi12 = 0.0;
		if ( iridescenceIOR < outsideIOR ) phi12 = PI;
		float phi21 = PI - phi12;
		vec3 baseIOR = Fresnel0ToIor( clamp( baseF0, 0.0, 0.9999 ) );		vec3 R1 = IorToFresnel0( baseIOR, iridescenceIOR );
		vec3 R23 = F_Schlick( R1, 1.0, cosTheta2 );
		vec3 phi23 = vec3( 0.0 );
		if ( baseIOR[ 0 ] < iridescenceIOR ) phi23[ 0 ] = PI;
		if ( baseIOR[ 1 ] < iridescenceIOR ) phi23[ 1 ] = PI;
		if ( baseIOR[ 2 ] < iridescenceIOR ) phi23[ 2 ] = PI;
		float OPD = 2.0 * iridescenceIOR * thinFilmThickness * cosTheta2;
		vec3 phi = vec3( phi21 ) + phi23;
		vec3 R123 = clamp( R12 * R23, 1e-5, 0.9999 );
		vec3 r123 = sqrt( R123 );
		vec3 Rs = pow2( T121 ) * R23 / ( vec3( 1.0 ) - R123 );
		vec3 C0 = R12 + Rs;
		I = C0;
		vec3 Cm = Rs - T121;
		for ( int m = 1; m <= 2; ++ m ) {
			Cm *= r123;
			vec3 Sm = 2.0 * evalSensitivity( float( m ) * OPD, float( m ) * phi );
			I += Cm * Sm;
		}
		return max( I, vec3( 0.0 ) );
	}
#endif`,tb=`#ifdef USE_BUMPMAP
	uniform sampler2D bumpMap;
	uniform float bumpScale;
	vec2 dHdxy_fwd() {
		vec2 dSTdx = dFdx( vBumpMapUv );
		vec2 dSTdy = dFdy( vBumpMapUv );
		float Hll = bumpScale * texture2D( bumpMap, vBumpMapUv ).x;
		float dBx = bumpScale * texture2D( bumpMap, vBumpMapUv + dSTdx ).x - Hll;
		float dBy = bumpScale * texture2D( bumpMap, vBumpMapUv + dSTdy ).x - Hll;
		return vec2( dBx, dBy );
	}
	vec3 perturbNormalArb( vec3 surf_pos, vec3 surf_norm, vec2 dHdxy, float faceDirection ) {
		vec3 vSigmaX = normalize( dFdx( surf_pos.xyz ) );
		vec3 vSigmaY = normalize( dFdy( surf_pos.xyz ) );
		vec3 vN = surf_norm;
		vec3 R1 = cross( vSigmaY, vN );
		vec3 R2 = cross( vN, vSigmaX );
		float fDet = dot( vSigmaX, R1 ) * faceDirection;
		vec3 vGrad = sign( fDet ) * ( dHdxy.x * R1 + dHdxy.y * R2 );
		return normalize( abs( fDet ) * surf_norm - vGrad );
	}
#endif`,rb=`#if NUM_CLIPPING_PLANES > 0
	vec4 plane;
	#ifdef ALPHA_TO_COVERAGE
		float distanceToPlane, distanceGradient;
		float clipOpacity = 1.0;
		#pragma unroll_loop_start
		for ( int i = 0; i < UNION_CLIPPING_PLANES; i ++ ) {
			plane = clippingPlanes[ i ];
			distanceToPlane = - dot( vClipPosition, plane.xyz ) + plane.w;
			distanceGradient = fwidth( distanceToPlane ) / 2.0;
			clipOpacity *= smoothstep( - distanceGradient, distanceGradient, distanceToPlane );
			if ( clipOpacity == 0.0 ) discard;
		}
		#pragma unroll_loop_end
		#if UNION_CLIPPING_PLANES < NUM_CLIPPING_PLANES
			float unionClipOpacity = 1.0;
			#pragma unroll_loop_start
			for ( int i = UNION_CLIPPING_PLANES; i < NUM_CLIPPING_PLANES; i ++ ) {
				plane = clippingPlanes[ i ];
				distanceToPlane = - dot( vClipPosition, plane.xyz ) + plane.w;
				distanceGradient = fwidth( distanceToPlane ) / 2.0;
				unionClipOpacity *= 1.0 - smoothstep( - distanceGradient, distanceGradient, distanceToPlane );
			}
			#pragma unroll_loop_end
			clipOpacity *= 1.0 - unionClipOpacity;
		#endif
		diffuseColor.a *= clipOpacity;
		if ( diffuseColor.a == 0.0 ) discard;
	#else
		#pragma unroll_loop_start
		for ( int i = 0; i < UNION_CLIPPING_PLANES; i ++ ) {
			plane = clippingPlanes[ i ];
			if ( dot( vClipPosition, plane.xyz ) > plane.w ) discard;
		}
		#pragma unroll_loop_end
		#if UNION_CLIPPING_PLANES < NUM_CLIPPING_PLANES
			bool clipped = true;
			#pragma unroll_loop_start
			for ( int i = UNION_CLIPPING_PLANES; i < NUM_CLIPPING_PLANES; i ++ ) {
				plane = clippingPlanes[ i ];
				clipped = ( dot( vClipPosition, plane.xyz ) > plane.w ) && clipped;
			}
			#pragma unroll_loop_end
			if ( clipped ) discard;
		#endif
	#endif
#endif`,ib=`#if NUM_CLIPPING_PLANES > 0
	varying vec3 vClipPosition;
	uniform vec4 clippingPlanes[ NUM_CLIPPING_PLANES ];
#endif`,nb=`#if NUM_CLIPPING_PLANES > 0
	varying vec3 vClipPosition;
#endif`,ab=`#if NUM_CLIPPING_PLANES > 0
	vClipPosition = - mvPosition.xyz;
#endif`,sb=`#if defined( USE_COLOR_ALPHA )
	diffuseColor *= vColor;
#elif defined( USE_COLOR )
	diffuseColor.rgb *= vColor;
#endif`,ob=`#if defined( USE_COLOR_ALPHA )
	varying vec4 vColor;
#elif defined( USE_COLOR )
	varying vec3 vColor;
#endif`,lb=`#if defined( USE_COLOR_ALPHA )
	varying vec4 vColor;
#elif defined( USE_COLOR ) || defined( USE_INSTANCING_COLOR ) || defined( USE_BATCHING_COLOR )
	varying vec3 vColor;
#endif`,cb=`#if defined( USE_COLOR_ALPHA )
	vColor = vec4( 1.0 );
#elif defined( USE_COLOR ) || defined( USE_INSTANCING_COLOR ) || defined( USE_BATCHING_COLOR )
	vColor = vec3( 1.0 );
#endif
#ifdef USE_COLOR
	vColor *= color;
#endif
#ifdef USE_INSTANCING_COLOR
	vColor.xyz *= instanceColor.xyz;
#endif
#ifdef USE_BATCHING_COLOR
	vec3 batchingColor = getBatchingColor( getIndirectIndex( gl_DrawID ) );
	vColor.xyz *= batchingColor.xyz;
#endif`,ub=`#define PI 3.141592653589793
#define PI2 6.283185307179586
#define PI_HALF 1.5707963267948966
#define RECIPROCAL_PI 0.3183098861837907
#define RECIPROCAL_PI2 0.15915494309189535
#define EPSILON 1e-6
#ifndef saturate
#define saturate( a ) clamp( a, 0.0, 1.0 )
#endif
#define whiteComplement( a ) ( 1.0 - saturate( a ) )
float pow2( const in float x ) { return x*x; }
vec3 pow2( const in vec3 x ) { return x*x; }
float pow3( const in float x ) { return x*x*x; }
float pow4( const in float x ) { float x2 = x*x; return x2*x2; }
float max3( const in vec3 v ) { return max( max( v.x, v.y ), v.z ); }
float average( const in vec3 v ) { return dot( v, vec3( 0.3333333 ) ); }
highp float rand( const in vec2 uv ) {
	const highp float a = 12.9898, b = 78.233, c = 43758.5453;
	highp float dt = dot( uv.xy, vec2( a,b ) ), sn = mod( dt, PI );
	return fract( sin( sn ) * c );
}
#ifdef HIGH_PRECISION
	float precisionSafeLength( vec3 v ) { return length( v ); }
#else
	float precisionSafeLength( vec3 v ) {
		float maxComponent = max3( abs( v ) );
		return length( v / maxComponent ) * maxComponent;
	}
#endif
struct IncidentLight {
	vec3 color;
	vec3 direction;
	bool visible;
};
struct ReflectedLight {
	vec3 directDiffuse;
	vec3 directSpecular;
	vec3 indirectDiffuse;
	vec3 indirectSpecular;
};
#ifdef USE_ALPHAHASH
	varying vec3 vPosition;
#endif
vec3 transformDirection( in vec3 dir, in mat4 matrix ) {
	return normalize( ( matrix * vec4( dir, 0.0 ) ).xyz );
}
vec3 inverseTransformDirection( in vec3 dir, in mat4 matrix ) {
	return normalize( ( vec4( dir, 0.0 ) * matrix ).xyz );
}
mat3 transposeMat3( const in mat3 m ) {
	mat3 tmp;
	tmp[ 0 ] = vec3( m[ 0 ].x, m[ 1 ].x, m[ 2 ].x );
	tmp[ 1 ] = vec3( m[ 0 ].y, m[ 1 ].y, m[ 2 ].y );
	tmp[ 2 ] = vec3( m[ 0 ].z, m[ 1 ].z, m[ 2 ].z );
	return tmp;
}
bool isPerspectiveMatrix( mat4 m ) {
	return m[ 2 ][ 3 ] == - 1.0;
}
vec2 equirectUv( in vec3 dir ) {
	float u = atan( dir.z, dir.x ) * RECIPROCAL_PI2 + 0.5;
	float v = asin( clamp( dir.y, - 1.0, 1.0 ) ) * RECIPROCAL_PI + 0.5;
	return vec2( u, v );
}
vec3 BRDF_Lambert( const in vec3 diffuseColor ) {
	return RECIPROCAL_PI * diffuseColor;
}
vec3 F_Schlick( const in vec3 f0, const in float f90, const in float dotVH ) {
	float fresnel = exp2( ( - 5.55473 * dotVH - 6.98316 ) * dotVH );
	return f0 * ( 1.0 - fresnel ) + ( f90 * fresnel );
}
float F_Schlick( const in float f0, const in float f90, const in float dotVH ) {
	float fresnel = exp2( ( - 5.55473 * dotVH - 6.98316 ) * dotVH );
	return f0 * ( 1.0 - fresnel ) + ( f90 * fresnel );
} // validated`,db=`#ifdef ENVMAP_TYPE_CUBE_UV
	#define cubeUV_minMipLevel 4.0
	#define cubeUV_minTileSize 16.0
	float getFace( vec3 direction ) {
		vec3 absDirection = abs( direction );
		float face = - 1.0;
		if ( absDirection.x > absDirection.z ) {
			if ( absDirection.x > absDirection.y )
				face = direction.x > 0.0 ? 0.0 : 3.0;
			else
				face = direction.y > 0.0 ? 1.0 : 4.0;
		} else {
			if ( absDirection.z > absDirection.y )
				face = direction.z > 0.0 ? 2.0 : 5.0;
			else
				face = direction.y > 0.0 ? 1.0 : 4.0;
		}
		return face;
	}
	vec2 getUV( vec3 direction, float face ) {
		vec2 uv;
		if ( face == 0.0 ) {
			uv = vec2( direction.z, direction.y ) / abs( direction.x );
		} else if ( face == 1.0 ) {
			uv = vec2( - direction.x, - direction.z ) / abs( direction.y );
		} else if ( face == 2.0 ) {
			uv = vec2( - direction.x, direction.y ) / abs( direction.z );
		} else if ( face == 3.0 ) {
			uv = vec2( - direction.z, direction.y ) / abs( direction.x );
		} else if ( face == 4.0 ) {
			uv = vec2( - direction.x, direction.z ) / abs( direction.y );
		} else {
			uv = vec2( direction.x, direction.y ) / abs( direction.z );
		}
		return 0.5 * ( uv + 1.0 );
	}
	vec3 bilinearCubeUV( sampler2D envMap, vec3 direction, float mipInt ) {
		float face = getFace( direction );
		float filterInt = max( cubeUV_minMipLevel - mipInt, 0.0 );
		mipInt = max( mipInt, cubeUV_minMipLevel );
		float faceSize = exp2( mipInt );
		highp vec2 uv = getUV( direction, face ) * ( faceSize - 2.0 ) + 1.0;
		if ( face > 2.0 ) {
			uv.y += faceSize;
			face -= 3.0;
		}
		uv.x += face * faceSize;
		uv.x += filterInt * 3.0 * cubeUV_minTileSize;
		uv.y += 4.0 * ( exp2( CUBEUV_MAX_MIP ) - faceSize );
		uv.x *= CUBEUV_TEXEL_WIDTH;
		uv.y *= CUBEUV_TEXEL_HEIGHT;
		#ifdef texture2DGradEXT
			return texture2DGradEXT( envMap, uv, vec2( 0.0 ), vec2( 0.0 ) ).rgb;
		#else
			return texture2D( envMap, uv ).rgb;
		#endif
	}
	#define cubeUV_r0 1.0
	#define cubeUV_m0 - 2.0
	#define cubeUV_r1 0.8
	#define cubeUV_m1 - 1.0
	#define cubeUV_r4 0.4
	#define cubeUV_m4 2.0
	#define cubeUV_r5 0.305
	#define cubeUV_m5 3.0
	#define cubeUV_r6 0.21
	#define cubeUV_m6 4.0
	float roughnessToMip( float roughness ) {
		float mip = 0.0;
		if ( roughness >= cubeUV_r1 ) {
			mip = ( cubeUV_r0 - roughness ) * ( cubeUV_m1 - cubeUV_m0 ) / ( cubeUV_r0 - cubeUV_r1 ) + cubeUV_m0;
		} else if ( roughness >= cubeUV_r4 ) {
			mip = ( cubeUV_r1 - roughness ) * ( cubeUV_m4 - cubeUV_m1 ) / ( cubeUV_r1 - cubeUV_r4 ) + cubeUV_m1;
		} else if ( roughness >= cubeUV_r5 ) {
			mip = ( cubeUV_r4 - roughness ) * ( cubeUV_m5 - cubeUV_m4 ) / ( cubeUV_r4 - cubeUV_r5 ) + cubeUV_m4;
		} else if ( roughness >= cubeUV_r6 ) {
			mip = ( cubeUV_r5 - roughness ) * ( cubeUV_m6 - cubeUV_m5 ) / ( cubeUV_r5 - cubeUV_r6 ) + cubeUV_m5;
		} else {
			mip = - 2.0 * log2( 1.16 * roughness );		}
		return mip;
	}
	vec4 textureCubeUV( sampler2D envMap, vec3 sampleDir, float roughness ) {
		float mip = clamp( roughnessToMip( roughness ), cubeUV_m0, CUBEUV_MAX_MIP );
		float mipF = fract( mip );
		float mipInt = floor( mip );
		vec3 color0 = bilinearCubeUV( envMap, sampleDir, mipInt );
		if ( mipF == 0.0 ) {
			return vec4( color0, 1.0 );
		} else {
			vec3 color1 = bilinearCubeUV( envMap, sampleDir, mipInt + 1.0 );
			return vec4( mix( color0, color1, mipF ), 1.0 );
		}
	}
#endif`,hb=`vec3 transformedNormal = objectNormal;
#ifdef USE_TANGENT
	vec3 transformedTangent = objectTangent;
#endif
#ifdef USE_BATCHING
	mat3 bm = mat3( batchingMatrix );
	transformedNormal /= vec3( dot( bm[ 0 ], bm[ 0 ] ), dot( bm[ 1 ], bm[ 1 ] ), dot( bm[ 2 ], bm[ 2 ] ) );
	transformedNormal = bm * transformedNormal;
	#ifdef USE_TANGENT
		transformedTangent = bm * transformedTangent;
	#endif
#endif
#ifdef USE_INSTANCING
	mat3 im = mat3( instanceMatrix );
	transformedNormal /= vec3( dot( im[ 0 ], im[ 0 ] ), dot( im[ 1 ], im[ 1 ] ), dot( im[ 2 ], im[ 2 ] ) );
	transformedNormal = im * transformedNormal;
	#ifdef USE_TANGENT
		transformedTangent = im * transformedTangent;
	#endif
#endif
transformedNormal = normalMatrix * transformedNormal;
#ifdef FLIP_SIDED
	transformedNormal = - transformedNormal;
#endif
#ifdef USE_TANGENT
	transformedTangent = ( modelViewMatrix * vec4( transformedTangent, 0.0 ) ).xyz;
	#ifdef FLIP_SIDED
		transformedTangent = - transformedTangent;
	#endif
#endif`,fb=`#ifdef USE_DISPLACEMENTMAP
	uniform sampler2D displacementMap;
	uniform float displacementScale;
	uniform float displacementBias;
#endif`,pb=`#ifdef USE_DISPLACEMENTMAP
	transformed += normalize( objectNormal ) * ( texture2D( displacementMap, vDisplacementMapUv ).x * displacementScale + displacementBias );
#endif`,mb=`#ifdef USE_EMISSIVEMAP
	vec4 emissiveColor = texture2D( emissiveMap, vEmissiveMapUv );
	#ifdef DECODE_VIDEO_TEXTURE_EMISSIVE
		emissiveColor = sRGBTransferEOTF( emissiveColor );
	#endif
	totalEmissiveRadiance *= emissiveColor.rgb;
#endif`,gb=`#ifdef USE_EMISSIVEMAP
	uniform sampler2D emissiveMap;
#endif`,vb="gl_FragColor = linearToOutputTexel( gl_FragColor );",_b=`vec4 LinearTransferOETF( in vec4 value ) {
	return value;
}
vec4 sRGBTransferEOTF( in vec4 value ) {
	return vec4( mix( pow( value.rgb * 0.9478672986 + vec3( 0.0521327014 ), vec3( 2.4 ) ), value.rgb * 0.0773993808, vec3( lessThanEqual( value.rgb, vec3( 0.04045 ) ) ) ), value.a );
}
vec4 sRGBTransferOETF( in vec4 value ) {
	return vec4( mix( pow( value.rgb, vec3( 0.41666 ) ) * 1.055 - vec3( 0.055 ), value.rgb * 12.92, vec3( lessThanEqual( value.rgb, vec3( 0.0031308 ) ) ) ), value.a );
}`,yb=`#ifdef USE_ENVMAP
	#ifdef ENV_WORLDPOS
		vec3 cameraToFrag;
		if ( isOrthographic ) {
			cameraToFrag = normalize( vec3( - viewMatrix[ 0 ][ 2 ], - viewMatrix[ 1 ][ 2 ], - viewMatrix[ 2 ][ 2 ] ) );
		} else {
			cameraToFrag = normalize( vWorldPosition - cameraPosition );
		}
		vec3 worldNormal = inverseTransformDirection( normal, viewMatrix );
		#ifdef ENVMAP_MODE_REFLECTION
			vec3 reflectVec = reflect( cameraToFrag, worldNormal );
		#else
			vec3 reflectVec = refract( cameraToFrag, worldNormal, refractionRatio );
		#endif
	#else
		vec3 reflectVec = vReflect;
	#endif
	#ifdef ENVMAP_TYPE_CUBE
		vec4 envColor = textureCube( envMap, envMapRotation * vec3( flipEnvMap * reflectVec.x, reflectVec.yz ) );
	#else
		vec4 envColor = vec4( 0.0 );
	#endif
	#ifdef ENVMAP_BLENDING_MULTIPLY
		outgoingLight = mix( outgoingLight, outgoingLight * envColor.xyz, specularStrength * reflectivity );
	#elif defined( ENVMAP_BLENDING_MIX )
		outgoingLight = mix( outgoingLight, envColor.xyz, specularStrength * reflectivity );
	#elif defined( ENVMAP_BLENDING_ADD )
		outgoingLight += envColor.xyz * specularStrength * reflectivity;
	#endif
#endif`,xb=`#ifdef USE_ENVMAP
	uniform float envMapIntensity;
	uniform float flipEnvMap;
	uniform mat3 envMapRotation;
	#ifdef ENVMAP_TYPE_CUBE
		uniform samplerCube envMap;
	#else
		uniform sampler2D envMap;
	#endif
	
#endif`,Sb=`#ifdef USE_ENVMAP
	uniform float reflectivity;
	#if defined( USE_BUMPMAP ) || defined( USE_NORMALMAP ) || defined( PHONG ) || defined( LAMBERT )
		#define ENV_WORLDPOS
	#endif
	#ifdef ENV_WORLDPOS
		varying vec3 vWorldPosition;
		uniform float refractionRatio;
	#else
		varying vec3 vReflect;
	#endif
#endif`,bb=`#ifdef USE_ENVMAP
	#if defined( USE_BUMPMAP ) || defined( USE_NORMALMAP ) || defined( PHONG ) || defined( LAMBERT )
		#define ENV_WORLDPOS
	#endif
	#ifdef ENV_WORLDPOS
		
		varying vec3 vWorldPosition;
	#else
		varying vec3 vReflect;
		uniform float refractionRatio;
	#endif
#endif`,Mb=`#ifdef USE_ENVMAP
	#ifdef ENV_WORLDPOS
		vWorldPosition = worldPosition.xyz;
	#else
		vec3 cameraToVertex;
		if ( isOrthographic ) {
			cameraToVertex = normalize( vec3( - viewMatrix[ 0 ][ 2 ], - viewMatrix[ 1 ][ 2 ], - viewMatrix[ 2 ][ 2 ] ) );
		} else {
			cameraToVertex = normalize( worldPosition.xyz - cameraPosition );
		}
		vec3 worldNormal = inverseTransformDirection( transformedNormal, viewMatrix );
		#ifdef ENVMAP_MODE_REFLECTION
			vReflect = reflect( cameraToVertex, worldNormal );
		#else
			vReflect = refract( cameraToVertex, worldNormal, refractionRatio );
		#endif
	#endif
#endif`,Eb=`#ifdef USE_FOG
	vFogDepth = - mvPosition.z;
#endif`,wb=`#ifdef USE_FOG
	varying float vFogDepth;
#endif`,Tb=`#ifdef USE_FOG
	#ifdef FOG_EXP2
		float fogFactor = 1.0 - exp( - fogDensity * fogDensity * vFogDepth * vFogDepth );
	#else
		float fogFactor = smoothstep( fogNear, fogFar, vFogDepth );
	#endif
	gl_FragColor.rgb = mix( gl_FragColor.rgb, fogColor, fogFactor );
#endif`,Rb=`#ifdef USE_FOG
	uniform vec3 fogColor;
	varying float vFogDepth;
	#ifdef FOG_EXP2
		uniform float fogDensity;
	#else
		uniform float fogNear;
		uniform float fogFar;
	#endif
#endif`,Cb=`#ifdef USE_GRADIENTMAP
	uniform sampler2D gradientMap;
#endif
vec3 getGradientIrradiance( vec3 normal, vec3 lightDirection ) {
	float dotNL = dot( normal, lightDirection );
	vec2 coord = vec2( dotNL * 0.5 + 0.5, 0.0 );
	#ifdef USE_GRADIENTMAP
		return vec3( texture2D( gradientMap, coord ).r );
	#else
		vec2 fw = fwidth( coord ) * 0.5;
		return mix( vec3( 0.7 ), vec3( 1.0 ), smoothstep( 0.7 - fw.x, 0.7 + fw.x, coord.x ) );
	#endif
}`,Ab=`#ifdef USE_LIGHTMAP
	uniform sampler2D lightMap;
	uniform float lightMapIntensity;
#endif`,Pb=`LambertMaterial material;
material.diffuseColor = diffuseColor.rgb;
material.specularStrength = specularStrength;`,Lb=`varying vec3 vViewPosition;
struct LambertMaterial {
	vec3 diffuseColor;
	float specularStrength;
};
void RE_Direct_Lambert( const in IncidentLight directLight, const in vec3 geometryPosition, const in vec3 geometryNormal, const in vec3 geometryViewDir, const in vec3 geometryClearcoatNormal, const in LambertMaterial material, inout ReflectedLight reflectedLight ) {
	float dotNL = saturate( dot( geometryNormal, directLight.direction ) );
	vec3 irradiance = dotNL * directLight.color;
	reflectedLight.directDiffuse += irradiance * BRDF_Lambert( material.diffuseColor );
}
void RE_IndirectDiffuse_Lambert( const in vec3 irradiance, const in vec3 geometryPosition, const in vec3 geometryNormal, const in vec3 geometryViewDir, const in vec3 geometryClearcoatNormal, const in LambertMaterial material, inout ReflectedLight reflectedLight ) {
	reflectedLight.indirectDiffuse += irradiance * BRDF_Lambert( material.diffuseColor );
}
#define RE_Direct				RE_Direct_Lambert
#define RE_IndirectDiffuse		RE_IndirectDiffuse_Lambert`,Ub=`uniform bool receiveShadow;
uniform vec3 ambientLightColor;
#if defined( USE_LIGHT_PROBES )
	uniform vec3 lightProbe[ 9 ];
#endif
vec3 shGetIrradianceAt( in vec3 normal, in vec3 shCoefficients[ 9 ] ) {
	float x = normal.x, y = normal.y, z = normal.z;
	vec3 result = shCoefficients[ 0 ] * 0.886227;
	result += shCoefficients[ 1 ] * 2.0 * 0.511664 * y;
	result += shCoefficients[ 2 ] * 2.0 * 0.511664 * z;
	result += shCoefficients[ 3 ] * 2.0 * 0.511664 * x;
	result += shCoefficients[ 4 ] * 2.0 * 0.429043 * x * y;
	result += shCoefficients[ 5 ] * 2.0 * 0.429043 * y * z;
	result += shCoefficients[ 6 ] * ( 0.743125 * z * z - 0.247708 );
	result += shCoefficients[ 7 ] * 2.0 * 0.429043 * x * z;
	result += shCoefficients[ 8 ] * 0.429043 * ( x * x - y * y );
	return result;
}
vec3 getLightProbeIrradiance( const in vec3 lightProbe[ 9 ], const in vec3 normal ) {
	vec3 worldNormal = inverseTransformDirection( normal, viewMatrix );
	vec3 irradiance = shGetIrradianceAt( worldNormal, lightProbe );
	return irradiance;
}
vec3 getAmbientLightIrradiance( const in vec3 ambientLightColor ) {
	vec3 irradiance = ambientLightColor;
	return irradiance;
}
float getDistanceAttenuation( const in float lightDistance, const in float cutoffDistance, const in float decayExponent ) {
	float distanceFalloff = 1.0 / max( pow( lightDistance, decayExponent ), 0.01 );
	if ( cutoffDistance > 0.0 ) {
		distanceFalloff *= pow2( saturate( 1.0 - pow4( lightDistance / cutoffDistance ) ) );
	}
	return distanceFalloff;
}
float getSpotAttenuation( const in float coneCosine, const in float penumbraCosine, const in float angleCosine ) {
	return smoothstep( coneCosine, penumbraCosine, angleCosine );
}
#if NUM_DIR_LIGHTS > 0
	struct DirectionalLight {
		vec3 direction;
		vec3 color;
	};
	uniform DirectionalLight directionalLights[ NUM_DIR_LIGHTS ];
	void getDirectionalLightInfo( const in DirectionalLight directionalLight, out IncidentLight light ) {
		light.color = directionalLight.color;
		light.direction = directionalLight.direction;
		light.visible = true;
	}
#endif
#if NUM_POINT_LIGHTS > 0
	struct PointLight {
		vec3 position;
		vec3 color;
		float distance;
		float decay;
	};
	uniform PointLight pointLights[ NUM_POINT_LIGHTS ];
	void getPointLightInfo( const in PointLight pointLight, const in vec3 geometryPosition, out IncidentLight light ) {
		vec3 lVector = pointLight.position - geometryPosition;
		light.direction = normalize( lVector );
		float lightDistance = length( lVector );
		light.color = pointLight.color;
		light.color *= getDistanceAttenuation( lightDistance, pointLight.distance, pointLight.decay );
		light.visible = ( light.color != vec3( 0.0 ) );
	}
#endif
#if NUM_SPOT_LIGHTS > 0
	struct SpotLight {
		vec3 position;
		vec3 direction;
		vec3 color;
		float distance;
		float decay;
		float coneCos;
		float penumbraCos;
	};
	uniform SpotLight spotLights[ NUM_SPOT_LIGHTS ];
	void getSpotLightInfo( const in SpotLight spotLight, const in vec3 geometryPosition, out IncidentLight light ) {
		vec3 lVector = spotLight.position - geometryPosition;
		light.direction = normalize( lVector );
		float angleCos = dot( light.direction, spotLight.direction );
		float spotAttenuation = getSpotAttenuation( spotLight.coneCos, spotLight.penumbraCos, angleCos );
		if ( spotAttenuation > 0.0 ) {
			float lightDistance = length( lVector );
			light.color = spotLight.color * spotAttenuation;
			light.color *= getDistanceAttenuation( lightDistance, spotLight.distance, spotLight.decay );
			light.visible = ( light.color != vec3( 0.0 ) );
		} else {
			light.color = vec3( 0.0 );
			light.visible = false;
		}
	}
#endif
#if NUM_RECT_AREA_LIGHTS > 0
	struct RectAreaLight {
		vec3 color;
		vec3 position;
		vec3 halfWidth;
		vec3 halfHeight;
	};
	uniform sampler2D ltc_1;	uniform sampler2D ltc_2;
	uniform RectAreaLight rectAreaLights[ NUM_RECT_AREA_LIGHTS ];
#endif
#if NUM_HEMI_LIGHTS > 0
	struct HemisphereLight {
		vec3 direction;
		vec3 skyColor;
		vec3 groundColor;
	};
	uniform HemisphereLight hemisphereLights[ NUM_HEMI_LIGHTS ];
	vec3 getHemisphereLightIrradiance( const in HemisphereLight hemiLight, const in vec3 normal ) {
		float dotNL = dot( normal, hemiLight.direction );
		float hemiDiffuseWeight = 0.5 * dotNL + 0.5;
		vec3 irradiance = mix( hemiLight.groundColor, hemiLight.skyColor, hemiDiffuseWeight );
		return irradiance;
	}
#endif`,Db=`#ifdef USE_ENVMAP
	vec3 getIBLIrradiance( const in vec3 normal ) {
		#ifdef ENVMAP_TYPE_CUBE_UV
			vec3 worldNormal = inverseTransformDirection( normal, viewMatrix );
			vec4 envMapColor = textureCubeUV( envMap, envMapRotation * worldNormal, 1.0 );
			return PI * envMapColor.rgb * envMapIntensity;
		#else
			return vec3( 0.0 );
		#endif
	}
	vec3 getIBLRadiance( const in vec3 viewDir, const in vec3 normal, const in float roughness ) {
		#ifdef ENVMAP_TYPE_CUBE_UV
			vec3 reflectVec = reflect( - viewDir, normal );
			reflectVec = normalize( mix( reflectVec, normal, roughness * roughness) );
			reflectVec = inverseTransformDirection( reflectVec, viewMatrix );
			vec4 envMapColor = textureCubeUV( envMap, envMapRotation * reflectVec, roughness );
			return envMapColor.rgb * envMapIntensity;
		#else
			return vec3( 0.0 );
		#endif
	}
	#ifdef USE_ANISOTROPY
		vec3 getIBLAnisotropyRadiance( const in vec3 viewDir, const in vec3 normal, const in float roughness, const in vec3 bitangent, const in float anisotropy ) {
			#ifdef ENVMAP_TYPE_CUBE_UV
				vec3 bentNormal = cross( bitangent, viewDir );
				bentNormal = normalize( cross( bentNormal, bitangent ) );
				bentNormal = normalize( mix( bentNormal, normal, pow2( pow2( 1.0 - anisotropy * ( 1.0 - roughness ) ) ) ) );
				return getIBLRadiance( viewDir, bentNormal, roughness );
			#else
				return vec3( 0.0 );
			#endif
		}
	#endif
#endif`,Ib=`ToonMaterial material;
material.diffuseColor = diffuseColor.rgb;`,Nb=`varying vec3 vViewPosition;
struct ToonMaterial {
	vec3 diffuseColor;
};
void RE_Direct_Toon( const in IncidentLight directLight, const in vec3 geometryPosition, const in vec3 geometryNormal, const in vec3 geometryViewDir, const in vec3 geometryClearcoatNormal, const in ToonMaterial material, inout ReflectedLight reflectedLight ) {
	vec3 irradiance = getGradientIrradiance( geometryNormal, directLight.direction ) * directLight.color;
	reflectedLight.directDiffuse += irradiance * BRDF_Lambert( material.diffuseColor );
}
void RE_IndirectDiffuse_Toon( const in vec3 irradiance, const in vec3 geometryPosition, const in vec3 geometryNormal, const in vec3 geometryViewDir, const in vec3 geometryClearcoatNormal, const in ToonMaterial material, inout ReflectedLight reflectedLight ) {
	reflectedLight.indirectDiffuse += irradiance * BRDF_Lambert( material.diffuseColor );
}
#define RE_Direct				RE_Direct_Toon
#define RE_IndirectDiffuse		RE_IndirectDiffuse_Toon`,Ob=`BlinnPhongMaterial material;
material.diffuseColor = diffuseColor.rgb;
material.specularColor = specular;
material.specularShininess = shininess;
material.specularStrength = specularStrength;`,kb=`varying vec3 vViewPosition;
struct BlinnPhongMaterial {
	vec3 diffuseColor;
	vec3 specularColor;
	float specularShininess;
	float specularStrength;
};
void RE_Direct_BlinnPhong( const in IncidentLight directLight, const in vec3 geometryPosition, const in vec3 geometryNormal, const in vec3 geometryViewDir, const in vec3 geometryClearcoatNormal, const in BlinnPhongMaterial material, inout ReflectedLight reflectedLight ) {
	float dotNL = saturate( dot( geometryNormal, directLight.direction ) );
	vec3 irradiance = dotNL * directLight.color;
	reflectedLight.directDiffuse += irradiance * BRDF_Lambert( material.diffuseColor );
	reflectedLight.directSpecular += irradiance * BRDF_BlinnPhong( directLight.direction, geometryViewDir, geometryNormal, material.specularColor, material.specularShininess ) * material.specularStrength;
}
void RE_IndirectDiffuse_BlinnPhong( const in vec3 irradiance, const in vec3 geometryPosition, const in vec3 geometryNormal, const in vec3 geometryViewDir, const in vec3 geometryClearcoatNormal, const in BlinnPhongMaterial material, inout ReflectedLight reflectedLight ) {
	reflectedLight.indirectDiffuse += irradiance * BRDF_Lambert( material.diffuseColor );
}
#define RE_Direct				RE_Direct_BlinnPhong
#define RE_IndirectDiffuse		RE_IndirectDiffuse_BlinnPhong`,Fb=`PhysicalMaterial material;
material.diffuseColor = diffuseColor.rgb * ( 1.0 - metalnessFactor );
vec3 dxy = max( abs( dFdx( nonPerturbedNormal ) ), abs( dFdy( nonPerturbedNormal ) ) );
float geometryRoughness = max( max( dxy.x, dxy.y ), dxy.z );
material.roughness = max( roughnessFactor, 0.0525 );material.roughness += geometryRoughness;
material.roughness = min( material.roughness, 1.0 );
#ifdef IOR
	material.ior = ior;
	#ifdef USE_SPECULAR
		float specularIntensityFactor = specularIntensity;
		vec3 specularColorFactor = specularColor;
		#ifdef USE_SPECULAR_COLORMAP
			specularColorFactor *= texture2D( specularColorMap, vSpecularColorMapUv ).rgb;
		#endif
		#ifdef USE_SPECULAR_INTENSITYMAP
			specularIntensityFactor *= texture2D( specularIntensityMap, vSpecularIntensityMapUv ).a;
		#endif
		material.specularF90 = mix( specularIntensityFactor, 1.0, metalnessFactor );
	#else
		float specularIntensityFactor = 1.0;
		vec3 specularColorFactor = vec3( 1.0 );
		material.specularF90 = 1.0;
	#endif
	material.specularColor = mix( min( pow2( ( material.ior - 1.0 ) / ( material.ior + 1.0 ) ) * specularColorFactor, vec3( 1.0 ) ) * specularIntensityFactor, diffuseColor.rgb, metalnessFactor );
#else
	material.specularColor = mix( vec3( 0.04 ), diffuseColor.rgb, metalnessFactor );
	material.specularF90 = 1.0;
#endif
#ifdef USE_CLEARCOAT
	material.clearcoat = clearcoat;
	material.clearcoatRoughness = clearcoatRoughness;
	material.clearcoatF0 = vec3( 0.04 );
	material.clearcoatF90 = 1.0;
	#ifdef USE_CLEARCOATMAP
		material.clearcoat *= texture2D( clearcoatMap, vClearcoatMapUv ).x;
	#endif
	#ifdef USE_CLEARCOAT_ROUGHNESSMAP
		material.clearcoatRoughness *= texture2D( clearcoatRoughnessMap, vClearcoatRoughnessMapUv ).y;
	#endif
	material.clearcoat = saturate( material.clearcoat );	material.clearcoatRoughness = max( material.clearcoatRoughness, 0.0525 );
	material.clearcoatRoughness += geometryRoughness;
	material.clearcoatRoughness = min( material.clearcoatRoughness, 1.0 );
#endif
#ifdef USE_DISPERSION
	material.dispersion = dispersion;
#endif
#ifdef USE_IRIDESCENCE
	material.iridescence = iridescence;
	material.iridescenceIOR = iridescenceIOR;
	#ifdef USE_IRIDESCENCEMAP
		material.iridescence *= texture2D( iridescenceMap, vIridescenceMapUv ).r;
	#endif
	#ifdef USE_IRIDESCENCE_THICKNESSMAP
		material.iridescenceThickness = (iridescenceThicknessMaximum - iridescenceThicknessMinimum) * texture2D( iridescenceThicknessMap, vIridescenceThicknessMapUv ).g + iridescenceThicknessMinimum;
	#else
		material.iridescenceThickness = iridescenceThicknessMaximum;
	#endif
#endif
#ifdef USE_SHEEN
	material.sheenColor = sheenColor;
	#ifdef USE_SHEEN_COLORMAP
		material.sheenColor *= texture2D( sheenColorMap, vSheenColorMapUv ).rgb;
	#endif
	material.sheenRoughness = clamp( sheenRoughness, 0.07, 1.0 );
	#ifdef USE_SHEEN_ROUGHNESSMAP
		material.sheenRoughness *= texture2D( sheenRoughnessMap, vSheenRoughnessMapUv ).a;
	#endif
#endif
#ifdef USE_ANISOTROPY
	#ifdef USE_ANISOTROPYMAP
		mat2 anisotropyMat = mat2( anisotropyVector.x, anisotropyVector.y, - anisotropyVector.y, anisotropyVector.x );
		vec3 anisotropyPolar = texture2D( anisotropyMap, vAnisotropyMapUv ).rgb;
		vec2 anisotropyV = anisotropyMat * normalize( 2.0 * anisotropyPolar.rg - vec2( 1.0 ) ) * anisotropyPolar.b;
	#else
		vec2 anisotropyV = anisotropyVector;
	#endif
	material.anisotropy = length( anisotropyV );
	if( material.anisotropy == 0.0 ) {
		anisotropyV = vec2( 1.0, 0.0 );
	} else {
		anisotropyV /= material.anisotropy;
		material.anisotropy = saturate( material.anisotropy );
	}
	material.alphaT = mix( pow2( material.roughness ), 1.0, pow2( material.anisotropy ) );
	material.anisotropyT = tbn[ 0 ] * anisotropyV.x + tbn[ 1 ] * anisotropyV.y;
	material.anisotropyB = tbn[ 1 ] * anisotropyV.x - tbn[ 0 ] * anisotropyV.y;
#endif`,zb=`struct PhysicalMaterial {
	vec3 diffuseColor;
	float roughness;
	vec3 specularColor;
	float specularF90;
	float dispersion;
	#ifdef USE_CLEARCOAT
		float clearcoat;
		float clearcoatRoughness;
		vec3 clearcoatF0;
		float clearcoatF90;
	#endif
	#ifdef USE_IRIDESCENCE
		float iridescence;
		float iridescenceIOR;
		float iridescenceThickness;
		vec3 iridescenceFresnel;
		vec3 iridescenceF0;
	#endif
	#ifdef USE_SHEEN
		vec3 sheenColor;
		float sheenRoughness;
	#endif
	#ifdef IOR
		float ior;
	#endif
	#ifdef USE_TRANSMISSION
		float transmission;
		float transmissionAlpha;
		float thickness;
		float attenuationDistance;
		vec3 attenuationColor;
	#endif
	#ifdef USE_ANISOTROPY
		float anisotropy;
		float alphaT;
		vec3 anisotropyT;
		vec3 anisotropyB;
	#endif
};
vec3 clearcoatSpecularDirect = vec3( 0.0 );
vec3 clearcoatSpecularIndirect = vec3( 0.0 );
vec3 sheenSpecularDirect = vec3( 0.0 );
vec3 sheenSpecularIndirect = vec3(0.0 );
vec3 Schlick_to_F0( const in vec3 f, const in float f90, const in float dotVH ) {
    float x = clamp( 1.0 - dotVH, 0.0, 1.0 );
    float x2 = x * x;
    float x5 = clamp( x * x2 * x2, 0.0, 0.9999 );
    return ( f - vec3( f90 ) * x5 ) / ( 1.0 - x5 );
}
float V_GGX_SmithCorrelated( const in float alpha, const in float dotNL, const in float dotNV ) {
	float a2 = pow2( alpha );
	float gv = dotNL * sqrt( a2 + ( 1.0 - a2 ) * pow2( dotNV ) );
	float gl = dotNV * sqrt( a2 + ( 1.0 - a2 ) * pow2( dotNL ) );
	return 0.5 / max( gv + gl, EPSILON );
}
float D_GGX( const in float alpha, const in float dotNH ) {
	float a2 = pow2( alpha );
	float denom = pow2( dotNH ) * ( a2 - 1.0 ) + 1.0;
	return RECIPROCAL_PI * a2 / pow2( denom );
}
#ifdef USE_ANISOTROPY
	float V_GGX_SmithCorrelated_Anisotropic( const in float alphaT, const in float alphaB, const in float dotTV, const in float dotBV, const in float dotTL, const in float dotBL, const in float dotNV, const in float dotNL ) {
		float gv = dotNL * length( vec3( alphaT * dotTV, alphaB * dotBV, dotNV ) );
		float gl = dotNV * length( vec3( alphaT * dotTL, alphaB * dotBL, dotNL ) );
		float v = 0.5 / ( gv + gl );
		return saturate(v);
	}
	float D_GGX_Anisotropic( const in float alphaT, const in float alphaB, const in float dotNH, const in float dotTH, const in float dotBH ) {
		float a2 = alphaT * alphaB;
		highp vec3 v = vec3( alphaB * dotTH, alphaT * dotBH, a2 * dotNH );
		highp float v2 = dot( v, v );
		float w2 = a2 / v2;
		return RECIPROCAL_PI * a2 * pow2 ( w2 );
	}
#endif
#ifdef USE_CLEARCOAT
	vec3 BRDF_GGX_Clearcoat( const in vec3 lightDir, const in vec3 viewDir, const in vec3 normal, const in PhysicalMaterial material) {
		vec3 f0 = material.clearcoatF0;
		float f90 = material.clearcoatF90;
		float roughness = material.clearcoatRoughness;
		float alpha = pow2( roughness );
		vec3 halfDir = normalize( lightDir + viewDir );
		float dotNL = saturate( dot( normal, lightDir ) );
		float dotNV = saturate( dot( normal, viewDir ) );
		float dotNH = saturate( dot( normal, halfDir ) );
		float dotVH = saturate( dot( viewDir, halfDir ) );
		vec3 F = F_Schlick( f0, f90, dotVH );
		float V = V_GGX_SmithCorrelated( alpha, dotNL, dotNV );
		float D = D_GGX( alpha, dotNH );
		return F * ( V * D );
	}
#endif
vec3 BRDF_GGX( const in vec3 lightDir, const in vec3 viewDir, const in vec3 normal, const in PhysicalMaterial material ) {
	vec3 f0 = material.specularColor;
	float f90 = material.specularF90;
	float roughness = material.roughness;
	float alpha = pow2( roughness );
	vec3 halfDir = normalize( lightDir + viewDir );
	float dotNL = saturate( dot( normal, lightDir ) );
	float dotNV = saturate( dot( normal, viewDir ) );
	float dotNH = saturate( dot( normal, halfDir ) );
	float dotVH = saturate( dot( viewDir, halfDir ) );
	vec3 F = F_Schlick( f0, f90, dotVH );
	#ifdef USE_IRIDESCENCE
		F = mix( F, material.iridescenceFresnel, material.iridescence );
	#endif
	#ifdef USE_ANISOTROPY
		float dotTL = dot( material.anisotropyT, lightDir );
		float dotTV = dot( material.anisotropyT, viewDir );
		float dotTH = dot( material.anisotropyT, halfDir );
		float dotBL = dot( material.anisotropyB, lightDir );
		float dotBV = dot( material.anisotropyB, viewDir );
		float dotBH = dot( material.anisotropyB, halfDir );
		float V = V_GGX_SmithCorrelated_Anisotropic( material.alphaT, alpha, dotTV, dotBV, dotTL, dotBL, dotNV, dotNL );
		float D = D_GGX_Anisotropic( material.alphaT, alpha, dotNH, dotTH, dotBH );
	#else
		float V = V_GGX_SmithCorrelated( alpha, dotNL, dotNV );
		float D = D_GGX( alpha, dotNH );
	#endif
	return F * ( V * D );
}
vec2 LTC_Uv( const in vec3 N, const in vec3 V, const in float roughness ) {
	const float LUT_SIZE = 64.0;
	const float LUT_SCALE = ( LUT_SIZE - 1.0 ) / LUT_SIZE;
	const float LUT_BIAS = 0.5 / LUT_SIZE;
	float dotNV = saturate( dot( N, V ) );
	vec2 uv = vec2( roughness, sqrt( 1.0 - dotNV ) );
	uv = uv * LUT_SCALE + LUT_BIAS;
	return uv;
}
float LTC_ClippedSphereFormFactor( const in vec3 f ) {
	float l = length( f );
	return max( ( l * l + f.z ) / ( l + 1.0 ), 0.0 );
}
vec3 LTC_EdgeVectorFormFactor( const in vec3 v1, const in vec3 v2 ) {
	float x = dot( v1, v2 );
	float y = abs( x );
	float a = 0.8543985 + ( 0.4965155 + 0.0145206 * y ) * y;
	float b = 3.4175940 + ( 4.1616724 + y ) * y;
	float v = a / b;
	float theta_sintheta = ( x > 0.0 ) ? v : 0.5 * inversesqrt( max( 1.0 - x * x, 1e-7 ) ) - v;
	return cross( v1, v2 ) * theta_sintheta;
}
vec3 LTC_Evaluate( const in vec3 N, const in vec3 V, const in vec3 P, const in mat3 mInv, const in vec3 rectCoords[ 4 ] ) {
	vec3 v1 = rectCoords[ 1 ] - rectCoords[ 0 ];
	vec3 v2 = rectCoords[ 3 ] - rectCoords[ 0 ];
	vec3 lightNormal = cross( v1, v2 );
	if( dot( lightNormal, P - rectCoords[ 0 ] ) < 0.0 ) return vec3( 0.0 );
	vec3 T1, T2;
	T1 = normalize( V - N * dot( V, N ) );
	T2 = - cross( N, T1 );
	mat3 mat = mInv * transposeMat3( mat3( T1, T2, N ) );
	vec3 coords[ 4 ];
	coords[ 0 ] = mat * ( rectCoords[ 0 ] - P );
	coords[ 1 ] = mat * ( rectCoords[ 1 ] - P );
	coords[ 2 ] = mat * ( rectCoords[ 2 ] - P );
	coords[ 3 ] = mat * ( rectCoords[ 3 ] - P );
	coords[ 0 ] = normalize( coords[ 0 ] );
	coords[ 1 ] = normalize( coords[ 1 ] );
	coords[ 2 ] = normalize( coords[ 2 ] );
	coords[ 3 ] = normalize( coords[ 3 ] );
	vec3 vectorFormFactor = vec3( 0.0 );
	vectorFormFactor += LTC_EdgeVectorFormFactor( coords[ 0 ], coords[ 1 ] );
	vectorFormFactor += LTC_EdgeVectorFormFactor( coords[ 1 ], coords[ 2 ] );
	vectorFormFactor += LTC_EdgeVectorFormFactor( coords[ 2 ], coords[ 3 ] );
	vectorFormFactor += LTC_EdgeVectorFormFactor( coords[ 3 ], coords[ 0 ] );
	float result = LTC_ClippedSphereFormFactor( vectorFormFactor );
	return vec3( result );
}
#if defined( USE_SHEEN )
float D_Charlie( float roughness, float dotNH ) {
	float alpha = pow2( roughness );
	float invAlpha = 1.0 / alpha;
	float cos2h = dotNH * dotNH;
	float sin2h = max( 1.0 - cos2h, 0.0078125 );
	return ( 2.0 + invAlpha ) * pow( sin2h, invAlpha * 0.5 ) / ( 2.0 * PI );
}
float V_Neubelt( float dotNV, float dotNL ) {
	return saturate( 1.0 / ( 4.0 * ( dotNL + dotNV - dotNL * dotNV ) ) );
}
vec3 BRDF_Sheen( const in vec3 lightDir, const in vec3 viewDir, const in vec3 normal, vec3 sheenColor, const in float sheenRoughness ) {
	vec3 halfDir = normalize( lightDir + viewDir );
	float dotNL = saturate( dot( normal, lightDir ) );
	float dotNV = saturate( dot( normal, viewDir ) );
	float dotNH = saturate( dot( normal, halfDir ) );
	float D = D_Charlie( sheenRoughness, dotNH );
	float V = V_Neubelt( dotNV, dotNL );
	return sheenColor * ( D * V );
}
#endif
float IBLSheenBRDF( const in vec3 normal, const in vec3 viewDir, const in float roughness ) {
	float dotNV = saturate( dot( normal, viewDir ) );
	float r2 = roughness * roughness;
	float a = roughness < 0.25 ? -339.2 * r2 + 161.4 * roughness - 25.9 : -8.48 * r2 + 14.3 * roughness - 9.95;
	float b = roughness < 0.25 ? 44.0 * r2 - 23.7 * roughness + 3.26 : 1.97 * r2 - 3.27 * roughness + 0.72;
	float DG = exp( a * dotNV + b ) + ( roughness < 0.25 ? 0.0 : 0.1 * ( roughness - 0.25 ) );
	return saturate( DG * RECIPROCAL_PI );
}
vec2 DFGApprox( const in vec3 normal, const in vec3 viewDir, const in float roughness ) {
	float dotNV = saturate( dot( normal, viewDir ) );
	const vec4 c0 = vec4( - 1, - 0.0275, - 0.572, 0.022 );
	const vec4 c1 = vec4( 1, 0.0425, 1.04, - 0.04 );
	vec4 r = roughness * c0 + c1;
	float a004 = min( r.x * r.x, exp2( - 9.28 * dotNV ) ) * r.x + r.y;
	vec2 fab = vec2( - 1.04, 1.04 ) * a004 + r.zw;
	return fab;
}
vec3 EnvironmentBRDF( const in vec3 normal, const in vec3 viewDir, const in vec3 specularColor, const in float specularF90, const in float roughness ) {
	vec2 fab = DFGApprox( normal, viewDir, roughness );
	return specularColor * fab.x + specularF90 * fab.y;
}
#ifdef USE_IRIDESCENCE
void computeMultiscatteringIridescence( const in vec3 normal, const in vec3 viewDir, const in vec3 specularColor, const in float specularF90, const in float iridescence, const in vec3 iridescenceF0, const in float roughness, inout vec3 singleScatter, inout vec3 multiScatter ) {
#else
void computeMultiscattering( const in vec3 normal, const in vec3 viewDir, const in vec3 specularColor, const in float specularF90, const in float roughness, inout vec3 singleScatter, inout vec3 multiScatter ) {
#endif
	vec2 fab = DFGApprox( normal, viewDir, roughness );
	#ifdef USE_IRIDESCENCE
		vec3 Fr = mix( specularColor, iridescenceF0, iridescence );
	#else
		vec3 Fr = specularColor;
	#endif
	vec3 FssEss = Fr * fab.x + specularF90 * fab.y;
	float Ess = fab.x + fab.y;
	float Ems = 1.0 - Ess;
	vec3 Favg = Fr + ( 1.0 - Fr ) * 0.047619;	vec3 Fms = FssEss * Favg / ( 1.0 - Ems * Favg );
	singleScatter += FssEss;
	multiScatter += Fms * Ems;
}
#if NUM_RECT_AREA_LIGHTS > 0
	void RE_Direct_RectArea_Physical( const in RectAreaLight rectAreaLight, const in vec3 geometryPosition, const in vec3 geometryNormal, const in vec3 geometryViewDir, const in vec3 geometryClearcoatNormal, const in PhysicalMaterial material, inout ReflectedLight reflectedLight ) {
		vec3 normal = geometryNormal;
		vec3 viewDir = geometryViewDir;
		vec3 position = geometryPosition;
		vec3 lightPos = rectAreaLight.position;
		vec3 halfWidth = rectAreaLight.halfWidth;
		vec3 halfHeight = rectAreaLight.halfHeight;
		vec3 lightColor = rectAreaLight.color;
		float roughness = material.roughness;
		vec3 rectCoords[ 4 ];
		rectCoords[ 0 ] = lightPos + halfWidth - halfHeight;		rectCoords[ 1 ] = lightPos - halfWidth - halfHeight;
		rectCoords[ 2 ] = lightPos - halfWidth + halfHeight;
		rectCoords[ 3 ] = lightPos + halfWidth + halfHeight;
		vec2 uv = LTC_Uv( normal, viewDir, roughness );
		vec4 t1 = texture2D( ltc_1, uv );
		vec4 t2 = texture2D( ltc_2, uv );
		mat3 mInv = mat3(
			vec3( t1.x, 0, t1.y ),
			vec3(    0, 1,    0 ),
			vec3( t1.z, 0, t1.w )
		);
		vec3 fresnel = ( material.specularColor * t2.x + ( vec3( 1.0 ) - material.specularColor ) * t2.y );
		reflectedLight.directSpecular += lightColor * fresnel * LTC_Evaluate( normal, viewDir, position, mInv, rectCoords );
		reflectedLight.directDiffuse += lightColor * material.diffuseColor * LTC_Evaluate( normal, viewDir, position, mat3( 1.0 ), rectCoords );
	}
#endif
void RE_Direct_Physical( const in IncidentLight directLight, const in vec3 geometryPosition, const in vec3 geometryNormal, const in vec3 geometryViewDir, const in vec3 geometryClearcoatNormal, const in PhysicalMaterial material, inout ReflectedLight reflectedLight ) {
	float dotNL = saturate( dot( geometryNormal, directLight.direction ) );
	vec3 irradiance = dotNL * directLight.color;
	#ifdef USE_CLEARCOAT
		float dotNLcc = saturate( dot( geometryClearcoatNormal, directLight.direction ) );
		vec3 ccIrradiance = dotNLcc * directLight.color;
		clearcoatSpecularDirect += ccIrradiance * BRDF_GGX_Clearcoat( directLight.direction, geometryViewDir, geometryClearcoatNormal, material );
	#endif
	#ifdef USE_SHEEN
		sheenSpecularDirect += irradiance * BRDF_Sheen( directLight.direction, geometryViewDir, geometryNormal, material.sheenColor, material.sheenRoughness );
	#endif
	reflectedLight.directSpecular += irradiance * BRDF_GGX( directLight.direction, geometryViewDir, geometryNormal, material );
	reflectedLight.directDiffuse += irradiance * BRDF_Lambert( material.diffuseColor );
}
void RE_IndirectDiffuse_Physical( const in vec3 irradiance, const in vec3 geometryPosition, const in vec3 geometryNormal, const in vec3 geometryViewDir, const in vec3 geometryClearcoatNormal, const in PhysicalMaterial material, inout ReflectedLight reflectedLight ) {
	reflectedLight.indirectDiffuse += irradiance * BRDF_Lambert( material.diffuseColor );
}
void RE_IndirectSpecular_Physical( const in vec3 radiance, const in vec3 irradiance, const in vec3 clearcoatRadiance, const in vec3 geometryPosition, const in vec3 geometryNormal, const in vec3 geometryViewDir, const in vec3 geometryClearcoatNormal, const in PhysicalMaterial material, inout ReflectedLight reflectedLight) {
	#ifdef USE_CLEARCOAT
		clearcoatSpecularIndirect += clearcoatRadiance * EnvironmentBRDF( geometryClearcoatNormal, geometryViewDir, material.clearcoatF0, material.clearcoatF90, material.clearcoatRoughness );
	#endif
	#ifdef USE_SHEEN
		sheenSpecularIndirect += irradiance * material.sheenColor * IBLSheenBRDF( geometryNormal, geometryViewDir, material.sheenRoughness );
	#endif
	vec3 singleScattering = vec3( 0.0 );
	vec3 multiScattering = vec3( 0.0 );
	vec3 cosineWeightedIrradiance = irradiance * RECIPROCAL_PI;
	#ifdef USE_IRIDESCENCE
		computeMultiscatteringIridescence( geometryNormal, geometryViewDir, material.specularColor, material.specularF90, material.iridescence, material.iridescenceFresnel, material.roughness, singleScattering, multiScattering );
	#else
		computeMultiscattering( geometryNormal, geometryViewDir, material.specularColor, material.specularF90, material.roughness, singleScattering, multiScattering );
	#endif
	vec3 totalScattering = singleScattering + multiScattering;
	vec3 diffuse = material.diffuseColor * ( 1.0 - max( max( totalScattering.r, totalScattering.g ), totalScattering.b ) );
	reflectedLight.indirectSpecular += radiance * singleScattering;
	reflectedLight.indirectSpecular += multiScattering * cosineWeightedIrradiance;
	reflectedLight.indirectDiffuse += diffuse * cosineWeightedIrradiance;
}
#define RE_Direct				RE_Direct_Physical
#define RE_Direct_RectArea		RE_Direct_RectArea_Physical
#define RE_IndirectDiffuse		RE_IndirectDiffuse_Physical
#define RE_IndirectSpecular		RE_IndirectSpecular_Physical
float computeSpecularOcclusion( const in float dotNV, const in float ambientOcclusion, const in float roughness ) {
	return saturate( pow( dotNV + ambientOcclusion, exp2( - 16.0 * roughness - 1.0 ) ) - 1.0 + ambientOcclusion );
}`,Bb=`
vec3 geometryPosition = - vViewPosition;
vec3 geometryNormal = normal;
vec3 geometryViewDir = ( isOrthographic ) ? vec3( 0, 0, 1 ) : normalize( vViewPosition );
vec3 geometryClearcoatNormal = vec3( 0.0 );
#ifdef USE_CLEARCOAT
	geometryClearcoatNormal = clearcoatNormal;
#endif
#ifdef USE_IRIDESCENCE
	float dotNVi = saturate( dot( normal, geometryViewDir ) );
	if ( material.iridescenceThickness == 0.0 ) {
		material.iridescence = 0.0;
	} else {
		material.iridescence = saturate( material.iridescence );
	}
	if ( material.iridescence > 0.0 ) {
		material.iridescenceFresnel = evalIridescence( 1.0, material.iridescenceIOR, dotNVi, material.iridescenceThickness, material.specularColor );
		material.iridescenceF0 = Schlick_to_F0( material.iridescenceFresnel, 1.0, dotNVi );
	}
#endif
IncidentLight directLight;
#if ( NUM_POINT_LIGHTS > 0 ) && defined( RE_Direct )
	PointLight pointLight;
	#if defined( USE_SHADOWMAP ) && NUM_POINT_LIGHT_SHADOWS > 0
	PointLightShadow pointLightShadow;
	#endif
	#pragma unroll_loop_start
	for ( int i = 0; i < NUM_POINT_LIGHTS; i ++ ) {
		pointLight = pointLights[ i ];
		getPointLightInfo( pointLight, geometryPosition, directLight );
		#if defined( USE_SHADOWMAP ) && ( UNROLLED_LOOP_INDEX < NUM_POINT_LIGHT_SHADOWS )
		pointLightShadow = pointLightShadows[ i ];
		directLight.color *= ( directLight.visible && receiveShadow ) ? getPointShadow( pointShadowMap[ i ], pointLightShadow.shadowMapSize, pointLightShadow.shadowIntensity, pointLightShadow.shadowBias, pointLightShadow.shadowRadius, vPointShadowCoord[ i ], pointLightShadow.shadowCameraNear, pointLightShadow.shadowCameraFar ) : 1.0;
		#endif
		RE_Direct( directLight, geometryPosition, geometryNormal, geometryViewDir, geometryClearcoatNormal, material, reflectedLight );
	}
	#pragma unroll_loop_end
#endif
#if ( NUM_SPOT_LIGHTS > 0 ) && defined( RE_Direct )
	SpotLight spotLight;
	vec4 spotColor;
	vec3 spotLightCoord;
	bool inSpotLightMap;
	#if defined( USE_SHADOWMAP ) && NUM_SPOT_LIGHT_SHADOWS > 0
	SpotLightShadow spotLightShadow;
	#endif
	#pragma unroll_loop_start
	for ( int i = 0; i < NUM_SPOT_LIGHTS; i ++ ) {
		spotLight = spotLights[ i ];
		getSpotLightInfo( spotLight, geometryPosition, directLight );
		#if ( UNROLLED_LOOP_INDEX < NUM_SPOT_LIGHT_SHADOWS_WITH_MAPS )
		#define SPOT_LIGHT_MAP_INDEX UNROLLED_LOOP_INDEX
		#elif ( UNROLLED_LOOP_INDEX < NUM_SPOT_LIGHT_SHADOWS )
		#define SPOT_LIGHT_MAP_INDEX NUM_SPOT_LIGHT_MAPS
		#else
		#define SPOT_LIGHT_MAP_INDEX ( UNROLLED_LOOP_INDEX - NUM_SPOT_LIGHT_SHADOWS + NUM_SPOT_LIGHT_SHADOWS_WITH_MAPS )
		#endif
		#if ( SPOT_LIGHT_MAP_INDEX < NUM_SPOT_LIGHT_MAPS )
			spotLightCoord = vSpotLightCoord[ i ].xyz / vSpotLightCoord[ i ].w;
			inSpotLightMap = all( lessThan( abs( spotLightCoord * 2. - 1. ), vec3( 1.0 ) ) );
			spotColor = texture2D( spotLightMap[ SPOT_LIGHT_MAP_INDEX ], spotLightCoord.xy );
			directLight.color = inSpotLightMap ? directLight.color * spotColor.rgb : directLight.color;
		#endif
		#undef SPOT_LIGHT_MAP_INDEX
		#if defined( USE_SHADOWMAP ) && ( UNROLLED_LOOP_INDEX < NUM_SPOT_LIGHT_SHADOWS )
		spotLightShadow = spotLightShadows[ i ];
		directLight.color *= ( directLight.visible && receiveShadow ) ? getShadow( spotShadowMap[ i ], spotLightShadow.shadowMapSize, spotLightShadow.shadowIntensity, spotLightShadow.shadowBias, spotLightShadow.shadowRadius, vSpotLightCoord[ i ] ) : 1.0;
		#endif
		RE_Direct( directLight, geometryPosition, geometryNormal, geometryViewDir, geometryClearcoatNormal, material, reflectedLight );
	}
	#pragma unroll_loop_end
#endif
#if ( NUM_DIR_LIGHTS > 0 ) && defined( RE_Direct )
	DirectionalLight directionalLight;
	#if defined( USE_SHADOWMAP ) && NUM_DIR_LIGHT_SHADOWS > 0
	DirectionalLightShadow directionalLightShadow;
	#endif
	#pragma unroll_loop_start
	for ( int i = 0; i < NUM_DIR_LIGHTS; i ++ ) {
		directionalLight = directionalLights[ i ];
		getDirectionalLightInfo( directionalLight, directLight );
		#if defined( USE_SHADOWMAP ) && ( UNROLLED_LOOP_INDEX < NUM_DIR_LIGHT_SHADOWS )
		directionalLightShadow = directionalLightShadows[ i ];
		directLight.color *= ( directLight.visible && receiveShadow ) ? getShadow( directionalShadowMap[ i ], directionalLightShadow.shadowMapSize, directionalLightShadow.shadowIntensity, directionalLightShadow.shadowBias, directionalLightShadow.shadowRadius, vDirectionalShadowCoord[ i ] ) : 1.0;
		#endif
		RE_Direct( directLight, geometryPosition, geometryNormal, geometryViewDir, geometryClearcoatNormal, material, reflectedLight );
	}
	#pragma unroll_loop_end
#endif
#if ( NUM_RECT_AREA_LIGHTS > 0 ) && defined( RE_Direct_RectArea )
	RectAreaLight rectAreaLight;
	#pragma unroll_loop_start
	for ( int i = 0; i < NUM_RECT_AREA_LIGHTS; i ++ ) {
		rectAreaLight = rectAreaLights[ i ];
		RE_Direct_RectArea( rectAreaLight, geometryPosition, geometryNormal, geometryViewDir, geometryClearcoatNormal, material, reflectedLight );
	}
	#pragma unroll_loop_end
#endif
#if defined( RE_IndirectDiffuse )
	vec3 iblIrradiance = vec3( 0.0 );
	vec3 irradiance = getAmbientLightIrradiance( ambientLightColor );
	#if defined( USE_LIGHT_PROBES )
		irradiance += getLightProbeIrradiance( lightProbe, geometryNormal );
	#endif
	#if ( NUM_HEMI_LIGHTS > 0 )
		#pragma unroll_loop_start
		for ( int i = 0; i < NUM_HEMI_LIGHTS; i ++ ) {
			irradiance += getHemisphereLightIrradiance( hemisphereLights[ i ], geometryNormal );
		}
		#pragma unroll_loop_end
	#endif
#endif
#if defined( RE_IndirectSpecular )
	vec3 radiance = vec3( 0.0 );
	vec3 clearcoatRadiance = vec3( 0.0 );
#endif`,Hb=`#if defined( RE_IndirectDiffuse )
	#ifdef USE_LIGHTMAP
		vec4 lightMapTexel = texture2D( lightMap, vLightMapUv );
		vec3 lightMapIrradiance = lightMapTexel.rgb * lightMapIntensity;
		irradiance += lightMapIrradiance;
	#endif
	#if defined( USE_ENVMAP ) && defined( STANDARD ) && defined( ENVMAP_TYPE_CUBE_UV )
		iblIrradiance += getIBLIrradiance( geometryNormal );
	#endif
#endif
#if defined( USE_ENVMAP ) && defined( RE_IndirectSpecular )
	#ifdef USE_ANISOTROPY
		radiance += getIBLAnisotropyRadiance( geometryViewDir, geometryNormal, material.roughness, material.anisotropyB, material.anisotropy );
	#else
		radiance += getIBLRadiance( geometryViewDir, geometryNormal, material.roughness );
	#endif
	#ifdef USE_CLEARCOAT
		clearcoatRadiance += getIBLRadiance( geometryViewDir, geometryClearcoatNormal, material.clearcoatRoughness );
	#endif
#endif`,Vb=`#if defined( RE_IndirectDiffuse )
	RE_IndirectDiffuse( irradiance, geometryPosition, geometryNormal, geometryViewDir, geometryClearcoatNormal, material, reflectedLight );
#endif
#if defined( RE_IndirectSpecular )
	RE_IndirectSpecular( radiance, iblIrradiance, clearcoatRadiance, geometryPosition, geometryNormal, geometryViewDir, geometryClearcoatNormal, material, reflectedLight );
#endif`,Gb=`#if defined( USE_LOGDEPTHBUF )
	gl_FragDepth = vIsPerspective == 0.0 ? gl_FragCoord.z : log2( vFragDepth ) * logDepthBufFC * 0.5;
#endif`,Wb=`#if defined( USE_LOGDEPTHBUF )
	uniform float logDepthBufFC;
	varying float vFragDepth;
	varying float vIsPerspective;
#endif`,jb=`#ifdef USE_LOGDEPTHBUF
	varying float vFragDepth;
	varying float vIsPerspective;
#endif`,Xb=`#ifdef USE_LOGDEPTHBUF
	vFragDepth = 1.0 + gl_Position.w;
	vIsPerspective = float( isPerspectiveMatrix( projectionMatrix ) );
#endif`,Yb=`#ifdef USE_MAP
	vec4 sampledDiffuseColor = texture2D( map, vMapUv );
	#ifdef DECODE_VIDEO_TEXTURE
		sampledDiffuseColor = sRGBTransferEOTF( sampledDiffuseColor );
	#endif
	diffuseColor *= sampledDiffuseColor;
#endif`,qb=`#ifdef USE_MAP
	uniform sampler2D map;
#endif`,Qb=`#if defined( USE_MAP ) || defined( USE_ALPHAMAP )
	#if defined( USE_POINTS_UV )
		vec2 uv = vUv;
	#else
		vec2 uv = ( uvTransform * vec3( gl_PointCoord.x, 1.0 - gl_PointCoord.y, 1 ) ).xy;
	#endif
#endif
#ifdef USE_MAP
	diffuseColor *= texture2D( map, uv );
#endif
#ifdef USE_ALPHAMAP
	diffuseColor.a *= texture2D( alphaMap, uv ).g;
#endif`,$b=`#if defined( USE_POINTS_UV )
	varying vec2 vUv;
#else
	#if defined( USE_MAP ) || defined( USE_ALPHAMAP )
		uniform mat3 uvTransform;
	#endif
#endif
#ifdef USE_MAP
	uniform sampler2D map;
#endif
#ifdef USE_ALPHAMAP
	uniform sampler2D alphaMap;
#endif`,Kb=`float metalnessFactor = metalness;
#ifdef USE_METALNESSMAP
	vec4 texelMetalness = texture2D( metalnessMap, vMetalnessMapUv );
	metalnessFactor *= texelMetalness.b;
#endif`,Zb=`#ifdef USE_METALNESSMAP
	uniform sampler2D metalnessMap;
#endif`,Jb=`#ifdef USE_INSTANCING_MORPH
	float morphTargetInfluences[ MORPHTARGETS_COUNT ];
	float morphTargetBaseInfluence = texelFetch( morphTexture, ivec2( 0, gl_InstanceID ), 0 ).r;
	for ( int i = 0; i < MORPHTARGETS_COUNT; i ++ ) {
		morphTargetInfluences[i] =  texelFetch( morphTexture, ivec2( i + 1, gl_InstanceID ), 0 ).r;
	}
#endif`,eM=`#if defined( USE_MORPHCOLORS )
	vColor *= morphTargetBaseInfluence;
	for ( int i = 0; i < MORPHTARGETS_COUNT; i ++ ) {
		#if defined( USE_COLOR_ALPHA )
			if ( morphTargetInfluences[ i ] != 0.0 ) vColor += getMorph( gl_VertexID, i, 2 ) * morphTargetInfluences[ i ];
		#elif defined( USE_COLOR )
			if ( morphTargetInfluences[ i ] != 0.0 ) vColor += getMorph( gl_VertexID, i, 2 ).rgb * morphTargetInfluences[ i ];
		#endif
	}
#endif`,tM=`#ifdef USE_MORPHNORMALS
	objectNormal *= morphTargetBaseInfluence;
	for ( int i = 0; i < MORPHTARGETS_COUNT; i ++ ) {
		if ( morphTargetInfluences[ i ] != 0.0 ) objectNormal += getMorph( gl_VertexID, i, 1 ).xyz * morphTargetInfluences[ i ];
	}
#endif`,rM=`#ifdef USE_MORPHTARGETS
	#ifndef USE_INSTANCING_MORPH
		uniform float morphTargetBaseInfluence;
		uniform float morphTargetInfluences[ MORPHTARGETS_COUNT ];
	#endif
	uniform sampler2DArray morphTargetsTexture;
	uniform ivec2 morphTargetsTextureSize;
	vec4 getMorph( const in int vertexIndex, const in int morphTargetIndex, const in int offset ) {
		int texelIndex = vertexIndex * MORPHTARGETS_TEXTURE_STRIDE + offset;
		int y = texelIndex / morphTargetsTextureSize.x;
		int x = texelIndex - y * morphTargetsTextureSize.x;
		ivec3 morphUV = ivec3( x, y, morphTargetIndex );
		return texelFetch( morphTargetsTexture, morphUV, 0 );
	}
#endif`,iM=`#ifdef USE_MORPHTARGETS
	transformed *= morphTargetBaseInfluence;
	for ( int i = 0; i < MORPHTARGETS_COUNT; i ++ ) {
		if ( morphTargetInfluences[ i ] != 0.0 ) transformed += getMorph( gl_VertexID, i, 0 ).xyz * morphTargetInfluences[ i ];
	}
#endif`,nM=`float faceDirection = gl_FrontFacing ? 1.0 : - 1.0;
#ifdef FLAT_SHADED
	vec3 fdx = dFdx( vViewPosition );
	vec3 fdy = dFdy( vViewPosition );
	vec3 normal = normalize( cross( fdx, fdy ) );
#else
	vec3 normal = normalize( vNormal );
	#ifdef DOUBLE_SIDED
		normal *= faceDirection;
	#endif
#endif
#if defined( USE_NORMALMAP_TANGENTSPACE ) || defined( USE_CLEARCOAT_NORMALMAP ) || defined( USE_ANISOTROPY )
	#ifdef USE_TANGENT
		mat3 tbn = mat3( normalize( vTangent ), normalize( vBitangent ), normal );
	#else
		mat3 tbn = getTangentFrame( - vViewPosition, normal,
		#if defined( USE_NORMALMAP )
			vNormalMapUv
		#elif defined( USE_CLEARCOAT_NORMALMAP )
			vClearcoatNormalMapUv
		#else
			vUv
		#endif
		);
	#endif
	#if defined( DOUBLE_SIDED ) && ! defined( FLAT_SHADED )
		tbn[0] *= faceDirection;
		tbn[1] *= faceDirection;
	#endif
#endif
#ifdef USE_CLEARCOAT_NORMALMAP
	#ifdef USE_TANGENT
		mat3 tbn2 = mat3( normalize( vTangent ), normalize( vBitangent ), normal );
	#else
		mat3 tbn2 = getTangentFrame( - vViewPosition, normal, vClearcoatNormalMapUv );
	#endif
	#if defined( DOUBLE_SIDED ) && ! defined( FLAT_SHADED )
		tbn2[0] *= faceDirection;
		tbn2[1] *= faceDirection;
	#endif
#endif
vec3 nonPerturbedNormal = normal;`,aM=`#ifdef USE_NORMALMAP_OBJECTSPACE
	normal = texture2D( normalMap, vNormalMapUv ).xyz * 2.0 - 1.0;
	#ifdef FLIP_SIDED
		normal = - normal;
	#endif
	#ifdef DOUBLE_SIDED
		normal = normal * faceDirection;
	#endif
	normal = normalize( normalMatrix * normal );
#elif defined( USE_NORMALMAP_TANGENTSPACE )
	vec3 mapN = texture2D( normalMap, vNormalMapUv ).xyz * 2.0 - 1.0;
	mapN.xy *= normalScale;
	normal = normalize( tbn * mapN );
#elif defined( USE_BUMPMAP )
	normal = perturbNormalArb( - vViewPosition, normal, dHdxy_fwd(), faceDirection );
#endif`,sM=`#ifndef FLAT_SHADED
	varying vec3 vNormal;
	#ifdef USE_TANGENT
		varying vec3 vTangent;
		varying vec3 vBitangent;
	#endif
#endif`,oM=`#ifndef FLAT_SHADED
	varying vec3 vNormal;
	#ifdef USE_TANGENT
		varying vec3 vTangent;
		varying vec3 vBitangent;
	#endif
#endif`,lM=`#ifndef FLAT_SHADED
	vNormal = normalize( transformedNormal );
	#ifdef USE_TANGENT
		vTangent = normalize( transformedTangent );
		vBitangent = normalize( cross( vNormal, vTangent ) * tangent.w );
	#endif
#endif`,cM=`#ifdef USE_NORMALMAP
	uniform sampler2D normalMap;
	uniform vec2 normalScale;
#endif
#ifdef USE_NORMALMAP_OBJECTSPACE
	uniform mat3 normalMatrix;
#endif
#if ! defined ( USE_TANGENT ) && ( defined ( USE_NORMALMAP_TANGENTSPACE ) || defined ( USE_CLEARCOAT_NORMALMAP ) || defined( USE_ANISOTROPY ) )
	mat3 getTangentFrame( vec3 eye_pos, vec3 surf_norm, vec2 uv ) {
		vec3 q0 = dFdx( eye_pos.xyz );
		vec3 q1 = dFdy( eye_pos.xyz );
		vec2 st0 = dFdx( uv.st );
		vec2 st1 = dFdy( uv.st );
		vec3 N = surf_norm;
		vec3 q1perp = cross( q1, N );
		vec3 q0perp = cross( N, q0 );
		vec3 T = q1perp * st0.x + q0perp * st1.x;
		vec3 B = q1perp * st0.y + q0perp * st1.y;
		float det = max( dot( T, T ), dot( B, B ) );
		float scale = ( det == 0.0 ) ? 0.0 : inversesqrt( det );
		return mat3( T * scale, B * scale, N );
	}
#endif`,uM=`#ifdef USE_CLEARCOAT
	vec3 clearcoatNormal = nonPerturbedNormal;
#endif`,dM=`#ifdef USE_CLEARCOAT_NORMALMAP
	vec3 clearcoatMapN = texture2D( clearcoatNormalMap, vClearcoatNormalMapUv ).xyz * 2.0 - 1.0;
	clearcoatMapN.xy *= clearcoatNormalScale;
	clearcoatNormal = normalize( tbn2 * clearcoatMapN );
#endif`,hM=`#ifdef USE_CLEARCOATMAP
	uniform sampler2D clearcoatMap;
#endif
#ifdef USE_CLEARCOAT_NORMALMAP
	uniform sampler2D clearcoatNormalMap;
	uniform vec2 clearcoatNormalScale;
#endif
#ifdef USE_CLEARCOAT_ROUGHNESSMAP
	uniform sampler2D clearcoatRoughnessMap;
#endif`,fM=`#ifdef USE_IRIDESCENCEMAP
	uniform sampler2D iridescenceMap;
#endif
#ifdef USE_IRIDESCENCE_THICKNESSMAP
	uniform sampler2D iridescenceThicknessMap;
#endif`,pM=`#ifdef OPAQUE
diffuseColor.a = 1.0;
#endif
#ifdef USE_TRANSMISSION
diffuseColor.a *= material.transmissionAlpha;
#endif
gl_FragColor = vec4( outgoingLight, diffuseColor.a );`,mM=`vec3 packNormalToRGB( const in vec3 normal ) {
	return normalize( normal ) * 0.5 + 0.5;
}
vec3 unpackRGBToNormal( const in vec3 rgb ) {
	return 2.0 * rgb.xyz - 1.0;
}
const float PackUpscale = 256. / 255.;const float UnpackDownscale = 255. / 256.;const float ShiftRight8 = 1. / 256.;
const float Inv255 = 1. / 255.;
const vec4 PackFactors = vec4( 1.0, 256.0, 256.0 * 256.0, 256.0 * 256.0 * 256.0 );
const vec2 UnpackFactors2 = vec2( UnpackDownscale, 1.0 / PackFactors.g );
const vec3 UnpackFactors3 = vec3( UnpackDownscale / PackFactors.rg, 1.0 / PackFactors.b );
const vec4 UnpackFactors4 = vec4( UnpackDownscale / PackFactors.rgb, 1.0 / PackFactors.a );
vec4 packDepthToRGBA( const in float v ) {
	if( v <= 0.0 )
		return vec4( 0., 0., 0., 0. );
	if( v >= 1.0 )
		return vec4( 1., 1., 1., 1. );
	float vuf;
	float af = modf( v * PackFactors.a, vuf );
	float bf = modf( vuf * ShiftRight8, vuf );
	float gf = modf( vuf * ShiftRight8, vuf );
	return vec4( vuf * Inv255, gf * PackUpscale, bf * PackUpscale, af );
}
vec3 packDepthToRGB( const in float v ) {
	if( v <= 0.0 )
		return vec3( 0., 0., 0. );
	if( v >= 1.0 )
		return vec3( 1., 1., 1. );
	float vuf;
	float bf = modf( v * PackFactors.b, vuf );
	float gf = modf( vuf * ShiftRight8, vuf );
	return vec3( vuf * Inv255, gf * PackUpscale, bf );
}
vec2 packDepthToRG( const in float v ) {
	if( v <= 0.0 )
		return vec2( 0., 0. );
	if( v >= 1.0 )
		return vec2( 1., 1. );
	float vuf;
	float gf = modf( v * 256., vuf );
	return vec2( vuf * Inv255, gf );
}
float unpackRGBAToDepth( const in vec4 v ) {
	return dot( v, UnpackFactors4 );
}
float unpackRGBToDepth( const in vec3 v ) {
	return dot( v, UnpackFactors3 );
}
float unpackRGToDepth( const in vec2 v ) {
	return v.r * UnpackFactors2.r + v.g * UnpackFactors2.g;
}
vec4 pack2HalfToRGBA( const in vec2 v ) {
	vec4 r = vec4( v.x, fract( v.x * 255.0 ), v.y, fract( v.y * 255.0 ) );
	return vec4( r.x - r.y / 255.0, r.y, r.z - r.w / 255.0, r.w );
}
vec2 unpackRGBATo2Half( const in vec4 v ) {
	return vec2( v.x + ( v.y / 255.0 ), v.z + ( v.w / 255.0 ) );
}
float viewZToOrthographicDepth( const in float viewZ, const in float near, const in float far ) {
	return ( viewZ + near ) / ( near - far );
}
float orthographicDepthToViewZ( const in float depth, const in float near, const in float far ) {
	return depth * ( near - far ) - near;
}
float viewZToPerspectiveDepth( const in float viewZ, const in float near, const in float far ) {
	return ( ( near + viewZ ) * far ) / ( ( far - near ) * viewZ );
}
float perspectiveDepthToViewZ( const in float depth, const in float near, const in float far ) {
	return ( near * far ) / ( ( far - near ) * depth - far );
}`,gM=`#ifdef PREMULTIPLIED_ALPHA
	gl_FragColor.rgb *= gl_FragColor.a;
#endif`,vM=`vec4 mvPosition = vec4( transformed, 1.0 );
#ifdef USE_BATCHING
	mvPosition = batchingMatrix * mvPosition;
#endif
#ifdef USE_INSTANCING
	mvPosition = instanceMatrix * mvPosition;
#endif
mvPosition = modelViewMatrix * mvPosition;
gl_Position = projectionMatrix * mvPosition;`,_M=`#ifdef DITHERING
	gl_FragColor.rgb = dithering( gl_FragColor.rgb );
#endif`,yM=`#ifdef DITHERING
	vec3 dithering( vec3 color ) {
		float grid_position = rand( gl_FragCoord.xy );
		vec3 dither_shift_RGB = vec3( 0.25 / 255.0, -0.25 / 255.0, 0.25 / 255.0 );
		dither_shift_RGB = mix( 2.0 * dither_shift_RGB, -2.0 * dither_shift_RGB, grid_position );
		return color + dither_shift_RGB;
	}
#endif`,xM=`float roughnessFactor = roughness;
#ifdef USE_ROUGHNESSMAP
	vec4 texelRoughness = texture2D( roughnessMap, vRoughnessMapUv );
	roughnessFactor *= texelRoughness.g;
#endif`,SM=`#ifdef USE_ROUGHNESSMAP
	uniform sampler2D roughnessMap;
#endif`,bM=`#if NUM_SPOT_LIGHT_COORDS > 0
	varying vec4 vSpotLightCoord[ NUM_SPOT_LIGHT_COORDS ];
#endif
#if NUM_SPOT_LIGHT_MAPS > 0
	uniform sampler2D spotLightMap[ NUM_SPOT_LIGHT_MAPS ];
#endif
#ifdef USE_SHADOWMAP
	#if NUM_DIR_LIGHT_SHADOWS > 0
		uniform sampler2D directionalShadowMap[ NUM_DIR_LIGHT_SHADOWS ];
		varying vec4 vDirectionalShadowCoord[ NUM_DIR_LIGHT_SHADOWS ];
		struct DirectionalLightShadow {
			float shadowIntensity;
			float shadowBias;
			float shadowNormalBias;
			float shadowRadius;
			vec2 shadowMapSize;
		};
		uniform DirectionalLightShadow directionalLightShadows[ NUM_DIR_LIGHT_SHADOWS ];
	#endif
	#if NUM_SPOT_LIGHT_SHADOWS > 0
		uniform sampler2D spotShadowMap[ NUM_SPOT_LIGHT_SHADOWS ];
		struct SpotLightShadow {
			float shadowIntensity;
			float shadowBias;
			float shadowNormalBias;
			float shadowRadius;
			vec2 shadowMapSize;
		};
		uniform SpotLightShadow spotLightShadows[ NUM_SPOT_LIGHT_SHADOWS ];
	#endif
	#if NUM_POINT_LIGHT_SHADOWS > 0
		uniform sampler2D pointShadowMap[ NUM_POINT_LIGHT_SHADOWS ];
		varying vec4 vPointShadowCoord[ NUM_POINT_LIGHT_SHADOWS ];
		struct PointLightShadow {
			float shadowIntensity;
			float shadowBias;
			float shadowNormalBias;
			float shadowRadius;
			vec2 shadowMapSize;
			float shadowCameraNear;
			float shadowCameraFar;
		};
		uniform PointLightShadow pointLightShadows[ NUM_POINT_LIGHT_SHADOWS ];
	#endif
	float texture2DCompare( sampler2D depths, vec2 uv, float compare ) {
		return step( compare, unpackRGBAToDepth( texture2D( depths, uv ) ) );
	}
	vec2 texture2DDistribution( sampler2D shadow, vec2 uv ) {
		return unpackRGBATo2Half( texture2D( shadow, uv ) );
	}
	float VSMShadow (sampler2D shadow, vec2 uv, float compare ){
		float occlusion = 1.0;
		vec2 distribution = texture2DDistribution( shadow, uv );
		float hard_shadow = step( compare , distribution.x );
		if (hard_shadow != 1.0 ) {
			float distance = compare - distribution.x ;
			float variance = max( 0.00000, distribution.y * distribution.y );
			float softness_probability = variance / (variance + distance * distance );			softness_probability = clamp( ( softness_probability - 0.3 ) / ( 0.95 - 0.3 ), 0.0, 1.0 );			occlusion = clamp( max( hard_shadow, softness_probability ), 0.0, 1.0 );
		}
		return occlusion;
	}
	float getShadow( sampler2D shadowMap, vec2 shadowMapSize, float shadowIntensity, float shadowBias, float shadowRadius, vec4 shadowCoord ) {
		float shadow = 1.0;
		shadowCoord.xyz /= shadowCoord.w;
		shadowCoord.z += shadowBias;
		bool inFrustum = shadowCoord.x >= 0.0 && shadowCoord.x <= 1.0 && shadowCoord.y >= 0.0 && shadowCoord.y <= 1.0;
		bool frustumTest = inFrustum && shadowCoord.z <= 1.0;
		if ( frustumTest ) {
		#if defined( SHADOWMAP_TYPE_PCF )
			vec2 texelSize = vec2( 1.0 ) / shadowMapSize;
			float dx0 = - texelSize.x * shadowRadius;
			float dy0 = - texelSize.y * shadowRadius;
			float dx1 = + texelSize.x * shadowRadius;
			float dy1 = + texelSize.y * shadowRadius;
			float dx2 = dx0 / 2.0;
			float dy2 = dy0 / 2.0;
			float dx3 = dx1 / 2.0;
			float dy3 = dy1 / 2.0;
			shadow = (
				texture2DCompare( shadowMap, shadowCoord.xy + vec2( dx0, dy0 ), shadowCoord.z ) +
				texture2DCompare( shadowMap, shadowCoord.xy + vec2( 0.0, dy0 ), shadowCoord.z ) +
				texture2DCompare( shadowMap, shadowCoord.xy + vec2( dx1, dy0 ), shadowCoord.z ) +
				texture2DCompare( shadowMap, shadowCoord.xy + vec2( dx2, dy2 ), shadowCoord.z ) +
				texture2DCompare( shadowMap, shadowCoord.xy + vec2( 0.0, dy2 ), shadowCoord.z ) +
				texture2DCompare( shadowMap, shadowCoord.xy + vec2( dx3, dy2 ), shadowCoord.z ) +
				texture2DCompare( shadowMap, shadowCoord.xy + vec2( dx0, 0.0 ), shadowCoord.z ) +
				texture2DCompare( shadowMap, shadowCoord.xy + vec2( dx2, 0.0 ), shadowCoord.z ) +
				texture2DCompare( shadowMap, shadowCoord.xy, shadowCoord.z ) +
				texture2DCompare( shadowMap, shadowCoord.xy + vec2( dx3, 0.0 ), shadowCoord.z ) +
				texture2DCompare( shadowMap, shadowCoord.xy + vec2( dx1, 0.0 ), shadowCoord.z ) +
				texture2DCompare( shadowMap, shadowCoord.xy + vec2( dx2, dy3 ), shadowCoord.z ) +
				texture2DCompare( shadowMap, shadowCoord.xy + vec2( 0.0, dy3 ), shadowCoord.z ) +
				texture2DCompare( shadowMap, shadowCoord.xy + vec2( dx3, dy3 ), shadowCoord.z ) +
				texture2DCompare( shadowMap, shadowCoord.xy + vec2( dx0, dy1 ), shadowCoord.z ) +
				texture2DCompare( shadowMap, shadowCoord.xy + vec2( 0.0, dy1 ), shadowCoord.z ) +
				texture2DCompare( shadowMap, shadowCoord.xy + vec2( dx1, dy1 ), shadowCoord.z )
			) * ( 1.0 / 17.0 );
		#elif defined( SHADOWMAP_TYPE_PCF_SOFT )
			vec2 texelSize = vec2( 1.0 ) / shadowMapSize;
			float dx = texelSize.x;
			float dy = texelSize.y;
			vec2 uv = shadowCoord.xy;
			vec2 f = fract( uv * shadowMapSize + 0.5 );
			uv -= f * texelSize;
			shadow = (
				texture2DCompare( shadowMap, uv, shadowCoord.z ) +
				texture2DCompare( shadowMap, uv + vec2( dx, 0.0 ), shadowCoord.z ) +
				texture2DCompare( shadowMap, uv + vec2( 0.0, dy ), shadowCoord.z ) +
				texture2DCompare( shadowMap, uv + texelSize, shadowCoord.z ) +
				mix( texture2DCompare( shadowMap, uv + vec2( -dx, 0.0 ), shadowCoord.z ),
					 texture2DCompare( shadowMap, uv + vec2( 2.0 * dx, 0.0 ), shadowCoord.z ),
					 f.x ) +
				mix( texture2DCompare( shadowMap, uv + vec2( -dx, dy ), shadowCoord.z ),
					 texture2DCompare( shadowMap, uv + vec2( 2.0 * dx, dy ), shadowCoord.z ),
					 f.x ) +
				mix( texture2DCompare( shadowMap, uv + vec2( 0.0, -dy ), shadowCoord.z ),
					 texture2DCompare( shadowMap, uv + vec2( 0.0, 2.0 * dy ), shadowCoord.z ),
					 f.y ) +
				mix( texture2DCompare( shadowMap, uv + vec2( dx, -dy ), shadowCoord.z ),
					 texture2DCompare( shadowMap, uv + vec2( dx, 2.0 * dy ), shadowCoord.z ),
					 f.y ) +
				mix( mix( texture2DCompare( shadowMap, uv + vec2( -dx, -dy ), shadowCoord.z ),
						  texture2DCompare( shadowMap, uv + vec2( 2.0 * dx, -dy ), shadowCoord.z ),
						  f.x ),
					 mix( texture2DCompare( shadowMap, uv + vec2( -dx, 2.0 * dy ), shadowCoord.z ),
						  texture2DCompare( shadowMap, uv + vec2( 2.0 * dx, 2.0 * dy ), shadowCoord.z ),
						  f.x ),
					 f.y )
			) * ( 1.0 / 9.0 );
		#elif defined( SHADOWMAP_TYPE_VSM )
			shadow = VSMShadow( shadowMap, shadowCoord.xy, shadowCoord.z );
		#else
			shadow = texture2DCompare( shadowMap, shadowCoord.xy, shadowCoord.z );
		#endif
		}
		return mix( 1.0, shadow, shadowIntensity );
	}
	vec2 cubeToUV( vec3 v, float texelSizeY ) {
		vec3 absV = abs( v );
		float scaleToCube = 1.0 / max( absV.x, max( absV.y, absV.z ) );
		absV *= scaleToCube;
		v *= scaleToCube * ( 1.0 - 2.0 * texelSizeY );
		vec2 planar = v.xy;
		float almostATexel = 1.5 * texelSizeY;
		float almostOne = 1.0 - almostATexel;
		if ( absV.z >= almostOne ) {
			if ( v.z > 0.0 )
				planar.x = 4.0 - v.x;
		} else if ( absV.x >= almostOne ) {
			float signX = sign( v.x );
			planar.x = v.z * signX + 2.0 * signX;
		} else if ( absV.y >= almostOne ) {
			float signY = sign( v.y );
			planar.x = v.x + 2.0 * signY + 2.0;
			planar.y = v.z * signY - 2.0;
		}
		return vec2( 0.125, 0.25 ) * planar + vec2( 0.375, 0.75 );
	}
	float getPointShadow( sampler2D shadowMap, vec2 shadowMapSize, float shadowIntensity, float shadowBias, float shadowRadius, vec4 shadowCoord, float shadowCameraNear, float shadowCameraFar ) {
		float shadow = 1.0;
		vec3 lightToPosition = shadowCoord.xyz;
		
		float lightToPositionLength = length( lightToPosition );
		if ( lightToPositionLength - shadowCameraFar <= 0.0 && lightToPositionLength - shadowCameraNear >= 0.0 ) {
			float dp = ( lightToPositionLength - shadowCameraNear ) / ( shadowCameraFar - shadowCameraNear );			dp += shadowBias;
			vec3 bd3D = normalize( lightToPosition );
			vec2 texelSize = vec2( 1.0 ) / ( shadowMapSize * vec2( 4.0, 2.0 ) );
			#if defined( SHADOWMAP_TYPE_PCF ) || defined( SHADOWMAP_TYPE_PCF_SOFT ) || defined( SHADOWMAP_TYPE_VSM )
				vec2 offset = vec2( - 1, 1 ) * shadowRadius * texelSize.y;
				shadow = (
					texture2DCompare( shadowMap, cubeToUV( bd3D + offset.xyy, texelSize.y ), dp ) +
					texture2DCompare( shadowMap, cubeToUV( bd3D + offset.yyy, texelSize.y ), dp ) +
					texture2DCompare( shadowMap, cubeToUV( bd3D + offset.xyx, texelSize.y ), dp ) +
					texture2DCompare( shadowMap, cubeToUV( bd3D + offset.yyx, texelSize.y ), dp ) +
					texture2DCompare( shadowMap, cubeToUV( bd3D, texelSize.y ), dp ) +
					texture2DCompare( shadowMap, cubeToUV( bd3D + offset.xxy, texelSize.y ), dp ) +
					texture2DCompare( shadowMap, cubeToUV( bd3D + offset.yxy, texelSize.y ), dp ) +
					texture2DCompare( shadowMap, cubeToUV( bd3D + offset.xxx, texelSize.y ), dp ) +
					texture2DCompare( shadowMap, cubeToUV( bd3D + offset.yxx, texelSize.y ), dp )
				) * ( 1.0 / 9.0 );
			#else
				shadow = texture2DCompare( shadowMap, cubeToUV( bd3D, texelSize.y ), dp );
			#endif
		}
		return mix( 1.0, shadow, shadowIntensity );
	}
#endif`,MM=`#if NUM_SPOT_LIGHT_COORDS > 0
	uniform mat4 spotLightMatrix[ NUM_SPOT_LIGHT_COORDS ];
	varying vec4 vSpotLightCoord[ NUM_SPOT_LIGHT_COORDS ];
#endif
#ifdef USE_SHADOWMAP
	#if NUM_DIR_LIGHT_SHADOWS > 0
		uniform mat4 directionalShadowMatrix[ NUM_DIR_LIGHT_SHADOWS ];
		varying vec4 vDirectionalShadowCoord[ NUM_DIR_LIGHT_SHADOWS ];
		struct DirectionalLightShadow {
			float shadowIntensity;
			float shadowBias;
			float shadowNormalBias;
			float shadowRadius;
			vec2 shadowMapSize;
		};
		uniform DirectionalLightShadow directionalLightShadows[ NUM_DIR_LIGHT_SHADOWS ];
	#endif
	#if NUM_SPOT_LIGHT_SHADOWS > 0
		struct SpotLightShadow {
			float shadowIntensity;
			float shadowBias;
			float shadowNormalBias;
			float shadowRadius;
			vec2 shadowMapSize;
		};
		uniform SpotLightShadow spotLightShadows[ NUM_SPOT_LIGHT_SHADOWS ];
	#endif
	#if NUM_POINT_LIGHT_SHADOWS > 0
		uniform mat4 pointShadowMatrix[ NUM_POINT_LIGHT_SHADOWS ];
		varying vec4 vPointShadowCoord[ NUM_POINT_LIGHT_SHADOWS ];
		struct PointLightShadow {
			float shadowIntensity;
			float shadowBias;
			float shadowNormalBias;
			float shadowRadius;
			vec2 shadowMapSize;
			float shadowCameraNear;
			float shadowCameraFar;
		};
		uniform PointLightShadow pointLightShadows[ NUM_POINT_LIGHT_SHADOWS ];
	#endif
#endif`,EM=`#if ( defined( USE_SHADOWMAP ) && ( NUM_DIR_LIGHT_SHADOWS > 0 || NUM_POINT_LIGHT_SHADOWS > 0 ) ) || ( NUM_SPOT_LIGHT_COORDS > 0 )
	vec3 shadowWorldNormal = inverseTransformDirection( transformedNormal, viewMatrix );
	vec4 shadowWorldPosition;
#endif
#if defined( USE_SHADOWMAP )
	#if NUM_DIR_LIGHT_SHADOWS > 0
		#pragma unroll_loop_start
		for ( int i = 0; i < NUM_DIR_LIGHT_SHADOWS; i ++ ) {
			shadowWorldPosition = worldPosition + vec4( shadowWorldNormal * directionalLightShadows[ i ].shadowNormalBias, 0 );
			vDirectionalShadowCoord[ i ] = directionalShadowMatrix[ i ] * shadowWorldPosition;
		}
		#pragma unroll_loop_end
	#endif
	#if NUM_POINT_LIGHT_SHADOWS > 0
		#pragma unroll_loop_start
		for ( int i = 0; i < NUM_POINT_LIGHT_SHADOWS; i ++ ) {
			shadowWorldPosition = worldPosition + vec4( shadowWorldNormal * pointLightShadows[ i ].shadowNormalBias, 0 );
			vPointShadowCoord[ i ] = pointShadowMatrix[ i ] * shadowWorldPosition;
		}
		#pragma unroll_loop_end
	#endif
#endif
#if NUM_SPOT_LIGHT_COORDS > 0
	#pragma unroll_loop_start
	for ( int i = 0; i < NUM_SPOT_LIGHT_COORDS; i ++ ) {
		shadowWorldPosition = worldPosition;
		#if ( defined( USE_SHADOWMAP ) && UNROLLED_LOOP_INDEX < NUM_SPOT_LIGHT_SHADOWS )
			shadowWorldPosition.xyz += shadowWorldNormal * spotLightShadows[ i ].shadowNormalBias;
		#endif
		vSpotLightCoord[ i ] = spotLightMatrix[ i ] * shadowWorldPosition;
	}
	#pragma unroll_loop_end
#endif`,wM=`float getShadowMask() {
	float shadow = 1.0;
	#ifdef USE_SHADOWMAP
	#if NUM_DIR_LIGHT_SHADOWS > 0
	DirectionalLightShadow directionalLight;
	#pragma unroll_loop_start
	for ( int i = 0; i < NUM_DIR_LIGHT_SHADOWS; i ++ ) {
		directionalLight = directionalLightShadows[ i ];
		shadow *= receiveShadow ? getShadow( directionalShadowMap[ i ], directionalLight.shadowMapSize, directionalLight.shadowIntensity, directionalLight.shadowBias, directionalLight.shadowRadius, vDirectionalShadowCoord[ i ] ) : 1.0;
	}
	#pragma unroll_loop_end
	#endif
	#if NUM_SPOT_LIGHT_SHADOWS > 0
	SpotLightShadow spotLight;
	#pragma unroll_loop_start
	for ( int i = 0; i < NUM_SPOT_LIGHT_SHADOWS; i ++ ) {
		spotLight = spotLightShadows[ i ];
		shadow *= receiveShadow ? getShadow( spotShadowMap[ i ], spotLight.shadowMapSize, spotLight.shadowIntensity, spotLight.shadowBias, spotLight.shadowRadius, vSpotLightCoord[ i ] ) : 1.0;
	}
	#pragma unroll_loop_end
	#endif
	#if NUM_POINT_LIGHT_SHADOWS > 0
	PointLightShadow pointLight;
	#pragma unroll_loop_start
	for ( int i = 0; i < NUM_POINT_LIGHT_SHADOWS; i ++ ) {
		pointLight = pointLightShadows[ i ];
		shadow *= receiveShadow ? getPointShadow( pointShadowMap[ i ], pointLight.shadowMapSize, pointLight.shadowIntensity, pointLight.shadowBias, pointLight.shadowRadius, vPointShadowCoord[ i ], pointLight.shadowCameraNear, pointLight.shadowCameraFar ) : 1.0;
	}
	#pragma unroll_loop_end
	#endif
	#endif
	return shadow;
}`,TM=`#ifdef USE_SKINNING
	mat4 boneMatX = getBoneMatrix( skinIndex.x );
	mat4 boneMatY = getBoneMatrix( skinIndex.y );
	mat4 boneMatZ = getBoneMatrix( skinIndex.z );
	mat4 boneMatW = getBoneMatrix( skinIndex.w );
#endif`,RM=`#ifdef USE_SKINNING
	uniform mat4 bindMatrix;
	uniform mat4 bindMatrixInverse;
	uniform highp sampler2D boneTexture;
	mat4 getBoneMatrix( const in float i ) {
		int size = textureSize( boneTexture, 0 ).x;
		int j = int( i ) * 4;
		int x = j % size;
		int y = j / size;
		vec4 v1 = texelFetch( boneTexture, ivec2( x, y ), 0 );
		vec4 v2 = texelFetch( boneTexture, ivec2( x + 1, y ), 0 );
		vec4 v3 = texelFetch( boneTexture, ivec2( x + 2, y ), 0 );
		vec4 v4 = texelFetch( boneTexture, ivec2( x + 3, y ), 0 );
		return mat4( v1, v2, v3, v4 );
	}
#endif`,CM=`#ifdef USE_SKINNING
	vec4 skinVertex = bindMatrix * vec4( transformed, 1.0 );
	vec4 skinned = vec4( 0.0 );
	skinned += boneMatX * skinVertex * skinWeight.x;
	skinned += boneMatY * skinVertex * skinWeight.y;
	skinned += boneMatZ * skinVertex * skinWeight.z;
	skinned += boneMatW * skinVertex * skinWeight.w;
	transformed = ( bindMatrixInverse * skinned ).xyz;
#endif`,AM=`#ifdef USE_SKINNING
	mat4 skinMatrix = mat4( 0.0 );
	skinMatrix += skinWeight.x * boneMatX;
	skinMatrix += skinWeight.y * boneMatY;
	skinMatrix += skinWeight.z * boneMatZ;
	skinMatrix += skinWeight.w * boneMatW;
	skinMatrix = bindMatrixInverse * skinMatrix * bindMatrix;
	objectNormal = vec4( skinMatrix * vec4( objectNormal, 0.0 ) ).xyz;
	#ifdef USE_TANGENT
		objectTangent = vec4( skinMatrix * vec4( objectTangent, 0.0 ) ).xyz;
	#endif
#endif`,PM=`float specularStrength;
#ifdef USE_SPECULARMAP
	vec4 texelSpecular = texture2D( specularMap, vSpecularMapUv );
	specularStrength = texelSpecular.r;
#else
	specularStrength = 1.0;
#endif`,LM=`#ifdef USE_SPECULARMAP
	uniform sampler2D specularMap;
#endif`,UM=`#if defined( TONE_MAPPING )
	gl_FragColor.rgb = toneMapping( gl_FragColor.rgb );
#endif`,DM=`#ifndef saturate
#define saturate( a ) clamp( a, 0.0, 1.0 )
#endif
uniform float toneMappingExposure;
vec3 LinearToneMapping( vec3 color ) {
	return saturate( toneMappingExposure * color );
}
vec3 ReinhardToneMapping( vec3 color ) {
	color *= toneMappingExposure;
	return saturate( color / ( vec3( 1.0 ) + color ) );
}
vec3 CineonToneMapping( vec3 color ) {
	color *= toneMappingExposure;
	color = max( vec3( 0.0 ), color - 0.004 );
	return pow( ( color * ( 6.2 * color + 0.5 ) ) / ( color * ( 6.2 * color + 1.7 ) + 0.06 ), vec3( 2.2 ) );
}
vec3 RRTAndODTFit( vec3 v ) {
	vec3 a = v * ( v + 0.0245786 ) - 0.000090537;
	vec3 b = v * ( 0.983729 * v + 0.4329510 ) + 0.238081;
	return a / b;
}
vec3 ACESFilmicToneMapping( vec3 color ) {
	const mat3 ACESInputMat = mat3(
		vec3( 0.59719, 0.07600, 0.02840 ),		vec3( 0.35458, 0.90834, 0.13383 ),
		vec3( 0.04823, 0.01566, 0.83777 )
	);
	const mat3 ACESOutputMat = mat3(
		vec3(  1.60475, -0.10208, -0.00327 ),		vec3( -0.53108,  1.10813, -0.07276 ),
		vec3( -0.07367, -0.00605,  1.07602 )
	);
	color *= toneMappingExposure / 0.6;
	color = ACESInputMat * color;
	color = RRTAndODTFit( color );
	color = ACESOutputMat * color;
	return saturate( color );
}
const mat3 LINEAR_REC2020_TO_LINEAR_SRGB = mat3(
	vec3( 1.6605, - 0.1246, - 0.0182 ),
	vec3( - 0.5876, 1.1329, - 0.1006 ),
	vec3( - 0.0728, - 0.0083, 1.1187 )
);
const mat3 LINEAR_SRGB_TO_LINEAR_REC2020 = mat3(
	vec3( 0.6274, 0.0691, 0.0164 ),
	vec3( 0.3293, 0.9195, 0.0880 ),
	vec3( 0.0433, 0.0113, 0.8956 )
);
vec3 agxDefaultContrastApprox( vec3 x ) {
	vec3 x2 = x * x;
	vec3 x4 = x2 * x2;
	return + 15.5 * x4 * x2
		- 40.14 * x4 * x
		+ 31.96 * x4
		- 6.868 * x2 * x
		+ 0.4298 * x2
		+ 0.1191 * x
		- 0.00232;
}
vec3 AgXToneMapping( vec3 color ) {
	const mat3 AgXInsetMatrix = mat3(
		vec3( 0.856627153315983, 0.137318972929847, 0.11189821299995 ),
		vec3( 0.0951212405381588, 0.761241990602591, 0.0767994186031903 ),
		vec3( 0.0482516061458583, 0.101439036467562, 0.811302368396859 )
	);
	const mat3 AgXOutsetMatrix = mat3(
		vec3( 1.1271005818144368, - 0.1413297634984383, - 0.14132976349843826 ),
		vec3( - 0.11060664309660323, 1.157823702216272, - 0.11060664309660294 ),
		vec3( - 0.016493938717834573, - 0.016493938717834257, 1.2519364065950405 )
	);
	const float AgxMinEv = - 12.47393;	const float AgxMaxEv = 4.026069;
	color *= toneMappingExposure;
	color = LINEAR_SRGB_TO_LINEAR_REC2020 * color;
	color = AgXInsetMatrix * color;
	color = max( color, 1e-10 );	color = log2( color );
	color = ( color - AgxMinEv ) / ( AgxMaxEv - AgxMinEv );
	color = clamp( color, 0.0, 1.0 );
	color = agxDefaultContrastApprox( color );
	color = AgXOutsetMatrix * color;
	color = pow( max( vec3( 0.0 ), color ), vec3( 2.2 ) );
	color = LINEAR_REC2020_TO_LINEAR_SRGB * color;
	color = clamp( color, 0.0, 1.0 );
	return color;
}
vec3 NeutralToneMapping( vec3 color ) {
	const float StartCompression = 0.8 - 0.04;
	const float Desaturation = 0.15;
	color *= toneMappingExposure;
	float x = min( color.r, min( color.g, color.b ) );
	float offset = x < 0.08 ? x - 6.25 * x * x : 0.04;
	color -= offset;
	float peak = max( color.r, max( color.g, color.b ) );
	if ( peak < StartCompression ) return color;
	float d = 1. - StartCompression;
	float newPeak = 1. - d * d / ( peak + d - StartCompression );
	color *= newPeak / peak;
	float g = 1. - 1. / ( Desaturation * ( peak - newPeak ) + 1. );
	return mix( color, vec3( newPeak ), g );
}
vec3 CustomToneMapping( vec3 color ) { return color; }`,IM=`#ifdef USE_TRANSMISSION
	material.transmission = transmission;
	material.transmissionAlpha = 1.0;
	material.thickness = thickness;
	material.attenuationDistance = attenuationDistance;
	material.attenuationColor = attenuationColor;
	#ifdef USE_TRANSMISSIONMAP
		material.transmission *= texture2D( transmissionMap, vTransmissionMapUv ).r;
	#endif
	#ifdef USE_THICKNESSMAP
		material.thickness *= texture2D( thicknessMap, vThicknessMapUv ).g;
	#endif
	vec3 pos = vWorldPosition;
	vec3 v = normalize( cameraPosition - pos );
	vec3 n = inverseTransformDirection( normal, viewMatrix );
	vec4 transmitted = getIBLVolumeRefraction(
		n, v, material.roughness, material.diffuseColor, material.specularColor, material.specularF90,
		pos, modelMatrix, viewMatrix, projectionMatrix, material.dispersion, material.ior, material.thickness,
		material.attenuationColor, material.attenuationDistance );
	material.transmissionAlpha = mix( material.transmissionAlpha, transmitted.a, material.transmission );
	totalDiffuse = mix( totalDiffuse, transmitted.rgb, material.transmission );
#endif`,NM=`#ifdef USE_TRANSMISSION
	uniform float transmission;
	uniform float thickness;
	uniform float attenuationDistance;
	uniform vec3 attenuationColor;
	#ifdef USE_TRANSMISSIONMAP
		uniform sampler2D transmissionMap;
	#endif
	#ifdef USE_THICKNESSMAP
		uniform sampler2D thicknessMap;
	#endif
	uniform vec2 transmissionSamplerSize;
	uniform sampler2D transmissionSamplerMap;
	uniform mat4 modelMatrix;
	uniform mat4 projectionMatrix;
	varying vec3 vWorldPosition;
	float w0( float a ) {
		return ( 1.0 / 6.0 ) * ( a * ( a * ( - a + 3.0 ) - 3.0 ) + 1.0 );
	}
	float w1( float a ) {
		return ( 1.0 / 6.0 ) * ( a *  a * ( 3.0 * a - 6.0 ) + 4.0 );
	}
	float w2( float a ){
		return ( 1.0 / 6.0 ) * ( a * ( a * ( - 3.0 * a + 3.0 ) + 3.0 ) + 1.0 );
	}
	float w3( float a ) {
		return ( 1.0 / 6.0 ) * ( a * a * a );
	}
	float g0( float a ) {
		return w0( a ) + w1( a );
	}
	float g1( float a ) {
		return w2( a ) + w3( a );
	}
	float h0( float a ) {
		return - 1.0 + w1( a ) / ( w0( a ) + w1( a ) );
	}
	float h1( float a ) {
		return 1.0 + w3( a ) / ( w2( a ) + w3( a ) );
	}
	vec4 bicubic( sampler2D tex, vec2 uv, vec4 texelSize, float lod ) {
		uv = uv * texelSize.zw + 0.5;
		vec2 iuv = floor( uv );
		vec2 fuv = fract( uv );
		float g0x = g0( fuv.x );
		float g1x = g1( fuv.x );
		float h0x = h0( fuv.x );
		float h1x = h1( fuv.x );
		float h0y = h0( fuv.y );
		float h1y = h1( fuv.y );
		vec2 p0 = ( vec2( iuv.x + h0x, iuv.y + h0y ) - 0.5 ) * texelSize.xy;
		vec2 p1 = ( vec2( iuv.x + h1x, iuv.y + h0y ) - 0.5 ) * texelSize.xy;
		vec2 p2 = ( vec2( iuv.x + h0x, iuv.y + h1y ) - 0.5 ) * texelSize.xy;
		vec2 p3 = ( vec2( iuv.x + h1x, iuv.y + h1y ) - 0.5 ) * texelSize.xy;
		return g0( fuv.y ) * ( g0x * textureLod( tex, p0, lod ) + g1x * textureLod( tex, p1, lod ) ) +
			g1( fuv.y ) * ( g0x * textureLod( tex, p2, lod ) + g1x * textureLod( tex, p3, lod ) );
	}
	vec4 textureBicubic( sampler2D sampler, vec2 uv, float lod ) {
		vec2 fLodSize = vec2( textureSize( sampler, int( lod ) ) );
		vec2 cLodSize = vec2( textureSize( sampler, int( lod + 1.0 ) ) );
		vec2 fLodSizeInv = 1.0 / fLodSize;
		vec2 cLodSizeInv = 1.0 / cLodSize;
		vec4 fSample = bicubic( sampler, uv, vec4( fLodSizeInv, fLodSize ), floor( lod ) );
		vec4 cSample = bicubic( sampler, uv, vec4( cLodSizeInv, cLodSize ), ceil( lod ) );
		return mix( fSample, cSample, fract( lod ) );
	}
	vec3 getVolumeTransmissionRay( const in vec3 n, const in vec3 v, const in float thickness, const in float ior, const in mat4 modelMatrix ) {
		vec3 refractionVector = refract( - v, normalize( n ), 1.0 / ior );
		vec3 modelScale;
		modelScale.x = length( vec3( modelMatrix[ 0 ].xyz ) );
		modelScale.y = length( vec3( modelMatrix[ 1 ].xyz ) );
		modelScale.z = length( vec3( modelMatrix[ 2 ].xyz ) );
		return normalize( refractionVector ) * thickness * modelScale;
	}
	float applyIorToRoughness( const in float roughness, const in float ior ) {
		return roughness * clamp( ior * 2.0 - 2.0, 0.0, 1.0 );
	}
	vec4 getTransmissionSample( const in vec2 fragCoord, const in float roughness, const in float ior ) {
		float lod = log2( transmissionSamplerSize.x ) * applyIorToRoughness( roughness, ior );
		return textureBicubic( transmissionSamplerMap, fragCoord.xy, lod );
	}
	vec3 volumeAttenuation( const in float transmissionDistance, const in vec3 attenuationColor, const in float attenuationDistance ) {
		if ( isinf( attenuationDistance ) ) {
			return vec3( 1.0 );
		} else {
			vec3 attenuationCoefficient = -log( attenuationColor ) / attenuationDistance;
			vec3 transmittance = exp( - attenuationCoefficient * transmissionDistance );			return transmittance;
		}
	}
	vec4 getIBLVolumeRefraction( const in vec3 n, const in vec3 v, const in float roughness, const in vec3 diffuseColor,
		const in vec3 specularColor, const in float specularF90, const in vec3 position, const in mat4 modelMatrix,
		const in mat4 viewMatrix, const in mat4 projMatrix, const in float dispersion, const in float ior, const in float thickness,
		const in vec3 attenuationColor, const in float attenuationDistance ) {
		vec4 transmittedLight;
		vec3 transmittance;
		#ifdef USE_DISPERSION
			float halfSpread = ( ior - 1.0 ) * 0.025 * dispersion;
			vec3 iors = vec3( ior - halfSpread, ior, ior + halfSpread );
			for ( int i = 0; i < 3; i ++ ) {
				vec3 transmissionRay = getVolumeTransmissionRay( n, v, thickness, iors[ i ], modelMatrix );
				vec3 refractedRayExit = position + transmissionRay;
				vec4 ndcPos = projMatrix * viewMatrix * vec4( refractedRayExit, 1.0 );
				vec2 refractionCoords = ndcPos.xy / ndcPos.w;
				refractionCoords += 1.0;
				refractionCoords /= 2.0;
				vec4 transmissionSample = getTransmissionSample( refractionCoords, roughness, iors[ i ] );
				transmittedLight[ i ] = transmissionSample[ i ];
				transmittedLight.a += transmissionSample.a;
				transmittance[ i ] = diffuseColor[ i ] * volumeAttenuation( length( transmissionRay ), attenuationColor, attenuationDistance )[ i ];
			}
			transmittedLight.a /= 3.0;
		#else
			vec3 transmissionRay = getVolumeTransmissionRay( n, v, thickness, ior, modelMatrix );
			vec3 refractedRayExit = position + transmissionRay;
			vec4 ndcPos = projMatrix * viewMatrix * vec4( refractedRayExit, 1.0 );
			vec2 refractionCoords = ndcPos.xy / ndcPos.w;
			refractionCoords += 1.0;
			refractionCoords /= 2.0;
			transmittedLight = getTransmissionSample( refractionCoords, roughness, ior );
			transmittance = diffuseColor * volumeAttenuation( length( transmissionRay ), attenuationColor, attenuationDistance );
		#endif
		vec3 attenuatedColor = transmittance * transmittedLight.rgb;
		vec3 F = EnvironmentBRDF( n, v, specularColor, specularF90, roughness );
		float transmittanceFactor = ( transmittance.r + transmittance.g + transmittance.b ) / 3.0;
		return vec4( ( 1.0 - F ) * attenuatedColor, 1.0 - ( 1.0 - transmittedLight.a ) * transmittanceFactor );
	}
#endif`,OM=`#if defined( USE_UV ) || defined( USE_ANISOTROPY )
	varying vec2 vUv;
#endif
#ifdef USE_MAP
	varying vec2 vMapUv;
#endif
#ifdef USE_ALPHAMAP
	varying vec2 vAlphaMapUv;
#endif
#ifdef USE_LIGHTMAP
	varying vec2 vLightMapUv;
#endif
#ifdef USE_AOMAP
	varying vec2 vAoMapUv;
#endif
#ifdef USE_BUMPMAP
	varying vec2 vBumpMapUv;
#endif
#ifdef USE_NORMALMAP
	varying vec2 vNormalMapUv;
#endif
#ifdef USE_EMISSIVEMAP
	varying vec2 vEmissiveMapUv;
#endif
#ifdef USE_METALNESSMAP
	varying vec2 vMetalnessMapUv;
#endif
#ifdef USE_ROUGHNESSMAP
	varying vec2 vRoughnessMapUv;
#endif
#ifdef USE_ANISOTROPYMAP
	varying vec2 vAnisotropyMapUv;
#endif
#ifdef USE_CLEARCOATMAP
	varying vec2 vClearcoatMapUv;
#endif
#ifdef USE_CLEARCOAT_NORMALMAP
	varying vec2 vClearcoatNormalMapUv;
#endif
#ifdef USE_CLEARCOAT_ROUGHNESSMAP
	varying vec2 vClearcoatRoughnessMapUv;
#endif
#ifdef USE_IRIDESCENCEMAP
	varying vec2 vIridescenceMapUv;
#endif
#ifdef USE_IRIDESCENCE_THICKNESSMAP
	varying vec2 vIridescenceThicknessMapUv;
#endif
#ifdef USE_SHEEN_COLORMAP
	varying vec2 vSheenColorMapUv;
#endif
#ifdef USE_SHEEN_ROUGHNESSMAP
	varying vec2 vSheenRoughnessMapUv;
#endif
#ifdef USE_SPECULARMAP
	varying vec2 vSpecularMapUv;
#endif
#ifdef USE_SPECULAR_COLORMAP
	varying vec2 vSpecularColorMapUv;
#endif
#ifdef USE_SPECULAR_INTENSITYMAP
	varying vec2 vSpecularIntensityMapUv;
#endif
#ifdef USE_TRANSMISSIONMAP
	uniform mat3 transmissionMapTransform;
	varying vec2 vTransmissionMapUv;
#endif
#ifdef USE_THICKNESSMAP
	uniform mat3 thicknessMapTransform;
	varying vec2 vThicknessMapUv;
#endif`,kM=`#if defined( USE_UV ) || defined( USE_ANISOTROPY )
	varying vec2 vUv;
#endif
#ifdef USE_MAP
	uniform mat3 mapTransform;
	varying vec2 vMapUv;
#endif
#ifdef USE_ALPHAMAP
	uniform mat3 alphaMapTransform;
	varying vec2 vAlphaMapUv;
#endif
#ifdef USE_LIGHTMAP
	uniform mat3 lightMapTransform;
	varying vec2 vLightMapUv;
#endif
#ifdef USE_AOMAP
	uniform mat3 aoMapTransform;
	varying vec2 vAoMapUv;
#endif
#ifdef USE_BUMPMAP
	uniform mat3 bumpMapTransform;
	varying vec2 vBumpMapUv;
#endif
#ifdef USE_NORMALMAP
	uniform mat3 normalMapTransform;
	varying vec2 vNormalMapUv;
#endif
#ifdef USE_DISPLACEMENTMAP
	uniform mat3 displacementMapTransform;
	varying vec2 vDisplacementMapUv;
#endif
#ifdef USE_EMISSIVEMAP
	uniform mat3 emissiveMapTransform;
	varying vec2 vEmissiveMapUv;
#endif
#ifdef USE_METALNESSMAP
	uniform mat3 metalnessMapTransform;
	varying vec2 vMetalnessMapUv;
#endif
#ifdef USE_ROUGHNESSMAP
	uniform mat3 roughnessMapTransform;
	varying vec2 vRoughnessMapUv;
#endif
#ifdef USE_ANISOTROPYMAP
	uniform mat3 anisotropyMapTransform;
	varying vec2 vAnisotropyMapUv;
#endif
#ifdef USE_CLEARCOATMAP
	uniform mat3 clearcoatMapTransform;
	varying vec2 vClearcoatMapUv;
#endif
#ifdef USE_CLEARCOAT_NORMALMAP
	uniform mat3 clearcoatNormalMapTransform;
	varying vec2 vClearcoatNormalMapUv;
#endif
#ifdef USE_CLEARCOAT_ROUGHNESSMAP
	uniform mat3 clearcoatRoughnessMapTransform;
	varying vec2 vClearcoatRoughnessMapUv;
#endif
#ifdef USE_SHEEN_COLORMAP
	uniform mat3 sheenColorMapTransform;
	varying vec2 vSheenColorMapUv;
#endif
#ifdef USE_SHEEN_ROUGHNESSMAP
	uniform mat3 sheenRoughnessMapTransform;
	varying vec2 vSheenRoughnessMapUv;
#endif
#ifdef USE_IRIDESCENCEMAP
	uniform mat3 iridescenceMapTransform;
	varying vec2 vIridescenceMapUv;
#endif
#ifdef USE_IRIDESCENCE_THICKNESSMAP
	uniform mat3 iridescenceThicknessMapTransform;
	varying vec2 vIridescenceThicknessMapUv;
#endif
#ifdef USE_SPECULARMAP
	uniform mat3 specularMapTransform;
	varying vec2 vSpecularMapUv;
#endif
#ifdef USE_SPECULAR_COLORMAP
	uniform mat3 specularColorMapTransform;
	varying vec2 vSpecularColorMapUv;
#endif
#ifdef USE_SPECULAR_INTENSITYMAP
	uniform mat3 specularIntensityMapTransform;
	varying vec2 vSpecularIntensityMapUv;
#endif
#ifdef USE_TRANSMISSIONMAP
	uniform mat3 transmissionMapTransform;
	varying vec2 vTransmissionMapUv;
#endif
#ifdef USE_THICKNESSMAP
	uniform mat3 thicknessMapTransform;
	varying vec2 vThicknessMapUv;
#endif`,FM=`#if defined( USE_UV ) || defined( USE_ANISOTROPY )
	vUv = vec3( uv, 1 ).xy;
#endif
#ifdef USE_MAP
	vMapUv = ( mapTransform * vec3( MAP_UV, 1 ) ).xy;
#endif
#ifdef USE_ALPHAMAP
	vAlphaMapUv = ( alphaMapTransform * vec3( ALPHAMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_LIGHTMAP
	vLightMapUv = ( lightMapTransform * vec3( LIGHTMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_AOMAP
	vAoMapUv = ( aoMapTransform * vec3( AOMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_BUMPMAP
	vBumpMapUv = ( bumpMapTransform * vec3( BUMPMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_NORMALMAP
	vNormalMapUv = ( normalMapTransform * vec3( NORMALMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_DISPLACEMENTMAP
	vDisplacementMapUv = ( displacementMapTransform * vec3( DISPLACEMENTMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_EMISSIVEMAP
	vEmissiveMapUv = ( emissiveMapTransform * vec3( EMISSIVEMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_METALNESSMAP
	vMetalnessMapUv = ( metalnessMapTransform * vec3( METALNESSMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_ROUGHNESSMAP
	vRoughnessMapUv = ( roughnessMapTransform * vec3( ROUGHNESSMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_ANISOTROPYMAP
	vAnisotropyMapUv = ( anisotropyMapTransform * vec3( ANISOTROPYMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_CLEARCOATMAP
	vClearcoatMapUv = ( clearcoatMapTransform * vec3( CLEARCOATMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_CLEARCOAT_NORMALMAP
	vClearcoatNormalMapUv = ( clearcoatNormalMapTransform * vec3( CLEARCOAT_NORMALMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_CLEARCOAT_ROUGHNESSMAP
	vClearcoatRoughnessMapUv = ( clearcoatRoughnessMapTransform * vec3( CLEARCOAT_ROUGHNESSMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_IRIDESCENCEMAP
	vIridescenceMapUv = ( iridescenceMapTransform * vec3( IRIDESCENCEMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_IRIDESCENCE_THICKNESSMAP
	vIridescenceThicknessMapUv = ( iridescenceThicknessMapTransform * vec3( IRIDESCENCE_THICKNESSMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_SHEEN_COLORMAP
	vSheenColorMapUv = ( sheenColorMapTransform * vec3( SHEEN_COLORMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_SHEEN_ROUGHNESSMAP
	vSheenRoughnessMapUv = ( sheenRoughnessMapTransform * vec3( SHEEN_ROUGHNESSMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_SPECULARMAP
	vSpecularMapUv = ( specularMapTransform * vec3( SPECULARMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_SPECULAR_COLORMAP
	vSpecularColorMapUv = ( specularColorMapTransform * vec3( SPECULAR_COLORMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_SPECULAR_INTENSITYMAP
	vSpecularIntensityMapUv = ( specularIntensityMapTransform * vec3( SPECULAR_INTENSITYMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_TRANSMISSIONMAP
	vTransmissionMapUv = ( transmissionMapTransform * vec3( TRANSMISSIONMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_THICKNESSMAP
	vThicknessMapUv = ( thicknessMapTransform * vec3( THICKNESSMAP_UV, 1 ) ).xy;
#endif`,zM=`#if defined( USE_ENVMAP ) || defined( DISTANCE ) || defined ( USE_SHADOWMAP ) || defined ( USE_TRANSMISSION ) || NUM_SPOT_LIGHT_COORDS > 0
	vec4 worldPosition = vec4( transformed, 1.0 );
	#ifdef USE_BATCHING
		worldPosition = batchingMatrix * worldPosition;
	#endif
	#ifdef USE_INSTANCING
		worldPosition = instanceMatrix * worldPosition;
	#endif
	worldPosition = modelMatrix * worldPosition;
#endif`;const BM=`varying vec2 vUv;
uniform mat3 uvTransform;
void main() {
	vUv = ( uvTransform * vec3( uv, 1 ) ).xy;
	gl_Position = vec4( position.xy, 1.0, 1.0 );
}`,HM=`uniform sampler2D t2D;
uniform float backgroundIntensity;
varying vec2 vUv;
void main() {
	vec4 texColor = texture2D( t2D, vUv );
	#ifdef DECODE_VIDEO_TEXTURE
		texColor = vec4( mix( pow( texColor.rgb * 0.9478672986 + vec3( 0.0521327014 ), vec3( 2.4 ) ), texColor.rgb * 0.0773993808, vec3( lessThanEqual( texColor.rgb, vec3( 0.04045 ) ) ) ), texColor.w );
	#endif
	texColor.rgb *= backgroundIntensity;
	gl_FragColor = texColor;
	#include <tonemapping_fragment>
	#include <colorspace_fragment>
}`,VM=`varying vec3 vWorldDirection;
#include <common>
void main() {
	vWorldDirection = transformDirection( position, modelMatrix );
	#include <begin_vertex>
	#include <project_vertex>
	gl_Position.z = gl_Position.w;
}`,GM=`#ifdef ENVMAP_TYPE_CUBE
	uniform samplerCube envMap;
#elif defined( ENVMAP_TYPE_CUBE_UV )
	uniform sampler2D envMap;
#endif
uniform float flipEnvMap;
uniform float backgroundBlurriness;
uniform float backgroundIntensity;
uniform mat3 backgroundRotation;
varying vec3 vWorldDirection;
#include <cube_uv_reflection_fragment>
void main() {
	#ifdef ENVMAP_TYPE_CUBE
		vec4 texColor = textureCube( envMap, backgroundRotation * vec3( flipEnvMap * vWorldDirection.x, vWorldDirection.yz ) );
	#elif defined( ENVMAP_TYPE_CUBE_UV )
		vec4 texColor = textureCubeUV( envMap, backgroundRotation * vWorldDirection, backgroundBlurriness );
	#else
		vec4 texColor = vec4( 0.0, 0.0, 0.0, 1.0 );
	#endif
	texColor.rgb *= backgroundIntensity;
	gl_FragColor = texColor;
	#include <tonemapping_fragment>
	#include <colorspace_fragment>
}`,WM=`varying vec3 vWorldDirection;
#include <common>
void main() {
	vWorldDirection = transformDirection( position, modelMatrix );
	#include <begin_vertex>
	#include <project_vertex>
	gl_Position.z = gl_Position.w;
}`,jM=`uniform samplerCube tCube;
uniform float tFlip;
uniform float opacity;
varying vec3 vWorldDirection;
void main() {
	vec4 texColor = textureCube( tCube, vec3( tFlip * vWorldDirection.x, vWorldDirection.yz ) );
	gl_FragColor = texColor;
	gl_FragColor.a *= opacity;
	#include <tonemapping_fragment>
	#include <colorspace_fragment>
}`,XM=`#include <common>
#include <batching_pars_vertex>
#include <uv_pars_vertex>
#include <displacementmap_pars_vertex>
#include <morphtarget_pars_vertex>
#include <skinning_pars_vertex>
#include <logdepthbuf_pars_vertex>
#include <clipping_planes_pars_vertex>
varying vec2 vHighPrecisionZW;
void main() {
	#include <uv_vertex>
	#include <batching_vertex>
	#include <skinbase_vertex>
	#include <morphinstance_vertex>
	#ifdef USE_DISPLACEMENTMAP
		#include <beginnormal_vertex>
		#include <morphnormal_vertex>
		#include <skinnormal_vertex>
	#endif
	#include <begin_vertex>
	#include <morphtarget_vertex>
	#include <skinning_vertex>
	#include <displacementmap_vertex>
	#include <project_vertex>
	#include <logdepthbuf_vertex>
	#include <clipping_planes_vertex>
	vHighPrecisionZW = gl_Position.zw;
}`,YM=`#if DEPTH_PACKING == 3200
	uniform float opacity;
#endif
#include <common>
#include <packing>
#include <uv_pars_fragment>
#include <map_pars_fragment>
#include <alphamap_pars_fragment>
#include <alphatest_pars_fragment>
#include <alphahash_pars_fragment>
#include <logdepthbuf_pars_fragment>
#include <clipping_planes_pars_fragment>
varying vec2 vHighPrecisionZW;
void main() {
	vec4 diffuseColor = vec4( 1.0 );
	#include <clipping_planes_fragment>
	#if DEPTH_PACKING == 3200
		diffuseColor.a = opacity;
	#endif
	#include <map_fragment>
	#include <alphamap_fragment>
	#include <alphatest_fragment>
	#include <alphahash_fragment>
	#include <logdepthbuf_fragment>
	float fragCoordZ = 0.5 * vHighPrecisionZW[0] / vHighPrecisionZW[1] + 0.5;
	#if DEPTH_PACKING == 3200
		gl_FragColor = vec4( vec3( 1.0 - fragCoordZ ), opacity );
	#elif DEPTH_PACKING == 3201
		gl_FragColor = packDepthToRGBA( fragCoordZ );
	#elif DEPTH_PACKING == 3202
		gl_FragColor = vec4( packDepthToRGB( fragCoordZ ), 1.0 );
	#elif DEPTH_PACKING == 3203
		gl_FragColor = vec4( packDepthToRG( fragCoordZ ), 0.0, 1.0 );
	#endif
}`,qM=`#define DISTANCE
varying vec3 vWorldPosition;
#include <common>
#include <batching_pars_vertex>
#include <uv_pars_vertex>
#include <displacementmap_pars_vertex>
#include <morphtarget_pars_vertex>
#include <skinning_pars_vertex>
#include <clipping_planes_pars_vertex>
void main() {
	#include <uv_vertex>
	#include <batching_vertex>
	#include <skinbase_vertex>
	#include <morphinstance_vertex>
	#ifdef USE_DISPLACEMENTMAP
		#include <beginnormal_vertex>
		#include <morphnormal_vertex>
		#include <skinnormal_vertex>
	#endif
	#include <begin_vertex>
	#include <morphtarget_vertex>
	#include <skinning_vertex>
	#include <displacementmap_vertex>
	#include <project_vertex>
	#include <worldpos_vertex>
	#include <clipping_planes_vertex>
	vWorldPosition = worldPosition.xyz;
}`,QM=`#define DISTANCE
uniform vec3 referencePosition;
uniform float nearDistance;
uniform float farDistance;
varying vec3 vWorldPosition;
#include <common>
#include <packing>
#include <uv_pars_fragment>
#include <map_pars_fragment>
#include <alphamap_pars_fragment>
#include <alphatest_pars_fragment>
#include <alphahash_pars_fragment>
#include <clipping_planes_pars_fragment>
void main () {
	vec4 diffuseColor = vec4( 1.0 );
	#include <clipping_planes_fragment>
	#include <map_fragment>
	#include <alphamap_fragment>
	#include <alphatest_fragment>
	#include <alphahash_fragment>
	float dist = length( vWorldPosition - referencePosition );
	dist = ( dist - nearDistance ) / ( farDistance - nearDistance );
	dist = saturate( dist );
	gl_FragColor = packDepthToRGBA( dist );
}`,$M=`varying vec3 vWorldDirection;
#include <common>
void main() {
	vWorldDirection = transformDirection( position, modelMatrix );
	#include <begin_vertex>
	#include <project_vertex>
}`,KM=`uniform sampler2D tEquirect;
varying vec3 vWorldDirection;
#include <common>
void main() {
	vec3 direction = normalize( vWorldDirection );
	vec2 sampleUV = equirectUv( direction );
	gl_FragColor = texture2D( tEquirect, sampleUV );
	#include <tonemapping_fragment>
	#include <colorspace_fragment>
}`,ZM=`uniform float scale;
attribute float lineDistance;
varying float vLineDistance;
#include <common>
#include <uv_pars_vertex>
#include <color_pars_vertex>
#include <fog_pars_vertex>
#include <morphtarget_pars_vertex>
#include <logdepthbuf_pars_vertex>
#include <clipping_planes_pars_vertex>
void main() {
	vLineDistance = scale * lineDistance;
	#include <uv_vertex>
	#include <color_vertex>
	#include <morphinstance_vertex>
	#include <morphcolor_vertex>
	#include <begin_vertex>
	#include <morphtarget_vertex>
	#include <project_vertex>
	#include <logdepthbuf_vertex>
	#include <clipping_planes_vertex>
	#include <fog_vertex>
}`,JM=`uniform vec3 diffuse;
uniform float opacity;
uniform float dashSize;
uniform float totalSize;
varying float vLineDistance;
#include <common>
#include <color_pars_fragment>
#include <uv_pars_fragment>
#include <map_pars_fragment>
#include <fog_pars_fragment>
#include <logdepthbuf_pars_fragment>
#include <clipping_planes_pars_fragment>
void main() {
	vec4 diffuseColor = vec4( diffuse, opacity );
	#include <clipping_planes_fragment>
	if ( mod( vLineDistance, totalSize ) > dashSize ) {
		discard;
	}
	vec3 outgoingLight = vec3( 0.0 );
	#include <logdepthbuf_fragment>
	#include <map_fragment>
	#include <color_fragment>
	outgoingLight = diffuseColor.rgb;
	#include <opaque_fragment>
	#include <tonemapping_fragment>
	#include <colorspace_fragment>
	#include <fog_fragment>
	#include <premultiplied_alpha_fragment>
}`,eE=`#include <common>
#include <batching_pars_vertex>
#include <uv_pars_vertex>
#include <envmap_pars_vertex>
#include <color_pars_vertex>
#include <fog_pars_vertex>
#include <morphtarget_pars_vertex>
#include <skinning_pars_vertex>
#include <logdepthbuf_pars_vertex>
#include <clipping_planes_pars_vertex>
void main() {
	#include <uv_vertex>
	#include <color_vertex>
	#include <morphinstance_vertex>
	#include <morphcolor_vertex>
	#include <batching_vertex>
	#if defined ( USE_ENVMAP ) || defined ( USE_SKINNING )
		#include <beginnormal_vertex>
		#include <morphnormal_vertex>
		#include <skinbase_vertex>
		#include <skinnormal_vertex>
		#include <defaultnormal_vertex>
	#endif
	#include <begin_vertex>
	#include <morphtarget_vertex>
	#include <skinning_vertex>
	#include <project_vertex>
	#include <logdepthbuf_vertex>
	#include <clipping_planes_vertex>
	#include <worldpos_vertex>
	#include <envmap_vertex>
	#include <fog_vertex>
}`,tE=`uniform vec3 diffuse;
uniform float opacity;
#ifndef FLAT_SHADED
	varying vec3 vNormal;
#endif
#include <common>
#include <dithering_pars_fragment>
#include <color_pars_fragment>
#include <uv_pars_fragment>
#include <map_pars_fragment>
#include <alphamap_pars_fragment>
#include <alphatest_pars_fragment>
#include <alphahash_pars_fragment>
#include <aomap_pars_fragment>
#include <lightmap_pars_fragment>
#include <envmap_common_pars_fragment>
#include <envmap_pars_fragment>
#include <fog_pars_fragment>
#include <specularmap_pars_fragment>
#include <logdepthbuf_pars_fragment>
#include <clipping_planes_pars_fragment>
void main() {
	vec4 diffuseColor = vec4( diffuse, opacity );
	#include <clipping_planes_fragment>
	#include <logdepthbuf_fragment>
	#include <map_fragment>
	#include <color_fragment>
	#include <alphamap_fragment>
	#include <alphatest_fragment>
	#include <alphahash_fragment>
	#include <specularmap_fragment>
	ReflectedLight reflectedLight = ReflectedLight( vec3( 0.0 ), vec3( 0.0 ), vec3( 0.0 ), vec3( 0.0 ) );
	#ifdef USE_LIGHTMAP
		vec4 lightMapTexel = texture2D( lightMap, vLightMapUv );
		reflectedLight.indirectDiffuse += lightMapTexel.rgb * lightMapIntensity * RECIPROCAL_PI;
	#else
		reflectedLight.indirectDiffuse += vec3( 1.0 );
	#endif
	#include <aomap_fragment>
	reflectedLight.indirectDiffuse *= diffuseColor.rgb;
	vec3 outgoingLight = reflectedLight.indirectDiffuse;
	#include <envmap_fragment>
	#include <opaque_fragment>
	#include <tonemapping_fragment>
	#include <colorspace_fragment>
	#include <fog_fragment>
	#include <premultiplied_alpha_fragment>
	#include <dithering_fragment>
}`,rE=`#define LAMBERT
varying vec3 vViewPosition;
#include <common>
#include <batching_pars_vertex>
#include <uv_pars_vertex>
#include <displacementmap_pars_vertex>
#include <envmap_pars_vertex>
#include <color_pars_vertex>
#include <fog_pars_vertex>
#include <normal_pars_vertex>
#include <morphtarget_pars_vertex>
#include <skinning_pars_vertex>
#include <shadowmap_pars_vertex>
#include <logdepthbuf_pars_vertex>
#include <clipping_planes_pars_vertex>
void main() {
	#include <uv_vertex>
	#include <color_vertex>
	#include <morphinstance_vertex>
	#include <morphcolor_vertex>
	#include <batching_vertex>
	#include <beginnormal_vertex>
	#include <morphnormal_vertex>
	#include <skinbase_vertex>
	#include <skinnormal_vertex>
	#include <defaultnormal_vertex>
	#include <normal_vertex>
	#include <begin_vertex>
	#include <morphtarget_vertex>
	#include <skinning_vertex>
	#include <displacementmap_vertex>
	#include <project_vertex>
	#include <logdepthbuf_vertex>
	#include <clipping_planes_vertex>
	vViewPosition = - mvPosition.xyz;
	#include <worldpos_vertex>
	#include <envmap_vertex>
	#include <shadowmap_vertex>
	#include <fog_vertex>
}`,iE=`#define LAMBERT
uniform vec3 diffuse;
uniform vec3 emissive;
uniform float opacity;
#include <common>
#include <packing>
#include <dithering_pars_fragment>
#include <color_pars_fragment>
#include <uv_pars_fragment>
#include <map_pars_fragment>
#include <alphamap_pars_fragment>
#include <alphatest_pars_fragment>
#include <alphahash_pars_fragment>
#include <aomap_pars_fragment>
#include <lightmap_pars_fragment>
#include <emissivemap_pars_fragment>
#include <envmap_common_pars_fragment>
#include <envmap_pars_fragment>
#include <fog_pars_fragment>
#include <bsdfs>
#include <lights_pars_begin>
#include <normal_pars_fragment>
#include <lights_lambert_pars_fragment>
#include <shadowmap_pars_fragment>
#include <bumpmap_pars_fragment>
#include <normalmap_pars_fragment>
#include <specularmap_pars_fragment>
#include <logdepthbuf_pars_fragment>
#include <clipping_planes_pars_fragment>
void main() {
	vec4 diffuseColor = vec4( diffuse, opacity );
	#include <clipping_planes_fragment>
	ReflectedLight reflectedLight = ReflectedLight( vec3( 0.0 ), vec3( 0.0 ), vec3( 0.0 ), vec3( 0.0 ) );
	vec3 totalEmissiveRadiance = emissive;
	#include <logdepthbuf_fragment>
	#include <map_fragment>
	#include <color_fragment>
	#include <alphamap_fragment>
	#include <alphatest_fragment>
	#include <alphahash_fragment>
	#include <specularmap_fragment>
	#include <normal_fragment_begin>
	#include <normal_fragment_maps>
	#include <emissivemap_fragment>
	#include <lights_lambert_fragment>
	#include <lights_fragment_begin>
	#include <lights_fragment_maps>
	#include <lights_fragment_end>
	#include <aomap_fragment>
	vec3 outgoingLight = reflectedLight.directDiffuse + reflectedLight.indirectDiffuse + totalEmissiveRadiance;
	#include <envmap_fragment>
	#include <opaque_fragment>
	#include <tonemapping_fragment>
	#include <colorspace_fragment>
	#include <fog_fragment>
	#include <premultiplied_alpha_fragment>
	#include <dithering_fragment>
}`,nE=`#define MATCAP
varying vec3 vViewPosition;
#include <common>
#include <batching_pars_vertex>
#include <uv_pars_vertex>
#include <color_pars_vertex>
#include <displacementmap_pars_vertex>
#include <fog_pars_vertex>
#include <normal_pars_vertex>
#include <morphtarget_pars_vertex>
#include <skinning_pars_vertex>
#include <logdepthbuf_pars_vertex>
#include <clipping_planes_pars_vertex>
void main() {
	#include <uv_vertex>
	#include <color_vertex>
	#include <morphinstance_vertex>
	#include <morphcolor_vertex>
	#include <batching_vertex>
	#include <beginnormal_vertex>
	#include <morphnormal_vertex>
	#include <skinbase_vertex>
	#include <skinnormal_vertex>
	#include <defaultnormal_vertex>
	#include <normal_vertex>
	#include <begin_vertex>
	#include <morphtarget_vertex>
	#include <skinning_vertex>
	#include <displacementmap_vertex>
	#include <project_vertex>
	#include <logdepthbuf_vertex>
	#include <clipping_planes_vertex>
	#include <fog_vertex>
	vViewPosition = - mvPosition.xyz;
}`,aE=`#define MATCAP
uniform vec3 diffuse;
uniform float opacity;
uniform sampler2D matcap;
varying vec3 vViewPosition;
#include <common>
#include <dithering_pars_fragment>
#include <color_pars_fragment>
#include <uv_pars_fragment>
#include <map_pars_fragment>
#include <alphamap_pars_fragment>
#include <alphatest_pars_fragment>
#include <alphahash_pars_fragment>
#include <fog_pars_fragment>
#include <normal_pars_fragment>
#include <bumpmap_pars_fragment>
#include <normalmap_pars_fragment>
#include <logdepthbuf_pars_fragment>
#include <clipping_planes_pars_fragment>
void main() {
	vec4 diffuseColor = vec4( diffuse, opacity );
	#include <clipping_planes_fragment>
	#include <logdepthbuf_fragment>
	#include <map_fragment>
	#include <color_fragment>
	#include <alphamap_fragment>
	#include <alphatest_fragment>
	#include <alphahash_fragment>
	#include <normal_fragment_begin>
	#include <normal_fragment_maps>
	vec3 viewDir = normalize( vViewPosition );
	vec3 x = normalize( vec3( viewDir.z, 0.0, - viewDir.x ) );
	vec3 y = cross( viewDir, x );
	vec2 uv = vec2( dot( x, normal ), dot( y, normal ) ) * 0.495 + 0.5;
	#ifdef USE_MATCAP
		vec4 matcapColor = texture2D( matcap, uv );
	#else
		vec4 matcapColor = vec4( vec3( mix( 0.2, 0.8, uv.y ) ), 1.0 );
	#endif
	vec3 outgoingLight = diffuseColor.rgb * matcapColor.rgb;
	#include <opaque_fragment>
	#include <tonemapping_fragment>
	#include <colorspace_fragment>
	#include <fog_fragment>
	#include <premultiplied_alpha_fragment>
	#include <dithering_fragment>
}`,sE=`#define NORMAL
#if defined( FLAT_SHADED ) || defined( USE_BUMPMAP ) || defined( USE_NORMALMAP_TANGENTSPACE )
	varying vec3 vViewPosition;
#endif
#include <common>
#include <batching_pars_vertex>
#include <uv_pars_vertex>
#include <displacementmap_pars_vertex>
#include <normal_pars_vertex>
#include <morphtarget_pars_vertex>
#include <skinning_pars_vertex>
#include <logdepthbuf_pars_vertex>
#include <clipping_planes_pars_vertex>
void main() {
	#include <uv_vertex>
	#include <batching_vertex>
	#include <beginnormal_vertex>
	#include <morphinstance_vertex>
	#include <morphnormal_vertex>
	#include <skinbase_vertex>
	#include <skinnormal_vertex>
	#include <defaultnormal_vertex>
	#include <normal_vertex>
	#include <begin_vertex>
	#include <morphtarget_vertex>
	#include <skinning_vertex>
	#include <displacementmap_vertex>
	#include <project_vertex>
	#include <logdepthbuf_vertex>
	#include <clipping_planes_vertex>
#if defined( FLAT_SHADED ) || defined( USE_BUMPMAP ) || defined( USE_NORMALMAP_TANGENTSPACE )
	vViewPosition = - mvPosition.xyz;
#endif
}`,oE=`#define NORMAL
uniform float opacity;
#if defined( FLAT_SHADED ) || defined( USE_BUMPMAP ) || defined( USE_NORMALMAP_TANGENTSPACE )
	varying vec3 vViewPosition;
#endif
#include <packing>
#include <uv_pars_fragment>
#include <normal_pars_fragment>
#include <bumpmap_pars_fragment>
#include <normalmap_pars_fragment>
#include <logdepthbuf_pars_fragment>
#include <clipping_planes_pars_fragment>
void main() {
	vec4 diffuseColor = vec4( 0.0, 0.0, 0.0, opacity );
	#include <clipping_planes_fragment>
	#include <logdepthbuf_fragment>
	#include <normal_fragment_begin>
	#include <normal_fragment_maps>
	gl_FragColor = vec4( packNormalToRGB( normal ), diffuseColor.a );
	#ifdef OPAQUE
		gl_FragColor.a = 1.0;
	#endif
}`,lE=`#define PHONG
varying vec3 vViewPosition;
#include <common>
#include <batching_pars_vertex>
#include <uv_pars_vertex>
#include <displacementmap_pars_vertex>
#include <envmap_pars_vertex>
#include <color_pars_vertex>
#include <fog_pars_vertex>
#include <normal_pars_vertex>
#include <morphtarget_pars_vertex>
#include <skinning_pars_vertex>
#include <shadowmap_pars_vertex>
#include <logdepthbuf_pars_vertex>
#include <clipping_planes_pars_vertex>
void main() {
	#include <uv_vertex>
	#include <color_vertex>
	#include <morphcolor_vertex>
	#include <batching_vertex>
	#include <beginnormal_vertex>
	#include <morphinstance_vertex>
	#include <morphnormal_vertex>
	#include <skinbase_vertex>
	#include <skinnormal_vertex>
	#include <defaultnormal_vertex>
	#include <normal_vertex>
	#include <begin_vertex>
	#include <morphtarget_vertex>
	#include <skinning_vertex>
	#include <displacementmap_vertex>
	#include <project_vertex>
	#include <logdepthbuf_vertex>
	#include <clipping_planes_vertex>
	vViewPosition = - mvPosition.xyz;
	#include <worldpos_vertex>
	#include <envmap_vertex>
	#include <shadowmap_vertex>
	#include <fog_vertex>
}`,cE=`#define PHONG
uniform vec3 diffuse;
uniform vec3 emissive;
uniform vec3 specular;
uniform float shininess;
uniform float opacity;
#include <common>
#include <packing>
#include <dithering_pars_fragment>
#include <color_pars_fragment>
#include <uv_pars_fragment>
#include <map_pars_fragment>
#include <alphamap_pars_fragment>
#include <alphatest_pars_fragment>
#include <alphahash_pars_fragment>
#include <aomap_pars_fragment>
#include <lightmap_pars_fragment>
#include <emissivemap_pars_fragment>
#include <envmap_common_pars_fragment>
#include <envmap_pars_fragment>
#include <fog_pars_fragment>
#include <bsdfs>
#include <lights_pars_begin>
#include <normal_pars_fragment>
#include <lights_phong_pars_fragment>
#include <shadowmap_pars_fragment>
#include <bumpmap_pars_fragment>
#include <normalmap_pars_fragment>
#include <specularmap_pars_fragment>
#include <logdepthbuf_pars_fragment>
#include <clipping_planes_pars_fragment>
void main() {
	vec4 diffuseColor = vec4( diffuse, opacity );
	#include <clipping_planes_fragment>
	ReflectedLight reflectedLight = ReflectedLight( vec3( 0.0 ), vec3( 0.0 ), vec3( 0.0 ), vec3( 0.0 ) );
	vec3 totalEmissiveRadiance = emissive;
	#include <logdepthbuf_fragment>
	#include <map_fragment>
	#include <color_fragment>
	#include <alphamap_fragment>
	#include <alphatest_fragment>
	#include <alphahash_fragment>
	#include <specularmap_fragment>
	#include <normal_fragment_begin>
	#include <normal_fragment_maps>
	#include <emissivemap_fragment>
	#include <lights_phong_fragment>
	#include <lights_fragment_begin>
	#include <lights_fragment_maps>
	#include <lights_fragment_end>
	#include <aomap_fragment>
	vec3 outgoingLight = reflectedLight.directDiffuse + reflectedLight.indirectDiffuse + reflectedLight.directSpecular + reflectedLight.indirectSpecular + totalEmissiveRadiance;
	#include <envmap_fragment>
	#include <opaque_fragment>
	#include <tonemapping_fragment>
	#include <colorspace_fragment>
	#include <fog_fragment>
	#include <premultiplied_alpha_fragment>
	#include <dithering_fragment>
}`,uE=`#define STANDARD
varying vec3 vViewPosition;
#ifdef USE_TRANSMISSION
	varying vec3 vWorldPosition;
#endif
#include <common>
#include <batching_pars_vertex>
#include <uv_pars_vertex>
#include <displacementmap_pars_vertex>
#include <color_pars_vertex>
#include <fog_pars_vertex>
#include <normal_pars_vertex>
#include <morphtarget_pars_vertex>
#include <skinning_pars_vertex>
#include <shadowmap_pars_vertex>
#include <logdepthbuf_pars_vertex>
#include <clipping_planes_pars_vertex>
void main() {
	#include <uv_vertex>
	#include <color_vertex>
	#include <morphinstance_vertex>
	#include <morphcolor_vertex>
	#include <batching_vertex>
	#include <beginnormal_vertex>
	#include <morphnormal_vertex>
	#include <skinbase_vertex>
	#include <skinnormal_vertex>
	#include <defaultnormal_vertex>
	#include <normal_vertex>
	#include <begin_vertex>
	#include <morphtarget_vertex>
	#include <skinning_vertex>
	#include <displacementmap_vertex>
	#include <project_vertex>
	#include <logdepthbuf_vertex>
	#include <clipping_planes_vertex>
	vViewPosition = - mvPosition.xyz;
	#include <worldpos_vertex>
	#include <shadowmap_vertex>
	#include <fog_vertex>
#ifdef USE_TRANSMISSION
	vWorldPosition = worldPosition.xyz;
#endif
}`,dE=`#define STANDARD
#ifdef PHYSICAL
	#define IOR
	#define USE_SPECULAR
#endif
uniform vec3 diffuse;
uniform vec3 emissive;
uniform float roughness;
uniform float metalness;
uniform float opacity;
#ifdef IOR
	uniform float ior;
#endif
#ifdef USE_SPECULAR
	uniform float specularIntensity;
	uniform vec3 specularColor;
	#ifdef USE_SPECULAR_COLORMAP
		uniform sampler2D specularColorMap;
	#endif
	#ifdef USE_SPECULAR_INTENSITYMAP
		uniform sampler2D specularIntensityMap;
	#endif
#endif
#ifdef USE_CLEARCOAT
	uniform float clearcoat;
	uniform float clearcoatRoughness;
#endif
#ifdef USE_DISPERSION
	uniform float dispersion;
#endif
#ifdef USE_IRIDESCENCE
	uniform float iridescence;
	uniform float iridescenceIOR;
	uniform float iridescenceThicknessMinimum;
	uniform float iridescenceThicknessMaximum;
#endif
#ifdef USE_SHEEN
	uniform vec3 sheenColor;
	uniform float sheenRoughness;
	#ifdef USE_SHEEN_COLORMAP
		uniform sampler2D sheenColorMap;
	#endif
	#ifdef USE_SHEEN_ROUGHNESSMAP
		uniform sampler2D sheenRoughnessMap;
	#endif
#endif
#ifdef USE_ANISOTROPY
	uniform vec2 anisotropyVector;
	#ifdef USE_ANISOTROPYMAP
		uniform sampler2D anisotropyMap;
	#endif
#endif
varying vec3 vViewPosition;
#include <common>
#include <packing>
#include <dithering_pars_fragment>
#include <color_pars_fragment>
#include <uv_pars_fragment>
#include <map_pars_fragment>
#include <alphamap_pars_fragment>
#include <alphatest_pars_fragment>
#include <alphahash_pars_fragment>
#include <aomap_pars_fragment>
#include <lightmap_pars_fragment>
#include <emissivemap_pars_fragment>
#include <iridescence_fragment>
#include <cube_uv_reflection_fragment>
#include <envmap_common_pars_fragment>
#include <envmap_physical_pars_fragment>
#include <fog_pars_fragment>
#include <lights_pars_begin>
#include <normal_pars_fragment>
#include <lights_physical_pars_fragment>
#include <transmission_pars_fragment>
#include <shadowmap_pars_fragment>
#include <bumpmap_pars_fragment>
#include <normalmap_pars_fragment>
#include <clearcoat_pars_fragment>
#include <iridescence_pars_fragment>
#include <roughnessmap_pars_fragment>
#include <metalnessmap_pars_fragment>
#include <logdepthbuf_pars_fragment>
#include <clipping_planes_pars_fragment>
void main() {
	vec4 diffuseColor = vec4( diffuse, opacity );
	#include <clipping_planes_fragment>
	ReflectedLight reflectedLight = ReflectedLight( vec3( 0.0 ), vec3( 0.0 ), vec3( 0.0 ), vec3( 0.0 ) );
	vec3 totalEmissiveRadiance = emissive;
	#include <logdepthbuf_fragment>
	#include <map_fragment>
	#include <color_fragment>
	#include <alphamap_fragment>
	#include <alphatest_fragment>
	#include <alphahash_fragment>
	#include <roughnessmap_fragment>
	#include <metalnessmap_fragment>
	#include <normal_fragment_begin>
	#include <normal_fragment_maps>
	#include <clearcoat_normal_fragment_begin>
	#include <clearcoat_normal_fragment_maps>
	#include <emissivemap_fragment>
	#include <lights_physical_fragment>
	#include <lights_fragment_begin>
	#include <lights_fragment_maps>
	#include <lights_fragment_end>
	#include <aomap_fragment>
	vec3 totalDiffuse = reflectedLight.directDiffuse + reflectedLight.indirectDiffuse;
	vec3 totalSpecular = reflectedLight.directSpecular + reflectedLight.indirectSpecular;
	#include <transmission_fragment>
	vec3 outgoingLight = totalDiffuse + totalSpecular + totalEmissiveRadiance;
	#ifdef USE_SHEEN
		float sheenEnergyComp = 1.0 - 0.157 * max3( material.sheenColor );
		outgoingLight = outgoingLight * sheenEnergyComp + sheenSpecularDirect + sheenSpecularIndirect;
	#endif
	#ifdef USE_CLEARCOAT
		float dotNVcc = saturate( dot( geometryClearcoatNormal, geometryViewDir ) );
		vec3 Fcc = F_Schlick( material.clearcoatF0, material.clearcoatF90, dotNVcc );
		outgoingLight = outgoingLight * ( 1.0 - material.clearcoat * Fcc ) + ( clearcoatSpecularDirect + clearcoatSpecularIndirect ) * material.clearcoat;
	#endif
	#include <opaque_fragment>
	#include <tonemapping_fragment>
	#include <colorspace_fragment>
	#include <fog_fragment>
	#include <premultiplied_alpha_fragment>
	#include <dithering_fragment>
}`,hE=`#define TOON
varying vec3 vViewPosition;
#include <common>
#include <batching_pars_vertex>
#include <uv_pars_vertex>
#include <displacementmap_pars_vertex>
#include <color_pars_vertex>
#include <fog_pars_vertex>
#include <normal_pars_vertex>
#include <morphtarget_pars_vertex>
#include <skinning_pars_vertex>
#include <shadowmap_pars_vertex>
#include <logdepthbuf_pars_vertex>
#include <clipping_planes_pars_vertex>
void main() {
	#include <uv_vertex>
	#include <color_vertex>
	#include <morphinstance_vertex>
	#include <morphcolor_vertex>
	#include <batching_vertex>
	#include <beginnormal_vertex>
	#include <morphnormal_vertex>
	#include <skinbase_vertex>
	#include <skinnormal_vertex>
	#include <defaultnormal_vertex>
	#include <normal_vertex>
	#include <begin_vertex>
	#include <morphtarget_vertex>
	#include <skinning_vertex>
	#include <displacementmap_vertex>
	#include <project_vertex>
	#include <logdepthbuf_vertex>
	#include <clipping_planes_vertex>
	vViewPosition = - mvPosition.xyz;
	#include <worldpos_vertex>
	#include <shadowmap_vertex>
	#include <fog_vertex>
}`,fE=`#define TOON
uniform vec3 diffuse;
uniform vec3 emissive;
uniform float opacity;
#include <common>
#include <packing>
#include <dithering_pars_fragment>
#include <color_pars_fragment>
#include <uv_pars_fragment>
#include <map_pars_fragment>
#include <alphamap_pars_fragment>
#include <alphatest_pars_fragment>
#include <alphahash_pars_fragment>
#include <aomap_pars_fragment>
#include <lightmap_pars_fragment>
#include <emissivemap_pars_fragment>
#include <gradientmap_pars_fragment>
#include <fog_pars_fragment>
#include <bsdfs>
#include <lights_pars_begin>
#include <normal_pars_fragment>
#include <lights_toon_pars_fragment>
#include <shadowmap_pars_fragment>
#include <bumpmap_pars_fragment>
#include <normalmap_pars_fragment>
#include <logdepthbuf_pars_fragment>
#include <clipping_planes_pars_fragment>
void main() {
	vec4 diffuseColor = vec4( diffuse, opacity );
	#include <clipping_planes_fragment>
	ReflectedLight reflectedLight = ReflectedLight( vec3( 0.0 ), vec3( 0.0 ), vec3( 0.0 ), vec3( 0.0 ) );
	vec3 totalEmissiveRadiance = emissive;
	#include <logdepthbuf_fragment>
	#include <map_fragment>
	#include <color_fragment>
	#include <alphamap_fragment>
	#include <alphatest_fragment>
	#include <alphahash_fragment>
	#include <normal_fragment_begin>
	#include <normal_fragment_maps>
	#include <emissivemap_fragment>
	#include <lights_toon_fragment>
	#include <lights_fragment_begin>
	#include <lights_fragment_maps>
	#include <lights_fragment_end>
	#include <aomap_fragment>
	vec3 outgoingLight = reflectedLight.directDiffuse + reflectedLight.indirectDiffuse + totalEmissiveRadiance;
	#include <opaque_fragment>
	#include <tonemapping_fragment>
	#include <colorspace_fragment>
	#include <fog_fragment>
	#include <premultiplied_alpha_fragment>
	#include <dithering_fragment>
}`,pE=`uniform float size;
uniform float scale;
#include <common>
#include <color_pars_vertex>
#include <fog_pars_vertex>
#include <morphtarget_pars_vertex>
#include <logdepthbuf_pars_vertex>
#include <clipping_planes_pars_vertex>
#ifdef USE_POINTS_UV
	varying vec2 vUv;
	uniform mat3 uvTransform;
#endif
void main() {
	#ifdef USE_POINTS_UV
		vUv = ( uvTransform * vec3( uv, 1 ) ).xy;
	#endif
	#include <color_vertex>
	#include <morphinstance_vertex>
	#include <morphcolor_vertex>
	#include <begin_vertex>
	#include <morphtarget_vertex>
	#include <project_vertex>
	gl_PointSize = size;
	#ifdef USE_SIZEATTENUATION
		bool isPerspective = isPerspectiveMatrix( projectionMatrix );
		if ( isPerspective ) gl_PointSize *= ( scale / - mvPosition.z );
	#endif
	#include <logdepthbuf_vertex>
	#include <clipping_planes_vertex>
	#include <worldpos_vertex>
	#include <fog_vertex>
}`,mE=`uniform vec3 diffuse;
uniform float opacity;
#include <common>
#include <color_pars_fragment>
#include <map_particle_pars_fragment>
#include <alphatest_pars_fragment>
#include <alphahash_pars_fragment>
#include <fog_pars_fragment>
#include <logdepthbuf_pars_fragment>
#include <clipping_planes_pars_fragment>
void main() {
	vec4 diffuseColor = vec4( diffuse, opacity );
	#include <clipping_planes_fragment>
	vec3 outgoingLight = vec3( 0.0 );
	#include <logdepthbuf_fragment>
	#include <map_particle_fragment>
	#include <color_fragment>
	#include <alphatest_fragment>
	#include <alphahash_fragment>
	outgoingLight = diffuseColor.rgb;
	#include <opaque_fragment>
	#include <tonemapping_fragment>
	#include <colorspace_fragment>
	#include <fog_fragment>
	#include <premultiplied_alpha_fragment>
}`,gE=`#include <common>
#include <batching_pars_vertex>
#include <fog_pars_vertex>
#include <morphtarget_pars_vertex>
#include <skinning_pars_vertex>
#include <logdepthbuf_pars_vertex>
#include <shadowmap_pars_vertex>
void main() {
	#include <batching_vertex>
	#include <beginnormal_vertex>
	#include <morphinstance_vertex>
	#include <morphnormal_vertex>
	#include <skinbase_vertex>
	#include <skinnormal_vertex>
	#include <defaultnormal_vertex>
	#include <begin_vertex>
	#include <morphtarget_vertex>
	#include <skinning_vertex>
	#include <project_vertex>
	#include <logdepthbuf_vertex>
	#include <worldpos_vertex>
	#include <shadowmap_vertex>
	#include <fog_vertex>
}`,vE=`uniform vec3 color;
uniform float opacity;
#include <common>
#include <packing>
#include <fog_pars_fragment>
#include <bsdfs>
#include <lights_pars_begin>
#include <logdepthbuf_pars_fragment>
#include <shadowmap_pars_fragment>
#include <shadowmask_pars_fragment>
void main() {
	#include <logdepthbuf_fragment>
	gl_FragColor = vec4( color, opacity * ( 1.0 - getShadowMask() ) );
	#include <tonemapping_fragment>
	#include <colorspace_fragment>
	#include <fog_fragment>
}`,_E=`uniform float rotation;
uniform vec2 center;
#include <common>
#include <uv_pars_vertex>
#include <fog_pars_vertex>
#include <logdepthbuf_pars_vertex>
#include <clipping_planes_pars_vertex>
void main() {
	#include <uv_vertex>
	vec4 mvPosition = modelViewMatrix[ 3 ];
	vec2 scale = vec2( length( modelMatrix[ 0 ].xyz ), length( modelMatrix[ 1 ].xyz ) );
	#ifndef USE_SIZEATTENUATION
		bool isPerspective = isPerspectiveMatrix( projectionMatrix );
		if ( isPerspective ) scale *= - mvPosition.z;
	#endif
	vec2 alignedPosition = ( position.xy - ( center - vec2( 0.5 ) ) ) * scale;
	vec2 rotatedPosition;
	rotatedPosition.x = cos( rotation ) * alignedPosition.x - sin( rotation ) * alignedPosition.y;
	rotatedPosition.y = sin( rotation ) * alignedPosition.x + cos( rotation ) * alignedPosition.y;
	mvPosition.xy += rotatedPosition;
	gl_Position = projectionMatrix * mvPosition;
	#include <logdepthbuf_vertex>
	#include <clipping_planes_vertex>
	#include <fog_vertex>
}`,yE=`uniform vec3 diffuse;
uniform float opacity;
#include <common>
#include <uv_pars_fragment>
#include <map_pars_fragment>
#include <alphamap_pars_fragment>
#include <alphatest_pars_fragment>
#include <alphahash_pars_fragment>
#include <fog_pars_fragment>
#include <logdepthbuf_pars_fragment>
#include <clipping_planes_pars_fragment>
void main() {
	vec4 diffuseColor = vec4( diffuse, opacity );
	#include <clipping_planes_fragment>
	vec3 outgoingLight = vec3( 0.0 );
	#include <logdepthbuf_fragment>
	#include <map_fragment>
	#include <alphamap_fragment>
	#include <alphatest_fragment>
	#include <alphahash_fragment>
	outgoingLight = diffuseColor.rgb;
	#include <opaque_fragment>
	#include <tonemapping_fragment>
	#include <colorspace_fragment>
	#include <fog_fragment>
}`,ot={alphahash_fragment:HS,alphahash_pars_fragment:VS,alphamap_fragment:GS,alphamap_pars_fragment:WS,alphatest_fragment:jS,alphatest_pars_fragment:XS,aomap_fragment:YS,aomap_pars_fragment:qS,batching_pars_vertex:QS,batching_vertex:$S,begin_vertex:KS,beginnormal_vertex:ZS,bsdfs:JS,iridescence_fragment:eb,bumpmap_pars_fragment:tb,clipping_planes_fragment:rb,clipping_planes_pars_fragment:ib,clipping_planes_pars_vertex:nb,clipping_planes_vertex:ab,color_fragment:sb,color_pars_fragment:ob,color_pars_vertex:lb,color_vertex:cb,common:ub,cube_uv_reflection_fragment:db,defaultnormal_vertex:hb,displacementmap_pars_vertex:fb,displacementmap_vertex:pb,emissivemap_fragment:mb,emissivemap_pars_fragment:gb,colorspace_fragment:vb,colorspace_pars_fragment:_b,envmap_fragment:yb,envmap_common_pars_fragment:xb,envmap_pars_fragment:Sb,envmap_pars_vertex:bb,envmap_physical_pars_fragment:Db,envmap_vertex:Mb,fog_vertex:Eb,fog_pars_vertex:wb,fog_fragment:Tb,fog_pars_fragment:Rb,gradientmap_pars_fragment:Cb,lightmap_pars_fragment:Ab,lights_lambert_fragment:Pb,lights_lambert_pars_fragment:Lb,lights_pars_begin:Ub,lights_toon_fragment:Ib,lights_toon_pars_fragment:Nb,lights_phong_fragment:Ob,lights_phong_pars_fragment:kb,lights_physical_fragment:Fb,lights_physical_pars_fragment:zb,lights_fragment_begin:Bb,lights_fragment_maps:Hb,lights_fragment_end:Vb,logdepthbuf_fragment:Gb,logdepthbuf_pars_fragment:Wb,logdepthbuf_pars_vertex:jb,logdepthbuf_vertex:Xb,map_fragment:Yb,map_pars_fragment:qb,map_particle_fragment:Qb,map_particle_pars_fragment:$b,metalnessmap_fragment:Kb,metalnessmap_pars_fragment:Zb,morphinstance_vertex:Jb,morphcolor_vertex:eM,morphnormal_vertex:tM,morphtarget_pars_vertex:rM,morphtarget_vertex:iM,normal_fragment_begin:nM,normal_fragment_maps:aM,normal_pars_fragment:sM,normal_pars_vertex:oM,normal_vertex:lM,normalmap_pars_fragment:cM,clearcoat_normal_fragment_begin:uM,clearcoat_normal_fragment_maps:dM,clearcoat_pars_fragment:hM,iridescence_pars_fragment:fM,opaque_fragment:pM,packing:mM,premultiplied_alpha_fragment:gM,project_vertex:vM,dithering_fragment:_M,dithering_pars_fragment:yM,roughnessmap_fragment:xM,roughnessmap_pars_fragment:SM,shadowmap_pars_fragment:bM,shadowmap_pars_vertex:MM,shadowmap_vertex:EM,shadowmask_pars_fragment:wM,skinbase_vertex:TM,skinning_pars_vertex:RM,skinning_vertex:CM,skinnormal_vertex:AM,specularmap_fragment:PM,specularmap_pars_fragment:LM,tonemapping_fragment:UM,tonemapping_pars_fragment:DM,transmission_fragment:IM,transmission_pars_fragment:NM,uv_pars_fragment:OM,uv_pars_vertex:kM,uv_vertex:FM,worldpos_vertex:zM,background_vert:BM,background_frag:HM,backgroundCube_vert:VM,backgroundCube_frag:GM,cube_vert:WM,cube_frag:jM,depth_vert:XM,depth_frag:YM,distanceRGBA_vert:qM,distanceRGBA_frag:QM,equirect_vert:$M,equirect_frag:KM,linedashed_vert:ZM,linedashed_frag:JM,meshbasic_vert:eE,meshbasic_frag:tE,meshlambert_vert:rE,meshlambert_frag:iE,meshmatcap_vert:nE,meshmatcap_frag:aE,meshnormal_vert:sE,meshnormal_frag:oE,meshphong_vert:lE,meshphong_frag:cE,meshphysical_vert:uE,meshphysical_frag:dE,meshtoon_vert:hE,meshtoon_frag:fE,points_vert:pE,points_frag:mE,shadow_vert:gE,shadow_frag:vE,sprite_vert:_E,sprite_frag:yE},Le={common:{diffuse:{value:new xt(16777215)},opacity:{value:1},map:{value:null},mapTransform:{value:new at},alphaMap:{value:null},alphaMapTransform:{value:new at},alphaTest:{value:0}},specularmap:{specularMap:{value:null},specularMapTransform:{value:new at}},envmap:{envMap:{value:null},envMapRotation:{value:new at},flipEnvMap:{value:-1},reflectivity:{value:1},ior:{value:1.5},refractionRatio:{value:.98}},aomap:{aoMap:{value:null},aoMapIntensity:{value:1},aoMapTransform:{value:new at}},lightmap:{lightMap:{value:null},lightMapIntensity:{value:1},lightMapTransform:{value:new at}},bumpmap:{bumpMap:{value:null},bumpMapTransform:{value:new at},bumpScale:{value:1}},normalmap:{normalMap:{value:null},normalMapTransform:{value:new at},normalScale:{value:new St(1,1)}},displacementmap:{displacementMap:{value:null},displacementMapTransform:{value:new at},displacementScale:{value:1},displacementBias:{value:0}},emissivemap:{emissiveMap:{value:null},emissiveMapTransform:{value:new at}},metalnessmap:{metalnessMap:{value:null},metalnessMapTransform:{value:new at}},roughnessmap:{roughnessMap:{value:null},roughnessMapTransform:{value:new at}},gradientmap:{gradientMap:{value:null}},fog:{fogDensity:{value:25e-5},fogNear:{value:1},fogFar:{value:2e3},fogColor:{value:new xt(16777215)}},lights:{ambientLightColor:{value:[]},lightProbe:{value:[]},directionalLights:{value:[],properties:{direction:{},color:{}}},directionalLightShadows:{value:[],properties:{shadowIntensity:1,shadowBias:{},shadowNormalBias:{},shadowRadius:{},shadowMapSize:{}}},directionalShadowMap:{value:[]},directionalShadowMatrix:{value:[]},spotLights:{value:[],properties:{color:{},position:{},direction:{},distance:{},coneCos:{},penumbraCos:{},decay:{}}},spotLightShadows:{value:[],properties:{shadowIntensity:1,shadowBias:{},shadowNormalBias:{},shadowRadius:{},shadowMapSize:{}}},spotLightMap:{value:[]},spotShadowMap:{value:[]},spotLightMatrix:{value:[]},pointLights:{value:[],properties:{color:{},position:{},decay:{},distance:{}}},pointLightShadows:{value:[],properties:{shadowIntensity:1,shadowBias:{},shadowNormalBias:{},shadowRadius:{},shadowMapSize:{},shadowCameraNear:{},shadowCameraFar:{}}},pointShadowMap:{value:[]},pointShadowMatrix:{value:[]},hemisphereLights:{value:[],properties:{direction:{},skyColor:{},groundColor:{}}},rectAreaLights:{value:[],properties:{color:{},position:{},width:{},height:{}}},ltc_1:{value:null},ltc_2:{value:null}},points:{diffuse:{value:new xt(16777215)},opacity:{value:1},size:{value:1},scale:{value:1},map:{value:null},alphaMap:{value:null},alphaMapTransform:{value:new at},alphaTest:{value:0},uvTransform:{value:new at}},sprite:{diffuse:{value:new xt(16777215)},opacity:{value:1},center:{value:new St(.5,.5)},rotation:{value:0},map:{value:null},mapTransform:{value:new at},alphaMap:{value:null},alphaMapTransform:{value:new at},alphaTest:{value:0}}},Ri={basic:{uniforms:Cr([Le.common,Le.specularmap,Le.envmap,Le.aomap,Le.lightmap,Le.fog]),vertexShader:ot.meshbasic_vert,fragmentShader:ot.meshbasic_frag},lambert:{uniforms:Cr([Le.common,Le.specularmap,Le.envmap,Le.aomap,Le.lightmap,Le.emissivemap,Le.bumpmap,Le.normalmap,Le.displacementmap,Le.fog,Le.lights,{emissive:{value:new xt(0)}}]),vertexShader:ot.meshlambert_vert,fragmentShader:ot.meshlambert_frag},phong:{uniforms:Cr([Le.common,Le.specularmap,Le.envmap,Le.aomap,Le.lightmap,Le.emissivemap,Le.bumpmap,Le.normalmap,Le.displacementmap,Le.fog,Le.lights,{emissive:{value:new xt(0)},specular:{value:new xt(1118481)},shininess:{value:30}}]),vertexShader:ot.meshphong_vert,fragmentShader:ot.meshphong_frag},standard:{uniforms:Cr([Le.common,Le.envmap,Le.aomap,Le.lightmap,Le.emissivemap,Le.bumpmap,Le.normalmap,Le.displacementmap,Le.roughnessmap,Le.metalnessmap,Le.fog,Le.lights,{emissive:{value:new xt(0)},roughness:{value:1},metalness:{value:0},envMapIntensity:{value:1}}]),vertexShader:ot.meshphysical_vert,fragmentShader:ot.meshphysical_frag},toon:{uniforms:Cr([Le.common,Le.aomap,Le.lightmap,Le.emissivemap,Le.bumpmap,Le.normalmap,Le.displacementmap,Le.gradientmap,Le.fog,Le.lights,{emissive:{value:new xt(0)}}]),vertexShader:ot.meshtoon_vert,fragmentShader:ot.meshtoon_frag},matcap:{uniforms:Cr([Le.common,Le.bumpmap,Le.normalmap,Le.displacementmap,Le.fog,{matcap:{value:null}}]),vertexShader:ot.meshmatcap_vert,fragmentShader:ot.meshmatcap_frag},points:{uniforms:Cr([Le.points,Le.fog]),vertexShader:ot.points_vert,fragmentShader:ot.points_frag},dashed:{uniforms:Cr([Le.common,Le.fog,{scale:{value:1},dashSize:{value:1},totalSize:{value:2}}]),vertexShader:ot.linedashed_vert,fragmentShader:ot.linedashed_frag},depth:{uniforms:Cr([Le.common,Le.displacementmap]),vertexShader:ot.depth_vert,fragmentShader:ot.depth_frag},normal:{uniforms:Cr([Le.common,Le.bumpmap,Le.normalmap,Le.displacementmap,{opacity:{value:1}}]),vertexShader:ot.meshnormal_vert,fragmentShader:ot.meshnormal_frag},sprite:{uniforms:Cr([Le.sprite,Le.fog]),vertexShader:ot.sprite_vert,fragmentShader:ot.sprite_frag},background:{uniforms:{uvTransform:{value:new at},t2D:{value:null},backgroundIntensity:{value:1}},vertexShader:ot.background_vert,fragmentShader:ot.background_frag},backgroundCube:{uniforms:{envMap:{value:null},flipEnvMap:{value:-1},backgroundBlurriness:{value:0},backgroundIntensity:{value:1},backgroundRotation:{value:new at}},vertexShader:ot.backgroundCube_vert,fragmentShader:ot.backgroundCube_frag},cube:{uniforms:{tCube:{value:null},tFlip:{value:-1},opacity:{value:1}},vertexShader:ot.cube_vert,fragmentShader:ot.cube_frag},equirect:{uniforms:{tEquirect:{value:null}},vertexShader:ot.equirect_vert,fragmentShader:ot.equirect_frag},distanceRGBA:{uniforms:Cr([Le.common,Le.displacementmap,{referencePosition:{value:new $},nearDistance:{value:1},farDistance:{value:1e3}}]),vertexShader:ot.distanceRGBA_vert,fragmentShader:ot.distanceRGBA_frag},shadow:{uniforms:Cr([Le.lights,Le.fog,{color:{value:new xt(0)},opacity:{value:1}}]),vertexShader:ot.shadow_vert,fragmentShader:ot.shadow_frag}};Ri.physical={uniforms:Cr([Ri.standard.uniforms,{clearcoat:{value:0},clearcoatMap:{value:null},clearcoatMapTransform:{value:new at},clearcoatNormalMap:{value:null},clearcoatNormalMapTransform:{value:new at},clearcoatNormalScale:{value:new St(1,1)},clearcoatRoughness:{value:0},clearcoatRoughnessMap:{value:null},clearcoatRoughnessMapTransform:{value:new at},dispersion:{value:0},iridescence:{value:0},iridescenceMap:{value:null},iridescenceMapTransform:{value:new at},iridescenceIOR:{value:1.3},iridescenceThicknessMinimum:{value:100},iridescenceThicknessMaximum:{value:400},iridescenceThicknessMap:{value:null},iridescenceThicknessMapTransform:{value:new at},sheen:{value:0},sheenColor:{value:new xt(0)},sheenColorMap:{value:null},sheenColorMapTransform:{value:new at},sheenRoughness:{value:1},sheenRoughnessMap:{value:null},sheenRoughnessMapTransform:{value:new at},transmission:{value:0},transmissionMap:{value:null},transmissionMapTransform:{value:new at},transmissionSamplerSize:{value:new St},transmissionSamplerMap:{value:null},thickness:{value:0},thicknessMap:{value:null},thicknessMapTransform:{value:new at},attenuationDistance:{value:0},attenuationColor:{value:new xt(0)},specularColor:{value:new xt(1,1,1)},specularColorMap:{value:null},specularColorMapTransform:{value:new at},specularIntensity:{value:1},specularIntensityMap:{value:null},specularIntensityMapTransform:{value:new at},anisotropyVector:{value:new St},anisotropyMap:{value:null},anisotropyMapTransform:{value:new at}}]),vertexShader:ot.meshphysical_vert,fragmentShader:ot.meshphysical_frag};const hc={r:0,b:0,g:0},ha=new Li,xE=new Yt;function SE(o,t,i,a,l,u,h){const f=new xt(0);let m=u===!0?0:1,p,_,y=null,x=0,b=null;function R(L){let C=L.isScene===!0?L.background:null;return C&&C.isTexture&&(C=(L.backgroundBlurriness>0?i:t).get(C)),C}function A(L){let C=!1;const G=R(L);G===null?v(f,m):G&&G.isColor&&(v(G,1),C=!0);const k=o.xr.getEnvironmentBlendMode();k==="additive"?a.buffers.color.setClear(0,0,0,1,h):k==="alpha-blend"&&a.buffers.color.setClear(0,0,0,0,h),(o.autoClear||C)&&(a.buffers.depth.setTest(!0),a.buffers.depth.setMask(!0),a.buffers.color.setMask(!0),o.clear(o.autoClearColor,o.autoClearDepth,o.autoClearStencil))}function S(L,C){const G=R(C);G&&(G.isCubeTexture||G.mapping===Tc)?(_===void 0&&(_=new si(new Oo(1,1,1),new Vn({name:"BackgroundCubeMaterial",uniforms:bs(Ri.backgroundCube.uniforms),vertexShader:Ri.backgroundCube.vertexShader,fragmentShader:Ri.backgroundCube.fragmentShader,side:zr,depthTest:!1,depthWrite:!1,fog:!1,allowOverride:!1})),_.geometry.deleteAttribute("normal"),_.geometry.deleteAttribute("uv"),_.onBeforeRender=function(k,I,H){this.matrixWorld.copyPosition(H.matrixWorld)},Object.defineProperty(_.material,"envMap",{get:function(){return this.uniforms.envMap.value}}),l.update(_)),ha.copy(C.backgroundRotation),ha.x*=-1,ha.y*=-1,ha.z*=-1,G.isCubeTexture&&G.isRenderTargetTexture===!1&&(ha.y*=-1,ha.z*=-1),_.material.uniforms.envMap.value=G,_.material.uniforms.flipEnvMap.value=G.isCubeTexture&&G.isRenderTargetTexture===!1?-1:1,_.material.uniforms.backgroundBlurriness.value=C.backgroundBlurriness,_.material.uniforms.backgroundIntensity.value=C.backgroundIntensity,_.material.uniforms.backgroundRotation.value.setFromMatrix4(xE.makeRotationFromEuler(ha)),_.material.toneMapped=Tt.getTransfer(G.colorSpace)!==kt,(y!==G||x!==G.version||b!==o.toneMapping)&&(_.material.needsUpdate=!0,y=G,x=G.version,b=o.toneMapping),_.layers.enableAll(),L.unshift(_,_.geometry,_.material,0,0,null)):G&&G.isTexture&&(p===void 0&&(p=new si(new Rc(2,2),new Vn({name:"BackgroundMaterial",uniforms:bs(Ri.background.uniforms),vertexShader:Ri.background.vertexShader,fragmentShader:Ri.background.fragmentShader,side:Hn,depthTest:!1,depthWrite:!1,fog:!1,allowOverride:!1})),p.geometry.deleteAttribute("normal"),Object.defineProperty(p.material,"map",{get:function(){return this.uniforms.t2D.value}}),l.update(p)),p.material.uniforms.t2D.value=G,p.material.uniforms.backgroundIntensity.value=C.backgroundIntensity,p.material.toneMapped=Tt.getTransfer(G.colorSpace)!==kt,G.matrixAutoUpdate===!0&&G.updateMatrix(),p.material.uniforms.uvTransform.value.copy(G.matrix),(y!==G||x!==G.version||b!==o.toneMapping)&&(p.material.needsUpdate=!0,y=G,x=G.version,b=o.toneMapping),p.layers.enableAll(),L.unshift(p,p.geometry,p.material,0,0,null))}function v(L,C){L.getRGB(hc,H_(o)),a.buffers.color.setClear(hc.r,hc.g,hc.b,C,h)}function D(){_!==void 0&&(_.geometry.dispose(),_.material.dispose(),_=void 0),p!==void 0&&(p.geometry.dispose(),p.material.dispose(),p=void 0)}return{getClearColor:function(){return f},setClearColor:function(L,C=1){f.set(L),m=C,v(f,m)},getClearAlpha:function(){return m},setClearAlpha:function(L){m=L,v(f,m)},render:A,addToRenderList:S,dispose:D}}function bE(o,t){const i=o.getParameter(o.MAX_VERTEX_ATTRIBS),a={},l=x(null);let u=l,h=!1;function f(w,F,te,se,ce){let ve=!1;const N=y(se,te,F);u!==N&&(u=N,p(u.object)),ve=b(w,se,te,ce),ve&&R(w,se,te,ce),ce!==null&&t.update(ce,o.ELEMENT_ARRAY_BUFFER),(ve||h)&&(h=!1,C(w,F,te,se),ce!==null&&o.bindBuffer(o.ELEMENT_ARRAY_BUFFER,t.get(ce).buffer))}function m(){return o.createVertexArray()}function p(w){return o.bindVertexArray(w)}function _(w){return o.deleteVertexArray(w)}function y(w,F,te){const se=te.wireframe===!0;let ce=a[w.id];ce===void 0&&(ce={},a[w.id]=ce);let ve=ce[F.id];ve===void 0&&(ve={},ce[F.id]=ve);let N=ve[se];return N===void 0&&(N=x(m()),ve[se]=N),N}function x(w){const F=[],te=[],se=[];for(let ce=0;ce<i;ce++)F[ce]=0,te[ce]=0,se[ce]=0;return{geometry:null,program:null,wireframe:!1,newAttributes:F,enabledAttributes:te,attributeDivisors:se,object:w,attributes:{},index:null}}function b(w,F,te,se){const ce=u.attributes,ve=F.attributes;let N=0;const K=te.getAttributes();for(const q in K)if(K[q].location>=0){const ge=ce[q];let we=ve[q];if(we===void 0&&(q==="instanceMatrix"&&w.instanceMatrix&&(we=w.instanceMatrix),q==="instanceColor"&&w.instanceColor&&(we=w.instanceColor)),ge===void 0||ge.attribute!==we||we&&ge.data!==we.data)return!0;N++}return u.attributesNum!==N||u.index!==se}function R(w,F,te,se){const ce={},ve=F.attributes;let N=0;const K=te.getAttributes();for(const q in K)if(K[q].location>=0){let ge=ve[q];ge===void 0&&(q==="instanceMatrix"&&w.instanceMatrix&&(ge=w.instanceMatrix),q==="instanceColor"&&w.instanceColor&&(ge=w.instanceColor));const we={};we.attribute=ge,ge&&ge.data&&(we.data=ge.data),ce[q]=we,N++}u.attributes=ce,u.attributesNum=N,u.index=se}function A(){const w=u.newAttributes;for(let F=0,te=w.length;F<te;F++)w[F]=0}function S(w){v(w,0)}function v(w,F){const te=u.newAttributes,se=u.enabledAttributes,ce=u.attributeDivisors;te[w]=1,se[w]===0&&(o.enableVertexAttribArray(w),se[w]=1),ce[w]!==F&&(o.vertexAttribDivisor(w,F),ce[w]=F)}function D(){const w=u.newAttributes,F=u.enabledAttributes;for(let te=0,se=F.length;te<se;te++)F[te]!==w[te]&&(o.disableVertexAttribArray(te),F[te]=0)}function L(w,F,te,se,ce,ve,N){N===!0?o.vertexAttribIPointer(w,F,te,ce,ve):o.vertexAttribPointer(w,F,te,se,ce,ve)}function C(w,F,te,se){A();const ce=se.attributes,ve=te.getAttributes(),N=F.defaultAttributeValues;for(const K in ve){const q=ve[K];if(q.location>=0){let ge=ce[K];if(ge===void 0&&(K==="instanceMatrix"&&w.instanceMatrix&&(ge=w.instanceMatrix),K==="instanceColor"&&w.instanceColor&&(ge=w.instanceColor)),ge!==void 0){const we=ge.normalized,O=ge.itemSize,ie=t.get(ge);if(ie===void 0)continue;const xe=ie.buffer,Q=ie.type,ue=ie.bytesPerElement,Me=Q===o.INT||Q===o.UNSIGNED_INT||ge.gpuType===sf;if(ge.isInterleavedBufferAttribute){const ye=ge.data,ke=ye.stride,Fe=ge.offset;if(ye.isInstancedInterleavedBuffer){for(let tt=0;tt<q.locationSize;tt++)v(q.location+tt,ye.meshPerAttribute);w.isInstancedMesh!==!0&&se._maxInstanceCount===void 0&&(se._maxInstanceCount=ye.meshPerAttribute*ye.count)}else for(let tt=0;tt<q.locationSize;tt++)S(q.location+tt);o.bindBuffer(o.ARRAY_BUFFER,xe);for(let tt=0;tt<q.locationSize;tt++)L(q.location+tt,O/q.locationSize,Q,we,ke*ue,(Fe+O/q.locationSize*tt)*ue,Me)}else{if(ge.isInstancedBufferAttribute){for(let ye=0;ye<q.locationSize;ye++)v(q.location+ye,ge.meshPerAttribute);w.isInstancedMesh!==!0&&se._maxInstanceCount===void 0&&(se._maxInstanceCount=ge.meshPerAttribute*ge.count)}else for(let ye=0;ye<q.locationSize;ye++)S(q.location+ye);o.bindBuffer(o.ARRAY_BUFFER,xe);for(let ye=0;ye<q.locationSize;ye++)L(q.location+ye,O/q.locationSize,Q,we,O*ue,O/q.locationSize*ye*ue,Me)}}else if(N!==void 0){const we=N[K];if(we!==void 0)switch(we.length){case 2:o.vertexAttrib2fv(q.location,we);break;case 3:o.vertexAttrib3fv(q.location,we);break;case 4:o.vertexAttrib4fv(q.location,we);break;default:o.vertexAttrib1fv(q.location,we)}}}}D()}function G(){H();for(const w in a){const F=a[w];for(const te in F){const se=F[te];for(const ce in se)_(se[ce].object),delete se[ce];delete F[te]}delete a[w]}}function k(w){if(a[w.id]===void 0)return;const F=a[w.id];for(const te in F){const se=F[te];for(const ce in se)_(se[ce].object),delete se[ce];delete F[te]}delete a[w.id]}function I(w){for(const F in a){const te=a[F];if(te[w.id]===void 0)continue;const se=te[w.id];for(const ce in se)_(se[ce].object),delete se[ce];delete te[w.id]}}function H(){P(),h=!0,u!==l&&(u=l,p(u.object))}function P(){l.geometry=null,l.program=null,l.wireframe=!1}return{setup:f,reset:H,resetDefaultState:P,dispose:G,releaseStatesOfGeometry:k,releaseStatesOfProgram:I,initAttributes:A,enableAttribute:S,disableUnusedAttributes:D}}function ME(o,t,i){let a;function l(p){a=p}function u(p,_){o.drawArrays(a,p,_),i.update(_,a,1)}function h(p,_,y){y!==0&&(o.drawArraysInstanced(a,p,_,y),i.update(_,a,y))}function f(p,_,y){if(y===0)return;t.get("WEBGL_multi_draw").multiDrawArraysWEBGL(a,p,0,_,0,y);let x=0;for(let b=0;b<y;b++)x+=_[b];i.update(x,a,1)}function m(p,_,y,x){if(y===0)return;const b=t.get("WEBGL_multi_draw");if(b===null)for(let R=0;R<p.length;R++)h(p[R],_[R],x[R]);else{b.multiDrawArraysInstancedWEBGL(a,p,0,_,0,x,0,y);let R=0;for(let A=0;A<y;A++)R+=_[A]*x[A];i.update(R,a,1)}}this.setMode=l,this.render=u,this.renderInstances=h,this.renderMultiDraw=f,this.renderMultiDrawInstances=m}function EE(o,t,i,a){let l;function u(){if(l!==void 0)return l;if(t.has("EXT_texture_filter_anisotropic")===!0){const I=t.get("EXT_texture_filter_anisotropic");l=o.getParameter(I.MAX_TEXTURE_MAX_ANISOTROPY_EXT)}else l=0;return l}function h(I){return!(I!==xi&&a.convert(I)!==o.getParameter(o.IMPLEMENTATION_COLOR_READ_FORMAT))}function f(I){const H=I===Lo&&(t.has("EXT_color_buffer_half_float")||t.has("EXT_color_buffer_float"));return!(I!==Pi&&a.convert(I)!==o.getParameter(o.IMPLEMENTATION_COLOR_READ_TYPE)&&I!==sn&&!H)}function m(I){if(I==="highp"){if(o.getShaderPrecisionFormat(o.VERTEX_SHADER,o.HIGH_FLOAT).precision>0&&o.getShaderPrecisionFormat(o.FRAGMENT_SHADER,o.HIGH_FLOAT).precision>0)return"highp";I="mediump"}return I==="mediump"&&o.getShaderPrecisionFormat(o.VERTEX_SHADER,o.MEDIUM_FLOAT).precision>0&&o.getShaderPrecisionFormat(o.FRAGMENT_SHADER,o.MEDIUM_FLOAT).precision>0?"mediump":"lowp"}let p=i.precision!==void 0?i.precision:"highp";const _=m(p);_!==p&&(console.warn("THREE.WebGLRenderer:",p,"not supported, using",_,"instead."),p=_);const y=i.logarithmicDepthBuffer===!0,x=i.reverseDepthBuffer===!0&&t.has("EXT_clip_control"),b=o.getParameter(o.MAX_TEXTURE_IMAGE_UNITS),R=o.getParameter(o.MAX_VERTEX_TEXTURE_IMAGE_UNITS),A=o.getParameter(o.MAX_TEXTURE_SIZE),S=o.getParameter(o.MAX_CUBE_MAP_TEXTURE_SIZE),v=o.getParameter(o.MAX_VERTEX_ATTRIBS),D=o.getParameter(o.MAX_VERTEX_UNIFORM_VECTORS),L=o.getParameter(o.MAX_VARYING_VECTORS),C=o.getParameter(o.MAX_FRAGMENT_UNIFORM_VECTORS),G=R>0,k=o.getParameter(o.MAX_SAMPLES);return{isWebGL2:!0,getMaxAnisotropy:u,getMaxPrecision:m,textureFormatReadable:h,textureTypeReadable:f,precision:p,logarithmicDepthBuffer:y,reverseDepthBuffer:x,maxTextures:b,maxVertexTextures:R,maxTextureSize:A,maxCubemapSize:S,maxAttributes:v,maxVertexUniforms:D,maxVaryings:L,maxFragmentUniforms:C,vertexTextures:G,maxSamples:k}}function wE(o){const t=this;let i=null,a=0,l=!1,u=!1;const h=new pa,f=new at,m={value:null,needsUpdate:!1};this.uniform=m,this.numPlanes=0,this.numIntersection=0,this.init=function(y,x){const b=y.length!==0||x||a!==0||l;return l=x,a=y.length,b},this.beginShadows=function(){u=!0,_(null)},this.endShadows=function(){u=!1},this.setGlobalState=function(y,x){i=_(y,x,0)},this.setState=function(y,x,b){const R=y.clippingPlanes,A=y.clipIntersection,S=y.clipShadows,v=o.get(y);if(!l||R===null||R.length===0||u&&!S)u?_(null):p();else{const D=u?0:a,L=D*4;let C=v.clippingState||null;m.value=C,C=_(R,x,L,b);for(let G=0;G!==L;++G)C[G]=i[G];v.clippingState=C,this.numIntersection=A?this.numPlanes:0,this.numPlanes+=D}};function p(){m.value!==i&&(m.value=i,m.needsUpdate=a>0),t.numPlanes=a,t.numIntersection=0}function _(y,x,b,R){const A=y!==null?y.length:0;let S=null;if(A!==0){if(S=m.value,R!==!0||S===null){const v=b+A*4,D=x.matrixWorldInverse;f.getNormalMatrix(D),(S===null||S.length<v)&&(S=new Float32Array(v));for(let L=0,C=b;L!==A;++L,C+=4)h.copy(y[L]).applyMatrix4(D,f),h.normal.toArray(S,C),S[C+3]=h.constant}m.value=S,m.needsUpdate=!0}return t.numPlanes=A,t.numIntersection=0,S}}function TE(o){let t=new WeakMap;function i(h,f){return f===wh?h.mapping=ys:f===Th&&(h.mapping=xs),h}function a(h){if(h&&h.isTexture){const f=h.mapping;if(f===wh||f===Th)if(t.has(h)){const m=t.get(h).texture;return i(m,h.mapping)}else{const m=h.image;if(m&&m.height>0){const p=new TS(m.height);return p.fromEquirectangularTexture(o,h),t.set(h,p),h.addEventListener("dispose",l),i(p.texture,h.mapping)}else return null}}return h}function l(h){const f=h.target;f.removeEventListener("dispose",l);const m=t.get(f);m!==void 0&&(t.delete(f),m.dispose())}function u(){t=new WeakMap}return{get:a,dispose:u}}const ms=4,Yv=[.125,.215,.35,.446,.526,.582],va=20,uh=new X_,qv=new xt;let dh=null,hh=0,fh=0,ph=!1;const ma=(1+Math.sqrt(5))/2,ps=1/ma,Qv=[new $(-ma,ps,0),new $(ma,ps,0),new $(-ps,0,ma),new $(ps,0,ma),new $(0,ma,-ps),new $(0,ma,ps),new $(-1,1,-1),new $(1,1,-1),new $(-1,1,1),new $(1,1,1)],RE=new $;class $v{constructor(t){this._renderer=t,this._pingPongRenderTarget=null,this._lodMax=0,this._cubeSize=0,this._lodPlanes=[],this._sizeLods=[],this._sigmas=[],this._blurMaterial=null,this._cubemapMaterial=null,this._equirectMaterial=null,this._compileMaterial(this._blurMaterial)}fromScene(t,i=0,a=.1,l=100,u={}){const{size:h=256,position:f=RE}=u;dh=this._renderer.getRenderTarget(),hh=this._renderer.getActiveCubeFace(),fh=this._renderer.getActiveMipmapLevel(),ph=this._renderer.xr.enabled,this._renderer.xr.enabled=!1,this._setSize(h);const m=this._allocateTargets();return m.depthBuffer=!0,this._sceneToCubeUV(t,a,l,m,f),i>0&&this._blur(m,0,0,i),this._applyPMREM(m),this._cleanup(m),m}fromEquirectangular(t,i=null){return this._fromTexture(t,i)}fromCubemap(t,i=null){return this._fromTexture(t,i)}compileCubemapShader(){this._cubemapMaterial===null&&(this._cubemapMaterial=Jv(),this._compileMaterial(this._cubemapMaterial))}compileEquirectangularShader(){this._equirectMaterial===null&&(this._equirectMaterial=Zv(),this._compileMaterial(this._equirectMaterial))}dispose(){this._dispose(),this._cubemapMaterial!==null&&this._cubemapMaterial.dispose(),this._equirectMaterial!==null&&this._equirectMaterial.dispose()}_setSize(t){this._lodMax=Math.floor(Math.log2(t)),this._cubeSize=Math.pow(2,this._lodMax)}_dispose(){this._blurMaterial!==null&&this._blurMaterial.dispose(),this._pingPongRenderTarget!==null&&this._pingPongRenderTarget.dispose();for(let t=0;t<this._lodPlanes.length;t++)this._lodPlanes[t].dispose()}_cleanup(t){this._renderer.setRenderTarget(dh,hh,fh),this._renderer.xr.enabled=ph,t.scissorTest=!1,fc(t,0,0,t.width,t.height)}_fromTexture(t,i){t.mapping===ys||t.mapping===xs?this._setSize(t.image.length===0?16:t.image[0].width||t.image[0].image.width):this._setSize(t.image.width/4),dh=this._renderer.getRenderTarget(),hh=this._renderer.getActiveCubeFace(),fh=this._renderer.getActiveMipmapLevel(),ph=this._renderer.xr.enabled,this._renderer.xr.enabled=!1;const a=i||this._allocateTargets();return this._textureToCubeUV(t,a),this._applyPMREM(a),this._cleanup(a),a}_allocateTargets(){const t=3*Math.max(this._cubeSize,112),i=4*this._cubeSize,a={magFilter:Ci,minFilter:Ci,generateMipmaps:!1,type:Lo,format:xi,colorSpace:Ss,depthBuffer:!1},l=Kv(t,i,a);if(this._pingPongRenderTarget===null||this._pingPongRenderTarget.width!==t||this._pingPongRenderTarget.height!==i){this._pingPongRenderTarget!==null&&this._dispose(),this._pingPongRenderTarget=Kv(t,i,a);const{_lodMax:u}=this;({sizeLods:this._sizeLods,lodPlanes:this._lodPlanes,sigmas:this._sigmas}=CE(u)),this._blurMaterial=AE(u,t,i)}return l}_compileMaterial(t){const i=new si(this._lodPlanes[0],t);this._renderer.compile(i,uh)}_sceneToCubeUV(t,i,a,l,u){const h=new $r(90,1,i,a),f=[1,-1,1,1,1,1],m=[1,1,1,-1,-1,-1],p=this._renderer,_=p.autoClear,y=p.toneMapping;p.getClearColor(qv),p.toneMapping=Bn,p.autoClear=!1;const x=new pf({name:"PMREM.Background",side:zr,depthWrite:!1,depthTest:!1}),b=new si(new Oo,x);let R=!1;const A=t.background;A?A.isColor&&(x.color.copy(A),t.background=null,R=!0):(x.color.copy(qv),R=!0);for(let S=0;S<6;S++){const v=S%3;v===0?(h.up.set(0,f[S],0),h.position.set(u.x,u.y,u.z),h.lookAt(u.x+m[S],u.y,u.z)):v===1?(h.up.set(0,0,f[S]),h.position.set(u.x,u.y,u.z),h.lookAt(u.x,u.y+m[S],u.z)):(h.up.set(0,f[S],0),h.position.set(u.x,u.y,u.z),h.lookAt(u.x,u.y,u.z+m[S]));const D=this._cubeSize;fc(l,v*D,S>2?D:0,D,D),p.setRenderTarget(l),R&&p.render(b,h),p.render(t,h)}b.geometry.dispose(),b.material.dispose(),p.toneMapping=y,p.autoClear=_,t.background=A}_textureToCubeUV(t,i){const a=this._renderer,l=t.mapping===ys||t.mapping===xs;l?(this._cubemapMaterial===null&&(this._cubemapMaterial=Jv()),this._cubemapMaterial.uniforms.flipEnvMap.value=t.isRenderTargetTexture===!1?-1:1):this._equirectMaterial===null&&(this._equirectMaterial=Zv());const u=l?this._cubemapMaterial:this._equirectMaterial,h=new si(this._lodPlanes[0],u),f=u.uniforms;f.envMap.value=t;const m=this._cubeSize;fc(i,0,0,3*m,2*m),a.setRenderTarget(i),a.render(h,uh)}_applyPMREM(t){const i=this._renderer,a=i.autoClear;i.autoClear=!1;const l=this._lodPlanes.length;for(let u=1;u<l;u++){const h=Math.sqrt(this._sigmas[u]*this._sigmas[u]-this._sigmas[u-1]*this._sigmas[u-1]),f=Qv[(l-u-1)%Qv.length];this._blur(t,u-1,u,h,f)}i.autoClear=a}_blur(t,i,a,l,u){const h=this._pingPongRenderTarget;this._halfBlur(t,h,i,a,l,"latitudinal",u),this._halfBlur(h,t,a,a,l,"longitudinal",u)}_halfBlur(t,i,a,l,u,h,f){const m=this._renderer,p=this._blurMaterial;h!=="latitudinal"&&h!=="longitudinal"&&console.error("blur direction must be either latitudinal or longitudinal!");const _=3,y=new si(this._lodPlanes[l],p),x=p.uniforms,b=this._sizeLods[a]-1,R=isFinite(u)?Math.PI/(2*b):2*Math.PI/(2*va-1),A=u/R,S=isFinite(u)?1+Math.floor(_*A):va;S>va&&console.warn(`sigmaRadians, ${u}, is too large and will clip, as it requested ${S} samples when the maximum is set to ${va}`);const v=[];let D=0;for(let I=0;I<va;++I){const H=I/A,P=Math.exp(-H*H/2);v.push(P),I===0?D+=P:I<S&&(D+=2*P)}for(let I=0;I<v.length;I++)v[I]=v[I]/D;x.envMap.value=t.texture,x.samples.value=S,x.weights.value=v,x.latitudinal.value=h==="latitudinal",f&&(x.poleAxis.value=f);const{_lodMax:L}=this;x.dTheta.value=R,x.mipInt.value=L-a;const C=this._sizeLods[l],G=3*C*(l>L-ms?l-L+ms:0),k=4*(this._cubeSize-C);fc(i,G,k,3*C,2*C),m.setRenderTarget(i),m.render(y,uh)}}function CE(o){const t=[],i=[],a=[];let l=o;const u=o-ms+1+Yv.length;for(let h=0;h<u;h++){const f=Math.pow(2,l);i.push(f);let m=1/f;h>o-ms?m=Yv[h-o+ms-1]:h===0&&(m=0),a.push(m);const p=1/(f-2),_=-p,y=1+p,x=[_,_,y,_,y,y,_,_,y,y,_,y],b=6,R=6,A=3,S=2,v=1,D=new Float32Array(A*R*b),L=new Float32Array(S*R*b),C=new Float32Array(v*R*b);for(let k=0;k<b;k++){const I=k%3*2/3-1,H=k>2?0:-1,P=[I,H,0,I+2/3,H,0,I+2/3,H+1,0,I,H,0,I+2/3,H+1,0,I,H+1,0];D.set(P,A*R*k),L.set(x,S*R*k);const w=[k,k,k,k,k,k];C.set(w,v*R*k)}const G=new Ui;G.setAttribute("position",new Ai(D,A)),G.setAttribute("uv",new Ai(L,S)),G.setAttribute("faceIndex",new Ai(C,v)),t.push(G),l>ms&&l--}return{lodPlanes:t,sizeLods:i,sigmas:a}}function Kv(o,t,i){const a=new Sa(o,t,i);return a.texture.mapping=Tc,a.texture.name="PMREM.cubeUv",a.scissorTest=!0,a}function fc(o,t,i,a,l){o.viewport.set(t,i,a,l),o.scissor.set(t,i,a,l)}function AE(o,t,i){const a=new Float32Array(va),l=new $(0,1,0);return new Vn({name:"SphericalGaussianBlur",defines:{n:va,CUBEUV_TEXEL_WIDTH:1/t,CUBEUV_TEXEL_HEIGHT:1/i,CUBEUV_MAX_MIP:`${o}.0`},uniforms:{envMap:{value:null},samples:{value:1},weights:{value:a},latitudinal:{value:!1},dTheta:{value:0},mipInt:{value:0},poleAxis:{value:l}},vertexShader:bf(),fragmentShader:`

			precision mediump float;
			precision mediump int;

			varying vec3 vOutputDirection;

			uniform sampler2D envMap;
			uniform int samples;
			uniform float weights[ n ];
			uniform bool latitudinal;
			uniform float dTheta;
			uniform float mipInt;
			uniform vec3 poleAxis;

			#define ENVMAP_TYPE_CUBE_UV
			#include <cube_uv_reflection_fragment>

			vec3 getSample( float theta, vec3 axis ) {

				float cosTheta = cos( theta );
				// Rodrigues' axis-angle rotation
				vec3 sampleDirection = vOutputDirection * cosTheta
					+ cross( axis, vOutputDirection ) * sin( theta )
					+ axis * dot( axis, vOutputDirection ) * ( 1.0 - cosTheta );

				return bilinearCubeUV( envMap, sampleDirection, mipInt );

			}

			void main() {

				vec3 axis = latitudinal ? poleAxis : cross( poleAxis, vOutputDirection );

				if ( all( equal( axis, vec3( 0.0 ) ) ) ) {

					axis = vec3( vOutputDirection.z, 0.0, - vOutputDirection.x );

				}

				axis = normalize( axis );

				gl_FragColor = vec4( 0.0, 0.0, 0.0, 1.0 );
				gl_FragColor.rgb += weights[ 0 ] * getSample( 0.0, axis );

				for ( int i = 1; i < n; i++ ) {

					if ( i >= samples ) {

						break;

					}

					float theta = dTheta * float( i );
					gl_FragColor.rgb += weights[ i ] * getSample( -1.0 * theta, axis );
					gl_FragColor.rgb += weights[ i ] * getSample( theta, axis );

				}

			}
		`,blending:zn,depthTest:!1,depthWrite:!1})}function Zv(){return new Vn({name:"EquirectangularToCubeUV",uniforms:{envMap:{value:null}},vertexShader:bf(),fragmentShader:`

			precision mediump float;
			precision mediump int;

			varying vec3 vOutputDirection;

			uniform sampler2D envMap;

			#include <common>

			void main() {

				vec3 outputDirection = normalize( vOutputDirection );
				vec2 uv = equirectUv( outputDirection );

				gl_FragColor = vec4( texture2D ( envMap, uv ).rgb, 1.0 );

			}
		`,blending:zn,depthTest:!1,depthWrite:!1})}function Jv(){return new Vn({name:"CubemapToCubeUV",uniforms:{envMap:{value:null},flipEnvMap:{value:-1}},vertexShader:bf(),fragmentShader:`

			precision mediump float;
			precision mediump int;

			uniform float flipEnvMap;

			varying vec3 vOutputDirection;

			uniform samplerCube envMap;

			void main() {

				gl_FragColor = textureCube( envMap, vec3( flipEnvMap * vOutputDirection.x, vOutputDirection.yz ) );

			}
		`,blending:zn,depthTest:!1,depthWrite:!1})}function bf(){return`

		precision mediump float;
		precision mediump int;

		attribute float faceIndex;

		varying vec3 vOutputDirection;

		// RH coordinate system; PMREM face-indexing convention
		vec3 getDirection( vec2 uv, float face ) {

			uv = 2.0 * uv - 1.0;

			vec3 direction = vec3( uv, 1.0 );

			if ( face == 0.0 ) {

				direction = direction.zyx; // ( 1, v, u ) pos x

			} else if ( face == 1.0 ) {

				direction = direction.xzy;
				direction.xz *= -1.0; // ( -u, 1, -v ) pos y

			} else if ( face == 2.0 ) {

				direction.x *= -1.0; // ( -u, v, 1 ) pos z

			} else if ( face == 3.0 ) {

				direction = direction.zyx;
				direction.xz *= -1.0; // ( -1, v, -u ) neg x

			} else if ( face == 4.0 ) {

				direction = direction.xzy;
				direction.xy *= -1.0; // ( -u, -1, v ) neg y

			} else if ( face == 5.0 ) {

				direction.z *= -1.0; // ( u, v, -1 ) neg z

			}

			return direction;

		}

		void main() {

			vOutputDirection = getDirection( uv, faceIndex );
			gl_Position = vec4( position, 1.0 );

		}
	`}function PE(o){let t=new WeakMap,i=null;function a(f){if(f&&f.isTexture){const m=f.mapping,p=m===wh||m===Th,_=m===ys||m===xs;if(p||_){let y=t.get(f);const x=y!==void 0?y.texture.pmremVersion:0;if(f.isRenderTargetTexture&&f.pmremVersion!==x)return i===null&&(i=new $v(o)),y=p?i.fromEquirectangular(f,y):i.fromCubemap(f,y),y.texture.pmremVersion=f.pmremVersion,t.set(f,y),y.texture;if(y!==void 0)return y.texture;{const b=f.image;return p&&b&&b.height>0||_&&b&&l(b)?(i===null&&(i=new $v(o)),y=p?i.fromEquirectangular(f):i.fromCubemap(f),y.texture.pmremVersion=f.pmremVersion,t.set(f,y),f.addEventListener("dispose",u),y.texture):null}}}return f}function l(f){let m=0;const p=6;for(let _=0;_<p;_++)f[_]!==void 0&&m++;return m===p}function u(f){const m=f.target;m.removeEventListener("dispose",u);const p=t.get(m);p!==void 0&&(t.delete(m),p.dispose())}function h(){t=new WeakMap,i!==null&&(i.dispose(),i=null)}return{get:a,dispose:h}}function LE(o){const t={};function i(a){if(t[a]!==void 0)return t[a];let l;switch(a){case"WEBGL_depth_texture":l=o.getExtension("WEBGL_depth_texture")||o.getExtension("MOZ_WEBGL_depth_texture")||o.getExtension("WEBKIT_WEBGL_depth_texture");break;case"EXT_texture_filter_anisotropic":l=o.getExtension("EXT_texture_filter_anisotropic")||o.getExtension("MOZ_EXT_texture_filter_anisotropic")||o.getExtension("WEBKIT_EXT_texture_filter_anisotropic");break;case"WEBGL_compressed_texture_s3tc":l=o.getExtension("WEBGL_compressed_texture_s3tc")||o.getExtension("MOZ_WEBGL_compressed_texture_s3tc")||o.getExtension("WEBKIT_WEBGL_compressed_texture_s3tc");break;case"WEBGL_compressed_texture_pvrtc":l=o.getExtension("WEBGL_compressed_texture_pvrtc")||o.getExtension("WEBKIT_WEBGL_compressed_texture_pvrtc");break;default:l=o.getExtension(a)}return t[a]=l,l}return{has:function(a){return i(a)!==null},init:function(){i("EXT_color_buffer_float"),i("WEBGL_clip_cull_distance"),i("OES_texture_float_linear"),i("EXT_color_buffer_half_float"),i("WEBGL_multisampled_render_to_texture"),i("WEBGL_render_shared_exponent")},get:function(a){const l=i(a);return l===null&&Sc("THREE.WebGLRenderer: "+a+" extension not supported."),l}}}function UE(o,t,i,a){const l={},u=new WeakMap;function h(y){const x=y.target;x.index!==null&&t.remove(x.index);for(const R in x.attributes)t.remove(x.attributes[R]);x.removeEventListener("dispose",h),delete l[x.id];const b=u.get(x);b&&(t.remove(b),u.delete(x)),a.releaseStatesOfGeometry(x),x.isInstancedBufferGeometry===!0&&delete x._maxInstanceCount,i.memory.geometries--}function f(y,x){return l[x.id]===!0||(x.addEventListener("dispose",h),l[x.id]=!0,i.memory.geometries++),x}function m(y){const x=y.attributes;for(const b in x)t.update(x[b],o.ARRAY_BUFFER)}function p(y){const x=[],b=y.index,R=y.attributes.position;let A=0;if(b!==null){const D=b.array;A=b.version;for(let L=0,C=D.length;L<C;L+=3){const G=D[L+0],k=D[L+1],I=D[L+2];x.push(G,k,k,I,I,G)}}else if(R!==void 0){const D=R.array;A=R.version;for(let L=0,C=D.length/3-1;L<C;L+=3){const G=L+0,k=L+1,I=L+2;x.push(G,k,k,I,I,G)}}else return;const S=new(N_(x)?B_:z_)(x,1);S.version=A;const v=u.get(y);v&&t.remove(v),u.set(y,S)}function _(y){const x=u.get(y);if(x){const b=y.index;b!==null&&x.version<b.version&&p(y)}else p(y);return u.get(y)}return{get:f,update:m,getWireframeAttribute:_}}function DE(o,t,i){let a;function l(x){a=x}let u,h;function f(x){u=x.type,h=x.bytesPerElement}function m(x,b){o.drawElements(a,b,u,x*h),i.update(b,a,1)}function p(x,b,R){R!==0&&(o.drawElementsInstanced(a,b,u,x*h,R),i.update(b,a,R))}function _(x,b,R){if(R===0)return;t.get("WEBGL_multi_draw").multiDrawElementsWEBGL(a,b,0,u,x,0,R);let A=0;for(let S=0;S<R;S++)A+=b[S];i.update(A,a,1)}function y(x,b,R,A){if(R===0)return;const S=t.get("WEBGL_multi_draw");if(S===null)for(let v=0;v<x.length;v++)p(x[v]/h,b[v],A[v]);else{S.multiDrawElementsInstancedWEBGL(a,b,0,u,x,0,A,0,R);let v=0;for(let D=0;D<R;D++)v+=b[D]*A[D];i.update(v,a,1)}}this.setMode=l,this.setIndex=f,this.render=m,this.renderInstances=p,this.renderMultiDraw=_,this.renderMultiDrawInstances=y}function IE(o){const t={geometries:0,textures:0},i={frame:0,calls:0,triangles:0,points:0,lines:0};function a(u,h,f){switch(i.calls++,h){case o.TRIANGLES:i.triangles+=f*(u/3);break;case o.LINES:i.lines+=f*(u/2);break;case o.LINE_STRIP:i.lines+=f*(u-1);break;case o.LINE_LOOP:i.lines+=f*u;break;case o.POINTS:i.points+=f*u;break;default:console.error("THREE.WebGLInfo: Unknown draw mode:",h);break}}function l(){i.calls=0,i.triangles=0,i.points=0,i.lines=0}return{memory:t,render:i,programs:null,autoReset:!0,reset:l,update:a}}function NE(o,t,i){const a=new WeakMap,l=new Ft;function u(h,f,m){const p=h.morphTargetInfluences,_=f.morphAttributes.position||f.morphAttributes.normal||f.morphAttributes.color,y=_!==void 0?_.length:0;let x=a.get(f);if(x===void 0||x.count!==y){let b=function(){H.dispose(),a.delete(f),f.removeEventListener("dispose",b)};x!==void 0&&x.texture.dispose();const R=f.morphAttributes.position!==void 0,A=f.morphAttributes.normal!==void 0,S=f.morphAttributes.color!==void 0,v=f.morphAttributes.position||[],D=f.morphAttributes.normal||[],L=f.morphAttributes.color||[];let C=0;R===!0&&(C=1),A===!0&&(C=2),S===!0&&(C=3);let G=f.attributes.position.count*C,k=1;G>t.maxTextureSize&&(k=Math.ceil(G/t.maxTextureSize),G=t.maxTextureSize);const I=new Float32Array(G*k*4*y),H=new O_(I,G,k,y);H.type=sn,H.needsUpdate=!0;const P=C*4;for(let w=0;w<y;w++){const F=v[w],te=D[w],se=L[w],ce=G*k*4*w;for(let ve=0;ve<F.count;ve++){const N=ve*P;R===!0&&(l.fromBufferAttribute(F,ve),I[ce+N+0]=l.x,I[ce+N+1]=l.y,I[ce+N+2]=l.z,I[ce+N+3]=0),A===!0&&(l.fromBufferAttribute(te,ve),I[ce+N+4]=l.x,I[ce+N+5]=l.y,I[ce+N+6]=l.z,I[ce+N+7]=0),S===!0&&(l.fromBufferAttribute(se,ve),I[ce+N+8]=l.x,I[ce+N+9]=l.y,I[ce+N+10]=l.z,I[ce+N+11]=se.itemSize===4?l.w:1)}}x={count:y,texture:H,size:new St(G,k)},a.set(f,x),f.addEventListener("dispose",b)}if(h.isInstancedMesh===!0&&h.morphTexture!==null)m.getUniforms().setValue(o,"morphTexture",h.morphTexture,i);else{let b=0;for(let A=0;A<p.length;A++)b+=p[A];const R=f.morphTargetsRelative?1:1-b;m.getUniforms().setValue(o,"morphTargetBaseInfluence",R),m.getUniforms().setValue(o,"morphTargetInfluences",p)}m.getUniforms().setValue(o,"morphTargetsTexture",x.texture,i),m.getUniforms().setValue(o,"morphTargetsTextureSize",x.size)}return{update:u}}function OE(o,t,i,a){let l=new WeakMap;function u(m){const p=a.render.frame,_=m.geometry,y=t.get(m,_);if(l.get(y)!==p&&(t.update(y),l.set(y,p)),m.isInstancedMesh&&(m.hasEventListener("dispose",f)===!1&&m.addEventListener("dispose",f),l.get(m)!==p&&(i.update(m.instanceMatrix,o.ARRAY_BUFFER),m.instanceColor!==null&&i.update(m.instanceColor,o.ARRAY_BUFFER),l.set(m,p))),m.isSkinnedMesh){const x=m.skeleton;l.get(x)!==p&&(x.update(),l.set(x,p))}return y}function h(){l=new WeakMap}function f(m){const p=m.target;p.removeEventListener("dispose",f),i.remove(p.instanceMatrix),p.instanceColor!==null&&i.remove(p.instanceColor)}return{update:u,dispose:h}}const q_=new Br,e_=new W_(1,1),Q_=new O_,$_=new lS,K_=new G_,t_=[],r_=[],i_=new Float32Array(16),n_=new Float32Array(9),a_=new Float32Array(4);function Es(o,t,i){const a=o[0];if(a<=0||a>0)return o;const l=t*i;let u=t_[l];if(u===void 0&&(u=new Float32Array(l),t_[l]=u),t!==0){a.toArray(u,0);for(let h=1,f=0;h!==t;++h)f+=i,o[h].toArray(u,f)}return u}function sr(o,t){if(o.length!==t.length)return!1;for(let i=0,a=o.length;i<a;i++)if(o[i]!==t[i])return!1;return!0}function or(o,t){for(let i=0,a=t.length;i<a;i++)o[i]=t[i]}function Cc(o,t){let i=r_[t];i===void 0&&(i=new Int32Array(t),r_[t]=i);for(let a=0;a!==t;++a)i[a]=o.allocateTextureUnit();return i}function kE(o,t){const i=this.cache;i[0]!==t&&(o.uniform1f(this.addr,t),i[0]=t)}function FE(o,t){const i=this.cache;if(t.x!==void 0)(i[0]!==t.x||i[1]!==t.y)&&(o.uniform2f(this.addr,t.x,t.y),i[0]=t.x,i[1]=t.y);else{if(sr(i,t))return;o.uniform2fv(this.addr,t),or(i,t)}}function zE(o,t){const i=this.cache;if(t.x!==void 0)(i[0]!==t.x||i[1]!==t.y||i[2]!==t.z)&&(o.uniform3f(this.addr,t.x,t.y,t.z),i[0]=t.x,i[1]=t.y,i[2]=t.z);else if(t.r!==void 0)(i[0]!==t.r||i[1]!==t.g||i[2]!==t.b)&&(o.uniform3f(this.addr,t.r,t.g,t.b),i[0]=t.r,i[1]=t.g,i[2]=t.b);else{if(sr(i,t))return;o.uniform3fv(this.addr,t),or(i,t)}}function BE(o,t){const i=this.cache;if(t.x!==void 0)(i[0]!==t.x||i[1]!==t.y||i[2]!==t.z||i[3]!==t.w)&&(o.uniform4f(this.addr,t.x,t.y,t.z,t.w),i[0]=t.x,i[1]=t.y,i[2]=t.z,i[3]=t.w);else{if(sr(i,t))return;o.uniform4fv(this.addr,t),or(i,t)}}function HE(o,t){const i=this.cache,a=t.elements;if(a===void 0){if(sr(i,t))return;o.uniformMatrix2fv(this.addr,!1,t),or(i,t)}else{if(sr(i,a))return;a_.set(a),o.uniformMatrix2fv(this.addr,!1,a_),or(i,a)}}function VE(o,t){const i=this.cache,a=t.elements;if(a===void 0){if(sr(i,t))return;o.uniformMatrix3fv(this.addr,!1,t),or(i,t)}else{if(sr(i,a))return;n_.set(a),o.uniformMatrix3fv(this.addr,!1,n_),or(i,a)}}function GE(o,t){const i=this.cache,a=t.elements;if(a===void 0){if(sr(i,t))return;o.uniformMatrix4fv(this.addr,!1,t),or(i,t)}else{if(sr(i,a))return;i_.set(a),o.uniformMatrix4fv(this.addr,!1,i_),or(i,a)}}function WE(o,t){const i=this.cache;i[0]!==t&&(o.uniform1i(this.addr,t),i[0]=t)}function jE(o,t){const i=this.cache;if(t.x!==void 0)(i[0]!==t.x||i[1]!==t.y)&&(o.uniform2i(this.addr,t.x,t.y),i[0]=t.x,i[1]=t.y);else{if(sr(i,t))return;o.uniform2iv(this.addr,t),or(i,t)}}function XE(o,t){const i=this.cache;if(t.x!==void 0)(i[0]!==t.x||i[1]!==t.y||i[2]!==t.z)&&(o.uniform3i(this.addr,t.x,t.y,t.z),i[0]=t.x,i[1]=t.y,i[2]=t.z);else{if(sr(i,t))return;o.uniform3iv(this.addr,t),or(i,t)}}function YE(o,t){const i=this.cache;if(t.x!==void 0)(i[0]!==t.x||i[1]!==t.y||i[2]!==t.z||i[3]!==t.w)&&(o.uniform4i(this.addr,t.x,t.y,t.z,t.w),i[0]=t.x,i[1]=t.y,i[2]=t.z,i[3]=t.w);else{if(sr(i,t))return;o.uniform4iv(this.addr,t),or(i,t)}}function qE(o,t){const i=this.cache;i[0]!==t&&(o.uniform1ui(this.addr,t),i[0]=t)}function QE(o,t){const i=this.cache;if(t.x!==void 0)(i[0]!==t.x||i[1]!==t.y)&&(o.uniform2ui(this.addr,t.x,t.y),i[0]=t.x,i[1]=t.y);else{if(sr(i,t))return;o.uniform2uiv(this.addr,t),or(i,t)}}function $E(o,t){const i=this.cache;if(t.x!==void 0)(i[0]!==t.x||i[1]!==t.y||i[2]!==t.z)&&(o.uniform3ui(this.addr,t.x,t.y,t.z),i[0]=t.x,i[1]=t.y,i[2]=t.z);else{if(sr(i,t))return;o.uniform3uiv(this.addr,t),or(i,t)}}function KE(o,t){const i=this.cache;if(t.x!==void 0)(i[0]!==t.x||i[1]!==t.y||i[2]!==t.z||i[3]!==t.w)&&(o.uniform4ui(this.addr,t.x,t.y,t.z,t.w),i[0]=t.x,i[1]=t.y,i[2]=t.z,i[3]=t.w);else{if(sr(i,t))return;o.uniform4uiv(this.addr,t),or(i,t)}}function ZE(o,t,i){const a=this.cache,l=i.allocateTextureUnit();a[0]!==l&&(o.uniform1i(this.addr,l),a[0]=l);let u;this.type===o.SAMPLER_2D_SHADOW?(e_.compareFunction=I_,u=e_):u=q_,i.setTexture2D(t||u,l)}function JE(o,t,i){const a=this.cache,l=i.allocateTextureUnit();a[0]!==l&&(o.uniform1i(this.addr,l),a[0]=l),i.setTexture3D(t||$_,l)}function ew(o,t,i){const a=this.cache,l=i.allocateTextureUnit();a[0]!==l&&(o.uniform1i(this.addr,l),a[0]=l),i.setTextureCube(t||K_,l)}function tw(o,t,i){const a=this.cache,l=i.allocateTextureUnit();a[0]!==l&&(o.uniform1i(this.addr,l),a[0]=l),i.setTexture2DArray(t||Q_,l)}function rw(o){switch(o){case 5126:return kE;case 35664:return FE;case 35665:return zE;case 35666:return BE;case 35674:return HE;case 35675:return VE;case 35676:return GE;case 5124:case 35670:return WE;case 35667:case 35671:return jE;case 35668:case 35672:return XE;case 35669:case 35673:return YE;case 5125:return qE;case 36294:return QE;case 36295:return $E;case 36296:return KE;case 35678:case 36198:case 36298:case 36306:case 35682:return ZE;case 35679:case 36299:case 36307:return JE;case 35680:case 36300:case 36308:case 36293:return ew;case 36289:case 36303:case 36311:case 36292:return tw}}function iw(o,t){o.uniform1fv(this.addr,t)}function nw(o,t){const i=Es(t,this.size,2);o.uniform2fv(this.addr,i)}function aw(o,t){const i=Es(t,this.size,3);o.uniform3fv(this.addr,i)}function sw(o,t){const i=Es(t,this.size,4);o.uniform4fv(this.addr,i)}function ow(o,t){const i=Es(t,this.size,4);o.uniformMatrix2fv(this.addr,!1,i)}function lw(o,t){const i=Es(t,this.size,9);o.uniformMatrix3fv(this.addr,!1,i)}function cw(o,t){const i=Es(t,this.size,16);o.uniformMatrix4fv(this.addr,!1,i)}function uw(o,t){o.uniform1iv(this.addr,t)}function dw(o,t){o.uniform2iv(this.addr,t)}function hw(o,t){o.uniform3iv(this.addr,t)}function fw(o,t){o.uniform4iv(this.addr,t)}function pw(o,t){o.uniform1uiv(this.addr,t)}function mw(o,t){o.uniform2uiv(this.addr,t)}function gw(o,t){o.uniform3uiv(this.addr,t)}function vw(o,t){o.uniform4uiv(this.addr,t)}function _w(o,t,i){const a=this.cache,l=t.length,u=Cc(i,l);sr(a,u)||(o.uniform1iv(this.addr,u),or(a,u));for(let h=0;h!==l;++h)i.setTexture2D(t[h]||q_,u[h])}function yw(o,t,i){const a=this.cache,l=t.length,u=Cc(i,l);sr(a,u)||(o.uniform1iv(this.addr,u),or(a,u));for(let h=0;h!==l;++h)i.setTexture3D(t[h]||$_,u[h])}function xw(o,t,i){const a=this.cache,l=t.length,u=Cc(i,l);sr(a,u)||(o.uniform1iv(this.addr,u),or(a,u));for(let h=0;h!==l;++h)i.setTextureCube(t[h]||K_,u[h])}function Sw(o,t,i){const a=this.cache,l=t.length,u=Cc(i,l);sr(a,u)||(o.uniform1iv(this.addr,u),or(a,u));for(let h=0;h!==l;++h)i.setTexture2DArray(t[h]||Q_,u[h])}function bw(o){switch(o){case 5126:return iw;case 35664:return nw;case 35665:return aw;case 35666:return sw;case 35674:return ow;case 35675:return lw;case 35676:return cw;case 5124:case 35670:return uw;case 35667:case 35671:return dw;case 35668:case 35672:return hw;case 35669:case 35673:return fw;case 5125:return pw;case 36294:return mw;case 36295:return gw;case 36296:return vw;case 35678:case 36198:case 36298:case 36306:case 35682:return _w;case 35679:case 36299:case 36307:return yw;case 35680:case 36300:case 36308:case 36293:return xw;case 36289:case 36303:case 36311:case 36292:return Sw}}class Mw{constructor(t,i,a){this.id=t,this.addr=a,this.cache=[],this.type=i.type,this.setValue=rw(i.type)}}class Ew{constructor(t,i,a){this.id=t,this.addr=a,this.cache=[],this.type=i.type,this.size=i.size,this.setValue=bw(i.type)}}class ww{constructor(t){this.id=t,this.seq=[],this.map={}}setValue(t,i,a){const l=this.seq;for(let u=0,h=l.length;u!==h;++u){const f=l[u];f.setValue(t,i[f.id],a)}}}const mh=/(\w+)(\])?(\[|\.)?/g;function s_(o,t){o.seq.push(t),o.map[t.id]=t}function Tw(o,t,i){const a=o.name,l=a.length;for(mh.lastIndex=0;;){const u=mh.exec(a),h=mh.lastIndex;let f=u[1];const m=u[2]==="]",p=u[3];if(m&&(f=f|0),p===void 0||p==="["&&h+2===l){s_(i,p===void 0?new Mw(f,o,t):new Ew(f,o,t));break}else{let _=i.map[f];_===void 0&&(_=new ww(f),s_(i,_)),i=_}}}class bc{constructor(t,i){this.seq=[],this.map={};const a=t.getProgramParameter(i,t.ACTIVE_UNIFORMS);for(let l=0;l<a;++l){const u=t.getActiveUniform(i,l),h=t.getUniformLocation(i,u.name);Tw(u,h,this)}}setValue(t,i,a,l){const u=this.map[i];u!==void 0&&u.setValue(t,a,l)}setOptional(t,i,a){const l=i[a];l!==void 0&&this.setValue(t,a,l)}static upload(t,i,a,l){for(let u=0,h=i.length;u!==h;++u){const f=i[u],m=a[f.id];m.needsUpdate!==!1&&f.setValue(t,m.value,l)}}static seqWithValue(t,i){const a=[];for(let l=0,u=t.length;l!==u;++l){const h=t[l];h.id in i&&a.push(h)}return a}}function o_(o,t,i){const a=o.createShader(t);return o.shaderSource(a,i),o.compileShader(a),a}const Rw=37297;let Cw=0;function Aw(o,t){const i=o.split(`
`),a=[],l=Math.max(t-6,0),u=Math.min(t+6,i.length);for(let h=l;h<u;h++){const f=h+1;a.push(`${f===t?">":" "} ${f}: ${i[h]}`)}return a.join(`
`)}const l_=new at;function Pw(o){Tt._getMatrix(l_,Tt.workingColorSpace,o);const t=`mat3( ${l_.elements.map(i=>i.toFixed(4))} )`;switch(Tt.getTransfer(o)){case Mc:return[t,"LinearTransferOETF"];case kt:return[t,"sRGBTransferOETF"];default:return console.warn("THREE.WebGLProgram: Unsupported color space: ",o),[t,"LinearTransferOETF"]}}function c_(o,t,i){const a=o.getShaderParameter(t,o.COMPILE_STATUS),l=o.getShaderInfoLog(t).trim();if(a&&l==="")return"";const u=/ERROR: 0:(\d+)/.exec(l);if(u){const h=parseInt(u[1]);return i.toUpperCase()+`

`+l+`

`+Aw(o.getShaderSource(t),h)}else return l}function Lw(o,t){const i=Pw(t);return[`vec4 ${o}( vec4 value ) {`,`	return ${i[1]}( vec4( value.rgb * ${i[0]}, value.a ) );`,"}"].join(`
`)}function Uw(o,t){let i;switch(t){case Nx:i="Linear";break;case Ox:i="Reinhard";break;case kx:i="Cineon";break;case M_:i="ACESFilmic";break;case zx:i="AgX";break;case Bx:i="Neutral";break;case Fx:i="Custom";break;default:console.warn("THREE.WebGLProgram: Unsupported toneMapping:",t),i="Linear"}return"vec3 "+o+"( vec3 color ) { return "+i+"ToneMapping( color ); }"}const pc=new $;function Dw(){Tt.getLuminanceCoefficients(pc);const o=pc.x.toFixed(4),t=pc.y.toFixed(4),i=pc.z.toFixed(4);return["float luminance( const in vec3 rgb ) {",`	const vec3 weights = vec3( ${o}, ${t}, ${i} );`,"	return dot( weights, rgb );","}"].join(`
`)}function Iw(o){return[o.extensionClipCullDistance?"#extension GL_ANGLE_clip_cull_distance : require":"",o.extensionMultiDraw?"#extension GL_ANGLE_multi_draw : require":""].filter(To).join(`
`)}function Nw(o){const t=[];for(const i in o){const a=o[i];a!==!1&&t.push("#define "+i+" "+a)}return t.join(`
`)}function Ow(o,t){const i={},a=o.getProgramParameter(t,o.ACTIVE_ATTRIBUTES);for(let l=0;l<a;l++){const u=o.getActiveAttrib(t,l),h=u.name;let f=1;u.type===o.FLOAT_MAT2&&(f=2),u.type===o.FLOAT_MAT3&&(f=3),u.type===o.FLOAT_MAT4&&(f=4),i[h]={type:u.type,location:o.getAttribLocation(t,h),locationSize:f}}return i}function To(o){return o!==""}function u_(o,t){const i=t.numSpotLightShadows+t.numSpotLightMaps-t.numSpotLightShadowsWithMaps;return o.replace(/NUM_DIR_LIGHTS/g,t.numDirLights).replace(/NUM_SPOT_LIGHTS/g,t.numSpotLights).replace(/NUM_SPOT_LIGHT_MAPS/g,t.numSpotLightMaps).replace(/NUM_SPOT_LIGHT_COORDS/g,i).replace(/NUM_RECT_AREA_LIGHTS/g,t.numRectAreaLights).replace(/NUM_POINT_LIGHTS/g,t.numPointLights).replace(/NUM_HEMI_LIGHTS/g,t.numHemiLights).replace(/NUM_DIR_LIGHT_SHADOWS/g,t.numDirLightShadows).replace(/NUM_SPOT_LIGHT_SHADOWS_WITH_MAPS/g,t.numSpotLightShadowsWithMaps).replace(/NUM_SPOT_LIGHT_SHADOWS/g,t.numSpotLightShadows).replace(/NUM_POINT_LIGHT_SHADOWS/g,t.numPointLightShadows)}function d_(o,t){return o.replace(/NUM_CLIPPING_PLANES/g,t.numClippingPlanes).replace(/UNION_CLIPPING_PLANES/g,t.numClippingPlanes-t.numClipIntersection)}const kw=/^[ \t]*#include +<([\w\d./]+)>/gm;function rf(o){return o.replace(kw,zw)}const Fw=new Map;function zw(o,t){let i=ot[t];if(i===void 0){const a=Fw.get(t);if(a!==void 0)i=ot[a],console.warn('THREE.WebGLRenderer: Shader chunk "%s" has been deprecated. Use "%s" instead.',t,a);else throw new Error("Can not resolve #include <"+t+">")}return rf(i)}const Bw=/#pragma unroll_loop_start\s+for\s*\(\s*int\s+i\s*=\s*(\d+)\s*;\s*i\s*<\s*(\d+)\s*;\s*i\s*\+\+\s*\)\s*{([\s\S]+?)}\s+#pragma unroll_loop_end/g;function h_(o){return o.replace(Bw,Hw)}function Hw(o,t,i,a){let l="";for(let u=parseInt(t);u<parseInt(i);u++)l+=a.replace(/\[\s*i\s*\]/g,"[ "+u+" ]").replace(/UNROLLED_LOOP_INDEX/g,u);return l}function f_(o){let t=`precision ${o.precision} float;
	precision ${o.precision} int;
	precision ${o.precision} sampler2D;
	precision ${o.precision} samplerCube;
	precision ${o.precision} sampler3D;
	precision ${o.precision} sampler2DArray;
	precision ${o.precision} sampler2DShadow;
	precision ${o.precision} samplerCubeShadow;
	precision ${o.precision} sampler2DArrayShadow;
	precision ${o.precision} isampler2D;
	precision ${o.precision} isampler3D;
	precision ${o.precision} isamplerCube;
	precision ${o.precision} isampler2DArray;
	precision ${o.precision} usampler2D;
	precision ${o.precision} usampler3D;
	precision ${o.precision} usamplerCube;
	precision ${o.precision} usampler2DArray;
	`;return o.precision==="highp"?t+=`
#define HIGH_PRECISION`:o.precision==="mediump"?t+=`
#define MEDIUM_PRECISION`:o.precision==="lowp"&&(t+=`
#define LOW_PRECISION`),t}function Vw(o){let t="SHADOWMAP_TYPE_BASIC";return o.shadowMapType===x_?t="SHADOWMAP_TYPE_PCF":o.shadowMapType===S_?t="SHADOWMAP_TYPE_PCF_SOFT":o.shadowMapType===rn&&(t="SHADOWMAP_TYPE_VSM"),t}function Gw(o){let t="ENVMAP_TYPE_CUBE";if(o.envMap)switch(o.envMapMode){case ys:case xs:t="ENVMAP_TYPE_CUBE";break;case Tc:t="ENVMAP_TYPE_CUBE_UV";break}return t}function Ww(o){let t="ENVMAP_MODE_REFLECTION";if(o.envMap)switch(o.envMapMode){case xs:t="ENVMAP_MODE_REFRACTION";break}return t}function jw(o){let t="ENVMAP_BLENDING_NONE";if(o.envMap)switch(o.combine){case b_:t="ENVMAP_BLENDING_MULTIPLY";break;case Dx:t="ENVMAP_BLENDING_MIX";break;case Ix:t="ENVMAP_BLENDING_ADD";break}return t}function Xw(o){const t=o.envMapCubeUVHeight;if(t===null)return null;const i=Math.log2(t)-2,a=1/t;return{texelWidth:1/(3*Math.max(Math.pow(2,i),112)),texelHeight:a,maxMip:i}}function Yw(o,t,i,a){const l=o.getContext(),u=i.defines;let h=i.vertexShader,f=i.fragmentShader;const m=Vw(i),p=Gw(i),_=Ww(i),y=jw(i),x=Xw(i),b=Iw(i),R=Nw(u),A=l.createProgram();let S,v,D=i.glslVersion?"#version "+i.glslVersion+`
`:"";i.isRawShaderMaterial?(S=["#define SHADER_TYPE "+i.shaderType,"#define SHADER_NAME "+i.shaderName,R].filter(To).join(`
`),S.length>0&&(S+=`
`),v=["#define SHADER_TYPE "+i.shaderType,"#define SHADER_NAME "+i.shaderName,R].filter(To).join(`
`),v.length>0&&(v+=`
`)):(S=[f_(i),"#define SHADER_TYPE "+i.shaderType,"#define SHADER_NAME "+i.shaderName,R,i.extensionClipCullDistance?"#define USE_CLIP_DISTANCE":"",i.batching?"#define USE_BATCHING":"",i.batchingColor?"#define USE_BATCHING_COLOR":"",i.instancing?"#define USE_INSTANCING":"",i.instancingColor?"#define USE_INSTANCING_COLOR":"",i.instancingMorph?"#define USE_INSTANCING_MORPH":"",i.useFog&&i.fog?"#define USE_FOG":"",i.useFog&&i.fogExp2?"#define FOG_EXP2":"",i.map?"#define USE_MAP":"",i.envMap?"#define USE_ENVMAP":"",i.envMap?"#define "+_:"",i.lightMap?"#define USE_LIGHTMAP":"",i.aoMap?"#define USE_AOMAP":"",i.bumpMap?"#define USE_BUMPMAP":"",i.normalMap?"#define USE_NORMALMAP":"",i.normalMapObjectSpace?"#define USE_NORMALMAP_OBJECTSPACE":"",i.normalMapTangentSpace?"#define USE_NORMALMAP_TANGENTSPACE":"",i.displacementMap?"#define USE_DISPLACEMENTMAP":"",i.emissiveMap?"#define USE_EMISSIVEMAP":"",i.anisotropy?"#define USE_ANISOTROPY":"",i.anisotropyMap?"#define USE_ANISOTROPYMAP":"",i.clearcoatMap?"#define USE_CLEARCOATMAP":"",i.clearcoatRoughnessMap?"#define USE_CLEARCOAT_ROUGHNESSMAP":"",i.clearcoatNormalMap?"#define USE_CLEARCOAT_NORMALMAP":"",i.iridescenceMap?"#define USE_IRIDESCENCEMAP":"",i.iridescenceThicknessMap?"#define USE_IRIDESCENCE_THICKNESSMAP":"",i.specularMap?"#define USE_SPECULARMAP":"",i.specularColorMap?"#define USE_SPECULAR_COLORMAP":"",i.specularIntensityMap?"#define USE_SPECULAR_INTENSITYMAP":"",i.roughnessMap?"#define USE_ROUGHNESSMAP":"",i.metalnessMap?"#define USE_METALNESSMAP":"",i.alphaMap?"#define USE_ALPHAMAP":"",i.alphaHash?"#define USE_ALPHAHASH":"",i.transmission?"#define USE_TRANSMISSION":"",i.transmissionMap?"#define USE_TRANSMISSIONMAP":"",i.thicknessMap?"#define USE_THICKNESSMAP":"",i.sheenColorMap?"#define USE_SHEEN_COLORMAP":"",i.sheenRoughnessMap?"#define USE_SHEEN_ROUGHNESSMAP":"",i.mapUv?"#define MAP_UV "+i.mapUv:"",i.alphaMapUv?"#define ALPHAMAP_UV "+i.alphaMapUv:"",i.lightMapUv?"#define LIGHTMAP_UV "+i.lightMapUv:"",i.aoMapUv?"#define AOMAP_UV "+i.aoMapUv:"",i.emissiveMapUv?"#define EMISSIVEMAP_UV "+i.emissiveMapUv:"",i.bumpMapUv?"#define BUMPMAP_UV "+i.bumpMapUv:"",i.normalMapUv?"#define NORMALMAP_UV "+i.normalMapUv:"",i.displacementMapUv?"#define DISPLACEMENTMAP_UV "+i.displacementMapUv:"",i.metalnessMapUv?"#define METALNESSMAP_UV "+i.metalnessMapUv:"",i.roughnessMapUv?"#define ROUGHNESSMAP_UV "+i.roughnessMapUv:"",i.anisotropyMapUv?"#define ANISOTROPYMAP_UV "+i.anisotropyMapUv:"",i.clearcoatMapUv?"#define CLEARCOATMAP_UV "+i.clearcoatMapUv:"",i.clearcoatNormalMapUv?"#define CLEARCOAT_NORMALMAP_UV "+i.clearcoatNormalMapUv:"",i.clearcoatRoughnessMapUv?"#define CLEARCOAT_ROUGHNESSMAP_UV "+i.clearcoatRoughnessMapUv:"",i.iridescenceMapUv?"#define IRIDESCENCEMAP_UV "+i.iridescenceMapUv:"",i.iridescenceThicknessMapUv?"#define IRIDESCENCE_THICKNESSMAP_UV "+i.iridescenceThicknessMapUv:"",i.sheenColorMapUv?"#define SHEEN_COLORMAP_UV "+i.sheenColorMapUv:"",i.sheenRoughnessMapUv?"#define SHEEN_ROUGHNESSMAP_UV "+i.sheenRoughnessMapUv:"",i.specularMapUv?"#define SPECULARMAP_UV "+i.specularMapUv:"",i.specularColorMapUv?"#define SPECULAR_COLORMAP_UV "+i.specularColorMapUv:"",i.specularIntensityMapUv?"#define SPECULAR_INTENSITYMAP_UV "+i.specularIntensityMapUv:"",i.transmissionMapUv?"#define TRANSMISSIONMAP_UV "+i.transmissionMapUv:"",i.thicknessMapUv?"#define THICKNESSMAP_UV "+i.thicknessMapUv:"",i.vertexTangents&&i.flatShading===!1?"#define USE_TANGENT":"",i.vertexColors?"#define USE_COLOR":"",i.vertexAlphas?"#define USE_COLOR_ALPHA":"",i.vertexUv1s?"#define USE_UV1":"",i.vertexUv2s?"#define USE_UV2":"",i.vertexUv3s?"#define USE_UV3":"",i.pointsUvs?"#define USE_POINTS_UV":"",i.flatShading?"#define FLAT_SHADED":"",i.skinning?"#define USE_SKINNING":"",i.morphTargets?"#define USE_MORPHTARGETS":"",i.morphNormals&&i.flatShading===!1?"#define USE_MORPHNORMALS":"",i.morphColors?"#define USE_MORPHCOLORS":"",i.morphTargetsCount>0?"#define MORPHTARGETS_TEXTURE_STRIDE "+i.morphTextureStride:"",i.morphTargetsCount>0?"#define MORPHTARGETS_COUNT "+i.morphTargetsCount:"",i.doubleSided?"#define DOUBLE_SIDED":"",i.flipSided?"#define FLIP_SIDED":"",i.shadowMapEnabled?"#define USE_SHADOWMAP":"",i.shadowMapEnabled?"#define "+m:"",i.sizeAttenuation?"#define USE_SIZEATTENUATION":"",i.numLightProbes>0?"#define USE_LIGHT_PROBES":"",i.logarithmicDepthBuffer?"#define USE_LOGDEPTHBUF":"",i.reverseDepthBuffer?"#define USE_REVERSEDEPTHBUF":"","uniform mat4 modelMatrix;","uniform mat4 modelViewMatrix;","uniform mat4 projectionMatrix;","uniform mat4 viewMatrix;","uniform mat3 normalMatrix;","uniform vec3 cameraPosition;","uniform bool isOrthographic;","#ifdef USE_INSTANCING","	attribute mat4 instanceMatrix;","#endif","#ifdef USE_INSTANCING_COLOR","	attribute vec3 instanceColor;","#endif","#ifdef USE_INSTANCING_MORPH","	uniform sampler2D morphTexture;","#endif","attribute vec3 position;","attribute vec3 normal;","attribute vec2 uv;","#ifdef USE_UV1","	attribute vec2 uv1;","#endif","#ifdef USE_UV2","	attribute vec2 uv2;","#endif","#ifdef USE_UV3","	attribute vec2 uv3;","#endif","#ifdef USE_TANGENT","	attribute vec4 tangent;","#endif","#if defined( USE_COLOR_ALPHA )","	attribute vec4 color;","#elif defined( USE_COLOR )","	attribute vec3 color;","#endif","#ifdef USE_SKINNING","	attribute vec4 skinIndex;","	attribute vec4 skinWeight;","#endif",`
`].filter(To).join(`
`),v=[f_(i),"#define SHADER_TYPE "+i.shaderType,"#define SHADER_NAME "+i.shaderName,R,i.useFog&&i.fog?"#define USE_FOG":"",i.useFog&&i.fogExp2?"#define FOG_EXP2":"",i.alphaToCoverage?"#define ALPHA_TO_COVERAGE":"",i.map?"#define USE_MAP":"",i.matcap?"#define USE_MATCAP":"",i.envMap?"#define USE_ENVMAP":"",i.envMap?"#define "+p:"",i.envMap?"#define "+_:"",i.envMap?"#define "+y:"",x?"#define CUBEUV_TEXEL_WIDTH "+x.texelWidth:"",x?"#define CUBEUV_TEXEL_HEIGHT "+x.texelHeight:"",x?"#define CUBEUV_MAX_MIP "+x.maxMip+".0":"",i.lightMap?"#define USE_LIGHTMAP":"",i.aoMap?"#define USE_AOMAP":"",i.bumpMap?"#define USE_BUMPMAP":"",i.normalMap?"#define USE_NORMALMAP":"",i.normalMapObjectSpace?"#define USE_NORMALMAP_OBJECTSPACE":"",i.normalMapTangentSpace?"#define USE_NORMALMAP_TANGENTSPACE":"",i.emissiveMap?"#define USE_EMISSIVEMAP":"",i.anisotropy?"#define USE_ANISOTROPY":"",i.anisotropyMap?"#define USE_ANISOTROPYMAP":"",i.clearcoat?"#define USE_CLEARCOAT":"",i.clearcoatMap?"#define USE_CLEARCOATMAP":"",i.clearcoatRoughnessMap?"#define USE_CLEARCOAT_ROUGHNESSMAP":"",i.clearcoatNormalMap?"#define USE_CLEARCOAT_NORMALMAP":"",i.dispersion?"#define USE_DISPERSION":"",i.iridescence?"#define USE_IRIDESCENCE":"",i.iridescenceMap?"#define USE_IRIDESCENCEMAP":"",i.iridescenceThicknessMap?"#define USE_IRIDESCENCE_THICKNESSMAP":"",i.specularMap?"#define USE_SPECULARMAP":"",i.specularColorMap?"#define USE_SPECULAR_COLORMAP":"",i.specularIntensityMap?"#define USE_SPECULAR_INTENSITYMAP":"",i.roughnessMap?"#define USE_ROUGHNESSMAP":"",i.metalnessMap?"#define USE_METALNESSMAP":"",i.alphaMap?"#define USE_ALPHAMAP":"",i.alphaTest?"#define USE_ALPHATEST":"",i.alphaHash?"#define USE_ALPHAHASH":"",i.sheen?"#define USE_SHEEN":"",i.sheenColorMap?"#define USE_SHEEN_COLORMAP":"",i.sheenRoughnessMap?"#define USE_SHEEN_ROUGHNESSMAP":"",i.transmission?"#define USE_TRANSMISSION":"",i.transmissionMap?"#define USE_TRANSMISSIONMAP":"",i.thicknessMap?"#define USE_THICKNESSMAP":"",i.vertexTangents&&i.flatShading===!1?"#define USE_TANGENT":"",i.vertexColors||i.instancingColor||i.batchingColor?"#define USE_COLOR":"",i.vertexAlphas?"#define USE_COLOR_ALPHA":"",i.vertexUv1s?"#define USE_UV1":"",i.vertexUv2s?"#define USE_UV2":"",i.vertexUv3s?"#define USE_UV3":"",i.pointsUvs?"#define USE_POINTS_UV":"",i.gradientMap?"#define USE_GRADIENTMAP":"",i.flatShading?"#define FLAT_SHADED":"",i.doubleSided?"#define DOUBLE_SIDED":"",i.flipSided?"#define FLIP_SIDED":"",i.shadowMapEnabled?"#define USE_SHADOWMAP":"",i.shadowMapEnabled?"#define "+m:"",i.premultipliedAlpha?"#define PREMULTIPLIED_ALPHA":"",i.numLightProbes>0?"#define USE_LIGHT_PROBES":"",i.decodeVideoTexture?"#define DECODE_VIDEO_TEXTURE":"",i.decodeVideoTextureEmissive?"#define DECODE_VIDEO_TEXTURE_EMISSIVE":"",i.logarithmicDepthBuffer?"#define USE_LOGDEPTHBUF":"",i.reverseDepthBuffer?"#define USE_REVERSEDEPTHBUF":"","uniform mat4 viewMatrix;","uniform vec3 cameraPosition;","uniform bool isOrthographic;",i.toneMapping!==Bn?"#define TONE_MAPPING":"",i.toneMapping!==Bn?ot.tonemapping_pars_fragment:"",i.toneMapping!==Bn?Uw("toneMapping",i.toneMapping):"",i.dithering?"#define DITHERING":"",i.opaque?"#define OPAQUE":"",ot.colorspace_pars_fragment,Lw("linearToOutputTexel",i.outputColorSpace),Dw(),i.useDepthPacking?"#define DEPTH_PACKING "+i.depthPacking:"",`
`].filter(To).join(`
`)),h=rf(h),h=u_(h,i),h=d_(h,i),f=rf(f),f=u_(f,i),f=d_(f,i),h=h_(h),f=h_(f),i.isRawShaderMaterial!==!0&&(D=`#version 300 es
`,S=[b,"#define attribute in","#define varying out","#define texture2D texture"].join(`
`)+`
`+S,v=["#define varying in",i.glslVersion===Mv?"":"layout(location = 0) out highp vec4 pc_fragColor;",i.glslVersion===Mv?"":"#define gl_FragColor pc_fragColor","#define gl_FragDepthEXT gl_FragDepth","#define texture2D texture","#define textureCube texture","#define texture2DProj textureProj","#define texture2DLodEXT textureLod","#define texture2DProjLodEXT textureProjLod","#define textureCubeLodEXT textureLod","#define texture2DGradEXT textureGrad","#define texture2DProjGradEXT textureProjGrad","#define textureCubeGradEXT textureGrad"].join(`
`)+`
`+v);const L=D+S+h,C=D+v+f,G=o_(l,l.VERTEX_SHADER,L),k=o_(l,l.FRAGMENT_SHADER,C);l.attachShader(A,G),l.attachShader(A,k),i.index0AttributeName!==void 0?l.bindAttribLocation(A,0,i.index0AttributeName):i.morphTargets===!0&&l.bindAttribLocation(A,0,"position"),l.linkProgram(A);function I(F){if(o.debug.checkShaderErrors){const te=l.getProgramInfoLog(A).trim(),se=l.getShaderInfoLog(G).trim(),ce=l.getShaderInfoLog(k).trim();let ve=!0,N=!0;if(l.getProgramParameter(A,l.LINK_STATUS)===!1)if(ve=!1,typeof o.debug.onShaderError=="function")o.debug.onShaderError(l,A,G,k);else{const K=c_(l,G,"vertex"),q=c_(l,k,"fragment");console.error("THREE.WebGLProgram: Shader Error "+l.getError()+" - VALIDATE_STATUS "+l.getProgramParameter(A,l.VALIDATE_STATUS)+`

Material Name: `+F.name+`
Material Type: `+F.type+`

Program Info Log: `+te+`
`+K+`
`+q)}else te!==""?console.warn("THREE.WebGLProgram: Program Info Log:",te):(se===""||ce==="")&&(N=!1);N&&(F.diagnostics={runnable:ve,programLog:te,vertexShader:{log:se,prefix:S},fragmentShader:{log:ce,prefix:v}})}l.deleteShader(G),l.deleteShader(k),H=new bc(l,A),P=Ow(l,A)}let H;this.getUniforms=function(){return H===void 0&&I(this),H};let P;this.getAttributes=function(){return P===void 0&&I(this),P};let w=i.rendererExtensionParallelShaderCompile===!1;return this.isReady=function(){return w===!1&&(w=l.getProgramParameter(A,Rw)),w},this.destroy=function(){a.releaseStatesOfProgram(this),l.deleteProgram(A),this.program=void 0},this.type=i.shaderType,this.name=i.shaderName,this.id=Cw++,this.cacheKey=t,this.usedTimes=1,this.program=A,this.vertexShader=G,this.fragmentShader=k,this}let qw=0;class Qw{constructor(){this.shaderCache=new Map,this.materialCache=new Map}update(t){const i=t.vertexShader,a=t.fragmentShader,l=this._getShaderStage(i),u=this._getShaderStage(a),h=this._getShaderCacheForMaterial(t);return h.has(l)===!1&&(h.add(l),l.usedTimes++),h.has(u)===!1&&(h.add(u),u.usedTimes++),this}remove(t){const i=this.materialCache.get(t);for(const a of i)a.usedTimes--,a.usedTimes===0&&this.shaderCache.delete(a.code);return this.materialCache.delete(t),this}getVertexShaderID(t){return this._getShaderStage(t.vertexShader).id}getFragmentShaderID(t){return this._getShaderStage(t.fragmentShader).id}dispose(){this.shaderCache.clear(),this.materialCache.clear()}_getShaderCacheForMaterial(t){const i=this.materialCache;let a=i.get(t);return a===void 0&&(a=new Set,i.set(t,a)),a}_getShaderStage(t){const i=this.shaderCache;let a=i.get(t);return a===void 0&&(a=new $w(t),i.set(t,a)),a}}class $w{constructor(t){this.id=qw++,this.code=t,this.usedTimes=0}}function Kw(o,t,i,a,l,u,h){const f=new k_,m=new Qw,p=new Set,_=[],y=l.logarithmicDepthBuffer,x=l.vertexTextures;let b=l.precision;const R={MeshDepthMaterial:"depth",MeshDistanceMaterial:"distanceRGBA",MeshNormalMaterial:"normal",MeshBasicMaterial:"basic",MeshLambertMaterial:"lambert",MeshPhongMaterial:"phong",MeshToonMaterial:"toon",MeshStandardMaterial:"physical",MeshPhysicalMaterial:"physical",MeshMatcapMaterial:"matcap",LineBasicMaterial:"basic",LineDashedMaterial:"dashed",PointsMaterial:"points",ShadowMaterial:"shadow",SpriteMaterial:"sprite"};function A(P){return p.add(P),P===0?"uv":`uv${P}`}function S(P,w,F,te,se){const ce=te.fog,ve=se.geometry,N=P.isMeshStandardMaterial?te.environment:null,K=(P.isMeshStandardMaterial?i:t).get(P.envMap||N),q=K&&K.mapping===Tc?K.image.height:null,ge=R[P.type];P.precision!==null&&(b=l.getMaxPrecision(P.precision),b!==P.precision&&console.warn("THREE.WebGLProgram.getParameters:",P.precision,"not supported, using",b,"instead."));const we=ve.morphAttributes.position||ve.morphAttributes.normal||ve.morphAttributes.color,O=we!==void 0?we.length:0;let ie=0;ve.morphAttributes.position!==void 0&&(ie=1),ve.morphAttributes.normal!==void 0&&(ie=2),ve.morphAttributes.color!==void 0&&(ie=3);let xe,Q,ue,Me;if(ge){const bt=Ri[ge];xe=bt.vertexShader,Q=bt.fragmentShader}else xe=P.vertexShader,Q=P.fragmentShader,m.update(P),ue=m.getVertexShaderID(P),Me=m.getFragmentShaderID(P);const ye=o.getRenderTarget(),ke=o.state.buffers.depth.getReversed(),Fe=se.isInstancedMesh===!0,tt=se.isBatchedMesh===!0,Lt=!!P.map,ut=!!P.matcap,Vt=!!K,B=!!P.aoMap,_r=!!P.lightMap,dt=!!P.bumpMap,pt=!!P.normalMap,Ge=!!P.displacementMap,Ct=!!P.emissiveMap,Ve=!!P.metalnessMap,U=!!P.roughnessMap,E=P.anisotropy>0,ee=P.clearcoat>0,he=P.dispersion>0,be=P.iridescence>0,pe=P.sheen>0,Be=P.transmission>0,Ce=E&&!!P.anisotropyMap,$e=ee&&!!P.clearcoatMap,Ye=ee&&!!P.clearcoatNormalMap,Ee=ee&&!!P.clearcoatRoughnessMap,Ne=be&&!!P.iridescenceMap,Xe=be&&!!P.iridescenceThicknessMap,He=pe&&!!P.sheenColorMap,Ue=pe&&!!P.sheenRoughnessMap,Ke=!!P.specularMap,rt=!!P.specularColorMap,Ut=!!P.specularIntensityMap,j=Be&&!!P.transmissionMap,Ae=Be&&!!P.thicknessMap,le=!!P.gradientMap,_e=!!P.alphaMap,Re=P.alphaTest>0,Te=!!P.alphaHash,st=!!P.extensions;let Gt=Bn;P.toneMapped&&(ye===null||ye.isXRRenderTarget===!0)&&(Gt=o.toneMapping);const nr={shaderID:ge,shaderType:P.type,shaderName:P.name,vertexShader:xe,fragmentShader:Q,defines:P.defines,customVertexShaderID:ue,customFragmentShaderID:Me,isRawShaderMaterial:P.isRawShaderMaterial===!0,glslVersion:P.glslVersion,precision:b,batching:tt,batchingColor:tt&&se._colorsTexture!==null,instancing:Fe,instancingColor:Fe&&se.instanceColor!==null,instancingMorph:Fe&&se.morphTexture!==null,supportsVertexTextures:x,outputColorSpace:ye===null?o.outputColorSpace:ye.isXRRenderTarget===!0?ye.texture.colorSpace:Ss,alphaToCoverage:!!P.alphaToCoverage,map:Lt,matcap:ut,envMap:Vt,envMapMode:Vt&&K.mapping,envMapCubeUVHeight:q,aoMap:B,lightMap:_r,bumpMap:dt,normalMap:pt,displacementMap:x&&Ge,emissiveMap:Ct,normalMapObjectSpace:pt&&P.normalMapType===Wx,normalMapTangentSpace:pt&&P.normalMapType===D_,metalnessMap:Ve,roughnessMap:U,anisotropy:E,anisotropyMap:Ce,clearcoat:ee,clearcoatMap:$e,clearcoatNormalMap:Ye,clearcoatRoughnessMap:Ee,dispersion:he,iridescence:be,iridescenceMap:Ne,iridescenceThicknessMap:Xe,sheen:pe,sheenColorMap:He,sheenRoughnessMap:Ue,specularMap:Ke,specularColorMap:rt,specularIntensityMap:Ut,transmission:Be,transmissionMap:j,thicknessMap:Ae,gradientMap:le,opaque:P.transparent===!1&&P.blending===gs&&P.alphaToCoverage===!1,alphaMap:_e,alphaTest:Re,alphaHash:Te,combine:P.combine,mapUv:Lt&&A(P.map.channel),aoMapUv:B&&A(P.aoMap.channel),lightMapUv:_r&&A(P.lightMap.channel),bumpMapUv:dt&&A(P.bumpMap.channel),normalMapUv:pt&&A(P.normalMap.channel),displacementMapUv:Ge&&A(P.displacementMap.channel),emissiveMapUv:Ct&&A(P.emissiveMap.channel),metalnessMapUv:Ve&&A(P.metalnessMap.channel),roughnessMapUv:U&&A(P.roughnessMap.channel),anisotropyMapUv:Ce&&A(P.anisotropyMap.channel),clearcoatMapUv:$e&&A(P.clearcoatMap.channel),clearcoatNormalMapUv:Ye&&A(P.clearcoatNormalMap.channel),clearcoatRoughnessMapUv:Ee&&A(P.clearcoatRoughnessMap.channel),iridescenceMapUv:Ne&&A(P.iridescenceMap.channel),iridescenceThicknessMapUv:Xe&&A(P.iridescenceThicknessMap.channel),sheenColorMapUv:He&&A(P.sheenColorMap.channel),sheenRoughnessMapUv:Ue&&A(P.sheenRoughnessMap.channel),specularMapUv:Ke&&A(P.specularMap.channel),specularColorMapUv:rt&&A(P.specularColorMap.channel),specularIntensityMapUv:Ut&&A(P.specularIntensityMap.channel),transmissionMapUv:j&&A(P.transmissionMap.channel),thicknessMapUv:Ae&&A(P.thicknessMap.channel),alphaMapUv:_e&&A(P.alphaMap.channel),vertexTangents:!!ve.attributes.tangent&&(pt||E),vertexColors:P.vertexColors,vertexAlphas:P.vertexColors===!0&&!!ve.attributes.color&&ve.attributes.color.itemSize===4,pointsUvs:se.isPoints===!0&&!!ve.attributes.uv&&(Lt||_e),fog:!!ce,useFog:P.fog===!0,fogExp2:!!ce&&ce.isFogExp2,flatShading:P.flatShading===!0,sizeAttenuation:P.sizeAttenuation===!0,logarithmicDepthBuffer:y,reverseDepthBuffer:ke,skinning:se.isSkinnedMesh===!0,morphTargets:ve.morphAttributes.position!==void 0,morphNormals:ve.morphAttributes.normal!==void 0,morphColors:ve.morphAttributes.color!==void 0,morphTargetsCount:O,morphTextureStride:ie,numDirLights:w.directional.length,numPointLights:w.point.length,numSpotLights:w.spot.length,numSpotLightMaps:w.spotLightMap.length,numRectAreaLights:w.rectArea.length,numHemiLights:w.hemi.length,numDirLightShadows:w.directionalShadowMap.length,numPointLightShadows:w.pointShadowMap.length,numSpotLightShadows:w.spotShadowMap.length,numSpotLightShadowsWithMaps:w.numSpotLightShadowsWithMaps,numLightProbes:w.numLightProbes,numClippingPlanes:h.numPlanes,numClipIntersection:h.numIntersection,dithering:P.dithering,shadowMapEnabled:o.shadowMap.enabled&&F.length>0,shadowMapType:o.shadowMap.type,toneMapping:Gt,decodeVideoTexture:Lt&&P.map.isVideoTexture===!0&&Tt.getTransfer(P.map.colorSpace)===kt,decodeVideoTextureEmissive:Ct&&P.emissiveMap.isVideoTexture===!0&&Tt.getTransfer(P.emissiveMap.colorSpace)===kt,premultipliedAlpha:P.premultipliedAlpha,doubleSided:P.side===an,flipSided:P.side===zr,useDepthPacking:P.depthPacking>=0,depthPacking:P.depthPacking||0,index0AttributeName:P.index0AttributeName,extensionClipCullDistance:st&&P.extensions.clipCullDistance===!0&&a.has("WEBGL_clip_cull_distance"),extensionMultiDraw:(st&&P.extensions.multiDraw===!0||tt)&&a.has("WEBGL_multi_draw"),rendererExtensionParallelShaderCompile:a.has("KHR_parallel_shader_compile"),customProgramCacheKey:P.customProgramCacheKey()};return nr.vertexUv1s=p.has(1),nr.vertexUv2s=p.has(2),nr.vertexUv3s=p.has(3),p.clear(),nr}function v(P){const w=[];if(P.shaderID?w.push(P.shaderID):(w.push(P.customVertexShaderID),w.push(P.customFragmentShaderID)),P.defines!==void 0)for(const F in P.defines)w.push(F),w.push(P.defines[F]);return P.isRawShaderMaterial===!1&&(D(w,P),L(w,P),w.push(o.outputColorSpace)),w.push(P.customProgramCacheKey),w.join()}function D(P,w){P.push(w.precision),P.push(w.outputColorSpace),P.push(w.envMapMode),P.push(w.envMapCubeUVHeight),P.push(w.mapUv),P.push(w.alphaMapUv),P.push(w.lightMapUv),P.push(w.aoMapUv),P.push(w.bumpMapUv),P.push(w.normalMapUv),P.push(w.displacementMapUv),P.push(w.emissiveMapUv),P.push(w.metalnessMapUv),P.push(w.roughnessMapUv),P.push(w.anisotropyMapUv),P.push(w.clearcoatMapUv),P.push(w.clearcoatNormalMapUv),P.push(w.clearcoatRoughnessMapUv),P.push(w.iridescenceMapUv),P.push(w.iridescenceThicknessMapUv),P.push(w.sheenColorMapUv),P.push(w.sheenRoughnessMapUv),P.push(w.specularMapUv),P.push(w.specularColorMapUv),P.push(w.specularIntensityMapUv),P.push(w.transmissionMapUv),P.push(w.thicknessMapUv),P.push(w.combine),P.push(w.fogExp2),P.push(w.sizeAttenuation),P.push(w.morphTargetsCount),P.push(w.morphAttributeCount),P.push(w.numDirLights),P.push(w.numPointLights),P.push(w.numSpotLights),P.push(w.numSpotLightMaps),P.push(w.numHemiLights),P.push(w.numRectAreaLights),P.push(w.numDirLightShadows),P.push(w.numPointLightShadows),P.push(w.numSpotLightShadows),P.push(w.numSpotLightShadowsWithMaps),P.push(w.numLightProbes),P.push(w.shadowMapType),P.push(w.toneMapping),P.push(w.numClippingPlanes),P.push(w.numClipIntersection),P.push(w.depthPacking)}function L(P,w){f.disableAll(),w.supportsVertexTextures&&f.enable(0),w.instancing&&f.enable(1),w.instancingColor&&f.enable(2),w.instancingMorph&&f.enable(3),w.matcap&&f.enable(4),w.envMap&&f.enable(5),w.normalMapObjectSpace&&f.enable(6),w.normalMapTangentSpace&&f.enable(7),w.clearcoat&&f.enable(8),w.iridescence&&f.enable(9),w.alphaTest&&f.enable(10),w.vertexColors&&f.enable(11),w.vertexAlphas&&f.enable(12),w.vertexUv1s&&f.enable(13),w.vertexUv2s&&f.enable(14),w.vertexUv3s&&f.enable(15),w.vertexTangents&&f.enable(16),w.anisotropy&&f.enable(17),w.alphaHash&&f.enable(18),w.batching&&f.enable(19),w.dispersion&&f.enable(20),w.batchingColor&&f.enable(21),P.push(f.mask),f.disableAll(),w.fog&&f.enable(0),w.useFog&&f.enable(1),w.flatShading&&f.enable(2),w.logarithmicDepthBuffer&&f.enable(3),w.reverseDepthBuffer&&f.enable(4),w.skinning&&f.enable(5),w.morphTargets&&f.enable(6),w.morphNormals&&f.enable(7),w.morphColors&&f.enable(8),w.premultipliedAlpha&&f.enable(9),w.shadowMapEnabled&&f.enable(10),w.doubleSided&&f.enable(11),w.flipSided&&f.enable(12),w.useDepthPacking&&f.enable(13),w.dithering&&f.enable(14),w.transmission&&f.enable(15),w.sheen&&f.enable(16),w.opaque&&f.enable(17),w.pointsUvs&&f.enable(18),w.decodeVideoTexture&&f.enable(19),w.decodeVideoTextureEmissive&&f.enable(20),w.alphaToCoverage&&f.enable(21),P.push(f.mask)}function C(P){const w=R[P.type];let F;if(w){const te=Ri[w];F=bS.clone(te.uniforms)}else F=P.uniforms;return F}function G(P,w){let F;for(let te=0,se=_.length;te<se;te++){const ce=_[te];if(ce.cacheKey===w){F=ce,++F.usedTimes;break}}return F===void 0&&(F=new Yw(o,w,P,u),_.push(F)),F}function k(P){if(--P.usedTimes===0){const w=_.indexOf(P);_[w]=_[_.length-1],_.pop(),P.destroy()}}function I(P){m.remove(P)}function H(){m.dispose()}return{getParameters:S,getProgramCacheKey:v,getUniforms:C,acquireProgram:G,releaseProgram:k,releaseShaderCache:I,programs:_,dispose:H}}function Zw(){let o=new WeakMap;function t(h){return o.has(h)}function i(h){let f=o.get(h);return f===void 0&&(f={},o.set(h,f)),f}function a(h){o.delete(h)}function l(h,f,m){o.get(h)[f]=m}function u(){o=new WeakMap}return{has:t,get:i,remove:a,update:l,dispose:u}}function Jw(o,t){return o.groupOrder!==t.groupOrder?o.groupOrder-t.groupOrder:o.renderOrder!==t.renderOrder?o.renderOrder-t.renderOrder:o.material.id!==t.material.id?o.material.id-t.material.id:o.z!==t.z?o.z-t.z:o.id-t.id}function p_(o,t){return o.groupOrder!==t.groupOrder?o.groupOrder-t.groupOrder:o.renderOrder!==t.renderOrder?o.renderOrder-t.renderOrder:o.z!==t.z?t.z-o.z:o.id-t.id}function m_(){const o=[];let t=0;const i=[],a=[],l=[];function u(){t=0,i.length=0,a.length=0,l.length=0}function h(y,x,b,R,A,S){let v=o[t];return v===void 0?(v={id:y.id,object:y,geometry:x,material:b,groupOrder:R,renderOrder:y.renderOrder,z:A,group:S},o[t]=v):(v.id=y.id,v.object=y,v.geometry=x,v.material=b,v.groupOrder=R,v.renderOrder=y.renderOrder,v.z=A,v.group=S),t++,v}function f(y,x,b,R,A,S){const v=h(y,x,b,R,A,S);b.transmission>0?a.push(v):b.transparent===!0?l.push(v):i.push(v)}function m(y,x,b,R,A,S){const v=h(y,x,b,R,A,S);b.transmission>0?a.unshift(v):b.transparent===!0?l.unshift(v):i.unshift(v)}function p(y,x){i.length>1&&i.sort(y||Jw),a.length>1&&a.sort(x||p_),l.length>1&&l.sort(x||p_)}function _(){for(let y=t,x=o.length;y<x;y++){const b=o[y];if(b.id===null)break;b.id=null,b.object=null,b.geometry=null,b.material=null,b.group=null}}return{opaque:i,transmissive:a,transparent:l,init:u,push:f,unshift:m,finish:_,sort:p}}function e1(){let o=new WeakMap;function t(a,l){const u=o.get(a);let h;return u===void 0?(h=new m_,o.set(a,[h])):l>=u.length?(h=new m_,u.push(h)):h=u[l],h}function i(){o=new WeakMap}return{get:t,dispose:i}}function t1(){const o={};return{get:function(t){if(o[t.id]!==void 0)return o[t.id];let i;switch(t.type){case"DirectionalLight":i={direction:new $,color:new xt};break;case"SpotLight":i={position:new $,direction:new $,color:new xt,distance:0,coneCos:0,penumbraCos:0,decay:0};break;case"PointLight":i={position:new $,color:new xt,distance:0,decay:0};break;case"HemisphereLight":i={direction:new $,skyColor:new xt,groundColor:new xt};break;case"RectAreaLight":i={color:new xt,position:new $,halfWidth:new $,halfHeight:new $};break}return o[t.id]=i,i}}}function r1(){const o={};return{get:function(t){if(o[t.id]!==void 0)return o[t.id];let i;switch(t.type){case"DirectionalLight":i={shadowIntensity:1,shadowBias:0,shadowNormalBias:0,shadowRadius:1,shadowMapSize:new St};break;case"SpotLight":i={shadowIntensity:1,shadowBias:0,shadowNormalBias:0,shadowRadius:1,shadowMapSize:new St};break;case"PointLight":i={shadowIntensity:1,shadowBias:0,shadowNormalBias:0,shadowRadius:1,shadowMapSize:new St,shadowCameraNear:1,shadowCameraFar:1e3};break}return o[t.id]=i,i}}}let i1=0;function n1(o,t){return(t.castShadow?2:0)-(o.castShadow?2:0)+(t.map?1:0)-(o.map?1:0)}function a1(o){const t=new t1,i=r1(),a={version:0,hash:{directionalLength:-1,pointLength:-1,spotLength:-1,rectAreaLength:-1,hemiLength:-1,numDirectionalShadows:-1,numPointShadows:-1,numSpotShadows:-1,numSpotMaps:-1,numLightProbes:-1},ambient:[0,0,0],probe:[],directional:[],directionalShadow:[],directionalShadowMap:[],directionalShadowMatrix:[],spot:[],spotLightMap:[],spotShadow:[],spotShadowMap:[],spotLightMatrix:[],rectArea:[],rectAreaLTC1:null,rectAreaLTC2:null,point:[],pointShadow:[],pointShadowMap:[],pointShadowMatrix:[],hemi:[],numSpotLightShadowsWithMaps:0,numLightProbes:0};for(let p=0;p<9;p++)a.probe.push(new $);const l=new $,u=new Yt,h=new Yt;function f(p){let _=0,y=0,x=0;for(let P=0;P<9;P++)a.probe[P].set(0,0,0);let b=0,R=0,A=0,S=0,v=0,D=0,L=0,C=0,G=0,k=0,I=0;p.sort(n1);for(let P=0,w=p.length;P<w;P++){const F=p[P],te=F.color,se=F.intensity,ce=F.distance,ve=F.shadow&&F.shadow.map?F.shadow.map.texture:null;if(F.isAmbientLight)_+=te.r*se,y+=te.g*se,x+=te.b*se;else if(F.isLightProbe){for(let N=0;N<9;N++)a.probe[N].addScaledVector(F.sh.coefficients[N],se);I++}else if(F.isDirectionalLight){const N=t.get(F);if(N.color.copy(F.color).multiplyScalar(F.intensity),F.castShadow){const K=F.shadow,q=i.get(F);q.shadowIntensity=K.intensity,q.shadowBias=K.bias,q.shadowNormalBias=K.normalBias,q.shadowRadius=K.radius,q.shadowMapSize=K.mapSize,a.directionalShadow[b]=q,a.directionalShadowMap[b]=ve,a.directionalShadowMatrix[b]=F.shadow.matrix,D++}a.directional[b]=N,b++}else if(F.isSpotLight){const N=t.get(F);N.position.setFromMatrixPosition(F.matrixWorld),N.color.copy(te).multiplyScalar(se),N.distance=ce,N.coneCos=Math.cos(F.angle),N.penumbraCos=Math.cos(F.angle*(1-F.penumbra)),N.decay=F.decay,a.spot[A]=N;const K=F.shadow;if(F.map&&(a.spotLightMap[G]=F.map,G++,K.updateMatrices(F),F.castShadow&&k++),a.spotLightMatrix[A]=K.matrix,F.castShadow){const q=i.get(F);q.shadowIntensity=K.intensity,q.shadowBias=K.bias,q.shadowNormalBias=K.normalBias,q.shadowRadius=K.radius,q.shadowMapSize=K.mapSize,a.spotShadow[A]=q,a.spotShadowMap[A]=ve,C++}A++}else if(F.isRectAreaLight){const N=t.get(F);N.color.copy(te).multiplyScalar(se),N.halfWidth.set(F.width*.5,0,0),N.halfHeight.set(0,F.height*.5,0),a.rectArea[S]=N,S++}else if(F.isPointLight){const N=t.get(F);if(N.color.copy(F.color).multiplyScalar(F.intensity),N.distance=F.distance,N.decay=F.decay,F.castShadow){const K=F.shadow,q=i.get(F);q.shadowIntensity=K.intensity,q.shadowBias=K.bias,q.shadowNormalBias=K.normalBias,q.shadowRadius=K.radius,q.shadowMapSize=K.mapSize,q.shadowCameraNear=K.camera.near,q.shadowCameraFar=K.camera.far,a.pointShadow[R]=q,a.pointShadowMap[R]=ve,a.pointShadowMatrix[R]=F.shadow.matrix,L++}a.point[R]=N,R++}else if(F.isHemisphereLight){const N=t.get(F);N.skyColor.copy(F.color).multiplyScalar(se),N.groundColor.copy(F.groundColor).multiplyScalar(se),a.hemi[v]=N,v++}}S>0&&(o.has("OES_texture_float_linear")===!0?(a.rectAreaLTC1=Le.LTC_FLOAT_1,a.rectAreaLTC2=Le.LTC_FLOAT_2):(a.rectAreaLTC1=Le.LTC_HALF_1,a.rectAreaLTC2=Le.LTC_HALF_2)),a.ambient[0]=_,a.ambient[1]=y,a.ambient[2]=x;const H=a.hash;(H.directionalLength!==b||H.pointLength!==R||H.spotLength!==A||H.rectAreaLength!==S||H.hemiLength!==v||H.numDirectionalShadows!==D||H.numPointShadows!==L||H.numSpotShadows!==C||H.numSpotMaps!==G||H.numLightProbes!==I)&&(a.directional.length=b,a.spot.length=A,a.rectArea.length=S,a.point.length=R,a.hemi.length=v,a.directionalShadow.length=D,a.directionalShadowMap.length=D,a.pointShadow.length=L,a.pointShadowMap.length=L,a.spotShadow.length=C,a.spotShadowMap.length=C,a.directionalShadowMatrix.length=D,a.pointShadowMatrix.length=L,a.spotLightMatrix.length=C+G-k,a.spotLightMap.length=G,a.numSpotLightShadowsWithMaps=k,a.numLightProbes=I,H.directionalLength=b,H.pointLength=R,H.spotLength=A,H.rectAreaLength=S,H.hemiLength=v,H.numDirectionalShadows=D,H.numPointShadows=L,H.numSpotShadows=C,H.numSpotMaps=G,H.numLightProbes=I,a.version=i1++)}function m(p,_){let y=0,x=0,b=0,R=0,A=0;const S=_.matrixWorldInverse;for(let v=0,D=p.length;v<D;v++){const L=p[v];if(L.isDirectionalLight){const C=a.directional[y];C.direction.setFromMatrixPosition(L.matrixWorld),l.setFromMatrixPosition(L.target.matrixWorld),C.direction.sub(l),C.direction.transformDirection(S),y++}else if(L.isSpotLight){const C=a.spot[b];C.position.setFromMatrixPosition(L.matrixWorld),C.position.applyMatrix4(S),C.direction.setFromMatrixPosition(L.matrixWorld),l.setFromMatrixPosition(L.target.matrixWorld),C.direction.sub(l),C.direction.transformDirection(S),b++}else if(L.isRectAreaLight){const C=a.rectArea[R];C.position.setFromMatrixPosition(L.matrixWorld),C.position.applyMatrix4(S),h.identity(),u.copy(L.matrixWorld),u.premultiply(S),h.extractRotation(u),C.halfWidth.set(L.width*.5,0,0),C.halfHeight.set(0,L.height*.5,0),C.halfWidth.applyMatrix4(h),C.halfHeight.applyMatrix4(h),R++}else if(L.isPointLight){const C=a.point[x];C.position.setFromMatrixPosition(L.matrixWorld),C.position.applyMatrix4(S),x++}else if(L.isHemisphereLight){const C=a.hemi[A];C.direction.setFromMatrixPosition(L.matrixWorld),C.direction.transformDirection(S),A++}}}return{setup:f,setupView:m,state:a}}function g_(o){const t=new a1(o),i=[],a=[];function l(_){p.camera=_,i.length=0,a.length=0}function u(_){i.push(_)}function h(_){a.push(_)}function f(){t.setup(i)}function m(_){t.setupView(i,_)}const p={lightsArray:i,shadowsArray:a,camera:null,lights:t,transmissionRenderTarget:{}};return{init:l,state:p,setupLights:f,setupLightsView:m,pushLight:u,pushShadow:h}}function s1(o){let t=new WeakMap;function i(l,u=0){const h=t.get(l);let f;return h===void 0?(f=new g_(o),t.set(l,[f])):u>=h.length?(f=new g_(o),h.push(f)):f=h[u],f}function a(){t=new WeakMap}return{get:i,dispose:a}}const o1=`void main() {
	gl_Position = vec4( position, 1.0 );
}`,l1=`uniform sampler2D shadow_pass;
uniform vec2 resolution;
uniform float radius;
#include <packing>
void main() {
	const float samples = float( VSM_SAMPLES );
	float mean = 0.0;
	float squared_mean = 0.0;
	float uvStride = samples <= 1.0 ? 0.0 : 2.0 / ( samples - 1.0 );
	float uvStart = samples <= 1.0 ? 0.0 : - 1.0;
	for ( float i = 0.0; i < samples; i ++ ) {
		float uvOffset = uvStart + i * uvStride;
		#ifdef HORIZONTAL_PASS
			vec2 distribution = unpackRGBATo2Half( texture2D( shadow_pass, ( gl_FragCoord.xy + vec2( uvOffset, 0.0 ) * radius ) / resolution ) );
			mean += distribution.x;
			squared_mean += distribution.y * distribution.y + distribution.x * distribution.x;
		#else
			float depth = unpackRGBAToDepth( texture2D( shadow_pass, ( gl_FragCoord.xy + vec2( 0.0, uvOffset ) * radius ) / resolution ) );
			mean += depth;
			squared_mean += depth * depth;
		#endif
	}
	mean = mean / samples;
	squared_mean = squared_mean / samples;
	float std_dev = sqrt( squared_mean - mean * mean );
	gl_FragColor = pack2HalfToRGBA( vec2( mean, std_dev ) );
}`;function c1(o,t,i){let a=new gf;const l=new St,u=new St,h=new Ft,f=new LS({depthPacking:Gx}),m=new US,p={},_=i.maxTextureSize,y={[Hn]:zr,[zr]:Hn,[an]:an},x=new Vn({defines:{VSM_SAMPLES:8},uniforms:{shadow_pass:{value:null},resolution:{value:new St},radius:{value:4}},vertexShader:o1,fragmentShader:l1}),b=x.clone();b.defines.HORIZONTAL_PASS=1;const R=new Ui;R.setAttribute("position",new Ai(new Float32Array([-1,-1,.5,3,-1,.5,-1,3,.5]),3));const A=new si(R,x),S=this;this.enabled=!1,this.autoUpdate=!0,this.needsUpdate=!1,this.type=x_;let v=this.type;this.render=function(k,I,H){if(S.enabled===!1||S.autoUpdate===!1&&S.needsUpdate===!1||k.length===0)return;const P=o.getRenderTarget(),w=o.getActiveCubeFace(),F=o.getActiveMipmapLevel(),te=o.state;te.setBlending(zn),te.buffers.color.setClear(1,1,1,1),te.buffers.depth.setTest(!0),te.setScissorTest(!1);const se=v!==rn&&this.type===rn,ce=v===rn&&this.type!==rn;for(let ve=0,N=k.length;ve<N;ve++){const K=k[ve],q=K.shadow;if(q===void 0){console.warn("THREE.WebGLShadowMap:",K,"has no shadow.");continue}if(q.autoUpdate===!1&&q.needsUpdate===!1)continue;l.copy(q.mapSize);const ge=q.getFrameExtents();if(l.multiply(ge),u.copy(q.mapSize),(l.x>_||l.y>_)&&(l.x>_&&(u.x=Math.floor(_/ge.x),l.x=u.x*ge.x,q.mapSize.x=u.x),l.y>_&&(u.y=Math.floor(_/ge.y),l.y=u.y*ge.y,q.mapSize.y=u.y)),q.map===null||se===!0||ce===!0){const O=this.type!==rn?{minFilter:Si,magFilter:Si}:{};q.map!==null&&q.map.dispose(),q.map=new Sa(l.x,l.y,O),q.map.texture.name=K.name+".shadowMap",q.camera.updateProjectionMatrix()}o.setRenderTarget(q.map),o.clear();const we=q.getViewportCount();for(let O=0;O<we;O++){const ie=q.getViewport(O);h.set(u.x*ie.x,u.y*ie.y,u.x*ie.z,u.y*ie.w),te.viewport(h),q.updateMatrices(K,O),a=q.getFrustum(),C(I,H,q.camera,K,this.type)}q.isPointLightShadow!==!0&&this.type===rn&&D(q,H),q.needsUpdate=!1}v=this.type,S.needsUpdate=!1,o.setRenderTarget(P,w,F)};function D(k,I){const H=t.update(A);x.defines.VSM_SAMPLES!==k.blurSamples&&(x.defines.VSM_SAMPLES=k.blurSamples,b.defines.VSM_SAMPLES=k.blurSamples,x.needsUpdate=!0,b.needsUpdate=!0),k.mapPass===null&&(k.mapPass=new Sa(l.x,l.y)),x.uniforms.shadow_pass.value=k.map.texture,x.uniforms.resolution.value=k.mapSize,x.uniforms.radius.value=k.radius,o.setRenderTarget(k.mapPass),o.clear(),o.renderBufferDirect(I,null,H,x,A,null),b.uniforms.shadow_pass.value=k.mapPass.texture,b.uniforms.resolution.value=k.mapSize,b.uniforms.radius.value=k.radius,o.setRenderTarget(k.map),o.clear(),o.renderBufferDirect(I,null,H,b,A,null)}function L(k,I,H,P){let w=null;const F=H.isPointLight===!0?k.customDistanceMaterial:k.customDepthMaterial;if(F!==void 0)w=F;else if(w=H.isPointLight===!0?m:f,o.localClippingEnabled&&I.clipShadows===!0&&Array.isArray(I.clippingPlanes)&&I.clippingPlanes.length!==0||I.displacementMap&&I.displacementScale!==0||I.alphaMap&&I.alphaTest>0||I.map&&I.alphaTest>0||I.alphaToCoverage===!0){const te=w.uuid,se=I.uuid;let ce=p[te];ce===void 0&&(ce={},p[te]=ce);let ve=ce[se];ve===void 0&&(ve=w.clone(),ce[se]=ve,I.addEventListener("dispose",G)),w=ve}if(w.visible=I.visible,w.wireframe=I.wireframe,P===rn?w.side=I.shadowSide!==null?I.shadowSide:I.side:w.side=I.shadowSide!==null?I.shadowSide:y[I.side],w.alphaMap=I.alphaMap,w.alphaTest=I.alphaToCoverage===!0?.5:I.alphaTest,w.map=I.map,w.clipShadows=I.clipShadows,w.clippingPlanes=I.clippingPlanes,w.clipIntersection=I.clipIntersection,w.displacementMap=I.displacementMap,w.displacementScale=I.displacementScale,w.displacementBias=I.displacementBias,w.wireframeLinewidth=I.wireframeLinewidth,w.linewidth=I.linewidth,H.isPointLight===!0&&w.isMeshDistanceMaterial===!0){const te=o.properties.get(w);te.light=H}return w}function C(k,I,H,P,w){if(k.visible===!1)return;if(k.layers.test(I.layers)&&(k.isMesh||k.isLine||k.isPoints)&&(k.castShadow||k.receiveShadow&&w===rn)&&(!k.frustumCulled||a.intersectsObject(k))){k.modelViewMatrix.multiplyMatrices(H.matrixWorldInverse,k.matrixWorld);const te=t.update(k),se=k.material;if(Array.isArray(se)){const ce=te.groups;for(let ve=0,N=ce.length;ve<N;ve++){const K=ce[ve],q=se[K.materialIndex];if(q&&q.visible){const ge=L(k,q,P,w);k.onBeforeShadow(o,k,I,H,te,ge,K),o.renderBufferDirect(H,null,te,ge,k,K),k.onAfterShadow(o,k,I,H,te,ge,K)}}}else if(se.visible){const ce=L(k,se,P,w);k.onBeforeShadow(o,k,I,H,te,ce,null),o.renderBufferDirect(H,null,te,ce,k,null),k.onAfterShadow(o,k,I,H,te,ce,null)}}const F=k.children;for(let te=0,se=F.length;te<se;te++)C(F[te],I,H,P,w)}function G(k){k.target.removeEventListener("dispose",G);for(const I in p){const H=p[I],P=k.target.uuid;P in H&&(H[P].dispose(),delete H[P])}}}const u1={[_h]:yh,[xh]:Mh,[Sh]:Eh,[_s]:bh,[yh]:_h,[Mh]:xh,[Eh]:Sh,[bh]:_s};function d1(o,t){function i(){let j=!1;const Ae=new Ft;let le=null;const _e=new Ft(0,0,0,0);return{setMask:function(Re){le!==Re&&!j&&(o.colorMask(Re,Re,Re,Re),le=Re)},setLocked:function(Re){j=Re},setClear:function(Re,Te,st,Gt,nr){nr===!0&&(Re*=Gt,Te*=Gt,st*=Gt),Ae.set(Re,Te,st,Gt),_e.equals(Ae)===!1&&(o.clearColor(Re,Te,st,Gt),_e.copy(Ae))},reset:function(){j=!1,le=null,_e.set(-1,0,0,0)}}}function a(){let j=!1,Ae=!1,le=null,_e=null,Re=null;return{setReversed:function(Te){if(Ae!==Te){const st=t.get("EXT_clip_control");Te?st.clipControlEXT(st.LOWER_LEFT_EXT,st.ZERO_TO_ONE_EXT):st.clipControlEXT(st.LOWER_LEFT_EXT,st.NEGATIVE_ONE_TO_ONE_EXT),Ae=Te;const Gt=Re;Re=null,this.setClear(Gt)}},getReversed:function(){return Ae},setTest:function(Te){Te?ye(o.DEPTH_TEST):ke(o.DEPTH_TEST)},setMask:function(Te){le!==Te&&!j&&(o.depthMask(Te),le=Te)},setFunc:function(Te){if(Ae&&(Te=u1[Te]),_e!==Te){switch(Te){case _h:o.depthFunc(o.NEVER);break;case yh:o.depthFunc(o.ALWAYS);break;case xh:o.depthFunc(o.LESS);break;case _s:o.depthFunc(o.LEQUAL);break;case Sh:o.depthFunc(o.EQUAL);break;case bh:o.depthFunc(o.GEQUAL);break;case Mh:o.depthFunc(o.GREATER);break;case Eh:o.depthFunc(o.NOTEQUAL);break;default:o.depthFunc(o.LEQUAL)}_e=Te}},setLocked:function(Te){j=Te},setClear:function(Te){Re!==Te&&(Ae&&(Te=1-Te),o.clearDepth(Te),Re=Te)},reset:function(){j=!1,le=null,_e=null,Re=null,Ae=!1}}}function l(){let j=!1,Ae=null,le=null,_e=null,Re=null,Te=null,st=null,Gt=null,nr=null;return{setTest:function(bt){j||(bt?ye(o.STENCIL_TEST):ke(o.STENCIL_TEST))},setMask:function(bt){Ae!==bt&&!j&&(o.stencilMask(bt),Ae=bt)},setFunc:function(bt,ur,oi){(le!==bt||_e!==ur||Re!==oi)&&(o.stencilFunc(bt,ur,oi),le=bt,_e=ur,Re=oi)},setOp:function(bt,ur,oi){(Te!==bt||st!==ur||Gt!==oi)&&(o.stencilOp(bt,ur,oi),Te=bt,st=ur,Gt=oi)},setLocked:function(bt){j=bt},setClear:function(bt){nr!==bt&&(o.clearStencil(bt),nr=bt)},reset:function(){j=!1,Ae=null,le=null,_e=null,Re=null,Te=null,st=null,Gt=null,nr=null}}}const u=new i,h=new a,f=new l,m=new WeakMap,p=new WeakMap;let _={},y={},x=new WeakMap,b=[],R=null,A=!1,S=null,v=null,D=null,L=null,C=null,G=null,k=null,I=new xt(0,0,0),H=0,P=!1,w=null,F=null,te=null,se=null,ce=null;const ve=o.getParameter(o.MAX_COMBINED_TEXTURE_IMAGE_UNITS);let N=!1,K=0;const q=o.getParameter(o.VERSION);q.indexOf("WebGL")!==-1?(K=parseFloat(/^WebGL (\d)/.exec(q)[1]),N=K>=1):q.indexOf("OpenGL ES")!==-1&&(K=parseFloat(/^OpenGL ES (\d)/.exec(q)[1]),N=K>=2);let ge=null,we={};const O=o.getParameter(o.SCISSOR_BOX),ie=o.getParameter(o.VIEWPORT),xe=new Ft().fromArray(O),Q=new Ft().fromArray(ie);function ue(j,Ae,le,_e){const Re=new Uint8Array(4),Te=o.createTexture();o.bindTexture(j,Te),o.texParameteri(j,o.TEXTURE_MIN_FILTER,o.NEAREST),o.texParameteri(j,o.TEXTURE_MAG_FILTER,o.NEAREST);for(let st=0;st<le;st++)j===o.TEXTURE_3D||j===o.TEXTURE_2D_ARRAY?o.texImage3D(Ae,0,o.RGBA,1,1,_e,0,o.RGBA,o.UNSIGNED_BYTE,Re):o.texImage2D(Ae+st,0,o.RGBA,1,1,0,o.RGBA,o.UNSIGNED_BYTE,Re);return Te}const Me={};Me[o.TEXTURE_2D]=ue(o.TEXTURE_2D,o.TEXTURE_2D,1),Me[o.TEXTURE_CUBE_MAP]=ue(o.TEXTURE_CUBE_MAP,o.TEXTURE_CUBE_MAP_POSITIVE_X,6),Me[o.TEXTURE_2D_ARRAY]=ue(o.TEXTURE_2D_ARRAY,o.TEXTURE_2D_ARRAY,1,1),Me[o.TEXTURE_3D]=ue(o.TEXTURE_3D,o.TEXTURE_3D,1,1),u.setClear(0,0,0,1),h.setClear(1),f.setClear(0),ye(o.DEPTH_TEST),h.setFunc(_s),dt(!1),pt(vv),ye(o.CULL_FACE),B(zn);function ye(j){_[j]!==!0&&(o.enable(j),_[j]=!0)}function ke(j){_[j]!==!1&&(o.disable(j),_[j]=!1)}function Fe(j,Ae){return y[j]!==Ae?(o.bindFramebuffer(j,Ae),y[j]=Ae,j===o.DRAW_FRAMEBUFFER&&(y[o.FRAMEBUFFER]=Ae),j===o.FRAMEBUFFER&&(y[o.DRAW_FRAMEBUFFER]=Ae),!0):!1}function tt(j,Ae){let le=b,_e=!1;if(j){le=x.get(Ae),le===void 0&&(le=[],x.set(Ae,le));const Re=j.textures;if(le.length!==Re.length||le[0]!==o.COLOR_ATTACHMENT0){for(let Te=0,st=Re.length;Te<st;Te++)le[Te]=o.COLOR_ATTACHMENT0+Te;le.length=Re.length,_e=!0}}else le[0]!==o.BACK&&(le[0]=o.BACK,_e=!0);_e&&o.drawBuffers(le)}function Lt(j){return R!==j?(o.useProgram(j),R=j,!0):!1}const ut={[ga]:o.FUNC_ADD,[gx]:o.FUNC_SUBTRACT,[vx]:o.FUNC_REVERSE_SUBTRACT};ut[_x]=o.MIN,ut[yx]=o.MAX;const Vt={[xx]:o.ZERO,[Sx]:o.ONE,[bx]:o.SRC_COLOR,[gh]:o.SRC_ALPHA,[Cx]:o.SRC_ALPHA_SATURATE,[Tx]:o.DST_COLOR,[Ex]:o.DST_ALPHA,[Mx]:o.ONE_MINUS_SRC_COLOR,[vh]:o.ONE_MINUS_SRC_ALPHA,[Rx]:o.ONE_MINUS_DST_COLOR,[wx]:o.ONE_MINUS_DST_ALPHA,[Ax]:o.CONSTANT_COLOR,[Px]:o.ONE_MINUS_CONSTANT_COLOR,[Lx]:o.CONSTANT_ALPHA,[Ux]:o.ONE_MINUS_CONSTANT_ALPHA};function B(j,Ae,le,_e,Re,Te,st,Gt,nr,bt){if(j===zn){A===!0&&(ke(o.BLEND),A=!1);return}if(A===!1&&(ye(o.BLEND),A=!0),j!==mx){if(j!==S||bt!==P){if((v!==ga||C!==ga)&&(o.blendEquation(o.FUNC_ADD),v=ga,C=ga),bt)switch(j){case gs:o.blendFuncSeparate(o.ONE,o.ONE_MINUS_SRC_ALPHA,o.ONE,o.ONE_MINUS_SRC_ALPHA);break;case _v:o.blendFunc(o.ONE,o.ONE);break;case yv:o.blendFuncSeparate(o.ZERO,o.ONE_MINUS_SRC_COLOR,o.ZERO,o.ONE);break;case xv:o.blendFuncSeparate(o.ZERO,o.SRC_COLOR,o.ZERO,o.SRC_ALPHA);break;default:console.error("THREE.WebGLState: Invalid blending: ",j);break}else switch(j){case gs:o.blendFuncSeparate(o.SRC_ALPHA,o.ONE_MINUS_SRC_ALPHA,o.ONE,o.ONE_MINUS_SRC_ALPHA);break;case _v:o.blendFunc(o.SRC_ALPHA,o.ONE);break;case yv:o.blendFuncSeparate(o.ZERO,o.ONE_MINUS_SRC_COLOR,o.ZERO,o.ONE);break;case xv:o.blendFunc(o.ZERO,o.SRC_COLOR);break;default:console.error("THREE.WebGLState: Invalid blending: ",j);break}D=null,L=null,G=null,k=null,I.set(0,0,0),H=0,S=j,P=bt}return}Re=Re||Ae,Te=Te||le,st=st||_e,(Ae!==v||Re!==C)&&(o.blendEquationSeparate(ut[Ae],ut[Re]),v=Ae,C=Re),(le!==D||_e!==L||Te!==G||st!==k)&&(o.blendFuncSeparate(Vt[le],Vt[_e],Vt[Te],Vt[st]),D=le,L=_e,G=Te,k=st),(Gt.equals(I)===!1||nr!==H)&&(o.blendColor(Gt.r,Gt.g,Gt.b,nr),I.copy(Gt),H=nr),S=j,P=!1}function _r(j,Ae){j.side===an?ke(o.CULL_FACE):ye(o.CULL_FACE);let le=j.side===zr;Ae&&(le=!le),dt(le),j.blending===gs&&j.transparent===!1?B(zn):B(j.blending,j.blendEquation,j.blendSrc,j.blendDst,j.blendEquationAlpha,j.blendSrcAlpha,j.blendDstAlpha,j.blendColor,j.blendAlpha,j.premultipliedAlpha),h.setFunc(j.depthFunc),h.setTest(j.depthTest),h.setMask(j.depthWrite),u.setMask(j.colorWrite);const _e=j.stencilWrite;f.setTest(_e),_e&&(f.setMask(j.stencilWriteMask),f.setFunc(j.stencilFunc,j.stencilRef,j.stencilFuncMask),f.setOp(j.stencilFail,j.stencilZFail,j.stencilZPass)),Ct(j.polygonOffset,j.polygonOffsetFactor,j.polygonOffsetUnits),j.alphaToCoverage===!0?ye(o.SAMPLE_ALPHA_TO_COVERAGE):ke(o.SAMPLE_ALPHA_TO_COVERAGE)}function dt(j){w!==j&&(j?o.frontFace(o.CW):o.frontFace(o.CCW),w=j)}function pt(j){j!==fx?(ye(o.CULL_FACE),j!==F&&(j===vv?o.cullFace(o.BACK):j===px?o.cullFace(o.FRONT):o.cullFace(o.FRONT_AND_BACK))):ke(o.CULL_FACE),F=j}function Ge(j){j!==te&&(N&&o.lineWidth(j),te=j)}function Ct(j,Ae,le){j?(ye(o.POLYGON_OFFSET_FILL),(se!==Ae||ce!==le)&&(o.polygonOffset(Ae,le),se=Ae,ce=le)):ke(o.POLYGON_OFFSET_FILL)}function Ve(j){j?ye(o.SCISSOR_TEST):ke(o.SCISSOR_TEST)}function U(j){j===void 0&&(j=o.TEXTURE0+ve-1),ge!==j&&(o.activeTexture(j),ge=j)}function E(j,Ae,le){le===void 0&&(ge===null?le=o.TEXTURE0+ve-1:le=ge);let _e=we[le];_e===void 0&&(_e={type:void 0,texture:void 0},we[le]=_e),(_e.type!==j||_e.texture!==Ae)&&(ge!==le&&(o.activeTexture(le),ge=le),o.bindTexture(j,Ae||Me[j]),_e.type=j,_e.texture=Ae)}function ee(){const j=we[ge];j!==void 0&&j.type!==void 0&&(o.bindTexture(j.type,null),j.type=void 0,j.texture=void 0)}function he(){try{o.compressedTexImage2D(...arguments)}catch(j){console.error("THREE.WebGLState:",j)}}function be(){try{o.compressedTexImage3D(...arguments)}catch(j){console.error("THREE.WebGLState:",j)}}function pe(){try{o.texSubImage2D(...arguments)}catch(j){console.error("THREE.WebGLState:",j)}}function Be(){try{o.texSubImage3D(...arguments)}catch(j){console.error("THREE.WebGLState:",j)}}function Ce(){try{o.compressedTexSubImage2D(...arguments)}catch(j){console.error("THREE.WebGLState:",j)}}function $e(){try{o.compressedTexSubImage3D(...arguments)}catch(j){console.error("THREE.WebGLState:",j)}}function Ye(){try{o.texStorage2D(...arguments)}catch(j){console.error("THREE.WebGLState:",j)}}function Ee(){try{o.texStorage3D(...arguments)}catch(j){console.error("THREE.WebGLState:",j)}}function Ne(){try{o.texImage2D(...arguments)}catch(j){console.error("THREE.WebGLState:",j)}}function Xe(){try{o.texImage3D(...arguments)}catch(j){console.error("THREE.WebGLState:",j)}}function He(j){xe.equals(j)===!1&&(o.scissor(j.x,j.y,j.z,j.w),xe.copy(j))}function Ue(j){Q.equals(j)===!1&&(o.viewport(j.x,j.y,j.z,j.w),Q.copy(j))}function Ke(j,Ae){let le=p.get(Ae);le===void 0&&(le=new WeakMap,p.set(Ae,le));let _e=le.get(j);_e===void 0&&(_e=o.getUniformBlockIndex(Ae,j.name),le.set(j,_e))}function rt(j,Ae){const le=p.get(Ae).get(j);m.get(Ae)!==le&&(o.uniformBlockBinding(Ae,le,j.__bindingPointIndex),m.set(Ae,le))}function Ut(){o.disable(o.BLEND),o.disable(o.CULL_FACE),o.disable(o.DEPTH_TEST),o.disable(o.POLYGON_OFFSET_FILL),o.disable(o.SCISSOR_TEST),o.disable(o.STENCIL_TEST),o.disable(o.SAMPLE_ALPHA_TO_COVERAGE),o.blendEquation(o.FUNC_ADD),o.blendFunc(o.ONE,o.ZERO),o.blendFuncSeparate(o.ONE,o.ZERO,o.ONE,o.ZERO),o.blendColor(0,0,0,0),o.colorMask(!0,!0,!0,!0),o.clearColor(0,0,0,0),o.depthMask(!0),o.depthFunc(o.LESS),h.setReversed(!1),o.clearDepth(1),o.stencilMask(4294967295),o.stencilFunc(o.ALWAYS,0,4294967295),o.stencilOp(o.KEEP,o.KEEP,o.KEEP),o.clearStencil(0),o.cullFace(o.BACK),o.frontFace(o.CCW),o.polygonOffset(0,0),o.activeTexture(o.TEXTURE0),o.bindFramebuffer(o.FRAMEBUFFER,null),o.bindFramebuffer(o.DRAW_FRAMEBUFFER,null),o.bindFramebuffer(o.READ_FRAMEBUFFER,null),o.useProgram(null),o.lineWidth(1),o.scissor(0,0,o.canvas.width,o.canvas.height),o.viewport(0,0,o.canvas.width,o.canvas.height),_={},ge=null,we={},y={},x=new WeakMap,b=[],R=null,A=!1,S=null,v=null,D=null,L=null,C=null,G=null,k=null,I=new xt(0,0,0),H=0,P=!1,w=null,F=null,te=null,se=null,ce=null,xe.set(0,0,o.canvas.width,o.canvas.height),Q.set(0,0,o.canvas.width,o.canvas.height),u.reset(),h.reset(),f.reset()}return{buffers:{color:u,depth:h,stencil:f},enable:ye,disable:ke,bindFramebuffer:Fe,drawBuffers:tt,useProgram:Lt,setBlending:B,setMaterial:_r,setFlipSided:dt,setCullFace:pt,setLineWidth:Ge,setPolygonOffset:Ct,setScissorTest:Ve,activeTexture:U,bindTexture:E,unbindTexture:ee,compressedTexImage2D:he,compressedTexImage3D:be,texImage2D:Ne,texImage3D:Xe,updateUBOMapping:Ke,uniformBlockBinding:rt,texStorage2D:Ye,texStorage3D:Ee,texSubImage2D:pe,texSubImage3D:Be,compressedTexSubImage2D:Ce,compressedTexSubImage3D:$e,scissor:He,viewport:Ue,reset:Ut}}function h1(o,t,i,a,l,u,h){const f=t.has("WEBGL_multisampled_render_to_texture")?t.get("WEBGL_multisampled_render_to_texture"):null,m=typeof navigator>"u"?!1:/OculusBrowser/g.test(navigator.userAgent),p=new St,_=new WeakMap;let y;const x=new WeakMap;let b=!1;try{b=typeof OffscreenCanvas<"u"&&new OffscreenCanvas(1,1).getContext("2d")!==null}catch{}function R(U,E){return b?new OffscreenCanvas(U,E):wc("canvas")}function A(U,E,ee){let he=1;const be=Ve(U);if((be.width>ee||be.height>ee)&&(he=ee/Math.max(be.width,be.height)),he<1)if(typeof HTMLImageElement<"u"&&U instanceof HTMLImageElement||typeof HTMLCanvasElement<"u"&&U instanceof HTMLCanvasElement||typeof ImageBitmap<"u"&&U instanceof ImageBitmap||typeof VideoFrame<"u"&&U instanceof VideoFrame){const pe=Math.floor(he*be.width),Be=Math.floor(he*be.height);y===void 0&&(y=R(pe,Be));const Ce=E?R(pe,Be):y;return Ce.width=pe,Ce.height=Be,Ce.getContext("2d").drawImage(U,0,0,pe,Be),console.warn("THREE.WebGLRenderer: Texture has been resized from ("+be.width+"x"+be.height+") to ("+pe+"x"+Be+")."),Ce}else return"data"in U&&console.warn("THREE.WebGLRenderer: Image in DataTexture is too big ("+be.width+"x"+be.height+")."),U;return U}function S(U){return U.generateMipmaps}function v(U){o.generateMipmap(U)}function D(U){return U.isWebGLCubeRenderTarget?o.TEXTURE_CUBE_MAP:U.isWebGL3DRenderTarget?o.TEXTURE_3D:U.isWebGLArrayRenderTarget||U.isCompressedArrayTexture?o.TEXTURE_2D_ARRAY:o.TEXTURE_2D}function L(U,E,ee,he,be=!1){if(U!==null){if(o[U]!==void 0)return o[U];console.warn("THREE.WebGLRenderer: Attempt to use non-existing WebGL internal format '"+U+"'")}let pe=E;if(E===o.RED&&(ee===o.FLOAT&&(pe=o.R32F),ee===o.HALF_FLOAT&&(pe=o.R16F),ee===o.UNSIGNED_BYTE&&(pe=o.R8)),E===o.RED_INTEGER&&(ee===o.UNSIGNED_BYTE&&(pe=o.R8UI),ee===o.UNSIGNED_SHORT&&(pe=o.R16UI),ee===o.UNSIGNED_INT&&(pe=o.R32UI),ee===o.BYTE&&(pe=o.R8I),ee===o.SHORT&&(pe=o.R16I),ee===o.INT&&(pe=o.R32I)),E===o.RG&&(ee===o.FLOAT&&(pe=o.RG32F),ee===o.HALF_FLOAT&&(pe=o.RG16F),ee===o.UNSIGNED_BYTE&&(pe=o.RG8)),E===o.RG_INTEGER&&(ee===o.UNSIGNED_BYTE&&(pe=o.RG8UI),ee===o.UNSIGNED_SHORT&&(pe=o.RG16UI),ee===o.UNSIGNED_INT&&(pe=o.RG32UI),ee===o.BYTE&&(pe=o.RG8I),ee===o.SHORT&&(pe=o.RG16I),ee===o.INT&&(pe=o.RG32I)),E===o.RGB_INTEGER&&(ee===o.UNSIGNED_BYTE&&(pe=o.RGB8UI),ee===o.UNSIGNED_SHORT&&(pe=o.RGB16UI),ee===o.UNSIGNED_INT&&(pe=o.RGB32UI),ee===o.BYTE&&(pe=o.RGB8I),ee===o.SHORT&&(pe=o.RGB16I),ee===o.INT&&(pe=o.RGB32I)),E===o.RGBA_INTEGER&&(ee===o.UNSIGNED_BYTE&&(pe=o.RGBA8UI),ee===o.UNSIGNED_SHORT&&(pe=o.RGBA16UI),ee===o.UNSIGNED_INT&&(pe=o.RGBA32UI),ee===o.BYTE&&(pe=o.RGBA8I),ee===o.SHORT&&(pe=o.RGBA16I),ee===o.INT&&(pe=o.RGBA32I)),E===o.RGB&&ee===o.UNSIGNED_INT_5_9_9_9_REV&&(pe=o.RGB9_E5),E===o.RGBA){const Be=be?Mc:Tt.getTransfer(he);ee===o.FLOAT&&(pe=o.RGBA32F),ee===o.HALF_FLOAT&&(pe=o.RGBA16F),ee===o.UNSIGNED_BYTE&&(pe=Be===kt?o.SRGB8_ALPHA8:o.RGBA8),ee===o.UNSIGNED_SHORT_4_4_4_4&&(pe=o.RGBA4),ee===o.UNSIGNED_SHORT_5_5_5_1&&(pe=o.RGB5_A1)}return(pe===o.R16F||pe===o.R32F||pe===o.RG16F||pe===o.RG32F||pe===o.RGBA16F||pe===o.RGBA32F)&&t.get("EXT_color_buffer_float"),pe}function C(U,E){let ee;return U?E===null||E===xa||E===Co?ee=o.DEPTH24_STENCIL8:E===sn?ee=o.DEPTH32F_STENCIL8:E===Ro&&(ee=o.DEPTH24_STENCIL8,console.warn("DepthTexture: 16 bit depth attachment is not supported with stencil. Using 24-bit attachment.")):E===null||E===xa||E===Co?ee=o.DEPTH_COMPONENT24:E===sn?ee=o.DEPTH_COMPONENT32F:E===Ro&&(ee=o.DEPTH_COMPONENT16),ee}function G(U,E){return S(U)===!0||U.isFramebufferTexture&&U.minFilter!==Si&&U.minFilter!==Ci?Math.log2(Math.max(E.width,E.height))+1:U.mipmaps!==void 0&&U.mipmaps.length>0?U.mipmaps.length:U.isCompressedTexture&&Array.isArray(U.image)?E.mipmaps.length:1}function k(U){const E=U.target;E.removeEventListener("dispose",k),H(E),E.isVideoTexture&&_.delete(E)}function I(U){const E=U.target;E.removeEventListener("dispose",I),w(E)}function H(U){const E=a.get(U);if(E.__webglInit===void 0)return;const ee=U.source,he=x.get(ee);if(he){const be=he[E.__cacheKey];be.usedTimes--,be.usedTimes===0&&P(U),Object.keys(he).length===0&&x.delete(ee)}a.remove(U)}function P(U){const E=a.get(U);o.deleteTexture(E.__webglTexture);const ee=U.source,he=x.get(ee);delete he[E.__cacheKey],h.memory.textures--}function w(U){const E=a.get(U);if(U.depthTexture&&(U.depthTexture.dispose(),a.remove(U.depthTexture)),U.isWebGLCubeRenderTarget)for(let he=0;he<6;he++){if(Array.isArray(E.__webglFramebuffer[he]))for(let be=0;be<E.__webglFramebuffer[he].length;be++)o.deleteFramebuffer(E.__webglFramebuffer[he][be]);else o.deleteFramebuffer(E.__webglFramebuffer[he]);E.__webglDepthbuffer&&o.deleteRenderbuffer(E.__webglDepthbuffer[he])}else{if(Array.isArray(E.__webglFramebuffer))for(let he=0;he<E.__webglFramebuffer.length;he++)o.deleteFramebuffer(E.__webglFramebuffer[he]);else o.deleteFramebuffer(E.__webglFramebuffer);if(E.__webglDepthbuffer&&o.deleteRenderbuffer(E.__webglDepthbuffer),E.__webglMultisampledFramebuffer&&o.deleteFramebuffer(E.__webglMultisampledFramebuffer),E.__webglColorRenderbuffer)for(let he=0;he<E.__webglColorRenderbuffer.length;he++)E.__webglColorRenderbuffer[he]&&o.deleteRenderbuffer(E.__webglColorRenderbuffer[he]);E.__webglDepthRenderbuffer&&o.deleteRenderbuffer(E.__webglDepthRenderbuffer)}const ee=U.textures;for(let he=0,be=ee.length;he<be;he++){const pe=a.get(ee[he]);pe.__webglTexture&&(o.deleteTexture(pe.__webglTexture),h.memory.textures--),a.remove(ee[he])}a.remove(U)}let F=0;function te(){F=0}function se(){const U=F;return U>=l.maxTextures&&console.warn("THREE.WebGLTextures: Trying to use "+U+" texture units while this GPU supports only "+l.maxTextures),F+=1,U}function ce(U){const E=[];return E.push(U.wrapS),E.push(U.wrapT),E.push(U.wrapR||0),E.push(U.magFilter),E.push(U.minFilter),E.push(U.anisotropy),E.push(U.internalFormat),E.push(U.format),E.push(U.type),E.push(U.generateMipmaps),E.push(U.premultiplyAlpha),E.push(U.flipY),E.push(U.unpackAlignment),E.push(U.colorSpace),E.join()}function ve(U,E){const ee=a.get(U);if(U.isVideoTexture&&Ge(U),U.isRenderTargetTexture===!1&&U.version>0&&ee.__version!==U.version){const he=U.image;if(he===null)console.warn("THREE.WebGLRenderer: Texture marked for update but no image data found.");else if(he.complete===!1)console.warn("THREE.WebGLRenderer: Texture marked for update but image is incomplete");else{Q(ee,U,E);return}}i.bindTexture(o.TEXTURE_2D,ee.__webglTexture,o.TEXTURE0+E)}function N(U,E){const ee=a.get(U);if(U.version>0&&ee.__version!==U.version){Q(ee,U,E);return}i.bindTexture(o.TEXTURE_2D_ARRAY,ee.__webglTexture,o.TEXTURE0+E)}function K(U,E){const ee=a.get(U);if(U.version>0&&ee.__version!==U.version){Q(ee,U,E);return}i.bindTexture(o.TEXTURE_3D,ee.__webglTexture,o.TEXTURE0+E)}function q(U,E){const ee=a.get(U);if(U.version>0&&ee.__version!==U.version){ue(ee,U,E);return}i.bindTexture(o.TEXTURE_CUBE_MAP,ee.__webglTexture,o.TEXTURE0+E)}const ge={[Rh]:o.REPEAT,[_a]:o.CLAMP_TO_EDGE,[Ch]:o.MIRRORED_REPEAT},we={[Si]:o.NEAREST,[Hx]:o.NEAREST_MIPMAP_NEAREST,[Yl]:o.NEAREST_MIPMAP_LINEAR,[Ci]:o.LINEAR,[kd]:o.LINEAR_MIPMAP_NEAREST,[ya]:o.LINEAR_MIPMAP_LINEAR},O={[jx]:o.NEVER,[Kx]:o.ALWAYS,[Xx]:o.LESS,[I_]:o.LEQUAL,[Yx]:o.EQUAL,[$x]:o.GEQUAL,[qx]:o.GREATER,[Qx]:o.NOTEQUAL};function ie(U,E){if(E.type===sn&&t.has("OES_texture_float_linear")===!1&&(E.magFilter===Ci||E.magFilter===kd||E.magFilter===Yl||E.magFilter===ya||E.minFilter===Ci||E.minFilter===kd||E.minFilter===Yl||E.minFilter===ya)&&console.warn("THREE.WebGLRenderer: Unable to use linear filtering with floating point textures. OES_texture_float_linear not supported on this device."),o.texParameteri(U,o.TEXTURE_WRAP_S,ge[E.wrapS]),o.texParameteri(U,o.TEXTURE_WRAP_T,ge[E.wrapT]),(U===o.TEXTURE_3D||U===o.TEXTURE_2D_ARRAY)&&o.texParameteri(U,o.TEXTURE_WRAP_R,ge[E.wrapR]),o.texParameteri(U,o.TEXTURE_MAG_FILTER,we[E.magFilter]),o.texParameteri(U,o.TEXTURE_MIN_FILTER,we[E.minFilter]),E.compareFunction&&(o.texParameteri(U,o.TEXTURE_COMPARE_MODE,o.COMPARE_REF_TO_TEXTURE),o.texParameteri(U,o.TEXTURE_COMPARE_FUNC,O[E.compareFunction])),t.has("EXT_texture_filter_anisotropic")===!0){if(E.magFilter===Si||E.minFilter!==Yl&&E.minFilter!==ya||E.type===sn&&t.has("OES_texture_float_linear")===!1)return;if(E.anisotropy>1||a.get(E).__currentAnisotropy){const ee=t.get("EXT_texture_filter_anisotropic");o.texParameterf(U,ee.TEXTURE_MAX_ANISOTROPY_EXT,Math.min(E.anisotropy,l.getMaxAnisotropy())),a.get(E).__currentAnisotropy=E.anisotropy}}}function xe(U,E){let ee=!1;U.__webglInit===void 0&&(U.__webglInit=!0,E.addEventListener("dispose",k));const he=E.source;let be=x.get(he);be===void 0&&(be={},x.set(he,be));const pe=ce(E);if(pe!==U.__cacheKey){be[pe]===void 0&&(be[pe]={texture:o.createTexture(),usedTimes:0},h.memory.textures++,ee=!0),be[pe].usedTimes++;const Be=be[U.__cacheKey];Be!==void 0&&(be[U.__cacheKey].usedTimes--,Be.usedTimes===0&&P(E)),U.__cacheKey=pe,U.__webglTexture=be[pe].texture}return ee}function Q(U,E,ee){let he=o.TEXTURE_2D;(E.isDataArrayTexture||E.isCompressedArrayTexture)&&(he=o.TEXTURE_2D_ARRAY),E.isData3DTexture&&(he=o.TEXTURE_3D);const be=xe(U,E),pe=E.source;i.bindTexture(he,U.__webglTexture,o.TEXTURE0+ee);const Be=a.get(pe);if(pe.version!==Be.__version||be===!0){i.activeTexture(o.TEXTURE0+ee);const Ce=Tt.getPrimaries(Tt.workingColorSpace),$e=E.colorSpace===Fn?null:Tt.getPrimaries(E.colorSpace),Ye=E.colorSpace===Fn||Ce===$e?o.NONE:o.BROWSER_DEFAULT_WEBGL;o.pixelStorei(o.UNPACK_FLIP_Y_WEBGL,E.flipY),o.pixelStorei(o.UNPACK_PREMULTIPLY_ALPHA_WEBGL,E.premultiplyAlpha),o.pixelStorei(o.UNPACK_ALIGNMENT,E.unpackAlignment),o.pixelStorei(o.UNPACK_COLORSPACE_CONVERSION_WEBGL,Ye);let Ee=A(E.image,!1,l.maxTextureSize);Ee=Ct(E,Ee);const Ne=u.convert(E.format,E.colorSpace),Xe=u.convert(E.type);let He=L(E.internalFormat,Ne,Xe,E.colorSpace,E.isVideoTexture);ie(he,E);let Ue;const Ke=E.mipmaps,rt=E.isVideoTexture!==!0,Ut=Be.__version===void 0||be===!0,j=pe.dataReady,Ae=G(E,Ee);if(E.isDepthTexture)He=C(E.format===Po,E.type),Ut&&(rt?i.texStorage2D(o.TEXTURE_2D,1,He,Ee.width,Ee.height):i.texImage2D(o.TEXTURE_2D,0,He,Ee.width,Ee.height,0,Ne,Xe,null));else if(E.isDataTexture)if(Ke.length>0){rt&&Ut&&i.texStorage2D(o.TEXTURE_2D,Ae,He,Ke[0].width,Ke[0].height);for(let le=0,_e=Ke.length;le<_e;le++)Ue=Ke[le],rt?j&&i.texSubImage2D(o.TEXTURE_2D,le,0,0,Ue.width,Ue.height,Ne,Xe,Ue.data):i.texImage2D(o.TEXTURE_2D,le,He,Ue.width,Ue.height,0,Ne,Xe,Ue.data);E.generateMipmaps=!1}else rt?(Ut&&i.texStorage2D(o.TEXTURE_2D,Ae,He,Ee.width,Ee.height),j&&i.texSubImage2D(o.TEXTURE_2D,0,0,0,Ee.width,Ee.height,Ne,Xe,Ee.data)):i.texImage2D(o.TEXTURE_2D,0,He,Ee.width,Ee.height,0,Ne,Xe,Ee.data);else if(E.isCompressedTexture)if(E.isCompressedArrayTexture){rt&&Ut&&i.texStorage3D(o.TEXTURE_2D_ARRAY,Ae,He,Ke[0].width,Ke[0].height,Ee.depth);for(let le=0,_e=Ke.length;le<_e;le++)if(Ue=Ke[le],E.format!==xi)if(Ne!==null)if(rt){if(j)if(E.layerUpdates.size>0){const Re=Xv(Ue.width,Ue.height,E.format,E.type);for(const Te of E.layerUpdates){const st=Ue.data.subarray(Te*Re/Ue.data.BYTES_PER_ELEMENT,(Te+1)*Re/Ue.data.BYTES_PER_ELEMENT);i.compressedTexSubImage3D(o.TEXTURE_2D_ARRAY,le,0,0,Te,Ue.width,Ue.height,1,Ne,st)}E.clearLayerUpdates()}else i.compressedTexSubImage3D(o.TEXTURE_2D_ARRAY,le,0,0,0,Ue.width,Ue.height,Ee.depth,Ne,Ue.data)}else i.compressedTexImage3D(o.TEXTURE_2D_ARRAY,le,He,Ue.width,Ue.height,Ee.depth,0,Ue.data,0,0);else console.warn("THREE.WebGLRenderer: Attempt to load unsupported compressed texture format in .uploadTexture()");else rt?j&&i.texSubImage3D(o.TEXTURE_2D_ARRAY,le,0,0,0,Ue.width,Ue.height,Ee.depth,Ne,Xe,Ue.data):i.texImage3D(o.TEXTURE_2D_ARRAY,le,He,Ue.width,Ue.height,Ee.depth,0,Ne,Xe,Ue.data)}else{rt&&Ut&&i.texStorage2D(o.TEXTURE_2D,Ae,He,Ke[0].width,Ke[0].height);for(let le=0,_e=Ke.length;le<_e;le++)Ue=Ke[le],E.format!==xi?Ne!==null?rt?j&&i.compressedTexSubImage2D(o.TEXTURE_2D,le,0,0,Ue.width,Ue.height,Ne,Ue.data):i.compressedTexImage2D(o.TEXTURE_2D,le,He,Ue.width,Ue.height,0,Ue.data):console.warn("THREE.WebGLRenderer: Attempt to load unsupported compressed texture format in .uploadTexture()"):rt?j&&i.texSubImage2D(o.TEXTURE_2D,le,0,0,Ue.width,Ue.height,Ne,Xe,Ue.data):i.texImage2D(o.TEXTURE_2D,le,He,Ue.width,Ue.height,0,Ne,Xe,Ue.data)}else if(E.isDataArrayTexture)if(rt){if(Ut&&i.texStorage3D(o.TEXTURE_2D_ARRAY,Ae,He,Ee.width,Ee.height,Ee.depth),j)if(E.layerUpdates.size>0){const le=Xv(Ee.width,Ee.height,E.format,E.type);for(const _e of E.layerUpdates){const Re=Ee.data.subarray(_e*le/Ee.data.BYTES_PER_ELEMENT,(_e+1)*le/Ee.data.BYTES_PER_ELEMENT);i.texSubImage3D(o.TEXTURE_2D_ARRAY,0,0,0,_e,Ee.width,Ee.height,1,Ne,Xe,Re)}E.clearLayerUpdates()}else i.texSubImage3D(o.TEXTURE_2D_ARRAY,0,0,0,0,Ee.width,Ee.height,Ee.depth,Ne,Xe,Ee.data)}else i.texImage3D(o.TEXTURE_2D_ARRAY,0,He,Ee.width,Ee.height,Ee.depth,0,Ne,Xe,Ee.data);else if(E.isData3DTexture)rt?(Ut&&i.texStorage3D(o.TEXTURE_3D,Ae,He,Ee.width,Ee.height,Ee.depth),j&&i.texSubImage3D(o.TEXTURE_3D,0,0,0,0,Ee.width,Ee.height,Ee.depth,Ne,Xe,Ee.data)):i.texImage3D(o.TEXTURE_3D,0,He,Ee.width,Ee.height,Ee.depth,0,Ne,Xe,Ee.data);else if(E.isFramebufferTexture){if(Ut)if(rt)i.texStorage2D(o.TEXTURE_2D,Ae,He,Ee.width,Ee.height);else{let le=Ee.width,_e=Ee.height;for(let Re=0;Re<Ae;Re++)i.texImage2D(o.TEXTURE_2D,Re,He,le,_e,0,Ne,Xe,null),le>>=1,_e>>=1}}else if(Ke.length>0){if(rt&&Ut){const le=Ve(Ke[0]);i.texStorage2D(o.TEXTURE_2D,Ae,He,le.width,le.height)}for(let le=0,_e=Ke.length;le<_e;le++)Ue=Ke[le],rt?j&&i.texSubImage2D(o.TEXTURE_2D,le,0,0,Ne,Xe,Ue):i.texImage2D(o.TEXTURE_2D,le,He,Ne,Xe,Ue);E.generateMipmaps=!1}else if(rt){if(Ut){const le=Ve(Ee);i.texStorage2D(o.TEXTURE_2D,Ae,He,le.width,le.height)}j&&i.texSubImage2D(o.TEXTURE_2D,0,0,0,Ne,Xe,Ee)}else i.texImage2D(o.TEXTURE_2D,0,He,Ne,Xe,Ee);S(E)&&v(he),Be.__version=pe.version,E.onUpdate&&E.onUpdate(E)}U.__version=E.version}function ue(U,E,ee){if(E.image.length!==6)return;const he=xe(U,E),be=E.source;i.bindTexture(o.TEXTURE_CUBE_MAP,U.__webglTexture,o.TEXTURE0+ee);const pe=a.get(be);if(be.version!==pe.__version||he===!0){i.activeTexture(o.TEXTURE0+ee);const Be=Tt.getPrimaries(Tt.workingColorSpace),Ce=E.colorSpace===Fn?null:Tt.getPrimaries(E.colorSpace),$e=E.colorSpace===Fn||Be===Ce?o.NONE:o.BROWSER_DEFAULT_WEBGL;o.pixelStorei(o.UNPACK_FLIP_Y_WEBGL,E.flipY),o.pixelStorei(o.UNPACK_PREMULTIPLY_ALPHA_WEBGL,E.premultiplyAlpha),o.pixelStorei(o.UNPACK_ALIGNMENT,E.unpackAlignment),o.pixelStorei(o.UNPACK_COLORSPACE_CONVERSION_WEBGL,$e);const Ye=E.isCompressedTexture||E.image[0].isCompressedTexture,Ee=E.image[0]&&E.image[0].isDataTexture,Ne=[];for(let _e=0;_e<6;_e++)!Ye&&!Ee?Ne[_e]=A(E.image[_e],!0,l.maxCubemapSize):Ne[_e]=Ee?E.image[_e].image:E.image[_e],Ne[_e]=Ct(E,Ne[_e]);const Xe=Ne[0],He=u.convert(E.format,E.colorSpace),Ue=u.convert(E.type),Ke=L(E.internalFormat,He,Ue,E.colorSpace),rt=E.isVideoTexture!==!0,Ut=pe.__version===void 0||he===!0,j=be.dataReady;let Ae=G(E,Xe);ie(o.TEXTURE_CUBE_MAP,E);let le;if(Ye){rt&&Ut&&i.texStorage2D(o.TEXTURE_CUBE_MAP,Ae,Ke,Xe.width,Xe.height);for(let _e=0;_e<6;_e++){le=Ne[_e].mipmaps;for(let Re=0;Re<le.length;Re++){const Te=le[Re];E.format!==xi?He!==null?rt?j&&i.compressedTexSubImage2D(o.TEXTURE_CUBE_MAP_POSITIVE_X+_e,Re,0,0,Te.width,Te.height,He,Te.data):i.compressedTexImage2D(o.TEXTURE_CUBE_MAP_POSITIVE_X+_e,Re,Ke,Te.width,Te.height,0,Te.data):console.warn("THREE.WebGLRenderer: Attempt to load unsupported compressed texture format in .setTextureCube()"):rt?j&&i.texSubImage2D(o.TEXTURE_CUBE_MAP_POSITIVE_X+_e,Re,0,0,Te.width,Te.height,He,Ue,Te.data):i.texImage2D(o.TEXTURE_CUBE_MAP_POSITIVE_X+_e,Re,Ke,Te.width,Te.height,0,He,Ue,Te.data)}}}else{if(le=E.mipmaps,rt&&Ut){le.length>0&&Ae++;const _e=Ve(Ne[0]);i.texStorage2D(o.TEXTURE_CUBE_MAP,Ae,Ke,_e.width,_e.height)}for(let _e=0;_e<6;_e++)if(Ee){rt?j&&i.texSubImage2D(o.TEXTURE_CUBE_MAP_POSITIVE_X+_e,0,0,0,Ne[_e].width,Ne[_e].height,He,Ue,Ne[_e].data):i.texImage2D(o.TEXTURE_CUBE_MAP_POSITIVE_X+_e,0,Ke,Ne[_e].width,Ne[_e].height,0,He,Ue,Ne[_e].data);for(let Re=0;Re<le.length;Re++){const Te=le[Re].image[_e].image;rt?j&&i.texSubImage2D(o.TEXTURE_CUBE_MAP_POSITIVE_X+_e,Re+1,0,0,Te.width,Te.height,He,Ue,Te.data):i.texImage2D(o.TEXTURE_CUBE_MAP_POSITIVE_X+_e,Re+1,Ke,Te.width,Te.height,0,He,Ue,Te.data)}}else{rt?j&&i.texSubImage2D(o.TEXTURE_CUBE_MAP_POSITIVE_X+_e,0,0,0,He,Ue,Ne[_e]):i.texImage2D(o.TEXTURE_CUBE_MAP_POSITIVE_X+_e,0,Ke,He,Ue,Ne[_e]);for(let Re=0;Re<le.length;Re++){const Te=le[Re];rt?j&&i.texSubImage2D(o.TEXTURE_CUBE_MAP_POSITIVE_X+_e,Re+1,0,0,He,Ue,Te.image[_e]):i.texImage2D(o.TEXTURE_CUBE_MAP_POSITIVE_X+_e,Re+1,Ke,He,Ue,Te.image[_e])}}}S(E)&&v(o.TEXTURE_CUBE_MAP),pe.__version=be.version,E.onUpdate&&E.onUpdate(E)}U.__version=E.version}function Me(U,E,ee,he,be,pe){const Be=u.convert(ee.format,ee.colorSpace),Ce=u.convert(ee.type),$e=L(ee.internalFormat,Be,Ce,ee.colorSpace),Ye=a.get(E),Ee=a.get(ee);if(Ee.__renderTarget=E,!Ye.__hasExternalTextures){const Ne=Math.max(1,E.width>>pe),Xe=Math.max(1,E.height>>pe);be===o.TEXTURE_3D||be===o.TEXTURE_2D_ARRAY?i.texImage3D(be,pe,$e,Ne,Xe,E.depth,0,Be,Ce,null):i.texImage2D(be,pe,$e,Ne,Xe,0,Be,Ce,null)}i.bindFramebuffer(o.FRAMEBUFFER,U),pt(E)?f.framebufferTexture2DMultisampleEXT(o.FRAMEBUFFER,he,be,Ee.__webglTexture,0,dt(E)):(be===o.TEXTURE_2D||be>=o.TEXTURE_CUBE_MAP_POSITIVE_X&&be<=o.TEXTURE_CUBE_MAP_NEGATIVE_Z)&&o.framebufferTexture2D(o.FRAMEBUFFER,he,be,Ee.__webglTexture,pe),i.bindFramebuffer(o.FRAMEBUFFER,null)}function ye(U,E,ee){if(o.bindRenderbuffer(o.RENDERBUFFER,U),E.depthBuffer){const he=E.depthTexture,be=he&&he.isDepthTexture?he.type:null,pe=C(E.stencilBuffer,be),Be=E.stencilBuffer?o.DEPTH_STENCIL_ATTACHMENT:o.DEPTH_ATTACHMENT,Ce=dt(E);pt(E)?f.renderbufferStorageMultisampleEXT(o.RENDERBUFFER,Ce,pe,E.width,E.height):ee?o.renderbufferStorageMultisample(o.RENDERBUFFER,Ce,pe,E.width,E.height):o.renderbufferStorage(o.RENDERBUFFER,pe,E.width,E.height),o.framebufferRenderbuffer(o.FRAMEBUFFER,Be,o.RENDERBUFFER,U)}else{const he=E.textures;for(let be=0;be<he.length;be++){const pe=he[be],Be=u.convert(pe.format,pe.colorSpace),Ce=u.convert(pe.type),$e=L(pe.internalFormat,Be,Ce,pe.colorSpace),Ye=dt(E);ee&&pt(E)===!1?o.renderbufferStorageMultisample(o.RENDERBUFFER,Ye,$e,E.width,E.height):pt(E)?f.renderbufferStorageMultisampleEXT(o.RENDERBUFFER,Ye,$e,E.width,E.height):o.renderbufferStorage(o.RENDERBUFFER,$e,E.width,E.height)}}o.bindRenderbuffer(o.RENDERBUFFER,null)}function ke(U,E){if(E&&E.isWebGLCubeRenderTarget)throw new Error("Depth Texture with cube render targets is not supported");if(i.bindFramebuffer(o.FRAMEBUFFER,U),!(E.depthTexture&&E.depthTexture.isDepthTexture))throw new Error("renderTarget.depthTexture must be an instance of THREE.DepthTexture");const ee=a.get(E.depthTexture);ee.__renderTarget=E,(!ee.__webglTexture||E.depthTexture.image.width!==E.width||E.depthTexture.image.height!==E.height)&&(E.depthTexture.image.width=E.width,E.depthTexture.image.height=E.height,E.depthTexture.needsUpdate=!0),ve(E.depthTexture,0);const he=ee.__webglTexture,be=dt(E);if(E.depthTexture.format===Ao)pt(E)?f.framebufferTexture2DMultisampleEXT(o.FRAMEBUFFER,o.DEPTH_ATTACHMENT,o.TEXTURE_2D,he,0,be):o.framebufferTexture2D(o.FRAMEBUFFER,o.DEPTH_ATTACHMENT,o.TEXTURE_2D,he,0);else if(E.depthTexture.format===Po)pt(E)?f.framebufferTexture2DMultisampleEXT(o.FRAMEBUFFER,o.DEPTH_STENCIL_ATTACHMENT,o.TEXTURE_2D,he,0,be):o.framebufferTexture2D(o.FRAMEBUFFER,o.DEPTH_STENCIL_ATTACHMENT,o.TEXTURE_2D,he,0);else throw new Error("Unknown depthTexture format")}function Fe(U){const E=a.get(U),ee=U.isWebGLCubeRenderTarget===!0;if(E.__boundDepthTexture!==U.depthTexture){const he=U.depthTexture;if(E.__depthDisposeCallback&&E.__depthDisposeCallback(),he){const be=()=>{delete E.__boundDepthTexture,delete E.__depthDisposeCallback,he.removeEventListener("dispose",be)};he.addEventListener("dispose",be),E.__depthDisposeCallback=be}E.__boundDepthTexture=he}if(U.depthTexture&&!E.__autoAllocateDepthBuffer){if(ee)throw new Error("target.depthTexture not supported in Cube render targets");const he=U.texture.mipmaps;he&&he.length>0?ke(E.__webglFramebuffer[0],U):ke(E.__webglFramebuffer,U)}else if(ee){E.__webglDepthbuffer=[];for(let he=0;he<6;he++)if(i.bindFramebuffer(o.FRAMEBUFFER,E.__webglFramebuffer[he]),E.__webglDepthbuffer[he]===void 0)E.__webglDepthbuffer[he]=o.createRenderbuffer(),ye(E.__webglDepthbuffer[he],U,!1);else{const be=U.stencilBuffer?o.DEPTH_STENCIL_ATTACHMENT:o.DEPTH_ATTACHMENT,pe=E.__webglDepthbuffer[he];o.bindRenderbuffer(o.RENDERBUFFER,pe),o.framebufferRenderbuffer(o.FRAMEBUFFER,be,o.RENDERBUFFER,pe)}}else{const he=U.texture.mipmaps;if(he&&he.length>0?i.bindFramebuffer(o.FRAMEBUFFER,E.__webglFramebuffer[0]):i.bindFramebuffer(o.FRAMEBUFFER,E.__webglFramebuffer),E.__webglDepthbuffer===void 0)E.__webglDepthbuffer=o.createRenderbuffer(),ye(E.__webglDepthbuffer,U,!1);else{const be=U.stencilBuffer?o.DEPTH_STENCIL_ATTACHMENT:o.DEPTH_ATTACHMENT,pe=E.__webglDepthbuffer;o.bindRenderbuffer(o.RENDERBUFFER,pe),o.framebufferRenderbuffer(o.FRAMEBUFFER,be,o.RENDERBUFFER,pe)}}i.bindFramebuffer(o.FRAMEBUFFER,null)}function tt(U,E,ee){const he=a.get(U);E!==void 0&&Me(he.__webglFramebuffer,U,U.texture,o.COLOR_ATTACHMENT0,o.TEXTURE_2D,0),ee!==void 0&&Fe(U)}function Lt(U){const E=U.texture,ee=a.get(U),he=a.get(E);U.addEventListener("dispose",I);const be=U.textures,pe=U.isWebGLCubeRenderTarget===!0,Be=be.length>1;if(Be||(he.__webglTexture===void 0&&(he.__webglTexture=o.createTexture()),he.__version=E.version,h.memory.textures++),pe){ee.__webglFramebuffer=[];for(let Ce=0;Ce<6;Ce++)if(E.mipmaps&&E.mipmaps.length>0){ee.__webglFramebuffer[Ce]=[];for(let $e=0;$e<E.mipmaps.length;$e++)ee.__webglFramebuffer[Ce][$e]=o.createFramebuffer()}else ee.__webglFramebuffer[Ce]=o.createFramebuffer()}else{if(E.mipmaps&&E.mipmaps.length>0){ee.__webglFramebuffer=[];for(let Ce=0;Ce<E.mipmaps.length;Ce++)ee.__webglFramebuffer[Ce]=o.createFramebuffer()}else ee.__webglFramebuffer=o.createFramebuffer();if(Be)for(let Ce=0,$e=be.length;Ce<$e;Ce++){const Ye=a.get(be[Ce]);Ye.__webglTexture===void 0&&(Ye.__webglTexture=o.createTexture(),h.memory.textures++)}if(U.samples>0&&pt(U)===!1){ee.__webglMultisampledFramebuffer=o.createFramebuffer(),ee.__webglColorRenderbuffer=[],i.bindFramebuffer(o.FRAMEBUFFER,ee.__webglMultisampledFramebuffer);for(let Ce=0;Ce<be.length;Ce++){const $e=be[Ce];ee.__webglColorRenderbuffer[Ce]=o.createRenderbuffer(),o.bindRenderbuffer(o.RENDERBUFFER,ee.__webglColorRenderbuffer[Ce]);const Ye=u.convert($e.format,$e.colorSpace),Ee=u.convert($e.type),Ne=L($e.internalFormat,Ye,Ee,$e.colorSpace,U.isXRRenderTarget===!0),Xe=dt(U);o.renderbufferStorageMultisample(o.RENDERBUFFER,Xe,Ne,U.width,U.height),o.framebufferRenderbuffer(o.FRAMEBUFFER,o.COLOR_ATTACHMENT0+Ce,o.RENDERBUFFER,ee.__webglColorRenderbuffer[Ce])}o.bindRenderbuffer(o.RENDERBUFFER,null),U.depthBuffer&&(ee.__webglDepthRenderbuffer=o.createRenderbuffer(),ye(ee.__webglDepthRenderbuffer,U,!0)),i.bindFramebuffer(o.FRAMEBUFFER,null)}}if(pe){i.bindTexture(o.TEXTURE_CUBE_MAP,he.__webglTexture),ie(o.TEXTURE_CUBE_MAP,E);for(let Ce=0;Ce<6;Ce++)if(E.mipmaps&&E.mipmaps.length>0)for(let $e=0;$e<E.mipmaps.length;$e++)Me(ee.__webglFramebuffer[Ce][$e],U,E,o.COLOR_ATTACHMENT0,o.TEXTURE_CUBE_MAP_POSITIVE_X+Ce,$e);else Me(ee.__webglFramebuffer[Ce],U,E,o.COLOR_ATTACHMENT0,o.TEXTURE_CUBE_MAP_POSITIVE_X+Ce,0);S(E)&&v(o.TEXTURE_CUBE_MAP),i.unbindTexture()}else if(Be){for(let Ce=0,$e=be.length;Ce<$e;Ce++){const Ye=be[Ce],Ee=a.get(Ye);i.bindTexture(o.TEXTURE_2D,Ee.__webglTexture),ie(o.TEXTURE_2D,Ye),Me(ee.__webglFramebuffer,U,Ye,o.COLOR_ATTACHMENT0+Ce,o.TEXTURE_2D,0),S(Ye)&&v(o.TEXTURE_2D)}i.unbindTexture()}else{let Ce=o.TEXTURE_2D;if((U.isWebGL3DRenderTarget||U.isWebGLArrayRenderTarget)&&(Ce=U.isWebGL3DRenderTarget?o.TEXTURE_3D:o.TEXTURE_2D_ARRAY),i.bindTexture(Ce,he.__webglTexture),ie(Ce,E),E.mipmaps&&E.mipmaps.length>0)for(let $e=0;$e<E.mipmaps.length;$e++)Me(ee.__webglFramebuffer[$e],U,E,o.COLOR_ATTACHMENT0,Ce,$e);else Me(ee.__webglFramebuffer,U,E,o.COLOR_ATTACHMENT0,Ce,0);S(E)&&v(Ce),i.unbindTexture()}U.depthBuffer&&Fe(U)}function ut(U){const E=U.textures;for(let ee=0,he=E.length;ee<he;ee++){const be=E[ee];if(S(be)){const pe=D(U),Be=a.get(be).__webglTexture;i.bindTexture(pe,Be),v(pe),i.unbindTexture()}}}const Vt=[],B=[];function _r(U){if(U.samples>0){if(pt(U)===!1){const E=U.textures,ee=U.width,he=U.height;let be=o.COLOR_BUFFER_BIT;const pe=U.stencilBuffer?o.DEPTH_STENCIL_ATTACHMENT:o.DEPTH_ATTACHMENT,Be=a.get(U),Ce=E.length>1;if(Ce)for(let Ye=0;Ye<E.length;Ye++)i.bindFramebuffer(o.FRAMEBUFFER,Be.__webglMultisampledFramebuffer),o.framebufferRenderbuffer(o.FRAMEBUFFER,o.COLOR_ATTACHMENT0+Ye,o.RENDERBUFFER,null),i.bindFramebuffer(o.FRAMEBUFFER,Be.__webglFramebuffer),o.framebufferTexture2D(o.DRAW_FRAMEBUFFER,o.COLOR_ATTACHMENT0+Ye,o.TEXTURE_2D,null,0);i.bindFramebuffer(o.READ_FRAMEBUFFER,Be.__webglMultisampledFramebuffer);const $e=U.texture.mipmaps;$e&&$e.length>0?i.bindFramebuffer(o.DRAW_FRAMEBUFFER,Be.__webglFramebuffer[0]):i.bindFramebuffer(o.DRAW_FRAMEBUFFER,Be.__webglFramebuffer);for(let Ye=0;Ye<E.length;Ye++){if(U.resolveDepthBuffer&&(U.depthBuffer&&(be|=o.DEPTH_BUFFER_BIT),U.stencilBuffer&&U.resolveStencilBuffer&&(be|=o.STENCIL_BUFFER_BIT)),Ce){o.framebufferRenderbuffer(o.READ_FRAMEBUFFER,o.COLOR_ATTACHMENT0,o.RENDERBUFFER,Be.__webglColorRenderbuffer[Ye]);const Ee=a.get(E[Ye]).__webglTexture;o.framebufferTexture2D(o.DRAW_FRAMEBUFFER,o.COLOR_ATTACHMENT0,o.TEXTURE_2D,Ee,0)}o.blitFramebuffer(0,0,ee,he,0,0,ee,he,be,o.NEAREST),m===!0&&(Vt.length=0,B.length=0,Vt.push(o.COLOR_ATTACHMENT0+Ye),U.depthBuffer&&U.resolveDepthBuffer===!1&&(Vt.push(pe),B.push(pe),o.invalidateFramebuffer(o.DRAW_FRAMEBUFFER,B)),o.invalidateFramebuffer(o.READ_FRAMEBUFFER,Vt))}if(i.bindFramebuffer(o.READ_FRAMEBUFFER,null),i.bindFramebuffer(o.DRAW_FRAMEBUFFER,null),Ce)for(let Ye=0;Ye<E.length;Ye++){i.bindFramebuffer(o.FRAMEBUFFER,Be.__webglMultisampledFramebuffer),o.framebufferRenderbuffer(o.FRAMEBUFFER,o.COLOR_ATTACHMENT0+Ye,o.RENDERBUFFER,Be.__webglColorRenderbuffer[Ye]);const Ee=a.get(E[Ye]).__webglTexture;i.bindFramebuffer(o.FRAMEBUFFER,Be.__webglFramebuffer),o.framebufferTexture2D(o.DRAW_FRAMEBUFFER,o.COLOR_ATTACHMENT0+Ye,o.TEXTURE_2D,Ee,0)}i.bindFramebuffer(o.DRAW_FRAMEBUFFER,Be.__webglMultisampledFramebuffer)}else if(U.depthBuffer&&U.resolveDepthBuffer===!1&&m){const E=U.stencilBuffer?o.DEPTH_STENCIL_ATTACHMENT:o.DEPTH_ATTACHMENT;o.invalidateFramebuffer(o.DRAW_FRAMEBUFFER,[E])}}}function dt(U){return Math.min(l.maxSamples,U.samples)}function pt(U){const E=a.get(U);return U.samples>0&&t.has("WEBGL_multisampled_render_to_texture")===!0&&E.__useRenderToTexture!==!1}function Ge(U){const E=h.render.frame;_.get(U)!==E&&(_.set(U,E),U.update())}function Ct(U,E){const ee=U.colorSpace,he=U.format,be=U.type;return U.isCompressedTexture===!0||U.isVideoTexture===!0||ee!==Ss&&ee!==Fn&&(Tt.getTransfer(ee)===kt?(he!==xi||be!==Pi)&&console.warn("THREE.WebGLTextures: sRGB encoded textures have to use RGBAFormat and UnsignedByteType."):console.error("THREE.WebGLTextures: Unsupported texture color space:",ee)),E}function Ve(U){return typeof HTMLImageElement<"u"&&U instanceof HTMLImageElement?(p.width=U.naturalWidth||U.width,p.height=U.naturalHeight||U.height):typeof VideoFrame<"u"&&U instanceof VideoFrame?(p.width=U.displayWidth,p.height=U.displayHeight):(p.width=U.width,p.height=U.height),p}this.allocateTextureUnit=se,this.resetTextureUnits=te,this.setTexture2D=ve,this.setTexture2DArray=N,this.setTexture3D=K,this.setTextureCube=q,this.rebindTextures=tt,this.setupRenderTarget=Lt,this.updateRenderTargetMipmap=ut,this.updateMultisampleRenderTarget=_r,this.setupDepthRenderbuffer=Fe,this.setupFrameBufferTexture=Me,this.useMultisampledRTT=pt}function f1(o,t){function i(a,l=Fn){let u;const h=Tt.getTransfer(l);if(a===Pi)return o.UNSIGNED_BYTE;if(a===of)return o.UNSIGNED_SHORT_4_4_4_4;if(a===lf)return o.UNSIGNED_SHORT_5_5_5_1;if(a===R_)return o.UNSIGNED_INT_5_9_9_9_REV;if(a===w_)return o.BYTE;if(a===T_)return o.SHORT;if(a===Ro)return o.UNSIGNED_SHORT;if(a===sf)return o.INT;if(a===xa)return o.UNSIGNED_INT;if(a===sn)return o.FLOAT;if(a===Lo)return o.HALF_FLOAT;if(a===C_)return o.ALPHA;if(a===A_)return o.RGB;if(a===xi)return o.RGBA;if(a===Ao)return o.DEPTH_COMPONENT;if(a===Po)return o.DEPTH_STENCIL;if(a===P_)return o.RED;if(a===cf)return o.RED_INTEGER;if(a===L_)return o.RG;if(a===uf)return o.RG_INTEGER;if(a===df)return o.RGBA_INTEGER;if(a===gc||a===vc||a===_c||a===yc)if(h===kt)if(u=t.get("WEBGL_compressed_texture_s3tc_srgb"),u!==null){if(a===gc)return u.COMPRESSED_SRGB_S3TC_DXT1_EXT;if(a===vc)return u.COMPRESSED_SRGB_ALPHA_S3TC_DXT1_EXT;if(a===_c)return u.COMPRESSED_SRGB_ALPHA_S3TC_DXT3_EXT;if(a===yc)return u.COMPRESSED_SRGB_ALPHA_S3TC_DXT5_EXT}else return null;else if(u=t.get("WEBGL_compressed_texture_s3tc"),u!==null){if(a===gc)return u.COMPRESSED_RGB_S3TC_DXT1_EXT;if(a===vc)return u.COMPRESSED_RGBA_S3TC_DXT1_EXT;if(a===_c)return u.COMPRESSED_RGBA_S3TC_DXT3_EXT;if(a===yc)return u.COMPRESSED_RGBA_S3TC_DXT5_EXT}else return null;if(a===Ah||a===Ph||a===Lh||a===Uh)if(u=t.get("WEBGL_compressed_texture_pvrtc"),u!==null){if(a===Ah)return u.COMPRESSED_RGB_PVRTC_4BPPV1_IMG;if(a===Ph)return u.COMPRESSED_RGB_PVRTC_2BPPV1_IMG;if(a===Lh)return u.COMPRESSED_RGBA_PVRTC_4BPPV1_IMG;if(a===Uh)return u.COMPRESSED_RGBA_PVRTC_2BPPV1_IMG}else return null;if(a===Dh||a===Ih||a===Nh)if(u=t.get("WEBGL_compressed_texture_etc"),u!==null){if(a===Dh||a===Ih)return h===kt?u.COMPRESSED_SRGB8_ETC2:u.COMPRESSED_RGB8_ETC2;if(a===Nh)return h===kt?u.COMPRESSED_SRGB8_ALPHA8_ETC2_EAC:u.COMPRESSED_RGBA8_ETC2_EAC}else return null;if(a===Oh||a===kh||a===Fh||a===zh||a===Bh||a===Hh||a===Vh||a===Gh||a===Wh||a===jh||a===Xh||a===Yh||a===qh||a===Qh)if(u=t.get("WEBGL_compressed_texture_astc"),u!==null){if(a===Oh)return h===kt?u.COMPRESSED_SRGB8_ALPHA8_ASTC_4x4_KHR:u.COMPRESSED_RGBA_ASTC_4x4_KHR;if(a===kh)return h===kt?u.COMPRESSED_SRGB8_ALPHA8_ASTC_5x4_KHR:u.COMPRESSED_RGBA_ASTC_5x4_KHR;if(a===Fh)return h===kt?u.COMPRESSED_SRGB8_ALPHA8_ASTC_5x5_KHR:u.COMPRESSED_RGBA_ASTC_5x5_KHR;if(a===zh)return h===kt?u.COMPRESSED_SRGB8_ALPHA8_ASTC_6x5_KHR:u.COMPRESSED_RGBA_ASTC_6x5_KHR;if(a===Bh)return h===kt?u.COMPRESSED_SRGB8_ALPHA8_ASTC_6x6_KHR:u.COMPRESSED_RGBA_ASTC_6x6_KHR;if(a===Hh)return h===kt?u.COMPRESSED_SRGB8_ALPHA8_ASTC_8x5_KHR:u.COMPRESSED_RGBA_ASTC_8x5_KHR;if(a===Vh)return h===kt?u.COMPRESSED_SRGB8_ALPHA8_ASTC_8x6_KHR:u.COMPRESSED_RGBA_ASTC_8x6_KHR;if(a===Gh)return h===kt?u.COMPRESSED_SRGB8_ALPHA8_ASTC_8x8_KHR:u.COMPRESSED_RGBA_ASTC_8x8_KHR;if(a===Wh)return h===kt?u.COMPRESSED_SRGB8_ALPHA8_ASTC_10x5_KHR:u.COMPRESSED_RGBA_ASTC_10x5_KHR;if(a===jh)return h===kt?u.COMPRESSED_SRGB8_ALPHA8_ASTC_10x6_KHR:u.COMPRESSED_RGBA_ASTC_10x6_KHR;if(a===Xh)return h===kt?u.COMPRESSED_SRGB8_ALPHA8_ASTC_10x8_KHR:u.COMPRESSED_RGBA_ASTC_10x8_KHR;if(a===Yh)return h===kt?u.COMPRESSED_SRGB8_ALPHA8_ASTC_10x10_KHR:u.COMPRESSED_RGBA_ASTC_10x10_KHR;if(a===qh)return h===kt?u.COMPRESSED_SRGB8_ALPHA8_ASTC_12x10_KHR:u.COMPRESSED_RGBA_ASTC_12x10_KHR;if(a===Qh)return h===kt?u.COMPRESSED_SRGB8_ALPHA8_ASTC_12x12_KHR:u.COMPRESSED_RGBA_ASTC_12x12_KHR}else return null;if(a===xc||a===$h||a===Kh)if(u=t.get("EXT_texture_compression_bptc"),u!==null){if(a===xc)return h===kt?u.COMPRESSED_SRGB_ALPHA_BPTC_UNORM_EXT:u.COMPRESSED_RGBA_BPTC_UNORM_EXT;if(a===$h)return u.COMPRESSED_RGB_BPTC_SIGNED_FLOAT_EXT;if(a===Kh)return u.COMPRESSED_RGB_BPTC_UNSIGNED_FLOAT_EXT}else return null;if(a===U_||a===Zh||a===Jh||a===ef)if(u=t.get("EXT_texture_compression_rgtc"),u!==null){if(a===xc)return u.COMPRESSED_RED_RGTC1_EXT;if(a===Zh)return u.COMPRESSED_SIGNED_RED_RGTC1_EXT;if(a===Jh)return u.COMPRESSED_RED_GREEN_RGTC2_EXT;if(a===ef)return u.COMPRESSED_SIGNED_RED_GREEN_RGTC2_EXT}else return null;return a===Co?o.UNSIGNED_INT_24_8:o[a]!==void 0?o[a]:null}return{convert:i}}const p1=`
void main() {

	gl_Position = vec4( position, 1.0 );

}`,m1=`
uniform sampler2DArray depthColor;
uniform float depthWidth;
uniform float depthHeight;

void main() {

	vec2 coord = vec2( gl_FragCoord.x / depthWidth, gl_FragCoord.y / depthHeight );

	if ( coord.x >= 1.0 ) {

		gl_FragDepth = texture( depthColor, vec3( coord.x - 1.0, coord.y, 1 ) ).r;

	} else {

		gl_FragDepth = texture( depthColor, vec3( coord.x, coord.y, 0 ) ).r;

	}

}`;class g1{constructor(){this.texture=null,this.mesh=null,this.depthNear=0,this.depthFar=0}init(t,i,a){if(this.texture===null){const l=new Br,u=t.properties.get(l);u.__webglTexture=i.texture,(i.depthNear!==a.depthNear||i.depthFar!==a.depthFar)&&(this.depthNear=i.depthNear,this.depthFar=i.depthFar),this.texture=l}}getMesh(t){if(this.texture!==null&&this.mesh===null){const i=t.cameras[0].viewport,a=new Vn({vertexShader:p1,fragmentShader:m1,uniforms:{depthColor:{value:this.texture},depthWidth:{value:i.z},depthHeight:{value:i.w}}});this.mesh=new si(new Rc(20,20),a)}return this.mesh}reset(){this.texture=null,this.mesh=null}getDepthTexture(){return this.texture}}class v1 extends Ms{constructor(t,i){super();const a=this;let l=null,u=1,h=null,f="local-floor",m=1,p=null,_=null,y=null,x=null,b=null,R=null;const A=new g1,S=i.getContextAttributes();let v=null,D=null;const L=[],C=[],G=new St;let k=null;const I=new $r;I.viewport=new Ft;const H=new $r;H.viewport=new Ft;const P=[I,H],w=new kS;let F=null,te=null;this.cameraAutoUpdate=!0,this.enabled=!1,this.isPresenting=!1,this.getController=function(Q){let ue=L[Q];return ue===void 0&&(ue=new ah,L[Q]=ue),ue.getTargetRaySpace()},this.getControllerGrip=function(Q){let ue=L[Q];return ue===void 0&&(ue=new ah,L[Q]=ue),ue.getGripSpace()},this.getHand=function(Q){let ue=L[Q];return ue===void 0&&(ue=new ah,L[Q]=ue),ue.getHandSpace()};function se(Q){const ue=C.indexOf(Q.inputSource);if(ue===-1)return;const Me=L[ue];Me!==void 0&&(Me.update(Q.inputSource,Q.frame,p||h),Me.dispatchEvent({type:Q.type,data:Q.inputSource}))}function ce(){l.removeEventListener("select",se),l.removeEventListener("selectstart",se),l.removeEventListener("selectend",se),l.removeEventListener("squeeze",se),l.removeEventListener("squeezestart",se),l.removeEventListener("squeezeend",se),l.removeEventListener("end",ce),l.removeEventListener("inputsourceschange",ve);for(let Q=0;Q<L.length;Q++){const ue=C[Q];ue!==null&&(C[Q]=null,L[Q].disconnect(ue))}F=null,te=null,A.reset(),t.setRenderTarget(v),b=null,x=null,y=null,l=null,D=null,xe.stop(),a.isPresenting=!1,t.setPixelRatio(k),t.setSize(G.width,G.height,!1),a.dispatchEvent({type:"sessionend"})}this.setFramebufferScaleFactor=function(Q){u=Q,a.isPresenting===!0&&console.warn("THREE.WebXRManager: Cannot change framebuffer scale while presenting.")},this.setReferenceSpaceType=function(Q){f=Q,a.isPresenting===!0&&console.warn("THREE.WebXRManager: Cannot change reference space type while presenting.")},this.getReferenceSpace=function(){return p||h},this.setReferenceSpace=function(Q){p=Q},this.getBaseLayer=function(){return x!==null?x:b},this.getBinding=function(){return y},this.getFrame=function(){return R},this.getSession=function(){return l},this.setSession=async function(Q){if(l=Q,l!==null){if(v=t.getRenderTarget(),l.addEventListener("select",se),l.addEventListener("selectstart",se),l.addEventListener("selectend",se),l.addEventListener("squeeze",se),l.addEventListener("squeezestart",se),l.addEventListener("squeezeend",se),l.addEventListener("end",ce),l.addEventListener("inputsourceschange",ve),S.xrCompatible!==!0&&await i.makeXRCompatible(),k=t.getPixelRatio(),t.getSize(G),typeof XRWebGLBinding<"u"&&"createProjectionLayer"in XRWebGLBinding.prototype){let ue=null,Me=null,ye=null;S.depth&&(ye=S.stencil?i.DEPTH24_STENCIL8:i.DEPTH_COMPONENT24,ue=S.stencil?Po:Ao,Me=S.stencil?Co:xa);const ke={colorFormat:i.RGBA8,depthFormat:ye,scaleFactor:u};y=new XRWebGLBinding(l,i),x=y.createProjectionLayer(ke),l.updateRenderState({layers:[x]}),t.setPixelRatio(1),t.setSize(x.textureWidth,x.textureHeight,!1),D=new Sa(x.textureWidth,x.textureHeight,{format:xi,type:Pi,depthTexture:new W_(x.textureWidth,x.textureHeight,Me,void 0,void 0,void 0,void 0,void 0,void 0,ue),stencilBuffer:S.stencil,colorSpace:t.outputColorSpace,samples:S.antialias?4:0,resolveDepthBuffer:x.ignoreDepthValues===!1,resolveStencilBuffer:x.ignoreDepthValues===!1})}else{const ue={antialias:S.antialias,alpha:!0,depth:S.depth,stencil:S.stencil,framebufferScaleFactor:u};b=new XRWebGLLayer(l,i,ue),l.updateRenderState({baseLayer:b}),t.setPixelRatio(1),t.setSize(b.framebufferWidth,b.framebufferHeight,!1),D=new Sa(b.framebufferWidth,b.framebufferHeight,{format:xi,type:Pi,colorSpace:t.outputColorSpace,stencilBuffer:S.stencil,resolveDepthBuffer:b.ignoreDepthValues===!1,resolveStencilBuffer:b.ignoreDepthValues===!1})}D.isXRRenderTarget=!0,this.setFoveation(m),p=null,h=await l.requestReferenceSpace(f),xe.setContext(l),xe.start(),a.isPresenting=!0,a.dispatchEvent({type:"sessionstart"})}},this.getEnvironmentBlendMode=function(){if(l!==null)return l.environmentBlendMode},this.getDepthTexture=function(){return A.getDepthTexture()};function ve(Q){for(let ue=0;ue<Q.removed.length;ue++){const Me=Q.removed[ue],ye=C.indexOf(Me);ye>=0&&(C[ye]=null,L[ye].disconnect(Me))}for(let ue=0;ue<Q.added.length;ue++){const Me=Q.added[ue];let ye=C.indexOf(Me);if(ye===-1){for(let Fe=0;Fe<L.length;Fe++)if(Fe>=C.length){C.push(Me),ye=Fe;break}else if(C[Fe]===null){C[Fe]=Me,ye=Fe;break}if(ye===-1)break}const ke=L[ye];ke&&ke.connect(Me)}}const N=new $,K=new $;function q(Q,ue,Me){N.setFromMatrixPosition(ue.matrixWorld),K.setFromMatrixPosition(Me.matrixWorld);const ye=N.distanceTo(K),ke=ue.projectionMatrix.elements,Fe=Me.projectionMatrix.elements,tt=ke[14]/(ke[10]-1),Lt=ke[14]/(ke[10]+1),ut=(ke[9]+1)/ke[5],Vt=(ke[9]-1)/ke[5],B=(ke[8]-1)/ke[0],_r=(Fe[8]+1)/Fe[0],dt=tt*B,pt=tt*_r,Ge=ye/(-B+_r),Ct=Ge*-B;if(ue.matrixWorld.decompose(Q.position,Q.quaternion,Q.scale),Q.translateX(Ct),Q.translateZ(Ge),Q.matrixWorld.compose(Q.position,Q.quaternion,Q.scale),Q.matrixWorldInverse.copy(Q.matrixWorld).invert(),ke[10]===-1)Q.projectionMatrix.copy(ue.projectionMatrix),Q.projectionMatrixInverse.copy(ue.projectionMatrixInverse);else{const Ve=tt+Ge,U=Lt+Ge,E=dt-Ct,ee=pt+(ye-Ct),he=ut*Lt/U*Ve,be=Vt*Lt/U*Ve;Q.projectionMatrix.makePerspective(E,ee,he,be,Ve,U),Q.projectionMatrixInverse.copy(Q.projectionMatrix).invert()}}function ge(Q,ue){ue===null?Q.matrixWorld.copy(Q.matrix):Q.matrixWorld.multiplyMatrices(ue.matrixWorld,Q.matrix),Q.matrixWorldInverse.copy(Q.matrixWorld).invert()}this.updateCamera=function(Q){if(l===null)return;let ue=Q.near,Me=Q.far;A.texture!==null&&(A.depthNear>0&&(ue=A.depthNear),A.depthFar>0&&(Me=A.depthFar)),w.near=H.near=I.near=ue,w.far=H.far=I.far=Me,(F!==w.near||te!==w.far)&&(l.updateRenderState({depthNear:w.near,depthFar:w.far}),F=w.near,te=w.far),I.layers.mask=Q.layers.mask|2,H.layers.mask=Q.layers.mask|4,w.layers.mask=I.layers.mask|H.layers.mask;const ye=Q.parent,ke=w.cameras;ge(w,ye);for(let Fe=0;Fe<ke.length;Fe++)ge(ke[Fe],ye);ke.length===2?q(w,I,H):w.projectionMatrix.copy(I.projectionMatrix),we(Q,w,ye)};function we(Q,ue,Me){Me===null?Q.matrix.copy(ue.matrixWorld):(Q.matrix.copy(Me.matrixWorld),Q.matrix.invert(),Q.matrix.multiply(ue.matrixWorld)),Q.matrix.decompose(Q.position,Q.quaternion,Q.scale),Q.updateMatrixWorld(!0),Q.projectionMatrix.copy(ue.projectionMatrix),Q.projectionMatrixInverse.copy(ue.projectionMatrixInverse),Q.isPerspectiveCamera&&(Q.fov=tf*2*Math.atan(1/Q.projectionMatrix.elements[5]),Q.zoom=1)}this.getCamera=function(){return w},this.getFoveation=function(){if(!(x===null&&b===null))return m},this.setFoveation=function(Q){m=Q,x!==null&&(x.fixedFoveation=Q),b!==null&&b.fixedFoveation!==void 0&&(b.fixedFoveation=Q)},this.hasDepthSensing=function(){return A.texture!==null},this.getDepthSensingMesh=function(){return A.getMesh(w)};let O=null;function ie(Q,ue){if(_=ue.getViewerPose(p||h),R=ue,_!==null){const Me=_.views;b!==null&&(t.setRenderTargetFramebuffer(D,b.framebuffer),t.setRenderTarget(D));let ye=!1;Me.length!==w.cameras.length&&(w.cameras.length=0,ye=!0);for(let Fe=0;Fe<Me.length;Fe++){const tt=Me[Fe];let Lt=null;if(b!==null)Lt=b.getViewport(tt);else{const Vt=y.getViewSubImage(x,tt);Lt=Vt.viewport,Fe===0&&(t.setRenderTargetTextures(D,Vt.colorTexture,Vt.depthStencilTexture),t.setRenderTarget(D))}let ut=P[Fe];ut===void 0&&(ut=new $r,ut.layers.enable(Fe),ut.viewport=new Ft,P[Fe]=ut),ut.matrix.fromArray(tt.transform.matrix),ut.matrix.decompose(ut.position,ut.quaternion,ut.scale),ut.projectionMatrix.fromArray(tt.projectionMatrix),ut.projectionMatrixInverse.copy(ut.projectionMatrix).invert(),ut.viewport.set(Lt.x,Lt.y,Lt.width,Lt.height),Fe===0&&(w.matrix.copy(ut.matrix),w.matrix.decompose(w.position,w.quaternion,w.scale)),ye===!0&&w.cameras.push(ut)}const ke=l.enabledFeatures;if(ke&&ke.includes("depth-sensing")&&l.depthUsage=="gpu-optimized"&&y){const Fe=y.getDepthInformation(Me[0]);Fe&&Fe.isValid&&Fe.texture&&A.init(t,Fe,l.renderState)}}for(let Me=0;Me<L.length;Me++){const ye=C[Me],ke=L[Me];ye!==null&&ke!==void 0&&ke.update(ye,ue,p||h)}O&&O(Q,ue),ue.detectedPlanes&&a.dispatchEvent({type:"planesdetected",data:ue}),R=null}const xe=new Y_;xe.setAnimationLoop(ie),this.setAnimationLoop=function(Q){O=Q},this.dispose=function(){}}}const fa=new Li,_1=new Yt;function y1(o,t){function i(S,v){S.matrixAutoUpdate===!0&&S.updateMatrix(),v.value.copy(S.matrix)}function a(S,v){v.color.getRGB(S.fogColor.value,H_(o)),v.isFog?(S.fogNear.value=v.near,S.fogFar.value=v.far):v.isFogExp2&&(S.fogDensity.value=v.density)}function l(S,v,D,L,C){v.isMeshBasicMaterial||v.isMeshLambertMaterial?u(S,v):v.isMeshToonMaterial?(u(S,v),y(S,v)):v.isMeshPhongMaterial?(u(S,v),_(S,v)):v.isMeshStandardMaterial?(u(S,v),x(S,v),v.isMeshPhysicalMaterial&&b(S,v,C)):v.isMeshMatcapMaterial?(u(S,v),R(S,v)):v.isMeshDepthMaterial?u(S,v):v.isMeshDistanceMaterial?(u(S,v),A(S,v)):v.isMeshNormalMaterial?u(S,v):v.isLineBasicMaterial?(h(S,v),v.isLineDashedMaterial&&f(S,v)):v.isPointsMaterial?m(S,v,D,L):v.isSpriteMaterial?p(S,v):v.isShadowMaterial?(S.color.value.copy(v.color),S.opacity.value=v.opacity):v.isShaderMaterial&&(v.uniformsNeedUpdate=!1)}function u(S,v){S.opacity.value=v.opacity,v.color&&S.diffuse.value.copy(v.color),v.emissive&&S.emissive.value.copy(v.emissive).multiplyScalar(v.emissiveIntensity),v.map&&(S.map.value=v.map,i(v.map,S.mapTransform)),v.alphaMap&&(S.alphaMap.value=v.alphaMap,i(v.alphaMap,S.alphaMapTransform)),v.bumpMap&&(S.bumpMap.value=v.bumpMap,i(v.bumpMap,S.bumpMapTransform),S.bumpScale.value=v.bumpScale,v.side===zr&&(S.bumpScale.value*=-1)),v.normalMap&&(S.normalMap.value=v.normalMap,i(v.normalMap,S.normalMapTransform),S.normalScale.value.copy(v.normalScale),v.side===zr&&S.normalScale.value.negate()),v.displacementMap&&(S.displacementMap.value=v.displacementMap,i(v.displacementMap,S.displacementMapTransform),S.displacementScale.value=v.displacementScale,S.displacementBias.value=v.displacementBias),v.emissiveMap&&(S.emissiveMap.value=v.emissiveMap,i(v.emissiveMap,S.emissiveMapTransform)),v.specularMap&&(S.specularMap.value=v.specularMap,i(v.specularMap,S.specularMapTransform)),v.alphaTest>0&&(S.alphaTest.value=v.alphaTest);const D=t.get(v),L=D.envMap,C=D.envMapRotation;L&&(S.envMap.value=L,fa.copy(C),fa.x*=-1,fa.y*=-1,fa.z*=-1,L.isCubeTexture&&L.isRenderTargetTexture===!1&&(fa.y*=-1,fa.z*=-1),S.envMapRotation.value.setFromMatrix4(_1.makeRotationFromEuler(fa)),S.flipEnvMap.value=L.isCubeTexture&&L.isRenderTargetTexture===!1?-1:1,S.reflectivity.value=v.reflectivity,S.ior.value=v.ior,S.refractionRatio.value=v.refractionRatio),v.lightMap&&(S.lightMap.value=v.lightMap,S.lightMapIntensity.value=v.lightMapIntensity,i(v.lightMap,S.lightMapTransform)),v.aoMap&&(S.aoMap.value=v.aoMap,S.aoMapIntensity.value=v.aoMapIntensity,i(v.aoMap,S.aoMapTransform))}function h(S,v){S.diffuse.value.copy(v.color),S.opacity.value=v.opacity,v.map&&(S.map.value=v.map,i(v.map,S.mapTransform))}function f(S,v){S.dashSize.value=v.dashSize,S.totalSize.value=v.dashSize+v.gapSize,S.scale.value=v.scale}function m(S,v,D,L){S.diffuse.value.copy(v.color),S.opacity.value=v.opacity,S.size.value=v.size*D,S.scale.value=L*.5,v.map&&(S.map.value=v.map,i(v.map,S.uvTransform)),v.alphaMap&&(S.alphaMap.value=v.alphaMap,i(v.alphaMap,S.alphaMapTransform)),v.alphaTest>0&&(S.alphaTest.value=v.alphaTest)}function p(S,v){S.diffuse.value.copy(v.color),S.opacity.value=v.opacity,S.rotation.value=v.rotation,v.map&&(S.map.value=v.map,i(v.map,S.mapTransform)),v.alphaMap&&(S.alphaMap.value=v.alphaMap,i(v.alphaMap,S.alphaMapTransform)),v.alphaTest>0&&(S.alphaTest.value=v.alphaTest)}function _(S,v){S.specular.value.copy(v.specular),S.shininess.value=Math.max(v.shininess,1e-4)}function y(S,v){v.gradientMap&&(S.gradientMap.value=v.gradientMap)}function x(S,v){S.metalness.value=v.metalness,v.metalnessMap&&(S.metalnessMap.value=v.metalnessMap,i(v.metalnessMap,S.metalnessMapTransform)),S.roughness.value=v.roughness,v.roughnessMap&&(S.roughnessMap.value=v.roughnessMap,i(v.roughnessMap,S.roughnessMapTransform)),v.envMap&&(S.envMapIntensity.value=v.envMapIntensity)}function b(S,v,D){S.ior.value=v.ior,v.sheen>0&&(S.sheenColor.value.copy(v.sheenColor).multiplyScalar(v.sheen),S.sheenRoughness.value=v.sheenRoughness,v.sheenColorMap&&(S.sheenColorMap.value=v.sheenColorMap,i(v.sheenColorMap,S.sheenColorMapTransform)),v.sheenRoughnessMap&&(S.sheenRoughnessMap.value=v.sheenRoughnessMap,i(v.sheenRoughnessMap,S.sheenRoughnessMapTransform))),v.clearcoat>0&&(S.clearcoat.value=v.clearcoat,S.clearcoatRoughness.value=v.clearcoatRoughness,v.clearcoatMap&&(S.clearcoatMap.value=v.clearcoatMap,i(v.clearcoatMap,S.clearcoatMapTransform)),v.clearcoatRoughnessMap&&(S.clearcoatRoughnessMap.value=v.clearcoatRoughnessMap,i(v.clearcoatRoughnessMap,S.clearcoatRoughnessMapTransform)),v.clearcoatNormalMap&&(S.clearcoatNormalMap.value=v.clearcoatNormalMap,i(v.clearcoatNormalMap,S.clearcoatNormalMapTransform),S.clearcoatNormalScale.value.copy(v.clearcoatNormalScale),v.side===zr&&S.clearcoatNormalScale.value.negate())),v.dispersion>0&&(S.dispersion.value=v.dispersion),v.iridescence>0&&(S.iridescence.value=v.iridescence,S.iridescenceIOR.value=v.iridescenceIOR,S.iridescenceThicknessMinimum.value=v.iridescenceThicknessRange[0],S.iridescenceThicknessMaximum.value=v.iridescenceThicknessRange[1],v.iridescenceMap&&(S.iridescenceMap.value=v.iridescenceMap,i(v.iridescenceMap,S.iridescenceMapTransform)),v.iridescenceThicknessMap&&(S.iridescenceThicknessMap.value=v.iridescenceThicknessMap,i(v.iridescenceThicknessMap,S.iridescenceThicknessMapTransform))),v.transmission>0&&(S.transmission.value=v.transmission,S.transmissionSamplerMap.value=D.texture,S.transmissionSamplerSize.value.set(D.width,D.height),v.transmissionMap&&(S.transmissionMap.value=v.transmissionMap,i(v.transmissionMap,S.transmissionMapTransform)),S.thickness.value=v.thickness,v.thicknessMap&&(S.thicknessMap.value=v.thicknessMap,i(v.thicknessMap,S.thicknessMapTransform)),S.attenuationDistance.value=v.attenuationDistance,S.attenuationColor.value.copy(v.attenuationColor)),v.anisotropy>0&&(S.anisotropyVector.value.set(v.anisotropy*Math.cos(v.anisotropyRotation),v.anisotropy*Math.sin(v.anisotropyRotation)),v.anisotropyMap&&(S.anisotropyMap.value=v.anisotropyMap,i(v.anisotropyMap,S.anisotropyMapTransform))),S.specularIntensity.value=v.specularIntensity,S.specularColor.value.copy(v.specularColor),v.specularColorMap&&(S.specularColorMap.value=v.specularColorMap,i(v.specularColorMap,S.specularColorMapTransform)),v.specularIntensityMap&&(S.specularIntensityMap.value=v.specularIntensityMap,i(v.specularIntensityMap,S.specularIntensityMapTransform))}function R(S,v){v.matcap&&(S.matcap.value=v.matcap)}function A(S,v){const D=t.get(v).light;S.referencePosition.value.setFromMatrixPosition(D.matrixWorld),S.nearDistance.value=D.shadow.camera.near,S.farDistance.value=D.shadow.camera.far}return{refreshFogUniforms:a,refreshMaterialUniforms:l}}function x1(o,t,i,a){let l={},u={},h=[];const f=o.getParameter(o.MAX_UNIFORM_BUFFER_BINDINGS);function m(D,L){const C=L.program;a.uniformBlockBinding(D,C)}function p(D,L){let C=l[D.id];C===void 0&&(R(D),C=_(D),l[D.id]=C,D.addEventListener("dispose",S));const G=L.program;a.updateUBOMapping(D,G);const k=t.render.frame;u[D.id]!==k&&(x(D),u[D.id]=k)}function _(D){const L=y();D.__bindingPointIndex=L;const C=o.createBuffer(),G=D.__size,k=D.usage;return o.bindBuffer(o.UNIFORM_BUFFER,C),o.bufferData(o.UNIFORM_BUFFER,G,k),o.bindBuffer(o.UNIFORM_BUFFER,null),o.bindBufferBase(o.UNIFORM_BUFFER,L,C),C}function y(){for(let D=0;D<f;D++)if(h.indexOf(D)===-1)return h.push(D),D;return console.error("THREE.WebGLRenderer: Maximum number of simultaneously usable uniforms groups reached."),0}function x(D){const L=l[D.id],C=D.uniforms,G=D.__cache;o.bindBuffer(o.UNIFORM_BUFFER,L);for(let k=0,I=C.length;k<I;k++){const H=Array.isArray(C[k])?C[k]:[C[k]];for(let P=0,w=H.length;P<w;P++){const F=H[P];if(b(F,k,P,G)===!0){const te=F.__offset,se=Array.isArray(F.value)?F.value:[F.value];let ce=0;for(let ve=0;ve<se.length;ve++){const N=se[ve],K=A(N);typeof N=="number"||typeof N=="boolean"?(F.__data[0]=N,o.bufferSubData(o.UNIFORM_BUFFER,te+ce,F.__data)):N.isMatrix3?(F.__data[0]=N.elements[0],F.__data[1]=N.elements[1],F.__data[2]=N.elements[2],F.__data[3]=0,F.__data[4]=N.elements[3],F.__data[5]=N.elements[4],F.__data[6]=N.elements[5],F.__data[7]=0,F.__data[8]=N.elements[6],F.__data[9]=N.elements[7],F.__data[10]=N.elements[8],F.__data[11]=0):(N.toArray(F.__data,ce),ce+=K.storage/Float32Array.BYTES_PER_ELEMENT)}o.bufferSubData(o.UNIFORM_BUFFER,te,F.__data)}}}o.bindBuffer(o.UNIFORM_BUFFER,null)}function b(D,L,C,G){const k=D.value,I=L+"_"+C;if(G[I]===void 0)return typeof k=="number"||typeof k=="boolean"?G[I]=k:G[I]=k.clone(),!0;{const H=G[I];if(typeof k=="number"||typeof k=="boolean"){if(H!==k)return G[I]=k,!0}else if(H.equals(k)===!1)return H.copy(k),!0}return!1}function R(D){const L=D.uniforms;let C=0;const G=16;for(let I=0,H=L.length;I<H;I++){const P=Array.isArray(L[I])?L[I]:[L[I]];for(let w=0,F=P.length;w<F;w++){const te=P[w],se=Array.isArray(te.value)?te.value:[te.value];for(let ce=0,ve=se.length;ce<ve;ce++){const N=se[ce],K=A(N),q=C%G,ge=q%K.boundary,we=q+ge;C+=ge,we!==0&&G-we<K.storage&&(C+=G-we),te.__data=new Float32Array(K.storage/Float32Array.BYTES_PER_ELEMENT),te.__offset=C,C+=K.storage}}}const k=C%G;return k>0&&(C+=G-k),D.__size=C,D.__cache={},this}function A(D){const L={boundary:0,storage:0};return typeof D=="number"||typeof D=="boolean"?(L.boundary=4,L.storage=4):D.isVector2?(L.boundary=8,L.storage=8):D.isVector3||D.isColor?(L.boundary=16,L.storage=12):D.isVector4?(L.boundary=16,L.storage=16):D.isMatrix3?(L.boundary=48,L.storage=48):D.isMatrix4?(L.boundary=64,L.storage=64):D.isTexture?console.warn("THREE.WebGLRenderer: Texture samplers can not be part of an uniforms group."):console.warn("THREE.WebGLRenderer: Unsupported uniform value type.",D),L}function S(D){const L=D.target;L.removeEventListener("dispose",S);const C=h.indexOf(L.__bindingPointIndex);h.splice(C,1),o.deleteBuffer(l[L.id]),delete l[L.id],delete u[L.id]}function v(){for(const D in l)o.deleteBuffer(l[D]);h=[],l={},u={}}return{bind:m,update:p,dispose:v}}class S1{constructor(t={}){const{canvas:i=Jx(),context:a=null,depth:l=!0,stencil:u=!1,alpha:h=!1,antialias:f=!1,premultipliedAlpha:m=!0,preserveDrawingBuffer:p=!1,powerPreference:_="default",failIfMajorPerformanceCaveat:y=!1,reverseDepthBuffer:x=!1}=t;this.isWebGLRenderer=!0;let b;if(a!==null){if(typeof WebGLRenderingContext<"u"&&a instanceof WebGLRenderingContext)throw new Error("THREE.WebGLRenderer: WebGL 1 is not supported since r163.");b=a.getContextAttributes().alpha}else b=h;const R=new Uint32Array(4),A=new Int32Array(4);let S=null,v=null;const D=[],L=[];this.domElement=i,this.debug={checkShaderErrors:!0,onShaderError:null},this.autoClear=!0,this.autoClearColor=!0,this.autoClearDepth=!0,this.autoClearStencil=!0,this.sortObjects=!0,this.clippingPlanes=[],this.localClippingEnabled=!1,this.toneMapping=Bn,this.toneMappingExposure=1,this.transmissionResolutionScale=1;const C=this;let G=!1;this._outputColorSpace=ai;let k=0,I=0,H=null,P=-1,w=null;const F=new Ft,te=new Ft;let se=null;const ce=new xt(0);let ve=0,N=i.width,K=i.height,q=1,ge=null,we=null;const O=new Ft(0,0,N,K),ie=new Ft(0,0,N,K);let xe=!1;const Q=new gf;let ue=!1,Me=!1;const ye=new Yt,ke=new Yt,Fe=new $,tt=new Ft,Lt={background:null,fog:null,environment:null,overrideMaterial:null,isScene:!0};let ut=!1;function Vt(){return H===null?q:1}let B=a;function _r(T,X){return i.getContext(T,X)}try{const T={alpha:!0,depth:l,stencil:u,antialias:f,premultipliedAlpha:m,preserveDrawingBuffer:p,powerPreference:_,failIfMajorPerformanceCaveat:y};if("setAttribute"in i&&i.setAttribute("data-engine",`three.js r${af}`),i.addEventListener("webglcontextlost",_e,!1),i.addEventListener("webglcontextrestored",Re,!1),i.addEventListener("webglcontextcreationerror",Te,!1),B===null){const X="webgl2";if(B=_r(X,T),B===null)throw _r(X)?new Error("Error creating WebGL context with your selected attributes."):new Error("Error creating WebGL context.")}}catch(T){throw console.error("THREE.WebGLRenderer: "+T.message),T}let dt,pt,Ge,Ct,Ve,U,E,ee,he,be,pe,Be,Ce,$e,Ye,Ee,Ne,Xe,He,Ue,Ke,rt,Ut,j;function Ae(){dt=new LE(B),dt.init(),rt=new f1(B,dt),pt=new EE(B,dt,t,rt),Ge=new d1(B,dt),pt.reverseDepthBuffer&&x&&Ge.buffers.depth.setReversed(!0),Ct=new IE(B),Ve=new Zw,U=new h1(B,dt,Ge,Ve,pt,rt,Ct),E=new TE(C),ee=new PE(C),he=new BS(B),Ut=new bE(B,he),be=new UE(B,he,Ct,Ut),pe=new OE(B,be,he,Ct),He=new NE(B,pt,U),Ee=new wE(Ve),Be=new Kw(C,E,ee,dt,pt,Ut,Ee),Ce=new y1(C,Ve),$e=new e1,Ye=new s1(dt),Xe=new SE(C,E,ee,Ge,pe,b,m),Ne=new c1(C,pe,pt),j=new x1(B,Ct,pt,Ge),Ue=new ME(B,dt,Ct),Ke=new DE(B,dt,Ct),Ct.programs=Be.programs,C.capabilities=pt,C.extensions=dt,C.properties=Ve,C.renderLists=$e,C.shadowMap=Ne,C.state=Ge,C.info=Ct}Ae();const le=new v1(C,B);this.xr=le,this.getContext=function(){return B},this.getContextAttributes=function(){return B.getContextAttributes()},this.forceContextLoss=function(){const T=dt.get("WEBGL_lose_context");T&&T.loseContext()},this.forceContextRestore=function(){const T=dt.get("WEBGL_lose_context");T&&T.restoreContext()},this.getPixelRatio=function(){return q},this.setPixelRatio=function(T){T!==void 0&&(q=T,this.setSize(N,K,!1))},this.getSize=function(T){return T.set(N,K)},this.setSize=function(T,X,ne=!0){if(le.isPresenting){console.warn("THREE.WebGLRenderer: Can't change size while VR device is presenting.");return}N=T,K=X,i.width=Math.floor(T*q),i.height=Math.floor(X*q),ne===!0&&(i.style.width=T+"px",i.style.height=X+"px"),this.setViewport(0,0,T,X)},this.getDrawingBufferSize=function(T){return T.set(N*q,K*q).floor()},this.setDrawingBufferSize=function(T,X,ne){N=T,K=X,q=ne,i.width=Math.floor(T*ne),i.height=Math.floor(X*ne),this.setViewport(0,0,T,X)},this.getCurrentViewport=function(T){return T.copy(F)},this.getViewport=function(T){return T.copy(O)},this.setViewport=function(T,X,ne,ae){T.isVector4?O.set(T.x,T.y,T.z,T.w):O.set(T,X,ne,ae),Ge.viewport(F.copy(O).multiplyScalar(q).round())},this.getScissor=function(T){return T.copy(ie)},this.setScissor=function(T,X,ne,ae){T.isVector4?ie.set(T.x,T.y,T.z,T.w):ie.set(T,X,ne,ae),Ge.scissor(te.copy(ie).multiplyScalar(q).round())},this.getScissorTest=function(){return xe},this.setScissorTest=function(T){Ge.setScissorTest(xe=T)},this.setOpaqueSort=function(T){ge=T},this.setTransparentSort=function(T){we=T},this.getClearColor=function(T){return T.copy(Xe.getClearColor())},this.setClearColor=function(){Xe.setClearColor(...arguments)},this.getClearAlpha=function(){return Xe.getClearAlpha()},this.setClearAlpha=function(){Xe.setClearAlpha(...arguments)},this.clear=function(T=!0,X=!0,ne=!0){let ae=0;if(T){let W=!1;if(H!==null){const Se=H.texture.format;W=Se===df||Se===uf||Se===cf}if(W){const Se=H.texture.type,De=Se===Pi||Se===xa||Se===Ro||Se===Co||Se===of||Se===lf,Pe=Xe.getClearColor(),Ie=Xe.getClearAlpha(),Je=Pe.r,qe=Pe.g,Ze=Pe.b;De?(R[0]=Je,R[1]=qe,R[2]=Ze,R[3]=Ie,B.clearBufferuiv(B.COLOR,0,R)):(A[0]=Je,A[1]=qe,A[2]=Ze,A[3]=Ie,B.clearBufferiv(B.COLOR,0,A))}else ae|=B.COLOR_BUFFER_BIT}X&&(ae|=B.DEPTH_BUFFER_BIT),ne&&(ae|=B.STENCIL_BUFFER_BIT,this.state.buffers.stencil.setMask(4294967295)),B.clear(ae)},this.clearColor=function(){this.clear(!0,!1,!1)},this.clearDepth=function(){this.clear(!1,!0,!1)},this.clearStencil=function(){this.clear(!1,!1,!0)},this.dispose=function(){i.removeEventListener("webglcontextlost",_e,!1),i.removeEventListener("webglcontextrestored",Re,!1),i.removeEventListener("webglcontextcreationerror",Te,!1),Xe.dispose(),$e.dispose(),Ye.dispose(),Ve.dispose(),E.dispose(),ee.dispose(),pe.dispose(),Ut.dispose(),j.dispose(),Be.dispose(),le.dispose(),le.removeEventListener("sessionstart",ws),le.removeEventListener("sessionend",Ts),bi.stop()};function _e(T){T.preventDefault(),console.log("THREE.WebGLRenderer: Context Lost."),G=!0}function Re(){console.log("THREE.WebGLRenderer: Context Restored."),G=!1;const T=Ct.autoReset,X=Ne.enabled,ne=Ne.autoUpdate,ae=Ne.needsUpdate,W=Ne.type;Ae(),Ct.autoReset=T,Ne.enabled=X,Ne.autoUpdate=ne,Ne.needsUpdate=ae,Ne.type=W}function Te(T){console.error("THREE.WebGLRenderer: A WebGL context could not be created. Reason: ",T.statusMessage)}function st(T){const X=T.target;X.removeEventListener("dispose",st),Gt(X)}function Gt(T){nr(T),Ve.remove(T)}function nr(T){const X=Ve.get(T).programs;X!==void 0&&(X.forEach(function(ne){Be.releaseProgram(ne)}),T.isShaderMaterial&&Be.releaseShaderCache(T))}this.renderBufferDirect=function(T,X,ne,ae,W,Se){X===null&&(X=Lt);const De=W.isMesh&&W.matrixWorld.determinant()<0,Pe=Cs(T,X,ne,ae,W);Ge.setMaterial(ae,De);let Ie=ne.index,Je=1;if(ae.wireframe===!0){if(Ie=be.getWireframeAttribute(ne),Ie===void 0)return;Je=2}const qe=ne.drawRange,Ze=ne.attributes.position;let yt=qe.start*Je,Mt=(qe.start+qe.count)*Je;Se!==null&&(yt=Math.max(yt,Se.start*Je),Mt=Math.min(Mt,(Se.start+Se.count)*Je)),Ie!==null?(yt=Math.max(yt,0),Mt=Math.min(Mt,Ie.count)):Ze!=null&&(yt=Math.max(yt,0),Mt=Math.min(Mt,Ze.count));const Wt=Mt-yt;if(Wt<0||Wt===1/0)return;Ut.setup(W,ae,Pe,ne,Ie);let ct,lt=Ue;if(Ie!==null&&(ct=he.get(Ie),lt=Ke,lt.setIndex(ct)),W.isMesh)ae.wireframe===!0?(Ge.setLineWidth(ae.wireframeLinewidth*Vt()),lt.setMode(B.LINES)):lt.setMode(B.TRIANGLES);else if(W.isLine){let je=ae.linewidth;je===void 0&&(je=1),Ge.setLineWidth(je*Vt()),W.isLineSegments?lt.setMode(B.LINES):W.isLineLoop?lt.setMode(B.LINE_LOOP):lt.setMode(B.LINE_STRIP)}else W.isPoints?lt.setMode(B.POINTS):W.isSprite&&lt.setMode(B.TRIANGLES);if(W.isBatchedMesh)if(W._multiDrawInstances!==null)Sc("THREE.WebGLRenderer: renderMultiDrawInstances has been deprecated and will be removed in r184. Append to renderMultiDraw arguments and use indirection."),lt.renderMultiDrawInstances(W._multiDrawStarts,W._multiDrawCounts,W._multiDrawCount,W._multiDrawInstances);else if(dt.get("WEBGL_multi_draw"))lt.renderMultiDraw(W._multiDrawStarts,W._multiDrawCounts,W._multiDrawCount);else{const je=W._multiDrawStarts,hr=W._multiDrawCounts,ci=W._multiDrawCount,Ar=Ie?he.get(Ie).bytesPerElement:1,ui=Ve.get(ae).currentProgram.getUniforms();for(let wr=0;wr<ci;wr++)ui.setValue(B,"_gl_DrawID",wr),lt.render(je[wr]/Ar,hr[wr])}else if(W.isInstancedMesh)lt.renderInstances(yt,Wt,W.count);else if(ne.isInstancedBufferGeometry){const je=ne._maxInstanceCount!==void 0?ne._maxInstanceCount:1/0,hr=Math.min(ne.instanceCount,je);lt.renderInstances(yt,Wt,hr)}else lt.render(yt,Wt)};function bt(T,X,ne){T.transparent===!0&&T.side===an&&T.forceSinglePass===!1?(T.side=zr,T.needsUpdate=!0,qt(T,X,ne),T.side=Hn,T.needsUpdate=!0,qt(T,X,ne),T.side=an):qt(T,X,ne)}this.compile=function(T,X,ne=null){ne===null&&(ne=T),v=Ye.get(ne),v.init(X),L.push(v),ne.traverseVisible(function(W){W.isLight&&W.layers.test(X.layers)&&(v.pushLight(W),W.castShadow&&v.pushShadow(W))}),T!==ne&&T.traverseVisible(function(W){W.isLight&&W.layers.test(X.layers)&&(v.pushLight(W),W.castShadow&&v.pushShadow(W))}),v.setupLights();const ae=new Set;return T.traverse(function(W){if(!(W.isMesh||W.isPoints||W.isLine||W.isSprite))return;const Se=W.material;if(Se)if(Array.isArray(Se))for(let De=0;De<Se.length;De++){const Pe=Se[De];bt(Pe,ne,W),ae.add(Pe)}else bt(Se,ne,W),ae.add(Se)}),v=L.pop(),ae},this.compileAsync=function(T,X,ne=null){const ae=this.compile(T,X,ne);return new Promise(W=>{function Se(){if(ae.forEach(function(De){Ve.get(De).currentProgram.isReady()&&ae.delete(De)}),ae.size===0){W(T);return}setTimeout(Se,10)}dt.get("KHR_parallel_shader_compile")!==null?Se():setTimeout(Se,10)})};let ur=null;function oi(T){ur&&ur(T)}function ws(){bi.stop()}function Ts(){bi.start()}const bi=new Y_;bi.setAnimationLoop(oi),typeof self<"u"&&bi.setContext(self),this.setAnimationLoop=function(T){ur=T,le.setAnimationLoop(T),T===null?bi.stop():bi.start()},le.addEventListener("sessionstart",ws),le.addEventListener("sessionend",Ts),this.render=function(T,X){if(X!==void 0&&X.isCamera!==!0){console.error("THREE.WebGLRenderer.render: camera is not an instance of THREE.Camera.");return}if(G===!0)return;if(T.matrixWorldAutoUpdate===!0&&T.updateMatrixWorld(),X.parent===null&&X.matrixWorldAutoUpdate===!0&&X.updateMatrixWorld(),le.enabled===!0&&le.isPresenting===!0&&(le.cameraAutoUpdate===!0&&le.updateCamera(X),X=le.getCamera()),T.isScene===!0&&T.onBeforeRender(C,T,X,H),v=Ye.get(T,L.length),v.init(X),L.push(v),ke.multiplyMatrices(X.projectionMatrix,X.matrixWorldInverse),Q.setFromProjectionMatrix(ke),Me=this.localClippingEnabled,ue=Ee.init(this.clippingPlanes,Me),S=$e.get(T,D.length),S.init(),D.push(S),le.enabled===!0&&le.isPresenting===!0){const Se=C.xr.getDepthSensingMesh();Se!==null&&Gn(Se,X,-1/0,C.sortObjects)}Gn(T,X,0,C.sortObjects),S.finish(),C.sortObjects===!0&&S.sort(ge,we),ut=le.enabled===!1||le.isPresenting===!1||le.hasDepthSensing()===!1,ut&&Xe.addToRenderList(S,T),this.info.render.frame++,ue===!0&&Ee.beginShadows();const ne=v.state.shadowsArray;Ne.render(ne,T,X),ue===!0&&Ee.endShadows(),this.info.autoReset===!0&&this.info.reset();const ae=S.opaque,W=S.transmissive;if(v.setupLights(),X.isArrayCamera){const Se=X.cameras;if(W.length>0)for(let De=0,Pe=Se.length;De<Pe;De++){const Ie=Se[De];Rs(ae,W,T,Ie)}ut&&Xe.render(T);for(let De=0,Pe=Se.length;De<Pe;De++){const Ie=Se[De];ba(S,T,Ie,Ie.viewport)}}else W.length>0&&Rs(ae,W,T,X),ut&&Xe.render(T),ba(S,T,X);H!==null&&I===0&&(U.updateMultisampleRenderTarget(H),U.updateRenderTargetMipmap(H)),T.isScene===!0&&T.onAfterRender(C,T,X),Ut.resetDefaultState(),P=-1,w=null,L.pop(),L.length>0?(v=L[L.length-1],ue===!0&&Ee.setGlobalState(C.clippingPlanes,v.state.camera)):v=null,D.pop(),D.length>0?S=D[D.length-1]:S=null};function Gn(T,X,ne,ae){if(T.visible===!1)return;if(T.layers.test(X.layers)){if(T.isGroup)ne=T.renderOrder;else if(T.isLOD)T.autoUpdate===!0&&T.update(X);else if(T.isLight)v.pushLight(T),T.castShadow&&v.pushShadow(T);else if(T.isSprite){if(!T.frustumCulled||Q.intersectsSprite(T)){ae&&tt.setFromMatrixPosition(T.matrixWorld).applyMatrix4(ke);const Se=pe.update(T),De=T.material;De.visible&&S.push(T,Se,De,ne,tt.z,null)}}else if((T.isMesh||T.isLine||T.isPoints)&&(!T.frustumCulled||Q.intersectsObject(T))){const Se=pe.update(T),De=T.material;if(ae&&(T.boundingSphere!==void 0?(T.boundingSphere===null&&T.computeBoundingSphere(),tt.copy(T.boundingSphere.center)):(Se.boundingSphere===null&&Se.computeBoundingSphere(),tt.copy(Se.boundingSphere.center)),tt.applyMatrix4(T.matrixWorld).applyMatrix4(ke)),Array.isArray(De)){const Pe=Se.groups;for(let Ie=0,Je=Pe.length;Ie<Je;Ie++){const qe=Pe[Ie],Ze=De[qe.materialIndex];Ze&&Ze.visible&&S.push(T,Se,Ze,ne,tt.z,qe)}}else De.visible&&S.push(T,Se,De,ne,tt.z,null)}}const W=T.children;for(let Se=0,De=W.length;Se<De;Se++)Gn(W[Se],X,ne,ae)}function ba(T,X,ne,ae){const W=T.opaque,Se=T.transmissive,De=T.transparent;v.setupLightsView(ne),ue===!0&&Ee.setGlobalState(C.clippingPlanes,ne),ae&&Ge.viewport(F.copy(ae)),W.length>0&&Wn(W,X,ne),Se.length>0&&Wn(Se,X,ne),De.length>0&&Wn(De,X,ne),Ge.buffers.depth.setTest(!0),Ge.buffers.depth.setMask(!0),Ge.buffers.color.setMask(!0),Ge.setPolygonOffset(!1)}function Rs(T,X,ne,ae){if((ne.isScene===!0?ne.overrideMaterial:null)!==null)return;v.state.transmissionRenderTarget[ae.id]===void 0&&(v.state.transmissionRenderTarget[ae.id]=new Sa(1,1,{generateMipmaps:!0,type:dt.has("EXT_color_buffer_half_float")||dt.has("EXT_color_buffer_float")?Lo:Pi,minFilter:ya,samples:4,stencilBuffer:u,resolveDepthBuffer:!1,resolveStencilBuffer:!1,colorSpace:Tt.workingColorSpace}));const W=v.state.transmissionRenderTarget[ae.id],Se=ae.viewport||F;W.setSize(Se.z*C.transmissionResolutionScale,Se.w*C.transmissionResolutionScale);const De=C.getRenderTarget();C.setRenderTarget(W),C.getClearColor(ce),ve=C.getClearAlpha(),ve<1&&C.setClearColor(16777215,.5),C.clear(),ut&&Xe.render(ne);const Pe=C.toneMapping;C.toneMapping=Bn;const Ie=ae.viewport;if(ae.viewport!==void 0&&(ae.viewport=void 0),v.setupLightsView(ae),ue===!0&&Ee.setGlobalState(C.clippingPlanes,ae),Wn(T,ne,ae),U.updateMultisampleRenderTarget(W),U.updateRenderTargetMipmap(W),dt.has("WEBGL_multisampled_render_to_texture")===!1){let Je=!1;for(let qe=0,Ze=X.length;qe<Ze;qe++){const yt=X[qe],Mt=yt.object,Wt=yt.geometry,ct=yt.material,lt=yt.group;if(ct.side===an&&Mt.layers.test(ae.layers)){const je=ct.side;ct.side=zr,ct.needsUpdate=!0,li(Mt,ne,ae,Wt,ct,lt),ct.side=je,ct.needsUpdate=!0,Je=!0}}Je===!0&&(U.updateMultisampleRenderTarget(W),U.updateRenderTargetMipmap(W))}C.setRenderTarget(De),C.setClearColor(ce,ve),Ie!==void 0&&(ae.viewport=Ie),C.toneMapping=Pe}function Wn(T,X,ne){const ae=X.isScene===!0?X.overrideMaterial:null;for(let W=0,Se=T.length;W<Se;W++){const De=T[W],Pe=De.object,Ie=De.geometry,Je=De.group;let qe=De.material;qe.allowOverride===!0&&ae!==null&&(qe=ae),Pe.layers.test(ne.layers)&&li(Pe,X,ne,Ie,qe,Je)}}function li(T,X,ne,ae,W,Se){T.onBeforeRender(C,X,ne,ae,W,Se),T.modelViewMatrix.multiplyMatrices(ne.matrixWorldInverse,T.matrixWorld),T.normalMatrix.getNormalMatrix(T.modelViewMatrix),W.onBeforeRender(C,X,ne,ae,T,Se),W.transparent===!0&&W.side===an&&W.forceSinglePass===!1?(W.side=zr,W.needsUpdate=!0,C.renderBufferDirect(ne,X,ae,W,T,Se),W.side=Hn,W.needsUpdate=!0,C.renderBufferDirect(ne,X,ae,W,T,Se),W.side=an):C.renderBufferDirect(ne,X,ae,W,T,Se),T.onAfterRender(C,X,ne,ae,W,Se)}function qt(T,X,ne){X.isScene!==!0&&(X=Lt);const ae=Ve.get(T),W=v.state.lights,Se=v.state.shadowsArray,De=W.state.version,Pe=Be.getParameters(T,W.state,Se,X,ne),Ie=Be.getProgramCacheKey(Pe);let Je=ae.programs;ae.environment=T.isMeshStandardMaterial?X.environment:null,ae.fog=X.fog,ae.envMap=(T.isMeshStandardMaterial?ee:E).get(T.envMap||ae.environment),ae.envMapRotation=ae.environment!==null&&T.envMap===null?X.environmentRotation:T.envMapRotation,Je===void 0&&(T.addEventListener("dispose",st),Je=new Map,ae.programs=Je);let qe=Je.get(Ie);if(qe!==void 0){if(ae.currentProgram===qe&&ae.lightsStateVersion===De)return Di(T,Pe),qe}else Pe.uniforms=Be.getUniforms(T),T.onBeforeCompile(Pe,C),qe=Be.acquireProgram(Pe,Ie),Je.set(Ie,qe),ae.uniforms=Pe.uniforms;const Ze=ae.uniforms;return(!T.isShaderMaterial&&!T.isRawShaderMaterial||T.clipping===!0)&&(Ze.clippingPlanes=Ee.uniform),Di(T,Pe),ae.needsLights=Pc(T),ae.lightsStateVersion=De,ae.needsLights&&(Ze.ambientLightColor.value=W.state.ambient,Ze.lightProbe.value=W.state.probe,Ze.directionalLights.value=W.state.directional,Ze.directionalLightShadows.value=W.state.directionalShadow,Ze.spotLights.value=W.state.spot,Ze.spotLightShadows.value=W.state.spotShadow,Ze.rectAreaLights.value=W.state.rectArea,Ze.ltc_1.value=W.state.rectAreaLTC1,Ze.ltc_2.value=W.state.rectAreaLTC2,Ze.pointLights.value=W.state.point,Ze.pointLightShadows.value=W.state.pointShadow,Ze.hemisphereLights.value=W.state.hemi,Ze.directionalShadowMap.value=W.state.directionalShadowMap,Ze.directionalShadowMatrix.value=W.state.directionalShadowMatrix,Ze.spotShadowMap.value=W.state.spotShadowMap,Ze.spotLightMatrix.value=W.state.spotLightMatrix,Ze.spotLightMap.value=W.state.spotLightMap,Ze.pointShadowMap.value=W.state.pointShadowMap,Ze.pointShadowMatrix.value=W.state.pointShadowMatrix),ae.currentProgram=qe,ae.uniformsList=null,qe}function dr(T){if(T.uniformsList===null){const X=T.currentProgram.getUniforms();T.uniformsList=bc.seqWithValue(X.seq,T.uniforms)}return T.uniformsList}function Di(T,X){const ne=Ve.get(T);ne.outputColorSpace=X.outputColorSpace,ne.batching=X.batching,ne.batchingColor=X.batchingColor,ne.instancing=X.instancing,ne.instancingColor=X.instancingColor,ne.instancingMorph=X.instancingMorph,ne.skinning=X.skinning,ne.morphTargets=X.morphTargets,ne.morphNormals=X.morphNormals,ne.morphColors=X.morphColors,ne.morphTargetsCount=X.morphTargetsCount,ne.numClippingPlanes=X.numClippingPlanes,ne.numIntersection=X.numClipIntersection,ne.vertexAlphas=X.vertexAlphas,ne.vertexTangents=X.vertexTangents,ne.toneMapping=X.toneMapping}function Cs(T,X,ne,ae,W){X.isScene!==!0&&(X=Lt),U.resetTextureUnits();const Se=X.fog,De=ae.isMeshStandardMaterial?X.environment:null,Pe=H===null?C.outputColorSpace:H.isXRRenderTarget===!0?H.texture.colorSpace:Ss,Ie=(ae.isMeshStandardMaterial?ee:E).get(ae.envMap||De),Je=ae.vertexColors===!0&&!!ne.attributes.color&&ne.attributes.color.itemSize===4,qe=!!ne.attributes.tangent&&(!!ae.normalMap||ae.anisotropy>0),Ze=!!ne.morphAttributes.position,yt=!!ne.morphAttributes.normal,Mt=!!ne.morphAttributes.color;let Wt=Bn;ae.toneMapped&&(H===null||H.isXRRenderTarget===!0)&&(Wt=C.toneMapping);const ct=ne.morphAttributes.position||ne.morphAttributes.normal||ne.morphAttributes.color,lt=ct!==void 0?ct.length:0,je=Ve.get(ae),hr=v.state.lights;if(ue===!0&&(Me===!0||T!==w)){const jt=T===w&&ae.id===P;Ee.setState(ae,T,jt)}let ci=!1;ae.version===je.__version?(je.needsLights&&je.lightsStateVersion!==hr.state.version||je.outputColorSpace!==Pe||W.isBatchedMesh&&je.batching===!1||!W.isBatchedMesh&&je.batching===!0||W.isBatchedMesh&&je.batchingColor===!0&&W.colorTexture===null||W.isBatchedMesh&&je.batchingColor===!1&&W.colorTexture!==null||W.isInstancedMesh&&je.instancing===!1||!W.isInstancedMesh&&je.instancing===!0||W.isSkinnedMesh&&je.skinning===!1||!W.isSkinnedMesh&&je.skinning===!0||W.isInstancedMesh&&je.instancingColor===!0&&W.instanceColor===null||W.isInstancedMesh&&je.instancingColor===!1&&W.instanceColor!==null||W.isInstancedMesh&&je.instancingMorph===!0&&W.morphTexture===null||W.isInstancedMesh&&je.instancingMorph===!1&&W.morphTexture!==null||je.envMap!==Ie||ae.fog===!0&&je.fog!==Se||je.numClippingPlanes!==void 0&&(je.numClippingPlanes!==Ee.numPlanes||je.numIntersection!==Ee.numIntersection)||je.vertexAlphas!==Je||je.vertexTangents!==qe||je.morphTargets!==Ze||je.morphNormals!==yt||je.morphColors!==Mt||je.toneMapping!==Wt||je.morphTargetsCount!==lt)&&(ci=!0):(ci=!0,je.__version=ae.version);let Ar=je.currentProgram;ci===!0&&(Ar=qt(ae,X,W));let ui=!1,wr=!1,fr=!1;const Dt=Ar.getUniforms(),Tr=je.uniforms;if(Ge.useProgram(Ar.program)&&(ui=!0,wr=!0,fr=!0),ae.id!==P&&(P=ae.id,wr=!0),ui||w!==T){Ge.buffers.depth.getReversed()?(ye.copy(T.projectionMatrix),tS(ye),rS(ye),Dt.setValue(B,"projectionMatrix",ye)):Dt.setValue(B,"projectionMatrix",T.projectionMatrix),Dt.setValue(B,"viewMatrix",T.matrixWorldInverse);const jt=Dt.map.cameraPosition;jt!==void 0&&jt.setValue(B,Fe.setFromMatrixPosition(T.matrixWorld)),pt.logarithmicDepthBuffer&&Dt.setValue(B,"logDepthBufFC",2/(Math.log(T.far+1)/Math.LN2)),(ae.isMeshPhongMaterial||ae.isMeshToonMaterial||ae.isMeshLambertMaterial||ae.isMeshBasicMaterial||ae.isMeshStandardMaterial||ae.isShaderMaterial)&&Dt.setValue(B,"isOrthographic",T.isOrthographicCamera===!0),w!==T&&(w=T,wr=!0,fr=!0)}if(W.isSkinnedMesh){Dt.setOptional(B,W,"bindMatrix"),Dt.setOptional(B,W,"bindMatrixInverse");const jt=W.skeleton;jt&&(jt.boneTexture===null&&jt.computeBoneTexture(),Dt.setValue(B,"boneTexture",jt.boneTexture,U))}W.isBatchedMesh&&(Dt.setOptional(B,W,"batchingTexture"),Dt.setValue(B,"batchingTexture",W._matricesTexture,U),Dt.setOptional(B,W,"batchingIdTexture"),Dt.setValue(B,"batchingIdTexture",W._indirectTexture,U),Dt.setOptional(B,W,"batchingColorTexture"),W._colorsTexture!==null&&Dt.setValue(B,"batchingColorTexture",W._colorsTexture,U));const yr=ne.morphAttributes;if((yr.position!==void 0||yr.normal!==void 0||yr.color!==void 0)&&He.update(W,ne,Ar),(wr||je.receiveShadow!==W.receiveShadow)&&(je.receiveShadow=W.receiveShadow,Dt.setValue(B,"receiveShadow",W.receiveShadow)),ae.isMeshGouraudMaterial&&ae.envMap!==null&&(Tr.envMap.value=Ie,Tr.flipEnvMap.value=Ie.isCubeTexture&&Ie.isRenderTargetTexture===!1?-1:1),ae.isMeshStandardMaterial&&ae.envMap===null&&X.environment!==null&&(Tr.envMapIntensity.value=X.environmentIntensity),wr&&(Dt.setValue(B,"toneMappingExposure",C.toneMappingExposure),je.needsLights&&Ac(Tr,fr),Se&&ae.fog===!0&&Ce.refreshFogUniforms(Tr,Se),Ce.refreshMaterialUniforms(Tr,ae,q,K,v.state.transmissionRenderTarget[T.id]),bc.upload(B,dr(je),Tr,U)),ae.isShaderMaterial&&ae.uniformsNeedUpdate===!0&&(bc.upload(B,dr(je),Tr,U),ae.uniformsNeedUpdate=!1),ae.isSpriteMaterial&&Dt.setValue(B,"center",W.center),Dt.setValue(B,"modelViewMatrix",W.modelViewMatrix),Dt.setValue(B,"normalMatrix",W.normalMatrix),Dt.setValue(B,"modelMatrix",W.matrixWorld),ae.isShaderMaterial||ae.isRawShaderMaterial){const jt=ae.uniformsGroups;for(let Pr=0,Ma=jt.length;Pr<Ma;Pr++){const Lr=jt[Pr];j.update(Lr,Ar),j.bind(Lr,Ar)}}return Ar}function Ac(T,X){T.ambientLightColor.needsUpdate=X,T.lightProbe.needsUpdate=X,T.directionalLights.needsUpdate=X,T.directionalLightShadows.needsUpdate=X,T.pointLights.needsUpdate=X,T.pointLightShadows.needsUpdate=X,T.spotLights.needsUpdate=X,T.spotLightShadows.needsUpdate=X,T.rectAreaLights.needsUpdate=X,T.hemisphereLights.needsUpdate=X}function Pc(T){return T.isMeshLambertMaterial||T.isMeshToonMaterial||T.isMeshPhongMaterial||T.isMeshStandardMaterial||T.isShadowMaterial||T.isShaderMaterial&&T.lights===!0}this.getActiveCubeFace=function(){return k},this.getActiveMipmapLevel=function(){return I},this.getRenderTarget=function(){return H},this.setRenderTargetTextures=function(T,X,ne){const ae=Ve.get(T);ae.__autoAllocateDepthBuffer=T.resolveDepthBuffer===!1,ae.__autoAllocateDepthBuffer===!1&&(ae.__useRenderToTexture=!1),Ve.get(T.texture).__webglTexture=X,Ve.get(T.depthTexture).__webglTexture=ae.__autoAllocateDepthBuffer?void 0:ne,ae.__hasExternalTextures=!0},this.setRenderTargetFramebuffer=function(T,X){const ne=Ve.get(T);ne.__webglFramebuffer=X,ne.__useDefaultFramebuffer=X===void 0};const ko=B.createFramebuffer();this.setRenderTarget=function(T,X=0,ne=0){H=T,k=X,I=ne;let ae=!0,W=null,Se=!1,De=!1;if(T){const Pe=Ve.get(T);if(Pe.__useDefaultFramebuffer!==void 0)Ge.bindFramebuffer(B.FRAMEBUFFER,null),ae=!1;else if(Pe.__webglFramebuffer===void 0)U.setupRenderTarget(T);else if(Pe.__hasExternalTextures)U.rebindTextures(T,Ve.get(T.texture).__webglTexture,Ve.get(T.depthTexture).__webglTexture);else if(T.depthBuffer){const qe=T.depthTexture;if(Pe.__boundDepthTexture!==qe){if(qe!==null&&Ve.has(qe)&&(T.width!==qe.image.width||T.height!==qe.image.height))throw new Error("WebGLRenderTarget: Attached DepthTexture is initialized to the incorrect size.");U.setupDepthRenderbuffer(T)}}const Ie=T.texture;(Ie.isData3DTexture||Ie.isDataArrayTexture||Ie.isCompressedArrayTexture)&&(De=!0);const Je=Ve.get(T).__webglFramebuffer;T.isWebGLCubeRenderTarget?(Array.isArray(Je[X])?W=Je[X][ne]:W=Je[X],Se=!0):T.samples>0&&U.useMultisampledRTT(T)===!1?W=Ve.get(T).__webglMultisampledFramebuffer:Array.isArray(Je)?W=Je[ne]:W=Je,F.copy(T.viewport),te.copy(T.scissor),se=T.scissorTest}else F.copy(O).multiplyScalar(q).floor(),te.copy(ie).multiplyScalar(q).floor(),se=xe;if(ne!==0&&(W=ko),Ge.bindFramebuffer(B.FRAMEBUFFER,W)&&ae&&Ge.drawBuffers(T,W),Ge.viewport(F),Ge.scissor(te),Ge.setScissorTest(se),Se){const Pe=Ve.get(T.texture);B.framebufferTexture2D(B.FRAMEBUFFER,B.COLOR_ATTACHMENT0,B.TEXTURE_CUBE_MAP_POSITIVE_X+X,Pe.__webglTexture,ne)}else if(De){const Pe=Ve.get(T.texture),Ie=X;B.framebufferTextureLayer(B.FRAMEBUFFER,B.COLOR_ATTACHMENT0,Pe.__webglTexture,ne,Ie)}else if(T!==null&&ne!==0){const Pe=Ve.get(T.texture);B.framebufferTexture2D(B.FRAMEBUFFER,B.COLOR_ATTACHMENT0,B.TEXTURE_2D,Pe.__webglTexture,ne)}P=-1},this.readRenderTargetPixels=function(T,X,ne,ae,W,Se,De){if(!(T&&T.isWebGLRenderTarget)){console.error("THREE.WebGLRenderer.readRenderTargetPixels: renderTarget is not THREE.WebGLRenderTarget.");return}let Pe=Ve.get(T).__webglFramebuffer;if(T.isWebGLCubeRenderTarget&&De!==void 0&&(Pe=Pe[De]),Pe){Ge.bindFramebuffer(B.FRAMEBUFFER,Pe);try{const Ie=T.texture,Je=Ie.format,qe=Ie.type;if(!pt.textureFormatReadable(Je)){console.error("THREE.WebGLRenderer.readRenderTargetPixels: renderTarget is not in RGBA or implementation defined format.");return}if(!pt.textureTypeReadable(qe)){console.error("THREE.WebGLRenderer.readRenderTargetPixels: renderTarget is not in UnsignedByteType or implementation defined type.");return}X>=0&&X<=T.width-ae&&ne>=0&&ne<=T.height-W&&B.readPixels(X,ne,ae,W,rt.convert(Je),rt.convert(qe),Se)}finally{const Ie=H!==null?Ve.get(H).__webglFramebuffer:null;Ge.bindFramebuffer(B.FRAMEBUFFER,Ie)}}},this.readRenderTargetPixelsAsync=async function(T,X,ne,ae,W,Se,De){if(!(T&&T.isWebGLRenderTarget))throw new Error("THREE.WebGLRenderer.readRenderTargetPixels: renderTarget is not THREE.WebGLRenderTarget.");let Pe=Ve.get(T).__webglFramebuffer;if(T.isWebGLCubeRenderTarget&&De!==void 0&&(Pe=Pe[De]),Pe)if(X>=0&&X<=T.width-ae&&ne>=0&&ne<=T.height-W){Ge.bindFramebuffer(B.FRAMEBUFFER,Pe);const Ie=T.texture,Je=Ie.format,qe=Ie.type;if(!pt.textureFormatReadable(Je))throw new Error("THREE.WebGLRenderer.readRenderTargetPixelsAsync: renderTarget is not in RGBA or implementation defined format.");if(!pt.textureTypeReadable(qe))throw new Error("THREE.WebGLRenderer.readRenderTargetPixelsAsync: renderTarget is not in UnsignedByteType or implementation defined type.");const Ze=B.createBuffer();B.bindBuffer(B.PIXEL_PACK_BUFFER,Ze),B.bufferData(B.PIXEL_PACK_BUFFER,Se.byteLength,B.STREAM_READ),B.readPixels(X,ne,ae,W,rt.convert(Je),rt.convert(qe),0);const yt=H!==null?Ve.get(H).__webglFramebuffer:null;Ge.bindFramebuffer(B.FRAMEBUFFER,yt);const Mt=B.fenceSync(B.SYNC_GPU_COMMANDS_COMPLETE,0);return B.flush(),await eS(B,Mt,4),B.bindBuffer(B.PIXEL_PACK_BUFFER,Ze),B.getBufferSubData(B.PIXEL_PACK_BUFFER,0,Se),B.deleteBuffer(Ze),B.deleteSync(Mt),Se}else throw new Error("THREE.WebGLRenderer.readRenderTargetPixelsAsync: requested read bounds are out of range.")},this.copyFramebufferToTexture=function(T,X=null,ne=0){const ae=Math.pow(2,-ne),W=Math.floor(T.image.width*ae),Se=Math.floor(T.image.height*ae),De=X!==null?X.x:0,Pe=X!==null?X.y:0;U.setTexture2D(T,0),B.copyTexSubImage2D(B.TEXTURE_2D,ne,0,0,De,Pe,W,Se),Ge.unbindTexture()};const jn=B.createFramebuffer(),As=B.createFramebuffer();this.copyTextureToTexture=function(T,X,ne=null,ae=null,W=0,Se=null){Se===null&&(W!==0?(Sc("WebGLRenderer: copyTextureToTexture function signature has changed to support src and dst mipmap levels."),Se=W,W=0):Se=0);let De,Pe,Ie,Je,qe,Ze,yt,Mt,Wt;const ct=T.isCompressedTexture?T.mipmaps[Se]:T.image;if(ne!==null)De=ne.max.x-ne.min.x,Pe=ne.max.y-ne.min.y,Ie=ne.isBox3?ne.max.z-ne.min.z:1,Je=ne.min.x,qe=ne.min.y,Ze=ne.isBox3?ne.min.z:0;else{const yr=Math.pow(2,-W);De=Math.floor(ct.width*yr),Pe=Math.floor(ct.height*yr),T.isDataArrayTexture?Ie=ct.depth:T.isData3DTexture?Ie=Math.floor(ct.depth*yr):Ie=1,Je=0,qe=0,Ze=0}ae!==null?(yt=ae.x,Mt=ae.y,Wt=ae.z):(yt=0,Mt=0,Wt=0);const lt=rt.convert(X.format),je=rt.convert(X.type);let hr;X.isData3DTexture?(U.setTexture3D(X,0),hr=B.TEXTURE_3D):X.isDataArrayTexture||X.isCompressedArrayTexture?(U.setTexture2DArray(X,0),hr=B.TEXTURE_2D_ARRAY):(U.setTexture2D(X,0),hr=B.TEXTURE_2D),B.pixelStorei(B.UNPACK_FLIP_Y_WEBGL,X.flipY),B.pixelStorei(B.UNPACK_PREMULTIPLY_ALPHA_WEBGL,X.premultiplyAlpha),B.pixelStorei(B.UNPACK_ALIGNMENT,X.unpackAlignment);const ci=B.getParameter(B.UNPACK_ROW_LENGTH),Ar=B.getParameter(B.UNPACK_IMAGE_HEIGHT),ui=B.getParameter(B.UNPACK_SKIP_PIXELS),wr=B.getParameter(B.UNPACK_SKIP_ROWS),fr=B.getParameter(B.UNPACK_SKIP_IMAGES);B.pixelStorei(B.UNPACK_ROW_LENGTH,ct.width),B.pixelStorei(B.UNPACK_IMAGE_HEIGHT,ct.height),B.pixelStorei(B.UNPACK_SKIP_PIXELS,Je),B.pixelStorei(B.UNPACK_SKIP_ROWS,qe),B.pixelStorei(B.UNPACK_SKIP_IMAGES,Ze);const Dt=T.isDataArrayTexture||T.isData3DTexture,Tr=X.isDataArrayTexture||X.isData3DTexture;if(T.isDepthTexture){const yr=Ve.get(T),jt=Ve.get(X),Pr=Ve.get(yr.__renderTarget),Ma=Ve.get(jt.__renderTarget);Ge.bindFramebuffer(B.READ_FRAMEBUFFER,Pr.__webglFramebuffer),Ge.bindFramebuffer(B.DRAW_FRAMEBUFFER,Ma.__webglFramebuffer);for(let Lr=0;Lr<Ie;Lr++)Dt&&(B.framebufferTextureLayer(B.READ_FRAMEBUFFER,B.COLOR_ATTACHMENT0,Ve.get(T).__webglTexture,W,Ze+Lr),B.framebufferTextureLayer(B.DRAW_FRAMEBUFFER,B.COLOR_ATTACHMENT0,Ve.get(X).__webglTexture,Se,Wt+Lr)),B.blitFramebuffer(Je,qe,De,Pe,yt,Mt,De,Pe,B.DEPTH_BUFFER_BIT,B.NEAREST);Ge.bindFramebuffer(B.READ_FRAMEBUFFER,null),Ge.bindFramebuffer(B.DRAW_FRAMEBUFFER,null)}else if(W!==0||T.isRenderTargetTexture||Ve.has(T)){const yr=Ve.get(T),jt=Ve.get(X);Ge.bindFramebuffer(B.READ_FRAMEBUFFER,jn),Ge.bindFramebuffer(B.DRAW_FRAMEBUFFER,As);for(let Pr=0;Pr<Ie;Pr++)Dt?B.framebufferTextureLayer(B.READ_FRAMEBUFFER,B.COLOR_ATTACHMENT0,yr.__webglTexture,W,Ze+Pr):B.framebufferTexture2D(B.READ_FRAMEBUFFER,B.COLOR_ATTACHMENT0,B.TEXTURE_2D,yr.__webglTexture,W),Tr?B.framebufferTextureLayer(B.DRAW_FRAMEBUFFER,B.COLOR_ATTACHMENT0,jt.__webglTexture,Se,Wt+Pr):B.framebufferTexture2D(B.DRAW_FRAMEBUFFER,B.COLOR_ATTACHMENT0,B.TEXTURE_2D,jt.__webglTexture,Se),W!==0?B.blitFramebuffer(Je,qe,De,Pe,yt,Mt,De,Pe,B.COLOR_BUFFER_BIT,B.NEAREST):Tr?B.copyTexSubImage3D(hr,Se,yt,Mt,Wt+Pr,Je,qe,De,Pe):B.copyTexSubImage2D(hr,Se,yt,Mt,Je,qe,De,Pe);Ge.bindFramebuffer(B.READ_FRAMEBUFFER,null),Ge.bindFramebuffer(B.DRAW_FRAMEBUFFER,null)}else Tr?T.isDataTexture||T.isData3DTexture?B.texSubImage3D(hr,Se,yt,Mt,Wt,De,Pe,Ie,lt,je,ct.data):X.isCompressedArrayTexture?B.compressedTexSubImage3D(hr,Se,yt,Mt,Wt,De,Pe,Ie,lt,ct.data):B.texSubImage3D(hr,Se,yt,Mt,Wt,De,Pe,Ie,lt,je,ct):T.isDataTexture?B.texSubImage2D(B.TEXTURE_2D,Se,yt,Mt,De,Pe,lt,je,ct.data):T.isCompressedTexture?B.compressedTexSubImage2D(B.TEXTURE_2D,Se,yt,Mt,ct.width,ct.height,lt,ct.data):B.texSubImage2D(B.TEXTURE_2D,Se,yt,Mt,De,Pe,lt,je,ct);B.pixelStorei(B.UNPACK_ROW_LENGTH,ci),B.pixelStorei(B.UNPACK_IMAGE_HEIGHT,Ar),B.pixelStorei(B.UNPACK_SKIP_PIXELS,ui),B.pixelStorei(B.UNPACK_SKIP_ROWS,wr),B.pixelStorei(B.UNPACK_SKIP_IMAGES,fr),Se===0&&X.generateMipmaps&&B.generateMipmap(hr),Ge.unbindTexture()},this.copyTextureToTexture3D=function(T,X,ne=null,ae=null,W=0){return Sc('WebGLRenderer: copyTextureToTexture3D function has been deprecated. Use "copyTextureToTexture" instead.'),this.copyTextureToTexture(T,X,ne,ae,W)},this.initRenderTarget=function(T){Ve.get(T).__webglFramebuffer===void 0&&U.setupRenderTarget(T)},this.initTexture=function(T){T.isCubeTexture?U.setTextureCube(T,0):T.isData3DTexture?U.setTexture3D(T,0):T.isDataArrayTexture||T.isCompressedArrayTexture?U.setTexture2DArray(T,0):U.setTexture2D(T,0),Ge.unbindTexture()},this.resetState=function(){k=0,I=0,H=null,Ge.reset(),Ut.reset()},typeof __THREE_DEVTOOLS__<"u"&&__THREE_DEVTOOLS__.dispatchEvent(new CustomEvent("observe",{detail:this}))}get coordinateSystem(){return on}get outputColorSpace(){return this._outputColorSpace}set outputColorSpace(t){this._outputColorSpace=t;const i=this.getContext();i.drawingBufferColorSpace=Tt._getDrawingBufferColorSpace(t),i.unpackColorSpace=Tt._getUnpackColorSpace()}}const _i=7,v_=10,b1=.18,M1=.6,__=1.4,y_=.55;function E1(){const o=mc.useRef(null),t=mc.useRef(null);return mc.useEffect(()=>{const i=o.current,a=new S1({antialias:!0});a.setPixelRatio(Math.min(window.devicePixelRatio,2)),a.setSize(window.innerWidth,window.innerHeight),a.shadowMap.enabled=!0,a.shadowMap.type=S_,a.toneMapping=M_,a.toneMappingExposure=1.2,i.appendChild(a.domElement);const l=new CS;l.background=new xt(657935),l.fog=new mf(657935,.032);const u=new $r(60,window.innerWidth/window.innerHeight,.1,200);u.position.set(0,5,18),u.lookAt(0,0,0);const h=new OS(1710650,1.2);l.add(h);const f=new NS(16777215,2.5);f.position.set(8,14,6),f.castShadow=!0,f.shadow.mapSize.set(1024,1024),f.shadow.camera.near=.5,f.shadow.camera.far=60,f.shadow.camera.top=15,f.shadow.camera.bottom=-15,f.shadow.camera.left=-15,f.shadow.camera.right=15,l.add(f);const m=new ch(6702335,6,25);m.position.set(-5,4,3),l.add(m);const p=new ch(16729190,6,25);p.position.set(5,-3,4),l.add(p);const _=new ch(4521932,4,20);_.position.set(0,-6,-5),l.add(_);const y=new xf(2.2,.65,180,24,2,3),x=new Hv({color:8939263,metalness:.85,roughness:.12,envMapIntensity:1}),b=new si(y,x);b.castShadow=!0,b.receiveShadow=!1,l.add(b);const R=new _f(4.5,1),A=new pf({color:4508927,wireframe:!0,transparent:!0,opacity:.35}),S=new si(R,A);l.add(S);const v=new yf(b1,14,14),D=[],L=[];for(let F=0;F<_i;F++)for(let te=0;te<_i;te++){const se=(F*_i+te)/(_i*_i)*.75+.55,ce=new xt().setHSL(se,.9,.6),ve=new Hv({color:ce,metalness:.4,roughness:.3,emissive:ce,emissiveIntensity:.25});L.push(ve);const N=new si(v,ve),K=(F/(_i-1)-.5)*v_,q=(te/(_i-1)-.5)*v_;N.position.set(K,-4,q),N.castShadow=!0,N.receiveShadow=!0,l.add(N),D.push(N)}let C=0,G=performance.now(),k=0,I;const H=new FS;function P(){I=requestAnimationFrame(P);const F=H.getElapsedTime();b.rotation.x=F*.38,b.rotation.y=F*.55,S.rotation.x=F*.12,S.rotation.y=F*.18,S.rotation.z=F*.09;for(let se=0;se<_i;se++)for(let ce=0;ce<_i;ce++){const ve=D[se*_i+ce],N=ve.position.x,K=ve.position.z,q=Math.sqrt(N*N+K*K);ve.position.y=-4+Math.sin(F*__-q*y_)*M1;const ge=L[se*_i+ce];ge.emissiveIntensity=.15+.35*(.5+.5*Math.sin(F*__-q*y_))}m.position.x=Math.cos(F*.7)*7,m.position.z=Math.sin(F*.7)*7,p.position.x=Math.cos(F*.5+Math.PI)*7,p.position.z=Math.sin(F*.5+Math.PI)*7,u.position.y=5+Math.sin(F*.22)*.8,u.lookAt(0,0,0),a.render(l,u),C++;const te=performance.now();te-G>=500&&(k=Math.round(C*1e3/(te-G)),C=0,G=te,t.current&&(t.current.textContent=`${k} FPS`))}P();function w(){const F=window.innerWidth,te=window.innerHeight;u.aspect=F/te,u.updateProjectionMatrix(),a.setSize(F,te)}return window.addEventListener("resize",w),cyfr.ready(),()=>{cancelAnimationFrame(I),window.removeEventListener("resize",w),a.dispose(),y.dispose(),x.dispose(),R.dispose(),A.dispose(),v.dispose(),L.forEach(F=>F.dispose()),i.contains(a.domElement)&&i.removeChild(a.domElement)}},[]),nn.jsxs("div",{style:{position:"relative",width:"100vw",height:"100vh",overflow:"hidden"},children:[nn.jsx("div",{ref:o,style:{position:"absolute",inset:0}}),nn.jsxs("div",{style:{position:"absolute",top:16,left:16,color:"rgba(200, 190, 255, 0.9)",fontFamily:"'SF Mono', 'Fira Code', 'Consolas', monospace",fontSize:13,lineHeight:1.6,pointerEvents:"none",userSelect:"none",textShadow:"0 0 12px rgba(120, 80, 255, 0.8)"},children:[nn.jsx("div",{style:{fontSize:17,fontWeight:700,letterSpacing:"0.08em",textTransform:"uppercase",color:"rgba(180, 160, 255, 1)",marginBottom:4},children:"three.js demo"}),nn.jsx("div",{style:{opacity:.75},children:"torus knot · wireframe orbiter · sphere grid"}),nn.jsx("div",{style:{marginTop:6,color:"rgba(100, 255, 180, 0.9)"},children:nn.jsx("span",{ref:t,children:"— FPS"})})]})]})}hx.createRoot(document.getElementById("root")).render(nn.jsx(mc.StrictMode,{children:nn.jsx(E1,{})}));
