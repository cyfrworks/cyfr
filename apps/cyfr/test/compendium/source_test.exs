# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.SourceTest do
  @moduledoc """
  The source column's closed vocabulary: two ingress channels, one
  remote? predicate, one roster the row builder enforces.
  """

  use ExUnit.Case, async: true

  doctest Compendium.Source

  alias Compendium.Source

  test "the roster is the scanner's and the pull's" do
    assert Prima.ComponentSource.values() == ["filesystem", "oci"]
  end

  test "the predicate splits the roster" do
    assert Source.remote?(Source.oci())
    refute Source.remote?(Source.filesystem())
    refute Source.remote?("published")
    refute Source.remote?(nil)
    refute Source.remote?("made-up")
  end
end
