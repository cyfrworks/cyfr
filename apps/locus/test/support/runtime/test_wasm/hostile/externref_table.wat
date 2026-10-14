;; SPDX-License-Identifier: Apache-2.0
;; Copyright 2026 CYFR Works Inc.
;;
;; A reagent whose core module declares a table of `externref`, which no
;; GC instruction touches: the engine gives a module declaring one a GC
;; heap at instantiation, so it is refused for GC's reference types alone
;; (`Prima.ComponentFeatures`). A component text, built by `build.sh`
;; (README.md).
(component
  (core module $m
    (table $refs 1 externref)
    (memory (export "memory") 1)
    (func (export "cabi_realloc") (param i32 i32 i32 i32) (result i32) (i32.const 1024))
    (func (export "compute") (param i32 i32) (result i32)
      (drop (table.get $refs (i32.const 0)))
      (i32.const 0)))
  (core instance $i (instantiate $m))
  (func $compute (param "input" string) (result string)
    (canon lift (core func $i "compute")
      (memory (core memory $i "memory")) (realloc (core func $i "cabi_realloc"))))
  (instance $compute-instance (export "compute" (func $compute)))
  (export "cyfr:reagent/compute@0.1.0" (instance $compute-instance)))
