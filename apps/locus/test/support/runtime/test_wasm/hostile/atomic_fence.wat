;; SPDX-License-Identifier: Apache-2.0
;; Copyright 2026 CYFR Works Inc.
;;
;; `wide_arithmetic` with one `atomic.fence` before its sum: an atomic
;; instruction of the threads proposal, beside no shared memory. Threads
;; is refused (`Prima.ComponentFeatures`), so this guest is refused at
;; admission and its compile is refused by the runner's engine. A
;; component text, built by `build.sh` (README.md).
(component
  (core module $m
    (memory (export "memory") 1)
    (data (i32.const 64) "{\"carried\":true}")
    (func (export "cabi_realloc") (param i32 i32 i32 i32) (result i32) (i32.const 1024))
    (func (export "compute") (param i32 i32) (result i32)
      (local $low i64)
      (local $high i64)
      (atomic.fence)
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
