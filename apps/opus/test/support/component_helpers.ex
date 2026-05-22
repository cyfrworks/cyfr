# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

# Canonical copy lives in apps/cyfr/test/support/component_helpers.ex
# This file loads it so per-app `mix test` in opus still works.
sanctum_path = Path.expand("../../../cyfr/test/support/component_helpers.ex", __DIR__)

unless Code.ensure_loaded?(Sanctum.Test.ComponentHelpers) do
  Code.require_file(sanctum_path)
end