// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The canvas proof's frame_kept step (tests/canvas-proof/proof.mjs), run
// against a stand-in page: it holds only when every placement asked for
// happens and the window's iframe stays the same element with no new load.

import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';
import {test} from 'node:test';

const text = readFileSync(new URL('../../../../../tests/canvas-proof/proof.mjs', import.meta.url),'utf8');
const from = text.indexOf('async function stepFrameKept(');
const until = text.indexOf('\n// Switch to `id`',from);
assert(from >= 0 && until > from);
const source = text.slice(from,until);

async function run(mode) {
  const frame = 'frm_review00001';
  let place = 'window';
  let iframe = {};
  let loads = 1;
  let result;
  const wrapper = {getAttribute(name){return name === 'data-canvas-frame' ? frame : place;}};
  const page = {
    async waitForSelector(){},
    async waitForTimeout(){},
    async $eval(selector,fn,arg){return fn(selector.startsWith('iframe') ? iframe : wrapper,arg);},
    async click(selector){
      if(selector.includes('action="tile"')) {
        place='tile';
        if(mode==='replace') iframe={};
      }
      if(selector.includes('action="full"')) {
        if(mode!=='ignore-full') place='full';
        if(mode==='reload') loads++;
      }
    },
    keyboard:{async press(){place='window';}}
  };
  const context = {
    showCanvas:async()=>{},
    lib:{waitFor:async(fn)=>{const value=await fn();if(value)return value;throw new Error('condition never became true');}},
    instrument:async()=>({loads:{[frame]:loads}}),
    note:(_step,_name,held,observation)=>{result={held,observation};},
    layoutRead:async()=>({apps:[{tincture:'tincture:local.canvas-full',placement:place}]}),
    layout:()=>({}),
    publish:async()=>{}
  };
  vm.createContext(context);
  vm.runInContext(source+'\nglobalThis.runStep=stepFrameKept;',context);
  await context.runStep(page,'chromium',{posture:'desk'});
  return result;
}

test('normal transitions retain the marked frame',async()=>{assert.equal((await run('normal')).held,true);});
test('replacement fails the identity check',async()=>{assert.equal((await run('replace')).held,false);});
test('an extra load fails the reload check',async()=>{assert.equal((await run('reload')).held,false);});
test('the proof must fail if making full never happens',async()=>{
  const result=await run('ignore-full');
  assert.equal(result.observation.after.find(x=>x.gesture==='full').place,'tile');
  assert.equal(result.held,false,'frame_kept reported success although the full transition never occurred');
});
