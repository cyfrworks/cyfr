# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.InstallationClaimsTest do
  @moduledoc """
  Who may mint the installation's first person: the installed mode, read
  inside every person mint, and the claim a restore makes of an empty
  node, only by opening its attempt. An uninstalled mode refuses;
  `:restore_reserved` refuses an ordinary first door on an empty node; a
  pending claim reserves the node whatever the mode; a restore's own mint
  is admitted only under its exact claim, on an empty node; a claim exists
  only with its attempt, ends with it, and spends its token for good.
  """

  # Installs the process-wide mode and takes the cell's slot; each case
  # restores both.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.{ControlPlane, IdentityAttempts, InstallationClaims, Users}
  alias Arca.Schemas.{CellLease, IdentityAttempt, InstallationClaim, ServerMeta, User}

  @slot_keys [
    {Arca.ControlPlane, :standing},
    {Arca.ControlPlane, :generation},
    {Arca.ControlPlane, :slot}
  ]

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    slot = hold_slot!()
    mode = if InstallationClaims.installed?(), do: InstallationClaims.mode()

    on_exit(fn ->
      if mode,
        do: InstallationClaims.install_mode!(mode),
        else: InstallationClaims.reset()
    end)

    # The node is empty inside this test's transaction, whatever another
    # suite committed: the guard's question is about this node's people.
    Arca.Repo.delete_all(User)
    InstallationClaims.install_mode!(:ordinary)
    {:ok, slot: slot}
  end

  # The writes under test are fenced by the member's slot: a claimant runs
  # and this member holds its slot. The process-wide standing and the claim
  # switch are restored after each case.
  defp hold_slot! do
    saved = Map.new(@slot_keys, &{&1, :persistent_term.get(&1, :absent)})
    claim = Application.get_env(:arca, :control_plane_claim_enabled)

    on_exit(fn ->
      for {key, value} <- saved do
        if value == :absent,
          do: :persistent_term.erase(key),
          else: :persistent_term.put(key, value)
      end

      if is_nil(claim),
        do: Application.delete_env(:arca, :control_plane_claim_enabled),
        else: Application.put_env(:arca, :control_plane_claim_enabled, claim)
    end)

    Application.put_env(:arca, :control_plane_claim_enabled, true)
    node = "node-#{System.unique_integer([:positive])}"
    {:ok, slot} = ControlPlane.take(node, node <> "#boot", 60_000)
    slot
  end

  defp server, do: Prima.Actor.system()

  defp digest(seed), do: Prima.Digest.sha256("#{seed}-#{System.unique_integer([:positive])}")

  defp identifier, do: "per_" <> Prima.Digest.sha256_hex("genesis-#{System.unique_integer()}")

  defp person_attrs do
    n = System.unique_integer([:positive])
    now = DateTime.utc_now()

    {%{
       id: Prima.UUID7.generate_id(Prima.PersonId.prefix()),
       provider: "github",
       email: "first#{n}@example.com",
       email_verified: true,
       first_seen_at: now,
       last_seen_at: now,
       created_at: now,
       updated_at: now
     },
     %{
       key: "github|https://github.com|first#{n}",
       provider: "github",
       issuer: "https://github.com",
       subject: "first#{n}",
       first_seen_at: now,
       last_seen_at: now
     }}
  end

  defp mint(opts \\ []) do
    {user, identity} = person_attrs()
    Users.mint(server(), user, identity, opts)
  end

  # A restore's submission under `token`: opening it claims the node.
  defp restore(token \\ digest("token")) do
    %{
      kind: "restore",
      request_id: "req_#{System.unique_integer([:positive])}",
      identifier: identifier(),
      directory_url: "https://dir.example",
      entry: "recover-request",
      request_digest: digest("recover"),
      expected_revision: 0,
      token_digest: token,
      staged_live_public_key: :crypto.strong_rand_bytes(32),
      staged_operational_public_key: :crypto.strong_rand_bytes(32),
      staged_live_key_sealed: "sealed-live",
      staged_operational_key_sealed: "sealed-op"
    }
  end

  defp open(attrs, opts \\ []), do: IdentityAttempts.open(server(), attrs, opts)

  defp ref(attrs), do: %{request_id: attrs.request_id, token_digest: attrs.token_digest}

  defp refuse!(attempt) do
    {:ok, _} = IdentityAttempts.advance(server(), attempt.id, "staged", "submitted")
    {:ok, _} = IdentityAttempts.advance(server(), attempt.id, "submitted", "refused")
  end

  defp people, do: Arca.Repo.aggregate(User, :count)
  defp claims, do: Arca.Repo.aggregate(InstallationClaim, :count)

  describe "the installed mode" do
    test "is answered once installed, replacing an earlier value" do
      :ok = InstallationClaims.install_mode!(:restore_reserved)
      assert InstallationClaims.mode() == :restore_reserved
      :ok = InstallationClaims.install_mode!(:ordinary)
      assert InstallationClaims.mode() == :ordinary
    end

    test "raises when nothing is installed, and a mint then writes nothing" do
      :ok = InstallationClaims.reset()
      refute InstallationClaims.installed?()
      assert_raise InstallationClaims.NotInstalledError, fn -> InstallationClaims.mode() end
      assert_raise InstallationClaims.NotInstalledError, fn -> mint() end
      assert people() == 0
    end

    test "a mode outside the two is not installed" do
      assert_raise FunctionClauseError, fn ->
        apply(InstallationClaims, :install_mode!, [:open])
      end
    end
  end

  describe "an ordinary mint" do
    test "under :ordinary mints as today" do
      assert {:ok, %{id: id}} = mint()
      assert people() == 1
      assert {:ok, %{id: ^id}} = Users.get(server(), id)
    end

    test "under :restore_reserved is refused on an empty node, and nothing is written" do
      :ok = InstallationClaims.install_mode!(:restore_reserved)
      assert {:error, :restore_reserved} = mint()
      assert people() == 0
    end

    test "under :restore_reserved is admitted once the node holds a person" do
      assert {:ok, _first} = mint()
      :ok = InstallationClaims.install_mode!(:restore_reserved)
      assert {:ok, _second} = mint()
      assert people() == 2
    end

    test "is refused while a claim is pending, whatever the mode" do
      assert {:ok, _attempt} = open(restore())
      assert {:error, :restore_reserved} = mint()

      :ok = InstallationClaims.install_mode!(:restore_reserved)
      assert {:error, :restore_reserved} = mint()
      assert people() == 0
    end
  end

  describe "a restore's mint" do
    test "is admitted only under its exact pending claim, on an empty node" do
      attrs = restore()
      {:ok, _attempt} = open(attrs)
      {user, _identity} = person_attrs()
      other = %{ref(attrs) | request_id: "req_other"}

      assert {:error, :not_claimed} = Users.mint(server(), user, nil, restore: other)
      assert {:ok, %{id: id}} = Users.mint(server(), user, nil, restore: ref(attrs))
      assert {:ok, []} = Users.identities(server(), id)

      {second, _} = person_attrs()
      assert {:error, :not_empty} = Users.mint(server(), second, nil, restore: ref(attrs))
    end

    test "without a claim is refused, and an ordinary mint names its identity" do
      {user, _identity} = person_attrs()

      assert {:error, :not_claimed} =
               Users.mint(server(), user, nil, restore: %{request_id: "r", token_digest: "t"})

      assert {:error, {:invalid, %{identity: _}}} = Users.mint(server(), user, nil)
      assert people() == 0
    end
  end

  describe "claiming through a restore's open" do
    test "binds the empty node with its attempt, and the exact request resumes both" do
      attrs = restore()
      assert {:ok, %{phase: "staged"} = attempt} = open(attrs)

      assert {:ok, %{state: "pending", request_id: request, token_digest: token} = claim} =
               InstallationClaims.get(server())

      assert {request, token} == {attrs.request_id, attrs.token_digest}
      assert {:ok, ^attempt} = open(attrs)
      assert {:ok, ^claim} = InstallationClaims.get(server())
      assert claims() == 1
    end

    test "refuses another request while pending, under the same token or another" do
      attrs = restore()
      {:ok, _} = open(attrs)

      # Two kits under one token: the second request is refused.
      assert {:error, :claimed} = open(restore(attrs.token_digest))
      # A new token while the first attempt is pending: refused too.
      assert {:error, :claimed} = open(restore())
      assert claims() == 1
    end

    test "an open that fails claims nothing, and its token is not spent" do
      attrs = restore()

      assert {:error, :kit_unsealed} = open(attrs, also: fn _attempt -> {:error, :kit_unsealed} end)
      assert {:error, :not_found} = InstallationClaims.get(server())
      assert claims() == 0
      assert Arca.Repo.aggregate(IdentityAttempt, :count) == 0

      assert {:ok, _} = open(attrs)
      assert {:ok, %{state: "pending"}} = InstallationClaims.get(server())
    end

    test "an attempt that fails ends its claim, and a token is spent for good (A, B, A)" do
      a = restore()
      {:ok, first} = open(a)
      refuse!(first)
      assert {:ok, %{state: "ended", outcome: "refused"}} = InstallationClaims.get(server())

      # The node is no longer reserved: a first door is admitted again.
      b = restore()
      {:ok, second} = open(b)
      refuse!(second)

      assert {:error, :token_spent} = open(restore(a.token_digest))
      assert {:error, :token_spent} = open(restore(b.token_digest))

      # The exact first request answers its ended attempt, and claims nothing.
      assert {:ok, %{phase: "refused"}} = open(a)
      assert claims() == 2

      assert {:ok, _} = open(restore())
      assert claims() == 3
    end

    test "a failed attempt leaves the node to an ordinary door" do
      attrs = restore()
      {:ok, attempt} = open(attrs)
      assert {:error, :restore_reserved} = mint()
      refuse!(attempt)
      assert {:ok, _person} = mint()
    end

    test "refuses a node that holds a person" do
      {:ok, _person} = mint()
      assert {:error, :not_empty} = open(restore())
      assert {:error, :not_found} = InstallationClaims.get(server())
    end

    test "refuses a malformed field and any actor but the platform's own" do
      assert {:error, {:invalid, %{token_digest: _}}} = open(%{restore() | token_digest: "raw-token"})

      assert {:error, :cross_tenant} =
               IdentityAttempts.open(Prima.Actor.in_athanor("ath_test"), restore())

      assert claims() == 0
    end
  end

  describe "the order row" do
    test "a database without the fingerprint row raises rather than deciding unordered" do
      key = Arca.SchemaFingerprint.key()
      {1, _} = Arca.Repo.delete_all(from(m in ServerMeta, where: m.key == ^key))

      assert_raise RuntimeError, ~r/no schema fingerprint row/, fn -> mint() end
      assert_raise RuntimeError, ~r/no schema fingerprint row/, fn -> open(restore()) end
      assert people() == 0
      assert claims() == 0
    end
  end

  describe "the member fence" do
    test "a stale owner claims nothing", %{slot: slot} do
      {1, _} =
        Arca.Repo.update_all(from(l in CellLease, where: l.node == ^slot.node),
          set: [owner: "someone-else", generation: slot.generation + 1]
        )

      assert {:error, :not_owner} = open(restore())
      assert {:error, :not_found} = InstallationClaims.get(server())
    end
  end
end

defmodule Arca.InstallationClaimsRaceTest do
  @moduledoc """
  A restore's claim racing a first door, and two kits racing under one
  token, on two real connections outside the sandbox. Both sides decide
  after locking one row, the schema fingerprint's, so the one that waits
  reads what the other committed: a door behind a claim is refused, a
  claim behind a door finds the node taken, and a second kit behind the
  first finds the node claimed. On PostgreSQL the waiter blocks on that
  row; on SQLite at the lock its transaction takes at entry.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias Arca.{ControlPlane, IdentityAttempts, InstallationClaims, Users}
  alias Arca.Schemas.{CellLease, ExternalIdentity, IdentityAttempt, InstallationClaim, User}
  alias Ecto.Adapters.SQL.Sandbox

  @slot_keys [
    {Arca.ControlPlane, :standing},
    {Arca.ControlPlane, :generation},
    {Arca.ControlPlane, :slot}
  ]

  defp unboxed(fun), do: Sandbox.unboxed_run(Arca.Repo, fun)
  defp server, do: Prima.Actor.system()
  defp postgres?, do: Arca.Repo.adapter() == Ecto.Adapters.Postgres
  defp digest(seed), do: Prima.Digest.sha256("#{seed}-#{System.unique_integer([:positive])}")

  setup do
    hold_slot!()
    mode = if InstallationClaims.installed?(), do: InstallationClaims.mode()
    token = digest("token")
    door_id = Prima.UUID7.generate_id(Prima.PersonId.prefix())

    on_exit(fn ->
      if mode, do: InstallationClaims.install_mode!(mode), else: InstallationClaims.reset()

      unboxed(fn ->
        Arca.Repo.delete_all(where(IdentityAttempt, token_digest: ^token))
        Arca.Repo.delete_all(where(InstallationClaim, token_digest: ^token))
        Arca.Repo.delete_all(where(ExternalIdentity, user_id: ^door_id))
        Arca.Repo.delete_all(where(User, id: ^door_id))
      end)
    end)

    InstallationClaims.install_mode!(:ordinary)

    # The race is over an empty node: nothing committed may hold a person
    # or a pending claim when it starts.
    assert {0, false} ==
             unboxed(fn ->
               {Arca.Repo.aggregate(User, :count),
                Arca.Repo.exists?(where(InstallationClaim, state: "pending"))}
             end)

    {:ok, token: token, door_id: door_id}
  end

  # This member's slot, taken on a real connection so every connection
  # reads the lease; the lease row, the process-wide standing and the
  # claim switch are given back after the case.
  defp hold_slot! do
    saved = Map.new(@slot_keys, &{&1, :persistent_term.get(&1, :absent)})
    claim = Application.get_env(:arca, :control_plane_claim_enabled)
    node = "node-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      unboxed(fn -> Arca.Repo.delete_all(from(l in CellLease, where: l.node == ^node)) end)

      for {key, value} <- saved do
        if value == :absent,
          do: :persistent_term.erase(key),
          else: :persistent_term.put(key, value)
      end

      if is_nil(claim),
        do: Application.delete_env(:arca, :control_plane_claim_enabled),
        else: Application.put_env(:arca, :control_plane_claim_enabled, claim)
    end)

    Application.put_env(:arca, :control_plane_claim_enabled, true)
    {:ok, slot} = unboxed(fn -> ControlPlane.take(node, node <> "#boot", 60_000) end)
    slot
  end

  # The connection's backend, on PostgreSQL, for the test to watch it wait.
  defp backend do
    if postgres?(), do: hd(hd(Arca.Repo.query!("SELECT pg_backend_pid()").rows))
  end

  # On PostgreSQL, `backend` is blocked on a row lock, in a statement
  # naming every one of `fragments`.
  defp await_wait!(backend, fragments, tries \\ 250) do
    [[type, event, query]] =
      unboxed(fn ->
        Arca.Repo.query!(
          "SELECT wait_event_type, wait_event, query FROM pg_stat_activity WHERE pid = $1",
          [backend]
        ).rows
      end)

    cond do
      type == "Lock" and Enum.all?(fragments, &String.contains?(query, &1)) -> :ok
      tries == 0 -> flunk("backend #{backend} is not waiting at #{inspect(fragments)}: #{type} #{event} #{query}")
      true -> retry_wait!(backend, fragments, tries)
    end
  end

  defp retry_wait!(backend, fragments, tries) do
    Process.sleep(20)
    await_wait!(backend, fragments, tries - 1)
  end

  # The waiter blocks where the order row is locked.
  defp assert_waits_on_order!(task, backend) do
    if postgres?(), do: await_wait!(backend, [~s("server_meta"), "FOR UPDATE"])
    refute Task.yield(task, 300), "the waiter decided while the other side held the order row"
  end

  defp pause(test, tag) do
    fn _row ->
      send(test, {tag, :holds})

      receive do
        :go -> :ok
      end
    end
  end

  defp restore(token) do
    %{
      kind: "restore",
      request_id: "req_#{System.unique_integer([:positive])}",
      identifier: "per_" <> Prima.Digest.sha256_hex("restored-#{System.unique_integer()}"),
      directory_url: "https://dir.example",
      entry: "recover-request",
      request_digest: digest("recover"),
      expected_revision: 0,
      token_digest: token,
      staged_live_public_key: :crypto.strong_rand_bytes(32),
      staged_operational_public_key: :crypto.strong_rand_bytes(32),
      staged_live_key_sealed: "sealed-live",
      staged_operational_key_sealed: "sealed-op"
    }
  end

  defp door(id, opts) do
    n = System.unique_integer([:positive])
    now = DateTime.utc_now()

    Users.mint(
      server(),
      %{
        id: id,
        provider: "github",
        email: "door#{n}@example.com",
        email_verified: true,
        first_seen_at: now,
        last_seen_at: now,
        created_at: now,
        updated_at: now
      },
      %{
        key: "github|https://github.com|door#{n}",
        provider: "github",
        issuer: "https://github.com",
        subject: "door#{n}",
        first_seen_at: now,
        last_seen_at: now
      },
      opts
    )
  end

  test "a first door waiting behind a restore's claim is refused", %{token: token, door_id: id} do
    test = self()

    claimant =
      Task.async(fn ->
        unboxed(fn -> IdentityAttempts.open(server(), restore(token), also: pause(test, :claim)) end)
      end)

    assert_receive {:claim, :holds}, 5_000

    opener =
      Task.async(fn ->
        unboxed(fn ->
          send(test, {:door, backend()})
          door(id, [])
        end)
      end)

    assert_receive {:door, pid}, 5_000
    assert_waits_on_order!(opener, pid)

    send(claimant.pid, :go)
    assert {:ok, %{phase: "staged"}} = Task.await(claimant, 25_000)
    assert {:error, :restore_reserved} = Task.await(opener, 25_000)
    refute unboxed(fn -> Arca.Repo.exists?(where(User, id: ^id)) end)
  end

  test "a restore waiting behind a first door finds the node taken", %{token: token, door_id: id} do
    test = self()

    opener =
      Task.async(fn -> unboxed(fn -> door(id, also: pause(test, :door)) end) end)

    assert_receive {:door, :holds}, 5_000

    claimant =
      Task.async(fn ->
        unboxed(fn ->
          send(test, {:claim, backend()})
          IdentityAttempts.open(server(), restore(token))
        end)
      end)

    assert_receive {:claim, pid}, 5_000
    assert_waits_on_order!(claimant, pid)

    send(opener.pid, :go)
    assert {:ok, %{id: ^id}} = Task.await(opener, 25_000)
    assert {:error, :not_empty} = Task.await(claimant, 25_000)
    refute unboxed(fn -> Arca.Repo.exists?(where(InstallationClaim, token_digest: ^token)) end)
  end

  test "a second kit under one token waits behind the first and is refused", %{token: token} do
    test = self()
    first = restore(token)

    kit =
      Task.async(fn ->
        unboxed(fn -> IdentityAttempts.open(server(), first, also: pause(test, :kit)) end)
      end)

    assert_receive {:kit, :holds}, 5_000

    second =
      Task.async(fn ->
        unboxed(fn ->
          send(test, {:second, backend()})
          IdentityAttempts.open(server(), restore(token))
        end)
      end)

    assert_receive {:second, pid}, 5_000
    assert_waits_on_order!(second, pid)

    send(kit.pid, :go)
    assert {:ok, %{request_id: request}} = Task.await(kit, 25_000)
    assert request == first.request_id
    assert {:error, :claimed} = Task.await(second, 25_000)

    assert [%{request_id: ^request, state: "pending"}] =
             unboxed(fn -> Arca.Repo.all(where(InstallationClaim, token_digest: ^token)) end)

    assert 1 == unboxed(fn -> Arca.Repo.aggregate(where(IdentityAttempt, token_digest: ^token), :count) end)
  end
end
