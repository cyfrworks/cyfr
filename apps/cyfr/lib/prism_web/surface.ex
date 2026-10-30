# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.Surface do
  @moduledoc """
  The person's mode, which the top bar switches (`PrismWeb.TopbarLive`):
  the Dashboard, the console's pages, or the Canvas, the shell at
  `/a/<athanor>/canvas` (`PrismWeb.ShellLive`). In the code it is the
  surface, beside the lite and dev UI mode (`Prism.Labels`).

  The mode is remembered per browser session, as the AQUA panel keeps its
  own: in `Arca.Cache` under the session token's hash, for a day, with the
  Dashboard page the person last had open. A load of `/` returns to the
  Canvas when that is where they left; a new sign-in is a new session and
  lands in the chat. A remembered value that is not a mode reads as the
  Dashboard.
  """

  @kept_ttl_ms :timer.hours(24)

  @typedoc "A mode: `dashboard` or `canvas`."
  @type t :: String.t()

  @typedoc "What a browser session remembers: its mode and its last Dashboard page's nav key."
  @type kept :: %{surface: t(), page: String.t() | nil}

  @doc "A value read as a mode: `canvas`, or the Dashboard for anything else."
  @spec read(term()) :: t()
  def read("canvas"), do: "canvas"
  def read(_other), do: "dashboard"

  @doc "The Canvas mode's path under the athanor route `route`."
  @spec canvas_path(String.t() | nil) :: String.t()
  def canvas_path(route), do: PrismWeb.Focus.path(route, PrismWeb.Nav.canvas_path())

  @doc """
  What the browser session holding `token` remembers: its mode, read as
  one, and its last Dashboard page, or the Dashboard and no page.
  """
  @spec recall(String.t() | nil) :: kept()
  def recall(token) do
    with key when not is_nil(key) <- key(token),
         {:ok, %{surface: surface} = kept} <- Arca.Cache.get(key) do
      %{surface: read(surface), page: page(Map.get(kept, :page))}
    else
      _none -> %{surface: "dashboard", page: nil}
    end
  end

  @doc """
  Remember that the browser session holding `token` is in `surface`: in
  the Dashboard on the page `page` (a nav key); in the Canvas, keeping the
  Dashboard page it had. A session with no token remembers nothing.
  """
  @spec remember(String.t() | nil, t(), String.t() | nil) :: :ok
  def remember(token, surface, page \\ nil) do
    case key(token) do
      nil ->
        :ok

      key ->
        page = if read(surface) == "canvas", do: recall(token).page, else: page(page)
        _ = Arca.Cache.put(key, %{surface: read(surface), page: page}, @kept_ttl_ms)
        :ok
    end
  end

  defp key(token) do
    case Prism.Tray.session_hash(token) do
      nil -> nil
      hash -> {:surface, hash}
    end
  end

  defp page(page) when is_binary(page) and page != "", do: page
  defp page(_other), do: nil
end
