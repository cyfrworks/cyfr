# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.LaunchTest do
  @moduledoc """
  An approved launch runs as the person who approved it, under the origin
  the approved turn's row stores — never `interactive` inferred from the
  person approving. A programmatic turn's launch stays programmatic, and a
  turn whose row stores no origin launches nothing.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Aqua.{Approvals, Launch, Tape}
  alias Arca.ThreadStorage, as: Threads
  alias Sanctum.Consent.Bootstrap
  alias Sanctum.Tenancy.{Members, Users}

  @seed_root Path.expand("../../../../seed", __DIR__)
  @soul "agent:local.aqua"
  # A shipped application that roots its own consent: whatever it
  # answers, its root's row is written as the launch admitted it.
  @application "formula:local.list-models"

  setup tags do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!(tags)

    test_path = Path.join(System.tmp_dir!(), "launch_#{System.unique_integer([:positive])}")
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

    ctx = Sanctum.TestContext.local()
    :ok = Sanctum.TestContext.shipped!(ctx.athanor_id)
    {:ok, %{errors: 0}} = Compendium.AutoIndexer.scan(ctx: ctx)
    {:ok, _} = Compendium.AgentIndex.sync(ctx)
    {:ok, %{minted: minted}} = Bootstrap.run(ctx)
    assert @soul in minted

    {:ok, %{profile_id: profile_id, consent_id: consent_id}} =
      Crucible.authority_for(ctx, :default, @soul)

    {:ok, %{capability_digest: capability}} = Compendium.AgentIndex.snapshot(ctx, "aqua")

    {:ok, thread} = Threads.create(Sanctum.Context.actor(ctx))

    pins = %{profile_id: profile_id, consent_id: consent_id, agent_capability_digest: capability}
    {:ok, ctx: ctx, thread: thread, pins: pins, approver: approver!(ctx)}
  end

  # A seated member other than the sender, whose approval the launch runs as.
  defp approver!(ctx) do
    n = System.unique_integer([:positive])

    {:ok, approver} =
      Users.upsert_from_provider(%{
        id: "github|https://github.com|launcher#{n}",
        provider: "github",
        email: "launcher#{n}@example.com",
        verified: true,
        name: "Launcher"
      })

    {:ok, _} = Members.ensure(approver.id, scope: "athanor", athanor_id: ctx.athanor_id)
    %{ctx | user_id: approver.id, origin: :interactive}
  end

  # A turn accepted from `sender`, whose context carries the origin its
  # admission path set, and started under its pinned root.
  defp started!(sender, thread, pins) do
    {:ok, %{turn: turn}} =
      Tape.accept(sender, thread.id, %{
        message: %{author: sender.user_id, content: "@aqua launch it"},
        turn: %{agent: "aqua", requested_by: sender.user_id}
      })

    {:ok, %{execution: execution, attempt: attempt}} =
      Arca.Execution.admit(
        %{
          id: "exec_launch_#{System.unique_integer([:positive])}",
          reference: @soul,
          user_id: sender.user_id,
          athanor_id: sender.athanor_id,
          component_type: "agent",
          kind: "turn",
          turn_id: turn.id,
          origin: sender.origin
        },
        reservation: %{budget_id: "bgt_#{System.unique_integer([:positive])}", cap: 4},
        grant: Cyfr.Test.AttemptFixtures.grant(sender.athanor_id),
        verify: &Sanctum.ExecutionStanding.verify/1
      )

    {:ok, turn} =
      Tape.start_turn(
        sender,
        turn,
        Map.merge(pins, %{
          root_execution_id: execution.id,
          attempt: attempt.attempt,
          recovery_limit: Aqua.Runner.RecoveryPolicy.max_attempts()
        })
      )

    turn
  end

  # A launch card for the application, as the loop opens it, approved by
  # `approver`: the step the loop hands the dispatcher.
  defp approved_launch!(ctx, turn, approver) do
    proposal = %{
      "tool" => "execution",
      "action" => "run",
      "args" => %{"reference" => @application, "input" => %{}}
    }

    {:ok, model_step} = Tape.record_model_intent(ctx, turn, %{})

    {:ok, %{calls: [%{step: step}]}} =
      Tape.record_response(ctx, turn, model_step, %{
        text: nil,
        tool_calls: [
          %{
            tool_call_id: "c1",
            name: "execution.run",
            tool: "execution",
            action: "run",
            arguments: proposal["args"],
            kind: "execute",
            step_kind: "launch"
          }
        ]
      })

    intent = %{
      "kind" => "request_approval",
      "title" => "execution.run",
      "action_kind" => "execute",
      "standing" => nil,
      "tool_call_id" => "c1",
      "proposal" => proposal
    }

    {:ok, %{approval: approval}} =
      Tape.open_approval(ctx, turn, step, %{
        proposal_digest: Aqua.Loop.Policy.proposal_digest(proposal),
        card: %{content: "execution.run?", payload: %{"intent" => intent}},
        expires_at: nil
      })

    assert {:ok, %{decision: "approved", resolution_kind: "launch"}} =
             Approvals.resolve(approver, approval.id, %{decision: :approved})

    {:ok, step} = Tape.step(ctx, step.id)
    step
  end

  defp launched(ctx) do
    Arca.Repo.all(
      from(e in Arca.Schemas.Execution,
        where: e.athanor_id == ^ctx.athanor_id and like(e.reference, ^"#{@application}%"),
        select: %{user_id: e.user_id, origin: e.origin, parent: e.parent_execution_id}
      )
    )
  end

  test "a programmatic turn's launch, approved by a person, runs as that person and stays programmatic",
       %{ctx: ctx, thread: thread, pins: pins, approver: approver} do
    sender = %{ctx | origin: :programmatic}
    turn = started!(sender, thread, pins)
    assert turn.origin == "programmatic"

    step = approved_launch!(ctx, turn, approver)
    dispatched = Launch.dispatch(ctx, step)

    assert [%{user_id: user_id, origin: origin, parent: nil}] = launched(ctx),
           "launch answered #{inspect(dispatched)}"

    assert user_id == approver.user_id
    assert origin == "programmatic"
  end

  test "an interactive turn's launch keeps the turn's origin", %{
    ctx: ctx,
    thread: thread,
    pins: pins,
    approver: approver
  } do
    turn = started!(%{ctx | origin: :interactive}, thread, pins)
    step = approved_launch!(ctx, turn, approver)
    dispatched = Launch.dispatch(ctx, step)

    assert [%{origin: "interactive"}] = launched(ctx), "launch answered #{inspect(dispatched)}"
  end

  test "a turn whose row stores no origin launches nothing, with that reason", %{
    ctx: ctx,
    thread: thread,
    pins: pins,
    approver: approver
  } do
    turn = started!(%{ctx | origin: nil}, thread, pins)
    assert is_nil(turn.origin)

    step = approved_launch!(ctx, turn, approver)

    # Never guessed from the person who approved it.
    assert {:error, {:approver_unavailable, :no_origin}} = Launch.dispatch(ctx, step)
    assert launched(ctx) == []
  end

  test "an origin the sender's request names is not the turn's", %{
    ctx: ctx,
    thread: thread
  } do
    sender = %{ctx | origin: :programmatic}

    {:ok, %{turn: turn}} =
      Tape.accept(sender, thread.id, %{
        message: %{author: sender.user_id, content: "@aqua go"},
        turn: %{agent: "aqua", requested_by: sender.user_id, origin: :interactive}
      })

    assert turn.origin == "programmatic"
  end
end
