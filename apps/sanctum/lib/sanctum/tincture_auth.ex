# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.TinctureAuth do
  @moduledoc """
  Unified tincture authentication.

  Resolves credentials and delegates to existing Sanctum infrastructure (API
  keys, Sanctum session tokens).

  Auth priority (header- and token-preferred so live credentials do not travel
  in URL query strings / access logs):

  1. `Authorization: Bearer …` header — an API key or a session token, told
     apart by the `cyfr_` prefix. The only way to present an account credential.
  2. `?_t=` — short-lived, single-purpose tincture access token

  **An account credential is never accepted from a query string.** An iframe or
  `<img>` cannot send headers, so those URLs carry a `?_t=` token instead,
  and a private tincture's own assets a `/_s/` token in their path. A URL
  ends up in browser history, `Referer` and every intermediary's logs, so
  what goes there has to be worth leaking.

  ## Derived tokens

  Both tokens are narrowed derivatives of one stored session or API key,
  never credentials of their own. This module owns both codecs, under
  distinct salts, and each carries exactly the payload version 1 fields:
  `v`, `purpose` (`"access"` or `"asset"`), `user_id`, `athanor_id`,
  `publisher`, `tincture_name`, `user_generation`, `athanor_generation`,
  `source_kind` (`"session"` or `"api_key"`), `source_id` (the session's
  base64url token hash, or the key's row id — lookup identifiers, never
  bearer credentials), `focus_basis` (the membership row id that
  authorized the focus, or `"key"`) and an absolute Unix-second
  `expires_at`.

  Minting and every use hold the token to the rows it names as they are
  now (`Sanctum.Caller.derived_standing/2`): a source logged out, deleted,
  expired, revoked or rotated, a person denied and allowed again, an
  athanor archived and reopened, or the membership a session's focus rested
  on removed — rejoining is a new row — refuses it for good. A key's focus
  is the key, so its creator leaving the athanor does not end it. A store
  that cannot answer is `{:error, :unavailable}`: nothing is minted and
  nothing served.

  A token expires at the earliest of one hour, its source's finite expiry
  and any parent token's deadline. An access token cannot mint another
  access token; an asset token is minted from a primary source or an
  access token's context and cannot outlive either; nothing mints from an
  asset token. A key with no person behind it mints nothing.

  ## The frame protocol's two credentials

  A private tincture version's files are served under an **asset
  credential** in the path (`/_s/<credential>/…`, `Prima.TinctureUrl`):
  signed, opaque and URL-safe, carrying no secret, stable for one person,
  one version digest and one window under one source, and held to that
  source's rows at every fetch (`mint_asset_credential/3`,
  `verify_asset_credential/2`). The window is the platform setting
  `asset_credential_window_s`, capped by the source's remaining life.

  A frame the shell opens holds a **frame credential**: a bearer naming
  one row of `Arca.FrameCredentials`, which is its standing on every
  member, bound to the person, the version digest, the grant revision and
  the frame id, with a deadline of its own (`frame_credential_deadline_s`,
  capped the same way). The shell suspends, resumes and revokes it here;
  a standing transition revokes it in its own transaction
  (`Arca.SecurityTransitions`); every use reads the row and the standing
  again (`mint_frame_credential/4`, `verify_frame_credential/2`,
  `suspend_frame/2`, `resume_frame/2`, `revoke_frame/2`).

  ## Returns

  - `{:ok, %Sanctum.Context{}}` — Authenticated context
  - `:unauthenticated` — no credential was presented at all
  - `{:error, refusal}` — a credential was presented and is dead or
    refused; the surface renders the named refusal instead of silently
    serving the anonymous fallback
  """

  alias Sanctum.Context

  @typedoc """
  Why a *presented* credential was refused. Distinct from the bare
  `:unauthenticated` answer (nothing presented), so a caller holding a
  dead credential learns so; `{:error, :unauthenticated}` is a token
  whose source no longer stands.
  """
  @type refusal ::
          :invalid_credential
          | :expired_token
          | :denied
          | :unauthenticated
          | :no_athanor
          | :wrong_tincture
          | :ip_not_allowed
          | :unavailable

  @typedoc """
  What a verified asset credential opens: the person, the athanor, the
  version digest, the source binding, its expiry and the seconds it has
  left.
  """
  @type asset_authority :: %{
          user_id: String.t(),
          athanor_id: String.t(),
          version_digest: String.t(),
          credential_binding: Context.credential_binding(),
          expires_at: DateTime.t(),
          remaining_s: pos_integer()
        }

  @typedoc """
  What a verified frame credential opens: its row's id, the frame id, the
  person, the athanor, the version digest, the grant revision, the
  deadline and the source binding.
  """
  @type frame_authority :: %{
          id: String.t(),
          frame_id: String.t(),
          user_id: String.t(),
          athanor_id: String.t(),
          version_digest: String.t(),
          grant_revision: non_neg_integer(),
          deadline: DateTime.t(),
          credential_binding: Context.credential_binding()
        }

  @typedoc "A frame credential's row, as `Arca.FrameCredentials` answers it."
  @type frame_row :: Arca.FrameCredentials.row()

  @typedoc "Why a derived token could not be minted."
  @type mint_refusal ::
          :not_owner
          | :not_primary
          | :missing_generation
          | :not_standing
          | :not_member
          | :ip_not_allowed
          | :expired_credential
          | :unavailable

  # Bumped from the unscoped and the person-only payloads: no token minted
  # under an earlier salt verifies, and there is no fallback to one.
  @access_salt "tincture_access_v5"
  @asset_salt "tincture_asset_v3"
  # The two credentials of the frame protocol, each under its own salt, so
  # neither verifies as the other or as either `?_t=`-era token.
  @asset_credential_salt "tincture_asset_credential_v1"
  @frame_credential_salt "tincture_frame_credential_v1"
  @max_age 3600
  @version 1

  @payload_keys [
    :v,
    :purpose,
    :user_id,
    :athanor_id,
    :publisher,
    :tincture_name,
    :user_generation,
    :athanor_generation,
    :source_kind,
    :source_id,
    :focus_basis,
    :expires_at
  ]

  @doc """
  The key both tincture tokens are signed with.

  From config, not from the web endpoint's module: the auth domain must not
  reach into the web layer for key material. In every deployed env this is
  the same secret the endpoint signs with (runtime.exs and dev.exs set both
  from one value), read through the domain's own key.
  """
  @spec signing_secret() :: binary()
  def signing_secret, do: Application.fetch_env!(:sanctum, :secret_key_base)

  @doc """
  Mint an access token for ONE tincture from a primary credential's
  context — a session's or a key's, as `Sanctum.Caller` established it.

  The rows the context's binding names are locked and reread first; the
  token expires at the earliest of one hour and the source's own expiry.
  It opens only `:execute` on `publisher`/`tincture_name`, is useless for
  the MCP API, and cannot mint another token. Refused on a member that
  does not hold the control plane (`:not_owner`), for an access-token
  context (`:not_primary`), a context with no source binding
  (`:missing_generation`), a source that no longer stands, and when the
  store cannot answer (`:unavailable`).
  """
  @spec issue_access_token(Context.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, mint_refusal()}
  def issue_access_token(%Context{} = ctx, publisher, tincture_name)
      when is_binary(publisher) and is_binary(tincture_name) do
    with :ok <- owner(),
         :ok <- primary(ctx),
         {:ok, claims} <- claims(ctx),
         {:ok, expires_at} <- deadline(claims, ctx, nil) do
      {:ok, sign(@access_salt, "access", claims, publisher, tincture_name, expires_at)}
    end
  end

  @doc """
  Mint an asset token — the `/_s/` path prefix a private tincture's own
  assets are fetched under — from a primary credential's context, or from
  the context an access token established, whose deadline it cannot
  outlive. Checked and refused exactly as `issue_access_token/3`; an
  asset token's own context is never an issuer.
  """
  @spec issue_asset_token(Context.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, mint_refusal()}
  def issue_asset_token(%Context{} = ctx, publisher, tincture_name)
      when is_binary(publisher) and is_binary(tincture_name) do
    with :ok <- owner(),
         :ok <- lineage(ctx),
         {:ok, claims} <- claims(ctx),
         {:ok, expires_at} <- deadline(claims, ctx, ctx.credential_deadline) do
      {:ok, sign(@asset_salt, "asset", claims, publisher, tincture_name, expires_at)}
    end
  end

  @doc """
  The seconds an access token has left, read from its signed deadline —
  what the mint endpoint reports as `expires_in`.
  """
  @spec expires_in(String.t()) :: {:ok, non_neg_integer()} | {:error, atom()}
  def expires_in(token) when is_binary(token) do
    with {:ok, claims} <- verify_access_token(token) do
      {:ok, max(DateTime.diff(claims.expires_at, DateTime.utc_now()), 0)}
    end
  end

  @doc """
  What a `?_t=` token says, once its signature, version, purpose and
  deadline check out — the envelope alone. The one place the token is
  decoded; `Sanctum.Caller` holds the credential it names to its rows
  before a context is built.
  """
  @spec verify_access_token(String.t()) ::
          {:ok, map()} | {:error, :expired_credential | :invalid_credential}
  def verify_access_token(token) when is_binary(token),
    do: envelope(token, @access_salt, "access")

  @doc """
  Verify a `/_s/` asset token against the request it arrived on: `ctx` is
  the context already resolved for the URL's athanor (with the client's
  address), and `publisher`/`tincture_name` the URL's. The envelope must
  be an asset token for exactly that athanor and tincture, and the
  credential it names must still stand (`Sanctum.Caller.derived_standing/2`).

  Answers `ctx` narrowed — carrying the token's binding and deadline —
  and builds no context of its own; or `:expired_credential`,
  `:invalid_credential` (any other token, including an access token),
  `:not_member`, `:not_standing`, `:ip_not_allowed` or `:unavailable`.
  """
  @spec verify_asset_token(String.t(), Context.t(), String.t(), String.t()) ::
          {:ok, Context.t()} | {:error, atom()}
  def verify_asset_token(token, %Context{} = ctx, publisher, tincture_name)
      when is_binary(token) and is_binary(publisher) and is_binary(tincture_name) do
    with {:ok, claims} <- envelope(token, @asset_salt, "asset"),
         :ok <- names(claims, ctx.athanor_id, publisher, tincture_name),
         {:ok, _standing} <- Sanctum.Caller.derived_standing(claims, client_ip: ctx.client_ip) do
      {:ok,
       %{ctx | credential_binding: claims_binding(claims), credential_deadline: claims.expires_at}}
    end
  end

  @doc false
  # The binding a derived token's claims name, in the context's shape.
  @spec claims_binding(map()) :: Context.credential_binding()
  def claims_binding(claims) do
    %{
      source_kind: claims.source_kind,
      source_id: claims.source_id,
      focus_basis: claims.focus_basis,
      user_generation: claims.user_generation,
      athanor_generation: claims.athanor_generation
    }
  end

  # ---- minting ---------------------------------------------------------------

  # A member that does not hold the control plane dispenses nothing.
  defp owner, do: if(Arca.ControlPlane.held?(), do: :ok, else: {:error, :not_owner})

  # A person's session or an athanor's key, as established — never a
  # derived token's context.
  defp primary(%Context{authenticated: true, anonymous: false, auth_method: method})
       when method in [:oidc, :session, :api_key],
       do: :ok

  defp primary(%Context{}), do: {:error, :not_primary}

  # Or the context an access token established, which carries the
  # token's deadline as its own.
  defp lineage(%Context{auth_method: :tincture, credential_deadline: %DateTime{}} = ctx),
    do: if(ctx.authenticated, do: :ok, else: {:error, :not_primary})

  defp lineage(%Context{} = ctx), do: primary(ctx)

  # The binding the mint is held to. An access token's context carries the
  # binding its verified envelope named; a primary context's binding must
  # agree with the credential field its one assembly path stamped beside it
  # (`Sanctum.Session`, `Sanctum.ApiKey`) — a session's row key encoding to
  # the source id, a key's id equal to it — so a context whose method was
  # changed cannot pass a derived binding off as a primary one.
  defp claims(%Context{auth_method: :tincture} = ctx), do: bound_claims(ctx)

  defp claims(
         %Context{
           session_token_hash: hash,
           credential_binding: %{source_kind: :session, source_id: source_id}
         } = ctx
       )
       when is_binary(hash) and is_binary(source_id) do
    if Base.url_encode64(hash, padding: false) == source_id,
      do: bound_claims(ctx),
      else: {:error, :missing_generation}
  end

  defp claims(
         %Context{api_key_id: id, credential_binding: %{source_kind: :api_key, source_id: id}} =
           ctx
       )
       when is_binary(id),
       do: bound_claims(ctx)

  defp claims(%Context{}), do: {:error, :missing_generation}

  defp bound_claims(%Context{
         user_id: user_id,
         athanor_id: athanor_id,
         credential_binding: %{source_kind: kind, source_id: source_id, focus_basis: basis} = b
       })
       when is_binary(user_id) and is_binary(athanor_id) and kind in [:session, :api_key] and
              is_binary(source_id) and (is_binary(basis) or basis == :key) and
              is_integer(b.athanor_generation) do
    {:ok,
     %{
       user_id: user_id,
       athanor_id: athanor_id,
       user_generation: b.user_generation,
       athanor_generation: b.athanor_generation,
       source_kind: kind,
       source_id: source_id,
       focus_basis: basis
     }}
  end

  defp bound_claims(%Context{}), do: {:error, :missing_generation}

  # The earliest of an hour from now (the database's now, read after the
  # locks), the source's own expiry and the parent's deadline.
  defp deadline(claims, %Context{client_ip: client_ip}, parent) do
    with {:ok, %{now: now, source_expires_at: source}} <-
           Sanctum.Caller.derived_standing(claims, client_ip: client_ip) do
      deadline =
        [DateTime.add(now, @max_age, :second), source, parent]
        |> Enum.reject(&is_nil/1)
        |> Enum.min(DateTime)

      if DateTime.compare(deadline, now) == :gt,
        do: {:ok, deadline},
        else: {:error, :expired_credential}
    end
  end

  defp sign(salt, purpose, claims, publisher, tincture_name, %DateTime{} = expires_at) do
    Phoenix.Token.sign(signing_secret(), salt, %{
      v: @version,
      purpose: purpose,
      user_id: claims.user_id,
      athanor_id: claims.athanor_id,
      publisher: publisher,
      tincture_name: tincture_name,
      user_generation: claims.user_generation,
      athanor_generation: claims.athanor_generation,
      source_kind: Atom.to_string(claims.source_kind),
      source_id: claims.source_id,
      focus_basis: if(claims.focus_basis == :key, do: "key", else: claims.focus_basis),
      # Floored to the second, so the signed deadline never outlives the
      # one it was derived from.
      expires_at: DateTime.to_unix(expires_at)
    })
  end

  # ---- the envelope ----------------------------------------------------------

  defp envelope(token, salt, purpose) do
    case Phoenix.Token.verify(signing_secret(), salt, token, max_age: @max_age) do
      {:ok, %{v: @version, purpose: ^purpose} = payload} -> decoded(payload)
      {:error, :expired} -> {:error, :expired_credential}
      _ -> {:error, :invalid_credential}
    end
  end

  defp decoded(payload) do
    with true <- Enum.sort(Map.keys(payload)) == Enum.sort(@payload_keys),
         {:ok, source_kind} <- source_kind(payload.source_kind),
         {:ok, focus_basis} <- focus_basis(payload.focus_basis, source_kind),
         true <- valid_claims?(payload),
         {:ok, expires_at} <- DateTime.from_unix(payload.expires_at) do
      if DateTime.compare(expires_at, DateTime.utc_now()) == :gt do
        {:ok,
         %{
           user_id: payload.user_id,
           athanor_id: payload.athanor_id,
           publisher: payload.publisher,
           tincture_name: payload.tincture_name,
           user_generation: payload.user_generation,
           athanor_generation: payload.athanor_generation,
           source_kind: source_kind,
           source_id: payload.source_id,
           focus_basis: focus_basis,
           expires_at: expires_at
         }}
      else
        {:error, :expired_credential}
      end
    else
      _ -> {:error, :invalid_credential}
    end
  end

  defp source_kind("session"), do: {:ok, :session}
  defp source_kind("api_key"), do: {:ok, :api_key}
  defp source_kind(_), do: :error

  defp focus_basis("key", :api_key), do: {:ok, :key}
  defp focus_basis(id, :session) when is_binary(id) and id != "key", do: {:ok, id}
  defp focus_basis(_, _), do: :error

  defp valid_claims?(payload) do
    Enum.all?([:user_id, :athanor_id, :publisher, :tincture_name, :source_id], fn key ->
      is_binary(Map.fetch!(payload, key)) and Map.fetch!(payload, key) != ""
    end) and positive?(payload.user_generation) and positive?(payload.athanor_generation) and
      is_integer(payload.expires_at)
  end

  defp positive?(n), do: is_integer(n) and n > 0

  defp names(
         %{athanor_id: athanor_id, publisher: publisher, tincture_name: name},
         athanor_id,
         publisher,
         name
       ),
       do: :ok

  defp names(_claims, _athanor_id, _publisher, _name), do: {:error, :invalid_credential}

  # ---- the asset credential --------------------------------------------------

  @doc """
  Mint the asset credential a private tincture version's files are served
  under (`/_s/<credential>/…`, `Prima.TinctureUrl`), from a person's
  session or key context: stable for the person, the version digest and
  the window, so a browser's cache holds across page loads.

  The window is the platform setting `asset_credential_window_s`, or
  `window_s:` when a caller asks for a shorter one. The credential expires
  at the end of the half-window bucket after the current one, so what it
  has left is always more than half the window and never more than the
  window, and the same source minting again within one bucket gets the
  same credential; it never outlives its source's own expiry. A window
  that is not a positive number of seconds, or a setting that cannot be
  read as one, is `:invalid_window`.

  Refused as `issue_access_token/3` refuses (`:not_owner`, `:not_primary`,
  `:missing_generation`, a source that no longer stands, `:unavailable`),
  and `:invalid_version` for a digest that is not one.
  """
  @spec mint_asset_credential(Context.t(), String.t(), keyword()) ::
          {:ok, %{credential: String.t(), expires_at: DateTime.t()}}
          | {:error, mint_refusal() | :invalid_window | :invalid_version}
  def mint_asset_credential(%Context{} = ctx, version_digest, opts \\ []) when is_list(opts) do
    with :ok <- owner(),
         :ok <- primary(ctx),
         :ok <- version_digest(version_digest),
         {:ok, window} <- window(opts),
         {:ok, claims} <- claims(ctx),
         {:ok, %{now: now, source_expires_at: source}} <-
           Sanctum.Caller.derived_standing(claims, client_ip: ctx.client_ip) do
      {start, expires} = asset_expiry(DateTime.to_unix(now), window, source)

      if expires > DateTime.to_unix(now) do
        payload = asset_payload(claims, version_digest, expires)

        credential =
          Plug.Crypto.sign(signing_secret(), @asset_credential_salt, payload,
            signed_at: start,
            max_age: expires - start
          )

        {:ok, %{credential: credential, expires_at: DateTime.from_unix!(expires)}}
      else
        {:error, :expired_credential}
      end
    end
  end

  @doc """
  What an asset credential opens, held to the rows it names as they are
  now: the person, the athanor, the version digest, the source binding and
  the seconds it has left, which a response's `Cache-Control: max-age`
  never exceeds. `client_ip:` is the request's address, for a key's
  allowlist.

  Refused with `:invalid_credential` for anything this server did not
  sign as an asset credential, `:expired_credential` past its window, and
  as `Sanctum.Caller.derived_standing/2` refuses when its source was
  retired or its person or athanor changed standing since: a retirement
  refuses every later fetch.
  """
  @spec verify_asset_credential(String.t(), keyword()) ::
          {:ok, asset_authority()}
          | {:error,
             :invalid_credential
             | :expired_credential
             | :not_standing
             | :not_member
             | :ip_not_allowed
             | :unavailable}
  def verify_asset_credential(credential, opts \\ []) when is_binary(credential) and is_list(opts) do
    with {:ok, claims, version_digest, expires} <- asset_claims(credential),
         {:ok, %{now: now}} <-
           Sanctum.Caller.derived_standing(claims, client_ip: Keyword.get(opts, :client_ip)) do
      remaining = expires - DateTime.to_unix(now)

      if remaining > 0 do
        {:ok,
         %{
           user_id: claims.user_id,
           athanor_id: claims.athanor_id,
           version_digest: version_digest,
           credential_binding: claims_binding(claims),
           expires_at: DateTime.from_unix!(expires),
           remaining_s: remaining
         }}
      else
        {:error, :expired_credential}
      end
    end
  end

  # The bucket the credential's expiry falls in: half the window wide, so
  # every mint within one bucket answers the same credential and each has
  # more than half the window left. A one-second window has no half; its
  # credential is the second's. Capped by the source's own expiry, floored
  # to the second so the signed deadline never outlives it.
  defp asset_expiry(now, 1, source), do: cap({now, now + 1}, source)

  defp asset_expiry(now, window, source) do
    half = div(window, 2)
    start = div(now, half) * half
    cap({start, start + 2 * half}, source)
  end

  defp cap({start, expires}, nil), do: {start, expires}
  defp cap({start, expires}, %DateTime{} = source), do: {start, min(expires, DateTime.to_unix(source))}

  defp window(opts) do
    with {:ok, setting} <- setting("asset_credential_window_s", :invalid_window) do
      case Keyword.get(opts, :window_s, setting) do
        asked when is_integer(asked) and asked > 0 -> {:ok, min(asked, setting)}
        _other -> {:error, :invalid_window}
      end
    end
  end

  # A positive number of seconds from the platform settings: anything else
  # — no value, zero, a store that was never installed — is `absent`, and
  # a store that cannot answer is `:unavailable`.
  defp setting(key, absent) do
    case Arca.PlatformSettings.effective(key) do
      {:ok, seconds} when is_integer(seconds) and seconds > 0 -> {:ok, seconds}
      {:error, :unavailable} -> {:error, :unavailable}
      _absent -> {:error, absent}
    end
  end

  defp version_digest("sha256:" <> hex = digest) when byte_size(hex) == 64 do
    if Regex.match?(~r/\A[0-9a-f]{64}\z/, hex), do: :ok, else: invalid_version(digest)
  end

  defp version_digest(digest), do: invalid_version(digest)

  defp invalid_version(_digest), do: {:error, :invalid_version}

  # A list, never a map: its encoding is the same bytes for the same
  # fields, which is what keeps a credential stable within its bucket.
  defp asset_payload(claims, version_digest, expires) do
    [
      @version,
      claims.user_id,
      claims.athanor_id,
      version_digest,
      Atom.to_string(claims.source_kind),
      claims.source_id,
      if(claims.focus_basis == :key, do: "key", else: claims.focus_basis),
      claims.user_generation,
      claims.athanor_generation,
      expires
    ]
  end

  defp asset_claims(credential) do
    case Plug.Crypto.verify(signing_secret(), @asset_credential_salt, credential) do
      {:ok,
       [@version, user_id, athanor_id, digest, kind, source_id, basis, user_gen, ath_gen, expires]} ->
        with {:ok, source_kind} <- source_kind(kind),
             {:ok, focus_basis} <- focus_basis(basis, source_kind),
             true <- Enum.all?([user_id, athanor_id, digest, source_id], &(is_binary(&1) and &1 != "")),
             true <- positive?(user_gen) and positive?(ath_gen) and is_integer(expires) do
          {:ok,
           %{
             user_id: user_id,
             athanor_id: athanor_id,
             user_generation: user_gen,
             athanor_generation: ath_gen,
             source_kind: source_kind,
             source_id: source_id,
             focus_basis: focus_basis
           }, digest, expires}
        else
          _ -> {:error, :invalid_credential}
        end

      {:ok, _other} ->
        {:error, :invalid_credential}

      {:error, :expired} ->
        {:error, :expired_credential}

      {:error, _} ->
        {:error, :invalid_credential}
    end
  end

  # ---- the frame credential --------------------------------------------------

  @doc """
  Mint the credential of one frame the shell opened, from a person's
  session or key context: a bearer the frame presents on every request
  (`Prima.TinctureWire`), whose row (`Arca.FrameCredentials`) is its
  standing on every member. It binds the person, the tincture version
  digest, the grant revision and the frame id.

  Its deadline is the platform setting `frame_credential_deadline_s` from
  now, capped by the source's own expiry. A frame id that is not one is
  `:missing_frame_id`; a setting that cannot be read as a positive number
  of seconds is `:missing_deadline`. Otherwise refused as
  `issue_access_token/3` refuses, `:invalid_version` for a digest that is
  not one, `:invalid_grant_revision`, and `:conflict` for a frame id the
  athanor already holds.

  Answers the bearer, the row's id — which `suspend_frame/2`,
  `resume_frame/2` and `revoke_frame/2` name — and the deadline.
  """
  @spec mint_frame_credential(Context.t(), String.t(), non_neg_integer(), String.t()) ::
          {:ok, %{credential: String.t(), id: String.t(), deadline: DateTime.t()}}
          | {:error,
             mint_refusal()
             | :missing_frame_id
             | :missing_deadline
             | :invalid_version
             | :invalid_grant_revision
             | :conflict}
  def mint_frame_credential(%Context{} = ctx, version_digest, grant_revision, frame_id) do
    with :ok <- owner(),
         :ok <- primary(ctx),
         :ok <- frame_id(frame_id),
         :ok <- version_digest(version_digest),
         :ok <- grant_revision(grant_revision),
         {:ok, lifetime} <- setting("frame_credential_deadline_s", :missing_deadline),
         {:ok, claims} <- claims(ctx),
         {:ok, %{now: now, source_expires_at: source}} <-
           Sanctum.Caller.derived_standing(claims, client_ip: ctx.client_ip),
         {:ok, deadline} <- frame_deadline(now, lifetime, source),
         {:ok, row} <-
           stored(
             Arca.FrameCredentials.mint(Context.actor(ctx), %{
               user_id: claims.user_id,
               version_digest: version_digest,
               grant_revision: grant_revision,
               frame_id: frame_id,
               source_kind: Atom.to_string(claims.source_kind),
               source_id: claims.source_id,
               deadline: deadline
             })
           ) do
      # The row is the standing, and the bearer only names it: the
      # generations and the focus basis it carries are the ones the mint
      # read, and a use whose rows no longer carry them is refused whether
      # or not the transition that moved them reached this row first.
      bearer =
        Plug.Crypto.sign(
          signing_secret(),
          @frame_credential_salt,
          [
            @version,
            row.id,
            claims.athanor_id,
            claims.user_generation,
            claims.athanor_generation,
            if(claims.focus_basis == :key, do: "key", else: claims.focus_basis)
          ],
          signed_at: DateTime.to_unix(now),
          max_age: max(DateTime.diff(deadline, now), 1)
        )

      {:ok, %{credential: bearer, id: row.id, deadline: row.deadline}}
    end
  end

  @doc """
  What a frame credential opens, held to its row and to the rows its
  source's standing rests on, read from the store at every use and never
  from a memo: so no use outlives the session-freshness bound
  (`Sanctum.Caller.fresh?/1`). `client_ip:` is the request's address, for
  a key's allowlist.

  Answers the frame's authority — the person, the athanor, the version
  digest, the grant revision, the frame id, the row's id, its deadline and
  the source binding — or `:invalid_credential` for a bearer this server
  did not sign as one, `:suspended`, `:revoked`, `:expired_credential`
  past its deadline, and a source's or a standing's refusal
  (`:not_standing`, `:not_member`, `:ip_not_allowed`); `:unavailable`
  when the store cannot answer.
  """
  @spec verify_frame_credential(String.t(), keyword()) ::
          {:ok, frame_authority()}
          | {:error,
             :invalid_credential
             | :suspended
             | :revoked
             | :expired_credential
             | :not_standing
             | :not_member
             | :ip_not_allowed
             | :unavailable}
  def verify_frame_credential(bearer, opts \\ []) when is_binary(bearer) and is_list(opts) do
    with {:ok, id, athanor_id, bound} <- frame_bearer(bearer),
         {:ok, row} <- frame_row(athanor_id, id),
         :ok <- frame_state(row),
         claims = frame_claims(row, bound),
         {:ok, %{now: now}} <-
           Sanctum.Caller.derived_standing(claims, client_ip: Keyword.get(opts, :client_ip)) do
      if DateTime.compare(row.deadline, now) == :gt do
        {:ok,
         %{
           id: row.id,
           frame_id: row.frame_id,
           user_id: row.user_id,
           athanor_id: row.athanor_id,
           version_digest: row.version_digest,
           grant_revision: row.grant_revision,
           deadline: row.deadline,
           credential_binding: claims_binding(claims)
         }}
      else
        {:error, :expired_credential}
      end
    end
  end

  @doc """
  Suspend the frame credential `id` of the context's person: its bearer
  opens nothing until `resume_frame/2`. `:not_found` for a row that is
  not the person's in the context's athanor; `:revoked` for one revoked.
  """
  @spec suspend_frame(Context.t(), String.t()) ::
          {:ok, frame_row()} | {:error, :not_found | :revoked | :no_athanor | :unavailable}
  def suspend_frame(%Context{} = ctx, id) when is_binary(id) do
    with {:ok, _row} <- own_frame(ctx, id) do
      stored(Arca.FrameCredentials.suspend(Context.actor(ctx), id))
    end
  end

  @doc """
  Resume the suspended frame credential `id` of the context's person, on
  a member that owns its slot and while the context's own source still
  stands. `:expired` past its deadline, `:revoked` for one revoked,
  `:not_owner` on a member that lost its slot, and the standing's
  refusals as `mint_frame_credential/4` answers them.
  """
  @spec resume_frame(Context.t(), String.t()) ::
          {:ok, frame_row()}
          | {:error,
             mint_refusal() | :not_found | :revoked | :expired | :no_athanor}
  def resume_frame(%Context{} = ctx, id) when is_binary(id) do
    with :ok <- owner(),
         :ok <- primary(ctx),
         {:ok, claims} <- claims(ctx),
         {:ok, _standing} <- Sanctum.Caller.derived_standing(claims, client_ip: ctx.client_ip),
         {:ok, _row} <- own_frame(ctx, id) do
      stored(Arca.FrameCredentials.resume(Context.actor(ctx), id))
    end
  end

  @doc """
  Revoke the frame credential `id` of the context's person, as the shell
  discards its frame. Revoking a revoked row answers it as it is; a
  member that lost its slot may still revoke.
  """
  @spec revoke_frame(Context.t(), String.t()) ::
          {:ok, frame_row()} | {:error, :not_found | :no_athanor | :unavailable}
  def revoke_frame(%Context{} = ctx, id) when is_binary(id) do
    with {:ok, _row} <- own_frame(ctx, id) do
      stored(Arca.FrameCredentials.revoke(Context.actor(ctx), id))
    end
  end

  defp frame_id(id), do: if(Prima.TinctureWire.frame_id?(id), do: :ok, else: {:error, :missing_frame_id})

  defp grant_revision(revision) when is_integer(revision) and revision >= 0, do: :ok
  defp grant_revision(_revision), do: {:error, :invalid_grant_revision}

  defp frame_deadline(now, lifetime, source) do
    deadline =
      [DateTime.add(now, lifetime, :second), source]
      |> Enum.reject(&is_nil/1)
      |> Enum.min(DateTime)

    if DateTime.compare(deadline, now) == :gt,
      do: {:ok, deadline},
      else: {:error, :expired_credential}
  end

  defp frame_bearer(bearer) do
    case Plug.Crypto.verify(signing_secret(), @frame_credential_salt, bearer) do
      {:ok, [@version, id, athanor_id, user_gen, ath_gen, basis]}
      when is_binary(id) and id != "" and is_binary(athanor_id) and athanor_id != "" ->
        if positive?(user_gen) and positive?(ath_gen) and (is_binary(basis) and basis != ""),
          do: {:ok, id, athanor_id, %{user_generation: user_gen, athanor_generation: ath_gen, focus_basis: basis}},
          else: {:error, :invalid_credential}

      {:error, :expired} ->
        {:error, :expired_credential}

      _ ->
        {:error, :invalid_credential}
    end
  end

  # The row the bearer names, in the athanor the bearer names. A bearer is
  # signed, so a missing row is a row retention already removed: a frame
  # discarded long enough ago that nothing opens.
  defp frame_row(athanor_id, id) do
    case Arca.FrameCredentials.get(Prima.Actor.in_athanor(athanor_id), id) do
      {:ok, row} -> {:ok, row}
      {:error, :not_found} -> {:error, :revoked}
      {:error, _unreadable} -> {:error, :unavailable}
    end
  end

  defp frame_state(%{state: "active"}), do: :ok
  defp frame_state(%{state: "suspended"}), do: {:error, :suspended}
  defp frame_state(%{state: _revoked}), do: {:error, :revoked}

  defp frame_claims(row, bound) do
    with {:ok, source_kind} <- source_kind(row.source_kind),
         {:ok, focus_basis} <- focus_basis(bound.focus_basis, source_kind) do
      %{
        user_id: row.user_id,
        athanor_id: row.athanor_id,
        user_generation: bound.user_generation,
        athanor_generation: bound.athanor_generation,
        source_kind: source_kind,
        source_id: row.source_id,
        focus_basis: focus_basis
      }
    else
      # A row whose source kind or focus does not read cannot be held to
      # any standing: it is held to one that refuses.
      _ ->
        %{
          user_id: row.user_id,
          athanor_id: row.athanor_id,
          user_generation: 0,
          athanor_generation: 0,
          source_kind: :api_key,
          source_id: row.source_id,
          focus_basis: :key
        }
    end
  end

  # The frame the context's person holds in the context's athanor; any
  # other person's row reads as absent.
  defp own_frame(%Context{athanor_id: athanor_id, user_id: user_id} = ctx, id)
       when is_binary(athanor_id) and athanor_id != "" and is_binary(user_id) do
    case stored(Arca.FrameCredentials.get(Context.actor(ctx), id)) do
      {:ok, %{user_id: ^user_id} = row} -> {:ok, row}
      {:ok, _theirs} -> {:error, :not_found}
      {:error, _} = refusal -> refusal
    end
  end

  defp own_frame(%Context{}, _id), do: {:error, :no_athanor}

  # A store that cannot answer is `:unavailable` to every caller of this
  # module, never the storage layer's own word.
  defp stored({:error, :database_error}), do: {:error, :unavailable}
  defp stored(other), do: other

  @spec authenticate(Plug.Conn.t()) ::
          {:ok, Context.t()} | :unauthenticated | {:error, refusal()}
  def authenticate(conn) do
    with :skip <- try_bearer_header(conn),
         :skip <- try_access_token(conn) do
      :unauthenticated
    else
      # Single tenant chokepoint. Every path builds a `scope: :athanor`
      # context without a tenant check; a context that names no athanor
      # must not authenticate for tincture access.
      {:ok, %Context{} = ctx} ->
        if tenant_resolved?(ctx), do: {:ok, ctx}, else: {:error, :no_athanor}

      {:error, _} = refusal ->
        refusal
    end
  end

  defp tenant_resolved?(%Context{} = ctx) do
    Sanctum.Context.tenant_ok(ctx) == :ok
  end

  # --- Authorization: Bearer header (preferred) ---
  #
  # Carries either kind of credential, told apart by the `cyfr_` prefix, so a
  # caller has one place to put it. This is what lets a client mint a scoped
  # `?_t=` token from `GET /t/access-token` without falling back to a query
  # parameter.

  defp try_bearer_header(conn) do
    case Sanctum.BearerToken.read(conn) do
      token when is_binary(token) ->
        if Sanctum.ApiKey.looks_like_key?(token) do
          validate_api_key(token, conn)
        else
          try_sanctum_session(token)
        end

      nil ->
        :skip
    end
  end

  # The address travels with the context: a token minted from this key is
  # held to the key's allowlist at mint as at every use.
  defp validate_api_key(token, conn) do
    client_ip = Sanctum.ClientIp.resolve(conn)

    case Sanctum.Caller.establish({:api_key, token}, client_ip: client_ip) do
      {:ok, %Context{} = ctx} -> {:ok, %{ctx | client_ip: client_ip}}
      {:error, :unavailable} -> {:error, :unavailable}
      {:error, :no_athanor} -> {:error, :no_athanor}
      {:error, _} -> {:error, :invalid_credential}
    end
  end

  # --- ?_t= short-lived tincture access token ---

  # The request's own tincture comes from the router's path params, so the
  # token is held to it on every `/t/:athanor/:publisher/:tincture_name`
  # route — index, asset and invoke — and a route that names none (the
  # `/t/access-token` mint) refuses minted tokens on its own account.
  defp try_access_token(conn) do
    case query_param(conn, "_t") do
      token when is_binary(token) and token != "" ->
        tincture = {path_param(conn, "publisher"), path_param(conn, "tincture_name")}

        client_ip = Sanctum.ClientIp.resolve(conn)

        case Sanctum.Caller.establish({:tincture_token, token},
               tincture: tincture,
               client_ip: client_ip
             ) do
          {:ok, %Context{} = ctx} -> {:ok, %{ctx | client_ip: client_ip}}
          {:error, :expired_credential} -> {:error, :expired_token}
          {:error, _} = refusal -> refusal
        end

      _ ->
        :skip
    end
  end

  defp path_param(%Plug.Conn{path_params: params}, key) when is_map(params),
    do: Map.get(params, key)

  defp path_param(_conn, _key), do: nil

  # A session token goes through the one door — `Sanctum.Caller.establish/2`
  # — so the memo, the door/denied refusal mapping and the tenant resolve
  # are the same ones every other surface uses (the `:tincture` surface
  # stamps auth_method `:session` in the loader). `denied` — the door
  # stopped admitting this person after the session was minted — is
  # refused; nothing here upgrades what loaded. The memo bounds
  # establishing, not validating: what it answers is revalidated against
  # the stored session and standing before it admits anything.
  defp try_sanctum_session(token) do
    case Sanctum.Caller.establish(token, surface: :tincture, refresh: false) do
      {:ok, %Context{} = ctx} ->
        revalidated_session(ctx)

      {:error, {:denied, _ctx}} ->
        {:error, :denied}

      {:error, :unavailable} ->
        {:error, :unavailable}

      {:error, :no_athanor} ->
        {:error, :no_athanor}

      {:error, _} ->
        {:error, :invalid_credential}
    end
  end

  defp revalidated_session(ctx) do
    case Sanctum.Caller.revalidate_session(ctx) do
      {:ok, fresh} -> {:ok, fresh}
      {:error, :unavailable} -> {:error, :unavailable}
      {:error, _refused} -> {:error, :invalid_credential}
    end
  end

  @sensitive_query_keys ~w(_t _key _session)

  @doc """
  The credential query params this surface accepts or has to scrub.

  `Sanctum.RedactionRosterTest` holds `Prima.Sanitizer` to this list: the
  same names arrive again as decoded params, where the query-string scrub
  below cannot reach them.
  """
  @spec sensitive_query_keys() :: [String.t()]
  def sensitive_query_keys, do: @sensitive_query_keys

  @doc """
  Redact tincture credential query params (`_t`, `_key`, `_session`) in a
  query string, replacing each value with `[REDACTED]`.

  Defense-in-depth: even with header-preferred auth, a stray credential query
  param must never reach an access log / error report. Operators should ALSO
  redact these keys at their reverse proxy (documented in the deploy notes).
  """
  @spec redact_query_string(String.t() | nil) :: String.t()
  def redact_query_string(qs) when is_binary(qs) and qs != "" do
    qs
    |> URI.decode_query()
    |> Enum.map_join("&", fn {k, v} ->
      v = if k in @sensitive_query_keys, do: "[REDACTED]", else: v
      URI.encode_www_form(k) <> "=" <> URI.encode_www_form(v)
    end)
  end

  def redact_query_string(_), do: ""

  @doc """
  Replace `conn.query_string` with its redacted form so any downstream log
  sink / error renderer never observes a raw tincture credential. Call AFTER
  `authenticate/1` (which needs the original query string).
  """
  @spec scrub_conn(Plug.Conn.t()) :: Plug.Conn.t()
  def scrub_conn(%Plug.Conn{} = conn) do
    %{conn | query_string: redact_query_string(conn.query_string)}
  end

  # --- Helpers ---

  defp query_param(conn, key) do
    case conn.query_string do
      qs when is_binary(qs) and qs != "" -> URI.decode_query(qs)[key]
      _ -> nil
    end
  end
end
