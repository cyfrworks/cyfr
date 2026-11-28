;; SPDX-License-Identifier: Apache-2.0
;; Copyright 2026 CYFR Works Inc.
;;
;; A reagent that answers its input unchanged, beside a second, shared
;; memory of the threads proposal it never touches: no atomic
;; instruction, the declaration alone. Threads is refused
;; (`Prima.ComponentFeatures`), so this guest is refused at admission and
;; its compile is refused by the runner's engine. A component text,
;; built by `build.sh` (README.md).
(component
  (core module $m
    (memory (export "memory") 1)
    (memory $shared 1 1 shared)
    (func (export "cabi_realloc") (param i32 i32 i32 i32) (result i32) (i32.const 1024))
    (func (export "compute") (param $ptr i32) (param $len i32) (result i32)
      (i32.store (i32.const 32) (local.get $ptr))
      (i32.store offset=4 (i32.const 32) (local.get $len))
      (i32.const 32)))
  (core instance $i (instantiate $m))
  (func $compute (param "input" string) (result string)
    (canon lift (core func $i "compute")
      (memory (core memory $i "memory")) (realloc (core func $i "cabi_realloc"))))
  (instance $compute-instance (export "compute" (func $compute)))
  (export "cyfr:reagent/compute@0.1.0" (instance $compute-instance)))
