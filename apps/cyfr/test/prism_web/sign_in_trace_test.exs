# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.SignInTraceTest do
  @moduledoc """
  One trace, end to end: the door admits, the mint is synchronous, the real
  shipped bundle fills in the BACKGROUND with no registry reachable, and the
  console mounts on the estate that fill left.

  Every part of this has had a test of its own and the composition has not,
  which is what §9.1 scores as Phase 1's missing evidence. The parts pass
  while the whole is untested because each one stubs the next: every console
  test reaches for `Sanctum.TestContext.shipped!/1` and
  `Athanors.mark_provisioned/1`, so nothing has ever mounted a page onto an
  estate an actual fill produced.

  Two deliberate departures from the other tests here:

    * `provisioning_inline` goes back to `false`. The suite forces fills
      inline for determinism, but "mints synchronously and fills in the
      background" is the claim under test, and inline proves only half of it.
    * No `shipped!/1`, no `mark_provisioned/1`, no `log_in_user/3`. The
      session is built from the athanor the mint returned, so the page can
      only mount if the fill really happened.
  """
  use PrismWeb.ConnCase, async: false

  import Cyfr.Test.Wait

  @moduletag timeout: 240_000

  alias Sanctum.{Door, SignIn}
  alias Sanctum.Tenancy.Athanors

  @repo_root Path.expand("../../../..", __DIR__)
  @providers ~w(claude openai gemini grok openrouter)

  setup do
    test_dir = Path.join(System.tmp_dir!(), "cyfr_trace_#{System.unique_integer([:positive])}")
    seed_dir = Path.join(test_dir, "seed")
    File.mkdir_p!(seed_dir)
    File.cp_r!(Path.join(@repo_root, "seed/components"), Path.join(seed_dir, "components"))
    File.cp_r!(Path.join(@repo_root, "seed/aqua"), Path.join(seed_dir, "aqua"))

    keys = [:base_path, :seed_path, :registry_url, :oci_registry_url, :provisioning_inline]
    prev = Map.new(keys, &{&1, Application.get_env(:cyfr, &1)})

    Application.put_env(:cyfr, :base_path, test_dir)
    Application.put_env(:cyfr, :seed_path, seed_dir)
    # Both endpoints, because they are separate settings and a pull dials
    # the OCI one.
    Application.put_env(:cyfr, :registry_url, "none")
    Application.put_env(:cyfr, :oci_registry_url, "none")
    Application.put_env(:cyfr, :provisioning_inline, false)

    on_exit(fn ->
      for {key, value} <- prev do
        if is_nil(value),
          do: Application.delete_env(:cyfr, key),
          else: Application.put_env(:cyfr, key, value)
      end

      File.rm_rf!(test_dir)
    end)

    # Fills run in the background here, and `after_sign_in/1` starts one this
    # test never waits for. A fill still running when the paths are restored
    # provisions against the repository's own seed and data trees, where a
    # failed registration's rollback deletes the unit it was writing.
    Cyfr.Test.Sandbox.stop_work_on_exit()

    :ok
  end

  test "the door admits, the estate is minted, the bundle fills behind it, and the console mounts",
       %{conn: conn} do
    n = System.unique_integer([:positive])
    {:ok, _} = Door.Store.allow("wildcard", "*", "ops")

    info = %{
      id: "github|https://github.com|trace-#{n}",
      provider: "github",
      email: "trace#{n}@example.com",
      verified: true,
      name: "Trace #{n}"
    }

    assert {:ok, :allowed} = Door.admit(info.id, info.email, true)

    # The mint is the synchronous half: a person is never admitted without
    # an estate to work in.
    assert {:ok, user} = SignIn.admitted(info, :allowed)
    athanor_id = user.personal_athanor_id
    assert is_binary(athanor_id)
    assert {:ok, %{kind: "person"}} = Athanors.get(athanor_id)

    # The fill is the other half, and nothing in this test performs it.
    wait_until(
      fn ->
        case Athanors.get(athanor_id) do
          {:ok, %{provisioned_at: %DateTime{}}} ->
            true

          {:ok, row} ->
            case Map.get(Athanors.settings(row), "provisioning_error") do
              nil -> false
              err -> flunk("the fill recorded an error instead of finishing: #{inspect(err)}")
            end

          other ->
            flunk("the athanor vanished: #{inspect(other)}")
        end
      end,
      45_000
    )

    {:ok, filled} = Athanors.get(athanor_id)

    refute Map.has_key?(Athanors.settings(filled), "provisioning_error"),
           "the fill recorded an error: #{inspect(Athanors.settings(filled))}"

    ctx =
      Sanctum.Context.build(
        user_id: user.id,
        email: info.email,
        provider: "github",
        athanor_id: athanor_id,
        permissions: Sanctum.Atoms.person_permissions(),
        scope: :athanor,
        auth_method: :oidc,
        authenticated: true
      )

    # What the fill actually laid down: the shipped bundle, from the seed
    # alone, with no registry configured at all.
    for name <- @providers do
      assert {:ok, %{publisher: "local"}} =
               Compendium.Registry.get_latest(ctx, name, "local", "catalyst"),
             "catalyst:local.#{name} is not registered after the fill"
    end

    assert {:ok, [_profile]} = Sanctum.Consent.Source.DB.profiles(ctx, "agent:local.aqua")

    # And the console mounts on it — the session built from the minted
    # athanor, never from a stubbed one.
    {:ok, session} = Sanctum.Session.create(ctx)
    Process.put(:prism_test_athanor_id, athanor_id)

    conn = Plug.Test.init_test_session(conn, %{PrismWeb.ConnCase.session_key() => session.token})

    # `/` lands the person in their own estate, which is the estate the mint
    # made and the fill filled — the redirect naming it is itself the claim.
    assert {:error, {:live_redirect, %{to: landing}}} = live(conn, "/")
    assert landing =~ "/chat"

    assert {:ok, _view, html} = live(conn, landing)

    # Not the preparing state: this estate was filled before the page opened.
    refute html =~ "Preparing"
  end
end
