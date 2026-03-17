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

  describe "desktop navigation logic" do
    test "initial state has dashboard active on system desktop" do
      state = initial_state()

      assert state.desktop == :system
      assert state.active_system_app == "dashboard"
      assert state.opened_system_apps == ["dashboard"]
      assert state.active_iframe_app == nil
      assert state.opened_iframe_apps == []
    end

    test "select_system_app sets active and tracks opened" do
      state =
        initial_state()
        |> select_system_app("logs")

      assert state.active_system_app == "logs"
      assert state.opened_system_apps == ["dashboard", "logs"]
    end

    test "select_system_app does not duplicate in opened list" do
      state =
        initial_state()
        |> select_system_app("logs")
        |> select_system_app("components")
        |> select_system_app("logs")

      assert state.active_system_app == "logs"
      assert state.opened_system_apps == ["dashboard", "logs", "components"]
    end

    test "select_system_app ignores invalid app id" do
      state =
        initial_state()
        |> select_system_app("nonexistent")

      assert state.active_system_app == "dashboard"
      assert state.opened_system_apps == ["dashboard"]
    end

    test "switch_desktop changes desktop" do
      state =
        initial_state()
        |> switch_desktop(:apps)

      assert state.desktop == :apps

      state = switch_desktop(state, :system)
      assert state.desktop == :system
    end

    test "select_iframe_app sets active and tracks opened" do
      state =
        initial_state()
        |> switch_desktop(:apps)
        |> select_iframe_app("iframe_hello")

      assert state.active_iframe_app == "iframe_hello"
      assert state.opened_iframe_apps == ["iframe_hello"]
    end

    test "select_iframe_app does not duplicate in opened list" do
      state =
        initial_state()
        |> select_iframe_app("iframe_hello")
        |> select_iframe_app("iframe_hello")

      assert state.active_iframe_app == "iframe_hello"
      assert state.opened_iframe_apps == ["iframe_hello"]
    end

    test "select_iframe_app ignores unknown app" do
      state =
        initial_state()
        |> select_iframe_app("iframe_unknown")

      assert state.active_iframe_app == nil
      assert state.opened_iframe_apps == []
    end

    test "system and iframe apps are tracked independently" do
      state =
        initial_state()
        |> select_system_app("logs")
        |> select_iframe_app("iframe_hello")
        |> switch_desktop(:apps)

      assert state.desktop == :apps
      assert state.active_system_app == "logs"
      assert state.opened_system_apps == ["dashboard", "logs"]
      assert state.active_iframe_app == "iframe_hello"
      assert state.opened_iframe_apps == ["iframe_hello"]
    end
  end

  # -- Test helpers that mirror ShellLive logic --

  defp initial_state do
    %{
      desktop: :system,
      active_system_app: "dashboard",
      opened_system_apps: ["dashboard"],
      active_iframe_app: nil,
      opened_iframe_apps: [],
      native_apps: %{
        "dashboard" => %{module: PrismWeb.DashboardLive, title: "Dashboard", icon: "home"},
        "logs" => %{module: PrismWeb.LogsLive, title: "Logs", icon: "document"},
        "components" => %{module: PrismWeb.ComponentsLive, title: "Components", icon: "cube"}
      },
      iframe_apps: [
        %{id: "iframe_hello", title: "Hello", icon: "cube", url: "/apps/local/hello/1.0.0/"}
      ]
    }
  end

  defp select_system_app(state, app_id) do
    if Map.has_key?(state.native_apps, app_id) do
      state
      |> Map.put(:active_system_app, app_id)
      |> maybe_track_system_app(app_id)
    else
      state
    end
  end

  defp select_iframe_app(state, app_id) do
    if Enum.any?(state.iframe_apps, &(&1.id == app_id)) do
      state
      |> Map.put(:active_iframe_app, app_id)
      |> maybe_track_iframe_app(app_id)
    else
      state
    end
  end

  defp switch_desktop(state, desktop) do
    Map.put(state, :desktop, desktop)
  end

  defp maybe_track_system_app(state, app_id) do
    if app_id in state.opened_system_apps do
      state
    else
      Map.put(state, :opened_system_apps, state.opened_system_apps ++ [app_id])
    end
  end

  defp maybe_track_iframe_app(state, app_id) do
    if app_id in state.opened_iframe_apps do
      state
    else
      Map.put(state, :opened_iframe_apps, state.opened_iframe_apps ++ [app_id])
    end
  end

  defp tool_allowed?(_tool, ["*"]), do: true

  defp tool_allowed?(tool, allowed) do
    normalized = String.replace(tool, "/", ".")
    Enum.any?(allowed, fn a -> a == tool || String.replace(a, "/", ".") == normalized end)
  end
end
