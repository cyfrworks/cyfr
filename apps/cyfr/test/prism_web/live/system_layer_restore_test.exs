# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.SystemLayerRestoreTest.Host do
  @moduledoc false
  # A page mounted through the context guard, holding the layer as a
  # settings page does, and forwarding what the layer tells it.
  use Phoenix.LiveView

  on_mount {CyfrWeb.ContextGuard, :protected}

  @impl true
  def mount(_params, session, socket),
    do: {:ok, assign(socket, test: session["test"], listen: Map.get(session, "listen", true))}

  @impl true
  def handle_info({:prompt, prompt}, socket) do
    PrismWeb.SystemLayer.show("system-layer", prompt)
    {:noreply, socket}
  end

  def handle_info(message, socket) do
    send(socket.assigns.test, {:host, message})
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.live_component
      module={PrismWeb.SystemLayer}
      id="system-layer"
      context={@context}
      listen={@listen}
    />
    """
  end
end

defmodule PrismWeb.SystemLayerRestoreTest do
  @moduledoc """
  The system layer's restore checklist after a declared restore: the API
  keys and webhooks the restore suspended, each with its re-enable
  control where the page reaches it, the profiles to consent to again and
  the entries to rotate. A re-enable is the layer's own sensitive change,
  confirmed by a passkey of the person's account like any other, and
  made again by the layer once confirmed. A device the restore suspended
  is not listed: it comes back by a fresh hello.
  """

  use PrismWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Prima.Test.Wait

  alias PrismWeb.SystemLayer.Prompt
  alias PrismWeb.SystemLayerRestoreTest.Host
  alias Sanctum.TestContext.Authenticator

  # ---- fixtures ------------------------------------------------------------------

  defp layer(view), do: with_target(view, "#system-layer")

  defp state_of(view),
    do: inspect(:sys.get_state(view.pid), limit: :infinity, printable_limit: :infinity)

  defp held_secret(view) do
    [secret] = Regex.run(~r/cnf_[A-Za-z0-9_-]{43}/, state_of(view))
    secret
  end

  # A passkey's proof given from this client: the layer opens the account
  # pages in a new tab with the record's `confirm` request, and the answer
  # the person's passkey of their account signs there returns to `/login`
  # in that tab, which takes it under this browser's session.
  defp prove_here!(view, ref, authenticator) do
    view |> element(~s([data-test="confirm-passkey"][phx-value-ref="#{ref}"])) |> render_click()
    assert_push_event(view, "system_layer:hop", %{layer: "system-layer", url: url})
    [_page, fragment] = String.split(url, "#", parts: 2)
    {:ok, request} = fragment |> Prima.SignIn.parse_fragment() |> elem(1) |> Prima.SignIn.decode()
    ctx = :sys.get_state(view.pid).socket.assigns.context
    account = Sanctum.TestContext.account!(ctx.user_id)
    answer = Authenticator.answer(authenticator, request, account.identifier)

    assert {:ok, %{purpose: :confirm, ref: ^ref}} =
             Sanctum.SignIn.answer(answer, {:session, ctx.session_token_hash})
  end

  defp open_prompt(view) do
    case Regex.run(~r/data-prompt-id="([^"]+)"/, render(view)) do
      [_, id] -> id
      nil -> nil
    end
  end

  defp now, do: DateTime.utc_now()
  defp uniq, do: System.unique_integer([:positive])

  defp insert!(schema, row) do
    {1, _} = Arca.Repo.insert_all(schema, [row])
    row.id
  end

  defp key!(athanor_id, user_id) do
    insert!(Arca.Schemas.ApiKey, %{
      id: Prima.UUID7.generate_id("key"),
      name: "key-#{uniq()}",
      key_hash: :crypto.strong_rand_bytes(32),
      key_prefix: "cyfr_sk_rs",
      type: "service",
      scope: "[]",
      revoked: false,
      suspended: false,
      created_by: user_id,
      athanor_id: athanor_id,
      inserted_at: now(),
      updated_at: now()
    })
  end

  defp profile!(athanor_id) do
    insert!(Arca.Schemas.Profile, %{
      id: Prima.UUID7.generate_id("prf"),
      athanor_id: athanor_id,
      source_ref: "local:acme/restored-#{uniq()}",
      kind: "owner",
      label: "default",
      status: "active",
      inserted_at: now(),
      updated_at: now()
    })
  end

  defp webhook!(athanor_id, user_id, profile_id) do
    insert!(Arca.Schemas.Webhook, %{
      id: Prima.UUID7.generate_id("whk"),
      name: "hook-#{uniq()}",
      slug: "hook-#{uniq()}",
      target_ref: "local:acme/tool",
      secret_encrypted: "sealed-webhook-secret",
      athanor_id: athanor_id,
      profile_id: profile_id,
      created_by: user_id,
      suspended: false,
      inserted_at: now(),
      updated_at: now()
    })
  end

  defp paired!(athanor_id, user_id) do
    insert!(Arca.Schemas.PairedClient, %{
      id: Prima.UUID7.generate_id("pcl"),
      athanor_id: athanor_id,
      user_id: user_id,
      source_kind: "session",
      source_id: "src_#{uniq()}",
      standing: "active",
      inserted_at: now(),
      updated_at: now()
    })
  end

  defp vault!(athanor_id) do
    insert!(Arca.Schemas.VaultEntry, %{
      id: Prima.UUID7.generate_id("vlt"),
      athanor_id: athanor_id,
      name: "restored-entry-#{uniq()}",
      kind: "api_key",
      destination: ~s({"hosts":["api.example.com"],"scheme":"https"}),
      status: "active",
      inserted_at: now(),
      updated_at: now()
    })
  end

  defp row!(schema, id), do: Arca.Repo.get!(schema, id)

  defp pending_records(user_id) do
    Arca.Repo.all(
      from(c in "pending_confirmations",
        where: c.user_id == ^user_id,
        select: %{ref: c.ref, operation: c.operation, action: c.action, state: c.state}
      )
    )
  end

  defp host!(conn, athanor, opts \\ []) do
    session = %{
      "athanor_id" => athanor.id,
      "test" => self(),
      "listen" => Keyword.get(opts, :listen, true)
    }

    {:ok, view, _html} = live_isolated(conn, Host, session: session)
    view
  end

  # A person whose home was restored from a backup with the marker: a
  # paired device, an API key and a webhook of theirs and a profile and a
  # vault entry of their own athanor, each standing before the restore;
  # then signed in again, since the restore ended every session.
  defp restored(%{conn: conn}) do
    user = test_user()
    _before = log_in_user(conn, user)
    athanor = seated_athanor()
    authenticator = Sanctum.TestContext.passkey!(user.user_id)
    profile_id = profile!(athanor.id)

    ids = %{
      client: paired!(athanor.id, user.user_id),
      key: key!(athanor.id, user.user_id),
      webhook: webhook!(athanor.id, user.user_id, profile_id),
      profile: profile_id,
      vault: vault!(athanor.id)
    }

    {:ok, _marked} = Arca.SecurityTransitions.mark_restore(Prima.Actor.system())
    {:ok, %{restore_id: _restore_id}} = Arca.SecurityTransitions.restore(slot: :none)

    conn = log_in_user(conn, user)

    %{
      conn: conn,
      view: host!(conn, athanor),
      user: user,
      athanor: athanor,
      authenticator: authenticator,
      ids: ids
    }
  end

  defp reenable!(view, operation, id) do
    view
    |> element(~s([data-test="restore-reenable"][data-operation="#{operation}"][data-id="#{id}"]))
    |> render_click()
  end

  describe "the restore checklist" do
    setup :restored

    test "lists what the restore suspended and asks for again, with nothing secret and no prompt",
         %{view: view, athanor: athanor, ids: ids} do
      assert has_element?(view, ~s([data-test="restore-checklist"]))
      assert render(view) =~ "This CYFR was restored from a backup"

      for {operation, id} <- [{"key.reenable", ids.key}, {"webhook.reenable", ids.webhook}] do
        assert has_element?(
                 view,
                 ~s([data-test="restore-reenable"][data-operation="#{operation}"][data-id="#{id}"])
               ),
               operation
      end

      # The device the restore suspended comes back by a fresh hello, not
      # from here.
      assert row!(Arca.Schemas.PairedClient, ids.client).standing == "suspended"
      refute has_element?(view, ~s([data-test="restore-checklist-item"][data-id="#{ids.client}"]))

      profile = row!(Arca.Schemas.Profile, ids.profile)

      assert has_element?(
               view,
               ~s([data-test="restore-checklist-profile"][data-id="#{ids.profile}"]),
               profile.source_ref
             )

      consent =
        PrismWeb.Focus.path(
          athanor,
          "/components?" <> URI.encode_query(%{"ref" => profile.source_ref, "setup" => "true"})
        )

      assert has_element?(view, ~s([data-test="restore-checklist-consent"][href="#{consent}"]))

      entry = row!(Arca.Schemas.VaultEntry, ids.vault)

      assert has_element?(
               view,
               ~s([data-test="restore-checklist-entry"][data-kind="vault"][data-id="#{ids.vault}"]),
               entry.name
             )

      # The checklist holds no secret: a webhook's sealed secret and a
      # key's hash never reach the page.
      html = render(view)
      key = row!(Arca.Schemas.ApiKey, ids.key)
      refute html =~ "sealed-webhook-secret"
      refute html =~ Base.encode16(key.key_hash, case: :lower)
      assert open_prompt(view) == nil
      Cyfr.Test.Sandbox.end_views()
    end

    test "a re-enable the checklist does not offer here dispatches nothing",
         %{view: view, user: user, ids: ids} do
      for {operation, id} <- [
            {"key.reenable", "key_not_listed"},
            {"vault.delete", ids.vault},
            {"pairing.reenable", ids.client},
            {"webhook.reenable", ids.key}
          ] do
        view
        |> layer()
        |> render_hook("restore_reenable", %{"operation" => operation, "id" => id})
      end

      assert open_prompt(view) == nil
      assert pending_records(user.user_id) == []
      refute has_element?(view, ~s([data-test="restore-checklist-error"]))
      Cyfr.Test.Sandbox.end_views()
    end

    test "is drawn by the page's own layer alone: a layer that does not listen draws none",
         %{conn: conn, athanor: athanor} do
      quiet = host!(conn, athanor, listen: false)
      refute has_element?(quiet, ~s([data-test="restore-checklist"]))
      Cyfr.Test.Sandbox.end_views()
    end

    test "a re-enable raises its record's prompt, which a passkey of the account confirms",
         %{view: view, user: user, ids: ids, authenticator: authenticator} do
      reenable!(view, "key.reenable", ids.key)

      assert [%{ref: ref, operation: "key.reenable", action: "restore_reenable"}] =
               pending_records(user.user_id)

      assert open_prompt(view) == Prompt.confirmation_id(ref)

      assert has_element?(
               view,
               ~s([data-test="confirmation"][data-ref="#{ref}"][data-own="true"])
             )

      # The secret is the layer's own, never drawn.
      refute render(view) =~ held_secret(view)

      prove_here!(view, ref, authenticator)

      wait_until(
        fn ->
          not has_element?(view, ~s([data-test="restore-checklist-item"][data-id="#{ids.key}"]))
        end,
        2_000,
        "the key's re-enable"
      )

      assert open_prompt(view) == nil

      assert has_element?(
               view,
               ~s([data-test="restore-checklist-notice"]),
               "API key is re-enabled"
             )

      refute row!(Arca.Schemas.ApiKey, ids.key).suspended

      # The webhook stays suspended until it is re-enabled itself.
      assert has_element?(view, ~s([data-test="restore-reenable"][data-id="#{ids.webhook}"]))
      assert row!(Arca.Schemas.Webhook, ids.webhook).suspended
      refute_received {:host, {:system_layer, _id, _outcome}}
      Cyfr.Test.Sandbox.end_views()
    end

    test "a dismissed re-enable cancels its record and changes nothing",
         %{view: view, user: user, ids: ids} do
      reenable!(view, "webhook.reenable", ids.webhook)
      assert [%{operation: "webhook.reenable"}] = pending_records(user.user_id)
      view |> element(~s([data-test="prompt-dismiss"])) |> render_click()
      assert open_prompt(view) == nil
      assert [%{state: "cancelled"}] = pending_records(user.user_id)
      assert row!(Arca.Schemas.Webhook, ids.webhook).suspended
      refute_received {:host, {:system_layer, _id, _outcome}}
      Cyfr.Test.Sandbox.end_views()
    end
  end

  describe "a person with nothing a restore suspended" do
    test "sees no restore checklist, even with a profile that asks for consent again",
         %{conn: conn} do
      user = test_user()
      conn = log_in_user(conn, user)
      athanor = seated_athanor()
      profile_id = profile!(athanor.id)

      {1, _} =
        Arca.Repo.update_all(from(p in Arca.Schemas.Profile, where: p.id == ^profile_id),
          set: [status: "needs_consent"]
        )

      view = host!(conn, athanor)
      ctx = :sys.get_state(view.pid).socket.assigns.context
      assert {:ok, nil} = Sanctum.Pairing.restore_checklist(ctx)
      refute has_element?(view, ~s([data-test="restore-checklist"]))
      Cyfr.Test.Sandbox.end_views()
    end
  end
end
