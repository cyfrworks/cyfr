# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.TinctureAuth do
  @moduledoc """
  The tincture frame protocol's two credentials: what a private tincture
  version's files are served under, and what a frame the shell opened
  presents to the endpoint. Both are narrowed derivatives of one stored
  session or API key, never credentials of their own, each under its own
  salt so neither verifies as the other. No credential of this module
  travels in a query string: a URL ends up in browser history and every
  intermediary's logs, and a `Referer` is never sent from a tincture
  (`Referrer-Policy: no-referrer`).

  A private tincture version's files are served under an **asset
  credential** in the path (`/_s/<credential>/…`, `Prima.TinctureUrl`):
  signed, opaque and URL-safe, carrying no secret, stable for one person,
  one version digest and one window under one source, and held to that
  source's rows at every fetch (`mint_asset_credential/3`,
  `verify_asset_credential/2`). The window is the platform setting
  `asset_credential_window_s`, capped by the source's remaining life. A
  canvas's host page is served under the same credential, for the frame
  its path names, read under that credential's authority and held to its
  version (`page_frame/2`).

  A frame the shell opens holds a **frame credential**: a bearer naming
  one row of `Arca.FrameCredentials`, which is its standing on every
  member, bound to the person, the tincture version (its reference and its
  digest), the grant revision and the frame id, with a deadline of its own
  (`frame_credential_deadline_s`, capped the same way). The shell
  suspends, resumes, renews and revokes it here; a standing transition
  revokes it in its own transaction (`Arca.SecurityTransitions`); every use
  reads the row and the standing again (`mint_frame_credential/5`,
  `verify_frame_credential/2`, `suspend_frame/2`, `resume_frame/2`,
  `renew_frame/2`, `revoke_frame/2`).

  A resume and a renew rotate the bearer, never extend it: each signs a
  new bearer naming the same row, with a deadline of its own, and moves
  the row's deadline to match. A canvas's resume signs nothing and keeps
  the row's deadline (`resume_frame/3` with `rotate: false`), so a canvas
  hidden past its deadline lapses. Every bearer carries the deadline it was
  signed with and is refused past it whatever the row's, so a copy of an
  earlier bearer gains nothing from a renewal, and a frame no shell renews
  ends at its deadline.

  A candidate version's hidden trial holds a **validation credential**: a
  frame credential of the same form whose row's purpose is `validation`
  (`mint_validation_credential/5`), with a deadline of 60 seconds capped
  the same way. It is never suspended or resumed, and it is spent once,
  by the activation that names its frame and the version digest it
  trialled (`consume_validation/3`).

  Minting and every use hold a credential to the rows its source names as
  they are now (`Sanctum.Caller.derived_standing/2`): a source logged out,
  deleted, expired, revoked or rotated, a person denied and allowed again,
  an athanor archived and reopened, or the membership a session's focus
  rested on removed — rejoining is a new row — refuses it for good. A
  key's focus is the key, so its creator leaving the athanor does not end
  it. Only a person's session or key context mints, on a member that holds
  the control plane; a key with no person behind it mints nothing. A store
  that cannot answer is `{:error, :unavailable}`: nothing is minted and
  nothing served.
  """

  alias Sanctum.Context

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

  @typedoc "A tincture version, as a frame credential names it."
  @type tincture_version :: %{publisher: String.t(), name: String.t(), version: String.t()}

  @typedoc """
  What a verified frame credential opens: its row's id, the frame id, the
  person, the athanor, the tincture version the frame opened and its
  digest, the grant revision, the frame's mode (its row's purpose), the
  deadline and the source binding.
  """
  @type frame_authority :: %{
          id: String.t(),
          frame_id: String.t(),
          user_id: String.t(),
          athanor_id: String.t(),
          reference: tincture_version(),
          version_digest: String.t(),
          grant_revision: non_neg_integer(),
          mode: frame_mode(),
          deadline: DateTime.t(),
          credential_binding: Context.credential_binding()
        }

  @typedoc "A frame credential's mode: a live frame's, or a validation trial's."
  @type frame_mode :: :live | :validation

  @typedoc "A frame credential's row, as `Arca.FrameCredentials` answers it."
  @type frame_row :: Arca.FrameCredentials.row()

  @typedoc "Why a credential could not be minted."
  @type mint_refusal ::
          :not_owner
          | :not_primary
          | :missing_generation
          | :not_standing
          | :not_member
          | :ip_not_allowed
          | :expired_credential
          | :identity_stale
          | :unavailable

  # The two credentials of the frame protocol, each under its own salt, so
  # neither verifies as the other.
  @asset_credential_salt "tincture_asset_credential_v1"
  @frame_credential_salt "tincture_frame_credential_v1"
  @version 1

  # The frame bearer's format tag; the bearer carries the deadline it was
  # signed with.
  @frame_version 2

  # A validation credential's life, in seconds: a trial answers within
  # its own deadline, and the credential is spent at activation.
  @validation_deadline_s 60

  # The key both tincture credentials are signed with. From config, not
  # from the web endpoint's module: the auth domain must not reach into the
  # web layer for key material. In every deployed env this is the same
  # secret the endpoint signs with (runtime.exs and dev.exs set both from
  # one value), read through the domain's own key.
  defp signing_secret, do: Application.fetch_env!(:sanctum, :secret_key_base)

  # ---- minting ---------------------------------------------------------------

  # A member that does not hold the control plane dispenses nothing. A
  # frame credential is also written under the live slot
  # (`Arca.FrameCredentials`); an asset credential writes no row, so this
  # cached check alone stands for its ownership, a stated limit: what a
  # stale member mints is bounded by its source session or key, whose
  # rows every fetch reads again.
  defp owner, do: if(Arca.ControlPlane.held?(), do: :ok, else: {:error, :not_owner})

  # A person's session or an athanor's key, as established — never a
  # frame's context.
  defp primary(%Context{authenticated: true, anonymous: false, auth_method: method})
       when method in [:oidc, :session, :api_key],
       do: :ok

  defp primary(%Context{}), do: {:error, :not_primary}

  # The binding the mint is held to. A primary context's binding must agree
  # with the credential field its one assembly path stamped beside it
  # (`Sanctum.Session`, `Sanctum.ApiKey`) — a session's row key encoding to
  # the source id, a key's id equal to it — so a context whose method was
  # changed cannot pass a derived binding off as a primary one.
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

  defp source_kind("session"), do: {:ok, :session}
  defp source_kind("api_key"), do: {:ok, :api_key}
  defp source_kind(_), do: :error

  defp focus_basis("key", :api_key), do: {:ok, :key}
  defp focus_basis(id, :session) when is_binary(id) and id != "key", do: {:ok, id}
  defp focus_basis(_, _), do: :error

  defp positive?(n), do: is_integer(n) and n > 0

  # The binding a credential's claims name, in the context's shape.
  defp claims_binding(claims) do
    %{
      source_kind: claims.source_kind,
      source_id: claims.source_id,
      focus_basis: claims.focus_basis,
      user_generation: claims.user_generation,
      athanor_generation: claims.athanor_generation
    }
  end

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

  Refused on a member that does not hold the control plane
  (`:not_owner`), for a context that is not a person's session or key
  (`:not_primary`), a context with no source binding
  (`:missing_generation`), a source that no longer stands, when the store
  cannot answer (`:unavailable`), and `:invalid_version` for a digest that
  is not one.
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
  refuses every later fetch. A remote person's session source pauses it
  as `:identity_stale` while their identity cannot be confirmed fresh.
  """
  @spec verify_asset_credential(String.t(), keyword()) ::
          {:ok, asset_authority()}
          | {:error,
             :invalid_credential
             | :expired_credential
             | :not_standing
             | :not_member
             | :ip_not_allowed
             | :identity_stale
             | :unavailable}
  def verify_asset_credential(credential, opts \\ [])
      when is_binary(credential) and is_list(opts) do
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

  defp cap({start, expires}, %DateTime{} = source),
    do: {start, min(expires, DateTime.to_unix(source))}

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
             true <-
               Enum.all?([user_id, athanor_id, digest, source_id], &(is_binary(&1) and &1 != "")),
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
  standing on every member. It binds the person, the tincture version the
  frame opened — `reference`, its `publisher`, `name` and `version` — and
  that version's release digest, the grant revision and the frame id.

  Its deadline is the platform setting `frame_credential_deadline_s` from
  now, capped by the source's own expiry. A frame id that is not one is
  `:missing_frame_id`; a setting that cannot be read as a positive number
  of seconds is `:missing_deadline`. Otherwise refused as
  `mint_asset_credential/3` refuses, `:invalid_reference` for a reference
  that does not name a tincture version, `:invalid_version` for a digest
  that is not one, `:invalid_grant_revision`, and `:conflict` for a frame id the
  athanor already holds.

  Answers the bearer, the row's id — which `suspend_frame/2`,
  `resume_frame/2` and `revoke_frame/2` name — and the deadline.
  """
  @spec mint_frame_credential(
          Context.t(),
          tincture_version(),
          String.t(),
          non_neg_integer(),
          String.t()
        ) ::
          {:ok, %{credential: String.t(), id: String.t(), deadline: DateTime.t()}}
          | {:error,
             mint_refusal()
             | :missing_frame_id
             | :missing_deadline
             | :invalid_reference
             | :invalid_version
             | :invalid_grant_revision
             | :conflict}
  def mint_frame_credential(
        %Context{} = ctx,
        reference,
        version_digest,
        grant_revision,
        frame_id
      ),
      do: mint_frame(ctx, reference, version_digest, grant_revision, frame_id, :live)

  @doc """
  Mint the validation credential of one hidden frame a candidate tincture
  version is trialled in: `mint_frame_credential/5`'s arguments, checks
  and refusals, and a bearer of the same form, whose row's purpose is
  `validation` — the established frame's mode says so (`Sanctum.Context`'s
  `frame.mode`). Its deadline is 60 seconds from now, never past the
  source's own expiry, and not the `frame_credential_deadline_s` setting.

  It is never suspended or resumed (`suspend_frame/2` and `resume_frame/2`
  answer `:validation`); `revoke_frame/2` discards it, and
  `consume_validation/3` spends it.
  """
  @spec mint_validation_credential(
          Context.t(),
          tincture_version(),
          String.t(),
          non_neg_integer(),
          String.t()
        ) ::
          {:ok, %{credential: String.t(), id: String.t(), deadline: DateTime.t()}}
          | {:error,
             mint_refusal()
             | :missing_frame_id
             | :invalid_reference
             | :invalid_version
             | :invalid_grant_revision
             | :conflict}
  def mint_validation_credential(
        %Context{} = ctx,
        reference,
        version_digest,
        grant_revision,
        frame_id
      ),
      do: mint_frame(ctx, reference, version_digest, grant_revision, frame_id, :validation)

  defp mint_frame(ctx, reference, version_digest, grant_revision, frame_id, mode) do
    with :ok <- owner(),
         :ok <- primary(ctx),
         :ok <- frame_id(frame_id),
         :ok <- tincture_version(reference),
         :ok <- version_digest(version_digest),
         :ok <- grant_revision(grant_revision),
         {:ok, lifetime} <- frame_lifetime(mode),
         {:ok, claims} <- claims(ctx),
         {:ok, %{now: now, source_expires_at: source}} <-
           Sanctum.Caller.derived_standing(claims, client_ip: ctx.client_ip),
         {:ok, deadline} <- frame_deadline(now, lifetime, source),
         {:ok, row} <-
           stored(
             Arca.FrameCredentials.mint(Context.actor(ctx), %{
               user_id: claims.user_id,
               publisher: reference.publisher,
               name: reference.name,
               version: reference.version,
               version_digest: version_digest,
               grant_revision: grant_revision,
               frame_id: frame_id,
               source_kind: Atom.to_string(claims.source_kind),
               source_id: claims.source_id,
               purpose: Atom.to_string(mode),
               deadline: deadline
             })
           ) do
      {:ok, signed(row, claims, now)}
    end
  end

  # A bearer naming `row`, signed for the row's deadline. The row is the
  # standing, and the bearer only names it: the generations and the focus
  # basis it carries are the ones the caller just read, and a use whose
  # rows no longer carry them is refused whether or not the transition that
  # moved them reached this row first. It carries the deadline it was
  # signed with, which no later move of the row's lengthens.
  defp signed(row, claims, now) do
    bearer =
      Plug.Crypto.sign(
        signing_secret(),
        @frame_credential_salt,
        [
          @frame_version,
          row.id,
          claims.athanor_id,
          claims.user_generation,
          claims.athanor_generation,
          if(claims.focus_basis == :key, do: "key", else: claims.focus_basis),
          DateTime.to_unix(row.deadline, :microsecond)
        ],
        signed_at: DateTime.to_unix(now),
        max_age: max(DateTime.diff(row.deadline, now, :second), 1)
      )

    %{credential: bearer, id: row.id, deadline: row.deadline}
  end

  @doc """
  What a frame credential opens, held to its row and to the rows its
  source's standing rests on, read from the store at every use and never
  from a memo: so no use outlives the session-freshness bound
  (`Sanctum.Caller.fresh?/1`). `client_ip:` is the request's address, for
  a key's allowlist.

  `held: true` reads it for a stream it already opened, which is held to
  the row: the bearer's own signed deadline and age end nothing, and the
  deadline answered is the row's, which a renewal or a resume moves. So a
  renewal keeps every open stream of the frame, and its suspension,
  revocation or the row's deadline ends each of them. A request is never
  read this way: a bearer a renewal replaced opens nothing past its own
  deadline.

  Answers the frame's authority — the person, the athanor, the tincture
  version (`reference`) and its digest, the grant revision, the frame id,
  the row's id, its mode (`:live` or `:validation`), its deadline (the
  row's, or the bearer's own when that is earlier: a bearer a renewal
  replaced keeps the deadline it was signed with) and the source binding
  — or `:invalid_credential` for a bearer this server did not sign as one,
  `:suspended`, `:revoked`, `:expired_credential` past either deadline,
  and a source's or a standing's refusal (`:not_standing`, `:not_member`,
  `:ip_not_allowed`, and `:identity_stale` while a remote person's session
  source cannot have their identity confirmed fresh); `:unavailable` when
  the store cannot answer.
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
             | :identity_stale
             | :unavailable}
  def verify_frame_credential(bearer, opts \\ []) when is_binary(bearer) and is_list(opts) do
    held? = Keyword.get(opts, :held, false)

    with {:ok, id, athanor_id, bound} <- frame_bearer(bearer, held?),
         {:ok, row} <- frame_row(athanor_id, id),
         :ok <- frame_state(row),
         claims = frame_claims(row, bound),
         {:ok, %{now: now}} <-
           Sanctum.Caller.derived_standing(claims, client_ip: Keyword.get(opts, :client_ip)) do
      deadline =
        if held?, do: row.deadline, else: Enum.min([row.deadline, bound.deadline], DateTime)

      if DateTime.compare(deadline, now) == :gt do
        {:ok,
         %{
           id: row.id,
           frame_id: row.frame_id,
           user_id: row.user_id,
           athanor_id: row.athanor_id,
           reference: %{publisher: row.publisher, name: row.name, version: row.version},
           version_digest: row.version_digest,
           grant_revision: row.grant_revision,
           mode: frame_mode(row.purpose),
           deadline: deadline,
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
  not the person's in the context's athanor; `:revoked` for one revoked;
  `:validation` for a validation credential, which is never suspended and
  stays as it is. A suspension is announced once it is stored
  (`Sanctum.Telemetry.frame_credential_changed/3`).
  """
  @spec suspend_frame(Context.t(), String.t()) ::
          {:ok, frame_row()}
          | {:error, :not_found | :revoked | :validation | :no_athanor | :unavailable}
  def suspend_frame(%Context{} = ctx, id) when is_binary(id) do
    with {:ok, _row} <- own_frame(ctx, id),
         {:ok, row} <- stored(Arca.FrameCredentials.suspend(Context.actor(ctx), id)) do
      announced(row, :suspended)
    end
  end

  @doc """
  Resume the suspended frame credential `id` of the context's person, on
  a member that owns its slot and while the context's own source still
  stands, and rotate its bearer: the standing is derived again as a mint
  derives it, and the answer is a new bearer naming the same row, with a
  new deadline (`frame_credential_deadline_s` from now, capped by the
  source's own expiry) that the row takes as it resumes. A row whose
  deadline passed while it was suspended is resumed all the same: every
  bearer signed for it before is refused past its own deadline, so only
  this one opens it. An active row before its deadline keeps its deadline,
  and the answer is a new bearer for it.

  With `rotate: false` nothing is signed and the row keeps its deadline,
  for a frame that is not resumed past its deadline (a canvas's, which
  lapses while hidden and is renewed only while shown): the row is
  resumed only before that deadline, and the answer is its id and
  deadline.

  `:expired` for a row past its deadline (a suspended one only with
  `rotate: false`), `:revoked` for one revoked, `:validation` for a
  validation credential, which is never resumed, `:not_found` for a row
  not the person's or not minted under the context's own source,
  `:not_owner` on a member that lost its slot, and the standing's refusals
  as `mint_frame_credential/5` answers them; none of them writes anything.
  """
  @spec resume_frame(Context.t(), String.t(), keyword()) ::
          {:ok, %{credential: String.t(), id: String.t(), deadline: DateTime.t()}}
          | {:ok, %{id: String.t(), deadline: DateTime.t()}}
          | {:error,
             mint_refusal()
             | :missing_deadline
             | :not_found
             | :revoked
             | :expired
             | :validation
             | :no_athanor}
  def resume_frame(%Context{} = ctx, id, opts \\ []) when is_binary(id) and is_list(opts) do
    if Keyword.get(opts, :rotate, true),
      do: rotate(ctx, id, &Arca.FrameCredentials.resume/3),
      else: reopen(ctx, id)
  end

  @doc """
  Renew the active frame credential `id` of the context's person while
  its frame runs: `resume_frame/2`'s rotation for a row that stays active.
  The standing is derived again as a mint derives it; the row's deadline
  becomes `frame_credential_deadline_s` from now, capped by the source's
  own expiry, written under the member's ownership; and the answer is a
  new bearer naming the same row, bound to the row's own version digest
  and grant revision. The bearer it replaces keeps its own deadline.

  `:suspended` for a suspended row, `:revoked` for one revoked,
  `:validation` for a validation credential, `:expired` for one past its
  deadline, `:not_found` for a row not the person's or not minted under
  the context's own source, `:not_owner` on a member that lost its slot,
  and the standing's refusals as `mint_frame_credential/5` answers them;
  none of them writes anything.
  """
  @spec renew_frame(Context.t(), String.t()) ::
          {:ok, %{credential: String.t(), id: String.t(), deadline: DateTime.t()}}
          | {:error,
             mint_refusal()
             | :missing_deadline
             | :not_found
             | :suspended
             | :revoked
             | :expired
             | :validation
             | :no_athanor}
  def renew_frame(%Context{} = ctx, id) when is_binary(id),
    do: rotate(ctx, id, &Arca.FrameCredentials.renew/3)

  # One rotation: the standing a mint reads, the person's own row minted
  # under this source, the new deadline written by `write` under the row's
  # lock and the member's slot, and a bearer signed for it.
  defp rotate(ctx, id, write) do
    with :ok <- owner(),
         :ok <- primary(ctx),
         {:ok, lifetime} <- frame_lifetime(:live),
         {:ok, claims} <- claims(ctx),
         {:ok, %{now: now, source_expires_at: source}} <-
           Sanctum.Caller.derived_standing(claims, client_ip: ctx.client_ip),
         {:ok, row} <- own_frame(ctx, id),
         :ok <- same_source(row, claims),
         {:ok, deadline} <- frame_deadline(now, lifetime, source),
         {:ok, row} <- stored(write.(Context.actor(ctx), id, deadline)) do
      {:ok, signed(row, claims, now)}
    end
  end

  # A resume that keeps the row's deadline and signs nothing.
  defp reopen(ctx, id) do
    with :ok <- owner(),
         :ok <- primary(ctx),
         {:ok, claims} <- claims(ctx),
         {:ok, _standing} <- Sanctum.Caller.derived_standing(claims, client_ip: ctx.client_ip),
         {:ok, row} <- own_frame(ctx, id),
         :ok <- same_source(row, claims),
         {:ok, row} <- stored(Arca.FrameCredentials.resume(Context.actor(ctx), id, :keep)) do
      {:ok, %{id: row.id, deadline: row.deadline}}
    end
  end

  # A bearer is signed only with the standing of the source its row was
  # minted under.
  defp same_source(%{source_kind: kind, source_id: source_id}, claims) do
    if kind == Atom.to_string(claims.source_kind) and source_id == claims.source_id,
      do: :ok,
      else: {:error, :not_found}
  end

  @doc """
  Revoke the frame credential `id` of the context's person, as the shell
  discards its frame. Revoking a revoked row answers it as it is; a
  member that lost its slot may still revoke. A revocation is announced
  once it is stored (`Sanctum.Telemetry.frame_credential_changed/3`).
  """
  @spec revoke_frame(Context.t(), String.t()) ::
          {:ok, frame_row()} | {:error, :not_found | :no_athanor | :unavailable}
  def revoke_frame(%Context{} = ctx, id) when is_binary(id) do
    with {:ok, _row} <- own_frame(ctx, id),
         {:ok, row} <- stored(Arca.FrameCredentials.revoke(Context.actor(ctx), id)) do
      announced(row, :revoked)
    end
  end

  # A suspension or a revocation is a standing change, announced once it
  # is stored, so a stream held open under the credential on any member
  # is re-established at once.
  defp announced(row, change) do
    Sanctum.Telemetry.frame_credential_changed(row.user_id, row.id, change)
    {:ok, row}
  end

  @doc """
  Spend the validation credential of the frame `frame_id`, once, for the
  context's person: on a member that owns its slot, from a person's
  session or key context, and only while the credential is a validation
  credential of the person's, standing and unexpired, and was minted for
  `expected_digest`, the version the activation names
  (`Arca.FrameCredentials.consume/3`). What is checked is checked before
  anything is written, in one transaction.

  `:ok` once it is spent. `:not_validated` for a frame with no such
  credential, a wrong digest included, which spends nothing, so the right
  digest then still succeeds. `:not_owner` on a member that lost its slot,
  `:not_primary` for a context that is not a person's session or key,
  `:no_athanor` for one with no athanor, and `:unavailable` when the store
  cannot answer; none spends anything.
  """
  @spec consume_validation(Context.t(), String.t(), String.t()) ::
          :ok
          | {:error, :not_validated | :not_owner | :not_primary | :no_athanor | :unavailable}
  def consume_validation(%Context{} = ctx, frame_id, expected_digest)
      when is_binary(frame_id) and is_binary(expected_digest) do
    with :ok <- owner(),
         :ok <- primary(ctx) do
      case stored(Arca.FrameCredentials.consume(Context.actor(ctx), frame_id, expected_digest)) do
        {:ok, _row} -> :ok
        {:error, :not_live} -> {:error, :not_validated}
        {:error, _reason} = refusal -> refusal
      end
    end
  end

  @doc """
  The frame `frame_id` a canvas's host page names, read under the
  authority of the page's asset credential (`verify_asset_credential/2`):
  the row of that frame id in the authority's athanor, of the authority's
  person. It answers the tincture version the frame opened and its digest
  only while the row stands, active or suspended with its deadline after
  the store's clock, and only for a row minted for the version the asset
  credential opens, so a page is served for its own open alone.

  Every other row, and no row, is `:not_found`; a store that cannot
  answer is `:unavailable`. Nothing is written.
  """
  @spec page_frame(asset_authority(), String.t()) ::
          {:ok, %{reference: tincture_version(), version_digest: String.t()}}
          | {:error, :not_found | :unavailable}
  def page_frame(
        %{user_id: user_id, athanor_id: athanor_id, version_digest: digest},
        frame_id
      )
      when is_binary(user_id) and user_id != "" and is_binary(athanor_id) and athanor_id != "" and
             is_binary(digest) and is_binary(frame_id) do
    actor =
      Context.build(user_id: user_id, athanor_id: athanor_id, scope: :athanor)
      |> Context.actor()

    with {:ok, row} <- stored(Arca.FrameCredentials.get_by_frame_id(actor, frame_id)),
         {:ok, now} <- store_clock() do
      if standing_page_frame?(row, digest, now),
        do:
          {:ok,
           %{
             reference: %{publisher: row.publisher, name: row.name, version: row.version},
             version_digest: row.version_digest
           }},
        else: {:error, :not_found}
    else
      {:error, :unavailable} -> {:error, :unavailable}
      {:error, _absent} -> {:error, :not_found}
    end
  end

  def page_frame(_authority, _frame_id), do: {:error, :not_found}

  defp standing_page_frame?(
         %{state: state, version_digest: digest, deadline: deadline},
         digest,
         now
       )
       when state in ["active", "suspended"],
       do: DateTime.compare(deadline, now) == :gt

  defp standing_page_frame?(_row, _digest, _now), do: false

  # The database's clock, which judges every frame credential's deadline.
  defp store_clock do
    {:ok, Arca.ServerMetaStorage.now!()}
  rescue
    _unreadable -> {:error, :unavailable}
  end

  defp frame_id(id),
    do: if(Prima.TinctureWire.frame_id?(id), do: :ok, else: {:error, :missing_frame_id})

  # A tincture version by its publisher, name and exact version.
  defp tincture_version(%{publisher: publisher, name: name, version: version})
       when is_binary(publisher) and is_binary(name) and is_binary(version) do
    with :ok <- Prima.ComponentRef.validate_ref_parts(publisher, name),
         :ok <- Prima.ComponentRef.validate_version(version) do
      :ok
    else
      _ -> {:error, :invalid_reference}
    end
  end

  defp tincture_version(_reference), do: {:error, :invalid_reference}

  defp grant_revision(revision) when is_integer(revision) and revision >= 0, do: :ok
  defp grant_revision(_revision), do: {:error, :invalid_grant_revision}

  # How long a frame credential lives before its source caps it: the
  # setting for a live frame, the module's own constant for a validation
  # trial.
  defp frame_lifetime(:live), do: setting("frame_credential_deadline_s", :missing_deadline)
  defp frame_lifetime(:validation), do: {:ok, @validation_deadline_s}

  # A frame's mode, from its row's purpose, which the store holds to
  # these two.
  defp frame_mode("live"), do: :live
  defp frame_mode("validation"), do: :validation

  defp frame_deadline(now, lifetime, source) do
    deadline =
      [DateTime.add(now, lifetime, :second), source]
      |> Enum.reject(&is_nil/1)
      |> Enum.min(DateTime)

    if DateTime.compare(deadline, now) == :gt,
      do: {:ok, deadline},
      else: {:error, :expired_credential}
  end

  # A held stream's bearer is read for the row it names whatever its own
  # age: the stream is held to the row, so the bearer's signed deadline is
  # not what ends it.
  defp frame_bearer(bearer, held?) do
    opts = if held?, do: [max_age: :infinity], else: []

    case Plug.Crypto.verify(signing_secret(), @frame_credential_salt, bearer, opts) do
      {:ok, [@frame_version, id, athanor_id, user_gen, ath_gen, basis, deadline]}
      when is_binary(id) and id != "" and is_binary(athanor_id) and athanor_id != "" and
             is_integer(deadline) ->
        if positive?(user_gen) and positive?(ath_gen) and (is_binary(basis) and basis != ""),
          do:
            {:ok, id, athanor_id,
             %{
               user_generation: user_gen,
               athanor_generation: ath_gen,
               focus_basis: basis,
               deadline: DateTime.from_unix!(deadline, :microsecond)
             }},
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
end
