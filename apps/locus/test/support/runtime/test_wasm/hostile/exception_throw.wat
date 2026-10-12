;; SPDX-License-Identifier: Apache-2.0
;; Copyright 2026 CYFR Works Inc.
;;
;; A reagent whose core module throws a tag and catches it with
;; `try_table`: valid WebAssembly with every feature on, refused for the
;; exception-handling feature alone (`Prima.ComponentFeatures`). A
;; component text, built by `build.sh` (README.md).
(component
  (core module $m
    (tag $raised)
    (memory (export "memory") 1)
    (func (export "cabi_realloc") (param i32 i32 i32 i32) (result i32) (i32.const 1024))
    (func (export "compute") (param i32 i32) (result i32)
      (block $caught
        (try_table (catch $raised $caught)
          (throw $raised)))
      (i32.const 0)))
  (core instance $i (instantiate $m))
  (func $compute (param "input" string) (result string)
    (canon lift (core func $i "compute")
      (memory $i "memory") (realloc (func $i "cabi_realloc"))))
  (instance $compute-instance (export "compute" (func $compute)))
  (export "cyfr:reagent/compute@0.1.0" (instance $compute-instance)))
