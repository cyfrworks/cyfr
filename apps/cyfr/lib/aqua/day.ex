# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Day do
  @moduledoc """
  The person's day, and the daily thread that holds it.

  The day is the person's own: the date now in their time zone, which the
  browser reports when the shell connects and the shell stores as
  `time_zone` in their preferences when it differs from what is stored
  (`Sanctum.Tenancy.Users.put_prefs/2`, `PrismWeb.ShellLive`). `UTC` until
  one arrives, and for a stored zone the zone database does not know.
  `today/1` is the one reader of that preference.

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
  handed to the calendar call as its argument. This module is its one
  user: the node's own `:time_zone_database` is not set, so nothing else
  in CYFR reads zones by accident. Its data is what the package compiled
  in; none of its updaters is started, so nothing fetches zone data at run
  time. A zone it does not know is refused where the shell writes it
  (`put_zone/2`), and one stored that it cannot resolve reads as UTC.
  """

  alias Sanctum.Context
  alias Sanctum.Tenancy.Users

  @utc "UTC"

  @doc "The zone a person with no stored one, or an unknown one, has: `UTC`."
  @spec default_zone() :: String.t()
  def default_zone, do: @utc

  @doc """
  Whether `zone` is a zone the day can be read in: a name of the zone
  database's, in the grammar the browser's report is held to
  (`Prima.TinctureWire.time_zone?/1`).
  """
  @spec zone?(term()) :: boolean()
  def zone?(zone) do
    Prima.TinctureWire.time_zone?(zone) and match?({:ok, _}, now_in(zone))
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

  @doc """
  Store `zone` as the person's when it is a zone the day can be read in
  and differs from the stored one. The preference is read fresh and only
  its own key is patched, so the person's other preferences stand. An
  unknown zone stores nothing.
  """
  @spec put_zone(String.t(), term()) :: :ok | {:error, term()}
  def put_zone(user_id, zone) when is_binary(user_id) do
    with true <- zone?(zone) || {:error, :invalid_zone},
         {:ok, user} <- Users.get(user_id) do
      if Users.prefs(user)["time_zone"] == zone do
        :ok
      else
        with {:ok, _user} <- Users.put_prefs(user, %{"time_zone" => zone}), do: :ok
      end
    end
  end

  defp zone_of(user_id) when is_binary(user_id) do
    with {:ok, user} <- Users.get(user_id),
         zone when is_binary(zone) <- Users.prefs(user)["time_zone"] do
      zone
    else
      _none -> @utc
    end
  end

  defp zone_of(_no_person), do: @utc

  defp now_in(zone) when is_binary(zone), do: DateTime.now(zone, Tz.TimeZoneDatabase)
  defp now_in(_zone), do: {:error, :time_zone_not_found}
end
