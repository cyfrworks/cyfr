# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Loop.Policy do
  @moduledoc """
  What a resolved call may do under the agent's effective policy: run at
  once, ask the person first, or be refused — and whether it may run
  beside others.

  The policy is `Aqua.ToolGrants.resolve/2`'s guest spelling
  (`"tool.action" => "auto" | "ask" | "deny"`, `"role.*" => "auto"`),
  already under the kind ceiling: a destructive or external action is
  never `auto` without a standing grant. A hand or catalog call reads its
  own key; a clone reads its role's glob; the `ui` event runs at once; an
  external server's tool always asks; a launch reads `execution.run` and
  then the launch rule: an application the estate consented to and this
  turn has not written to may run under `auto`, anything else needs a
  card. Reads run beside each other; everything else runs alone.

  What this turn wrote to is read from the durable rows, never from
  memory: `touched_refs/1` names the components the turn's closed write,
  destructive and execute calls — its own and its clones' — reached, so
  the rule survives a restart.
  """

  alias Aqua.Loop.Binding.Call

  @type decision :: :auto | :ask | {:deny, String.t()} | {:refuse, String.t()}

  @doc """
  The decision for `call` under `policy`. `opts`: `:consented?` (a
  function of a reference), `:touched` (a `MapSet` of references this
  turn wrote to).
  """
  @spec decide(Call.t(), map(), keyword()) :: decision()
  def decide(%Call{kind: :ui}, _policy, _opts), do: :auto

  def decide(%Call{kind: :clone, target: role}, policy, _opts) do
    if Map.get(policy, "#{role}.*") == "auto",
      do: :auto,
      else: {:deny, "the soul may not clone into #{role}: its policy does not allow it"}
  end

  def decide(%Call{kind: :external}, _policy, _opts), do: :ask

  def decide(%Call{kind: :launch, target: reference} = call, policy, opts) do
    case launch_rule(reference, opts) do
      {:refuse, text} -> {:refuse, text}
      :card -> if Map.get(policy, key(call)) == "deny", do: deny(call), else: :ask
      :child -> by_key(call, policy)
    end
  end

  def decide(%Call{} = call, policy, _opts), do: by_key(call, policy)

  defp by_key(call, policy) do
    case Map.get(policy, key(call)) do
      "auto" -> :auto
      "ask" -> :ask
      _ -> deny(call)
    end
  end

  defp deny(call), do: {:deny, "#{key(call)} is not in the agent's policy"}

  defp key(%Call{tool: tool, action: action}), do: "#{tool}.#{action}"

  @doc """
  Whether `call` may run beside other calls of the same batch: only a
  read does; a write, an execute, a destructive act and a clone run
  alone.
  """
  @spec overlap(Call.t()) :: :concurrent | :exclusive
  def overlap(%Call{kind: kind, tool: tool, action: action}) when kind in [:hand, :catalog] do
    if Aqua.Kinds.kind_for(tool, action) == :read, do: :concurrent, else: :exclusive
  end

  def overlap(%Call{}), do: :exclusive

  @doc """
  The launch rule: an `execution.run` of `reference` runs as a child of
  the turn (`:child`) when the estate consented to it and this turn did
  not write to it; a reference this turn wrote to, or one the estate has
  not consented to, needs a card (`:card`); a reference that is not a
  component is refused.
  """
  @spec launch_rule(String.t(), keyword()) :: :child | :card | {:refuse, String.t()}
  def launch_rule(reference, opts) do
    consented? = Keyword.get(opts, :consented?, fn _ -> false end)
    touched = Keyword.get(opts, :touched, MapSet.new())

    case Sanctum.ComponentRef.parse(reference) do
      {:ok, _} ->
        cond do
          MapSet.member?(touched, name_level(reference)) -> :card
          consented?.(reference) -> :child
          true -> :card
        end

      _ ->
        {:refuse, "#{inspect(reference)} is not a component reference"}
    end
  end

  @doc """
  The component references the turn's closed write, destructive and
  execute calls reached, from their `tool_call` payloads: an argument
  named `reference` or `ref`, and a file path under `components/`. Name
  level, so any version of a touched component counts.
  """
  @spec touched_refs([map()]) :: MapSet.t()
  def touched_refs(calls) when is_list(calls) do
    calls
    |> Enum.filter(fn call ->
      Aqua.Kinds.kind_for(call["tool"] || "", call["action"] || "") in [
        :write,
        :destructive,
        :execute
      ]
    end)
    |> Enum.flat_map(fn call ->
      args = call["arguments"] || %{}

      refs =
        [args["reference"], args["ref"]]
        |> Enum.filter(&is_binary/1)
        |> Enum.map(&name_level/1)

      refs ++ path_refs(args["path"])
    end)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  @doc """
  The card a call that asks becomes: today's intent shape, which the
  console card and the wire read — the proposal canonical, the kind and
  the standing from the catalog, never from the model.
  """
  @spec card(Call.t(), keyword()) :: map()
  def card(%Call{} = call, opts \\ []) do
    proposal = %{"tool" => call.tool, "action" => call.action, "args" => call.args}

    %{
      "kind" => "request_approval",
      "id" => Keyword.get(opts, :id) || Cyfr.UUID7.generate_id("apr"),
      "title" => Keyword.get(opts, :title) || "#{call.tool}.#{call.action}",
      "summary" => Keyword.get(opts, :summary) || "",
      "action_kind" =>
        Atom.to_string(Aqua.Kinds.kind_for(call.tool, call.action || "") || :external),
      "standing" =>
        Cyfr.Ops.Annotations.standing_to_wire(
          Aqua.Kinds.standing_for(call.tool, call.action || "")
        ),
      "proposal" => proposal
    }
  end

  @doc "The digest a card is consumed by: the canonical proposal, hashed."
  @spec proposal_digest(map()) :: String.t()
  def proposal_digest(%{"proposal" => proposal}), do: proposal_digest(proposal)

  def proposal_digest(proposal) when is_map(proposal) do
    {:ok, digest} = Sanctum.JCS.hash(proposal)
    digest
  end

  defp name_level(reference), do: Aqua.Hands.name_level(reference)

  # `components/<types>/<publisher>/<name>/<version>/…` names a component.
  defp path_refs(path) when is_binary(path) do
    case String.split(path, "/") do
      ["components", plural, publisher, name | _] ->
        type = String.trim_trailing(plural, "s")
        ["#{type}:#{publisher}.#{name}"]

      _ ->
        []
    end
  end

  defp path_refs(_), do: []
end
