# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Intents do
  @moduledoc """
  Navigation and UI intents — what an agent may ask the browser to do —
  and the routes they may name. The web adapter maps an intent to a
  page; the intent itself names no estate, the athanor in focus is added
  when it is pushed.

  `ui.navigate` paths are validated against the console GET routes the
  router declares — derived, never mirrored. A detail route (one with a
  parameter) and a redirect stub are left out by rule, and the list is
  not configurable. Resource-focus intents compute their target paths.
  """

  @allowed_overlay_states ~w(half full)

  # One optional colon: an external MCP server's tool is proposed as

  # `server:tool` — the shape `kind_for/2`'s `:external` branch and the

  # approval card already speak, but which this regex silently refused, so

  # the card never appeared for a policy that asked for one. Anchored

  # `\A…\z`, not `^…$` — `$` matches before a trailing newline.

  @id_re ~r/\A[\w.\-]+(:[\w.\-]+)?\z/

  # A generous ceiling for a pasted code block, and a bound on what a model

  # can push through the LiveView channel into a browser in one action.

  @max_clipboard_bytes 100_000

  def validate(%{"kind" => "ui.navigate"} = obj) do
    with {:ok, path} <- string_field(obj, "path"),
         :ok <- check_allowed_path(path) do
      {:ok, %{kind: "navigate", to: path}}
    end
  end

  def validate(%{"kind" => "ui.overlay.open"} = obj) do
    case Map.get(obj, "state") do
      nil ->
        {:ok, %{kind: "overlay_open"}}

      state when is_binary(state) ->
        if state in @allowed_overlay_states do
          {:ok, %{kind: "overlay_open", state: state}}
        else
          {:error, "ui.overlay.open: state must be \"half\" or \"full\", got #{inspect(state)}"}
        end

      other ->
        {:error, "ui.overlay.open: state must be a string, got #{inspect(other)}"}
    end
  end

  def validate(%{"kind" => "ui.overlay.close"} = _obj), do: {:ok, %{kind: "overlay_close"}}

  def validate(%{"kind" => "ui.overlay.focus_input"} = _obj),
    do: {:ok, %{kind: "overlay_focus_input"}}

  def validate(%{"kind" => "ui.copy_clipboard"} = obj) do
    case Map.get(obj, "text") do
      text when is_binary(text) ->
        if byte_size(text) > @max_clipboard_bytes do
          {:error,
           "ui.copy_clipboard: 'text' exceeds #{@max_clipboard_bytes} bytes " <>
             "(got #{byte_size(text)})"}
        else
          {:ok, %{kind: "copy_clipboard", text: sanitize_clipboard(text)}}
        end

      _ ->
        {:error, "ui.copy_clipboard: requires string 'text'"}
    end
  end

  def validate(%{"kind" => "ui.activity.focus"} = obj),
    do: focus_intent(obj, "id", "req_", &"/activities?id=#{&1}")

  def validate(%{"kind" => "ui.execution.focus"} = obj),
    do: focus_intent(obj, "id", "exec_", &"/executions?id=#{&1}")

  def validate(%{"kind" => "ui.schedule.focus"} = obj),
    do: focus_intent(obj, "id", "sched_", &"/schedules?id=#{&1}")

  def validate(%{"kind" => "ui.component.focus"} = obj) do
    with {:ok, ref} <- string_field(obj, "ref"),
         :ok <- component_focus_ref(ref) do
      {:ok, %{kind: "navigate", to: "/components/#{URI.encode(ref, &URI.char_unreserved?/1)}"}}
    end
  end

  def validate(%{"kind" => "ui.tincture.focus"} = obj) do
    with {:ok, publisher} <- string_field(obj, "publisher"),
         {:ok, name} <- string_field(obj, "name"),
         :ok <- check_id_shape(publisher, "ui.tincture.focus", "publisher"),
         :ok <- check_id_shape(name, "ui.tincture.focus", "name") do
      path =
        "/tinctures?publisher=#{URI.encode_www_form(publisher)}" <>
          "&tincture_name=#{URI.encode_www_form(name)}"

      {:ok, %{kind: "navigate", to: path}}
    end
  end

  def validate(%{"kind" => "ui.mcp_server.focus"} = obj) do
    with {:ok, name} <- string_field(obj, "name") do
      {:ok, %{kind: "navigate", to: "/mcp-servers?name=#{URI.encode_www_form(name)}"}}
    end
  end

  def validate(%{"kind" => kind}), do: {:error, "unknown kind: #{inspect(kind)}"}

  defp focus_intent(obj, key, prefix, path_fn) do
    with {:ok, id} <- string_field(obj, key),
         :ok <- check_id_shape(id, "focus", key),
         :ok <- check_prefix(id, prefix, key) do
      {:ok, %{kind: "navigate", to: path_fn.(id)}}
    end
  end

  @doc false
  def string_field(obj, key) do
    case Map.get(obj, key) do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:error, "requires non-empty string '#{key}'"}
    end
  end

  defp check_allowed_path(path) do
    routes = allowed_routes()

    cond do
      path in routes -> :ok
      matches_query_form?(path, routes) -> :ok
      true -> {:error, "ui.navigate: path #{inspect(path)} not in allowlist"}
    end
  end

  defp matches_query_form?(path, routes) do
    case String.split(path, "?", parts: 2) do
      [base, _query] -> base in routes
      _ -> false
    end
  end

  # The Prism page paths — the router's routes under `/a/:athanor/…` with

  # the focus prefix stripped (an intent addresses a page; the athanor in

  # focus is added when it is pushed), plus the global pages, which have no

  # estate in their address and are pushed as they are. A route with a

  # parameter left in it is a record's, not a page's, and a redirect stub

  # is not a page at all. Memoized, since the router's route table is

  # fixed for the VM lifetime.

  @focus_prefix "/a/:athanor"

  @doc false

  @spec allowed_routes() :: [String.t()]

  def allowed_routes do
    case :persistent_term.get({Aqua.Intents, :allowed_routes}, :miss) do
      :miss ->
        routes =
          EmissaryWeb.Router.__routes__()
          |> Enum.filter(
            &(&1.verb == :get and String.starts_with?(&1.path, @focus_prefix <> "/") and
                not redirect_stub?(&1))
          )
          |> Enum.map(&String.replace_prefix(&1.path, @focus_prefix, ""))
          |> Enum.reject(&String.contains?(&1, ":"))
          |> Kernel.++(Cyfr.GlobalPages.paths())
          |> Enum.uniq()

        :persistent_term.put({Aqua.Intents, :allowed_routes}, routes)
        routes

      routes ->
        routes
    end
  end

  # A LiveView named `…RedirectLive` only forwards to another address: a

  # navigate to it would land the browser somewhere the agent did not

  # name, so the stub is not a target — the page it forwards to is.

  defp redirect_stub?(%{metadata: %{phoenix_live_view: live}}) when is_tuple(live) do
    live |> elem(0) |> Atom.to_string() |> String.ends_with?("RedirectLive")
  end

  defp redirect_stub?(_route), do: false

  # The clipboard is the one action whose output leaves the browser: whatever

  # lands there can be pasted anywhere, and a terminal treats a carriage

  # return or a trailing newline as Enter — so model-written text ending in

  # one runs on paste without a second keystroke. Newlines and tabs inside

  # the text stay (a pasted code block needs them); what goes is every other

  # C0 control character, and any run of them at the end.

  defp sanitize_clipboard(text) do
    text
    |> String.replace(~r/[\x00-\x08\x0B-\x1F\x7F]/, "")
    |> String.trim_trailing("\n")
  end

  # A full component ref (`type:ns.name:version` — the grammar the prompt

  # teaches, validated by its owner) or a bare dotted name. The generic

  # id-shape regex alone refused `:`, so every full ref was silently

  # dropped.

  defp component_focus_ref(ref) do
    case Sanctum.ComponentRef.parse(ref) do
      {:ok, _} -> :ok
      {:error, _} -> check_id_shape(ref, "ui.component.focus", "ref")
    end
  end

  @doc false
  def check_id_shape(value, kind, key) do
    if Regex.match?(@id_re, value) do
      :ok
    else
      {:error, "#{kind}: #{key} #{inspect(value)} contains disallowed characters"}
    end
  end

  defp check_prefix(value, prefix, key) do
    if String.starts_with?(value, prefix) do
      :ok
    else
      {:error, "focus.#{key} #{inspect(value)} must start with #{prefix}"}
    end
  end
end
