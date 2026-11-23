# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Language do
  @moduledoc """
  The person's language: the tag their own browser reports when the shell
  connects, beside their time zone (`Aqua.Day`), which the shell stores as
  `locale` in their preferences when it differs from what is stored
  (`Sanctum.Tenancy.Users.put_prefs/2`, `PrismWeb.ShellLive`). Aqua's
  browser reads pages in it (`Aqua.BrowserSetting.start/1`). There is no
  setting on a screen: the person changes it by changing their own
  browser's language, which takes effect at the browser's next start.

  It is one value of the person's preferences, read and written here and
  nowhere else, in the grammar the browser's report is held to
  (`Prima.TinctureWire.locale?/1`). An absent value, a person who has
  never opened a screen, is no language, and Aqua's browser keeps the
  image's; a stored value out of the grammar reads as absent.
  """

  alias Sanctum.Tenancy.Users

  @key "locale"

  @doc """
  Store `locale` as the person's when it is a language tag and differs
  from the stored one. The preference is read fresh and only its own key
  is patched, so the person's other preferences stand. Anything else
  stores nothing.
  """
  @spec put(String.t(), term()) :: :ok | {:error, term()}
  def put(user_id, locale) when is_binary(user_id) do
    if Prima.TinctureWire.locale?(locale),
      do: keep(user_id, locale),
      else: {:error, :invalid_locale}
  end

  defp keep(user_id, locale) do
    with {:ok, user} <- Users.get(user_id) do
      if Users.prefs(user)[@key] == locale do
        :ok
      else
        with {:ok, _user} <- Users.put_prefs(user, %{@key => locale}), do: :ok
      end
    end
  end

  @doc "The language stored in `prefs`, a person's preferences, or nil for none."
  @spec stored(map()) :: String.t() | nil
  def stored(prefs) when is_map(prefs) do
    locale = prefs[@key]
    if Prima.TinctureWire.locale?(locale), do: locale
  end
end
