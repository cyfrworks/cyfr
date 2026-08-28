# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Time do
  @moduledoc """
  The one spelling of "this timestamp, as ISO-8601 or nil".

  Six modules had grown private `format_datetime/1` copies that disagreed
  on nil, on `NaiveDateTime`, and on the fallback — one had no catch-all
  at all, so a shape its siblings tolerated raised there. Rendering (a
  text `"N/A"`, a display string) belongs at the call site; the
  conversion belongs here.
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

  def iso8601(value) when is_binary(value) do
    # Defensive: a datetime that arrives as an offset-less string gains a
    # "Z" so the output stays valid ISO 8601.
    if String.ends_with?(value, "Z") or Regex.match?(~r/[+-]\d{2}:\d{2}$/, value) do
      value
    else
      value <> "Z"
    end
  end
end
