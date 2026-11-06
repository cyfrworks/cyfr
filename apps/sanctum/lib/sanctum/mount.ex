# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.Mount do
  @moduledoc """
  The fifth use of a vault entry: a login entry mounted into its program.

  A login entry (`kind: "login"`, `Sanctum.Vault.create/2`) points at a
  program's own sign-in. Its destination is the program form
  `{"program": name}`, naming the `mcp_servers` row it signs in to; it
  holds no material, is attach-only, and its id is the id of the kept
  home the program runs in. The vault never holds what the program keeps
  there: the box that holds the home (the backends service) does, under a
  uid of the home's own that it draws when it first makes the home, and
  no CYFR process can read it. Mounting is the only use of such an entry:
  it is never attached, dispensed or disclosed (`Sanctum.VaultReader`,
  `Sanctum.Attach`).

  `resolve/4` decides a component's login need for one run and answers
  the kept home and the program row, never material, in this order, each
  before anything after it is touched:

    1. the run's binding of the need is live (`Sanctum.Attach.live/3`: the
       run's pins, the head consent, the binding's row and a lender's),
       read without consuming a `once` binding;
    2. a binding through a share is refused `{:not_built, :shared_login}`:
       a recipient's use of a shared login entry is not built yet;
    3. the entry is active at the binding digest the consent approved
       (`Sanctum.VaultReader.usable/3`) and is a login entry
       (`:not_mountable` otherwise);
    4. the entry's destination names the program the consent approved,
       and that program's row stands in the athanor, enabled, a program
       (`stdio` or `pipe`) with a kept home
       (`{:program_unavailable, name}` otherwise);
    5. only then is the binding used (`Sanctum.Attach.lifetime/3`), which
       consumes a `once` binding for this root, so a mount refused by any
       check above consumes nothing.

  `login_entry/3`, `home_of/2` and `login_entries/1` are the reads the
  programs controller and its surfaces make of the same entries: the
  entry a person names for a program's sign-in or reset, the home a
  deleted entry leaves behind, and the homes of an archived athanor.
  """

  alias Prima.Authority
  alias Prima.Authority.Blob
  alias Prima.Authority.Blob.Edge
  alias Sanctum.{Attach, Context, VaultReader}

  @login "login"

  @typedoc "A kept home's id: the login entry's id."
  @type home_id :: String.t()

  @typedoc "Why a mount did not resolve."
  @type refusal ::
          :anonymous_denied
          | :connection_not_granted
          | :grant_expired
          | :unavailable
          | :not_mountable
          | {:not_built, :shared_login}
          | {:program_unavailable, String.t()}
          | :not_found
          | {:entry_unavailable, String.t() | nil, String.t()}
          | {:binding_mismatch, String.t() | nil}
          | {:unavailable, String.t()}

  @doc """
  The kept home and the program row the run's binding of `need_name`
  mounts, as the module doc orders the checks: `{:ok, {:mount, home_id,
  row}}`. `authority` is the run's (`Prima.Authority`), whose edge's
  binding is the need's; `root_execution_id` is the run's root, which a
  `once` binding is consumed for.
  """
  @spec resolve(Context.t(), Authority.t(), String.t(), String.t()) ::
          {:ok, {:mount, home_id(), map()}} | {:error, refusal()}
  def resolve(%Context{anonymous: true}, _authority, _need_name, _root),
    do: {:error, :anonymous_denied}

  def resolve(%Context{} = ctx, %Authority{} = authority, need_name, root_execution_id)
      when is_binary(need_name) and is_binary(root_execution_id) do
    use = %{
      root_execution_id: root_execution_id,
      profile_id: authority.profile_id,
      consent_id: authority.consent_id
    }

    with {:ok, vault} <- binding(authority, need_name),
         :ok <- live(ctx, vault, use),
         :ok <- own(vault),
         {:ok, entry} <- usable(ctx, vault),
         {:ok, row} <- program_row(ctx, entry, vault),
         :ok <- Attach.lifetime(ctx, vault, use) do
      {:ok, {:mount, entry.id, row}}
    end
  end

  # The edge's binding of the need: an entry bound to a program
  # destination, under a key whose edge names this need when it names one.
  defp binding(%Authority{resources: %Edge{} = edge}, need_name) do
    with {:ok,
          %{entry_id: _, binding_key: key, destination: %Prima.Destination{program: p}} = vault}
         when is_binary(p) <- Blob.vault_for(edge, nil),
         true <- names_need?(key, need_name) do
      {:ok, vault}
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

  defp live(ctx, vault, use) do
    case Attach.live(ctx, vault, use) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp own(%{scope: "athanor"}), do: :ok
  defp own(%{scope: "share"}), do: {:error, {:not_built, :shared_login}}
  defp own(_other_scope), do: {:error, :connection_not_granted}

  defp usable(%Context{} = ctx, vault) do
    with {:ok, entry} <-
           VaultReader.usable(Context.athanor!(ctx), vault.entry_id, vault.binding_digest) do
      if entry.kind == @login, do: {:ok, entry}, else: {:error, :not_mountable}
    end
  end

  # The program the entry names must be the one the consent approved, and
  # its row must stand as a program with a kept home.
  defp program_row(ctx, entry, %{destination: %Prima.Destination{program: approved}}) do
    with {:ok, named} <- entry_program(entry),
         true <- named == approved,
         {:ok, row} <- Arca.McpServerStorage.get(Context.actor(ctx), approved),
         true <- mountable_row?(row) do
      {:ok, row}
    else
      {:error, reason} when reason in [:database_error, :unavailable] ->
        {:error, {:unavailable, "Programs"}}

      _another_program_absent_or_unfit ->
        {:error, {:program_unavailable, approved}}
    end
  end

  defp mountable_row?(%{enabled: true, transport: transport, home: "kept"})
       when transport in ["stdio", "pipe"],
       do: true

  defp mountable_row?(_row), do: false

  defp entry_program(%{destination: text}) when is_binary(text) do
    with {:ok, %{} = map} <- Prima.Json.decode(text),
         {:ok, %Prima.Destination{program: program}} when is_binary(program) <-
           Prima.Destination.from_map(map) do
      {:ok, program}
    else
      _hosts_or_unreadable -> :error
    end
  end

  @doc """
  The active login entry of the context's athanor that `entry` names, by
  id or by name, whose destination names `program`: what a person picks
  for a program's sign-in or the reset of its home. A missing entry, one
  of another athanor, one not active, one of another kind and one naming
  another program are `{:error, :not_found}`, `{:error, {:entry_unavailable,
  status}}`, `{:error, :not_a_login_entry}` and `{:error,
  {:another_program, name}}`; a store that cannot answer is
  `{:error, {:unavailable, "Vault"}}`.

  With `for: :sign_in` an entry whose program is not signed in
  (`needs_reauth`: a new entry, or one a restore left) is admitted too:
  signing the program in is how it becomes active (`signed_in/2`).
  """
  @spec login_entry(Context.t(), String.t(), String.t(), keyword()) ::
          {:ok, %{id: String.t(), name: String.t(), status: String.t()}} | {:error, term()}
  def login_entry(%Context{} = ctx, entry, program, opts \\ [])
      when is_binary(entry) and is_binary(program) and is_list(opts) do
    actor = Context.actor(ctx)

    with {:ok, row} <- by_id_or_name(actor, entry),
         :ok <- active(row, Keyword.get(opts, :for)),
         :ok <- login(row),
         {:ok, named} <- entry_program(row) |> program_named(),
         :ok <- if(named == program, do: :ok, else: {:error, {:another_program, named}}) do
      {:ok, %{id: row.id, name: row.name, status: row.status}}
    end
  end

  @doc """
  A sign-in of the login entry `entry_id` whose command exited 0, in the
  interactive session that opened it: an entry whose program was not
  signed in (`needs_reauth`: a new entry, or one a restore left) is
  active, the person's own deliberate act, as re-authorizing an OAuth
  entry is. An active entry stays as it is. Only
  the sign-in relay calls it, and nothing else makes a login entry active
  again. Answers `:ok`, or `{:error, reason}` for an entry that is not
  this athanor's login entry or a store that cannot answer.
  """
  @spec signed_in(Context.t(), String.t()) :: :ok | {:error, term()}
  def signed_in(%Context{} = ctx, entry_id) when is_binary(entry_id) do
    actor = Context.actor(ctx)

    with {:ok, row} <- by_id_or_name(actor, entry_id),
         :ok <- login(row) do
      case row.status do
        "active" ->
          :ok

        "needs_reauth" ->
          case Arca.VaultStorage.set_status(actor, row.id, "active") do
            {:ok, _} ->
              Sanctum.Telemetry.vault_entry_changed(
                Context.athanor!(ctx),
                row.id,
                :rotate,
                %{name: row.name}
              )

              :ok

            {:error, _} = error ->
              error
          end

        status ->
          {:error, {:entry_unavailable, status}}
      end
    end
  end

  defp by_id_or_name(actor, entry) do
    result =
      case Arca.VaultStorage.get(actor, entry) do
        {:ok, %{status: "tombstoned"}} -> Arca.VaultStorage.get_by_name(actor, entry)
        {:ok, row} -> {:ok, row}
        {:error, :not_found} -> Arca.VaultStorage.get_by_name(actor, entry)
        other -> other
      end

    case result do
      {:ok, row} -> {:ok, row}
      {:error, :not_found} -> {:error, :not_found}
      {:error, _unanswered} -> {:error, {:unavailable, "Vault"}}
    end
  end

  defp active(%{status: "active"}, _for), do: :ok
  defp active(%{status: "needs_reauth"}, :sign_in), do: :ok
  defp active(%{status: status}, _for), do: {:error, {:entry_unavailable, status}}

  defp login(%{kind: @login}), do: :ok
  defp login(_entry), do: {:error, :not_a_login_entry}

  defp program_named({:ok, program}), do: {:ok, program}
  defp program_named(:error), do: {:error, :not_a_login_entry}

  @doc """
  The kept home the entry `entry_id` of `athanor_id` names: its own id,
  for a login entry of any status, a deleted one included, so the home a
  deleted entry leaves behind is found and retired. `:none` for another
  kind or no such entry; `{:error, :unavailable}` when the store cannot
  answer.
  """
  @spec home_of(String.t(), String.t()) :: {:ok, home_id()} | :none | {:error, :unavailable}
  def home_of(athanor_id, entry_id)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(entry_id) do
    case Arca.VaultStorage.get(Prima.Actor.in_athanor(athanor_id), entry_id) do
      {:ok, %{kind: @login, id: id}} -> {:ok, id}
      {:ok, _another_kind} -> :none
      {:error, :not_found} -> :none
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  @doc """
  Which of the kept homes `home_ids` (a box's) no login entry holds any
  more, with the athanor each was its entry's (nil for an entry with no
  row left): its entry deleted, another kind, or its athanor archived.
  The positive evidence the programs controller retires a home on; a home
  whose entry stands is not named. `{:error, :unavailable}` when the store
  cannot answer, so the sweep retires nothing and asks again later.
  """
  @spec orphaned_homes([home_id()]) ::
          {:ok, [{home_id(), String.t() | nil}]} | {:error, :unavailable}
  def orphaned_homes(home_ids) when is_list(home_ids) do
    case Arca.VaultStorage.standing(home_ids) do
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

  defp orphaned(%{kind: @login, status: status, athanor_archived: false})
       when status != "tombstoned",
       do: :stands

  defp orphaned(%{athanor_id: athanor_id}), do: athanor_id

  @doc """
  The ids of `athanor_id`'s login entries that are not deleted: the kept
  homes an archived athanor leaves behind, which the programs controller
  retires. `{:error, :unavailable}` when the store cannot answer.
  """
  @spec login_entries(String.t()) :: {:ok, [home_id()]} | {:error, :unavailable}
  def login_entries(athanor_id) when is_binary(athanor_id) and athanor_id != "" do
    case Arca.VaultStorage.list(Prima.Actor.in_athanor(athanor_id)) do
      {:ok, entries} -> {:ok, for(%{kind: @login, id: id} <- entries, do: id)}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end
end
