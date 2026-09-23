# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Tenancy do
  @moduledoc """
  Tenant resolution from memberships.

  `resolve_status/2` is the single chokepoint the one establish recipe
  (`Sanctum.Caller`) flows through to attach the caller's athanor and
  capabilities to their Context. It reads the user's membership rows: an
  athanor row grants that athanor; a platform row makes the caller a
  platform admin (`platform_admin: true`), which is a capability the
  context carries, never a wider scope — every request works inside one
  athanor.

  There is no deployment "mode". A fresh install with no auth configured never
  reaches here (requests run as the unauthenticated public context). With
  auth configured, who may sign in is decided at the door
  (`Sanctum.Door`), and the rows this module reads are written at sign-in
  (`Sanctum.SignIn`) and by the `athanor.*` / `member.*` verbs.

  ## Test overrides

  Tests can bypass membership resolution by setting
  `config :sanctum, :tenancy_resolver_override, MyResolver` — the override's
  `resolve/1` runs instead. This is honored only when the compile-time flag
  `config :sanctum, :allow_tenancy_resolver_override, true` is set (test/dev);
  production releases compile it out entirely, so the override can never run.
  """

  require Logger
  alias Sanctum.Context
  alias Sanctum.Tenancy.{Athanors, Members, Users}

  @doc """
  Merge the caller's athanor and capabilities into the context.

  Without `force: true`, no-ops when the context already carries an
  `athanor_id` (the stored value was resolved at session-create time and
  re-querying every request is wasteful). The sign-in paths, which mint a
  session for a Context that has just been admitted, pass `force: true`.

  The athanor chosen is, in order: the one the context already names when a
  membership still grants it, the person's own athanor, and the first
  athanor a membership grants. A person with none of those has no working
  athanor, operator or not.

  A membership read that FAILED is `{:error, :unavailable}`, distinct from
  a person who genuinely belongs to no athanor (`{:ok, ctx}` with no
  athanor, which the tenant gate refuses): a database blip must never read
  as "you belong nowhere, contact your administrator" — a permanent-
  sounding answer to a transient fault no operator can see.

  The reads that choose the athanor also bind the context
  (`t:Sanctum.Context.credential_binding/0`). A context that holds no
  credential yet — an admitted sign-in, the only caller that passes
  `force: true` — is stamped `source_kind: :identity` with the person's
  and the chosen estate's generations and the membership that granted it,
  read after the door's verdict; a session or key context keeps its
  source and person generation and takes the new estate's. A person with
  no `users` row carries no binding, and can be issued nothing.
  """
  @spec resolve_status(Context.t(), keyword()) :: {:ok, Context.t()} | {:error, :unavailable}
  def resolve_status(ctx, opts \\ [])

  def resolve_status(%Context{athanor_id: athanor_id} = ctx, opts)
      when is_binary(athanor_id) and athanor_id != "" do
    if Keyword.get(opts, :force, false), do: do_resolve(ctx), else: {:ok, ctx}
  end

  def resolve_status(%Context{} = ctx, _opts), do: do_resolve(ctx)

  @doc """
  The athanors the context may work in — the rows behind the caller's own
  active memberships, and their own athanor. A platform admin sees their
  own memberships like anyone else; opening another athanor is an explicit,
  audited act (`Sanctum.Context.focus/2`), not a listing.
  """
  @spec list_athanors(Context.t()) :: [Sanctum.Tenancy.Athanors.athanor()]
  def list_athanors(%Context{user_id: user_id}) when is_binary(user_id) do
    Athanors.list_for_user(user_id)
  end

  def list_athanors(_), do: []

  # The membership-resolution override is a test-only seam. `do_resolve/1` is
  # defined in two compile-time variants: a production release — compiled with
  # prod config, where the flag is false — gets the plain membership path with
  # NO override code at all, so the override can never bypass membership
  # resolution regardless of how the app env is set at runtime.
  if Application.compile_env(:sanctum, :allow_tenancy_resolver_override, false) do
    defp do_resolve(%Context{} = ctx) do
      case Application.get_env(:sanctum, :tenancy_resolver_override) do
        nil ->
          resolve_from_memberships(ctx)

        module ->
          case module.resolve(ctx.user_id) do
            %{athanor_id: athanor_id} ->
              {:ok, %{ctx | athanor_id: athanor_id, scope: :athanor}}

            :no_membership ->
              {:ok, ctx}

            {:error, reason} ->
              Logger.error(
                "[Sanctum.Tenancy] resolve override failed for #{ctx.user_id}: #{inspect(reason)}"
              )

              {:error, :unavailable}
          end
      end
    end
  else
    defp do_resolve(%Context{} = ctx), do: resolve_from_memberships(ctx)
  end

  defp resolve_from_memberships(%Context{user_id: user_id} = ctx) do
    with {:ok, user} <- user_row(user_id),
         {:ok, memberships} <- Members.list_by_user(user_id) do
      {ctx, athanor} = apply_membership(ctx, memberships, user)
      {:ok, bind(ctx, user, athanor, memberships)}
    else
      {:error, reason} ->
        Logger.error("[Sanctum.Tenancy] resolve failed for #{user_id}: #{inspect(reason)}")
        {:error, :unavailable}
    end
  end

  # A person unknown to the users table (a context minted by a test stub or
  # a caller that never came through the door) resolves from memberships alone.
  defp user_row(user_id) do
    case Users.get(user_id) do
      {:ok, user} -> {:ok, user}
      {:error, :not_found} -> {:ok, nil}
      {:error, _} = err -> err
    end
  end

  # Set capability and athanor from an already-loaded membership list;
  # answers the context and the chosen estate's row.
  defp apply_membership(%Context{} = ctx, memberships, user) do
    admin? = platform_admin?(memberships)
    athanor = working_athanor(ctx, memberships, admin?, user)

    {%{
       ctx
       | scope: :athanor,
         platform_admin: admin?,
         athanor_id: athanor && athanor.id
     }, athanor}
  end

  # The binding the resolve's own reads support. A context with no source
  # of its own — an admitted sign-in — is bound as `:identity`; a session
  # or key context keeps its source and its person generation and follows
  # the estate this resolve chose.
  defp bind(%Context{} = ctx, nil, _athanor, _memberships), do: %{ctx | credential_binding: nil}

  defp bind(
         %Context{credential_binding: %{source_kind: kind} = binding} = ctx,
         _user,
         athanor,
         memberships
       )
       when kind in [:session, :api_key] do
    basis =
      if binding.focus_basis == :key, do: :key, else: focus_basis(ctx, athanor, memberships)

    %{
      ctx
      | credential_binding: %{
          binding
          | focus_basis: basis,
            athanor_generation: athanor && athanor.security_generation
        }
    }
  end

  defp bind(%Context{} = ctx, user, athanor, memberships) do
    %{
      ctx
      | credential_binding: %{
          source_kind: :identity,
          source_id: nil,
          focus_basis: focus_basis(ctx, athanor, memberships),
          user_generation: user.security_generation,
          athanor_generation: athanor && athanor.security_generation
        }
    }
  end

  @doc """
  The membership row that authorizes `ctx`'s focus on `athanor`: the
  person's active seat there, else — for a platform admin — their
  platform row, else nil. `memberships` are the person's active rows.
  """
  @spec focus_basis(Context.t(), map() | nil, [map()]) :: String.t() | nil
  def focus_basis(_ctx, nil, _memberships), do: nil

  def focus_basis(%Context{} = ctx, %{id: athanor_id}, memberships) do
    seat =
      Enum.find(memberships, fn
        %{scope: "athanor", status: "active", athanor_id: ^athanor_id} -> true
        _ -> false
      end)

    platform =
      if ctx.platform_admin,
        do: Enum.find(memberships, &(&1.scope == "platform" and &1.status == "active"))

    case seat || platform do
      %{id: id} -> id
      nil -> nil
    end
  end

  @typedoc """
  The generations a person and an estate stand at, read from their rows:
  what an issuance from a context with no binding of its own is checked
  against (`Sanctum.Session.create/2`'s `:generation_snapshot`).
  """
  @type snapshot :: %{
          user_id: String.t(),
          user_generation: pos_integer(),
          athanor_id: String.t() | nil,
          athanor_generation: pos_integer() | nil
        }

  @doc """
  Read the generations `user_id` and `athanor_id` stand at now:
  `{:ok, snapshot}`, `{:error, :not_found}` when either row is absent, or
  `{:error, :unavailable}` when the store cannot answer. A snapshot is
  only a claim — the issuance that consumes it locks and rereads both
  rows and refuses a generation that has since moved.
  """
  @spec generation_snapshot(String.t(), String.t() | nil) ::
          {:ok, snapshot()} | {:error, :not_found | :unavailable}
  def generation_snapshot(user_id, athanor_id) when is_binary(user_id) do
    with {:ok, user} <- snapshot_row(Users.get(user_id)),
         {:ok, athanor_generation} <- athanor_generation(athanor_id) do
      {:ok,
       %{
         user_id: user.id,
         user_generation: user.security_generation,
         athanor_id: athanor_id,
         athanor_generation: athanor_generation
       }}
    end
  end

  defp athanor_generation(nil), do: {:ok, nil}

  defp athanor_generation(athanor_id) when is_binary(athanor_id) do
    with {:ok, athanor} <- snapshot_row(Athanors.get(athanor_id)),
         do: {:ok, athanor.security_generation}
  end

  defp snapshot_row({:ok, row}), do: {:ok, row}
  defp snapshot_row({:error, :not_found}), do: {:error, :not_found}
  defp snapshot_row({:error, _reason}), do: {:error, :unavailable}

  # The candidates in order of preference, then one read for their rows so
  # an archived athanor is skipped: the athanor the context already names
  # (when a membership still grants it, or the caller is a platform admin who
  # opened it deliberately), the person's own, and the first a membership
  # grants.
  defp working_athanor(%Context{} = ctx, memberships, admin?, user) do
    named? = is_binary(ctx.athanor_id) and ctx.athanor_id != ""
    granted? = named? and membership_grants?(memberships, ctx.athanor_id)

    # An operator keeps an athanor no membership grants them — that is how
    # `session.use` and an opened URL stay put across requests. `focus/2`
    # audits the moment they open one; this audits every request that keeps
    # it, so the record covers the session and not just its first act.
    if named? and admin? and not granted? do
      Sanctum.Telemetry.platform_context_event(%{
        caller: :session_athanor,
        user_id: ctx.user_id,
        athanor_id: ctx.athanor_id,
        auth_method: ctx.auth_method
      })
    end

    current = if named? and (admin? or granted?), do: [ctx.athanor_id], else: []

    personal =
      case user do
        %{personal_athanor_id: id} when is_binary(id) -> [id]
        _ -> []
      end

    granted =
      for %{scope: "athanor", status: "active", athanor_id: id} <- memberships,
          is_binary(id),
          do: id

    candidates = Enum.uniq(current ++ personal ++ granted)
    active = candidates |> Athanors.list_by_ids() |> Enum.filter(&(&1.status == "active"))

    Enum.find_value(candidates, fn id -> Enum.find(active, &(&1.id == id)) end)
  end

  defp membership_grants?(memberships, athanor_id) do
    Enum.any?(memberships, fn
      %{scope: "athanor", status: "active", athanor_id: id} -> id == athanor_id
      _ -> false
    end)
  end

  @doc """
  Re-validate a *restored* session context against the user's CURRENT
  standing, returning the corrected context.

  Sessions persist their athanor so the per-request hot path doesn't
  re-resolve, but a change after the session was created MUST take effect
  immediately: a denied user is dropped to unauthenticated, a revoked
  platform membership loses the capability, and a session pointing at an
  athanor the user no longer belongs to (or that was archived) is moved to
  the broadest current membership. A user with no memberships and no own
  athanor is dropped to an athanor-less context (the tenant gate then
  rejects tenant-scoped routes).

  Cost: one `users` read and one `Members.list_by_user/1` query per restored
  request (both indexed). It trades those for immediate revocation instead
  of waiting out the session TTL.

  A store that cannot answer is `{:error, :unavailable}`, never the
  context as it was: every caller is a credential path, and a context kept
  unchanged would outlive a denial or a removal the store could not
  report. The caller answers 503 and the client's own retry asks again.
  """
  @spec revalidate(Context.t()) :: {:ok, Context.t()} | {:error, :unavailable}
  def revalidate(%Context{user_id: user_id} = ctx) when is_binary(user_id) do
    case user_row(user_id) do
      {:ok, %{status: "denied"}} ->
        {:ok, %{ctx | authenticated: false, athanor_id: nil, platform_admin: false}}

      {:ok, user} ->
        case Members.list_by_user(user_id) do
          {:ok, memberships} -> {:ok, ctx |> apply_membership(memberships, user) |> elem(0)}
          {:error, reason} -> unavailable("memberships", user_id, reason)
        end

      {:error, reason} ->
        unavailable("user", user_id, reason)
    end
  end

  def revalidate(%Context{} = ctx), do: {:ok, ctx}

  @doc """
  The context a recovered turn continues under: the person-shaped
  context the sender's sign-in would carry (`auth_method: :oidc`, the
  person's full permission vocabulary), rebuilt from the turn's rows when
  the sender's own context is gone. Unlike `revalidate/1`, it refuses
  instead of degrading: `:denied` when the `users` row is denied or
  missing (read first — a denial marks the user before memberships are
  swept, so a surviving membership proves nothing), `:not_member` when
  the person is not seated in the turn's own athanor, `:archived` when
  the estate is not active, `:unavailable` when the store cannot answer.
  """
  @spec continuation(String.t(), String.t()) ::
          {:ok, Context.t()} | {:error, :denied | :not_member | :archived | :unavailable}
  def continuation(user_id, athanor_id)
      when is_binary(user_id) and user_id != "" and is_binary(athanor_id) and athanor_id != "" do
    case Users.get(user_id) do
      {:ok, %{status: "denied"}} ->
        {:error, :denied}

      {:ok, _user} ->
        cond do
          not Members.member?(user_id, athanor_id) -> {:error, :not_member}
          not Athanors.active?(athanor_id) -> {:error, :archived}
          true -> {:ok, continuation_context(user_id, athanor_id)}
        end

      {:error, :not_found} ->
        {:error, :denied}

      {:error, reason} ->
        Logger.warning(
          "[Sanctum.Tenancy] user read failed while continuing a turn for user=#{user_id}: " <>
            "#{inspect(reason)} — refusing"
        )

        {:error, :unavailable}
    end
  end

  # The one site that builds a person's continuation context.
  defp continuation_context(user_id, athanor_id) do
    Context.build(
      user_id: user_id,
      athanor_id: athanor_id,
      permissions: Sanctum.Atoms.person_permissions(),
      scope: :athanor,
      auth_method: :oidc,
      authenticated: true
    )
  end

  defp unavailable(what, user_id, reason) do
    Logger.warning(
      "[Sanctum.Tenancy] #{what} read failed during revalidation for user=#{user_id}: " <>
        "#{inspect(reason)} — refusing"
    )

    {:error, :unavailable}
  end

  @doc """
  Whether a standing channel (a webhook, an API key, a tincture token) may
  still act: its athanor is active and its creator has not been denied on
  this server.

  Channels are athanor-owned: a creator who merely leaves the group leaves
  the channel running for the members who remain. `created_by` is nil or
  one of the server's synthetic principals (`system`, `_seed`,
  `webhook:<slug>`) for a channel nobody signed in to create — those are
  never denied. Any other id names a person, and that row is read: a
  denied person's channels stop, whether the row carries an id minted
  here (`usr_…`) or the IdP composite a server upgraded in place still
  holds. A minted id with no row is refused — rows are never deleted, so
  such an id was never a person. An id of any other shape with no row (a
  fixture, an imported row) was never a signed-in person here, and the
  channel is the athanor's regardless.

  Every caller is a credential path — a webhook, an API key, a tincture
  token, a schedule about to fire — so a store that cannot answer FAILS
  CLOSED: the firing is refused and the sender's own retry asks again.
  """
  @spec channel_active?(String.t() | nil, String.t() | nil) :: boolean()
  def channel_active?(athanor_id, created_by) do
    athanor_active?(athanor_id) and creator_not_denied?(created_by)
  end

  defp athanor_active?(athanor_id) when is_binary(athanor_id) and athanor_id != "" do
    case Athanors.get(athanor_id) do
      {:ok, %{status: status}} ->
        status == "active"

      {:error, :not_found} ->
        false

      {:error, reason} ->
        Logger.warning(
          "[Sanctum.Tenancy] athanor read failed during channel re-check for " <>
            "athanor=#{athanor_id}: #{inspect(reason)} — refusing this firing"
        )

        false
    end
  end

  defp athanor_active?(_), do: false

  # The server's synthetic principals are never people, so they are never
  # denied. Every other id is read as a person's — the shape of the id
  # decides nothing, or a denied person whose row predates minted ids
  # would keep every channel they created.
  @synthetic_principals ["system", "_seed"]

  defp creator_not_denied?(user_id) when is_binary(user_id) do
    if synthetic_principal?(user_id) do
      true
    else
      case Users.get(user_id) do
        {:ok, %{status: "denied"}} ->
          false

        {:ok, _} ->
          true

        {:error, :not_found} ->
          not Cyfr.PersonId.person?(user_id)

        {:error, reason} ->
          Logger.warning(
            "[Sanctum.Tenancy] creator read failed during channel re-check for " <>
              "user=#{user_id}: #{inspect(reason)} — refusing this firing"
          )

          false
      end
    end
  end

  defp creator_not_denied?(_), do: true

  defp synthetic_principal?(id),
    do: id in @synthetic_principals or String.starts_with?(id, "webhook:")

  @doc """
  Whether this person holds the operator capability — an ACTIVE platform
  membership row.

  Returns false on a failed membership read; capability checks fail closed.
  """
  @spec platform_admin?(String.t() | [map()]) :: boolean()
  def platform_admin?(user_id) when is_binary(user_id) do
    case Members.list_by_user(user_id) do
      {:ok, rows} -> platform_admin?(rows)
      {:error, _} -> false
    end
  end

  def platform_admin?(memberships) when is_list(memberships) do
    Enum.any?(memberships, &(&1.scope == "platform" and &1.status == "active"))
  end
end
