# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.ToolGrants do
  @moduledoc """
  Standing tool grants: what a person answered about one `tool.action`
  for one agent, kept so the question is not asked again, and the rule
  for which answers may stand.

  A grant is consent state, so its rows are read and written only here.
  The tenant is the caller's context — a caller cannot name an athanor,
  a deciding person or a row id; `grant_row/2` and `put/2` take them from
  the context and drop everything else the attributes carry.

  ## Which answers may stand

  `check_standing/2` is the one rule. Both writes apply it, and a reader
  applies it again to every row it reads back, so an allow the action's
  current declaration would refuse counts for nothing, however it was
  written. It reads the action through `Sanctum.Grimoire`:

    * a destructive or external action, or one whose kind is unknown,
      takes no standing allow;
    * `standing: false` takes none at all, and `standing: :thread` none
      at agent scope;
    * an allow may carry bounds: the lifecycle it ends with (an
      execution, a turn or a schedule, and that row's id), a deadline
      still to come, and a constraint, a resource kind and its patterns,
      only for an action that declares an argument naming a resource of
      that kind (`Prima.Operation`'s `resource:`);
    * a deny carries none of them and always stands, so a standing deny
      never lapses.

  ## A bounded allow is decided per call

  A bounded allow never makes its pair automatic for a turn. `admits?/2`
  answers, for one call, whether a bounded allow covers it, from the rows
  as they stand when it is asked: the allow's lifecycle is the call's own
  execution, turn or schedule and is still live, its deadline has not
  passed, and the call's resource argument lies inside its constraint. A
  deny for the pair covers every call.
  """

  alias Sanctum.Context

  @typedoc "One stored grant, as a plain map."
  @type grant :: %{required(:scope) => String.t(), optional(atom()) => term()}

  @typedoc "Field errors for attributes that do not make a grant."
  @type field_errors :: %{optional(atom()) => [String.t()]}

  @typedoc """
  Why an answer may not stand. The kind of the action (`:destructive`,
  `:external`, `:unknown_kind`), its standing declaration
  (`:never_standing`, `:thread_only`), a deny carrying a bound
  (`:bounded_deny`), a lifecycle that names no row (`:invalid_lifecycle`),
  a deadline that is not a time to come (`:invalid_deadline`,
  `:deadline_passed`), and a constraint on an action that names no
  resource (`:no_resource`), of another kind than the action's
  (`:resource_kind`) or outside its kind's grammar
  (`:invalid_constraint`).
  """
  @type reason ::
          :destructive
          | :external
          | :unknown_kind
          | :never_standing
          | :thread_only
          | :bounded_deny
          | :invalid_lifecycle
          | :invalid_deadline
          | :deadline_passed
          | :no_resource
          | :resource_kind
          | :invalid_constraint

  @typedoc "An answer the rule refuses to let stand."
  @type refusal :: {:scope_not_permitted, reason()}

  @typedoc """
  One call as `admits?/2` judges it: the agent that makes it, its thread,
  its `tool` and `action` with its arguments, and the turn and the root
  execution it is made in.
  """
  @type call :: %{
          required(:agent_name) => String.t(),
          required(:thread_id) => String.t(),
          required(:tool) => String.t(),
          required(:action) => String.t(),
          required(:args) => map(),
          optional(:execution_id) => String.t() | nil,
          optional(:turn_id) => String.t() | nil
        }

  # The bounds an allow may carry and a deny never does, as the row names
  # them.
  @bounds [:lifecycle_kind, :lifecycle_id, :expires_at, :constraint]

  # The kinds an action may have to take a standing allow: a destructive
  # or external action always asks, and so does one of unknown kind.
  @standing_kinds [:read, :write, :execute]

  @doc "The scopes a grant may carry: `\"thread\"` or `\"agent\"`."
  @spec scopes() :: [String.t()]
  def scopes, do: Arca.ToolGrantStorage.scopes()

  @doc "The effects a grant may carry: `\"allow\"` or `\"deny\"`."
  @spec effects() :: [String.t()]
  def effects, do: Arca.ToolGrantStorage.effects()

  @doc """
  Every grant bearing on one thread in the caller's athanor: the thread's
  own thread-scope rows and every agent-scope row. A bounded allow is
  answered only while it stands: before its deadline and while its
  lifecycle's row is open.

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
  The row a decision writes, built and checked but not written, for a
  caller whose storage lands it inside a transaction of its own (the turn
  store writes it with the decision that made it).

  `attrs` names `scope`, `effect`, `agent_name`, `tool`, `action` and, at
  thread scope, `thread_id`; an allow may name its bounds,
  `lifecycle_kind` with `lifecycle_id`, `expires_at` and `constraint`.
  The athanor and the deciding person come from the context. A context
  with no tenant is `:forbidden`; attributes that do not make a grant are
  `:invalid_argument`; an answer that may not stand is refused with its
  reason (`check_standing/2`).
  """
  @spec grant_row(Context.t(), map()) ::
          {:ok, map()} | {:error, :invalid_argument | :forbidden | refusal()}
  def grant_row(%Context{} = ctx, attrs) when is_map(attrs) do
    with {:ok, row} <- build(ctx, attrs, :decision),
         :ok <- check_standing(row, DateTime.utc_now()) do
      {:ok, row}
    else
      {:error, :no_athanor} -> {:error, :forbidden}
      {:error, {:invalid, _field_errors}} -> {:error, :invalid_argument}
      {:error, {:scope_not_permitted, _reason}} = refusal -> refusal
    end
  end

  @doc """
  Record a decision in the caller's athanor, replacing whatever the same
  key said before. The attributes are `grant_row/2`'s, and an answer that
  may not stand is refused with its reason before anything is written.
  """
  @spec put(Context.t(), map()) ::
          {:ok, grant()}
          | {:error, :unavailable | :no_athanor | {:invalid, field_errors()} | refusal()}
  def put(%Context{} = ctx, attrs) when is_map(attrs) do
    with {:ok, row} <- build(ctx, attrs, :decision),
         :ok <- check_standing(row, DateTime.utc_now()) do
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

  @doc """
  Whether an answer may stand, at `now`: `:ok`, or the reason it is
  refused.

  `attrs` is a decision or a stored row: its `scope`, `effect`, `tool`
  and `action`, and any bounds. A deny stands exactly when it carries no
  bound. An allow stands only while the action's current declaration,
  read through `Sanctum.Grimoire`, would take it at its scope, and its
  bounds are well formed: a lifecycle names its kind and its row
  together, a deadline is after `now`, and a constraint is a resource
  kind the action declares with patterns in the store's one grammar for
  it (`Arca.ToolGrantStorage.constraint_errors/2`): a storage path names
  one path or a folder ending in `/`, never a wildcard. Both
  writes apply it, and a reader applies it to every row it reads back.
  """
  @spec check_standing(map(), DateTime.t()) :: :ok | {:error, refusal()}
  def check_standing(attrs, %DateTime{} = now) when is_map(attrs) do
    case standing(attrs, now) do
      {:ok, _declaration} -> :ok
      {:error, _refusal} = refusal -> refusal
    end
  end

  @doc """
  Whether a bounded allow covers `call`, as it is asked: `true` only when
  no deny stands for the pair and a bounded allow for the call's agent,
  tool and action, read fresh from the store, still stands
  (`check_standing/2`, at this moment) and covers the call — its
  lifecycle is the call's own execution, turn or the schedule its
  execution was started by, and the call's resource argument lies inside
  its constraint: a path read as the storage door reads it (refused when
  absolute or unsafe, then matched as the call spells it by
  `Prima.ComponentPath.path_granted?/2`), or a host as the egress policy
  matches it. An unbounded allow is the policy's to answer, not this.

  A store that cannot be read, a call that names no thread or agent, and
  a call whose resource argument is absent or unsafe are all `false`: a
  bounded allow that cannot be checked is not one.
  """
  @spec admits?(Context.t(), call()) :: boolean()
  def admits?(
        %Context{} = ctx,
        %{agent_name: agent, thread_id: thread_id, tool: tool, action: action} = call
      )
      when is_binary(agent) and is_binary(thread_id) and is_binary(tool) and is_binary(action) do
    case for_thread(ctx, thread_id) do
      {:ok, rows} ->
        now = DateTime.utc_now()

        rows =
          Enum.filter(rows, &(&1.agent_name == agent and &1.tool == tool and &1.action == action))

        not Enum.any?(rows, &(&1.effect == "deny")) and
          Enum.any?(rows, &covers?(ctx, &1, call, now))

      {:error, _unreadable} ->
        false
    end
  end

  def admits?(%Context{}, _call), do: false

  # ---------------------------------------------------------------------------
  # The rule
  # ---------------------------------------------------------------------------

  # The declaration an allow stood on, for a caller that goes on to judge
  # its bounds against a call; a deny stands on none.
  defp standing(%{effect: "deny"} = attrs, _now) do
    if bounded?(attrs), do: refuse(:bounded_deny), else: {:ok, nil}
  end

  defp standing(%{effect: "allow", scope: scope, tool: tool, action: action} = attrs, now)
       when is_binary(tool) and is_binary(action) do
    with :ok <- known_scope(scope),
         {:ok, declaration} <- declaration(tool, action),
         :ok <- standing_kind(declaration.kind),
         :ok <- declared_standing(declaration.standing, scope),
         :ok <- lifecycle(attrs),
         :ok <- deadline(attrs, now),
         :ok <- constraint(attrs, declaration.resource) do
      {:ok, declaration}
    end
  end

  # A row whose scope, effect or pair is outside the vocabulary — nothing
  # writes one, but a stored row is read back trusting nobody — stands as
  # no allow.
  defp standing(_attrs, _now), do: refuse(:unknown_kind)

  defp known_scope(scope) do
    if scope in scopes(), do: :ok, else: refuse(:unknown_kind)
  end

  defp declaration(tool, action) do
    case Sanctum.Grimoire.action_declaration("#{tool}.#{action}") do
      {:ok, %{kind: _, standing: _, resource: _} = declaration} -> {:ok, declaration}
      _ -> refuse(:unknown_kind)
    end
  end

  defp standing_kind(kind) when kind in [:destructive, :external], do: refuse(kind)
  defp standing_kind(kind) when kind in @standing_kinds, do: :ok
  defp standing_kind(_kind), do: refuse(:unknown_kind)

  # `false` takes no standing allow, `:thread` none at agent scope, and no
  # declaration either scope; any other value is read as the narrowest.
  defp declared_standing(nil, _scope), do: :ok
  defp declared_standing(:thread, "thread"), do: :ok
  defp declared_standing(:thread, _scope), do: refuse(:thread_only)
  defp declared_standing(_standing, _scope), do: refuse(:never_standing)

  # A lifecycle names its kind and the row it ends with, together.
  defp lifecycle(attrs) do
    case {Map.get(attrs, :lifecycle_kind), Map.get(attrs, :lifecycle_id)} do
      {nil, nil} ->
        :ok

      {kind, id} when is_binary(kind) and is_binary(id) and id != "" ->
        if kind in Arca.ToolGrantStorage.lifecycle_kinds(),
          do: :ok,
          else: refuse(:invalid_lifecycle)

      _ ->
        refuse(:invalid_lifecycle)
    end
  end

  defp deadline(attrs, now) do
    case Map.get(attrs, :expires_at) do
      nil ->
        :ok

      %DateTime{} = at ->
        if DateTime.compare(at, now) == :gt, do: :ok, else: refuse(:deadline_passed)

      _ ->
        refuse(:invalid_deadline)
    end
  end

  # A constraint only for an action that declares its resource, of that
  # resource's kind, with patterns in the one grammar the store holds a
  # row to (`Arca.ToolGrantStorage.constraint_errors/2`), so no answer this
  # rule lets stand is refused by the write. A stored constraint that does
  # not decode (`:corrupt`) is none of these.
  defp constraint(attrs, resource) do
    case {Map.get(attrs, :constraint), resource} do
      {nil, _resource} ->
        :ok

      {_constraint, nil} ->
        refuse(:no_resource)

      {constraint, {_argument, kind}} ->
        declared = Atom.to_string(kind)

        case constraint_parts(constraint) do
          {:ok, ^declared, patterns} ->
            if Arca.ToolGrantStorage.constraint_errors(declared, patterns) == [],
              do: :ok,
              else: refuse(:invalid_constraint)

          {:ok, _other, _patterns} ->
            refuse(:resource_kind)

          :error ->
            refuse(:invalid_constraint)
        end
    end
  end

  defp constraint_parts(%{} = constraint) do
    kind = Map.get(constraint, :kind, Map.get(constraint, "kind"))
    patterns = Map.get(constraint, :patterns, Map.get(constraint, "patterns"))

    kind =
      if is_atom(kind) and not is_nil(kind) and not is_boolean(kind),
        do: Atom.to_string(kind),
        else: kind

    if is_binary(kind), do: {:ok, kind, patterns}, else: :error
  end

  defp constraint_parts(_constraint), do: :error

  defp bounded?(attrs), do: Enum.any?(@bounds, &(not is_nil(Map.get(attrs, &1))))

  defp refuse(reason), do: {:error, {:scope_not_permitted, reason}}

  # ---------------------------------------------------------------------------
  # One call against one row
  # ---------------------------------------------------------------------------

  defp covers?(ctx, %{effect: "allow"} = row, call, now) do
    bounded?(row) and
      case standing(row, now) do
        {:ok, declaration} ->
          within_lifecycle?(ctx, row, call) and within_constraint?(row, declaration, call)

        {:error, _refusal} ->
          false
      end
  end

  defp covers?(_ctx, _row, _call, _now), do: false

  # The row answered only while its lifecycle's row is open (the store's
  # read joins it); here it must also be the call's own.
  defp within_lifecycle?(ctx, row, call) do
    id = Map.get(row, :lifecycle_id)

    case Map.get(row, :lifecycle_kind) do
      nil -> true
      "execution" -> own?(id, Map.get(call, :execution_id))
      "turn" -> own?(id, Map.get(call, :turn_id))
      "schedule" -> own?(id, schedule_of(ctx, Map.get(call, :execution_id)))
      _other -> false
    end
  end

  defp own?(id, call_id), do: is_binary(id) and is_binary(call_id) and id == call_id

  # The schedule the call's execution was started by, read in the caller's
  # athanor; none, for an execution no schedule started or one not found.
  defp schedule_of(ctx, execution_id) when is_binary(execution_id) do
    case Arca.Execution.get_tenant(Context.actor(ctx), execution_id) do
      %{schedule_id: schedule_id} when is_binary(schedule_id) -> schedule_id
      _ -> nil
    end
  end

  defp schedule_of(_ctx, _execution_id), do: nil

  # The row's constraint as the store answers it, decoded; `standing/2`
  # has already held it to the action's declared kind and grammar.
  defp within_constraint?(row, declaration, call) do
    case {Map.get(row, :constraint), declaration} do
      {nil, _declaration} ->
        true

      {%{kind: kind, patterns: patterns}, %{resource: {argument, declared}}} ->
        args = Map.get(call, :args)
        value = if is_map(args), do: Map.get(args, argument)
        kind == Atom.to_string(declared) and inside?(kind, value, patterns)

      _unreadable ->
        false
    end
  end

  # A path is read as the storage door reads one (`Crucible.GuestStorage`):
  # refused whole when it is absolute or a segment is unsafe (`..`, `.`, an
  # encoded dot, a backslash), then matched as the call spells it against
  # the constraint's patterns by the door's own rule
  # (`Prima.ComponentPath.path_granted?/2`). A pattern ending in `/` covers
  # the folder and everything below it, any other names one path; a
  # constraint holds no wildcard (`Arca.Schemas.ToolGrant`).
  defp inside?("storage_path", value, patterns) when is_binary(value) do
    value != "" and Prima.PathSafety.validate_relative_path(value) == :ok and
      Prima.ComponentPath.path_granted?(value, patterns)
  end

  # A host is matched as the egress policy matches one; a wildcard is a
  # pattern, never a host a call may name.
  defp inside?("egress_domain", value, patterns) when is_binary(value) do
    not String.starts_with?(value, "*") and Prima.Manifest.valid_connect_domain?(value) and
      Prima.Network.domain_allowed?(value, patterns)
  end

  defp inside?(_kind, _value, _patterns), do: false

  # ---------------------------------------------------------------------------
  # Rows
  # ---------------------------------------------------------------------------

  # The one shape both writes and the key a revoke deletes by. An
  # agent-scope row names no thread: it is the same answer in every
  # thread, and keeping the one it was given in would make the key
  # ambiguous. A decision carries its effect, the person who made it and
  # any bound it names; a key is only what identifies the row.
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
        :key ->
          {:ok, key}

        :decision ->
          bounds =
            attrs |> Map.take(@bounds) |> Map.reject(fn {_field, value} -> is_nil(value) end)

          {:ok,
           key
           |> Map.merge(%{effect: attrs.effect, granted_by: ctx.user_id})
           |> Map.merge(bounds)}
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
  defp check_effect(errors, attrs, :decision),
    do: require_member(errors, attrs, :effect, effects())

  defp check_effect(errors, _attrs, :key), do: errors

  defp require_text(errors, attrs, field) do
    case Map.get(attrs, field) do
      value when is_binary(value) and value != "" -> errors
      _ -> Map.put(errors, field, ["can't be blank"])
    end
  end

  defp check_thread(errors, %{scope: "thread"} = attrs),
    do: require_text(errors, attrs, :thread_id)

  defp check_thread(errors, _attrs), do: errors
end
