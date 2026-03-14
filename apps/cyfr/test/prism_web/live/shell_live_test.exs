defmodule PrismWeb.ShellLiveTest do
  use ExUnit.Case, async: true

  describe "tool_allowed?/2" do
    test "wildcard allows all" do
      assert tool_allowed?("anything", ["*"])
      assert tool_allowed?("execution.list", ["*"])
    end

    test "exact match" do
      assert tool_allowed?("execution.list", ["execution.list", "execution.get"])
      assert tool_allowed?("execution.get", ["execution.list", "execution.get"])
    end

    test "slash/dot normalization" do
      assert tool_allowed?("execution/list", ["execution.list"])
      assert tool_allowed?("execution.list", ["execution/list"])
    end

    test "denied when not in list" do
      refute tool_allowed?("secrets/list", ["execution.list"])
    end

    test "empty list denies all" do
      refute tool_allowed?("execution.list", [])
    end
  end

  describe "tab management logic" do
    test "open_tab adds a new tab" do
      state = initial_state()
      state = open_tab(state, "dashboard")

      assert length(state.tabs) == 1
      assert state.active_tab == "tab_1"
      assert hd(state.tabs).app_id == "dashboard"
    end

    test "open_tab switches to existing tab instead of duplicating" do
      state =
        initial_state()
        |> open_tab("dashboard")
        |> open_tab("logs")
        |> open_tab("dashboard")

      assert length(state.tabs) == 2
      assert state.active_tab == "tab_1"
    end

    test "close_tab removes tab and activates adjacent" do
      state =
        initial_state()
        |> open_tab("dashboard")
        |> open_tab("logs")
        |> open_tab("components")

      # Close the middle tab (active is tab_3/components)
      state = close_tab(state, "tab_2")

      assert length(state.tabs) == 2
      # Active was tab_3, not the closed one, so it stays
      assert state.active_tab == "tab_3"
    end

    test "close_tab activates adjacent when closing active tab" do
      state =
        initial_state()
        |> open_tab("dashboard")
        |> open_tab("logs")
        |> open_tab("components")
        |> switch_tab("tab_2")

      # Close the active tab (tab_2/logs)
      state = close_tab(state, "tab_2")

      assert length(state.tabs) == 2
      # Should activate the tab at the same position (tab_3/components, now at index 1)
      assert state.active_tab == "tab_3"
    end

    test "close_tab on last tab results in nil active" do
      state =
        initial_state()
        |> open_tab("dashboard")

      state = close_tab(state, "tab_1")

      assert state.tabs == []
      assert state.active_tab == nil
    end

    test "switch_tab changes active tab" do
      state =
        initial_state()
        |> open_tab("dashboard")
        |> open_tab("logs")

      assert state.active_tab == "tab_2"

      state = switch_tab(state, "tab_1")
      assert state.active_tab == "tab_1"
    end
  end

  # -- Test helpers that mirror ShellLive logic --

  defp initial_state do
    %{
      tabs: [],
      active_tab: nil,
      tab_counter: 0,
      native_apps: %{
        "dashboard" => %{module: PrismWeb.DashboardLive, title: "Dashboard", icon: "home"},
        "logs" => %{module: PrismWeb.LogsLive, title: "Logs", icon: "document"},
        "components" => %{module: PrismWeb.ComponentsLive, title: "Components", icon: "cube"}
      },
      iframe_apps: []
    }
  end

  defp open_tab(state, app_id) do
    case Enum.find(state.tabs, &(&1.app_id == app_id)) do
      %{id: existing_id} ->
        %{state | active_tab: existing_id}

      nil ->
        counter = state.tab_counter + 1
        tab_id = "tab_#{counter}"

        app_info = Map.get(state.native_apps, app_id)

        tab = %{
          id: tab_id,
          app_id: app_id,
          type: :native,
          title: app_info.title,
          icon: app_info.icon,
          module: app_info.module
        }

        %{state | tabs: state.tabs ++ [tab], active_tab: tab_id, tab_counter: counter}
    end
  end

  defp close_tab(state, tab_id) do
    tabs = Enum.reject(state.tabs, &(&1.id == tab_id))

    active =
      if state.active_tab == tab_id do
        case tabs do
          [] ->
            nil

          remaining ->
            old_idx = Enum.find_index(state.tabs, &(&1.id == tab_id)) || 0
            new_idx = min(old_idx, length(remaining) - 1)
            Enum.at(remaining, new_idx).id
        end
      else
        state.active_tab
      end

    %{state | tabs: tabs, active_tab: active}
  end

  defp switch_tab(state, tab_id) do
    %{state | active_tab: tab_id}
  end

  defp tool_allowed?(_tool, ["*"]), do: true

  defp tool_allowed?(tool, allowed) do
    normalized = String.replace(tool, "/", ".")
    Enum.any?(allowed, fn a -> a == tool || String.replace(a, "/", ".") == normalized end)
  end
end
