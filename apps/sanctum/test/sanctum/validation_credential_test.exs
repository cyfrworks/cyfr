# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.ValidationCredentialTest do
  @moduledoc """
  The validation credential: a frame credential whose row's purpose is
  `validation`, minted with the frame credential's arguments and checks
  for 60 seconds, never past its source; established as a validation
  frame; never suspended or resumed; and spent once, by its own person's
  primary context, only for the digest it was minted for and only on a
  member that still owns its slot. No log line or refusal names its
  bearer.
  """

  # Takes a slot through `Arca.ControlPlane`, which writes the process-wide
  # standing record, and raises the global log level for one case; each is
  # restored when its case ends.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog, only: [with_log: 2]

  alias Arca.Schemas.{CellLease, FrameCredential}
  alias Sanctum.Context
  alias Sanctum.TinctureAuth

  @person "github|https://github.com|validation-person"
  @digest "sha256:" <> String.duplicate("e", 64)
  @other_digest "sha256:" <> String.duplicate("f", 64)
  @tincture %{publisher: "acme", name: "canvas", version: "1.0.3"}

  @keys [
    {Arca.ControlPlane, :standing},
    {Arca.ControlPlane, :generation},
    {Arca.ControlPlane, :slot}
  ]

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    Arca.Cache.init()
    settings!(3_600, 900)
    user = person!(@person)
    {session, ctx} = session_ctx!(user)
    {:ok, user: user, session: session, source: ctx}
  end

  describe "minting" do
    test "a validation credential has the frame credential's form, its row's purpose, and 60 seconds",
         %{source: ctx} do
      frame = frame_id()

      assert {:ok, %{credential: bearer, id: id, deadline: deadline}} =
               TinctureAuth.mint_validation_credential(ctx, @tincture, @digest, 3, frame)

      refute bearer =~ ctx.user_id
      # The frame credential setting is 900 seconds; a validation trial's
      # life is its own.
      assert DateTime.diff(deadline, DateTime.utc_now()) in 50..60

      assert %FrameCredential{
               purpose: "validation",
               state: "active",
               frame_id: ^frame,
               version_digest: @digest,
               grant_revision: 3
             } = Arca.Repo.get(FrameCredential, id)

      assert {:ok, %{id: ^id, frame_id: ^frame, mode: :validation, deadline: ^deadline}} =
               TinctureAuth.verify_frame_credential(bearer, client_ip: "127.0.0.1")

      {:ok, %{id: live_id, deadline: live}} =
        TinctureAuth.mint_frame_credential(ctx, @tincture, @digest, 3, frame_id())

      assert DateTime.diff(live, DateTime.utc_now()) in 890..900
      assert %FrameCredential{purpose: "live"} = Arca.Repo.get(FrameCredential, live_id)
    end

    test "takes the frame credential's checks", %{source: ctx} do
      frame = frame_id()
      {:ok, _} = TinctureAuth.mint_frame_credential(ctx, @tincture, @digest, 1, frame)

      assert {:error, :conflict} =
               TinctureAuth.mint_validation_credential(ctx, @tincture, @digest, 1, frame)

      assert {:error, :missing_frame_id} =
               TinctureAuth.mint_validation_credential(ctx, @tincture, @digest, 1, "short")

      assert {:error, :invalid_reference} =
               TinctureAuth.mint_validation_credential(
                 ctx,
                 %{@tincture | version: "latest"},
                 @digest,
                 1,
                 frame_id()
               )

      assert {:error, :invalid_version} =
               TinctureAuth.mint_validation_credential(ctx, @tincture, "sha256:no", 1, frame_id())

      assert {:error, :invalid_grant_revision} =
               TinctureAuth.mint_validation_credential(ctx, @tincture, @digest, -1, frame_id())

      {:ok, %{credential: bearer}} =
        TinctureAuth.mint_validation_credential(ctx, @tincture, @digest, 1, frame_id())

      {:ok, framed} = Sanctum.Caller.establish({:frame_credential, bearer})

      assert {:error, :not_primary} =
               TinctureAuth.mint_validation_credential(framed, @tincture, @digest, 1, frame_id())

      assert Arca.Repo.aggregate(
               from(f in FrameCredential, where: f.purpose == "validation"),
               :count
             ) == 1
    end

    test "its deadline never outlives its source", %{source: ctx, session: session} do
      ends = expire_session_in!(session, 10)

      {:ok, %{deadline: deadline}} =
        TinctureAuth.mint_validation_credential(ctx, @tincture, @digest, 1, frame_id())

      refute DateTime.compare(deadline, ends) == :gt
      assert DateTime.diff(deadline, DateTime.utc_now()) <= 10
    end
  end

  describe "the established frame" do
    test "names the validation mode, and a live frame the live one", %{source: ctx} do
      frame = frame_id()

      {:ok, %{credential: bearer, id: id, deadline: deadline}} =
        TinctureAuth.mint_validation_credential(ctx, @tincture, @digest, 2, frame)

      assert {:ok, framed} =
               Sanctum.Caller.establish({:frame_credential, bearer}, client_ip: "127.0.0.1")

      assert framed.frame == %{
               id: id,
               frame_id: frame,
               reference: @tincture,
               version_digest: @digest,
               grant_revision: 2,
               mode: :validation
             }

      assert framed.auth_method == :tincture
      assert framed.credential_deadline == deadline

      {:ok, %{credential: live}} =
        TinctureAuth.mint_frame_credential(ctx, @tincture, @digest, 2, frame_id())

      assert {:ok, %Context{frame: %{mode: :live}}} =
               Sanctum.Caller.establish({:frame_credential, live})
    end

    test "is never suspended or resumed, and is revoked as any frame is", %{source: ctx} do
      frame = frame_id()

      {:ok, %{credential: bearer, id: id}} =
        TinctureAuth.mint_validation_credential(ctx, @tincture, @digest, 1, frame)

      before = Arca.Repo.get(FrameCredential, id)

      assert {:error, :validation} = TinctureAuth.suspend_frame(ctx, id)
      assert {:error, :validation} = TinctureAuth.resume_frame(ctx, id)
      assert Arca.Repo.get(FrameCredential, id) == before
      assert {:ok, %{frame: %{mode: :validation}}} = establish(bearer)

      assert {:ok, %{state: "revoked"}} = TinctureAuth.revoke_frame(ctx, id)
      assert {:error, :revoked} = establish(bearer)
      assert {:error, :validation} = TinctureAuth.resume_frame(ctx, id)
      assert {:error, :not_validated} = TinctureAuth.consume_validation(ctx, frame, @digest)
    end
  end

  describe "consuming" do
    test "a consume with the wrong digest changes nothing and the right one then succeeds", %{
      source: ctx
    } do
      frame = frame_id()

      {:ok, %{credential: bearer, id: id}} =
        TinctureAuth.mint_validation_credential(ctx, @tincture, @digest, 1, frame)

      before = Arca.Repo.get(FrameCredential, id)

      assert {:error, :not_validated} =
               TinctureAuth.consume_validation(ctx, frame, @other_digest)

      assert Arca.Repo.get(FrameCredential, id) == before
      assert {:ok, %{mode: :validation}} = TinctureAuth.verify_frame_credential(bearer)

      assert :ok = TinctureAuth.consume_validation(ctx, frame, @digest)
      assert %FrameCredential{state: "revoked"} = Arca.Repo.get(FrameCredential, id)
      assert {:error, :revoked} = TinctureAuth.verify_frame_credential(bearer)

      # Spent once: the same consume again spends nothing.
      assert {:error, :not_validated} = TinctureAuth.consume_validation(ctx, frame, @digest)
    end

    test "a live credential, another person's or an expired one is not consumed", %{
      source: ctx
    } do
      live = frame_id()
      {:ok, %{id: live_id}} = TinctureAuth.mint_frame_credential(ctx, @tincture, @digest, 1, live)

      assert {:error, :not_validated} = TinctureAuth.consume_validation(ctx, live, @digest)
      assert %FrameCredential{state: "active"} = Arca.Repo.get(FrameCredential, live_id)

      mine = frame_id()

      {:ok, %{id: mine_id}} =
        TinctureAuth.mint_validation_credential(ctx, @tincture, @digest, 1, mine)

      {_session, theirs} = session_ctx!(person!("github|https://github.com|validation-other"))
      assert {:error, :not_validated} = TinctureAuth.consume_validation(theirs, mine, @digest)
      assert %FrameCredential{state: "active"} = Arca.Repo.get(FrameCredential, mine_id)
      assert :ok = TinctureAuth.consume_validation(ctx, mine, @digest)

      expired = frame_id()

      {:ok, %{id: expired_id}} =
        TinctureAuth.mint_validation_credential(ctx, @tincture, @digest, 1, expired)

      {1, _} =
        Arca.Repo.update_all(from(f in FrameCredential, where: f.id == ^expired_id),
          set: [deadline: DateTime.add(DateTime.utc_now(), -1, :second)]
        )

      assert {:error, :not_validated} = TinctureAuth.consume_validation(ctx, expired, @digest)
      assert %FrameCredential{state: "active"} = Arca.Repo.get(FrameCredential, expired_id)
    end

    test "a frame's own context spends nothing", %{source: ctx} do
      frame = frame_id()

      {:ok, %{credential: bearer, id: id}} =
        TinctureAuth.mint_validation_credential(ctx, @tincture, @digest, 1, frame)

      {:ok, framed} = establish(bearer)

      assert {:error, :not_primary} = TinctureAuth.consume_validation(framed, frame, @digest)
      assert %FrameCredential{state: "active"} = Arca.Repo.get(FrameCredential, id)
    end

    test "ownership lost before the consume spends nothing", %{source: ctx} do
      slot = claimant!()
      frame = frame_id()

      {:ok, %{id: id}} =
        TinctureAuth.mint_validation_credential(ctx, @tincture, @digest, 1, frame)

      # A successor takes the slot over; this member still believes it
      # holds it, so only the consume's own live check stands between it
      # and the write.
      {1, _} =
        Arca.Repo.update_all(from(l in CellLease, where: l.node == ^slot.node),
          set: [owner: slot.node <> "#boot_b", generation: slot.generation + 1]
        )

      assert Arca.ControlPlane.held?()
      assert {:error, :not_owner} = TinctureAuth.consume_validation(ctx, frame, @digest)
      assert %FrameCredential{state: "active"} = Arca.Repo.get(FrameCredential, id)
    end

    test "no log line or refusal names the bearer", %{source: ctx} do
      previous = Logger.level()
      on_exit(fn -> Logger.configure(level: previous) end)
      Logger.configure(level: :debug)

      frame = frame_id()

      {{bearer, refusals}, log} =
        with_log([level: :debug], fn ->
          {:ok, %{credential: bearer, id: id}} =
            TinctureAuth.mint_validation_credential(ctx, @tincture, @digest, 1, frame)

          refusals = [
            TinctureAuth.suspend_frame(ctx, id),
            TinctureAuth.resume_frame(ctx, id),
            TinctureAuth.consume_validation(ctx, frame, @other_digest),
            TinctureAuth.consume_validation(ctx, "frm_never_opened", @digest)
          ]

          {:ok, _framed} = establish(bearer)
          assert :ok = TinctureAuth.consume_validation(ctx, frame, @digest)
          {bearer, refusals ++ [establish(bearer)]}
        end)

      assert refusals == [
               {:error, :validation},
               {:error, :validation},
               {:error, :not_validated},
               {:error, :not_validated},
               {:error, :revoked}
             ]

      refute log =~ bearer
    end
  end

  # ---- helpers ---------------------------------------------------------------

  defp frame_id, do: "frm_#{System.unique_integer([:positive])}_trial"

  defp establish(bearer),
    do: Sanctum.Caller.establish({:frame_credential, bearer}, client_ip: "127.0.0.1")

  # The two settings the frame protocol reads, installed beside whatever
  # the run installed and restored after.
  defp settings!(window, deadline) do
    previous = Arca.PlatformSettings.installed()

    on_exit(fn ->
      if previous,
        do: Arca.PlatformSettings.install_defaults!(previous),
        else: Arca.PlatformSettings.uninstall()
    end)

    Arca.PlatformSettings.install_defaults!(
      Map.merge(previous || %{}, %{
        "asset_credential_window_s" => %{default: window, stale: :serve},
        "frame_credential_deadline_s" => %{default: deadline, stale: :serve}
      })
    )
  end

  defp person!(id) do
    {:ok, user} =
      Sanctum.Test.People.linked(%{
        id: id,
        provider: "github",
        email: String.replace(id, ~r/\A.*\|/, "") <> "@example.com",
        verified: true
      })

    {:ok, _} = Sanctum.Tenancy.Members.ensure(user.id, scope: "athanor", athanor_id: "ath_acme")
    user
  end

  defp session_ctx!(user) do
    ctx =
      Context.build(
        user_id: user.id,
        provider: "github",
        athanor_id: "ath_acme",
        permissions: [:*],
        scope: :athanor,
        auth_method: :oidc,
        authenticated: true
      )

    {:ok, session} = Sanctum.TestContext.create_session(ctx)
    {:ok, established} = Sanctum.Caller.establish(session.token, focus: "ath_acme")
    {session, %{established | client_ip: "127.0.0.1"}}
  end

  defp expire_session_in!(session, seconds) do
    hash = Sanctum.Session.token_hash(session.token)
    at = DateTime.add(DateTime.utc_now(), seconds, :second)

    {1, _} =
      Arca.Repo.update_all(
        from(s in Arca.Schemas.Session, where: s.token_hash == ^hash),
        set: [expires_at: at]
      )

    Sanctum.Caller.invalidate_hash(hash)
    at
  end

  # A claimant runs, as a deployment's does, and this member holds its
  # slot: the umbrella's test configuration runs none, which would leave
  # the consume's live check nothing to check.
  defp claimant! do
    saved = Map.new(@keys, &{&1, :persistent_term.get(&1, :absent)})
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
    node = "node-vcred-#{System.unique_integer([:positive])}"
    {:ok, slot} = Arca.ControlPlane.take(node, node <> "#boot_a", 60_000)
    slot
  end
end

defmodule Sanctum.ValidationCredentialRaceTest do
  @moduledoc """
  Two consumes of one validation credential at once, on connections of
  their own: inside the sandbox one shared connection would serialize
  them. Exactly one spends it. On PostgreSQL both are held behind a
  transaction that locks the row until each is seen waiting on it, so
  they race for the row when it is let go; SQLite's one write lock admits
  one transaction at a time, so there the two run as two processes. The
  case works in an athanor of its own, whose rows it deletes when it ends.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import Arca.Test.Adapter, only: [postgres?: 0]

  alias Arca.Schemas.FrameCredential
  alias Arca.Test.LockWait
  alias Ecto.Adapters.SQL.Sandbox
  alias Sanctum.Context
  alias Sanctum.TinctureAuth

  @digest "sha256:" <> String.duplicate("e", 64)

  setup do
    athanor = "ath_vcred_race_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      unboxed(fn ->
        Arca.Repo.delete_all(from(f in FrameCredential, where: f.athanor_id == ^athanor))
      end)
    end)

    {:ok, athanor: athanor}
  end

  test "two concurrent consumes of one credential: exactly one answers :ok", %{
    athanor: athanor
  } do
    ctx =
      Context.build(
        user_id: "usr_vcred_race",
        athanor_id: athanor,
        permissions: [:*],
        scope: :athanor,
        auth_method: :oidc,
        authenticated: true
      )

    frame = "frm_#{System.unique_integer([:positive])}_race"

    {:ok, row} =
      unboxed(fn ->
        Arca.FrameCredentials.mint(Context.actor(ctx), %{
          user_id: ctx.user_id,
          publisher: "acme",
          name: "canvas",
          version: "1.0.3",
          version_digest: @digest,
          grant_revision: 1,
          frame_id: frame,
          source_kind: "session",
          source_id: "c2Vzc2lvbi1yYWNl",
          purpose: "validation",
          deadline: DateTime.add(DateTime.utc_now(), 60, :second)
        })
      end)

    test = self()

    consume = fn ->
      Task.async(fn ->
        unboxed(fn ->
          if postgres?(), do: send(test, {:backend, backend_pid()})
          TinctureAuth.consume_validation(ctx, frame, @digest)
        end)
      end)
    end

    answers =
      if postgres?() do
        holder =
          holding(fn ->
            from(f in FrameCredential, where: f.id == ^row.id)
            |> Arca.QueryHelpers.for_update()
            |> Arca.Repo.one()
          end)

        consumers = [consume.(), consume.()]

        for _ <- consumers do
          assert_receive {:backend, backend}, 15_000
          LockWait.await_lock_wait!(backend, [], timeout_ms: 10_000)
        end

        release(holder)
        Enum.map(consumers, &Task.await(&1, 30_000))
      else
        [consume.(), consume.()] |> Enum.map(&Task.await(&1, 30_000))
      end

    assert Enum.sort(answers) == [:ok, {:error, :not_validated}]

    assert %FrameCredential{state: "revoked"} =
             unboxed(fn -> Arca.Repo.get(FrameCredential, row.id) end)
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Arca.Repo, fun)

  # Run `lock` in a transaction of its own and hold it open until
  # `release/1`.
  defp holding(lock) do
    test = self()

    task =
      Task.async(fn ->
        unboxed(fn ->
          Arca.Repo.transaction(fn ->
            result = lock.()
            send(test, {:holding, self()})

            receive do
              :commit -> result
            end
          end)
        end)
      end)

    assert_receive {:holding, _pid}, 15_000
    task
  end

  defp release(task) do
    send(task.pid, :commit)
    Task.await(task, 30_000)
  end

  # The backend of the current connection, so another can watch it wait.
  defp backend_pid do
    %{rows: [[pid]]} = Arca.Repo.query!("SELECT pg_backend_pid()")
    pid
  end
end
