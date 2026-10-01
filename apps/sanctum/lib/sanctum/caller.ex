# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Caller do
  @moduledoc """
  One verb that establishes who is calling and where they work.

  A credential names a caller; what a surface needs is the finished
  Context — the principal named, its standing checked, the tenant gate
  passed, optionally focused on an athanor. This is the only builder of
  an authenticated Context: every surface hands its credential here and
  gets a Context or a named refusal its adapter maps to a halt, a
  redirect, or a status code.

  Credentials, and the standing each is held to:

    * `{:session, token}` — a person's session (the bare token is the
      same credential). Memberships resolve the athanor, the users row
      supplies the namespace, and a person the door no longer admits is
      `{:denied, ctx}`.
    * `{:api_key, raw}` — an athanor's key (`client_ip:` for its
      allowlist). The athanor is the key row's, never the creator's
      current membership; the key stands while the athanor is open and
      its creator is not denied.
    * `{:frame_credential, bearer}` — the per-open credential of one
      frame the shell created (`Sanctum.TinctureAuth.verify_frame_credential/2`,
      `client_ip:` for a key's allowlist). Its row and its source's rows
      are read at every establish, never from the memo, so each use is
      within the session-freshness bound; a suspended, revoked or expired
      row, or a retired source, refuses it, and a remote person's session
      source pauses it as the session is paused (`:identity_stale`,
      `derived_standing/2`). The context acts as the person
      in the row's athanor, bound to the frame (`Sanctum.Context`'s
      `frame`: the tincture version and its digest, the grant revision,
      the frame id and the row's id), with the frame's deadline as its
      credential deadline and no interactive class. A holder that keeps it
      establishes the bearer again rather than revalidating the context.
    * `{:webhook, webhook}` — a verified webhook row (`request_id:`).
      Stands while its athanor is open and its creator is not denied.

  A paired device is established by `establish_device/2`, not
  `establish/2`: its one caller is `Sanctum.DeviceCerts`, which verified
  the device's proof of possession and certificate on its channel and
  read the rows the context is built from. The branch trusts that caller
  and reads nothing from the store. Host's export roster
  (`Cyfr.Boundaries`) does not name it, so no surface can hand it rows of
  its own.

  Every Context this module establishes from a credential carries
  `validated_at`, the instant its credential and standing were read from
  the store. A memo hit returns that same instant, so reuse never extends
  it. A context an auth provider synthesized (`establish_context/2`) has
  no stored credential behind it and carries none. A holder
  that keeps a session context — a mounted console, an open stream, a
  pending grant — asks `revalidate_session/1` for a fresh one before
  acting on it once `fresh?/1` says the context is past the bound.

  Refusals:

    * `:unauthenticated` — no token, not a session this server issued, or
      a token or webhook whose principal no longer stands where it was
      minted: a presented credential that opens nothing.
    * `:invalid_credential` / `:expired_credential` — a key or token that
      is not one of this server's, or one past its life.
    * `:revoked` / `:ip_not_allowed` — a key the store or its allowlist
      refuses.
    * `{:denied, ctx}` — a session whose person the door no longer
      admits. The context rides along for surfaces that forward it to the
      anonymous surface rather than halting.
    * `:suspended` — a frame credential whose frame the shell suspended.
    * `:no_athanor` — authenticated, but no athanor resolved.
    * `:not_member` / `:archived` / `:not_found` — the requested focus
      refused.
    * `:unavailable` — a transient store failure. Retryable: it must
      never read as "signed out" or bounce a person into a claim they
      already made.
    * `:identity_stale` — a session of a person whose identity is
      `remote`, whose head is past its freshness bound and could not be
      refreshed from their directory (`Sanctum.IdentityFreshness`). Their
      work pauses and the session stands: retryable, never a sign-out and
      never a denial.

  ## A remote person's session

  A session of a person whose identity provenance is `remote` stands, at
  every establish and every revalidation alike, only on that identity's
  fresh head (`Sanctum.IdentityFreshness.fresh?/2`) and only while the
  session's `identity_key_epoch` is that head's `key_epoch`. A session
  bound to another epoch, or to none, is revoked there and then and
  refused as `:unauthenticated`; a head that cannot be confirmed fresh
  pauses the work as `:identity_stale`. A refresh that moves the head to
  a new `key_epoch` has already deleted the sessions bound to the old one
  in its own transaction, and their memos are dropped once it committed
  (`drop_retired/2`). A local person's session never reads a directory.

  Inside a caller's transaction (a revalidation a write makes under its
  locks) the check reads the cached head alone and writes nothing: a head
  past its bound pauses the work without a directory read, and a session
  bound to another epoch is refused without being revoked there, which
  the next revalidation outside a transaction does.
  """

  alias Sanctum.Context
  alias Sanctum.Session

  require Logger

  @type refusal ::
          :unauthenticated
          | :invalid_credential
          | :expired_credential
          | :revoked
          | :ip_not_allowed
          | {:denied, Context.t()}
          | :suspended
          | :no_athanor
          | :not_member
          | :archived
          | :not_found
          | :unavailable
          | :identity_stale

  @typedoc """
  A paired device as `Sanctum.DeviceCerts` verified it: the certificate
  it stands under (nil for a renewal), its paired-client row, and its
  person's `users` row, the athanor's row and the membership that seats
  them there, read for this verification, and whether they hold the
  platform's.
  """
  @type device :: %{
          required(:certificate) => Prima.DeviceCert.t() | nil,
          required(:client) => map(),
          required(:user) => map(),
          required(:athanor) => map(),
          required(:seat) => map(),
          required(:platform_admin) => boolean()
        }

  @type credential ::
          {:session, String.t() | nil}
          | {:api_key, String.t()}
          | {:frame_credential, String.t()}
          | {:webhook, %{required(:slug) => String.t(), optional(atom()) => term()}}

  @doc """
  Establish the caller behind a session token.

  Options:

    * `:surface` — forwarded to `Session.load/2` (default `:console`).
    * `:focus` — an athanor id or row to focus the established context on
      (`Context.focus/2`); how a nested view follows the page's focus.
    * `:refresh` — slide the session's expiry when due (default `true`).
    * `:task_supervisor` — where the fire-and-forget refresh runs (default
      `Sanctum.TaskSupervisor`), so the write never blocks the hot path;
      `nil` runs none.
  """
  @spec establish(credential() | String.t() | nil, keyword()) ::
          {:ok, Context.t()} | {:error, refusal()}
  def establish(credential, opts \\ [])

  # A bare token is a session token: what the browser cookie and the CLI carry.
  def establish(token, opts) when is_binary(token) or is_nil(token),
    do: establish({:session, token}, opts)

  def establish({:session, token}, _opts) when token in [nil, ""], do: {:error, :unauthenticated}

  def establish({:session, token}, opts) when is_binary(token) do
    ttl = memo_ttl_ms()

    if ttl > 0 do
      # A cold page load establishes the same caller several times inside
      # a second (the plug, the dead render, the connected mount, the
      # nested topbar). The short memo collapses those to one pipeline
      # run. Only successes are cached, and every session mutation
      # (`Session.destroy/1`, `destroy_by_hash/1`, `use_athanor/2`,
      # `revoke_all_for_user/1`) calls `invalidate_hash/1`, so a revoked
      # or repointed session misses on its very next establish — the TTL
      # only bounds reads that race the mutation itself, and, on a peer,
      # an announcement the bus did not deliver. What is cached is an
      # AUTHORIZATION decision, so the TTL is a security bound and not a
      # tuning knob: it is how long a revoked authority may outlive its
      # revocation anywhere in the cell — the same bound `fresh?/1` holds
      # a retained context to.
      key = memo_key(token, opts)

      case Arca.Cache.get(key) do
        {:ok, %Context{} = ctx} ->
          {:ok, ctx}

        :miss ->
          result = do_establish(token, opts)

          with {:ok, ctx} <- result, do: memoize(key, ctx, ttl)
          result
      end
    else
      do_establish(token, opts)
    end
  end

  def establish({:api_key, raw}, opts) when is_binary(raw) do
    case Sanctum.ApiKey.validate(raw, client_ip: Keyword.get(opts, :client_ip)) do
      {:ok, metadata} ->
        ctx = Sanctum.ApiKey.context_from_metadata(metadata)
        with :ok <- tenant_ok(ctx), do: {:ok, validated(ctx)}

      {:error, reason} ->
        {:error, api_key_refusal(reason)}
    end
  end

  def establish({:frame_credential, bearer}, opts) when is_binary(bearer) do
    case Sanctum.TinctureAuth.verify_frame_credential(bearer,
           client_ip: Keyword.get(opts, :client_ip)
         ) do
      {:ok, authority} ->
        ctx =
          Context.build(
            user_id: authority.user_id,
            namespace: Sanctum.Namespace.lookup(authority.user_id),
            athanor_id: authority.athanor_id,
            permissions: frame_permissions(authority.credential_binding),
            scope: :athanor,
            auth_method: :tincture,
            credential_binding: authority.credential_binding,
            credential_deadline: authority.deadline,
            client_ip: Keyword.get(opts, :client_ip),
            frame: %{
              id: authority.id,
              frame_id: authority.frame_id,
              reference: authority.reference,
              version_digest: authority.version_digest,
              grant_revision: authority.grant_revision
            },
            authenticated: true
          )

        with :ok <- tenant_ok(ctx), do: {:ok, validated(ctx)}

      {:error, reason} ->
        {:error, frame_refusal(reason)}
    end
  end

  def establish({:webhook, %{slug: slug} = webhook}, opts) when is_binary(slug) do
    # The stored row must not remain a standing execution channel once its
    # athanor is archived or its creator denied here.
    if Sanctum.Tenancy.channel_active?(webhook.athanor_id, webhook.created_by) do
      # namespace is identity-only (not path-bearing): the creator's, for
      # attribution; nil if the webhook is orphaned.
      namespace =
        case webhook.created_by do
          user_id when is_binary(user_id) and user_id != "" -> Sanctum.Namespace.lookup(user_id)
          _ -> nil
        end

      ctx =
        Context.build(
          user_id: "webhook:#{webhook.slug}",
          namespace: namespace,
          permissions: [:execute],
          athanor_id: webhook.athanor_id,
          auth_method: :webhook,
          # A webhook is not anonymous: the hook is operator-created and
          # consented (profile_id is required at create), so its bound
          # executions may read their vault material.
          authenticated: true,
          anonymous: false,
          request_id: Keyword.get(opts, :request_id)
        )

      with :ok <- tenant_ok(ctx), do: {:ok, validated(ctx)}
    else
      {:error, :unauthenticated}
    end
  end

  # The key store's answers, in this module's vocabulary. A malformed key
  # and an unknown one read alike, as the store already takes care they do.
  defp api_key_refusal(reason) when reason in [:invalid_key_format, :invalid_key],
    do: :invalid_credential

  defp api_key_refusal(reason) when reason in [:revoked, :channel_closed], do: :revoked
  defp api_key_refusal(:ip_not_allowed), do: :ip_not_allowed
  defp api_key_refusal(:database_error), do: :unavailable

  @doc """
  Establish a paired device's context from what `Sanctum.DeviceCerts`
  verified and read for it (`t:device/0`; `request_id:` and `client_ip:`
  for the connection): its one caller. It trusts that caller, which
  verified the device's proof of possession on its channel and its
  certificate, and read the paired client and its person, athanor and
  seat from the store. It reads nothing from the store itself, and checks
  only that the rows it is handed agree with each other: one active
  device client of that person in that athanor, the person and the
  athanor active, the seat theirs, and the certificate, when there is
  one, naming that client, athanor, person and device key. Rows that do
  not agree are `{:error, :unauthenticated}`.

  The context is the person's own interactive client there
  (`auth_method: :device`, its `client_id`, `origin: :interactive`),
  whose credential deadline is the certificate's expiry. A renewal's
  context carries no certificate and so no deadline: it is the fixed
  renewal exchange's, and the one operation it is used for,
  `Sanctum.Pairing.renew/2`, takes no other. Nothing is memoized: the
  channel reads it all again on every request.

  Host's export roster (`Cyfr.Boundaries`) does not name this function.
  """
  @spec establish_device(device(), keyword()) :: {:ok, Context.t()} | {:error, refusal()}
  def establish_device(%{client: client} = device, opts) when is_map(client) and is_list(opts) do
    if device_stands?(device) do
      ctx =
        Context.build(
          user_id: client.user_id,
          email: device.user.email,
          provider: device.user.provider,
          namespace: device.user.namespace,
          athanor_id: client.athanor_id,
          permissions: Context.person_permissions(),
          scope: :athanor,
          auth_method: :device,
          client_id: client.id,
          credential_binding: device_binding(device),
          credential_deadline: device_deadline(device.certificate),
          platform_admin: device.platform_admin,
          origin: :interactive,
          request_id: Keyword.get(opts, :request_id),
          client_ip: Keyword.get(opts, :client_ip),
          authenticated: true
        )

      with :ok <- tenant_ok(ctx), do: {:ok, validated(ctx)}
    else
      {:error, :unauthenticated}
    end
  end

  # The rows a device's verification read agree with each other, as they
  # were read (nothing is read here): one active device client of the
  # person in the athanor, the person and the athanor active, the seat
  # theirs (their seat there or their platform row), and the certificate,
  # when there is one, naming that client, athanor, person and device key.
  defp device_stands?(%{
         certificate: certificate,
         client:
           %{
             id: client_id,
             user_id: user_id,
             athanor_id: athanor_id,
             standing: "active",
             source_kind: "device_cert"
           } = client,
         user: %{id: user_id, status: "active", security_generation: user_generation},
         athanor: %{id: athanor_id, status: "active", security_generation: athanor_generation},
         seat: %{id: seat_id, status: "active", user_id: user_id} = seat,
         platform_admin: platform_admin
       })
       when is_binary(client_id) and is_binary(user_id) and is_binary(athanor_id) and
              is_binary(seat_id) and is_integer(user_generation) and
              is_integer(athanor_generation) and is_boolean(platform_admin) do
    seated?(seat, athanor_id) and certifies?(certificate, client)
  end

  defp device_stands?(_device), do: false

  defp seated?(%{scope: "athanor", athanor_id: athanor_id}, athanor_id), do: true
  defp seated?(%{scope: "platform"}, _athanor_id), do: true
  defp seated?(_seat, _athanor_id), do: false

  defp certifies?(nil, _client), do: true

  defp certifies?(%Prima.DeviceCert{} = certificate, client) do
    certificate.client_id == client.id and certificate.athanor == client.athanor_id and
      certificate.subject == %{kind: :local, user_id: client.user_id} and
      certificate.device_key == client.device_public_key
  end

  defp certifies?(_certificate, _client), do: false

  # What the device's context was read against
  # (`t:Sanctum.Context.credential_binding/0`): the person's and the
  # athanor's generations and the seat that grants the athanor, so an
  # issuance from it locks and rereads them. Its source is `:identity`,
  # the kind that names no stored credential of its own: the paired client
  # is read again on every request, not held.
  defp device_binding(device) do
    %{
      source_kind: :identity,
      source_id: nil,
      focus_basis: device.seat.id,
      user_generation: device.user.security_generation,
      athanor_generation: device.athanor.security_generation
    }
  end

  defp device_deadline(nil), do: nil

  defp device_deadline(%Prima.DeviceCert{expires_at: expires_at}),
    do: DateTime.from_unix!(expires_at, :millisecond)

  # A frame acts as its person, whose session holds every person
  # permission; what it may reach of them is its tincture's declaration,
  # which the data routes hold it to before anything is dispatched. A
  # frame minted under a key carries none: the key's own scopes are not
  # read here, and a frame is never wider than its source.
  defp frame_permissions(%{source_kind: :session}), do: Context.person_permissions()
  defp frame_permissions(_binding), do: []

  # The frame credential's refusals, in this module's vocabulary: a source
  # or standing that no longer holds is a presented credential that opens
  # nothing.
  # A paused identity pauses the frame its session minted: retryable, and
  # no more a retired source than the session is.
  defp frame_refusal(reason)
       when reason in [
              :invalid_credential,
              :expired_credential,
              :suspended,
              :revoked,
              :ip_not_allowed,
              :identity_stale,
              :unavailable
            ],
       do: reason

  defp frame_refusal(_retired), do: :unauthenticated

  @doc """
  Whether the source a derived credential names still stands: the one
  authoritative check behind every tincture asset and frame credential, at
  mint and at every use. Never answered from the establish memo.

  `claims` name the person, the athanor and their generations as read at
  mint, the source credential (`:session` with its base64url token hash,
  or `:api_key` with its row id) and the focus basis (the membership row
  id, or `:key`). The rows are locked and reread in the standing order
  (`Arca.CredentialBindings.check/3`), with the database's own time read
  after the locks, and must hold:

    * the person exists, is active, at the generation read — a person
      denied and allowed again is a new generation;
    * the athanor exists, is active, at the generation read — an athanor
      archived and reopened is a new generation;
    * a session source still exists for this person and has not
      expired; a key source is unrevoked, the athanor's, the person's,
      and its allowlist admits `client_ip:`;
    * the membership a session's focus rested on is still that active
      seat (a rejoin is a new row); a key's focus is the key, so its
      creator leaving the athanor does not end it.

  A session source of a remote person stands, as the session itself does
  (the module doc), only on that person's fresh identity head and while
  bound to its `key_epoch`. The head is read after the locked check and
  outside its transaction, since a head past its bound reads the
  directory. A head that cannot be confirmed fresh pauses the credential
  as `:identity_stale`; a session bound to another epoch is revoked and
  refused as a retired source is, `:not_standing`.

  `{:ok, %{now: now, source_expires_at: expiry | nil}}`, or a refusal:
  `:not_standing`, `:not_member` (the focus membership is gone),
  `:ip_not_allowed`, `:identity_stale`, or `:unavailable` when the store
  cannot answer — never read as either verdict.
  """
  @spec derived_standing(map(), keyword()) ::
          {:ok, %{now: DateTime.t(), source_expires_at: DateTime.t() | nil}}
          | {:error,
             :not_standing | :not_member | :ip_not_allowed | :identity_stale | :unavailable}
  def derived_standing(claims, opts \\ []) do
    binding = %{
      user_id: claims.user_id,
      athanor_id: claims.athanor_id,
      membership_id: if(is_binary(claims.focus_basis), do: claims.focus_basis),
      source: source_row(claims)
    }

    case Arca.CredentialBindings.check(Prima.Actor.system(), binding,
           verify: &derived_policy(&1, claims, Keyword.get(opts, :client_ip))
         ) do
      {:ok, standing} -> derived_identity(claims, standing)
      {:error, :database_error} -> {:error, :unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  # A session source is its person's: a remote person's stands on their
  # identity's fresh head, as their session does at its revalidation. A
  # key source is the athanor's channel and survives a `key_epoch` change.
  defp derived_identity(%{source_kind: :session, user_id: user_id} = claims, standing) do
    with {:session, hash} when hash != <<>> <- source_row(claims),
         :ok <- identity_current(user_id, hash) do
      {:ok, standing}
    else
      {:error, reason} when reason in [:identity_stale, :unavailable] -> {:error, reason}
      _retired -> {:error, :not_standing}
    end
  end

  defp derived_identity(_claims, standing), do: {:ok, standing}

  defp source_row(%{source_kind: :session, source_id: id}) do
    case Base.url_decode64(id, padding: false) do
      {:ok, hash} -> {:session, hash}
      :error -> {:session, <<>>}
    end
  end

  defp source_row(%{source_kind: :api_key, source_id: id}), do: {:api_key, id}

  defp derived_policy(rows, claims, client_ip) do
    with :ok <- derived_person(rows.user, claims),
         :ok <- derived_athanor(rows.athanor, claims),
         :ok <- derived_focus(rows.membership, claims),
         {:ok, expires_at} <- derived_source(rows.source, rows.now, claims, client_ip) do
      {:ok, %{now: rows.now, source_expires_at: expires_at}}
    end
  end

  defp derived_person(%{status: "active", security_generation: generation}, %{
         user_generation: generation
       }),
       do: :ok

  defp derived_person(_user, _claims), do: {:error, :not_standing}

  defp derived_athanor(%{status: "active", security_generation: generation}, %{
         athanor_generation: generation
       }),
       do: :ok

  defp derived_athanor(_athanor, _claims), do: {:error, :not_standing}

  defp derived_focus(nil, %{focus_basis: :key, source_kind: :api_key}), do: :ok

  defp derived_focus(
         %{status: "active", user_id: user_id, scope: "athanor", athanor_id: athanor_id},
         %{user_id: user_id, athanor_id: athanor_id, source_kind: :session}
       ),
       do: :ok

  defp derived_focus(
         %{status: "active", user_id: user_id, scope: "platform"},
         %{user_id: user_id, source_kind: :session}
       ),
       do: :ok

  defp derived_focus(_membership, _claims), do: {:error, :not_member}

  defp derived_source(
         %{kind: :session, row: %{user_id: user_id} = row},
         now,
         %{
           user_id: user_id
         },
         _client_ip
       ) do
    if DateTime.compare(row.expires_at, now) == :gt,
      do: {:ok, row.expires_at},
      else: {:error, :not_standing}
  end

  defp derived_source(
         %{
           kind: :api_key,
           row: %{revoked: false, athanor_id: athanor_id, created_by: user_id} = row
         },
         _now,
         %{athanor_id: athanor_id, user_id: user_id},
         client_ip
       ) do
    case decode_allowlist(row.ip_allowlist) do
      :corrupt -> {:error, :ip_not_allowed}
      allowlist when allowlist in [nil, []] -> {:ok, nil}
      allowlist when is_binary(client_ip) and is_list(allowlist) -> allowed(client_ip, allowlist)
      _ -> {:error, :ip_not_allowed}
    end
  end

  defp derived_source(_source, _now, _claims, _client_ip), do: {:error, :not_standing}

  defp allowed(client_ip, allowlist) do
    if Sanctum.ApiKey.ip_allowed?(client_ip, allowlist),
      do: {:ok, nil},
      else: {:error, :ip_not_allowed}
  end

  defp do_establish(token, opts) do
    case Session.load_sliding(token, surface: Keyword.get(opts, :surface, :console)) do
      {:ok, %Context{} = ctx, slide_due?} ->
        with {:ok, established} <- establish_context(ctx, opts),
             :ok <- identity_current(established.user_id, established.session_token_hash) do
          if slide_due?, do: maybe_refresh(token, opts)
          {:ok, validated(established)}
        end

      {:error, reason} when reason in [:namespace_unavailable, :database_error] ->
        {:error, :unavailable}

      {:error, _reason} ->
        {:error, :unauthenticated}
    end
  end

  @doc """
  Establish a Context that already exists — a loaded session's, or one a
  configured auth provider synthesized (which never went through
  `Session.load/2`, so nothing about it can be assumed done).

  An unauthenticated context is `{:denied, ctx}` — the door stopped
  admitting its person after the session was minted.
  """
  @spec establish_context(Context.t(), keyword()) :: {:ok, Context.t()} | {:error, refusal()}
  def establish_context(ctx, opts \\ [])

  def establish_context(%Context{authenticated: false} = ctx, _opts) do
    {:error, {:denied, ensure_namespace(ctx)}}
  end

  def establish_context(%Context{} = ctx, opts) do
    # Distinguish a retryable membership-read failure from having no athanor membership.
    with {:ok, ctx} <- resolve(ctx),
         ctx = ensure_namespace(ctx),
         :ok <- tenant_ok(ctx),
         {:ok, ctx} <- focus(ctx, Keyword.get(opts, :focus)) do
      {:ok, ctx}
    end
  end

  defp resolve(ctx) do
    case Sanctum.Tenancy.resolve_status(ctx) do
      {:ok, ctx} -> {:ok, ctx}
      {:error, :unavailable} -> {:error, :unavailable}
    end
  end

  @typedoc "Why a retained session context no longer stands."
  @type revalidation_refusal ::
          :unauthenticated | :not_standing | :not_member | :unavailable | :identity_stale

  @doc """
  Revalidate a context a holder has kept since it was established: the
  one check a long-lived surface (a mounted console, an open stream, a
  pending grant) runs before acting on a context it did not just get.

  For a session-backed context (a `:session` credential binding, or a
  session row key) it rereads, under the standing lock order
  (`Arca.CredentialBindings.check/3`, never the establish memo), the
  session row the context's hash names — it must exist, be unexpired and
  belong to the same person — and the person's standing, and the focused
  athanor's; then rebuilds the context from the stored session and the
  person's current memberships (`Sanctum.Session.load_by_hash/2`) and
  focuses it again on the athanor the caller had in focus
  (`Sanctum.Context.focus/2`). The result carries the caller's request
  correlation and plane, never more permission than the caller held, and
  a new `validated_at`.

  Refusals, each distinct:

    * `:unauthenticated` — the session is gone, expired or another
      person's, or the context names a session binding with no row key.
    * `:not_standing` — the person is denied or no longer exists.
    * `:not_member` — the focused athanor is archived, gone or no longer
      the caller's to focus. The session's own default athanor is never
      substituted.
    * `:unavailable` — the store could not answer; never a verdict.
    * `:identity_stale` — a remote person's identity head could not be
      confirmed fresh (the module doc): the work pauses, and the session
      stands.

  A remote person's session is held to their identity's fresh head as
  well, as the module doc says: one bound to a `key_epoch` the fresh head
  does not name is revoked here and refused as `:unauthenticated`.

  An API-key context is held to its key the same way: the key row, its
  creator and its athanor are reread under the same lock — the key
  unrevoked, still the athanor's and the creator's, its allowlist admitting
  the caller's address, the athanor active and the creator not denied (the
  rules the key was established under) — and the context comes back with
  a new `validated_at`, or `:unauthenticated` for a key that no longer
  admits the caller and `:not_standing` for an athanor or creator that no
  longer stands.

  A paired device's context is held to its paired client the same way
  (`Sanctum.DeviceCerts.client_standing/1`): past its certificate's
  expiry it is refused as an expired session is, `:unauthenticated`; a
  client revoked, or a person denied, gone from the athanor or in an
  archived one, is `:not_standing`; and it comes back with a new
  `validated_at` while it stands. So work a device started and something
  else holds (a pending OAuth grant, say) is refused at its recheck once
  the device is revoked or its certificate expired.

  Any other context — one an auth provider synthesized, a frame's, a
  webhook, the system's own — keeps its establishment contract and is
  answered `{:ok, ctx}` unchanged.
  """
  @spec revalidate_session(Context.t()) ::
          {:ok, Context.t()} | {:error, revalidation_refusal()}
  def revalidate_session(%Context{} = ctx) do
    case holder(ctx) do
      {:session, hash, surface} -> revalidate_stored(ctx, hash, surface)
      {:api_key, id} -> revalidate_key(ctx, id)
      :device -> revalidate_device(ctx)
      :other -> {:ok, ctx}
      :unbound -> {:error, :unauthenticated}
    end
  end

  @doc """
  Whether `ctx` was validated within the caller bound
  (`config :sanctum, :caller_memo_ttl_ms`, 2 s): a holder acts on a fresh
  context as it is and revalidates one that is not
  (`revalidate_session/1`). It is the establish memo's own TTL — one
  bound on how long a read of the store is trusted, whether a memo or a
  holder keeps it. The bound runs from `validated_at`, the last time the
  store was read for this context, so reusing a context never extends
  it. A context no one validated is never fresh, and neither is one
  whose validation lies in the future: the elapsed time must be at least
  zero and under the bound. The bound runs on this node's wall clock —
  a context never leaves the node that validated it — so a backward
  clock step can only shorten it, never extend it.
  """
  @spec fresh?(Context.t()) :: boolean()
  def fresh?(%Context{validated_at: %DateTime{} = at}) do
    elapsed = DateTime.diff(now(), at, :millisecond)
    elapsed >= 0 and elapsed < memo_ttl_ms()
  end

  def fresh?(%Context{}), do: false

  defp memo_ttl_ms, do: Application.get_env(:sanctum, :caller_memo_ttl_ms, 2_000)

  # Which credential the context holds, as far as revalidation goes. A
  # frame credential is a derived credential held to its own rows at every
  # use (`derived_standing/2`), whatever its source was; a context that
  # names a session — by binding or by row key — is revalidated from that
  # session and nothing else, so a binding without its key refuses rather
  # than passing as some other kind.
  defp holder(%Context{auth_method: :device}), do: :device
  defp holder(%Context{auth_method: :tincture}), do: :other
  defp holder(%Context{auth_method: :api_key} = ctx), do: key_holder(ctx)

  defp holder(%Context{session_token_hash: hash, credential_binding: binding} = ctx) do
    if session_binding?(binding) or not is_nil(hash),
      do: session_holder(ctx),
      else: :other
  end

  defp session_binding?(%{source_kind: :session}), do: true
  defp session_binding?(_binding), do: false

  defp session_holder(%Context{session_token_hash: hash, credential_binding: binding} = ctx)
       when is_binary(hash) and hash != "" do
    with true <- binding_names?(binding, hash),
         {:ok, surface} <- surface_of(ctx) do
      {:session, hash, surface}
    else
      _ -> :unbound
    end
  end

  defp session_holder(%Context{}), do: :unbound

  # The binding and the row key are stamped together by the one session
  # assembly; a context where they disagree is not that assembly's.
  defp binding_names?(nil, _hash), do: true

  defp binding_names?(%{source_kind: :session, source_id: id}, hash),
    do: id == Base.url_encode64(hash, padding: false)

  defp binding_names?(_binding, _hash), do: false

  # A key context names its row; a binding, when the key has one, names
  # the same row.
  defp key_holder(%Context{api_key_id: id, credential_binding: binding})
       when is_binary(id) and id != "" do
    case binding do
      nil -> {:api_key, id}
      %{source_kind: :api_key, source_id: ^id} -> {:api_key, id}
      _other -> :unbound
    end
  end

  defp key_holder(%Context{}), do: :unbound

  defp surface_of(%Context{auth_method: :oidc}), do: {:ok, :console}
  defp surface_of(%Context{auth_method: :session}), do: {:ok, :tincture}
  defp surface_of(%Context{}), do: :error

  defp revalidate_stored(ctx, hash, surface) do
    with :ok <- stored_standing(ctx, hash),
         {:ok, rebuilt} <- reload(hash, surface),
         :ok <- same_person(rebuilt, ctx),
         :ok <- identity_current(rebuilt.user_id, hash),
         {:ok, focused} <- refocus(rebuilt, ctx.athanor_id) do
      {:ok, carried(focused, ctx)}
    end
  end

  # A remote person's session stands only on their identity's fresh head
  # (`Sanctum.IdentityFreshness.fresh?/2`): past the bound with the
  # directory unable to refresh it, the work pauses as `:identity_stale`,
  # and the session stays. A session bound to another `key_epoch` than
  # the fresh head's, or to none, is revoked here and then: a refresh that
  # retired its epoch deleted it already, and one minted against an epoch
  # the head no longer names never stands. A local person's session reads
  # no directory.
  defp identity_current(user_id, hash) when is_binary(user_id) and is_binary(hash) do
    case Arca.PersonIdentities.get(Prima.Actor.system(), user_id) do
      {:ok, %{provenance: "remote", identifier: identifier}} when is_binary(identifier) ->
        remote_current(identifier, hash)

      {:ok, %{provenance: "remote"}} ->
        {:error, :unauthenticated}

      {:ok, _local} ->
        :ok

      {:error, :not_found} ->
        :ok

      {:error, _unanswered} ->
        {:error, :unavailable}
    end
  end

  defp identity_current(_user_id, _hash), do: {:error, :unauthenticated}

  defp remote_current(identifier, hash) do
    case Sanctum.IdentityFreshness.fresh?(identifier, []) do
      {:ok, %{key_epoch: epoch}} -> session_epoch(hash, epoch)
      {:refused, :identity_stale} -> {:error, :identity_stale}
      {:error, :unavailable} -> {:error, :unavailable}
    end
  end

  defp session_epoch(hash, epoch) do
    case Arca.SessionStorage.get_session(hash) do
      {:ok, %{identity_key_epoch: ^epoch}} when is_binary(epoch) ->
        :ok

      # Refused either way. Revoked only outside a transaction: a caller's
      # transaction is no place to delete a session and announce it, so the
      # next revalidation outside one revokes it.
      {:ok, _retired_or_unbound} ->
        if Arca.in_transaction?() do
          {:error, :unauthenticated}
        else
          Logger.warning(
            "[Sanctum.Caller] a remote person's session is bound to no key_epoch, or to " <>
              "one the fresh head no longer names; revoking it"
          )

          _ = Session.destroy_by_hash(hash)
          {:error, :unauthenticated}
        end

      {:error, :not_found} ->
        {:error, :unauthenticated}

      {:error, _unanswered} ->
        {:error, :unavailable}
    end
  end

  # The session, the person and the focused athanor, locked and reread in
  # the standing order with the database's own time read after the locks.
  defp stored_standing(ctx, hash) do
    binding = %{
      user_id: ctx.user_id,
      athanor_id: ctx.athanor_id,
      membership_id: nil,
      source: {:session, hash}
    }

    case Arca.CredentialBindings.check(Prima.Actor.system(), binding,
           verify: &session_standing(&1, ctx)
         ) do
      :ok ->
        :ok

      {:error, reason} when reason in [:unauthenticated, :not_standing, :not_member] ->
        {:error, reason}

      {:error, _unanswered} ->
        {:error, :unavailable}
    end
  end

  defp session_standing(rows, ctx) do
    with :ok <- stored_session(rows.source, rows.now, ctx.user_id),
         :ok <- standing_person(rows.user) do
      standing_athanor(rows.athanor, ctx.athanor_id)
    end
  end

  defp stored_session(
         %{kind: :session, row: %{user_id: user_id, expires_at: expires_at}},
         now,
         user_id
       ) do
    if DateTime.compare(expires_at, now) == :gt, do: :ok, else: {:error, :unauthenticated}
  end

  defp stored_session(_source, _now, _user_id), do: {:error, :unauthenticated}

  defp standing_person(%{status: "active"}), do: :ok
  defp standing_person(_user), do: {:error, :not_standing}

  defp standing_athanor(_athanor, nil), do: :ok
  defp standing_athanor(%{status: "active"}, _athanor_id), do: :ok
  defp standing_athanor(_athanor, _athanor_id), do: {:error, :not_member}

  # A paired device's certificate deadline on this node's clock, then its
  # paired client and its person's seat, read from the store. Nothing is
  # rebuilt: everything the context carries is the client row's.
  defp revalidate_device(%Context{credential_deadline: deadline} = ctx) do
    if expired?(deadline) do
      {:error, :unauthenticated}
    else
      case Sanctum.DeviceCerts.client_standing(ctx) do
        :ok -> {:ok, validated(ctx)}
        {:error, :unavailable} -> {:error, :unavailable}
        {:error, _ended} -> {:error, :not_standing}
      end
    end
  end

  defp expired?(%DateTime{} = deadline), do: DateTime.compare(now(), deadline) != :lt
  defp expired?(nil), do: false

  # The key row, its creator and its athanor, locked and reread in the
  # standing order; nothing is rebuilt, since everything a key's context
  # carries is the key row's.
  defp revalidate_key(ctx, id) do
    binding = %{
      user_id: ctx.user_id || "",
      athanor_id: ctx.athanor_id,
      membership_id: nil,
      source: {:api_key, id}
    }

    case Arca.CredentialBindings.check(Prima.Actor.system(), binding,
           verify: &key_standing(&1, ctx)
         ) do
      :ok -> {:ok, validated(ctx)}
      {:error, reason} when reason in [:unauthenticated, :not_standing] -> {:error, reason}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  defp key_standing(rows, ctx) do
    with :ok <- stored_key(rows.source, ctx),
         :ok <- key_creator(rows.user, ctx.user_id) do
      key_athanor(rows.athanor)
    end
  end

  defp stored_key(
         %{
           kind: :api_key,
           row: %{revoked: false, athanor_id: athanor_id, created_by: creator} = row
         },
         %Context{athanor_id: athanor_id, user_id: creator, client_ip: client_ip}
       ) do
    case decode_allowlist(row.ip_allowlist) do
      :corrupt ->
        {:error, :unauthenticated}

      allowlist when allowlist in [nil, []] ->
        :ok

      allowlist when is_list(allowlist) and is_binary(client_ip) ->
        if Sanctum.ApiKey.ip_allowed?(client_ip, allowlist),
          do: :ok,
          else: {:error, :unauthenticated}

      _unprovable ->
        {:error, :unauthenticated}
    end
  end

  defp stored_key(_source, _ctx), do: {:error, :unauthenticated}

  # The channel rule a key stands by (`Sanctum.Tenancy.channel_active?/2`):
  # its creator not denied. A creator id that names no row stands only if
  # it was never a person's.
  defp key_creator(%{status: "denied"}, _user_id), do: {:error, :not_standing}
  defp key_creator(%{}, _user_id), do: :ok

  defp key_creator(nil, user_id) when is_binary(user_id) do
    if Prima.PersonId.person?(user_id), do: {:error, :not_standing}, else: :ok
  end

  defp key_creator(nil, _user_id), do: :ok

  defp key_athanor(%{status: "active"}), do: :ok
  defp key_athanor(_athanor), do: {:error, :not_standing}

  defp reload(hash, surface) do
    case Session.load_by_hash(hash, surface: surface) do
      {:ok, %Context{} = rebuilt} -> {:ok, rebuilt}
      {:error, :invalid_session} -> {:error, :unauthenticated}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  defp same_person(%Context{user_id: user_id, authenticated: true}, %Context{user_id: user_id}),
    do: :ok

  defp same_person(%Context{user_id: user_id}, %Context{user_id: user_id}),
    do: {:error, :not_standing}

  defp same_person(_rebuilt, _ctx), do: {:error, :unauthenticated}

  # The caller's focus, authorized again as any focus is; a refusal is the
  # caller's focus lost, never a move to the session's default athanor.
  defp refocus(rebuilt, nil), do: {:ok, rebuilt}

  defp refocus(rebuilt, athanor_id) do
    case Context.focus(rebuilt, athanor_id) do
      {:ok, focused} -> {:ok, focused}
      {:error, :unavailable} -> {:error, :unavailable}
      {:error, _refused} -> {:error, :not_member}
    end
  end

  # What the caller brought that the stored session does not say: its
  # request correlation and the admission it is inside, the origin that
  # admission stamped, the paired client and the pending confirmation it
  # names, its address, a guest plane it cannot leave, and no permission
  # it did not already hold.
  defp carried(%Context{} = fresh, %Context{} = held) do
    fresh = %{
      fresh
      | request_id: held.request_id,
        call_id: held.call_id,
        origin: held.origin,
        client_id: held.client_id,
        confirmation_id: held.confirmation_id,
        client_ip: held.client_ip,
        permissions: narrowed(fresh.permissions, held.permissions),
        validated_at: now()
    }

    if held.plane == :guest, do: Context.enter_guest(fresh), else: fresh
  end

  defp narrowed(fresh, held) do
    if MapSet.member?(held, :*), do: fresh, else: MapSet.intersection(fresh, held)
  end

  defp validated(%Context{} = ctx), do: %{ctx | validated_at: now()}

  defp now, do: DateTime.utc_now()

  @doc """
  A light look at who a session belongs to — the identity fields and the
  publisher namespace, if any — with none of the establish work. For
  surfaces that need only the person (the claim and legal flows), not a
  working Context.
  """
  @spec peek(String.t() | nil) ::
          {:ok,
           %{
             user_id: String.t() | nil,
             provider: String.t() | nil,
             email: String.t() | nil,
             namespace: String.t() | nil
           }}
          | {:error, :unauthenticated | :unavailable}
  def peek(token) when token in [nil, ""], do: {:error, :unauthenticated}

  def peek(token) when is_binary(token) do
    case Session.load(token, surface: :console) do
      {:ok, %Context{} = ctx} ->
        {:ok,
         %{
           user_id: ctx.user_id,
           provider: ctx.provider,
           email: ctx.email,
           namespace: ctx.namespace
         }}

      {:error, reason} when reason in [:namespace_unavailable, :database_error] ->
        {:error, :unavailable}

      {:error, _reason} ->
        {:error, :unauthenticated}
    end
  end

  @doc """
  Drop every established-context memo for a session row key, on this
  member and on every other.

  Called by the session mutations (`Sanctum.Session.destroy/1`,
  `destroy_by_hash/1`, `use_athanor/2`, `revoke_all_for_user/1`,
  `invalidate_memo_for_user/1` — which is what archiving an athanor uses)
  so a revoked or repointed session is a next-request fact rather than a
  TTL-bounded one — the same invalidate-on-write discipline
  `Sanctum.Namespace.invalidate/1` applies to its cache.

  The memo table is each member's own, so this member's copy goes first
  and synchronously, before this returns: the caller is usually mid-way
  through an authorization change and must not depend on a round trip.
  The rest of the cell is reached by announcement — a foundation below
  the host emits telemetry and the host puts it on the bus
  (`Cyfr.StandingWatch`). A delivery that never arrives leaves a peer
  serving its memo for the rest of its TTL and no longer: the TTL is the
  bound, the announcement is what makes the usual case immediate.
  """
  @spec invalidate_hash(binary()) :: :ok
  def invalidate_hash(hash) when is_binary(hash) do
    drop_memo(hash)
    Sanctum.Telemetry.caller_invalidated(hash)
  end

  @doc """
  Let go of the sessions a refreshed identity head retired: the head's
  advance deleted every session bound to the `key_epoch` it replaced, in
  its own transaction (`Arca.DirectoryHeads`), and once that committed
  each one's memo is dropped on this member and announced to the rest
  (`invalidate_hash/1`), and the revocation is announced for each person
  in `user_ids`, so their mounted views let go. Called by
  `Sanctum.IdentityFreshness` after every refresh that retired sessions.
  """
  @spec drop_retired([String.t()], [binary()]) :: :ok
  def drop_retired(user_ids, hashes) when is_list(user_ids) and is_list(hashes) do
    Enum.each(hashes, &invalidate_hash/1)
    Enum.each(user_ids, &Sanctum.Telemetry.sessions_revoked/1)
  end

  @doc """
  Drop this member's established-context memos for a session row key,
  announcing nothing.

  What a member does when it HEARS an invalidation
  (`Cyfr.StandingWatch`), and the first half of `invalidate_hash/1`. Kept
  apart from it so hearing an announcement cannot make another.
  """
  @spec drop_memo(binary()) :: :ok
  def drop_memo(hash) when is_binary(hash) do
    Arca.Cache.delete_match(Arca.Cache.Keys.match_established(hash))
    :ok
  end

  # The memo is kept for what remains of the bound `fresh?/1` holds the
  # context to, never longer: the bound runs on this node's wall clock
  # from `validated_at`, whole milliseconds truncated, while the memo runs
  # on the monotonic clock from the put. So it is kept for the bound less
  # the time already elapsed since the validation and less one millisecond
  # for that truncation, and a context with nothing left is not memoized.
  # The elapsed time is never less than zero: a wall clock stepped back
  # since the validation shortens the memo, never keeps it past the TTL.
  # Every establish stamps `validated_at` (`validated/1`).
  defp memoize(key, %Context{validated_at: %DateTime{} = at} = ctx, ttl) do
    elapsed = max(DateTime.diff(now(), at, :millisecond), 0)
    left = ttl - elapsed - 1
    if left > 0, do: Arca.Cache.put(key, ctx, left), else: :ok
  end

  defp memo_key(token, opts) do
    Arca.Cache.Keys.established(
      Session.token_hash(token),
      Keyword.get(opts, :surface, :console),
      memo_coord(Keyword.get(opts, :focus))
    )
  end

  defp memo_coord(%{id: id}), do: id
  defp memo_coord(other), do: other

  defp tenant_ok(ctx) do
    case Context.tenant_ok(ctx) do
      :ok -> :ok
      {:error, :missing_tenant} -> {:error, :no_athanor}
    end
  end

  defp focus(ctx, nil), do: {:ok, ctx}
  defp focus(ctx, coordinate), do: Context.focus(ctx, coordinate)

  # `Session.load/2` populates the namespace from the users row, but a
  # provider-synthesized Context never saw the load — refresh from the
  # row when it is missing.
  defp ensure_namespace(%Context{namespace: ns} = ctx) when is_binary(ns) and ns != "", do: ctx

  defp ensure_namespace(%Context{} = ctx),
    do: %{ctx | namespace: Sanctum.Namespace.lookup(ctx.user_id)}

  # Activity-based sliding refresh, fire-and-forget so the hot path never
  # waits on the write. Started only when the row the load read is due one
  # (`Session.slide_due?/1`); `Session.refresh_if_stale/1` checks again.
  defp maybe_refresh(token, opts) do
    with true <- Keyword.get(opts, :refresh, true),
         supervisor when not is_nil(supervisor) <-
           Keyword.get(opts, :task_supervisor, Sanctum.TaskSupervisor) do
      start_refresh(supervisor, token)
    else
      _ -> :ok
    end
  end

  # Best effort: a pool that is not up (a standalone build that never
  # started this application) costs the slide, never the establish.
  defp start_refresh(supervisor, token) do
    logger_metadata = Prima.LoggerContext.capture()

    case Task.Supervisor.start_child(supervisor, fn ->
           Prima.LoggerContext.restore(logger_metadata)
           slide(token)
         end) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        Logger.debug("[Sanctum.Caller] session refresh task not started: #{inspect(reason)}")
    end
  catch
    :exit, reason ->
      Logger.debug("[Sanctum.Caller] session refresh task not started: #{inspect(reason)}")
  end

  # The slide swallows a store that cannot answer; a connection taken away
  # under it (its owner gone) is the same unanswered read.
  defp slide(token) do
    Session.refresh_if_stale(token)
  catch
    :exit, reason ->
      Logger.debug("[Sanctum.Caller] session refresh did not run: #{inspect(reason)}")
  end

  # A stored allowlist is a security row. Valid JSON holding only strings
  # is the list, an absent column is no restriction, and anything else is
  # corrupt, which every admission refuses. The line names the column and
  # its size, never its bytes.
  defp decode_allowlist(nil), do: nil
  defp decode_allowlist(""), do: nil

  defp decode_allowlist(json) when is_binary(json) do
    case Prima.Json.decode(json) do
      {:ok, list} when is_list(list) ->
        if Enum.all?(list, &is_binary/1),
          do: list,
          else: corrupt_allowlist("is not a list of strings", json)

      {:ok, _other} ->
        corrupt_allowlist("is not a list of strings", json)

      {:error, :invalid_json} ->
        corrupt_allowlist("is not valid JSON", json)
    end
  end

  defp corrupt_allowlist(problem, json) do
    Logger.warning("[Sanctum.Caller] stored ip_allowlist #{problem} (#{byte_size(json)} bytes)")
    :corrupt
  end
end
