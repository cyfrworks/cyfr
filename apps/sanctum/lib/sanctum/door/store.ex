# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Door.Store do
  @moduledoc """
  The server allowlist: what the door reads and what platform admins edit.

  An allow names a person identifier (`identifier`, `per_…`, how the
  CYFR sign-in's people are named) or the wildcard `*` (`wildcard`); a
  deny names a person of this server (`person`, their `usr_…` id) or a
  person identifier (`Arca.Doors.kinds/1`). An `allow` entry with
  `status: "requested"` is one a member asked for by inviting an
  identifier the door does not admit, or a CYFR sign-in the door refused;
  it admits nobody until a platform admin resolves it. A `deny` entry
  cannot be written for a platform administrator, named by their person
  id or their identifier: the installation's administrator is never shut
  out of it.

  The rows are `Arca.Doors`', asked as the server (`Prima.Actor.system/0`).
  The door is consulted **before** a session exists, so at admission time
  there is no caller actor to pass: the question "does this server admit
  this identity?" is the server's own, whoever prompted it. An entry is a
  plain map here, never a schema struct.

  Reads that decide admission — `find/2` and everything built on it —
  refuse when the store cannot answer, because "no such entry" and "we
  could not look" are different answers and the door is where that
  difference decides who gets in. The two display reads default to empty
  instead, each saying so at its own call site.
  """

  alias Arca.Doors

  @allow_kinds Doors.kinds("allow")
  @deny_kinds Doors.kinds("deny")

  @typedoc "A door row as this module hands it on: the ten columns, as a plain map."
  @type entry :: Doors.entry()

  @doc "Every entry, allowed and requested, newest first."
  @spec list() :: [entry()]
  def list do
    # Deliberate default: an admin display read — admission itself goes
    # through find/2, whose outage answer is an error the door refuses on.
    case Doors.list(actor()) do
      {:ok, entries} -> entries
      {:error, _} -> []
    end
  end

  @doc "The pending requests, oldest first."
  @spec requests() :: [entry()]
  def requests do
    # Deliberate default: a display read for the operator's queue — a request
    # a blinked read hides is still a row and shows on the next render.
    case Doors.requests(actor()) do
      {:ok, entries} -> entries
      {:error, _} -> []
    end
  end

  @spec get(String.t()) :: {:ok, entry()} | {:error, :not_found | :database_error}
  def get(id) when is_binary(id), do: Doors.get(actor(), id)

  @doc """
  Write an allow entry (or turn an existing deny / request into one).
  `kind` is `"identifier"` or `"wildcard"`.
  """
  @spec allow(String.t(), String.t(), String.t() | nil, String.t() | nil) ::
          {:ok, entry()} | {:error, term()}
  def allow(kind, value, added_by, note \\ nil) when kind in @allow_kinds do
    upsert(kind, value, %{effect: "allow", status: "allowed", added_by: added_by, note: note})
  end

  @doc """
  Write a deny entry (or turn an existing allow / request into one).
  `kind` is `"person"` or `"identifier"`. Refuses a platform administrator
  (`:platform_admin`), named by their person id or their identifier.
  """
  @spec deny(String.t(), String.t(), String.t() | nil, String.t() | nil) ::
          {:ok, entry()} | {:error, :platform_admin | term()}
  def deny(kind, value, added_by, note \\ nil) when kind in @deny_kinds do
    cond do
      names_platform_admin?(kind, value) ->
        {:error, :platform_admin}

      true ->
        # A deny answers whatever request produced the row: the member who
        # asked is no longer who this entry is about.
        upsert(kind, value, %{
          effect: "deny",
          status: "allowed",
          added_by: added_by,
          note: note,
          requested_by: nil
        })
    end
  end

  # The person an entry names, by their id or by the identifier their
  # identity row holds, read for their platform grant.
  defp names_platform_admin?("person", value), do: Sanctum.Tenancy.platform_admin?(value)

  defp names_platform_admin?("identifier", value) do
    case Sanctum.Tenancy.Users.get_by_identifier(value) do
      {:ok, %{id: user_id}} -> Sanctum.Tenancy.platform_admin?(user_id)
      _ -> false
    end
  end

  @doc "Delete an entry by id."
  @spec remove(String.t()) :: :ok | {:error, :not_found | :database_error}
  def remove(id) when is_binary(id), do: Doors.delete(actor(), id)

  @doc """
  Record that someone wants the person identifier `value` let in — one a
  member invited, or one whose CYFR sign-in the door refused.

  Idempotent, and it says which it was: a real entry for that value (allow or
  deny) is left untouched and answers `:existing`, so the caller does not tell
  the operator someone is waiting at a door that already has its answer. That
  also bounds it — one row per identifier, ever, however many times it is
  asked.

  A request is not an allow: `allowed/2` needs `status: "allowed"`, which
  only `resolve/3` writes.
  """
  @spec request(String.t(), String.t(), String.t() | nil, String.t() | nil) ::
          {:ok, :created | :existing, entry()} | {:error, term()}
  def request("identifier" = kind, value, requested_by, note \\ nil) when is_binary(value) do
    case find(kind, value) do
      {:ok, entry} ->
        {:ok, :existing, entry}

      {:error, :not_found} ->
        insert_new(%{
          kind: kind,
          value: value,
          effect: "allow",
          status: "requested",
          requested_by: requested_by,
          note: note
        })

      {:error, _} = err ->
        err
    end
  end

  @doc "Approve (`:allow`) or drop (`:reject`) a request."
  @spec resolve(String.t(), :allow | :reject, String.t() | nil) ::
          {:ok, entry()} | :ok | {:error, term()}
  def resolve(id, decision, admin_user_id) do
    with {:ok, %{status: "requested"} = entry} <- get(id) do
      case decision do
        :allow -> update(entry, %{status: "allowed", added_by: admin_user_id})
        :reject -> remove(id)
      end
    else
      {:ok, _} -> {:error, :not_a_request}
      {:error, _} = err -> err
    end
  end

  # ---- what the door reads ---------------------------------------------------

  @typedoc """
  What a door read says. `{:ok, true | false}` is an answer the store gave;
  `{:error, :unavailable}` is no answer at all, and is never folded into
  either — `Sanctum.Door` refuses on it rather than admitting or denying
  without having looked.
  """
  @type answer :: {:ok, boolean()} | {:error, :unavailable}

  @doc """
  Is there a deny entry for this person (their `usr_…` id) or person
  identifier? Deliberately reads `effect` alone — unlike `allowed/2`,
  which also wants `status: "allowed"` — so a deny row is honoured
  whatever its status says: a malformed or half-written deny must never
  read as an admit.
  """
  @spec denied(String.t() | nil, String.t() | nil) :: answer()
  def denied(user_id, identifier) do
    [{"person", user_id}, {"identifier", identifier}]
    |> Enum.reject(&match?({_kind, nil}, &1))
    |> Enum.reduce_while({:ok, false}, fn {kind, value}, acc ->
      case find(kind, value) do
        {:ok, %{effect: "deny"}} -> {:halt, {:ok, true}}
        {:ok, _entry} -> {:cont, acc}
        {:error, :not_found} -> {:cont, acc}
        {:error, _} -> {:halt, {:error, :unavailable}}
      end
    end)
  end

  @doc "Is `*` on the list?"
  @spec wildcard() :: answer()
  def wildcard, do: in_force(find("wildcard", "*"))

  @doc "Is this exact person identifier allowed (a request does not count)?"
  @spec allowed(String.t(), String.t() | nil) :: answer()
  def allowed(_kind, nil), do: {:ok, false}
  def allowed("identifier" = kind, value), do: in_force(find(kind, value))

  defp in_force({:ok, %{effect: "allow", status: "allowed"}}), do: {:ok, true}
  defp in_force({:ok, _entry}), do: {:ok, false}
  defp in_force({:error, :not_found}), do: {:ok, false}
  defp in_force({:error, _reason}), do: {:error, :unavailable}

  # ---- internal --------------------------------------------------------------

  # The door is asked before anyone has signed in, so there is no caller
  # actor to carry: the server asks its own question, with the platform
  # scope `Arca.Doors` gates the table on.
  defp actor, do: Prima.Actor.system()

  defp find(kind, value), do: Doors.find(actor(), kind, value)

  defp upsert(kind, value, attrs) do
    case find(kind, value) do
      {:ok, entry} ->
        update(entry, attrs)

      {:error, :not_found} ->
        case insert_new(Map.merge(attrs, %{kind: kind, value: value})) do
          {:ok, :created, entry} -> {:ok, entry}
          {:ok, :existing, entry} -> update(entry, attrs)
          {:error, _} = err -> err
        end

      {:error, _} = err ->
        err
    end
  end

  # The unique `[kind, value]` index is the arbiter: an insert that lost the
  # race to another write of the same entry answers the row that landed.
  defp insert_new(attrs) do
    case Doors.insert(actor(), attrs) do
      {:ok, entry} ->
        {:ok, :created, entry}

      {:error, :already_exists} ->
        with {:ok, entry} <- find(attrs.kind, attrs.value), do: {:ok, :existing, entry}

      {:error, _} = error ->
        error
    end
  end

  defp update(%{id: id}, attrs), do: Doors.update(actor(), id, attrs)
end
