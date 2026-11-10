# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.SignInTraceTest do
  @moduledoc """
  Sign-in on the product path, end to end. A person this CYFR holds, with
  their account and its passkey at the directory, opens the sign-in page;
  the page sends the browser to the account pages with a request bound to
  it; the account pages' answer comes back to `/login`; the door admits
  the person; the real shipped bundle fills their athanor in the
  background with no registry reachable; a one-time ticket bound to this
  browser sets the session's cookie; and the console mounts on the
  athanor that fill left, its context established from that cookie.

  Fills run in the background here (`provisioning_inline: false`), and no
  athanor is stubbed: the page can mount only because the fill happened.
  """
  use PrismWeb.ConnCase, async: false

  import Prima.Test.Wait

  @moduletag timeout: 240_000

  alias Cyfr.Test.SeedBundle
  alias Sanctum.Tenancy.Athanors
  alias Sanctum.Test.DirectoryServer

  @repo_root Path.expand("../../../..", __DIR__)

  setup do
    test_dir = Path.join(System.tmp_dir!(), "cyfr_trace_#{System.unique_integer([:positive])}")
    seed_dir = Path.join(test_dir, "seed")
    on_exit(fn -> File.rm_rf!(test_dir) end)
    File.mkdir_p!(seed_dir)
    File.cp_r!(Path.join(@repo_root, "seed/components"), Path.join(seed_dir, "components"))
    File.cp_r!(Path.join(@repo_root, "seed/aqua"), Path.join(seed_dir, "aqua"))

    # The storage roots are the persistence layer's; the registry endpoints
    # (both, because a pull dials the OCI one) are the host's; the
    # directory and the inline provisioning are the identity domain's.
    Prima.Test.Env.put_app_env(:arca, :base_path, test_dir)
    Prima.Test.Env.put_app_env(:arca, :seed_path, seed_dir)
    Prima.Test.Env.put_app_env(:cyfr, :registry_url, "none")
    Prima.Test.Env.put_app_env(:cyfr, :oci_registry_url, "none")
    Prima.Test.Env.put_app_env(:sanctum, :provisioning_inline, false)

    tls = DirectoryServer.tls()
    DirectoryServer.listen!()
    DirectoryServer.seam!(tls)
    dir = DirectoryServer.start!(tls)
    Prima.Test.Env.put_app_env(:sanctum, :directory_url, dir.url)

    # The sign-in budgets are node-wide counters another test may have spent.
    Prima.Test.RateLimiter.reset!()

    # A fill still running when the paths are restored would provision
    # against the repository's own seed and data trees.
    Cyfr.Test.Sandbox.stop_work_on_exit()

    {:ok, _} = Sanctum.Door.Store.allow("wildcard", "*", "ops")
    %{dir: dir}
  end

  test "the sign-in page, the account pages' answer, the ticket, the cookie, the filled athanor",
       %{conn: conn, dir: dir} do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Sanctum.Test.People.linked(%{id: "trace|https://idp.test|#{n}", provider: "trace"})

    account = dir.dir |> DirectoryServer.account!(dir.url)
    account = DirectoryServer.add_passkey!(dir.dir, account)
    :ok = DirectoryServer.account_person!(user.id, account)

    # The browser's first visit gives it the session the request and the
    # ticket are bound to.
    page = get(conn, "/login")
    {:ok, login, _html} = live(page)
    login |> element(~s([data-test="sign-in"])) |> render_click()
    assert_push_event(login, "account:hop", %{url: url})

    # The account pages sign the request with the account's passkey and
    # send the browser back to `/login` with the answer in the fragment.
    [_page, fragment] = String.split(url, "#", parts: 2)
    {:ok, map} = Prima.SignIn.parse_fragment(fragment)
    {:ok, request} = Prima.SignIn.decode(map)

    answer =
      request
      |> DirectoryServer.passkey_answer(account, hd(account.passkeys))
      |> Prima.SignIn.fragment()

    render_hook(login, "account_answer", %{"answer" => answer})
    {ticket_path, _flash} = assert_redirect(login)
    assert ticket_path =~ "/auth/passkey/complete/"

    signed_in = page |> recycle() |> get(ticket_path)
    assert redirected_to(signed_in) == "/"
    assert get_session(signed_in, :sanctum_session_token)

    assert_console_on_filled_athanor(signed_in, user.id)

    Cyfr.Test.Sandbox.end_views()
  end

  # The fill the person's athanor received with nothing here performing
  # it, and the console mounted from the cookie.
  defp assert_console_on_filled_athanor(signed_in, user_id) do
    assert {:ok, %{id: athanor_id}} = Athanors.get_by_owner(user_id)

    wait_until(
      fn ->
        case Athanors.get(athanor_id) do
          {:ok, %{provisioned_at: %DateTime{}}} ->
            true

          {:ok, row} ->
            case Athanors.provisioning_failure(row) do
              nil -> false
              failure -> flunk("the fill recorded a failure: #{inspect(failure)}")
            end

          other ->
            flunk("the athanor vanished: #{inspect(other)}")
        end
      end,
      45_000
    )

    # What the fill laid down: the shipped bundle, from the seed alone.
    reader = Sanctum.Context.internal(athanor_id: athanor_id, scope: :athanor)

    for unit <- SeedBundle.model_chat_units() do
      assert {:ok, %{publisher: "local"}} =
               Compendium.Registry.get_latest(reader, unit.name, "local", "catalyst"),
             "#{unit.ref} is not registered after the fill"
    end

    assert {:ok, [_profile]} =
             Arca.ConsentStorage.profiles(Sanctum.Context.actor(reader), "agent:local.aqua")

    # `/` lands the person on their own desktop, which is not the
    # preparing state.
    Process.put(:prism_test_athanor_id, athanor_id)
    console = recycle(signed_in)

    assert {:ok, view, html} = live(console, "/")
    assert view.module == PrismWeb.DesktopLive
    refute html =~ "Preparing"
  end
end
