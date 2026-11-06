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
  Mark `athanor_id` filled, as a fill's last write marks it, and nothing
  more — what a test says when it roots a run, which `Opus.run_root/5`
  admits only in a ready athanor (`Sanctum.Provisioning.ready/1`). The
  row is made first when the test named an athanor no fixture made.
  It copies no shipped tree in.
  """
  def ready!(athanor_id) when is_binary(athanor_id) do
    Arca.Test.Actor.ensure_athanor_row(athanor_id)
    {:ok, athanor} = Sanctum.Tenancy.Athanors.get(athanor_id)

    case athanor.provisioned_at do
      nil ->
        {:ok, filled} = mark_provisioned(athanor)
        filled

      _ ->
        athanor
    end
  end

  @doc """
  Record `athanor` provisioned and forget any failure on its row, as a
  settled fill writes it (`Sanctum.Provisioning`), with no claim behind
  it: a fixture's, never a server's. Its person's open views hear of it.
  """
  def mark_provisioned(%{id: id}) do
    now = DateTime.utc_now()

    with :ok <-
           Arca.Athanors.set(Prima.Actor.in_athanor(id),
             provisioned_at: now,
             provisioning_failed_at: nil,
             provisioning_failure: nil,
             updated_at: now
           ),
         {:ok, updated} <- Sanctum.Tenancy.Athanors.get(id) do
      Sanctum.Notify.broadcast(id, :athanor_changed, %{name: updated.name})
      {:ok, updated}
    end
  end

  @doc """
  Mark the person `user_id` the platform administrator with no admission
  behind it: a fixture's operator, the mark written straight onto their
  row in the sandbox. The product's one mark is the installation's first
  person's (`Sanctum.Newcomer`, `Sanctum.Test.People.first!/1`).
  Idempotent: answers the person's row as it stands.
  """
  def ensure_platform(user_id) when is_binary(user_id) do
    require Ecto.Query

    Arca.Repo.update_all(
      Ecto.Query.from(u in Arca.Schemas.User,
        where: u.id == ^user_id and is_nil(u.platform_admin_at)
      ),
      set: [platform_admin_at: DateTime.utc_now()]
    )

    Sanctum.Tenancy.Users.get(user_id)
  end

  @doc """
  Leave `port` (`Sanctum.Consent.Components`, `Sanctum.Proxy`) with no
  implementation installed, as a boot that installed none leaves it.
  """
  def uninstall_port(port) when port in [Sanctum.Consent.Components, Sanctum.Proxy] do
    :persistent_term.erase({port, :impl})
    :ok
  end

  @doc "The tasks `Sanctum.RunningTasks` holds registered for `request_id`."
  def running_pids(request_id) do
    for {^request_id, pid} <- :ets.lookup(Sanctum.RunningTasks, request_id), do: pid
  end

  @doc """
  Copy every shipped unit the athanor lacks into `athanor_id` — the
  shipped AQUA tree and the bundle — without marking it provisioned.
  """
  def shipped!(athanor_id) when is_binary(athanor_id) do
    ctx = Sanctum.Context.internal(user_id: "_seed", athanor_id: athanor_id, scope: :athanor)

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
            name: "Test",
            slug: "test",
            owner_user_id: local().user_id,
            created_by: "system"
          })

        athanor
    end
  end

  @doc """
  The athanor archived as its person's denial archives it: its standing
  moved (`Arca.Test.Actor.archive!/1`) and its archival announced
  (`Sanctum.Tenancy.Athanors.announce_archived/2`), which drops its
  people's context memos and stops work running in it. Answers the row.
  """
  def archive!(athanor_id) when is_binary(athanor_id) do
    athanor = Arca.Test.Actor.archive!(athanor_id)
    members = Map.new([{athanor_id, List.wrap(athanor.owner_user_id)}])

    :ok =
      Sanctum.Tenancy.Athanors.announce_archived([athanor_id], %{
        member_user_ids: members,
        athanors: [athanor]
      })

    athanor
  end

  @doc "The athanor reopened as its person's allow reopens it."
  def reopen!(athanor_id) when is_binary(athanor_id), do: Arca.Test.Actor.reopen!(athanor_id)

  @doc """
  Build a permissive single-user test Context with namespace `"testns"`,
  working in the `"ath_test"` athanor.

  Impersonates a logged-in user (`auth_method: :oidc`) so tests exercise
  the same authorization path production does.
  Use this in tests, factories and fixtures.
  """
  def local do
    ns = "testns"

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

  @doc """
  The context's identity signed in: the person `ctx.user_id`, read as the
  identity key of a linked sign-in method, names (made the first time,
  `Sanctum.Test.People.linked/1`), and the context re-named by the
  person's own id — what every request carries after admission. Returns
  the context and the row.
  """
  def person!(%Context{} = ctx, attrs \\ %{}) do
    {:ok, user} =
      Sanctum.Test.People.linked(
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
    * the person is given an account (`account!/1`): a log at the suite's
      test directory listing the person's software passkey
      (`Sanctum.TestContext.Authenticator`), whose head this CYFR has
      read, and the person's identity row naming it;
    * the record is opened by `Sanctum.Consent.Authz.check/3` under
      `ctx`, so `ctx`'s own credential is its opener and alone repeats
      the change, and confirmed by the passkey's answer to the record's
      `confirm` request (`Sanctum.SignIn`), whatever surface `ctx` itself
      is: a key's context repeats the change it asked for once its person
      proved it.

  A person without standing (no athanor, or no longer a person here)
  can prove nothing: the context is answered without a confirmation, and
  the deciding site refuses them as it would, which is what a test of
  their ejection asserts.
  """
  @spec confirmed(Context.t(), atom(), map()) :: Context.t()
  def confirmed(%Context{} = ctx, action, change) do
    ctx = %{person_ctx!(ctx) | confirmation_id: nil}
    _account = account!(ctx.user_id)

    case Sanctum.Consent.Authz.check(ctx, action, change) do
      {:error, {:confirmation_required, %{id: id}}} ->
        case prove(ctx, id) do
          {:ok, _row} -> %{ctx | confirmation_id: id}
          {:error, :no_standing} -> ctx
        end

      {:error, _refused} ->
        ctx

      other ->
        raise "confirmed/3: #{change.operation} asked no confirmation: #{inspect(other)}"
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
    _account = account!(ctx.user_id)

    case fun.(ctx) do
      {:error, {:confirmation_required, %{id: id}}} ->
        prove!(ctx, id)
        fun.(%{ctx | confirmation_id: id})

      other ->
        other
    end
  end

  # The action each credential site this suite confirms decides under
  # (`Sanctum.Pairing`'s table of actions).
  @confirmed_actions %{
    "key.create" => :credential_issuance,
    "key.rotate" => :credential_issuance,
    "webhook.create" => :credential_issuance,
    "webhook.rotate" => :credential_issuance,
    "vault.create" => :credential_entry,
    "vault.rotate" => :credential_entry,
    "vault.authorize" => :credential_entry,
    "oauth.set_client" => :credential_entry
  }

  @doc """
  `confirmed/3` for the change the deciding site of `operation`
  (`tool.action`) passes for `arguments`, naming `resource`, under the
  action that site decides. Every credential site names its resource by
  name (the entry, the key, the webhook, the OAuth provider).
  """
  @spec confirmed_change(Context.t(), String.t(), map(), String.t() | nil) :: Context.t()
  def confirmed_change(%Context{} = ctx, operation, arguments, resource) do
    action = Map.fetch!(@confirmed_actions, operation)

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
  A login entry whose program has signed in: `create_vault/2` with
  `kind: "login"`, which makes it waiting on its sign-in, then the sign-in
  whose command exited 0 (`Sanctum.Mount.signed_in/2`).
  """
  def create_signed_in_login(%Context{} = ctx, params) do
    with {:ok, view} <- create_vault(ctx, Map.put(params, :kind, "login")),
         :ok <- Sanctum.Mount.signed_in(ctx, view.id),
         do: {:ok, %{view | status: "active"}}
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
  # a person id a fixture made up minted as that person with their
  # account (`account!/1`), a person already here as they are.
  defp person_ctx!(%Context{user_id: user_id} = ctx) do
    cond do
      not Prima.PersonId.person?(user_id) ->
        # A fixture's bare name reads as a local door's identity.
        key =
          if match?([_, _, _], String.split(user_id, "|", parts: 3)),
            do: user_id,
            else: "local|local|" <> user_id

        {person, _user} = person!(%{ctx | user_id: key})
        person

      match?({:ok, _person}, Sanctum.Tenancy.Users.get(user_id)) ->
        ctx

      true ->
        now = DateTime.utc_now()

        {:ok, _person} =
          Arca.Test.People.mint(
            Prima.Actor.system(),
            %{
              id: user_id,
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
            also: fn person ->
              _account = account!(person.id)
              :ok
            end
          )

        ctx
    end
  end

  @doc """
  Remove `ctx`'s person's stored registry credential for one
  `(registry, namespace_slug)`, as losing it would.
  """
  def drop_registry_credential!(%Context{user_id: user_id}, registry, namespace_slug) do
    require Ecto.Query

    {1, _} =
      Ecto.Query.from(t in Arca.Schemas.RegistryToken,
        where:
          t.user_id == ^user_id and t.registry == ^registry and
            t.namespace_slug == ^namespace_slug
      )
      |> Arca.Repo.delete_all()

    :ok
  end

  @doc """
  The invoke-budget counter of `authority`'s root (or of a bare budget) on
  this node: its slots in flight and its cap, read from the counter's
  table (`Sanctum.Authority.BudgetCounter`), one row per budget id with
  work in flight.
  """
  def invoke_budget(%Prima.Authority{budget: budget}), do: invoke_budget(budget)

  def invoke_budget(%Prima.Authority.Budget{id: id, cap: cap}) do
    in_flight =
      case :ets.lookup(Sanctum.Authority.BudgetCounter, id) do
        [{^id, n}] -> max(n, 0)
        [] -> 0
      end

    %{in_flight: in_flight, cap: cap}
  end

  # The directory the suite's accounts live at: what their passkeys'
  # assertions name as origin and host. No request reaches it: this CYFR
  # holds each account's head as read.
  @test_directory "https://dir.example"

  @doc """
  Prove the pending confirmation whose secret `id` the signal answered
  (or, given a `cnr_` ref, the record it names) of `ctx`'s person with the
  passkey of their account (`account!/1`): this CYFR mints the record's
  `confirm` request and the passkey's answer to it confirms the record
  (`Sanctum.SignIn`), from the person's interactive surface in `ctx`'s
  athanor. Answers the confirmed record. The third argument is no longer
  read.
  """
  def prove!(%Context{} = ctx, id, _authenticator \\ nil) do
    case prove(ctx, id) do
      {:ok, row} -> row
      {:error, reason} -> raise "prove!/3: the confirmation was not proven: #{inspect(reason)}"
    end
  end

  defp prove(%Context{} = ctx, id) do
    account = account!(ctx.user_id)
    ref = if Prima.Confirmation.ref?(id), do: id, else: Prima.Confirmation.ref(id)
    binding = {:channel, "test-context-proof"}

    case Sanctum.SignIn.request(:confirm, binding,
           ctx: interactive(ctx),
           ref: ref,
           identifier: account.identifier
         ) do
      {:ok, %{request: request}} ->
        answer =
          Sanctum.TestContext.Authenticator.answer(
            account.authenticator,
            request,
            account.identifier
          )

        with {:ok, %{purpose: :confirm}} <- Sanctum.SignIn.answer(answer, binding) do
          Arca.PendingConfirmations.get(Context.actor(ctx), ref)
        end

      {:error, :unauthenticated} ->
        {:error, :no_standing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The person's own interactive surface, in the same athanor, from the
  # authenticated context that asked: where a confirmation is proven,
  # whatever surface asked for it.
  defp interactive(%Context{} = ctx),
    do: %{ctx | auth_method: :oidc, client_id: nil, plane: :external, anonymous: false}

  @doc """
  The person `user_id`'s account, made once and the same in every process
  of a test: a genesis at the suite's test directory signed by a recovery
  key, and the person's software passkey
  (`Sanctum.TestContext.Authenticator.for_person/1`) the recovery key
  added, both derived from the person's id. This CYFR caches the account's
  head as a first read leaves it, and the person's identity row names the
  account in place of any row they held. Answers `%{identifier,
  authenticator, head}`.
  """
  def account!(user_id) when is_binary(user_id) do
    alias Prima.Identity
    alias Prima.Identity.{Entry, Key}

    authenticator = Sanctum.TestContext.Authenticator.for_person(user_id)

    {recovery_pub, recovery_priv} =
      :crypto.generate_key(
        :eddsa,
        :ed25519,
        :crypto.hash(:sha256, ["cyfr-test-recovery|", user_id])
      )

    signer = Identity.recovery_signer(recovery_pub)
    at = 1_700_000_000_000

    {:ok, genesis} =
      Entry.new(
        kind: :genesis,
        seq: 0,
        at: at,
        signer: signer,
        directory: @test_directory,
        recovery: [recovery_pub]
      )

    genesis = Identity.sign(genesis, recovery_priv)

    {:ok, key} =
      Key.new(
        alg: :es256,
        kind: :passkey,
        pub: authenticator.public_key,
        credential_id: authenticator.credential_id
      )

    {:ok, added} =
      Entry.new(
        kind: :add_key,
        prev: Identity.hash(genesis),
        seq: 1,
        at: at,
        signer: signer,
        key: key
      )

    added = Identity.sign(added, recovery_priv)
    {:ok, state} = Identity.verify_chain([genesis, added])
    held!(user_id, state, Identity.canonical(genesis))
    %{identifier: state.identifier, authenticator: authenticator, head: state.head}
  end

  # The account's head cached here and the person's identity row naming
  # it, unless both already stand.
  defp held!(user_id, state, genesis) do
    import Ecto.Query, only: [from: 2]

    system = Prima.Actor.system()

    case Arca.DirectoryHeads.put(system, %{
           identifier: state.identifier,
           genesis: genesis,
           directory_url: @test_directory,
           head_hash: state.head,
           state: state |> Prima.Identity.State.encode() |> Jason.encode!()
         }) do
      {:ok, _head} -> :ok
      {:error, :exists} -> :ok
    end

    case Arca.PersonIdentities.get(system, user_id) do
      {:ok, %{identifier: identifier}} when identifier == state.identifier ->
        :ok

      _other ->
        Arca.Repo.delete_all(from(p in Arca.Schemas.PersonIdentity, where: p.user_id == ^user_id))

        {:ok, _row} =
          Arca.PersonIdentities.create(system, %{
            user_id: user_id,
            provenance: "remote",
            identifier: state.identifier,
            directory_url: @test_directory,
            head_hash: state.head
          })

        :ok
    end
  end

  @doc """
  The person `user_id`'s software passkey, the one their account lists
  (`account!/1`). Answers the authenticator.
  """
  def passkey!(user_id) when is_binary(user_id), do: account!(user_id).authenticator

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
    {:ok, loaded} = Sanctum.Session.load(session.token)
    loaded
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
    The browser's answer to a registration's `options`. `opts`: `:origin`, `:rp_id`, `:uv`
    (default `true`), `:backup_eligible` (default `false`: a credential
    that may sync), `:count` (default `0`), `:challenge` (in place of the
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
          "origin" => Keyword.get(opts, :origin, "https://dir.example"),
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
    The account pages' answer to `request` (`Prima.SignIn`) by this
    passkey, of the account `identifier`: an assertion over the request's
    digest at the suite's test directory, with user presence and
    verification.
    """
    def answer(%__MODULE__{} = auth, %Prima.SignIn{} = request, identifier) do
      digest = Prima.SignIn.digest(request)

      client_data =
        Jason.encode!(%{
          "type" => "webauthn.get",
          "challenge" => b64(digest),
          "origin" => "https://dir.example"
        })

      authenticator_data = :crypto.hash(:sha256, "dir.example") <> <<0x05, 0::32>>

      signature =
        :crypto.sign(
          :ecdsa,
          :sha256,
          authenticator_data <> :crypto.hash(:sha256, client_data),
          [auth.private_key, :secp256r1]
        )

      %Prima.SignIn.PasskeyAnswer{
        challenge: request.challenge,
        identifier: identifier,
        credential_id: auth.credential_id,
        authenticator_data: authenticator_data,
        client_data: client_data,
        signature: signature
      }
    end

    @doc """
    The browser's answer to a request whose challenge is `challenge`
    (raw bytes). `opts`: `:origin`, `:rp_id` (default the test directory's), `:uv`
    (default `true`), `:count` (default `0`), `:type` (default
    `"webauthn.get"`).
    """
    def assertion(%__MODULE__{} = auth, challenge, opts \\ []) when is_binary(challenge) do
      client_data =
        Jason.encode!(%{
          "type" => Keyword.get(opts, :type, "webauthn.get"),
          "challenge" => b64(challenge),
          "origin" => Keyword.get(opts, :origin, "https://dir.example"),
          "crossOrigin" => false
        })

      auth_data =
        :crypto.hash(:sha256, Keyword.get(opts, :rp_id, "dir.example")) <>
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

    # User presence always; user verification unless `uv: false`; backup
    # eligibility when asked; and the attested-credential flag a
    # registration adds.
    defp flags(opts, extra) do
      uv = if Keyword.get(opts, :uv, true), do: 0x04, else: 0
      be = if Keyword.get(opts, :backup_eligible, false), do: 0x08, else: 0
      0x01 |> Bitwise.bor(uv) |> Bitwise.bor(be) |> Bitwise.bor(extra)
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
  already names a person — and then focused on that person's own athanor,
  since a credential is issued only into the person's own — the test
  athanor's row present when it works there, and the binding an admitted sign-in carries
  (`t:Sanctum.Context.credential_binding/0`, `source_kind: :identity`) stamped from
  `snapshot!/1` — the suite's one hand-bound issuer, for the tests that
  issue through a tool rather than by calling the issuer.
  """
  def issuer!(%Context{} = ctx, attrs \\ %{}) do
    ctx =
      if Prima.PersonId.person?(ctx.user_id),
        do: ctx,
        else: own(person!(ctx, attrs))

    if ctx.athanor_id == @athanor_id, do: athanor!()
    snapshot = snapshot!(ctx)

    %{
      ctx
      | credential_binding: %{
          source_kind: :identity,
          source_id: nil,
          user_generation: snapshot.user_generation,
          athanor_generation: snapshot.athanor_generation
        }
    }
  end

  defp own({%Context{} = ctx, user}),
    do: %{ctx | athanor_id: Sanctum.Test.People.athanor!(user).id}

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
