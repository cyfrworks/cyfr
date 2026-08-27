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
  admitted sign-in (`activate_invited/1`) and is withdrawn when the door
  denies that address (`withdraw_invites_for_email/1`) — a seat must not
  outlive the eject. Adding an email the door does not admit also queues a
  request for the platform admin — an invite never opens the door by itself.

  Every change broadcasts `{:membership_changed, %{user_id, athanor_id,
  change}}` on `"sanctum:memberships:<user_id>"` so a mounted LiveView can
  re-derive what it shows.
  """

  import Ecto.Query

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
    Arca.Repo.Errors.with_db_rescue("Sanctum.Tenancy.Members.create", fn ->
      now = DateTime.utc_now()

      attrs =
        attrs
        |> Map.new()
        |> Map.put_new(:id, Emissary.UUID7.generate_id("mem"))
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
    end)
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

  @doc "Every platform-admin row — the server's operators, as the rows say."
  @spec list_platform() :: {:ok, [Membership.t()]} | {:error, :database_error}
  def list_platform do
    Arca.Repo.Errors.with_db_rescue("Sanctum.Tenancy.Members.list_platform", fn ->
      {:ok, Arca.Repo.all(from(m in Membership, where: m.scope == "platform"))}
    end)
  end

  @doc """
  Remove the platform-admin row for `user_id`, if any. A failure is
  reported, not swallowed: the caller is taking a capability away, and
  answering `:ok` while the row survives would leave the operator bit on.

  When a row was actually removed, the person's sessions are revoked with
  it (`Sanctum.Session.revoke_all_for_user/1`): the capability rides on
  established contexts — memoized per request, held for a LiveView
  socket's lifetime — and ending the sessions is what makes the
  revocation a next-request fact on every surface. A no-op revoke (no
  row) touches nothing, so the routine sign-in of a non-operator never
  logs anyone out.
  """
  @spec revoke_platform(String.t()) :: :ok | {:error, :database_error}
  def revoke_platform(user_id) when is_binary(user_id) do
    Arca.Repo.Errors.with_db_rescue("Sanctum.Tenancy.Members.revoke_platform", fn ->
      {count, _} =
        Arca.Repo.delete_all(
          from(m in Membership, where: m.user_id == ^user_id and m.scope == "platform")
        )

      if count > 0, do: Sanctum.Session.revoke_all_for_user(user_id)

      :ok
    end)
  end

  def get(id) do
    Arca.Repo.Errors.with_db_rescue("Sanctum.Tenancy.Members.get", fn ->
      case Arca.Repo.get(Membership, id) do
        nil -> {:error, :not_found}
        membership -> {:ok, membership}
      end
    end)
  end

  @doc "Is `user_id` an active member of the athanor?"
  @spec member?(String.t() | nil, String.t()) :: boolean()
  def member?(user_id, athanor_id) when is_binary(user_id) and is_binary(athanor_id) do
    match?({:ok, %Membership{status: "active"}}, find(user_id, "athanor", athanor_id))
  end

  def member?(_, _), do: false

  @doc """
  Add someone to an athanor: a person already on this server (`user_id:`)
  becomes an active member; an `email:` becomes an active member when
  exactly one identity with that verified email is known, else an `invited`
  row — and, when the door would not admit that address, a pending request
  for the platform admin. Answers uniformly for a stranger's address and a
  known one so it cannot be used to learn who is on the server; the two
  addresses it cannot seat — one that two identities here sign in with
  (`:ambiguous_email`: add by user id), and one a known person's provider
  positively refuses (`:email_unverified`: a permanent invite would be the
  alternative) — are refused with the reason. The per-group member cap
  applies. A person's own athanor has exactly one member — its owner — on
  every path, not only in the UI.
  """
  @spec add(Arca.Schemas.Athanor.t(), [user_id: String.t()] | [email: String.t()], String.t()) ::
          {:ok, :added | :invited} | {:error, term()}
  def add(athanor, target, added_by)

  def add(%{kind: "person"}, _target, _added_by), do: {:error, :person_athanor}

  def add(%{id: athanor_id, status: "active"} = athanor, [user_id: user_id], added_by)
      when is_binary(user_id) do
    opts = [scope: "athanor", athanor_id: athanor_id, added_by: added_by]

    # A membership names a person: an id nobody has signed in with, or one
    # the door has since denied, is refused. (Unlike the email arm, a
    # verified email is not required — a person admitted by a `user_id`
    # door entry may have none.)
    with {:ok, %User{status: "active"}} <- Users.get(user_id),
         :ok <- Caps.check_counted(:max_members_per_group, fn -> count_seats(athanor_id) end),
         {:ok, _} <- ensure(user_id, opts) do
      broadcast_change(user_id, athanor.id, :joined)
      Sanctum.Notify.member_changed(athanor.id)
      {:ok, :added}
    else
      {:ok, %User{}} -> {:error, :unknown_user}
      {:error, :not_found} -> {:error, :unknown_user}
      other -> other
    end
  end

  def add(%{id: athanor_id, status: "active"} = athanor, [email: email], added_by)
      when is_binary(email) do
    email = String.downcase(String.trim(email))

    with true <- String.contains?(email, "@") or {:error, :invalid_email},
         :ok <- Caps.check_counted(:max_members_per_group, fn -> count_seats(athanor_id) end) do
      known = Users.list_by_email(email)

      case Enum.filter(known, &known_and_active?/1) do
        [%User{id: user_id}] ->
          add(athanor, [user_id: user_id], added_by)

        [_, _ | _] ->
          {:error, :ambiguous_email}

        [] ->
          if Enum.any?(known, &(&1.status == "active" and &1.email_verified == false)) do
            {:error, :email_unverified}
          else
            with {:ok, _} <- invite(athanor_id, email, added_by) do
              unless Door.email_admitted?(email) do
                # Only a request that was actually written puts someone at the
                # operator's door; an address that already has an entry (a
                # standing deny, say) has its answer already.
                case Door.Store.request("email", email, added_by) do
                  {:ok, :created, _} -> Sanctum.Notify.allowlist_request(email)
                  _ -> :ok
                end
              end

              Sanctum.Notify.member_changed(athanor.id)
              {:ok, :invited}
            end
          end
      end
    end
  end

  def add(_athanor, _target, _added_by), do: {:error, :athanor_archived}

  # The door decided who may be here; what a member's invitation needs is
  # that the provider did not *deny* the address. An issuer that never
  # claims verification (many enterprise IdPs) must not make invitations
  # impossible; one that says `false` still refuses.
  defp known_and_active?(%User{} = user),
    do: user.email_verified != false and user.status == "active"

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
  Turn every `invited` row for the person's email into their active
  membership — unless their provider positively says the address is not
  theirs, which is the one answer that refuses — two set-based statements in one transaction, so two
  first sign-ins of the same identity cannot both claim a row: invitations
  for athanors where the person is already active are dropped, the rest are
  activated with the email consumed (the assignment index then admits no
  second row for the person and athanor). Returns how many activated.
  """
  @spec activate_invited(User.t()) :: {:ok, non_neg_integer()}
  def activate_invited(%User{email: email, email_verified: verified, id: user_id})
      when is_binary(email) and verified != false do
    Arca.Repo.Errors.with_db_rescue("Sanctum.Tenancy.Members.activate_invited", fn ->
      now = DateTime.utc_now()

      invited =
        from(m in Membership,
          where: m.email == ^email and m.status == "invited" and m.scope == "athanor"
        )

      # An invitation for an athanor the person is already an active member of
      # is superseded. Written as a subquery, not a join: SQLite refuses joins
      # on DELETE.
      superseded =
        from(m in invited,
          where:
            m.athanor_id in subquery(
              from(a in Membership,
                where: a.user_id == ^user_id and a.scope == "athanor" and a.status == "active",
                select: a.athanor_id
              )
            )
        )

      {:ok, athanor_ids} =
        Arca.Repo.transaction(fn ->
          Arca.Repo.delete_all(superseded)

          {_n, ids} =
            Arca.Repo.update_all(from(m in invited, select: m.athanor_id),
              set: [user_id: user_id, status: "active", email: nil, updated_at: now]
            )

          ids
        end)

      for athanor_id <- athanor_ids do
        broadcast_change(user_id, athanor_id, :joined)
        Sanctum.Notify.member_changed(athanor_id)
      end

      {:ok, length(athanor_ids)}
    end)
  end

  def activate_invited(_user), do: {:ok, 0}

  @doc """
  Drop every pending invitation for an address — what a deny at the door
  owes the groups that were holding a seat for it. Invited rows name an
  email and no person, so the deny's sweep by `user_id` cannot see them;
  without this a seat survives the eject and the next allow would seat
  someone the operator threw out. Returns how many were withdrawn.
  """
  @spec withdraw_invites_for_email(String.t() | nil) :: non_neg_integer()
  def withdraw_invites_for_email(email) when is_binary(email) and email != "" do
    # Deliberate default: the deny's best-effort sweep — a withdrawal the
    # store missed leaves invited rows, not seats: activation re-checks the
    # door, which now denies the address.
    Arca.Repo.Errors.with_db_rescue("Sanctum.Tenancy.Members.withdraw_invites_for_email", 0, fn ->
      email = String.downcase(String.trim(email))

      query =
        from(m in Membership,
          where: m.email == ^email and m.status == "invited" and m.scope == "athanor",
          select: m.athanor_id
        )

      {_n, athanor_ids} = Arca.Repo.delete_all(query)
      athanor_ids = athanor_ids || []

      for athanor_id <- athanor_ids, is_binary(athanor_id) do
        Sanctum.Notify.member_changed(athanor_id)
      end

      length(athanor_ids)
    end)
  end

  def withdraw_invites_for_email(_), do: 0

  def remove(%Membership{} = membership) do
    Arca.Repo.Errors.with_db_rescue("Sanctum.Tenancy.Members.remove", fn ->
      Arca.Repo.delete(membership)
    end)
  end

  @doc """
  Remove a person from an athanor (or a pending invite by email). The last
  active member leaving a group archives it — Home included, and Home never
  comes back (`Sanctum.Tenancy.Athanors.ensure_home/0` mints its successor).
  The owner of a person's athanor is that athanor's one member and is never
  removed — deny at the door is the only way out of one's own furnace.
  """
  @spec remove_member(Arca.Schemas.Athanor.t(), [user_id: String.t()] | [email: String.t()]) ::
          :ok | {:error, term()}
  def remove_member(%{kind: "person"}, _target), do: {:error, :person_athanor}

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

  @doc """
  Remove every row of a person (a denied user's rows) — group and platform
  alike. A group they were the last active member of is archived, as when
  they leave it. A failure is reported: the caller is ejecting someone and
  must not answer "done" while rows survive.
  """
  @spec remove_all_for_user(String.t()) :: :ok | {:error, :database_error}
  def remove_all_for_user(user_id) when is_binary(user_id) do
    Arca.Repo.Errors.with_db_rescue("Sanctum.Tenancy.Members.remove_all_for_user", fn ->
      rows = Arca.Repo.all(from(m in Membership, where: m.user_id == ^user_id))
      Arca.Repo.delete_all(from(m in Membership, where: m.user_id == ^user_id))

      for %{athanor_id: athanor_id} <- rows, is_binary(athanor_id) do
        broadcast_change(user_id, athanor_id, :left)
        Sanctum.Notify.member_changed(athanor_id)

        case Athanors.get(athanor_id) do
          {:ok, athanor} -> archive_when_empty(athanor)
          _ -> :ok
        end
      end

      :ok
    end)
  end

  @max_page 500

  @doc """
  The members of an athanor — active and invited — as display rows, oldest
  first: `%{user_id, email, display_name, namespace, status, added_by, since}`.
  Paged with `limit:` (default and ceiling #{@max_page}) and `offset:`; the
  member cap bounds the roster, the page bounds one read.
  """
  @spec list_by_athanor(String.t(), keyword()) :: {:ok, [map()]} | {:error, :database_error}
  def list_by_athanor(athanor_id, opts \\ []) when is_binary(athanor_id) do
    Arca.Repo.Errors.with_db_rescue("Sanctum.Tenancy.Members.list_by_athanor", fn ->
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
             email: coalesce(m.email, u.email),
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

  @doc "Every row of a person: platform and athanor, active only. Uncapped."
  @spec list_by_user(String.t()) :: {:ok, [Membership.t()]} | {:error, :database_error}
  def list_by_user(user_id) do
    Arca.Repo.Errors.with_db_rescue("Sanctum.Tenancy.Members.list_by_user", fn ->
      {:ok,
       from(m in Membership,
         where: m.user_id == ^user_id and m.status == "active",
         order_by: [desc: m.created_at]
       )
       |> Arca.Repo.all()}
    end)
  end

  @doc """
  How many active members an athanor has. Strict like `Athanors.count/0`
  and `count_seats/1`: a count that decides anything (auto-archive keys on
  zero) must refuse when the store cannot answer, never read as empty.
  """
  @spec count_by_athanor(String.t()) :: {:ok, non_neg_integer()} | {:error, :database_error}
  def count_by_athanor(athanor_id) do
    Arca.Repo.Errors.with_db_rescue("Sanctum.Tenancy.Members.count_by_athanor", fn ->
      {:ok,
       Arca.Repo.one(
         from(m in Membership,
           where: m.athanor_id == ^athanor_id and m.status == "active",
           select: count(m.id)
         )
       ) || 0}
    end)
  end

  # Every seat the athanor has handed out — active members and pending
  # invitations — which is what the member cap bounds; an invitation is a
  # seat someone will take.
  defp count_seats(athanor_id) do
    Arca.Repo.Errors.with_db_rescue("Sanctum.Tenancy.Members.count_seats", fn ->
      {:ok,
       Arca.Repo.one(
         from(m in Membership,
           where: m.athanor_id == ^athanor_id and m.scope == "athanor",
           select: count(m.id)
         )
       ) || 0}
    end)
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

  defp archive_when_empty(%{id: id, kind: "group"} = athanor) do
    # Only a verified zero archives. A store failure aborts: archiving is
    # terminal for a group (an :empty archive releases the slug and cannot
    # be undone), so a transient read error must never read as "empty".
    with {:ok, 0} <- count_by_athanor(id),
         {:ok, current} <- Athanors.get(id) do
      Athanors.archive(current, reason: :empty)
    else
      _ -> {:ok, athanor}
    end

    :ok
  end

  defp archive_when_empty(_), do: :ok

  defp find(user_id, scope, athanor_id) do
    Arca.Repo.Errors.with_db_rescue("Sanctum.Tenancy.Members.find", fn ->
      query =
        from(m in Membership,
          where: m.user_id == ^user_id and m.scope == ^scope,
          order_by: [asc: m.created_at, asc: m.id],
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
    end)
  end

  defp find_invited(email, athanor_id) do
    Arca.Repo.Errors.with_db_rescue("Sanctum.Tenancy.Members.find_invited", fn ->
      case Arca.Repo.one(
             from(m in Membership,
               where: m.email == ^email and m.athanor_id == ^athanor_id and m.status == "invited",
               limit: 1
             )
           ) do
        nil -> {:error, :not_found}
        membership -> {:ok, membership}
      end
    end)
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

end
