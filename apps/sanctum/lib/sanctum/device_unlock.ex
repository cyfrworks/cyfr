# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.DeviceUnlock do
  @moduledoc """
  A protected device: one whose key a local unlock guards, a TPM `chip`
  sealing it under a PIN or a passphrase-wrapped `software` file. It
  enrolls its key at an admission, unlocks into a browser session, locks
  that session again, and proves the person for one pending change. Every
  proof is `Prima.DeviceCert.Proof` over a challenge this home holds in
  `Arca.Cache` and consumes at most once (`tests/fixtures/device_unlock.json`).
  A challenge a member does not hold (a cache lost or another member's) is
  refused and asked again, never skipped. Every fresh challenge expires
  60 seconds after the database's clock read when it was issued, and is
  refused at that instant. The PIN or passphrase never reaches this home.

  ## Enrollment

  `enrollment_challenge/2` answers an `enroll` challenge for the device
  key, the request id the device drew and keeps, and the athanor and
  client id reserved for it, held with what the device reports of its
  holder. `enroll/2` takes the proof over it:

    * `{:setup, token}` admits the installation's first person, or the
      person setup made while they hold no method at this home's address
      (`Sanctum.Newcomer`): their keys, athanor, platform grant, the
      paired client under the reserved id, its first certificate, the
      first-method latch and the recovery enrollment commit together
      (`{:device, enrollment, identity}`), and the admission answers the
      certificate and the recovery code. No session is minted: the device
      unlocks for one.
    * `{:invitation, code}` and `{:open, source}` admit a new person under
      an invitation's code or the door's open admission
      (`Sanctum.Newcomer`), as setup admits its first: their keys,
      athanor, the paired client, its first certificate, the first-method
      latch and the recovery enrollment commit together, or none of them,
      and the admission answers the certificate and the recovery code. An
      invitation's challenge is held for that code alone, so a proof over
      it completes under no other. An open admission's challenges are
      counted against their source address (20 a minute) and the
      installation (200 a minute) before anything is held.
    * `{:restore, ctx}` enrolls the first method of a person a restore
      brought back, from the `restore` session that restore issued and
      within its first-method window (`Sanctum.Passkeys.first_method_session?/2`).
      The client, its certificate and the first-method latch commit
      together under the person's lock, so the window enrolls one first
      method: a passkey or another device that claimed the latch first
      refuses it (`:first_method_used`). After the window, the restore's
      reproof issues a new `restore` session (`Sanctum.Recovery`).

  `resume/2` recovers a lost answer: the request id and the key of a
  client an enrollment committed are answered an `enroll` challenge bound
  to that client, and a proof over it the client's certificate (and, for
  setup, the recovery code while it is unsaved). It takes the
  installation capability the admission did (the setup token, or the
  restore token for a restore), and the proof of the committed key, never
  the request id alone. An invitation's resume takes the code its person
  redeemed; an open admission's takes the proof alone, counted against
  its source address as its challenges are. Nothing is reopened or
  minted again.

  ## Unlock and lock

  Through the device channel only (`auth_method: :device`) and only for a
  client that reports a holder: `unlock/2` with no proof answers an
  `unlock` challenge reserving one session id, and reserves that session
  as a row no token loads, expiring with the challenge
  (`Arca.SessionStorage.reserve_client_session/2`), from the moment the
  id leaves this home; with the proof over it, while that row still
  stands, a 32-byte single-use ticket, held 60 seconds with the reserved
  session, the client and the issuance expectation the channel's context
  read, and the row carried to the ticket's deadline. `redeem/1`, the browser's exchange, spends the ticket once and
  activates that row (`Sanctum.Session.create_unlocked/1`) in the
  issuance transaction that rereads the person, athanor, seat, client
  and certificate the expectation names, under the client's lock and
  then the row's. The ticket is bearer authority for this brief exchange
  alone; a ticket this member's cache no longer holds redeems nothing.

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

  ## Confirmation

  `confirm_challenge/2` answers a `confirm` challenge for one pending
  confirmation of the device's person: its public ref and stored digest,
  expiring no later than the record. `confirm_proof/3` verifies the proof
  over it for `Sanctum.Consent.Authz`, which records the client as the
  confirmer.
  """

  require Logger

  alias Prima.DeviceCert
  alias Prima.DeviceCert.{Challenge, Proof}
  alias Prima.Identity.Encoding
  alias Sanctum.{Context, Person}

  @ticket_bytes 32
  @lifetime_ms 60_000
  @max_display_name 64
  @holder_kinds ~w(chip software)

  # An open admission's challenges and resumes, per source address and for
  # the installation, in a minute.
  @window_ms 60_000
  @open_source_cap 20
  @open_installation_cap 200

  @typedoc """
  What admits an enrollment: the setup token, a restore's session, an
  invitation's code, or the door's open admission from a source address
  (nil where the ingress knew none).
  """
  @type admission ::
          {:setup, String.t()}
          | {:restore, Context.t()}
          | {:invitation, String.t()}
          | {:open, String.t() | nil}

  @typedoc "The capability a resume takes: the admission's own, or an open one's address."
  @type capability ::
          {:setup, String.t()}
          | {:restore, String.t()}
          | {:invitation, String.t()}
          | {:open, String.t() | nil}

  @typedoc "An enrollment the device proved, as `Sanctum.Newcomer` writes it."
  @type enrollment :: %{
          required(:athanor_id) => String.t(),
          required(:client_id) => String.t(),
          required(:device_key) => binary(),
          required(:request_id) => String.t(),
          required(:holder_kind) => String.t(),
          required(:display_name) => String.t(),
          required(:user_id) => String.t() | nil
        }

  @doc "How long a ticket and a fresh challenge live, and a session lasts unslid, in ms."
  @spec lifetime_ms() :: pos_integer()
  def lifetime_ms, do: @lifetime_ms

  # ===========================================================================
  # Enrollment
  # ===========================================================================

  @doc """
  An `enroll` challenge (the module doc). `params`: `"admission"`
  (`"setup"`, `"restore"`, `"invitation"` or `"open"`, the credential's),
  `"device_key"`, `"request_id"`, `"holder_kind"` and `"display_name"`.
  Refusals: `:setup_closed`, `:invalid_request`, `:first_method_used`,
  `:not_restored`, `:invitation_invalid`, `{:door, reason}`,
  `:no_directory`, `{:rate_limited, seconds}` and `:unavailable`.
  """
  @spec enrollment_challenge(admission(), map()) ::
          {:ok, %{challenge: Challenge.t()}} | {:error, atom()}
  def enrollment_challenge(admission, params) when is_map(params) do
    with {:ok, reported} <- reported(params, kind(admission)),
         {:ok, binding} <- enrollment_binding(admission),
         {:ok, now} <- db_now_ms() do
      issue_enroll(
        %{
          admission: kind(admission),
          athanor: binding.athanor_id,
          client_id: Prima.UUID7.generate_id("pcl"),
          request_id: reported.request_id,
          device_key: reported.device_key
        },
        Map.merge(reported, %{
          user_id: binding.user_id,
          kind: kind(admission),
          admitter: admitter(admission)
        }),
        now
      )
    end
  end

  def enrollment_challenge(_admission, _params), do: {:error, :invalid_request}

  @doc """
  Enroll the device whose proof answers a held `enroll` challenge (the
  module doc). `params`: `"proof"`, and for setup the new person's
  `"name"` and `"recovery_secret"` (`Sanctum.Newcomer.identity/1`; the
  request id is the challenge's), as for an invitation and an open
  admission. Answers `%{certificate, recovery}`, the recovery absent for a
  restore. Refusals: `:proof_refused`, `:setup_closed`,
  `:first_method_used`, `:not_restored`, `{:invalid_argument, sentence}`,
  `:invalid_request`, `:unavailable` and the admission's own
  (`Sanctum.Newcomer`).
  """
  @spec enroll(admission(), map()) :: {:ok, map()} | {:error, term()}
  def enroll(admission, %{"proof" => proof} = params) do
    with {:ok, held} <- take_proven({:device_enroll, kind(admission)}, proof),
         :ok <- same_admitter(admission, held) do
      enrolled_by(admission, held, params)
    end
  end

  def enroll(_admission, _params), do: {:error, :invalid_request}

  defp enrolled_by({kind, _credential} = admission, held, params)
       when kind in [:setup, :invitation, :open] do
    with {:ok, identity} <-
           Sanctum.Newcomer.identity(%{
             "name" => params["name"],
             "recovery_secret" => params["recovery_secret"],
             "request_id" => held.challenge.request_id
           }),
         {:ok, admitted} <-
           Sanctum.Newcomer.admit(newcomer(admission), {:device, enrollment(held), identity}),
         {:ok, certificate} <- certificate(held.challenge.athanor, held.challenge.client_id) do
      {:ok, Map.merge(%{certificate: certificate}, Map.take(admitted, [:recovery]))}
    end
  end

  defp enrolled_by({:restore, %Context{} = ctx}, held, _params) do
    with :ok <- restore_window(ctx),
         {:ok, _client} <-
           write_enrolled(held.challenge.athanor, ctx.user_id, enrollment(held), :claim),
         {:ok, certificate} <- certificate(held.challenge.athanor, held.challenge.client_id) do
      {:ok, %{certificate: certificate}}
    end
  end

  @doc """
  Resume an enrollment whose answer was lost (the module doc). Without a
  proof, `params` names `"admission"`, `"device_key"` and `"request_id"`
  and is answered `%{challenge}`; with `"proof"` alone, the committed
  client's `%{certificate}` and, for setup, its person's `recovery`.
  Refusals: `:invalid_token`, `:not_found`, `:proof_refused`,
  `:invalid_request` and `:unavailable`.
  """
  @spec resume(capability(), map()) :: {:ok, map()} | {:error, atom()}
  def resume(capability, params) when is_map(params) do
    with :ok <- capable(capability) do
      case params do
        %{"proof" => proof} when map_size(params) == 1 -> resumed(capability, proof)
        %{"proof" => _proof} -> {:error, :invalid_request}
        _no_proof -> resume_challenge(capability, params)
      end
    end
  end

  def resume(_capability, _params), do: {:error, :invalid_request}

  defp resume_challenge(capability, params) do
    with {:ok, key} <- device_key(params["device_key"]),
         {:ok, request_id} <- request_id(params["request_id"]),
         true <- params["admission"] == Atom.to_string(elem(capability, 0)) or :invalid,
         {:ok, client} <- enrolled_client(request_id, key),
         :ok <- admitted_by(capability, client),
         {:ok, now} <- db_now_ms() do
      issue_enroll(
        %{
          admission: elem(capability, 0),
          athanor: client.athanor_id,
          client_id: client.id,
          request_id: request_id,
          device_key: key
        },
        %{user_id: client.user_id, kind: {:resume, elem(capability, 0)}},
        now
      )
    else
      :invalid -> {:error, :invalid_request}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resumed({kind, _token}, proof) do
    with {:ok, held} <- take_proven({:device_enroll, {:resume, kind}}, proof),
         {:ok, certificate} <- certificate(held.challenge.athanor, held.challenge.client_id) do
      if kind in [:setup, :invitation, :open] do
        case Sanctum.Recovery.admission_recovery(held.user_id) do
          {:ok, nil} -> {:ok, %{certificate: certificate}}
          {:ok, recovery} -> {:ok, %{certificate: certificate, recovery: recovery}}
          {:error, _unanswered} -> {:error, :unavailable}
        end
      else
        {:ok, %{certificate: certificate}}
      end
    end
  end

  @doc false
  # Inside a setup admission's transaction (`Sanctum.Newcomer`), after the
  # person's keys and athanor: the device's client under the reserved id
  # in the athanor reserved for it, its first certificate and the
  # first-method mark, set if not set before.
  @spec enrolled(map(), enrollment()) :: :ok | {:error, term()}
  def enrolled(%{id: user_id}, %{} = enrollment) do
    case write_enrolled(enrollment.athanor_id, user_id, enrollment, :mark) do
      {:ok, _client} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # The reserved athanor is the person's own: a readmission whose person's
  # athanor is another refuses, and the device asks again.
  defp write_enrolled(athanor_id, user_id, enrollment, first_method) do
    actor = Prima.Actor.in_athanor(athanor_id)

    with :ok <- own_athanor(user_id, athanor_id) do
      actor
      |> Arca.PairedClients.enroll(
        %{
          id: enrollment.client_id,
          user_id: user_id,
          source_kind: "device_cert",
          source_id: enrollment.request_id,
          device_public_key: enrollment.device_key,
          holder_kind: enrollment.holder_kind,
          display_name: enrollment.display_name
        },
        first_method: first_method,
        also: &Sanctum.Pairing.certify_first(actor, &1)
      )
      |> case do
        {:ok, client} -> {:ok, client}
        {:error, :first_method_used} -> {:error, :first_method_used}
        {:error, :conflict} -> {:error, :invalid_request}
        {:error, :not_owner} -> {:error, :not_owner}
        {:error, {:invalid, _errors}} -> {:error, :invalid_request}
        {:error, :database_error} -> {:error, :unavailable}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp own_athanor(user_id, athanor_id) do
    case Arca.Athanors.get_by_owner(Prima.Actor.system(), user_id) do
      {:ok, %{id: ^athanor_id}} -> :ok
      {:ok, _another} -> {:error, :setup_closed}
      {:error, :not_found} -> {:error, :setup_closed}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  defp enrollment(held) do
    %{
      athanor_id: held.challenge.athanor,
      client_id: held.challenge.client_id,
      device_key: held.challenge.device_key,
      request_id: held.challenge.request_id,
      holder_kind: held.holder_kind,
      display_name: held.display_name,
      user_id: held.user_id
    }
  end

  # What admits the enrollment, and the athanor it is reserved in: a new
  # one for the installation's first person, the person's own for one
  # setup readmits or a restore brought back.
  defp enrollment_binding({:setup, token}) do
    case Sanctum.Newcomer.setup_admits(token) do
      {:ok, :first} -> {:ok, %{user_id: nil, athanor_id: Prima.UUID7.generate_id("ath")}}
      {:ok, {:readmit, %{id: user_id}}} -> own_binding(user_id)
      {:error, reason} -> {:error, reason}
    end
  end

  defp enrollment_binding({:invitation, code}) do
    with :ok <- Sanctum.Newcomer.admits({:invitation, code}),
         do: {:ok, %{user_id: nil, athanor_id: Prima.UUID7.generate_id("ath")}}
  end

  defp enrollment_binding({:open, source}) do
    with :ok <- open_room(source),
         :ok <- Sanctum.Newcomer.admits(:open),
         do: {:ok, %{user_id: nil, athanor_id: Prima.UUID7.generate_id("ath")}}
  end

  defp enrollment_binding({:restore, %Context{} = ctx}) do
    with :ok <- restore_window(ctx), do: own_binding(ctx.user_id)
  end

  defp enrollment_binding(_admission), do: {:error, :invalid_request}

  defp own_binding(user_id) do
    case Arca.Athanors.get_by_owner(Prima.Actor.system(), user_id) do
      {:ok, %{id: athanor_id}} -> {:ok, %{user_id: user_id, athanor_id: athanor_id}}
      {:error, :not_found} -> {:error, :setup_closed}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  # A restore's own session, inside the first-method window it opened,
  # while no first method exists: the person the restore brought back.
  defp restore_window(%Context{provider: "restore", user_id: user_id} = ctx)
       when is_binary(user_id) do
    cond do
      not Sanctum.Passkeys.first_method_session?(ctx, user_id) ->
        {:error, :not_restored}

      true ->
        case Arca.PersonIdentities.first_method_open?(Prima.Actor.system(), user_id) do
          {:ok, true} -> :ok
          {:ok, false} -> {:error, :first_method_used}
          {:error, _unanswered} -> {:error, :unavailable}
        end
    end
  end

  defp restore_window(_ctx), do: {:error, :not_restored}

  defp same_admitter({:setup, _token}, %{user_id: _any}), do: :ok
  defp same_admitter({:open, _source}, %{user_id: nil}), do: :ok

  # An invitation's challenge completes under the code it was issued for.
  defp same_admitter({:invitation, code}, %{user_id: nil, admitter: held}) when is_binary(held) do
    case Sanctum.Invitations.code_hash(code) do
      {:ok, hash} ->
        if Plug.Crypto.secure_compare(hash, held), do: :ok, else: {:error, :proof_refused}

      {:error, _invalid} ->
        {:error, :proof_refused}
    end
  end

  defp same_admitter({:restore, %Context{user_id: user_id}}, %{user_id: user_id}), do: :ok
  defp same_admitter(_admission, _held), do: {:error, :proof_refused}

  defp kind({:setup, _token}), do: :setup
  defp kind({:restore, _ctx}), do: :restore
  defp kind({:invitation, _code}), do: :invitation
  defp kind({:open, _source}), do: :open
  defp kind(_admission), do: :none

  # What a held challenge remembers of its admitter: an invitation's code
  # hash, which its completion must name again.
  defp admitter({:invitation, code}) do
    case Sanctum.Invitations.code_hash(code) do
      {:ok, hash} -> hash
      {:error, _invalid} -> nil
    end
  end

  defp admitter(_admission), do: nil

  # The admission a new person's enrollment is admitted under.
  defp newcomer({:open, _source}), do: :open
  defp newcomer(admission), do: admission

  defp capable({:setup, token}) do
    if Sanctum.Newcomer.setup_token?(token), do: :ok, else: {:error, :invalid_token}
  end

  defp capable({:restore, token}) do
    if Sanctum.Recovery.restore_token?(token), do: :ok, else: {:error, :invalid_token}
  end

  defp capable({:invitation, code}) do
    case Sanctum.Invitations.code_hash(code) do
      {:ok, _hash} -> :ok
      {:error, _invalid} -> {:error, :invalid_token}
    end
  end

  defp capable({:open, source}), do: open_room(source)

  defp capable(_capability), do: {:error, :invalid_token}

  # An invitation's resume: the code the client's person redeemed when the
  # enrollment committed. Setup's and a restore's capability is the
  # installation's, and an open admission's resume rests on its proof.
  defp admitted_by({:invitation, code}, %{user_id: user_id}) do
    with {:ok, hash} <- Sanctum.Invitations.code_hash(code) do
      case Arca.Invitations.by_code_hash(Prima.Actor.system(), hash) do
        {:ok, %{redeemed_by: ^user_id}} -> :ok
        {:ok, _another} -> {:error, :not_found}
        {:error, :not_found} -> {:error, :not_found}
        {:error, _unanswered} -> {:error, :unavailable}
      end
    else
      {:error, _invalid} -> {:error, :invalid_token}
    end
  end

  defp admitted_by(_capability, _client), do: :ok

  # An open admission names no credential, so its calls are counted against
  # their source address and the installation, this node's count and then
  # the cell's (`Arca.RequestRateWindows`), before anything is held.
  defp open_room(source) do
    key = if is_binary(source) and source != "", do: source, else: "unknown"

    with :ok <- on_node({:device_open, :source, key}, @open_source_cap),
         :ok <- on_node({:device_open, :installation}, @open_installation_cap),
         :ok <- in_cell(:device_open_source, key, @open_source_cap) do
      in_cell(:device_open_installation, "installation", @open_installation_cap)
    end
  end

  defp on_node(key, cap) do
    case Prima.RateLimiter.check(key, cap, @window_ms) do
      :ok -> :ok
      {:deny, retry_after_s} -> {:error, {:rate_limited, retry_after_s}}
    end
  end

  defp in_cell(bucket, key, cap) do
    case Arca.RequestRateWindows.claim(Prima.Actor.system(), bucket, key, cap, @window_ms) do
      :ok ->
        :ok

      {:error, {:rate_limited, retry_after_ms}} ->
        {:error, {:rate_limited, seconds(retry_after_ms)}}

      {:error, _unanswered} ->
        {:error, :unavailable}
    end
  end

  defp seconds(ms), do: max(div(ms + 999, 1_000), 1)

  defp enrolled_client(request_id, key) do
    case Arca.PairedClients.enrolled(Prima.Actor.system(), request_id) do
      {:ok, %{standing: "active", device_public_key: stored} = client} ->
        if Plug.Crypto.secure_compare(stored, key), do: {:ok, client}, else: {:error, :not_found}

      {:ok, _not_active} ->
        {:error, :not_found}

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, _unanswered} ->
        {:error, :unavailable}
    end
  end

  # What the device reports beside its key, read as the admission takes
  # it: a setup or a restore's own word, the key, the request id it keeps,
  # and its holder and name.
  defp reported(params, admission) do
    with true <- params["admission"] == Atom.to_string(admission) or :invalid,
         {:ok, key} <- device_key(params["device_key"]),
         {:ok, request_id} <- request_id(params["request_id"]),
         true <- params["holder_kind"] in @holder_kinds or :invalid,
         true <- display_name?(params["display_name"]) or :invalid do
      {:ok,
       %{
         device_key: key,
         request_id: request_id,
         holder_kind: params["holder_kind"],
         display_name: params["display_name"]
       }}
    else
      _invalid -> {:error, :invalid_request}
    end
  end

  defp device_key(value) do
    case Encoding.unb64(value, Encoding.key_bytes()) do
      {:ok, key} -> {:ok, key}
      :error -> {:error, :invalid_request}
    end
  end

  defp request_id(value) do
    if Encoding.id?(value), do: {:ok, value}, else: {:error, :invalid_request}
  end

  defp display_name?(value),
    do: Encoding.text?(value, @max_display_name)

  defp issue_enroll(binding, held, now) do
    nonce = :crypto.strong_rand_bytes(Challenge.nonce_bytes())

    case Challenge.new(
           purpose: :enroll,
           home: Person.home(),
           athanor: binding.athanor,
           client_id: binding.client_id,
           device_key: binding.device_key,
           admission: binding.admission,
           request_id: binding.request_id,
           nonce: nonce,
           now: now
         ) do
      {:ok, challenge} ->
        hold({:device_enroll, held.kind}, challenge, Map.put(held, :challenge, challenge), now)
        {:ok, %{challenge: challenge}}

      {:error, _malformed} ->
        {:error, :invalid_request}
    end
  end

  # The certificate this home recorded for the client, as signed.
  defp certificate(athanor_id, client_id) do
    case Arca.DeviceCertificates.current(Prima.Actor.in_athanor(athanor_id), client_id) do
      {:ok, %{certificate: bytes}} ->
        with {:ok, map} <- Jason.decode(bytes),
             {:ok, certificate} <- DeviceCert.decode(map) do
          {:ok, certificate}
        else
          _damaged -> {:error, :unavailable}
        end

      {:error, _none_or_unanswered} ->
        {:error, :unavailable}
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
    case Challenge.new(
           purpose: :lock,
           home: Person.home(),
           athanor: ctx.athanor_id,
           client_id: ctx.client_id,
           device_key: client.device_public_key,
           session_id: session_id
         ) do
      {:ok, challenge} -> {:ok, challenge}
      {:error, _malformed} -> {:error, :proof_refused}
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
  # Confirmation
  # ===========================================================================

  @doc """
  A `confirm` challenge for the pending confirmation `record` (its `ref`,
  stored `digest` and `expires_at`), held for the device `ctx` names,
  expiring with the record if sooner. `{:ok, nil}` for a context that is
  not a protected device's.
  """
  @spec confirm_challenge(Context.t(), map()) :: {:ok, Challenge.t() | nil} | {:error, atom()}
  def confirm_challenge(
        %Context{auth_method: :device} = ctx,
        %{ref: ref, digest: digest} = record
      ) do
    with {:ok, client} <- holder(ctx),
         {:ok, now} <- db_now_ms(),
         {:ok, challenge} <-
           fresh(:confirm, ctx, client, now,
             ref: ref,
             digest: digest,
             not_after: DateTime.to_unix(record.expires_at, :millisecond)
           ) do
      hold({:device_confirm, ctx.client_id}, challenge, %{challenge: challenge}, now)
      {:ok, challenge}
    else
      {:error, :no_holder} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  def confirm_challenge(%Context{}, _record), do: {:ok, nil}

  @doc """
  Verify a device's proof over the `confirm` challenge it holds for the
  record `ref` with the stored `digest`, consuming the challenge. Refusals:
  `:not_a_device`, `:no_holder`, `:proof_refused` and `:unavailable`.
  """
  @spec confirm_proof(Context.t(), map(), term()) ::
          :ok | {:error, atom()}
  def confirm_proof(%Context{} = ctx, %{ref: ref, digest: digest}, proof) do
    with {:ok, _client} <- holder(ctx),
         {:ok, held} <- take_proven({:device_confirm, ctx.client_id}, proof) do
      if held.challenge.ref == ref and held.challenge.digest == digest,
        do: :ok,
        else: {:error, :proof_refused}
    end
  end

  # ===========================================================================
  # Challenges
  # ===========================================================================

  # A protected device's own client row, as its channel's context names it.
  defp holder(%Context{auth_method: :device, authenticated: true} = ctx)
       when is_binary(ctx.client_id) and is_binary(ctx.athanor_id) do
    case Arca.PairedClients.list(Context.actor(ctx), user_id: ctx.user_id, standing: :active) do
      {:ok, rows} ->
        case Enum.find(rows, &(&1.id == ctx.client_id)) do
          %{holder_kind: kind} = client when kind in @holder_kinds -> {:ok, client}
          %{} -> {:error, :no_holder}
          nil -> {:error, :not_standing}
        end

      {:error, _unanswered} ->
        {:error, :unavailable}
    end
  end

  defp holder(%Context{}), do: {:error, :not_a_device}

  defp fresh(purpose, ctx, client, now, fields) do
    case Challenge.new(
           [
             purpose: purpose,
             home: Person.home(),
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
