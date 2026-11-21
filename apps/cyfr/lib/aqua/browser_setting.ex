# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.BrowserSetting do
  @moduledoc """
  The person's browser setting: whether Aqua may use its browser
  (`Opus.Browser`). There is no yes per thread for the browser's own
  actions: with it on, every action of the browser tool is decided as
  any offered call; with it off, every one is refused and Aqua says so.
  Turning it off holds at once: from then on CYFR starts no browser and
  sends it nothing, no action and no page, and a browser that a start
  already under way brings up is sent nothing and closed as soon as that
  start answers; its profile is kept. The browser is started so that it
  reaches nothing by itself (the driver, `cyfr-browser`).

  It is one value of the person's preferences, `aqua_browser`, read and
  written here and nowhere else. An absent value reads as the default,
  which is on; a value that is not a boolean reads as off. The person
  turns it on and off with the switch on the Aqua page; turning it on is
  theirs alone, and Aqua turns it off when asked, which holds at once
  (`Aqua.Providers.Browser`). A write merges into the preferences as
  the store holds them, so it keeps every other preference written
  meanwhile (`Sanctum.Tenancy.Users.put_prefs/2`).
  """

  alias Sanctum.Context

  @key "aqua_browser"
  @default true

  @doc """
  Whether the context's person lets Aqua use the browser, read from the
  store now: `{:ok, false}` for a person this server does not hold, and
  `{:error, :unavailable}` when the store cannot answer.
  """
  @spec allowed?(Context.t()) :: {:ok, boolean()} | {:error, :unavailable}
  def allowed?(%Context{user_id: user_id}) when is_binary(user_id) and user_id != "" do
    case Sanctum.Tenancy.Users.get(user_id) do
      {:ok, user} -> {:ok, read(Sanctum.Tenancy.Users.prefs(user))}
      {:error, :not_found} -> {:ok, false}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  def allowed?(%Context{}), do: {:ok, false}

  @doc """
  Set the context's person's browser setting to `on`. Turning it off
  ends their browser (`Opus.Browser.stop/2`): every request waiting is
  answered, and its session closes, its profile kept. The setting is
  written before the browser is stopped, so a holder the stop does not
  find reads it off before it starts anything (`Opus.Browser.act/4`).
  """
  @spec put(Context.t(), boolean()) :: {:ok, boolean()} | {:error, term()}
  def put(%Context{athanor_id: athanor_id, user_id: user_id}, on)
      when is_binary(user_id) and user_id != "" and is_boolean(on) do
    with {:ok, _user} <- Sanctum.Tenancy.Users.put_prefs(%{id: user_id}, %{@key => on}) do
      if not on and is_binary(athanor_id), do: Opus.Browser.stop(athanor_id, user_id)
      {:ok, on}
    end
  end

  defp read(prefs) do
    case Map.fetch(prefs, @key) do
      :error -> @default
      {:ok, on} when is_boolean(on) -> on
      {:ok, _unreadable} -> false
    end
  end
end
