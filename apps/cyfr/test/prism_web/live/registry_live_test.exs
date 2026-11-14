# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.RegistryLiveTest do
  @moduledoc """
  The registry page's acts are requests a passkey of the person's account
  signs: an appeal of a takedown and a sync of their push tokens. Each asks the registry tool
  for its request, bound to the person's session, and opens the account
  pages' sign page with it in a new tab; nothing reaches the registry
  until the answer returns to the sign-in page (`PrismWeb.LoginLiveTest`).
  No identity provider is asked for any of them.

  A publisher claim and its verification are signed the same way. A
  namespace's push tokens and members are managed under the push token
  this CYFR holds for it: a revoke and a removal are asked before they
  are sent, and issuing a token waits on a fresh confirmation, its secret
  shown once. A namespace is reported through the report sheet.

  The registry is `Sanctum.Test.RegistryStub`, which answers the page's
  terms read and fails the case on any signed request.
  """
  use PrismWeb.ConnCase, async: false

  alias Sanctum.Test.RegistryStub

  @directory "https://dir-a.test"

  setup %{conn: conn} do
    Prima.Test.Env.put_app_env(:sanctum, :directory_url, @directory)
    user = test_user()

    RegistryStub.start!(fn
      %{method: "GET", path: "/v1/legal/version"} ->
        {200,
         RegistryStub.answer(%{
           "policy_version" => "2026-09",
           "updated_at" => "2026-09-14T08:30:00Z",
           "policies" => [%{"name" => "terms", "title" => "Terms of Service", "sha256" => "x"}]
         })}

      %{method: "GET"} ->
        {404, ""}

      %{method: "POST", path: path} ->
        flunk("a signed request reached the registry from the page: #{path}")
    end)

    {:ok, conn: log_in_user(conn, user), user: user}
  end

  # The request the page opened the account pages with, in a new tab
  # through its layer: the registry request it carries, for the person's
  # account.
  defp hopped(view, user) do
    assert_push_event(view, "system_layer:hop", %{layer: "system-layer", url: url})
    assert String.starts_with?(url, @directory <> "/account/sign#")
    [_page, fragment] = String.split(url, "#", parts: 2)
    {:ok, map} = Prima.SignIn.parse_fragment(fragment)

    {:ok, %Prima.SignIn{purpose: :registry, registry_request: registry}} =
      Prima.SignIn.decode(map)

    assert {:ok, registry.identifier} == Sanctum.Tenancy.Users.identifier(user.user_id)
    registry
  end

  # `registry.whoami` names the person's publisher namespaces, and the page
  # lists each beside the personal one. The test registry is a closed
  # port, so the namespace is kept unconfirmed and its listing is refused.
  test "a publisher namespace the person holds a push token for is one the page reads",
       %{conn: conn, user: user} do
    ctx = %{Sanctum.TestContext.local() | user_id: user.user_id, athanor_id: seated_athanor().id}

    :ok =
      Compendium.Registry.CredentialStore.put_push_token(
        ctx,
        Compendium.RegistryHost.canonical_host(),
        "acme.dev",
        "cyfr_pt_fake_acme",
        "owner"
      )

    {view, _html} = mount_athanor(conn, "/registry")
    render_async(view, 5_000)

    render_async(view, 5_000)
    assert "acme.dev" in :sys.get_state(view.pid).socket.assigns.namespaces
  end

  # cyfr.run filters a listing by `namespace`: asked by any other key it
  # answers the whole registry's newest components.
  test "the page lists a namespace's components by asking the registry for that namespace",
       %{conn: conn, user: user} do
    ctx = %{Sanctum.TestContext.local() | user_id: user.user_id, athanor_id: seated_athanor().id}

    :ok =
      Compendium.Registry.CredentialStore.put_push_token(
        ctx,
        Compendium.RegistryHost.canonical_host(),
        "acme.dev",
        "cyfr_pt_fake_acme",
        "owner"
      )

    {view, _html} = mount_athanor(conn, "/registry")
    render_async(view, 5_000)

    assert_receive {:registry_request,
                    %{method: "GET", path: "/v1/components?namespace=acme.dev"}},
                   5_000
  end

  # The registry holds another publisher's component beside the person's
  # own: asked by namespace it answers only the namespace's, and the page
  # lists what it was answered, under that namespace.
  test "the page lists the person's own components, never another publisher's",
       %{conn: conn, user: user} do
    row = fn slug, name ->
      %{
        "id" => "cmp_#{name}",
        "name" => name,
        "version" => "1.0.0",
        "component_type" => "reagent",
        "namespace_slug" => slug,
        "status" => "active"
      }
    end

    listing = fn rows ->
      {200, Jason.encode!(%{"components" => rows, "total" => length(rows)})}
    end

    RegistryStub.start!(fn
      %{method: "GET", path: "/v1/components?" <> query} ->
        case URI.decode_query(query) do
          %{"namespace" => "acme.dev"} -> listing.([row.("acme.dev", "acme-widget")])
          %{"namespace" => _other} -> listing.([])
          _unfiltered -> listing.([row.("zeta.dev", "zeta-widget")])
        end

      %{method: "GET"} ->
        {404, ""}
    end)

    ctx = %{Sanctum.TestContext.local() | user_id: user.user_id, athanor_id: seated_athanor().id}

    :ok =
      Compendium.Registry.CredentialStore.put_push_token(
        ctx,
        Compendium.RegistryHost.canonical_host(),
        "acme.dev",
        "cyfr_pt_fake_acme",
        "owner"
      )

    {view, _html} = mount_athanor(conn, "/registry")
    render_async(view, 5_000)
    render_async(view, 5_000)

    html = render(view)
    assert html =~ "acme-widget"
    refute html =~ "zeta-widget"
  end

  test "an appeal is a request the person's passkey signs, with no sign-in method asked",
       %{conn: conn, user: user} do
    {view, _html} = mount_athanor(conn, "/registry")
    render_async(view, 5_000)
    html = render_click(view, "open-appeal", %{"id" => "cmp_taken_down"})
    refute html =~ "GitHub"
    refute html =~ "provider"

    html =
      render_submit(view, "submit-appeal", %{"argument" => "This named the wrong component."})

    assert %Prima.RegistryRequest{
             operation: "appeal.file",
             body: %{
               "action_type" => "takedown",
               "action_ref" => "cmp_taken_down",
               "argument" => "This named the wrong component."
             }
           } = hopped(view, user)

    assert html =~ "Sign the appeal"
    refute has_element?(view, "form[phx-submit=submit-appeal]")
  end

  # An action named past what a registry request carries (256 bytes) makes
  # no request to sign.
  test "an appeal whose request cannot be made keeps the form and what was typed",
       %{conn: conn} do
    {view, _html} = mount_athanor(conn, "/registry")
    render_async(view, 5_000)
    render_click(view, "open-appeal", %{"id" => String.duplicate("c", 257)})

    {submitted, _log} =
      ExUnit.CaptureLog.with_log(fn ->
        render_submit(view, "submit-appeal", %{"argument" => "Again."})
      end)

    assert submitted =~ "Submit failed"
    assert has_element?(view, "form[phx-submit=submit-appeal]")
    assert render(view) =~ "Again."
  end

  # The registry is the configured one (`RegistryStub`'s host, not
  # cyfr.run): the page names it as the registry, never as cyfr.run.
  test "the page speaks of the registry, never of cyfr.run", %{conn: conn} do
    refute Compendium.RegistryHost.canonical_rest_host() =~ "cyfr.run"

    {view, _html} = mount_athanor(conn, "/registry")
    render_async(view, 5_000)

    render_async(view, 5_000)
    html = render(view)
    assert html =~ "Components you&#39;ve published to the registry."
    assert html =~ "The account service&#39;s terms: version"
    refute html =~ "cyfr.run"
  end

  # The terms are accepted once, when the account is made; a later
  # version asks nobody to accept again. The page names the version in
  # force and when it was published, and asks for nothing.
  describe "the account service's terms" do
    test "the page names the version in force and its date, linked to where the terms are read",
         %{conn: conn} do
      {view, _html} = mount_athanor(conn, "/registry")
      render_async(view, 5_000)

      assert view |> element("#registry-terms") |> render() =~
               ~r{The account service&#39;s terms: version <span class="font-mono">2026-09</span>, updated 14 September 2026}

      assert has_element?(view, ~s(#registry-terms a[href$="/legal"]))
    end

    test "with no date from the registry, the page names the version alone", %{conn: conn} do
      RegistryStub.start!(fn
        %{method: "GET", path: "/v1/legal/version"} ->
          {200, RegistryStub.answer(%{"policy_version" => "2026-09", "policies" => []})}

        %{method: "GET"} ->
          {404, ""}
      end)

      {view, _html} = mount_athanor(conn, "/registry")
      render_async(view, 5_000)
      line = view |> element("#registry-terms") |> render()

      assert line =~
               ~s(The account service&#39;s terms: version <span class="font-mono">2026-09</span>)

      refute line =~ "updated"
    end

    test "nothing on the page asks to accept the terms", %{conn: conn} do
      {view, _html} = mount_athanor(conn, "/registry")
      render_async(view, 5_000)
      html = render(view)

      refute html =~ "Registry policies"
      refute html =~ "asks you to accept its current version"
      refute html =~ "Accept version"
      refute has_element?(view, ~s([phx-click="accept-policy"]))
    end
  end

  describe "a yank sent to the registry" do
    # How long a test waits for the registry's answer to reach the page.
    @answered_ms 5_000

    # The browser gives up on a pushed event it waits on for 30 seconds and
    # reloads (the shipped script's push timeout); a test stands that wait
    # in with this one.
    @push_timeout_ms 1_000

    # The registry, holding the yank until the test releases it (the test
    # is told `{:held, stub}`), and the person's push token for their
    # namespace.
    defp held_yank!(user) do
      test = self()

      RegistryStub.start!(fn
        %{method: "POST", path: "/v1/components/" <> _} ->
          send(test, {:held, self()})

          receive do
            :release -> :ok
          end

          {200, RegistryStub.answer(%{"status" => "yanked"})}

        %{method: "GET"} ->
          {404, ""}
      end)

      ctx = %{
        Sanctum.TestContext.local()
        | user_id: user.user_id,
          athanor_id: seated_athanor().id
      }

      :ok =
        Compendium.Registry.CredentialStore.put_push_token(
          ctx,
          Compendium.RegistryHost.canonical_host(),
          user.namespace,
          "cyfr_pt_yank",
          "personal"
        )
    end

    # An event as the browser pushes it: waited on no longer than the
    # browser waits.
    defp pushed(fun) do
      task = Task.async(fun)

      case Task.yield(task, @push_timeout_ms) do
        {:ok, html} -> html
        nil -> :unanswered
      end
    end

    defp registry_requests do
      receive do
        {:registry_request, %{method: method, path: path}} ->
          [{method, path} | registry_requests()]
      after
        0 -> []
      end
    end

    test "a yank held past the browser's wait answers at once, says so, is sent once, and its answer reloads the page",
         %{conn: conn, user: user} do
      held_yank!(user)
      reference = "reagent:#{user.namespace}.held:1.0.0"
      {view, _html} = mount_athanor(conn, "/registry")
      render_async(view, @answered_ms)
      registry_requests()
      render_click(view, "open-yank", %{"reference" => reference})
      yank = fn -> render_submit(view, "yank", %{"reference" => reference, "reason" => ""}) end

      html = pushed(yank)
      assert_receive {:held, stub}, @answered_ms

      try do
        assert is_binary(html), "the page did not answer while the registry held the yank"
        assert html =~ "Yanking…"

        # A second yank while the first is sent sends nothing.
        assert is_binary(pushed(yank))

        # Held past the browser's wait, and past it twice, the page still
        # says it is yanking.
        Process.sleep(2 * @push_timeout_ms)
        assert render(view) =~ "Yanking…"
      after
        send(stub, :release)
      end

      Prima.Test.Wait.wait_until(
        fn -> render(view) =~ "Yanked #{reference}." end,
        @answered_ms,
        "the registry's answer to reach the page"
      )

      render_async(view, @answered_ms)
      refute render(view) =~ "Yanking…"
      sent = registry_requests()
      assert [{"POST", _yank}] = Enum.filter(sent, &(elem(&1, 0) == "POST"))
      # The page read the registry again once it answered.
      assert {"GET", "/v1/legal/version"} in sent
    end
  end

  test "a sync asks a passkey to sign the mint and sends nothing until it is signed",
       %{conn: conn, user: user} do
    {view, _html} = mount_athanor(conn, "/registry")
    render_async(view, 5_000)
    html = render_click(view, "sync", %{})

    assert %Prima.RegistryRequest{
             operation: "tokens.mint",
             body: %{"label" => label}
           } = hopped(view, user)

    assert label == Compendium.Registry.CredentialStore.wire_label()
    assert html =~ "Sign the sync"
    refute_received {:registry_request, %{method: "POST"}}
  end

  describe "a publisher namespace" do
    test "a claim asks a passkey to sign the claim of the domain and sends nothing until it is signed",
         %{conn: conn, user: user} do
      {view, _html} = mount_athanor(conn, "/registry")
      render_async(view, 5_000)
      html = view |> form("#claim-publisher", %{"slug" => " acme.dev "}) |> render_submit()

      assert %Prima.RegistryRequest{operation: "publisher.claim", body: %{"slug" => "acme.dev"}} =
               hopped(view, user)

      assert html =~ "Sign the claim of acme.dev with your passkey in the new tab."
      refute_received {:registry_request, %{method: "POST"}}
    end

    test "a verification asks a passkey to sign it, under the label this CYFR's tokens carry",
         %{conn: conn, user: user} do
      {view, _html} = mount_athanor(conn, "/registry")
      render_async(view, 5_000)
      html = view |> form("#verify-publisher", %{"slug" => "acme.dev"}) |> render_submit()

      assert %Prima.RegistryRequest{
               operation: "publisher.verify",
               body: %{"slug" => "acme.dev", "label" => label}
             } = hopped(view, user)

      assert label == Compendium.Registry.CredentialStore.wire_label()
      assert html =~ "Sign the verification of acme.dev"
      refute_received {:registry_request, %{method: "POST"}}
    end

    test "a claim with no domain is refused on the page and asks nothing", %{conn: conn} do
      {view, _html} = mount_athanor(conn, "/registry")
      render_async(view, 5_000)
      html = render_submit(view, "claim-publisher", %{"slug" => "  "})

      assert html =~ "Name the domain of the publisher namespace."
      refute_push_event(view, "system_layer:hop", %{})
    end
  end

  describe "a namespace's push tokens and members" do
    @token %{
      "id" => "6a1b0e1e-0000-4000-8000-000000000001",
      "label" => "build server",
      "created_at" => "2026-11-01T10:00:00Z",
      "handle" => "alice"
    }
    @revoked %{
      "id" => "6a1b0e1e-0000-4000-8000-000000000002",
      "label" => "old laptop",
      "created_at" => "2026-10-01T10:00:00Z",
      "revoked_at" => "2026-10-20T10:00:00Z"
    }
    @members [
      %{"handle" => "alice", "role" => "admin", "member_identifier" => "id_alice"},
      %{"handle" => "bob", "role" => "member", "member_identifier" => "id_bob"}
    ]

    # The registry, answering the namespace's tokens and members and
    # `changes.(request)` for every other request; the person's push
    # token for `acme.dev` and for their personal namespace.
    defp managed!(user, changes) do
      RegistryStub.start!(fn
        %{method: "GET", path: "/v1/namespaces/acme.dev/tokens"} ->
          {200, Jason.encode!(%{"tokens" => [@token, @revoked]})}

        %{method: "GET", path: "/v1/namespaces/acme.dev/members"} ->
          {200, Jason.encode!(%{"members" => @members})}

        %{method: "GET", path: "/v1/namespaces/" <> _personal} ->
          {200, Jason.encode!(%{"tokens" => []})}

        %{method: "GET"} = request ->
          changes.(request) || {404, ""}

        request ->
          changes.(request)
      end)

      ctx = %{
        Sanctum.TestContext.local()
        | user_id: user.user_id,
          athanor_id: seated_athanor().id
      }

      for {slug, token, role} <- [
            {"acme.dev", "cyfr_pt_acme", "admin"},
            {user.namespace, "cyfr_pt_personal", "personal"}
          ] do
        :ok =
          Compendium.Registry.CredentialStore.put_push_token(
            ctx,
            Compendium.RegistryHost.canonical_host(),
            slug,
            token,
            role
          )
      end

      ctx
    end

    defp no_change(%{method: "GET"}), do: nil

    defp no_change(%{method: method, path: path}),
      do: flunk("the page sent #{method} #{path} unasked")

    defp manage!(conn, slug) do
      {view, _html} = mount_athanor(conn, "/registry")
      render_async(view, 5_000)
      render_async(view, 5_000)
      render_click(view, "manage", %{"slug" => slug})
      render_async(view, 5_000)
      view
    end

    defp sent(method) do
      receive do
        {:registry_request, %{method: ^method} = request} -> request
      after
        5_000 -> flunk("no #{method} reached the registry")
      end
    end

    defp registry_paths do
      receive do
        {:registry_request, %{path: path}} -> [path | registry_paths()]
      after
        0 -> []
      end
    end

    defp bearer?(%{headers: headers}, token),
      do: Enum.any?(headers, &(String.downcase(&1) == "authorization: bearer #{token}"))

    test "a publisher namespace lists its push tokens and members, read under its own push token",
         %{conn: conn, user: user} do
      managed!(user, &no_change/1)
      view = manage!(conn, "acme.dev")

      assert_received {:registry_request,
                       %{method: "GET", path: "/v1/namespaces/acme.dev/tokens"} = tokens}

      assert bearer?(tokens, "cyfr_pt_acme")

      assert_received {:registry_request,
                       %{method: "GET", path: "/v1/namespaces/acme.dev/members"}}

      html = render(view)
      assert html =~ "Manage <span class=\"font-mono\">acme.dev</span>"
      assert html =~ "build server"
      assert html =~ "made by alice · issued 2026-11-01T10:00:00Z · never used"
      assert html =~ "revoked 2026-10-20T10:00:00Z"
      # Only a standing token offers Revoke.
      assert has_element?(
               view,
               ~s(button[phx-click="ask-revoke"][phx-value-id="#{@token["id"]}"])
             )

      refute has_element?(
               view,
               ~s(button[phx-click="ask-revoke"][phx-value-id="#{@revoked["id"]}"])
             )

      assert has_element?(view, "form#member-alice select option[value=admin][selected]")
      assert has_element?(view, "form#member-bob select option[value=member][selected]")
    end

    test "the personal namespace lists its push tokens and has no members", %{
      conn: conn,
      user: user
    } do
      managed!(user, &no_change/1)
      view = manage!(conn, user.namespace)

      assert has_element?(view, "form#issue-token")
      refute has_element?(view, "form#add-member")
      refute Enum.any?(registry_paths(), &String.ends_with?(&1, "/members"))
    end

    test "a namespace this CYFR holds no push token for says to sync", %{conn: conn, user: user} do
      view = manage!(conn, user.namespace)

      assert render(view) =~
               "This CYFR holds no push token for #{user.namespace}: sync your push tokens on the Registry page."

      refute_received {:registry_request, %{path: "/v1/namespaces/" <> _}}
    end

    test "a namespace the person does not hold is not managed", %{conn: conn, user: user} do
      managed!(user, &no_change/1)
      view = manage!(conn, "zeta.dev")

      refute has_element?(view, "form#issue-token")
      refute_received {:registry_request, %{path: "/v1/namespaces/zeta.dev/" <> _}}
    end

    test "a revoke is asked before it is sent, and then revokes that token under the namespace's push token",
         %{conn: conn, user: user} do
      managed!(user, fn
        %{method: "DELETE", path: "/v1/namespaces/acme.dev/tokens/" <> _} -> {204, ""}
        request -> no_change(request)
      end)

      view = manage!(conn, "acme.dev")
      html = render_click(view, "ask-revoke", %{"id" => @token["id"]})
      assert html =~ "Revoke this push token?"
      refute_received {:registry_request, %{method: "DELETE"}}

      render_click(view, "revoke-token", %{})
      delete = sent("DELETE")
      assert delete.path == "/v1/namespaces/acme.dev/tokens/#{@token["id"]}"
      assert bearer?(delete, "cyfr_pt_acme")

      Prima.Test.Wait.wait_until(
        fn -> render(view) =~ "Push token revoked." end,
        5_000,
        "the revoke's answer"
      )

      assert :sys.get_state(view.pid).socket.assigns.revoke_pending == nil
    end

    test "a revoke the person cancels sends nothing", %{conn: conn, user: user} do
      managed!(user, &no_change/1)
      view = manage!(conn, "acme.dev")
      render_click(view, "ask-revoke", %{"id" => @token["id"]})
      render_click(view, "close-revoke", %{})
      render_click(view, "revoke-token", %{})

      refute_received {:registry_request, %{method: "DELETE"}}
    end

    test "issuing a push token waits on a fresh confirmation, then issues it once and shows its secret once",
         %{conn: conn, user: user} do
      ctx =
        managed!(user, fn
          %{method: "POST", path: "/v1/namespaces/acme.dev/tokens"} ->
            {201, Jason.encode!(%{"id" => "tok_new", "token" => "cyfr_pt_issued_once"})}

          request ->
            no_change(request)
        end)

      view = manage!(conn, "acme.dev")
      view |> form("#issue-token", %{"label" => "ci runner"}) |> render_submit()

      assert {:ok, [%{ref: ref, operation: "registry.tokens_issue"}]} =
               Arca.PendingConfirmations.list_open(Sanctum.Context.actor(ctx), ctx.user_id)

      refute_received {:registry_request, %{method: "POST"}}
      refute render(view) =~ "cyfr_pt_issued_once"

      Sanctum.TestContext.prove!(ctx, ref)
      post = sent("POST")
      assert post.path == "/v1/namespaces/acme.dev/tokens"
      assert bearer?(post, "cyfr_pt_acme")
      assert Jason.decode!(post.body) == %{"label" => "ci runner"}

      Prima.Test.Wait.wait_until(
        fn -> render(view) =~ "cyfr_pt_issued_once" end,
        5_000,
        "the issued token"
      )

      assert render(view) =~ "Copy it now — it won&#39;t be shown again."
      render_click(view, "dismiss-issued", %{})
      refute render(view) =~ "cyfr_pt_issued_once"
      refute_received {:registry_request, %{method: "POST"}}
      Cyfr.Test.Sandbox.end_views()
    end

    test "adding a member sends their handle and role", %{conn: conn, user: user} do
      managed!(user, fn
        %{method: "POST", path: "/v1/namespaces/acme.dev/members"} -> {201, ""}
        request -> no_change(request)
      end)

      view = manage!(conn, "acme.dev")
      view |> form("#add-member", %{"handle" => " carol ", "role" => "admin"}) |> render_submit()

      post = sent("POST")
      assert bearer?(post, "cyfr_pt_acme")
      assert Jason.decode!(post.body) == %{"target_personal_slug" => "carol", "role" => "admin"}

      Prima.Test.Wait.wait_until(fn -> render(view) =~ "Added carol." end, 5_000, "the add")
    end

    test "changing a member's role sends the new role for that member", %{conn: conn, user: user} do
      managed!(user, fn
        %{method: "PATCH", path: "/v1/namespaces/acme.dev/members/bob"} -> {204, ""}
        request -> no_change(request)
      end)

      view = manage!(conn, "acme.dev")
      view |> form("#member-bob", %{"role" => "admin"}) |> render_submit()

      patch = sent("PATCH")
      assert Jason.decode!(patch.body) == %{"role" => "admin"}

      Prima.Test.Wait.wait_until(
        fn -> render(view) =~ "Changed bob&#39;s role." end,
        5_000,
        "the change"
      )
    end

    test "a removal is asked before it is sent, and then removes that member",
         %{conn: conn, user: user} do
      managed!(user, fn
        %{method: "DELETE", path: "/v1/namespaces/acme.dev/members/bob"} -> {204, ""}
        request -> no_change(request)
      end)

      view = manage!(conn, "acme.dev")
      html = render_click(view, "ask-remove", %{"handle" => "bob"})
      assert html =~ "every push token they made for it is revoked"
      refute_received {:registry_request, %{method: "DELETE"}}

      render_click(view, "remove-member", %{})
      assert sent("DELETE").path == "/v1/namespaces/acme.dev/members/bob"
      Prima.Test.Wait.wait_until(fn -> render(view) =~ "Removed bob." end, 5_000, "the removal")
    end

    test "a change the registry refuses says why, and the members stay as read",
         %{conn: conn, user: user} do
      managed!(user, fn
        %{method: "POST", path: "/v1/namespaces/acme.dev/members"} ->
          {403,
           Jason.encode!(%{
             "errors" => [
               %{"code" => "FORBIDDEN", "message" => "admin role required for this namespace"}
             ]
           })}

        request ->
          no_change(request)
      end)

      view = manage!(conn, "acme.dev")
      members = :sys.get_state(view.pid).socket.assigns.members
      view |> form("#add-member", %{"handle" => "carol", "role" => "member"}) |> render_submit()
      sent("POST")

      Prima.Test.Wait.wait_until(
        fn -> render(view) =~ "Adding failed: " end,
        5_000,
        "the refusal"
      )

      assert :sys.get_state(view.pid).socket.assigns.members == members
      assert :sys.get_state(view.pid).socket.assigns.acting == nil
    end
  end

  describe "reporting a namespace" do
    test "the report sheet opens on the namespace and sends it as the report's target",
         %{conn: conn, user: user} do
      RegistryStub.start!(fn
        %{method: "POST", path: "/v1/abuse-reports"} -> {201, Jason.encode!(%{"id" => "rpt_1"})}
        %{method: "GET"} -> {404, ""}
      end)

      ctx = %{
        Sanctum.TestContext.local()
        | user_id: user.user_id,
          athanor_id: seated_athanor().id
      }

      :ok =
        Compendium.Registry.CredentialStore.put_push_token(
          ctx,
          Compendium.RegistryHost.canonical_host(),
          user.namespace,
          "cyfr_pt_personal",
          "personal"
        )

      {view, _html} = mount_athanor(conn, "/registry")
      render_async(view, 5_000)
      view |> form("#report-namespace", %{"slug" => "spam.example"}) |> render_submit()

      html = render(view)
      assert html =~ "Report this namespace"
      assert html =~ "spam.example"

      view
      |> form("#report-form", %{"category" => "spam", "details" => "Floods search."})
      |> render_submit()

      receive do
        {:registry_request, %{method: "POST", path: "/v1/abuse-reports", body: body}} ->
          sent = Jason.decode!(body)
          assert sent["target_namespace"] == "spam.example"
          refute Map.has_key?(sent, "target_component_ref")
          assert sent["category"] == "spam"
      after
        5_000 -> flunk("the report did not reach the registry")
      end

      Prima.Test.Wait.wait_until(
        fn -> render(view) =~ "Report sent to the registry&#39;s moderators." end,
        5_000,
        "the report's answer"
      )
    end

    test "a report with no namespace named opens nothing", %{conn: conn} do
      {view, _html} = mount_athanor(conn, "/registry")
      render_async(view, 5_000)
      html = render_submit(view, "report-namespace", %{"slug" => " "})

      assert html =~ "Name the namespace to report."
      refute html =~ "Report this namespace"
    end
  end
end
