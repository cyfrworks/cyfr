# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.CrewBoundTest do
  @moduledoc """
  A job's bound on its scrolls, reckoned on what the member reads
  (`Aqua.Crew.within_bound/2`): every frame, delimiter and separator
  counts, so scrolls whose names and bodies fit the bound can still not.
  """

  use ExUnit.Case, async: true

  @bound 131_072

  # Many small scrolls whose names and bodies fit the bound, each in its
  # frame, delimiters and separators with it, do not, and the job is
  # refused in the sentence that names the bound; a hundred of them fit.
  test "many small scrolls that fit as parts and not as framed are refused for one job" do
    scrolls =
      for n <- 1..1_400,
          do: %{"name" => "s" <> String.pad_leading("#{n}", 4, "0"), "body" => "b", "files" => []}

    framed = scrolls |> Aqua.Reader.scrolls(Aqua.Reader.token()) |> byte_size()

    assert Enum.sum(for s <- scrolls, do: byte_size(s["name"]) + byte_size(s["body"])) < @bound
    assert framed > @bound

    assert {:error, {:invalid_argument, refusal}} = Aqua.Crew.within_bound(scrolls, "crew.ask")

    assert refusal ==
             "crew.ask: the scrolls named come to #{framed} bytes as the member reads them, " <>
               "more than the 131072 one job carries"

    assert :ok = Aqua.Crew.within_bound(Enum.take(scrolls, 100), "crew.ask")
  end
end
