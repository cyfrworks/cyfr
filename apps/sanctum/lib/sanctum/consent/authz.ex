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
  | A paired device (`:device`), naming its paired client | yes — the person's own interactive client, on its device channel |
  | An API key with a capability pinned to this exact commit digest | yes, and only for that one commit |
  | A tincture session upgrade (`:session`) | **no** — this is the public tincture surface, not a console |
  | A tincture token, webhook, cron, system, or unauthenticated caller | no |
  | Anything on the guest plane | no, whatever else it carries |

  A paired client is only the device channel's: a `:device` context names
  its client (`client_id`), and a context of any other surface names
  none, so one that claims a paired client without being the channel's,
  or the channel's surface without its client, is no surface that may
  consent. The same rule holds for the interactive and staging arms
  below.

  Whichever arm admits the caller, its standing is read again as the
  grant is decided: a session must still exist, be unexpired and be its
  person's, the person not denied and the focused athanor open
  (`Sanctum.Caller.revalidate_session/1`); a key must still be unrevoked,
  its athanor's and its creator's; a paired device's certificate must be
  unexpired, its paired client active and its person still seated in the
  athanor, which revalidation reads as it does a session's. A grant needs
  the session alone, never a fresh confirmation.

  ## Sensitive changes

  `confirm/3`, `check/3` and `consume/2` are where a sensitive change is
  decided (`Sanctum.Pairing`'s action table): each deciding site passes
  the action it confirms and the request, the operation (`tool.action`)
  and its exact arguments, with the affected resource by name and any
  public facts for the preview. Nothing a client holds satisfies one; the
  proof is a pending confirmation, consumed once. Until a proof can be
  given, `Sanctum.Pairing.fresh_required?/2` answers `false` for every
  action, and each answers `:ok` for a known action and a well-formed
  change, adding no refusal to the site's own checks — every change
  behaves as it did.

  Overrides — granting a component more than its author declared — are
  always interactive. A key cannot mint one no matter how tightly caveated,
  because the whole point of an override is that a person looked at it.

  The scoped-key envelope is deliberately the narrowest thing that works:
  one exact commit digest, with an expiry. A general subset lattice over
  needs, tool lists, wildcard domains, paths and limits is a much larger
  design and is not needed to automate a known, previewed grant.
  """

  alias Sanctum.Context

  require Logger

  defmodule Request do
    @moduledoc """
    What is being consented to, from the authorization plane's point of
    view: the exact commit, whether it carries an override, and the key
    capability presented (if any).
    """

    @type capability :: %{
            required(:commit_digest) => String.t(),
            required(:expires_at) => DateTime.t()
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

  @typedoc """
  What a sensitive change is: the operation as `tool.action`, its exact
  arguments, and, for the preview, the affected resource by name and any
  public facts (never a secret argument's value).
  """
  @type change :: %{
          required(:operation) => String.t(),
          required(:arguments) => map(),
          optional(:resource) => String.t(),
          optional(:details) => %{optional(String.t()) => String.t() | [String.t()]}
        }

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
          | :not_standing
          | :unavailable

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
         :ok <- check_authenticated(ctx),
         {:ok, granted_via} <- by_auth_method(ctx, request, now),
         :ok <- standing(ctx) do
      {:ok, granted_via}
    end
  end

  def authorize(_ctx, _request, _now), do: {:error, :invalid_request}

  @doc """
  Decide the sensitive change `change` (`t:change/0`), which confirms
  `action` (`Sanctum.Pairing.actions/0`), under `ctx`, where its effect is
  one call.

  `:ok` when the action needs no fresh confirmation. A change that needs
  one is decided only by consuming the confirmation `ctx.confirmation_id`
  names; otherwise one is opened and the answer is the consent signal
  `{:error, {:confirmation_required, %{id, operation, expires_at}}}`.
  Until a proof can be given no action needs one
  (`Sanctum.Pairing.fresh_required?/2`), and the answer is `:ok` for an
  action of the table and a well-formed change, `{:error,
  :invalid_request}` otherwise: the site's own checks of who may act
  decide, as they did.
  """
  @spec confirm(Context.t(), Sanctum.Pairing.action(), change()) ::
          :ok | {:error, refusal() | {:confirmation_required, map()}}
  def confirm(%Context{} = ctx, action, change), do: decide(ctx, action, change)

  @doc """
  What `confirm/3` would answer for `change`, consuming nothing: for a
  site whose effect opens a row, which asks first and consumes in the
  transaction that opens it (`consume/2`).
  """
  @spec check(Context.t(), Sanctum.Pairing.action(), change()) ::
          :ok | {:error, refusal() | {:confirmation_required, map()}}
  def check(%Context{} = ctx, action, change), do: decide(ctx, action, change)

  @doc """
  Consume the confirmation `change` needs, `{action, change}` as
  `confirm/3` takes them, inside the caller's transaction: the one that
  opens the row the change's effect writes, so the two commit or roll back
  together. Answers as `confirm/3`.
  """
  @spec consume(Context.t(), {Sanctum.Pairing.action(), change()}) ::
          :ok | {:error, refusal() | {:confirmation_required, map()}}
  def consume(%Context{} = ctx, {action, change}), do: decide(ctx, action, change)

  @doc """
  The staging gate for plan and preview: authenticated, external-plane,
  and a surface that could ever finish the walk (`:oidc` or a paired
  `:device` interactively, `:api_key` through a digest-pinned
  capability). Staging grants nothing — the commit is where the consent
  class bites — but candidate listings are operator data, so anonymous
  and in-chain surfaces never see them.
  """
  @spec authorize_staging(Context.t()) :: :ok | {:error, refusal()}
  def authorize_staging(%Context{} = ctx) do
    with :ok <- check_plane(ctx),
         :ok <- check_authenticated(ctx),
         {:ok, method} <- surface(ctx) do
      if method in [:oidc, :device, :api_key],
        do: :ok,
        else: {:error, {:surface_not_permitted, method}}
    end
  end

  @doc """
  The interactive arm alone, for mutations that have no commit digest to
  bind — vault CRUD, profile revocation. Same plane and authentication
  gates; only an `:oidc` session or a paired `:device` passes, and no key
  capability can substitute (a digest-pinned capability is meaningless
  without a digest-shaped act). A paired device's standing is read on
  its channel, on every request, before the gate is asked
  (`Sanctum.DeviceCerts.verify_request/3`).
  """
  @spec authorize_interactive(Context.t()) :: {:ok, :interactive} | {:error, refusal()}
  def authorize_interactive(%Context{} = ctx) do
    with :ok <- check_plane(ctx),
         :ok <- check_authenticated(ctx),
         {:ok, method} <- surface(ctx) do
      if method in [:oidc, :device],
        do: {:ok, :interactive},
        else: {:error, {:surface_not_permitted, method}}
    end
  end

  @doc """
  The interactive arm for a call already inside a running chain.

  Every in-chain call runs guest-planed, so the plane conjunct of
  `authorize_interactive/1` is dropped here for all of them — not only for
  an approved card. What stands in for it is the chain's own gate: the
  authority's tool grant, minted from the caps a person consented to, was
  applied at the dispatch chokepoint before this runs. An action the
  agent's policy holds at `ask` reaches here through the card the person
  clicked; one held at `auto` reaches here on the strength of that consent
  alone. The surface half stays — only an `:oidc` session's chain gets
  through, so a key- or schedule-started run of the same formula is
  refused here exactly as it is at the door.
  """
  @spec authorize_interactive_in_chain(Context.t()) :: {:ok, :interactive} | {:error, refusal()}
  def authorize_interactive_in_chain(%Context{} = ctx) do
    with :ok <- check_authenticated(ctx) do
      case ctx.auth_method do
        :oidc -> {:ok, :interactive}
        method -> {:error, {:surface_not_permitted, method}}
      end
    end
  end

  @doc """
  Render a refusal as the sentence the caller reads — the ONE spelling of
  this vocabulary's prose. Every surface that answers a consent refusal
  (`Sanctum.Providers.Profile`, the MCP dispatch gate via
  `Sanctum.Unauthorized`) renders through here, so the phrasing cannot
  fork per surface.
  """
  @spec message(refusal() | term()) :: String.t()
  def message({:surface_not_permitted, method}),
    do: "Consent needs an interactive sign-in; this surface (#{method}) cannot consent"

  def message(:guest_plane), do: "A call from inside a running component cannot consent"
  def message(:not_authenticated), do: "Consent requires authentication"
  def message(:anonymous), do: "An anonymous caller cannot consent"

  def message(:no_capability),
    do: "This key carries no consent capability"

  def message(:capability_digest_mismatch),
    do: "The key's consent capability pins a different commit digest"

  def message(:capability_expired), do: "The key's consent capability has expired"

  def message(:override_requires_interactive),
    do: "A consent override needs an interactive sign-in"

  def message(:invalid_request), do: "The consent request is not valid"

  def message(:not_standing),
    do: "Your sign-in or key no longer stands here; sign in again to decide this"

  def message(:unavailable), do: "Your standing could not be checked; try again"

  # This IS the vocabulary module — an unknown term here is a producer bug,
  # logged and generalized, never inspected onto the wire (the catch-all
  # `inspect/1` undid the closed union above).
  def message(other) do
    Logger.warning("[Sanctum.Consent.Authz] unrenderable consent refusal: #{inspect(other)}")
    "The consent request is not valid"
  end

  # ============================================================================
  # Private
  # ============================================================================

  # The first form of a sensitive change's decision: an action of the
  # table and a well-formed change, and nothing the deciding site did not
  # already decide — its own checks of who may act stand, as they did. No
  # action needs a fresh confirmation until a proof can be given, so none
  # is opened or consumed here; a table that asked for one before this
  # could consume it would be a programmer error, and raises rather than
  # deciding the change.
  defp decide(ctx, action, change) do
    with :ok <- known_action(action),
         :ok <- change(change) do
      false = Sanctum.Pairing.fresh_required?(action, ctx)
      :ok
    end
  end

  defp known_action(action) do
    if action in Sanctum.Pairing.actions(), do: :ok, else: {:error, :invalid_request}
  end

  defp change(%{operation: operation, arguments: arguments} = change)
       when is_binary(operation) and is_map(arguments) do
    if Prima.Manifest.Tincture.operation_name?(operation) and
         Map.keys(change) -- [:operation, :arguments, :resource, :details] == [],
       do: :ok,
       else: {:error, :invalid_request}
  end

  defp change(_change), do: {:error, :invalid_request}

  # The caller's standing, read again as the grant is decided: whatever
  # credential admitted it must still stand, under the standing lock order
  # (`Sanctum.Caller.revalidate_session/1`), a paired device's client and
  # its person's seat among them. A context no stored credential backs
  # keeps its establishment contract.
  defp standing(ctx) do
    case Sanctum.Caller.revalidate_session(ctx) do
      {:ok, _current} -> :ok
      {:error, :unauthenticated} -> {:error, :not_authenticated}
      {:error, reason} when reason in [:not_standing, :not_member] -> {:error, :not_standing}
      {:error, :unavailable} -> {:error, :unavailable}
    end
  end

  # The surface a context authenticated through. A paired client is the
  # device channel's alone: a `:device` context names its client, and no
  # other context names one, so a context that claims either without the
  # other is refused as the surface it claims.
  defp surface(%Context{auth_method: :device, client_id: client_id}) when is_binary(client_id),
    do: {:ok, :device}

  defp surface(%Context{auth_method: method, client_id: nil}) when method != :device,
    do: {:ok, method}

  defp surface(%Context{auth_method: method}), do: {:error, {:surface_not_permitted, method}}

  defp check_plane(%Context{plane: :guest}), do: {:error, :guest_plane}
  defp check_plane(%Context{}), do: :ok

  defp check_authenticated(%Context{authenticated: false}), do: {:error, :not_authenticated}
  defp check_authenticated(%Context{anonymous: true}), do: {:error, :anonymous}
  defp check_authenticated(%Context{}), do: :ok

  defp by_auth_method(ctx, request, now) do
    with {:ok, method} <- surface(ctx), do: by_surface(method, request, now)
  end

  # A Sanctum session. Note this is deliberately the *loaded session*
  # provenance, so a CLI that device-flowed into a session consents like the
  # console does — same class of act, same authorization. A paired device
  # is the person's own interactive client, and grants what their session
  # grants.
  defp by_surface(method, _request, _now) when method in [:oidc, :device],
    do: {:ok, :interactive}

  defp by_surface(:api_key, request, now) do
    if request.override? do
      {:error, :override_requires_interactive}
    else
      check_capability(request, now)
    end
  end

  # Everything else is a surface that must not be able to consent — most
  # sharply `:session`, which is produced only by the tincture upgrade path
  # and would otherwise let a public tincture surface grant authority.
  defp by_surface(method, _request, _now), do: {:error, {:surface_not_permitted, method}}

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

  # An expiry is part of the envelope, not an option: the moduledoc
  # promises "one exact commit digest, with an expiry", so a capability
  # without one (or with a malformed one) is refused, never eternal.
  defp expired?(capability, now) do
    case Map.get(capability, :expires_at) do
      %DateTime{} = expires_at -> DateTime.compare(now, expires_at) != :lt
      _ -> true
    end
  end
end
