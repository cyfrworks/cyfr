# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.Mount do
  @moduledoc """
  A catalyst's login need mounted into the program row it is bound to.

  A program row with a kept home (`mcp_servers`, `home: "kept"`) has one
  folder, its own: the home's id is the row's id, made with the row and
  retired with it. The box that holds the home (the backends service)
  keeps what the program keeps there, under a uid of the home's own that
  it draws when it first makes the home, and no CYFR process can read it.
  A grant that lets a catalyst's login need use the folder binds the need
  to the row: the binding's value is the row's id.

  `resolve/5` decides a component's login need for one run and answers
  the program row, never material, in this order, each before anything
  after it is touched:

    1. the run's binding of the need is live (`Sanctum.Attach.live/3`: the
       run's pins, the head consent, the binding's row and a lender's),
       read without consuming a `once` binding;
    2. the binding is the athanor's own: a program's folder is never
       shared, so a binding through a share is `:connection_not_granted`;
    3. the row it names stands in the athanor, enabled, a `driven`
       program with a kept home (`{:program_unavailable, name}`
       otherwise), and its name is the program the component's trusted
       manifest names for the need (`{:another_program, row_name}`
       otherwise: the binding mounts another program);
    4. only then is the binding used (`Sanctum.Attach.lifetime/3`), which
       consumes a `once` binding for this root, so a mount refused by any
       check above consumes nothing.

  `agents_mounting/2` and `orphaned_homes/1` are the reads the programs
  controller makes of the same rows: the agents whose brain runs in a
  home it resets or retires, and the homes a box holds that no kept row
  holds any more.
  """

  alias Prima.Authority
  alias Prima.Authority.Blob
  alias Prima.Authority.Blob.Edge
  alias Sanctum.{Attach, Context}

  @typedoc "A kept home's id: its program row's id."
  @type home_id :: String.t()

  @typedoc "Why a mount did not resolve."
  @type refusal ::
          :anonymous_denied
          | :connection_not_granted
          | :grant_expired
          | :unavailable
          | {:program_unavailable, String.t()}
          | {:another_program, String.t()}
          | {:unavailable, String.t()}

  @doc """
  The program row the run's binding of `need_name` mounts, as the module
  doc orders the checks: `{:ok, row}`, whose id is the kept home's.
  `authority` is the run's (`Prima.Authority`), whose edge's binding is
  the need's; `program` is the name the component's trusted manifest
  gives the need; `root_execution_id` is the run's root, which a `once`
  binding is consumed for.
  """
  @spec resolve(Context.t(), Authority.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, refusal()}
  def resolve(%Context{anonymous: true}, _authority, _need_name, _program, _root),
    do: {:error, :anonymous_denied}

  def resolve(%Context{} = ctx, %Authority{} = authority, need_name, program, root_execution_id)
      when is_binary(need_name) and is_binary(program) and is_binary(root_execution_id) do
    use = %{
      root_execution_id: root_execution_id,
      profile_id: authority.profile_id,
      consent_id: authority.consent_id
    }

    with {:ok, binding} <- binding(authority, need_name),
         :ok <- Attach.live(ctx, binding, use),
         :ok <- own(binding),
         {:ok, row} <- program_row(ctx, binding.entry_id, program),
         :ok <- Attach.lifetime(ctx, binding, use) do
      {:ok, row}
    end
  end

  # The edge's binding of the need: a row id under a key whose edge names
  # this need when it names one.
  defp binding(%Authority{resources: %Edge{} = edge}, need_name) do
    with {:ok, %{entry_id: row_id, binding_key: key} = binding} when is_binary(row_id) <-
           Blob.vault_for(edge, nil),
         true <- names_need?(key, need_name) do
      {:ok, binding}
    else
      _unbound_or_another_need -> {:error, :connection_not_granted}
    end
  end

  defp binding(_authority, _need_name), do: {:error, :connection_not_granted}

  # An edge key spells a named need as `<ref>|<need>` and the unnamed slot
  # as the bare ref; a key naming another need is not this need's binding.
  defp names_need?(key, need_name) do
    case Blob.parse_binding_key(key) do
      {:ok, {_node, edge_key, _slot}} ->
        case String.split(edge_key, "|", parts: 2) do
          [_ref, need] -> need == need_name
          [_bare_ref_or_ingress] -> true
        end

      :error ->
        false
    end
  end

  defp own(%{scope: "athanor"}), do: :ok
  defp own(_shared_or_unscoped), do: {:error, :connection_not_granted}

  # The row the binding names must be the athanor's own driven program with
  # a kept home, enabled, and the program the trusted manifest names.
  defp program_row(ctx, row_id, program) do
    case Arca.McpServerStorage.get_by_id(Context.actor(ctx), row_id) do
      {:ok, %{enabled: true, transport: "program", mark: "driven", home: "kept"} = row} ->
        if row.name == program, do: {:ok, row}, else: {:error, {:another_program, row.name}}

      {:error, reason} when reason in [:database_error, :unavailable] ->
        {:error, {:unavailable, "Programs"}}

      _absent_or_unfit ->
        {:error, {:program_unavailable, program}}
    end
  end

  @doc """
  The names of the agents of `athanor_id`, the soul's included, whose
  brain runs in the kept home of the program row `row_id`: the agent's
  head binds the row on its own edge to its brain (the catalyst its
  index row names), or selects there a profile of that brain whose own
  ingress binds it (`Arca.ConsentStorage.head_edges_binding/2`). An edge
  to a hand is no brain's. `{:error, :unavailable}` when the store cannot
  answer.
  """
  @spec agents_mounting(String.t(), String.t()) :: {:ok, [String.t()]} | {:error, :unavailable}
  def agents_mounting(athanor_id, row_id)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(row_id) do
    actor = Prima.Actor.in_athanor(athanor_id)

    with {:ok, edges} <- Arca.ConsentStorage.head_edges_binding(actor, row_id),
         {:ok, agents} <- Arca.AgentStorage.list(actor) do
      {:ok,
       for(
         %{name: name, catalyst_ref: brain} when is_binary(brain) <- agents,
         {:ok, brain} <- [Prima.ComponentRef.to_name_ref(brain)],
         source = Prima.AgentRef.ref(name),
         {source, source, brain} in edges,
         do: name
       )}
    else
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  @doc """
  Which of the kept homes `home_ids` (a box's) no program row keeps any
  more, with the athanor each was its row's (nil for a row that is gone):
  its row deleted, no longer a program with a kept home, or its athanor
  archived. The positive evidence the programs controller retires a home
  on; a home whose row stands is not named. `{:error, :unavailable}` when
  the store cannot answer, so the sweep retires nothing and asks again
  later.
  """
  @spec orphaned_homes([home_id()]) ::
          {:ok, [{home_id(), String.t() | nil}]} | {:error, :unavailable}
  def orphaned_homes(home_ids) when is_list(home_ids) do
    case Arca.McpServerStorage.standing(home_ids) do
      {:ok, standing} ->
        orphans =
          Enum.flat_map(home_ids, fn id ->
            case orphaned(Map.get(standing, id)) do
              :stands -> []
              athanor_id -> [{id, athanor_id}]
            end
          end)

        {:ok, orphans}

      {:error, _unanswered} ->
        {:error, :unavailable}
    end
  end

  defp orphaned(nil), do: nil
  defp orphaned(%{kept: true, athanor_archived: false}), do: :stands
  defp orphaned(%{athanor_id: athanor_id}), do: athanor_id
end
