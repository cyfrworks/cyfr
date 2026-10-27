# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.AdmissionCapacityTest do
  @moduledoc """
  What a full server does to an open admission.

  `CYFR_MINT_PER_HOUR`, a rate bound, limits how fast people arrive and
  `CYFR_MAX_ATHANORS`, a cap, how many athanors the server holds. A person
  is made with their athanor in one transaction (`Sanctum.Newcomer`), so
  an admission whose athanor cannot be minted makes no one. The
  installation's administrator, made by setup, is minted past both.

  The rate bound is off only while unset. It fails closed: a stored value
  outside the roster's range (0 included), a store that cannot answer, a
  stale value and a count that cannot be taken each refuse the admission.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Arca.Schemas.User
  alias Sanctum.Newcomer
  alias Sanctum.Tenancy.{Athanors, Members}
  alias Sanctum.Test.Settings
  alias Sanctum.TestContext.Authenticator

  @token String.duplicate("c4", 32)

  setup tags do
    Arca.Test.Sandbox.setup!(tags)

    previous = Application.fetch_env(:sanctum, :setup_token)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:sanctum, :setup_token, value)
        :error -> Application.delete_env(:sanctum, :setup_token)
      end
    end)

    Application.put_env(:sanctum, :setup_token, @token)
    Arca.Repo.delete_all(User)
    :ok
  end

  defp registration do
    {:ok, options} = Sanctum.Passkeys.newcomer_options()
    Authenticator.registration(Authenticator.new("cap|#{System.unique_integer()}"), options)
  end

  defp open, do: Newcomer.admit(:open, {:passkey, registration()})
  defp people, do: Arca.Repo.aggregate(User, :count)

  # The administrator, and the door open to anyone.
  defp set_up! do
    {:ok, %{person: admin}} = Newcomer.admit({:setup, @token}, {:command_line, "laptop"})
    {:ok, _} = Sanctum.Door.Store.allow("wildcard", "*", "ops")
    admin
  end

  defp mint_rate!(value), do: Settings.put("mint_per_hour", value)

  # The admission's first query of the athanors table is the mint rate's
  # count, after the person's keys are written; the table is renamed then.
  # The rename lives in the test's sandbox transaction, which rolls it
  # back; on PostgreSQL the count's failure ends that transaction, so this
  # is the test's last database step.
  defp break_count_after_keys! do
    owner = self()
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:arca, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if self() == owner and metadata[:source] == "person_identities" and
               Process.put(handler, :renamed) == nil do
            Arca.Repo.query!("ALTER TABLE athanors RENAME TO athanors_away")
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  test "an admission the athanor cap refuses makes no one" do
    _admin = set_up!()
    Settings.put("max_athanors", 1)

    assert {:error, {:limit_reached, :max_athanors, 1}} = open()
    assert people() == 1
  end

  test "the administrator is minted past the caps" do
    Settings.put("max_athanors", 1)
    mint_rate!(0)

    capture_log(fn ->
      assert {:ok, %{person: admin}} =
               Newcomer.admit({:setup, @token}, {:command_line, "laptop"})

      assert {:ok, own} = Athanors.get_by_owner(admin.id)
      assert own.kind == "person"
      assert Members.member?(admin.id, own.id)
    end)
  end

  describe "the mint rate" do
    test "unset is no bound; a bound refuses the admission past it, and groups do not draw on it" do
      admin = set_up!()
      assert {:ok, nil} = Arca.PlatformSettings.effective("mint_per_hour")
      assert {:ok, %{person: _first}} = open()

      # The bound at what this hour minted already, the administrator's
      # and the first newcomer's among them.
      {:ok, minted} = Athanors.count_created_since(DateTime.add(DateTime.utc_now(), -3600))
      mint_rate!(minted)
      assert {:error, {:limit_reached, :mint_per_hour, ^minted}} = open()
      assert people() == 2

      # Groups people create do not draw on the mint budget: the bound
      # measures person athanors, so a member's `athanor.create` cannot
      # starve admissions.
      {:ok, _} = Athanors.create_group(admin.id, "Not a mint")
      mint_rate!(minted + 1)
      assert {:ok, _} = open()
    end

    test "a stored value outside the roster's range refuses, never reads as no bound" do
      _admin = set_up!()

      for value <- [0, -1, 1_000_001, "10"] do
        mint_rate!(value)

        log =
          capture_log(fn ->
            assert {:error, {:cap_unverifiable, :mint_per_hour}} = open()
          end)

        assert log =~ "mint_per_hour holds #{inspect(value)}"
      end

      assert people() == 1

      # The refusal reads as the unavailable class, not a limit the
      # account reached.
      assert %Prima.Refusal{class: :unavailable} =
               Prima.Refusal.classify({:cap_unverifiable, :mint_per_hour})
    end

    test "a bound the store cannot answer refuses" do
      _admin = set_up!()
      mint_rate!(5)
      # The ceremony is drawn before the store breaks: its options read it.
      credential = registration()
      Settings.break_store!()

      log =
        capture_log(fn ->
          assert {:error, {:cap_unverifiable, :mint_per_hour}} =
                   Newcomer.admit(:open, {:passkey, credential})
        end)

      assert log =~ "mint_per_hour could not be read"
    end

    test "a stale bound is refused, not served" do
      _admin = set_up!()
      mint_rate!(5)
      credential = registration()
      Settings.expire("mint_per_hour")
      Settings.break_store!()

      log =
        capture_log(fn ->
          assert {:error, {:cap_unverifiable, :mint_per_hour}} =
                   Newcomer.admit(:open, {:passkey, credential})
        end)

      assert log =~ "mint_per_hour could not be read"
    end

    test "a count that cannot be taken refuses the admission" do
      _admin = set_up!()
      mint_rate!(5)
      # Read once, so the mint's own read is answered from the cache.
      assert {:ok, 5} = Arca.PlatformSettings.effective("mint_per_hour")
      break_count_after_keys!()

      log =
        capture_log(fn ->
          assert {:error, {:cap_unverifiable, :mint_per_hour}} = open()
        end)

      assert log =~ "mint_per_hour count failed"
    end
  end
end
