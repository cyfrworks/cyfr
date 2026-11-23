# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Reading do
  @moduledoc """
  How the person reads: their time zone and language, as their own browser
  reports them when the shell connects (`PrismWeb.ShellLive`), stored as
  `time_zone` and `locale` in their preferences. A report is one write:
  each value kept when it reads as CYFR's one definition of a zone or a
  language (`Opus.Browser.zone?/1`, `language?/1`) and differs from the
  stored one, both in one patch (`Sanctum.Tenancy.Users.put_prefs/2`), so
  nothing reads one without the other, and two devices that report at once
  leave one device's pair. The preferences are read fresh and only the
  report's own keys are patched, so the person's other preferences stand.

  The zone reads the person's day (`Aqua.Day`), and both the pages Aqua's
  browser shows (`Aqua.BrowserSetting.start/1`), exactly as reported:
  nothing is added to them. There is no setting on a screen: the person
  changes them by changing their own browser's, which takes effect at
  Aqua's browser's next start. An absent value, a person who has never
  opened a screen, is none, and Aqua's browser keeps the image's; a stored
  value that does not read is none.
  """

  alias Sanctum.Tenancy.Users

  @keys %{"time_zone" => &Opus.Browser.zone?/1, "locale" => &Opus.Browser.language?/1}

  @doc """
  Keep the browser's report, a map that may hold `"time_zone"` and
  `"locale"`, as the person's, in one write of the values that read and
  differ from the stored ones: `:ok` when the store holds every value that
  reads, `{:error, :invalid}` when the report holds none that does.
  """
  @spec put(String.t(), map()) :: :ok | {:error, term()}
  def put(user_id, report) when is_binary(user_id) and is_map(report) do
    kept = for {key, valid?} <- @keys, valid?.(report[key]), into: %{}, do: {key, report[key]}

    if kept == %{}, do: {:error, :invalid}, else: keep(user_id, kept)
  end

  defp keep(user_id, kept) do
    with {:ok, user} <- Users.get(user_id) do
      stored = Users.prefs(user)
      patch = for {key, value} <- kept, stored[key] != value, into: %{}, do: {key, value}

      if patch == %{},
        do: :ok,
        else: with({:ok, _user} <- Users.put_prefs(user, patch), do: :ok)
    end
  end

  @doc "The language stored in `prefs`, a person's preferences, or nil for none."
  @spec locale(map()) :: String.t() | nil
  def locale(prefs) when is_map(prefs) do
    locale = prefs["locale"]
    if Opus.Browser.language?(locale), do: locale
  end
end
