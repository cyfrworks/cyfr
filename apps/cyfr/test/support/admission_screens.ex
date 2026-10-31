# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.AdmissionScreens do
  @moduledoc """
  The two screens a new person meets (`PrismWeb.AdmissionCard`), driven as
  a browser drives them, against a scripted cyfr.run, and the vocabulary
  rule every page test holds its page's text to.

    * `directory!/0` serves a scripted directory
      (`Sanctum.Test.DirectoryServer`) and pins it for the test's
      admissions; `next_genesis/2` scripts how it answers the next
      registration, which no test can name before the admission draws its
      keys: `:drop` (registered, the answer lost: cyfr.run silent) or
      `:refuse`.
    * `registry!/1` serves a scripted registry (`Sanctum.Test.RegistryStub`)
      answering names (`:taken`, `:close`, or free), its policy version
      and its claims, in order from a script `script/2` changes.
    * `name!/2`, `ceremony/2` and `admit!/3` drive screen 1; `code!/1`
      takes the recovery code the page pushed to its hook.
    * `refute_vocabulary/1` holds a page's visible text to none of the
      words the vocabulary rule keeps from a person.
  """

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]
  import Phoenix.LiveViewTest

  alias Sanctum.Test.{DirectoryServer, Newcomers, RegistryStub}
  alias Sanctum.TestContext.Authenticator

  # The words, with their plurals and forms, no page a person reads says.
  @vocabulary ~r/\b(handles?|enroll\w*|director(?:y|ies)|registr(?:y|ies)|kits?|homes?|hubs?|cells?|nodes?|doors?|glass(?:es)?)\b/i

  @doc "A scripted directory, pinned for the calling test's admissions."
  def directory! do
    tls = DirectoryServer.tls()
    DirectoryServer.listen!()
    DirectoryServer.seam!(tls)
    Arca.Cache.init()
    on_exit(fn -> Arca.Cache.delete_match(Arca.Cache.Keys.match_identity_unreachable()) end)

    %{dir: dir} = DirectoryServer.start!(tls)
    {:ok, next} = Agent.start_link(fn -> nil end)
    server = DirectoryServer.Server.start(tls[:server_config], scripted(dir, next), self())
    on_exit(fn -> DirectoryServer.Server.stop(server) end)

    url = "https://dir-a.test:#{server.port}"
    Newcomers.directory!(url)
    %{url: url, dir: dir, next: next}
  end

  @doc "How the directory answers the next registration: `:drop` or `:refuse`."
  def next_genesis(%{next: next}, mode) when mode in [:drop, :refuse],
    do: Agent.update(next, fn _ -> mode end)

  # The directory's own handler, with the next registration's answer
  # scripted for the identifier it carries.
  defp scripted(dir, next) do
    base = DirectoryServer.handler(dir)

    fn
      %{method: "POST", target: "/directory/v1/genesis", body: body} = request ->
        case Agent.get_and_update(next, &{&1, nil}) do
          nil ->
            :ok

          mode ->
            {:ok, genesis} = body |> Jason.decode!() |> Prima.Identity.Entry.decode()
            DirectoryServer.next(dir, Prima.Identity.identifier(genesis), mode)
        end

        base.(request)

      request ->
        base.(request)
    end
  end

  @doc """
  A scripted registry: `names` answers a name's lookup (`:taken`, `:close`,
  or free when absent); `version:` answers the policy version (`:answer`,
  `:close` or `:unreadable`); `claims:` answers the claims in order
  (`:taken`, `:reserved`, `:close`), each after the last accepted. Answers
  the script's agent.
  """
  def registry!(names \\ %{}, opts \\ []) do
    {:ok, script} =
      Agent.start_link(fn ->
        %{
          names: names,
          version: Keyword.get(opts, :version, :answer),
          claims: Keyword.get(opts, :claims, [])
        }
      end)

    RegistryStub.start!(&answer(script, &1))
    script
  end

  @doc "Change the registry's script: `version:` or `claims:`."
  def script(script, changes), do: Agent.update(script, &Map.merge(&1, Map.new(changes)))

  defp answer(script, %{method: "GET", path: "/v1/handles/" <> name}) do
    case Agent.get(script, &Map.get(&1.names, name)) do
      nil -> RegistryStub.refusal(:handle_not_found)
      :close -> :close
      :taken -> {200, handle_answer(name, "per_" <> String.duplicate("a", 64))}
    end
  end

  defp answer(script, %{method: "GET", path: "/v1/legal/version"}) do
    case Agent.get(script, & &1.version) do
      :answer -> {200, RegistryStub.answer(%{"policy_version" => "2026-10", "policies" => []})}
      :unreadable -> {200, RegistryStub.answer(%{"policies" => []})}
      :close -> :close
    end
  end

  defp answer(_script, %{path: "/v1/legal/accept"}),
    do: {201, RegistryStub.answer(%{"accepted" => true})}

  defp answer(script, %{path: "/v1/namespaces/personal/claim", body: body}) do
    request = Jason.decode!(body)

    case Agent.get_and_update(script, &next_claim/1) do
      nil ->
        {201,
         RegistryStub.answer(%{
           "handle" => request["body"]["handle"],
           "identifier" => request["identifier"]
         })}

      :taken ->
        RegistryStub.refusal(:handle_taken)

      :reserved ->
        RegistryStub.refusal(:handle_reserved)

      :close ->
        :close
    end
  end

  defp next_claim(%{claims: [next | rest]} = script), do: {next, %{script | claims: rest}}
  defp next_claim(script), do: {nil, script}

  defp handle_answer(handle, identifier) do
    RegistryStub.answer(%{
      "protocol" => Prima.HandleAnswer.protocol(),
      "registry" => RegistryStub.host(),
      "handle" => handle,
      "identifier" => identifier,
      "directory" => RegistryStub.directory()
    })
  end

  @doc """
  Type `name` on screen 1, and let the page answer its check. The page it
  renders holds none of the vocabulary rule's words (`refute_vocabulary/1`),
  as does the page `admit!/3` renders and the screen `screen_2?/2` reads.
  """
  def name!(view, name) do
    view |> element(~s([data-test="admission-name"])) |> render_change(%{"name" => name})
    view |> render() |> tap(&refute_vocabulary/1)
  end

  @doc "The browser's ceremony under the options the page in `mode` answered."
  def ceremony(view, mode) do
    render_hook(view, "#{mode}_start", %{})
    assert_reply(view, %{public_key: public_key, registration: registration})

    Authenticator.registration(
      Authenticator.new("#{mode}|#{System.unique_integer([:positive])}"),
      %{public_key: public_key, registration: registration}
    )
  end

  @doc """
  The passkey made in `mode` for the name the page holds, with a fresh
  recovery secret and request id as the browser draws them; answers the
  identity sent (`Sanctum.Test.Newcomers.identity/1`), its name the page's.
  """
  def admit!(view, mode, credential \\ nil) do
    identity = Newcomers.identity()
    fields = identity |> Newcomers.fields() |> Map.delete("name")
    credential = credential || ceremony(view, mode)
    render_hook(view, "#{mode}_passkey", Map.put(fields, "credential", credential))
    view |> render() |> refute_vocabulary()
    identity
  end

  @doc "The recovery code the page pushed to its hook."
  def code!(view) do
    assert_push_event(view, "admission_code", %{code: code})
    code
  end

  @doc """
  Whether screen 2 stands in `state`. Screen 2, wherever it is drawn, holds
  none of the vocabulary rule's words.
  """
  def screen_2?(view, state) do
    if has_element?(view, ~s([data-test="admission-code"])),
      do: view |> element(~s([data-test="admission-code"])) |> render() |> refute_vocabulary()

    has_element?(view, ~s([data-test="admission-code"][data-state="#{state}"]))
  end

  @doc """
  `html`'s visible text holds none of the vocabulary rule's words: handle,
  enroll, directory, registry, kit, home, hub, cell, node, door or glass,
  whole words in any case, with their plurals and forms.
  """
  def refute_vocabulary(html) when is_binary(html) do
    text = html |> LazyHTML.from_fragment() |> LazyHTML.to_tree() |> visible()
    found = @vocabulary |> Regex.scan(text) |> Enum.map(&hd/1) |> Enum.uniq()
    assert found == [], "the page says #{inspect(found)}:\n#{text}"
  end

  defp visible(nodes) when is_list(nodes), do: Enum.map_join(nodes, " ", &visible/1)
  defp visible({tag, _attrs, _children}) when tag in ~w(script style template), do: ""
  defp visible({_tag, _attrs, children}), do: visible(children)
  defp visible(text) when is_binary(text), do: text
  defp visible(_comment), do: ""
end
