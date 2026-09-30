# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.Consent.AuthzTest do
  @moduledoc """
  Who may grant a consent, and how a sensitive change is decided.

  A grant needs an interactive caller, or a key capability within its
  exact envelope, and that caller's standing read again as it is decided:
  a session that expired or is gone, a person denied, an athanor archived
  or a key revoked grants nothing. Tincture sessions, the guest plane and
  key overrides stay refused. No client holds a rank.

  `confirm/3`, `check/3` and `consume/2` decide a sensitive change: in
  their first form no action asks for a fresh confirmation, a known action
  and a well-formed change are answered `:ok`, and the deciding site's own
  checks of who may act stand as they were.
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

    {:ok, %{api_key: raw}} =
      Sanctum.ApiKey.create(session_ctx, %{
        name: name,
        consent_capability: %{commit_digest: digest, expires_at: expires_at}
      })

    {:ok, key_ctx} = Sanctum.Caller.establish({:api_key, raw})
    {:ok, key_capability} = Sanctum.ApiKey.consent_capability(key_ctx, key_ctx.api_key_id)

    %{key_ctx: key_ctx, key_name: name, key_digest: digest, key_capability: key_capability}
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

    test "no non-interactive surface can consent, a paired device not yet among them" do
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
  # Sensitive changes, first form
  # ============================================================================

  describe "a sensitive change" do
    test "is answered as before, whatever the action and whoever the site admitted" do
      for action <- Sanctum.Pairing.actions(),
          caller <- [ctx(auth_method: :oidc), ctx(auth_method: :api_key)] do
        assert Authz.confirm(caller, action, change()) == :ok
        assert Authz.check(caller, action, change()) == :ok
        assert Authz.consume(caller, {action, change()}) == :ok
      end
    end

    test "adds no refusal of its own to the deciding site's checks of who may act" do
      # Who may enter a credential or mint a key is the site's to decide,
      # as it was: until a proof can be given, the decision refuses nothing
      # a site admitted.
      for caller <- [
            Context.enter_guest(ctx(auth_method: :oidc)),
            Context.build(%{authenticated: false, auth_method: :oidc}),
            ctx(auth_method: :oidc, anonymous: true)
          ] do
        assert Authz.confirm(caller, :credential_entry, change()) == :ok
        assert Authz.check(caller, :credential_entry, change()) == :ok
        assert Authz.consume(caller, {:credential_entry, change()}) == :ok
      end
    end

    test "names an action of the table and a well-formed change" do
      session = ctx(auth_method: :oidc)

      assert Authz.confirm(session, :delete_everything, change()) == {:error, :invalid_request}

      for bad <- [
            %{operation: "vault/create", arguments: %{}},
            %{operation: "vault.create"},
            %{operation: "vault.create", arguments: %{}, preview: %{"resource" => "x"}},
            %{operation: nil, arguments: %{}},
            "vault.create"
          ] do
        assert Authz.confirm(session, :credential_entry, bad) == {:error, :invalid_request},
               inspect(bad)
      end
    end
  end
end
