# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.PersonId do
  @moduledoc """
  The shape of a person's id, and the predicate that tells one from the
  server's synthetic principals.

  A person's id is minted by this server with the `usr` prefix. The
  server's own principals — `system`, `_seed`, `webhook:<slug>`, … — are
  never people, never have a row of their own, and never wear the prefix.
  Both sides read the rule here: the identity domain mints and the row
  store refuses.
  """

  @prefix "usr"

  @doc "The prefix every person's id carries."
  @spec prefix() :: String.t()
  def prefix, do: @prefix

  @doc """
  Whether `id` is a person's, as opposed to one of the server's synthetic
  principals. A non-binary is not a person's id.
  """
  @spec person?(term()) :: boolean()
  def person?(id) when is_binary(id), do: String.starts_with?(id, @prefix <> "_")
  def person?(_), do: false
end
