# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Members do
  @moduledoc """
  Membership rows — "user X is a member of athanor A", the person's seat
  in their own athanor, and the platform grant (`Arca.Schemas.Membership`).

  ## Two shapes, because a membership is the fabric that names a tenant

  Every function states which shape it is, and the shape decides where its
  athanor comes from.

    * **Inside one tenant.** `seat/2`, `find/2`, `list/2` and
      `active_user_ids/1` work in the athanor
      the actor's `athanor_id` names. The id comes from the actor, never
      from an argument, so a roster read or a seat written for one actor
      cannot touch another athanor's rows; an actor whose athanor is nil
      OR the empty string is `{:error, :no_athanor}` before any query
      runs. The empty string is an identity that was never resolved, the
      same thing `Sanctum.Context.build/1` refuses outright and
      `Arca.QueryHelpers.where_tenant/2` raises on — never a tenant named
      `""` — and a guard that took it would answer an empty roster where
      the refusal belongs.

    * **Across tenants.** A `"platform"` row names no athanor at all — it
      is the server's operator grant. A person's rows are read across
      every athanor to resolve which one they work in, and a deny sweeps a
      person's rows at once. None of these can be filtered
      by one athanor without ceasing to do their job, so they match
      `scope: :platform` and refuse an athanor-scoped actor with
      `{:error, :cross_tenant}`.

  ## The platform grant

  The one platform grant is the installation's first person's, written by
  `grant_platform!/1` inside that person's mint (`Arca.Users.mint/4`),
  under the installation claims' order row and the member slot. No other
  function here writes a platform row.

  Nothing that belongs to Ecto crosses the boundary: a row is answered as
  a plain map (`Arca.Data`). A refusal is
  `:conflict` (the assignment index — the row is already there, so a
  caller that raced re-reads it), `{:invalid, %{field => [message]}}`,
  `:unknown_athanor`, `:athanor_archived`, `:not_found`, `:cross_tenant`,
  `:no_athanor` or `:database_error`.
  """

  import Ecto.Query

  alias Arca.QueryHelpers
  alias Arca.Schemas.{Athanor, Membership, User}

  @type refusal :: {:error, :cross_tenant | :database_error}
  @type write_refusal ::
          {:error,
           :conflict | :unknown_athanor | {:invalid, %{atom() => [String.t()]}} | :database_error}

  @max_page 500

  @doc "The ceiling on one roster page, which is also its default."
  @spec max_page() :: pos_integer()
  def max_page, do: @max_page

  # ---- inside one tenant -----------------------------------------------------

  @doc """
  Write a membership row in the actor's athanor. `attrs` carries
  `:user_id`, `:scope` and `:added_by`; the athanor is the actor's and any
  `:athanor_id` in `attrs` is ignored.

  The row also carries a foreign key, but SQLite reports a violation
  without naming it, so the changeset could not translate it. Reading the
  athanor first answers `:unknown_athanor` the same way on both adapters.

  The person the seat names is locked first, then the athanor row, before
  the seat is written, in one `Arca.Repo.locking_transaction/2`, the
  standing order (`Arca.SecurityTransitions`). A denial holding the
  person, or a denial or an archive retiring the athanor, holds one of
  those locks, so a seat waits for it and then reads what it committed: a
  seat never lands in an archived athanor (`{:error, :athanor_archived}`).
  """
  @spec seat(Prima.Actor.t(), map()) ::
          {:ok, map()} | {:error, :no_athanor | :athanor_archived} | write_refusal()
  def seat(%Prima.Actor{athanor_id: athanor_id}, attrs)
      when is_binary(athanor_id) and athanor_id != "" and is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("Arca.Members.seat", fn ->
      Arca.Repo.locking_transaction(fn ->
        written =
          with :ok <- hold_person(Map.get(attrs, :user_id)),
               :ok <- seatable(athanor_id) do
            attrs |> defaults() |> Map.put(:athanor_id, athanor_id) |> do_insert()
          end

        Arca.Repo.committed(written)
      end)
    end)
    |> Arca.Data.project()
  end

  def seat(%Prima.Actor{}, _attrs), do: {:error, :no_athanor}

  @doc "The person's athanor row in the actor's athanor, if any."
  @spec find(Prima.Actor.t(), String.t()) ::
          {:ok, map()} | {:error, :not_found | :no_athanor | :database_error}
  def find(%Prima.Actor{athanor_id: athanor_id}, user_id)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(user_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.Members.find", fn ->
      found(
        Arca.Repo.one(
          from(m in Membership,
            where: m.user_id == ^user_id and m.scope == "athanor" and m.athanor_id == ^athanor_id,
            order_by: [asc: m.created_at, asc: m.id],
            limit: 1
          )
        )
      )
    end)
    |> Arca.Data.project()
  end

  def find(%Prima.Actor{}, _user_id), do: {:error, :no_athanor}

  @doc """
  The actor's athanor's members as display rows, oldest first:
  `%{user_id, email, display_name, namespace, status, added_by, since}`. Paged with `limit:` (default and ceiling
  `max_page/0`) and `offset:`.
  """
  @spec list(Prima.Actor.t(), keyword()) ::
          {:ok, [map()]} | {:error, :no_athanor | :database_error}
  def list(actor, opts \\ [])

  def list(%Prima.Actor{athanor_id: athanor_id}, opts)
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.Members.list", fn ->
      limit = opts |> Keyword.get(:limit, @max_page) |> min(@max_page) |> max(1)
      offset = opts |> Keyword.get(:offset, 0) |> max(0)

      {:ok,
       Arca.Repo.all(
         from(m in Membership,
           left_join: u in User,
           on: u.id == m.user_id,
           where: m.athanor_id == ^athanor_id and m.scope == "athanor",
           order_by: [asc: m.created_at, asc: m.id],
           limit: ^limit,
           offset: ^offset,
           select: %{
             user_id: m.user_id,
             email: u.email,
             display_name: u.display_name,
             namespace: u.namespace,
             status: m.status,
             added_by: m.added_by,
             since: m.created_at
           }
         )
       )}
    end)
  end

  def list(%Prima.Actor{}, _opts), do: {:error, :no_athanor}

  @doc """
  Every ACTIVE member's person id in the actor's athanor, oldest first.

  Unpaged, unlike `list/2`: this is the roster a close has to reach in
  full — a member it missed would keep a cached authorization the close
  was supposed to end.
  """
  @spec active_user_ids(Prima.Actor.t()) ::
          {:ok, [String.t()]} | {:error, :no_athanor | :database_error}
  def active_user_ids(%Prima.Actor{athanor_id: athanor_id})
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.Members.active_user_ids", fn ->
      {:ok,
       Arca.Repo.all(
         from(m in Membership,
           where:
             m.athanor_id == ^athanor_id and m.scope == "athanor" and m.status == "active" and
               not is_nil(m.user_id),
           order_by: [asc: m.created_at, asc: m.id],
           select: m.user_id
         )
       )}
    end)
  end

  def active_user_ids(%Prima.Actor{}), do: {:error, :no_athanor}

  # ---- across tenants --------------------------------------------------------

  @doc false
  @spec grant_platform!(String.t()) :: :ok | {:error, term()}
  # The installation's first person's platform grant, inside their mint's
  # transaction (`Arca.Users.mint/4`), which holds the order row and the
  # member slot: the one writer of a platform row. The person is held
  # first, as a seat holds them.
  # arca:db-raise-ok a transaction step: the mint that runs it rescues around its transaction.
  def grant_platform!(user_id) when is_binary(user_id) do
    :ok = hold_person(user_id)

    case %{user_id: user_id} |> defaults() |> Map.put(:scope, "platform") |> do_insert() do
      {:ok, _row} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "A membership by its own id. The athanor may be nil — a platform row names none."
  @spec get(Prima.Actor.t(), String.t()) ::
          {:ok, map()} | {:error, :not_found} | refusal()
  # arca:unscoped-ok a membership is fabric, read by its own id; the athanor may be nil (platform).
  def get(%Prima.Actor{scope: :platform}, id) when is_binary(id) do
    Arca.Repo.Errors.with_db_rescue("Arca.Members.get", fn ->
      found(Arca.Repo.get(Membership, id))
    end)
    |> Arca.Data.project()
  end

  def get(%Prima.Actor{}, _id), do: {:error, :cross_tenant}

  @doc "The person's platform row, if any."
  @spec find_platform(Prima.Actor.t(), String.t()) ::
          {:ok, map()} | {:error, :not_found} | refusal()
  # arca:unscoped-ok a platform row names no athanor by design.
  def find_platform(%Prima.Actor{scope: :platform}, user_id) when is_binary(user_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.Members.find_platform", fn ->
      found(
        Arca.Repo.one(
          from(m in Membership,
            where: m.user_id == ^user_id and m.scope == "platform" and is_nil(m.athanor_id),
            order_by: [asc: m.created_at, asc: m.id],
            limit: 1
          )
        )
      )
    end)
    |> Arca.Data.project()
  end

  def find_platform(%Prima.Actor{}, _user_id), do: {:error, :cross_tenant}

  @doc "Every platform row — the server's operators, as the rows say."
  @spec list_platform(Prima.Actor.t()) :: {:ok, [map()]} | refusal()
  # arca:unscoped-ok platform memberships carry no athanor by design.
  def list_platform(%Prima.Actor{scope: :platform}) do
    Arca.Repo.Errors.with_db_rescue("Arca.Members.list_platform", fn ->
      {:ok, Arca.Repo.all(from(m in Membership, where: m.scope == "platform"))}
    end)
    |> Arca.Data.project()
  end

  def list_platform(%Prima.Actor{}), do: {:error, :cross_tenant}

  @doc "Every ACTIVE row of a person — platform and athanor alike, newest first."
  @spec list_active_for_user(Prima.Actor.t(), String.t()) ::
          {:ok, [map()]} | refusal()
  # arca:unscoped-ok person-keyed by design — resolving a person's seats across athanors is the point.
  def list_active_for_user(%Prima.Actor{scope: :platform}, user_id) when is_binary(user_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.Members.list_active_for_user", fn ->
      {:ok,
       Arca.Repo.all(
         from(m in Membership,
           where: m.user_id == ^user_id and m.status == "active",
           order_by: [desc: m.created_at]
         )
       )}
    end)
    |> Arca.Data.project()
  end

  def list_active_for_user(%Prima.Actor{}, _user_id), do: {:error, :cross_tenant}

  # ---- internal --------------------------------------------------------------

  # People sorted by id: the order every multi-person lock takes them in.
  defp lock_people(user_ids) do
    from(u in User, where: u.id in ^user_ids, order_by: [asc: u.id])
    |> QueryHelpers.for_update()
    |> Arca.Repo.all()
    |> Map.new(&{&1.id, &1})
  end

  # arca:unscoped-ok the athanor is the caller's clause's: `seat/3` takes it from the actor and
  # `grant_platform!/1` writes the row that names none, so this statement never chooses one.
  defp do_insert(attrs) do
    %Membership{}
    |> Membership.changeset(attrs)
    |> Arca.Repo.insert()
    |> settled()
  end

  defp defaults(attrs) do
    now = DateTime.utc_now()

    attrs
    |> Map.new()
    |> Map.put_new(:id, Prima.UUID7.generate_id("mem"))
    |> Map.put_new(:created_at, now)
    |> Map.put_new(:updated_at, now)
  end

  # The person a membership row names, locked: the first lock of the
  # standing order (`Arca.SecurityTransitions`), so a seat, a claim or a
  # grant waits for a leave or a denial holding the person, or it for them.
  # A person with no row has nothing to hold; an invitation names no
  # person.
  defp hold_person(user_id) when is_binary(user_id) do
    _held = lock_people([user_id])
    :ok
  end

  defp hold_person(_none), do: :ok

  # The athanor a seat is written into, locked: an athanor being retired
  # holds this row until it commits.
  defp seatable(athanor_id) do
    from(a in Athanor, where: a.id == ^athanor_id, select: a.status)
    |> QueryHelpers.for_update()
    |> Arca.Repo.one()
    |> case do
      nil -> {:error, :unknown_athanor}
      "archived" -> {:error, :athanor_archived}
      _active -> :ok
    end
  end

  defp found(nil), do: {:error, :not_found}
  defp found(%Membership{} = membership), do: {:ok, membership}

  defp settled({:ok, %Membership{} = membership}), do: {:ok, membership}
  defp settled({:error, %Ecto.Changeset{} = changeset}), do: {:error, refusal(changeset)}

  # The assignment index is the one refusal a caller acts on rather than
  # reports: the row it wanted is already there, so it re-reads it.
  defp refusal(%Ecto.Changeset{errors: errors} = changeset) do
    if unique?(errors), do: :conflict, else: Arca.Data.invalid(changeset)
  end

  defp unique?(errors) do
    Enum.any?(errors, fn {_field, {_message, meta}} -> meta[:constraint] == :unique end)
  end
end
