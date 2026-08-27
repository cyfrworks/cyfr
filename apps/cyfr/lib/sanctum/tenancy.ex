# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Tenancy do
  @moduledoc """
  Tenant resolution from memberships.

  `resolve_into/2` is the single chokepoint every auth path flows through to
  attach the caller's athanor and capabilities to their Context. It reads
  the user's membership rows: an athanor row grants that athanor; a platform
  row makes the caller a platform admin (`platform_admin: true`), which is a
  capability the context carries, never a wider scope — every request works
  inside one athanor.

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
  `athanor_id` (the per-request safety-net usage in plugs: the stored value
  was resolved at session-create time and re-querying every request is
  wasteful). Auth paths that produce a Context *before* membership has been
  resolved — `Sanctum.Auth.OAuth`, `Sanctum.Auth.DeviceFlow`,
  `Sanctum.Auth.OIDC` — pass `force: true`.

  The athanor chosen is, in order: the one the context already names when a
  membership still grants it, the person's own athanor, the first athanor
  a membership grants, and for a platform admin with none of those, Home.
  Resolution failure logs and returns the context unchanged — a context with
  no resolved athanor is rejected downstream by the tenant gate
  (`Sanctum.Context.tenant_ok/1`).
  """
  @spec resolve_into(Context.t(), keyword()) :: Context.t()
  def resolve_into(ctx, opts \\ [])

  def resolve_into(%Context{athanor_id: athanor_id} = ctx, opts)
      when is_binary(athanor_id) and athanor_id != "" do
    if Keyword.get(opts, :force, false), do: do_resolve(ctx), else: ctx
  end

  def resolve_into(%Context{} = ctx, _opts), do: do_resolve(ctx)

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
              %{ctx | athanor_id: athanor_id, scope: :athanor}

            :no_membership ->
              ctx

            {:error, reason} ->
              Logger.error(
                "[Sanctum.Tenancy] resolve override failed for #{ctx.user_id}: #{inspect(reason)}"
              )

              ctx
          end
      end
    end
  else
    defp do_resolve(%Context{} = ctx), do: resolve_from_memberships(ctx)
  end

  defp resolve_from_memberships(%Context{user_id: user_id} = ctx) do
    with {:ok, user} <- user_row(user_id),
         {:ok, memberships} <- Members.list_by_user(user_id) do
      apply_membership(ctx, memberships, user)
    else
      {:error, reason} ->
        Logger.error("[Sanctum.Tenancy] resolve failed for #{user_id}: #{inspect(reason)}")
        ctx
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

  Failing safe: on a transient read error the context is returned unchanged
  rather than locking the user out or silently re-resolving.
  """
  @spec revalidate(Context.t()) :: Context.t()
  def revalidate(%Context{user_id: user_id} = ctx) when is_binary(user_id) do
    case user_row(user_id) do
      {:ok, %{status: "denied"}} ->
        %{ctx | authenticated: false, athanor_id: nil, platform_admin: false}

      {:ok, user} ->
        case Members.list_by_user(user_id) do
          {:ok, memberships} -> apply_membership(ctx, memberships, user)
          {:error, _} -> ctx
        end

      {:error, _} ->
        ctx
    end
  end

  def revalidate(%Context{} = ctx), do: ctx

  @doc """
  Whether a standing channel (a webhook, a cron schedule, an API key) may
  still fire: its athanor is active and its creator has not been denied on
  this server.

  Channels are athanor-owned: a creator who merely leaves the group leaves
  the channel running for the members who remain. `created_by` may be nil or
  a synthetic principal (`webhook:<slug>`, `_seed`, `system`) — those are
  never denied. On a transient read error the check fails safe (active),
  matching `revalidate/1`'s posture — a DB blip must not silently kill every
  schedule; the read is retried on the next firing.
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
            "athanor=#{athanor_id}: #{inspect(reason)} — allowing this firing"
        )

        true
    end
  end

  defp athanor_active?(_), do: false

  defp creator_not_denied?(user_id) when is_binary(user_id) and user_id != "" do
    case Users.get(user_id) do
      {:ok, %{status: "denied"}} -> false
      _ -> true
    end
  end

  defp creator_not_denied?(_), do: true

  defp platform_admin?(memberships) do
    Enum.any?(memberships, &(&1.scope == "platform" and &1.status == "active"))
  end
end
