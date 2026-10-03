# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.SettingsLiveTest.LinkFlow do
  @moduledoc false
  # A device flow whose provider the suite plays: it starts with a code,
  # and its poll answers the link ticket a completed sign-in with the door
  # would, for the identity the test names (`:settings_link_identity`).
  def init_device_flow(provider, _client_ip) when provider in [:github, :google] do
    {:ok,
     %{
       device_code: "dc-settings-link",
       user_code: "LINK-2026",
       verification_uri: "https://github.com/login/device",
       interval: 5
     }}
  end

  def poll_for_link(provider, "dc-settings-link", _client_ip, ctx) do
    key = Application.fetch_env!(:sanctum, :settings_link_identity)

    with {:ok, ticket} <-
           Sanctum.SignIn.link_ticket(ctx, %{key: key, provider: provider, email: nil}) do
      {:ok, %{status: "complete", provider: to_string(provider), ticket: ticket}}
    end
  end
end

defmodule PrismWeb.SettingsLiveTest do
  @moduledoc """
  Settings: the door and the platform settings are the operator's
  sections and nobody else's; the lite/dev preference is every person's
  own.

  The person's identity, doors and passkeys are their own: read through
  `person.status` and `passkey.list`, each change an operation through the
  gate, each one that needs a fresh confirmation asked through the page's
  system layer and made again once confirmed, and every recovery prompt
  drawn in the layer alone.
  """
  use PrismWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Prima.Test.Wait

  alias Arca.Schemas.PersonIdentity
  alias Prima.Identity
  alias Prima.Identity.Entry
  alias Sanctum.{Cipher, CipherAAD}
  alias Sanctum.TestContext.Authenticator

  test "the door section is shown to a platform admin and to nobody else", %{conn: conn} do
    person = test_user()
    {view, html} = conn |> log_in_user(person) |> mount_athanor("/settings")
    refute html =~ "Server allowlist"
    refute has_element?(view, "button[phx-click=door_allow]")

    ops = test_user()
    {:ok, _} = Sanctum.Tenancy.Members.ensure_platform(ops.user_id)
    {admin_view, admin_html} = build_conn() |> log_in_user(ops) |> mount_athanor("/settings")
    assert admin_html =~ "Server allowlist"

    email = "letin-#{System.unique_integer([:positive])}@example.com"

    # The entry typed is what the Allow button carries; the click adds
    # nothing of its own.
    admin_view
    |> element(~s(form[phx-change="door_form_changed"]))
    |> render_change(%{"value" => email})

    assert has_element?(admin_view, ~s(button[phx-click="door_allow"][phx-value-door="#{email}"]))
    assert has_element?(admin_view, ~s(button[phx-click="door_deny"][phx-value-door="#{email}"]))

    admin_view
    |> element("button[phx-click=door_allow]")
    |> render_click()

    assert render(admin_view) =~ email
    assert {:ok, :allowed} = Sanctum.Door.admit("github|https://github.com|x", email, true)
  end

  test "the platform settings card is the operator's, saves against its revision, and shows a pin read-only",
       %{conn: conn} do
    pinned = Application.get_env(:cyfr, :deployment_pinned)

    on_exit(fn ->
      if pinned,
        do: Application.put_env(:cyfr, :deployment_pinned, pinned),
        else: Application.delete_env(:cyfr, :deployment_pinned)
    end)

    Application.put_env(:cyfr, :deployment_pinned, [{"max_athanors", 5}])

    person = test_user()
    {_view, html} = conn |> log_in_user(person) |> mount_athanor("/settings")
    refute html =~ "Platform settings"

    ops = test_user()
    {:ok, _} = Sanctum.Tenancy.Members.ensure_platform(ops.user_id)
    {view, html} = build_conn() |> log_in_user(ops) |> mount_athanor("/settings")

    assert html =~ "Platform settings"
    assert html =~ "reaches new and refreshed work"
    assert html =~ "within 30 s"

    # A pinned key is the deployment's: no form, and the card says so.
    refute has_element?(view, "#setting-max_athanors")
    assert html =~ "set by the deployment"

    view |> form("#setting-mcp_rate_limit_max", %{"value" => "240"}) |> render_submit()
    assert Arca.PlatformSettings.effective("mcp_rate_limit_max") == {:ok, 240}
    assert render(view) =~ "mcp_rate_limit_max saved."

    # A value under the floor is refused with its range, and nothing moves.
    view |> form("#setting-mcp_rate_limit_max", %{"value" => "0"}) |> render_submit()
    assert render(view) =~ "from 1 to 1000000000"
    assert Arca.PlatformSettings.effective("mcp_rate_limit_max") == {:ok, 240}

    # A write this card has not heard of since it listed refuses its next
    # change, and the card lists again, so the one after goes through.
    {:ok, %{revision: revision}} = Arca.PlatformSettings.all()
    {:ok, _} = Arca.PlatformSettings.put("device_label", "elsewhere", revision, "other")

    reset = "button[phx-click=setting_reset][phx-value-key=mcp_rate_limit_max]"
    view |> element(reset) |> render_click()
    assert render(view) =~ "changed since they were read"
    assert Arca.PlatformSettings.effective("mcp_rate_limit_max") == {:ok, 240}

    view |> element(reset) |> render_click()
    assert Arca.PlatformSettings.get("mcp_rate_limit_max") == {:error, :not_found}
  end

  test "the mode preference is written to the person's row", %{conn: conn} do
    person = test_user()
    {view, _} = conn |> log_in_user(person) |> mount_athanor("/settings")

    view |> element("button[phx-click=set_mode][phx-value-mode=lite]") |> render_click()
    {:ok, user} = Sanctum.Tenancy.Users.get(person.user_id)
    assert Sanctum.Tenancy.Users.prefs(user)["mode"] == "lite"

    view |> element("button[phx-click=set_mode][phx-value-mode=dev]") |> render_click()
    {:ok, user} = Sanctum.Tenancy.Users.get(person.user_id)
    assert Sanctum.Tenancy.Users.prefs(user)["mode"] == "dev"
  end

  # ---------------------------------------------------------------------------
  # The person's identity, doors and passkeys
  # ---------------------------------------------------------------------------

  # A directory this home cannot reach: nothing here reads one.
  @directory "https://dir.example"

  defp keep_env(app, keys) do
    prior = Map.new(keys, &{&1, Application.fetch_env(app, &1)})

    on_exit(fn ->
      for {key, value} <- prior do
        case value do
          {:ok, value} -> Application.put_env(app, key, value)
          :error -> Application.delete_env(app, key)
        end
      end
    end)
  end

  defp layer(view), do: with_target(view, "#system-layer")

  defp held_secret(view) do
    state = inspect(:sys.get_state(view.pid), limit: :infinity, printable_limit: :infinity)
    [secret] = Regex.run(~r/cnf_[A-Za-z0-9_-]{43}/, state)
    secret
  end

  # The page's own request, proven here with the person's passkey over the
  # record's digest, as the layer asks.
  defp prove_here!(view, authenticator) do
    ref = Prima.Confirmation.ref(held_secret(view))
    view |> element(~s([data-test="confirm-passkey"][phx-value-ref="#{ref}"])) |> render_click()

    assert_push_event(view, "webauthn:get", %{
      purpose: "confirmation",
      id: ^ref,
      public_key: %{"challenge" => challenge}
    })

    {:ok, digest} = Prima.Identity.Encoding.unb64(challenge, 32)

    view
    |> layer()
    |> render_hook("webauthn_result", %{
      "purpose" => "confirmation",
      "id" => ref,
      "credential" => Authenticator.assertion(authenticator, digest)
    })
  end

  # The person's enrollment, accepted, as a retry records the directory's
  # acceptance: their kit is not saved yet.
  defp enrolled!(person) do
    begun = pending!(person)
    as = %Prima.Actor{user_id: person.user_id}
    {:ok, _} = Arca.IdentityAttempts.advance(as, begun.attempt_id, "submitted", "accepted")
    begun
  end

  # The person's enrollment, submitted with no answer recorded: it waits on
  # the seed of the browser that began it.
  defp pending!(person) do
    keys = Arca.Repo.get_by!(PersonIdentity, user_id: person.user_id)

    {:ok, operational} =
      Cipher.decrypt(
        keys.operational_key_sealed,
        CipherAAD.person_key(person.user_id, :operational)
      )

    {recovery, _} = :crypto.generate_key(:eddsa, :ed25519)

    {:ok, genesis} =
      Entry.genesis(
        live_key: keys.live_public_key,
        operational_key: keys.operational_public_key,
        recovery_keys: [recovery],
        directory: @directory
      )

    genesis = Identity.sign(genesis, operational)
    as = %Prima.Actor{user_id: person.user_id}

    {:ok, attempt} =
      Arca.IdentityAttempts.open(as, %{
        kind: "enrollment",
        request_id: "req_#{System.unique_integer([:positive])}",
        user_id: person.user_id,
        identifier: Identity.identifier(genesis),
        directory_url: @directory,
        genesis: Identity.canonical(genesis),
        request_digest: Identity.hash(genesis),
        kit_seed_sealed: "sealed-kit-seed"
      })

    {:ok, _} = Arca.IdentityAttempts.advance(as, attempt.id, "staged", "submitted")
    %{attempt_id: attempt.id, identifier: Identity.identifier(genesis)}
  end

  # `person`, signed in, made a person whose keys are at another home:
  # their identity row is `remote`, their head cached as verified now, and
  # the conn holds a session of theirs bound to that head's `key_epoch`.
  defp remote!(conn, person) do
    conn = log_in_user(conn, person)
    Arca.Repo.delete_all(from(p in PersonIdentity, where: p.user_id == ^person.user_id))

    {live, _} = :crypto.generate_key(:eddsa, :ed25519)
    {operational_public, operational} = :crypto.generate_key(:eddsa, :ed25519)
    {recovery, _} = :crypto.generate_key(:eddsa, :ed25519)

    {:ok, genesis} =
      Entry.genesis(
        live_key: live,
        operational_key: operational_public,
        recovery_keys: [recovery],
        directory: @directory
      )

    genesis = Identity.sign(genesis, operational)
    identifier = Identity.identifier(genesis)
    head = Identity.hash(genesis)

    {:ok, _} =
      Arca.PersonIdentities.create(Prima.Actor.system(), %{
        user_id: person.user_id,
        provenance: "remote",
        identifier: identifier,
        directory_url: @directory
      })

    {:ok, _} =
      Arca.DirectoryHeads.put(Prima.Actor.system(), %{
        identifier: identifier,
        genesis: Identity.canonical(genesis),
        directory_url: @directory,
        head_hash: head,
        key_epoch: head,
        recovery_epoch: head,
        state: ~s({"head":"#{head}"})
      })

    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    now = DateTime.utc_now()

    Arca.Repo.insert_all(Arca.Schemas.Session, [
      %{
        id: Prima.UUID7.generate_id("ses"),
        token_hash: Sanctum.Session.token_hash(token),
        token_prefix: String.slice(token, 0, 8),
        user_id: person.user_id,
        provider: "cyfr",
        athanor_id: Process.get(:prism_test_athanor_id),
        identity_key_epoch: head,
        expires_at: DateTime.add(now, 30 * 86_400, :second),
        inserted_at: now
      }
    ])

    {Plug.Test.init_test_session(conn, %{session_key() => token}), identifier}
  end

  describe "your identity" do
    setup do
      keep_env(:sanctum, [:directory_url])
      :ok
    end

    test "with no directory pinned, enrolling names the setting the operator owes, and the rest stands",
         %{conn: conn} do
      Application.delete_env(:sanctum, :directory_url)
      person = test_user()
      {view, html} = conn |> log_in_user(person) |> mount_athanor("/settings")

      assert has_element?(view, ~s([data-test="identity"][data-provenance="local"]))
      assert has_element?(view, ~s([data-test="identity"][data-enrollment="none"]))
      assert has_element?(view, ~s([data-test="identity-no-directory"]), "CYFR_DIRECTORY_URL")
      refute has_element?(view, ~s([data-test="identity-enroll"]))
      assert html =~ "local pairing included"

      # The doors and passkeys stand without a directory.
      assert has_element?(view, ~s([data-test="door"][data-key="#{person.identity}"]))
      assert has_element?(view, ~s([data-test="passkey-register"]))
    end

    test "Enroll opens the enrollment prompt in the page's layer, naming the pinned directory",
         %{conn: conn} do
      Application.put_env(:sanctum, :directory_url, @directory)
      person = test_user()
      {view, _html} = conn |> log_in_user(person) |> mount_athanor("/settings")

      assert has_element?(view, ~s([data-test="identity-directory"]), @directory)
      view |> element(~s([data-test="identity-enroll"])) |> render_click()
      render(view)

      assert has_element?(view, ~s(#system-layer [data-test="recovery"][data-kind="enrollment"]))
      assert has_element?(view, ~s(#system-layer [data-test="recovery-directory"]), @directory)
      assert has_element?(view, ~s(#system-layer form[data-recovery="enrollment"]))
    end

    test "a kit not yet saved is offered again; another kit and the rotation are offered once enrolled",
         %{conn: conn} do
      Application.put_env(:sanctum, :directory_url, @directory)
      person = test_user()
      enrolled = enrolled!(person)
      {view, html} = conn |> log_in_user(person) |> mount_athanor("/settings")

      assert has_element?(view, ~s([data-test="identity"][data-enrollment="enrolled"]))
      assert has_element?(view, ~s([data-test="identity-identifier"]), enrolled.identifier)
      refute html =~ "sealed-kit-seed"

      kit = ~s([data-test="identity-kit"][data-attempt="#{enrolled.attempt_id}"])
      assert has_element?(view, kit)

      view |> element(~s([data-test="identity-kit-show"])) |> render_click()
      render(view)
      assert has_element?(view, ~s(#system-layer [data-test="recovery"][data-kind="kit"]))
      view |> element(~s([data-test="prompt-dismiss"])) |> render_click()

      view |> element(~s([data-test="identity-add-kit"])) |> render_click()
      render(view)
      assert has_element?(view, ~s(#system-layer [data-test="recovery"][data-kind="holder"]))
      view |> element(~s([data-test="prompt-dismiss"])) |> render_click()

      # Rotating the live key asks for its fresh confirmation in the layer,
      # as this page's own request, and rotates nothing before it.
      view |> element(~s([data-test="identity-rotate"])) |> render_click()
      render(view)
      assert has_element?(view, ~s(#system-layer [data-test="confirmation"][data-own="true"]))

      ctx = %{Sanctum.TestContext.local() | user_id: person.user_id}

      assert [%{action: "key_rotation", state: "pending"}] =
               Arca.Repo.all(
                 from(c in "pending_confirmations",
                   where: c.user_id == ^ctx.user_id,
                   select: %{action: c.action, state: c.state}
                 )
               )

      assert Arca.Repo.all(
               from(a in Arca.Schemas.IdentityAttempt,
                 where: a.user_id == ^person.user_id and a.kind == "rotation"
               )
             ) == []
    end

    test "an enrollment no prompt here holds is abandoned and begun again under a new kit",
         %{conn: conn} do
      Application.put_env(:sanctum, :directory_url, @directory)
      person = test_user()
      pending = pending!(person)
      {view, _html} = conn |> log_in_user(person) |> mount_athanor("/settings")

      assert has_element?(view, ~s([data-test="identity"][data-enrollment="pending"]))
      refute has_element?(view, ~s([data-test="identity-enroll"]))

      # No confirmation is asked: it discards an unfinished attempt and
      # mints nothing.
      view |> element(~s([data-test="identity-abandon"])) |> render_click()
      render(view)

      assert %{phase: "superseded", kit_seed_sealed: nil} =
               Arca.Repo.get!(Arca.Schemas.IdentityAttempt, pending.attempt_id)

      assert Arca.Repo.all(
               from(c in "pending_confirmations",
                 where: c.user_id == ^person.user_id,
                 select: c.action
               )
             ) == []

      assert has_element?(view, ~s([data-test="identity"][data-enrollment="none"]))
      assert render(view) =~ "The unfinished enrollment was abandoned."

      # Begun again: the enrollment prompt is open in the layer, its seed
      # the browser's to draw.
      assert has_element?(view, ~s(#system-layer [data-test="recovery"][data-kind="enrollment"]))
      assert has_element?(view, ~s(#system-layer form[data-recovery="enrollment"]))
    end

    test "no abandonment is offered while the page's own enrollment prompt holds its seed",
         %{conn: conn} do
      Application.put_env(:sanctum, :directory_url, @directory)
      person = test_user()
      {view, _html} = conn |> log_in_user(person) |> mount_athanor("/settings")

      view |> element(~s([data-test="identity-enroll"])) |> render_click()
      render(view)
      assert has_element?(view, ~s(#system-layer [data-test="recovery"][data-kind="enrollment"]))

      # The prompt's submission stands at the directory, unanswered, and
      # the page reads the identity again with the prompt still open.
      _pending = pending!(person)
      send(view.pid, :load)
      render(view)

      assert has_element?(view, ~s([data-test="identity"][data-enrollment="pending"]))
      refute has_element?(view, ~s([data-test="identity-abandon"]))

      # Dismissed, the prompt and the seed it held are gone.
      view |> element(~s([data-test="prompt-dismiss"])) |> render_click()
      render(view)
      assert has_element?(view, ~s([data-test="identity-abandon"]))
    end

    test "a person whose keys another home holds is told to change them there, and offered nothing",
         %{conn: conn} do
      Application.put_env(:sanctum, :directory_url, @directory)
      person = test_user()
      {conn, identifier} = remote!(conn, person)
      {view, _html} = mount_athanor(conn, "/settings")

      assert has_element?(view, ~s([data-test="identity"][data-provenance="remote"]))
      assert has_element?(view, ~s([data-test="identity-remote"]), "held at another home")
      assert has_element?(view, ~s([data-test="identity-identifier"]), identifier)

      for control <-
            ~w(identity-enroll identity-abandon identity-no-directory identity-kit identity-add-kit identity-rotate) do
        refute has_element?(view, ~s([data-test="#{control}"])), control
      end
    end
  end

  describe "sign-in doors" do
    test "the last door stays while the person holds no passkey here, said in its sentence",
         %{conn: conn} do
      person = test_user()
      {view, _html} = conn |> log_in_user(person) |> mount_athanor("/settings")

      view |> element(~s([data-test="door-unlink"])) |> render_click()
      html = render(view)

      assert html =~ "hold no passkey"
      assert html =~ "link another door"
      assert {:ok, [_door]} = Arca.Users.identities(Prima.Actor.system(), person.user_id)
    end

    test "a GitHub door is linked through a device flow's ticket, under a fresh confirmation",
         %{conn: conn} do
      keep_env(:sanctum, [:device_flow, :github_client_id, :settings_link_identity])
      Application.put_env(:sanctum, :device_flow, PrismWeb.SettingsLiveTest.LinkFlow)
      Application.put_env(:sanctum, :github_client_id, "settings-test-client")

      person = test_user()
      authenticator = Sanctum.TestContext.passkey!(person.user_id)
      key = "github|https://github.com|linked-#{System.unique_integer([:positive])}"
      {:ok, _} = Sanctum.Door.Store.allow("user_id", key, "test")
      Application.put_env(:sanctum, :settings_link_identity, key)

      {view, _html} = conn |> log_in_user(person) |> mount_athanor("/settings")
      view |> element(~s([data-test="door-link-github"])) |> render_click()
      assert has_element?(view, ~s([data-test="door-link-code"]), "LINK-2026")

      # The provider authorized it: the poll answers a ticket, which the
      # page presents, and the link waits on its fresh confirmation.
      send(view.pid, :link_poll)
      render(view)
      assert has_element?(view, ~s(#system-layer [data-test="confirmation"][data-own="true"]))
      assert {:ok, [_one]} = Arca.Users.identities(Prima.Actor.system(), person.user_id)

      prove_here!(view, authenticator)

      wait_until(fn -> render(view) =~ "Linked github sign-in" end, 2_000, "the door linked")

      assert has_element?(view, ~s([data-test="door"][data-key="#{key}"]))
      assert {:ok, [_, _]} = Arca.Users.identities(Prima.Actor.system(), person.user_id)
    end

    test "an OpenID Connect door's ticket left in the session is presented as the page loads; a stale one says nothing",
         %{conn: conn} do
      person = test_user()
      authenticator = Sanctum.TestContext.passkey!(person.user_id)
      conn = log_in_user(conn, person)
      {:ok, ctx} = Sanctum.Caller.establish(get_session(conn, session_key()))

      key = "oidcc|https://issuer.example|sub-#{System.unique_integer([:positive])}"
      {:ok, _} = Sanctum.Door.Store.allow("user_id", key, "test")
      {:ok, ticket} = Sanctum.SignIn.link_ticket(ctx, %{key: key, provider: "oidcc", email: nil})

      linked =
        Plug.Test.init_test_session(conn, %{
          PrismWeb.AuthController.link_ticket_key() => %{
            "provider" => "oidcc",
            "ticket" => ticket
          }
        })

      {view, _html} = mount_athanor(linked, "/settings")
      render(view)
      assert has_element?(view, ~s(#system-layer [data-test="confirmation"][data-own="true"]))

      prove_here!(view, authenticator)

      wait_until(fn -> render(view) =~ "Linked oidcc sign-in" end, 2_000, "the door linked")

      assert has_element?(view, ~s([data-test="door"][data-key="#{key}"]))

      # Loaded again, the spent ticket the session still holds says nothing.
      {view, html} = mount_athanor(linked, "/settings")
      render(view)
      refute html =~ "Door:"
      refute render(view) =~ "Door:"
      refute has_element?(view, ~s(#system-layer [data-test="confirmation"]))
    end
  end

  describe "passkeys" do
    # The page's registration ceremony, answered by the person's software
    # authenticator and handed to the layer: answers the authenticator.
    defp ceremony!(view, person) do
      view |> element(~s([data-test="passkey-register"])) |> render_click()

      assert_push_event(view, "webauthn:create", %{
        layer: "system-layer",
        purpose: "passkey",
        public_key: public_key,
        registration: registration
      })

      authenticator = Authenticator.for_person(person.user_id)

      credential =
        Authenticator.registration(authenticator, %{
          public_key: public_key,
          registration: registration
        })

      view
      |> layer()
      |> render_hook("webauthn_result", %{"purpose" => "passkey", "credential" => credential})

      authenticator
    end

    test "one is registered through the layer's ceremony, then revoked under a fresh confirmation",
         %{conn: conn} do
      # No email, so no fresh method here: a first passkey, right after the
      # sign-in, needs no other proof.
      person = test_user(%{email: nil})
      {view, _html} = conn |> log_in_user(person) |> mount_athanor("/settings")
      assert render(view) =~ "No passkey is registered here."

      authenticator = ceremony!(view, person)

      html = render(view)
      assert html =~ "Passkey registered."
      assert has_element?(view, ~s([data-test="passkey"][data-state="active"]))

      # Revoking it needs a fresh proof; the door the person keeps lets it go.
      view |> element(~s([data-test="passkey-revoke"])) |> render_click()
      render(view)
      assert has_element?(view, ~s(#system-layer [data-test="confirmation"][data-own="true"]))
      assert has_element?(view, ~s([data-test="passkey"][data-state="active"]))

      prove_here!(view, authenticator)

      wait_until(fn -> render(view) =~ "Passkey revoked." end, 2_000, "the passkey revoked")

      refute has_element?(view, ~s([data-test="passkey"]))
    end

    test "a person with a verified email is asked by the layer to confirm their first passkey, and the code mailed to them registers it",
         %{conn: conn} do
      # A verified email the suite's transport reaches: a fresh method, so
      # a recent sign-in alone registers nothing.
      person = test_user()
      {view, _html} = conn |> log_in_user(person) |> mount_athanor("/settings")
      ceremony!(view, person)

      render(view)
      assert has_element?(view, ~s(#system-layer [data-test="confirmation"][data-own="true"]))
      refute render(view) =~ "Passkey registered."
      refute has_element?(view, ~s([data-test="passkey"]))
      assert {:ok, %{passkeys: []}} = passkeys(person)

      view |> element(~s([data-test="confirm-email"])) |> render_click()
      assert_receive {:confirmation_code_mail, mail}, 2_000

      view
      |> form("#system-layer-code", %{"code" => Sanctum.TestContext.MailSink.code(mail)})
      |> render_submit()

      # Confirmed, the page makes the registration again under the record.
      wait_until(fn -> render(view) =~ "Passkey registered." end, 2_000, "the passkey registered")
      assert has_element?(view, ~s([data-test="passkey"][data-state="active"]))
    end

    test "a ceremony the browser did not finish registers nothing, and says so", %{conn: conn} do
      person = test_user()
      {view, _html} = conn |> log_in_user(person) |> mount_athanor("/settings")

      view |> element(~s([data-test="passkey-register"])) |> render_click()
      view |> layer() |> render_hook("webauthn_error", %{"purpose" => "passkey"})

      assert render(view) =~ "Nothing was registered."
      assert {:ok, %{passkeys: []}} = passkeys(person)
    end
  end

  defp passkeys(person) do
    ctx = %{
      Sanctum.TestContext.local()
      | user_id: person.user_id,
        auth_method: :oidc
    }

    case Sanctum.Passkeys.list(ctx) do
      {:ok, passkeys} -> {:ok, %{passkeys: passkeys}}
      other -> other
    end
  end
end
