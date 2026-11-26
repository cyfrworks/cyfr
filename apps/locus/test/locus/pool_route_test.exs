# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.PoolRouteTest do
  @moduledoc """
  The pool wire's route (`Locus.PoolRoute`) on each of the three services
  that mount it, the runtime's worker listener, the builds service and the
  backends service: each serves its role's report, asked of its own
  keeper, under the pool key derived from its own key, refuses a header
  signed with another service's pool key even where all three were given
  the same key, refuses in its own convention, and logs no key and nothing
  derived from one.
  """

  # The builds key and the runtime's credentials are the node's own,
  # shared by every test: this module sets them, and puts them back.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  alias Locus.Backends.Service
  alias Locus.BuilderService
  alias Locus.Runtime.WorkerListener
  alias Prima.LocusPool

  # One 32-byte key for all three services, as an operator might give it.
  @key :binary.list_to_bin(Enum.to_list(1..32))
  @owners __MODULE__.Owners

  # A role's keeper as the route asks it: a report per `after`, the rev
  # each ask named, and the backends service's boot, which every one of
  # its answers carries.
  defmodule Keeper do
    @moduledoc false
    use GenServer

    def start_link(opts),
      do: GenServer.start_link(__MODULE__, opts[:answer], Keyword.take(opts, [:name]))

    def asked(keeper), do: GenServer.call(keeper, :asked)

    @impl true
    def init(answer), do: {:ok, %{answer: answer, asked: []}}

    @impl true
    def handle_call(:boot, _from, state), do: {:reply, "bt_test", state}
    def handle_call(:asked, _from, state), do: {:reply, Enum.reverse(state.asked), state}

    def handle_call({:report, after_rev}, _from, state),
      do: {:reply, state.answer, %{state | asked: [after_rev | state.asked]}}
  end

  defp report(kind, subject) do
    %{
      boot: "0123456789abcdef0123456789abcdef",
      budget: 6_174_015_488,
      work: 5_066_719_232,
      floor: 171_966_464,
      used: 268_435_456,
      next: nil,
      counters: [
        %{
          rev: 5,
          day: ~D[2026-11-27],
          athanor: "ath_one",
          kind: kind,
          subject: subject,
          bytes: 268_435_456,
          mib_ms: 512_000,
          measured_ms: 2_000,
          peak_bytes: 268_435_456,
          cap: 0,
          machine: 0,
          either: 0
        }
      ]
    }
  end

  @reports %{
    runtime: {"run", nil},
    builds: {"build", nil},
    backends: {"program", "mcp_one"}
  }

  setup do
    builds_key = Application.fetch_env(:locus, :request_key)
    credentials = Locus.Runtime.Credentials.current()

    on_exit(fn ->
      case builds_key do
        {:ok, key} -> Application.put_env(:locus, :request_key, key)
        :error -> Application.delete_env(:locus, :request_key)
      end

      if credentials,
        do: Locus.Runtime.Credentials.install(credentials),
        else: :persistent_term.erase({Locus.Runtime.Credentials, :current})
    end)

    Application.put_env(:locus, :request_key, @key)

    Locus.Runtime.Credentials.install(%Locus.Runtime.Credentials{
      service_id: "wrk_pool",
      worker_key: @key,
      dispatch_key: Prima.WorkerAuth.dispatch_key(@key),
      dispatch_seal_key: Prima.WorkerAuth.dispatch_seal_key(@key),
      host_url: "http://127.0.0.1:1",
      bind: {127, 0, 0, 1},
      port: 0
    })

    keepers =
      Map.new(@reports, fn {service, {kind, subject}} ->
        {service,
         start_supervised!({Keeper, answer: {:ok, report(kind, subject)}},
           id: {:keeper, service}
         )}
      end)

    # The backends service's owners, which every one of its answers asks
    # for its boot.
    start_supervised!({Keeper, answer: {:ok, nil}, name: @owners}, id: :owners)

    {:ok, keepers: keepers}
  end

  # Post `body` to `service`'s pool route under `header` (signed with
  # `service`'s own pool key at now unless given), asking `keeper`.
  defp post(service, keeper, body, opts \\ []) do
    ts = Keyword.get(opts, :ts, System.system_time(:millisecond))
    signer = Keyword.get(opts, :signer, service)

    header =
      Keyword.get_lazy(opts, :header, fn ->
        LocusPool.header(signer, LocusPool.pool_key(signer, @key), ts, body)
      end)

    conn =
      :post
      |> conn(LocusPool.route(), body)
      |> put_req_header("content-type", "application/json")
      |> then(&if(header, do: put_req_header(&1, "x-cyfr-auth", header), else: &1))

    conn = listener(service).call(conn, listener(service).init(opts(service, keeper)))
    {conn.status, conn.resp_body}
  end

  defp listener(:runtime), do: WorkerListener
  defp listener(:builds), do: BuilderService
  defp listener(:backends), do: Service

  defp opts(:backends, keeper), do: [keeper: keeper, owners: @owners, key: @key]
  defp opts(_service, keeper), do: [keeper: keeper]

  # What each listener answers for a refused header, in its own words.
  defp unauthorized?(:runtime, 401, body),
    do: Jason.decode!(body)["error"] in ~w(bad_mac malformed outside_window unknown_version)

  defp unauthorized?(:builds, 401, body), do: builds_refusal(body) == "unauthorized"
  defp unauthorized?(:backends, 401, body), do: Jason.decode!(body)["error"] == "unauthorized"
  defp unauthorized?(_service, _status, _body), do: false

  defp builds_refusal(body), do: body |> String.trim() |> Jason.decode!() |> Map.fetch!("class")

  test "each service answers its role's report, asked of its own keeper after the rev the body names",
       %{keepers: keepers} do
    for {service, keeper} <- keepers do
      {kind, subject} = @reports[service]
      assert {200, body} = post(service, keeper, LocusPool.request_body(41))
      assert LocusPool.read_answer(body) == {:ok, report(kind, subject)}
      assert Keeper.asked(keeper) == [41]
    end
  end

  test "a pool header of one service is refused by the two others, all three given the same key",
       %{keepers: keepers} do
    body = LocusPool.request_body(0)

    for {service, keeper} <- keepers, signer <- LocusPool.services() -- [service] do
      {status, answer} = post(service, keeper, body, signer: signer)
      assert unauthorized?(service, status, answer), "#{signer}'s header at #{service}: #{status}"
      assert Keeper.asked(keeper) == []
    end

    # The service's own key, or a key it signs anything else with, is no pool key.
    for {service, keeper} <- keepers do
      header = LocusPool.header(service, @key, System.system_time(:millisecond), body)
      {status, answer} = post(service, keeper, body, header: header)
      assert unauthorized?(service, status, answer)
    end
  end

  test "a header is refused outside its window, absent, or over another body, before the keeper is asked",
       %{keepers: keepers} do
    body = LocusPool.request_body(0)
    late = System.system_time(:millisecond) - LocusPool.window_ms() - 1_000
    other = LocusPool.request_body(1)

    for {service, keeper} <- keepers do
      for opts <- [
            [ts: late],
            [header: nil],
            [
              header:
                LocusPool.header(
                  service,
                  LocusPool.pool_key(service, @key),
                  late + 1_000_000,
                  other
                )
            ]
          ] do
        {status, answer} = post(service, keeper, body, opts)
        assert unauthorized?(service, status, answer), "#{service} #{inspect(opts)}: #{status}"
      end

      assert Keeper.asked(keeper) == []
    end
  end

  test "a body that does not read, or runs past its bound, is refused in each listener's words",
       %{keepers: keepers} do
    huge = Jason.encode!(%{"v" => 1, "after" => 0, "pad" => String.duplicate("x", 2_000)})

    for {service, keeper} <- keepers do
      for body <- [~s({"v":2,"after":0}), ~s({"v":1,"after":-1}), huge] do
        {status, answer} = post(service, keeper, body)

        case service do
          :runtime ->
            assert {status, Jason.decode!(answer)["error"]} in [
                     {400, "unknown_version"},
                     {400, "malformed"},
                     {413, "malformed"}
                   ]

          :builds ->
            assert {status, builds_refusal(answer)} == {400, "malformed"}

          :backends ->
            assert {status, Jason.decode!(answer)["error"]} in [
                     {400, "bad_request"},
                     {413, "too_large"}
                   ]
        end
      end

      assert Keeper.asked(keeper) == []
    end
  end

  test "a keeper that does not answer, or refuses, is unavailable in each listener's words" do
    for answer <- [{:error, {:refused, "bad_request"}}, :gone], service <- LocusPool.services() do
      keeper =
        case answer do
          :gone -> :no_such_keeper
          refusal -> start_supervised!({Keeper, answer: refusal}, id: {:refusing, service})
        end

      {status, body} = post(service, keeper, LocusPool.request_body(0))
      assert status == 503, "#{service}: #{status} #{body}"

      case service do
        :builds -> assert builds_refusal(body) == "unavailable"
        _ -> assert Jason.decode!(body)["error"] == "unavailable"
      end

      if is_pid(keeper), do: stop_supervised!({:refusing, service})
    end
  end

  test "no log line carries a key, a pool key or a header's MAC", %{keepers: keepers} do
    body = LocusPool.request_body(0)
    ts = System.system_time(:millisecond)

    headers =
      for signer <- LocusPool.services(),
          do: {signer, LocusPool.header(signer, LocusPool.pool_key(signer, @key), ts, body)}

    log =
      capture_log(fn ->
        for {service, keeper} <- keepers, {_signer, header} <- headers do
          post(service, keeper, body, header: header)
          post(service, keeper, ~s({"v":2}), header: header)
          post(service, :no_such_keeper, body, header: header)
        end
      end)

    assert log =~ "refused"

    secrets =
      for service <- LocusPool.services(),
          key <- [@key, LocusPool.pool_key(service, @key)],
          spelled <- [
            Base.encode16(key, case: :lower),
            Base.encode16(key, case: :upper),
            Base.url_encode64(key, padding: false),
            Base.encode64(key)
          ],
          do: spelled

    macs = for {_signer, header} <- headers, do: header |> String.split("mac=") |> List.last()

    for secret <- secrets ++ macs, do: refute(log =~ secret)
  end
end
