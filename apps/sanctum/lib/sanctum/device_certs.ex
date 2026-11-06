# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.DeviceCerts do
  @moduledoc """
  Device certificates (`Prima.DeviceCert`, `cyfr-device-cert/v2`): this
  CYFR's own word that a device of a person's account is admitted here,
  issued and verified under its installation key
  (`Sanctum.Cipher.installation_key/0`) and read by nothing else.

  ## Issuing

  `issue/2` signs a certificate for a paired client that is a key of its
  person's account, naming the client's `kid`, the account's identifier
  and the account head it is issued under, for this CYFR as audience
  (`Sanctum.SignIn.audience/0`), valid `device_cert_seconds` from now, and
  records it on the client's row under the issuance fence
  (`Arca.DeviceCertificates.record/2`, `Arca.DirectoryHeads.fence!/2`): a
  head that is no longer the cached head of the person's account is
  refused `:stale_head`, so a certificate issued against a head a refresh
  has moved past either commits before the refresh and is retired by its
  walk, or is refused. A device's first certificate is issued at its hello
  (`Sanctum.DeviceUnlock`), a renewal's through its channel
  (`Sanctum.Pairing.renew/2`).

  ## On a connection

  `verify_connect/3` decides the proof a device sends on its channel,
  against the challenge the channel holds for that connection
  (`Prima.DeviceCert.Challenge`), by the challenge's purpose:

    * `connect` — the proof of possession of the key the certificate's
      paired client stores (the challenge's device key, whose kid the
      certificate names), then the certificate itself, as every request
      checks it (below). Answers the client's context, whose credential
      deadline is the certificate's expiry.
    * `renew` — the proof of possession of the device key the active
      paired-client row stores, for a device whose certificate expired or
      was signed under an installation key this CYFR no longer holds. The
      certificate it brought only located the client; it authorizes
      nothing and is not checked. Answers the renewal exchange's context,
      which carries no certificate and so no deadline: the channel uses it
      for the one renewal operation (`pairing/renew`) and nothing else.

  A challenge is bound to this CYFR, the athanor, the client and the
  device key, so a connect proof is never taken as a renewal proof, or a
  proof for one client as another's.

  ## On every request

  `verify_request/2` takes only a device context `verify_connect/3`
  produced, and a certificate for it: the one that context was
  established under (its credential deadline is the certificate's
  expiry), or, for the renewal exchange's context, the replacement the
  renewal issued. A certificate is not secret, so it verifies nothing
  without the proof of possession that context stands for. In order: the
  paired client the certificate names stands and holds the certificate's
  kid; the account it names is the client's person's, and its head is
  read within freshness's policy (`Sanctum.IdentityFreshness.fresh?/2`),
  whose walk retires what a removed key or a recovery ends before
  anything else is read; the certificate is one this CYFR recorded for
  the client and still holds, and verifies under the installation key
  with the head its row names, its audience, its not-before with the
  clock tolerance (`clock_skew_seconds`) and its expiry strictly on this
  CYFR's clock (`Prima.DeviceCert.verify/3`); the client is read again,
  and then the person's standing: not denied, the athanor open and
  theirs. Nothing is cached: the next request reads it all again.

  This module verifies and builds no context: once a proof or a request
  verifies, the client's context is established by
  `Sanctum.Caller.establish_device/2` from what was read here.

  ## Verification bounds

  Two families of bounds, each in two layers: this node's count
  (`Prima.RateLimiter`), which answers a flood without a database read,
  then the cell's, shared by every member (`Arca.RequestRateWindows`).
  Renewals count in one family (`:device_verification_*`), connects in
  another (`:device_connect_*`), so bad connects cannot starve renewals.

  An attempt is charged to a client only once it has proven what only
  that client's device can, against the stored row; what it merely names
  counts for nothing, since a certificate and a client id are not secret,
  and a flood naming a real client must not spend that client's budget.
  So, on every path:

    1. The source address's window is read without counting, this
       node's and then the cell's, before any row or signature: a spent
       one refuses with nothing verified and nothing counted.
    2. The attempt is attributed when its proof verifies over the
       challenge under the device key the named paired-client row stores
       (the row read at any standing).
    3. An attributed attempt is charged to its client, 20 a minute, this
       node's count and then the cell's; a connect only when it fails,
       before its certificate is checked its budget read without counting
       (`Prima.RateLimiter.peek/3`, `Arca.RequestRateWindows.check/5`), a
       renewal every time. A spent budget refuses `{:device_rate_limited,
       retry_after_ms}`.
    4. An attempt nothing attributes is charged to the source (20 a
       minute) and the installation (200 a minute), this node's two
       counts and then the cell's, and is refused with the word the
       checks always gave it, or `{:rate_limited, retry_after_ms}` once
       either bound is spent.

  ## Refusals

    * `:proof_refused` — the proof does not answer the held challenge
      under its device key, the challenge is not this CYFR's, or its
      device key is not the one the client's row stores.
    * `:expired`, `:not_yet_valid`, `:bad_signature`, `:wrong_audience`,
      `:stale_head` — the certificate, as `Prima.DeviceCert.verify/3`
      refuses it; `:bad_signature` also for one this CYFR never recorded.
    * `:client_mismatch` — the certificate names another client, athanor,
      key or account than the paired-client row or the context, or the
      context is not a device context `verify_connect/3` produced.
    * `:revoked` — the paired client or the certificate was revoked.
    * `:not_standing` — no such paired client here, a suspended one, the
      person denied, the athanor archived or not theirs, or the account
      gone.
    * `:identity_stale` — the account's head could not be read fresh: the
      request pauses.
    * `:company_login_required` — the person stands but for the company
      sign-in this CYFR requires (`Sanctum.CompanyLogin`).
    * `{:rate_limited, retry_after_ms}`, `{:device_rate_limited,
      retry_after_ms}` — a verification bound is spent.
    * `:unavailable` — the store or a setting could not answer; never a
      verdict either way.
  """

  require Logger

  alias Prima.DeviceCert
  alias Prima.DeviceCert.{Challenge, Proof}
  alias Prima.Identity.{Encoding, Key}
  alias Sanctum.Context

  @window_ms 60_000
  @source_cap 20
  @installation_cap 200
  @name_cap 20

  @typedoc """
  What the connection presented: the client id and the certificate it
  sent (a `connect`'s, or a `renew`'s locator), and the source address it
  came from, which the verification bounds count an attempt nothing
  attributes by.
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
          | :stale_head
          | :client_mismatch
          | :revoked
          | :not_standing
          | :identity_stale
          | :company_login_required
          | {:rate_limited, non_neg_integer()}
          | {:device_rate_limited, non_neg_integer()}
          | :unavailable

  @typedoc """
  A person's standing in their athanor, as read now: the users row, the
  athanor row, and whether they hold the platform administrator's mark —
  a capability over the instance.
  """
  @type standing :: %{
          user: map(),
          athanor: map(),
          platform_admin: boolean()
        }

  # ---------------------------------------------------------------------------
  # Issuing
  # ---------------------------------------------------------------------------

  @doc """
  Issue and record a certificate for the paired client `client` (its
  row, a key of its person's account: `kid` set) under the account head
  `head` (the module doc). Refusals: `:stale_head`, `:not_standing` (the
  client no longer stands), `:unavailable`, and the store's own.
  """
  @spec issue(map(), String.t()) :: {:ok, DeviceCert.t()} | {:error, term()}
  def issue(%{id: client_id, kid: kid, athanor_id: athanor_id, user_id: user_id} = client, head)
      when is_binary(kid) and is_binary(head) do
    with {:ok, identifier} <- identifier(user_id),
         {:ok, seconds} <- cert_seconds(),
         {:ok, home} <- Sanctum.SignIn.audience(),
         now = System.os_time(:millisecond),
         {:ok, unsigned} <-
           DeviceCert.new(
             kid: kid,
             client_id: client_id,
             identifier: identifier,
             head: head,
             athanor: athanor_id,
             audience: home,
             not_before: now,
             expires_at: now + seconds * 1_000
           ) do
      {_public, private} = Sanctum.Cipher.installation_key()
      certificate = DeviceCert.sign(unsigned, private)

      with {:ok, _row} <- record(client, certificate), do: {:ok, certificate}
    else
      {:error, {reason, _field}} when reason in [:invalid_field, :missing_field] ->
        {:error, :unavailable}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def issue(_client, _head), do: {:error, :not_standing}

  # The certificate on the client's row, as signed: its JCS bytes and
  # their digest, under the member's live ownership, the person's lock and
  # the fence, and the client's lock.
  defp record(client, %DeviceCert{} = certificate) do
    bytes = Encoding.jcs!(DeviceCert.encode(certificate))

    case Arca.DeviceCertificates.record(Prima.Actor.in_athanor(client.athanor_id), %{
           paired_client_id: client.id,
           user_id: client.user_id,
           identifier: certificate.identifier,
           kid: certificate.kid,
           head: certificate.head,
           device_public_key: client.device_public_key,
           issuing_home: certificate.audience,
           audience_home: certificate.audience,
           not_before: DateTime.from_unix!(certificate.not_before, :millisecond),
           expires_at: DateTime.from_unix!(certificate.expires_at, :millisecond),
           certificate: bytes,
           digest: Prima.Digest.sha256(bytes)
         }) do
      {:ok, row} -> {:ok, row}
      {:error, :stale_head} -> {:error, :stale_head}
      {:error, :client_not_active} -> {:error, :not_standing}
      {:error, :database_error} -> {:error, :unavailable}
      {:error, :not_owner} -> {:error, :unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  # A certificate's validity refuses a stale value: a store that cannot
  # answer it issues nothing, as a session is not issued on a window this
  # member cannot read.
  defp cert_seconds do
    case Arca.PlatformSettings.effective("device_cert_seconds") do
      {:ok, seconds} when is_integer(seconds) and seconds > 0 ->
        {:ok, seconds}

      {:ok, other} ->
        Logger.error(
          "[Sanctum.DeviceCerts] the stored device_cert_seconds #{inspect(other)} is not a " <>
            "positive whole number of seconds; refusing until it is"
        )

        {:error, :unavailable}

      {:error, :unavailable} ->
        {:error, :unavailable}

      {:error, reason} when reason in [:uninstalled, :unknown_key] ->
        raise "[Sanctum.DeviceCerts] device_cert_seconds cannot be read: the setting is #{reason}"
    end
  end

  # ---------------------------------------------------------------------------
  # On a connection
  # ---------------------------------------------------------------------------

  @doc """
  The device key a connection's `connect` or `renew` challenge is bound
  to: the key the paired client the connection names stores, at any
  standing, when its `kid` is the one the certificate names. The source
  address's bound of the purpose's family is read first, counting
  nothing, as `verify_connect/3` reads it. A client this CYFR does not
  hold, or one of another key, is `:unchallengeable`.
  """
  @spec challenge_key(:connect | :renew, connection()) ::
          {:ok, binary()}
          | {:error, :unchallengeable | {:rate_limited, non_neg_integer()} | :unavailable}
  def challenge_key(purpose, %{client_id: client_id, certificate: %DeviceCert{} = cert} = conn)
      when purpose in [:connect, :renew] and is_binary(client_id) do
    family = if purpose == :connect, do: :device_connect, else: :device_verification

    with :ok <- source_room(family, Map.get(conn, :source)) do
      case Arca.PairedClients.list(Prima.Actor.in_athanor(cert.athanor), standing: :all) do
        {:ok, rows} ->
          case Enum.find(rows, &(&1.id == client_id)) do
            %{kid: kid, device_public_key: key} when kid == cert.kid and is_binary(key) ->
              {:ok, key}

            _absent_or_another ->
              {:error, :unchallengeable}
          end

        {:error, _unanswered} ->
          {:error, :unavailable}
      end
    end
  end

  def challenge_key(_purpose, _connection), do: {:error, :unchallengeable}

  @doc """
  Decide the proof `proof` a device sent on its connection, against the
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

    # The address's bound is read before any signature is checked, and a
    # spent one refuses with nothing verified and nothing counted.
    with :ok <- source_room(:device_connect, source) do
      case connect_attribution(certificate, client_id, proof, challenge, now) do
        {:ok, row} -> attributed_connect(row, certificate, client_id, source, now)
        :not_the_clients -> unattributed_connect(certificate, client_id, source, now)
        {:unattributed, refused} -> unattributed(:device_connect, source, refused)
        {:error, :unavailable} = unanswered -> unanswered
      end
    end
  end

  def verify_connect(%{client_id: client_id} = connection, proof, %Challenge{purpose: :renew} = c)
      when is_binary(client_id) do
    now = now_ms()
    source = Map.get(connection, :source)

    with :ok <- source_room(:device_verification, source) do
      case renewal_attribution(c, client_id, proof, now) do
        {:ok, row} -> attributed_renewal(row, source)
        {:unattributed, refused} -> unattributed(:device_verification, source, refused)
        {:error, :unavailable} = unanswered -> unanswered
      end
    end
  end

  def verify_connect(_connection, _proof, _challenge), do: {:error, :proof_refused}

  # A connect is the named client's once its proof, made by the device key
  # the challenge names over the challenge held for it, shows that key is
  # the one the client's row stores. A proof or a challenge that fails
  # first is no one's, refused with its own word; one the client's row
  # does not stand behind is no one's either (`:not_the_clients`).
  defp connect_attribution(certificate, client_id, proof, challenge, now) do
    with :ok <- held(challenge, client_id, certificate),
         :ok <- possession(proof, challenge, now),
         :ok <- names_client(certificate, %{client_id: client_id}) do
      case attribution(certificate.athanor, client_id, challenge.device_key) do
        {:ok, row} -> {:ok, row}
        {:unattributed, _row_says} -> :not_the_clients
        {:error, :unavailable} -> {:error, :unavailable}
      end
    else
      {:error, refused} -> {:unattributed, refused}
    end
  end

  # A connect no client's row stands behind is counted against the address
  # and the installation first, so past either bound it is refused having
  # cost nothing more. Under them it is answered the word its certificate's
  # own check gives, as every connect is checked.
  defp unattributed_connect(certificate, client_id, source, now) do
    case claim_unattributed(:device_connect, source) do
      {:error, {:rate_limited, _retry_after_ms}} = spent -> spent
      _counted -> checked_request(certificate, %{client_id: client_id}, now, client_ip: source)
    end
  end

  # The client's own connect budget is read before its certificate is
  # checked, and counts only a failure: a paired device reconnecting is
  # no guess. The row read to attribute the connect only attributes it:
  # its standing is read again once the certificate is checked.
  defp attributed_connect(row, certificate, client_id, source, now) do
    name = {:client, row.id}

    with :ok <- device_bound(named_room(:device_connect, name)) do
      case checked_request(certificate, %{client_id: client_id}, now, client_ip: source) do
        {:ok, ctx} ->
          {:ok, ctx}

        # A store or an account that could not be read is no failed proof.
        {:error, reason} = unanswered when reason in [:unavailable, :identity_stale] ->
          unanswered

        {:error, refused} ->
          case device_bound(claim_named(:device_connect, name)) do
            {:error, {:device_rate_limited, _retry_after_ms}} = spent -> spent
            _counted -> {:error, refused}
          end
      end
    end
  end

  # A renewal is the named client's once its proof shows the device key
  # the client's row stores; the certificate the device brought only
  # located the client.
  defp renewal_attribution(%Challenge{} = challenge, client_id, proof, now) do
    with :ok <- renewal_held(challenge, client_id),
         :ok <- possession(proof, challenge, now) do
      attribution(challenge.athanor, client_id, challenge.device_key)
    else
      {:error, refused} -> {:unattributed, refused}
    end
  end

  # Counted against the client's own budget before anything more is read;
  # the account's head is read before the client again, so a walk that
  # retired the client is seen.
  defp attributed_renewal(row, source) do
    with :ok <- device_bound(claim_named(:device_verification, {:client, row.id})),
         {:ok, identifier} <- identifier(row.user_id),
         :ok <- fresh(identifier),
         {:ok, row} <- paired_client(row.athanor_id, row.user_id, row.id),
         {:ok, standing} <- standing(row.user_id, row.athanor_id) do
      established(row, standing, nil, identifier, client_ip: source)
    end
  end

  # The client `client_id` names in `athanor_id`, read at any standing,
  # and whether `device_key`, which a verified proof was just made by, is
  # the key its row stores: only then is the attempt that client's.
  # Otherwise answers the refusal the row itself gives.
  defp attribution(athanor_id, client_id, device_key)
       when is_binary(athanor_id) and athanor_id != "" and is_binary(client_id) and
              is_binary(device_key) do
    case Arca.PairedClients.list(Prima.Actor.in_athanor(athanor_id), standing: :all) do
      {:ok, rows} ->
        case Enum.find(rows, &(&1.id == client_id)) do
          %{device_public_key: ^device_key} = row ->
            {:ok, row}

          nil ->
            {:unattributed, :not_standing}

          row ->
            case row_standing(row) do
              {:ok, _standing_row} -> {:unattributed, :proof_refused}
              {:error, refused} -> {:unattributed, refused}
            end
        end

      {:error, _unanswered} ->
        {:error, :unavailable}
    end
  end

  defp attribution(_athanor_id, _client_id, _device_key), do: {:unattributed, :not_standing}

  # The challenge the channel holds for this connect: this CYFR's, for
  # this client, bound to the certificate's athanor and to the device key
  # whose kid the certificate names.
  defp held(%Challenge{} = challenge, client_id, %DeviceCert{} = certificate) do
    if this_home?(challenge.home) and challenge.client_id == client_id and
         challenge.athanor == certificate.athanor and
         Key.kid(challenge.device_key) == certificate.kid,
       do: :ok,
       else: {:error, :proof_refused}
  end

  defp renewal_held(%Challenge{} = challenge, client_id) do
    if this_home?(challenge.home) and challenge.client_id == client_id,
      do: :ok,
      else: {:error, :proof_refused}
  end

  defp this_home?(home), do: Sanctum.SignIn.audience() == {:ok, home}

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
  """
  @spec verify_request(DeviceCert.t(), Context.t()) :: {:ok, Context.t()} | {:error, refusal()}
  def verify_request(
        %DeviceCert{} = certificate,
        %Context{auth_method: :device, authenticated: true, client_id: client_id} = ctx
      )
      when is_binary(client_id) do
    with :ok <- names_context(certificate, ctx),
         {:ok, %Context{user_id: user_id} = checked} <-
           checked_request(certificate, ctx, now_ms(),
             request_id: ctx.request_id,
             client_ip: ctx.client_ip
           ) do
      if user_id == ctx.user_id, do: {:ok, checked}, else: {:error, :client_mismatch}
    end
  end

  def verify_request(%DeviceCert{}, _not_a_device_context), do: {:error, :client_mismatch}

  # A certificate and the client it is presented for: the context's, or,
  # inside `verify_connect/3` once the proof verified, the client the
  # connection names. Private: a certificate alone proves nothing.
  #
  # The client's standing is read before the certificate is, so a revoked
  # or suspended client is told its standing ended whatever its
  # certificate's age; the account's head is read before the certificate's
  # row and the client again, so whatever its walk retires is seen.
  defp checked_request(certificate, client, now, carried) do
    with :ok <- names_client(certificate, client),
         {:ok, row} <- certified_client(certificate),
         {:ok, identifier} <- identifier(row.user_id),
         :ok <- same(identifier, certificate.identifier),
         :ok <- fresh(identifier),
         {:ok, head} <- recorded(row, certificate),
         {:ok, certificate} <- checked(certificate, head, now),
         {:ok, row} <- paired_client(row.athanor_id, row.user_id, row.id),
         {:ok, standing} <- standing(row.user_id, certificate.athanor) do
      established(row, standing, certificate, identifier, carried)
    end
  end

  # The client the certificate names, at any standing, standing and
  # holding the certificate's kid.
  defp certified_client(%DeviceCert{athanor: athanor_id, client_id: client_id, kid: kid}) do
    case Arca.PairedClients.list(Prima.Actor.in_athanor(athanor_id), standing: :all) do
      {:ok, rows} ->
        case Enum.find(rows, &(&1.id == client_id)) do
          nil ->
            {:error, :not_standing}

          row ->
            with {:ok, row} <- row_standing(row) do
              if row.kid == kid, do: {:ok, row}, else: {:error, :client_mismatch}
            end
        end

      {:error, _unanswered} ->
        {:error, :unavailable}
    end
  end

  defp same(value, value), do: :ok
  defp same(_value, _other), do: {:error, :client_mismatch}

  # The context names the certificate's client and athanor and was
  # established under this certificate (its deadline is the certificate's
  # expiry), or is the renewal exchange's, established under none.
  defp names_context(%DeviceCert{} = certificate, %Context{} = ctx) do
    deadline = ctx.credential_deadline

    if ctx.client_id == certificate.client_id and ctx.athanor_id == certificate.athanor and
         is_binary(ctx.user_id) and
         (is_nil(deadline) or DateTime.to_unix(deadline, :millisecond) == certificate.expires_at),
       do: :ok,
       else: {:error, :client_mismatch}
  end

  defp names_client(%DeviceCert{client_id: id}, %{client_id: id}), do: :ok
  defp names_client(%DeviceCert{}, _client), do: {:error, :client_mismatch}

  # The account the person's identity row names.
  defp identifier(user_id) do
    case Arca.PersonIdentities.get(Prima.Actor.system(), user_id) do
      {:ok, %{identifier: identifier}} when is_binary(identifier) -> {:ok, identifier}
      {:ok, _none} -> {:error, :not_standing}
      {:error, :not_found} -> {:error, :not_standing}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  # The account's head within freshness's policy: a refresh walks the
  # entries after the cached head before it answers, so a key it removes
  # or a recovery has retired its bindings by now.
  defp fresh(identifier) do
    case Sanctum.IdentityFreshness.fresh?(identifier) do
      {:ok, _head} -> :ok
      {:refused, :identity_stale} -> {:error, :identity_stale}
      {:refused, _gone} -> {:error, :not_standing}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  # The head the certificate's own row names: the row this CYFR recorded
  # when it issued these bytes, read now, so one revoked since stands for
  # nothing and one never recorded here is no certificate of this CYFR's.
  defp recorded(row, %DeviceCert{} = certificate) do
    digest = Prima.Digest.sha256(Encoding.jcs!(DeviceCert.encode(certificate)))

    case Arca.DeviceCertificates.list(Prima.Actor.in_athanor(row.athanor_id),
           paired_client_id: row.id,
           status: :all
         ) do
      {:ok, rows} ->
        case Enum.find(rows, &(&1.digest == digest)) do
          %{status: "active", head: head} -> {:ok, head}
          %{status: "expired"} -> {:error, :expired}
          %{status: "revoked"} -> {:error, :revoked}
          nil -> {:error, :bad_signature}
        end

      {:error, _unanswered} ->
        {:error, :unavailable}
    end
  end

  # The certificate under the installation key, for this CYFR, at the head
  # its row names, within its window.
  defp checked(certificate, head, now) do
    {public, _private} = Sanctum.Cipher.installation_key()

    with {:ok, home} <- Sanctum.SignIn.audience(),
         {:ok, skew_ms} <- skew_ms() do
      case DeviceCert.verify(certificate, public,
             home: home,
             head: head,
             now: now,
             skew: skew_ms
           ) do
        {:ok, certificate} ->
          {:ok, certificate}

        {:error, reason}
        when reason in [
               :expired,
               :not_yet_valid,
               :bad_signature,
               :wrong_audience,
               :stale_head
             ] ->
          {:error, reason}

        {:error, _malformed} ->
          {:error, :bad_signature}
      end
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
  person `user_id`: `{:ok, row}` for an active device client,
  `:revoked` for a revoked one, `:not_standing` for a suspended one (a
  declared restore's) and for one this CYFR does not hold, and
  `:unavailable` when the store cannot answer.
  """
  @spec paired_client(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, :revoked | :not_standing | :unavailable}
  def paired_client(athanor_id, user_id, client_id)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(user_id) and
             is_binary(client_id) do
    filters = [user_id: user_id, standing: :all]

    case Arca.PairedClients.list(Prima.Actor.in_athanor(athanor_id), filters) do
      {:ok, rows} ->
        case Enum.find(rows, &(&1.id == client_id)) do
          nil -> {:error, :not_standing}
          row -> row_standing(row)
        end

      {:error, _unanswered} ->
        {:error, :unavailable}
    end
  end

  def paired_client(_athanor_id, _user_id, _client_id), do: {:error, :not_standing}

  # Only an active device client that is a key of the account stands. A
  # suspended one is refused as a client whose standing ended, never as
  # revoked: it stands again once re-enabled.
  defp row_standing(%{standing: "active", source_kind: "device_cert", kid: kid} = row)
       when is_binary(kid),
       do: {:ok, row}

  defp row_standing(%{standing: "revoked"}), do: {:error, :revoked}
  defp row_standing(_suspended_or_no_device), do: {:error, :not_standing}

  @doc """
  The standing of the person `user_id` in the athanor `athanor_id`, read
  now (`t:standing/0`): the person not denied, the athanor open and
  theirs (its `owner_user_id`), as an issuance holds a focus to
  (`Sanctum.Issuance`). Their mark is reported as the capability flag
  (`platform_admin`) and stands for nothing in the athanor.
  `:not_standing` otherwise, `:unavailable` when the store cannot answer.
  """
  @spec standing(String.t(), String.t()) ::
          {:ok, standing()} | {:error, :not_standing | :unavailable}
  def standing(user_id, athanor_id) when is_binary(user_id) and is_binary(athanor_id) do
    with {:ok, user} <- row(Sanctum.Tenancy.Users.get(user_id)),
         :ok <- active(user),
         {:ok, athanor} <- row(Sanctum.Tenancy.Athanors.get(athanor_id)),
         :ok <- active(athanor),
         :ok <- owned(athanor, user_id) do
      {:ok,
       %{user: user, athanor: athanor, platform_admin: Sanctum.Tenancy.platform_admin?(user)}}
    end
  end

  defp row({:ok, row}), do: {:ok, row}
  defp row({:error, :not_found}), do: {:error, :not_standing}
  defp row({:error, _unanswered}), do: {:error, :unavailable}

  defp active(%{status: "active"}), do: :ok
  defp active(_row), do: {:error, :not_standing}

  defp owned(%{owner_user_id: user_id}, user_id), do: :ok
  defp owned(_athanor, _user_id), do: {:error, :not_standing}

  @doc """
  Whether the paired client a device context names still stands: its
  certificate's deadline not passed, the paired-client row active (a
  suspended one is `:not_standing`) and the person's standing in the
  athanor (`standing/2`). For a grant decided under a paired device
  (`Sanctum.Consent.Authz.authorize/3`) and for who can confirm
  (`Sanctum.Pairing.can_confirm?/1`). Any other context stands for no
  paired client.
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
  # account it is a key of, and its person and athanor as just read, with
  # the connection's request correlation and address.
  defp established(row, standing, certificate, identifier, carried) do
    device = %{
      certificate: certificate,
      client: row,
      identifier: identifier,
      user: standing.user,
      athanor: standing.athanor,
      platform_admin: standing.platform_admin
    }

    # The rows were read as standing just now; establish refusing them is
    # a standing that no longer reads as one, but for the company sign-in,
    # which the person gives and the pairing outlives.
    case Sanctum.Caller.establish_device(device, carried) do
      {:ok, ctx} -> {:ok, ctx}
      {:error, :company_login_required} -> {:error, :company_login_required}
      {:error, _refused} -> {:error, :not_standing}
    end
  end

  # ---------------------------------------------------------------------------
  # Verification bounds
  # ---------------------------------------------------------------------------

  defp source_room(family, source) do
    key = source_key(source)

    with :ok <- node_room({family, :source, key}, @source_cap) do
      cell_room(bucket(family, :source), key, @source_cap)
    end
  end

  defp named_room(family, {kind, id}) do
    with :ok <- node_room({family, kind, id}, @name_cap) do
      cell_room(bucket(family, kind), id, @name_cap)
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

  # A proven client's own budget. Only a client an attempt proved reaches
  # this node's table, so no caller chooses how many keys it holds.
  defp claim_named(family, {:client, id}) when is_binary(id) do
    with :ok <- on_node({family, :client, id}, @name_cap) do
      in_cell(bucket(family, :client), id, @name_cap)
    end
  end

  # The source's and then the installation's bounds, this node's before
  # the cell's: past this node's installation count nothing more is
  # written, so a flood from many addresses writes at most the cap.
  defp claim_unattributed(family, source) do
    key = source_key(source)

    with :ok <- on_node({family, :source, key}, @source_cap),
         :ok <- on_node({family, :installation}, @installation_cap),
         :ok <- in_cell(bucket(family, :source), key, @source_cap) do
      in_cell(bucket(family, :installation), "installation", @installation_cap)
    end
  end

  # An attempt nothing attributed is counted and refused; one that finds
  # its bound spent says so.
  defp unattributed(family, source, refusal) do
    case claim_unattributed(family, source) do
      {:error, {:rate_limited, _retry_after_ms}} = spent -> spent
      _counted_or_unanswered -> {:error, refusal}
    end
  end

  # On the channel, a client's own spent budget is told apart from the
  # address's and the installation's.
  defp device_bound({:error, {:rate_limited, retry_after_ms}}),
    do: {:error, {:device_rate_limited, retry_after_ms}}

  defp device_bound(answer), do: answer

  # The durable buckets, spelled in code: the renewal bounds, and the
  # connect bounds beside them.
  defp bucket(:device_verification, :source), do: :device_verification_source
  defp bucket(:device_verification, :installation), do: :device_verification_installation
  defp bucket(:device_verification, :client), do: :device_verification_client
  defp bucket(:device_connect, :source), do: :device_connect_source
  defp bucket(:device_connect, :installation), do: :device_connect_installation
  defp bucket(:device_connect, :client), do: :device_connect_client

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
