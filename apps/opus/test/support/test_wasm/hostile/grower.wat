;; SPDX-License-Identifier: Apache-2.0
;; Copyright 2026 CYFR Works Inc.
;;
;; A reagent that takes all the linear memory and table the engine lets it
;; have: it grows its one memory a page (64 KiB) at a time, and its table
;; an element at a time, each until the engine answers -1, and answers
;; `{"pages": P, "table": T}`, the size of each once the engine refused it.
;; A run's store bounds its memory at the node's consented
;; `max_memory_bytes` and each table at 20,000 elements
;; (`Opus.Runtime.store_limits/1`), so P is that bound in pages and T is
;; 20,000: growth past either is refused by the engine, and the run goes
;; on. Built by `build.sh` (README.md).
(module
  (memory $io (export "memory") 1)
  (table $t 1 funcref)
  (data (i32.const 256) "{\22pages\22:")
  (data (i32.const 272) ",\22table\22:")
  (global $heap (mut i32) (i32.const 1024))
  (func (export "cabi_realloc") (param $old i32) (param $old_size i32) (param $align i32) (param $new_size i32) (result i32)
    (local $ptr i32)
    (local.set $ptr (global.get $heap))
    (global.set $heap (i32.add (global.get $heap) (i32.add (local.get $new_size) (i32.const 8))))
    (local.get $ptr))
  ;; Write `n` in decimal at `at`, answering the position after it.
  (func $decimal (param $n i32) (param $at i32) (result i32)
    (local $digits i32)
    (local $rest i32)
    (local $i i32)
    (local.set $digits (i32.const 1))
    (local.set $rest (local.get $n))
    (block $counted
      (loop $count
        (br_if $counted (i32.lt_u (local.get $rest) (i32.const 10)))
        (local.set $rest (i32.div_u (local.get $rest) (i32.const 10)))
        (local.set $digits (i32.add (local.get $digits) (i32.const 1)))
        (br $count)))
    (local.set $i (i32.add (local.get $at) (local.get $digits)))
    (local.set $rest (local.get $n))
    (loop $write
      (local.set $i (i32.sub (local.get $i) (i32.const 1)))
      (i32.store8 (local.get $i)
        (i32.add (i32.const 48) (i32.rem_u (local.get $rest) (i32.const 10))))
      (local.set $rest (i32.div_u (local.get $rest) (i32.const 10)))
      (br_if $write (i32.gt_u (local.get $i) (local.get $at))))
    (i32.add (local.get $at) (local.get $digits)))
  (func (export "cyfr:reagent/compute@0.1.0#compute") (param $ptr i32) (param $len i32) (result i32)
    (local $at i32)
    (block $memory_refused
      (loop $grow_memory
        (br_if $memory_refused (i32.eq (memory.grow (i32.const 1)) (i32.const -1)))
        (br $grow_memory)))
    (block $table_refused
      (loop $grow_table
        (br_if $table_refused
          (i32.eq (table.grow $t (ref.null func) (i32.const 1)) (i32.const -1)))
        (br $grow_table)))
    ;; The answer, at 512: {"pages":P,"table":T}
    (memory.copy (i32.const 512) (i32.const 256) (i32.const 9))
    (local.set $at (call $decimal (memory.size) (i32.const 521)))
    (memory.copy (local.get $at) (i32.const 272) (i32.const 9))
    (local.set $at (call $decimal (table.size $t) (i32.add (local.get $at) (i32.const 9))))
    (i32.store8 (local.get $at) (i32.const 125))
    (i32.store (i32.const 8) (i32.const 512))
    (i32.store (i32.const 12) (i32.sub (i32.add (local.get $at) (i32.const 1)) (i32.const 512)))
    (i32.const 8)))
