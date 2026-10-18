# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.StorageReserveTest do
  @moduledoc """
  The storage reserve (`Cyfr.StorageReserve`, `ARCHITECTURE.md` §6.9),
  under a free-space reading the test sets: the latch and the reserve
  file it keeps, and what the gate, Arca's write gate and the decision log
  do while it reads `depleted`.

  A device revocation completes through the gate while depleted, its
  confirmation read by its `request`, proven and spent, while a note
  write is refused and an ordinary confirmation beside it can be neither
  read, proven nor spent. The latch stays `depleted` across the polls
  after the free and across a restart until the space is above the mark
  plus the reserve, a failed allocation is `depleted`, and a reserve
  directory the boot cannot use refuses the boot.
  """

  # The latch is this member's, read by every write: one test at a time.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Prima.DeviceCert
  alias Prima.DeviceCert.{Challenge, Proof}
  alias Prima.Identity.Encoding
  alias Sanctum.Context
  alias Sanctum.Tenancy.{Athanors, Users}

  # A reserve small enough for any test filesystem.
  @bytes 64 * 1024

  defmodule Disk do
    @moduledoc false
    # The free space the test sets, per path or for every path, and an
    # allocation that fails when the test says so; otherwise the real
    # allocation, so the reserve file is a real file of the real size.

    def start_link, do: Agent.start_link(fn -> %{free: nil, fail: false} end, name: __MODULE__)

    def set_free(free), do: Agent.update(__MODULE__, &%{&1 | free: free})
    def fail_allocation(fail?), do: Agent.update(__MODULE__, &%{&1 | fail: fail?})

    def free_bytes(_path) do
      case Agent.get(__MODULE__, & &1.free) do
        free when is_integer(free) -> {:ok, free}
        _unread -> {:error, :unread}
      end
    end

    def allocate(file, bytes) do
      if Agent.get(__MODULE__, & &1.fail),
        do: {:error, :enospc},
        else: Cyfr.StorageReserve.Disk.allocate(file, bytes)
    end
  end

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    Prima.Test.RateLimiter.reset!()
    # Restores registered before anything changes them.
    on_exit(fn ->
      Arca.StorageReserve.put(:ok)
      Prima.Test.RateLimiter.reset!()
    end)

    start_supervised!(%{id: Disk, start: {Disk, :start_link, []}})
    :ok
  end

  # The monitor over `directory`, polling only when asked.
  defp monitor(directory, opts \\ []) do
    opts =
      Keyword.merge(
        [
          name: __MODULE__.Monitor,
          bytes: @bytes,
          directory: directory,
          roots: [],
          disk: Disk,
          interval: :infinity
        ],
        opts
      )

    {Cyfr.StorageReserve, opts}
  end

  defp start!(directory, opts \\ []) do
    spec = monitor(directory, opts)
    pid = start_supervised!(spec)
    {pid, spec}
  end

  defp reserve_file(directory), do: Cyfr.StorageReserve.file(directory)

  defp held?(directory),
    do: match?({:ok, %File.Stat{size: @bytes}}, File.stat(reserve_file(directory)))

  defp reserve_refusal?({:error, %Prima.Refusal{class: :unavailable, reason: reason}}),
    do: reason == {:unavailable, :storage_reserve}

  defp reserve_refusal?(_answer), do: false

  describe "the latch" do
    @describetag :tmp_dir

    test "a boot with room preallocates the reserve file and reads ok", %{tmp_dir: dir} do
      Disk.set_free(10 * @bytes)
      {pid, _spec} = start!(dir)

      assert Arca.StorageReserve.state() == :ok
      assert held?(dir)
      assert Cyfr.StorageReserve.poll(pid) == :ok
    end

    test "below the mark the latch is depleted and the file freed; the polls after stay depleted",
         %{tmp_dir: dir} do
      Disk.set_free(10 * @bytes)
      {pid, _spec} = start!(dir)

      Disk.set_free(@bytes - 1)
      assert Cyfr.StorageReserve.poll(pid) == :depleted
      assert Arca.StorageReserve.depleted?()
      refute File.exists?(reserve_file(dir))

      # The freed file's bytes are back on the filesystem: the reading
      # rises by the reserve, and is still not headroom.
      Disk.set_free(2 * @bytes - 1)
      assert Cyfr.StorageReserve.poll(pid) == :depleted
      assert Cyfr.StorageReserve.poll(pid) == :depleted
      Disk.set_free(2 * @bytes)
      assert Cyfr.StorageReserve.poll(pid) == :depleted
      refute File.exists?(reserve_file(dir))
    end

    test "a restart while depleted stays depleted", %{tmp_dir: dir} do
      Disk.set_free(10 * @bytes)
      {pid, spec} = start!(dir)
      Disk.set_free(@bytes - 1)
      assert Cyfr.StorageReserve.poll(pid) == :depleted

      :ok = stop_supervised(Cyfr.StorageReserve)
      # A new VM's term, before any monitor derives it.
      Arca.StorageReserve.put(:ok)

      # Back above the mark, but not above the mark plus the reserve.
      Disk.set_free(2 * @bytes - 1)
      start_supervised!(spec)
      assert Arca.StorageReserve.state() == :depleted
      refute File.exists?(reserve_file(dir))
    end

    test "replenishment above the mark plus the reserve allocates the file and returns to ok",
         %{tmp_dir: dir} do
      Disk.set_free(10 * @bytes)
      {pid, _spec} = start!(dir)
      Disk.set_free(@bytes - 1)
      assert Cyfr.StorageReserve.poll(pid) == :depleted

      Disk.set_free(2 * @bytes + 1)
      assert Cyfr.StorageReserve.poll(pid) == :ok
      assert Arca.StorageReserve.state() == :ok
      assert held?(dir)
    end

    test "a boot under the mark, a failed reading and a failed allocation are each depleted",
         %{tmp_dir: dir} do
      Disk.set_free(@bytes - 1)
      start!(dir)
      refute File.exists?(reserve_file(dir))
      assert Arca.StorageReserve.state() == :depleted
      :ok = stop_supervised(Cyfr.StorageReserve)

      # A local root whose reading fails (the reserve's own directory
      # refuses the boot instead, below).
      Arca.StorageReserve.put(:ok)
      Disk.set_free(nil)
      start!(nil, roots: [dir])
      assert Arca.StorageReserve.state() == :depleted
      :ok = stop_supervised(Cyfr.StorageReserve)

      Arca.StorageReserve.put(:ok)
      Disk.set_free(10 * @bytes)
      Disk.fail_allocation(true)
      {pid, _spec} = start!(dir)
      assert Arca.StorageReserve.state() == :depleted
      refute File.exists?(reserve_file(dir))

      # Allocated once the filesystem takes it.
      Disk.fail_allocation(false)
      assert Cyfr.StorageReserve.poll(pid) == :ok
      assert held?(dir)

      # A reading that fails while ok is depleted too.
      Disk.set_free(nil)
      assert Cyfr.StorageReserve.poll(pid) == :depleted
      refute File.exists?(reserve_file(dir))
    end

    test "a held file at boot keeps the latch ok between the mark and the mark plus the reserve",
         %{tmp_dir: dir} do
      Disk.set_free(10 * @bytes)
      start!(dir)
      :ok = stop_supervised(Cyfr.StorageReserve)
      assert held?(dir)

      Disk.set_free(@bytes + 1)
      start!(dir)
      assert Arca.StorageReserve.state() == :ok
    end

    test "a stray message is dropped, and the monitor keeps its latch", %{tmp_dir: dir} do
      Disk.set_free(10 * @bytes)
      {pid, _spec} = start!(dir)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          send(pid, {:unexpected, "a value"})
          assert Cyfr.StorageReserve.poll(pid) == :ok
        end)

      assert log =~ "[Cyfr.StorageReserve] unexpected message"
      refute log =~ "a value"
    end

    test "with no directory the local roots alone are read, and with none nothing is" do
      Disk.set_free(@bytes - 1)
      start!(nil, roots: ["/a/root"])
      assert Arca.StorageReserve.state() == :depleted
      :ok = stop_supervised(Cyfr.StorageReserve)

      start!(nil, roots: [])
      assert Arca.StorageReserve.state() == :ok
    end
  end

  describe "the boot's refusals" do
    @describetag :tmp_dir

    test "a directory that does not exist, is not writable or reports no free space",
         %{tmp_dir: dir} do
      Disk.set_free(10 * @bytes)
      Process.flag(:trap_exit, true)

      missing = Path.join(dir, "missing")

      assert {:error, {{:storage_reserve_path, :not_found}, _}} =
               start_supervised(monitor(missing))

      locked = Path.join(dir, "locked")
      File.mkdir_p!(locked)
      on_exit(fn -> File.chmod(locked, 0o700) end)
      File.chmod!(locked, 0o500)

      assert {:error, {{:storage_reserve_path, :not_writable}, _}} =
               start_supervised(monitor(locked))

      Disk.set_free(nil)

      assert {:error, {{:storage_reserve_path, :no_free_space_reading}, _}} =
               start_supervised(monitor(dir))
    end

    test "the size is a whole number of bytes from 1, defaulting to 64 MiB; 0 is refused" do
      sqlite = :sqlite
      postgres = :postgres
      env = fn vars -> &Map.get(vars, &1) end

      assert {:ok, %{bytes: 67_108_864, path: "/srv/cyfr/db"}} =
               Cyfr.RuntimeConfig.resolve_storage_reserve(
                 env.(%{}),
                 sqlite,
                 "/srv/cyfr/db/cyfr.db"
               )

      assert {:ok, %{bytes: 67_108_864, path: nil}} =
               Cyfr.RuntimeConfig.resolve_storage_reserve(env.(%{}), postgres, "/srv/cyfr.db")

      assert {:ok, %{bytes: 1, path: "/srv/reserve"}} =
               Cyfr.RuntimeConfig.resolve_storage_reserve(
                 env.(%{
                   "CYFR_STORAGE_RESERVE_BYTES" => "1",
                   "CYFR_STORAGE_RESERVE_PATH" => "/srv/reserve"
                 }),
                 postgres,
                 "/srv/cyfr.db"
               )

      for refused <- ["0", "-1", "64MiB", "1.5", "1099511627777"] do
        assert {:error, message} =
                 Cyfr.RuntimeConfig.resolve_storage_reserve(
                   env.(%{"CYFR_STORAGE_RESERVE_BYTES" => refused}),
                   sqlite,
                   "/srv/cyfr.db"
                 )

        assert message =~ "CYFR_STORAGE_RESERVE_BYTES"
      end

      assert {:error, message} =
               Cyfr.RuntimeConfig.resolve_storage_reserve(
                 env.(%{"CYFR_STORAGE_RESERVE_PATH" => " "}),
                 postgres,
                 "/srv/cyfr.db"
               )

      assert message =~ "CYFR_STORAGE_RESERVE_PATH"
    end
  end

  describe "the filesystem" do
    @describetag :tmp_dir

    test "reads a real free space and allocates a real file", %{tmp_dir: dir} do
      assert {:ok, free} = Cyfr.StorageReserve.Disk.free_bytes(dir)
      assert is_integer(free) and free > 0

      file = Path.join(dir, "reserve")
      assert :ok = Cyfr.StorageReserve.Disk.allocate(file, 3 * 4096 + 5)
      assert {:ok, %File.Stat{size: 12_293}} = File.stat(file)
      # Allocated again in place, and shortened to the size asked.
      assert :ok = Cyfr.StorageReserve.Disk.allocate(file, 4096)
      assert {:ok, %File.Stat{size: 4096}} = File.stat(file)

      assert {:error, _unread} = Cyfr.StorageReserve.Disk.free_bytes(Path.join(dir, "missing"))
    end
  end

  describe "while depleted" do
    @describetag :tmp_dir

    setup %{tmp_dir: dir} do
      seated = seated!()
      authenticator = Sanctum.TestContext.passkey!(seated.user.id)
      device = pair!(seated.session_ctx)

      Disk.set_free(10 * @bytes)
      {pid, _spec} = start!(dir)
      Map.merge(seated, %{authenticator: authenticator, device: device, monitor: pid})
    end

    test "a device revocation completes, read by its request, while a note write is refused",
         %{session_ctx: ctx, authenticator: authenticator, device: device, monitor: pid} do
      Disk.set_free(@bytes - 1)
      assert Cyfr.StorageReserve.poll(pid) == :depleted

      # The note: refused at the gate, and by Arca's write gate below it.
      assert reserve_refusal?(
               call(ctx, "notes", "keep", %{"name" => "reserve", "content" => "a note"})
             )

      assert {:error, {:unavailable, :storage_reserve}} =
               Arca.put(Context.actor(ctx), ["notes", "reserve.md"], "a note")

      # The revocation opens its confirmation…
      assert {:error, {:confirmation_required, %{id: id}}} =
               call(ctx, "pairing", "revoke", %{"client_id" => device.client_id})

      ref = Prima.Confirmation.ref(id)

      # …which the list shows, and its request reads alone.
      assert {:ok, %{confirmations: [%{ref: ^ref}]}} =
               call(ctx, "confirmation", "pending", %{})

      assert {:ok, %{confirmations: [entry]}} =
               call(ctx, "confirmation", "pending", %{"request" => ref})

      assert entry.ref == ref
      assert entry.operation == "pairing.revoke"

      # The proof, then the revocation repeated naming it.
      {:ok, digest} = Encoding.unb64(entry.webauthn["challenge"], 32)
      assertion = Sanctum.TestContext.Authenticator.assertion(authenticator, digest)

      assert {:ok, %{state: "confirmed"}} =
               call(ctx, "confirmation", "confirm", %{"ref" => ref, "assertion" => assertion})

      assert {:ok, %{client_id: client_id, standing: standing}} =
               call(%{ctx | confirmation_id: id}, "pairing", "revoke", %{
                 "client_id" => device.client_id
               })

      assert client_id == device.client_id
      assert standing == "revoked"

      # Committed: read back from the store.
      assert {:ok, %{clients: clients}} = call(ctx, "pairing", "list", %{})
      refute Enum.any?(clients, &(&1.client_id == device.client_id))
    end

    test "an ordinary confirmation beside it is neither read, proven, cancelled nor spent",
         %{session_ctx: ctx, authenticator: authenticator, device: device, monitor: pid} do
      key = device_key!()

      assert {:error, {:confirmation_required, %{id: ordinary_id}}} =
               call(ctx, "pairing", "begin", %{"key_digest" => key.digest})

      ordinary = Prima.Confirmation.ref(ordinary_id)

      {:ok, %{confirmations: [listed]}} =
        call(ctx, "confirmation", "pending", %{"request" => ordinary})

      {:ok, digest} = Encoding.unb64(listed.webauthn["challenge"], 32)
      assertion = Sanctum.TestContext.Authenticator.assertion(authenticator, digest)

      Disk.set_free(@bytes - 1)
      assert Cyfr.StorageReserve.poll(pid) == :depleted

      assert {:error, {:confirmation_required, %{id: flagged_id}}} =
               call(ctx, "pairing", "revoke", %{"client_id" => device.client_id})

      flagged = Prima.Confirmation.ref(flagged_id)

      # The list answers the flagged request's record alone; the ordinary
      # one is never in it, nor read by its ref.
      assert {:ok, %{confirmations: [%{ref: ^flagged}]}} =
               call(ctx, "confirmation", "pending", %{})

      assert reserve_refusal?(call(ctx, "confirmation", "pending", %{"request" => ordinary}))

      assert reserve_refusal?(
               call(ctx, "confirmation", "confirm", %{"ref" => ordinary, "assertion" => assertion})
             )

      assert reserve_refusal?(
               call(ctx, "confirmation", "reauth", %{"ref" => ordinary, "method" => "email"})
             )

      assert reserve_refusal?(call(ctx, "confirmation", "cancel", %{"ref" => ordinary}))

      assert reserve_refusal?(
               call(%{ctx | confirmation_id: ordinary_id}, "pairing", "begin", %{
                 "key_digest" => key.digest
               })
             )

      # A ref that names no record is refused alike.
      assert reserve_refusal?(call(ctx, "confirmation", "pending", %{"request" => "cnr_none"}))

      # The flagged request's record alone answers, and the ordinary one
      # still waits, untouched.
      assert {:ok, %{confirmations: [%{ref: ^flagged}]}} =
               call(ctx, "confirmation", "pending", %{"request" => flagged})

      assert {:ok, %{state: "pending"}} =
               Arca.PendingConfirmations.get(Context.actor(ctx), ordinary)

      # Cancelled by its ref, as the flagged request's own closure.
      assert {:ok, %{ref: ^flagged}} = call(ctx, "confirmation", "cancel", %{"ref" => flagged})
    end

    test "a read is admitted and spends no reserve; the decision log and Arca's writes refuse",
         %{session_ctx: ctx, monitor: pid} do
      actor = Context.actor(ctx)
      :ok = Arca.put(actor, ["data", "kept"], "kept")

      Disk.set_free(@bytes - 1)
      assert Cyfr.StorageReserve.poll(pid) == :depleted

      request_id = Prima.UUID7.request_id()
      ctx = %{ctx | request_id: request_id}

      assert {:ok, %{clients: [_device]}} = call(ctx, "pairing", "list", %{})
      assert {:ok, _whoami} = call(ctx, "session", "whoami", %{})

      # Neither admission was written: the log refuses rather than spend.
      assert Arca.Repo.all(
               from(d in Arca.Schemas.DecisionLog, where: d.request_id == ^request_id)
             ) == []

      decision = %Prima.Decision{
        call_id: Sanctum.Decisions.call_id!(nil),
        request_id: request_id,
        user_id: ctx.user_id,
        athanor_id: ctx.athanor_id,
        plane: :external,
        tool: "pairing",
        action: "list",
        inserted_at: DateTime.utc_now(),
        admission: :admitted
      }

      assert {:error, %Arca.DecisionLog.AuditFailure{kind: :storage_reserve, stage: :append}} =
               Arca.DecisionLog.append(Context.actor(ctx), decision)

      # An object of the athanor is refused; a delete still reclaims space.
      assert {:error, {:unavailable, :storage_reserve}} = Arca.put(actor, ["data", "x"], "x")
      assert {:error, {:unavailable, :storage_reserve}} = Arca.append(actor, ["data", "y"], "y")
      assert :ok = Arca.delete(actor, ["data", "kept"])
      assert {:error, :not_found} = Arca.get(actor, ["data", "kept"])
    end

    test "Arca's refusal reaching a surface renders as unavailable, in the table's sentence",
         %{session_ctx: ctx, monitor: pid} do
      Disk.set_free(@bytes - 1)
      assert Cyfr.StorageReserve.poll(pid) == :depleted

      assert {:error, reason} = Arca.put(Context.actor(ctx), ["data", "x"], "x")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert %Prima.Refusal{class: :unavailable, reason: ^reason, message: message} =
                   Sanctum.Refusals.classify(reason)

          assert message =~ "nearly out of storage"
          assert Sanctum.Refusals.render(reason) == message
        end)

      refute log =~ "unexpected"

      # The gate's own refusal is the same row.
      assert {:error, %Prima.Refusal{message: gate_message}} =
               call(ctx, "notes", "keep", %{"name" => "reserve", "content" => "a note"})

      assert gate_message == Sanctum.Refusals.render(reason)
    end

    test "the cell's own claims are written while depleted", %{monitor: pid} do
      Disk.set_free(@bytes - 1)
      assert Cyfr.StorageReserve.poll(pid) == :depleted

      key = "storage-reserve-#{System.unique_integer([:positive])}"
      assert {:ok, _claim} = Arca.JobClaims.claim("bootstrap", key, "storage-reserve", 60_000)
    end
  end

  # ---------------------------------------------------------------------------
  # A person, their session and a paired device
  # ---------------------------------------------------------------------------

  defp call(ctx, tool, action, args),
    do: Sanctum.Gate.call_external(tool, ctx, Map.put(args, "action", action))

  defp seated! do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Users.upsert_from_provider(%{
        id: "github|https://github.com|storage-reserve-#{n}",
        provider: "github",
        email: "storage-reserve#{n}@example.com",
        verified: true
      })

    {:ok, athanor} = Athanors.create_group(user.id, "Storage reserve #{n}")

    built =
      Context.build(
        user_id: user.id,
        email: user.email,
        provider: "github",
        athanor_id: athanor.id,
        permissions: [:*],
        auth_method: :oidc,
        authenticated: true
      )

    {:ok, session} = Sanctum.TestContext.create_session(built)

    {:ok, session_ctx} =
      Sanctum.Caller.establish(session.token, focus: athanor.id, task_supervisor: nil)

    %{user: user, athanor: athanor, session_ctx: session_ctx}
  end

  defp glass, do: Context.build(%{authenticated: false, client_ip: "198.51.100.45"})

  defp device_key! do
    {device_key, private} = :crypto.generate_key(:eddsa, :ed25519)
    %{public: device_key, private: private, digest: Prima.Device.key_digest(device_key)}
  end

  defp pair!(session_ctx) do
    key = device_key!()

    {:ok, %{invitation_secret: secret}} =
      Sanctum.TestContext.confirming(
        session_ctx,
        &call(&1, "pairing", "begin", %{"key_digest" => key.digest})
      )

    submission = %{
      "invitation_secret" => secret,
      "device_key" => Encoding.b64(key.public),
      "key_digest" => key.digest
    }

    {:ok, %{challenge: challenge}} = call(glass(), "pairing", "complete", submission)
    {:ok, challenge} = Challenge.decode(challenge)
    proof = Proof.encode(Proof.sign(challenge, key.private))

    {:ok, %{client_id: client_id, certificate: certificate}} =
      call(glass(), "pairing", "complete", Map.put(submission, "proof", proof))

    {:ok, certificate} = DeviceCert.decode(certificate)
    %{client_id: client_id, certificate: certificate, key: key}
  end
end
