# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.BuildRecords do
  @moduledoc """
  The build-record vocabulary: flat `builds/{id}.json` status files under
  the athanor's data tree. `Locus.MCP` writes them and `Cyfr.Retention`
  prunes them — two apps, one owner of the shape both rely on.
  """

  @prefix ["builds"]

  @doc "The build-records directory segments."
  @spec prefix() :: [String.t()]
  def prefix, do: @prefix

  @doc "The segments of one build's record file."
  @spec path(String.t()) :: [String.t()]
  def path(build_id) when is_binary(build_id), do: @prefix ++ [build_id <> ".json"]
end
