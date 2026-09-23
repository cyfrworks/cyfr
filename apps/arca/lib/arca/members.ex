# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Members do
  @moduledoc """
  Membership rows — "user X is a member of athanor A"
  (`Arca.Schemas.Membership`).

  ## Two shapes, because a membership is the fabric that names a tenant

  Every function states which shape it is, and the shape decides where its
  athanor comes from.

    * **Inside one tenant.** `seat/2`, `find/2`, `find_invited/2`,
      `list/2`, `count_active/1` and `count_seats/1` work in the athanor
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
      every athanor to resolve which one they work in, an invitation is
      keyed on an email rather than on an athanor, and a deny sweeps a
      person out of every estate at once. None of these can be filtered
      by one athanor without ceasing to do their job, so they match
      `scope: :platform` and refuse an athanor-scoped actor with
      `{:error, :cross_tenant}`.

  ## The platform transitions

  `ensure_platform/3`, `revoke_platform/3` and `reconcile_platform/3` read
  rows and change them under one view, so each is one
  `Arca.Repo.locking_transaction/2` taking its locks in one order: the
  member slot, the bootstrap claim, the people sorted by id, their
  platform grants, then their sessions. A sign-in's grant or revoke takes
  only the suffix from the person on, and never a claim or a slot after
  it. A removed grant ends every session of its person in the same
  transaction, and the ended sessions' token hashes are read from that
  DELETE itself, so the caller invalidates exactly what was removed and
  only after it committed.

  Nothing that belongs to Ecto crosses the boundary. A refusal is
  `:conflict` (the assignment index — the row is already there, so a
  caller that raced re-reads it), `{:invalid, %{field => [message]}}`,
  `:unknown_athanor`, `:not_found`, `:cross_tenant`, `:no_athanor` or
  `:database_error`.
  """

  import Ecto.Query

  alias Arca.{ControlPlane, JobClaims, QueryHelpers}
  alias Arca.Schemas.{Athanor, JobClaim, Membership, Session, User}

  @type refusal :: {:error, :cross_tenant | :database_error}
  @type write_refusal ::
          {:error,
           :conflict | :unknown_athanor | {:invalid, %{atom() => [String.t()]}} | :database_error}

  @typedoc """
  The identity facts one admitted sign-in asserted, spelled as the
  `users` row stores them: the lowercased email, and the verification
  claim as `true`, `false` or `nil` for none.
  """
  @type identity :: %{email: String.t() | nil, email_verified: boolean() | nil}

  @typedoc "One person a platform transition took the grant from, and the sessions it ended."
  @type revoked :: %{user_id: String.t(), session_hashes: [binary()]}

  @typedoc "Why the operator reconcile committed nothing."
  @type reconcile_refusal ::
          {:error,
           :slot_lost
           | :claim_taken
           | :claim_lapsed
           | :missing_user
           | :cross_tenant
           | :database_error}

  @max_page 500

  @doc "The ceiling on one roster page, which is also its default."
  @spec max_page() :: pos_integer()
  def max_page, do: @max_page

  # ---- inside one tenant -----------------------------------------------------

  @doc """
  Write a membership row in the actor's athanor. `attrs` carries the
  principal (`:user_id` for an active row, `:email` for an invited one),
  `:scope`, `:status` and `:added_by`; the athanor is the actor's and any
  `:athanor_id` in `attrs` is ignored.

  The row also carries a foreign key, but SQLite reports a violation
  without naming it, so the changeset could not translate it. Reading the
  athanor first answers `:unknown_athanor` the same way on both adapters.
  """
  @spec seat(Cyfr.Actor.t(), map()) ::
          {:ok, Membership.t()} | {:error, :no_athanor} | write_refusal()
  def seat(%Cyfr.Actor{athanor_id: athanor_id}, attrs)
      when is_binary(athanor_id) and athanor_id != "" and is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("Arca.Members.seat", fn ->
      if athanor_exists?(athanor_id) do
        attrs |> defaults() |> Map.put(:athanor_id, athanor_id) |> do_insert()
      else
        {:error, :unknown_athanor}
      end
    end)
  end

  def seat(%Cyfr.Actor{}, _attrs), do: {:error, :no_athanor}

  @doc "The person's ACTIVE-or-invited athanor row in the actor's athanor, if any."
  @spec find(Cyfr.Actor.t(), String.t()) ::
          {:ok, Membership.t()} | {:error, :not_found | :no_athanor | :database_error}
  def find(%Cyfr.Actor{athanor_id: athanor_id}, user_id)
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
  end

  def find(%Cyfr.Actor{}, _user_id), do: {:error, :no_athanor}

  @doc "The invitation this address holds in the actor's athanor, if any."
  @spec find_invited(Cyfr.Actor.t(), String.t()) ::
          {:ok, Membership.t()} | {:error, :not_found | :no_athanor | :database_error}
  def find_invited(%Cyfr.Actor{athanor_id: athanor_id}, email)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(email) do
    Arca.Repo.Errors.with_db_rescue("Arca.Members.find_invited", fn ->
      found(
        Arca.Repo.one(
          from(m in Membership,
            where: m.email == ^email and m.athanor_id == ^athanor_id and m.status == "invited",
            limit: 1
          )
        )
      )
    end)
  end

  def find_invited(%Cyfr.Actor{}, _email), do: {:error, :no_athanor}

  @doc """
  The actor's athanor's members — active and invited — as display rows,
  oldest first: `%{user_id, email, display_name, namespace, status,
  added_by, since}`. Paged with `limit:` (default and ceiling
  `max_page/0`) and `offset:`.
  """
  @spec list(Cyfr.Actor.t(), keyword()) ::
          {:ok, [map()]} | {:error, :no_athanor | :database_error}
  def list(actor, opts \\ [])

  def list(%Cyfr.Actor{athanor_id: athanor_id}, opts)
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

  def list(%Cyfr.Actor{}, _opts), do: {:error, :no_athanor}

  @doc "How many ACTIVE members the actor's athanor has."
  @spec count_active(Cyfr.Actor.t()) ::
          {:ok, non_neg_integer()} | {:error, :no_athanor | :database_error}
  def count_active(%Cyfr.Actor{athanor_id: athanor_id})
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.Members.count_active", fn ->
      counted(
        from(m in Membership,
          where: m.athanor_id == ^athanor_id and m.status == "active",
          select: count(m.id)
        )
      )
    end)
  end

  def count_active(%Cyfr.Actor{}), do: {:error, :no_athanor}

  @doc """
  Every ACTIVE member's person id in the actor's athanor, oldest first.

  Unpaged, unlike `list/2`: this is the roster a close has to reach in
  full — a member it missed would keep a cached authorization the close
  was supposed to end — and the member cap is what bounds it.
  """
  @spec active_user_ids(Cyfr.Actor.t()) ::
          {:ok, [String.t()]} | {:error, :no_athanor | :database_error}
  def active_user_ids(%Cyfr.Actor{athanor_id: athanor_id})
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

  def active_user_ids(%Cyfr.Actor{}), do: {:error, :no_athanor}

  @doc """
  Every seat the actor's athanor has handed out — active members and
  pending invitations alike, which is what the member cap bounds: an
  invitation is a seat someone will take.
  """
  @spec count_seats(Cyfr.Actor.t()) ::
          {:ok, non_neg_integer()} | {:error, :no_athanor | :database_error}
  def count_seats(%Cyfr.Actor{athanor_id: athanor_id})
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.Members.count_seats", fn ->
      counted(
        from(m in Membership,
          where: m.athanor_id == ^athanor_id and m.scope == "athanor",
          select: count(m.id)
        )
      )
    end)
  end

  def count_seats(%Cyfr.Actor{}), do: {:error, :no_athanor}

  # ---- across tenants --------------------------------------------------------

  @doc "Write the platform row for a person — the grant that names no athanor."
  @spec grant_platform(Cyfr.Actor.t(), map()) ::
          {:ok, Membership.t()} | refusal() | write_refusal()
  def grant_platform(%Cyfr.Actor{scope: :platform}, attrs) when is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("Arca.Members.grant_platform", fn ->
      attrs
      |> defaults()
      |> Map.put(:scope, "platform")
      |> Map.put(:athanor_id, nil)
      |> do_insert()
    end)
  end

  def grant_platform(%Cyfr.Actor{}, _attrs), do: {:error, :cross_tenant}

  @doc "A membership by its own id. The athanor may be nil — a platform row names none."
  @spec get(Cyfr.Actor.t(), String.t()) ::
          {:ok, Membership.t()} | {:error, :not_found} | refusal()
  # arca:unscoped-ok a membership is fabric, read by its own id; the athanor may be nil (platform).
  def get(%Cyfr.Actor{scope: :platform}, id) when is_binary(id) do
    Arca.Repo.Errors.with_db_rescue("Arca.Members.get", fn ->
      found(Arca.Repo.get(Membership, id))
    end)
  end

  def get(%Cyfr.Actor{}, _id), do: {:error, :cross_tenant}

  @doc "The person's platform row, if any."
  @spec find_platform(Cyfr.Actor.t(), String.t()) ::
          {:ok, Membership.t()} | {:error, :not_found} | refusal()
  # arca:unscoped-ok a platform row names no athanor by design.
  def find_platform(%Cyfr.Actor{scope: :platform}, user_id) when is_binary(user_id) do
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
  end

  def find_platform(%Cyfr.Actor{}, _user_id), do: {:error, :cross_tenant}

  @doc "Delete exactly the row the caller already holds."
  @spec delete(Cyfr.Actor.t(), Membership.t()) ::
          {:ok, Membership.t()} | refusal() | write_refusal()
  # arca:unscoped-ok deletes exactly the fabric row the caller already holds.
  def delete(%Cyfr.Actor{scope: :platform}, %Membership{} = membership) do
    Arca.Repo.Errors.with_db_rescue("Arca.Members.delete", fn ->
      membership |> Arca.Repo.delete() |> settled()
    end)
  end

  def delete(%Cyfr.Actor{}, %Membership{}), do: {:error, :cross_tenant}

  @doc "Every platform row — the server's operators, as the rows say."
  @spec list_platform(Cyfr.Actor.t()) :: {:ok, [Membership.t()]} | refusal()
  # arca:unscoped-ok platform memberships carry no athanor by design.
  def list_platform(%Cyfr.Actor{scope: :platform}) do
    Arca.Repo.Errors.with_db_rescue("Arca.Members.list_platform", fn ->
      {:ok, Arca.Repo.all(from(m in Membership, where: m.scope == "platform"))}
    end)
  end

  def list_platform(%Cyfr.Actor{}), do: {:error, :cross_tenant}

  @doc """
  Hold the person's platform grant, writing it when absent, and answer
  whether this call wrote it.

  `expected_identity:` is what an admitted sign-in asserted (`t:identity/0`).
  With it, the person's row is locked and must still carry exactly those
  facts, and its email must not be explicitly unverified, or nothing is
  written and the answer is `{:error, :stale_identity}`: an earlier
  sign-in must not grant the operator bit to a row a later assertion has
  since changed. Without it, the grant is the server's own act and
  answers to no sign-in. `added_by:` names who wrote the row.
  """
  @spec ensure_platform(Cyfr.Actor.t(), String.t(), keyword()) ::
          {:ok, %{membership: Membership.t(), granted: boolean()}}
          | {:error, :stale_identity}
          | refusal()
          | write_refusal()
  def ensure_platform(%Cyfr.Actor{scope: :platform}, user_id, opts)
      when is_binary(user_id) and is_list(opts) do
    expected = Keyword.get(opts, :expected_identity)

    grant = fn ->
      with :ok <- identity_holds(user_id, expected, :grant) do
        case locked_platform_rows([user_id]) do
          [%Membership{} = row | _] ->
            %{membership: row, granted: false}

          [] ->
            attrs = %{user_id: user_id, added_by: Keyword.get(opts, :added_by)}

            case attrs |> defaults() |> Map.put(:scope, "platform") |> do_insert() do
              {:ok, row} -> %{membership: row, granted: true}
              {:error, reason} -> Arca.Repo.rollback(reason)
            end
        end
      else
        {:error, reason} -> Arca.Repo.rollback(reason)
      end
    end

    Arca.Repo.Errors.with_db_rescue("Arca.Members.ensure_platform", fn ->
      # A writer that does not take the person's lock (`grant_platform/2`)
      # can still win the assignment index between the read and the
      # insert; the one retry reads the row it wrote.
      case Arca.Repo.locking_transaction(grant) do
        {:error, :conflict} -> Arca.Repo.locking_transaction(grant)
        other -> other
      end
    end)
  end

  def ensure_platform(%Cyfr.Actor{}, _user_id, _opts), do: {:error, :cross_tenant}

  @doc """
  Remove the person's platform grant and, when one went, every session
  they hold, in one transaction. Answers how many grant rows went and the
  token hashes of the sessions that went with them; an absent grant ends
  no session.

  `expected_identity:` checks the person's row as `ensure_platform/3`
  does, answering `{:error, :stale_identity}` with nothing removed.
  """
  @spec revoke_platform(Cyfr.Actor.t(), String.t(), keyword()) ::
          {:ok, %{removed: non_neg_integer(), session_hashes: [binary()]}}
          | {:error, :stale_identity}
          | refusal()
  def revoke_platform(actor, user_id, opts \\ [])

  def revoke_platform(%Cyfr.Actor{scope: :platform}, user_id, opts)
      when is_binary(user_id) and is_list(opts) do
    expected = Keyword.get(opts, :expected_identity)

    Arca.Repo.Errors.with_db_rescue("Arca.Members.revoke_platform", fn ->
      Arca.Repo.locking_transaction(fn ->
        with :ok <- identity_holds(user_id, expected, :revoke) do
          {removed, session_hashes} = remove_platform([user_id])
          %{removed: removed, session_hashes: Map.get(session_hashes, user_id, [])}
        else
          {:error, reason} -> Arca.Repo.rollback(reason)
        end
      end)
    end)
  end

  def revoke_platform(%Cyfr.Actor{}, _user_id, _opts), do: {:error, :cross_tenant}

  @doc """
  The boot's operator reconcile: remove every platform grant whose person
  the operator list no longer names, with all of that person's sessions,
  under the member slot and the `bootstrap` claim `claim` — one
  transaction, or nothing.

  `opts` (all required): `:slot`, the slot this member won
  (`Arca.ControlPlane.held/0`), or `:none` in a deployment where no
  member claims one; `:operators`, the lowercased emails the operator
  list names; `:policy_digest`, the digest of that list; `:lease_ms`, the
  claim lease the final renewal extends.

  A grant stands while its person exists and their stored email is one of
  `:operators`. Every person holding a grant is locked, sorted by id, and
  their grants are read again under that lock; those are the grants
  examined, and at commit each of them stands. A grant naming a person
  with no row refuses the whole reconcile (`:missing_user`) rather than
  guessing.

  The slot is verified and the claim held at the start and again at the
  end, where a final checked renewal records
  `%{version: 1, status: "complete", policy_digest: …, owner: …}` in
  `JobClaim.detail` and answers the newest claim, which is what the
  caller releases. `{:ok, %{claim: renewed, revoked: [revoked()]}}` is
  answered only after commit.
  """
  @spec reconcile_platform(Cyfr.Actor.t(), JobClaim.t(), keyword()) ::
          {:ok, %{claim: JobClaim.t(), revoked: [revoked()]}} | reconcile_refusal()
  def reconcile_platform(%Cyfr.Actor{scope: :platform}, %JobClaim{} = claim, opts)
      when is_list(opts) do
    slot = Keyword.fetch!(opts, :slot)
    operators = opts |> Keyword.fetch!(:operators) |> MapSet.new()
    detail = completion(Keyword.fetch!(opts, :policy_digest), claim.owner)
    lease_ms = Keyword.fetch!(opts, :lease_ms)

    Arca.Repo.Errors.with_db_rescue("Arca.Members.reconcile_platform", fn ->
      Arca.Repo.locking_transaction(fn ->
        with :ok <- slot_holds(slot),
             {:ok, held} <- claim_holds(claim),
             {:ok, revoked} <- delist(operators),
             :ok <- slot_holds(slot),
             {:ok, renewed} <- renewed(held, lease_ms, detail) do
          %{claim: renewed, revoked: revoked}
        else
          {:error, reason} -> Arca.Repo.rollback(reason)
        end
      end)
    end)
  end

  def reconcile_platform(%Cyfr.Actor{}, %JobClaim{}, _opts), do: {:error, :cross_tenant}

  @doc "Every ACTIVE row of a person — platform and athanor alike, newest first."
  @spec list_active_for_user(Cyfr.Actor.t(), String.t()) ::
          {:ok, [Membership.t()]} | refusal()
  # arca:unscoped-ok person-keyed by design — resolving a person's seats across athanors is the point.
  def list_active_for_user(%Cyfr.Actor{scope: :platform}, user_id) when is_binary(user_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.Members.list_active_for_user", fn ->
      {:ok,
       Arca.Repo.all(
         from(m in Membership,
           where: m.user_id == ^user_id and m.status == "active",
           order_by: [desc: m.created_at]
         )
       )}
    end)
  end

  def list_active_for_user(%Cyfr.Actor{}, _user_id), do: {:error, :cross_tenant}

  @doc "Every row of a person, whatever its status — what a deny has to sweep."
  @spec list_all_for_user(Cyfr.Actor.t(), String.t()) :: {:ok, [Membership.t()]} | refusal()
  # arca:unscoped-ok person-keyed by design — a deny sweeps every athanor the person sat in.
  def list_all_for_user(%Cyfr.Actor{scope: :platform}, user_id) when is_binary(user_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.Members.list_all_for_user", fn ->
      {:ok, Arca.Repo.all(from(m in Membership, where: m.user_id == ^user_id))}
    end)
  end

  def list_all_for_user(%Cyfr.Actor{}, _user_id), do: {:error, :cross_tenant}

  @doc "Delete every row of a person. Answers how many rows went."
  @spec delete_all_for_user(Cyfr.Actor.t(), String.t()) ::
          {:ok, non_neg_integer()} | refusal()
  # arca:unscoped-ok person-keyed by design — a deny sweeps every athanor the person sat in.
  def delete_all_for_user(%Cyfr.Actor{scope: :platform}, user_id) when is_binary(user_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.Members.delete_all_for_user", fn ->
      {count, _} = Arca.Repo.delete_all(from(m in Membership, where: m.user_id == ^user_id))
      {:ok, count}
    end)
  end

  def delete_all_for_user(%Cyfr.Actor{}, _user_id), do: {:error, :cross_tenant}

  @doc """
  Turn every invitation held for `email` into this person's active
  membership, and answer the athanors that changed.

  Two set-based statements in ONE transaction, so two first sign-ins of
  the same identity cannot both claim a row: invitations for athanors
  where the person is already active are dropped, the rest are activated
  with the email consumed — after which the assignment index admits no
  second row for that person and athanor. An invitation already activated
  or already withdrawn is not there to find, so neither produces a second
  membership.
  """
  @spec activate_invited(Cyfr.Actor.t(), String.t(), String.t(), DateTime.t()) ::
          {:ok, [String.t()]} | refusal()
  # arca:unscoped-ok invited rows are email-keyed fabric, activated across athanors.
  def activate_invited(%Cyfr.Actor{scope: :platform}, user_id, email, %DateTime{} = now)
      when is_binary(user_id) and is_binary(email) do
    Arca.Repo.Errors.with_db_rescue("Arca.Members.activate_invited", fn ->
      invited =
        from(m in Membership,
          where: m.email == ^email and m.status == "invited" and m.scope == "athanor"
        )

      # An invitation for an athanor the person is already an active member
      # of is superseded. Written as a subquery, not a join: SQLite refuses
      # joins on DELETE.
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

      Arca.Repo.transaction(fn ->
        Arca.Repo.delete_all(superseded)

        {_count, athanor_ids} =
          Arca.Repo.update_all(from(m in invited, select: m.athanor_id),
            set: [user_id: user_id, status: "active", email: nil, updated_at: now]
          )

        athanor_ids || []
      end)
    end)
  end

  def activate_invited(%Cyfr.Actor{}, _user_id, _email, _now), do: {:error, :cross_tenant}

  @doc """
  Drop every pending invitation for an address, and answer the athanors
  that were holding one. An invited row names an email and no person, so
  a deny's sweep by `user_id` cannot see it.
  """
  @spec withdraw_invites_for_email(Cyfr.Actor.t(), String.t()) ::
          {:ok, [String.t()]} | refusal()
  # arca:unscoped-ok invites are email-keyed fabric, withdrawn across every athanor that invited.
  def withdraw_invites_for_email(%Cyfr.Actor{scope: :platform}, email) when is_binary(email) do
    Arca.Repo.Errors.with_db_rescue("Arca.Members.withdraw_invites_for_email", fn ->
      {_count, athanor_ids} =
        Arca.Repo.delete_all(
          from(m in Membership,
            where: m.email == ^email and m.status == "invited" and m.scope == "athanor",
            select: m.athanor_id
          )
        )

      {:ok, athanor_ids || []}
    end)
  end

  def withdraw_invites_for_email(%Cyfr.Actor{}, _email), do: {:error, :cross_tenant}

  @doc """
  Whether two people currently sit together in at least one ACTIVE estate
  — active memberships in active athanors only, since an invitation is not
  a seat and an archived room is not a room.
  """
  @spec shared_estate?(Cyfr.Actor.t(), String.t(), String.t()) :: {:ok, boolean()} | refusal()
  def shared_estate?(%Cyfr.Actor{scope: :platform}, user_a, user_b)
      when is_binary(user_a) and is_binary(user_b) do
    Arca.Repo.Errors.with_db_rescue("Arca.Members.shared_estate?", fn ->
      count =
        Arca.Repo.one(
          from(a in Membership,
            join: b in Membership,
            on: a.athanor_id == b.athanor_id,
            join: ath in Athanor,
            on: ath.id == a.athanor_id,
            where:
              a.user_id == ^user_a and b.user_id == ^user_b and
                a.scope == "athanor" and b.scope == "athanor" and
                a.status == "active" and b.status == "active" and
                ath.status == "active",
            select: count(a.id)
          )
        )

      {:ok, (count || 0) > 0}
    end)
  end

  def shared_estate?(%Cyfr.Actor{}, _user_a, _user_b), do: {:error, :cross_tenant}

  # ---- internal --------------------------------------------------------------

  defp slot_holds(:none), do: :ok

  defp slot_holds(slot) do
    case ControlPlane.verify_held(slot) do
      :ok -> :ok
      :lost -> {:error, :slot_lost}
    end
  end

  defp claim_holds(claim) do
    case JobClaims.hold(claim) do
      {:ok, held} -> {:ok, held}
      :taken -> {:error, :claim_taken}
      :lapsed -> {:error, :claim_lapsed}
    end
  end

  defp renewed(held, lease_ms, detail) do
    case JobClaims.renew_held(held, lease_ms, detail: detail) do
      {:ok, renewed} -> {:ok, renewed}
      :taken -> {:error, :claim_taken}
      :lapsed -> {:error, :claim_lapsed}
    end
  end

  defp completion(digest, owner) when is_binary(digest) and is_binary(owner) do
    Jason.encode!(%{version: 1, status: "complete", policy_digest: digest, owner: owner})
  end

  # arca:unscoped-ok platform rows name no athanor by design; the reconcile is server-wide.
  defp delist(operators) do
    user_ids =
      Arca.Repo.all(from(m in Membership, where: m.scope == "platform", select: m.user_id))
      |> Enum.uniq()
      |> Enum.sort()

    people = lock_people(Enum.reject(user_ids, &is_nil/1))

    if Enum.any?(user_ids, &(not Map.has_key?(people, &1))) do
      {:error, :missing_user}
    else
      delisted =
        for %Membership{user_id: user_id} <- locked_platform_rows(Map.keys(people)),
            not MapSet.member?(operators, people[user_id].email),
            uniq: true,
            do: user_id

      {_removed, session_hashes} = remove_platform(delisted)

      {:ok,
       Enum.map(delisted, &%{user_id: &1, session_hashes: Map.get(session_hashes, &1, [])})}
    end
  end

  # The person's row under lock, checked against what a sign-in asserted.
  # A grant also refuses an email the provider explicitly left unverified.
  defp identity_holds(user_id, expected, transition) do
    person = Map.get(lock_people([user_id]), user_id)

    cond do
      is_nil(expected) -> :ok
      is_nil(person) -> {:error, :stale_identity}
      person.email != expected.email -> {:error, :stale_identity}
      person.email_verified != expected.email_verified -> {:error, :stale_identity}
      transition == :grant and person.email_verified == false -> {:error, :stale_identity}
      true -> :ok
    end
  end

  # People before their grants, sorted by id: the order every platform
  # transition takes their locks in.
  defp lock_people([]), do: %{}

  defp lock_people(user_ids) do
    from(u in User, where: u.id in ^user_ids, order_by: [asc: u.id])
    |> QueryHelpers.for_update()
    |> Arca.Repo.all()
    |> Map.new(&{&1.id, &1})
  end

  # arca:unscoped-ok platform rows name no athanor by design; the people are the scope.
  defp locked_platform_rows(user_ids) do
    from(m in Membership,
      where: m.scope == "platform" and m.user_id in ^user_ids,
      order_by: [asc: m.user_id, asc: m.id]
    )
    |> QueryHelpers.for_update()
    |> Arca.Repo.all()
  end

  # Grants first, then the sessions of the people who lost one, each read
  # back from its own DELETE: what the caller invalidates is exactly what
  # this transaction removed.
  # arca:unscoped-ok platform rows name no athanor, and sessions are the person's own.
  defp remove_platform(user_ids) do
    {_count, removed} =
      Arca.Repo.delete_all(
        from(m in Membership,
          where: m.scope == "platform" and m.user_id in ^user_ids,
          select: m.user_id
        )
      )

    removed = removed || []
    people = Enum.uniq(removed)

    session_hashes =
      if people == [] do
        %{}
      else
        {_count, sessions} =
          Arca.Repo.delete_all(
            from(s in Session, where: s.user_id in ^people, select: {s.user_id, s.token_hash})
          )

        Enum.group_by(sessions || [], &elem(&1, 0), &elem(&1, 1))
      end

    {length(removed), session_hashes}
  end

  # arca:unscoped-ok the athanor is the caller's clause's: `seat/2` takes it from the actor and
  # `grant_platform/2` writes the row that names none, so this statement never chooses one.
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
    |> Map.put_new(:id, Cyfr.UUID7.generate_id("mem"))
    |> Map.put_new(:created_at, now)
    |> Map.put_new(:updated_at, now)
  end

  defp athanor_exists?(athanor_id),
    do: Arca.Repo.exists?(from(a in Athanor, where: a.id == ^athanor_id))

  defp found(nil), do: {:error, :not_found}
  defp found(%Membership{} = membership), do: {:ok, membership}

  defp counted(query), do: {:ok, Arca.Repo.one(query) || 0}

  defp settled({:ok, %Membership{} = membership}), do: {:ok, membership}
  defp settled({:error, %Ecto.Changeset{} = changeset}), do: {:error, refusal(changeset)}

  # The assignment index is the one refusal a caller acts on rather than
  # reports: the row it wanted is already there, so it re-reads it.
  defp refusal(%Ecto.Changeset{errors: errors} = changeset) do
    if unique?(errors), do: :conflict, else: {:invalid, messages(changeset)}
  end

  defp unique?(errors) do
    Enum.any?(errors, fn {_field, {_message, meta}} -> meta[:constraint] == :unique end)
  end

  defp messages(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _whole, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
