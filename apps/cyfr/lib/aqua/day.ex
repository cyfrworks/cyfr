# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Day do
  @moduledoc """
  The person's day, and the daily thread that holds it.

  The day is the person's own: the date now in their time zone, which the
  browser reports when the shell connects and the shell stores as
  `time_zone` in their preferences, with their language, when either
  differs from what is stored (`Aqua.Reading`, `PrismWeb.ShellLive`). `UTC`
  until one arrives, and for a stored zone the zone database does not
  know. `today/1` reads that preference for the day, and `stored_zone/1`
  for Aqua's browser, which reads pages in it
  (`Aqua.BrowserSetting.start/1`).

  The current daily thread is the one whose `day` is that date, made if
  none exists (`Arca.ThreadStorage.daily/2`); nothing else about the day is
  stored. A message joins the current daily thread when it is accepted,
  and a delivery (a schedule's fire) the one current when it is delivered,
  so a changed zone takes effect at the next of either, never before and
  never later: that one joins the daily thread of the date in the new
  zone, made or used again. No daily thread is renamed, moved or merged,
  and a turn that crosses midnight ends on the daily thread it began on.

  ## The zone database

  Elixir knows UTC alone, and a zone's date cannot be read without its
  rules, which change with the clocks; a schedule fires while no browser is
  open. So the day is read with the `tz` package's database (Apache-2.0),
  handed to the calendar call as its argument. This module and the one
  definition of a zone (`Opus.Browser.zone?/1`) are its users: the node's
  own `:time_zone_database` is not set, so nothing else in CYFR reads
  zones by accident. Its data is what the package compiled in; none of its
  updaters is started, so nothing fetches zone data at run time. A zone it
  does not know is refused where the shell writes it (`Aqua.Reading`), and
  one stored that it cannot resolve reads as UTC.
  """

  alias Sanctum.Context
  alias Sanctum.Tenancy.Users

  @utc "UTC"

  @doc "The zone a person with no stored one, or an unknown one, has: `UTC`."
  @spec default_zone() :: String.t()
  def default_zone, do: @utc

  @doc """
  Whether `zone` is a zone the day can be read in: CYFR's one definition
  of a zone, which Aqua's browser holds too (`Opus.Browser.zone?/1`).
  """
  @spec zone?(term()) :: boolean()
  defdelegate zone?(zone), to: Opus.Browser

  @doc """
  The zone stored in `prefs`, a person's preferences, when the day can be
  read in it, or nil for none: a person with no zone stored has the
  image's for Aqua's browser.
  """
  @spec stored_zone(map()) :: String.t() | nil
  def stored_zone(prefs) when is_map(prefs) do
    zone = prefs["time_zone"]
    if zone?(zone), do: zone
  end

  @doc "The date now in the context's person's stored zone."
  @spec today(Context.t()) :: Date.t()
  def today(%Context{user_id: user_id}) do
    zone = zone_of(user_id)

    case now_in(zone) do
      {:ok, now} -> DateTime.to_date(now)
      {:error, _unknown} -> Date.utc_today()
    end
  end

  @doc """
  The current daily thread of the context's athanor: the one of `today/1`'s
  date, made if none exists.
  """
  @spec current(Context.t()) :: {:ok, map()} | {:error, term()}
  def current(%Context{} = ctx),
    do: Arca.ThreadStorage.daily(Context.actor(ctx), today(ctx))

  defp zone_of(user_id) when is_binary(user_id) do
    with {:ok, user} <- Users.get(user_id),
         zone when is_binary(zone) <- Users.prefs(user)["time_zone"] do
      zone
    else
      _none -> @utc
    end
  end

  defp zone_of(_no_person), do: @utc

  defp now_in(zone), do: DateTime.now(zone, Tz.TimeZoneDatabase)
end
