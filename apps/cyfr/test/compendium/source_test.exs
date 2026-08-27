# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.SourceTest do
  @moduledoc """
  The source column's closed vocabulary: three ingress channels, one
  remote? predicate, one roster the row builder enforces.
  """

  use ExUnit.Case, async: true

  doctest Compendium.Source

  alias Compendium.Source

  test "the roster is closed and the predicate splits it" do
    assert Source.values() == [Source.filesystem(), Source.published(), Source.oci()]

    assert Source.remote?(Source.oci())
    assert Source.remote?(Source.published())
    refute Source.remote?(Source.filesystem())
    refute Source.remote?(nil)
    refute Source.remote?("made-up")
  end
end
