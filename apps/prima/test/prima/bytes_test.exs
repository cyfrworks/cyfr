# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.BytesTest do
  use ExUnit.Case, async: true

  test "a count is written in the largest unit it reaches, to one decimal" do
    assert Prima.Bytes.format(0) == "0 B"
    assert Prima.Bytes.format(1023) == "1023 B"
    assert Prima.Bytes.format(1024) == "1.0 KB"
    assert Prima.Bytes.format(384 * 1024 * 1024) == "384.0 MB"
    assert Prima.Bytes.format(3 * 512 * 1024 * 1024) == "1.5 GB"
  end
end
