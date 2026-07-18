# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.ApplicationTest do
  use ExUnit.Case, async: true

  # A wildcard CORS origin once authentication is configured must fail closed
  # at boot in a real release, not merely warn. cors_enforcement/3 is the pure
  # decision seam the boot guard uses (first arg: auth configured?).
  describe "cors_enforcement/3" do
    test "auth configured + wildcard + real release => raise" do
      assert {:raise, msg} = Cyfr.Application.cors_enforcement(true, ["*"], true)
      assert msg =~ "FATAL"
      assert msg =~ "authentication enabled"

      assert {:raise, _} = Cyfr.Application.cors_enforcement(true, ["https://a.example", "*"], true)
    end

    test "auth configured + wildcard outside a release => warn (dev/test not blocked)" do
      assert {:warn, msg} = Cyfr.Application.cors_enforcement(true, ["*"], false)
      assert msg =~ "suppressed outside a release"
    end

    test "auth configured with an explicit allowlist => ok" do
      assert :ok = Cyfr.Application.cors_enforcement(true, ["https://app.example"], true)
      assert :ok = Cyfr.Application.cors_enforcement(true, [], true)
    end

    test "no auth configured is never blocked, even with a wildcard in a release" do
      assert :ok = Cyfr.Application.cors_enforcement(false, ["*"], true)
      assert :ok = Cyfr.Application.cors_enforcement(false, ["*"], false)
    end
  end

  describe "supervision tiers" do
    test "root supervises exactly the infra and web tier supervisors" do
      children = Supervisor.which_children(Cyfr.Supervisor)

      assert [{Cyfr.WebSupervisor, _, :supervisor, _}, {Cyfr.InfraSupervisor, _, :supervisor, _}] =
               children
    end

    test "data/infra children live under the infra tier" do
      ids =
        Cyfr.InfraSupervisor
        |> Supervisor.which_children()
        |> Enum.map(fn {id, _pid, _type, _mods} -> id end)

      assert Arca.Repo in ids
      assert Phoenix.PubSub.Supervisor in ids or
               Enum.any?(ids, fn id -> id == Emissary.PubSub end)

      assert Emissary.MCP.ToolRegistry in ids
      refute EmissaryWeb.Endpoint in ids
    end

    test "endpoints live under the web tier" do
      ids =
        Cyfr.WebSupervisor
        |> Supervisor.which_children()
        |> Enum.map(fn {id, _pid, _type, _mods} -> id end)

      assert EmissaryWeb.Endpoint in ids
      assert PrismWeb.Endpoint in ids
      refute Arca.Repo in ids
    end
  end
end
