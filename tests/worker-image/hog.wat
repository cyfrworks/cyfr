;; SPDX-License-Identifier: Apache-2.0
;; Copyright 2026 CYFR Works Inc.
;;
;; A catalyst each of whose runs holds all the linear memory the engine
;; lets one run have, and keeps it: a formula's child in memory.py's bound
;; case, where several of them in one runner hold together more than the
;; runner's memory bound, each within its own.
;;
;; The engine gives a run one linear memory of at most the node's
;; consented `max_memory_bytes` (`Opus.Runtime.store_limits/1`), 64 MiB
;; under the zero authority a child of the scripted control plane runs
;; under. `run`, in order:
;;
;;   1. emits `{"type":"hog.ready"}` (`cyfr:emit/events`, a `push_deltas`
;;      host call), which the control plane holds until the test lets this
;;      child take its memory;
;;   2. proves the engine's bound is what it assumes: growing its memory
;;      past 64 MiB must be refused (-1), and growing it to exactly 64 MiB
;;      must not be, or it traps;
;;   3. writes one byte to every 4 KiB page of the 64 MiB, so the runner
;;      holds all of it resident;
;;   4. emits `{"type":"hog.holding","bytes":67108864}`, which the control
;;      plane never answers, so the child keeps its memory until its runner
;;      ends;
;;   5. would answer `{"status":200,"data":{"held":67108864}}`.
;;
;; The canonical ABI of `emit: func(json-event: string) -> string` lowers
;; to (event pointer, event length, return pointer): the host writes the
;; answer string's pointer and length at the return pointer, allocating it
;; through `cabi_realloc`. `run` is lowered as vault_probe.wat's under
;; apps/opus/test/support/test_wasm/hostile. Built by build.sh, which
;; memory.py's digests hold it to.
(module
  (import "cyfr:emit/events@0.1.0" "emit" (func $emit (param i32 i32 i32)))
  (memory $io (export "memory") 1)
  (data (i32.const 256) "{\22type\22:\22hog.ready\22}")
  (data (i32.const 320) "{\22type\22:\22hog.holding\22,\22bytes\22:67108864}")
  (data (i32.const 384) "{\22status\22:200,\22data\22:{\22held\22:67108864}}")
  (global $heap (mut i32) (i32.const 1024))
  (func (export "cabi_realloc") (param $old i32) (param $old_size i32) (param $align i32) (param $new_size i32) (result i32)
    (local $ptr i32)
    (local.set $ptr (global.get $heap))
    (global.set $heap (i32.add (global.get $heap) (i32.add (local.get $new_size) (i32.const 8))))
    (local.get $ptr))
  (func (export "cyfr:catalyst/run@0.1.0#run") (param $ptr i32) (param $len i32) (result i32)
    (local $at i32)
    (call $emit (i32.const 256) (i32.const 20) (i32.const 64))
    ;; Past 64 MiB the engine refuses the growth (-1); if it did not, its
    ;; bound is not what this guest assumes, and the guest traps.
    (if (i32.ne (memory.grow (i32.const 1024)) (i32.const -1))
      (then (unreachable)))
    (if (i32.eq (memory.grow (i32.const 1023)) (i32.const -1))
      (then (unreachable)))
    ;; Page starts only: the strings above and the heap below 4 KiB are
    ;; never written over.
    (loop $page
      (i32.store8 (local.get $at) (i32.const 1))
      (local.set $at (i32.add (local.get $at) (i32.const 4096)))
      (br_if $page (i32.lt_u (local.get $at) (i32.const 67108864))))
    (call $emit (i32.const 320) (i32.const 39) (i32.const 64))
    (i32.store (i32.const 8) (i32.const 384))
    (i32.store (i32.const 12) (i32.const 39))
    (i32.const 8)))
