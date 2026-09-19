;; SPDX-License-Identifier: Apache-2.0
;; Copyright 2026 CYFR Works Inc.
;;
;; A reagent that declares a second linear memory beside the one the
;; canonical ABI uses, and would write to it and answer its input unchanged.
;; A run's store holds one linear memory (`Opus.Runtime.store_limits/1`),
;; so the engine refuses to instantiate it and the run ends as a
;; `resource_limit`; nothing of it runs. Built by `build.sh` (README.md).
(module
  (memory $io (export "memory") 1)
  (memory $second 1)
  (global $heap (mut i32) (i32.const 1024))
  (func (export "cabi_realloc") (param $old i32) (param $old_size i32) (param $align i32) (param $new_size i32) (result i32)
    (local $ptr i32)
    (local.set $ptr (global.get $heap))
    (global.set $heap (i32.add (global.get $heap) (i32.add (local.get $new_size) (i32.const 8))))
    (local.get $ptr))
  (func (export "cyfr:reagent/compute@0.1.0#compute") (param $ptr i32) (param $len i32) (result i32)
    (i32.store8 $second (i32.const 0) (i32.const 1))
    (i32.store (i32.const 8) (local.get $ptr))
    (i32.store (i32.const 12) (local.get $len))
    (i32.const 8)))
