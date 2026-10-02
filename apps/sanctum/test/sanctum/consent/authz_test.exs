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
  grant and an approval need the session alone; every request for a
  sensitive change opens a pending confirmation of its own for its exact
  person, athanor, operation, argument digest and preview, answered to it
  alone under a secret, announced and stored under the secret's ref, and
  goes ahead only by consuming that record once it was proven, under the
  secret and from the credential that asked, with the person's standing
  read again. A caller that could never confirm is refused rather than
  asked, and so is a person whose keys are at another home. Standing a
  revalidation cannot name refuses rather than crashing.
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

  defp checkout(tags) do
    Arca.Cache.init()
    Arca.Test.Sandbox.setup!(tags)
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
      assert Authz.message(:identity_stale) =~ "directory"
    end
  end

  describe "a revalidation's refusal" do
    test "is named here: a stale identity as itself, one this vocabulary does not know as unavailable" do
      assert Authz.standing_refusal(:unauthenticated) == :not_authenticated
      assert Authz.standing_refusal(:not_standing) == :not_standing
      assert Authz.standing_refusal(:not_member) == :not_standing
      assert Authz.standing_refusal(:identity_stale) == :identity_stale
      assert Authz.standing_refusal(:unavailable) == :unavailable

      # A refusal revalidation learns later still refuses, never crashes.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert Authz.standing_refusal(:a_refusal_not_yet_named) == :unavailable
          assert Authz.standing_refusal({:refused, :elsewhere}) == :unavailable
        end)

      assert log =~ "unknown refusal"
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

  # The record whose secret the signal answered, read by its ref.
  defp record(ctx, id) do
    {:ok, row} = Arca.PendingConfirmations.get(Context.actor(ctx), ref(id))
    row
  end

  defp ref(id), do: Prima.Confirmation.ref(id)

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

    test "a thief holding the asking session's own token, asking first, never takes the person's change",
         %{session: session, athanor: athanor} do
      # Two contexts built from one session token: the thief's, which asks
      # first, and the person's, which asks for the identical change.
      {:ok, thief} =
        Sanctum.Caller.establish(session.token, focus: athanor.id, task_supervisor: nil)

      {:ok, person} =
        Sanctum.Caller.establish(session.token, focus: athanor.id, task_supervisor: nil)

      assert thief.session_token_hash == person.session_token_hash

      thief_id = opened!(thief)
      person_id = opened!(person)

      # The person's request got a record of its own, and proves it.
      refute person_id == thief_id
      refute ref(person_id) == ref(thief_id)
      assert record(person, person_id).opener == record(person, thief_id).opener
      assert %{state: "confirmed"} = Sanctum.TestContext.prove!(person, person_id)

      # The thief cannot repeat the person's change. Under its own secret
      # it waits on its own unproven record; under the ref it can learn,
      # which names nothing to consume, it is asked anew.
      assert {:error, {:confirmation_required, %{id: ^thief_id}}} =
               Authz.confirm(%{thief | confirmation_id: thief_id}, :credential_entry, change())

      assert {:error, {:confirmation_required, %{id: fresh}}} =
               Authz.confirm(
                 %{thief | confirmation_id: ref(person_id)},
                 :credential_entry,
                 change()
               )

      refute fresh in [thief_id, person_id]

      for named <- [thief_id, ref(person_id)] do
        assert {:error, {:conflict, _}} =
                 Authz.consume(%{thief | confirmation_id: named}, {:credential_entry, change()})
      end

      assert record(person, person_id).state == "confirmed"

      # The person repeats under their own secret, once; the thief's record
      # stays unproven.
      assert Authz.confirm(%{person | confirmation_id: person_id}, :credential_entry, change()) ==
               :ok

      assert record(person, person_id).state == "consumed"
      assert record(person, thief_id).state == "pending"
    end

    test "every request opens its own record, announced by its ref and never by its secret",
         %{session_ctx: session_ctx, user: user} do
      capture([[:cyfr, :sanctum, :confirmation, :opened]], user.id)
      id = opened!(session_ctx)

      # Asked again for the identical change, a second record answers, under
      # a secret of its own.
      assert {:error, {:confirmation_required, %{id: again}}} =
               Authz.confirm(session_ctx, :credential_entry, change())

      refute again == id

      # The secret: 256 random bits, a valid id, and never the record's name.
      assert "cnf_" <> body = id
      assert {:ok, <<_::256>>} = Base.url_decode64(body, padding: false)

      row = record(session_ctx, id)
      assert row.ref == ref(id)

      assert {row.user_id, row.operation, row.action, row.state} ==
               {user.id, "vault.create", "credential_entry", "pending"}

      assert Jason.decode!(row.asker) |> Map.take(["kind", "name"]) ==
               %{"kind" => "session", "name" => "github"}

      refute inspect(row, limit: :infinity, printable_limit: :infinity) =~ id

      for secret <- [id, again] do
        assert_receive {:announced, [:cyfr, :sanctum, :confirmation, :opened], meta}
        assert Enum.sort(Map.keys(meta)) == [:athanor_id, :expires_at, :operation, :ref, :user_id]
        assert meta.ref == ref(secret)
        refute inspect(meta) =~ secret
      end

      refute_receive {:announced, [:cyfr, :sanctum, :confirmation, :opened], _}
    end

    test "a repeat before the proof waits on its own record: the same id, its expiry, nothing opened",
         %{session_ctx: session_ctx, user: user} do
      capture([[:cyfr, :sanctum, :confirmation, :opened]], user.id)
      id = opened!(session_ctx)
      assert_receive {:announced, [:cyfr, :sanctum, :confirmation, :opened], _}
      expires_at = record(session_ctx, id).expires_at
      repeat = %{session_ctx | confirmation_id: id}

      # Repeated twice, through each deciding mode: the same secret, the
      # record's own expiry, and no record opened or announced.
      for decide <- [
            &Authz.check(&1, :credential_entry, change()),
            &Authz.confirm(&1, :credential_entry, change())
          ] do
        assert {:error,
                {:confirmation_required,
                 %{id: ^id, operation: "vault.create", expires_at: ^expires_at}}} =
                 decide.(repeat)
      end

      refute_receive {:announced, [:cyfr, :sanctum, :confirmation, :opened], _}

      {:ok, open} =
        Arca.PendingConfirmations.list_open(Context.actor(session_ctx), session_ctx.user_id)

      assert Enum.map(open, & &1.ref) == [ref(id)]
      assert record(session_ctx, id).state == "pending"

      # Once the person proves it, the repeat completes.
      Sanctum.TestContext.prove!(session_ctx, id)
      assert Authz.confirm(repeat, :credential_entry, change()) == :ok
      assert record(session_ctx, id).state == "consumed"
    end

    test "a repeat before the proof for another change, or once its record ended, asks anew",
         %{session_ctx: session_ctx} do
      id = opened!(session_ctx)
      repeat = %{session_ctx | confirmation_id: id}
      other = %{change() | arguments: %{name: "other-key"}, resource: "other-key"}

      assert {:error, {:confirmation_required, %{id: for_other}}} =
               Authz.check(repeat, :credential_entry, other)

      refute for_other == id

      {:ok, _} = Arca.PendingConfirmations.cancel(Context.actor(session_ctx), ref(id))

      assert {:error, {:confirmation_required, %{id: after_cancel}}} =
               Authz.check(repeat, :credential_entry, change())

      refute after_cancel in [id, for_other]
    end

    test "under another opener, the same secret opens a record for that opener",
         %{session_ctx: asking, user: user, athanor: athanor} do
      id = opened!(asking)

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

      {:ok, other} =
        Sanctum.Caller.establish(session.token, focus: athanor.id, task_supervisor: nil)

      assert {:error, {:confirmation_required, %{id: own}}} =
               Authz.check(%{other | confirmation_id: id}, :credential_entry, change())

      refute own == id
      refute record(asking, own).opener == record(asking, id).opener
      assert record(asking, id).state == "pending"
    end

    test "one credential's requests hold at most eight open records; the oldest is announced voided",
         %{session_ctx: session_ctx, user: user} do
      capture([[:cyfr, :sanctum, :confirmation, :voided]], user.id)
      bound = Arca.PendingConfirmations.open_per_opener()

      [oldest | kept] = for _ <- 1..bound, do: opened!(session_ctx)
      refute_received {:announced, [:cyfr, :sanctum, :confirmation, :voided], _}

      newest = opened!(session_ctx)
      assert_receive {:announced, [:cyfr, :sanctum, :confirmation, :voided], meta}
      assert meta.ref == ref(oldest) and meta.operation == "vault.create"
      refute inspect(meta) =~ oldest
      assert record(session_ctx, oldest).state == "voided"

      {:ok, open} =
        Arca.PendingConfirmations.list_open(Context.actor(session_ctx), session_ctx.user_id)

      assert Enum.sort(Enum.map(open, & &1.ref)) == Enum.sort(Enum.map([newest | kept], &ref/1))
    end

    test "the asker's name is cut within 255 bytes at a UTF-8 boundary, never mid-character" do
      for {name, kept} <- [
            {"short", "short"},
            {String.duplicate("a", 300), String.duplicate("a", 255)},
            {String.duplicate("é", 200), String.duplicate("é", 127)},
            {String.duplicate("🦫", 100), String.duplicate("🦫", 63)},
            {String.duplicate("a", 254) <> "é", String.duplicate("a", 254)},
            {<<0xFF, 0xFE>>, ""}
          ] do
        bounded = Authz.utf8_prefix(name, 255)
        assert bounded == kept
        assert byte_size(bounded) <= 255 and String.valid?(bounded)
      end
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
      assert meta.ref == ref(confirmed.confirmation_id)

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

      stale = ref(confirmed.confirmation_id)

      Arca.Repo.update_all(
        from(c in Arca.Schemas.PendingConfirmation, where: c.ref == ^stale),
        set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
      )

      assert {:error, {:confirmation_required, %{id: fresh}}} =
               Authz.confirm(confirmed, :credential_entry, change())

      refute fresh == confirmed.confirmation_id
      assert_receive {:announced, [:cyfr, :sanctum, :confirmation, :expired], meta}
      assert meta.ref == stale
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

      # A context no stored credential backs is named by this home.
      assert Jason.decode!(record(theirs, own).asker) ==
               %{"kind" => "unbound", "name" => Sanctum.Person.home()}
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

      # Every request opens its own: checked again, it is answered another.
      assert {:error, {:confirmation_required, %{id: checked}}} =
               Authz.check(%{stolen | confirmation_id: id}, :credential_entry, change())

      refute checked in [id, own]

      assert {:error, {:conflict, _}} =
               Authz.consume(%{stolen | confirmation_id: id}, {:credential_entry, change()})

      # Asked for the same change again, the asking session is answered a
      # new record of its own, never another's; it repeats under the proven
      # one's secret, once.
      assert {:error, {:confirmation_required, %{id: another}}} =
               Authz.check(asking, :credential_entry, change())

      refute another in [id, own, checked]

      assert Authz.confirm(proven, :credential_entry, change()) == :ok
      assert record(asking, id).state == "consumed"
      assert record(asking, own).state == "pending"
      assert record(asking, another).state == "pending"
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

      assert ref(confirmed.confirmation_id) in voided

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

      # The record names the key that asked, so its person tells it from
      # their own sessions' requests.
      assert Jason.decode!(record(key_ctx, id).asker) == %{"kind" => "key", "name" => name}

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

    test "names the athanor as its members know it while the preview holds the name, by its id past that",
         %{session_ctx: session_ctx, athanor: athanor} do
      bound = Prima.Confirmation.Preview.max_text()

      # PostgreSQL's column holds 255 characters, well inside the preview's
      # bound, so only SQLite stores a name the preview cannot hold.
      names =
        if Arca.Repo.adapter() == Ecto.Adapters.Postgres,
          do: [{String.duplicate("n", 255), :name}],
          else: [{String.duplicate("n", bound), :name}, {String.duplicate("n", bound + 1), :id}]

      for {name, shown} <- names do
        {:ok, _} = Athanors.update(athanor, %{name: name})
        key = "k-#{byte_size(name)}"

        id =
          opened!(session_ctx, %{
            operation: "vault.create",
            arguments: %{name: key},
            resource: key
          })

        expected = if shown == :name, do: name, else: athanor.id
        assert Jason.decode!(record(session_ctx, id).preview)["athanor"] == expected
      end
    end
  end
end
