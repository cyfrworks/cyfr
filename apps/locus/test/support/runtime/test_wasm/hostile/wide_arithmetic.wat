;; SPDX-License-Identifier: Apache-2.0
;; Copyright 2026 CYFR Works Inc.
;;
;; A reagent that adds two 128-bit integers with wide arithmetic's
;; `i64.add128`, (2^64 - 1) + 1 = 2^64, and answers {"carried":true} when
;; the sum's high half is 1 and its low half 0, and traps otherwise. Wide
;; arithmetic is admitted (`Prima.ComponentFeatures`), so this guest runs.
;; A component text, built by `build.sh` (README.md).
(component
  (core module $m
    (memory (export "memory") 1)
    (data (i32.const 64) "{\"carried\":true}")
    (func (export "cabi_realloc") (param i32 i32 i32 i32) (result i32) (i32.const 1024))
    (func (export "compute") (param i32 i32) (result i32)
      (local $low i64)
      (local $high i64)
      (i64.add128 (i64.const -1) (i64.const 0) (i64.const 1) (i64.const 0))
      (local.set $high)
      (local.set $low)
      (if (i32.or (i64.ne (local.get $low) (i64.const 0)) (i64.ne (local.get $high) (i64.const 1)))
        (then (unreachable)))
      (i32.store (i32.const 32) (i32.const 64))
      (i32.store offset=4 (i32.const 32) (i32.const 16))
      (i32.const 32)))
  (core instance $i (instantiate $m))
  (func $compute (param "input" string) (result string)
    (canon lift (core func $i "compute")
      (memory (core memory $i "memory")) (realloc (core func $i "cabi_realloc"))))
  (instance $compute-instance (export "compute" (func $compute)))
  (export "cyfr:reagent/compute@0.1.0" (instance $compute-instance)))
