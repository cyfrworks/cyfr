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

  ## What is decided here, and what is stored below

  The statements are `Arca.Members`'. What stays here is the deciding: who
  may be seated and on what proof, which cap bounds a roster, that a
  frozen estate never gains a member, what a leave archives, and who is
  told afterwards. A row inside one athanor is written and read as the
  server narrowed to that athanor; the rows that name no athanor, or that
  name a person across every athanor, run as the server itself.
  """

  alias Arca.Schemas.{Membership, User}
  alias Sanctum.Door
  alias Sanctum.Tenancy.{Athanors, Caps, Users}

  @topic_prefix "sanctum:memberships:"

  @doc """
  Insert a membership. `attrs` must carry `:scope`; an active row `:user_id`,
  an invited row `:email`; `:athanor_id` is required for the `"athanor"`
  scope and must name an existing athanor.
  """
  @spec create(map(), keyword()) :: {:ok, Membership.t()} | {:error, term()}
  def create(attrs, opts \\ []) do
    attrs = Map.new(attrs)

    if Map.get(attrs, :scope) == "platform" do
      Arca.Members.grant_platform(server(), attrs)
    else
      seat(attrs, opts)
    end
  end

  # A frozen estate took its members at birth and never gains another —
  # every writer of a membership row is held to that here, not only
  # `add/3`; the birth itself says so with `birth: true`
  # (`Sanctum.Tenancy.Athanors`).
  defp seat(attrs, opts) do
    athanor_id = Map.get(attrs, :athanor_id)

    if not Keyword.get(opts, :birth, false) and frozen?(athanor_id) do
      {:error, :frozen_roster}
    else
      Arca.Members.seat(in_athanor(athanor_id), attrs)
    end
  end

  defp frozen?(athanor_id) when is_binary(athanor_id),
    do: match?({:ok, %{roster: "frozen"}}, Athanors.get(athanor_id))

  defp frozen?(_athanor_id), do: false

  @doc """
  Idempotently ensure an active membership exists for `user_id`.

  Opts: `:scope` (required — the two scopes are different grants and neither
  is a default), `:athanor_id`, `:added_by`. Safe under concurrent first
  sign-ins — a unique-constraint conflict resolves to a re-read of the
  existing row.
  """
  @spec ensure(String.t(), keyword()) :: {:ok, Membership.t()} | {:error, term()}
  def ensure(user_id, opts) when is_binary(user_id) do
    scope = Keyword.fetch!(opts, :scope)
    athanor_id = Keyword.get(opts, :athanor_id)

    # Read-before-write: the membership almost always already exists (it is
    # minted once), so probing first avoids a failed INSERT — and the noisy
    # `QUERY ERROR ... memberships` log line — on every later sign-in. A
    # concurrent first-login can still race past the probe; the INSERT's
    # conflict then resolves to a re-read.
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
          {:ok, membership} -> {:ok, membership}
          # Lost the race: re-read the existing assignment.
          {:error, :conflict} -> find(user_id, scope, athanor_id)
          other -> other
        end
    end
  end

  @doc "Ensure the platform-admin row for `user_id`."
  @spec ensure_platform(String.t()) :: {:ok, Membership.t()} | {:error, term()}
  def ensure_platform(user_id), do: ensure(user_id, scope: "platform")

  @doc "Every platform-admin row — the server's operators, as the rows say."
  @spec list_platform() :: {:ok, [Membership.t()]} | {:error, :database_error}
  def list_platform, do: Arca.Members.list_platform(server())

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
    with {:ok, count} <- Arca.Members.delete_platform(server(), user_id) do
      if count > 0, do: Sanctum.Session.revoke_all_for_user(user_id)
      :ok
    end
  end

  @spec get(String.t()) :: {:ok, Membership.t()} | {:error, :not_found | :database_error}
  def get(id), do: Arca.Members.get(server(), id)

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

  # A frozen estate took its members at birth and never gains another —
  # that is what makes a DM a DM. Guarded here, beside the person clause,
  # so BOTH the `user_id:` and `email:` arms are covered: a rule enforced
  # on one arm is a rule an invitation walks around. Growing the room is a
  # different act — mint an open estate with the three of them, and the
  # pair stays as it was.
  def add(%{roster: "frozen"}, _target, _added_by), do: {:error, :frozen_roster}

  def add(%{id: athanor_id, status: "active"} = athanor, [user_id: user_id], added_by)
      when is_binary(user_id) do
    opts = [scope: "athanor", athanor_id: athanor_id, added_by: added_by]

    # A membership names a person — by their own id, or by an IdP identity
    # key that names them. An id nobody has signed in with, or one the door
    # has since denied, is refused. (Unlike the email arm, a verified email
    # is not required — a person admitted by a `user_id` door entry may
    # have none.)
    with {:ok, %User{status: "active", id: user_id}} <- find_person(user_id),
         :ok <- member_cap(athanor_id),
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
         :ok <- member_cap(athanor_id) do
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

  # Every seat the athanor has handed out — active members and pending
  # invitations — is what the cap bounds; an invitation is a seat someone
  # will take.
  defp member_cap(athanor_id) do
    Caps.check_counted(:max_members_per_group, fn ->
      Arca.Members.count_seats(in_athanor(athanor_id))
    end)
  end

  # Seat by email only when the provider verifies it. Unknown verification
  # creates an invitation pending a verified sign-in; explicit false refuses.
  # Use user_id for providers that omit email verification.
  defp known_and_active?(%User{} = user),
    do: user.email_verified == true and user.status == "active"

  defp find_person(id) do
    if Sanctum.Auth.Identity.key?(id), do: Users.get_by_identity(id), else: Users.get(id)
  end

  defp invite(athanor_id, email, added_by) do
    case Arca.Members.find_invited(in_athanor(athanor_id), email) do
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

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Turn every `invited` row for the person's email into their active
  membership — but only for an address the provider **proved**.

  An invited row names an email and no person, so activating it is a grant
  keyed on the address alone: anyone who can get an issuer to assert
  `carol@acme.com` would inherit every seat held for Carol. `Sanctum.Door`
  already refuses an exact email allowlist entry on anything but `true`, and
  a group seat is the same kind of grant, so it takes the same answer. An
  issuer that never asserts `email_verified` seats nobody by email; the seat
  is not withdrawn, and a later sign-in that does prove the address claims it.

  Two set-based statements in one transaction, so two first sign-ins of the
  same identity cannot both claim a row: invitations for athanors where the
  person is already active are dropped, the rest are activated with the email
  consumed (the assignment index then admits no second row for the person and
  athanor). An invitation already activated, or already withdrawn, is not
  there to find and produces no second membership. Returns how many activated.
  """
  @spec activate_invited(User.t()) :: {:ok, non_neg_integer()} | {:error, :database_error}
  def activate_invited(%User{email: email, email_verified: true, id: user_id})
      when is_binary(email) do
    with {:ok, athanor_ids} <-
           Arca.Members.activate_invited(server(), user_id, email, DateTime.utc_now()) do
      for athanor_id <- athanor_ids do
        broadcast_change(user_id, athanor_id, :joined)
        Sanctum.Notify.member_changed(athanor_id)
      end

      {:ok, length(athanor_ids)}
    end
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
    email = String.downcase(String.trim(email))

    # Deliberate default: the deny's best-effort sweep — a withdrawal the
    # store missed leaves invited rows, not seats: activation re-checks the
    # door, which now denies the address.
    case Arca.Members.withdraw_invites_for_email(server(), email) do
      {:ok, athanor_ids} ->
        for athanor_id <- athanor_ids, is_binary(athanor_id) do
          Sanctum.Notify.member_changed(athanor_id)
        end

        length(athanor_ids)

      {:error, _} ->
        0
    end
  end

  def withdraw_invites_for_email(_), do: 0

  @spec remove(Membership.t()) :: {:ok, Membership.t()} | {:error, term()}
  def remove(%Membership{} = membership), do: Arca.Members.delete(server(), membership)

  @doc """
  Remove a person from an athanor (or a pending invite by email). The last
  active member leaving a group archives it.
  The owner of a person's athanor is that athanor's one member and is never
  removed — deny at the door is the only way out of one's own furnace.

  The person's thread follows in the athanor go with the seat: a follow row
  left behind would resume the moment they are re-added, so a returning
  member starts unfollowed like a new one.
  """
  @spec remove_member(Arca.Schemas.Athanor.t(), [user_id: String.t()] | [email: String.t()]) ::
          :ok | {:error, term()}
  def remove_member(%{kind: "person"}, _target), do: {:error, :person_athanor}

  def remove_member(%{id: athanor_id} = athanor, user_id: user_id) when is_binary(user_id) do
    # Follows are dropped BEFORE the membership row, for the reason
    # `end_if_frozen/1` runs first: with the row already gone a failed
    # sweep could never be retried (`find/3` answers :not_found), and the
    # orphaned follows would stand until a re-add revived them.
    with {:ok, row} <- find(user_id, "athanor", athanor_id),
         :ok <- end_if_frozen(athanor),
         :ok <- Arca.ThreadSubscriptionStorage.unfollow_all(athanor_id, user_id),
         {:ok, _} <- remove(row) do
      # Invalidate cached contexts after membership removal; retain sessions for revalidation.
      Sanctum.Session.invalidate_memo_for_user(user_id)
      broadcast_change(user_id, athanor_id, :left)
      Sanctum.Notify.member_changed(athanor_id)
      archive_when_empty(athanor)
      :ok
    end
  end

  def remove_member(%{id: athanor_id}, email: email) when is_binary(email) do
    with {:ok, row} <- Arca.Members.find_invited(in_athanor(athanor_id), String.downcase(email)),
         {:ok, _} <- remove(row) do
      Sanctum.Notify.member_changed(athanor_id)
      :ok
    end
  end

  @doc """
  Remove every row of a person (a denied user's rows) — group and platform
  alike, and their thread follows in every athanor they held a seat in. A
  group they were the last active member of is archived, as when they
  leave it. A failure is reported: the caller is ejecting someone and must
  not answer "done" while rows survive.
  """
  @spec remove_all_for_user(String.t()) :: :ok | {:error, term()}
  def remove_all_for_user(user_id) when is_binary(user_id) do
    # Frozen estates end when ANYONE leaves — archived BEFORE the rows
    # go, for the same reason `remove_member/2` orders it that way: a
    # failure must abort while the memberships still exist, or the husk
    # could never be re-attempted and its pair_key would stand forever.
    # The follows go before the rows for the same reason.
    with {:ok, rows} <- Arca.Members.list_all_for_user(server(), user_id),
         :ok <- end_frozen_estates(rows),
         :ok <- drop_follows(rows, user_id),
         {:ok, _count} <- Arca.Members.delete_all_for_user(server(), user_id) do
      for %{athanor_id: athanor_id} <- rows, is_binary(athanor_id) do
        broadcast_change(user_id, athanor_id, :left)
        Sanctum.Notify.member_changed(athanor_id)

        case Athanors.get(athanor_id) do
          {:ok, athanor} -> archive_when_empty(athanor)
          _ -> :ok
        end
      end

      :ok
    end
  end

  defp end_frozen_estates(rows) do
    rows
    |> athanor_ids()
    |> Enum.reduce_while(:ok, fn athanor_id, :ok ->
      case Athanors.get(athanor_id) do
        {:ok, athanor} ->
          case end_if_frozen(athanor) do
            :ok -> {:cont, :ok}
            {:error, _} = err -> {:halt, err}
          end

        # A membership naming no live athanor row has nothing to end; a
        # store fault must abort — "unreadable" is not "not frozen".
        {:error, :not_found} ->
          {:cont, :ok}

        {:error, _} = err ->
          {:halt, err}
      end
    end)
  end

  defp drop_follows(rows, user_id) do
    rows
    |> athanor_ids()
    |> Enum.reduce_while(:ok, fn athanor_id, :ok ->
      case Arca.ThreadSubscriptionStorage.unfollow_all(athanor_id, user_id) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  # The athanors a person's rows name — a platform row names none.
  defp athanor_ids(rows) do
    rows
    |> Enum.map(& &1.athanor_id)
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  @doc """
  The members of an athanor — active and invited — as display rows, oldest
  first: `%{user_id, email, display_name, namespace, status, added_by, since}`.
  Paged with `limit:` (default and ceiling `Arca.Members.max_page/0`) and
  `offset:`; the member cap bounds the roster, the page bounds one read.
  """
  @spec list_by_athanor(String.t(), keyword()) :: {:ok, [map()]} | {:error, :database_error}
  def list_by_athanor(athanor_id, opts \\ []) when is_binary(athanor_id),
    do: Arca.Members.list(in_athanor(athanor_id), opts)

  @doc "Every row of a person: platform and athanor, active only. Uncapped."
  @spec list_by_user(String.t()) :: {:ok, [Membership.t()]} | {:error, :database_error}
  def list_by_user(user_id), do: Arca.Members.list_active_for_user(server(), user_id)

  @doc """
  How many active members an athanor has. Strict like `Athanors.count/0`:
  a count that decides anything (auto-archive keys on zero) must refuse
  when the store cannot answer, never read as empty.
  """
  @spec count_by_athanor(String.t()) :: {:ok, non_neg_integer()} | {:error, :database_error}
  def count_by_athanor(athanor_id), do: Arca.Members.count_active(in_athanor(athanor_id))

  @doc """
  Whether two people currently sit together in at least one ACTIVE estate.

  The DM reachability rule: a pair can be minted only with someone already
  in a room with you. This is what keeps `athanor.pair` from being a
  directory — a user id you cannot see on any members list is a user id you
  cannot pair with, and probing one answers exactly what probing an unknown
  one does. No estate is shared server-wide, so two people who belong to no
  group together cannot reach each other at all; operators are no exception
  and add each other to a group to talk.

  Active memberships in active athanors only: an invitation is not a seat,
  and an archived room is not a room. Fails toward "no", like `solo?/1` —
  an unanswerable read must not open a door.
  """
  @spec shared_estate?(String.t(), String.t()) :: boolean()
  def shared_estate?(user_a, user_b) when is_binary(user_a) and is_binary(user_b),
    do: match?({:ok, true}, Arca.Members.shared_estate?(server(), user_a, user_b))

  def shared_estate?(_, _), do: false

  @doc """
  Whether exactly one human is in this estate.

  Returns whether the athanor has a single human member. Used for implicit
  agent addressing and speaker prefixes in turn tasks.

  Active memberships only: an `invited` row is a seat nobody is sitting in.
  Fails toward "several", so an unanswerable count costs an `@` rather than
  starting turns nobody addressed.
  """
  @spec solo?(String.t() | nil) :: boolean()
  def solo?(athanor_id) when is_binary(athanor_id),
    do: match?({:ok, 1}, count_by_athanor(athanor_id))

  def solo?(_), do: false

  @doc "The PubSub topic a person's LiveViews subscribe to for their own membership changes."
  @spec topic(String.t()) :: String.t()
  def topic(user_id) when is_binary(user_id), do: @topic_prefix <> user_id

  @doc false
  def broadcast_change(user_id, athanor_id, change) when is_binary(user_id),
    do: Sanctum.Telemetry.membership_changed(user_id, athanor_id, change)

  def broadcast_change(_user_id, _athanor_id, _change), do: :ok

  # ---- internal --------------------------------------------------------------

  # A person's seats span athanors and a platform row names none, so the
  # fabric reads as the server.
  defp server, do: Cyfr.Actor.system()

  # The server narrowed to one athanor — the actor a read or write of that
  # athanor's own roster runs as. A nil athanor is refused by the facade
  # before any query.
  defp in_athanor(id), do: %{Cyfr.Actor.system() | athanor_id: id, scope: :athanor}

  # A frozen estate ends when ANYONE leaves, not when the last person does.
  # Waiting for empty would leave a one-member pair standing: a second You
  # that the person who stayed can still open, whose `pair_key` still
  # hashes both ids — so the two could never be paired again, because the
  # husk holds the key. Ending it releases the key; clicking the name later
  # mints a new tape rather than reopening this one.
  #
  # Archived BEFORE the membership row goes, and the result is the leave's
  # to report: with the row already gone, a failed archive could never be
  # retried (`find/3` answers :not_found), and the husk's `pair_key` would
  # block those two pairing forever. `Athanors.archive/2` re-reads and is
  # idempotent on an archived row, so both failure orders self-heal — a
  # failed archive leaves everything as it was, and a failed row removal
  # after it retries straight through.
  defp end_if_frozen(%{kind: "group", roster: "frozen"} = athanor) do
    with {:ok, _} <- Athanors.archive(athanor, reason: :empty), do: :ok
  end

  defp end_if_frozen(_athanor), do: :ok

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

  defp find(user_id, "platform", _athanor_id),
    do: Arca.Members.find_platform(server(), user_id)

  defp find(user_id, _scope, athanor_id),
    do: Arca.Members.find(in_athanor(athanor_id), user_id)
end
