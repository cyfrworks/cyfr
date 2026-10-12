;; SPDX-License-Identifier: Apache-2.0
;; Copyright 2026 CYFR Works Inc.
;;
;; A reagent that traps on one input and runs to completion on any other:
;; an input of exactly 13 bytes, `{"trap":true}`, reaches an `unreachable`
;; instruction; any other input is answered `{"ran":true}`. One instance
;; can be called with both, so the call after a trap shows whether the
;; instance still serves. Built by `build.sh` (README.md).
(module
  (memory $io (export "memory") 1)
  (data (i32.const 256) "{\22ran\22:true}")
  (global $heap (mut i32) (i32.const 1024))
  (func (export "cabi_realloc") (param $old i32) (param $old_size i32) (param $align i32) (param $new_size i32) (result i32)
    (local $ptr i32)
    (local.set $ptr (global.get $heap))
    (global.set $heap (i32.add (global.get $heap) (i32.add (local.get $new_size) (i32.const 8))))
    (local.get $ptr))
  (func (export "cyfr:reagent/compute@0.1.0#compute") (param $ptr i32) (param $len i32) (result i32)
    (if (i32.eq (local.get $len) (i32.const 13))
      (then (unreachable)))
    (i32.store (i32.const 8) (i32.const 256))
    (i32.store (i32.const 12) (i32.const 12))
    (i32.const 8)))
