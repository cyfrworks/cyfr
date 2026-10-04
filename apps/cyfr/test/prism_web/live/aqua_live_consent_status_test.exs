# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.AquaLiveConsentStatusTest do
  @moduledoc """
  What the AQUA page says about consent: a row and a re-consent button per
  source whose consent no longer answers, nothing when none drifted, and
  — when the status could not be read — one line that says so and offers
  nothing to press. An outage never reads as "all consents current".
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias PrismWeb.AquaLive

  test "an unreadable status is one line, with no re-consent button" do
    for refused <- [:unavailable, :corrupt, :forbidden] do
      html = render_component(&AquaLive.consent_status/1, stale_consents: {:error, refused})

      assert html =~ "Consent status unavailable"
      assert [_one] = Regex.scan(~r/role="status"/, html)
      refute html =~ "Re-consent"
      refute html =~ "open_consent"
    end
  end

  test "each stale or drifted source is a row with its own re-consent button" do
    html =
      render_component(&AquaLive.consent_status/1,
        stale_consents:
          {:ok,
           [
             {"formula:local.uses-remote", :stale},
             {"agent:local.aqua", {:drifted, ["notes.keep"]}}
           ]}
      )

    assert html =~ ~s(id="aqua-consent-drift-formula:local.uses-remote")
    assert html =~ ~s(id="aqua-consent-drift-agent:local.aqua")
    assert html =~ "uses-remote cannot run until a member consents again"
    assert html =~ "notes.keep"
    assert [_, _] = Regex.scan(~r/Re-consent/, html)
    refute html =~ "Consent status unavailable"
  end

  test "nothing stale renders nothing" do
    html = render_component(&AquaLive.consent_status/1, stale_consents: {:ok, []})

    refute html =~ "Re-consent"
    refute html =~ "Consent status unavailable"
  end
end

defmodule PrismWeb.AquaLiveConsentStatusTest.GrantTest do
  @moduledoc """
  The consent the AQUA page asks for (`open_consent`, which its
  re-consent rows and its "Connect a model" both send) opens on the plan's
  suggestion: the model's one key is bound before the person does
  anything, and that is what the grant commits.
  """

  use PrismWeb.ConnCase, async: false

  # Minimal valid WASM with a `run` export.
  @wasm <<0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00>> <>
          <<0x01, 0x04, 0x01, 0x60, 0x00, 0x00>> <>
          <<0x03, 0x02, 0x01, 0x00>> <>
          <<0x07, 0x07, 0x01, 0x03, "run", 0x00, 0x00>> <>
          <<0x0A, 0x04, 0x01, 0x02, 0x00, 0x0B>>

  setup %{conn: conn} do
    test_path = Path.join(System.tmp_dir!(), "aqua_consent_#{:rand.uniform(1_000_000)}")
    original = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, test_path)

    on_exit(fn ->
      File.rm_rf(test_path)

      if original,
        do: Application.put_env(:arca, :base_path, original),
        else: Application.delete_env(:arca, :base_path)
    end)

    user = test_user()
    conn = log_in_user(conn, user)
    athanor = seated_athanor()
    ctx = %{Sanctum.TestContext.local() | user_id: user.user_id, athanor_id: athanor.id}
    {:ok, conn: conn, ctx: ctx}
  end

  # Point the soul at `ref`, and put it back afterwards.
  defp soul_names_catalyst!(ctx, ref) do
    {:ok, soul} = Aqua.AgentConfig.agent(ctx, "aqua")
    was = soul["catalyst_ref"] || ""

    {:ok, _} =
      Aqua.AgentConfig.call_aqua(ctx, %{
        "action" => "update",
        "name" => "aqua",
        "catalyst_ref" => ref
      })

    on_exit(fn ->
      Aqua.AgentConfig.call_aqua(ctx, %{
        "action" => "update",
        "name" => "aqua",
        "catalyst_ref" => was
      })
    end)

    :ok
  end

  test "the page's consent opens with the model's key bound, and grants it",
       %{conn: conn, ctx: ctx} do
    ref = "catalyst:local.status-keyed"
    :ok = soul_names_catalyst!(ctx, ref)

    {:ok, _} =
      Compendium.Registry.publish_bytes(ctx, @wasm, %{
        name: "status-keyed",
        version: "0.1.0",
        type: "catalyst",
        description: "A model catalyst",
        manifest:
          Jason.encode!(%{
            "needs" => %{
              "api_key" => %{
                "type" => "api_key:status.test",
                "reason" => "to call the model with your key",
                "fields" => ["STATUS_API_KEY"],
                "required" => true
              }
            }
          })
      })

    # The model reads its key itself, so the entry is disclosed.
    {:ok, entry} =
      Sanctum.TestContext.create_vault(ctx, %{
        name: "status key",
        kind: "api_key",
        provider_hint: "status.test",
        fields: %{"STATUS_API_KEY" => "sk-status"},
        destination: %{"hosts" => ["api.status.example"]},
        disclose: true
      })

    {view, _html} = mount_athanor(conn, "/aqua")

    view
    |> element("button[phx-click=open_consent]", "Connect a model")
    |> render_click()

    # Nothing picked: the plan's suggestion is already the binding.
    assert has_element?(
             view,
             ~s(#system-layer-dialog [data-test="grant-pick"][aria-pressed="true"]),
             entry.name
           )

    view |> element(~s(#system-layer-dialog button[phx-click="confirm"])) |> render_click()
    Prima.Test.Wait.wait_until(fn -> render(view) =~ "Model connected." end, 5_000, "the grant")

    {:ok, [%{id: profile_id} | _]} = Sanctum.Consent.profiles(ctx, ref)
    {:ok, head} = Sanctum.Consent.head_consent(ctx, profile_id)
    assert Enum.any?(head.vault_refs, &(&1.vault_entry_id == entry.id))
  end
end
