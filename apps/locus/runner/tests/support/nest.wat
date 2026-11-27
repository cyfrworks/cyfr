;; SPDX-License-Identifier: Apache-2.0
;; Copyright 2026 CYFR Works Inc.
;;
;; A reagent whose `compute` answers its input's length in nested arrays:
;; for an input of N bytes, N `[` and then N `]`, a JSON value nested N
;; deep. It lets a test hand the engine a guest output at exactly the depth
;; a document is read to, and one level past it. A component text, built
;; with the wasm-tools scripts/wasm-tools.sh pins:
;;   wasm-tools parse nest.wat -o nest.wasm
(component
  (core module $m
    (memory (export "memory") 1)
    (global $heap (mut i32) (i32.const 1024))
    (func (export "cabi_realloc") (param i32 i32 i32 i32) (result i32)
      (local $at i32)
      (local.set $at (global.get $heap))
      (global.set $heap (i32.add (global.get $heap) (local.get 3)))
      (local.get $at))
    ;; The output is written at 32768, and its pointer and length at 16.
    (func (export "compute") (param $input i32) (param $length i32) (result i32)
      (local $i i32)
      (block $opened
        (loop $open
          (br_if $opened (i32.ge_u (local.get $i) (local.get $length)))
          (i32.store8 (i32.add (i32.const 32768) (local.get $i)) (i32.const 91))
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br $open)))
      (local.set $i (i32.const 0))
      (block $closed
        (loop $close
          (br_if $closed (i32.ge_u (local.get $i) (local.get $length)))
          (i32.store8
            (i32.add (i32.add (i32.const 32768) (local.get $length)) (local.get $i))
            (i32.const 93))
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br $close)))
      (i32.store (i32.const 16) (i32.const 32768))
      (i32.store (i32.const 20) (i32.shl (local.get $length) (i32.const 1)))
      (i32.const 16)))
  (core instance $i (instantiate $m))
  (func $compute (param "input" string) (result string)
    (canon lift (core func $i "compute")
      (memory (core memory $i "memory")) (realloc (core func $i "cabi_realloc"))))
  (instance $compute-instance (export "compute" (func $compute)))
  (export "cyfr:reagent/compute@0.1.0" (instance $compute-instance)))
