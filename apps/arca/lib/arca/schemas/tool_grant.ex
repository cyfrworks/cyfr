# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.ToolGrant do
  @moduledoc """
  A standing decision a person made about one `tool.action` for one agent
  of the athanor the row belongs to.

  Distinct from the agent's markdown `tool_policy`, which is **authored**
  policy — what the agent's author says it may do. A grant is what a human
  answered when asked, and the two are composed at use time by
  `Aqua.ToolGrants.effective/2`.

  `scope` says how far the answer reaches: `"thread"` — this thread
  only, surviving a runner restart — or `"agent"` — every thread
  this agent runs in, in this athanor. An agent belongs to the athanor whose
  `aqua/` tree holds it, so the row's `athanor_id` is the agent's athanor
  as well as the tenancy that reclaims the row.

  `effect` is `"allow"` or `"deny"`; deny is where the decline verb
  ("never ask me this again") lives, and it beats an authored `"auto"`.
  The vocabulary is spelled here, once, and validated at the write.

  An allow may carry bounds: the lifecycle it ends with
  (`lifecycle_kind`, `execution`, `turn` or `schedule`, and
  `lifecycle_id`, that row's id), a deadline (`expires_at`) and a
  `constraint`, a resource kind (`storage_path`, `egress_domain` or
  `vault_entry`) and its patterns, stored as JSON in the one grammar
  `constraint_errors/2` spells. A deny carries none of the four, so a standing deny never
  lapses; one written with any is refused.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @type t :: %__MODULE__{}

  @scopes ~w(thread agent)
  @effects ~w(allow deny)
  @lifecycle_kinds ~w(execution turn schedule)
  @constraint_kinds Enum.map(Prima.Operation.resource_kinds(), &Atom.to_string/1)
  @bounds [:lifecycle_kind, :lifecycle_id, :expires_at, :constraint]
  @max_patterns 64
  # An entry's id as the stores mint it: a lowercase prefix, an underscore
  # and the id itself. No wildcard and no separator, so a pattern names one
  # entry exactly.
  @entry_id ~r/\A[a-z][a-z0-9]*_[A-Za-z0-9-]{1,128}\z/

  schema "tool_grants" do
    field :athanor_id, :string
    field :scope, :string
    field :effect, :string
    field :thread_id, :string
    field :agent_name, :string
    field :tool, :string
    field :action, :string
    field :granted_by, :string
    field :granted_at, :utc_datetime_usec
    field :lifecycle_kind, :string
    field :lifecycle_id, :string
    field :expires_at, :utc_datetime_usec
    field :constraint, :string
  end

  @doc "The lifecycles a bounded allow may end with."
  @spec lifecycle_kinds() :: [String.t()]
  def lifecycle_kinds, do: @lifecycle_kinds

  @doc "The resource kinds a constraint may name (`Prima.Operation.resource_kinds/0`)."
  @spec constraint_kinds() :: [String.t()]
  def constraint_kinds, do: @constraint_kinds

  @doc "The scopes a grant may carry."
  @spec scopes() :: [String.t()]
  def scopes, do: @scopes

  @doc "The effects a grant may carry."
  @spec effects() :: [String.t()]
  def effects, do: @effects

  @doc "The scope of an answer for one thread."
  @spec thread_scope() :: String.t()
  def thread_scope, do: "thread"

  @doc "The scope of an answer for the agent wherever it runs in its athanor."
  @spec agent_scope() :: String.t()
  def agent_scope, do: "agent"

  @doc """
  The row a write is held to: every key present, the scope and effect in
  the vocabulary, and a thread named exactly when the scope is a
  thread's. The partial unique indexes are declared by the storage
  module, which knows the names each adapter reports them by.
  """
  @spec changeset(t() | map(), map()) :: Ecto.Changeset.t()
  def changeset(grant \\ %__MODULE__{}, attrs) do
    {constraint, attrs} = Map.pop(Map.new(attrs), :constraint)

    grant
    |> cast(attrs, [
      :id,
      :athanor_id,
      :scope,
      :effect,
      :thread_id,
      :agent_name,
      :tool,
      :action,
      :granted_by,
      :granted_at,
      :lifecycle_kind,
      :lifecycle_id,
      :expires_at
    ])
    |> validate_required([
      :id,
      :athanor_id,
      :scope,
      :effect,
      :agent_name,
      :tool,
      :action,
      :granted_at
    ])
    |> validate_inclusion(:scope, @scopes)
    |> validate_inclusion(:effect, @effects)
    |> validate_thread()
    |> put_constraint(constraint)
    |> validate_lifecycle()
    |> validate_bounds()
  end

  @doc """
  A stored constraint read back: `%{kind: kind, patterns: [pattern]}`, or
  nil for none. A stored value that does not decode is `:corrupt`, which a
  reader treats as a grant it cannot answer.
  """
  @spec decode_constraint(String.t() | nil) ::
          %{kind: String.t(), patterns: [String.t()]} | nil | :corrupt
  def decode_constraint(nil), do: nil

  def decode_constraint(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{"kind" => kind, "patterns" => patterns}} ->
        case constraint_errors(kind, patterns) do
          [] -> %{kind: kind, patterns: patterns}
          _errors -> :corrupt
        end

      _ ->
        :corrupt
    end
  end

  # A constraint arrives as a map of its kind and patterns and is stored as
  # JSON; a string or any other shape is refused rather than stored as given.
  defp put_constraint(changeset, nil), do: changeset

  defp put_constraint(changeset, %{} = constraint) do
    kind = Map.get(constraint, :kind, Map.get(constraint, "kind"))
    patterns = Map.get(constraint, :patterns, Map.get(constraint, "patterns"))
    kind = if is_atom(kind) and not is_nil(kind), do: Atom.to_string(kind), else: kind

    case constraint_errors(kind, patterns) do
      [] ->
        put_change(
          changeset,
          :constraint,
          Jason.encode!(%{"kind" => kind, "patterns" => patterns})
        )

      [error | _] ->
        add_error(changeset, :constraint, error)
    end
  end

  defp put_constraint(changeset, _other),
    do: add_error(changeset, :constraint, "is a resource kind and its patterns")

  @doc """
  The one constraint grammar: `[]` for a resource kind and patterns a
  row may carry, else why not. A kind a constraint may name
  (`constraint_kinds/0`); between one and #{@max_patterns} patterns, none
  twice; each in its kind's grammar — a storage path is a safe relative
  path, literal or a folder ending in `/`, never a wildcard, an egress
  domain a bare domain with an optional `*.` prefix, and a vault entry
  an entry's id (`<prefix>_<id>`), compared with the id a call's named
  account resolves to and never with the name. The write
  holds a row to it, and the rule that decides which answers may stand
  (`Sanctum.ToolGrants.check_standing/2`) asks it before the write.
  """
  @spec constraint_errors(term(), term()) :: [String.t()]
  def constraint_errors(kind, patterns) do
    cond do
      kind not in @constraint_kinds ->
        ["names no resource kind a constraint may carry"]

      not is_list(patterns) or patterns == [] or length(patterns) > @max_patterns ->
        ["names between one and #{@max_patterns} patterns"]

      length(Enum.uniq(patterns)) != length(patterns) ->
        ["names a pattern twice"]

      not Enum.all?(patterns, &pattern?(kind, &1)) ->
        ["names a pattern outside the #{kind} grammar"]

      true ->
        []
    end
  end

  # The storage-path grammar is the storage layer's own denylist, with no
  # wildcard: a pattern names one path or, ending in `/`, one folder, and
  # every reader of a stored constraint reads it the same way (a `*` some
  # path matcher reads as every path would widen the answer). The
  # egress-domain grammar is a bare domain with an optional `*.` prefix.
  defp pattern?("storage_path", pattern) when is_binary(pattern) and pattern != "",
    do:
      not String.contains?(pattern, "*") and
        Prima.PathSafety.validate_relative_path(pattern) == :ok

  defp pattern?("egress_domain", pattern) when is_binary(pattern),
    do: Prima.Manifest.valid_connect_domain?(pattern)

  defp pattern?("vault_entry", pattern) when is_binary(pattern),
    do: Regex.match?(@entry_id, pattern)

  defp pattern?(_kind, _pattern), do: false

  defp validate_lifecycle(changeset) do
    case {get_field(changeset, :lifecycle_kind), get_field(changeset, :lifecycle_id)} do
      {nil, nil} ->
        changeset

      {nil, _id} ->
        add_error(changeset, :lifecycle_kind, "names no lifecycle for its id")

      {_kind, nil} ->
        changeset
        |> validate_inclusion(:lifecycle_kind, @lifecycle_kinds)
        |> add_error(:lifecycle_id, "names no row for its lifecycle")

      {_kind, _id} ->
        validate_inclusion(changeset, :lifecycle_kind, @lifecycle_kinds)
    end
  end

  # A deny carries no bound: a standing deny never lapses.
  defp validate_bounds(changeset) do
    if get_field(changeset, :effect) == "deny" do
      Enum.reduce(@bounds, changeset, fn field, acc ->
        if is_nil(get_field(acc, field)),
          do: acc,
          else: add_error(acc, field, "a deny carries no bound")
      end)
    else
      changeset
    end
  end

  defp validate_thread(changeset) do
    case {get_field(changeset, :scope), get_field(changeset, :thread_id)} do
      {"thread", nil} ->
        add_error(changeset, :thread_id, "names no thread")

      {"agent", id} when is_binary(id) ->
        add_error(changeset, :thread_id, "an agent-scope answer names no thread")

      _ ->
        changeset
    end
  end
end
