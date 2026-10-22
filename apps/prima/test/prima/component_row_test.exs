# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.ComponentRowTest do
  use ExUnit.Case, async: true

  alias Prima.ComponentRow

  doctest Prima.ComponentRow

  test "a row is read by its atom keys alone" do
    row = %{component_type: "catalyst", publisher: nil, name: "files"}
    assert ComponentRow.node_key(row) == "catalyst:local.files"

    decoded = %{"component_type" => "catalyst", "publisher" => nil, "name" => "files"}
    refute ComponentRow.node_key(decoded) == "catalyst:local.files"
  end

  test "the semver-latest row wins, inserted_at breaking a tie" do
    early = ~U[2026-10-01 00:00:00Z]
    late = ~U[2026-10-02 00:00:00Z]

    rows = [
      %{version: "1.2.0", inserted_at: early},
      %{version: "1.10.0", inserted_at: early},
      %{version: "1.10.0", inserted_at: late, tag: :latest}
    ]

    assert %{version: "1.10.0", tag: :latest} = ComponentRow.latest_of(rows)
    assert ComponentRow.latest_of([]) == nil
  end
end
