# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.Consent.AuthzTest do
  @moduledoc """
  Who may grant a consent, and how a sensitive change is decided.

  A grant needs an interactive caller, or a key capability within its
  exact envelope, and that caller's standing read again as it is decided:
  a session that expired or is gone, a person denied, an athanor archived
  or a key revoked grants nothing. A paired device is an interactive
  caller: it previews and grants as its person's session does, while its
  certificate's deadline holds, its paired client is active and its
  person is seated. A paired client is the device channel's alone: a
  context that names one without being the channel's, or the channel's
  without its client, is refused. Tincture sessions, the guest plane and
  key overrides stay refused. No client holds a rank.

  `confirm/3`, `check/3` and `consume/2` decide a sensitive change: a
  grant and an approval need the session alone; every sensitive change
  opens, or answers, one pending confirmation for its exact person,
  athanor, operation, argument digest and preview, and goes ahead only by
  consuming that record once it was proven, with the person's standing
  read again. A caller that could never confirm is refused rather than
  asked, and so is a person whose keys are at another home.
  """
  use ExUnit.Case, async: true

  import Ecto.Query

  alias Sanctum.Consent.Authz
  alias Sanctum.Consent.Authz.Request
  alias Sanctum.Context
  alias Sanctum.Tenancy.{Athanors, Members, Users}

  @digest "sha256:commit-one"

  defp ctx(attrs) do
    Context.build(
      Map.merge(%{user_id: "user_1", authenticated: true, permissions: [:*]}, Map.new(attrs))
    )
  end

  defp request(attrs \\ []) do
    struct!(%Request{commit_digest: @digest}, attrs)
  end

  defp capability(attrs \\ []) do
    # An expiry is required — the envelope is "with an expiry", enforced.
    %{commit_digest: @digest, expires_at: DateTime.add(DateTime.utc_now(), 60, :second)}
    |> Map.merge(Map.new(attrs))
  end

  defp change(operation \\ "vault.create"),
    do: %{operation: operation, arguments: %{name: "prod-key"}, resource: "prod-key"}

  # ============================================================================
  # Standing, from the store
  # ============================================================================

  defp checkout(_tags) do
    Arca.Cache.init()
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    :ok
  end

  # A person seated in a group of their own, and the context a session
  # established for them there.
  defp standing_session(_tags) do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Users.upsert_from_provider(%{
        id: "github|https://github.com|authz-#{n}",
        provider: "github",
        email: "authz#{n}@example.com",
        verified: true
      })

    {:ok, athanor} = Athanors.create_group(user.id, "Authz #{n}")
    {:ok, _} = Members.ensure(user.id, scope: "athanor", athanor_id: athanor.id)

    built =
      Context.build(
        user_id: user.id,
        email: user.email,
        provider: "github",
        athanor_id: athanor.id,
        permissions: [:*],
        auth_method: :oidc,
        authenticated: true
      )

    {:ok, session} = Sanctum.TestContext.create_session(built)

    {:ok, session_ctx} =
      Sanctum.Caller.establish(session.token, focus: athanor.id, task_supervisor: nil)

    %{user: user, athanor: athanor, session: session, session_ctx: session_ctx}
  end

  # A key minted under that session, pinned to one real commit digest, and
  # the context the key establishes.
  defp scoped_key(%{session_ctx: session_ctx}) do
    digest = "sha256:" <> String.duplicate("ab", 32)
    name = "authz-key-#{System.unique_integer([:positive])}"
    expires_at = DateTime.add(DateTime.utc_now(), 3600, :second)

    opts = %{name: name, consent_capability: %{commit_digest: digest, expires_at: expires_at}}

    confirmed =
      Sanctum.TestContext.confirmed(session_ctx, :credential_issuance, %{
        operation: "key.create",
        arguments: opts,
        resource: name
      })

    {:ok, %{api_key: raw}} = Sanctum.ApiKey.create(confirmed, opts)

    {:ok, key_ctx} = Sanctum.Caller.establish({:api_key, raw})
    {:ok, key_capability} = Sanctum.ApiKey.consent_capability(key_ctx, key_ctx.api_key_id)

    %{key_ctx: key_ctx, key_name: name, key_digest: digest, key_capability: key_capability}
  end

  # A device paired to that person through the ceremony, and the context
  # its channel mints once it proves its key.
  defp paired_device(%{session_ctx: session_ctx}) do
    source = "192.0.2.#{rem(System.unique_integer([:positive]), 250) + 1}"
    glass = Context.build(%{authenticated: false, client_ip: source})
    {device_key, private} = :crypto.generate_key(:eddsa, :ed25519)

    confirmed =
      Sanctum.TestContext.confirmed(
        session_ctx,
        :device_pairing,
        Sanctum.Pairing.invitation_change()
      )

    {:ok, invitation} = Sanctum.Pairing.begin(confirmed, %{})

    {:ok, %{challenge: challenge}} =
      Sanctum.Pairing.complete(glass, invitation.invitation_secret, %{device_key: device_key})

    {:ok, %{client_id: client_id, certificate: certificate}} =
      Sanctum.Pairing.complete(glass, invitation.invitation_secret, %{
        device_key: device_key,
        proof: Prima.DeviceCert.Proof.sign(challenge, private)
      })

    {:ok, connect} =
      Prima.DeviceCert.Challenge.new(
        purpose: :connect,
        home: certificate.audience,
        athanor: certificate.athanor,
        client_id: client_id,
        device_key: device_key,
        nonce: :crypto.strong_rand_bytes(32),
        now: System.system_time(:millisecond)
      )

    {:ok, device_ctx} =
      Sanctum.DeviceCerts.verify_connect(
        %{client_id: client_id, certificate: certificate, source: source},
        Prima.DeviceCert.Proof.sign(connect, private),
        connect
      )

    %{device_ctx: device_ctx}
  end

  defp session_rows(hash), do: from(s in Arca.Schemas.Session, where: s.token_hash == ^hash)

  describe "a standing session" do
    setup [:checkout, :standing_session]

    test "grants, and may take an override", %{session_ctx: session_ctx} do
      assert Authz.authorize(session_ctx, request()) == {:ok, :interactive}
      assert Authz.authorize(session_ctx, request(override?: true)) == {:ok, :interactive}
    end

    test "that expired grants nothing", %{session_ctx: session_ctx} do
      past = DateTime.add(DateTime.utc_now(), -60, :second)
      Arca.Repo.update_all(session_rows(session_ctx.session_token_hash), set: [expires_at: past])

      assert Authz.authorize(session_ctx, request()) == {:error, :not_authenticated}
    end

    test "that was signed out grants nothing", %{session_ctx: session_ctx} do
      Arca.Repo.delete_all(session_rows(session_ctx.session_token_hash))

      assert Authz.authorize(session_ctx, request()) == {:error, :not_authenticated}
    end

    test "of a person since denied grants nothing", %{session_ctx: session_ctx, user: user} do
      Arca.Repo.update_all(from(u in Arca.Schemas.User, where: u.id == ^user.id),
        set: [status: "denied"]
      )

      assert Authz.authorize(session_ctx, request()) == {:error, :not_standing}
    end

    test "in an athanor since archived grants nothing", %{
      session_ctx: session_ctx,
      athanor: athanor
    } do
      Arca.Repo.update_all(from(a in Arca.Schemas.Athanor, where: a.id == ^athanor.id),
        set: [status: "archived"]
      )

      assert Authz.authorize(session_ctx, request()) == {:error, :not_standing}
    end

    test "the refusals render through the vocabulary's owner" do
      assert Authz.message(:not_standing) =~ "no longer stands"
      assert Authz.message(:unavailable) =~ "try again"
    end
  end

  describe "a paired device" do
    setup [:checkout, :standing_session, :paired_device]

    test "previews and grants a component's consent as its person's session does", %{
      device_ctx: device_ctx
    } do
      assert device_ctx.auth_method == :device
      assert Authz.authorize_staging(device_ctx) == :ok
      assert Authz.authorize_interactive(device_ctx) == {:ok, :interactive}
      assert Authz.authorize(device_ctx, request()) == {:ok, :interactive}
      assert Authz.authorize(device_ctx, request(override?: true)) == {:ok, :interactive}
    end

    test "whose pairing was revoked grants nothing", %{
      device_ctx: device_ctx,
      session_ctx: session_ctx
    } do
      client_id = device_ctx.client_id

      confirmed =
        Sanctum.TestContext.confirmed(session_ctx, :pairing_revocation, %{
          operation: "pairing.revoke",
          arguments: %{"client_id" => client_id},
          resource: client_id
        })

      {:ok, _row} = Sanctum.Pairing.revoke(confirmed, client_id)

      assert Authz.authorize(device_ctx, request()) == {:error, :not_standing}
    end

    test "whose certificate's deadline passed grants nothing, as an expired session", %{
      device_ctx: device_ctx
    } do
      expired = %{device_ctx | credential_deadline: DateTime.add(DateTime.utc_now(), -1, :second)}

      assert Authz.authorize(expired, request()) == {:error, :not_authenticated}
    end

    test "of a person since denied grants nothing", %{device_ctx: device_ctx, user: user} do
      Arca.Repo.update_all(from(u in Arca.Schemas.User, where: u.id == ^user.id),
        set: [status: "denied"]
      )

      assert Authz.authorize(device_ctx, request()) == {:error, :not_standing}
    end
  end

  describe "a paired client is the device channel's alone" do
    test "a guest-plane context carrying a client id is refused before anything else" do
      for method <- [:device, :oidc] do
        guest = Context.enter_guest(ctx(auth_method: method, client_id: "pcl_1"))

        assert Authz.authorize(guest, request()) == {:error, :guest_plane}
        assert Authz.authorize_staging(guest) == {:error, :guest_plane}
        assert Authz.authorize_interactive(guest) == {:error, :guest_plane}
      end

      # The in-chain arm stays the session's: a device's chain is refused.
      assert Authz.authorize_interactive_in_chain(
               Context.enter_guest(ctx(auth_method: :device, client_id: "pcl_1"))
             ) == {:error, {:surface_not_permitted, :device}}
    end

    test "a tincture credential, a session or a key claiming a client id is refused" do
      for method <- [:tincture, :oidc, :api_key, :session] do
        claiming = ctx(auth_method: method, client_id: "pcl_1")
        refused = {:error, {:surface_not_permitted, method}}

        assert Authz.authorize(claiming, request(key_capability: capability())) == refused
        assert Authz.authorize_staging(claiming) == refused
        assert Authz.authorize_interactive(claiming) == refused
      end
    end

    test "the channel's surface naming no client is refused" do
      unpaired = ctx(auth_method: :device)
      refused = {:error, {:surface_not_permitted, :device}}

      assert Authz.authorize(unpaired, request()) == refused
      assert Authz.authorize_staging(unpaired) == refused
      assert Authz.authorize_interactive(unpaired) == refused
    end

    test "a standing lookup that cannot reach the store is unavailable, never a denial" do
      assert Sanctum.Unauthorized.class({:consent_class_required, :unavailable}) == :unavailable

      assert Sanctum.Unauthorized.message({:consent_class_required, :unavailable}) ==
               Authz.message(:unavailable)

      # Every other consent refusal keeps its class.
      assert Sanctum.Unauthorized.class({:consent_class_required, :not_standing}) == :forbidden

      assert Sanctum.Unauthorized.class({:consent_class_required, :not_authenticated}) ==
               :unauthenticated
    end
  end

  describe "an exact digest-pinned key" do
    setup [:checkout, :standing_session, :scoped_key]

    test "commits exactly its pinned digest", %{
      key_ctx: key_ctx,
      key_digest: digest,
      key_capability: key_capability
    } do
      assert Authz.authorize(key_ctx, %Request{
               commit_digest: digest,
               key_capability: key_capability
             }) ==
               {:ok, :scoped_key}

      other = %Request{commit_digest: "sha256:" <> String.duplicate("cd", 32)}

      assert Authz.authorize(key_ctx, %{other | key_capability: key_capability}) ==
               {:error, :capability_digest_mismatch}
    end

    test "never takes an override, however caveated", %{
      key_ctx: key_ctx,
      key_digest: digest,
      key_capability: key_capability
    } do
      assert Authz.authorize(key_ctx, %Request{
               commit_digest: digest,
               key_capability: key_capability,
               override?: true
             }) == {:error, :override_requires_interactive}
    end

    test "that was revoked grants nothing", %{
      key_ctx: key_ctx,
      key_name: name,
      key_digest: digest,
      key_capability: key_capability,
      session_ctx: session_ctx
    } do
      :ok = Sanctum.ApiKey.revoke(session_ctx, name)

      assert Authz.authorize(key_ctx, %Request{
               commit_digest: digest,
               key_capability: key_capability
             }) ==
               {:error, :not_authenticated}
    end

    test "whose athanor was archived grants nothing", %{
      key_ctx: key_ctx,
      key_digest: digest,
      key_capability: key_capability,
      athanor: athanor
    } do
      Arca.Repo.update_all(from(a in Arca.Schemas.Athanor, where: a.id == ^athanor.id),
        set: [status: "archived"]
      )

      assert Authz.authorize(key_ctx, %Request{
               commit_digest: digest,
               key_capability: key_capability
             }) ==
               {:error, :not_standing}
    end

    test "a key context that names no key row stands for nothing" do
      unbound = ctx(auth_method: :api_key)

      assert Authz.authorize(unbound, request(key_capability: capability())) ==
               {:error, :not_authenticated}
    end
  end

  # ============================================================================
  # Who may consent
  # ============================================================================

  describe "interactive, in-chain" do
    # Inside a running chain every call is guest-planed, so the plane
    # conjunct is dropped for all of them; the surface conjunct is what
    # keeps a key- or schedule-started run of the same formula out.
    test "an :oidc session's chain gets through, guest plane and all" do
      assert Authz.authorize_interactive_in_chain(ctx(auth_method: :oidc, plane: :guest)) ==
               {:ok, :interactive}
    end

    test "a key, a schedule and the system plane are refused exactly as at the door" do
      for method <- [:api_key, :scheduled, :system] do
        assert {:error, {:surface_not_permitted, ^method}} =
                 Authz.authorize_interactive_in_chain(
                   ctx(auth_method: method, plane: :guest, api_key_type: :admin)
                 )
      end
    end

    test "the door still asks the plane; the chain does not" do
      guest = ctx(auth_method: :oidc, plane: :guest)
      assert {:error, _} = Authz.authorize_interactive(guest)
      assert {:ok, :interactive} = Authz.authorize_interactive_in_chain(guest)
    end
  end

  describe "interactive" do
    test "a capability without an expiry is refused, never eternal" do
      no_expiry = %{commit_digest: @digest}

      assert Authz.authorize(
               ctx(auth_method: :api_key, api_key_type: :admin),
               request(key_capability: no_expiry)
             ) ==
               {:error, :capability_expired}
    end

    test "a session a provider synthesized, with no stored credential behind it, may consent" do
      # Its establishment contract stands: nothing stored to reread.
      assert Authz.authorize(ctx(auth_method: :oidc), request()) == {:ok, :interactive}

      assert Authz.authorize(ctx(auth_method: :oidc), request(override?: true)) ==
               {:ok, :interactive}
    end

    test "permissions are never consulted" do
      # The whole reason consent is not a permission: `:*` satisfies every
      # permission check, so a permission could not exclude admin keys.
      no_permissions = ctx(auth_method: :oidc, permissions: [])
      assert Authz.authorize(no_permissions, request()) == {:ok, :interactive}
    end
  end

  describe "refused surfaces" do
    test "the tincture session upgrade cannot consent" do
      # `:session` is produced only by the tincture upgrade path — admitting
      # it would put consent on the public tincture surface.
      assert Authz.authorize(ctx(auth_method: :session), request()) ==
               {:error, {:surface_not_permitted, :session}}
    end

    test "no non-interactive surface can consent, nor the device channel's naming no client" do
      for method <- [:tincture, :webhook, :scheduled, :system, :device, nil] do
        assert {:error, {:surface_not_permitted, ^method}} =
                 Authz.authorize(ctx(auth_method: method), request()),
               "#{inspect(method)} was allowed to consent"
      end
    end

    test "an unauthenticated or anonymous caller cannot consent" do
      unauthenticated = Context.build(%{authenticated: false, auth_method: :oidc})
      assert Authz.authorize(unauthenticated, request()) == {:error, :not_authenticated}

      anonymous = ctx(auth_method: :oidc, anonymous: true)
      assert Authz.authorize(anonymous, request()) == {:error, :anonymous}
    end

    test "the guest plane is refused before anything else is considered" do
      guest = Context.enter_guest(ctx(auth_method: :oidc))
      assert Authz.authorize(guest, request()) == {:error, :guest_plane}

      # Even holding a perfectly valid capability.
      guest_key = Context.enter_guest(ctx(auth_method: :api_key))

      assert Authz.authorize(guest_key, request(key_capability: capability())) ==
               {:error, :guest_plane}
    end
  end

  # ============================================================================
  # Scoped automation, refused before standing is read
  # ============================================================================

  describe "api keys" do
    test "an admin key with no capability is rejected" do
      admin = ctx(auth_method: :api_key, api_key_type: :admin)
      assert Authz.authorize(admin, request()) == {:error, :no_capability}
    end

    test "a key caveated to a different commit is rejected" do
      key = ctx(auth_method: :api_key)
      other = capability(commit_digest: "sha256:commit-two")

      assert Authz.authorize(key, request(key_capability: other)) ==
               {:error, :capability_digest_mismatch}
    end

    test "the envelope is one exact digest — no prefixes, no patterns" do
      key = ctx(auth_method: :api_key)

      for value <- ["sha256:", "sha256:commit-on", "sha256:commit-one-and-more", "*", ""] do
        assert {:error, reason} =
                 Authz.authorize(key, request(key_capability: capability(commit_digest: value)))

        assert reason in [:capability_digest_mismatch, :no_capability]
      end
    end

    test "an expired capability is rejected, the expiry inclusive" do
      key = ctx(auth_method: :api_key)
      now = ~U[2026-08-07 12:00:00Z]

      expired = capability(expires_at: DateTime.add(now, -1, :second))

      assert Authz.authorize(key, request(key_capability: expired), now) ==
               {:error, :capability_expired}

      # Expiry is inclusive: a capability is dead the moment it expires.
      exactly_now = capability(expires_at: now)

      assert Authz.authorize(key, request(key_capability: exactly_now), now) ==
               {:error, :capability_expired}
    end

    test "overrides are rejected from any key, however caveated" do
      key = ctx(auth_method: :api_key)

      assert Authz.authorize(key, request(override?: true, key_capability: capability())) ==
               {:error, :override_requires_interactive}
    end

    test "a malformed capability is not a capability" do
      key = ctx(auth_method: :api_key)

      for bad <- [%{}, %{commit_digest: nil}, "sha256:commit-one", 42] do
        assert {:error, reason} = Authz.authorize(key, request(key_capability: bad))
        assert reason in [:no_capability, :capability_digest_mismatch]
      end
    end
  end

  # ============================================================================
  # Request validation
  # ============================================================================

  describe "request validation" do
    test "a request without a commit digest authorizes nothing" do
      session = ctx(auth_method: :oidc)

      assert Authz.authorize(session, %Request{commit_digest: ""}) == {:error, :invalid_request}
      assert Authz.authorize(session, %Request{commit_digest: nil}) == {:error, :invalid_request}
    end
  end

  # ============================================================================
  # Sensitive changes
  # ============================================================================

  defp opened!(ctx, change \\ change()) do
    assert {:error, {:confirmation_required, %{id: id, operation: operation, expires_at: at}}} =
             Authz.check(ctx, :credential_entry, change)

    assert operation == change.operation
    assert %DateTime{} = at
    id
  end

  defp record(ctx, id) do
    {:ok, row} = Arca.PendingConfirmations.get(Context.actor(ctx), id)
    row
  end

  # The announcements about `user_id`'s records alone: this module runs
  # asynchronously, and a handler hears every test's.
  defp capture(events, user_id) do
    test = self()
    id = {__MODULE__, make_ref()}

    :telemetry.attach_many(
      id,
      events,
      fn event, _measurements, meta, _ ->
        if meta[:user_id] == user_id, do: send(test, {:announced, event, meta})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  describe "a sensitive change" do
    setup [:checkout, :standing_session]

    test "a grant or an approval needs the session alone", %{session_ctx: session_ctx} do
      for action <- [:grant, :approval] do
        assert Authz.confirm(session_ctx, action, change()) == :ok
        assert Authz.check(session_ctx, action, change()) == :ok
        assert Authz.consume(session_ctx, {action, change()}) == :ok
      end

      for action <- Sanctum.Pairing.actions(), action not in [:grant, :approval] do
        assert Sanctum.Pairing.fresh_required?(action, session_ctx), inspect(action)
      end
    end

    test "from a session with no proof, answers the signal naming one record for the change",
         %{session_ctx: session_ctx, user: user} do
      capture([[:cyfr, :sanctum, :confirmation, :opened]], user.id)
      id = opened!(session_ctx)

      # Asked again, the same record answers; nothing new is opened.
      assert {:error, {:confirmation_required, %{id: ^id}}} =
               Authz.confirm(session_ctx, :credential_entry, change())

      row = record(session_ctx, id)

      assert {row.user_id, row.operation, row.action, row.state} ==
               {user.id, "vault.create", "credential_entry", "pending"}

      assert_receive {:announced, [:cyfr, :sanctum, :confirmation, :opened], meta}
      assert Enum.sort(Map.keys(meta)) == [:athanor_id, :expires_at, :id, :operation, :user_id]
      assert meta.id == id
      refute_receive {:announced, [:cyfr, :sanctum, :confirmation, :opened], _}
    end

    test "a caller that could never confirm is refused, not asked", %{session_ctx: session_ctx} do
      assert Authz.confirm(Context.enter_guest(session_ctx), :credential_entry, change()) ==
               {:error, :guest_plane}

      assert Authz.confirm(%{session_ctx | authenticated: false}, :credential_entry, change()) ==
               {:error, :not_authenticated}

      assert Authz.confirm(%{session_ctx | anonymous: true}, :credential_entry, change()) ==
               {:error, :anonymous}

      assert Authz.confirm(ctx(auth_method: :oidc), :credential_entry, change()) ==
               {:error, {:surface_not_permitted, :oidc}}

      assert Authz.confirm(%{session_ctx | athanor_id: nil}, :credential_entry, change()) ==
               {:error, :missing_tenant}
    end

    test "a proven record goes ahead once, and only for its own change",
         %{session_ctx: session_ctx, user: user} do
      capture(
        [
          [:cyfr, :sanctum, :confirmation, :confirmed],
          [:cyfr, :sanctum, :confirmation, :consumed]
        ],
        user.id
      )

      confirmed = Sanctum.TestContext.confirmed(session_ctx, :credential_entry, change())
      assert_receive {:announced, [:cyfr, :sanctum, :confirmation, :confirmed], _}

      # Other arguments, a secret among them, are another change.
      other = put_in(change().arguments[:fields], %{"KEY" => "sk-other"})

      assert {:error, {:confirmation_required, %{id: fresh}}} =
               Authz.confirm(confirmed, :credential_entry, other)

      refute fresh == confirmed.confirmation_id
      assert record(session_ctx, confirmed.confirmation_id).state == "confirmed"

      assert Authz.confirm(confirmed, :credential_entry, change()) == :ok
      assert record(session_ctx, confirmed.confirmation_id).state == "consumed"
      assert_receive {:announced, [:cyfr, :sanctum, :confirmation, :consumed], meta}
      assert meta.id == confirmed.confirmation_id

      # Consumed twice: asked for again.
      assert {:error, {:confirmation_required, %{id: again}}} =
               Authz.confirm(confirmed, :credential_entry, change())

      refute again == confirmed.confirmation_id
    end

    test "check/3 consumes nothing, and consume/2 consumes inside the caller's transaction",
         %{session_ctx: session_ctx} do
      confirmed = Sanctum.TestContext.confirmed(session_ctx, :credential_entry, change())

      assert Authz.check(confirmed, :credential_entry, change()) == :ok
      assert record(session_ctx, confirmed.confirmation_id).state == "confirmed"

      assert {:ok, :ok} =
               Arca.Repo.transaction(fn ->
                 Authz.consume(confirmed, {:credential_entry, change()})
               end)

      assert record(session_ctx, confirmed.confirmation_id).state == "consumed"

      # Once consumed, consume/2 opens nothing inside a transaction: it
      # refuses, and the caller rolls back.
      assert {:error, {:conflict, _}} = Authz.consume(confirmed, {:credential_entry, change()})

      # consume/2 with no confirmation named was not asked first.
      assert Authz.consume(session_ctx, {:credential_entry, change()}) ==
               {:error, :invalid_request}
    end

    test "a record past its expiry is asked for again, and announced expired",
         %{session_ctx: session_ctx, user: user} do
      capture([[:cyfr, :sanctum, :confirmation, :expired]], user.id)
      confirmed = Sanctum.TestContext.confirmed(session_ctx, :credential_entry, change())

      Arca.Repo.update_all(
        from(c in Arca.Schemas.PendingConfirmation, where: c.id == ^confirmed.confirmation_id),
        set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
      )

      assert {:error, {:confirmation_required, %{id: fresh}}} =
               Authz.confirm(confirmed, :credential_entry, change())

      refute fresh == confirmed.confirmation_id
      assert_receive {:announced, [:cyfr, :sanctum, :confirmation, :expired], meta}
      assert meta.id == confirmed.confirmation_id
    end

    test "another person's record is theirs: naming it opens one's own", %{
      session_ctx: session_ctx,
      athanor: athanor
    } do
      confirmed = Sanctum.TestContext.confirmed(session_ctx, :credential_entry, change())

      n = System.unique_integer([:positive])

      {:ok, other} =
        Users.upsert_from_provider(%{
          id: "github|https://github.com|authz-other-#{n}",
          provider: "github",
          email: "authz-other#{n}@example.com",
          verified: true
        })

      {:ok, _} = Members.ensure(other.id, scope: "athanor", athanor_id: athanor.id)

      theirs = %{
        ctx(auth_method: :oidc, user_id: other.id, athanor_id: athanor.id)
        | confirmation_id: confirmed.confirmation_id
      }

      assert {:error, {:confirmation_required, %{id: own}}} =
               Authz.confirm(theirs, :credential_entry, change())

      refute own == confirmed.confirmation_id
      assert record(session_ctx, confirmed.confirmation_id).state == "confirmed"
    end

    test "another session of the same person never takes a record this one opened, even proven",
         %{session_ctx: asking, user: user, athanor: athanor} do
      # A second session of the same person, as a stolen one would be,
      # listening for the proof on the person's confirmation stream.
      built =
        Context.build(
          user_id: user.id,
          email: user.email,
          provider: "github",
          athanor_id: athanor.id,
          permissions: [:*],
          auth_method: :oidc,
          authenticated: true
        )

      {:ok, session} = Sanctum.TestContext.create_session(built)

      {:ok, stolen} =
        Sanctum.Caller.establish(session.token, focus: athanor.id, task_supervisor: nil)

      refute stolen.session_token_hash == asking.session_token_hash

      proven = Sanctum.TestContext.confirmed(asking, :credential_entry, change())
      id = proven.confirmation_id
      assert record(asking, id).state == "confirmed"

      # The stolen session names the record: it is asked for its own proof,
      # on a record of its own, and the proven one stands untouched.
      assert {:error, {:confirmation_required, %{id: own}}} =
               Authz.confirm(%{stolen | confirmation_id: id}, :credential_entry, change())

      refute own == id
      assert record(asking, id).state == "confirmed"

      assert {:error, {:confirmation_required, %{id: ^own}}} =
               Authz.check(%{stolen | confirmation_id: id}, :credential_entry, change())

      assert {:error, {:conflict, _}} =
               Authz.consume(%{stolen | confirmation_id: id}, {:credential_entry, change()})

      # Asked for the same change, the asking session is answered its own
      # record, never the stolen one's, and repeats under it once.
      assert {:error, {:confirmation_required, %{id: ^id}}} =
               Authz.check(asking, :credential_entry, change())

      assert Authz.confirm(proven, :credential_entry, change()) == :ok
      assert record(asking, id).state == "consumed"
      assert record(asking, own).state == "pending"
    end

    test "the person's standing is read again as the record is consumed",
         %{session_ctx: session_ctx, user: user} do
      confirmed = Sanctum.TestContext.confirmed(session_ctx, :credential_entry, change())
      {:ok, _denied} = Users.deny(user)

      # The denial retired the session the context holds, and its open
      # confirmations with it: the proven record goes nowhere.
      assert Authz.confirm(confirmed, :credential_entry, change()) == {:error, :not_authenticated}
      refute record(session_ctx, confirmed.confirmation_id).state == "consumed"
    end

    test "confirmed by a passkey then revoked: the record is void, and asked for again",
         %{session_ctx: session_ctx} do
      confirmed = Sanctum.TestContext.confirmed(session_ctx, :credential_entry, change())

      %{passkey_id: passkey_id} =
        record(session_ctx, confirmed.confirmation_id)
        |> then(&%{passkey_id: &1.confirmed_passkey_id})

      {:ok, %{voided_confirmation_ids: voided}} =
        Arca.Passkeys.revoke(Prima.Actor.system(), passkey_id)

      assert confirmed.confirmation_id in voided

      assert {:error, {:confirmation_required, %{id: fresh}}} =
               Authz.confirm(confirmed, :credential_entry, change())

      refute fresh == confirmed.confirmation_id
    end

    test "a key's context asks for its creator's confirmation, and repeats one they gave",
         %{session_ctx: session_ctx} do
      name = "authz-plain-#{System.unique_integer([:positive])}"
      opts = %{name: name}

      confirmed =
        Sanctum.TestContext.confirmed(session_ctx, :credential_issuance, %{
          operation: "key.create",
          arguments: opts,
          resource: name
        })

      {:ok, %{api_key: raw}} = Sanctum.ApiKey.create(confirmed, opts)
      {:ok, key_ctx} = Sanctum.Caller.establish({:api_key, raw})
      minted = %{operation: "key.create", arguments: %{name: "minted"}, resource: "minted"}

      assert {:error, {:confirmation_required, %{id: id}}} =
               Authz.confirm(key_ctx, :credential_issuance, minted)

      assert record(key_ctx, id).user_id == key_ctx.user_id

      Sanctum.TestContext.prove!(key_ctx, id)

      assert Authz.confirm(%{key_ctx | confirmation_id: id}, :credential_issuance, minted) == :ok
    end

    test "names an action of the table and a well-formed change" do
      session = ctx(auth_method: :oidc)

      assert Authz.confirm(session, :delete_everything, change()) == {:error, :invalid_request}

      for bad <- [
            %{operation: "vault/create", arguments: %{}},
            %{operation: "vault.create"},
            %{operation: "vault.create", arguments: %{}, preview: %{"resource" => "x"}},
            %{operation: nil, arguments: %{}},
            %{operation: "vault.create", arguments: %{ratio: 1.5}},
            "vault.create"
          ] do
        assert Authz.confirm(session, :credential_entry, bad) == {:error, :invalid_request},
               inspect(bad)
      end
    end
  end

  describe "the argument digest" do
    setup [:checkout]

    test "the same arguments bind the same digest, however spelled" do
      {:ok, digest} = Authz.args_digest(%{name: "k", fields: %{"KEY" => "sk-1"}, note: nil})

      assert Authz.args_digest(%{"name" => "k", "fields" => %{"KEY" => "sk-1"}}) == {:ok, digest}
      assert Authz.args_digest(%{fields: %{"KEY" => "sk-1"}, name: :k}) == {:ok, digest}
      assert "sha256:" <> hex = digest
      assert byte_size(hex) == 64

      at = ~U[2026-09-30 12:00:00Z]

      assert Authz.args_digest(%{until: at}) ==
               Authz.args_digest(%{until: DateTime.to_iso8601(at)})
    end

    test "any changed argument, a secret value included, binds another digest" do
      {:ok, one} = Authz.args_digest(%{name: "k", fields: %{"KEY" => "sk-1"}})
      {:ok, two} = Authz.args_digest(%{name: "k", fields: %{"KEY" => "sk-2"}})
      {:ok, three} = Authz.args_digest(%{name: "k2", fields: %{"KEY" => "sk-1"}})
      assert Enum.uniq([one, two, three]) == [one, two, three]
    end

    test "is keyed: no plain hash of the arguments, or of a secret, is the digest" do
      arguments = %{"name" => "k", "fields" => %{"KEY" => "sk-guessable"}}
      {:ok, digest} = Authz.args_digest(arguments)
      {:ok, plain} = Prima.JCS.hash(arguments)

      refute digest == plain
      refute digest == Prima.Digest.sha256("sk-guessable")
    end

    test "a float, a nil in a list, a string not UTF-8, another struct or colliding keys are no request" do
      for arguments <- [
            %{ratio: 1.5},
            %{list: ["a", nil]},
            %{bytes: <<255, 254>>},
            %{at: ~D[2026-09-30]},
            %{"name" => "a", name: "b"},
            %{"name" => nil, name: "b"}
          ] do
        assert Authz.args_digest(arguments) == {:error, :invalid_request}, inspect(arguments)
      end
    end
  end

  describe "the stored record" do
    setup [:checkout, :standing_session]

    test "holds the keyed digest and a secret-free preview, never a plain hash of an argument",
         %{session_ctx: session_ctx} do
      secret = "sk-stored-#{System.unique_integer([:positive])}"
      arguments = %{name: "prod-key", kind: "api_key", fields: %{"KEY" => secret}}
      change = %{operation: "vault.create", arguments: arguments, resource: "prod-key"}
      id = opened!(session_ctx, change)
      row = record(session_ctx, id)

      {:ok, digest} = Authz.args_digest(arguments)
      assert row.args_digest == digest

      {:ok, plain} =
        Prima.JCS.hash(%{
          "name" => "prod-key",
          "kind" => "api_key",
          "fields" => %{"KEY" => secret}
        })

      stored = inspect(row, limit: :infinity, printable_limit: :infinity)
      refute stored =~ secret
      refute stored =~ plain
      refute stored =~ Prima.Digest.sha256(secret)
      assert Jason.decode!(row.preview)["resource"] == "prod-key"
    end
  end
end
