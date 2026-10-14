;; SPDX-License-Identifier: Apache-2.0
;; Copyright 2026 CYFR Works Inc.
;;
;; A reagent whose `compute` is lifted async with a callback: the
;; construct GHSA-32h6-97mm-8q3c turns on, a callback whose result count
;; the engine trusts. Its callback has the right type (three i32s to one
;; i32), so it is valid WebAssembly with every feature on and is refused
;; for the component-model async feature alone (`Prima.ComponentFeatures`).
;; A component text, built by `build.sh` (README.md).
(component
  (core module $m
    (memory (export "memory") 1)
    (func (export "cabi_realloc") (param i32 i32 i32 i32) (result i32) (i32.const 1024))
    (func (export "compute") (param i32 i32) (result i32) (i32.const 0))
    (func (export "callback") (param i32 i32 i32) (result i32) (i32.const 0)))
  (core instance $i (instantiate $m))
  (func $compute async (param "input" string) (result string)
    (canon lift (core func $i "compute") async
      (callback (core func $i "callback"))
      (memory (core memory $i "memory")) (realloc (core func $i "cabi_realloc"))))
  (instance $compute-instance (export "compute" (func $compute)))
  (export "cyfr:reagent/compute@0.1.0" (instance $compute-instance)))
