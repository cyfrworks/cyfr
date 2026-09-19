# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.HostAPITest do
  @moduledoc """
  A field name a `secret_denied` `record_denial` carries is the guest's, so
  the contract bounds it: 1 to 256 bytes of UTF-8 without a control
  character, which the runner reports and CYFR records, and nothing else.
  """

  use ExUnit.Case, async: true

  alias Cyfr.HostAPI

  test "a field name is 1 to 256 bytes of UTF-8 without a control character" do
    for name <- ["K", "PROBE_KEY", "api key", "clé-ünïcode", String.duplicate("N", 256)] do
      assert HostAPI.valid_field_name?(name), inspect(name)
    end

    for name <-
          [
            "",
            String.duplicate("N", 257),
            "PROBE\nKEY",
            "tab\tbed",
            "nul\0byte",
            "del\x7Fbyte",
            "esc\e[31m",
            <<0xFF, 0xFE>>,
            :PROBE_KEY,
            nil,
            42
          ] do
      refute HostAPI.valid_field_name?(name), inspect(name)
    end
  end

  test "a multi-byte name is bounded by its bytes, not its characters" do
    assert HostAPI.valid_field_name?(String.duplicate("é", 128))
    refute HostAPI.valid_field_name?(String.duplicate("é", 129))
  end

  test "a denial reported to CYFR is never retried: its effect may have happened" do
    assert HostAPI.retry(:record_denial) == :never
  end
end
