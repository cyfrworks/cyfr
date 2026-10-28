# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.CompanyLogin do
  @moduledoc """
  A company sign-in as a standing condition of every person at this CYFR.

  A CYFR may require each person here to sign in with their company's
  account (`CYFR_COMPANY_LOGIN`): `:off` requires nothing, `:join` a
  binding made once, and `:renew` one made again every
  `CYFR_COMPANY_LOGIN_DAYS` days. The company's issuer is WorkOS when its
  three settings are set (`Sanctum.Auth.WorkOS`), and the configured
  OpenID Connect issuer otherwise (`Sanctum.Auth.OIDC`), which beside
  WorkOS is a linked sign-in method only. A company sign-in is not a
  sign-in method: it never creates or unlocks a person, it is never
  linked, and it never counts as a fresh confirmation.

  ## Standing

  `standing/1` is the condition, which `Sanctum.Caller` checks last on
  every path that reads a person's standing (a session's, an API key's
  creator's and a paired device's person's, at establishment and at each
  revalidation), so a passkey, a paired device, the CYFR sign-in and an
  API key all pass it alike. With the mode `:off` it reads nothing;
  otherwise it reads the person's row by its primary key
  (`Arca.CompanyAuthorizations`). A row stands only under the current
  configuration: its OpenID Connect issuer and client id are the
  configured ones, or its WorkOS organization is the configured one. Then
  `:join` needs the row, and `:renew` an `authorized_at` within the
  configured days. Anything else is `{:error, :company_login_required}`.
  A principal that is not a person is held to nothing here.

  ## The sign-in

  `held/1` answers the owner of a session refused for the company
  condition and nothing else: the one session the company page and its
  start accept. `start/1` opens an attempt for it
  (`Arca.CompanyLoginAttempts`: the person and the session, a 10-minute
  expiry, the state's hash, and for OpenID Connect the nonce and PKCE
  verifier) and answers the issuer's URL. `complete/2` takes the issuer's
  callback in three steps:

    1. it consumes the attempt once, for the state the callback carries
       and the session presenting it, while it is unconsumed and
       unexpired;
    2. it exchanges the code with the issuer outside any transaction
       (ARCHITECTURE.md §4.4: a transaction's closures call no network);
    3. in the transaction that binds (`Arca.CompanyAuthorizations.bind/3`)
       it reads again, under the person's lock, the session's standing
       (it still exists, is the attempt's person's, and is refused for
       nothing but this condition) and the company configuration (the one
       the exchange answered under). Only then is the subject bound or
       its binding refreshed.

  A revocation, a denial or a sign-out that commits during the exchange
  is read by step 3, and nothing is bound. Whatever happens after step 1,
  the attempt stays consumed, so the person starts again from the page.

  ## The binding

  The configuration a row records is
  `["oidc", issuer, client_id]` or `["workos", organization, connection]`,
  as JSON; the subject is OpenID Connect's `sub`, or WorkOS's profile `id`
  once its organization is checked against the configured one, never an
  email. A configuration change therefore makes every person bind again
  at their next company sign-in, and `Arca.CompanyAuthorizations` decides
  a subject bound to another person (`:company_subject_bound`).
  """

  alias Sanctum.Caller

  require Logger

  @attempt_ms 600_000
  @redirect_path "/auth/company/callback"

  @typedoc "Where a company sign-in was given: the issuer and client, or the organization and connection."
  @type configuration ::
          {:oidc, issuer :: String.t(), client_id :: String.t()}
          | {:workos, organization :: String.t(), connection :: String.t()}

  @typedoc """
  An attempt as an issuer is handed it: the URI the issuer returns the
  browser to, and for OpenID Connect the nonce and PKCE verifier.
  """
  @type attempt :: %{
          redirect_uri: String.t(),
          nonce: String.t() | nil,
          pkce_verifier: String.t() | nil
        }

  @typedoc "The owner of a session the company page accepts."
  @type owner :: %{user_id: String.t(), session_hash: binary()}

  @doc """
  The settings `config/runtime.exs` installed: the mode, the days (with
  `:renew` alone) and the company's issuer (`:oidc`, `:workos`, or nil
  when neither is configured).
  """
  @spec settings() :: %{
          mode: :off | :join | :renew,
          days: pos_integer() | nil,
          issuer: :oidc | :workos | nil
        }
  def settings do
    Application.get_env(:sanctum, :company_login, %{mode: :off, days: nil, issuer: nil})
  end

  @doc "Whether this CYFR requires a company sign-in at all."
  @spec required?() :: boolean()
  def required?, do: settings().mode != :off

  @doc """
  Whether the person `user_id` stands under the company condition (the
  module doc): `:ok`, `{:error, :company_login_required}`, or
  `{:error, :unavailable}` when the store cannot answer.
  """
  @spec standing(String.t() | nil) :: :ok | {:error, :company_login_required | :unavailable}
  def standing(user_id) do
    case settings() do
      %{mode: :off} ->
        :ok

      settings ->
        if Prima.PersonId.person?(user_id), do: person_standing(user_id, settings), else: :ok
    end
  end

  defp person_standing(user_id, settings) do
    case Arca.CompanyAuthorizations.get(Prima.Actor.system(), user_id) do
      {:ok, row} ->
        if stands?(row, settings), do: :ok, else: {:error, :company_login_required}

      {:error, :not_found} ->
        {:error, :company_login_required}

      {:error, _unanswered} ->
        {:error, :unavailable}
    end
  end

  defp stands?(row, %{mode: :join} = settings), do: current?(row.configuration, settings)

  defp stands?(row, %{mode: :renew, days: days} = settings) when is_integer(days) do
    current?(row.configuration, settings) and
      DateTime.diff(DateTime.utc_now(), row.authorized_at, :second) < days * 86_400
  end

  defp stands?(_row, _settings), do: false

  # A row stands under the configuration this boot names: the same
  # issuer and client, or the same WorkOS organization through any of its
  # connections.
  defp current?(stored, settings) do
    case {decode(stored), current(settings)} do
      {{:oidc, issuer, client_id}, {:oidc, issuer, client_id}} -> true
      {{:workos, organization, _connection}, {:workos, organization}} -> true
      _other -> false
    end
  end

  defp current(%{issuer: :oidc}) do
    case {Sanctum.Auth.OIDC.issuer(), Sanctum.Auth.OIDC.client_credentials()} do
      {issuer, {:ok, {client_id, _secret}}} when is_binary(issuer) -> {:oidc, issuer, client_id}
      _unconfigured -> nil
    end
  end

  defp current(%{issuer: :workos}) do
    case Sanctum.Auth.WorkOS.organization() do
      organization when is_binary(organization) -> {:workos, organization}
      _unconfigured -> nil
    end
  end

  defp current(_settings), do: nil

  @doc """
  The owner of the session `token`, when it is refused for the company
  condition and nothing else. `{:error, :standing}` for a session that
  stands, or `Sanctum.Caller`'s refusal.
  """
  @spec held(String.t() | nil) :: {:ok, owner()} | {:error, :standing | Caller.refusal()}
  def held(token) do
    case Caller.establish({:session, token}, refresh: false) do
      {:error, :company_login_required} -> owner(token)
      {:ok, _standing} -> {:error, :standing}
      {:error, reason} -> {:error, reason}
    end
  end

  # The session row the refused establishment just read, for its person;
  # no context is built from it here (`Sanctum.Caller` builds them all).
  defp owner(token) do
    hash = Sanctum.Session.token_hash(token)

    case Arca.SessionStorage.get_session(hash) do
      {:ok, %{user_id: user_id}} when is_binary(user_id) ->
        {:ok, %{user_id: user_id, session_hash: hash}}

      {:error, :database_error} ->
        {:error, :unavailable}

      _gone ->
        {:error, :unauthenticated}
    end
  end

  @doc """
  Begin a company sign-in for the session `token` (`held/1`): open its
  attempt and answer the issuer's URL. A new attempt replaces the
  person's earlier one. Refusals: `held/1`'s, `:not_required` when no
  company sign-in is configured, `:unavailable`.
  """
  @spec start(String.t() | nil) :: {:ok, String.t()} | {:error, term()}
  def start(token) do
    with {:ok, kind, issuer} <- issuer(),
         {:ok, owner} <- held(token) do
      state = secret()
      attempt = attempt(kind)

      case Arca.CompanyLoginAttempts.open(Prima.Actor.system(), %{
             user_id: owner.user_id,
             session_hash: owner.session_hash,
             state_hash: digest(state),
             nonce: attempt.nonce,
             pkce_verifier: attempt.pkce_verifier,
             lifetime_ms: @attempt_ms
           }) do
        {:ok, _opened} -> issuer.authorize_url(attempt, state)
        {:error, _unanswered} -> {:error, :unavailable}
      end
    end
  end

  defp attempt(:oidc),
    do: %{redirect_uri: redirect_uri(), nonce: secret(), pkce_verifier: secret()}

  defp attempt(:workos), do: %{redirect_uri: redirect_uri(), nonce: nil, pkce_verifier: nil}

  @doc """
  Finish a company sign-in from the issuer's callback `params`, presented
  with the session `token` (the module doc's three steps). Answers
  `{:ok, :bound}` or `{:ok, :refreshed}`, or a refusal: `:attempt_invalid`
  (no attempt for this state and session: unknown, consumed, expired, or
  another session's), `:issuer_refused`, `:wrong_organization`,
  `:session_ended` (the session no longer stands but for this
  condition), `:configuration_changed`, `:company_subject_bound`,
  `:not_required` or `:unavailable`. Nothing is bound on a refusal, and
  the attempt is spent once step 1 found it.
  """
  @spec complete(map(), String.t() | nil) :: {:ok, :bound | :refreshed} | {:error, atom()}
  def complete(params, token) do
    with {:ok, _kind, issuer} <- issuer(),
         {:ok, state, code} <- callback(params),
         {:ok, row} <- consume(state, token),
         attempt = %{
           redirect_uri: redirect_uri(),
           nonce: row.nonce,
           pkce_verifier: row.pkce_verifier
         },
         {:ok, code} <- answered(code),
         {:ok, %{configuration: configuration, subject: subject}} <-
           issuer.complete(code, attempt) do
      bind(row, configuration, subject)
    end
    |> tap(&report/1)
  end

  defp callback(%{"state" => state} = params)
       when is_binary(state) and state != "" and byte_size(state) <= 256,
       do: {:ok, state, params["code"]}

  defp callback(_params), do: {:error, :attempt_invalid}

  # The issuer's refusal (an `error` and no code) still spends the attempt.
  defp answered(code) when is_binary(code) and code != "" and byte_size(code) <= 4096,
    do: {:ok, code}

  defp answered(_none), do: {:error, :issuer_refused}

  defp consume(state, token) when is_binary(token) and token != "" do
    case Arca.CompanyLoginAttempts.consume(
           Prima.Actor.system(),
           digest(state),
           Sanctum.Session.token_hash(token)
         ) do
      {:ok, row} -> {:ok, row}
      {:error, :not_found} -> {:error, :attempt_invalid}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  defp consume(_state, _token), do: {:error, :attempt_invalid}

  # The exchange may outlast a remote person's identity freshness bound,
  # and inside a transaction their head is read from the cache alone
  # (`Sanctum.Caller`'s module doc). So the session is revalidated once
  # before the transaction, where the head may be read fresh from their
  # directory; that answer decides nothing, and the transaction's re-read
  # decides.
  defp bind(row, configuration, subject) do
    _warmed = revalidated_session(row)

    case Arca.CompanyAuthorizations.bind(
           Prima.Actor.system(),
           %{user_id: row.user_id, configuration: encode(configuration), subject: subject},
           verify: fn -> still(row, configuration) end
         ) do
      {:ok, outcome} -> {:ok, outcome}
      {:error, :subject_bound} -> {:error, :company_subject_bound}
      {:error, reason} when reason in [:session_ended, :configuration_changed] -> {:error, reason}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  # Step 3, inside the binding transaction under the person's lock: the
  # configuration is the one the exchange answered under, and the session
  # that opened the attempt still stands but for this condition.
  defp still(row, configuration) do
    if current?(encode(configuration), settings()),
      do: session_still(row),
      else: {:error, :configuration_changed}
  end

  defp session_still(row) do
    case revalidated_session(row) do
      answer when answer in [:ok, {:error, :company_login_required}] -> :ok
      {:error, reason} when reason in [:unavailable, :identity_stale] -> {:error, :unavailable}
      _ended -> {:error, :session_ended}
    end
  end

  defp revalidated_session(%{user_id: user_id, session_hash: hash}) do
    with {:ok, %{user_id: ^user_id} = ctx} <- Sanctum.Session.load_by_hash(hash),
         {:ok, _fresh} <- Caller.revalidate_session(ctx) do
      :ok
    else
      {:ok, _another_person} ->
        {:error, :unauthenticated}

      {:error, reason} when reason in [:database_error, :namespace_unavailable] ->
        {:error, :unavailable}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp report({:ok, outcome}),
    do: Logger.info("[Sanctum.CompanyLogin] a company sign-in finished: #{outcome}")

  defp report({:error, reason}),
    do: Logger.info("[Sanctum.CompanyLogin] a company sign-in was refused: #{reason}")

  defp issuer do
    case settings() do
      %{mode: mode, issuer: :oidc} when mode != :off -> {:ok, :oidc, Sanctum.Auth.OIDC}
      %{mode: mode, issuer: :workos} when mode != :off -> {:ok, :workos, Sanctum.Auth.WorkOS}
      _none -> {:error, :not_required}
    end
  end

  defp redirect_uri, do: Sanctum.Person.home() <> @redirect_path

  @doc false
  # The stored form of a configuration (the module doc).
  @spec encode(configuration()) :: String.t()
  def encode({kind, first, second}) when kind in [:oidc, :workos],
    do: Jason.encode!([Atom.to_string(kind), first, second])

  defp decode(stored) do
    case Jason.decode(stored) do
      {:ok, ["oidc", issuer, client_id]} -> {:oidc, issuer, client_id}
      {:ok, ["workos", organization, connection]} -> {:workos, organization, connection}
      _other -> nil
    end
  end

  defp secret, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
  defp digest(value), do: :crypto.hash(:sha256, value)
end
