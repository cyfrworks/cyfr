# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ShellSetupGrantTest do
  @moduledoc """
  The desktop a person first reaches after the sign-in that follows their
  admission: the sign-in ran the fill's local half, so the shipped canvas
  holds its baseline consent and opens with no grant asked, however the
  registry half went.
  """

  use PrismWeb.ConnCase, async: false

  import Prima.Test.Wait

  alias Prism.Frames
  alias Sanctum.Tenancy.Athanors

  @seed Path.expand("../../../../../seed", __DIR__)

  setup do
    dir = Path.join(System.tmp_dir!(), "shell_setup_grant_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)

    seed = Path.join(dir, "seed")
    canvas = Path.join([seed, "components", "tinctures", "local", "canvas"])
    File.mkdir_p!(Path.dirname(canvas))
    File.cp_r!(Path.join([@seed, "components", "tinctures", "local", "canvas"]), canvas)
    File.cp_r!(Path.join(@seed, "aqua"), Path.join(seed, "aqua"))

    # A shipped catalyst whose required dependency only a registry serves,
    # and a registry nothing answers at: the registry half fails at its
    # closure step.
    foo = Path.join([seed, "components", "catalysts", "local", "foo", "1.0.0"])
    File.mkdir_p!(foo)
    File.write!(Path.join(foo, "catalyst.wasm"), Cyfr.Test.Guests.wasm(:catalyst))

    File.write!(
      Path.join(foo, "cyfr-manifest.json"),
      Jason.encode!(%{
        "name" => "foo",
        "version" => "1.0.0",
        "type" => "catalyst",
        "caps" => %{"egress" => %{"domains" => []}},
        "dependencies" => %{"static" => ["catalyst:someone.elsewhere"]}
      })
    )

    Prima.Test.Env.put_app_env(:arca, :base_path, Path.join(dir, "base"))
    Prima.Test.Env.put_app_env(:arca, :seed_path, seed)
    Prima.Test.Env.put_app_env(:cyfr, :registry_url, "127.0.0.1:19")
    :ok
  end

  test "a sign-in whose registry half failed lands on the shipped canvas with its grant, and no grant is asked",
       %{conn: conn} do
    # Admitted with an athanor of their own, not yet filled.
    user = test_user()
    athanor = Sanctum.Test.People.athanor!(user.user_id)
    assert athanor.provisioned_at == nil

    # The sign-in that follows an admission.
    :ok = Sanctum.Provisioning.after_sign_in(user.user_id)

    # The registry half failed where it pulls, and the athanor is not filled.
    {:ok, row} = Athanors.get(athanor.id)
    assert row.provisioned_at == nil
    assert %{step: "closure"} = Athanors.provisioning_failure(row)

    # The shipped canvas's grant stands: the newest version the seed ships
    # opens under it.
    version = Cyfr.Test.SeedBundle.local_unit!("tinctures", "canvas").version
    ctx = Sanctum.Provisioning.person_ctx(user.user_id, athanor.id)

    assert {:ok, %{profile: %{id: profile_id, kind: :owner}, revision: 1}} =
             Sanctum.Consent.TinctureGrant.fetch(ctx, "tincture:local.canvas:#{version}")

    # Minted by the fill, attributed to the person whose sign-in caused it.
    assert {:ok, %{granted_via: "bootstrap", granted_by: granted_by}, _refs} =
             Arca.ConsentStorage.get_head(Sanctum.Context.actor(ctx), profile_id)

    assert granted_by == user.user_id

    conn = log_in_user(conn, user, athanor_id: athanor.id)
    {view, _html} = mount_desktop(conn)

    # The shipped canvas is decided, trialled first as a new version is,
    # and nothing asks for a grant.
    wait_until(
      fn ->
        render(view)

        case shell_frames(view) do
          [%{reference: %{name: "canvas", version: ^version}, state: :live} | _] -> true
          _deciding -> false
        end
      end,
      5_000,
      "the shipped canvas to open"
    )

    assert :sys.get_state(view.pid).socket.assigns.grant_prompts == %{}
    refute render(view) =~ ~s(data-kind="grant")
    refute Enum.any?(shell_frames(view), &(&1.state == :refused))
  end

  defp shell_frames(view), do: Frames.list(:sys.get_state(view.pid).socket.assigns.frames)
end
