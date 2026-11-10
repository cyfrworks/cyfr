# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Requests do
  @moduledoc """
  The requests waiting on a person: what a frame asked them for through
  the system layer that they have not decided yet (`PrismWeb.ShellLive`,
  which presents each one and runs it once approved). A request is held
  by the shell that presents it: the shell's own process registers it
  here, under its id, and it leaves with that process whatever ends it,
  so no request outlives the prompt that asks it. Nothing is stored: a
  request lives on the member whose shell holds it and expires with it,
  so a member of a cell lists only its own shells'.

  This registry is the one authority on whether a request still waits.
  Whatever decides it, the person's approval, refusal or dismissal in the
  system layer, its expiry, or its frame's leaving, first ends it here
  with `decide/2`, which answers `:ok` to the first decision alone and
  `:decided` to every later one; only the decision that ended it acts,
  and the prompt follows. Only the holding process can end a request, and
  the system layer that presents it runs in that process, so the check
  and the end are one step that nothing else interleaves with: an
  approval queued behind the expiry finds the request decided and runs
  nothing.

  Each opening and each end is told on the person's attention topic
  (`Cyfr.Bus.attention/2`) as an `attention.changes` item of kind
  `grant_request` and its `removed`, and `waiting/2` is that stream's
  refresh of them (`Cyfr.Providers.Attention`). Its destination is the
  system layer's prompt, by the request's id. A request whose shell died
  is told nowhere, and leaves the stream's picture at its next refresh.
  """

  alias Cyfr.Bus
  alias Cyfr.Bus.Attention
  alias Sanctum.Context

  require Logger

  @registry __MODULE__

  @typedoc "A waiting request, as `attention.changes` names it."
  @type item :: %{
          kind: :grant_request,
          id: String.t(),
          label: String.t(),
          since: DateTime.t(),
          destination: %{kind: String.t(), page: nil, ref: String.t()},
          outcome: nil
        }

  @doc "The registry the shells hold their requests in, one entry per request id."
  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_arg), do: Registry.child_spec(keys: :unique, name: @registry)

  @doc """
  Request `id` waits on the context's person, labelled `label` (the
  operation it asks for, or the component a grant names): held by the
  calling process and told on the person's attention topic.
  """
  @spec open(Context.t(), String.t(), String.t()) :: :ok
  def open(%Context{athanor_id: athanor_id, user_id: user_id} = ctx, id, label)
      when is_binary(athanor_id) and is_binary(user_id) and is_binary(id) and is_binary(label) do
    item = item(id, label, DateTime.utc_now())
    held = %{actor: Context.actor(ctx), user_id: user_id, item: item}
    {:ok, _owner} = Registry.register(@registry, id, held)
    tell(held, :grant_request, Map.delete(item, :kind))
  end

  @doc """
  Ends request `id` as `outcome` says (`Cyfr.Bus.Attention.outcomes/0`):
  decided by the person (`resolved`), left until it expired (`expired`),
  or taken away with its frame (`withdrawn`). `:ok` when the calling
  process held it waiting, which it no longer does; `:decided` when it
  waits no longer, ended already or never held here, and nothing
  changes. The first decision of a request is the one that acts.
  """
  @spec decide(String.t(), Attention.outcome()) :: :ok | :decided
  def decide(id, outcome) when is_binary(id) do
    case Registry.lookup(@registry, id) do
      [{owner, held}] when owner == self() ->
        :ok = Registry.unregister(@registry, id)
        tell(held, :removed, %{id: id, outcome: outcome})

      _decided ->
        :decided
    end
  end

  @doc "The requests waiting on `user_id` in athanor `athanor_id`, oldest first."
  @spec waiting(String.t(), String.t()) :: [item()]
  def waiting(athanor_id, user_id) when is_binary(athanor_id) and is_binary(user_id) do
    @registry
    |> Registry.select([{{:_, :_, :"$1"}, [], [:"$1"]}])
    |> Enum.filter(&(&1.actor.athanor_id == athanor_id and &1.user_id == user_id))
    |> Enum.map(& &1.item)
    |> Enum.sort_by(& &1.since, DateTime)
  end

  defp item(id, label, since),
    do: %{
      kind: :grant_request,
      id: id,
      label: label,
      since: since,
      destination: %{kind: "ref", page: nil, ref: id},
      outcome: nil
    }

  # A request is the shell's to run whatever its announcement meets: a
  # broadcast refused is logged, and the stream's next refresh tells it.
  defp tell(%{actor: actor, user_id: user_id}, kind, fields) do
    case Bus.broadcast(actor, Bus.attention(actor, user_id), Attention.new(actor, kind, fields)) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("[Cyfr.Requests] #{kind} not told its person: #{inspect(reason)}")
        :ok
    end
  end
end
