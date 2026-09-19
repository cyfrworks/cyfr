# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Test.SourceTree do
  @moduledoc """
  How Locus's architecture tests find the files they scan: a glob that
  matches nothing raises, so a scan pointed at a moved or misspelled tree
  cannot pass by reading nothing.
  """

  @doc "`Path.wildcard/1`, refusing an empty match."
  @spec files!(String.t()) :: [String.t()]
  def files!(glob) do
    case Path.wildcard(glob) do
      [] -> raise "no file matches #{glob}"
      paths -> paths
    end
  end
end
