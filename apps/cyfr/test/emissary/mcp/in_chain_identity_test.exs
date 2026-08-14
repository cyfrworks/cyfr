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
        org_id: "local",
        project_id: "default",
        scope: :project,
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

  test "call_external rejects a guest-plane context outright" do
    ctx =
      Context.enter_guest(%Context{
        user_id: "identity_matrix_user",
        org_id: "local",
        project_id: "default",
        permissions: MapSet.new([:*]),
        authenticated: true
      })

    assert {:error, msg} = ToolRegistry.call_external("component", ctx, %{"action" => "list"})
    assert msg =~ "guest-plane context cannot make external-plane call"
  end

  test "call_in_chain denies an action the authority does not grant" do
    auth = granting_authority([{"component", "list"}])

    ctx =
      Context.enter_guest(%Context{
        user_id: "identity_matrix_user",
        org_id: "local",
        project_id: "default",
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
        org_id: "local",
        project_id: "default",
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

  test "an external server tool under an authority denies without a granted digest" do
    auth = granting_authority([{"component", "list"}])

    ctx =
      Context.enter_guest(%Context{
        user_id: "identity_matrix_user",
        org_id: "local",
        project_id: "default",
        permissions: MapSet.new([:*]),
        authenticated: true,
        request_id: "req_identity_matrix"
      })

    assert {:error, msg} =
             ToolRegistry.call_in_chain("github:create_issue", ctx, %{}, auth)

    assert msg =~ "Denied by chain authority"
  end
end
