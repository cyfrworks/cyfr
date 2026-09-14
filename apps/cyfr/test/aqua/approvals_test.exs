# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.ApprovalsTest do
  @moduledoc """
  A card is decided once, from its own rows: the standing answer lands
  with the decision, a replay answers the first decision, a moved
  proposal or an expiry settles the card without running anything, and a
  turn whose pins moved is failed rather than resumed. An approved launch
  is consumed as the person who approved it, or not at all.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Aqua.{Approvals, Launch, Tape}
  alias Arca.ThreadStorage, as: Threads
  alias Sanctum.Consent.{Bootstrap, Source}
  alias Sanctum.Tenancy.{Members, Users}

  @moduletag :requires_opus_modules

  @seed_root Path.expand("../../../../seed", __DIR__)
  @soul "agent:local.aqua"

  setup do
    Arca.Cache.init()
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    test_path = Path.join(System.tmp_dir!(), "approvals_#{System.unique_integer([:positive])}")
    keys = [:base_path, :seed_path, :consent_source]
    prev = Map.new(keys, &{&1, Application.get_env(:cyfr, &1)})
    Application.put_env(:cyfr, :base_path, test_path)
    Application.put_env(:cyfr, :seed_path, @seed_root)
    Application.put_env(:cyfr, :consent_source, Source.DB)

    on_exit(fn ->
      File.rm_rf!(test_path)

      for {key, value} <- prev do
        if value,
          do: Application.put_env(:cyfr, key, value),
          else: Application.delete_env(:cyfr, key)
      end
    end)

    ctx = Sanctum.TestContext.local()
    :ok = Sanctum.TestContext.shipped!(ctx.athanor_id)
    {:ok, %{errors: 0}} = Compendium.AutoIndexer.scan(ctx: ctx)
    {:ok, _} = Compendium.AgentIndex.sync(ctx)
    {:ok, %{minted: minted}} = Bootstrap.run(ctx)
    assert @soul in minted

    {:ok, %{profile_id: profile_id, consent_id: consent_id}} =
      Cyfr.Execution.authority_for(ctx, :default, @soul)

    {:ok, %{capability_digest: capability}} = Compendium.AgentIndex.snapshot(ctx, "aqua")

    {:ok, thread} = Threads.create(ctx)
    :ok = Phoenix.PubSub.subscribe(Emissary.PubSub, Tape.topic(ctx, thread.id))

    pins = %{profile_id: profile_id, consent_id: consent_id, agent_capability_digest: capability}
    {:ok, ctx: ctx, thread: thread, pins: pins}
  end

  defp started!(ctx, thread, pins) do
    {:ok, %{turn: turn}} =
      Tape.accept(ctx, thread.id, %{
        message: %{author: ctx.user_id, content: "@aqua go"},
        turn: %{orchestrator: "aqua", requested_by: ctx.user_id}
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
          turn_id: turn.id
        },
        reservation: %{budget_id: "bgt_#{System.unique_integer([:positive])}", cap: 4}
      )

    {:ok, turn} =
      Tape.start_turn(
        ctx,
        turn,
        Map.merge(pins, %{root_execution_id: execution.id, attempt: attempt.attempt})
      )

    turn
  end

  # A card for one call, as the loop opens it: the proposal digested, the
  # intent on the card row.
  defp card!(ctx, turn, call, opts \\ []) do
    {:ok, model_step} = Tape.record_model_intent(ctx, turn, %{})
    proposal = %{"tool" => call.tool, "action" => call.action, "args" => call.args}

    {:ok, %{calls: [%{step: step}]}} =
      Tape.record_response(ctx, turn, model_step, %{
        text: nil,
        tool_calls: [
          %{
            tool_call_id: "c1",
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
      "tool_call_id" => "c1",
      "proposal" => proposal
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
  @wipe %{tool: "files", action: "delete", args: %{"path" => "data/x"}}

  test "approving once resumes the step, and deciding again answers the first decision", %{
    ctx: ctx,
    thread: thread,
    pins: pins
  } do
    turn = started!(ctx, thread, pins)
    %{approval: approval, step: step} = card!(ctx, turn, @keep, standing: "thread")

    assert {:ok,
            %{decision: "approved", resolution_kind: "continue", replayed: false, pending: 0}} =
             Approvals.resolve(ctx, approval.id, %{decision: :approved})

    assert_receive {:thread, _, {:approval_resolved, %{approval_id: aid, decision: "approved"}}}

    assert aid == approval.id
    assert {:ok, %{dispatch_state: "proposed", kind: "tool"}} = Tape.step(ctx, step.id)
    assert {:ok, %{status: "approved", decided_by: decided_by}} = Tape.approval(ctx, approval.id)
    assert decided_by == ctx.user_id
    assert {:ok, []} = Aqua.ToolGrants.for_thread(ctx, thread.id, "aqua")

    assert {:ok, %{decision: "approved", replayed: true}} =
             Approvals.resolve(ctx, approval.id, %{decision: :declined, scope: :never})

    assert {:ok, %{dispatch_state: "proposed"}} = Tape.step(ctx, step.id)
    assert {:error, :not_found} = Approvals.resolve(ctx, "apr_nothing", %{decision: :approved})
  end

  test "a standing answer lands with the decision, and a refused scope decides nothing", %{
    ctx: ctx,
    thread: thread,
    pins: pins
  } do
    turn = started!(ctx, thread, pins)
    %{approval: approval} = card!(ctx, turn, @keep, standing: "thread")

    assert {:error, {:scope_not_permitted, :thread_only}} =
             Approvals.resolve(ctx, approval.id, %{decision: :approved, scope: :always})

    assert {:ok, %{status: "pending"}} = Tape.approval(ctx, approval.id)

    assert {:ok, %{decision: "approved"}} =
             Approvals.resolve(ctx, approval.id, %{decision: :approved, scope: :thread})

    assert {:ok, [%{tool: "notes", action: "keep", effect: "allow", scope: "thread"}]} =
             Aqua.ToolGrants.for_thread(ctx, thread.id, "aqua")

    %{approval: destructive} = card!(ctx, turn, @wipe, kind: "destructive")

    assert {:error, {:scope_not_permitted, "destructive"}} =
             Approvals.resolve(ctx, destructive.id, %{decision: :approved, scope: :thread})
  end

  test "declining closes the step denied with a tool result, and never records a deny", %{
    ctx: ctx,
    thread: thread,
    pins: pins
  } do
    turn = started!(ctx, thread, pins)
    %{approval: approval, step: step} = card!(ctx, turn, @wipe, kind: "destructive")

    assert {:ok, %{decision: "declined", resolution_kind: "denied"}} =
             Approvals.resolve(ctx, approval.id, %{
               decision: :declined,
               scope: :never,
               reason: "not that"
             })

    assert {:ok, %{dispatch_state: "closed", outcome: "denied", result_message_id: rid}} =
             Tape.step(ctx, step.id)

    assert {:ok, %{kind: "tool_result", content: "declined: not that"} = row} =
             Tape.message(ctx, rid)

    assert Threads.payload(row)["is_error"] == true

    assert {:ok, [%{tool: "files", action: "delete", effect: "deny", scope: "agent"}]} =
             Aqua.ToolGrants.for_thread(ctx, thread.id, "aqua")
  end

  test "a card whose proposal no longer matches its approval settles as an error", %{
    ctx: ctx,
    thread: thread,
    pins: pins
  } do
    turn = started!(ctx, thread, pins)
    %{approval: approval, step: step} = card!(ctx, turn, @keep, digest: "sha256:elsewhere")

    assert {:ok, %{decision: "error"}} =
             Approvals.resolve(ctx, approval.id, %{decision: :approved})

    assert {:ok, %{dispatch_state: "closed", outcome: "denied"}} = Tape.step(ctx, step.id)
    assert {:ok, %{status: "running"}} = Tape.turn(ctx, turn.id)
  end

  test "a card past its expiry settles expired, decided or swept", %{
    ctx: ctx,
    thread: thread,
    pins: pins
  } do
    turn = started!(ctx, thread, pins)
    past = DateTime.add(DateTime.utc_now(), -60, :second)
    %{approval: decided} = card!(ctx, turn, @keep, expires_at: past)
    %{approval: swept} = card!(ctx, turn, @keep, expires_at: past)

    %{approval: live} =
      card!(ctx, turn, @keep, expires_at: DateTime.add(DateTime.utc_now(), 3600))

    assert {:ok, %{decision: "expired", resolution_kind: "expired"}} =
             Approvals.resolve(ctx, decided.id, %{decision: :approved})

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
    %{approval: approval, step: step} = card!(ctx, turn, @keep, expires_at: past)

    assert {:ok, 1} = Approvals.expire_due(ctx)

    # The step is closed, not left open: a card nobody decided must not
    # leave the call waiting for an answer that is never coming.
    assert {:ok, %{outcome: "denied", dispatch_state: "closed"}} = Tape.step(ctx, step.id)

    # And the model is told, in the row it reads as the call's result, that
    # the action did not run — the denial it observes instead of waiting.
    rows = Tape.latest_messages(ctx, thread.id, 50)
    result = Enum.find(rows, &(&1.kind == "tool_result" and payload_of(&1)["step_id"] == step.id))

    assert result, "the expired call left no result for the model to read"
    assert result.content =~ "expired"
  end

  defp payload_of(%{payload: payload}) when is_map(payload), do: payload
  defp payload_of(%{payload: json}) when is_binary(json), do: Jason.decode!(json)
  defp payload_of(_), do: %{}

  test "a turn whose consent or agent moved is failed, never resumed", %{
    ctx: ctx,
    thread: thread,
    pins: pins
  } do
    moved = started!(ctx, thread, %{pins | consent_id: "consent_elsewhere"})
    %{approval: approval} = card!(ctx, moved, @keep)

    assert {:error, :turn_superseded} =
             Approvals.resolve(ctx, approval.id, %{decision: :approved})

    assert {:ok, %{status: "error"}} = Tape.approval(ctx, approval.id)
    assert {:ok, %{status: "failed"}} = Tape.turn(ctx, moved.id)

    {:ok, other} = Threads.create(ctx)
    changed = started!(ctx, other, %{pins | agent_capability_digest: "sha256:other"})
    %{approval: approval} = card!(ctx, changed, @keep)

    assert {:error, :turn_superseded} =
             Approvals.resolve(ctx, approval.id, %{decision: :approved})

    assert {:ok, %{status: "failed"}} = Tape.turn(ctx, changed.id)
  end

  test "an approved launch is consumed as its approver, or not at all", %{
    ctx: ctx,
    thread: thread,
    pins: pins
  } do
    n = System.unique_integer([:positive])

    {:ok, approver} =
      Users.upsert_from_provider(%{
        id: "github|https://github.com|approver#{n}",
        provider: "github",
        email: "approver#{n}@example.com",
        verified: true,
        name: "Approver"
      })

    {:ok, _} = Members.ensure(approver.id, scope: "athanor", athanor_id: ctx.athanor_id)
    approver_ctx = %{ctx | user_id: approver.id}

    turn = started!(ctx, thread, pins)

    launch = %{
      tool: "execution",
      action: "run",
      args: %{"reference" => "formula:local.nowhere:1.0.0", "input" => %{}}
    }

    %{approval: approval, step: step} =
      card!(ctx, turn, launch, kind: "execute", step_kind: "launch")

    assert {:ok, %{decision: "approved", resolution_kind: "launch"}} =
             Approvals.resolve(approver_ctx, approval.id, %{decision: :approved})

    assert {:ok, %{kind: "launch", dispatch_state: "proposed"} = step} = Tape.step(ctx, step.id)
    assert {:ok, %{decided_by: decided_by}} = Tape.approval(ctx, approval.id)
    assert decided_by == approver.id

    # The application is asked for as the approver: an unknown reference
    # is the execution tool's own refusal, not a plane or a seat.
    assert {:error, reason} = Launch.dispatch(ctx, step)
    refute match?({:approver_unavailable, _}, reason)

    # A shipped application roots its own consent and runs as the approver:
    # whatever it answers, the execution row is the approver's.
    real = %{
      tool: "execution",
      action: "run",
      args: %{"reference" => "formula:local.list-models", "input" => %{}}
    }

    %{approval: approval_real, step: step_real} =
      card!(ctx, turn, real, kind: "execute", step_kind: "launch")

    {:ok, _} = Approvals.resolve(approver_ctx, approval_real.id, %{decision: :approved})
    {:ok, step_real} = Tape.step(ctx, step_real.id)
    dispatched = Launch.dispatch(ctx, step_real)

    launched =
      Arca.Repo.all(
        from(e in Arca.Execution,
          where:
            e.athanor_id == ^ctx.athanor_id and
              like(e.reference, "formula:local.list-models%")
        )
      )

    assert [%{user_id: launched_by}] = launched, "launch answered #{inspect(dispatched)}"
    assert launched_by == approver.id

    # A hand is not a launch, whatever the card said.
    hand = %{
      tool: "execution",
      action: "run",
      args: %{
        "reference" => "catalyst:local.files",
        "input" => %{"action" => "list", "path" => "data"}
      }
    }

    %{approval: approval2, step: step2} =
      card!(ctx, turn, hand, kind: "execute", step_kind: "launch")

    {:ok, _} = Approvals.resolve(approver_ctx, approval2.id, %{decision: :approved})
    {:ok, step2} = Tape.step(ctx, step2.id)
    assert {:error, {:invalid_argument, msg}} = Launch.dispatch(ctx, step2)
    assert msg =~ "hand"

    # A step nobody approved launches nothing.
    %{step: step3} = card!(ctx, turn, launch, kind: "execute", step_kind: "launch")
    assert {:error, :not_approved} = Launch.dispatch(ctx, step3)

    # A person no longer seated launches nothing either.
    {:ok, _} = Users.deny(approver)
    assert {:error, {:approver_unavailable, :denied}} = Launch.dispatch(ctx, step)
  end

  describe "ttl_seconds/1" do
    test "is the estate's setting in hours, else the configured default, never a bad value" do
      ctx = Sanctum.TestContext.local()
      assert Approvals.ttl_seconds(ctx) == 24 * 3600

      {:ok, athanor} = Sanctum.Tenancy.Athanors.get(ctx.athanor_id)

      {:ok, _} =
        Sanctum.Tenancy.Athanors.put_settings(athanor, %{"approvals" => %{"expiry_hours" => 2}})

      assert Approvals.ttl_seconds(ctx) == 7200

      {:ok, athanor} = Sanctum.Tenancy.Athanors.get(ctx.athanor_id)

      {:ok, _} =
        Sanctum.Tenancy.Athanors.put_settings(athanor, %{"approvals" => %{"expiry_hours" => "x"}})

      assert Approvals.ttl_seconds(ctx) == 24 * 3600

      {:ok, athanor} = Sanctum.Tenancy.Athanors.get(ctx.athanor_id)

      {:ok, _} =
        Sanctum.Tenancy.Athanors.put_settings(athanor, %{"approvals" => %{"expiry_hours" => 0}})

      assert Approvals.ttl_seconds(ctx) == 24 * 3600
    end
  end
end
