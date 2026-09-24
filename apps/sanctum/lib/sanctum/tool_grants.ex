# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.ToolGrants do
  @moduledoc """
  Standing tool grants: what a person answered about one `tool.action`
  for one agent, kept so the question is not asked again.

  A grant is consent state, so its rows are read and written only here.
  The tenant is the caller's context — a caller cannot name an athanor,
  a deciding person or a row id; `grant_row/2` and `put/2` take them from
  the context and drop everything else the attributes carry.

  The rule for which answers may stand at all — the kind of the action and
  its standing declaration — belongs to the assistant, which checks it
  before it calls here (`Aqua.ToolGrants`). This module holds the
  vocabulary, the row shape and the tenancy.
  """

  alias Sanctum.Context

  @typedoc "One stored grant, as a plain map."
  @type grant :: %{required(:scope) => String.t(), optional(atom()) => term()}

  @typedoc "Field errors for attributes that do not make a grant."
  @type field_errors :: %{optional(atom()) => [String.t()]}

  @doc "The scopes a grant may carry: `\"thread\"` or `\"agent\"`."
  @spec scopes() :: [String.t()]
  def scopes, do: Arca.ToolGrantStorage.scopes()

  @doc "The effects a grant may carry: `\"allow\"` or `\"deny\"`."
  @spec effects() :: [String.t()]
  def effects, do: Arca.ToolGrantStorage.effects()

  @doc """
  Every grant bearing on one thread in the caller's athanor: the thread's
  own thread-scope rows and every agent-scope row.

  A store that cannot be read is `{:error, :unavailable}`, never an empty
  list: no rows would drop every deny, so an outage would widen what runs.
  """
  @spec for_thread(Context.t(), String.t()) ::
          {:ok, [grant()]} | {:error, :unavailable | :no_athanor}
  def for_thread(%Context{} = ctx, thread_id) when is_binary(thread_id) do
    case Arca.ToolGrantStorage.list_for_thread(Context.actor(ctx), thread_id) do
      {:ok, rows} -> {:ok, rows}
      {:error, :no_athanor} -> {:error, :no_athanor}
      {:error, _unreadable} -> {:error, :unavailable}
    end
  end

  @doc """
  The row a decision writes, built and validated but not written, for a
  caller whose storage lands it inside a transaction of its own (the turn
  store writes it with the decision that made it).

  `attrs` names `scope`, `effect`, `agent_name`, `tool`, `action` and, at
  thread scope, `thread_id`. The athanor and the deciding person come from
  the context. A context with no tenant is `:forbidden`; attributes that
  do not make a grant are `:invalid_argument`.
  """
  @spec grant_row(Context.t(), map()) ::
          {:ok, map()} | {:error, :invalid_argument | :forbidden}
  def grant_row(%Context{} = ctx, attrs) when is_map(attrs) do
    case build(ctx, attrs, :decision) do
      {:ok, row} -> {:ok, row}
      {:error, :no_athanor} -> {:error, :forbidden}
      {:error, {:invalid, _field_errors}} -> {:error, :invalid_argument}
    end
  end

  @doc """
  Record a decision in the caller's athanor, replacing whatever the same
  key said before.
  """
  @spec put(Context.t(), map()) ::
          {:ok, grant()} | {:error, :unavailable | :no_athanor | {:invalid, field_errors()}}
  def put(%Context{} = ctx, attrs) when is_map(attrs) do
    with {:ok, row} <- build(ctx, attrs, :decision) do
      case Arca.ToolGrantStorage.put(row) do
        {:ok, grant} -> {:ok, grant}
        {:error, {:invalid, _field_errors} = invalid} -> {:error, invalid}
        {:error, _unreadable} -> {:error, :unavailable}
      end
    end
  end

  @doc "Withdraw a decision in the caller's athanor. Idempotent."
  @spec revoke(Context.t(), map()) ::
          :ok | {:error, :unavailable | :no_athanor | {:invalid, field_errors()}}
  def revoke(%Context{} = ctx, attrs) when is_map(attrs) do
    with {:ok, key} <- build(ctx, attrs, :key) do
      case Arca.ToolGrantStorage.delete(key) do
        :ok -> :ok
        {:error, _unreadable} -> {:error, :unavailable}
      end
    end
  end

  # The one shape both writes and the key a revoke deletes by. An
  # agent-scope row names no thread: it is the same answer in every
  # thread, and keeping the one it was given in would make the key
  # ambiguous. A decision carries its effect and the person who made it;
  # a key is only what identifies the row.
  defp build(ctx, attrs, kind) do
    with {:ok, athanor_id} <- athanor(ctx),
         :ok <- validate(attrs, kind) do
      scope = Map.fetch!(attrs, :scope)

      key = %{
        athanor_id: athanor_id,
        scope: scope,
        agent_name: Map.fetch!(attrs, :agent_name),
        tool: Map.fetch!(attrs, :tool),
        action: Map.fetch!(attrs, :action),
        thread_id: if(scope == "thread", do: Map.fetch!(attrs, :thread_id))
      }

      case kind do
        :key -> {:ok, key}
        :decision -> {:ok, Map.merge(key, %{effect: attrs.effect, granted_by: ctx.user_id})}
      end
    end
  end

  defp athanor(ctx) do
    case Context.actor(ctx) do
      %Prima.Actor{athanor_id: athanor_id} when is_binary(athanor_id) and athanor_id != "" ->
        {:ok, athanor_id}

      _ ->
        {:error, :no_athanor}
    end
  end

  defp validate(attrs, kind) do
    errors =
      %{}
      |> require_member(attrs, :scope, scopes())
      |> check_effect(attrs, kind)
      |> require_text(attrs, :agent_name)
      |> require_text(attrs, :tool)
      |> require_text(attrs, :action)
      |> check_thread(attrs)

    if errors == %{}, do: :ok, else: {:error, {:invalid, errors}}
  end

  defp require_member(errors, attrs, field, allowed) do
    if Map.get(attrs, field) in allowed,
      do: errors,
      else: Map.put(errors, field, ["must be one of: #{Enum.join(allowed, ", ")}"])
  end

  # A decision names its effect; a revoke deletes by key and ignores it.
  defp check_effect(errors, attrs, :decision), do: require_member(errors, attrs, :effect, effects())
  defp check_effect(errors, _attrs, :key), do: errors

  defp require_text(errors, attrs, field) do
    case Map.get(attrs, field) do
      value when is_binary(value) and value != "" -> errors
      _ -> Map.put(errors, field, ["can't be blank"])
    end
  end

  defp check_thread(errors, %{scope: "thread"} = attrs), do: require_text(errors, attrs, :thread_id)
  defp check_thread(errors, _attrs), do: errors
end
