# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.RosterTest do
  use ExUnit.Case, async: true

  alias Aqua.Roster

  test "a mention picks the longest matching name and strips it" do
    roster = [%{"name" => "aqua"}, %{"name" => "aqua-fast"}, %{"name" => "web"}]

    assert {"read this", %{"name" => "aqua-fast"}} =
             Roster.parse_mention("@aqua-fast read this", roster)

    assert {"@web hi", nil} = Roster.parse_mention("@web hi", [])
    assert {"@aqua", %{"name" => "aqua"}} = Roster.parse_mention("@aqua", roster)
    assert {"mail me@web.example", nil} = Roster.parse_mention("mail me@web.example", roster)
  end
end
