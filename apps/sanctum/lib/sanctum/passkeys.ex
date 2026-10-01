# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Passkeys do
  @moduledoc """
  A person's passkeys at this relying home: registration with user
  verification, sign-in by passkey as a door beside the others, and an
  assertion over a pending confirmation's digest as a fresh proof. Each is
  pinned to this home's RP ID (`rp_id/0`, the host of
  `Sanctum.Person.home/0`) and expected origin (`origin/0`, the home
  itself), and stored through `Arca.Passkeys`. WebAuthn is verified by
  `wax_`, whose calls are rescued: a malformed ceremony is a refusal,
  never a crash.

  ## Registration

  `register/2` without a credential answers the creation options: user
  verification and a discoverable credential required, attestation
  `none`, the person's passkeys here excluded, and an opaque registration
  token, a keyed digest with its expiry, that the browser hands back with
  the credential. The token's nonce is claimed once when a credential is
  stored, so one ceremony registers at most one passkey. With the
  credential, the ceremony is verified and the first of these applies:

    1. a person whose keys are at another home is refused
       `:remote_identity_unavailable`, until J.J0 installs remote
       freshness;
    2. a local person for whom no fresh method has ever existed (the
       persistent first-method mark on their identity row), signed in
       through a local door, `restore` included and a CYFR sign-in never,
       by a session created within `reauth_seconds`, registers it at once:
       the local first-method exception, announced to their other clients
       (`:passkey_registered`);
    3. a person who holds a fresh method here (an active passkey, an
       OpenID Connect door this home re-authenticates, or a verified email
       a code can reach) confirms `passkey_registration`
       (`Sanctum.Consent.Authz`), consumed with the row it opens;
    4. a person for whom no method has ever existed, on an older or
       non-local sign-in, is refused `:reauth_required`: signing in again
       reopens the exception;
    5. otherwise the credential is kept `pending`, verified and inert,
       awaiting the platform administrator (`recover_admin/2`). Revoking
       every method never reopens the exception.

  Every branch writes the credential only while the person is active and
  the credential the context holds still stands, read again under the
  person's lock in the transaction that writes it: a denial or a sign-out
  that commits between the ceremony's checks and its write leaves nothing
  behind.

  ## Confirmation

  `assert/3` proves a pending confirmation of the caller's own person: a
  WebAuthn assertion whose challenge is the 32 raw bytes of the record's
  digest (`Prima.Confirmation.digest/1`), with user verification, at this
  home's origin and RP ID, by an active passkey of that person registered
  here. The signature counter is checked as WebAuthn Level 3 §7.2 has it:
  two zero counts pass, and otherwise the count must rise. The record is
  confirmed once, naming the passkey and any paired client that gave the
  proof, so revoking either voids it.

  ## Sign-in

  `sign_in_challenge/0` and `sign_in/2` are the passkey door: an active
  passkey of an active local person, whose linked door identities or
  verified email still pass `Sanctum.Door.admit/3` (or, for a person with
  no linked door, their own id, as a restore's door entry names it),
  mints a session with provider `passkey`. The sign-in page holds the
  challenge and answers it once.
  """

  alias Prima.Identity.Encoding
  alias Sanctum.Consent.Authz
  alias Sanctum.Context

  @token_protocol "cyfr-passkey-registration/v1"
  @digest_protocol "cyfr-passkey-credential/v1"
  @nonce_bytes 16
  @nonce_window_ms 3_600_000
  @algorithms [-7, -8, -257]
  @sign_in_ms 120_000

  @typedoc "A passkey as its person and the administrator read it."
  @type listed :: %{
          id: String.t(),
          label: String.t() | nil,
          state: String.t(),
          rp_id: String.t(),
          registered_at: DateTime.t() | nil,
          activated_at: DateTime.t() | nil,
          expires_at: DateTime.t() | nil,
          registration_digest: String.t()
        }

  @typedoc """
  What a sign-in page holds between the challenge and the assertion: the
  challenge's bytes and when it expires (Unix milliseconds).
  """
  @type sign_in_challenge :: %{
          challenge: binary(),
          expires_at: non_neg_integer(),
          public_key: map()
        }

  @doc "This home's WebAuthn RP ID: the host of `Sanctum.Person.home/0`."
  @spec rp_id() :: String.t()
  def rp_id, do: Encoding.home_host(Sanctum.Person.home())

  @doc "The origin every ceremony at this home must come from: `Sanctum.Person.home/0`."
  @spec origin() :: String.t()
  def origin, do: Sanctum.Person.home()

  # ---------------------------------------------------------------------------
  # Registration
  # ---------------------------------------------------------------------------

  @doc """
  Register a passkey for the context's person (the module doc).

  `args` holds `credential` (or `"credential"`): absent, the answer is
  `%{public_key: creation_options, registration: token, expires_at:}`;
  given, it is the browser's answer to those options, the token under
  `registration` beside the WebAuthn `id`, `rawId`, `type` and `response`
  (`clientDataJSON` and `attestationObject`, unpadded base64url).

  Answers `%{status: "active", passkey: listed}`, or `%{status:
  "awaiting_administrator", passkey_id:, registration_digest:,
  expires_at:}` for a pending credential; the consent signal
  `{:error, {:confirmation_required, _}}` when a confirmation is needed;
  or a refusal: `:remote_identity_unavailable`, `:reauth_required`,
  `:registration_refused` (a ceremony that does not verify, or a token
  expired or used), `{:conflict, _}` (the credential is already here),
  `:unavailable`.
  """
  @spec register(Context.t(), map()) :: {:ok, map()} | {:error, term()}
  def register(%Context{} = ctx, args) when is_map(args) do
    with {:ok, user_id} <- registrant(ctx),
         {:ok, identity} <- identity(user_id) do
      case Map.get(args, :credential, Map.get(args, "credential")) do
        nil -> options(ctx, user_id)
        credential when is_map(credential) -> registered(ctx, identity, credential)
        _malformed -> {:error, :registration_refused}
      end
    end
  end

  defp registrant(%Context{plane: :guest}), do: {:error, :guest_plane}

  defp registrant(%Context{authenticated: true, anonymous: false, user_id: user_id} = ctx) do
    cond do
      ctx.auth_method not in [:oidc, :device] ->
        {:error, {:surface_not_permitted, ctx.auth_method}}

      Prima.PersonId.person?(user_id) ->
        {:ok, user_id}

      true ->
        {:error, :unauthenticated}
    end
  end

  defp registrant(%Context{}), do: {:error, :unauthenticated}

  # The person's identity row: a remote person's keys, and so their fresh
  # proofs, are another home's until J.J0.
  defp identity(user_id) do
    case Arca.PersonIdentities.get(Prima.Actor.system(), user_id) do
      {:ok, %{provenance: "remote"}} -> {:error, :remote_identity_unavailable}
      {:ok, identity} -> {:ok, identity}
      {:error, :not_found} -> {:error, :unavailable}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  defp options(ctx, user_id) do
    with {:ok, seconds} <- Authz.confirmation_seconds(),
         {:ok, excluded} <- live_credentials(ctx, user_id) do
      nonce = :crypto.strong_rand_bytes(@nonce_bytes)
      expires_at = now_ms() + seconds * 1000
      challenge = registration_challenge(user_id, nonce, expires_at)
      {name, display} = names(user_id)

      public_key = %{
        "rp" => %{"id" => rp_id(), "name" => rp_id()},
        "user" => %{
          "id" => Encoding.b64(user_handle(user_id)),
          "name" => name,
          "displayName" => display
        },
        "challenge" => Encoding.b64(challenge),
        "pubKeyCredParams" => Enum.map(@algorithms, &%{"type" => "public-key", "alg" => &1}),
        "timeout" => seconds * 1000,
        "excludeCredentials" =>
          Enum.map(excluded, &%{"type" => "public-key", "id" => &1.credential_id}),
        "authenticatorSelection" => %{
          "residentKey" => "required",
          "requireResidentKey" => true,
          "userVerification" => "required"
        },
        "attestation" => "none"
      }

      {:ok,
       %{
         public_key: public_key,
         registration: token(nonce, expires_at),
         expires_at: DateTime.from_unix!(expires_at, :millisecond)
       }}
    end
  end

  defp registered(ctx, identity, credential) do
    user_id = identity.user_id

    with {:ok, verified} <- verify_registration(user_id, credential) do
      cond do
        is_nil(identity.first_method_at) and first_method_session?(ctx, user_id) ->
          first_method(ctx, verified, credential)

        fresh_method?(ctx) ->
          confirmed(ctx, verified, credential, [])

        is_nil(identity.first_method_at) ->
          {:error, :reauth_required}

        true ->
          pending(ctx, verified, [])
      end
    end
  end

  # The local first-method exception, stored only while the person and
  # the session it rests on still stand, read under the person's lock in
  # the write (`still_standing/1`). A method that appeared meanwhile closes
  # it: the registration then follows the ordinary rule, with the token's
  # nonce already claimed.
  defp first_method(ctx, verified, credential) do
    case store(ctx.user_id, verified, "active",
           first_method: true,
           also: fn _row -> still_standing(ctx) end
         ) do
      {:ok, row} ->
        announce(:passkey_registered, [personal_athanor(row.user_id)])
        {:ok, %{status: "active", passkey: listed(row)}}

      {:error, :first_method_used} ->
        if fresh_method?(ctx),
          do: confirmed(ctx, verified, credential, claimed: true),
          else: pending(ctx, verified, claimed: true)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A person who holds a fresh method confirms the registration; the
  # confirmation is consumed in the transaction that writes the row, after
  # the caller's standing is read again there (`Authz.consume/2`).
  defp confirmed(ctx, verified, credential, opts) do
    change = registration_change(verified, credential)

    with :ok <- Authz.check(ctx, :passkey_registration, change) do
      also = fn _row -> Authz.consume(ctx, {:passkey_registration, change}) end

      case store(ctx.user_id, verified, "active", [also: also] ++ opts) do
        {:ok, row} ->
          Authz.consumed(ctx)
          {:ok, %{status: "active", passkey: listed(row)}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # A pending credential, inert until the administrator authorizes it,
  # kept only while the person and the credential that asked still stand.
  defp pending(ctx, verified, opts) do
    with {:ok, seconds} <- Authz.confirmation_seconds() do
      expires_at = DateTime.add(DateTime.utc_now(), seconds, :second)

      case store(
             ctx.user_id,
             verified,
             "pending",
             [expires_at: expires_at, also: fn _row -> still_standing(ctx) end] ++ opts
           ) do
        {:ok, row} ->
          {:ok,
           %{
             status: "awaiting_administrator",
             passkey_id: row.id,
             registration_digest: row.registration_digest,
             expires_at: row.expires_at
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # What confirming a registration approves: this exact credential, named
  # in the preview by the start of its id.
  defp registration_change(verified, credential) do
    %{
      operation: "passkey.register",
      arguments: %{"credential" => credential},
      resource: "passkey " <> String.slice(verified.credential_id, 0, 16),
      details: %{"registration_digest" => verified.registration_digest}
    }
  end

  # The token's nonce is claimed once, whichever standing the credential is
  # stored at (`claimed: true` when this ceremony already claimed it); then
  # the row.
  defp store(user_id, verified, state, opts) do
    with :ok <- if(Keyword.get(opts, :claimed, false), do: :ok, else: claim_nonce(verified)) do
      attrs = %{
        user_id: user_id,
        credential_id: verified.credential_id,
        rp_id: rp_id(),
        relying_home: origin(),
        public_key: verified.public_key,
        sign_count: verified.sign_count,
        registration_digest: verified.registration_digest,
        possession_verified: true,
        state: state,
        expires_at: Keyword.get(opts, :expires_at)
      }

      arca_opts = Keyword.take(opts, [:first_method, :also])

      case Arca.Passkeys.register(Prima.Actor.system(), attrs, arca_opts) do
        {:ok, row} -> {:ok, row}
        {:error, :conflict} -> {:error, {:conflict, "This passkey is already registered here"}}
        {:error, :first_method_used} -> {:error, :first_method_used}
        {:error, :database_error} -> {:error, :unavailable}
        {:error, :not_owner} -> {:error, :unavailable}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # The window is fixed, and as wide as any token lives (`confirmation_seconds`
  # is at most an hour): a window's width is part of what it counts.
  defp claim_nonce(%{nonce: nonce}) do
    case Arca.RequestRateWindows.claim(
           Prima.Actor.system(),
           :passkey_registration_nonce,
           Encoding.b64(nonce),
           1,
           @nonce_window_ms
         ) do
      :ok -> :ok
      {:error, {:rate_limited, _retry}} -> {:error, :registration_refused}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  # A local door's session, created within `reauth_seconds` on the
  # original creation time (never the sliding expiry), is the first-method
  # exception's one ground. A CYFR sign-in never is.
  defp first_method_session?(
         %Context{auth_method: :oidc, session_token_hash: hash},
         user_id
       )
       when is_binary(hash) do
    with {:ok, %{user_id: ^user_id, provider: provider, inserted_at: %DateTime{} = at}} <-
           Arca.SessionStorage.get_session(hash),
         true <- local_door?(provider),
         {:ok, seconds} <- Authz.seconds_setting("reauth_seconds") do
      age = DateTime.diff(DateTime.utc_now(), at, :millisecond)
      age >= 0 and age <= seconds * 1000
    else
      _no -> false
    end
  end

  defp first_method_session?(%Context{}, _user_id), do: false

  # Run inside a write's transaction: the person's row locked first, the
  # head of the standing order, and read active; then the credential the
  # context holds read again under its own locks, as a sensitive change's
  # consumption reads it (`Authz.standing/1`), the athanor it focuses among
  # them. A denial or a sign-out that committed first refuses the write,
  # and one that starts after waits for it and then revokes what it wrote.
  defp still_standing(%Context{user_id: user_id} = ctx) do
    with :ok <- active_person(user_id), do: Authz.standing(ctx)
  end

  # The person `user_id`, locked in the caller's transaction and read as
  # the lock holds them.
  defp active_person(user_id) do
    _locked = Arca.DirectoryHeads.lock_person!(user_id)

    case Sanctum.Tenancy.Users.get(user_id) do
      {:ok, %{status: "active"}} -> :ok
      {:ok, _not_active} -> {:error, :not_standing}
      {:error, :not_found} -> {:error, :not_standing}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  defp local_door?(provider) when is_binary(provider) and provider != "",
    do: provider not in ["cyfr", "passkey"]

  defp local_door?(_provider), do: false

  @doc """
  Whether the context's person holds a fresh method at this home: an
  active passkey registered here, an OpenID Connect door this home can
  re-authenticate (`Sanctum.Auth.OIDC.reauth_available?/1`), or a verified
  email a one-time code can reach
  (`Sanctum.Auth.EmailVerification.code_available?/1`). The passkeys are
  read as the context's own.
  """
  @spec fresh_method?(Context.t()) :: boolean()
  def fresh_method?(%Context{user_id: user_id} = ctx) when is_binary(user_id) do
    active_here?(ctx, user_id) or Sanctum.Auth.OIDC.reauth_available?(user_id) or
      Sanctum.Auth.EmailVerification.code_available?(user_id)
  end

  defp active_here?(ctx, user_id) do
    case Arca.Passkeys.list(Context.actor(ctx), user_id, state: :active) do
      {:ok, rows} -> Enum.any?(rows, &(&1.rp_id == rp_id()))
      {:error, _unanswered} -> false
    end
  end

  defp live_credentials(ctx, user_id) do
    case Arca.Passkeys.list(Context.actor(ctx), user_id, state: :all) do
      {:ok, rows} -> {:ok, Enum.filter(rows, &(&1.state != "revoked" and &1.rp_id == rp_id()))}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  # What the authenticator shows the person: their email, or their name.
  defp names(user_id) do
    case Sanctum.Tenancy.Users.get(user_id) do
      {:ok, user} ->
        name = present(user[:email]) || present(user[:display_name]) || user_id
        {name, present(user[:display_name]) || name}

      {:error, _unanswered} ->
        {user_id, user_id}
    end
  end

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_value), do: nil

  # The WebAuthn user handle: opaque and stable per person, never their id.
  defp user_handle(user_id),
    do: :crypto.mac(:hmac, :sha256, Authz.derived_key("passkey-user-handle"), user_id)

  defp registration_challenge(user_id, nonce, expires_at) do
    :crypto.mac(
      :hmac,
      :sha256,
      Authz.derived_key("passkey-registration"),
      Encoding.jcs!(%{
        "protocol" => @token_protocol,
        "user" => user_id,
        "rp_id" => rp_id(),
        "nonce" => Encoding.b64(nonce),
        "expires_at" => expires_at
      })
    )
  end

  defp token(nonce, expires_at),
    do: Encoding.b64(Encoding.jcs!(%{"nonce" => Encoding.b64(nonce), "expires_at" => expires_at}))

  defp read_token(token) when is_binary(token) and byte_size(token) <= 256 do
    with {:ok, json} <- b64(token),
         {:ok, %{"nonce" => nonce, "expires_at" => expires_at}} <- Jason.decode(json),
         {:ok, nonce} <- Encoding.unb64(nonce, @nonce_bytes),
         true <- is_integer(expires_at) do
      {:ok, nonce, expires_at}
    else
      _malformed -> {:error, :registration_refused}
    end
  end

  defp read_token(_token), do: {:error, :registration_refused}

  defp verify_registration(user_id, credential) do
    with {:ok, nonce, expires_at} <- read_token(credential["registration"]),
         true <- expires_at > now_ms() or {:error, :registration_refused},
         {:ok, raw_id} <- b64(credential["rawId"] || credential["id"]),
         %{} = response <- credential["response"],
         {:ok, client_data} <- b64(response["clientDataJSON"]),
         {:ok, attestation} <- b64(response["attestationObject"]),
         {:ok, auth_data} <-
           wax_register(
             attestation,
             client_data,
             registration_challenge(user_id, nonce, expires_at)
           ),
         %{credential_id: ^raw_id, credential_public_key: cose_key} <-
           auth_data.attested_credential_data do
      credential_id = Encoding.b64(raw_id)

      {:ok,
       %{
         credential_id: credential_id,
         public_key: :erlang.term_to_binary(cose_key),
         sign_count: auth_data.sign_count,
         nonce: nonce,
         expires_at: expires_at,
         registration_digest:
           Prima.Digest.sha256(
             Encoding.jcs!(%{
               "protocol" => @digest_protocol,
               "rp_id" => rp_id(),
               "user" => user_id,
               "credential_id" => credential_id,
               "authenticator_data" => Encoding.b64(auth_data.raw_bytes)
             })
           )
       }}
    else
      {:error, :unavailable} -> {:error, :unavailable}
      _refused -> {:error, :registration_refused}
    end
  end

  defp wax_register(attestation, client_data, challenge_bytes) do
    challenge =
      [
        origin: origin(),
        rp_id: rp_id(),
        user_verification: "required",
        attestation: "none",
        verify_trust_root: false
      ]
      |> Wax.new_registration_challenge()
      |> challenging(challenge_bytes)

    case Wax.register(attestation, client_data, challenge) do
      {:ok, {auth_data, _attestation}} -> {:ok, auth_data}
      {:error, _refused} -> {:error, :registration_refused}
    end
  rescue
    _malformed -> {:error, :registration_refused}
  end

  # The bytes a ceremony signs are this home's (a registration token's
  # keyed challenge, a confirmation's digest, a sign-in page's draw), never
  # the random ones Wax draws: set on the challenge once it is built, since
  # Wax's options type names no `bytes`.
  defp challenging(%Wax.Challenge{} = challenge, bytes) when is_binary(bytes),
    do: %{challenge | bytes: bytes}

  # ---------------------------------------------------------------------------
  # Confirmation
  # ---------------------------------------------------------------------------

  @doc """
  Prove the pending confirmation `ref` (its public ref,
  `Prima.Confirmation.ref/1`), in the context's athanor and of the
  context's own person, with the WebAuthn `assertion` (`id`, `rawId`,
  `type` and `response` with `clientDataJSON`, `authenticatorData` and
  `signature`, unpadded base64url). The record is confirmed once with
  proof `passkey`, naming the passkey and the paired client
  `ctx.client_id` names, if any.

  Answers `%{ref:, state: "confirmed", expires_at:}`, or a refusal:
  `:assertion_refused` (another challenge, origin or RP ID, no user
  verification, a bad signature, a credential not registered here or not
  this person's, or a counter that did not rise), `{:not_found,
  "confirmation", ref}`, `:remote_identity_unavailable`, and the record's
  own (`:not_pending`, `:expired`, `:revoked`).
  """
  @spec assert(Context.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def assert(%Context{} = ctx, ref, assertion) when is_binary(ref) and is_map(assertion) do
    actor = Context.actor(ctx)

    with {:ok, user_id} <- confirming_person(ctx),
         {:ok, _identity} <- identity(user_id),
         {:ok, row} <- record(actor, ref, user_id),
         {:ok, challenge} <- record_challenge(row),
         {:ok, parsed} <- parse_assertion(assertion),
         {:ok, passkey} <- credential(parsed.credential_id),
         true <- passkey.user_id == user_id or {:error, :assertion_refused},
         {:ok, sign_count} <- verify_assertion(parsed, passkey, challenge),
         :ok <- counted(passkey, sign_count),
         {:ok, confirmed} <- confirm_record(actor, ref, passkey, ctx.client_id) do
      Authz.announce(:confirmed, confirmed)
      {:ok, %{ref: confirmed.ref, state: confirmed.state, expires_at: confirmed.expires_at}}
    end
  end

  def assert(%Context{}, _ref, _assertion), do: {:error, :assertion_refused}

  defp confirming_person(%Context{plane: :guest}), do: {:error, :guest_plane}

  defp confirming_person(%Context{} = ctx) do
    if Sanctum.Pairing.can_confirm?(ctx) and is_binary(ctx.athanor_id) and ctx.athanor_id != "",
      do: {:ok, ctx.user_id},
      else: {:error, :unauthenticated}
  end

  # The record `ref` names, of this person, deciding a change at this home.
  defp record(actor, ref, user_id) do
    case Arca.PendingConfirmations.get(actor, ref) do
      {:ok, %{user_id: ^user_id} = row} ->
        if row.home == origin() and row.rp_id == rp_id(),
          do: {:ok, row},
          else: {:error, :assertion_refused}

      {:ok, _another} ->
        {:error, {:not_found, "confirmation", ref}}

      {:error, :not_found} ->
        {:error, {:not_found, "confirmation", ref}}

      {:error, _unanswered} ->
        {:error, :unavailable}
    end
  end

  # The WebAuthn challenge a record's proof signs: the raw bytes of its
  # digest, rebuilt from the stored record and held to the digest stored
  # beside it.
  defp record_challenge(row) do
    with {:ok, record} <- Arca.PendingConfirmations.confirmation(row),
         digest when digest == row.digest <- Prima.Confirmation.digest(record),
         "sha256:" <> hex <- digest do
      {:ok, Base.decode16!(hex, case: :lower)}
    else
      _damaged -> {:error, :unavailable}
    end
  end

  defp credential(credential_id) do
    case Arca.Passkeys.get_by_credential(Prima.Actor.system(), rp_id(), credential_id) do
      {:ok, %{state: "active", relying_home: home} = passkey} ->
        if home == origin(), do: {:ok, passkey}, else: {:error, :assertion_refused}

      {:ok, _pending} ->
        {:error, :assertion_refused}

      {:error, :not_found} ->
        {:error, :assertion_refused}

      {:error, _unanswered} ->
        {:error, :unavailable}
    end
  end

  defp confirm_record(actor, ref, passkey, client_id) do
    case Arca.PendingConfirmations.confirm(actor, ref, %{
           proof: "passkey",
           passkey_id: passkey.id,
           client_id: client_id
         }) do
      {:ok, row} -> {:ok, row}
      {:error, :database_error} -> {:error, :unavailable}
      {:error, :not_owner} -> {:error, :unavailable}
      {:error, :not_found} -> {:error, {:not_found, "confirmation", ref}}
      {:error, reason} -> {:error, reason}
    end
  end

  # WebAuthn Level 3 §7.2 step 22: two zero counts pass (an authenticator
  # that keeps no counter, whose replay the single-use record refuses);
  # otherwise the count must rise, and the rise lands by compare-and-set.
  defp counted(%{sign_count: 0}, 0), do: :ok

  defp counted(%{sign_count: stored} = passkey, reported) when reported > stored do
    case Arca.Passkeys.record_use(Prima.Actor.system(), passkey.id, stored, reported) do
      {:ok, _row} -> :ok
      {:error, :stale} -> {:error, :assertion_refused}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  defp counted(_passkey, _reported), do: {:error, :assertion_refused}

  defp parse_assertion(%{"response" => %{} = response} = assertion) do
    with {:ok, raw_id} <- b64(assertion["rawId"] || assertion["id"]),
         {:ok, client_data} <- b64(response["clientDataJSON"]),
         {:ok, authenticator_data} <- b64(response["authenticatorData"]),
         {:ok, signature} <- b64(response["signature"]) do
      {:ok,
       %{
         credential_id: Encoding.b64(raw_id),
         client_data: client_data,
         authenticator_data: authenticator_data,
         signature: signature
       }}
    else
      _malformed -> {:error, :assertion_refused}
    end
  end

  defp parse_assertion(_assertion), do: {:error, :assertion_refused}

  # The assertion over `challenge`, at this home, with user verification,
  # by the passkey's own key. Answers the count the authenticator reported.
  defp verify_assertion(parsed, passkey, challenge_bytes) do
    cose_key = :erlang.binary_to_term(passkey.public_key, [:safe])

    challenge =
      [
        origin: origin(),
        rp_id: rp_id(),
        user_verification: "required",
        allow_credentials: [{passkey.credential_id, cose_key}]
      ]
      |> Wax.new_authentication_challenge()
      |> challenging(challenge_bytes)

    case Wax.authenticate(
           parsed.credential_id,
           parsed.authenticator_data,
           parsed.signature,
           parsed.client_data,
           challenge,
           []
         ) do
      {:ok, auth_data} -> {:ok, auth_data.sign_count}
      {:error, _refused} -> {:error, :assertion_refused}
    end
  rescue
    _malformed -> {:error, :assertion_refused}
  end

  # ---------------------------------------------------------------------------
  # Sign-in
  # ---------------------------------------------------------------------------

  @doc """
  A sign-in challenge for the sign-in page to hold (`t:sign_in_challenge/0`):
  32 random bytes, alive two minutes, and the WebAuthn request options for
  a discoverable credential with user verification required.
  """
  @spec sign_in_challenge() :: sign_in_challenge()
  def sign_in_challenge do
    challenge = :crypto.strong_rand_bytes(32)

    %{
      challenge: challenge,
      expires_at: now_ms() + @sign_in_ms,
      public_key: %{
        "challenge" => Encoding.b64(challenge),
        "rpId" => rp_id(),
        "userVerification" => "required",
        "allowCredentials" => [],
        "timeout" => @sign_in_ms
      }
    }
  end

  @doc """
  Sign in by passkey: the WebAuthn `assertion` over the challenge the
  sign-in page held. The passkey must be active here, its person active
  and local, and one of their linked door identities, or their verified
  email, must still pass `Sanctum.Door.admit/3`, so removing someone from
  the allowlist closes this door too. Mints a session with provider
  `passkey` and answers its token and the sign-in outcome, as the device
  flow does.

  Refusals: `:assertion_refused`, `:expired`, `{:door, reason}`,
  `:remote_identity_unavailable`, `:unavailable`.
  """
  @spec sign_in(sign_in_challenge() | map(), map()) ::
          {:ok, %{session_token: String.t(), outcome: term()}} | {:error, term()}
  def sign_in(%{challenge: challenge, expires_at: expires_at}, assertion)
      when is_binary(challenge) and is_map(assertion) do
    with true <- expires_at > now_ms() or {:error, :expired},
         {:ok, parsed} <- parse_assertion(assertion),
         {:ok, passkey} <- credential(parsed.credential_id),
         {:ok, user} <- standing_person(passkey.user_id),
         {:ok, _identity} <- identity(user.id),
         {:ok, sign_count} <- verify_assertion(parsed, passkey, challenge),
         :ok <- counted(passkey, sign_count),
         :ok <- door(user) do
      session(user)
    end
  end

  def sign_in(_challenge, _assertion), do: {:error, :assertion_refused}

  defp standing_person(user_id) do
    case Sanctum.Tenancy.Users.get(user_id) do
      {:ok, %{status: "active"} = user} -> {:ok, user}
      {:ok, _denied} -> {:error, :assertion_refused}
      {:error, :not_found} -> {:error, :assertion_refused}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  # The door, asked for every door identity the person holds and for
  # their verified email: one admission suffices, a store that cannot
  # answer admits nothing. A person who holds no door identity (a restored
  # person before they link one, or one who unlinked their last door while
  # holding a passkey) is asked about by their own id
  # (`Sanctum.Door.admit_person/1`), as the door's reconciliation asks
  # about them and as unlinking a last door checks first.
  defp door(user) do
    verified =
      case user[:email_verified] do
        claim when is_boolean(claim) -> claim
        _unknown -> :unknown
      end

    with {:ok, identities} <- door_identities(user.id) do
      verdicts =
        case identities do
          [] ->
            [Sanctum.Door.admit_person(user)]

          identities ->
            asks =
              Enum.map(identities, &{&1.key, user[:email], verified}) ++
                if(verified == true, do: [{user.id, user[:email], true}], else: [])

            Enum.map(asks, fn {key, email, claim} -> Sanctum.Door.admit(key, email, claim) end)
        end

      cond do
        Enum.any?(verdicts, &match?({:ok, _admitted}, &1)) -> :ok
        Enum.member?(verdicts, {:error, :unavailable}) -> {:error, :unavailable}
        Enum.member?(verdicts, {:error, :denied}) -> {:error, {:door, :denied}}
        true -> {:error, {:door, :not_allowed}}
      end
    end
  end

  defp door_identities(user_id) do
    case Arca.Users.identities(Prima.Actor.system(), user_id) do
      {:ok, identities} -> {:ok, identities}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  defp session(user) do
    ctx =
      Context.build(
        user_id: user.id,
        email: user[:email],
        provider: "passkey",
        athanor_id: nil,
        permissions: Context.person_permissions()
      )

    with {:ok, ctx} <-
           Sanctum.Tenancy.resolve_status(%{ctx | namespace: user[:namespace]}, force: true),
         {:ok, session} <- Sanctum.Session.create(ctx) do
      {:ok,
       %{session_token: session.token, outcome: {:proceed, %{unsynced: [], probe: :skipped}}}}
    else
      {:error, :unavailable} -> {:error, :unavailable}
      {:error, _refused} -> {:error, :unavailable}
    end
  end

  # ---------------------------------------------------------------------------
  # Reading, revoking, and the administrator's recovery
  # ---------------------------------------------------------------------------

  @doc """
  The context's person's passkeys here, active and pending, oldest first
  (`t:listed/0`).
  """
  @spec list(Context.t()) :: {:ok, [listed()]} | {:error, term()}
  def list(%Context{} = ctx) do
    with {:ok, user_id} <- registrant(ctx) do
      case Arca.Passkeys.list(Context.actor(ctx), user_id, state: :all) do
        {:ok, rows} -> {:ok, for(row <- rows, row.state != "revoked", do: listed(row))}
        {:error, _unanswered} -> {:error, :unavailable}
      end
    end
  end

  @doc """
  Revoke the context person's passkey `passkey_id`: a sensitive change
  (`passkey_registration`), its confirmation consumed at once, then the
  credential revoked with the open confirmations it proved voided in one
  transaction (`Arca.Passkeys.revoke/3`), under the person's lock. The
  first-method mark stays: revoking the last passkey never reopens the
  exception.

  The last active passkey here of a person with no linked door is their
  only way in, so revoking it is refused (`{:conflict, _}`), before the
  confirmation is asked and again under the lock, where an unlinking of
  their last door serializes with it (`Sanctum.SignIn.unlink_door/2`).
  """
  @spec revoke(Context.t(), String.t()) :: {:ok, listed()} | {:error, term()}
  def revoke(%Context{} = ctx, passkey_id) when is_binary(passkey_id) do
    with {:ok, user_id} <- registrant(ctx),
         {:ok, passkey} <- own(ctx, user_id, passkey_id),
         :ok <- leaves_a_way_in(ctx, user_id, passkey, passkey.state),
         :ok <-
           Authz.confirm(ctx, :passkey_registration, %{
             operation: "passkey.revoke",
             arguments: %{"passkey_id" => passkey_id},
             resource: passkey.label || "passkey " <> String.slice(passkey.credential_id, 0, 16)
           }) do
      also = fn %{passkey: revoked, was: was} -> leaves_a_way_in(ctx, user_id, revoked, was) end

      case Arca.Passkeys.revoke(Context.actor(ctx), passkey_id, also: also) do
        {:ok, %{passkey: row}} -> {:ok, listed(row)}
        {:error, {:conflict, _sentence} = refusal} -> {:error, refusal}
        {:error, reason} when reason in [:database_error, :unavailable] -> {:error, :unavailable}
        {:error, _gone} -> {:error, {:not_found, "passkey", passkey_id}}
      end
    end
  end

  # Revoking `passkey`, which stood `was`, leaves the person a way to sign
  # in here: a linked door, or another active passkey at this RP ID. Only
  # an active passkey here was a way in, so revoking a pending one, or one
  # pinned elsewhere, takes none away.
  defp leaves_a_way_in(ctx, user_id, passkey, "active") do
    if passkey.rp_id == rp_id() do
      with {:ok, []} <- door_identities(user_id),
           {:ok, []} <- other_active(ctx, user_id, passkey.id) do
        {:error,
         {:conflict,
          "This passkey is your only way to sign in here; link a door or register another " <>
            "passkey before you revoke it"}}
      else
        {:ok, [_ | _]} -> :ok
        {:error, :unavailable} -> {:error, :unavailable}
      end
    else
      :ok
    end
  end

  defp leaves_a_way_in(_ctx, _user_id, _passkey, _was), do: :ok

  defp other_active(ctx, user_id, passkey_id) do
    case Arca.Passkeys.list(Context.actor(ctx), user_id, state: :active) do
      {:ok, rows} -> {:ok, Enum.filter(rows, &(&1.id != passkey_id and &1.rp_id == rp_id()))}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  defp own(ctx, user_id, passkey_id) do
    case Arca.Passkeys.get(Context.actor(ctx), passkey_id) do
      {:ok, %{user_id: ^user_id, state: state} = passkey} when state != "revoked" ->
        {:ok, passkey}

      {:error, :database_error} ->
        {:error, :unavailable}

      _other ->
        {:error, {:not_found, "passkey", passkey_id}}
    end
  end

  @doc """
  The platform administrator authorizes the pending registration
  `passkey_id` of the person `user_id`, whose exact registration digest
  the administrator names: a sensitive change of the administrator's own
  (`passkey_registration`), asked first and consumed in the transaction
  that activates the credential (`Arca.Passkeys.activate/3`), so the
  authorization and the activation commit together and a revoked, expired
  or changed pending credential activates nothing. In that transaction the
  person is locked and read active, so a person denied first gains no
  passkey (`{:conflict, _}`). Recorded by the gate's decision, and
  announced to the person's own clients (`:passkey_registered`) and to
  them and the members of every athanor they belong to
  (`:passkey_recovered`), never to the administrator's. A person whose
  keys are at another home is refused `:remote_identity_unavailable`
  until J.J0.
  """
  @spec recover_admin(Context.t(), map()) :: {:ok, map()} | {:error, term()}
  def recover_admin(
        %Context{platform_admin: true} = ctx,
        %{user_id: user_id, passkey_id: passkey_id, registration_digest: digest}
      )
      when is_binary(user_id) and is_binary(passkey_id) and is_binary(digest) do
    change = %{
      operation: "passkey.recover_admin",
      arguments: %{
        "user_id" => user_id,
        "passkey_id" => passkey_id,
        "registration_digest" => digest
      },
      resource: Sanctum.Tenancy.Users.display_name(user_id),
      details: %{"registration_digest" => digest}
    }

    with {:ok, _identity} <- identity(user_id),
         {:ok, _pending} <- pending_registration(user_id, passkey_id),
         :ok <- Authz.check(ctx, :passkey_registration, change) do
      # The person first, locked and read active, then the administrator's
      # own standing and confirmation (`Authz.consume/2`).
      also = fn _row ->
        with :ok <- recovered_person(user_id),
             do: Authz.consume(ctx, {:passkey_registration, change})
      end

      case Arca.Passkeys.activate(Prima.Actor.system(), passkey_id,
             registration_digest: digest,
             identity_key_epoch: nil,
             admin_confirmation_id: confirmation_ref(ctx),
             also: also
           ) do
        {:ok, row} ->
          Authz.consumed(ctx)
          announce(:passkey_registered, [personal_athanor(user_id)])
          announce(:passkey_recovered, person_athanors(user_id))
          {:ok, %{status: "active", passkey: listed(row)}}

        {:error, :person_not_standing} ->
          {:error, {:conflict, "That person no longer stands here; nothing was activated"}}

        {:error, reason} when reason in [:not_pending, :expired, :mismatch, :not_found] ->
          {:error,
           {:conflict,
            "That pending passkey is gone, expired or changed; the person registers it again"}}

        {:error, reason} when reason in [:database_error, :not_owner] ->
          {:error, :unavailable}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def recover_admin(%Context{platform_admin: true}, _args),
    do: {:error, {:invalid_argument, "Name the person, the pending passkey and its digest"}}

  def recover_admin(%Context{}, _args), do: {:error, :platform_admin_required}

  # The administrator's confirmation, as the activated passkey records it:
  # its public ref, never the secret the administrator's request presented.
  defp confirmation_ref(%Context{confirmation_id: id}) when is_binary(id) and id != "",
    do: Prima.Confirmation.ref(id)

  defp confirmation_ref(%Context{}), do: nil

  # The person a recovery activates for, locked in its transaction and
  # read active.
  defp recovered_person(user_id) do
    case active_person(user_id) do
      :ok -> :ok
      {:error, :not_standing} -> {:error, :person_not_standing}
      {:error, reason} -> {:error, reason}
    end
  end

  defp pending_registration(user_id, passkey_id) do
    case Arca.Passkeys.get(Prima.Actor.system(), passkey_id) do
      {:ok, %{user_id: ^user_id, state: "pending"} = passkey} -> {:ok, passkey}
      {:error, :database_error} -> {:error, :unavailable}
      _other -> {:error, {:not_found, "pending passkey", passkey_id}}
    end
  end

  # ---------------------------------------------------------------------------
  # Shared
  # ---------------------------------------------------------------------------

  @doc "A passkey row as its person and the administrator read it (`t:listed/0`)."
  @spec listed(map()) :: listed()
  def listed(row) do
    %{
      id: row.id,
      label: row.label,
      state: row.state,
      rp_id: row.rp_id,
      registered_at: row.inserted_at,
      activated_at: row.activated_at,
      expires_at: row.expires_at,
      registration_digest: row.registration_digest
    }
  end

  defp personal_athanor(user_id) do
    case Sanctum.Tenancy.Users.personal_athanor_id(user_id) do
      {:ok, athanor_id} -> athanor_id
      :none -> nil
    end
  end

  # Every athanor the person works in: their own, then each group an
  # active membership grants.
  defp person_athanors(user_id),
    do: user_id |> Sanctum.Tenancy.Athanors.list_for_user() |> Enum.map(& &1.id)

  defp announce(kind, athanor_ids) do
    for athanor_id <- Enum.uniq(athanor_ids), is_binary(athanor_id) and athanor_id != "" do
      Sanctum.Notify.broadcast(athanor_id, kind, %{})
    end

    :ok
  end

  defp b64(value) when is_binary(value) do
    case Base.url_decode64(value, padding: false) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> Base.url_decode64(value)
    end
  end

  defp b64(_value), do: :error

  defp now_ms, do: System.os_time(:millisecond)
end
