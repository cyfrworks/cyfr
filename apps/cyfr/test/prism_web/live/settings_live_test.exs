# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.SettingsLiveTest do
  @moduledoc """
  Settings: the door and the platform settings are the operator's
  sections and nobody else's; the lite/dev preference is every person's
  own. The person's name and their account's identifier are shown, and
  the devices and passkeys of their account connected here are listed: a
  paired device revoked under a fresh confirmation through the page's
  system layer, a passkey signed out here at once.
  """
  use PrismWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Sanctum.Test.RegistryStub

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

  describe "invite to this CYFR" do
    defp text(html), do: html |> LazyHTML.from_fragment() |> LazyHTML.text() |> String.trim()

    test "the administrator creates a link naming no thread, shown once, lists it and revokes it",
         %{conn: conn} do
      ops = test_user()
      {:ok, _} = Sanctum.TestContext.ensure_platform(ops.user_id)

      # The administrator's invitation into a thread they sit in is the
      # thread's, and this section does not list it.
      {:ok, thread} = Sanctum.SharedThreads.create(ops.user_id, "Settings thread")
      ctx = Sanctum.TestContext.session!(ops.user_id)
      {:ok, %{invitation: threaded}} = Sanctum.Invitations.create(ctx, thread.id)

      {view, html} = conn |> log_in_user(ops) |> mount_athanor("/settings")
      assert html =~ "Invite to this CYFR"
      assert has_element?(view, ~s([data-test="invite-cyfr"] [data-test="invitation-create"]))
      refute has_element?(view, ~s([data-test="invitation-new"]))
      refute has_element?(view, ~s([phx-value-id="#{threaded.id}"]))

      view
      |> element(~s([data-test="invitation-create"]))
      |> render_click()

      link = view |> element(~s([data-test="invitation-link"])) |> render() |> text()
      assert String.starts_with?(link, Sanctum.origin() <> "/invite#")
      code = link |> String.split("#") |> List.last()
      assert has_element?(view, ~s([data-test="invitation-copy"]))

      [%{id: id, issued_by: issuer}] =
        Arca.Repo.all(from(i in Arca.Schemas.Invitation, where: is_nil(i.thread_id)))

      assert issuer == ops.user_id
      assert {:ok, shown} = Sanctum.Invitations.lookup(code)
      refute Map.has_key?(shown, :thread)

      revoke = ~s(#invite-cyfr [data-test="invitation-revoke"][phx-value-id="#{id}"])
      assert has_element?(view, revoke)
      refute has_element?(view, ~s([phx-value-id="#{threaded.id}"]))

      # Shown once: the page read again lists the link and no longer shows it.
      {again, html} = build_conn() |> log_in_user(ops) |> mount_athanor("/settings")
      refute has_element?(again, ~s([data-test="invitation-new"]))
      refute html =~ code
      assert has_element?(again, "#invite-cyfr td", "pending")

      again |> element(revoke) |> render_click()

      assert has_element?(again, "#invite-cyfr td", "revoked")
      refute has_element?(again, revoke)
      assert %DateTime{} = Arca.Repo.get!(Arca.Schemas.Invitation, id).revoked_at
      assert {:error, :invitation_invalid} = Sanctum.Invitations.lookup(code)
      assert Arca.Repo.get!(Arca.Schemas.Invitation, threaded.id).revoked_at == nil
    end

    test "a person who is not the administrator does not see the section", %{conn: conn} do
      person = test_user()
      {view, html} = conn |> log_in_user(person) |> mount_athanor("/settings")

      refute html =~ "Invite to this CYFR"
      refute has_element?(view, ~s([data-test="invite-cyfr"]))
      refute has_element?(view, ~s([data-test="invitation-create"]))
    end
  end

  # A key the platform administrator offers is shared from their own
  # vault; Settings holds no credential store of its own.
  test "a platform administrator's Settings offers no place to enter or list a key",
       %{conn: conn} do
    ops = test_user()
    {:ok, _} = Sanctum.TestContext.ensure_platform(ops.user_id)
    {view, html} = conn |> log_in_user(ops) |> mount_athanor("/settings")

    assert html =~ "Server allowlist"

    # No form makes a key: none names its kind or where it may go, and no
    # field takes a value.
    refute has_element?(view, ~s(select[name="kind"]))
    refute has_element?(view, ~s([name="destination_hosts"]))
    refute has_element?(view, ~s(input[type="password"]))

    # No card lists one: nothing on the page says a key is attach-only.
    refute html =~ "attach-only"
  end

  test "the allowlist allows and denies by name, shows each entry's name, and says why a name is refused",
       %{conn: conn} do
    ops = test_user()
    {:ok, _} = Sanctum.TestContext.ensure_platform(ops.user_id)
    n = System.unique_integer([:positive])

    # A handle's answer is read at the directory it names: a scripted one.
    tls = Sanctum.Test.DirectoryServer.tls()
    Sanctum.Test.DirectoryServer.listen!()
    Sanctum.Test.DirectoryServer.seam!(tls)
    directory = Sanctum.Test.DirectoryServer.start!(tls)

    [alice, bob] =
      for _name <- 1..2,
          do: Sanctum.Test.DirectoryServer.account!(directory.dir, directory.url).identifier

    registry(nil, %{
      "alice" => {:held, alice, directory.url},
      "bob" => {:held, bob, directory.url},
      "down" => :close
    })

    {view, html} = conn |> log_in_user(ops) |> mount_athanor("/settings")

    assert has_element?(
             view,
             ~s(#door-entry-form input[name="value"][placeholder="@name, or * for everyone"])
           )

    assert html =~ "Allow or deny someone by their name"
    PrismWeb.Vocabulary.refute_vocabulary(view |> element("#allowlist") |> render())

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
  # The person's name and the devices connected here
  # ---------------------------------------------------------------------------

  describe "your name" do
    test "shows the name this CYFR recorded and the account's identifier", %{conn: conn} do
      person = test_user()
      %{identifier: identifier} = Sanctum.TestContext.account!(person.user_id)
      {view, _html} = conn |> log_in_user(person) |> mount_athanor("/settings")

      assert view |> element(~s([data-test="identity-name"])) |> render() =~
               "@" <> person.namespace

      assert view |> element(~s([data-test="identity-identifier"])) |> render() =~ identifier

      PrismWeb.Vocabulary.refute_vocabulary(
        view
        |> element(~s([data-test="identity"]))
        |> render()
      )
    end
  end

  describe "finishing your name" do
    test "a person with no name here types theirs, and it is recorded once cyfr.run says it is theirs",
         %{conn: conn} do
      person = test_user()
      %{account: account, dir: dir} = Sanctum.Test.DirectoryServer.member!(person.user_id)
      stranger = Sanctum.Test.DirectoryServer.account!(dir.dir, dir.url)

      RegistryStub.handles!(
        %{"mira" => account.identifier, "taken" => stranger.identifier},
        dir.url
      )

      {view, _html} = conn |> log_in_user(person, claim: false) |> mount_athanor("/settings")
      refute has_element?(view, ~s([data-test="identity-name"]))
      card = view |> element(~s([data-test="identity"])) |> render()
      assert card =~ "Finish your name"
      PrismWeb.Vocabulary.refute_vocabulary(card)

      for {typed, sentence} <- [
            {"taken", "@taken is another account&#39;s name, not yours"},
            {"unheld", "No account holds @unheld at cyfr.run"}
          ] do
        view
        |> element(~s([data-test="identity-name-form"]))
        |> render_submit(%{"name" => typed})

        error = view |> element(~s([data-test="identity-name-error"])) |> render()
        assert error =~ sentence
        PrismWeb.Vocabulary.refute_vocabulary(error)
      end

      view
      |> element(~s([data-test="identity-name-form"]))
      |> render_submit(%{"name" => "@mira"})

      assert view |> element(~s([data-test="identity-name"])) |> render() =~ "@mira"
      refute has_element?(view, ~s([data-test="identity-name-form"]))
      assert {:ok, %{namespace: "mira"}} = Sanctum.Tenancy.Users.get(person.user_id)
    end
  end

  describe "devices connected here" do
    test "lists the passkeys that signed in here by their key's short code, and signs one out",
         %{conn: conn} do
      person = test_user()
      %{head: head} = Sanctum.TestContext.account!(person.user_id)
      kid = Prima.Digest.sha256("phone-#{System.unique_integer()}")
      "sha256:" <> hex = kid

      # The passkey's client and a session on it, as its sign-in here
      # records them.
      {:ok, athanor} = Sanctum.Tenancy.Athanors.get_by_owner(person.user_id)

      {:ok, client} =
        Arca.PairedClients.record_passkey(Prima.Actor.in_athanor(athanor.id), %{
          user_id: person.user_id,
          kid: kid,
          head: head
        })

      :ok =
        Arca.SessionStorage.create_session(
          :crypto.strong_rand_bytes(32),
          %{
            user_id: person.user_id,
            provider: "passkey",
            kid: kid,
            head: head,
            client_id: client.id,
            expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
          },
          lock: %{user_id: person.user_id, athanor_id: nil, source: nil},
          verify: fn _rows -> :ok end
        )

      {view, _html} = conn |> log_in_user(person) |> mount_athanor("/settings")
      passkey = ~s([data-test="passkey"][data-kid="#{kid}"])

      # Listed once, as a passkey and not again among the devices.
      assert view |> element(passkey) |> render() =~ String.slice(hex, 0, 16)
      refute has_element?(view, ~s([data-test="device"][data-id="#{client.id}"]))

      view |> element(passkey <> ~s( [data-test="passkey-revoke"])) |> render_click()
      refute has_element?(view, passkey)
    end
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
          {:held, identifier, directory} -> {200, handle_answer(handle, identifier, directory)}
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

  defp handle_answer(handle, identifier, directory \\ RegistryStub.directory()) do
    RegistryStub.answer(%{
      "protocol" => Prima.HandleAnswer.protocol(),
      "registry" => RegistryStub.host(),
      "handle" => handle,
      "identifier" => identifier,
      "directory" => directory
    })
  end
end
