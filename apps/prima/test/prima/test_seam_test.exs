# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.TestSeamTest do
  # The gate's decision, and the build's own answer: a build without the
  # test permission answers the shipped default and never runs the read.
  use ExUnit.Case, async: true

  require Prima.TestSeam

  @permitted Application.compile_env(:prima, :test_seams_permitted, false)

  test "a build without the permission answers the default and never reads" do
    read = fn -> flunk("a build without the test permission ran the read") end
    assert Prima.TestSeam.value(false, :shipped, read) == :shipped
  end

  test "a build with the permission answers the read" do
    assert Prima.TestSeam.value(true, :shipped, fn -> :set_at_start_up end) == :set_at_start_up
  end

  test "value/2 decides with the permission this build was compiled with" do
    expected = if @permitted, do: :read, else: :shipped
    assert Prima.TestSeam.value(:shipped, fn -> :read end) == expected
  end
end
