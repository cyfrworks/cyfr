# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.ApprovalTool do
  @moduledoc """
  A card decided on the wire: the `approval` tool.

  `resolve` is `Aqua.Approvals.resolve/3` — the one door a person's
  decision goes through, the same one the console's buttons use — and
  `list` shows a thread's open cards. Both are external-plane and
  `consent: :interactive`: a running agent cannot decide its own cards,
  and no standing credential can decide for a person.

  A decision is made once: deciding a card again answers the first
  decision as a replay, with no second effect.
  """

  @behaviour Prima.Provider

  alias Aqua.Approvals
  alias Aqua.Tape
  alias Sanctum.Context

  @impl true
  def service, do: "approval"

  @impl true
  def tools, do: [definition()]

  @doc false
  def definition do
    alias Prima.{Arg, Operation}

    Operation.tool(
      [
        Operation.new(
          "approval",
          "resolve",
          "Resolve approval",
          [
            Arg.new("approval", :string, required: true, description: "resolve: the approval id"),
            Arg.new("decision", :string,
              required: true,
              description: "resolve: the decision",
              enum: ["approve", "decline"]
            ),
            Arg.new("scope", :string,
              description:
                "resolve: approve once | thread | always; decline once | never. Default once.",
              enum: ["once", "thread", "always", "never"]
            ),
            Arg.new("reason", :string, description: "resolve: why (decline)")
          ],
          kind: :write,
          planes: [:external],
          consent: :interactive
        ),
        Operation.new(
          "approval",
          "list",
          "List approval",
          [
            Arg.new("thread", :string,
              required: true,
              description: "list: the thread whose open cards to show"
            )
          ],
          kind: :read,
          planes: [:external],
          consent: :interactive
        )
      ],
      description:
        "Decide the approval cards a turn raises, and list a thread's open cards. Approve once, for this thread, or always (where the action allows a standing answer); decline once or never. Deciding a card that was already decided answers the first decision.",
      title: "Approvals"
    )
  end

  @impl true
  def handle("approval", %Context{} = ctx, args), do: dispatch(ctx, args)
  def handle(tool, _ctx, _args), do: {:error, {:not_found, "tool", tool}}

  # The interactive-surface gate is the `consent: :interactive`
  # declaration on every action, enforced by the registry before this
  # runs.
  defp dispatch(ctx, %{"action" => "resolve", "approval" => id, "decision" => decision} = args)
       when is_binary(id) and id != "" do
    with {:ok, choice} <- choice(decision, args["scope"], args["reason"]) do
      case Approvals.resolve(ctx, id, choice) do
        {:ok, outcome} -> {:ok, outcome}
        {:error, reason} -> {:error, refusal(reason, id)}
      end
    end
  end

  defp dispatch(_ctx, %{"action" => "resolve"}),
    do: {:error, {:invalid_argument, "resolve requires 'approval' and 'decision'"}}

  defp dispatch(ctx, %{"action" => "list", "thread" => thread_id})
       when is_binary(thread_id) and thread_id != "" do
    with {:ok, _thread} <- Tape.thread(ctx, thread_id),
         {:ok, turns} <- Tape.open_turns(ctx, thread_id) do
      approvals =
        Enum.flat_map(turns, fn turn ->
          case Tape.pending_approvals(ctx, turn) do
            {:ok, rows} -> Enum.map(rows, &render/1)
            _ -> []
          end
        end)

      {:ok, %{thread: thread_id, approvals: approvals, count: length(approvals)}}
    else
      {:error, :not_found} -> {:error, {:not_found, "thread", thread_id}}
      {:error, reason} -> {:error, refusal(reason, thread_id)}
    end
  end

  defp dispatch(_ctx, %{"action" => "list"}),
    do: {:error, {:invalid_argument, "list requires 'thread'"}}

  defp dispatch(_ctx, _args),
    do: {:error, {:invalid_argument, "approval requires an 'action'"}}

  defp choice("approve", scope, _reason) when scope in [nil, "once", "thread", "always"],
    do: {:ok, %{decision: :approved, scope: Aqua.ApprovalScope.parse(scope || "once")}}

  defp choice("approve", scope, _reason),
    do: {:error, {:invalid_argument, "approve takes scope once, thread or always, not #{scope}"}}

  defp choice("decline", scope, reason) when scope in [nil, "once", "never"],
    do:
      {:ok,
       %{decision: :declined, scope: Aqua.ApprovalScope.parse(scope || "once"), reason: reason}}

  defp choice("decline", scope, _reason),
    do: {:error, {:invalid_argument, "decline takes scope once or never, not #{scope}"}}

  defp choice(decision, _scope, _reason),
    do:
      {:error,
       {:invalid_argument, "decision must be approve or decline, not #{inspect(decision)}"}}

  defp render(approval) do
    %{
      id: approval.id,
      turn_id: approval.turn_id,
      step_id: approval.step_id,
      message_id: approval.message_id,
      status: approval.status,
      expires_at: approval.expires_at,
      inserted_at: approval.inserted_at
    }
  end

  defp refusal(:not_found, id), do: {:not_found, "approval", id}

  defp refusal(:turn_superseded, _id),
    do: {:conflict, "the turn's consent moved — send the message again"}

  defp refusal({:scope_not_permitted, _} = reason, _id),
    do: {:invalid_argument, Aqua.ToolGrants.refusal_message(reason)}

  defp refusal({:unavailable, what}, _id), do: {:unavailable, what}
  defp refusal(reason, _id), do: {:conflict, Aqua.Ops.render_refusal(reason)}
end
