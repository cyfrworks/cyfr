# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Auth.OIDC do
  @moduledoc """
  OIDC authentication provider for `Sanctum.Auth`.

  Signs a person in through a generic OIDC issuer via `ueberauth_oidcc`,
  for deployments that federate against their own IdP. GitHub and Google
  sign in by device flow (`Sanctum.Auth.DeviceFlow`), not through this
  provider.

  ## Configuration

      export CYFR_AUTH_PROVIDER=oidc
      export CYFR_OIDC_ISSUER=https://auth.example.com
      export CYFR_OIDC_CLIENT_ID=xxx
      export CYFR_OIDC_CLIENT_SECRET=xxx

  ## Usage

  This provider proves an identity for `PrismWeb.AuthController.callback/2`,
  which then asks the door (`Sanctum.Door.admit_identity/2`) and only on
  admission mints the session. The provider itself never creates one.

  ## Re-authentication for one confirmation

  A sign-in proves who someone is, not that they are present now: an
  issuer may answer it from its own session. So a sign-in is no fresh
  proof, and a pending confirmation (`Prima.Confirmation`) is proven by a
  re-authentication bound to it instead:

    * `reauth_url/2` begins one for a pending confirmation of the
      caller's own person, named by its public ref
      (`Prima.Confirmation.ref/1`), who must hold an `oidcc` door of this
      issuer. It asks the issuer, through `Oidcc` directly against the
      `:cyfr_oidc` configuration worker, for a login forced fresh with
      `prompt=login` and `max_age=0`, carrying a nonce derived from the
      confirmation's ref and digest and held on the record, a state
      naming the record's ref under a keyed digest, and a PKCE verifier
      derived from the nonce. Its redirect URI is
      `<origin>/auth/oidcc/reauth`, which the issuer must list beside the
      sign-in callback. Nothing here carries the secret the asking
      request holds: the URL travels through the issuer, the browser and
      the request log.
    * `reauth_callback/1` accepts the issuer's answer only when the ID
      token's `nonce` is the one the record holds, its `auth_time` is not
      earlier than the record's opening (an answer with no `auth_time`
      is no fresh proof), and its issuer and subject are the person's
      linked `oidcc` door. It confirms nothing: it holds the proof under
      a single-use ticket and answers the record's preview, which the
      callback's page shows.
    * `reauth_decide/3` spends that ticket on the person's answer to the
      page. An approval confirms the record, with proof `oidc_reauth`,
      only from a browser whose own session is the record's person; a
      decline, another person's session or none confirms nothing. So a
      fresh login someone else asked for never confirms a change its
      person did not see.

  The exchange with the issuer is `Sanctum.Auth.OIDC.Oidcc`'s. A test
  stands in its own issuer through `:sanctum, :oidc_reauth_client`, a
  seam deliberately undeclared in config, as the device flow's is: every
  check of the answer is this module's either way.
  """

  @behaviour Sanctum.Auth

  alias Prima.Identity.Encoding
  alias Sanctum.Auth.Identity
  alias Sanctum.Consent.Authz
  alias Sanctum.Context

  @reauth_path "/auth/oidcc/reauth"
  @nonce_protocol "cyfr-oidc-reauth/v1"
  # How long a verified re-authentication waits for its person's answer.
  @held_ms 600_000

  defmodule Oidcc do
    @moduledoc """
    The exchange a re-authentication makes with the issuer, over `Oidcc`,
    against the `:cyfr_oidc` provider configuration worker
    `ueberauth_oidcc` starts from the issuer `runtime.exs` configures, with
    the client id and secret of the `oidcc` Ueberauth provider:

      * `authorize_url/1` — the issuer's authorization URL for a login
        forced fresh, for a request's `redirect_uri`, `nonce`, `state` and
        `pkce_verifier`;
      * `redeem/2` — the claims of the ID token a code redeems for,
        validated for signature, audience, expiry and the request's nonce.

    A test's stand-in (`:sanctum, :oidc_reauth_client`) answers the same
    two functions.
    """

    @doc "The issuer's authorization URL for a login forced fresh."
    @spec authorize_url(map()) :: {:ok, String.t()} | {:error, :unavailable}
    def authorize_url(request) do
      with {:ok, {client_id, client_secret}} <- Sanctum.Auth.OIDC.client_credentials() do
        case Elixir.Oidcc.create_redirect_url(:cyfr_oidc, client_id, client_secret, %{
               redirect_uri: request.redirect_uri,
               nonce: request.nonce,
               state: request.state,
               pkce_verifier: request.pkce_verifier,
               scopes: ["openid"],
               url_extension: [{"prompt", "login"}, {"max_age", "0"}]
             }) do
          {:ok, url} -> {:ok, IO.iodata_to_binary(url)}
          {:error, _reason} -> {:error, :unavailable}
        end
      end
    end

    @doc "The validated ID token claims `code` redeems for."
    @spec redeem(String.t(), map()) :: {:ok, map()} | {:error, :reauth_refused | :unavailable}
    def redeem(code, request) do
      with {:ok, {client_id, client_secret}} <- Sanctum.Auth.OIDC.client_credentials() do
        case Elixir.Oidcc.retrieve_token(code, :cyfr_oidc, client_id, client_secret, %{
               redirect_uri: request.redirect_uri,
               nonce: request.nonce,
               pkce_verifier: request.pkce_verifier
             }) do
          {:ok, token} -> id_claims(token)
          {:error, _reason} -> {:error, :reauth_refused}
        end
      end
    end

    # An answer with no ID token carries no `nonce` or `auth_time`, so it
    # proves nothing. `Oidcc.Token`'s type omits that case, which `oidcc`
    # answers with the atom `none`, so the field is read, not matched.
    defp id_claims(token) do
      case Map.get(token, :id) do
        %{claims: claims} when is_map(claims) -> {:ok, claims}
        _no_id_token -> {:error, :reauth_refused}
      end
    end
  end

  @impl true
  @doc """
  Authenticate from Ueberauth.Auth struct.

  Called after successful OAuth callback with the auth struct from Ueberauth.
  Builds a `Sanctum.Context` from the OAuth provider's response and resolves
  athanor membership.

  ## Examples

      auth = %Ueberauth.Auth{
        uid: "12345",
        info: %{email: "alice@example.com", nickname: "alice"},
        provider: :oidcc
      }

      {:ok, ctx} = Sanctum.Auth.OIDC.authenticate(auth)
      ctx.user_id
      #=> "oidcc|https://auth.example.com|12345"
  """
  def authenticate(%{__struct__: Ueberauth.Auth} = auth) do
    provider = auth.provider
    # Resolve issuer first — this is a deployment-configuration assertion
    # (raises on misconfigured OIDC wiring) and must fail fast regardless of
    # user-input state like email.
    iss = resolve_issuer()

    email = get_email(auth)
    extra = Map.get(auth, :extra) || %{}

    case Sanctum.Auth.EmailVerification.verify(provider, email, extra) do
      :ok ->
        # Before the door the person is named by their IdP identity key;
        # their own id, and their namespace, come with admission.
        identity = Identity.key(provider, iss, to_string(auth.uid))

        # Athanor-less: the athanor is resolved after the door, by the one
        # recipe, once the person is named by their own id.
        ctx =
          Context.build(
            user_id: identity,
            email: email,
            provider: to_string(provider),
            namespace: nil,
            athanor_id: nil,
            permissions: Context.person_permissions()
          )

        Sanctum.Telemetry.auth_event(provider, :success)
        {:ok, ctx}

      {:error, reason} = err ->
        Sanctum.Telemetry.auth_event(provider, :failure, %{reason: reason})
        err
    end
  end

  def authenticate(_params) do
    Sanctum.Telemetry.auth_event(:unknown, :failure, %{reason: :invalid_credentials})
    {:error, :invalid_credentials}
  end

  @impl true
  @doc """
  This provider issues no bearer credential of its own: a session token or
  an API key on a request is established by the one recipe
  (`Sanctum.Caller.establish/2`) in `CyfrWeb.Plugs.Authenticate`
  before the provider is asked. Always `nil`.
  """
  def current_user(_conn), do: nil

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp get_email(auth) do
    cond do
      auth.info && is_map(auth.info) && Map.get(auth.info, :email) ->
        Map.get(auth.info, :email)

      auth.extra && is_map(auth.extra) && is_map(auth.extra[:raw_info]) &&
          auth.extra[:raw_info]["email"] ->
        auth.extra[:raw_info]["email"]

      auth.extra && is_map(auth.extra) && is_map(Map.get(auth.extra, :raw_info)) &&
          Map.get(auth.extra, :raw_info)["email"] ->
        Map.get(auth.extra, :raw_info)["email"]

      true ->
        nil
    end
  end

  @doc """
  The operator-configured issuer (`:sanctum, :oidc_issuer`, pinned at boot
  from `CYFR_OIDC_ISSUER`), or `nil` when none is set.
  """
  @spec issuer() :: String.t() | nil
  def issuer, do: Application.get_env(:sanctum, :oidc_issuer)

  @doc """
  A plain sign-in through this issuer proves who someone is, never that
  they are present now: an issuer may answer it from its own session. It
  is no fresh proof; only a re-authentication its person then approves
  is (`reauth_callback/1`, `reauth_decide/3`).
  """
  @spec proves_freshness?() :: false
  def proves_freshness?, do: false

  @doc """
  The client id and secret of the configured `oidcc` Ueberauth provider,
  the one registration at the issuer both the sign-in and the
  re-authentication use. `{:error, :unavailable}` when this home signs no
  one in through an issuer.
  """
  @spec client_credentials() :: {:ok, {String.t(), String.t()}} | {:error, :unavailable}
  def client_credentials do
    providers = Application.get_env(:ueberauth, Ueberauth, [])[:providers] || []

    case providers[:oidcc] do
      {_strategy, opts} when is_list(opts) ->
        case {opts[:client_id], opts[:client_secret]} do
          {id, secret} when is_binary(id) and id != "" and is_binary(secret) ->
            {:ok, {id, secret}}

          _incomplete ->
            {:error, :unavailable}
        end

      _none ->
        {:error, :unavailable}
    end
  end

  @doc """
  Whether the person `user_id` can re-authenticate here: this home signs
  people in through an issuer, and the person holds an `oidcc` door of it.
  """
  @spec reauth_available?(String.t()) :: boolean()
  def reauth_available?(user_id) when is_binary(user_id) do
    match?({:ok, _door}, linked_door(user_id))
  end

  @doc """
  Begin a re-authentication for the pending confirmation `ref` of the
  context's own person, in the context's athanor (the module doc).
  Answers `%{method: "oidc", url:}`, the issuer's URL to send the browser
  to. A new one replaces any earlier re-authentication for that record.

  Refusals: `{:invalid_argument, _}` for a person with no linked `oidcc`
  door of this issuer, or a home that signs no one in through one;
  `{:not_found, "confirmation", ref}`; `:not_pending`; `:unavailable`.
  """
  @spec reauth_url(Context.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def reauth_url(%Context{} = ctx, ref) when is_binary(ref) do
    actor = Context.actor(ctx)

    with {:ok, user_id} <- confirming_person(ctx),
         {:ok, _door} <- linked_door(user_id),
         {:ok, row} <- pending_record(actor, ref, user_id) do
      nonce = reauth_nonce(row)

      case Arca.PendingConfirmations.put_challenge(actor, row.ref, %{reauth_nonce: nonce}) do
        {:ok, _held} ->
          case client().authorize_url(request(ctx.athanor_id, row.ref, nonce)) do
            {:ok, url} -> {:ok, %{method: "oidc", url: url}}
            {:error, _unreached} -> {:error, :unavailable}
          end

        {:error, :not_pending} ->
          {:error, :not_pending}

        {:error, _unanswered} ->
          {:error, :unavailable}
      end
    end
  end

  @doc """
  The issuer's answer to a re-authentication (`params` holds `state` and
  `code`): redeemed, and its ID token held to the record's nonce, opening
  and person (the module doc). It confirms nothing: the verified proof is
  held under a single-use ticket, alive while the record is and at most
  ten minutes, and the answer is what the person approves or declines,
  `%{ticket:, ref:, operation:, preview:, expires_at:}`, the preview as the
  home stored it. The ticket goes to `reauth_decide/3` and nowhere a
  page renders.

  Refusals: `:reauth_refused` (a state not this home's, an error answer,
  a code the issuer refuses, or an ID token whose nonce, `auth_time`,
  issuer or subject does not hold), `{:not_found, "confirmation", ref}`,
  `:not_pending`, `:expired`, `:unavailable`.
  """
  @spec reauth_callback(map()) :: {:ok, map()} | {:error, term()}
  def reauth_callback(%{"state" => state, "code" => code})
      when is_binary(state) and is_binary(code) and code != "" do
    with {:ok, athanor_id, ref} <- read_state(state),
         actor = Prima.Actor.in_athanor(athanor_id),
         {:ok, row} <- stored(actor, ref),
         {:ok, nonce} <- held_nonce(row),
         {:ok, ttl} <- alive_ms(row),
         {:ok, claims} <- client().redeem(code, request(athanor_id, row.ref, nonce)),
         :ok <- fresh(claims, nonce, row),
         :ok <- same_door(claims, row.user_id),
         {:ok, preview} <- Jason.decode(row.preview) do
      ticket = Encoding.b64(:crypto.strong_rand_bytes(32))

      Arca.Cache.put(
        {:oidc_reauth_proof, ticket},
        %{athanor_id: athanor_id, ref: row.ref, user_id: row.user_id, nonce: nonce},
        ttl
      )

      {:ok,
       %{
         ticket: ticket,
         ref: row.ref,
         operation: row.operation,
         preview: preview,
         expires_at: row.expires_at
       }}
    else
      {:error, reason} when reason in [:unavailable, :not_pending, :expired] -> {:error, reason}
      {:error, {:not_found, _what, _id} = missing} -> {:error, missing}
      _refused -> {:error, :reauth_refused}
    end
  end

  def reauth_callback(_params), do: {:error, :reauth_refused}

  @doc """
  The person's answer to the page a verified re-authentication showed:
  `ticket` is `reauth_callback/1`'s, spent here whatever the answer;
  `session_token` is the session the answering browser holds, or nil;
  `decision` is `:approve` or `:decline`.

  An approval confirms the record with proof `oidc_reauth` only when that
  session is the record's person's, still standing (`Sanctum.Caller.establish/2`),
  and the record still pending under the nonce the login answered.
  Answers `%{ref:, state: "confirmed", expires_at:}`, or `:declined` for a
  decline, which confirms nothing.

  Refusals: `:reauth_refused` (a ticket spent, expired or never issued, or
  a record re-asked since), `:another_person` (no session, another
  person's, or one that no longer stands), `:not_pending`, `:expired`,
  `:unavailable`.
  """
  @spec reauth_decide(String.t() | nil, String.t() | nil, :approve | :decline) ::
          {:ok, map() | :declined} | {:error, term()}
  def reauth_decide(ticket, session_token, decision) when decision in [:approve, :decline] do
    with {:ok, held} <- take_held(ticket) do
      case decision do
        :decline -> {:ok, :declined}
        :approve -> approved(held, session_token)
      end
    end
  end

  defp take_held(ticket) when is_binary(ticket) and ticket != "" and byte_size(ticket) <= 64 do
    case Arca.Cache.take({:oidc_reauth_proof, ticket}) do
      {:ok, %{athanor_id: _, ref: _, user_id: _, nonce: _} = held} -> {:ok, held}
      _spent -> {:error, :reauth_refused}
    end
  end

  defp take_held(_ticket), do: {:error, :reauth_refused}

  defp approved(held, session_token) do
    actor = Prima.Actor.in_athanor(held.athanor_id)

    with :ok <- answering_person(session_token, held.user_id),
         {:ok, row} <- stored(actor, held.ref),
         {:ok, nonce} <- held_nonce(row),
         true <- Plug.Crypto.secure_compare(nonce, held.nonce) or {:error, :reauth_refused} do
      case Arca.PendingConfirmations.confirm(actor, row.ref, %{proof: "oidc_reauth"}) do
        {:ok, confirmed} ->
          Authz.announce(:confirmed, confirmed)
          {:ok, %{ref: confirmed.ref, state: confirmed.state, expires_at: confirmed.expires_at}}

        {:error, reason} when reason in [:not_pending, :expired] ->
          {:error, reason}

        {:error, _unanswered} ->
          {:error, :unavailable}
      end
    end
  end

  # The answering browser's own session names the record's person and
  # still stands.
  defp answering_person(token, user_id) when is_binary(token) and token != "" do
    case Sanctum.Caller.establish(token, task_supervisor: nil) do
      {:ok, %Context{user_id: ^user_id, authenticated: true}} -> :ok
      {:ok, _another} -> {:error, :another_person}
      {:error, :unavailable} -> {:error, :unavailable}
      {:error, _gone} -> {:error, :another_person}
    end
  end

  defp answering_person(_token, _user_id), do: {:error, :another_person}

  # How long a verified proof is held: while its record is open, and never
  # past ten minutes.
  defp alive_ms(row) do
    left = DateTime.diff(row.expires_at, DateTime.utc_now(), :millisecond)
    if left > 0, do: {:ok, min(left, @held_ms)}, else: {:error, :expired}
  end

  defp client, do: Application.get_env(:sanctum, :oidc_reauth_client, __MODULE__.Oidcc)

  defp confirming_person(%Context{} = ctx) do
    if Sanctum.Pairing.can_confirm?(ctx) and is_binary(ctx.athanor_id) and ctx.athanor_id != "",
      do: {:ok, ctx.user_id},
      else: {:error, :unauthenticated}
  end

  # The person's `oidcc` doors of the issuer this home signs people in
  # through: the identities a re-authentication may prove.
  defp linked_door(user_id) do
    with iss when is_binary(iss) and iss != "" <- issuer(),
         {:ok, _credentials} <- client_credentials(),
         {:ok, identities} <- Arca.Users.identities(Prima.Actor.system(), user_id),
         [_ | _] = doors <-
           Enum.filter(identities, &(&1.provider == "oidcc" and &1.issuer == iss)) do
      {:ok, doors}
    else
      _none -> {:error, {:invalid_argument, "No OpenID Connect sign-in of this server is yours"}}
    end
  end

  defp pending_record(actor, ref, user_id) do
    case Arca.PendingConfirmations.get(actor, ref) do
      {:ok, %{user_id: ^user_id, state: "pending"} = row} -> {:ok, row}
      {:ok, %{user_id: ^user_id}} -> {:error, :not_pending}
      {:ok, _another} -> {:error, {:not_found, "confirmation", ref}}
      {:error, :not_found} -> {:error, {:not_found, "confirmation", ref}}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  defp stored(actor, ref) do
    case Arca.PendingConfirmations.get(actor, ref) do
      {:ok, row} -> {:ok, row}
      {:error, :not_found} -> {:error, {:not_found, "confirmation", ref}}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  defp held_nonce(%{state: "pending", reauth_nonce: nonce}) when is_binary(nonce) and nonce != "",
    do: {:ok, nonce}

  defp held_nonce(%{state: "pending"}), do: {:error, :reauth_refused}
  defp held_nonce(_row), do: {:error, :not_pending}

  # A nonce bound to the record's ref and digest, and drawn fresh for each
  # re-authentication: only this home can make one, and each names one
  # attempt at one record.
  defp reauth_nonce(row) do
    Encoding.b64(
      :crypto.mac(
        :hmac,
        :sha256,
        Authz.derived_key("oidc-reauth-nonce"),
        Encoding.jcs!(%{
          "protocol" => @nonce_protocol,
          "ref" => row.ref,
          "digest" => row.digest,
          "salt" => Encoding.b64(:crypto.strong_rand_bytes(16))
        })
      )
    )
  end

  defp request(athanor_id, ref, nonce) do
    %{
      redirect_uri: Sanctum.Person.home() <> @reauth_path,
      nonce: nonce,
      state: state(athanor_id, ref),
      pkce_verifier:
        Encoding.b64(:crypto.mac(:hmac, :sha256, Authz.derived_key("oidc-reauth-pkce"), nonce))
    }
  end

  # The state names the record by its public ref, under a keyed digest
  # only this home can make: the callback reads nothing it did not write,
  # and the state, which the issuer, the browser and the request log all
  # see, carries nothing the asking request alone holds.
  defp state(athanor_id, ref) do
    payload = Encoding.b64(Encoding.jcs!(%{"a" => athanor_id, "c" => ref}))
    payload <> "." <> Encoding.b64(state_mac(payload))
  end

  defp state_mac(payload),
    do: :crypto.mac(:hmac, :sha256, Authz.derived_key("oidc-reauth-state"), payload)

  defp read_state(state) when byte_size(state) <= 1024 do
    with [payload, mac] <- String.split(state, ".", parts: 2),
         {:ok, mac} <- Encoding.unb64(mac, 32),
         true <- Plug.Crypto.secure_compare(mac, state_mac(payload)),
         {:ok, json} <- Base.url_decode64(payload, padding: false),
         {:ok, %{"a" => athanor_id, "c" => ref}} <- Jason.decode(json),
         true <- Encoding.id?(athanor_id) and Prima.Confirmation.ref?(ref) do
      {:ok, athanor_id, ref}
    else
      _forged -> {:error, :reauth_refused}
    end
  end

  defp read_state(_state), do: {:error, :reauth_refused}

  # The ID token names this record's nonce and a login at or after the
  # record opened. An issuer that sends no `auth_time` proves no freshness.
  defp fresh(%{"nonce" => nonce, "auth_time" => auth_time}, nonce_held, row)
       when is_binary(nonce) and is_integer(auth_time) do
    opened = DateTime.to_unix(row.opened_at, :second)

    if Plug.Crypto.secure_compare(nonce, nonce_held) and auth_time >= opened,
      do: :ok,
      else: {:error, :reauth_refused}
  end

  defp fresh(_claims, _nonce, _row), do: {:error, :reauth_refused}

  # The issuer is this home's, and the subject is the record's person's
  # own door of it; neither an email nor a nonce alone names a person.
  defp same_door(%{"iss" => iss, "sub" => sub}, user_id) when is_binary(iss) and is_binary(sub) do
    with ^iss <- issuer(),
         {:ok, doors} <- linked_door(user_id),
         true <- Enum.any?(doors, &(&1.subject == sub)) do
      :ok
    else
      _another -> {:error, :reauth_refused}
    end
  end

  defp same_door(_claims, _user_id), do: {:error, :reauth_refused}

  # Reading the issuer here — rather than digging it out of
  # ueberauth_oidcc's Auth struct — keeps the user-id issuer deterministic
  # and reads the SAME source as the boot reserved-host check
  # (Cyfr.Application.validate_oidc_issuer_config!/0).
  defp resolve_issuer do
    iss =
      case issuer() do
        issuer when is_binary(issuer) and issuer != "" ->
          issuer

        _ ->
          raise "OIDC misconfiguration: :sanctum, :oidc_issuer is not set " <>
                  "(CYFR_OIDC_ISSUER was absent at boot)."
      end

    # A reserved issuer here is a live request, so it raises rather than
    # returning: the deployment is already wired wrong and every id it mints
    # would be the split one. Boot refuses the same value more gently.
    if Identity.reserved_issuer?(iss) do
      raise "OIDC issuer policy violation: ueberauth_oidcc wired against a reserved issuer " <>
              "(#{iss}); GitHub and Google sign in by device flow."
    end

    iss
  end
end
