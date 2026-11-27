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
  import Prima.Test.Wait

  alias PrismWeb.MemoryWords
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

  test "a second person given the administrator's mark sees and uses the administrator's Settings; the last mark stays",
       %{conn: conn} do
    ops = test_user()
    {:ok, _} = Sanctum.TestContext.ensure_platform(ops.user_id)
    mira = test_user()
    {:ok, mira_row} = Sanctum.Tenancy.Users.get(mira.user_id)

    {view, _html} = conn |> log_in_user(mira) |> mount_athanor("/settings")
    refute has_element?(view, "#allowlist")

    {view, _html} = build_conn() |> log_in_user(ops) |> mount_athanor("/settings")

    admins =
      view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query(~s([data-test="admin"]))

    assert Enum.count(admins) == 1
    assert has_element?(view, ~s([data-test="admin"][data-id="#{ops.user_id}"]))
    refute has_element?(view, ~s(button[phx-click="admin_clear"]))

    # Marking asks the administrator to confirm, through the system layer.
    view |> form("#admin-form", %{"person" => mira.user_id}) |> render_submit()

    assert [%{operation: "door.mark_admin"}] =
             Arca.Repo.all(
               from(c in Arca.Schemas.PendingConfirmation, where: c.user_id == ^ops.user_id)
             )

    {:ok, _} = Sanctum.Tenancy.Users.mark_platform_admin(mira_row, ops.user_id)

    # Mira, now an administrator, sees the allowlist and changes it.
    {view, _html} = build_conn() |> log_in_user(mira) |> mount_athanor("/settings")
    assert has_element?(view, "#allowlist")
    assert has_element?(view, ~s([data-test="admin"][data-id="#{mira.user_id}"]))

    identifier = "per_" <> Prima.Digest.sha256_hex("second-admin-#{mira.user_id}")

    view
    |> element(~s(form[phx-change="door_form_changed"]))
    |> render_change(%{"value" => identifier})

    view |> element("button[phx-click=door_allow]") |> render_click()
    assert {:ok, :allowed} = Sanctum.Door.admit_identifier(identifier)

    # The first administrator's mark comes off; the last one, Mira's, stays.
    {:ok, ops_row} = Sanctum.Tenancy.Users.get(ops.user_id)
    {:ok, _} = Sanctum.Tenancy.Users.clear_platform_admin(ops_row, mira.user_id)

    assert {:error, :last_admin} =
             Sanctum.Tenancy.Users.clear_platform_admin(mira_row, mira.user_id)

    assert Sanctum.Tenancy.platform_admin?(mira.user_id)
  end

  test "the page says in words what Mode, the request card, a setting and the sign-in are, and Remove asks first",
       %{conn: conn} do
    ops = test_user()
    {:ok, _} = Sanctum.TestContext.ensure_platform(ops.user_id)
    {:ok, _} = Sanctum.Door.Store.allow("wildcard", "*", ops.user_id)
    {view, _html} = conn |> log_in_user(ops) |> mount_athanor("/settings")

    assert has_element?(view, "#mode-words", "Executions, where each run's failure says why")

    # The lite words name every page lite's menu lists, and the dev words none of them.
    for %{label: label} <- PrismWeb.Nav.items("lite") do
      assert has_element?(view, ~s(#mode-words [data-test="mode-lite"]), label)
      refute has_element?(view, ~s(#mode-words [data-test="mode-dev"]), label)
    end

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
          view |> element(~s([data-test="api-keys-link"])) |> render(),
          view |> element("#host-decisions") |> render()
        ],
        do: PrismWeb.Vocabulary.refute_vocabulary(html)
  end

  test "the page links to API Keys", %{conn: conn} do
    person = test_user()
    {view, _html} = conn |> log_in_user(person) |> mount_athanor("/settings")

    assert has_element?(view, ~s([data-test="api-keys-link"] a[href$="/api-keys"]))
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

  describe "the administrator's setup" do
    @market %{
      "hosts" => ["api.market.example"],
      "methods" => ["GET"],
      "paths" => ["/v1/quotes"]
    }

    # A person signed in to their own athanor, an administrator or not.
    defp person!(admin?) do
      user = test_user()
      if admin?, do: {:ok, _} = Sanctum.TestContext.ensure_platform(user.user_id)
      {:ok, own} = Sanctum.Tenancy.Athanors.get_by_owner(user.user_id)

      ctx =
        Sanctum.Context.build(
          user_id: user.user_id,
          athanor_id: own.id,
          permissions: [:*],
          scope: :athanor,
          auth_method: :oidc,
          authenticated: true
        )

      %{
        user: user,
        conn: log_in_user(build_conn(), user),
        own: own,
        ctx: Sanctum.TestContext.via(ctx, :prism)
      }
    end

    defp key!(%{ctx: ctx}, name, destination) do
      {:ok, %{entry: entry}} =
        Sanctum.TestContext.confirming(
          ctx,
          &Sanctum.Gate.call_external("vault", &1, %{
            "action" => "create",
            "name" => name,
            "kind" => "api_key",
            "fields" => %{"MARKET_KEY" => "mk-sentinel-#{name}"},
            "destination" => destination,
            "disclose" => false
          })
        )

      entry
    end

    defp seen(%{user: user}) do
      {:ok, row} = Sanctum.Tenancy.Users.get(user.user_id)
      Sanctum.Tenancy.Users.prefs(row)["admin_setup_seen"]
    end

    defp texts(view, selector) do
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(selector)
      |> Enum.map(&(&1 |> LazyHTML.text() |> String.replace(~r/\s+/, " ") |> String.trim()))
    end

    test "opens for an administrator at ?setup=1, writes that it was seen, says each step, " <>
           "and is offered again from Settings once closed" do
      admin = person!(true)
      {view, _html} = mount_athanor(admin.conn, "/settings?setup=1", admin.own)

      assert has_element?(view, ~s([data-test="setup"]))
      refute has_element?(view, ~s([data-test="setup-open"]))
      assert seen(admin) == true

      assert texts(view, ~s([data-test="setup"] ol > li > span)) == [
               "Share a key with everyone.",
               "Let people in.",
               "How this CYFR is reached.",
               "What only administrators can do."
             ]

      [share, let_in, reach, administrators] =
        texts(view, ~s([data-test="setup"] ol > li > p:first-of-type))

      assert share =~ "what each new person's Aqua uses when it fits"
      assert share =~ "daily cap per person filled in"
      assert let_in =~ "invitation link"
      assert let_in =~ "allowlist"
      assert reach =~ "cyfr access"
      assert reach =~ "opens only on this computer"
      assert administrators =~ "second administrator"
      assert administrators =~ "cyfr backup"
      assert administrators =~ "the database, the files stored on that machine"
      assert administrators =~ "Files kept in S3 storage are not in it"
      refute administrators =~ "everything"
      assert has_element?(view, ~s([data-test="setup"] a[href="#admins"]))
      assert has_element?(view, ~s([data-test="setup"] a[href="#invite-cyfr"]))
      assert has_element?(view, ~s([data-test="setup"] a[href="#allowlist"]))
      PrismWeb.Vocabulary.refute_vocabulary(view |> element(~s([data-test="setup"])) |> render())

      # No key yet: the first step says where one is connected.
      assert has_element?(view, ~s([data-test="setup-no-key"]), "Connect one on your Aqua page.")

      view |> element(~s([data-test="setup-close"])) |> render_click()
      refute has_element?(view, ~s([data-test="setup"]))
      view |> element(~s([data-test="setup-open"])) |> render_click()
      assert has_element?(view, ~s([data-test="setup"]))
      Cyfr.Test.Sandbox.end_views()
    end

    test "opens for nobody but an administrator, read from their row as it is now" do
      person = person!(false)
      {view, _html} = mount_athanor(person.conn, "/settings?setup=1", person.own)
      refute has_element?(view, ~s([data-test="setup"]))
      refute has_element?(view, ~s([data-test="setup-open"]))
      assert seen(person) == nil

      # An administrator whose mark was taken away while signed in: the
      # session still remembers the capability, the row does not.
      admin = person!(true)
      {view, _html} = mount_athanor(admin.conn, "/settings", admin.own)
      assert has_element?(view, ~s([data-test="setup-open"]))

      {1, _} =
        Arca.Repo.update_all(
          from(u in Arca.Schemas.User, where: u.id == ^admin.user.user_id),
          set: [platform_admin_at: nil]
        )

      view |> element(~s([data-test="setup-open"])) |> render_click()
      refute has_element?(view, ~s([data-test="setup"]))
      assert seen(admin) == nil

      # Nor does the first step's event open a sheet outside the setup.
      market = key!(admin, "market key", @market)
      render_click(view, "setup_share", %{"id" => market.id})
      refute has_element?(view, "#system-layer-dialog [data-kind=share]")
      Cyfr.Test.Sandbox.end_views()
    end

    test "a mark taken away while the setup is open closes it at its next act, which does " <>
           "nothing" do
      admin = person!(true)
      market = key!(admin, "market key", @market)
      {view, _html} = mount_athanor(admin.conn, "/settings?setup=1", admin.own)
      share = ~s([data-test="setup-key-share"][phx-value-id="#{market.id}"])
      assert has_element?(view, share)

      {1, _} =
        Arca.Repo.update_all(
          from(u in Arca.Schemas.User, where: u.id == ^admin.user.user_id),
          set: [platform_admin_at: nil]
        )

      view |> element(share) |> render_click()
      refute has_element?(view, "#system-layer-dialog [data-kind=share]")
      refute has_element?(view, ~s([data-test="setup"]))
      assert render(view) =~ "You no longer administer this CYFR, so nothing was done."
      Cyfr.Test.Sandbox.end_views()
    end

    test "the first step's event acts on a listed key alone: keys not read, or outside the " <>
           "person's own athanor, open nothing and keep the page up" do
      admin = person!(true)
      market = key!(admin, "market key", @market)
      {view, _html} = mount_athanor(admin.conn, "/settings?setup=1", admin.own)

      for state <- [:unread, :not_own] do
        :sys.replace_state(view.pid, fn channel ->
          update_in(channel.socket, &Phoenix.Component.assign(&1, :setup_keys, state))
        end)

        render_click(view, "setup_share", %{"id" => market.id})
        assert Process.alive?(view.pid), inspect(state)
        refute has_element?(view, "#system-layer-dialog [data-kind=share]"), inspect(state)
      end

      Cyfr.Test.Sandbox.end_views()
    end

    test "the first step lists the administrator's shareable keys, the newest first, and " <>
           "opens the sharing sheet at everyone with the daily cap per person; what is made " <>
           "is what the sheet shows when confirmed" do
      admin = person!(true)
      # Named so the alphabet orders them the other way round: the step
      # orders them by when each was made.
      older = key!(admin, "alpha key", @market)
      newer = key!(admin, "zulu key", @market)
      _not_shareable = key!(admin, "open key", %{"hosts" => ["api.market.example"]})

      {1, _} =
        Arca.Repo.update_all(
          from(e in Arca.Schemas.VaultEntry, where: e.id == ^older.id),
          set: [inserted_at: ~U[2026-01-01 00:00:00.000000Z]]
        )

      {view, _html} = mount_athanor(admin.conn, "/settings?setup=1", admin.own)

      assert texts(view, ~s([data-test="setup-key"] > span:first-child)) ==
               ["zulu key", "alpha key"]

      view
      |> element(~s([data-test="setup-key-share"][phx-value-id="#{newer.id}"]))
      |> render_click()

      sheet = "#system-layer-dialog form#system-layer-share"
      assert has_element?(view, sheet <> ~s( input[name="audience"][value="everyone"][checked]))
      assert has_element?(view, sheet <> ~s( input[name="person_daily"][value="50"]))
      refute view |> element(sheet <> ~s( input[name="total_daily"])) |> render() =~ ~s(value="5)

      assert texts(view, ~s([data-test="share-everyone"])) == [
               "You administer this CYFR, so a key you share with everyone is also what each " <>
                 "new person's Aqua uses when it fits."
             ]

      # The preset is not submitted by itself: a submit naming no audience
      # makes nothing, whatever the sheet started from.
      view |> element(sheet) |> render_submit(%{"audience" => ""})

      assert has_element?(
               view,
               "#system-layer-dialog [role=alert]",
               "Choose who it is shared with"
             )

      # The administrator changes the cap before confirming: what is made is
      # what the sheet shows then.
      typed = %{"audience" => "everyone", "person_daily" => "20", "total_daily" => ""}
      view |> form(sheet, typed) |> render_change()
      view |> form(sheet, typed) |> render_submit()

      assert {:ok, [%{ref: ref, operation: "share.create"}]} =
               Arca.PendingConfirmations.list_open(
                 Sanctum.Context.actor(admin.ctx),
                 admin.user.user_id
               )

      Sanctum.TestContext.prove!(admin.ctx, ref)

      shares = fn ->
        {:ok, %{shares: shares}} =
          Sanctum.Gate.call_external("share", admin.ctx, %{"action" => "list"})

        shares
      end

      wait_until(fn -> shares.() != [] end, 2_000, "the share made once confirmed")

      assert [%{entry_id: entry_id, audience: "everyone", person_daily: 20, total_daily: nil}] =
               shares.()

      assert entry_id == newer.id

      wait_until(
        fn ->
          has_element?(
            view,
            ~s([data-test="setup-key"]:first-child),
            "Shared with everyone"
          )
        end,
        2_000,
        "the step reads the key shared"
      )

      refute has_element?(
               view,
               ~s([data-test="setup-key-share"][phx-value-id="#{newer.id}"])
             )

      # A key already shared with everyone opens no second sheet.
      render_click(view, "setup_share", %{"id" => newer.id})
      refute has_element?(view, "#system-layer-dialog [data-kind=share]")

      # The share stands under the Vault page's Shared by you with the cap
      # that was confirmed.
      [share] = shares.()
      {vault, _html} = mount_athanor(admin.conn, "/vault", admin.own)

      assert texts(
               vault,
               ~s([data-test="shared-by-you-row"][data-id="#{share.id}"] [data-test="share-line"])
             ) == ["zulu key, shared with everyone, 0 today, at most 20 a person a day"]

      Cyfr.Test.Sandbox.end_views()
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

  describe "memory use" do
    @mib 1_048_576
    @boot String.duplicate("f", 32)

    defp record!(counters, names, endpoint \\ "wrk_page", after_rev \\ 0) do
      {:ok, claim} =
        Arca.JobClaims.claim("memory", Arca.JobClaims.cell_key(), "boot_page", 60_000)

      report = %{
        boot: @boot,
        budget: 8_000 * @mib,
        work: 4_800 * @mib,
        floor: 164 * @mib,
        used: 1_000 * @mib,
        counters: counters,
        next: nil
      }

      {:ok, _stored} =
        Arca.MemoryRecord.store(claim, :none, endpoint, after_rev, report, names, 90)

      :ok
    end

    defp used(rev, athanor_id, opts) do
      %{
        rev: rev,
        day: Keyword.get(opts, :day, Date.utc_today()),
        athanor: athanor_id,
        kind: Keyword.get(opts, :kind, "program"),
        subject: Keyword.get(opts, :subject),
        bytes: Keyword.get(opts, :mib, 0) * @mib,
        mib_ms: Keyword.get(opts, :mib_ms, 0),
        measured_ms: Keyword.get(opts, :measured_ms, 0),
        peak_bytes: Keyword.get(opts, :peak, 0) * @mib,
        cap: Keyword.get(opts, :cap, 0),
        machine: Keyword.get(opts, :machine, 0),
        either: 0
      }
    end

    defp own_athanor_id(person) do
      _conn = log_in_user(build_conn(), person)
      seated_athanor().id
    end

    test "the administrator reads who used what by person, kind and name, and nobody else does" do
      terry = test_user()
      alice = test_user()
      ops = test_user()
      {:ok, _} = Sanctum.TestContext.ensure_platform(ops.user_id)
      t = own_athanor_id(terry)
      a = own_athanor_id(alice)

      record!(
        [
          used(1, t,
            subject: "srv_t",
            mib: 500,
            mib_ms: 1_800_000_000,
            measured_ms: 3_900_000,
            peak: 700,
            cap: 1
          ),
          used(2, a, kind: "run", mib: 164, measured_ms: 45_000, peak: 164, machine: 2)
        ],
        %{{t, "srv_t"} => %{name: "claude", shown: "program"}}
      )

      {view, _html} = build_conn() |> log_in_user(ops) |> mount_athanor("/settings")
      section = view |> element("#memory-use") |> render()

      assert section =~ "Memory use"

      assert section =~
               "In use: 1000.0 MB of 4.7 GB, of which the work listed below uses 664.0 MB now; " <>
                 "164.0 MB more is kept ready for the next run."

      assert section =~ "claude"
      assert section =~ "500.0 MB"
      assert section =~ "Day (UTC)"
      used = view |> cells("#memory-days") |> Enum.map(&Enum.at(&1, 3))

      assert [
               "461.5 MB on average",
               "at most 700.0 MB, for 1 hour 5 minutes in all",
               "Ended for memory: " <> ended(cap: 1)
             ] in used

      assert [
               "0 B on average",
               "at most 164.0 MB, for 45 seconds in all",
               "Ended for memory: " <> ended(machine: 2)
             ] in used

      assert section =~ "Counted a few seconds ago."
      PrismWeb.Vocabulary.refute_vocabulary(section)

      for person <- [terry, alice] do
        {view, html} = build_conn() |> log_in_user(person) |> mount_athanor("/settings")
        refute html =~ "Memory use"
        refute has_element?(view, "#memory-use")
      end
    end

    # "In use" is the machine's charges, which can exceed what the rows
    # read for reasons the record does not carry: the page says how much
    # of it the rows account for, never why, and nothing when they
    # account for all of it or more.
    test "the total says how much of it the work listed below uses" do
      ops = test_user()
      {:ok, _} = Sanctum.TestContext.ensure_platform(ops.user_id)
      o = own_athanor_id(ops)

      record!(
        [
          used(1, o, kind: "program", subject: "srv_o", mib: 500),
          used(2, o, kind: "run", mib: 164)
        ],
        %{{o, "srv_o"} => %{name: "everything", shown: "program"}}
      )

      {view, _html} = build_conn() |> log_in_user(ops) |> mount_athanor("/settings")

      use_line = fn ->
        view
        |> element(~s(#memory-use [data-test="memory-in-use"]))
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.text()
        |> String.trim()
      end

      assert use_line.() ==
               "In use: 1000.0 MB of 4.7 GB, of which the work listed below uses 664.0 MB now; " <>
                 "164.0 MB more is kept ready for the next run."

      set_endpoint = fn fields ->
        Arca.Repo.update_all(
          from(e in Arca.Schemas.MemoryEndpoint, where: e.endpoint == "wrk_page"),
          set: fields
        )

        send(view.pid, :memory)
      end

      set_endpoint.(floor: 0)

      assert use_line.() ==
               "In use: 1000.0 MB of 4.7 GB, of which the work listed below uses 664.0 MB now."

      set_endpoint.(used: 664 * @mib)
      assert use_line.() == "In use: 664.0 MB of 4.7 GB."

      set_endpoint.(used: 600 * @mib)
      assert use_line.() == "In use: 600.0 MB of 4.7 GB."
    end

    test "a program marked mcp reads as an mcp program, its terminal as a terminal" do
      ops = test_user()
      {:ok, _} = Sanctum.TestContext.ensure_platform(ops.user_id)
      o = own_athanor_id(ops)

      record!(
        [
          used(1, o, kind: "program", subject: "srv_e", mib: 246, measured_ms: 1_000),
          used(2, o, kind: "terminal", subject: "srv_e", mib: 233, measured_ms: 1_000)
        ],
        %{{o, "srv_e"} => %{name: "everything", shown: "tool"}}
      )

      {view, _html} = build_conn() |> log_in_user(ops) |> mount_athanor("/settings")

      assert cells(view, ~s(#memory-use [data-test="memory-machine"] table)) == [
               ["@#{ops_name(o)}", "terminal", "everything", "233.0 MB"],
               ["@#{ops_name(o)}", "mcp program", "everything", "246.0 MB"]
             ]

      assert view |> cells("#memory-days") |> Enum.map(&Enum.at(&1, 2)) ==
               [["everything", "terminal"], ["everything", "mcp program"]]
    end

    test "each day's row says its use in a person's units, in four columns that stack when narrow" do
      ops = test_user()
      {:ok, _} = Sanctum.TestContext.ensure_platform(ops.user_id)
      o = own_athanor_id(ops)
      me = "@" <> ops_name(o)

      record!(
        [
          used(1, o, kind: "run", peak: 28, measured_ms: 0),
          used(5, o, kind: "terminal", subject: "srv_z", peak: 0, measured_ms: 0),
          used(2, o, kind: "build", mib_ms: 162 * 20_000, measured_ms: 20_000, peak: 318),
          used(3, o,
            kind: "program",
            subject: "srv_e",
            mib_ms: 192 * 600_000,
            measured_ms: 600_000,
            peak: 246
          ),
          used(4, o,
            kind: "terminal",
            subject: "srv_s",
            mib_ms: 95 * 7_200_000,
            measured_ms: 7_200_000,
            peak: 143,
            cap: 2,
            machine: 1
          )
        ],
        %{
          {o, "srv_e"} => %{name: "everything", shown: "tool"},
          {o, "srv_s"} => %{name: "shell", shown: "terminal"}
        }
      )

      {view, _html} = build_conn() |> log_in_user(ops) |> mount_athanor("/settings")

      table =
        view |> element("#memory-days") |> render() |> LazyHTML.from_fragment()

      assert table |> LazyHTML.query("thead th") |> Enum.map(&String.trim(LazyHTML.text(&1))) ==
               ["Day (UTC)", "Person", "What", "Used"]

      today = Date.to_iso8601(Date.utc_today())

      # A row that was ended says so under what it used; one that was not
      # says nothing of it. With no time measured the cell is one line.
      assert cells(view, "#memory-days") == [
               [
                 today,
                 me,
                 [MemoryWords.kind(:build)],
                 ["162.0 MB on average", "at most 318.0 MB, for 20 seconds in all"]
               ],
               [today, me, [MemoryWords.kind(:run)], ["at most 28.0 MB"]],
               [today, me, [MemoryWords.kind(:terminal)], ["nothing measured"]],
               [
                 today,
                 me,
                 ["shell", MemoryWords.kind(:terminal)],
                 [
                   "95.0 MB on average",
                   "at most 143.0 MB, for 2 hours in all",
                   "Ended for memory: " <> ended(cap: 2, machine: 1)
                 ]
               ],
               [
                 today,
                 me,
                 ["everything", MemoryWords.kind(:tool)],
                 ["192.0 MB on average", "at most 246.0 MB, for 10 minutes in all"]
               ]
             ]

      # Below the width its four columns fit at, the table is no table:
      # its heading goes and each row and cell stacks, so nothing scrolls
      # sideways and no column is held in place.
      classes = fn selector ->
        table |> LazyHTML.query(selector) |> Enum.flat_map(&LazyHTML.attribute(&1, "class"))
      end

      for {selector, narrow, wide} <- [
            {"table", "block", "sm:table"},
            {"thead", "hidden", "sm:table-header-group"},
            {"tbody tr", "block", "sm:table-row"},
            {"tbody td", ~r/\b(inline-)?block\b/, "sm:table-cell"}
          ],
          class <- classes.(selector) do
        assert class =~ narrow
        assert class =~ wide
        refute class =~ "sticky"
      end
    end

    # A day's endings as the shared words say them, joined as a row joins them.
    defp ended(counts) do
      %{cap: 0, machine: 0, either: 0}
      |> Map.merge(Map.new(counts))
      |> MemoryWords.ended()
      |> Enum.join("; ")
    end

    test "a stacked day row breaks a long person's name inside its card" do
      ops = test_user()
      {:ok, _} = Sanctum.TestContext.ensure_platform(ops.user_id)
      o = own_athanor_id(ops)
      long = String.duplicate("w", 39)

      Arca.Repo.update_all(from(a in Arca.Schemas.Athanor, where: a.id == ^o), set: [slug: long])
      record!([used(1, o, kind: "run", mib_ms: 1_000, measured_ms: 1_000, peak: 1)], %{})

      {view, _html} = build_conn() |> log_in_user(ops) |> mount_athanor("/settings")

      [person] =
        view
        |> element("#memory-days")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("tbody td:nth-child(2)")
        |> Enum.to_list()

      assert String.trim(LazyHTML.text(person)) == "@" <> long

      # No wider than its row, and broken where it would be: as What is.
      classes = person |> LazyHTML.attribute("class") |> hd() |> String.split()
      assert "max-w-full" in classes
      assert "break-words" in classes
    end

    # Each row's cells, their words with runs of space, no-break ones
    # among them, as one: a cell of lines as the list of its lines.
    defp cells(view, selector) do
      words =
        &(&1
          |> LazyHTML.text()
          |> String.replace("\u00a0", " ")
          |> String.split()
          |> Enum.join(" "))

      view
      |> element(selector)
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("tbody tr")
      |> Enum.map(fn row ->
        row
        |> LazyHTML.query("td")
        |> Enum.map(fn cell ->
          case Enum.to_list(LazyHTML.query(cell, "span.block")) do
            [] -> words.(cell)
            lines -> Enum.map(lines, words)
          end
        end)
      end)
    end

    defp ops_name(athanor_id) do
      {:ok, athanor} = Sanctum.Tenancy.Athanors.get(athanor_id)
      athanor.slug
    end

    test "the days show seven at a time, the newest first" do
      ops = test_user()
      {:ok, _} = Sanctum.TestContext.ensure_platform(ops.user_id)
      o = own_athanor_id(ops)
      today = Date.utc_today()

      record!(
        for(
          n <- 0..8,
          do: used(n + 1, o, kind: "build", day: Date.add(today, -n), measured_ms: 1_000)
        ),
        %{}
      )

      {view, _html} = build_conn() |> log_in_user(ops) |> mount_athanor("/settings")
      days = view |> element("#memory-days") |> render()

      assert days =~ Date.to_iso8601(today)
      assert days =~ Date.to_iso8601(Date.add(today, -6))
      refute days =~ Date.to_iso8601(Date.add(today, -7))

      view |> element(~s([data-test="memory-more"])) |> render_click()
      days = view |> element("#memory-days") |> render()

      assert days =~ Date.to_iso8601(Date.add(today, -8))
      refute has_element?(view, ~s([data-test="memory-more"]))
    end

    test "a mark taken away shows no more days, though the page still offers them" do
      # The page's context is kept as read for a minute, so only the
      # click's own read of the record can see the mark gone.
      Prima.Test.Env.put_app_env(:sanctum, :caller_memo_ttl_ms, 60_000)
      ops = test_user()
      {:ok, _} = Sanctum.TestContext.ensure_platform(ops.user_id)
      o = own_athanor_id(ops)
      today = Date.utc_today()

      record!(
        for(
          n <- 0..8,
          do: used(n + 1, o, kind: "build", day: Date.add(today, -n), measured_ms: 1_000)
        ),
        %{}
      )

      {view, _html} = build_conn() |> log_in_user(ops) |> mount_athanor("/settings")
      assert view |> element("#memory-days") |> render() =~ Date.to_iso8601(Date.add(today, -6))

      # The mark taken away as `Sanctum.TestContext.ensure_platform/1` sets it.
      {1, _} =
        Arca.Repo.update_all(from(u in Arca.Schemas.User, where: u.id == ^ops.user_id),
          set: [platform_admin_at: nil]
        )

      view |> element(~s([data-test="memory-more"])) |> render_click()
      section = view |> element("#memory-use") |> render()

      refute section =~ Date.to_iso8601(Date.add(today, -7))
      refute section =~ Date.to_iso8601(Date.add(today, -8))
      refute section =~ Date.to_iso8601(today)
      assert section =~ "Memory use cannot be read right now."
    end

    # The page's guard reads the person's standing before any message is
    # served, so a store that cannot say who administers stops the page
    # there; the read fails here at the record's own table.
    test "a record that cannot be read keeps nothing of it, and says so" do
      ops = test_user()
      {:ok, _} = Sanctum.TestContext.ensure_platform(ops.user_id)
      o = own_athanor_id(ops)
      record!([used(1, o, subject: "srv_o", mib: 500, peak: 500)], %{})

      {view, _html} = build_conn() |> log_in_user(ops) |> mount_athanor("/settings")
      assert view |> element("#memory-use") |> render() =~ "500.0 MB"

      Arca.Repo.query!("ALTER TABLE memory_endpoints RENAME TO memory_endpoints_unavailable")

      try do
        ExUnit.CaptureLog.capture_log(fn ->
          send(view.pid, :memory)
          section = view |> element("#memory-use") |> render()

          assert section =~ "Memory use cannot be read right now."
          refute section =~ "500.0 MB"
          refute section =~ "Nothing has reported its memory yet"
        end)
      after
        Arca.Repo.query!("ALTER TABLE memory_endpoints_unavailable RENAME TO memory_endpoints")
      end
    end

    test "a service that has not answered is said as the service it is, never as a machine" do
      ops = test_user()
      {:ok, _} = Sanctum.TestContext.ensure_platform(ops.user_id)
      o = own_athanor_id(ops)
      record!([used(1, o, subject: "srv_o", mib: 500, peak: 500)], %{})
      silent = [Opus.Programs.local(), Prima.LocusPool.builds_endpoint(), "wrk_gone"]
      for endpoint <- silent, do: record!([], %{}, endpoint)
      an_hour_ago = DateTime.add(DateTime.utc_now(), -3_600, :second)
      since = MemoryWords.clock(an_hour_ago)

      Arca.Repo.update_all(from(e in Arca.Schemas.MemoryEndpoint, where: e.endpoint in ^silent),
        set: [heard_at: an_hour_ago]
      )

      {view, _html} = build_conn() |> log_in_user(ops) |> mount_athanor("/settings")
      section = view |> element("#memory-use") |> render()

      refute section =~ "Machine"
      assert section =~ "Counted a few seconds ago."

      # One stop is one sentence, as the shared words say it.
      said =
        PrismWeb.MemoryWords.silent(for e <- silent, do: %{endpoint: e, heard_at: an_hour_ago})

      assert said =~ "The services for builds, programs and runs (wrk_gone) have not answered"
      assert said =~ "since #{since}"

      assert view
             |> element(~s(#memory-use [data-test="memory-unanswered"]))
             |> render()
             |> LazyHTML.from_fragment()
             |> LazyHTML.text()
             |> String.trim() == said

      assert section |> String.split(~s(data-test="memory-machine")) |> length() == 2
    end

    test "one machine holding no person's work says so without naming a machine" do
      ops = test_user()
      {:ok, _} = Sanctum.TestContext.ensure_platform(ops.user_id)
      record!([], %{})

      {view, _html} = build_conn() |> log_in_user(ops) |> mount_athanor("/settings")
      section = view |> element("#memory-use") |> render()

      assert section =~ "No person&#39;s work uses memory now."
      refute section =~ "on it now"
      refute section =~ "Machine"

      # The line under the total says the rows account for none of it.
      assert section =~
               "In use: 1000.0 MB of 4.7 GB; 164.0 MB more is kept ready for the next run."
    end

    test "a row keeps its place when its size passes another's" do
      ops = test_user()
      {:ok, _} = Sanctum.TestContext.ensure_platform(ops.user_id)
      o = own_athanor_id(ops)

      names = %{
        {o, "srv_b"} => %{name: "bee", shown: "program"},
        {o, "srv_a"} => %{name: "ant", shown: "program"}
      }

      record!(
        [
          used(1, o, kind: "program", subject: "srv_b", mib: 900),
          used(2, o, kind: "program", subject: "srv_a", mib: 600),
          used(3, o, kind: "run", mib: 300)
        ],
        names
      )

      {view, _html} = build_conn() |> log_in_user(ops) |> mount_athanor("/settings")

      rows = fn ->
        view
        |> element(~s(#memory-use [data-test="memory-machine"] table))
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("tbody tr")
        |> Enum.map(fn row ->
          row |> LazyHTML.query("td") |> Enum.drop(1) |> Enum.map(&String.trim(LazyHTML.text(&1)))
        end)
      end

      assert rows.() == [
               ["run", "—", "300.0 MB"],
               ["program", "ant", "600.0 MB"],
               ["program", "bee", "900.0 MB"]
             ]

      record!(
        [
          used(4, o, kind: "program", subject: "srv_b", mib: 50),
          used(5, o, kind: "program", subject: "srv_a", mib: 800),
          used(6, o, kind: "run", mib: 950)
        ],
        names,
        "wrk_page",
        3
      )

      send(view.pid, :memory)

      assert rows.() == [
               ["run", "—", "950.0 MB"],
               ["program", "ant", "800.0 MB"],
               ["program", "bee", "50.0 MB"]
             ]
    end

    test "two rows of one person and kind with no name keep their places when their sizes cross" do
      ops = test_user()
      {:ok, _} = Sanctum.TestContext.ensure_platform(ops.user_id)
      o = own_athanor_id(ops)

      record!(
        [
          used(1, o, kind: "terminal", subject: "srv_a", mib: 900),
          used(2, o, kind: "terminal", subject: "srv_b", mib: 600)
        ],
        %{}
      )

      {view, _html} = build_conn() |> log_in_user(ops) |> mount_athanor("/settings")

      sizes = fn ->
        view
        |> element(~s(#memory-use [data-test="memory-machine"] table))
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("tbody tr td:last-child")
        |> Enum.map(&String.trim(LazyHTML.text(&1)))
      end

      assert sizes.() == ["900.0 MB", "600.0 MB"]

      record!(
        [
          used(3, o, kind: "terminal", subject: "srv_a", mib: 800),
          used(4, o, kind: "terminal", subject: "srv_b", mib: 950)
        ],
        %{},
        "wrk_page",
        2
      )

      send(view.pid, :memory)

      assert sizes.() == ["800.0 MB", "950.0 MB"]
    end
  end
end
