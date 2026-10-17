# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Gate.HandlerUncertaintyTest do
  @moduledoc """
  A handler that stops without answering after it may have acted: its
  effect is not undone by its stopping, so unless its action is declared
  `recovery: :replay_safe` the call answers `{:error, {:uncertain, _}}`
  and its decision completes `uncertain` — on the external plane under
  either runner and in a chain alike, for a raise, an exit and a cancel
  that lands once it ran. A replay-safe read answers the ordinary typed
  error, and a call cancelled before its handler started answers
  cancelled and never runs.
  """

  use ExUnit.Case, async: false

  alias Prima.Authority
  alias Prima.Authority.Blob
  alias Sanctum.Catalog
  alias Sanctum.Context

  @tool "uncertainty_probe"
  @planted "planted-exception-text-7c41"

  defmodule Probe do
    @moduledoc false
    # Tells the process registered as `:uncertainty_probe_observer` that
    # it acted, then fails as `mode` says.
    @behaviour Prima.Provider

    alias Prima.{Arg, Operation}

    @impl true
    def service, do: "probe"

    @impl true
    def tools do
      args = [Arg.new("mode", :string, required: true, enum: ~w(raise exit block))]

      [
        Operation.tool([
          Operation.new("uncertainty_probe", "effect", "Act, then fail", args,
            kind: :write,
            planes: [:external, :in_chain]
          ),
          Operation.new("uncertainty_probe", "peek", "Read, then fail", args,
            kind: :read,
            planes: [:external, :in_chain],
            recovery: :replay_safe
          )
        ])
      ]
    end

    @impl true
    def handle("uncertainty_probe", _ctx, %{"action" => action, "mode" => mode}) do
      send(:uncertainty_probe_observer, {:acted, action, self()})

      case mode do
        "raise" -> raise "failed after its effect: planted-exception-text-7c41"
        "exit" -> exit({:after_its_effect, "planted-exception-text-7c41"})
        "block" -> Process.sleep(:infinity)
      end
    end
  end

  setup tags do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!(tags)
    Process.register(self(), :uncertainty_probe_observer)
    :ok
  end

  describe "the external plane" do
    for runner <- [:inline, :supervised] do
      @runner runner

      test "#{runner}: a write that acted and then raised answers uncertain, and its decision completes uncertain" do
        ctx = external_ctx()

        assert {:error, {:uncertain, message} = reason} =
                 call(ctx, "effect", "raise", runner: @runner)

        assert_received {:acted, "effect", _handler}
        assert message == "Tool #{@tool} crashed; its outcome is unknown"
        refute message =~ @planted
        assert %Prima.Refusal{class: :uncertain} = Sanctum.Refusals.classify(reason)

        assert %{admission: :admitted, completion: :uncertain, completion_class: :uncertain} =
                 decision = decision!(ctx)

        assert {decision.plane, decision.user_id, decision.athanor_id} ==
                 {:external, ctx.user_id, ctx.athanor_id}

        assert {decision.tool, decision.action} == {@tool, "effect"}
      end

      test "#{runner}: a write that acted and then exited answers uncertain" do
        ctx = external_ctx()

        assert {:error, {:uncertain, message}} = call(ctx, "effect", "exit", runner: @runner)
        assert_received {:acted, "effect", _handler}
        assert message == "Tool #{@tool} exited; its outcome is unknown"
        refute message =~ @planted
        assert %{completion: :uncertain} = decision!(ctx)
      end

      test "#{runner}: a replay-safe read that raised answers the ordinary crash" do
        ctx = external_ctx()

        assert {:error, {:crashed, "Tool #{@tool} crashed"}} =
                 call(ctx, "peek", "raise", runner: @runner)

        assert_received {:acted, "peek", _handler}
        assert %{completion: :failed, completion_class: :internal} = decision!(ctx)
      end
    end

    test "a supervised write cancelled once it ran answers uncertain, and one cancelled before it started answers cancelled" do
      ctx = external_ctx()
      handle = {__MODULE__, System.unique_integer([:positive])}
      test = self()

      Catalog.with_providers([Probe], fn ->
        caller =
          spawn(fn ->
            result =
              Sanctum.Gate.call_external(@tool, ctx, %{"action" => "effect", "mode" => "block"},
                runner: :supervised,
                cancel_handle: handle
              )

            send(test, {:result, result})
          end)

        assert_receive {:acted, "effect", handler}, 5_000
        ref = Process.monitor(handler)
        assert :ok = Sanctum.RunningTasks.cancel_handle(handle)
        assert_receive {:DOWN, ^ref, :process, ^handler, :cancelled}, 5_000

        assert_receive {:result,
                        {:error,
                         {:uncertain,
                          "Tool uncertainty_probe was cancelled; its outcome is unknown"}}},
                       5_000

        refute Process.alive?(caller)
      end)

      assert %{completion: :uncertain} = decision!(ctx)

      # Cancelled before the gate claims it: the handler never runs, so the
      # call is cancelled whatever its action may do.
      cancelled = {__MODULE__, System.unique_integer([:positive])}
      assert :ok = Sanctum.RunningTasks.claim(cancelled)
      assert :ok = Sanctum.RunningTasks.cancel_handle(cancelled)

      assert {:error, {:cancelled, "Tool uncertainty_probe was cancelled"}} =
               Catalog.with_providers([Probe], fn ->
                 Sanctum.Gate.call_external(
                   @tool,
                   external_ctx(),
                   %{"action" => "effect", "mode" => "raise"},
                   runner: :supervised,
                   cancel_handle: cancelled
                 )
               end)

      refute_received {:acted, _action, _handler}
      Sanctum.RunningTasks.release_handle(cancelled)
    end
  end

  describe "in a chain" do
    setup :chain

    test "a write that acted and then raised answers uncertain, and its decision completes uncertain",
         %{ctx: ctx, authority: authority, lineage: lineage} do
      assert {:error, {:uncertain, message}} = chain_call(ctx, authority, lineage, "effect")
      assert_received {:acted, "effect", _handler}
      assert message == "Tool #{@tool} crashed; its outcome is unknown"
      refute message =~ @planted

      assert %{admission: :admitted, completion: :uncertain, plane: :in_chain} = decision!(ctx)
    end

    test "a replay-safe read that raised answers the ordinary crash",
         %{ctx: ctx, authority: authority, lineage: lineage} do
      assert {:error, {:crashed, "Tool #{@tool} crashed"}} =
               chain_call(ctx, authority, lineage, "peek")

      assert_received {:acted, "peek", _handler}
      assert %{completion: :failed, plane: :in_chain} = decision!(ctx)
    end
  end

  defp external_ctx,
    do: %{Sanctum.TestContext.local() | request_id: Prima.UUID7.request_id()}

  defp call(ctx, action, mode, opts) do
    {result, _log} =
      ExUnit.CaptureLog.with_log(fn ->
        Catalog.with_providers([Probe], fn ->
          Sanctum.Gate.call_external(@tool, ctx, %{"action" => action, "mode" => mode}, opts)
        end)
      end)

    result
  end

  defp chain_call(ctx, authority, lineage, action) do
    {result, _log} =
      ExUnit.CaptureLog.with_log(fn ->
        Catalog.with_providers([Probe], fn ->
          Sanctum.Gate.call_in_chain(
            @tool,
            ctx,
            %{"action" => action, "mode" => "raise"},
            authority,
            lineage: lineage
          )
        end)
      end)

    result
  end

  defp decision!(ctx) do
    assert {:ok, [decision]} = Arca.DecisionLog.correlate(Context.actor(ctx), ctx.request_id)
    decision
  end

  # A chain whose authority grants both probe actions, calling from its
  # root's admitted execution and the attempt that owns it, as the host
  # stamps them.
  @node "formula:local.uncertainty"
  @athanor "ath_test"
  @user "uncertainty_user"

  defp chain(_context) do
    graph = %{
      "canonical" => "jcs-1",
      "nodes" => %{
        @node => %{
          "limits" => %{
            "timeout" => "1m",
            "max_memory_bytes" => 67_108_864,
            "max_request_size" => 1_048_576,
            "max_response_size" => 5_242_880,
            "rate_limit" => %{"requests" => 10_000, "window" => "1m"},
            "max_concurrent_tasks" => 10,
            "batch_timeout" => "1m"
          },
          "edges" => %{"@ingress" => %{"tools" => ["#{@tool}.effect", "#{@tool}.peek"]}}
        }
      }
    }

    {:ok, blob} = Blob.parse(graph)

    {:ok, authority} =
      Authority.root(
        %{
          profile_id: "prof-uncertainty",
          consent_id: "consent-uncertainty",
          source_ref: @node,
          kind: :owner,
          invoke_mode: :open_inert,
          activation: %{@node => "sha256:uncertainty"}
        },
        blob,
        ceiling: Sanctum.Policy.Ceiling.platform_ceiling()
      )

    {:ok, %{execution: root, attempt: root_attempt}} =
      Arca.Execution.admit(
        %{
          id: "exec_uncertainty_#{System.unique_integer([:positive])}",
          reference: "#{@node}:1.0.0",
          user_id: @user,
          athanor_id: @athanor,
          component_type: "formula",
          origin: :programmatic
        },
        reservation: %{budget_id: authority.budget.id, cap: 1},
        grant: Cyfr.Test.AttemptFixtures.grant(@athanor),
        verify: &Sanctum.ExecutionStanding.verify/1
      )

    ctx =
      Context.enter_guest(%Context{
        user_id: @user,
        athanor_id: @athanor,
        scope: :athanor,
        permissions: MapSet.new([:*]),
        authenticated: true,
        request_id: Prima.UUID7.request_id()
      })

    {:ok,
     ctx: ctx,
     authority: authority,
     lineage: %{parent_execution_id: root.id, attempt: root_attempt.attempt}}
  end
end
