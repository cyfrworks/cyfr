# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Auth.CyfrDoor do
  @moduledoc """
  The `cyfr` door (`ARCHITECTURE.md` §9.2): a person whose keys another
  home holds signs in here with an assertion their own home signed over
  this home's challenge, audience and pending carry. Homes never delegate
  admission to each other: the assertion and the person's genesis travel
  in their browser, the person's state comes from the directory their
  genesis names, and this home admits under its own standing rules.

  ## Where the person starts

  The person names their signing home by its address; `signing_home/1`
  answers that home's `/carry` page with this home as the destination in
  its fragment, where they begin the carry themselves
  (`person.carry_begin`).

  ## The challenge

  `challenge/1` takes the carry fragment the person's browser brought
  from their signing home (`Prima.Carry`: the signed envelope and its
  payload, `%{"genesis" => genesis}`) and, before any network use, holds
  the envelope's destination to this home (`Sanctum.Person.home/0`) and
  the genesis to the envelope's identifier (`Prima.Identity.locate/2`: a
  genesis that does not hash to it causes no request). It then reads the
  identity's head fresh from the directory that genesis names
  (`Sanctum.IdentityFreshness.fresh!/2`, never a cache and never a URL the
  browser supplied; the directory client's pinned transport refuses a
  private, metadata or redirected address) and verifies the envelope under
  the current live key (`Prima.Carry.Envelope.verify/4`): its signature,
  destination, action, payload digest, `key_epoch` and age.

  That read, and the head it caches, come before any signature can be
  checked: the envelope is signed by the live key, which only the head
  names. So every carry that reaches it is counted first against the
  installation's bound, 200 a minute, as the device families' unproven
  attempts are (`Sanctum.DeviceCerts`): this node's count, which sheds a
  flood without a database read, then the cell's, shared by every member
  (`Arca.RequestRateWindows`), which reads its window first and writes
  nothing past the cap. A carry refused there reads no directory. The
  sign-in page bounds each address on its own (`PrismWeb.LoginLive`). A
  head cached for an identifier no person here holds is removed once a
  carry could no longer rely on it (`Sanctum.Carry.sweep/1`).

  It answers the challenge this home holds for that carry, as the string
  keyed map the browser's session cookie carries
  (`t:held/0`): 32 random challenge bytes, a challenge id, a browser
  secret, the carry's action id, the identifier, the source home and its
  signed return URL, the `key_epoch` and an expiry. `redirect_url/1` is
  where the browser goes next: the envelope's signed return URL, always
  the source's `/carry`, with the challenge in its fragment
  (`challenge_fragment/1`). This home never redirects to an address the
  envelope does not sign.

  ## The callback

  `callback/2` takes the fragment the signing home sent the browser back
  with (`{"assertion": …, "genesis": …}`, `Prima.PersonAssertion.open/1`)
  and the challenge the browser's session cookie holds. A challenge this
  home already admitted under resumes its recorded result: its login
  receipt (`Arca.CarryActions.receipt/3`) bound to the browser secret and
  to the same assertion answers the session minted then, whose token is
  derived from the secret and the challenge id (`session_token/1`), and
  never a second session; a session since ended is refused. Otherwise it
  holds the assertion's identifier to the challenge's, reads the head
  fresh again, verifies the assertion under the current live key
  (`Prima.PersonAssertion.verify/3`: identifier, `key_epoch`, signature,
  this home as audience, the exact challenge, the carry the challenge was
  bound to, expiry), and asks the door about the identity
  `cyfr|<directory>|<identifier>` (`Sanctum.Auth.Identity.cyfr_key/2`),
  which judges it by its identifier. An admitted person is recorded
  (`Sanctum.SignIn.admitted/2`: a `remote` identity row, no key, no
  personal athanor of their own) and their session minted
  (`Sanctum.Session.create/2`) with the login receipt in its transaction
  and the head's `key_epoch` recorded, read fresh once more; an epoch
  that moved since the assertion was verified admits nothing.

  ## Refusals

    * `:invalid_carry` — a fragment, envelope, payload or genesis that does
      not read, is too large, or does not hash to its identifier.
    * `:wrong_destination` — a carry for another home.
    * `{:refused, reason}` — an envelope or assertion that does not verify
      under the current head, with `Prima.Carry.Envelope.verify/4`'s or
      `Prima.PersonAssertion.verify/3`'s reason, or `:wrong_identifier`
      for an assertion of another identity than the challenge's.
    * `:expired` — the challenge the cookie holds is past its expiry.
    * `:no_challenge` — the cookie holds no challenge.
    * `:identity_stale` — the directory could not be read fresh.
    * `{:rate_limited, retry_after_ms}` — the installation's bound on
      carries is spent; no directory was read.
    * `{:door, reason}` — the door refused the identity.
    * `:session_ended` — a retried login whose session has ended since.
    * `:receipt_conflict` — a retried login under another browser secret
      or with another assertion.
    * `:unavailable` — the store could not answer.
  """

  require Logger

  alias Prima.{Carry, PersonAssertion}
  alias Prima.Carry.Envelope
  alias Prima.Identity
  alias Prima.Identity.Encoding
  alias Sanctum.{Context, IdentityFreshness, Person}
  alias Sanctum.Directory.Client

  @challenge_bytes 32
  @secret_bytes 32
  @held ~w(challenge challenge_id browser_secret action_id identifier source return_url key_epoch expires_at)
  # The installation's bound on carries that reach a directory read.
  @installation_cap 200
  @window_ms 60_000

  @typedoc """
  The challenge a browser's session cookie carries between `challenge/1`
  and `callback/2`, string keyed: `challenge` (unpadded base64url of its
  32 bytes), `challenge_id`, `browser_secret`, `action_id`, `identifier`,
  `source`, `return_url`, `key_epoch` and `expires_at` (Unix
  milliseconds).
  """
  @type held :: %{required(String.t()) => String.t() | non_neg_integer()}

  @typedoc "An admitted, or resumed, sign-in: the session's token and the outcome to render."
  @type admitted :: %{
          session_token: String.t(),
          outcome: {:proceed, map()},
          resumed: boolean(),
          action_id: String.t(),
          return_url: String.t()
        }

  # ---------------------------------------------------------------------------
  # The signing home
  # ---------------------------------------------------------------------------

  @doc """
  Where the sign-in page sends a person who names their signing home by
  its `address`: that home's `/carry` page, with this home as the
  destination in its fragment (`#destination=<this home>`), where they
  begin the sign-in themselves. A fragment, not a query: a person not yet
  signed in there is sent through that home's sign-in first, and a
  redirect keeps the fragment where it drops the query. The address is
  read as an origin (`https://` when it names no scheme, and any path
  dropped), and only the person supplies it: no directory says where a
  person's home is.

  Refusals: `:invalid_home` (no home's origin) and `:this_home`.
  """
  @spec signing_home(String.t()) :: {:ok, String.t()} | {:error, :invalid_home | :this_home}
  def signing_home(address) when is_binary(address) do
    address = String.trim(address)
    address = if String.contains?(address, "://"), do: address, else: "https://" <> address
    home = Person.home()

    with %URI{scheme: scheme, host: host, port: port} when scheme in ["http", "https"] <-
           URI.parse(address),
         true <- is_binary(host) and host != "",
         origin = origin(String.downcase(scheme), String.downcase(host), port),
         true <- Encoding.home?(origin) do
      if origin == home,
        do: {:error, :this_home},
        else:
          {:ok,
           Carry.return_url(origin) <>
             "#" <> URI.encode_query(%{"destination" => home})}
    else
      _unread -> {:error, :invalid_home}
    end
  end

  def signing_home(_address), do: {:error, :invalid_home}

  @doc """
  How long a carry lives, in milliseconds (`Arca.CarryActions.lifetime_ms/0`):
  the bound a sign-in page holds its in-flight carry data to, which the
  page hands its script.
  """
  @spec carry_lifetime_ms() :: pos_integer()
  def carry_lifetime_ms, do: Arca.CarryActions.lifetime_ms()

  defp origin(scheme, host, port) do
    if port in [nil, URI.default_port(scheme)],
      do: scheme <> "://" <> host,
      else: scheme <> "://" <> host <> ":" <> Integer.to_string(port)
  end

  # ---------------------------------------------------------------------------
  # The challenge
  # ---------------------------------------------------------------------------

  @doc """
  The challenge for the carry `fragment` the browser brought (the module
  doc). Answers `{:ok, held}` (`t:held/0`) or a refusal.
  """
  @spec challenge(String.t()) :: {:ok, held()} | {:error, term()}
  def challenge(fragment) when is_binary(fragment) do
    home = Person.home()

    with {:ok, %{envelope: envelope, payload: payload}} <- carry(fragment),
         :ok <- destination(envelope, home),
         {:ok, genesis} <- payload_genesis(payload, envelope.identifier),
         {:ok, digest} <- payload_digest(payload),
         :ok <- installation_room(),
         {:ok, state} <- fresh_state(envelope.identifier, genesis),
         {:ok, skew} <- skew_ms(),
         {:ok, envelope} <- verified_envelope(envelope, state, home, digest, skew) do
      now = now_ms()

      {:ok,
       %{
         "challenge" => Encoding.b64(:crypto.strong_rand_bytes(@challenge_bytes)),
         "challenge_id" => Prima.UUID7.generate_id("chl"),
         "browser_secret" => Encoding.b64(:crypto.strong_rand_bytes(@secret_bytes)),
         "action_id" => envelope.action_id,
         "identifier" => envelope.identifier,
         "source" => envelope.source,
         "return_url" => envelope.return_url,
         "key_epoch" => state.key_epoch,
         "expires_at" => now + Arca.CarryActions.lifetime_ms()
       }}
    end
  end

  def challenge(_fragment), do: {:error, :invalid_carry}

  @doc """
  The fragment the source's `/carry` page reads for a held challenge: the
  unpadded base64url of the JCS bytes of `{"protocol": "cyfr-carry/v1",
  "action_id": …, "audience": <this home>, "challenge": …}`.
  """
  @spec challenge_fragment(held()) :: String.t()
  def challenge_fragment(%{"action_id" => action_id, "challenge" => challenge}) do
    %{
      "protocol" => Carry.protocol(),
      "action_id" => action_id,
      "audience" => Person.home(),
      "challenge" => challenge
    }
    |> Encoding.jcs!()
    |> Encoding.b64()
  end

  @doc """
  Where the browser takes a held challenge: the envelope's signed return
  URL (the source's `/carry`) with the challenge in its fragment.
  """
  @spec redirect_url(held()) :: String.t()
  def redirect_url(%{"return_url" => return_url} = held) when is_binary(return_url),
    do: return_url <> "#" <> challenge_fragment(held)

  defp carry(fragment) do
    case Carry.parse_fragment(fragment) do
      {:ok, carry} -> {:ok, carry}
      {:error, _unread} -> {:error, :invalid_carry}
    end
  end

  # Before any network use: the carry is for this home.
  defp destination(%Envelope{destination: home}, home), do: :ok
  defp destination(%Envelope{}, _home), do: {:error, :wrong_destination}

  # The payload is the genesis alone, held to the envelope's identifier
  # before anything uses its directory.
  defp payload_genesis(%{"genesis" => genesis} = payload, identifier)
       when map_size(payload) == 1 do
    case Identity.locate(genesis, identifier) do
      {:ok, _located} -> {:ok, genesis}
      {:error, _mismatch} -> {:error, :invalid_carry}
    end
  end

  defp payload_genesis(_payload, _identifier), do: {:error, :invalid_carry}

  defp payload_digest(payload) do
    case Carry.payload_digest(payload) do
      {:ok, digest} -> {:ok, digest}
      {:error, _unread} -> {:error, :invalid_carry}
    end
  end

  # Counted before the directory is read, whoever sent it: this node's
  # count first, so past it a flood asks no database, then the cell's,
  # whose claim reads the window before it counts and writes nothing past
  # the cap. A store that cannot count reads no directory either.
  defp installation_room do
    case Prima.RateLimiter.check({:cyfr_carry, :installation}, @installation_cap, @window_ms) do
      :ok ->
        case Arca.RequestRateWindows.claim(
               Prima.Actor.system(),
               :cyfr_carry_installation,
               "installation",
               @installation_cap,
               @window_ms
             ) do
          :ok -> :ok
          {:error, {:rate_limited, retry_after_ms}} -> {:error, {:rate_limited, retry_after_ms}}
          {:error, _unanswered} -> {:error, :unavailable}
        end

      {:deny, retry_after_s} ->
        {:error, {:rate_limited, retry_after_s * 1_000}}
    end
  end

  defp verified_envelope(envelope, state, home, digest, skew) do
    case Envelope.verify(
           envelope,
           state,
           %{destination: home, action_id: envelope.action_id, payload_digest: digest},
           now: now_ms(),
           skew: skew,
           max_age: Arca.CarryActions.lifetime_ms()
         ) do
      {:ok, envelope} -> {:ok, envelope}
      {:error, reason} -> refused(:envelope, reason)
    end
  end

  # ---------------------------------------------------------------------------
  # The callback
  # ---------------------------------------------------------------------------

  @doc """
  Admit, or resume, the sign-in the signing home's `fragment` answers for
  the challenge the browser's session cookie `held` (the module doc).
  Answers `t:admitted/0`, or a refusal.
  """
  @spec callback(String.t(), held() | nil) :: {:ok, admitted()} | {:error, term()}
  def callback(fragment, held) do
    home = Person.home()

    with {:ok, held} <- held(held),
         {:ok, transport} <- transport(fragment),
         {:ok, %{assertion: assertion, genesis: genesis}} <- opened(transport) do
      case resume(held, assertion, home) do
        :none -> admit(held, assertion, genesis, transport, home)
        answered -> answered
      end
    end
  end

  # A challenge this home admitted under already: its receipt, bound to
  # this browser's secret and this assertion, answers the session minted
  # then, whichever request carried it first.
  defp resume(held, assertion, home) do
    case Arca.CarryActions.receipt(Prima.Actor.system(), home, held["challenge_id"]) do
      {:ok, receipt} ->
        cond do
          receipt.browser_binding_digest != binding_digest(held) ->
            {:error, :receipt_conflict}

          receipt.assertion_digest != assertion_digest(assertion) ->
            {:error, :receipt_conflict}

          true ->
            token = session_token(held)

            case Sanctum.Session.get(token) do
              {:ok, _session} -> {:ok, answer(token, held, true)}
              {:error, :invalid_session} -> {:error, :session_ended}
              {:error, _unanswered} -> {:error, :unavailable}
            end
        end

      {:error, reason} when reason in [:not_found, :expired] ->
        :none

      {:error, _unanswered} ->
        {:error, :unavailable}
    end
  end

  defp admit(held, assertion, genesis, transport, home) do
    with :ok <- unexpired(held),
         :ok <- same_identity(assertion, held),
         {:ok, state} <- fresh_state(assertion.identifier, transport["genesis"]),
         {:ok, assertion} <- verified_assertion(assertion, state, held, home),
         key = Sanctum.Auth.Identity.cyfr_key(state.directory, state.identifier),
         {:ok, verdict} <- Sanctum.Door.admit_identity(key, %{email: nil, verified: :unknown}),
         {:ok, user} <- Sanctum.SignIn.admitted(person(key, state, genesis), verdict),
         {:ok, ctx} <- context(user) do
      receipt = %{
        action_id: held["action_id"],
        destination_home: home,
        challenge_id: held["challenge_id"],
        source_home: held["source"],
        key_epoch: assertion.key_epoch,
        browser_binding_digest: binding_digest(held),
        assertion_digest: assertion_digest(assertion),
        outcome: "admitted"
      }

      case Sanctum.Session.create(ctx,
             login_receipt: %{token: session_token(held), receipt: receipt}
           ) do
        {:ok, session} ->
          {:ok, answer(session.token, held, false)}

        # A concurrent request for the same challenge may have minted the
        # one session first: then this one resumes it.
        {:error, reason} ->
          case resume(held, assertion, home) do
            {:ok, resumed} -> {:ok, resumed}
            _none -> session_refusal(reason)
          end
      end
    end
  end

  defp answer(token, held, resumed?) do
    %{
      session_token: token,
      outcome: {:proceed, %{unsynced: [], probe: :skipped}},
      resumed: resumed?,
      action_id: held["action_id"],
      return_url: held["return_url"]
    }
  end

  defp session_refusal(reason) when reason in [:identity_stale, :unavailable],
    do: {:error, reason}

  defp session_refusal(:stale_key_epoch), do: {:error, {:refused, :stale_key_epoch}}
  defp session_refusal(:receipt_conflict), do: {:error, :receipt_conflict}

  defp session_refusal(reason) do
    Logger.warning(
      "[Sanctum.Auth.CyfrDoor] the session could not be minted: " <>
        Prima.LoggerContext.shape(reason)
    )

    {:error, :unavailable}
  end

  # What the door admitted, for `Sanctum.SignIn.admitted/2`: a person with
  # no email, whose identity is the identifier at the directory its
  # genesis names.
  defp person(key, state, genesis) do
    %{
      id: key,
      provider: "cyfr",
      email: nil,
      verified: :unknown,
      name: nil,
      remote: %{
        identifier: state.identifier,
        directory_url: state.directory,
        genesis_hash: Identity.hash(genesis),
        head_hash: state.head
      }
    }
  end

  # The person's own context, bound to the athanor their memberships give,
  # or none: a person admitted to nothing here holds a session with no
  # athanor and is told so.
  defp context(user) do
    ctx =
      Context.build(
        user_id: user.id,
        email: user[:email],
        provider: "cyfr",
        athanor_id: nil,
        permissions: Context.person_permissions()
      )

    case Sanctum.Tenancy.resolve_status(%{ctx | namespace: user[:namespace]}, force: true) do
      {:ok, ctx} -> {:ok, ctx}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  defp held(%{} = held) do
    with true <- Enum.all?(@held, &Map.has_key?(held, &1)),
         {:ok, _bytes} <- Encoding.unb64(held["challenge"], @challenge_bytes),
         true <- Encoding.id?(held["challenge_id"]) and Encoding.id?(held["action_id"]),
         true <- Encoding.identifier?(held["identifier"]) and Encoding.home?(held["source"]),
         true <- is_binary(held["browser_secret"]) and is_integer(held["expires_at"]) do
      {:ok, held}
    else
      _malformed -> {:error, :no_challenge}
    end
  end

  defp held(_absent), do: {:error, :no_challenge}

  defp unexpired(%{"expires_at" => expires_at}) do
    if expires_at > now_ms(), do: :ok, else: {:error, :expired}
  end

  # The fragment's transport, length first: `{"assertion", "genesis"}`.
  defp transport(fragment) when is_binary(fragment) do
    with {:ok, fragment} <- Carry.bounded(fragment),
         {:ok, transport} <- Carry.decode_object(fragment) do
      {:ok, transport}
    else
      _unread -> {:error, :invalid_carry}
    end
  end

  defp transport(_fragment), do: {:error, :invalid_carry}

  defp opened(transport) do
    case PersonAssertion.open(transport) do
      {:ok, opened} -> {:ok, opened}
      {:error, _unread} -> {:error, :invalid_carry}
    end
  end

  defp same_identity(%PersonAssertion{identifier: identifier}, %{"identifier" => identifier}),
    do: :ok

  defp same_identity(%PersonAssertion{}, _held), do: refused(:assertion, :wrong_identifier)

  defp verified_assertion(assertion, state, held, home) do
    {:ok, challenge} = Encoding.unb64(held["challenge"], @challenge_bytes)

    case PersonAssertion.verify(assertion, state,
           audience: home,
           challenge: challenge,
           action_id: held["action_id"],
           now: now_ms()
         ) do
      {:ok, assertion} -> {:ok, assertion}
      {:error, reason} -> refused(:assertion, reason)
    end
  end

  # ---------------------------------------------------------------------------
  # Shared
  # ---------------------------------------------------------------------------

  # The identity's head, read from its directory now, whatever the cache
  # says: admission never rests on a cached head. The genesis locates the
  # directory only when nothing is cached; a cached binding is the
  # identifier's for good.
  defp fresh_state(identifier, genesis) do
    case IdentityFreshness.fresh!(identifier, genesis: genesis) do
      {:ok, head} ->
        with {:ok, state} <- Client.state(head),
             :ok <- same_genesis(head, genesis, identifier) do
          {:ok, state}
        else
          {:error, :corrupt} -> {:error, :unavailable}
          {:error, _reason} = refusal -> refusal
        end

      {:refused, :identity_stale} ->
        {:error, :identity_stale}

      {:error, :unavailable} ->
        {:error, :unavailable}
    end
  end

  defp same_genesis(%{genesis: cached}, genesis, identifier) do
    case Identity.locate(genesis, identifier) do
      {:ok, located} ->
        if Identity.canonical(located) == cached, do: :ok, else: {:error, :invalid_carry}

      {:error, _mismatch} ->
        {:error, :invalid_carry}
    end
  end

  defp refused(what, reason) do
    Logger.info(
      "[Sanctum.Auth.CyfrDoor] a #{what} was refused: " <> Prima.LoggerContext.shape(reason)
    )

    {:error, {:refused, refusal_reason(reason)}}
  end

  defp refusal_reason(reason) when is_atom(reason), do: reason
  defp refusal_reason({reason, _detail}) when is_atom(reason), do: reason

  defp skew_ms do
    case Arca.PlatformSettings.effective("clock_skew_seconds") do
      {:ok, seconds} when is_integer(seconds) and seconds >= 0 -> {:ok, seconds * 1_000}
      {:ok, _other} -> {:error, :unavailable}
      {:error, :unavailable} -> {:error, :unavailable}
      {:error, reason} -> raise "[Sanctum.Auth.CyfrDoor] clock_skew_seconds is #{reason}"
    end
  end

  @doc """
  The session token a held challenge's admission mints: an HMAC, under a
  key derived for this purpose, over the browser secret and the challenge
  id. A retried login recomputes it from the cookie it still holds and
  finds the one session that admission minted; no one without that
  cookie can.
  """
  @spec session_token(held()) :: String.t()
  def session_token(%{"browser_secret" => secret, "challenge_id" => challenge_id})
      when is_binary(secret) and is_binary(challenge_id) do
    :hmac
    |> :crypto.mac(
      :sha256,
      Sanctum.Consent.Authz.derived_key("cyfr-door-session"),
      secret <> "|" <> challenge_id
    )
    |> Base.url_encode64(padding: false)
  end

  defp binding_digest(%{"browser_secret" => secret}), do: Prima.Digest.sha256(secret)

  defp assertion_digest(%PersonAssertion{} = assertion),
    do: assertion |> PersonAssertion.encode() |> Encoding.jcs!() |> Prima.Digest.sha256()

  defp now_ms, do: System.os_time(:millisecond)
end
