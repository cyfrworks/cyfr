# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.AdmissionCapacityTest do
  @moduledoc """
  What a full server does at the door.

  `CYFR_MINT_PER_HOUR`, a rate bound, limits how fast strangers arrive and
  `CYFR_MAX_ATHANORS`, a cap, how many athanors the server holds. Nothing is
  shared server-wide for a person to land in, so a sign-in whose athanor
  cannot be minted is refused rather than admitted to a session with
  nowhere to work. An operator is not a stranger and is minted past both.

  The rate bound is off only while unset. It fails closed: a stored value
  outside the roster's range (0 included), a store that cannot answer, a
  stale value and a count that cannot be taken each refuse the mint.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Sanctum.{Provisioning, SignIn}
  alias Sanctum.Test.Settings
  alias Sanctum.Tenancy.{Athanors, Members, Users}

  setup tags do
    Arca.Test.Sandbox.setup!(tags)

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

  defp at_capacity!, do: Settings.put("max_athanors", 1)

  defp mint_rate!(value), do: Settings.put("mint_per_hour", value)

  # A person with a row and a namespace and no athanor yet: the next
  # `Provisioning.ensure_personal_athanor/1` mints one.
  defp stranger!(n) do
    {:ok, user} =
      Users.upsert_from_provider(%{
        id: "github|https://github.com|mint-#{n}",
        provider: "github",
        email: "mint#{n}@example.com",
        verified: true
      })

    {:ok, user} = Users.set_namespace(user, "mint#{n}")
    user
  end

  # The person's own lookup reads the athanors table before the mint rate
  # counts it, so the table is renamed between the two: once the calling
  # process's first query of it has answered. The rename lives in the
  # test's sandbox transaction, which rolls it back; on PostgreSQL the
  # count's failure ends that transaction, so this is the test's last
  # database step.
  defp break_count_after_lookup! do
    owner = self()
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:arca, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if self() == owner and metadata[:source] == "athanors" and
               Process.put(handler, :renamed) == nil do
            Arca.Repo.query!("ALTER TABLE athanors RENAME TO athanors_away")
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  test "a stranger the caps refuse is turned away, with no athanor and no session" do
    n = System.unique_integer([:positive])
    at_capacity!()

    assert {:error, {:limit_reached, :max_athanors, 1}} = SignIn.admitted(info(n), :allowed)

    # Nothing half-made. The person's row is written before the mint is
    # attempted, so the athanor is what to look for — under their minted id,
    # never the IdP identity they arrived with.
    {:ok, user} = Users.get_by_identity("github|https://github.com|cap-#{n}")
    assert {:error, :not_found} = Athanors.get_by_owner(user.id)
  end

  test "an operator is minted past the caps" do
    n = System.unique_integer([:positive])
    email = "cap#{n}@example.com"
    previous = Application.get_env(:sanctum, :platform_admin_emails, [])
    Application.put_env(:sanctum, :platform_admin_emails, [email])
    on_exit(fn -> Application.put_env(:sanctum, :platform_admin_emails, previous) end)

    at_capacity!()

    assert {:ok, user} = SignIn.admitted(info(n), :admin)
    assert {:ok, own} = Athanors.get_by_owner(user.id)
    assert own.kind == "person"
    assert Members.member?(user.id, own.id)
  end

  describe "the mint rate" do
    test "unset is no bound; a bound refuses the mint past it, and groups do not draw on it" do
      n = System.unique_integer([:positive])
      assert {:ok, nil} = Arca.PlatformSettings.effective("mint_per_hour")
      first = stranger!(n)
      assert {:ok, _} = Provisioning.ensure_personal_athanor(first)

      # One was minted this hour already (above).
      mint_rate!(1)
      second = stranger!(n + 1)

      assert {:error, {:limit_reached, :mint_per_hour, 1}} =
               Provisioning.ensure_personal_athanor(second)

      # At the door, the refusal the sign-in pages name.
      assert {:error, {:limit_reached, :mint_per_hour, 1}} = SignIn.admitted(info(n), :allowed)

      # Groups people create do not draw on the mint budget: the bound
      # measures person athanors, so a member's `athanor.create` cannot
      # starve sign-ins.
      mint_rate!(2)
      {:ok, _} = Athanors.create_group(first.id, "Not a mint")
      assert {:ok, _} = Provisioning.ensure_personal_athanor(second)
    end

    test "a stored value outside the roster's range refuses, never reads as no bound" do
      n = System.unique_integer([:positive])

      for {value, i} <- Enum.with_index([0, -1, 1_000_001, "10"]) do
        mint_rate!(value)
        user = stranger!(n + i)

        log =
          capture_log(fn ->
            assert {:error, {:cap_unverifiable, :mint_per_hour}} =
                     Provisioning.ensure_personal_athanor(user)
          end)

        assert log =~ "mint_per_hour holds #{inspect(value)}"
        assert {:error, :not_found} = Athanors.get_by_owner(user.id)
      end

      # The door reads it as the unavailable class, not a limit the
      # account reached.
      assert %Prima.Refusal{class: :unavailable} =
               Prima.Refusal.classify({:cap_unverifiable, :mint_per_hour})
    end

    # The fail-closed counterpart of a server at capacity still admitting
    # its operator: the operator's mint bypasses the rate check whole, so
    # an invalid stored bound that refuses every stranger never locks out
    # the person who can correct it.
    test "an invalid stored bound refuses a stranger but still mints the operator's own" do
      n = System.unique_integer([:positive])
      email = "cap#{n}@example.com"
      previous = Application.get_env(:sanctum, :platform_admin_emails, [])
      Application.put_env(:sanctum, :platform_admin_emails, [email])
      on_exit(fn -> Application.put_env(:sanctum, :platform_admin_emails, previous) end)

      mint_rate!(0)
      stranger = stranger!(n + 1)

      capture_log(fn ->
        assert {:error, {:cap_unverifiable, :mint_per_hour}} =
                 Provisioning.ensure_personal_athanor(stranger)
      end)

      assert {:ok, user} = SignIn.admitted(info(n), :admin)
      assert {:ok, own} = Athanors.get_by_owner(user.id)
      assert own.kind == "person"
      assert Members.member?(user.id, own.id)
    end

    test "a bound the store cannot answer refuses" do
      mint_rate!(5)
      user = stranger!(System.unique_integer([:positive]))
      Settings.break_store!()

      log =
        capture_log(fn ->
          assert {:error, {:cap_unverifiable, :mint_per_hour}} =
                   Provisioning.ensure_personal_athanor(user)
        end)

      assert log =~ "mint_per_hour could not be read"
    end

    test "a stale bound is refused, not served" do
      mint_rate!(5)
      user = stranger!(System.unique_integer([:positive]))
      Settings.expire("mint_per_hour")
      Settings.break_store!()

      log =
        capture_log(fn ->
          assert {:error, {:cap_unverifiable, :mint_per_hour}} =
                   Provisioning.ensure_personal_athanor(user)
        end)

      assert log =~ "mint_per_hour could not be read"
    end

    test "a count that cannot be taken refuses the mint" do
      mint_rate!(5)
      user = stranger!(System.unique_integer([:positive]))
      # Read once, so the mint's own read is answered from the cache.
      assert {:ok, 5} = Arca.PlatformSettings.effective("mint_per_hour")
      break_count_after_lookup!()

      log =
        capture_log(fn ->
          assert {:error, {:cap_unverifiable, :mint_per_hour}} =
                   Provisioning.ensure_personal_athanor(user)
        end)

      assert log =~ "mint_per_hour count failed"
    end
  end
end
