# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.ReleaseChannel do
  @moduledoc """
  Whether the release channel `cyfr update` reads lists a release newer
  than this one (`update_available/0`).

  The channel is the CYFR repository's releases on GitHub, read through
  the control plane's pinned transport (`Sanctum.Egress`) with a bounded
  answer. The newest release is chosen by the CLI's rule
  (`apps/codex/internal/release`, `newest/1`): the greatest by SemVer
  precedence of the releases that are not pre-releases and, while none is
  listed, of the pre-releases, a pre-release being one GitHub marks as such
  or whose tag carries one; drafts and tags outside the release-version
  grammar (`version?/1`) are skipped. An update is available when it is
  strictly higher than `Prima.Version.current/0` and both are release
  versions (`newer?/2`), so a listing with no release, or a build that is
  none, is told of no update. `tests/fixtures/release_manifest.json`'s
  `versions` hold the grammar and the precedence to the CLI's, and its
  `selection` the choice.

  The channel is read only when asked: at most once a day, and after a
  failed read no sooner than an hour later, keeping the last answer. A
  read runs beside the process, so `update_available/0` answers at once
  with the last answer, nil before a read has succeeded, and a stale
  answer only asks for a read.

  The listing is read a page at a time, from page 1, 100 releases a page,
  until a page holds fewer, at most 10 pages, as the CLI reads it, so a
  release past the first page still counts.

  Options: `:name`; `:fetch`, the read of one page, a function of the page
  number answering as `Sanctum.Egress.pinned_request/5` does, or `false` for an instance that
  never reads (`:release_channel_enabled` false: the suite's, and a
  server's whose `CYFR_NO_UPDATE_CHECK` holds a value, as the terminal's
  check is off then, `Cyfr.RuntimeConfig.release_check?/1`); and `:clock`,
  the monotonic milliseconds its intervals are measured on.
  """

  use GenServer

  require Logger

  @url "https://api.github.com/repos/cyfrworks/cyfr/releases"
  @per_page 100
  @max_pages 10

  # A page of releases with their assets and notes, with room to spare.
  @max_response_bytes 8 * 1024 * 1024
  @receive_timeout_ms 10_000

  @fresh_ms :timer.hours(24)
  @retry_ms :timer.hours(1)

  # The CLI's versionPattern, anchored at both ends of the input.
  @version ~r/\A(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(\.(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*)?\z/

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Whether a release newer than this one is listed: the last answer, nil
  before the channel has been read. Never waits for a read; a stale
  answer asks the process for one.
  """
  @spec update_available(GenServer.server()) :: boolean() | nil
  def update_available(server \\ __MODULE__) do
    GenServer.call(server, :update_available)
  catch
    :exit, _not_running -> nil
  end

  @doc "Whether `version` is a release version as its tag names it (the CLI's `IsVersion`)."
  @spec version?(term()) :: boolean()
  def version?(version) when is_binary(version), do: Regex.match?(@version, version)
  def version?(_version), do: false

  @doc """
  The newest release of a listing as the GitHub releases API answers it
  (the CLI's `Latest`), or nil when none is left.
  """
  @spec newest(list()) :: String.t() | nil
  def newest(releases) when is_list(releases) do
    {prereleases, releases} =
      releases
      |> Enum.flat_map(fn
        %{"tag_name" => tag} = release ->
          if release["draft"] == true or not version?(tag),
            do: [],
            else: [{release["prerelease"] == true or String.contains?(tag, "-"), tag}]

        _other ->
          []
      end)
      |> Enum.split_with(fn {prerelease?, _tag} -> prerelease? end)

    greatest(releases) || greatest(prereleases)
  end

  defp greatest(tagged) do
    tagged
    |> Enum.map(fn {_prerelease?, tag} -> tag end)
    |> Enum.max(&(Version.compare(&1, &2) != :lt), fn -> nil end)
  end

  @doc """
  Whether `latest` is a release version of strictly higher precedence
  than `current` (the CLI's `IsNewer`); false when either is no release
  version.
  """
  @spec newer?(term(), term()) :: boolean()
  def newer?(latest, current) do
    version?(latest) and version?(current) and Version.compare(latest, current) == :gt
  end

  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    # The read is the channel's own: linked to it, so the channel's death
    # takes the read with it, and ended in `terminate/2` when it stops.
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       fetch: Keyword.get(opts, :fetch, &fetch/1),
       clock: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end),
       answer: nil,
       read_at: nil,
       failed_at: nil,
       reading: nil
     }}
  end

  @impl true
  def handle_call(:update_available, _from, state),
    do: {:reply, state.answer, maybe_read(state)}

  @impl true
  def handle_info({tag, answer}, %{reading: {tag, _reader}} = state) do
    now = state.clock.()

    case answer do
      {:ok, newer?} ->
        {:noreply, %{state | reading: nil, answer: newer?, read_at: now, failed_at: nil}}

      {:error, why} ->
        Logger.info("[Cyfr.ReleaseChannel] the release channel was not read: #{inspect(why)}")
        {:noreply, %{state | reading: nil, failed_at: now}}
    end
  end

  # A read's own exit: after its answer, nothing more; before one, a
  # failure.
  def handle_info({:EXIT, reader, _reason}, %{reading: {_tag, reader}} = state) do
    Logger.info("[Cyfr.ReleaseChannel] the release channel's read ended without an answer")
    {:noreply, %{state | reading: nil, failed_at: state.clock.()}}
  end

  def handle_info({:EXIT, _reader, _reason}, state), do: {:noreply, state}

  def handle_info(msg, state) do
    Prima.LoggerContext.unexpected(__MODULE__, msg)
    {:noreply, state}
  end

  defp maybe_read(%{fetch: false} = state), do: state
  defp maybe_read(%{reading: {_tag, _reader}} = state), do: state

  defp maybe_read(state) do
    now = state.clock.()

    if within?(state.read_at, now, @fresh_ms) or within?(state.failed_at, now, @retry_ms) do
      state
    else
      fetch = state.fetch
      channel = self()
      tag = make_ref()
      # The read's answer comes as a message, and its exit tells of a read
      # that ended without one.
      reader = spawn_link(fn -> send(channel, {tag, answer(listing(fetch))}) end)
      %{state | reading: {tag, reader}}
    end
  end

  @impl true
  def terminate(_reason, %{reading: {_tag, reader}}) do
    Process.exit(reader, :kill)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp within?(nil, _now, _ms), do: false
  defp within?(at, now, ms), do: now - at < ms

  @doc """
  The listing as `fetch` reads it page by page, from page 1 until a page
  holds fewer than #{@per_page} releases or #{@max_pages} pages are read:
  `{:ok, releases}`, or the first failure of a page, its reason a class.
  """
  @spec listing((pos_integer() -> term())) :: {:ok, list()} | {:error, term()}
  def listing(fetch), do: read(fetch, 1, [])

  defp read(fetch, page, releases) do
    case listed(fetch.(page)) do
      {:ok, listed} when length(listed) < @per_page or page >= @max_pages ->
        {:ok, releases ++ listed}

      {:ok, listed} ->
        read(fetch, page + 1, releases ++ listed)

      {:error, _why} = failure ->
        failure
    end
  end

  defp fetch(page) do
    Sanctum.Egress.pinned_request(
      :get,
      "#{@url}?per_page=#{@per_page}&page=#{page}",
      [
        {"accept", "application/vnd.github+json"},
        {"user-agent", "cyfr/" <> Prima.Version.current()}
      ],
      nil,
      receive_timeout: @receive_timeout_ms,
      max_response_bytes: @max_response_bytes
    )
  end

  # One page's answer, its reason reduced to a class: a body is never
  # carried into the log.
  defp listed({:ok, 200, _headers, body}) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, releases} when is_list(releases) -> {:ok, releases}
      _malformed -> {:error, :malformed}
    end
  end

  defp listed({:ok, status, _headers, _body}) when is_integer(status),
    do: {:error, {:status, status}}

  defp listed(_unreachable), do: {:error, :unreachable}

  # The read's answer: whether its newest release is newer than this one.
  defp answer({:ok, releases}), do: {:ok, newer?(newest(releases), Prima.Version.current())}
  defp answer({:error, _why} = failure), do: failure
end
