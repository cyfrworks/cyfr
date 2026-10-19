# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Mix.Tasks.Cyfr.Gen.ReachRefusals do
  @shortdoc "Render the reach engine's refusal sentences from Prima.Refusal"

  @moduledoc """
  Renders the `refusals` section of `tests/fixtures/reach_modes.json` and
  `apps/codex/internal/reach/refusals_gen.go` from `Prima.Refusal`, the one
  definition of every sentence the reach engine and `cyfr up` print. Each
  code carries its class and its variants: the payload values a variant
  fixes, the payload keys it fills in, its template (the row's sentence
  with each filled key written `{key}`) and an example the Go side renders
  back to the row's own sentence.

      mix cyfr.gen.reach_refusals
      mix cyfr.gen.reach_refusals --check

  `--check` fails when either file is not the render.
  """

  use Boundary, classify_to: Cyfr.Mix

  use Mix.Task

  @fixture "tests/fixtures/reach_modes.json"
  @go "apps/codex/internal/reach/refusals_gen.go"

  # Every code the engine and `cyfr up` render, in the order the plan's
  # refusal table lists them, with its variants: the payload values a
  # variant fixes and the keys it fills in. A filled key's sample is the
  # value the template is rendered with before the sample is replaced by
  # `{key}`; it satisfies the row's guard.
  @rows [
    {:reach_busy,
     [
       {%{}, ~w(holder pid until)},
       {%{}, ~w(holder pid)},
       {%{}, ~w(holder)},
       {%{}, ~w(join_id until)}
     ]},
    {:reach_stale, [{%{}, ~w(words)}]},
    {:reach_unchanged, [{%{}, ~w(address)}]},
    {:reach_invalid,
     for(kind <- ~w(domain tailnet_name email), do: {%{kind: kind}, ~w(input rule)})},
    {:reach_option_outside_mode,
     for(
       option <- ~w(--domain --acme-email),
       mode <- ~w(local tailnet),
       do: {%{option: option, mode: mode}, []}
     )},
    {:reach_request_reused, [{%{}, []}]},
    {:tailnet_not_joined, [{%{}, []}]},
    {:tailnet_https_off, [{%{}, ~w(name)}]},
    {:tailnet_active, [{%{}, ~w(name)}]},
    {:tailnet_name_changed, [{%{}, ~w(frozen now)}]},
    {:tailnet_node_mismatch, [{%{}, ~w(node env)}]},
    {:tailnet_node_id_unsupported, [{%{}, ~w(value)}]},
    {:tailnet_join_expired, [{%{}, []}]},
    {:tailnet_join_cancelled, [{%{}, []}]},
    {:tailnet_join_ended, [{%{}, []}]},
    {:tailnet_join_not_current, [{%{}, []}]},
    {:docker_unavailable, [{%{}, ~w(reason)}]},
    {:reach_rolled_back,
     [{%{}, ~w(new old reason)}] ++
       for(
         local <- ~w(tailnet_node_mismatch tailnet_not_joined tailnet_https_off),
         do: {%{local: local}, ~w(new old reason)}
       )},
    {:reach_failed, [{%{}, ~w(new env)}]},
    {:reach_env_edited,
     for(then <- ~w(started not_running failed), do: {%{then: then}, ~w(env)}) ++
       [{%{then: "incoherent"}, []}]},
    {:reach_uncertain, [{%{}, ~w(observed)}]},
    {:reach_outcome_unknown, [{%{}, ~w(reason)}]},
    {:compose_env_refused, [{%{}, ~w(key)}, {%{}, ~w(line)}]},
    {:compose_override_refused,
     [
       {%{}, ~w(file service key)},
       {%{why: :interpolated}, ~w(file service key)},
       {%{}, ~w(file service)}
     ]}
  ]

  # The values a filled key is rendered with: a marker no sentence holds,
  # inside whatever the row's guard asks of the value.
  @samples %{key: "COMPOSE_@@key@@"}
  @examples %{key: "COMPOSE_PROFILES", line: "7"}

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("compile")
    fixture = Path.join(root(), @fixture)
    go = Path.join(root(), @go)

    # arca:bypass-ok=E — the renders' homes are tracked files.
    {:ok, json} = File.read(fixture)
    rendered_json = render_fixture(json)
    rendered_go = render_go()

    case args do
      ["--check"] ->
        # arca:bypass-ok=E
        if json == rendered_json and
             Mix.Tasks.Ops.Gen.Cli.current?(File.read(go), rendered_go) do
          Mix.shell().info("#{@fixture} refusals and #{@go} are current")
        else
          Mix.raise("#{@fixture} refusals or #{@go} is stale — run `mix cyfr.gen.reach_refusals`")
        end

      [] ->
        # arca:bypass-ok=E
        File.write!(fixture, rendered_json)
        # arca:bypass-ok=E
        File.write!(go, rendered_go)
        gofmt(go)
        Mix.shell().info("wrote #{@fixture} refusals and #{@go}")

      _other ->
        Mix.raise("usage: mix cyfr.gen.reach_refusals [--check]")
    end
  end

  @doc "The vector file's path and the Go file's, relative to the repository root."
  @spec targets() :: {String.t(), String.t()}
  def targets, do: {@fixture, @go}

  @doc """
  The `refusals` section: each code with its class and variants, from
  `Prima.Refusal`.
  """
  @spec section() :: [Jason.OrderedObject.t()]
  def section do
    for {code, variants} <- @rows do
      rendered = Enum.map(variants, &variant(code, &1))
      classes = rendered |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
      [class] = classes

      Jason.OrderedObject.new([
        {"code", Atom.to_string(code)},
        {"class", Atom.to_string(class)},
        {"variants", Enum.map(rendered, &elem(&1, 1))}
      ])
    end
  end

  defp variant(code, {fixed, slots}) do
    keys = for slot <- slots, do: String.to_existing_atom(slot)
    sample = Map.new(keys, &{&1, Map.get(@samples, &1, "@@#{&1}@@")})
    example = Map.new(keys, &{&1, Map.get(@examples, &1, "x-#{&1}")})

    %Prima.Refusal{class: class, message: marked} =
      Prima.Refusal.classify({code, Map.merge(fixed, sample)})

    %Prima.Refusal{message: sentence} = Prima.Refusal.classify({code, Map.merge(fixed, example)})

    template =
      Enum.reduce(keys, marked, fn key, text ->
        String.replace(text, Map.fetch!(sample, key), "{#{key}}")
      end)

    if marked == Prima.Refusal.unconfirmed() or template =~ "@@" or
         Enum.any?(keys, &(not String.contains?(template, "{#{&1}}"))) or
         String.contains?(Prima.Refusal.message({code, Map.merge(fixed, sample)}), ["{", "}"]) do
      Mix.raise("#{code} #{inspect(fixed)} does not render a template")
    end

    payload = Map.merge(fixed, example)

    {class,
     Jason.OrderedObject.new([
       {"fixed", ordered(fixed)},
       {"slots", slots},
       {"template", template},
       {"example",
        Jason.OrderedObject.new([{"payload", ordered(payload)}, {"sentence", sentence}])}
     ])}
  end

  defp ordered(map) do
    map
    |> Enum.map(fn {key, value} -> {Atom.to_string(key), to_string(value)} end)
    |> Enum.sort()
    |> Jason.OrderedObject.new()
  end

  @doc "The vector file's text with its `refusals` section rendered."
  @spec render_fixture(String.t()) :: String.t()
  def render_fixture(json) do
    %Jason.OrderedObject{values: values} = Jason.decode!(json, objects: :ordered_objects)
    values = List.keydelete(values, "refusals", 0) ++ [{"refusals", section()}]
    Jason.encode!(%Jason.OrderedObject{values: values}, pretty: true) <> "\n"
  end

  @doc "`refusals_gen.go`'s text."
  @spec render_go() :: String.t()
  def render_go do
    rows =
      for row <- section() do
        variants =
          for v <- row["variants"] do
            fixed = for {k, val} <- v["fixed"].values, do: "#{go_string(k)}: #{go_string(val)}, "
            slots = Enum.map_join(v["slots"], ", ", &go_string/1)

            "\t\t\t{Fixed: map[string]string{#{Enum.join(fixed) |> String.trim_trailing(", ")}}, " <>
              "Slots: []string{#{slots}}, Template: #{go_string(v["template"])}},\n"
          end

        "\t#{go_string(row["code"])}: {\n\t\tClass: #{go_string(row["class"])},\n" <>
          "\t\tVariants: []refusalVariant{\n#{Enum.join(variants)}\t\t},\n\t},\n"
      end

    """
    // SPDX-License-Identifier: Apache-2.0
    // Copyright 2026 CYFR Works Inc.

    // Code generated by `mix cyfr.gen.reach_refusals` from Prima.Refusal. DO NOT EDIT.

    package reach

    // refusalRows are the engine's and `cyfr up`'s refusals, each code's
    // class and sentence templates, as tests/fixtures/reach_modes.json's
    // refusals section holds them.
    var refusalRows = map[string]refusalRow{
    #{Enum.join(rows)}}
    """
  end

  defp go_string(text) do
    if String.match?(text, ~r/[\x00-\x1f\x7f]/),
      do: Mix.raise("#{inspect(text)} holds a control character")

    "\"" <> (text |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")) <> "\""
  end

  # The Go toolchain formats what it will compile; without one the file is
  # written as rendered and `gofmt` runs where the CLI is built. It reads
  # none of the server's settings, so it is given none of them.
  defp gofmt(path) do
    case System.find_executable("gofmt") do
      nil ->
        :ok

      gofmt ->
        unset =
          for {name, _} <- System.get_env(), String.starts_with?(name, "CYFR_"), do: {name, nil}

        {_, 0} = System.cmd(gofmt, ["-w", path], env: unset)
    end
  end

  defp root, do: Path.expand("../../../../..", __DIR__)
end
