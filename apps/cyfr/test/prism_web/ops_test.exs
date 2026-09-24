# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.OpsTest do
  use ExUnit.Case, async: false

  alias Grimoire.Catalog
  alias Grimoire.Probe
  alias PrismWeb.Ops

  setup do
    Cyfr.Test.Sandbox.setup!()
    {:ok, socket: %{assigns: %{context: Sanctum.TestContext.local()}}}
  end

  test "call_tool splits tool/action and requires a context", %{socket: socket} do
    Catalog.with_providers([Probe.List], fn ->
      assert {:ok, %{items: [%{id: 1}]}} =
               Ops.call_tool(socket, "helper_list_probe/wrapped")

      assert {:error, :no_context} = Ops.call_tool(%{assigns: %{}}, "key/list")
    end)
  end

  test "fetch_list unwraps both list shapes to one", %{socket: socket} do
    Catalog.with_providers([Probe.List], fn ->
      assert {:ok, [%{id: 1}]} = Ops.fetch_list(socket, "helper_list_probe/wrapped", :items)
      assert {:ok, [%{id: 2}]} = Ops.fetch_list(socket, "helper_list_probe/bare", :items)
    end)
  end

  test "anything else becomes one failure vocabulary", %{socket: socket} do
    Catalog.with_providers([Probe.List], fn ->
      assert {:error, "The outcome could not be confirmed."} =
               Ops.fetch_list(socket, "helper_list_probe/shapeless", :items)

      assert {:error, "Not allowed."} =
               Ops.fetch_list(socket, "helper_list_probe/refused", :items)

      assert {:error, "Not signed in."} =
               Ops.fetch_list(%{assigns: %{}}, "helper_list_probe/wrapped", :items)
    end)
  end

  test "error_message passes refusal sentences and hides raw terms" do
    assert Ops.error_message("Unauthorized: nope") == "Unauthorized: nope"
    assert Ops.error_message({:weird, :term}) == "The outcome could not be confirmed."
  end
end
