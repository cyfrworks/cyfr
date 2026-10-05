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
  alias Aqua.Loop.{Binding, Policy}
  alias Arca.ThreadStorage, as: Threads
  alias Cyfr.Bus.ThreadEvent
  alias Sanctum.Consent.{Bootstrap}
  alias Sanctum.Tenancy.{Members, Users}

  @seed_root Path.expand("../../../../seed", __DIR__)
  @soul "agent:local.aqua"
  @math_wasm Path.expand("../support/test_wasm/math.wasm", __DIR__)

  setup tags do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!(tags)

    test_path = Path.join(System.tmp_dir!(), "approvals_#{System.unique_integer([:positive])}")
    keys = [:base_path, :seed_path]
    prev = Map.new(keys, &{&1, Application.get_env(:arca, &1)})
    Application.put_env(:arca, :base_path, test_path)
    Application.put_env(:arca, :seed_path, @seed_root)

    on_exit(fn ->
      File.rm_rf!(test_path)

      for {key, value} <- prev do
        if value,
          do: Application.put_env(:arca, key, value),
          else: Application.delete_env(:arca, key)
      end
    end)

    ctx = Sanctum.TestContext.local(:prism)
    :ok = Sanctum.TestContext.shipped!(ctx.athanor_id)
    {:ok, %{errors: 0}} = Compendium.AutoIndexer.scan(ctx: ctx)
    {:ok, _} = Compendium.AgentIndex.sync(ctx)
    {:ok, %{minted: minted}} = Bootstrap.run(ctx)
    assert @soul in minted

    {:ok, %{profile_id: profile_id, consent_id: consent_id}} =
      Crucible.authority_for(ctx, :default, @soul)

    {:ok, %{capability_digest: capability}} = Compendium.AgentIndex.snapshot(ctx, "aqua")

    {:ok, thread} = Threads.create(Sanctum.Context.actor(ctx))
    :ok = Aqua.Runner.subscribe(thread.id, ctx.athanor_id)

    pins = %{profile_id: profile_id, consent_id: consent_id, agent_capability_digest: capability}
    {:ok, ctx: ctx, thread: thread, pins: pins}
  end

  defp started!(ctx, thread, pins) do
    {:ok, %{turn: turn}} =
      Tape.accept(ctx, thread.id, %{
        message: %{author: ctx.user_id, content: "@aqua go"},
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
          recovery_limit: Aqua.Runner.RecoveryPolicy.max_attempts()
        })
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

    assert_receive %ThreadEvent{
      kind: :approval_resolved,
      data: %{approval_id: aid, decision: "approved"}
    }

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

  test "an unbounded thread-scope allow over approval.resolve stands, judged under the turn's origin",
       %{ctx: ctx, thread: thread, pins: pins} do
    turn = started!(ctx, thread, pins)
    %{approval: approval} = card!(ctx, turn, @keep, standing: "thread")

    # Sent over the API: the approver's line is programmatic, and the pin
    # check reads the turn's grant under the interactive origin its row
    # stores. An allow for this chat with no lifecycle, deadline or
    # constraint is narrower than the agent-scope answer and stays
    # accepted, though the console offers only its five bounded choices.
    api = Sanctum.TestContext.via(ctx, :api)

    assert {:ok, _resolved} =
             Grimoire.call_external("approval", api, %{
               "action" => "resolve",
               "approval" => approval.id,
               "decision" => "approve",
               "scope" => "thread"
             })

    assert {:ok,
            [
              %{
                effect: "allow",
                scope: "thread",
                lifecycle_kind: nil,
                expires_at: nil,
                constraint: nil
              }
            ]} = Aqua.ToolGrants.for_thread(ctx, thread.id, "aqua")
  end

  describe "a bounded standing approval" do
    @write %{
      tool: "files",
      action: "write",
      args: %{"path" => "data/other/x.md", "content" => "x"}
    }
    @notes %{kind: "storage_path", patterns: ["data/notes/"]}

    defp soon, do: DateTime.add(DateTime.utc_now(), 3600, :second) |> DateTime.truncate(:second)

    defp resolution(ctx, approval_id) do
      {:ok, %{resolution: resolution}} = Tape.approval(ctx, approval_id)
      if is_binary(resolution), do: Jason.decode!(resolution), else: resolution
    end

    test "carries its lifecycle and deadline from the card's own turn into its row", %{
      ctx: ctx,
      thread: thread,
      pins: pins
    } do
      turn = started!(ctx, thread, pins)
      until = soon()
      %{approval: approval} = card!(ctx, turn, @keep, standing: "thread")

      assert {:ok, %{decision: "approved"}} =
               Approvals.resolve(ctx, approval.id, %{
                 decision: :approved,
                 scope: :thread,
                 lifecycle: :turn,
                 until: until
               })

      turn_id = turn.id

      assert {:ok,
              [
                %{
                  tool: "notes",
                  action: "keep",
                  effect: "allow",
                  scope: "thread",
                  lifecycle_kind: "turn",
                  lifecycle_id: ^turn_id,
                  constraint: nil
                } = row
              ]} = Aqua.ToolGrants.for_thread(ctx, thread.id, "aqua")

      assert DateTime.compare(row.expires_at, until) == :eq

      assert %{"scope" => "thread", "lifecycle" => "turn", "until" => spelled} =
               resolution(ctx, approval.id)

      assert {:ok, ^until, 0} = DateTime.from_iso8601(spelled)

      # The run it ends with is the turn's root, read from the turn.
      %{approval: again} = card!(ctx, turn, @keep, standing: "thread")

      {:ok, _} =
        Approvals.resolve(ctx, again.id, %{
          decision: :approved,
          scope: :thread,
          lifecycle: :execution
        })

      root = turn.root_execution_id

      assert {:ok, [%{lifecycle_kind: "execution", lifecycle_id: ^root}]} =
               Aqua.ToolGrants.for_thread(ctx, thread.id, "aqua")
    end

    test "carries a constraint for an action that names its resource", %{
      ctx: ctx,
      thread: thread,
      pins: pins
    } do
      turn = started!(ctx, thread, pins)

      # What put files.write in the soul's policy: an earlier answer, for
      # this run and data/notes/ alone, at agent scope.
      {:ok, _} =
        Aqua.ToolGrants.put(ctx, %{
          scope: "agent",
          effect: "allow",
          agent_name: "aqua",
          tool: "files",
          action: "write",
          lifecycle_kind: "execution",
          lifecycle_id: turn.root_execution_id,
          constraint: @notes
        })

      %{approval: approval} = card!(ctx, turn, @write)
      other = %{kind: "storage_path", patterns: ["data/other/"]}

      assert {:ok, %{decision: "approved"}} =
               Approvals.resolve(ctx, approval.id, %{
                 decision: :approved,
                 scope: :thread,
                 lifecycle: :turn,
                 constraint: other
               })

      {:ok, rows} = Aqua.ToolGrants.for_thread(ctx, thread.id, "aqua")

      assert %{constraint: ^other, lifecycle_kind: "turn"} =
               Enum.find(rows, &(&1.scope == "thread"))

      assert %{"constraint" => %{"kind" => "storage_path"}} = resolution(ctx, approval.id)

      place = fn path ->
        %{
          agent_name: "aqua",
          thread_id: thread.id,
          tool: "files",
          action: "write",
          args: %{"path" => path},
          turn_id: turn.id,
          execution_id: turn.root_execution_id
        }
      end

      assert Sanctum.ToolGrants.admits?(ctx, place.("data/other/y.md"))
      assert Sanctum.ToolGrants.admits?(ctx, place.("data/notes/y.md"))
      refute Sanctum.ToolGrants.admits?(ctx, place.("data/elsewhere/y.md"))
    end

    test "a bound the answer may not carry is refused, and the card stays open", %{
      ctx: ctx,
      thread: thread,
      pins: pins
    } do
      turn = started!(ctx, thread, pins)
      %{approval: approval} = card!(ctx, turn, @keep, standing: "thread")
      past = DateTime.add(DateTime.utc_now(), -60, :second)

      for {choice, reason} <- [
            {%{decision: :approved, scope: :thread, constraint: @notes}, :no_resource},
            {%{decision: :approved, scope: :once, lifecycle: :turn}, :bounds_without_standing},
            {%{decision: :approved, scope: :thread, lifecycle: :schedule}, :no_schedule},
            {%{decision: :approved, scope: :thread, lifecycle: :forever}, :invalid_lifecycle},
            {%{decision: :approved, scope: :thread, until: past}, :deadline_passed},
            {%{decision: :declined, scope: :never, until: soon()}, :bounded_deny},
            {%{decision: :declined, scope: :never, lifecycle: :turn}, :bounded_deny},
            {%{decision: :declined, scope: :never, constraint: @notes}, :bounded_deny},
            {%{decision: :declined, scope: :once, until: soon()}, :bounds_without_standing}
          ] do
        assert {:error, {:scope_not_permitted, ^reason}} =
                 Approvals.resolve(ctx, approval.id, choice),
               "#{inspect(choice)} was not refused as #{reason}"

        assert {:ok, %{status: "pending"}} = Tape.approval(ctx, approval.id)
      end

      assert {:ok, []} = Aqua.ToolGrants.for_thread(ctx, thread.id, "aqua")

      # A constraint the store would refuse is refused by the rule, before
      # the decision's transaction: a pattern twice, more than 64, or a
      # wildcard. What put files.write in the policy is an earlier answer
      # for this run and data/notes/ alone.
      {:ok, _} =
        Aqua.ToolGrants.put(ctx, %{
          scope: "agent",
          effect: "allow",
          agent_name: "aqua",
          tool: "files",
          action: "write",
          lifecycle_kind: "execution",
          lifecycle_id: turn.root_execution_id,
          constraint: @notes
        })

      %{approval: write} = card!(ctx, turn, @write)

      for patterns <- [["data/a/", "data/a/"], Enum.map(1..65, &"data/#{&1}.md"), ["*"]] do
        assert {:error, {:scope_not_permitted, :invalid_constraint}} =
                 Approvals.resolve(ctx, write.id, %{
                   decision: :approved,
                   scope: :thread,
                   constraint: %{kind: "storage_path", patterns: patterns}
                 }),
               "#{inspect(patterns)} was not refused"

        assert {:ok, %{status: "pending"}} = Tape.approval(ctx, write.id)
      end

      assert {:ok, [%{scope: "agent", constraint: @notes}]} =
               Aqua.ToolGrants.for_thread(ctx, thread.id, "aqua")

      # A destructive action takes no standing allow, bounded or not.
      %{approval: destructive} = card!(ctx, turn, @wipe, kind: "destructive")

      assert {:error, {:scope_not_permitted, "destructive"}} =
               Approvals.resolve(ctx, destructive.id, %{
                 decision: :approved,
                 scope: :thread,
                 lifecycle: :turn
               })

      assert {:ok, %{status: "pending"}} = Tape.approval(ctx, destructive.id)
    end
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
    %{step: step} = card!(ctx, turn, @keep, expires_at: past)

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

    {:ok, other} = Threads.create(Sanctum.Context.actor(ctx))
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

    # A launch continues under the origin its turn's row stores: this
    # turn was sent from the console.
    turn = started!(%{ctx | origin: :interactive}, thread, pins)

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
        from(e in Arca.Schemas.Execution,
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

    # A card rewritten after its approval launches nothing.
    %{approval: approval4, step: step4} =
      card!(ctx, turn, launch, kind: "execute", step_kind: "launch")

    {:ok, _} = Approvals.resolve(approver_ctx, approval4.id, %{decision: :approved})
    {:ok, card} = Tape.message(ctx, approval4.message_id)

    rewritten =
      card
      |> Threads.payload()
      |> put_in(["intent", "proposal", "args", "input"], %{"other" => true})
      |> Jason.encode!()

    {1, _} =
      Arca.Repo.update_all(
        from(m in Arca.Schemas.Message, where: m.id == ^card.id),
        set: [payload: rewritten]
      )

    {:ok, step4} = Tape.step(ctx, step4.id)
    assert {:error, {:invalid_argument, changed}} = Launch.dispatch(ctx, step4)
    assert changed =~ "no longer matches"

    # A step nobody approved launches nothing.
    %{step: step3} = card!(ctx, turn, launch, kind: "execute", step_kind: "launch")
    assert {:error, :not_approved} = Launch.dispatch(ctx, step3)

    # A person no longer seated launches nothing either.
    {:ok, _} = Users.deny(approver)
    assert {:error, {:approver_unavailable, :denied}} = Launch.dispatch(ctx, step)
  end

  describe "a launch's approval" do
    @launch %{
      tool: "execution",
      action: "run",
      args: %{"reference" => "formula:local.nowhere:1.0.0", "input" => %{}}
    }

    test "takes no standing answer, bounded or not, over the approval operation, and once stands",
         %{ctx: ctx, thread: thread, pins: pins} do
      turn = started!(ctx, thread, pins)
      %{approval: approval} = card!(ctx, turn, @launch, kind: "execute", step_kind: "launch")
      sentence = Aqua.ToolGrants.refusal_message({:scope_not_permitted, :never_standing})
      until = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()

      for scope <- ["thread", "always"],
          bounds <- [
            %{},
            %{"lifecycle" => "turn"},
            %{"until" => until},
            %{"constraint" => %{"kind" => "vault_entry", "patterns" => ["vlt_work-1"]}}
          ] do
        assert {:error, {:invalid_argument, ^sentence}} =
                 Aqua.Providers.Approval.handle(
                   "approval",
                   ctx,
                   Map.merge(
                     %{
                       "action" => "resolve",
                       "approval" => approval.id,
                       "decision" => "approve",
                       "scope" => scope
                     },
                     bounds
                   )
                 ),
               "#{scope} #{inspect(bounds)} stood on a launch"

        assert {:ok, %{status: "pending"}} = Tape.approval(ctx, approval.id)
      end

      assert {:ok, []} = Aqua.ToolGrants.for_thread(ctx, thread.id, "aqua")

      # One approval for the one launch is unaffected.
      assert {:ok, %{decision: "approved", resolution_kind: "launch"}} =
               Aqua.Providers.Approval.handle("approval", ctx, %{
                 "action" => "resolve",
                 "approval" => approval.id,
                 "decision" => "approve",
                 "scope" => "once"
               })

      assert {:ok, []} = Aqua.ToolGrants.for_thread(ctx, thread.id, "aqua")
    end

    test "resolves the account a launch names before it asks, and binds its entry in the card",
         %{ctx: ctx} do
      %{ref: ref, work: work} = named_app!(ctx)
      versioned = ref <> ":1.0.0"

      launch = fn args ->
        {:ok, call} = Binding.resolve("execution.run", Map.put(args, "reference", versioned))
        call
      end

      named = launch.(%{"input" => %{}, "connection" => "Work"})
      work_id = work.id

      # Whatever the agent's own policy says, a launch asks: a launch runs
      # only from an approved card.
      for mode <- ["ask", "auto"] do
        assert {:ask, %{vault_entry: ^work_id}} =
                 Policy.decide(named, %{"execution.run" => mode}, ctx: ctx)

        assert :ask =
                 Policy.decide(launch.(%{"input" => %{}}), %{"execution.run" => mode}, ctx: ctx)
      end

      assert {:deny, _} = Policy.decide(named, %{"execution.run" => "deny"}, ctx: ctx)

      # Spelled in another case it is the same account: Work's entry, under
      # the name its binding stores.
      lower = launch.(%{"input" => %{}, "connection" => "work"})

      assert {:ask, %{vault_entry: ^work_id, name: "Work"} = same} =
               Policy.decide(lower, %{"execution.run" => "ask"}, ctx: ctx)

      # The card binds the entry the name resolved to, beside the call, and
      # takes no standing answer.
      {:ask, account} = Policy.decide(named, %{"execution.run" => "ask"}, ctx: ctx)
      card = Policy.card(named, account: account)
      assert card["proposal"]["vault_entry"] == work.id
      assert card["proposal"]["args"]["connection"] == "Work"
      assert card["standing"] == false
      refute Policy.proposal_digest(card) == Policy.proposal_digest(Policy.proposal(named))

      # The card for the call spelled `work` reads and binds Work, the name
      # its binding stores: the same proposal and digest as Work's own.
      lower_card = Policy.card(lower, account: same)
      assert lower_card["proposal"] == card["proposal"]
      assert Policy.proposal_digest(lower_card) == Policy.proposal_digest(card)

      # A name the app's own profile does not bind is setup required, naming
      # the app and the account, before any approval is read.
      for name <- ["Home", "Works"] do
        assert {:setup_required, ^versioned, {nil, ^name}} =
                 Policy.decide(launch.(%{"connection" => name}), %{"execution.run" => "ask"},
                   ctx: ctx
                 )
      end

      # An app with no grant at all binds no account either.
      {:ok, ungranted} =
        Binding.resolve("execution.run", %{
          "reference" => "formula:local.nowhere:1.0.0",
          "connection" => "Work"
        })

      assert {:setup_required, "formula:local.nowhere:1.0.0", {nil, "Work"}} =
               Policy.decide(ungranted, %{"execution.run" => "ask"}, ctx: ctx)

      # A profile that cannot be told is a refusal, never a setup.
      assert {:refuse, why} =
               Policy.decide(
                 launch.(%{"connection" => "Work", "profile" => "elsewhere"}),
                 %{"execution.run" => "ask"},
                 ctx: ctx
               )

      assert why =~ "could not be read"
    end
  end

  # An app of the person's own whose own calls bind a default and the
  # account "Work" beside it, through the consent walk.
  defp named_app!(ctx) do
    name = "named-launch-#{System.unique_integer([:positive])}"

    manifest = %{
      "name" => name,
      "version" => "1.0.0",
      "type" => "reagent",
      "needs" => %{
        "api_key" => %{
          "type" => "api_key:example.com",
          "reason" => "to call the example API",
          "fields" => ["KEY"]
        }
      },
      "caps" => %{"egress" => %{"domains" => ["api.example.com"]}}
    }

    {:ok, _component} =
      Compendium.Registry.publish_bytes(ctx, File.read!(@math_wasm), %{
        name: name,
        version: "1.0.0",
        type: "reagent",
        manifest: Jason.encode!(manifest)
      })

    entry = fn label ->
      {:ok, view} =
        Sanctum.TestContext.create_vault(ctx, %{
          name: "#{name} #{label}",
          kind: "api_key",
          provider_hint: "example.com",
          fields: %{"KEY" => "k-#{label}"},
          destination: %{"hosts" => ["api.example.com"]},
          disclose: true
        })

      view
    end

    default = entry.("default")
    work = entry.("work")
    ref = "reagent:local." <> name

    decisions = %{
      ref: ref,
      bindings: [
        %{need: "api_key", entry_id: default.id},
        %{need: "api_key", name: "Work", entry_id: work.id}
      ]
    }

    {:ok, plan} = Sanctum.Consent.Plan.plan(ctx, %{ref: ref})
    {:ok, preview} = Sanctum.Consent.Commit.preview(ctx, decisions)

    {:ok, _} =
      Sanctum.Consent.Commit.commit(ctx, %{
        decisions: decisions,
        plan_token: plan.plan_token,
        proof: preview.proof,
        commit_digest: preview.commit_digest,
        expected_consent_revision: plan.expected_consent_revision
      })

    %{ref: ref, default: default, work: work}
  end

  describe "ttl_seconds/1" do
    test "is the athanor's setting in hours, else the configured default, never a bad value" do
      ctx = Sanctum.TestContext.local(:prism)
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
