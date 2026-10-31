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
  alias Sanctum.Test.RegistryStub
  alias Sanctum.TestContext.Authenticator

  test "the door section is shown to a platform admin and to nobody else", %{conn: conn} do
    person = test_user()
    {view, html} = conn |> log_in_user(person) |> mount_athanor("/settings")
    refute html =~ "Server allowlist"
    refute has_element?(view, "button[phx-click=door_allow]")

    ops = test_user()
    {:ok, _} = Sanctum.TestContext.ensure_platform(ops.user_id)
    {admin_view, admin_html} = build_conn() |> log_in_user(ops) |> mount_athanor("/settings")
    assert admin_html =~ "Server allowlist"

    identifier = "per_" <> Prima.Digest.sha256_hex("letin-#{System.unique_integer([:positive])}")

    # The entry typed is what the Allow button carries; the click adds
    # nothing of its own.
    admin_view
    |> element(~s(form[phx-change="door_form_changed"]))
    |> render_change(%{"value" => identifier})

    assert has_element?(
             admin_view,
             ~s(button[phx-click="door_allow"][phx-value-door="#{identifier}"])
           )

    assert has_element?(
             admin_view,
             ~s(button[phx-click="door_deny"][phx-value-door="#{identifier}"])
           )

    assert {:error, :not_allowed} = Sanctum.Door.admit_identifier(identifier)

    admin_view
    |> element("button[phx-click=door_allow]")
    |> render_click()

    assert render(admin_view) =~ identifier
    assert {:ok, :allowed} = Sanctum.Door.admit_identifier(identifier)
  end

  # A key the platform administrator offers is shared from their own
  # vault; Settings holds no credential store of its own.
  test "a platform administrator's Settings holds no instance entries", %{conn: conn} do
    ops = test_user()
    {:ok, _} = Sanctum.TestContext.ensure_platform(ops.user_id)
    {view, html} = conn |> log_in_user(ops) |> mount_athanor("/settings")

    assert html =~ "Server allowlist"
    refute html =~ "Instance entries"
    refute html =~ "instance entry"
    refute has_element?(view, ~s([data-test="instance-entries"]))
    refute has_element?(view, ~s([data-test="instance-use"]))
    refute has_element?(view, "#instance-create")
  end

  test "the allowlist allows and denies by name, shows each entry's name, and says why a name is refused",
       %{conn: conn} do
    ops = test_user()
    {:ok, _} = Sanctum.TestContext.ensure_platform(ops.user_id)
    n = System.unique_integer([:positive])
    alice = "per_" <> Prima.Digest.sha256_hex("handle-allow-#{n}")
    bob = "per_" <> Prima.Digest.sha256_hex("handle-deny-#{n}")

    registry(nil, %{
      "alice" => {:held, alice},
      "bob" => {:held, bob},
      "down" => :close
    })

    {view, html} = conn |> log_in_user(ops) |> mount_athanor("/settings")

    assert has_element?(
             view,
             ~s(#door-entry-form input[name="value"][placeholder="@name, or * for everyone"])
           )

    assert html =~ "Allow or deny someone by their name"
    PrismWeb.AdmissionScreens.refute_vocabulary(view |> element("#allowlist") |> render())

    door_entry(view, "door_allow", "@alice")
    assert has_element?(view, "td", alice)
    assert has_element?(view, ~s(td [data-test="door-entry-label"]), "@alice")
    assert {:ok, :allowed} = Sanctum.Door.admit_identifier(alice)

    door_entry(view, "door_deny", "@bob")
    assert has_element?(view, "td", bob)
    assert has_element?(view, ~s(td [data-test="door-entry-label"]), "@bob")
    assert {:error, :denied} = Sanctum.Door.admit_identifier(bob)

    door_entry(view, "door_allow", "@nobody")
    assert render(view) =~ "No one holds that handle at the registry."

    ExUnit.CaptureLog.capture_log(fn ->
      door_entry(view, "door_allow", "@down")
      assert render(view) =~ "The registry could not be reached just now"
    end)

    assert [_, _] = Sanctum.Door.Store.list()

    # An entry made by no name: a person here shows their name, `*`
    # everyone, and an identifier nothing here names where it came from.
    held = test_user()
    record_namespace!(held)
    typed = "per_" <> Prima.Digest.sha256_hex("typed-#{n}")
    {:ok, _} = Sanctum.Door.Store.deny("person", held.user_id, ops.user_id)
    {:ok, _} = Sanctum.Door.Store.allow("identifier", typed, ops.user_id)
    {:ok, _} = Sanctum.Door.Store.allow("wildcard", "*", ops.user_id)
    {view, _html} = build_conn() |> log_in_user(ops) |> mount_athanor("/settings")

    assert has_element?(view, "th", "Name")

    for {value, name} <- [
          {held.user_id, "@" <> held.namespace},
          {typed, "added from the command line"},
          {"*", "everyone"}
        ] do
      assert has_element?(
               view,
               "#allowlist tr",
               ~r/#{Regex.escape(value)}\s+#{Regex.escape(name)}/
             ),
             value
    end
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
    {:ok, _} = Sanctum.TestContext.ensure_platform(ops.user_id)
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

  # The registry: `handles` answers a handle's resolution by name (`:free`
  # for none, `:taken` for one held), the policy version is current, and
  # every signed request is verified under `state` and handed to
  # `answer`.
  defp registry(state, handles, answer \\ fn _request -> flunk("no signed request expected") end) do
    RegistryStub.start!(fn
      %{method: "GET", path: "/v1/legal/version"} ->
        {200, RegistryStub.answer(%{"policy_version" => "2026-09", "policies" => []})}

      %{method: "GET", path: "/v1/handles/" <> handle} ->
        case Map.get(handles, handle, :free) do
          :free -> RegistryStub.refusal(:handle_not_found)
          :taken -> {200, handle_answer(handle, "per_" <> String.duplicate("a", 64))}
          {:held, identifier} -> {200, handle_answer(handle, identifier)}
          :close -> :close
        end

      %{body: body} = request ->
        case RegistryStub.verify(body, state) do
          {:ok, signed} -> answer.(Map.put(request, :signed, signed))
          {:error, reason} -> flunk("the registry refused the request: #{inspect(reason)}")
        end
    end)
  end

  # An allowlist entry typed into the panel's form, then its button clicked.
  defp door_entry(view, button, value) do
    view
    |> element(~s(form[phx-change="door_form_changed"]))
    |> render_change(%{"value" => value})

    view |> element("button[phx-click=#{button}]") |> render_click()
  end

  defp handle_answer(handle, identifier) do
    RegistryStub.answer(%{
      "protocol" => Prima.HandleAnswer.protocol(),
      "registry" => RegistryStub.host(),
      "handle" => handle,
      "identifier" => identifier,
      "directory" => RegistryStub.directory()
    })
  end

  # Signed in, holding `name` as their recorded one, or none: the login
  # helper records a namespace for every person it signs in.
  defp signed_in(conn, person, name \\ nil) do
    conn = log_in_user(conn, person)

    Arca.Repo.update_all(from(u in Arca.Schemas.User, where: u.id == ^person.user_id),
      set: [namespace: name]
    )

    conn
  end

  # Registered at the directory, the recovery code saved.
  defp acknowledged!(person) do
    state = RegistryStub.enroll!(person.user_id)
    as = %Prima.Actor{user_id: person.user_id}

    [attempt] =
      Arca.Repo.all(from(a in Arca.Schemas.IdentityAttempt, where: a.user_id == ^person.user_id))

    {:ok, _} = Arca.IdentityAttempts.acknowledge_kit(as, attempt.id)
    state
  end

  # An added code accepted at the directory, its recovery code not saved.
  defp added!(person, state) do
    as = %Prima.Actor{user_id: person.user_id}

    {:ok, attempt} =
      Arca.IdentityAttempts.open(as, %{
        kind: "holder",
        request_id: "req_#{System.unique_integer([:positive])}",
        user_id: person.user_id,
        identifier: state.identifier,
        directory_url: RegistryStub.directory(),
        entry: "recover-request",
        request_digest: Prima.Digest.sha256("recover-#{System.unique_integer()}"),
        expected_revision: 0,
        expected_head: state.head,
        kit_seed_sealed: "sealed-kit-seed"
      })

    {:ok, _} = Arca.IdentityAttempts.advance(as, attempt.id, "staged", "submitted")

    {:ok, _} =
      Arca.IdentityAttempts.advance(as, attempt.id, "submitted", "accepted", %{
        entry_hash: Prima.Digest.sha256("committed-#{System.unique_integer()}")
      })

    attempt.id
  end

  # A person as a page that admitted them leaves them when it ends before
  # "I saved it": their enrollment opened at `directory` with `name`.
  defp unfinished!(directory, name) do
    person = test_user()
    identity = Sanctum.Test.Newcomers.identity(name)
    :ok = Sanctum.Recovery.open_at_admission(person.user_id, identity, directory.url)
    {person, identity}
  end

  defp attempt(person),
    do:
      Arca.Repo.get_by!(Arca.Schemas.IdentityAttempt, user_id: person.user_id, kind: "enrollment")

  defp prompt_id(view) do
    [_, id] = Regex.run(~r/data-prompt-id="(identity-recovery-\d+)"/, render(view))
    id
  end

  @costs [
    "Your identity is registered at cyfr.run. While cyfr.run cannot be reached, changing your " <>
      "keys, bringing your identity back and other CYFRs checking who you are all wait.",
    "Your recovery code brings your identity back on a new CYFR. Anyone who holds a copy can " <>
      "replace your keys, so keep it apart from your devices.",
    "Add a second recovery code before you rely on one. Only a code you hold can add another.",
    "If every recovery code is lost, nothing can add one. Your identity keeps working here, " <>
      "with no way back if this CYFR is lost.",
    "If this CYFR and every recovery code are lost, your identity is gone, and you start again " <>
      "with a new name.",
    "Bringing your identity back restores you alone, never your private data or the CYFR " <>
      "addresses your devices saved. You add those again from surviving devices or invitations."
  ]

  describe "your name" do
    import PrismWeb.AdmissionScreens

    test "a named person sees their name, their identifier for the command line, another recovery code, what losing it costs and the rotation",
         %{conn: conn} do
      person = test_user()
      state = acknowledged!(person)
      {view, html} = conn |> signed_in(person, "alicia") |> mount_athanor("/settings")

      assert has_element?(view, ~s([data-test="identity"][data-state="named"]))
      assert has_element?(view, ~s([data-test="identity-name"]), "Your name is @alicia.")

      assert has_element?(
               view,
               ~s([data-test="identity-identifier"]),
               "Your identifier, for the command line: #{state.identifier}"
             )

      assert has_element?(view, ~s([data-test="identity-add-code"]), "Add another recovery code")
      assert has_element?(view, ~s([data-test="identity-costs"] summary), "What losing it costs")

      assert view |> element(~s([data-test="identity-costs"] ol)) |> render() |> sentences() ==
               @costs

      assert has_element?(view, ~s([data-test="identity-rotate"]), "Rotate the live key")
      refute has_element?(view, ~s([data-test="identity-show-code"]))
      refute html =~ "sealed-kit-seed"
      refute_vocabulary(identity_card(view))

      for gone <-
            ~w(identity-handle identity-enroll identity-abandon identity-claim identity-add-kit identity-kit identity-directory) do
        refute has_element?(view, ~s([data-test="#{gone}"])), gone
      end

      view |> element(~s([data-test="identity-add-code"])) |> render_click()
      render(view)
      assert has_element?(view, ~s(#system-layer [data-test="recovery"][data-kind="holder"]))
      assert has_element?(view, "#system-layer-title", "Add another recovery code")
      view |> element(~s([data-test="prompt-dismiss"])) |> render_click()

      # Rotating the live key asks for its fresh confirmation in the layer,
      # as this page's own request, and rotates nothing before it.
      view |> element(~s([data-test="identity-rotate"])) |> render_click()
      render(view)
      assert has_element?(view, ~s(#system-layer [data-test="confirmation"][data-own="true"]))

      assert [%{action: "key_rotation", state: "pending"}] =
               Arca.Repo.all(
                 from(c in "pending_confirmations",
                   where: c.user_id == ^person.user_id,
                   select: %{action: c.action, state: c.state}
                 )
               )
    end

    test "an added code whose recovery code waits to be saved is shown again from here", %{
      conn: conn
    } do
      person = test_user()
      state = acknowledged!(person)
      attempt_id = added!(person, state)
      {view, _html} = conn |> signed_in(person, "alicia") |> mount_athanor("/settings")

      assert has_element?(view, ~s([data-test="identity"][data-state="named"]))
      assert has_element?(view, ~s([data-test="identity-add-code"]))

      view
      |> element(~s([data-test="identity-show-code"][phx-value-attempt="#{attempt_id}"]))
      |> render_click()

      render(view)
      assert has_element?(view, ~s(#system-layer [data-test="recovery"][data-kind="kit"]))
      assert has_element?(view, "#system-layer-title", "Your recovery code")
      refute_vocabulary(identity_card(view))
    end

    test "an unfinished person sees screen 2 driven by registry.register, another name in place of a taken one, and their recovery code under one confirmation",
         %{conn: conn} do
      directory = directory!()
      registry!(%{}, claims: [:taken])
      {person, _identity} = unfinished!(directory, "mira")
      attempt = attempt(person)

      {view, _html} = conn |> signed_in(person) |> mount_athanor("/settings")
      render_async(view, 15_000)

      assert has_element?(view, ~s([data-test="identity"][data-state="unfinished"]))

      assert has_element?(
               view,
               ~s([data-test="identity"]),
               "Your name and recovery code are not finished."
             )

      assert screen_2?(view, :taken)
      assert has_element?(view, ~s([data-test="admission-code"]), "Someone took @mira")
      assert has_element?(view, ~s([data-test="identity-costs"]))
      refute has_element?(view, ~s([data-test="identity-add-code"]))
      refute has_element?(view, ~s([data-test="identity-rotate"]))
      refute_vocabulary(identity_card(view))

      view |> element("#admission-rename") |> render_submit(%{"name" => "nova"})
      render_async(view, 15_000)
      assert screen_2?(view, :code)
      assert {:ok, %{namespace: "nova"}} = Sanctum.Tenancy.Users.get(person.user_id)
      refute has_element?(view, ~s([data-test="recovery-code"]))
      refute_vocabulary(identity_card(view))

      view |> element(~s([data-test="identity-show-code"])) |> render_click()
      render(view)
      assert has_element?(view, ~s(#system-layer [data-test="recovery"][data-kind="kit"]))
      assert has_element?(view, "#system-layer-title", "Your recovery code")
      id = prompt_id(view)

      # The prompt's "I saved it" finishes the person: the card reads again.
      ctx = Sanctum.TestContext.session!(person.user_id)
      assert {:ok, _} = Sanctum.Recovery.recovery_code_saved(ctx, attempt.id)
      send(view.pid, {:system_layer, id, :confirmed})
      render_async(view, 15_000)

      assert has_element?(view, ~s([data-test="identity"][data-state="named"]))
      assert has_element?(view, ~s([data-test="identity-name"]), "Your name is @nova.")
    end

    @tag :capture_log
    test "an unfinished person whose cyfr.run does not answer is offered Try again", %{
      conn: conn
    } do
      directory = directory!()
      registry = registry!(%{}, version: :close)
      {person, _identity} = unfinished!(directory, "mira")

      {view, _html} = conn |> signed_in(person) |> mount_athanor("/settings")
      render_async(view, 15_000)

      assert screen_2?(view, :silent)

      assert has_element?(
               view,
               ~s([data-test="admission-code"]),
               "cyfr.run did not answer. Try again."
             )

      refute has_element?(view, ~s([data-test="identity-show-code"]))
      assert %{phase: "accepted"} = attempt(person)

      script(registry, version: :answer)
      view |> element(~s([data-test="admission-retry"])) |> render_click()
      render_async(view, 15_000)
      assert screen_2?(view, :code)
      assert has_element?(view, ~s([data-test="identity-show-code"]), "Show your recovery code")
    end

    test "a person with no name and nothing to finish is told so, with nothing sent", %{
      conn: conn
    } do
      person = test_user()
      RegistryStub.start!(fn _request -> flunk("nothing is sent") end)
      {view, _html} = conn |> signed_in(person) |> mount_athanor("/settings")
      render_async(view, 15_000)

      assert has_element?(view, ~s([data-test="identity"][data-state="unfinished"]))

      assert has_element?(
               view,
               ~s([data-test="admission-error"]),
               "There is no unfinished name and recovery code to finish here."
             )

      refute_vocabulary(identity_card(view))
    end

    test "a person whose keys another CYFR holds is told their name and recovery code are there, and offered nothing",
         %{conn: conn} do
      person = test_user()
      {conn, _identifier} = remote!(conn, person)
      {view, _html} = mount_athanor(conn, "/settings")

      assert has_element?(view, ~s([data-test="identity"][data-state="remote"]))

      assert has_element?(
               view,
               ~s([data-test="identity-remote"]),
               "Your keys are at your CYFR, so your name and recovery code are there."
             )

      for control <-
            ~w(identity-name identity-identifier identity-add-code identity-costs identity-show-code identity-rotate admission-code) do
        refute has_element?(view, ~s([data-test="#{control}"])), control
      end

      refute_vocabulary(identity_card(view))
    end
  end

  # The identity card's markup, the part of the page this card writes.
  defp identity_card(view), do: view |> element("#identity-card") |> render()

  # The text of each item of a list, its whitespace folded.
  defp sentences(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("li")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.split() |> Enum.join(" ")))
  end

  describe "sign-in doors" do
    test "the last door stays while the person holds no passkey here, said in its sentence",
         %{conn: conn} do
      person = test_user()
      {view, _html} = conn |> log_in_user(person) |> mount_athanor("/settings")

      view |> element(~s([data-test="door-unlink"])) |> render_click()
      html = render(view)

      assert html =~ "hold no passkey"
      assert html =~ "link another sign-in method"
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
      refute html =~ "Sign-in method:"
      refute render(view) =~ "Sign-in method:"
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
