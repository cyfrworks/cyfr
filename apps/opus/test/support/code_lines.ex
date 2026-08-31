# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

# Canonical copy lives in apps/cyfr/test/support/code_lines.ex
# This file loads it so per-app `mix test` in opus still works.
canonical = Path.expand("../../../cyfr/test/support/code_lines.ex", __DIR__)

unless Code.ensure_loaded?(Cyfr.Test.CodeLines) do
  Code.require_file(canonical)
end
