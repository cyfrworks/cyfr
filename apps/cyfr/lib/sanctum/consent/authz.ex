# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.Consent.Authz do
  @moduledoc """
  Who may grant a consent.

  Consent is a third authorization class, belonging to neither the operator
  RBAC plane nor the runtime plane. It cannot be a permission: `:*`
  short-circuits every permission check, so no permission atom can express
  "an admin key may not do this" — and an admin key granting consent
  unattended is exactly what must not happen.

  So the decision is made on *how the caller authenticated*, not on what
  they hold:

  | Caller | May consent |
  |---|---|
  | A Sanctum session (`:oidc`) | yes — Prism web, the CLI, and device-flow-derived sessions all land here |
  | An API key with a capability pinned to this exact commit digest | yes, and only for that one commit |
  | A tincture session upgrade (`:session`) | **no** — this is the public tincture surface, not a console |
  | A tincture token, webhook, cron, system, or unauthenticated caller | no |
  | Anything on the guest plane | no, whatever else it carries |

  Overrides — granting a component more than its author declared — are
  always interactive. A key cannot mint one no matter how tightly caveated,
  because the whole point of an override is that a person looked at it.

  The scoped-key envelope is deliberately the narrowest thing that works:
  one exact commit digest, with an expiry. A general subset lattice over
  needs, tool lists, wildcard domains, paths and limits is a much larger
  design and is not needed to automate a known, previewed grant.
  """

  alias Sanctum.Context

  defmodule Request do
    @moduledoc """
    What is being consented to, from the authorization plane's point of
    view: the exact commit, whether it carries an override, and the key
    capability presented (if any).
    """

    @type capability :: %{
            required(:commit_digest) => String.t(),
            optional(:expires_at) => DateTime.t()
          }

    @type t :: %__MODULE__{
            commit_digest: String.t(),
            override?: boolean(),
            key_capability: capability() | nil
          }

    @enforce_keys [:commit_digest]
    defstruct [:commit_digest, override?: false, key_capability: nil]
  end

  @type granted_via :: :interactive | :scoped_key

  @type refusal ::
          :guest_plane
          | :not_authenticated
          | :anonymous
          | {:surface_not_permitted, atom()}
          | :override_requires_interactive
          | :no_capability
          | :capability_digest_mismatch
          | :capability_expired
          | :invalid_request

  @doc """
  Decide whether this caller may commit this consent.

  `now` is injectable so expiry is testable without sleeping.
  """
  @spec authorize(Context.t(), Request.t(), DateTime.t()) ::
          {:ok, granted_via()} | {:error, refusal()}
  def authorize(ctx, request, now \\ DateTime.utc_now())

  def authorize(%Context{} = ctx, %Request{commit_digest: digest}, _now)
      when not is_binary(digest) or digest == "" do
    _ = ctx
    {:error, :invalid_request}
  end

  def authorize(%Context{} = ctx, %Request{} = request, now) do
    # The plane gate comes first and applies to every arm: a context that
    # has entered a guest closure can never authorize consent, whatever
    # credentials it carries or capability it presents.
    with :ok <- check_plane(ctx),
         :ok <- check_authenticated(ctx) do
      by_auth_method(ctx, request, now)
    end
  end

  def authorize(_ctx, _request, _now), do: {:error, :invalid_request}

  # ============================================================================
  # Private
  # ============================================================================

  defp check_plane(%Context{plane: :guest}), do: {:error, :guest_plane}
  defp check_plane(%Context{}), do: :ok

  defp check_authenticated(%Context{authenticated: false}), do: {:error, :not_authenticated}
  defp check_authenticated(%Context{anonymous: true}), do: {:error, :anonymous}
  defp check_authenticated(%Context{}), do: :ok

  # A Sanctum session. Note this is deliberately the *loaded session*
  # provenance, so a CLI that device-flowed into a session consents like the
  # console does — same class of act, same authorization.
  defp by_auth_method(%Context{auth_method: :oidc}, _request, _now), do: {:ok, :interactive}

  defp by_auth_method(%Context{auth_method: :api_key}, request, now) do
    if request.override? do
      {:error, :override_requires_interactive}
    else
      check_capability(request, now)
    end
  end

  # Everything else is a surface that must not be able to consent — most
  # sharply `:session`, which is produced only by the tincture upgrade path
  # and would otherwise let a public tincture surface grant authority.
  defp by_auth_method(%Context{auth_method: method}, _request, _now) do
    {:error, {:surface_not_permitted, method}}
  end

  defp check_capability(%Request{key_capability: nil}, _now), do: {:error, :no_capability}

  defp check_capability(%Request{key_capability: capability} = request, now)
       when is_map(capability) do
    cond do
      not exact_digest?(capability, request.commit_digest) ->
        {:error, :capability_digest_mismatch}

      expired?(capability, now) ->
        {:error, :capability_expired}

      true ->
        {:ok, :scoped_key}
    end
  end

  defp check_capability(_request, _now), do: {:error, :no_capability}

  # Pinned to one exact commit, never a prefix or a pattern: the envelope is
  # "this grant, already previewed", not "grants like this one".
  defp exact_digest?(capability, commit_digest) do
    case Map.get(capability, :commit_digest) do
      value when is_binary(value) and value != "" ->
        Plug.Crypto.secure_compare(value, commit_digest)

      _ ->
        false
    end
  end

  defp expired?(capability, now) do
    case Map.get(capability, :expires_at) do
      nil -> false
      %DateTime{} = expires_at -> DateTime.compare(now, expires_at) != :lt
      _ -> true
    end
  end
end
