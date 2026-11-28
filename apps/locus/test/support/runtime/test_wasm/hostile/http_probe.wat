;; SPDX-License-Identifier: Apache-2.0
;; Copyright 2026 CYFR Works Inc.
;;
;; A guest of WASI's own HTTP: it imports `wasi:http/outgoing-handler`'s
;; `handle` and the types of `wasi:http/types` that `handle` names, as a
;; guest built for `wasi:http` does, and would answer {"instantiated":true}.
;; It never calls `handle`: importing it is what is refused. No component
;; type is given `wasi:http` (a catalyst's requests go through
;; `cyfr:http`), so every type's instantiation refuses it, naming the
;; first import it cannot satisfy, `wasi:http/types`. It exports its one
;; function as a reagent's `compute` and a catalyst's and a formula's
;; `run`. A component text, built by `build.sh` (README.md).
(component
  (import "wasi:http/types@0.2.0" (instance $types
    (export "outgoing-request" (type (sub resource)))
    (export "request-options" (type (sub resource)))
    (export "future-incoming-response" (type (sub resource)))
    (type $dns (record (field "rcode" (option string)) (field "info-code" (option u16))))
    (export "DNS-error-payload" (type $dns-payload (eq $dns)))
    (type $tls (record (field "alert-id" (option u8)) (field "alert-message" (option string))))
    (export "TLS-alert-received-payload" (type $tls-payload (eq $tls)))
    (type $field (record (field "field-name" (option string)) (field "field-size" (option u32))))
    (export "field-size-payload" (type $field-payload (eq $field)))
    (type $error-code (variant
      (case "DNS-timeout")
      (case "DNS-error" $dns-payload)
      (case "destination-not-found")
      (case "destination-unavailable")
      (case "destination-IP-prohibited")
      (case "destination-IP-unroutable")
      (case "connection-refused")
      (case "connection-terminated")
      (case "connection-timeout")
      (case "connection-read-timeout")
      (case "connection-write-timeout")
      (case "connection-limit-reached")
      (case "TLS-protocol-error")
      (case "TLS-certificate-error")
      (case "TLS-alert-received" $tls-payload)
      (case "HTTP-request-denied")
      (case "HTTP-request-length-required")
      (case "HTTP-request-body-size" (option u64))
      (case "HTTP-request-method-invalid")
      (case "HTTP-request-URI-invalid")
      (case "HTTP-request-URI-too-long")
      (case "HTTP-request-header-section-size" (option u32))
      (case "HTTP-request-header-size" (option $field-payload))
      (case "HTTP-request-trailer-section-size" (option u32))
      (case "HTTP-request-trailer-size" $field-payload)
      (case "HTTP-response-incomplete")
      (case "HTTP-response-header-section-size" (option u32))
      (case "HTTP-response-header-size" $field-payload)
      (case "HTTP-response-body-size" (option u64))
      (case "HTTP-response-trailer-section-size" (option u32))
      (case "HTTP-response-trailer-size" $field-payload)
      (case "HTTP-response-transfer-coding" (option string))
      (case "HTTP-response-content-coding" (option string))
      (case "HTTP-response-timeout")
      (case "HTTP-upgrade-failed")
      (case "HTTP-protocol-error")
      (case "loop-detected")
      (case "configuration-error")
      (case "internal-error" (option string))))
    (export "error-code" (type (eq $error-code)))))
  (alias export $types "outgoing-request" (type $outgoing-request))
  (alias export $types "request-options" (type $request-options))
  (alias export $types "future-incoming-response" (type $future-incoming-response))
  (alias export $types "error-code" (type $error-code))
  (import "wasi:http/outgoing-handler@0.2.0" (instance $handler
    (alias outer 1 $outgoing-request (type $r))
    (export "outgoing-request" (type $request (eq $r)))
    (alias outer 1 $request-options (type $o))
    (export "request-options" (type $options (eq $o)))
    (alias outer 1 $future-incoming-response (type $f))
    (export "future-incoming-response" (type $response (eq $f)))
    (alias outer 1 $error-code (type $e))
    (export "error-code" (type $error (eq $e)))
    (export "handle"
      (func (param "request" (own $request)) (param "options" (option (own $options)))
        (result (result (own $response) (error $error)))))))

  (core module $m
    (memory (export "memory") 1)
    (data (i32.const 64) "{\22instantiated\22:true}")
    (func (export "cabi_realloc") (param i32 i32 i32 i32) (result i32) (i32.const 1024))
    (func (export "compute") (param i32 i32) (result i32)
      (i32.store (i32.const 32) (i32.const 64))
      (i32.store offset=4 (i32.const 32) (i32.const 21))
      (i32.const 32)))
  (core instance $i (instantiate $m))
  (func $compute (param "input" string) (result string)
    (canon lift (core func $i "compute")
      (memory (core memory $i "memory")) (realloc (core func $i "cabi_realloc"))))
  ;; One function under each type's export, so every type is refused it.
  (instance $compute-instance (export "compute" (func $compute)))
  (instance $run-instance (export "run" (func $compute)))
  (export "cyfr:reagent/compute@0.1.0" (instance $compute-instance))
  (export "cyfr:catalyst/run@0.1.0" (instance $run-instance))
  (export "cyfr:formula/run@0.1.0" (instance $run-instance)))
