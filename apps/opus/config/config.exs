# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

# The configuration a standalone Opus build and test run boot with (`cd
# apps/opus`): a worker service reaching a host API on this machine.
# Umbrella builds supply the root application's config, and the `opus`
# release reads its `OPUS_*` environment through `config/runtime.exs`.
import Config

config :opus,
  service_id: "wrk_local",
  # A development key. CYFR derives a service's key from its worker root
  # (`mix cyfr.opus.key <service_id>`); a deployment configures that one.
  service_key: "0000000000000000000000000000000000000000000000000000000000000000",
  host_url: "http://127.0.0.1:4300",
  bind: "127.0.0.1",
  port: 4200

# A test binds no fixed port: each listener a test needs is started on
# port 0 and asked which it was given.
if config_env() == :test, do: config(:opus, port: 0)
