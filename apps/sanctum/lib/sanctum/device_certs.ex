# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.DeviceCerts do
  @moduledoc """
  Device certificates as a backend checks them: the proof of possession
  on a connection, and on every paired request a strict expiry on this
  home's clock, clock tolerance at not-before alone, and the chain to the
  person's current live key, read from the certificate's own subject. No
  cached validation outlives a certificate.

  ## On a connection

  `verify_connect/3` decides the proof a glass sends on the device
  channel, against the challenge the channel holds for that connection
  (`Prima.DeviceCert.Challenge`), by the challenge's purpose:

    * `connect` — the proof of possession of the certificate's device
      key, then the certificate itself, as every request checks it
      (below). Answers the client's context, whose credential deadline is
      the certificate's expiry.
    * `renew` — the proof of possession of the device key the active
      paired-client row stores, for a glass whose certificate expired or
      was chained to a live key since rotated. The certificate the glass
      brought only located the client; it authorizes nothing and is not
      checked. Answers the renewal exchange's context, which carries no
      certificate and so no deadline: the channel uses it for the one
      renewal operation (`pairing/renew`) and nothing else, and
      `Sanctum.Pairing.renew/2` takes no other context.

  A challenge is bound to this home (`Sanctum.Person.home/0`), the
  athanor, the client and the device key, so a connect proof is never
  taken as a renewal proof, or a proof for one client or home as
  another's.

  ## On every request

  `verify_request/3` takes only a device context `verify_connect/3`
  produced, and a certificate for it: the one that context was
  established under (its credential deadline is the certificate's
  expiry), or, for the renewal exchange's context, the replacement the
  renewal issued. A certificate is not secret, so it verifies nothing
  without the proof of possession that context stands for. It checks the
  certificate's signature under the person's live key as this home stores
  it now (read from the certificate's own subject, never from what the
  connection claims), its audience, its not-before with the clock
  tolerance (`clock_skew_seconds`) and its expiry, strictly on this
  home's clock; then that the certificate's client, athanor and person
  are the context's, and the paired-client row active and holding the
  certificate's device key; then the person's standing: not denied, the
  athanor open and a seat in it (or the platform's). Nothing is cached:
  the next request reads it all again, so no validation outlives the
  certificate or the standing behind it.

  This module verifies and builds no context: once a proof or a request
  verifies, the client's context is established by
  `Sanctum.Caller.establish_device/2`, whose one caller this is, from the
  verified certificate, the paired client and its person, athanor and
  seat as read here.

  ## A remote person's certificate

  A certificate of an `identity` subject names a person whose keys another
  home holds, and that home issued it (`remote_subject/3`). It is checked
  against the person this home admitted under that identifier (their
  identity row, `remote`) and the head their directory names: signed by
  its current live key, under its current `key_epoch`, for this home as
  audience, within its window. On every request the head is answered
  within `identity_freshness_seconds` (`Sanctum.IdentityFreshness.fresh?/2`)
  and read again past it; a directory that cannot be read pauses the
  request (`:identity_stale`), and a head that moved retires the
  certificate (`:bad_signature`, as a local certificate chained to a
  rotated key is). This home never calls the person's home. Pairing reads
  the head live instead (`Sanctum.Pairing.complete/3`). A remote
  certificate is not renewed here: a `renew` for a remote person's client
  is refused `:remote_identity_unavailable`, and the glass is certified
  again at the person's home.

  ## Verification bounds

  Pairing completions and renewals count against two bounds
  (`claim_verification/1`): 20 a minute per source address and 200 a
  minute for the installation, shared by every member of the cell
  (`Arca.RequestRateWindows`), behind a per-node check
  (`Prima.RateLimiter`) that sheds a flood before it reaches the
  database. Each is counted before it is verified, so a flood past the
  bound is refused before any verification work.

  Failed connect proofs count in bounds of their own, 20 a minute per
  source and 200 for the installation, in the same two layers
  (`claim_connect_failure/1`), and never in the completion and renewal
  bounds, so bad connects cannot starve renewals. A connect is counted
  only when its proof or certificate fails, so a paired device
  reconnecting spends nothing, and a burst of devices reconnecting after
  a restart does not spend the installation's bound. Before any signature
  is checked, the connect bounds are read without counting
  (`connect_budget/1`): this node's first, then the cell's
  (`Prima.RateLimiter.peek/3`, `Arca.RequestRateWindows.check/5`). A spent
  bound refuses the connect `{:rate_limited, retry_after_ms}` with nothing
  verified and nothing counted, and so does a failure that finds its bound
  spent. A read and a later count can race between concurrent failing
  connects; the overshoot is bounded by that concurrency.

  ## Refusals

    * `:proof_refused` — the proof does not answer the held challenge
      under its device key, the challenge is not this home's, or its
      device key is not the one the certificate or row names.
    * `:expired`, `:not_yet_valid`, `:bad_signature`, `:wrong_audience` —
      the certificate, as `Prima.DeviceCert.verify/3` refuses it.
      `:bad_signature` is also a certificate chained to a live key the
      person's row no longer names.
    * `:unknown_subject` — the certificate names no person with a local
      key set here.
    * `:client_mismatch` — the certificate names another client, athanor,
      person or device key than the paired-client row or the context, or
      the context is not a device context `verify_connect/3` produced.
    * `:revoked` — the paired client was revoked.
    * `:not_standing` — no such paired client here, or the person is
      denied, the athanor archived or the person no longer seated in it.
    * `:identity_stale` — a remote person's directory could not confirm
      their head fresh: the request pauses.
    * `:remote_identity_unavailable` — a renewal for a remote person's
      client, which their own home certifies again.
    * `{:rate_limited, retry_after_ms}` — a verification bound is spent.
    * `:unavailable` — the store or a setting could not answer; never a
      verdict either way.
  """

  require Logger

  alias Prima.DeviceCert
  alias Prima.DeviceCert.{Challenge, Proof}
  alias Sanctum.{Context, Person}

  @window_ms 60_000
  @source_cap 20
  @installation_cap 200

  @typedoc """
  What the connection presented: the client id and the certificate it
  sent (a `connect`'s, or a `renew`'s locator), and the source address it
  came from, which the verification bounds are counted by.
  """
  @type connection :: %{
          required(:client_id) => String.t(),
          optional(:certificate) => DeviceCert.t() | nil,
          optional(:source) => String.t() | nil
        }

  @typedoc "Why a proof, a certificate or a client's standing was refused (the module doc)."
  @type refusal ::
          :proof_refused
          | :expired
          | :not_yet_valid
          | :bad_signature
          | :wrong_audience
          | :unknown_subject
          | :client_mismatch
          | :revoked
          | :not_standing
          | :identity_stale
          | :remote_identity_unavailable
          | {:rate_limited, non_neg_integer()}
          | :unavailable

  @typedoc """
  A person's standing in an athanor, as read now: the users row, the
  athanor row, and the membership that seats them there (their seat, or
  their platform row), and whether they hold the platform's.
  """
  @type standing :: %{
          user: map(),
          athanor: map(),
          seat: map(),
          platform_admin: boolean()
        }

  # ---------------------------------------------------------------------------
  # On a connection
  # ---------------------------------------------------------------------------

  @doc """
  Decide the proof `proof` a glass sent on its connection, against the
  challenge `challenge` the channel holds for it, by the challenge's
  purpose (the module doc). Answers the client's context, which
  `Sanctum.Caller.establish_device/2` builds from what was verified here:
  `auth_method: :device`, its `client_id`, the person and athanor of the
  paired-client row, `origin: :interactive`, and, for a `connect`, the
  certificate's expiry as its credential deadline.
  """
  @spec verify_connect(connection(), Proof.t() | map(), Challenge.t()) ::
          {:ok, Context.t()} | {:error, refusal()}
  def verify_connect(
        %{client_id: client_id, certificate: %DeviceCert{} = certificate} = connection,
        proof,
        %Challenge{purpose: :connect} = challenge
      )
      when is_binary(client_id) do
    now = now_ms()
    source = Map.get(connection, :source)

    # The connect bounds are read before any signature is checked, and a
    # spent one refuses with nothing verified and nothing counted.
    result =
      with :ok <- connect_budget(source),
           :ok <- held(challenge, client_id, certificate),
           :ok <- possession(proof, challenge, now) do
        checked_request(certificate, %{client_id: client_id}, now, client_ip: source)
      end

    # Only a failed connect counts, in the connect bounds: a paired device
    # reconnecting is no guess, and a flood of failures neither locks the
    # paired out nor spends the bounds renewals are held to. A failure
    # that finds its bound spent says so.
    case result do
      {:ok, _ctx} ->
        result

      # A store or a directory that could not answer is no failed proof.
      {:error, reason} when reason in [:unavailable, :identity_stale] ->
        result

      {:error, {:rate_limited, _retry_after_ms}} ->
        result

      {:error, refused} ->
        case claim_connect_failure(source) do
          {:error, {:rate_limited, _retry_after_ms}} = spent -> spent
          _counted -> {:error, refused}
        end
    end
  end

  def verify_connect(%{client_id: client_id} = connection, proof, %Challenge{purpose: :renew} = c)
      when is_binary(client_id) do
    now = now_ms()
    source = Map.get(connection, :source)

    with :ok <- claim_verification(source),
         :ok <- renewal_held(c, client_id),
         :ok <- possession(proof, c, now),
         {:ok, row} <- paired_client(c.athanor, nil, client_id),
         :ok <- stored_key(row, c.device_key),
         :ok <- local_identity(row.user_id),
         {:ok, standing} <- standing(row.user_id, row.athanor_id) do
      established(row, standing, nil, client_ip: source)
    end
  end

  def verify_connect(_connection, _proof, _challenge), do: {:error, :proof_refused}

  # The challenge the channel holds for this connect: this home's, for
  # this client, bound to the certificate's athanor and device key.
  defp held(%Challenge{} = challenge, client_id, %DeviceCert{} = certificate) do
    if challenge.home == Person.home() and challenge.client_id == client_id and
         challenge.athanor == certificate.athanor and
         challenge.device_key == certificate.device_key,
       do: :ok,
       else: {:error, :proof_refused}
  end

  defp renewal_held(%Challenge{} = challenge, client_id) do
    if challenge.home == Person.home() and challenge.client_id == client_id,
      do: :ok,
      else: {:error, :proof_refused}
  end

  defp possession(proof, %Challenge{} = challenge, now) do
    case Proof.verify(proof, challenge, now) do
      :ok -> :ok
      {:error, _refused} -> {:error, :proof_refused}
    end
  end

  # ---------------------------------------------------------------------------
  # On every request
  # ---------------------------------------------------------------------------

  @doc """
  Check `certificate` for a request of the device context `ctx` (the
  module doc): a `%Sanctum.Context{auth_method: :device}` that
  `verify_connect/3` produced, or that an earlier call here answered.
  The certificate must be the one the context was established under (its
  credential deadline is the certificate's expiry), or, for the renewal
  exchange's context, which has none, the replacement the renewal issued.
  Answers the client's context as it stands now, its credential deadline
  the certificate's expiry and `validated_at` now, its request
  correlation and address carried on; any other context is refused
  `:client_mismatch`.

  `opts`: `:now`, this home's clock in Unix milliseconds, which defaults
  to the system's.
  """
  @spec verify_request(DeviceCert.t(), Context.t(), keyword()) ::
          {:ok, Context.t()} | {:error, refusal()}
  def verify_request(
        %DeviceCert{} = certificate,
        %Context{auth_method: :device, authenticated: true, client_id: client_id} = ctx,
        opts
      )
      when is_binary(client_id) and is_list(opts) do
    now = Keyword.get(opts, :now) || now_ms()

    with :ok <- names_context(certificate, ctx),
         {:ok, %Context{user_id: user_id} = checked} <-
           checked_request(certificate, ctx, now,
             request_id: ctx.request_id,
             client_ip: ctx.client_ip
           ) do
      # The certificate's subject, resolved to a person here, is the
      # context's own person.
      if user_id == ctx.user_id, do: {:ok, checked}, else: {:error, :client_mismatch}
    end
  end

  def verify_request(%DeviceCert{}, _not_a_device_context, opts) when is_list(opts),
    do: {:error, :client_mismatch}

  # A certificate and the client it is presented for: the context's, or,
  # inside `verify_connect/3` once the proof verified, the client the
  # connection names. Private: a certificate alone proves nothing.
  defp checked_request(certificate, client, now, carried) do
    with :ok <- names_client(certificate, client),
         {:ok, subject} <- subject(certificate, now),
         certificate = subject.certificate,
         {:ok, row} <- paired_client(certificate.athanor, subject.user_id, certificate.client_id),
         :ok <- stored_key(row, certificate.device_key, :client_mismatch),
         {:ok, standing} <- standing(subject.user_id, certificate.athanor) do
      established(row, standing, certificate, carried, subject.identity)
    end
  end

  # The context names the certificate's client, athanor and, for a local
  # subject, person (an identity subject's person is resolved from the
  # identifier and held to the context's after), and was established under
  # this certificate (its deadline is the certificate's expiry) or is the
  # renewal exchange's, established under none.
  defp names_context(%DeviceCert{} = certificate, %Context{} = ctx) do
    deadline = ctx.credential_deadline

    if ctx.client_id == certificate.client_id and ctx.athanor_id == certificate.athanor and
         names_person?(certificate, ctx.user_id) and
         (is_nil(deadline) or DateTime.to_unix(deadline, :millisecond) == certificate.expires_at),
       do: :ok,
       else: {:error, :client_mismatch}
  end

  defp names_person?(%DeviceCert{subject: %{kind: :local, user_id: user_id}}, user_id), do: true
  defp names_person?(%DeviceCert{subject: %{kind: :identity}}, user_id), do: is_binary(user_id)
  defp names_person?(%DeviceCert{}, _user_id), do: false

  defp names_client(%DeviceCert{client_id: id}, %{client_id: id}), do: :ok
  defp names_client(%DeviceCert{}, _client), do: {:error, :client_mismatch}

  # The person a certificate names and the certificate as verified: a local
  # subject under the live key this home stores for them; an identity
  # subject under the head their directory names (`remote_subject/3`).
  defp subject(%DeviceCert{subject: %{kind: :local, user_id: user_id}} = certificate, now) do
    with {:ok, live_key} <- live_key(user_id),
         {:ok, skew_ms} <- skew_ms(),
         {:ok, certificate} <- checked(certificate, live_key, now, skew_ms, nil) do
      {:ok, %{user_id: user_id, identity: nil, certificate: certificate}}
    end
  end

  defp subject(%DeviceCert{subject: %{kind: :identity}} = certificate, now),
    do: remote_subject(certificate, now, :bounded)

  defp subject(%DeviceCert{}, _now), do: {:error, :unknown_subject}

  @doc """
  Check `certificate`, an `identity` subject's, as another home issued it
  for one of its people (the module doc), at `now` (Unix milliseconds):
  the person this home admitted under that identifier, whose identity row
  is `remote`, and the head their directory names, read within its
  freshness bound (`:bounded`, every request) or live (`:live`, a
  pairing). The certificate must be signed by that head's live key, under
  its `key_epoch`, for this home as audience, within its window.

  Answers `{:ok, %{user_id, identity, certificate}}`, `identity` the
  person's identity row as read here (its `user_id`, `provenance` and
  `identifier`), or a refusal: `:unknown_subject` (no remote person here
  holds that identifier), `:bad_signature` (another key, or a `key_epoch`
  the head has moved past), `:expired`, `:not_yet_valid`,
  `:wrong_audience`, `:identity_stale`, `:unavailable`.
  """
  @spec remote_subject(DeviceCert.t(), non_neg_integer(), :bounded | :live) ::
          {:ok,
           %{
             user_id: String.t(),
             identity: %{user_id: String.t(), provenance: String.t(), identifier: String.t()},
             certificate: DeviceCert.t()
           }}
          | {:error, refusal()}
  def remote_subject(
        %DeviceCert{subject: %{kind: :identity, identifier: identifier}} = certificate,
        now,
        freshness
      )
      when freshness in [:bounded, :live] do
    with {:ok, identity} <- remote_person(identifier),
         {:ok, state} <- head_state(identifier, freshness),
         {:ok, skew_ms} <- skew_ms(),
         {:ok, certificate} <- checked(certificate, state.live_key, now, skew_ms, state.key_epoch) do
      {:ok, %{user_id: identity.user_id, identity: identity, certificate: certificate}}
    end
  end

  def remote_subject(%DeviceCert{}, _now, _freshness), do: {:error, :unknown_subject}

  # The person this home admitted under `identifier`: a remote person's
  # identity row, of which the context's establishment is handed the
  # columns that bind it (`Sanctum.Caller.establish_device/2`). A local
  # person's own identifier names no certificate another home issued to
  # them here.
  defp remote_person(identifier) do
    case Arca.PersonIdentities.lookup_identifier(Prima.Actor.system(), identifier) do
      {:ok, %{provenance: "remote"} = row} ->
        {:ok, Map.take(row, [:user_id, :provenance, :identifier])}

      {:ok, _local} ->
        {:error, :unknown_subject}

      {:error, :not_found} ->
        {:error, :unknown_subject}

      {:error, _unanswered} ->
        {:error, :unavailable}
    end
  end

  defp head_state(identifier, freshness) do
    answer =
      case freshness do
        :bounded -> Sanctum.IdentityFreshness.fresh?(identifier)
        :live -> Sanctum.IdentityFreshness.fresh!(identifier)
      end

    case answer do
      {:ok, head} ->
        case Sanctum.Directory.Client.state(head) do
          {:ok, state} -> {:ok, state}
          {:error, :corrupt} -> {:error, :unavailable}
        end

      {:refused, :identity_stale} ->
        {:error, :identity_stale}

      {:error, :unavailable} ->
        {:error, :unavailable}
    end
  end

  # The live key this home stores for the certificate's own subject, read
  # as the server, as every read of a person's key row is
  # (`Sanctum.Person`): the subject names the person, and a person is not
  # a row inside an athanor.
  defp live_key(user_id) do
    case Arca.PersonIdentities.get(Prima.Actor.system(), user_id) do
      {:ok, %{provenance: "local", live_public_key: key}} when is_binary(key) -> {:ok, key}
      {:ok, _no_local_keys} -> {:error, :unknown_subject}
      {:error, :not_found} -> {:error, :unknown_subject}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  @doc """
  Whether the person `user_id` holds a local key set at this home, the
  only kind this home signs a certificate for: `:ok`, or
  `:remote_identity_unavailable` for a person whose keys are at another
  home (or who holds none here), and `:unavailable` when the store
  cannot answer.
  """
  @spec local_identity(String.t()) :: :ok | {:error, :remote_identity_unavailable | :unavailable}
  def local_identity(user_id) when is_binary(user_id) do
    case live_key(user_id) do
      {:ok, _key} -> :ok
      {:error, :unavailable} -> {:error, :unavailable}
      {:error, _not_local} -> {:error, :remote_identity_unavailable}
    end
  end

  # A certificate under `live_key`; an identity subject's under the
  # `key_epoch` its head names too, a moved epoch reading as a key the
  # person's head no longer names.
  defp checked(certificate, live_key, now, skew_ms, key_epoch) do
    case DeviceCert.verify(certificate, live_key,
           home: Person.home(),
           now: now,
           skew: skew_ms,
           key_epoch: key_epoch
         ) do
      {:ok, certificate} ->
        {:ok, certificate}

      {:error, reason}
      when reason in [:expired, :not_yet_valid, :bad_signature, :wrong_audience] ->
        {:error, reason}

      {:error, _malformed_or_moved} ->
        {:error, :bad_signature}
    end
  end

  # The clock tolerance, applied to a certificate's not-before alone. A
  # value the store cannot answer refuses the request: a certificate is
  # never accepted on a tolerance this member cannot read.
  defp skew_ms do
    case Arca.PlatformSettings.effective("clock_skew_seconds") do
      {:ok, seconds} when is_integer(seconds) and seconds >= 0 ->
        {:ok, seconds * 1_000}

      {:ok, _other} ->
        Logger.error(
          "[Sanctum.DeviceCerts] the stored clock_skew_seconds is not a whole number of " <>
            "seconds; refusing until it is"
        )

        {:error, :unavailable}

      {:error, :unavailable} ->
        {:error, :unavailable}

      {:error, reason} when reason in [:uninstalled, :unknown_key] ->
        raise "[Sanctum.DeviceCerts] clock_skew_seconds cannot be read: the setting is #{reason}"
    end
  end

  # ---------------------------------------------------------------------------
  # The paired client and the person's standing
  # ---------------------------------------------------------------------------

  @doc """
  The paired-client row `client_id` in the athanor `athanor_id`, of the
  person `user_id` (any person's for `nil`): `{:ok, row}` for an active
  client paired with a device key, `:revoked` for a revoked one,
  `:not_standing` for one this home does not hold, and `:unavailable`
  when the store cannot answer.
  """
  @spec paired_client(String.t(), String.t() | nil, String.t()) ::
          {:ok, map()} | {:error, :revoked | :not_standing | :unavailable}
  def paired_client(athanor_id, user_id, client_id)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(client_id) do
    filters =
      if is_binary(user_id),
        do: [user_id: user_id, standing: :all],
        else: [standing: :all]

    case Arca.PairedClients.list(Prima.Actor.in_athanor(athanor_id), filters) do
      {:ok, rows} ->
        case Enum.find(rows, &(&1.id == client_id)) do
          %{standing: "active", source_kind: "device_cert"} = row -> {:ok, row}
          %{standing: "revoked"} -> {:error, :revoked}
          _absent_or_no_device -> {:error, :not_standing}
        end

      {:error, _unanswered} ->
        {:error, :unavailable}
    end
  end

  def paired_client(_athanor_id, _user_id, _client_id), do: {:error, :not_standing}

  defp stored_key(row, device_key, mismatch \\ :proof_refused) do
    if row.device_public_key == device_key, do: :ok, else: {:error, mismatch}
  end

  @doc """
  The standing of the person `user_id` in the athanor `athanor_id`, read
  now (`t:standing/0`): the person not denied, the athanor open, and a
  seat of theirs there or, for a platform administrator, their platform
  row, as an issuance holds a focus to (`Sanctum.Issuance`).
  `:not_standing` otherwise, `:unavailable` when the store cannot answer.
  """
  @spec standing(String.t(), String.t()) ::
          {:ok, standing()} | {:error, :not_standing | :unavailable}
  def standing(user_id, athanor_id) when is_binary(user_id) and is_binary(athanor_id) do
    with {:ok, user} <- row(Sanctum.Tenancy.Users.get(user_id)),
         :ok <- active(user),
         {:ok, athanor} <- row(Sanctum.Tenancy.Athanors.get(athanor_id)),
         :ok <- active(athanor),
         {:ok, platform} <- seat(Sanctum.Tenancy.Members.platform_seat(user_id)),
         {:ok, seat} <- seat(Sanctum.Tenancy.Members.active_seat(user_id, athanor_id)),
         {:ok, basis} <- basis(seat, platform) do
      {:ok, %{user: user, athanor: athanor, seat: basis, platform_admin: not is_nil(platform)}}
    end
  end

  defp row({:ok, row}), do: {:ok, row}
  defp row({:error, :not_found}), do: {:error, :not_standing}
  defp row({:error, _unanswered}), do: {:error, :unavailable}

  defp active(%{status: "active"}), do: :ok
  defp active(_row), do: {:error, :not_standing}

  defp seat({:ok, row}), do: {:ok, row}
  defp seat(:none), do: {:ok, nil}
  defp seat({:error, _unanswered}), do: {:error, :unavailable}

  defp basis(nil, nil), do: {:error, :not_standing}
  defp basis(nil, platform), do: {:ok, platform}
  defp basis(seat, _platform), do: {:ok, seat}

  @doc """
  Whether the paired client a device context names still stands: its
  certificate's deadline not passed, the paired-client row active and the
  person's standing in the athanor (`standing/2`). For a grant decided
  under a paired device (`Sanctum.Consent.Authz.authorize/3`) and for who
  can confirm (`Sanctum.Pairing.can_confirm?/1`). Any other context
  stands for no paired client.
  """
  @spec client_standing(Context.t()) :: :ok | {:error, :revoked | :not_standing | :unavailable}
  def client_standing(
        %Context{auth_method: :device, client_id: client_id, user_id: user_id, athanor_id: a} =
          ctx
      )
      when is_binary(client_id) and is_binary(user_id) and is_binary(a) do
    with :ok <- within(ctx.credential_deadline),
         {:ok, _row} <- paired_client(a, user_id, client_id),
         {:ok, _standing} <- standing(user_id, a) do
      :ok
    end
  end

  def client_standing(%Context{}), do: {:error, :not_standing}

  defp within(nil), do: :ok

  defp within(%DateTime{} = deadline) do
    if DateTime.compare(DateTime.utc_now(), deadline) == :lt,
      do: :ok,
      else: {:error, :not_standing}
  end

  # The client's context, established by `Sanctum.Caller.establish_device/2`
  # from what was verified here: the certificate (nil for a renewal, whose
  # certificate only located the client), the paired-client row, the
  # identity row an identity subject's person was resolved by (nil for a
  # local subject), and its person, athanor and seat as just read, with the
  # connection's request correlation and address. Nothing here builds a
  # context.
  defp established(row, standing, certificate, carried, identity \\ nil) do
    device = %{
      certificate: certificate,
      client: row,
      identity: identity,
      user: standing.user,
      athanor: standing.athanor,
      seat: standing.seat,
      platform_admin: standing.platform_admin
    }

    # The rows were read as standing just now; establish refusing them is
    # a standing that no longer reads as one.
    case Sanctum.Caller.establish_device(device, carried) do
      {:ok, ctx} -> {:ok, ctx}
      {:error, _refused} -> {:error, :not_standing}
    end
  end

  # ---------------------------------------------------------------------------
  # Verification bounds
  # ---------------------------------------------------------------------------

  @doc """
  Count one pairing completion or renewal from `source` (a client
  address, or `nil` where the ingress knew none) against the source and
  installation bounds (the module doc): this node's own count first,
  which answers a flood without a database read, then the cell's.
  `{:rate_limited, retry_after_ms}` once either is spent, `:unavailable`
  when the store cannot count, which refuses as the bound would.
  """
  @spec claim_verification(String.t() | nil) ::
          :ok | {:error, {:rate_limited, non_neg_integer()} | :unavailable}
  def claim_verification(source),
    do: claim(:device_verification, source)

  @doc """
  Count one failed connect proof from `source` against the connect bounds
  (the module doc), which are the connect's own: the same caps and the
  same two layers as `claim_verification/1`, in buckets no completion or
  renewal spends. Answers as `claim_verification/1` does.
  """
  @spec claim_connect_failure(String.t() | nil) ::
          :ok | {:error, {:rate_limited, non_neg_integer()} | :unavailable}
  def claim_connect_failure(source),
    do: claim(:device_connect, source)

  @doc """
  Whether the connect bounds of `source` have room, counting nothing: the
  per-node window first, which answers a flood without a database read,
  then the cell's (the module doc). `:ok`, `{:rate_limited,
  retry_after_ms}` once either is spent, or `:unavailable` when the store
  cannot answer, which refuses as a spent bound would.
  """
  @spec connect_budget(String.t() | nil) ::
          :ok | {:error, {:rate_limited, non_neg_integer()} | :unavailable}
  def connect_budget(source) do
    key = source_key(source)

    with :ok <- node_room({:device_connect, :source, key}, @source_cap),
         :ok <- node_room({:device_connect, :installation}, @installation_cap),
         :ok <- cell_room(bucket(:device_connect, :source), key, @source_cap) do
      cell_room(bucket(:device_connect, :installation), "installation", @installation_cap)
    end
  end

  defp node_room(key, cap) do
    case Prima.RateLimiter.peek(key, cap, @window_ms) do
      :ok -> :ok
      {:deny, retry_after_s} -> {:error, {:rate_limited, retry_after_s * 1_000}}
    end
  end

  defp cell_room(bucket, key, cap) do
    case Arca.RequestRateWindows.check(Prima.Actor.system(), bucket, key, cap, @window_ms) do
      :ok -> :ok
      {:error, {:rate_limited, retry_after_ms}} -> {:error, {:rate_limited, retry_after_ms}}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  defp claim(kind, source) do
    key = source_key(source)

    with :ok <- on_node({kind, :source, key}, @source_cap),
         :ok <- on_node({kind, :installation}, @installation_cap),
         :ok <- in_cell(bucket(kind, :source), key, @source_cap) do
      in_cell(bucket(kind, :installation), "installation", @installation_cap)
    end
  end

  # The durable buckets, spelled in code: the completion and renewal
  # bounds, and the connect bounds beside them.
  defp bucket(:device_verification, :source), do: :device_verification_source
  defp bucket(:device_verification, :installation), do: :device_verification_installation
  defp bucket(:device_connect, :source), do: :device_connect_source
  defp bucket(:device_connect, :installation), do: :device_connect_installation

  defp on_node(key, cap) do
    case Prima.RateLimiter.check(key, cap, @window_ms) do
      :ok -> :ok
      {:deny, retry_after_s} -> {:error, {:rate_limited, retry_after_s * 1_000}}
    end
  end

  defp in_cell(bucket, key, cap) do
    case Arca.RequestRateWindows.claim(Prima.Actor.system(), bucket, key, cap, @window_ms) do
      :ok -> :ok
      {:error, {:rate_limited, retry_after_ms}} -> {:error, {:rate_limited, retry_after_ms}}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  # An ingress that knew no address charges one shared bucket, never none.
  defp source_key(source) when is_binary(source) and source != "", do: source
  defp source_key(_source), do: "unknown"

  defp now_ms, do: System.os_time(:millisecond)
end
