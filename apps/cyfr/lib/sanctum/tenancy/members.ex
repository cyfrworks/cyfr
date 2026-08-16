# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Tenancy.Members do
  @moduledoc """
  Membership assignments — "user X is a member of athanor A".

  A membership row is a presence-only grant: its existence makes the user a
  member (every member is the athanor's admin — there is no role tier). A
  `"platform"` row names no athanor: it makes the user a platform admin, the
  server's operator, minted on first sign-in for the emails in
  `CYFR_PLATFORM_ADMIN_EMAILS` (see `Sanctum.SignIn`).

  An `invited` row names an email instead of a person: someone was added to
  a group before they ever signed in here. It activates on their first
  admitted sign-in (`activate_invited/1`). Adding an email the door does not
  admit also queues a request for the platform admin — an invite never
  opens the door by itself.

  Every change broadcasts `{:membership_changed, %{user_id, athanor_id,
  change}}` on `"sanctum:memberships:<user_id>"` so a mounted LiveView can
  re-derive what it shows.
  """

  import Ecto.Query
  require Logger
  require Arca.Repo.Errors

  alias Arca.Schemas.{Membership, User}
  alias Sanctum.Tenancy.{Athanors, Users}
  alias Sanctum.Door
  alias Sanctum.Tenancy.Caps

  @topic_prefix "sanctum:memberships:"

  @doc """
  Insert a membership. `attrs` must carry `:scope`; an active row `:user_id`,
  an invited row `:email`; `:athanor_id` is required by the changeset for
  the `"athanor"` scope and must name an existing athanor.
  """
  def create(attrs) do
    now = DateTime.utc_now()

    attrs =
      attrs
      |> Map.new()
      |> Map.put_new(:id, generate_id())
      |> Map.put_new(:created_at, now)
      |> Map.put_new(:updated_at, now)

    changeset = Membership.changeset(%Membership{}, attrs)

    # The row also carries a foreign key, but SQLite reports a violation
    # without naming it, so the changeset could not translate it. Checking
    # here answers the same way on both adapters.
    if changeset.valid? and missing_athanor?(changeset) do
      {:error, Ecto.Changeset.add_error(changeset, :athanor_id, "does not exist")}
    else
      Arca.Repo.insert(changeset)
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("Sanctum.Tenancy.Members: create failed (#{Exception.message(e)})")
      {:error, :database_error}
  end

  @doc """
  Idempotently ensure an active membership exists for `user_id`.

  Opts: `:scope` (required — the two scopes are different grants and neither
  is a default), `:athanor_id`, `:added_by`. Safe under concurrent first
  sign-ins — a unique-constraint conflict resolves to a re-read of the
  existing row.
  """
  def ensure(user_id, opts) when is_binary(user_id) do
    scope = Keyword.fetch!(opts, :scope)
    athanor_id = Keyword.get(opts, :athanor_id)

    # Read-before-write: the membership almost always already exists (it is
    # minted once), so probing first avoids a failed INSERT — and the noisy
    # `QUERY ERROR ... memberships` log line — on every later sign-in. A
    # concurrent first-login can still race past the probe; the INSERT's
    # unique-constraint error then resolves to a re-read.
    case find(user_id, scope, athanor_id) do
      {:ok, membership} ->
        {:ok, membership}

      _ ->
        case create(%{
               user_id: user_id,
               scope: scope,
               athanor_id: athanor_id,
               added_by: Keyword.get(opts, :added_by)
             }) do
          {:ok, membership} ->
            {:ok, membership}

          {:error, %Ecto.Changeset{errors: errors}} = err ->
            if Keyword.has_key?(errors, :user_id) or unique_conflict?(errors) do
              # Lost the race: re-read the existing assignment.
              find(user_id, scope, athanor_id)
            else
              err
            end

          other ->
            other
        end
    end
  end

  @doc "Ensure the platform-admin row for `user_id`."
  @spec ensure_platform(String.t()) :: {:ok, Membership.t()} | {:error, term()}
  def ensure_platform(user_id), do: ensure(user_id, scope: "platform")

  @doc "Remove the platform-admin row for `user_id`, if any."
  @spec revoke_platform(String.t()) :: :ok
  def revoke_platform(user_id) when is_binary(user_id) do
    Arca.Repo.delete_all(
      from(m in Membership, where: m.user_id == ^user_id and m.scope == "platform")
    )

    :ok
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("Sanctum.Tenancy.Members: revoke_platform failed (#{Exception.message(e)})")
      :ok
  end

  def get(id) do
    case Arca.Repo.get(Membership, id) do
      nil -> {:error, :not_found}
      membership -> {:ok, membership}
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("Sanctum.Tenancy.Members: get failed (#{Exception.message(e)})")
      {:error, :database_error}
  end

  @doc "Is `user_id` an active member of the athanor?"
  @spec member?(String.t() | nil, String.t()) :: boolean()
  def member?(user_id, athanor_id) when is_binary(user_id) and is_binary(athanor_id) do
    match?({:ok, %Membership{status: "active"}}, find(user_id, "athanor", athanor_id))
  end

  def member?(_, _), do: false

  @doc """
  Add someone to an athanor: a person already on this server (`user_id:`)
  becomes an active member; an `email:` becomes an active member when an
  identity with that verified email is known, else an `invited` row — and,
  when the door would not admit that address, a pending request for the
  platform admin. Answers uniformly so it cannot be used to learn who is on
  the server. The per-group member cap applies.
  """
  @spec add(Arca.Schemas.Athanor.t(), [user_id: String.t()] | [email: String.t()], String.t()) ::
          {:ok, :added | :invited} | {:error, term()}
  def add(athanor, target, added_by)

  def add(%{id: athanor_id, status: "active"} = athanor, [user_id: user_id], added_by)
      when is_binary(user_id) do
    opts = [scope: "athanor", athanor_id: athanor_id, added_by: added_by]

    with :ok <- Caps.check(:max_members_per_group, count_by_athanor(athanor_id)),
         {:ok, _} <- ensure(user_id, opts) do
      broadcast_change(user_id, athanor.id, :joined)
      Sanctum.Notify.member_changed(athanor.id)
      {:ok, :added}
    end
  end

  def add(%{id: athanor_id, status: "active"} = athanor, [email: email], added_by)
      when is_binary(email) do
    email = String.downcase(String.trim(email))

    with true <- String.contains?(email, "@") or {:error, :invalid_email},
         :ok <- Caps.check(:max_members_per_group, count_by_athanor(athanor_id)) do
      case Enum.filter(Users.list_by_email(email), &known_and_active?/1) do
        [%User{id: user_id} | _] ->
          add(athanor, [user_id: user_id], added_by)

        [] ->
          with {:ok, _} <- invite(athanor_id, email, added_by) do
            unless Door.email_admitted?(email) do
              Door.Store.request(email, added_by)
              Sanctum.Notify.allowlist_request(email)
            end

            Sanctum.Notify.member_changed(athanor.id)
            {:ok, :invited}
          end
      end
    end
  end

  def add(_athanor, _target, _added_by), do: {:error, :athanor_archived}

  defp known_and_active?(%User{} = user), do: user.email_verified and user.status == "active"

  defp invite(athanor_id, email, added_by) do
    case find_invited(email, athanor_id) do
      {:ok, row} ->
        {:ok, row}

      {:error, :not_found} ->
        create(%{
          email: email,
          scope: "athanor",
          status: "invited",
          athanor_id: athanor_id,
          added_by: added_by
        })
    end
  end

  @doc """
  Turn every `invited` row for the person's verified email into their active
  membership. One statement per row set; an active row that already exists
  wins and the invitation is consumed.
  """
  @spec activate_invited(User.t()) :: {:ok, non_neg_integer()}
  def activate_invited(%User{email: email, email_verified: true, id: user_id})
      when is_binary(email) do
    invited =
      Arca.Repo.all(from(m in Membership, where: m.email == ^email and m.status == "invited"))

    activated =
      Enum.reduce(invited, 0, fn row, n ->
        case find(user_id, "athanor", row.athanor_id) do
          {:ok, _active} ->
            remove(row)
            n

          _ ->
            case row
                 |> Membership.changeset(%{
                   user_id: user_id,
                   status: "active",
                   updated_at: DateTime.utc_now()
                 })
                 |> Arca.Repo.update() do
              {:ok, _} ->
                broadcast_change(user_id, row.athanor_id, :joined)
                Sanctum.Notify.member_changed(row.athanor_id)
                n + 1

              {:error, _} ->
                n
            end
        end
      end)

    {:ok, activated}
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("Sanctum.Tenancy.Members: activate_invited failed (#{Exception.message(e)})")
      {:ok, 0}
  end

  def activate_invited(_user), do: {:ok, 0}

  def remove(%Membership{} = membership) do
    Arca.Repo.delete(membership)
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("Sanctum.Tenancy.Members: remove failed (#{Exception.message(e)})")
      {:error, :database_error}
  end

  @doc """
  Remove a person from an athanor (or a pending invite by email). The last
  active member leaving a group archives it; Home is never archived.
  """
  @spec remove_member(Arca.Schemas.Athanor.t(), [user_id: String.t()] | [email: String.t()]) ::
          :ok | {:error, term()}
  def remove_member(%{id: athanor_id} = athanor, user_id: user_id) when is_binary(user_id) do
    with {:ok, row} <- find(user_id, "athanor", athanor_id),
         {:ok, _} <- remove(row) do
      broadcast_change(user_id, athanor_id, :left)
      Sanctum.Notify.member_changed(athanor_id)
      archive_when_empty(athanor)
      :ok
    end
  end

  def remove_member(%{id: athanor_id}, email: email) when is_binary(email) do
    with {:ok, row} <- find_invited(String.downcase(email), athanor_id),
         {:ok, _} <- remove(row) do
      Sanctum.Notify.member_changed(athanor_id)
      :ok
    end
  end

  @doc "Remove every group row of a person (a denied user's rows). Platform rows too."
  @spec remove_all_for_user(String.t()) :: :ok
  def remove_all_for_user(user_id) when is_binary(user_id) do
    rows = Arca.Repo.all(from(m in Membership, where: m.user_id == ^user_id))
    Arca.Repo.delete_all(from(m in Membership, where: m.user_id == ^user_id))

    for %{athanor_id: athanor_id} <- rows, is_binary(athanor_id) do
      broadcast_change(user_id, athanor_id, :left)
      Sanctum.Notify.member_changed(athanor_id)
    end

    :ok
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("Sanctum.Tenancy.Members: remove_all failed (#{Exception.message(e)})")
      :ok
  end

  @doc "The members of an athanor — active and invited — as display rows."
  @spec list(String.t()) :: [map()]
  def list(athanor_id) when is_binary(athanor_id) do
    Arca.Repo.all(
      from(m in Membership,
        left_join: u in User,
        on: u.id == m.user_id,
        where: m.athanor_id == ^athanor_id and m.scope == "athanor",
        order_by: [asc: m.created_at],
        select: %{
          user_id: m.user_id,
          email: coalesce(m.email, u.email),
          display_name: u.display_name,
          namespace: u.namespace,
          status: m.status,
          added_by: m.added_by,
          since: m.created_at
        }
      )
    )
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("Sanctum.Tenancy.Members: list failed (#{Exception.message(e)})")
      []
  end

  def list_by_athanor(athanor_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 500)

    from(m in Membership,
      where: m.athanor_id == ^athanor_id,
      order_by: [desc: m.created_at],
      limit: ^limit
    )
    |> Arca.Repo.all()
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("Sanctum.Tenancy.Members: list_by_athanor failed (#{Exception.message(e)})")
      {:error, :database_error}
  end

  @doc "Every row of a person: platform and athanor, active only. Uncapped."
  def list_by_user(user_id) do
    from(m in Membership,
      where: m.user_id == ^user_id and m.status == "active",
      order_by: [desc: m.created_at]
    )
    |> Arca.Repo.all()
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("Sanctum.Tenancy.Members: list_by_user failed (#{Exception.message(e)})")
      {:error, :database_error}
  end

  @doc "How many active members an athanor has."
  @spec count_by_athanor(String.t()) :: non_neg_integer()
  def count_by_athanor(athanor_id) do
    Arca.Repo.one(
      from(m in Membership,
        where: m.athanor_id == ^athanor_id and m.status == "active",
        select: count(m.id)
      )
    ) || 0
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("Sanctum.Tenancy.Members: count_by_athanor failed (#{Exception.message(e)})")
      0
  end

  @doc "The PubSub topic a person's LiveViews subscribe to for their own membership changes."
  @spec topic(String.t()) :: String.t()
  def topic(user_id) when is_binary(user_id), do: @topic_prefix <> user_id

  @doc false
  def broadcast_change(user_id, athanor_id, change) when is_binary(user_id) do
    Phoenix.PubSub.broadcast(
      Emissary.PubSub,
      topic(user_id),
      {:membership_changed, %{user_id: user_id, athanor_id: athanor_id, change: change}}
    )
  end

  def broadcast_change(_user_id, _athanor_id, _change), do: :ok

  # ---- internal --------------------------------------------------------------

  defp archive_when_empty(%{home: true}), do: :ok

  defp archive_when_empty(%{id: id, kind: "group"} = athanor) do
    if count_by_athanor(id) == 0 do
      case Athanors.get(id) do
        {:ok, current} -> Athanors.archive(current)
        _ -> {:ok, athanor}
      end
    end

    :ok
  end

  defp archive_when_empty(_), do: :ok

  defp find(user_id, scope, athanor_id) do
    query =
      from(m in Membership,
        where: m.user_id == ^user_id and m.scope == ^scope,
        limit: 1
      )

    query =
      case athanor_id do
        nil -> from(m in query, where: is_nil(m.athanor_id))
        id -> from(m in query, where: m.athanor_id == ^id)
      end

    case Arca.Repo.one(query) do
      nil -> {:error, :not_found}
      membership -> {:ok, membership}
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("Sanctum.Tenancy.Members: find failed (#{Exception.message(e)})")
      {:error, :database_error}
  end

  defp find_invited(email, athanor_id) do
    case Arca.Repo.one(
           from(m in Membership,
             where: m.email == ^email and m.athanor_id == ^athanor_id and m.status == "invited",
             limit: 1
           )
         ) do
      nil -> {:error, :not_found}
      membership -> {:ok, membership}
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("Sanctum.Tenancy.Members: find_invited failed (#{Exception.message(e)})")
      {:error, :database_error}
  end

  defp missing_athanor?(changeset) do
    case Ecto.Changeset.get_field(changeset, :athanor_id) do
      nil -> false
      id -> match?({:error, :not_found}, Athanors.get(id))
    end
  end

  defp unique_conflict?(errors) do
    Enum.any?(errors, fn {_field, {_msg, opts}} -> opts[:constraint] == :unique end)
  end

  defp generate_id, do: "mem_" <> Ecto.UUID.generate()
end
