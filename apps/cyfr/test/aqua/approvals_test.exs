# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.ApprovalsTest do
  @moduledoc """
  An approval opens only with the digest it is consumed by, and a card
  past its expiry is swept expired without running anything, its step
  closed denied with an answer for the model. No turn opens a card; each
  case lays its own (`card!/4`).
  """

  use ExUnit.Case, async: false

  alias Aqua.{Approvals, Tape}
  alias Arca.ThreadStorage, as: Threads

  @soul "agent:local.aqua"

  setup tags do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!(tags)

    test_path = Path.join(System.tmp_dir!(), "approvals_#{System.unique_integer([:positive])}")
    keys = [:base_path]
    prev = Map.new(keys, &{&1, Application.get_env(:arca, &1)})
    Application.put_env(:arca, :base_path, test_path)

    on_exit(fn ->
      File.rm_rf!(test_path)

      for {key, value} <- prev do
        if value,
          do: Application.put_env(:arca, key, value),
          else: Application.delete_env(:arca, key)
      end
    end)

    Cyfr.Test.SeedBundle.lay!(~w(claude files http), formulas: ~w(list-models))

    # A fill a call asks for runs in the background under the path and the
    # seed above. Registered last, it stops first: before the seed is
    # removed and the path put back.
    Cyfr.Test.Sandbox.stop_work_on_exit()

    ctx = Sanctum.TestContext.local(:prism)
    {thread, pins} = ready!(ctx)
    {:ok, ctx: ctx, thread: thread, pins: pins}
  end

  # The athanor `ctx` works in, made one a turn can run in: filled through
  # the explicit verb, the soul's consent among what it minted. Answers a thread there,
  # subscribed to, and the pins a turn of the soul starts with.
  defp ready!(ctx) do
    {:ok, athanor} = Sanctum.Tenancy.Athanors.get(ctx.athanor_id)
    {:ok, %{provisioned_at: %DateTime{}}} = Sanctum.Provisioning.provision(athanor, ctx)
    {:ok, [_soul]} = Arca.ConsentStorage.profiles(Sanctum.Context.actor(ctx), @soul)

    {:ok, %{profile_id: profile_id, consent_id: consent_id}} =
      Opus.authority_for(ctx, :default, @soul)

    {:ok, %{revision_digest: revision, capability_digest: capability}} =
      Compendium.AgentIndex.snapshot(ctx, "aqua")

    {:ok, thread} = Arca.Test.Days.thread(Sanctum.Context.actor(ctx))
    :ok = Aqua.Runner.subscribe(thread.id, ctx.athanor_id)

    pins = %{
      profile_id: profile_id,
      consent_id: consent_id,
      agent_revision_digest: revision,
      agent_capability_digest: capability
    }

    {thread, pins}
  end

  defp started!(ctx, thread, pins) do
    {:ok, %{turn: turn}} =
      Tape.accept(ctx, thread.id, %{
        message: %{author: ctx.user_id, sent_by: "person", content: "@aqua go"},
        turn: %{agent: "aqua", requested_by: ctx.user_id}
      })

    {:ok, %{execution: execution, attempt: attempt}} =
      Arca.Execution.admit(
        %{
          id: "exec_apr_#{System.unique_integer([:positive])}",
          reference: @soul,
          user_id: ctx.user_id,
          athanor_id: ctx.athanor_id,
          component_type: "agent",
          kind: "turn",
          turn_id: turn.id,
          origin: :interactive
        },
        reservation: %{budget_id: "bgt_#{System.unique_integer([:positive])}", cap: 4},
        grant: Cyfr.Test.AttemptFixtures.grant(ctx.athanor_id),
        verify: &Sanctum.ExecutionStanding.verify/1
      )

    {:ok, turn} =
      Tape.start_turn(
        ctx,
        turn,
        Map.merge(pins, %{
          root_execution_id: execution.id,
          attempt: attempt.attempt,
          agent_mode: "auto",
          recovery_limit: Aqua.Runner.RecoveryPolicy.max_attempts()
        })
      )

    turn
  end

  # A card for one call, laid on the turn's rows: the proposal digested,
  # the intent on the card row.
  defp card!(ctx, turn, call, opts) do
    {:ok, model_step} = Tape.record_model_intent(ctx, turn, %{})
    proposal = %{"tool" => call.tool, "action" => call.action, "args" => call.args}

    {:ok, %{calls: [%{step: step}]}} =
      Tape.record_response(ctx, turn, model_step, %{
        text: nil,
        tool_calls: [
          %{
            tool_call_id: Keyword.get(opts, :call_id, "c1"),
            name: "#{call.tool}.#{call.action}",
            tool: call.tool,
            action: call.action,
            arguments: call.args,
            kind: Keyword.get(opts, :kind, "write"),
            step_kind: Keyword.get(opts, :step_kind, "tool")
          }
        ]
      })

    intent = %{
      "kind" => "request_approval",
      "title" => "#{call.tool}.#{call.action}",
      "action_kind" => Keyword.get(opts, :kind, "write"),
      "standing" => Keyword.get(opts, :standing),
      "tool_call_id" => Keyword.get(opts, :call_id, "c1"),
      "proposal" => proposal,
      "sources" => Prima.Source.to_json_list(Keyword.get(opts, :sources, []))
    }

    {:ok, %{approval: approval}} =
      Tape.open_approval(ctx, turn, step, %{
        proposal_digest: Keyword.get(opts, :digest, Aqua.Loop.Policy.proposal_digest(proposal)),
        expires_at: Keyword.get(opts, :expires_at),
        card: %{content: "#{call.tool}.#{call.action}?", payload: %{"intent" => intent}}
      })

    %{approval: approval, step: step}
  end

  @keep %{tool: "notes", action: "keep", args: %{"name" => "n", "content" => "c"}}

  test "an approval opens only with the digest it is consumed by", %{
    ctx: ctx,
    thread: thread,
    pins: pins
  } do
    turn = started!(ctx, thread, pins)
    {:ok, model_step} = Tape.record_model_intent(ctx, turn, %{})

    {:ok, %{calls: [%{step: step}]}} =
      Tape.record_response(ctx, turn, model_step, %{
        text: nil,
        tool_calls: [%{tool_call_id: "c1", name: "notes", tool: "notes", action: "keep"}]
      })

    for digest <- [nil, ""] do
      assert {:error, :proposal_digest_required} =
               Tape.open_approval(ctx, turn, step, %{proposal_digest: digest, card: %{}})
    end

    refute Approvals.proposal?(%{proposal_digest: ""}, %{"tool" => "notes"})
    refute Approvals.proposal?(%{proposal_digest: nil}, %{"tool" => "notes"})
  end

  test "a card past its expiry is swept expired, and one still open stays pending", %{
    ctx: ctx,
    thread: thread,
    pins: pins
  } do
    turn = started!(ctx, thread, pins)
    past = DateTime.add(DateTime.utc_now(), -60, :second)
    %{approval: swept} = card!(ctx, turn, @keep, expires_at: past)

    %{approval: live} =
      card!(ctx, turn, @keep, expires_at: DateTime.add(DateTime.utc_now(), 3600))

    assert {:ok, 1} = Approvals.expire_due(ctx)
    assert {:ok, %{status: "expired"}} = Tape.approval(ctx, swept.id)
    assert {:ok, %{status: "pending"}} = Tape.approval(ctx, live.id)
    assert {:ok, 0} = Approvals.expire_due(ctx)
  end

  test "an expired card closes its step denied and leaves the model an answer", %{
    ctx: ctx,
    thread: thread,
    pins: pins
  } do
    turn = started!(ctx, thread, pins)
    past = DateTime.add(DateTime.utc_now(), -60, :second)
    %{step: step} = card!(ctx, turn, @keep, expires_at: past)

    assert {:ok, 1} = Approvals.expire_due(ctx)

    # The step is closed, not left open: a card nobody decided must not
    # leave the call waiting for an answer that is never coming.
    assert {:ok, %{outcome: "denied", dispatch_state: "closed"}} = Tape.step(ctx, step.id)

    # And the model is told, in the row it reads as the call's result, that
    # the action did not run — the denial it observes instead of waiting.
    rows = Threads.latest_messages(Sanctum.Context.actor(ctx), thread.id, 50)
    result = Enum.find(rows, &(&1.kind == "tool_result" and payload_of(&1)["step_id"] == step.id))

    assert result, "the expired call left no result for the model to read"
    assert result.content =~ "expired"
  end

  defp payload_of(%{payload: payload}) when is_map(payload), do: payload
  defp payload_of(%{payload: json}) when is_binary(json), do: Jason.decode!(json)
  defp payload_of(_), do: %{}
end
