# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.AdmissionCapacityTest do
  @moduledoc """
  What a full server does at the door.

  `CYFR_MINT_PER_HOUR` bounds how fast strangers arrive and
  `CYFR_MAX_ATHANORS` how many estates the server holds. Nothing is shared
  server-wide for a person to land in, so a sign-in whose athanor cannot be
  minted is refused rather than admitted to a session with nowhere to work.
  An operator is not a stranger and is minted past both.
  """
  use ExUnit.Case, async: false

  alias Sanctum.SignIn
  alias Sanctum.Tenancy.{Athanors, Members, Users}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    previous = Application.get_env(:cyfr, :caps, [])
    on_exit(fn -> Application.put_env(:cyfr, :caps, previous) end)

    :ok
  end

  defp info(n) do
    %{
      id: "github|https://github.com|cap-#{n}",
      provider: "github",
      email: "cap#{n}@example.com",
      verified: true,
      name: "Cap #{n}"
    }
  end

  defp at_capacity!, do: Application.put_env(:cyfr, :caps, max_athanors: 1)

  test "a stranger the caps refuse is turned away, with no athanor and no session" do
    n = System.unique_integer([:positive])
    at_capacity!()

    assert {:error, {:limit_reached, :max_athanors, 1}} = SignIn.admitted(info(n), :allowed)

    # Nothing half-made. The person's row is written before the mint is
    # attempted, so the estate is what to look for — under their minted id,
    # never the IdP identity they arrived with.
    {:ok, user} = Users.get_by_identity("github|https://github.com|cap-#{n}")
    assert {:error, :not_found} = Athanors.get_by_owner(user.id)
  end

  test "an operator is minted past the caps" do
    n = System.unique_integer([:positive])
    email = "cap#{n}@example.com"
    previous = Application.get_env(:cyfr, :platform_admin_emails, [])
    Application.put_env(:cyfr, :platform_admin_emails, [email])
    on_exit(fn -> Application.put_env(:cyfr, :platform_admin_emails, previous) end)

    at_capacity!()

    assert {:ok, user} = SignIn.admitted(info(n), :admin)
    assert {:ok, own} = Athanors.get_by_owner(user.id)
    assert own.kind == "person"
    assert Members.member?(user.id, own.id)
  end
end
