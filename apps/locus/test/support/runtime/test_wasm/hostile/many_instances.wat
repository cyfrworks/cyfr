;; SPDX-License-Identifier: Apache-2.0
;; Copyright 2026 CYFR Works Inc.
;;
;; A reagent of eleven core instances, one past the ten a run's store
;; holds (`apps/locus/runner`, `imports::MAX_INSTANCES`): its own and ten
;; of a module that defines nothing. The store counts each instance as it
;; is made and refuses the first past its bound, so the refusal names the
;; count it reached, 11: the ten before it were held. Were it run, it
;; would answer {"ran":true}. A component text, built by `build.sh`
;; (README.md).
(component
  (core module $m
    (memory (export "memory") 1)
    (data (i32.const 64) "{\22ran\22:true}")
    (func (export "cabi_realloc") (param i32 i32 i32 i32) (result i32) (i32.const 1024))
    (func (export "compute") (param i32 i32) (result i32)
      (i32.store (i32.const 32) (i32.const 64))
      (i32.store offset=4 (i32.const 32) (i32.const 12))
      (i32.const 32)))
  (core module $empty)
  (core instance $i (instantiate $m))
  (core instance (instantiate $empty))
  (core instance (instantiate $empty))
  (core instance (instantiate $empty))
  (core instance (instantiate $empty))
  (core instance (instantiate $empty))
  (core instance (instantiate $empty))
  (core instance (instantiate $empty))
  (core instance (instantiate $empty))
  (core instance (instantiate $empty))
  (core instance (instantiate $empty))
  (func $compute (param "input" string) (result string)
    (canon lift (core func $i "compute")
      (memory (core memory $i "memory")) (realloc (core func $i "cabi_realloc"))))
  (instance $compute-instance (export "compute" (func $compute)))
  (export "cyfr:reagent/compute@0.1.0" (instance $compute-instance)))
