# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.OpsTest do
  use ExUnit.Case, async: false

  alias Cyfr.Ops.Catalog
  alias PrismWeb.Ops

  defmodule ListProvider do
    def handle("helper_list_probe", _ctx, %{"action" => "wrapped"}),
      do: {:ok, %{items: [%{id: 1}]}}

    def handle("helper_list_probe", _ctx, %{"action" => "bare"}), do: {:ok, [%{id: 2}]}
    def handle("helper_list_probe", _ctx, %{"action" => "shapeless"}), do: {:ok, %{count: 3}}
    def handle("helper_list_probe", _ctx, %{"action" => "refused"}), do: {:error, "Not allowed."}
  end

  @annotations %{
    actions: %{
      "wrapped" => %{kind: :read, planes: [:external]},
      "bare" => %{kind: :read, planes: [:external]},
      "shapeless" => %{kind: :read, planes: [:external]},
      "refused" => %{kind: :read, planes: [:external]}
    }
  }

  setup do
    Catalog.register_tool(
      "helper_list_probe",
      ListProvider,
      %{annotations: @annotations},
      :timer.minutes(1)
    )

    on_exit(fn -> Catalog.unregister_tool("helper_list_probe") end)
    {:ok, socket: %{assigns: %{context: Sanctum.TestContext.local()}}}
  end

  test "call_tool splits tool/action and requires a context", %{socket: socket} do
    assert {:ok, %{items: [%{id: 1}]}} =
             Ops.call_tool(socket, "helper_list_probe/wrapped")

    assert {:error, :no_context} = Ops.call_tool(%{assigns: %{}}, "key/list")
  end

  test "fetch_list unwraps both list shapes to one", %{socket: socket} do
    assert {:ok, [%{id: 1}]} = Ops.fetch_list(socket, "helper_list_probe/wrapped", :items)
    assert {:ok, [%{id: 2}]} = Ops.fetch_list(socket, "helper_list_probe/bare", :items)
  end

  test "anything else becomes one failure vocabulary", %{socket: socket} do
    assert {:error, "The request failed — try again."} =
             Ops.fetch_list(socket, "helper_list_probe/shapeless", :items)

    assert {:error, "Not allowed."} =
             Ops.fetch_list(socket, "helper_list_probe/refused", :items)

    assert {:error, "Not signed in."} =
             Ops.fetch_list(%{assigns: %{}}, "helper_list_probe/wrapped", :items)
  end

  test "error_message passes refusal sentences and hides raw terms" do
    assert Ops.error_message("Unauthorized: nope") == "Unauthorized: nope"
    assert Ops.error_message({:weird, :term}) == "The request failed — try again."
  end
end
