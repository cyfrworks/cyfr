;; SPDX-License-Identifier: Apache-2.0
;; Copyright 2026 CYFR Works Inc.
;;
;; A reagent whose core module allocates a GC struct: valid WebAssembly
;; with every feature on, refused for the GC feature alone
;; (`Prima.ComponentFeatures`). A component text, built by `build.sh`
;; (README.md).
(component
  (core module $m
    (type $pair (struct (field i32) (field i32)))
    (memory (export "memory") 1)
    (func (export "cabi_realloc") (param i32 i32 i32 i32) (result i32) (i32.const 1024))
    (func (export "compute") (param i32 i32) (result i32)
      (drop (struct.new $pair (i32.const 1) (i32.const 2)))
      (i32.const 0)))
  (core instance $i (instantiate $m))
  (func $compute (param "input" string) (result string)
    (canon lift (core func $i "compute")
      (memory (core memory $i "memory")) (realloc (core func $i "cabi_realloc"))))
  (instance $compute-instance (export "compute" (func $compute)))
  (export "cyfr:reagent/compute@0.1.0" (instance $compute-instance)))
