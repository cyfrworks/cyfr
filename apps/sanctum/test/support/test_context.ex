# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.TestContext do
  @moduledoc """
  Permissive Context helpers for the suite. It lives in `test/support`,
  which only `MIX_ENV=test` compiles, so no other build holds it.

  Production code must build contexts via `Sanctum.Context.build/1`
  (with a real namespace claimed via cyfr.run) or use
  `Sanctum.system_context/0` for platform-scope tasks.
  """

  alias Sanctum.Context

  # The athanor every permissive test context works in. Tenant rows carry
  # no foreign key, so most fixtures need no row; the standing-channel
  # gates (API keys, webhooks, schedules) do read the athanor's status, so
  # the suite seeds the well-known test athanors once (`seed_athanors!/0`)
  # and `athanor!/0` returns this one.
  @athanor_id "ath_test"

  @doc "The athanor id `local/0` contexts carry."
  def athanor_id, do: @athanor_id

  @doc """
  Insert the well-known test athanor rows (idempotent). Called from each
  app's `test_helper.exs` after the migrations ran, before ExUnit starts.

  The roster is `Arca.Test.Actor`'s: an `athanors` row is the persistence
  layer's, and both suites name the same ids.
  """
  defdelegate seed_athanors!(), to: Arca.Test.Actor

  @doc "Two contexts working in different athanors."
  @spec two_contexts() :: {Context.t(), Context.t()}
  def two_contexts do
    {context_in("ath_a", "user_a"), context_in("ath_b", "user_b")}
  end

  defp context_in(athanor_id, user_id) do
    Context.build(
      user_id: user_id,
      namespace: user_id,
      athanor_id: athanor_id,
      permissions: [:*],
      scope: :athanor,
      auth_method: :oidc,
      authenticated: true
    )
  end

  @doc """
  Mark `athanor_id` filled — what a test says when it drives a turn —
  with the shipped AQUA tree and bundle copied in, as a fill copies
  them, so the athanor has a soul to answer with.

  A turn pins the baseline consent provisioning mints, so an athanor a
  test chats in is one that has been set up. Left off by default: the
  seeded rows are bare athanors, as a fresh server's are, and a
  server-wide sweep must not find work on every one of them.
  """
  def provisioned!(athanor_id) when is_binary(athanor_id) do
    {:ok, athanor} = Sanctum.Tenancy.Athanors.get(athanor_id)
    shipped!(athanor_id)

    case athanor.provisioned_at do
      nil ->
        {:ok, filled} = Sanctum.Tenancy.Athanors.mark_provisioned(athanor)
        filled

      _ ->
        athanor
    end
  end

  @doc """
  Copy every shipped unit the athanor lacks into `athanor_id` — the
  shipped AQUA tree and the bundle — without marking it provisioned.
  """
  def shipped!(athanor_id) when is_binary(athanor_id) do
    ctx = Sanctum.internal_context(user_id: "_seed", athanor_id: athanor_id, scope: :athanor)

    for root <- Arca.Storage.overlay_roots() do
      {:ok, _copied} = Arca.Overlay.materialize_shipped(Sanctum.Context.actor(ctx), root)
    end

    :ok
  end

  @doc """
  Ensure the athanor row behind `local/0` exists and return it.
  """
  def athanor! do
    case Sanctum.Tenancy.Athanors.get(@athanor_id) do
      {:ok, athanor} ->
        athanor

      {:error, :not_found} ->
        {:ok, athanor} =
          Sanctum.Tenancy.Athanors.create(%{
            id: @athanor_id,
            kind: "group",
            name: "Test",
            slug: "test",
            created_by: "system"
          })

        athanor
    end
  end

  @doc """
  Build a permissive single-user test Context with namespace `"testns"`
  (override via `:sanctum, :default_test_namespace`), working in the
  `"ath_test"` athanor.

  Impersonates a logged-in user (`auth_method: :oidc`) so tests exercise
  the same authorization path production does.
  Use this in tests, factories and fixtures.
  """
  def local do
    ns = Application.get_env(:sanctum, :default_test_namespace, "testns")

    Context.build(
      user_id: "local|local|#{ns}",
      provider: "local",
      namespace: ns,
      athanor_id: @athanor_id,
      permissions: Context.person_permissions(),
      scope: :athanor,
      auth_method: :oidc,
      authenticated: true
    )
  end

  # The admission path a case models, and the origin each one gives the
  # context it builds (`Prima.Origin`), whatever credential is behind it.
  @admission_paths %{
    prism: :interactive,
    device: :interactive,
    api: :programmatic,
    mcp: :programmatic,
    schedule: :schedule,
    webhook: :webhook
  }

  @doc """
  `local/0` admitted through `path` (`via/2`): the context a run started
  there carries.
  """
  @spec local(atom() | nil) :: Context.t()
  def local(path), do: via(local(), path)

  @doc """
  `ctx` as the admission path `path` builds it: `:prism` and `:device`
  give `interactive`, `:api` and `:mcp` give `programmatic`, `:schedule`
  and `:webhook` give their own. The origin is the path's, never the
  credential's, so the context's authentication is left as it is. `nil`
  is a context with no origin, for the cases a missing origin must
  refuse.

  `local/0` names no path, so a root a case runs without saying how it
  was admitted is refused, as it is in production.
  """
  @spec via(Context.t(), atom() | nil) :: Context.t()
  def via(%Context{} = ctx, nil), do: %{ctx | origin: nil}

  def via(%Context{} = ctx, path) when is_map_key(@admission_paths, path),
    do: %{ctx | origin: Map.fetch!(@admission_paths, path)}

  def via(%Context{}, path),
    do:
      raise(
        ArgumentError,
        "no admission path #{inspect(path)}: one of #{inspect(Map.keys(@admission_paths))}"
      )

  @doc "The admission paths `via/2` knows, each with the origin it gives."
  @spec admission_paths() :: %{atom() => Prima.Origin.t()}
  def admission_paths, do: @admission_paths

  @doc """
  The context's identity signed in: the `users` row minted (or found)
  for `ctx.user_id` read as an IdP identity key, and the context re-named
  by the person's own id — what every request carries after admission.
  Returns the context and the row.
  """
  def person!(%Context{} = ctx, attrs \\ %{}) do
    {:ok, user} =
      Sanctum.Tenancy.Users.upsert_from_provider(
        Map.merge(
          %{
            id: ctx.user_id,
            provider: ctx.provider || "local",
            email: ctx.email,
            verified: true
          },
          attrs
        )
      )

    {%{ctx | user_id: user.id}, user}
  end

  @doc """
  The generations the context's person and athanor stand at, read from
  their rows (`Sanctum.Tenancy.generation_snapshot/2`): what a fixture
  that builds an issuing context by hand passes as `generation_snapshot:`
  to `Sanctum.Session.create/2` or `Sanctum.ApiKey.create/3`. The
  issuance still locks and rereads both rows.
  """
  def snapshot!(%Context{user_id: user_id, athanor_id: athanor_id}) do
    {:ok, snapshot} = Sanctum.Tenancy.generation_snapshot(user_id, athanor_id)
    snapshot
  end

  @doc """
  `Sanctum.Session.create/2` for a context a fixture built by hand, with
  the `generation_snapshot:` its rows stand at now (`snapshot!/1`).
  """
  def create_session(%Context{} = ctx),
    do: Sanctum.Session.create(ctx, generation_snapshot: snapshot!(ctx))

  @doc """
  `Sanctum.ApiKey.create/3` for a context a fixture built by hand, with
  the `generation_snapshot:` its rows stand at now (`snapshot!/1`), and the
  fresh confirmation minting a key needs (`confirmed/3`). The context
  names a person from here on, as `confirmed/3` answers it.
  """
  def create_key(%Context{} = ctx, attrs) do
    ctx =
      confirmed(ctx, :credential_issuance, %{
        operation: "key.create",
        arguments: attrs,
        resource: Map.fetch!(attrs, :name)
      })

    Sanctum.ApiKey.create(ctx, attrs, generation_snapshot: snapshot!(ctx))
  end

  # ---------------------------------------------------------------------------
  # Fresh confirmation
  # ---------------------------------------------------------------------------

  @doc """
  `ctx` holding a proven confirmation of the sensitive change `change`
  (`t:Sanctum.Consent.Authz.change/0`), which confirms `action`: the
  context the deciding site then consumes it under, `confirmation_id`
  naming the record.

  The change must be exactly the one the deciding site passes: its
  operation, its arguments as the call passes them, and its resource
  and details, since the record binds them all. The proof is real, and
  goes through production code alone:

    * the context is given a real person when it names none
      (`person!/2`);
    * the person's software passkey (`Sanctum.TestContext.Authenticator`)
      is registered once, as `Sanctum.Passkeys.register/2` has the person
      register their first (`passkey!/1`): confirmed with the code mailed
      to their verified email, or, for a person who holds no fresh method,
      at once under the local first-method rule;
    * the record is opened by `Sanctum.Consent.Authz.check/3` under
      `ctx`, so `ctx`'s own credential is its opener and alone repeats
      the change, and proven by the passkey's assertion over its digest
      (`Sanctum.Passkeys.assert/3`), from the person's interactive
      surface, whatever surface `ctx` itself is: a key's context repeats
      the change it asked for once its person proved it in Prism.

  A person whose first method was ever used, who holds no fresh method
  and no passkey this helper made, raises: a test that needs that path
  drives it itself. A person without standing (denied, or no longer a
  member where the registration is asked) can prove nothing: the context
  is answered without a confirmation, and the deciding site refuses them
  as it would, which is what a test of their ejection asserts.
  """
  @spec confirmed(Context.t(), atom(), map()) :: Context.t()
  def confirmed(%Context{} = ctx, action, change) do
    ctx = %{person_ctx!(ctx) | confirmation_id: nil}

    case passkey(ctx.user_id) do
      {:ok, authenticator} ->
        case Sanctum.Consent.Authz.check(ctx, action, change) do
          {:error, {:confirmation_required, %{id: id}}} ->
            prove!(ctx, id, authenticator)
            %{ctx | confirmation_id: id}

          other ->
            raise "confirmed/3: #{change.operation} asked no confirmation: #{inspect(other)}"
        end

      {:error, {:no_standing, _refusal}} ->
        ctx

      {:error, other} ->
        raise "confirmed/3: #{ctx.user_id}'s passkey could not be made: #{inspect(other)}"
    end
  end

  @doc """
  Run `fun` under `ctx`, made a person's as `confirmed/3` makes it, and
  when it answers the confirmation signal, prove that record as
  `confirmed/3` proves one (`prove!/3`) and run `fun` once more naming
  it: the person confirming in Prism and the page repeating its change.
  For a change reached through a provider or a surface, whose exact
  arguments the provider builds; any other answer is `fun`'s own.
  """
  @spec confirming(Context.t(), (Context.t() -> term())) :: term()
  def confirming(%Context{} = ctx, fun) when is_function(fun, 1) do
    ctx = %{person_ctx!(ctx) | confirmation_id: nil}
    authenticator = passkey!(ctx.user_id)

    case fun.(ctx) do
      {:error, {:confirmation_required, %{id: id}}} ->
        prove!(ctx, id, authenticator)
        fun.(%{ctx | confirmation_id: id})

      other ->
        other
    end
  end

  @doc """
  `confirmed/3` for the change the deciding site of `operation`
  (`tool.action`) passes for `arguments`, naming `resource`: the action is
  the table's (`Sanctum.Pairing.action_for/1`). Every credential site
  names its resource by name (the entry, the key, the webhook, the OAuth
  provider).
  """
  @spec confirmed_change(Context.t(), String.t(), map(), String.t() | nil) :: Context.t()
  def confirmed_change(%Context{} = ctx, operation, arguments, resource) do
    action =
      Sanctum.Pairing.action_for(operation) ||
        raise ArgumentError, "#{operation} confirms nothing"

    confirmed(ctx, action, %{operation: operation, arguments: arguments, resource: resource})
  end

  # ---------------------------------------------------------------------------
  # The credential sites, each under the confirmation its change needs
  # ---------------------------------------------------------------------------

  @doc "`Sanctum.ApiKey.rotate/3` under the confirmation it needs (`confirmed_change/4`)."
  def rotate_key(%Context{} = ctx, name, issuance \\ []) do
    ctx
    |> confirmed_change("key.rotate", %{name: name}, name)
    |> Sanctum.ApiKey.rotate(name, issuance)
  end

  @doc "`Sanctum.Webhook.create/2` under the confirmation it needs (`confirmed_change/4`)."
  def create_webhook(%Context{} = ctx, opts) do
    ctx
    |> confirmed_change("webhook.create", opts, opts[:name])
    |> Sanctum.Webhook.create(opts)
  end

  @doc "`Sanctum.Webhook.rotate/2` under the confirmation it needs (`confirmed_change/4`)."
  def rotate_webhook(%Context{} = ctx, name) do
    ctx
    |> confirmed_change("webhook.rotate", %{name: name}, name)
    |> Sanctum.Webhook.rotate(name)
  end

  @doc "`Sanctum.Vault.create/2` under the confirmation it needs (`confirmed_change/4`)."
  def create_vault(%Context{} = ctx, params) do
    ctx
    |> confirmed_change("vault.create", params, params[:name])
    |> Sanctum.Vault.create(params)
  end

  @doc """
  `Sanctum.Vault.rotate/2` under the confirmation it needs
  (`confirmed_change/4`), naming the entry as the vault names it.
  """
  def rotate_vault(%Context{} = ctx, %{id: id} = params) do
    ctx
    |> confirmed_change("vault.rotate", params, entry_name(ctx, id))
    |> Sanctum.Vault.rotate(params)
  end

  @doc """
  `Sanctum.Vault.OAuthGrant.authorize_url/2` under the confirmation it
  needs (`confirmed_change/4`), naming the entry as the grant names it:
  the new entry's name, or the entry re-authorized.
  """
  def authorize_vault(%Context{} = ctx, params) do
    name =
      case params do
        %{entry_id: id} -> entry_name(ctx, id)
        _new -> params[:name]
      end

    ctx
    |> confirmed_change("vault.authorize", params, name)
    |> Sanctum.Vault.OAuthGrant.authorize_url(params)
  end

  @doc """
  `Sanctum.ProviderCredentials.put/4` under the confirmation it needs
  (`confirmed_change/4`).
  """
  def put_provider_credentials(%Context{} = ctx, provider, client_id, client_secret \\ nil) do
    ctx
    |> confirmed_change(
      "oauth.set_client",
      %{provider: provider, client_id: client_id, client_secret: client_secret},
      provider
    )
    |> Sanctum.ProviderCredentials.put(provider, client_id, client_secret)
  end

  defp entry_name(ctx, id) do
    case Arca.VaultStorage.get(Context.actor(ctx), id) do
      {:ok, %{name: name}} -> name
      _missing -> nil
    end
  end

  # The context as a person's: an IdP identity key signed in (`person!/2`),
  # a person id a fixture made up minted as that person with their keys,
  # a person already here as they are.
  defp person_ctx!(%Context{user_id: user_id} = ctx) do
    cond do
      not Prima.PersonId.person?(user_id) ->
        # A fixture's bare name reads as a local door's identity.
        key =
          if Sanctum.Auth.Identity.key?(user_id), do: user_id, else: "local|local|" <> user_id

        {person, _user} = person!(%{ctx | user_id: key})
        person

      match?({:ok, _person}, Sanctum.Tenancy.Users.get(user_id)) ->
        ctx

      true ->
        now = DateTime.utc_now()

        {:ok, _person} =
          Arca.Users.mint(
            Prima.Actor.system(),
            %{
              id: user_id,
              provider: "local",
              prefs: "{}",
              first_seen_at: now,
              last_seen_at: now,
              created_at: now,
              updated_at: now
            },
            %{
              key: "local|local|" <> user_id,
              provider: "local",
              issuer: "local",
              subject: user_id,
              first_seen_at: now,
              last_seen_at: now
            },
            also: &Sanctum.Person.mint_keys/1
          )

        ctx
    end
  end

  @doc """
  Prove the pending confirmation whose secret `id` the signal answered
  (or, given a `cnr_` ref, the record it names) of `ctx`'s person with
  the software passkey `authenticator` (`passkey!/1`'s by default), from
  the person's interactive surface in `ctx`'s athanor, naming the record
  by its ref as any client of the person does. Answers the confirmed
  record.
  """
  def prove!(%Context{} = ctx, id, authenticator \\ nil) do
    authenticator = authenticator || passkey!(ctx.user_id)
    ref = if Prima.Confirmation.ref?(id), do: id, else: Prima.Confirmation.ref(id)
    {:ok, row} = Arca.PendingConfirmations.get(Context.actor(ctx), ref)
    "sha256:" <> hex = row.digest

    assertion =
      Sanctum.TestContext.Authenticator.assertion(
        authenticator,
        Base.decode16!(hex, case: :lower)
      )

    {:ok, confirmed} = Sanctum.Passkeys.assert(interactive(ctx), ref, assertion)
    confirmed
  end

  # The person's own interactive surface, in the same athanor: where a
  # confirmation is proven, whatever surface asked for it.
  defp interactive(%Context{} = ctx),
    do: %{ctx | auth_method: :oidc, client_id: nil, plane: :external}

  @doc """
  The person `user_id`'s software passkey, registered at this home once,
  as `Sanctum.Passkeys.register/2` has the person register their first.
  Answers the authenticator.

  A person who holds a fresh method here confirms the registration. A
  fixture person (`person!/2`) holds one: a verified email, whose code the
  suite's transport (`MailSink`) delivers to the asking process. The
  registration is asked and confirmed on a new session of a local door
  focused on the person's own athanor, minted for them as admission
  mints one (`Sanctum.Provisioning.ensure_personal_athanor/1`) when they
  have none, and the code mailed to them proves it. A person who holds no
  fresh method (one with no email) registers it at once under the local
  first-method rule; a test of that rule builds such a person itself.
  """
  def passkey!(user_id) when is_binary(user_id) do
    case passkey(user_id) do
      {:ok, authenticator} ->
        authenticator

      {:error, {:no_standing, refusal}} ->
        raise "passkey!/1: #{user_id} has no standing to register a passkey: #{inspect(refusal)}"

      {:error, other} ->
        raise "passkey!/1: #{user_id}'s first passkey was not registered: #{inspect(other)}"
    end
  end

  # `passkey!/1` without the raise: `{:error, {:no_standing, refusal}}`
  # when the person cannot register one here (denied, or without the seat
  # the registration is asked in), `{:error, other}` for anything else.
  @standing_refusals [:not_standing, :unauthenticated, :denied, :not_member]
  defp passkey(user_id) do
    authenticator = Sanctum.TestContext.Authenticator.for_person(user_id)
    credential_id = Base.url_encode64(authenticator.credential_id, padding: false)

    case Arca.Passkeys.get_by_credential(
           Prima.Actor.system(),
           Sanctum.Passkeys.rp_id(),
           credential_id
         ) do
      {:ok, %{state: "active", user_id: ^user_id}} ->
        {:ok, authenticator}

      _none ->
        person = Context.build(user_id: user_id, auth_method: :oidc, authenticated: true)

        registered =
          if Sanctum.Passkeys.fresh_method?(person),
            do: confirmed_passkey(user_id, authenticator),
            else: first_passkey(user_id, authenticator)

        case registered do
          {:ok, _} = ok ->
            ok

          {:error, refusal} when refusal in @standing_refusals ->
            {:error, {:no_standing, refusal}}

          {:error, {refusal, _}} when refusal in @standing_refusals ->
            {:error, {:no_standing, refusal}}

          {:error, _} = error ->
            error

          other ->
            {:error, other}
        end
    end
  end

  # The local first-method rule, on a session focused nowhere: a passkey is
  # the person's, and the write rechecks the session and the person alone,
  # whatever seat a fixture's person holds or lacks.
  defp first_passkey(user_id, authenticator) do
    session = %{session!(user_id) | athanor_id: nil}

    with {:ok, options} <- Sanctum.Passkeys.register(session, %{}),
         credential = Sanctum.TestContext.Authenticator.registration(authenticator, options),
         {:ok, %{status: "active"}} <-
           Sanctum.Passkeys.register(session, %{credential: credential}) do
      {:ok, authenticator}
    end
  end

  # The registration a fresh method confirms, asked on a session focused on
  # the person's own athanor (a confirmation is opened in an athanor) and
  # proven with the code mailed to their verified email.
  defp confirmed_passkey(user_id, authenticator) do
    with {:ok, athanor_id} <- own_athanor(user_id),
         session = session!(user_id, "local", athanor_id),
         {:ok, options} <- Sanctum.Passkeys.register(session, %{}),
         credential = Sanctum.TestContext.Authenticator.registration(authenticator, options),
         {:error, {:confirmation_required, %{id: id}}} <-
           Sanctum.Passkeys.register(session, %{credential: credential}),
         :ok <- mailed_proof(session, Prima.Confirmation.ref(id)),
         {:ok, %{status: "active"}} <-
           Sanctum.Passkeys.register(%{session | confirmation_id: id}, %{credential: credential}) do
      {:ok, authenticator}
    else
      {:ok, %{status: "active"}} -> {:ok, authenticator}
      other -> other
    end
  end

  # The confirmation `ref` proven with the code the suite's transport
  # delivers to this process.
  defp mailed_proof(session, ref) do
    with {:ok, %{method: "email"}} <- Sanctum.Auth.EmailVerification.send_code(session, ref) do
      receive do
        {:confirmation_code_mail, mail} ->
          code = Sanctum.TestContext.MailSink.code(mail)

          case Sanctum.Auth.EmailVerification.verify_code(session, ref, code) do
            {:ok, %{state: "confirmed"}} -> :ok
            other -> other
          end
      after
        5_000 -> {:error, :no_code_mailed}
      end
    end
  end

  # The person's own athanor, minted as admission mints it when they have
  # none.
  # An athanor the person has standing in, where the registration can be
  # asked: their personal athanor when they hold a seat there (a fixture
  # may have made the athanor by hand, without one), otherwise any
  # athanor they sit in, otherwise one provisioned for them as admission
  # provisions it. A person provisioning refuses (denied, or gone) has
  # no standing.
  defp own_athanor(user_id) do
    with {:ok, rows} <- Sanctum.Tenancy.Members.list_by_user(user_id) do
      seats = for %{scope: "athanor", athanor_id: id} <- rows, is_binary(id), do: id

      personal =
        case Sanctum.Tenancy.Users.personal_athanor_id(user_id) do
          {:ok, id} -> id
          :none -> nil
        end

      cond do
        personal in seats -> {:ok, personal}
        seats != [] -> {:ok, hd(seats)}
        true -> provisioned_athanor(user_id)
      end
    end
  end

  defp provisioned_athanor(user_id) do
    with {:ok, user} <- Sanctum.Tenancy.Users.get(user_id),
         {:ok, athanor} <- Sanctum.Provisioning.ensure_personal_athanor(user) do
      {:ok, athanor.id}
    else
      {:error, _refused} -> {:error, :not_standing}
    end
  end

  @doc """
  A context loaded from a new session of the person `user_id`, as the
  console holds one: `provider` (default `"local"`) is the door the
  session records, which the first-method rule reads, and `athanor_id`
  (default none) the athanor it is focused on, one the person stands in.
  """
  def session!(user_id, provider \\ "local", athanor_id \\ nil) when is_binary(user_id) do
    base =
      Context.build(
        user_id: user_id,
        provider: provider,
        athanor_id: athanor_id,
        permissions: Context.person_permissions(),
        auth_method: :oidc
      )

    {:ok, session} = Sanctum.Session.create(base, generation_snapshot: snapshot!(base))
    {:ok, loaded} = Sanctum.Session.load(session.token, surface: :console)
    loaded
  end

  defmodule MailSink do
    @moduledoc """
    The suite's transport for one-time confirmation codes
    (`:sanctum, :confirmation_code_transport` in `config/test.exs`): each
    message is sent to the process that asked for it, and to the
    processes it was asked on behalf of, as
    `{:confirmation_code_mail, %{to:, subject:, text:}}`.
    """

    @doc false
    def deliver(%{to: _, subject: _, text: _} = message) do
      for pid <- [self() | Process.get(:"$callers", [])],
          do: send(pid, {:confirmation_code_mail, message})

      :ok
    end

    @doc "The code a captured message carries."
    def code(%{text: text}) do
      [code] = Regex.run(~r/\b(\d{6})\b/, text, capture: :all_but_first)
      code
    end
  end

  defmodule Authenticator do
    @moduledoc """
    A software WebAuthn authenticator for the suite: an ES256 key pair and
    a credential id, derived from a seed so every process of a test finds
    the same one for the same person. It answers a registration with
    attestation `none`, and an assertion over any challenge, with user
    presence and verification set unless told otherwise. Its counter is
    `0` unless a test gives one: an authenticator that keeps no counter.
    """

    defstruct [:credential_id, :private_key, :public_key]

    @doc "The authenticator a seed derives."
    def new(seed) when is_binary(seed) do
      private = :crypto.hash(:sha256, ["cyfr-test-authenticator|", seed])
      {public, private} = :crypto.generate_key(:ecdh, :secp256r1, private)
      credential_id = binary_part(:crypto.hash(:sha256, ["cyfr-test-credential|", seed]), 0, 16)
      %__MODULE__{credential_id: credential_id, private_key: private, public_key: public}
    end

    @doc "The person `user_id`'s authenticator."
    def for_person(user_id), do: new("person|" <> user_id)

    @doc """
    The browser's answer to `options` (`Sanctum.Passkeys.register/2`'s
    answer without a credential). `opts`: `:origin`, `:rp_id`, `:uv`
    (default `true`), `:count` (default `0`), `:challenge` (in place of the
    options').
    """
    def registration(
          %__MODULE__{} = auth,
          %{public_key: public_key, registration: token},
          opts \\ []
        ) do
      challenge = Keyword.get(opts, :challenge, public_key["challenge"])
      rp_id = Keyword.get(opts, :rp_id, public_key["rp"]["id"])

      client_data =
        Jason.encode!(%{
          "type" => "webauthn.create",
          "challenge" => challenge,
          "origin" => Keyword.get(opts, :origin, Sanctum.Passkeys.origin()),
          "crossOrigin" => false
        })

      <<4, x::binary-size(32), y::binary-size(32)>> = auth.public_key
      cose = cbor(%{1 => 2, 3 => -7, -1 => 1, -2 => {:bytes, x}, -3 => {:bytes, y}})

      auth_data =
        :crypto.hash(:sha256, rp_id) <>
          <<flags(opts, 0x40)::8, Keyword.get(opts, :count, 0)::32>> <>
          <<0::128>> <> <<byte_size(auth.credential_id)::16>> <> auth.credential_id <> cose

      attestation =
        cbor(%{"fmt" => "none", "attStmt" => %{}, "authData" => {:bytes, auth_data}})

      %{
        "id" => b64(auth.credential_id),
        "rawId" => b64(auth.credential_id),
        "type" => "public-key",
        "registration" => token,
        "response" => %{
          "clientDataJSON" => b64(client_data),
          "attestationObject" => b64(attestation)
        }
      }
    end

    @doc """
    The browser's answer to a request whose challenge is `challenge`
    (raw bytes). `opts`: `:origin`, `:rp_id` (default this home's), `:uv`
    (default `true`), `:count` (default `0`), `:type` (default
    `"webauthn.get"`).
    """
    def assertion(%__MODULE__{} = auth, challenge, opts \\ []) when is_binary(challenge) do
      client_data =
        Jason.encode!(%{
          "type" => Keyword.get(opts, :type, "webauthn.get"),
          "challenge" => b64(challenge),
          "origin" => Keyword.get(opts, :origin, Sanctum.Passkeys.origin()),
          "crossOrigin" => false
        })

      auth_data =
        :crypto.hash(:sha256, Keyword.get(opts, :rp_id, Sanctum.Passkeys.rp_id())) <>
          <<flags(opts, 0)::8, Keyword.get(opts, :count, 0)::32>>

      signature =
        :crypto.sign(
          :ecdsa,
          :sha256,
          auth_data <> :crypto.hash(:sha256, client_data),
          [auth.private_key, :secp256r1]
        )

      %{
        "id" => b64(auth.credential_id),
        "rawId" => b64(auth.credential_id),
        "type" => "public-key",
        "response" => %{
          "clientDataJSON" => b64(client_data),
          "authenticatorData" => b64(auth_data),
          "signature" => b64(signature)
        }
      }
    end

    # User presence always; user verification unless `uv: false`; and the
    # attested-credential flag a registration adds.
    defp flags(opts, extra) do
      uv = if Keyword.get(opts, :uv, true), do: 0x04, else: 0
      Bitwise.bor(Bitwise.bor(0x01, uv), extra)
    end

    defp b64(bytes), do: Base.url_encode64(bytes, padding: false)

    # The CBOR the two answers need: integers, text, `{:bytes, _}` byte
    # strings and maps.
    defp cbor(value) when is_integer(value) and value >= 0, do: head(0, value)
    defp cbor(value) when is_integer(value), do: head(1, -1 - value)
    defp cbor({:bytes, bytes}), do: head(2, byte_size(bytes)) <> bytes
    defp cbor(text) when is_binary(text), do: head(3, byte_size(text)) <> text

    defp cbor(map) when is_map(map) do
      Enum.reduce(map, head(5, map_size(map)), fn {key, value}, acc ->
        acc <> cbor(key) <> cbor(value)
      end)
    end

    defp head(major, n) when n < 24, do: <<major::3, n::5>>
    defp head(major, n) when n < 0x100, do: <<major::3, 24::5, n::8>>
    defp head(major, n) when n < 0x10000, do: <<major::3, 25::5, n::16>>
    defp head(major, n), do: <<major::3, 26::5, n::32>>
  end

  @doc """
  The context as an issuer: its identity signed in (`person!/2`) unless it
  already names a person, the test athanor's row present when it works
  there, the person seated in the athanor it works in, and the binding an
  admitted sign-in carries (`t:Sanctum.Context.credential_binding/0`,
  `source_kind: :identity`, focused through that seat) stamped from
  `snapshot!/1` — the suite's one hand-bound issuer, for the tests that
  issue through a tool rather than by calling the issuer.
  """
  def issuer!(%Context{} = ctx, attrs \\ %{}) do
    ctx =
      if Prima.PersonId.person?(ctx.user_id),
        do: ctx,
        else: ctx |> person!(attrs) |> elem(0)

    if ctx.athanor_id == @athanor_id, do: athanor!()
    snapshot = snapshot!(ctx)

    %{
      ctx
      | credential_binding: %{
          source_kind: :identity,
          source_id: nil,
          focus_basis: seat!(ctx),
          user_generation: snapshot.user_generation,
          athanor_generation: snapshot.athanor_generation
        }
    }
  end

  defp seat!(%Context{athanor_id: nil}), do: nil

  defp seat!(%Context{user_id: user_id, athanor_id: athanor_id}) do
    {:ok, seat} =
      Sanctum.Tenancy.Members.ensure(user_id, scope: "athanor", athanor_id: athanor_id)

    seat.id
  end

  @doc """
  Build a platform-scope test Context through the one sanctioned
  construction path (`Sanctum.Context.internal/1`) — `build/1` refuses
  `scope: :platform` from anywhere else.

  Defaults are `internal/1`'s (`user_id: "system"`, `auth_method: :system`,
  the four system permissions); fixtures that need the wildcard pass
  `permissions: [:*]`, and `platform_admin: true` marks the operator
  capability on the returned struct.
  """
  def platform(opts \\ []) do
    {admin?, opts} = Keyword.pop(opts, :platform_admin, false)
    ctx = Context.internal(opts)
    %{ctx | platform_admin: admin? == true}
  end
end
