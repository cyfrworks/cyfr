# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Door.Store do
  @moduledoc """
  The server allowlist rows (`Arca.Schemas.ServerAllowlistEntry`): what the
  door reads and what platform admins edit.

  Entries name an email, an IdP subject (`user_id`) or the wildcard `*`.
  An `allow` entry with `status: "requested"` is one a member asked for by
  inviting an address the door does not know; it admits nobody until a
  platform admin resolves it. A `deny` entry cannot be written for an
  email in `CYFR_PLATFORM_ADMIN_EMAILS` — the operators can only be removed
  from that list.
  """

  import Ecto.Query, only: [from: 2]
  require Logger
  require Arca.Repo.Errors

  alias Arca.Schemas.ServerAllowlistEntry, as: Entry

  @kinds Entry.kinds()

  @doc "Every entry, allowed and requested, newest first."
  @spec list() :: [Entry.t()]
  def list do
    Arca.Repo.all(from(e in Entry, order_by: [desc: e.created_at]))
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("Sanctum.Door.Store: list failed (#{Exception.message(e)})")
      []
  end

  @doc "The pending requests, oldest first."
  @spec requests() :: [Entry.t()]
  def requests do
    Arca.Repo.all(from(e in Entry, where: e.status == "requested", order_by: [asc: e.created_at]))
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("Sanctum.Door.Store: requests failed (#{Exception.message(e)})")
      []
  end

  @spec get(String.t()) :: {:ok, Entry.t()} | {:error, :not_found}
  def get(id) when is_binary(id) do
    case Arca.Repo.get(Entry, id) do
      nil -> {:error, :not_found}
      entry -> {:ok, entry}
    end
  end

  @doc """
  Write an allow entry (or turn an existing deny / request into one).
  `kind` is `"email"`, `"user_id"` or `"wildcard"`.
  """
  @spec allow(String.t(), String.t(), String.t() | nil, String.t() | nil) ::
          {:ok, Entry.t()} | {:error, term()}
  def allow(kind, value, added_by, note \\ nil) when kind in @kinds do
    upsert(kind, value, %{effect: "allow", status: "allowed", added_by: added_by, note: note})
  end

  @doc """
  Write a deny entry (or turn an existing allow / request into one). Refuses
  an email listed in `CYFR_PLATFORM_ADMIN_EMAILS`.
  """
  @spec deny(String.t(), String.t(), String.t() | nil, String.t() | nil) ::
          {:ok, Entry.t()} | {:error, :platform_admin | term()}
  def deny(kind, value, added_by, note \\ nil) when kind in @kinds do
    cond do
      kind == "wildcard" ->
        {:error, :wildcard_cannot_be_denied}

      kind == "email" and Sanctum.Door.platform_admin_email?(value) ->
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

  @doc "Delete an entry by id."
  @spec remove(String.t()) :: :ok | {:error, :not_found}
  def remove(id) when is_binary(id) do
    case Arca.Repo.delete_all(from(e in Entry, where: e.id == ^id)) do
      {0, _} -> {:error, :not_found}
      _ -> :ok
    end
  end

  @doc """
  Record that someone wants `value` let in — an address a member invited, or
  the IdP subject of a sign-in the door refused.

  Idempotent, and it says which it was: a real entry for that value (allow or
  deny) is left untouched and answers `:existing`, so the caller does not tell
  the operator someone is waiting at a door that already has its answer. That
  also bounds it — one row per address or identity, ever, however many times
  it is asked.

  A request is not an allow: `allowed?/2` needs `status: "allowed"`, which
  only `resolve/3` writes.
  """
  @spec request(String.t(), String.t(), String.t() | nil, String.t() | nil) ::
          {:ok, :created | :existing, Entry.t()} | {:error, term()}
  def request(kind, value, requested_by, note \\ nil)
      when kind in ["email", "user_id"] and is_binary(value) do
    value = if kind == "email", do: String.downcase(value), else: value

    case find(kind, value) do
      {:ok, entry} ->
        {:ok, :existing, entry}

      {:error, :not_found} ->
        with {:ok, entry} <-
               insert(%{
                 kind: kind,
                 value: value,
                 effect: "allow",
                 status: "requested",
                 requested_by: requested_by,
                 note: note
               }) do
          {:ok, :created, entry}
        end
    end
  end

  @doc "Approve (`:allow`) or drop (`:reject`) a request."
  @spec resolve(String.t(), :allow | :reject, String.t() | nil) ::
          {:ok, Entry.t()} | :ok | {:error, term()}
  def resolve(id, decision, admin_user_id) do
    with {:ok, %Entry{status: "requested"} = entry} <- get(id) do
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

  @doc """
  Is there a deny entry for this identity or email? Deliberately reads
  `effect` alone — unlike `allowed?/2`, which also wants `status:
  "allowed"` — so a deny row is honoured whatever its status says: a
  malformed or half-written deny must never read as an admit. The same
  posture covers the store itself: a read the database could not answer
  counts as denied, because "not denied" is the one answer this function
  must never give without having actually looked.
  """
  @spec denied?(String.t() | nil, String.t() | nil) :: boolean()
  def denied?(user_id, email) do
    values = [{"user_id", user_id}, {"email", downcase(email)}]

    Enum.any?(values, fn
      {_kind, nil} ->
        false

      {kind, value} ->
        case find(kind, value) do
          {:ok, %Entry{effect: "deny"}} -> true
          {:ok, %Entry{}} -> false
          {:error, :not_found} -> false
          {:error, _} -> true
        end
    end)
  end

  @doc "Is `*` on the list?"
  @spec wildcard?() :: boolean()
  def wildcard? do
    match?({:ok, %Entry{effect: "allow", status: "allowed"}}, find("wildcard", "*"))
  end

  @doc "Is this exact email or IdP subject allowed (a request does not count)?"
  @spec allowed?(String.t(), String.t() | nil) :: boolean()
  def allowed?(_kind, nil), do: false

  def allowed?(kind, value) when kind in ["email", "user_id"] do
    value = if kind == "email", do: downcase(value), else: value
    match?({:ok, %Entry{effect: "allow", status: "allowed"}}, find(kind, value))
  end

  # ---- internal --------------------------------------------------------------

  defp find(kind, value) do
    case Arca.Repo.get_by(Entry, kind: kind, value: value) do
      nil -> {:error, :not_found}
      entry -> {:ok, entry}
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("Sanctum.Door.Store: read failed (#{Exception.message(e)})")
      {:error, :database_error}
  end

  defp upsert(kind, value, attrs) do
    value = if kind == "email", do: downcase(value), else: value

    case find(kind, value) do
      {:ok, entry} -> update(entry, attrs)
      {:error, :not_found} -> insert(Map.merge(attrs, %{kind: kind, value: value}))
      {:error, _} = err -> err
    end
  end

  defp insert(attrs) do
    now = DateTime.utc_now()

    %Entry{}
    |> Entry.changeset(
      Map.merge(attrs, %{id: "door_" <> Ecto.UUID.generate(), created_at: now, updated_at: now})
    )
    |> Arca.Repo.insert()
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("Sanctum.Door.Store: insert failed (#{Exception.message(e)})")
      {:error, :database_error}
  end

  defp update(%Entry{} = entry, attrs) do
    entry
    |> Entry.changeset(Map.put(attrs, :updated_at, DateTime.utc_now()))
    |> Arca.Repo.update()
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("Sanctum.Door.Store: update failed (#{Exception.message(e)})")
      {:error, :database_error}
  end

  defp downcase(nil), do: nil
  defp downcase(v) when is_binary(v), do: String.downcase(v)
end
