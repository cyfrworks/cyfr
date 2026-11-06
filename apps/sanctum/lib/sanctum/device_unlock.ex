# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.DeviceUnlock do
  @moduledoc """
  A protected device: a device of a person's account whose key a local
  unlock guards, a TPM chip sealing it under a PIN or a passphrase-wrapped
  file. It is admitted here by its hello, unlocks into a browser session,
  and locks that session again. Every unlock and lock proof is
  `Prima.DeviceCert.Proof` over a challenge this CYFR holds in
  `Arca.Cache` and consumes at most once (`tests/fixtures/device_unlock.json`).
  A challenge a member does not hold (a cache lost or another member's) is
  refused and asked again, never skipped. Every fresh challenge expires
  60 seconds after the database's clock read when it was issued, and is
  refused at that instant. The PIN or passphrase never reaches this CYFR.

  ## The hello

  A device's first connection here (`ARCHITECTURE.md` §9.3) names the key
  it holds (`kid`), the account it is a key of (`identifier`), what holds
  the key (`holder_kind`) and the name it shows (`display_name`), each in
  `Prima.Device`'s grammar, and, when it comes with one, the capability
  that admits a new person: the setup token or an invitation's code.
  `hello/2` answers a `sign_in` request (`Prima.SignIn`) bound to the
  channel that asked, by the client id it reserved for the device, and
  held for the key, holder and name the hello named
  (`Sanctum.SignIn.request/3`); a setup token that is not this CYFR's, or
  an invitation code that names none, is refused before anything is held.
  The device signs the request's digest after its local unlock, and
  `admit/2` takes the answer: `Sanctum.SignIn.answer/3` spends the request
  and verifies the answer against the account's log, by the key the hello
  named, then admits the person: a new one under the capability or the
  door (`Sanctum.Newcomer.admit/3`), one this CYFR holds by the door's
  verdict. The device is paired in the same transaction as a new person's
  admission, right after the door's verdict for a person this CYFR holds
  (`pair/4`): the paired client, a key of the account at the head the
  answer was verified under, with the holder and name its hello reported,
  and its first certificate
  (`Sanctum.DeviceCerts.issue/2`), under the issuance fence. A device
  whose key already stands here as an active client of the person is
  answered a new certificate for that client instead, so a hello asked
  again pairs nothing twice. A capability that admits nobody writes
  nothing. `admit/2` answers the paired client's id, its certificate and
  its standing; from then on the device connects with that certificate
  (`Sanctum.DeviceCerts`).

  ## Unlock and lock

  Through the device channel only (`auth_method: :device`):
  `unlock/2` with no proof answers an `unlock` challenge reserving one
  session id, and reserves that session as a row no token loads, expiring
  with the challenge (`Arca.SessionStorage.reserve_client_session/2`),
  from the moment the id leaves this CYFR; with the proof over it, while
  that row still stands, a 32-byte single-use ticket, held 60 seconds with
  the reserved session, the client and the issuance expectation the
  channel's context read, and the row carried to the ticket's deadline.
  `redeem/1`, the browser's exchange, spends the ticket once and
  activates that row (`Sanctum.Session.create_unlocked/1`) in the issuance
  transaction that rereads the person, athanor, client and certificate the
  expectation names, under the client's lock and then the row's. The
  ticket is bearer authority for this brief exchange alone; a ticket this
  member's cache no longer holds redeems nothing.

  The session expires 60 seconds after the database's clock, never past
  the certificate, and only the device channel's standing check moves it
  (`slide/2`); a browser's sliding refresh never does, and nothing revives
  an expired one. `lock/2` takes the `lock` proof the device signed at
  unlock for exactly that session: it needs no freshness, deletes that
  session's row, reserved or active, under the client's lock, and a
  repeat answers the same and ends nothing else. A redemption after it
  finds no reservation and refuses, so no cookie escapes a lock, whatever
  a cache holds. `closed/3` is the channel's end: its sessions and
  reservations go with it. A channel that dies without closing leaves
  them to their expiry.

  A device confirms a pending change by answering this CYFR's `confirm`
  request over its channel (`Sanctum.Providers.Confirmation`).
  """

  require Logger

  alias Prima.DeviceCert.{Challenge, Proof}
  alias Prima.Identity.{Encoding, Key}
  alias Sanctum.Context

  @ticket_bytes 32
  @lifetime_ms 60_000

  @typedoc """
  What a hello names (the module doc): the device's key, the account it is
  a key of, what holds the key and the name it shows, and the capability
  a new person comes in under, when it brings one.
  """
  @type hello :: %{
          required(:kid) => String.t(),
          required(:identifier) => String.t(),
          required(:holder_kind) => String.t(),
          required(:display_name) => String.t(),
          optional(:admission) => {:setup, String.t()} | {:invitation, String.t()} | nil
        }

  @typedoc """
  The device a hello pairs (`pair/4`): the client id the channel reserved
  for it, what holds its key and the name it shows.
  """
  @type device :: %{client_id: String.t(), holder_kind: String.t(), display_name: String.t()}

  @typedoc "What `admit/2` answers: the paired client, its certificate and its standing."
  @type admitted :: %{
          client_id: String.t(),
          certificate: Prima.DeviceCert.t(),
          standing: %{client_id: String.t(), athanor: String.t(), expires_at: pos_integer()}
        }

  @doc "How long a ticket and a fresh challenge live, and a session lasts unslid, in ms."
  @spec lifetime_ms() :: pos_integer()
  def lifetime_ms, do: @lifetime_ms

  # ===========================================================================
  # The hello
  # ===========================================================================

  @doc """
  Answer a device's hello on the channel that reserved `client_id` for it
  with a `sign_in` request held for that channel and the hello's key (the
  module doc). Refusals: `:setup_closed` (a setup token that is not this
  CYFR's), `:invitation_invalid` (an invitation code that names none),
  `{:invalid_argument, sentence}`, `:no_directory`, `:unavailable`.
  """
  @spec hello(String.t(), hello()) :: {:ok, Prima.SignIn.t()} | {:error, term()}
  def hello(
        "pcl_" <> _ = client_id,
        %{kid: kid, identifier: identifier, holder_kind: holder_kind, display_name: name} = hello
      ) do
    with :ok <- named(kid, identifier, holder_kind, name),
         {:ok, admission} <- admission(Map.get(hello, :admission)),
         {:ok, %{request: request}} <-
           Sanctum.SignIn.request(:sign_in, {:channel, client_id},
             identifier: identifier,
             kid: kid,
             holder_kind: holder_kind,
             display_name: name,
             admission: admission
           ) do
      {:ok, request}
    end
  end

  def hello(_client_id, _hello), do: unnamed()

  defp named(kid, identifier, holder_kind, name) do
    if Encoding.digest?(kid) and Encoding.identifier?(identifier) and
         holder_kind in Prima.Device.holder_kinds() and Prima.Device.display_name?(name),
       do: :ok,
       else: unnamed()
  end

  defp unnamed,
    do:
      {:error, {:invalid_argument, "A hello names its key, its account, its holder and its name"}}

  # A capability that admits nobody refuses here, before anything is held.
  defp admission(nil), do: {:ok, nil}

  defp admission({:setup, token} = admission) do
    if Sanctum.Newcomer.setup_token?(token), do: {:ok, admission}, else: {:error, :setup_closed}
  end

  defp admission({:invitation, code}) do
    with {:ok, hash} <- Sanctum.Invitations.code_hash(code),
         :ok <- Sanctum.Invitations.redeemable_hash(hash) do
      {:ok, {:invitation, hash}}
    end
  end

  defp admission(_other),
    do: {:error, {:invalid_argument, "A hello comes with the setup token or an invitation"}}

  @doc """
  Take the device's answer to the request its hello was answered, on the
  channel that reserved `client_id` (the module doc): admit the person,
  pair the device and issue its first certificate. Answers
  `t:admitted/0`. Refusals: `Sanctum.SignIn.answer/3`'s, among them
  `:answer_refused`, `:identity_stale`, `:identity_gone`, `:stale_head`,
  `{:door, reason}`, `:invitation_invalid`, `:setup_closed`, and
  `:unavailable`.
  """
  @spec admit(String.t(), Prima.SignIn.DeviceAnswer.t() | map()) ::
          {:ok, admitted()} | {:error, term()}
  def admit("pcl_" <> _ = client_id, answer) do
    with {:ok, answer} <- device_answer(answer),
         {:ok, %{purpose: :sign_in, user: user, kid: kid}} <-
           Sanctum.SignIn.answer(answer, {:channel, client_id}) do
      paired(user.id, kid)
    end
  end

  def admit(_client_id, _answer), do: {:error, :answer_refused}

  defp device_answer(%Prima.SignIn.DeviceAnswer{} = answer), do: {:ok, answer}

  defp device_answer(map) do
    case Prima.SignIn.DeviceAnswer.decode(map) do
      {:ok, answer} -> {:ok, answer}
      {:error, _malformed} -> {:error, :answer_refused}
    end
  end

  @doc false
  # Inside a new person's admission (`Sanctum.Newcomer.admit/3`), or right
  # after the door admitted a person this CYFR holds (`Sanctum.SignIn`):
  # the device `key` of `person`'s account, verified at `head`, paired in
  # the person's athanor under the client id the channel reserved, with
  # the holder and name its hello reported (`t:device/0`), and its first
  # certificate, in one transaction; or, where the key already stands as
  # an active client of theirs there, a new certificate for that client.
  @spec pair(map(), device(), Key.t(), String.t()) :: :ok | {:error, term()}
  def pair(
        %{id: user_id},
        %{client_id: client_id, holder_kind: holder_kind, display_name: display_name},
        %Key{kind: :device, kid: kid, pub: pub},
        head
      ) do
    with {:ok, athanor_id} <- athanor(user_id) do
      actor = Prima.Actor.in_athanor(athanor_id)

      case standing_client(actor, user_id, kid) do
        {:ok, %{} = client} ->
          issued(Sanctum.DeviceCerts.issue(client, head))

        {:ok, nil} ->
          actor
          |> Arca.PairedClients.enroll(
            %{
              id: client_id,
              user_id: user_id,
              source_kind: "device_cert",
              source_id: client_id,
              device_public_key: pub,
              holder_kind: holder_kind,
              display_name: display_name,
              kid: kid,
              head: head
            },
            also: &Sanctum.DeviceCerts.issue(&1, head)
          )
          |> issued()

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp issued({:ok, _issued}), do: :ok
  defp issued({:error, :conflict}), do: {:error, :answer_refused}
  defp issued({:error, :database_error}), do: {:error, :unavailable}
  defp issued({:error, {:invalid, _errors}}), do: {:error, :unavailable}
  defp issued({:error, reason}), do: {:error, reason}

  defp athanor(user_id) do
    case Arca.Athanors.get_by_owner(Prima.Actor.system(), user_id) do
      {:ok, %{id: athanor_id}} -> {:ok, athanor_id}
      {:error, :not_found} -> {:error, :not_standing}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  # The person's active device client in the athanor that is this key.
  defp standing_client(actor, user_id, kid) do
    case Arca.PairedClients.list(actor, user_id: user_id, standing: :active) do
      {:ok, rows} ->
        {:ok, Enum.find(rows, &(&1.source_kind == "device_cert" and &1.kid == kid))}

      {:error, _unanswered} ->
        {:error, :unavailable}
    end
  end

  # The client the hello paired, by its key, and its newest certificate,
  # as recorded and signed.
  defp paired(user_id, kid) do
    with {:ok, athanor_id} <- athanor(user_id),
         actor = Prima.Actor.in_athanor(athanor_id),
         {:ok, %{} = client} <- standing_client(actor, user_id, kid),
         {:ok, %{certificate: bytes}} <- Arca.DeviceCertificates.current(actor, client.id),
         {:ok, map} <- Jason.decode(bytes),
         {:ok, certificate} <- Prima.DeviceCert.decode(map) do
      {:ok,
       %{
         client_id: client.id,
         certificate: certificate,
         standing: %{
           client_id: client.id,
           athanor: athanor_id,
           expires_at: certificate.expires_at
         }
       }}
    else
      {:ok, nil} -> {:error, :unavailable}
      {:error, reason} when reason in [:not_standing, :unavailable] -> {:error, reason}
      _damaged_or_unanswered -> {:error, :unavailable}
    end
  end

  # ===========================================================================
  # Unlock, redemption and lock
  # ===========================================================================

  @doc """
  The device channel's unlock (the module doc): without a proof an
  `unlock` challenge reserving one session id, `%{challenge}`; with
  `"proof"` alone, `%{ticket, session_id, expires_at}`, the ticket's
  deadline in ms. Refusals: `:not_a_device`, `:no_holder`,
  `:proof_refused`, `:session_retired` (a lock or the channel's end retired
  the reserved session before the proof), `:invalid_request`,
  `:not_standing` and `:unavailable`.
  """
  @spec unlock(Context.t(), map()) :: {:ok, map()} | {:error, atom()}
  def unlock(%Context{} = ctx, args) when is_map(args) do
    with {:ok, client} <- holder(ctx) do
      case args do
        empty when map_size(empty) == 0 -> unlock_challenge(ctx, client)
        %{"proof" => proof} when map_size(args) == 1 -> ticket(ctx, proof)
        _other -> {:error, :invalid_request}
      end
    end
  end

  def unlock(_ctx, _args), do: {:error, :invalid_request}

  # The session id leaves this home in the challenge, so its reservation
  # stands from that moment: a lock the device signs over the id before
  # its unlock proof arrives deletes the row, and the proof then finds none.
  defp unlock_challenge(ctx, client) do
    with {:ok, now} <- db_now_ms(),
         {:ok, challenge} <-
           fresh(:unlock, ctx, client, now, session_id: Prima.UUID7.generate_id("ses")),
         :ok <- reserve(ctx, challenge.session_id, challenge.expires_at) do
      hold({:device_unlock, ctx.client_id}, challenge, %{challenge: challenge}, now)
      {:ok, %{challenge: challenge}}
    end
  end

  defp ticket(ctx, proof) do
    with {:ok, held} <- take_proven({:device_unlock, ctx.client_id}, proof),
         {:ok, expectation} <- Sanctum.Issuance.expectation(ctx, []),
         {:ok, now} <- db_now_ms(),
         session_id = held.challenge.session_id,
         :ok <- still_reserved(ctx, session_id, now + @lifetime_ms) do
      ticket = :crypto.strong_rand_bytes(@ticket_bytes)

      Arca.Cache.put(
        {:device_ticket, ticket_digest(ticket)},
        %{
          session_id: session_id,
          client_id: ctx.client_id,
          user_id: ctx.user_id,
          athanor_id: ctx.athanor_id,
          email: ctx.email,
          expectation: expectation,
          deadline: ctx.credential_deadline
        },
        @lifetime_ms
      )

      {:ok,
       %{
         ticket: Encoding.b64(ticket),
         session_id: session_id,
         expires_at: now + @lifetime_ms
       }}
    end
  end

  # The session the challenge names, reserved as a row no token loads and
  # expiring with the challenge: what a lock retires.
  defp reserve(ctx, session_id, expires_at_ms) do
    case Arca.SessionStorage.reserve_client_session(session_id, %{
           client_id: ctx.client_id,
           user_id: ctx.user_id,
           email: ctx.email,
           athanor_id: ctx.athanor_id,
           expires_at: DateTime.from_unix!(expires_at_ms, :millisecond)
         }) do
      :ok -> :ok
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  # The reservation the proof answers, still standing, carried to the
  # ticket's deadline; one a lock or the channel's end retired, or that
  # expired, issues no ticket.
  defp still_reserved(ctx, session_id, until_ms) do
    case Arca.SessionStorage.hold_client_reservation(
           ctx.client_id,
           session_id,
           DateTime.from_unix!(until_ms, :millisecond)
         ) do
      :ok -> :ok
      {:error, :reservation_retired} -> {:error, :session_retired}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  @doc """
  Spend a ticket once and activate its session (the module doc): `%{token,
  expires_at}`. Refusals: `:invalid_ticket` (malformed, spent, expired,
  held by another member, or its reservation retired by a lock or the
  channel's end), `:not_standing`, `:stale_generation`, `:unauthenticated`,
  `:not_owner` and `:unavailable`.
  """
  @spec redeem(term()) :: {:ok, %{token: String.t(), expires_at: DateTime.t()}} | {:error, atom()}
  def redeem(ticket) do
    with {:ok, raw} <- ticket_bytes(ticket),
         digest = ticket_digest(raw),
         {:ok, held} <- take_ticket(digest) do
      case Sanctum.Session.create_unlocked(held) do
        {:error, :reservation_retired} -> {:error, :invalid_ticket}
        result -> result
      end
    end
  end

  defp ticket_bytes(ticket) do
    case Encoding.unb64(ticket, @ticket_bytes) do
      {:ok, raw} -> {:ok, raw}
      :error -> {:error, :invalid_ticket}
    end
  end

  defp take_ticket(digest) do
    case Arca.Cache.take({:device_ticket, digest}) do
      {:ok, held} -> {:ok, held}
      :miss -> {:error, :invalid_ticket}
    end
  end

  @doc """
  Retire the session a `lock` proof names (the module doc): `%{locked:
  true}`, also when the session is already gone. Refusals:
  `:not_a_device`, `:no_holder`, `:proof_refused`, `:invalid_request` and
  `:unavailable`.
  """
  @spec lock(Context.t(), map()) :: {:ok, %{locked: true}} | {:error, atom()}
  def lock(%Context{} = ctx, %{"proof" => proof} = args) when map_size(args) == 1 do
    with {:ok, client} <- holder(ctx),
         {:ok, presented} <- read_proof(proof),
         session_id when is_binary(session_id) <- presented.challenge.session_id || :refused,
         {:ok, held} <- lock_challenge(ctx, client, session_id),
         :ok <- verified(Proof.verify_lock(presented, held)),
         :ok <- retire(ctx.user_id, ctx.client_id, [session_id]) do
      {:ok, %{locked: true}}
    else
      :refused -> {:error, :proof_refused}
      {:error, reason} -> {:error, reason}
    end
  end

  def lock(_ctx, _args), do: {:error, :invalid_request}

  defp lock_challenge(ctx, client, session_id) do
    with {:ok, home} <- Sanctum.SignIn.audience() do
      case Challenge.new(
             purpose: :lock,
             home: home,
             athanor: ctx.athanor_id,
             client_id: ctx.client_id,
             device_key: client.device_public_key,
             session_id: session_id
           ) do
        {:ok, challenge} -> {:ok, challenge}
        {:error, _malformed} -> {:error, :proof_refused}
      end
    end
  end

  @doc """
  The device channel's standing check: slide the sessions `session_ids`
  its unlocks created to 60 seconds past the database's clock, never past
  the certificate the channel stands under (`ctx.credential_deadline`).
  Answers the ids that still stand, active or reserved. A store that
  cannot answer, or a member that lost its slot, moves none.
  """
  @spec slide(Context.t(), [String.t()]) :: {:ok, [String.t()]} | {:error, :unavailable}
  def slide(%Context{auth_method: :device, client_id: client_id} = ctx, session_ids)
      when is_binary(client_id) and is_list(session_ids) do
    cap = ctx.credential_deadline || DateTime.utc_now()

    case session_ids do
      [] ->
        {:ok, []}

      ids ->
        case Arca.SessionStorage.slide_client_sessions(client_id, ids, @lifetime_ms, cap) do
          {:ok, standing} -> {:ok, standing}
          {:error, _unanswered_or_not_owner} -> {:error, :unavailable}
        end
    end
  end

  @doc """
  The device channel's end: its sessions and reservations go with it. A store that cannot answer leaves the sessions to their
  expiry.
  """
  @spec closed(String.t(), String.t(), [String.t()]) :: :ok
  def closed(user_id, client_id, session_ids)
      when is_binary(user_id) and is_binary(client_id) and is_list(session_ids) do
    case retire(user_id, client_id, session_ids) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[Sanctum.DeviceUnlock] a closed channel's sessions are left to expire: " <>
            Prima.LoggerContext.shape(reason)
        )
    end
  end

  # The sessions' rows, reserved or active, under the client's lock, then
  # every memo of them.
  defp retire(_user_id, _client_id, []), do: :ok

  defp retire(user_id, client_id, session_ids) do
    case Arca.SessionStorage.delete_client_sessions(client_id, session_ids) do
      {:ok, []} ->
        :ok

      {:ok, hashes} ->
        Sanctum.Session.announce_revoked(user_id, hashes)

      {:error, _unanswered} ->
        {:error, :unavailable}
    end
  end

  # ===========================================================================
  # What a device reports of its disks
  # ===========================================================================

  @doc """
  Hold what the device `ctx` reports of its disks in its `capabilities`
  (`Prima.DeviceCert.Storage`) for 60 seconds, for its person's devices
  list (`storage/2`). Information, never an input to a decision. A report
  naming two states for one volume is `{:error, :contradictory}`.
  """
  @spec report_storage(Context.t(), [String.t()]) :: :ok | {:error, :contradictory}
  def report_storage(%Context{auth_method: :device} = ctx, names) when is_list(names) do
    with {:ok, storage} <- Prima.DeviceCert.Storage.read(names) do
      Arca.Cache.put({:device_storage, ctx.athanor_id, ctx.client_id}, storage, @lifetime_ms)
    end
  end

  @doc """
  What the client `client_id` of the athanor `athanor_id` last reported
  of its disks, within the last 60 seconds: `%{root, data}`, each
  `:encrypted`, `:unencrypted` or `:unknown`; both unknown when it has
  reported nothing since.
  """
  @spec storage(String.t(), String.t()) :: Prima.DeviceCert.Storage.t()
  def storage(athanor_id, client_id) do
    case Arca.Cache.get({:device_storage, athanor_id, client_id}) do
      {:ok, %{root: _, data: _} = storage} -> storage
      _none -> %{root: :unknown, data: :unknown}
    end
  end

  # ===========================================================================
  # Challenges
  # ===========================================================================

  # A protected device's own client row, as its channel's context names
  # it: a device client, which only a hello pairs.
  defp holder(%Context{auth_method: :device, authenticated: true} = ctx)
       when is_binary(ctx.client_id) and is_binary(ctx.athanor_id) do
    case Arca.PairedClients.list(Context.actor(ctx), user_id: ctx.user_id, standing: :active) do
      {:ok, rows} ->
        case Enum.find(rows, &(&1.id == ctx.client_id)) do
          %{source_kind: "device_cert"} = client -> {:ok, client}
          %{} -> {:error, :no_holder}
          nil -> {:error, :not_standing}
        end

      {:error, _unanswered} ->
        {:error, :unavailable}
    end
  end

  defp holder(%Context{}), do: {:error, :not_a_device}

  defp fresh(purpose, ctx, client, now, fields) do
    with {:ok, home} <- Sanctum.SignIn.audience() do
      case Challenge.new(
             [
               purpose: purpose,
               home: home,
               athanor: ctx.athanor_id,
               client_id: ctx.client_id,
               device_key: client.device_public_key,
               nonce: :crypto.strong_rand_bytes(Challenge.nonce_bytes()),
               now: now
             ] ++ fields
           ) do
        {:ok, challenge} -> {:ok, challenge}
        {:error, _malformed} -> {:error, :unavailable}
      end
    end
  end

  # Held under its nonce, beside what the home reads back with it, until
  # its expiry.
  defp hold(scope, challenge, held, now) do
    Arca.Cache.put({scope, challenge.nonce}, held, max(challenge.expires_at - now, 1))
  end

  # The held challenge a proof's nonce names, taken once whatever the
  # verdict, and the proof verified over it on the database's clock.
  defp take_proven(scope, proof) do
    with {:ok, presented} <- read_proof(proof),
         nonce when is_binary(nonce) <- presented.challenge.nonce || :refused,
         {:ok, now} <- db_now_ms() do
      held =
        case Arca.Cache.take({scope, nonce}) do
          {:ok, held} -> held
          :miss -> nil
        end

      with :ok <- verified(Proof.verify(presented, held && held.challenge, now)),
           do: {:ok, held}
    else
      :refused -> {:error, :proof_refused}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_proof(proof) do
    case Proof.decode(proof) do
      {:ok, proof} -> {:ok, proof}
      {:error, _malformed} -> {:error, :proof_refused}
    end
  end

  defp verified(:ok), do: :ok
  defp verified({:error, _refused}), do: {:error, :proof_refused}

  defp ticket_digest(ticket), do: :crypto.hash(:sha256, ticket)

  defp db_now_ms do
    {:ok, DateTime.to_unix(Arca.ServerMetaStorage.now!(), :millisecond)}
  rescue
    _unanswered -> {:error, :unavailable}
  end
end
