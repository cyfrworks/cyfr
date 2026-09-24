# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Providers.ApprovalTest do
  @moduledoc """
  A card decided on the wire goes through the same door as the console's
  buttons, and only a person's own session may open it: a standing
  credential and a running agent are refused at the registry.
  """

  use ExUnit.Case, async: false

  alias Aqua.Tape
  alias Arca.ThreadStorage, as: Threads
  alias Grimoire.{Catalog, Visibility}
  alias Sanctum.Context

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    Sanctum.TestContext.athanor!()
    ctx = Sanctum.TestContext.local()
    {:ok, thread} = Threads.create(Sanctum.Context.actor(ctx))
    {:ok, ctx: ctx, thread: thread}
  end

  defp card!(ctx, thread) do
    {:ok, %{turn: turn}} =
      Tape.accept(ctx, thread.id, %{
        message: %{author: ctx.user_id, content: "@aqua go"},
        turn: %{agent: "aqua", requested_by: ctx.user_id}
      })

    {:ok, %{execution: execution, attempt: attempt}} =
      Arca.Execution.admit(
        %{
          id: "exec_aprtool_#{System.unique_integer([:positive])}",
          reference: "agent:local.aqua",
          user_id: ctx.user_id,
          athanor_id: ctx.athanor_id,
          component_type: "agent",
          kind: "turn",
          turn_id: turn.id
        },
        reservation: %{budget_id: "bgt_#{System.unique_integer([:positive])}", cap: 4},
        grant: Cyfr.Test.AttemptFixtures.grant(ctx.athanor_id),
        verify: &Sanctum.ExecutionStanding.verify/1
      )

    {:ok, turn} =
      Tape.start_turn(ctx, turn, %{
        root_execution_id: execution.id,
        attempt: attempt.attempt,
        profile_id: "prof_x",
        consent_id: "consent_x"
      })

    {:ok, model_step} = Tape.record_model_intent(ctx, turn, %{})
    proposal = %{"tool" => "files", "action" => "delete", "args" => %{"path" => "data/x"}}

    {:ok, %{calls: [%{step: step}]}} =
      Tape.record_response(ctx, turn, model_step, %{
        text: nil,
        tool_calls: [
          %{
            tool_call_id: "c1",
            name: "files.delete",
            tool: "files",
            action: "delete",
            arguments: proposal["args"],
            kind: "destructive"
          }
        ]
      })

    intent = %{
      "kind" => "request_approval",
      "title" => "files.delete",
      "action_kind" => "destructive",
      "tool_call_id" => "c1",
      "proposal" => proposal
    }

    {:ok, %{approval: approval}} =
      Tape.open_approval(ctx, turn, step, %{
        proposal_digest: Aqua.Loop.Policy.proposal_digest(proposal),
        card: %{content: "files.delete?", payload: %{"intent" => intent}}
      })

    %{turn: turn, step: step, approval: approval}
  end

  test "a standing credential and a running agent are refused; a session sees the tool", %{
    ctx: ctx
  } do
    star = %{ctx | auth_method: :api_key, api_key_type: :admin, permissions: MapSet.new([:*])}

    assert {:error, {:consent_class_required, {:surface_not_permitted, :api_key}}} =
             Catalog.call_external("approval", star, %{
               "action" => "resolve",
               "approval" => "apr_x",
               "decision" => "approve"
             })

    refute Enum.any?(
             Visibility.filter_for_context(Catalog.list_tools(), star),
             &(&1["name"] == "approval")
           )

    assert Enum.any?(
             Visibility.filter_for_context(Catalog.list_tools(), ctx),
             &(&1["name"] == "approval")
           )

    guest = Context.enter_guest(ctx)

    assert {:error, {:guest_plane_call, "approval"}} =
             Catalog.call_external("approval", guest, %{"action" => "list"})
  end

  test "a card is listed, declined once through the door, and answered again as a replay", %{
    ctx: ctx,
    thread: thread
  } do
    %{approval: approval, step: step} = card!(ctx, thread)

    assert {:ok, %{count: 1, approvals: [%{id: aid, status: "pending"}]}} =
             Catalog.call_external("approval", ctx, %{
               "action" => "list",
               "thread" => thread.id
             })

    assert aid == approval.id

    assert {:ok, %{decision: "declined", resolution_kind: "denied", replayed: false}} =
             Catalog.call_external("approval", ctx, %{
               "action" => "resolve",
               "approval" => approval.id,
               "decision" => "decline",
               "scope" => "never",
               "reason" => "no"
             })

    assert {:ok, %{dispatch_state: "closed", outcome: "denied"}} = Tape.step(ctx, step.id)

    assert {:ok, %{count: 0}} =
             Catalog.call_external("approval", ctx, %{
               "action" => "list",
               "thread" => thread.id
             })

    assert {:ok, %{decision: "declined", replayed: true}} =
             Catalog.call_external("approval", ctx, %{
               "action" => "resolve",
               "approval" => approval.id,
               "decision" => "approve"
             })
  end

  test "a wrong scope, a missing card and a bad decision are typed refusals", %{
    ctx: ctx,
    thread: thread
  } do
    %{approval: approval} = card!(ctx, thread)

    assert {:error, {:invalid_argument, msg}} =
             Catalog.call_external("approval", ctx, %{
               "action" => "resolve",
               "approval" => approval.id,
               "decision" => "approve",
               "scope" => "never"
             })

    assert msg =~ "approve takes scope"

    assert {:error, {:invalid_argument, _}} =
             Catalog.call_external("approval", ctx, %{
               "action" => "resolve",
               "approval" => approval.id,
               "decision" => "maybe"
             })

    assert {:error, {:not_found, "approval", "apr_nothing"}} =
             Catalog.call_external("approval", ctx, %{
               "action" => "resolve",
               "approval" => "apr_nothing",
               "decision" => "decline"
             })

    assert {:error, {:not_found, "thread", "thread_nothing"}} =
             Catalog.call_external("approval", ctx, %{
               "action" => "list",
               "thread" => "thread_nothing"
             })
  end
end
