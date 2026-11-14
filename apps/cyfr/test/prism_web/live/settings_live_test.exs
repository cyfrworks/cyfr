# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.SettingsLiveTest do
  @moduledoc """
  Settings: the door and the platform settings are the operator's
  sections and nobody else's; the lite/dev preference is every person's
  own. The person's name and their account's identifier are shown, and
  every key of their account is listed, a passkey by its maker and a
  device by its name, with the person's sessions here under each, each
  signed out on its own at once.
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

    # Every person here is an account's, admitted by an allow, `*` or an
    # invitation: none is made here or holds keys at another CYFR.
    door = admin_view |> element("#allowlist > p") |> render()
    assert door =~ "An account signs in when"
    refute door =~ "made here"
    refute door =~ "another CYFR"
    PrismWeb.Vocabulary.refute_vocabulary(door)

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

  describe "invitation links" do
    defp text(html), do: html |> LazyHTML.from_fragment() |> LazyHTML.text() |> String.trim()

    test "the administrator makes a link offering a name, shown once, lists every link by name and place, and revokes one",
         %{conn: conn} do
      ops = test_user()
      {:ok, _} = Sanctum.TestContext.ensure_platform(ops.user_id)

      # The administrator's invitation into a thread they sit in is listed
      # too, by the thread's title.
      {:ok, thread} = Sanctum.SharedThreads.create(ops.user_id, "Settings thread")
      ctx = Sanctum.TestContext.session!(ops.user_id)
      {:ok, %{invitation: threaded}} = Sanctum.Invitations.create(ctx, thread.id)

      {view, html} = conn |> log_in_user(ops) |> mount_athanor("/settings")
      assert html =~ "Invitation links"
      assert has_element?(view, ~s([data-test="invite-cyfr"] [data-test="invitation-create"]))
      refute has_element?(view, ~s([data-test="invitation-new"]))
      assert has_element?(view, ~s(#invite-cyfr tr), ~r/Settings thread\s*pending/)

      assert has_element?(
               view,
               ~s([data-test="invitation-revoke"][phx-value-id="#{threaded.id}"])
             )

      view |> form("#invitation-form", %{"name" => "uj-wren"}) |> render_submit()

      link = view |> element(~s([data-test="invitation-link"])) |> render() |> text()
      assert String.starts_with?(link, Sanctum.origin() <> "/invite#")
      code = link |> String.split("#") |> List.last()
      assert has_element?(view, ~s([data-test="invitation-copy"]))

      # A test CYFR's address is this computer's loopback, which the link
      # opens nowhere else than.
      assert has_element?(view, ~s([data-test="invitation-local"]), "opens only on this computer")

      [%{id: id, issued_by: issuer, name: "uj-wren"}] =
        Arca.Repo.all(from(i in Arca.Schemas.Invitation, where: is_nil(i.thread_id)))

      assert issuer == ops.user_id
      assert {:ok, %{name: "uj-wren"} = shown} = Sanctum.Invitations.lookup(code)
      refute Map.has_key?(shown, :thread)

      assert has_element?(view, ~s(#invite-cyfr tr), ~r/uj-wren\s*this CYFR\s*pending/)
      revoke = ~s(#invite-cyfr [data-test="invitation-revoke"][phx-value-id="#{id}"])
      assert has_element?(view, revoke)

      # Shown once: the page read again lists the link and no longer shows it.
      {again, html} = build_conn() |> log_in_user(ops) |> mount_athanor("/settings")
      refute has_element?(again, ~s([data-test="invitation-new"]))
      refute html =~ code

      again |> element(revoke) |> render_click()

      assert has_element?(again, ~s(#invite-cyfr tr), ~r/uj-wren\s*this CYFR\s*revoked/)
      refute has_element?(again, revoke)
      assert %DateTime{} = Arca.Repo.get!(Arca.Schemas.Invitation, id).revoked_at
      assert {:error, :invitation_invalid} = Sanctum.Invitations.lookup(code)
      assert Arca.Repo.get!(Arca.Schemas.Invitation, threaded.id).revoked_at == nil
    end

    test "a person who is not the administrator sees their own thread links with Revoke, and makes none here",
         %{conn: conn} do
      person = test_user()
      {view, html} = conn |> log_in_user(person) |> mount_athanor("/settings")
      refute html =~ "Invitation links"
      refute has_element?(view, ~s([data-test="invite-cyfr"]))

      {:ok, thread} = Sanctum.SharedThreads.create(person.user_id, "Crew thread")
      ctx = Sanctum.TestContext.session!(person.user_id)
      {:ok, %{invitation: invitation}} = Sanctum.Invitations.create(ctx, thread.id, "uj-oren")

      {view, _html} = build_conn() |> log_in_user(person) |> mount_athanor("/settings")
      assert has_element?(view, ~s(#invite-cyfr tr), ~r/uj-oren\s*Crew thread\s*pending/)
      refute has_element?(view, ~s([data-test="invitation-create"]))

      view
      |> element(~s([data-test="invitation-revoke"][phx-value-id="#{invitation.id}"]))
      |> render_click()

      assert %DateTime{} = Arca.Repo.get!(Arca.Schemas.Invitation, invitation.id).revoked_at
    end
  end

  test "the page says in words what Mode, the request card, a setting and the sign-in are, and Remove asks first",
       %{conn: conn} do
    ops = test_user()
    {:ok, _} = Sanctum.TestContext.ensure_platform(ops.user_id)
    {:ok, _} = Sanctum.Door.Store.allow("wildcard", "*", ops.user_id)
    {view, _html} = conn |> log_in_user(ops) |> mount_athanor("/settings")

    assert has_element?(view, "#mode-words", "Executions, where each run's failure says why")
    assert has_element?(view, "#request-stats h3", "Your requests, last hour")
    assert has_element?(view, "#request-stats", "Nobody's athanor but yours is counted here.")
    assert has_element?(view, ~s([data-test="auth-method"]), "your account, in this browser")

    {:ok, %Cyfr.Platform.Settings.Roster.Entry{doc: doc}} =
      Cyfr.Platform.Settings.Roster.fetch("max_athanors")

    assert has_element?(view, ~s([data-test="setting-doc"]), doc)

    assert has_element?(
             view,
             ~s(button[phx-click="door_remove"][data-confirm^="Remove *?"])
           )

    for html <- [
          view |> element("#mode-words") |> render(),
          view |> element("#request-stats") |> render(),
          view |> element("#approvals") |> render(),
          view |> element("#host-decisions") |> render()
        ],
        do: PrismWeb.Vocabulary.refute_vocabulary(html)
  end

  test "an approval's wait is saved as whole hours, and the page links to API Keys", %{conn: conn} do
    person = test_user()
    {view, _html} = conn |> log_in_user(person) |> mount_athanor("/settings")

    assert has_element?(view, ~s(#approval-hours[placeholder="default"]))
    refute has_element?(view, ~s(#approval-hours[value]))
    assert has_element?(view, ~s([data-test="api-keys-link"] a[href$="/api-keys"]))

    view |> form("#approvals-form", %{"hours" => "0"}) |> render_submit()
    assert render(view) =~ "the wait is a whole number of hours"

    view |> form("#approvals-form", %{"hours" => "6"}) |> render_submit()
    assert has_element?(view, ~s(#approval-hours[value="6"]))

    # Saved in the athanor's settings, where AQUA reads it: the page read
    # again shows it.
    {again, _html} = build_conn() |> log_in_user(person) |> mount_athanor("/settings")
    assert has_element?(again, ~s(#approval-hours[value="6"]))

    # Cleared, the stored wait is gone and AQUA's own default holds again.
    again |> form("#approvals-form", %{"hours" => ""}) |> render_submit()
    assert render(again) =~ "Approvals wait AQUA&#39;s default time again."
    refute has_element?(again, ~s(#approval-hours[value]))
    assert has_element?(again, "#approvals", "Left empty, AQUA's own default")

    athanor = seated_athanor()
    {:ok, row} = Sanctum.Tenancy.Athanors.get(athanor.id)

    refute Map.has_key?(
             Sanctum.Tenancy.Athanors.settings(row)["approvals"] || %{},
             "expiry_hours"
           )
  end

  test "the request card names the page where a failed request with no execution is read", %{
    conn: conn
  } do
    person = test_user()
    {view, _html} = conn |> log_in_user(person) |> mount_athanor("/settings")

    assert has_element?(
             view,
             ~s(#request-stats [data-test="activities-link"][href$="/activities"]),
             "Activities"
           )

    refute view |> element("#request-stats") |> render() =~ "Executions"

    # A failed call that starts no execution: revoking an invitation that
    # does not exist.
    render_click(view, "invitation_revoke", %{"id" => "inv_missing"})

    {activities, _html} = build_conn() |> log_in_user(person) |> mount_athanor("/activities")
    assert has_element?(activities, "tr", ~r/invitation\.revoke.*failed/s)
  end

  test "the administrator reads the host's decisions, opens one, and closing an account asks a confirmation",
       %{conn: conn} do
    ops = test_user()
    {:ok, _} = Sanctum.TestContext.ensure_platform(ops.user_id)

    # A refused call no athanor holds: a decision about the host.
    request_id = Prima.UUID7.request_id()

    anonymous =
      Sanctum.Context.build(authenticated: false, permissions: [], request_id: request_id)

    {:error, _} = Sanctum.Gate.call_external("tools", anonymous, %{"action" => "list"})

    {:ok, [refused]} =
      Arca.DecisionLog.list_global(%Prima.Actor{platform_admin: true}, request_id: request_id)

    {view, _html} = conn |> log_in_user(ops) |> mount_athanor("/settings")
    assert has_element?(view, "#host-decisions tr", ~r/tools\.list\s*refused/)

    view
    |> element(~s(#host-decisions button[phx-value-id="#{refused.call_id}"]))
    |> render_click()

    assert has_element?(view, "#host-decision dd", refused.call_id)

    identifier = "per_" <> Prima.Digest.sha256_hex("closed-#{ops.user_id}")
    view |> form("#tombstone-form", %{"identifier" => identifier}) |> render_submit()

    assert [%{operation: "directory.tombstone"}] =
             Arca.Repo.all(
               from(c in Arca.Schemas.PendingConfirmation, where: c.user_id == ^ops.user_id)
             )

    # Someone who is not the administrator sees neither.
    person = test_user()
    {view, _html} = build_conn() |> log_in_user(person) |> mount_athanor("/settings")
    refute has_element?(view, "#host-decisions")
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
    assert has_element?(view, ~s(td [data-test="door-entry-name"]), "@alice")
    assert {:ok, :allowed} = Sanctum.Door.admit_identifier(alice)

    door_entry(view, "door_deny", "@bob")
    assert has_element?(view, "td", bob)
    assert has_element?(view, ~s(td [data-test="door-entry-name"]), "@bob")
    assert {:error, :denied} = Sanctum.Door.admit_identifier(bob)

    door_entry(view, "door_allow", "@nobody")

    assert render(view) =~
             "No account with that name yet: check the spelling, or ask them to make one."

    ExUnit.CaptureLog.capture_log(fn ->
      door_entry(view, "door_allow", "@down")
      assert render(view) =~ "The registry could not be reached just now"
    end)

    assert [_, _] = Sanctum.Door.Store.list()

    # An entry made by no name: a person here shows their name, `*`
    # everyone, and an identifier nothing here names the identifier.
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
          {typed, typed},
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

  test "people are admitted under their account's name, which the allowlist, the requests and their public address show",
       %{conn: conn} do
    ops = test_user()
    {:ok, _} = Sanctum.TestContext.ensure_platform(ops.user_id)

    tls = Sanctum.Test.DirectoryServer.tls()
    Sanctum.Test.DirectoryServer.listen!()
    Sanctum.Test.DirectoryServer.seam!(tls)
    directory = Sanctum.Test.DirectoryServer.start!(tls)

    [invited, allowed, refused] =
      for _ <- 1..3 do
        account = Sanctum.Test.DirectoryServer.account!(directory.dir, directory.url)
        head = Sanctum.Test.DirectoryServer.cached!(account)

        %{
          identifier: account.identifier,
          directory_url: directory.url,
          head_hash: head.head_hash
        }
      end

    n = System.unique_integer([:positive])
    [mira, oren, wren] = for name <- ["mira", "oren", "wren"], do: "#{name}-#{n}"

    RegistryStub.handles!(
      %{mira => invited.identifier, oren => allowed.identifier, wren => refused.identifier},
      directory.url
    )

    # One comes in by an invitation, one by an allow typed as an
    # identifier, and the third is refused at the door.
    admin = Sanctum.TestContext.session!(ops.user_id) |> Map.put(:platform_admin, true)
    {:ok, %{code: code}} = Sanctum.Invitations.create(admin, nil)
    {:ok, hash} = Sanctum.Invitations.code_hash(code)
    {:ok, _} = Sanctum.Door.Store.allow("identifier", allowed.identifier, ops.user_id)

    {:ok, %{person: first}} = Sanctum.Newcomer.admit({:invitation, hash}, invited)
    {:ok, %{person: second}} = Sanctum.Newcomer.admit(:open, allowed)
    assert {:error, {:door, :not_allowed}} = Sanctum.Newcomer.admit(:open, refused)

    # A request a member asked for names them.
    asked = "per_" <> Prima.Digest.sha256_hex("asked-#{n}")
    {:ok, :created, _} = Sanctum.Door.Store.request("identifier", asked, ops.user_id)

    {view, _html} = conn |> log_in_user(ops) |> mount_athanor("/settings")

    assert has_element?(
             view,
             "#allowlist tr",
             ~r/#{Regex.escape(asked)}\s*#{Regex.escape(asked)}\s*@#{Regex.escape(ops.namespace)}/
           )

    for {identifier, name} <- [{invited.identifier, mira}, {allowed.identifier, oren}] do
      assert has_element?(
               view,
               "#allowlist tr",
               ~r/#{Regex.escape(identifier)}\s*@#{Regex.escape(name)}\s*identifier/
             ),
             name
    end

    assert has_element?(
             view,
             "#allowlist tr",
             ~r/@#{Regex.escape(wren)}\s*#{Regex.escape(refused.identifier)}\s*themselves, at sign-in/
           )

    # Each one's athanor is at their name, as a public address reads it.
    for {person, name} <- [{first, mira}, {second, oren}] do
      {:ok, %{id: athanor_id, slug: ^name}} = Sanctum.Tenancy.Athanors.get_by_owner(person.id)

      assert {:ok, %{athanor_id: ^athanor_id}} =
               Sanctum.TinctureAccess.public_context("@" <> name)
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
  # The person's name and the keys on their account
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

  describe "keys on your account" do
    @apple "fbfc3007-154e-4ecc-8c0b-6e020557d7bd"
    @safari "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Safari/605.1.15"

    # A session the key `kid` signed for at the account's cached head, in
    # the person's own athanor: its token and its row's id.
    defp keyed_session!(person, kid, user_agent) do
      token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      hash = Sanctum.Session.token_hash(token)
      {:ok, athanor} = Sanctum.Tenancy.Athanors.get_by_owner(person.user_id)
      {:ok, %{head_hash: head}} = Arca.PersonIdentities.get(Prima.Actor.system(), person.user_id)
      {browser, system} = Sanctum.UserAgent.words(user_agent)

      :ok =
        Arca.SessionStorage.create_session(
          hash,
          %{
            user_id: person.user_id,
            email: person.email,
            provider: "passkey",
            athanor_id: athanor.id,
            kid: kid,
            head: head,
            browser: browser,
            system: system,
            expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
          },
          lock: %{user_id: person.user_id, athanor_id: nil, source: nil},
          verify: fn _rows -> :ok end
        )

      {:ok, rows} = Arca.SessionStorage.list_live(person.user_id)
      {token, Enum.find(rows, &(&1.token_hash == hash)).id}
    end

    # The terminal's client here, named as its hello named it.
    defp named_device!(person, {pub, _priv}, name) do
      {:ok, athanor} = Sanctum.Tenancy.Athanors.get_by_owner(person.user_id)
      {:ok, %{head_hash: head}} = Arca.PersonIdentities.get(Prima.Actor.system(), person.user_id)

      {:ok, _client} =
        Arca.PairedClients.record(Prima.Actor.in_athanor(athanor.id), %{
          user_id: person.user_id,
          source_kind: "device_cert",
          source_id: "req_#{System.unique_integer([:positive])}",
          device_public_key: pub,
          kid: Prima.Identity.Key.kid(pub),
          head: head,
          display_name: name
        })

      :ok
    end

    defp signed_in_as(conn, token),
      do: Plug.Test.init_test_session(conn, %{"sanctum_session_token" => token})

    defp text(view, selector),
      do: view |> element(selector) |> render() |> String.replace(~r/\s+/, " ")

    test "lists every key of the account by its maker or name, with its sessions here, and links to the account pages for removal",
         %{conn: conn} do
      person = test_user()
      %{account: account, dir: dir} = Sanctum.Test.DirectoryServer.member!(person.user_id)
      account = Sanctum.Test.DirectoryServer.add_passkey!(dir.dir, account, aaguid: @apple)
      _head = Sanctum.Test.DirectoryServer.cached!(account)

      [device] = account.devices
      device_kid = Sanctum.Test.DirectoryServer.kid(device)
      passkey_kid = Prima.Identity.Key.kid(hd(account.passkeys).pub)
      [_genesis, device_added, passkey_added] = account.log

      conn = log_in_user(conn, person)
      named_device!(person, device, "Moon's terminal")
      {own, _own_id} = keyed_session!(person, passkey_kid, @safari)
      {_terminal, terminal_id} = keyed_session!(person, device_kid, nil)

      {view, _html} = conn |> signed_in_as(own) |> mount_athanor("/settings")
      card = text(view, ~s([data-test="keys"]))
      assert card =~ "Keys on your account"
      refute card =~ "Devices connected here"
      refute card =~ "Sign out this passkey"
      refute card =~ "Sign out this device"
      PrismWeb.Vocabulary.refute_vocabulary(view |> element(~s([data-test="keys"])) |> render())

      passkey_row = text(view, ~s([data-test="key"][data-kid="#{passkey_kid}"]))
      assert passkey_row =~ "Apple Passwords passkey, added #{day(passkey_added.at)}"
      assert passkey_row =~ "Safari on macOS"
      assert passkey_row =~ "(this session)"

      device_row = text(view, ~s([data-test="key"][data-kid="#{device_kid}"]))
      assert device_row =~ "Moon&#39;s terminal, added #{day(device_added.at)}"
      refute device_row =~ "(this session)"

      assert view
             |> element(~s([data-test="keys-account"]))
             |> render() =~ ~s(href="#{dir.url}/account/devices")

      # A session signs out alone: the terminal's goes, its key stays listed.
      view
      |> element(~s([data-test="session-end"][phx-value-id="#{terminal_id}"]))
      |> render_click()

      refute has_element?(view, ~s([data-test="session"][data-id="#{terminal_id}"]))
      assert has_element?(view, ~s([data-test="key"][data-kid="#{device_kid}"]))
      assert render(view) =~ "Signed out."
    end

    test "signing out the session the page stands on leaves the page", %{conn: conn} do
      person = test_user()
      %{account: account} = Sanctum.Test.DirectoryServer.member!(person.user_id)
      device_kid = Sanctum.Test.DirectoryServer.kid(hd(account.devices))

      conn = log_in_user(conn, person)
      {own, own_id} = keyed_session!(person, device_kid, @safari)
      {view, _html} = conn |> signed_in_as(own) |> mount_athanor("/settings")

      view |> element(~s([data-test="session-end"][phx-value-id="#{own_id}"])) |> render_click()
      assert_redirect(view, "/login")
      assert {:error, :invalid_session} = Sanctum.Session.load(own)
    end
  end

  defp day(ms), do: ms |> DateTime.from_unix!(:millisecond) |> Calendar.strftime("%-d %b %Y")

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
