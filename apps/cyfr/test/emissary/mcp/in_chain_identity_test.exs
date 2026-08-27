# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Emissary.MCP.InChainIdentityTest do
  # The provider half of the plane split: an in-chain call is authorized by
  # the chain's authority AND the caller's identity. The authority conjunct
  # is applied at the dispatch chokepoint, so no gate behind an
  # in-chain-annotated action may re-refuse the guest plane — that would
  # make the action unauthorizable from a chain by construction.
  #
  # This test is the audit: every in-chain pair is called through the real
  # chokepoint with a fully-permissioned guest context and a fully-granting
  # authority. Argument validation errors are fine; a plane refusal is a
  # gate that still needs the identity-conjunct branch.
  use ExUnit.Case, async: false

  alias Emissary.MCP.ToolRegistry
  alias Sanctum.Authority
  alias Sanctum.Authority.Blob
  alias Sanctum.Context

  @plane_refusal ~r/guest-plane context cannot/

  setup do
    Arca.Cache.init()
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    :ok
  end

  defp in_chain_pairs do
    for module <- Application.get_env(:cyfr, :tool_providers, []),
        tool <- module.tools(),
        {action, annotation} <- get_in(tool, [:annotations, :actions]) || %{},
        :in_chain in (annotation[:planes] || []),
        do: {tool.name, action}
  end

  defp granting_authority(pairs) do
    node = "formula:local.identity-matrix"
    tools = pairs |> Enum.map(fn {tool, action} -> "#{tool}.#{action}" end) |> Enum.sort()

    graph = %{
      "canonical" => "jcs-1",
      "nodes" => %{
        node => %{
          "limits" => %{
            "timeout" => "1m",
            "max_memory_bytes" => 67_108_864,
            "max_request_size" => 1_048_576,
            "max_response_size" => 5_242_880,
            "rate_limit" => %{"requests" => 10_000, "window" => "1m"},
            "max_concurrent_tasks" => 10,
            "batch_timeout" => "1m"
          },
          "edges" => %{"@ingress" => %{"tools" => tools}}
        }
      }
    }

    {:ok, blob} = Blob.parse(graph)

    {:ok, auth} =
      Authority.root(
        %{
          profile_id: "prof-matrix",
          consent_id: "consent-matrix",
          source_ref: node,
          kind: :owner,
          invoke_mode: :open_inert,
          activation: %{node => "sha256:matrix"}
        },
        blob
      )

    auth
  end

  @tag :requires_opus_modules
  test "no in-chain-annotated action refuses a permissioned guest at the plane" do
    pairs = in_chain_pairs()
    assert pairs != [], "no in-chain pairs found — provider config missing?"

    auth = granting_authority(pairs)

    ctx =
      Context.enter_guest(%Context{
        user_id: "identity_matrix_user",
        athanor_id: "ath_test",
        scope: :athanor,
        permissions: MapSet.new([:*]),
        authenticated: true,
        request_id: "req_identity_matrix"
      })

    refusals =
      for {tool, action} <- pairs,
          result = ToolRegistry.call_in_chain(tool, ctx, %{"action" => action}, auth),
          match?({:error, msg} when is_binary(msg), result),
          {:error, msg} = result,
          msg =~ @plane_refusal,
          do: {tool, action, msg}

    assert refusals == [],
           "gates refusing the guest plane behind in-chain actions:\n" <>
             Enum.map_join(refusals, "\n", fn {t, a, m} -> "  #{t}.#{a}: #{m}" end)
  end

  test "tincture_visibility.get reaches its handler from a chain" do
    # Regression: the handler used to gate through Context.authorize, whose
    # permission arm refuses the guest plane unconditionally — an in-chain
    # annotation the gate contradicted. With the gate central (guest arm =
    # identity conjunct) and the handler keeping only the tenant residual,
    # a chain-granted read must get past the plane. Passing full args
    # matters: the arg-matching clauses sit in front of the residual, so an
    # action-only probe would prove nothing about it.
    auth = granting_authority([{"tincture_visibility", "get"}])

    ctx =
      Context.enter_guest(%Context{
        user_id: "identity_matrix_user",
        athanor_id: "ath_test",
        scope: :athanor,
        permissions: MapSet.new([:*]),
        authenticated: true,
        request_id: "req_identity_matrix"
      })

    args = %{"action" => "get", "publisher" => "local", "name" => "no-such-tincture"}

    case ToolRegistry.call_in_chain("tincture_visibility", ctx, args, auth) do
      {:ok, _result} ->
        :ok

      {:error, msg} ->
        refute msg =~ @plane_refusal,
               "tincture_visibility.get still refuses the guest plane: #{msg}"
    end
  end

  test "call_external rejects a guest-plane context outright" do
    ctx =
      Context.enter_guest(%Context{
        user_id: "identity_matrix_user",
        athanor_id: "ath_test",
        permissions: MapSet.new([:*]),
        authenticated: true
      })

    assert {:error, {:guest_plane_call, "component"}} =
             ToolRegistry.call_external("component", ctx, %{"action" => "list"})
  end

  test "call_in_chain denies an action the authority does not grant" do
    auth = granting_authority([{"component", "list"}])

    ctx =
      Context.enter_guest(%Context{
        user_id: "identity_matrix_user",
        athanor_id: "ath_test",
        permissions: MapSet.new([:*]),
        authenticated: true,
        request_id: "req_identity_matrix"
      })

    assert {:error, msg} =
             ToolRegistry.call_in_chain("component", ctx, %{"action" => "search"}, auth)

    assert msg =~ "Denied by chain authority"
  end

  @tag :requires_opus_modules
  test "call_in_chain refuses an action not reachable in-chain" do
    pairs = in_chain_pairs()
    auth = granting_authority(pairs ++ [{"execution", "force_release"}])

    ctx =
      Context.enter_guest(%Context{
        user_id: "identity_matrix_user",
        athanor_id: "ath_test",
        permissions: MapSet.new([:*]),
        authenticated: true,
        request_id: "req_identity_matrix"
      })

    assert {:error, msg} =
             ToolRegistry.call_in_chain(
               "execution",
               ctx,
               %{"action" => "force_release"},
               auth
             )

    assert msg =~ "not reachable from a running chain"
  end

  @tag :requires_opus_modules
  test "the tenancy verbs are people's acts — never reachable from a running chain" do
    verbs = [
      {"athanor", "create"},
      {"athanor", "archive"},
      {"member", "add"},
      {"member", "remove"},
      {"door", "allow"},
      # A chain may read the athanor's agent definitions, never rewrite them
      # — the tool_policy it runs under is not its own to widen.
      {"aqua", "create"},
      {"aqua", "update"},
      {"aqua", "delete"}
    ]

    auth = granting_authority(in_chain_pairs() ++ verbs)

    ctx =
      Context.enter_guest(%Context{
        user_id: "identity_matrix_user",
        athanor_id: "ath_test",
        permissions: MapSet.new([:*]),
        authenticated: true,
        platform_admin: true,
        request_id: "req_identity_matrix"
      })

    for {tool, action} <- verbs do
      assert {:error, msg} =
               ToolRegistry.call_in_chain(tool, ctx, %{"action" => action, "name" => "x"}, auth)

      assert msg =~ "not reachable from a running chain", "#{tool}.#{action}: #{msg}"
    end
  end

  test "an external server tool under an authority denies without a granted digest" do
    auth = granting_authority([{"component", "list"}])

    ctx =
      Context.enter_guest(%Context{
        user_id: "identity_matrix_user",
        athanor_id: "ath_test",
        permissions: MapSet.new([:*]),
        authenticated: true,
        request_id: "req_identity_matrix"
      })

    assert {:error, msg} =
             ToolRegistry.call_in_chain("github:create_issue", ctx, %{}, auth)

    assert msg =~ "Denied by chain authority"
  end
end
