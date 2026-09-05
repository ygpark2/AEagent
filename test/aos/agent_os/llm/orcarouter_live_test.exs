defmodule AOS.AgentOS.LLM.OrcaRouterLiveTest do
  use ExUnit.Case, async: false

  alias AOS.AgentOS.LLM.Provider.OpenAI

  @moduletag :external
  @moduletag timeout: 300_000

  setup do
    key = required_env("ORCAROUTER_API_KEY")
    model = required_env("ORCAROUTER_MODEL")
    keys = [:agent_base_url, :agent_api_key, :agent_model]
    previous = Enum.map(keys, &{&1, Application.fetch_env(:aos, &1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {name, {:ok, value}} -> Application.put_env(:aos, name, value)
        {name, :error} -> Application.delete_env(:aos, name)
      end)
    end)

    Application.put_env(:aos, :agent_base_url, "https://api.orcarouter.ai/v1")
    Application.put_env(:aos, :agent_api_key, key)
    Application.put_env(:aos, :agent_model, model)
    {:ok, model: model}
  end

  test "selected model is listed", %{model: model} do
    assert {:ok, models} = OpenAI.list_models()
    assert model in models
  end

  test "Korean chat and conversation history work with streaming off and on" do
    for stream <- [false, true] do
      ref = make_ref()
      opts = [stream: stream, on_delta: fn text -> send(self(), {ref, text}) end]
      prompt = "한국어로 짧게 인사하세요. 한 문장만 답하세요."
      assert {:ok, first} = OpenAI.call(prompt, [], opts)
      assert_text(first)
      if stream, do: assert_received({^ref, text} when is_binary(text))

      history = [{"user", prompt}, {"assistant", first["text"]}]
      assert {:ok, second} = OpenAI.call("방금 답변을 한 문장으로 영어로 번역하세요.", history, opts)
      assert_text(second)
      report("chat", stream, [first, second])
    end
  end

  test "synthetic read-only tool round trip works with streaming off and on" do
    tool = %{
      "server_id" => "integration",
      "name" => "echo",
      "description" => "Returns the supplied text unchanged.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{"text" => %{"type" => "string"}},
        "required" => ["text"],
        "additionalProperties" => false
      }
    }

    for stream <- [false, true] do
      prompt =
        "Call integration__echo exactly once with text aeagent_smoke. Do not answer until you receive the tool result."

      assert {:ok, %{"tool_calls" => [call]} = first} =
               OpenAI.call(prompt, [], stream: stream, tools: [tool])

      assert call["name"] == "integration__echo"
      assert call["arguments"] == %{"text" => "aeagent_smoke"}

      # Only this synthetic echo is evaluated; model output never dispatches real tools.
      history = [
        {"user", prompt},
        {"assistant", %{tool_calls: [call]}},
        {"tool",
         %{
           id: call["id"],
           name: call["name"],
           content: %{content: [%{text: call["arguments"]["text"]}]}
         }}
      ]

      assert {:ok, final} = OpenAI.call(nil, history, stream: stream)
      assert_text(final)
      assert final["text"] =~ "aeagent_smoke"
      report("tool_round_trip", stream, [first, final])
    end
  end

  defp assert_text(response) do
    assert is_binary(response["text"]) and String.trim(response["text"]) != ""
    assert response["usage"].total_tokens > 0
  end

  defp required_env(name) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" -> value
      _ -> flunk("Set #{name} locally before explicitly running live tests")
    end
  end

  defp report(check, stream, responses) do
    IO.puts(
      Jason.encode!(%{
        check: check,
        stream: stream,
        models: Enum.map(responses, & &1["model"]),
        total_tokens: Enum.sum(Enum.map(responses, & &1["usage"].total_tokens))
      })
    )
  end
end
