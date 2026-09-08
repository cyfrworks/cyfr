# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.ConsentDriftTest do
  use ExUnit.Case, async: true

  alias Cyfr.ConsentDrift

  test "the actions the consent lacks are named in the manifest's order" do
    declared = ~w(aqua.get notes.keep notes.list schedule.list)
    assert ConsentDrift.missing(declared, ~w(aqua.get schedule.list)) == ~w(notes.keep notes.list)
    assert ConsentDrift.missing(declared, declared) == []
    assert ConsentDrift.missing([], ~w(aqua.get)) == []
  end
end
