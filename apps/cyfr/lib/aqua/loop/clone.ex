# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Loop.Clone do
  @moduledoc """
  A role the soul clones into: its own turn under the parent's root,
  attempt, authority and deadline, run by the parent's exclusive worker
  as a loop of its own — its own steps through workers of its own, its
  own policy, catalyst and prompt, its own rows. A clone never pauses:
  what asks is refused, and a launch is not its to make. Its last reply
  is the parent's tool result.
  """

  alias Aqua.Loop.Binding.Call
  alias Aqua.Loop.Turn
  alias Aqua.Tape
  alias Arca.Schemas.Message

  @spec run(Aqua.Loop.State.t(), Tape.step(), Call.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def run(%Aqua.Loop.State{} = parent, step, %Call{kind: :clone, target: role, args: args}) do
    task = if is_binary(args["task"]), do: args["task"], else: ""
    guest = parent.spec.guest

    with {:ok, definition} <- Turn.role(parent.spec, role),
         {:ok, %{turn: clone}} <-
           Tape.open_clone_turn(guest, parent.turn, %{
             role: role,
             task: task,
             model: definition["model"],
             step_id: step.id
           }),
         {:ok, spec} <-
           Turn.build(parent.spec.ctx, clone,
             authority: parent.spec.authority,
             agent: definition,
             catalyst: parent.spec.catalyst,
             model: parent.spec.model,
             excerpt?: false
           ) do
      state = %Aqua.Loop.State{
        spec: spec,
        claim: nil,
        turn: clone,
        parent: parent,
        clone?: true,
        since: parent.since,
        active_ms: parent.active_ms
      }

      {result, ended} = Aqua.Loop.loop(state)
      {status, error} = terminal(result)
      _ = Tape.close_clone_turn(guest, ended.turn, status, %{error: error})

      case result do
        :completed -> {:ok, last_reply(guest, ended.turn)}
        _ -> {:error, "the #{role} role did not finish: #{error}"}
      end
    else
      {:error, :no_such_role} -> {:error, "no role named #{role}"}
      {:error, reason} -> {:error, Aqua.Ops.render_refusal(reason)}
    end
  end

  defp terminal(:completed), do: {"completed", nil}
  defp terminal(:cancelled), do: {"cancelled", "stopped"}
  defp terminal({:paused, _}), do: {"failed", "a role cannot pause"}
  defp terminal({:failed, reason}), do: {"failed", describe(reason)}
  defp terminal({:uncertain, reason}), do: {"uncertain", describe(reason)}

  defp last_reply(guest, clone) do
    agent = Message.agent_author()

    case Tape.projection(guest, clone) do
      {:ok, rows} ->
        rows
        |> Enum.filter(fn row ->
          row.kind == "text" and row.author == agent and
            Tape.payload(row)["as"] != "task"
        end)
        |> List.last()
        |> case do
          %{content: content} when is_binary(content) and content != "" -> content
          _ -> "(the role answered nothing)"
        end

      _ ->
        "(the role's reply could not be read)"
    end
  end

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp describe(reason), do: Aqua.Ops.render_refusal(reason)
end
