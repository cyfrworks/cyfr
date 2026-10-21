# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.ScrubSpanCredentials do
  @moduledoc """
  The traces exporter that redacts tincture credentials from every span
  before the exporter it wraps sends it.

  An instrumentation names a request by its raw path before any plug runs:
  `OpentelemetryBandit` reads Bandit's request-start connection, so
  `CyfrWeb.Plugs.ScrubTinctureCredentials` has not redacted it yet. The
  rewrite therefore sits at the export boundary, where every span passes
  whatever produced it and whenever its attributes were set. A span
  processor cannot do it: the SDK hands each processor the same ended span
  and takes back only a boolean, so a rewrite never reaches the processor
  that exports.

  Configured as `{CyfrWeb.ScrubSpanCredentials, inner}`, where `inner` is
  the exporter that sends (`{:opentelemetry_exporter, opts}` in a release).
  `inner` is handed a private copy of each batch, never the SDK's own
  table, in which each attribute that names the request's path or query
  is rewritten:

    * a path (`url.path`, `http.route`) through
      `CyfrWeb.Plugs.ScrubTinctureCredentials.redact_path/1`, the one
      definition of where a credential stands in a path;
    * a query (`url.query`) pair by pair, each value whose key the
      redaction roster names (`Prima.Sanitizer.sensitive_key?/1`, which
      holds the tincture credential query keys) replaced by `[REDACTED]`.

  These are the attributes the installed instrumentation names a request
  by (`OpentelemetryBandit`, `OpentelemetryPhoenix`).

  Every other attribute, and an attribute already free of a credential,
  is exported as it was recorded. A batch that cannot be rewritten is
  dropped, never sent as recorded.
  """

  @behaviour :otel_exporter_traces

  require Record

  Record.defrecordp(
    :span,
    Record.extract(:span,
      from: Path.join(Mix.Project.deps_path(), "opentelemetry/include/otel_span.hrl")
    )
  )

  @redacted "[REDACTED]"

  @path_keys ["url.path", "http.route"]
  @query_keys ["url.query"]

  @impl true
  def init(inner) do
    case :otel_exporter.init(inner) do
      exporter when exporter in [:undefined, :none] -> :ignore
      exporter -> {:ok, exporter}
    end
  end

  @impl true
  def export(spans_tab, resource, exporter) do
    case scrubbed_snapshot(spans_tab) do
      {:ok, snapshot} ->
        try do
          :otel_exporter_traces.export(exporter, snapshot, resource)
        after
          :ets.delete(snapshot)
        end

      :error ->
        :failed_not_retryable
    end
  end

  @impl true
  def shutdown(exporter), do: :otel_exporter.shutdown(exporter)

  # `inner` sees a private table holding the batch's spans rewritten, never
  # the SDK's: that table is public, and while the SDK stops it is still
  # the one ending spans are inserted into, so a span ending after the
  # rewrite would reach `inner` as recorded. The copy has the batch table's
  # type and key, which an exporter may read it by. A failure exports
  # nothing: the SDK logs an exporter's exception with its stack, which
  # could carry a span as recorded, so nothing raises from here.
  defp scrubbed_snapshot(tab) do
    snapshot =
      :ets.new(__MODULE__, [
        :ets.info(tab, :type),
        :private,
        keypos: :ets.info(tab, :keypos)
      ])

    try do
      :ets.insert(snapshot, tab |> :ets.tab2list() |> Enum.map(&scrub_span/1))
      {:ok, snapshot}
    catch
      _kind, _reason ->
        :ets.delete(snapshot)
        :error
    end
  catch
    _kind, _reason -> :error
  end

  @doc """
  The span with every path- and query-bearing attribute redacted; any
  other term unchanged.
  """
  @spec scrub_span(term()) :: term()
  def scrub_span(span(attributes: attributes) = record) when attributes != :undefined do
    redacted =
      attributes
      |> :otel_attributes.map()
      |> Enum.flat_map(fn {key, value} ->
        case scrub(key, value) do
          ^value -> []
          new -> [{key, new}]
        end
      end)
      |> Map.new()

    if redacted == %{},
      do: record,
      else: span(record, attributes: :otel_attributes.set(redacted, attributes))
  end

  def scrub_span(other), do: other

  @doc """
  An attribute's value with the credential its key can carry redacted, by
  the attribute's key (an atom or a string).
  """
  @spec scrub(term(), term()) :: term()
  def scrub(key, value) when is_atom(key), do: scrub(Atom.to_string(key), value)

  def scrub(key, value) when is_binary(key) and is_binary(value) do
    cond do
      key in @path_keys -> redact_path(value)
      key in @query_keys -> redact_query(value)
      true -> value
    end
  end

  def scrub(_key, value), do: value

  defp redact_path(path), do: CyfrWeb.Plugs.ScrubTinctureCredentials.redact_path(path)

  # Pair by pair, so a pair the roster passes is written back byte for
  # byte. A key is compared decoded, as the parameters it names are.
  defp redact_query(query) do
    query
    |> String.split("&")
    |> Enum.map_join("&", &redact_pair/1)
  end

  defp redact_pair(pair) do
    case String.split(pair, "=", parts: 2) do
      [key, _value] ->
        if Prima.Sanitizer.sensitive_key?(decoded(key)), do: key <> "=" <> @redacted, else: pair

      [_key] ->
        pair
    end
  end

  defp decoded(text) do
    URI.decode_www_form(text)
  rescue
    ArgumentError -> text
  end
end
