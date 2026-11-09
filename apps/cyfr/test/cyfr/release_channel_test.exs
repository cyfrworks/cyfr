# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.ReleaseChannelTest do
  @moduledoc """
  The release channel `cyfr update` reads, as the status a canvas reads
  asks it: the CLI's version grammar and precedence, held to
  tests/fixtures/release_manifest.json's `versions`; the CLI's choice of
  the newest release over listings with drafts, pre-releases and
  malformed tags; and the process, on a read and a clock of the test's
  own, which serves its answer without waiting, reads a stale one once in
  the background, keeps the last answer through a failure and tries again
  no sooner than an hour later. Nothing here reaches GitHub.
  """

  use ExUnit.Case, async: true

  import Prima.Test.Wait

  alias Cyfr.ReleaseChannel

  @versions Path.expand("../../../../tests/fixtures/release_manifest.json", __DIR__)
            |> File.read!()
            |> Jason.decode!()
            |> Map.fetch!("versions")

  @day :timer.hours(24)
  @hour :timer.hours(1)

  describe "the version grammar and precedence" do
    test "accept every accepted version and refuse every refused one" do
      for version <- @versions["accepted"], do: assert(ReleaseChannel.version?(version), version)

      for version <- @versions["refused"],
          do: refute(ReleaseChannel.version?(version), inspect(version))

      refute ReleaseChannel.version?(nil)
      refute ReleaseChannel.version?(123)
    end

    test "order the ascending versions, each strictly newer than every one before it" do
      ascending = @versions["ascending"]

      for {older, i} <- Enum.with_index(ascending),
          {newer, j} <- Enum.with_index(ascending),
          i < j do
        assert ReleaseChannel.newer?(newer, older), "#{newer} is newer than #{older}"
        refute ReleaseChannel.newer?(older, newer), "#{older} is not newer than #{newer}"
      end

      for version <- ascending, do: refute(ReleaseChannel.newer?(version, version))
    end

    test "tell no update when either side is no release version" do
      refute ReleaseChannel.newer?("1.0.0", "dev")
      refute ReleaseChannel.newer?("v2.0.0", "1.0.0")
      refute ReleaseChannel.newer?(nil, "1.0.0")
    end
  end

  describe "the newest release of a listing" do
    test "is the greatest by precedence, whatever order the listing is in" do
      releases =
        for tag <- Enum.shuffle(@versions["ascending"]),
            do: %{"tag_name" => tag, "draft" => false, "prerelease" => false}

      assert ReleaseChannel.newest(releases) == "99999999999999.0.0"
    end

    test "skips drafts, GitHub pre-releases, tags outside the grammar and tags with a pre-release" do
      releases = [
        %{"tag_name" => "9.0.0", "draft" => true, "prerelease" => false},
        %{"tag_name" => "8.0.0", "draft" => false, "prerelease" => true},
        %{"tag_name" => "v7.0.0", "draft" => false, "prerelease" => false},
        %{"tag_name" => "6.0.0-rc.1", "draft" => false, "prerelease" => false},
        %{"tag_name" => 5, "draft" => false},
        %{"name" => "4.0.0"},
        "3.0.0",
        %{"tag_name" => "1.2.3"},
        %{"tag_name" => "1.10.0", "draft" => false, "prerelease" => false},
        %{"tag_name" => "1.9.9", "draft" => false, "prerelease" => false}
      ]

      assert ReleaseChannel.newest(releases) == "1.10.0"
    end

    test "is none when nothing is left" do
      assert ReleaseChannel.newest([]) == nil

      assert ReleaseChannel.newest([
               %{"tag_name" => "0.6.0-alpha.13", "draft" => false, "prerelease" => true}
             ]) == nil
    end
  end

  describe "the process" do
    setup do
      clock = start_supervised!({Agent, fn -> 0 end})
      test = self()

      # A read that tells the test it began and answers what the test hands it.
      fetch = fn ->
        send(test, {:fetched, self()})

        receive do
          {:answer, answer} -> answer
        end
      end

      channel =
        start_supervised!(
          {ReleaseChannel, name: nil, fetch: fetch, clock: fn -> Agent.get(clock, & &1) end}
        )

      {:ok, channel: channel, clock: clock}
    end

    test "serves nil at once before the first read, and reads once however often it is asked", %{
      channel: channel
    } do
      assert ReleaseChannel.update_available(channel) == nil
      assert_receive {:fetched, read}
      # Asked again while the read waits: the same nil, and no second read.
      assert ReleaseChannel.update_available(channel) == nil
      assert ReleaseChannel.update_available(channel) == nil
      refute_received {:fetched, _}

      send(read, {:answer, listing(["99999.0.0"])})
      answered(channel, true)
    end

    test "serves a fresh answer without a read, and reads a stale one once in the background", %{
      channel: channel,
      clock: clock
    } do
      read!(channel, listing(["99999.0.0"]))
      answered(channel, true)

      Agent.update(clock, &(&1 + @day - 1))
      assert ReleaseChannel.update_available(channel) == true
      refute_received {:fetched, _}

      # A day on, the answer is stale: it is served while the read runs.
      Agent.update(clock, &(&1 + 1))
      assert ReleaseChannel.update_available(channel) == true
      assert_receive {:fetched, read}
      assert ReleaseChannel.update_available(channel) == true
      refute_received {:fetched, _}

      send(read, {:answer, listing(["0.0.1"])})
      answered(channel, false)
    end

    test "keeps the last answer through a failed read, and tries again an hour later", %{
      channel: channel,
      clock: clock
    } do
      read!(channel, listing(["99999.0.0"]))
      answered(channel, true)

      for failure <- [
            {:ok, 403, [], "rate limited"},
            {:ok, 200, [], "not json"},
            {:ok, 200, [], "{}"},
            {:error, %{reason: :timeout}}
          ] do
        Agent.update(clock, &(&1 + @day))
        assert ReleaseChannel.update_available(channel) == true
        assert_receive {:fetched, read}
        send(read, {:answer, failure})
        read_ended(channel)
        assert ReleaseChannel.update_available(channel) == true

        # Within the hour after the failure, nothing is read.
        Agent.update(clock, &(&1 + @hour - 1))
        assert ReleaseChannel.update_available(channel) == true
        refute_received {:fetched, _}
      end

      Agent.update(clock, &(&1 + 1))
      assert ReleaseChannel.update_available(channel) == true
      assert_receive {:fetched, read}
      send(read, {:answer, listing(["0.0.1"])})
      answered(channel, false)
    end

    test "a read that ends without an answer is a failure, and the process goes on", %{
      channel: channel
    } do
      assert ReleaseChannel.update_available(channel) == nil
      assert_receive {:fetched, read}
      Process.exit(read, :kill)
      read_ended(channel)
      assert ReleaseChannel.update_available(channel) == nil
      refute_received {:fetched, _}
    end
  end

  test "an instance that never reads answers nil, and so does one that is not running" do
    channel = start_supervised!({ReleaseChannel, name: nil, fetch: false})
    assert ReleaseChannel.update_available(channel) == nil
    assert :sys.get_state(channel).reading == nil

    # The application's own instance in the suite never reads.
    assert ReleaseChannel.update_available() == nil
    assert ReleaseChannel.update_available(:no_such_channel) == nil
  end

  defp listing(tags) do
    body =
      Jason.encode!(
        for tag <- tags, do: %{"tag_name" => tag, "draft" => false, "prerelease" => false}
      )

    {:ok, 200, [{"content-type", "application/json"}], body}
  end

  defp read!(channel, answer) do
    assert ReleaseChannel.update_available(channel) == nil
    assert_receive {:fetched, read}
    send(read, {:answer, answer})
  end

  # The process has taken in its read's end, whatever it was.
  defp read_ended(channel),
    do: wait_until(fn -> :sys.get_state(channel).reading == nil end, 5_000, "the read to end")

  defp answered(channel, answer) do
    wait_until(
      fn -> ReleaseChannel.update_available(channel) == answer end,
      5_000,
      "the channel to answer #{answer}"
    )
  end
end
