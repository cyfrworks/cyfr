# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.IngressSymmetryTest do
  @moduledoc """
  Both ingresses hand a tool the same arguments.

  Checks that HTTP and in-process calls enforce the same inputSchema
  validation before dispatching to a handler.
  """
  use ExUnit.Case, async: false

  alias Grimoire.Catalog
  alias Grimoire.Probe
  alias Prima.Refusal

  setup do
    Cyfr.Test.Sandbox.setup!()
    Process.register(self(), :ingress_probe_observer)
    {:ok, ctx: Sanctum.TestContext.local()}
  end

  test "a wrongly-typed argument is refused on the console path too", %{ctx: ctx} do
    Catalog.with_providers([Probe.Ingress], fn ->
      # Require string ids on both HTTP and console dispatch.
      assert {:error, %Refusal{stage: :admission, reason: {:invalid_argument, _}}} =
               Grimoire.call_external("ingress_probe", ctx, %{
                 "action" => "echo",
                 "id" => 12_345
               })

      refute_receive {:reached_handler, _}, 200
    end)
  end

  test "an unknown action is still refused in its own vocabulary", %{ctx: ctx} do
    Catalog.with_providers([Probe.Ingress], fn ->
      # The catalog returns unknown_action for undeclared actions before schema validation.
      assert {:error, %Refusal{stage: :admission, reason: {:unknown_action, _}}} =
               Grimoire.call_external("ingress_probe", ctx, %{"action" => "nope"})

      refute_receive {:reached_handler, _}, 200
    end)
  end

  test "a well-formed call still reaches the handler", %{ctx: ctx} do
    Catalog.with_providers([Probe.Ingress], fn ->
      assert {:ok, _} =
               Grimoire.call_external("ingress_probe", ctx, %{
                 "action" => "echo",
                 "id" => "abc"
               })

      assert_receive {:reached_handler, %{"action" => "echo", "id" => "abc"}}, 2_000
    end)
  end

  test "a tool with no additional arguments still refuses unknown actions", %{ctx: ctx} do
    Catalog.with_providers([Probe.Ingress], fn ->
      assert {:error, %Refusal{stage: :admission, reason: {:unknown_action, _}}} =
               Grimoire.call_external("ingress_probe_bare", ctx, %{"action" => "nope"})
    end)
  end
end
