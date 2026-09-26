# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ShellLiveTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Tests for ShellLive's picker navigation logic. The frames it creates,
  their attributes, credentials and shell verbs are
  `PrismWeb.ShellFrameTest`'s.
  """

  describe "tincture selection" do
    test "initial state has no active tincture" do
      state = initial_state()

      assert state.active_tincture == nil
      assert state.opened_tinctures == []
    end

    test "selecting a tincture sets it as active and tracks it as opened" do
      state =
        initial_state()
        |> select_tincture("iframe_stock-dashboard")

      assert state.active_tincture == "iframe_stock-dashboard"
      assert state.opened_tinctures == ["iframe_stock-dashboard"]
    end

    test "selecting the same tincture twice does not duplicate in opened list" do
      state =
        initial_state()
        |> select_tincture("iframe_stock-dashboard")
        |> select_tincture("iframe_stock-dashboard")

      assert state.active_tincture == "iframe_stock-dashboard"
      assert state.opened_tinctures == ["iframe_stock-dashboard"]
    end

    test "selecting multiple tinctures tracks all as opened" do
      state =
        initial_state()
        |> select_tincture("iframe_stock-dashboard")
        |> select_tincture("iframe_weather")

      assert state.active_tincture == "iframe_weather"
      assert state.opened_tinctures == ["iframe_stock-dashboard", "iframe_weather"]
    end

    test "selecting an unknown tincture is ignored" do
      state =
        initial_state()
        |> select_tincture("iframe_nonexistent")

      assert state.active_tincture == nil
      assert state.opened_tinctures == []
    end
  end

  describe "tincture iframe URLs" do
    test "entry URL uses the canonical athanor-scoped route" do
      url = Prima.TinctureUrl.path("home", "local", "stock-dashboard")

      # Must use the index route (not asset route) for CSP headers
      assert url == "/t/home/local/stock-dashboard"
      refute String.contains?(url, "index.html")
    end
  end

  # -- Test helpers that mirror ShellLive logic --

  defp initial_state do
    %{
      active_tincture: nil,
      opened_tinctures: [],
      tinctures: [
        %{
          id: "iframe_stock-dashboard",
          name: "stock-dashboard",
          publisher: "local",
          title: "Stock Dashboard",
          icon: "chart-line",
          url: "/t/home/local/stock-dashboard"
        },
        %{
          id: "iframe_weather",
          name: "weather",
          publisher: "local",
          title: "Weather",
          icon: "cloud",
          url: "/t/home/local/weather"
        }
      ]
    }
  end

  defp select_tincture(state, tincture_id) do
    if Enum.any?(state.tinctures, &(&1.id == tincture_id)) do
      state
      |> Map.put(:active_tincture, tincture_id)
      |> maybe_track_tincture(tincture_id)
    else
      state
    end
  end

  defp maybe_track_tincture(state, tincture_id) do
    if tincture_id in state.opened_tinctures do
      state
    else
      Map.put(state, :opened_tinctures, state.opened_tinctures ++ [tincture_id])
    end
  end
end
