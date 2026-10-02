# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.AdmissionTest do
  @moduledoc """
  The admission roster against what admits.

  Every admission entry `Cyfr.Boundaries.admission_entries/0` rosters
  belongs to a built path, and every module a built path names is an
  entry's; a path the roster declares and defers, and one it does not
  name, admit nothing. The boot reads the roster: a socket the
  endpoint mounts, or a listener the running tree holds, that no built
  path names refuses it, naming what it found.
  """

  use ExUnit.Case, async: true

  alias Cyfr.Admission
  alias Cyfr.Boundaries

  # ==========================================================================
  # The roster and the admission entries agree
  # ==========================================================================

  describe "the roster" do
    test "names four built paths and two declared ones, each once" do
      assert Admission.paths() == [
               :http,
               :host_api,
               :scheduler,
               :device_channel,
               :unix_socket,
               :compositor
             ]

      assert Admission.built() == [:http, :host_api, :scheduler, :device_channel]
    end

    test "every admission entry belongs to a built path, and every module a path names is an entry's" do
      assert disagreements(entry_modules(Boundaries.admission_entries()), Admission.roster()) ==
               {[], []}
    end

    test "an entry on no path, and a path naming a module that is no entry, are both found" do
      planted_entry = %{
        module: Emissary.Web.PlantedController,
        site: :index,
        plane: :external,
        origin: :none
      }

      entries = entry_modules([planted_entry | Boundaries.admission_entries()])

      roster =
        Enum.map(Admission.roster(), fn
          %{path: :scheduler} = row -> %{row | entries: ["Crucible.Planted" | row.entries]}
          row -> row
        end)

      assert disagreements(entries, roster) ==
               {["Emissary.Web.PlantedController"], ["Crucible.Planted"]}
    end

    test "the device channel is a built path carried by its own entry and the gate" do
      assert {:ok, row} = Admission.fetch(:device_channel)
      assert row.sockets == [{"/device", "Emissary.Web.DeviceChannel"}]
      assert row.listener == "CyfrWeb.Endpoint"
      assert Enum.sort(row.entries) == ["Emissary.Web.DeviceChannel", "Grimoire"]
    end

    test "a path declared and deferred admits nothing, and names nothing it would carry" do
      for path <- [:unix_socket, :compositor] do
        assert Admission.fetch(path) == {:error, :deferred}
        row = Enum.find(Admission.roster(), &(&1.path == path))
        assert %{built: false, listener: nil, sockets: [], entries: []} = row
      end
    end

    test "a path not on the roster admits nothing" do
      for path <- [:bluetooth, "http", nil, {:http}] do
        assert Admission.fetch(path) == {:error, :not_on_roster}
      end
    end

    test "every row says why it reads as it does" do
      for row <- Admission.roster() do
        assert is_binary(row.reason) and row.reason != "", inspect(row.path)
      end
    end
  end

  # ==========================================================================
  # The boot reads the roster
  # ==========================================================================

  describe "the endpoint's sockets" do
    test "are each on the roster" do
      assert Admission.socket_findings(CyfrWeb.Endpoint.__sockets__()) == []
      assert Cyfr.Application.check_endpoint_sockets!() == :ok
    end

    test "a socket the roster does not name refuses the boot, naming it" do
      sockets = [{"/rogue", Planted.RogueSocket, []} | CyfrWeb.Endpoint.__sockets__()]

      error =
        assert_raise RuntimeError, fn -> Cyfr.Application.check_endpoint_sockets!(sockets) end

      assert error.message =~ "refusing to boot"
      assert error.message =~ "/rogue (Planted.RogueSocket)"
    end

    test "a rostered socket at another mount is not on the roster" do
      sockets = [{"/glass", Emissary.Web.DeviceChannel, []}]
      assert [finding] = Admission.socket_findings(sockets)
      assert finding =~ "/glass (Emissary.Web.DeviceChannel)"
    end
  end

  describe "the listeners under the tree" do
    test "are each on the roster, the HostAPI listener among them" do
      listeners = Cyfr.Application.listeners(Cyfr.Supervisor)

      assert Crucible.HostListener in listeners
      assert Admission.listener_findings(listeners) == []
      assert Cyfr.Application.check_listeners!(listeners) == :ok
    end

    test "a listener the roster does not name refuses the boot, naming it" do
      error =
        assert_raise RuntimeError, fn ->
          Cyfr.Application.check_listeners!([Crucible.HostListener, Planted.RogueListener])
        end

      assert error.message =~ "refusing to boot"
      assert error.message =~ "Planted.RogueListener"
      refute error.message =~ "Crucible.HostListener"
    end

    test "a listener is found by the socket server it runs, wherever it sits in the tree" do
      server = fn id ->
        Supervisor.child_spec(
          {Bandit, plug: Plug.Head, ip: {127, 0, 0, 1}, port: 0, startup_log: false},
          id: id
        )
      end

      group = fn id, children ->
        %{
          id: id,
          start: {Supervisor, :start_link, [children, [strategy: :one_for_one]]},
          type: :supervisor
        }
      end

      children = [
        # A listener of its own, two levels down, and one beside it that
        # runs no socket server.
        group.(Planted.Domain, [
          group.(Planted.RogueListener, [server.(:server)]),
          group.(Planted.Quiet, [{Task.Supervisor, name: Planted.QuietTasks}])
        ]),
        # A socket server started directly under the root.
        server.(:bare)
      ]

      root =
        start_supervised!(%{
          id: Planted.Root,
          start: {Supervisor, :start_link, [children, [strategy: :one_for_one]]},
          type: :supervisor
        })

      assert Enum.sort(Cyfr.Application.listeners(root)) ==
               Enum.sort([Planted.RogueListener, root])

      error =
        assert_raise RuntimeError, fn ->
          root |> Cyfr.Application.listeners() |> Cyfr.Application.check_listeners!()
        end

      assert error.message =~ "Planted.RogueListener"
    end
  end

  # The entries' modules on no built path, and the modules a built path
  # names that are no entry's.
  defp disagreements(entry_modules, roster) do
    carried =
      for %{built: true, entries: entries} <- roster, module <- entries, uniq: true, do: module

    {Enum.sort(entry_modules -- carried), Enum.sort(Enum.uniq(carried) -- entry_modules)}
  end

  defp entry_modules(entries), do: entries |> Enum.map(&inspect(&1.module)) |> Enum.uniq()
end
