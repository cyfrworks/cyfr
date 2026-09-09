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
  `config :cyfr, :tenancy_resolver_override, MyResolver` — the override's
  `resolve/1` runs instead. This is honored only when the compile-time flag
  `config :cyfr, :allow_tenancy_resolver_override, true` is set (test/dev);
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
  membership still grants it, the person's own athanor, the first athanor
  a membership grants, and for a platform admin with none of those, Home.

  A membership read that FAILED is `{:error, :unavailable}`, distinct from
  a person who genuinely belongs to no athanor (`{:ok, ctx}` with no
  athanor, which the tenant gate refuses): a database blip must never read
  as "you belong nowhere, contact your administrator" — a permanent-
  sounding answer to a transient fault no operator can see.
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
  @spec list_athanors(Context.t()) :: [Arca.Schemas.Athanor.t()]
  def list_athanors(%Context{user_id: user_id}) when is_binary(user_id) do
    Athanors.list_for_user(user_id)
  end

  def list_athanors(_), do: []

  # The membership-resolution override is a test-only seam. `do_resolve/1` is
  # defined in two compile-time variants: a production release — compiled with
  # prod config, where the flag is false — gets the plain membership path with
  # NO override code at all, so the override can never bypass membership
  # resolution regardless of how `:cyfr` app env is set at runtime.
  if Application.compile_env(:cyfr, :allow_tenancy_resolver_override, false) do
    defp do_resolve(%Context{} = ctx) do
      case Application.get_env(:cyfr, :tenancy_resolver_override) do
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
      {:ok, apply_membership(ctx, memberships, user)}
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

  # Set capability and athanor from an already-loaded membership list.
  defp apply_membership(%Context{} = ctx, memberships, user) do
    admin? = platform_admin?(memberships)

    %{
      ctx
      | scope: :athanor,
        platform_admin: admin?,
        athanor_id: working_athanor(ctx, memberships, admin?, user)
    }
  end

  # The candidates in order of preference, then one read for their rows so
  # an archived athanor is skipped: the athanor the context already names
  # (when a membership still grants it, or the caller is a platform admin who
  # opened it deliberately), the person's own, the first membership grants,
  # and — for a platform admin with none of those — Home.
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

    case Enum.find(candidates, fn id -> Enum.any?(active, &(&1.id == id)) end) do
      nil -> if admin?, do: home_id(), else: nil
      id -> id
    end
  end

  # A missing Home is an install defect; a request must not 500 on it.
  defp home_id do
    case Athanors.home() do
      {:ok, home} -> home.id
      _ -> nil
    end
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
          {:ok, memberships} -> {:ok, apply_membership(ctx, memberships, user)}
          {:error, reason} -> unavailable("memberships", user_id, reason)
        end

      {:error, reason} ->
        unavailable("user", user_id, reason)
    end
  end

  def revalidate(%Context{} = ctx), do: {:ok, ctx}

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
          not Arca.Schemas.User.person_id?(user_id)

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

  The one derivation: callers used to re-spell it (dropping the status
  check, which only held because `Members.list_by_user/1` happens to
  filter active) and each copy could silently widen the moment that query
  changed. A failed read answers `false` — a capability check fails
  closed.
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
