# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.ActionCoverageTest do
  @moduledoc """
  Every declared action reaches a handler clause of its own, through the
  gate, and the handler does not raise.

  Each action is called as a caller would call it: through
  `Grimoire.call_external/4` under a full context when the external plane
  reaches it, and through `Grimoire.call_in_chain/5` under a chain
  authority that grants it when only a chain does — so the gate's context
  projection (`:actor` providers get the actor alone) applies exactly as
  in production. Its arguments are built from its declaration: a
  type-valid placeholder for each required `Prima.Arg`.

  What the call answers decides:

    * an admission refusal fails — the generated call did not satisfy the
      declaration it was built from, or the gate refuses a caller the
      declaration admits;
    * a handler that raised or exited fails — the gate contains it as a
      crash, which a direct `handle/3` call used to count as handled;
    * `{:ok, _}` or a handler's own refusal passes: the action reached a
      clause that knows it, and placeholder arguments name nothing.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Prima.Authority
  alias Prima.Authority.Blob
  alias Sanctum.Context

  # config:compile-runtime-ok — cases require the live registry’s roster at compile time.
  @providers Application.compile_env(:cyfr, :tool_providers, [])

  setup do
    Arca.Cache.init()
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    :ok
  end

  for provider <- @providers,
      tool <- provider.tools(),
      %Prima.Operation{action: action} <- tool.operations do
    @tag tool: tool.name, action: action
    test "#{inspect(provider)} #{tool.name}.#{action} reaches its handler through the gate" do
      name = unquote(tool.name)
      action = unquote(action)
      {:ok, {_module, tool}} = Grimoire.lookup(name)
      operation = Enum.find(tool.operations, &(&1.action == action))

      {result, log} = with_log(fn -> dispatch(operation, arguments(operation)) end)

      refute_admission_refused(operation, result)
      refute_crashed(operation, result, log)
    end
  end

  test "a handler that raises or exits fails the coverage; one that refuses does not" do
    Grimoire.Catalog.with_providers([Grimoire.Probe.Crashing], fn ->
      {:ok, {_module, tool}} = Grimoire.lookup(Grimoire.Probe.Crashing.tool())

      for action <- ~w(raise exit) do
        operation = Enum.find(tool.operations, &(&1.action == action))
        {result, log} = with_log(fn -> dispatch(operation, arguments(operation)) end)

        assert_raise ExUnit.AssertionError, ~r/raised in its handler/, fn ->
          refute_crashed(operation, result, log)
        end
      end

      for action <- ~w(unauthorized ok) do
        operation = Enum.find(tool.operations, &(&1.action == action))
        {result, log} = with_log(fn -> dispatch(operation, arguments(operation)) end)
        assert refute_crashed(operation, result, log) == :ok
        assert refute_admission_refused(operation, result) == :ok
      end
    end)
  end

  test "the roster reaches every provider the table holds" do
    table = Grimoire.operations() |> Map.values() |> Enum.map(&elem(&1, 0)) |> MapSet.new()
    assert MapSet.subset?(table, MapSet.new(@providers))
  end

  # ---------------------------------------------------------------------------
  # The call
  # ---------------------------------------------------------------------------

  defp dispatch(%Prima.Operation{} = operation, args) do
    if :external in operation.planes do
      Grimoire.call_external(operation.tool, external_context(operation), args)
    else
      ctx = chain_context()

      Grimoire.call_in_chain(operation.tool, ctx, args, granting(operation),
        lineage: Cyfr.Test.AttemptFixtures.lineage!(ctx)
      )
    end
  end

  # A person with every permission, signed in interactively; a platform
  # operation's caller holds the operator capability.
  defp external_context(%Prima.Operation{scope: :platform}),
    do: Sanctum.TestContext.platform(permissions: [:*], platform_admin: true)

  defp external_context(_operation),
    do: %{Sanctum.TestContext.local() | permissions: MapSet.new([:*])}

  defp chain_context do
    Context.enter_guest(%Context{
      user_id: "action_coverage_user",
      athanor_id: Sanctum.TestContext.athanor_id(),
      scope: :athanor,
      permissions: MapSet.new([:*]),
      authenticated: true,
      request_id: "req_action_coverage"
    })
  end

  # A root authority whose ingress edge grants exactly this action.
  defp granting(%Prima.Operation{tool: tool, action: action}) do
    node = "formula:local.action-coverage"

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
          "edges" => %{"@ingress" => %{"tools" => ["#{tool}.#{action}"]}}
        }
      }
    }

    {:ok, blob} = Blob.parse(graph)

    {:ok, authority} =
      Authority.root(
        %{
          profile_id: "prof-action-coverage",
          consent_id: "consent-action-coverage",
          source_ref: node,
          kind: :owner,
          invoke_mode: :open_inert,
          activation: %{node => "sha256:action-coverage"}
        },
        blob,
        ceiling: Sanctum.Policy.Ceiling.platform_ceiling()
      )

    authority
  end

  # ---------------------------------------------------------------------------
  # Arguments from the declaration
  # ---------------------------------------------------------------------------

  defp arguments(%Prima.Operation{action: action, args: args}) do
    for %Prima.Arg{required: true} = arg <- args,
        into: %{"action" => action},
        do: {arg.name, placeholder(arg)}
  end

  defp placeholder(%Prima.Arg{enum: [first | _]}), do: first

  defp placeholder(%Prima.Arg{type: :string} = arg),
    do: String.duplicate("x", max(arg.min || 1, 1))

  defp placeholder(%Prima.Arg{type: :integer} = arg), do: arg.min || 1
  defp placeholder(%Prima.Arg{type: :number} = arg), do: arg.min || 1
  defp placeholder(%Prima.Arg{type: :boolean}), do: false
  defp placeholder(%Prima.Arg{type: :json}), do: %{}

  defp placeholder(%Prima.Arg{type: {:array, item}} = arg),
    do: List.duplicate(placeholder(item), arg.min || 0)

  defp placeholder(%Prima.Arg{type: {:record, fields}}) do
    for %Prima.Arg{required: true} = field <- fields,
        into: %{},
        do: {field.name, placeholder(field)}
  end

  defp placeholder(%Prima.Arg{type: {:map, _value}}), do: %{}

  # ---------------------------------------------------------------------------
  # What the call answered
  # ---------------------------------------------------------------------------

  defp refute_admission_refused(operation, {:error, %Prima.Refusal{stage: :admission} = refusal}) do
    flunk(
      "#{operation.tool}.#{operation.action} was refused before its handler ran " <>
        "(#{refusal.class}: #{refusal.message}); the call built from its declaration " <>
        "must reach the handler"
    )
  end

  defp refute_admission_refused(_operation, _result), do: :ok

  defp refute_crashed(operation, {:error, {tag, message}}, log)
       when tag in [:crashed, :exit, :uncertain] and is_binary(message) do
    if tag != :uncertain or message =~ ~r/crashed|exited/ do
      flunk("#{operation.tool}.#{operation.action} raised in its handler (#{message}):\n#{log}")
    end
  end

  defp refute_crashed(_operation, _result, _log), do: :ok
end
