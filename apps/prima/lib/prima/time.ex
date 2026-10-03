# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.Time do
  @moduledoc """
  The one spelling of "this timestamp, as ISO-8601 or nil".

  Converts supported date/time values to a shared representation.
  Callers choose display text and fallback rendering.
  """

  @doc """
  ISO-8601 for a `DateTime` or `NaiveDateTime` (rendered as UTC, `Z`
  appended — the schema stores UTC on both adapters); `nil` for nil; an
  already-formatted string passes through.
  """
  @spec iso8601(DateTime.t() | NaiveDateTime.t() | String.t() | nil) :: String.t() | nil
  def iso8601(nil), do: nil
  def iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  def iso8601(%NaiveDateTime{} = ndt),
    do: ndt |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()

  # A full date-and-time with no offset — the one shape the "Z" belongs on.
  # Appending it to whatever arrived instead turned a bare date into the
  # invalid "2026-01-01Z" and any non-timestamp string into nonsense; the
  # branch exists to REPAIR an offset-less datetime, not to decorate.
  @offsetless_datetime ~r/^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(\.\d+)?$/

  def iso8601(value) when is_binary(value) do
    if Regex.match?(@offsetless_datetime, value), do: value <> "Z", else: value
  end
end
