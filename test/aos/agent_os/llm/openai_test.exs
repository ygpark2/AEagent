defmodule AOS.AgentOS.LLM.OpenAITest do
  use AOS.DataCase, async: false
  import Mock
  alias AOS.AgentOS.Executions
  alias AOS.AgentOS.LLM.{Client, HTTPError}
  alias AOS.AgentOS.LLM.Provider.OpenAI
  alias AOS.AgentOS.MCP.Manager
  alias AOS.AgentOS.Roles.LLM

  setup do
    keys = [:agent_base_url, :agent_api_key, :agent_model, :llm_provider, :agent_stream]
    previous = Enum.map(keys, &{&1, Application.fetch_env(:aos, &1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:aos, key, value)
        {key, :error} -> Application.delete_env(:aos, key)
      end)
    end)

    Application.put_env(:aos, :agent_base_url, "https://api.orcarouter.ai/v1")
    Application.put_env(:aos, :agent_api_key, "test-key")
    Application.put_env(:aos, :agent_model, "provider/model")
    Application.put_env(:aos, :llm_provider, OpenAI)
    Application.put_env(:aos, :agent_stream, false)
    :ok
  end

  test "normalizes endpoint variants and preserves model ids and auth" do
    with_mock AOS.HTTPClient, [:passthrough],
      post: fn url, body, headers, opts ->
        assert url == "https://api.orcarouter.ai/v1/chat/completions"
        assert {"Authorization", "Bearer test-key"} in headers
        assert opts[:retry] == false
        assert opts[:decode_body] == false
        assert opts[:redirect] == false
        payload = Jason.decode!(body)
        assert payload["model"] == "provider/model"
        refute Map.has_key?(payload, "tools")

        {:ok,
         %{
           status: 200,
           body: Jason.encode!(%{choices: [%{message: %{content: "hello", tool_calls: nil}}]})
         }}
      end,
      get: fn url, _, _ ->
        assert url == "https://api.orcarouter.ai/v1/models"
        {:ok, %{status: 200, body: "{\"data\":[{\"id\":\"provider/model\"}]}"}}
      end do
      for suffix <- ["", "/", "/v1", "/v1/", "/v1beta", "/v1beta/"] do
        Application.put_env(:aos, :agent_base_url, "https://api.orcarouter.ai" <> suffix)
        assert {:ok, %{"text" => "hello"}} = OpenAI.call("hello", [], [])
        assert {:ok, ["provider/model"]} = OpenAI.list_models()
      end
    end
  end

  test "round trips tool call history and validates arguments" do
    with_mock AOS.HTTPClient, [:passthrough],
      post: fn _, body, _, _ ->
        payload = Jason.decode!(body)

        assert [
                 %{"role" => "assistant", "tool_calls" => [call]},
                 %{"role" => "tool", "tool_call_id" => "c1"}
               ] = payload["messages"]

        assert call["function"]["arguments"] == "{\"value\":1}"
        assert hd(payload["tools"])["function"]["name"] == "internal__echo"

        {:ok,
         %{status: 200, body: Jason.encode!(%{choices: [%{message: %{tool_calls: [call]}}]})}}
      end do
      call = %{"id" => "c1", "name" => "internal__echo", "arguments" => %{"value" => 1}}

      history = [
        {"assistant", %{tool_calls: [call]}},
        {"tool", %{id: "c1", name: "internal__echo", content: "ok"}}
      ]

      tools = [
        %{"server_id" => "internal", "name" => "echo", "inputSchema" => %{"type" => "object"}}
      ]

      assert {:ok, %{"tool_calls" => [^call]}} = OpenAI.call(nil, history, tools: tools)
    end
  end

  test "terminal OrcaRouter errors do not retry or disclose response text" do
    with_mock AOS.HTTPClient, [:passthrough],
      post: fn _, _, _, _ ->
        {:ok,
         %{
           status: 503,
           body: "{\"error\":{\"code\":\"byok:key_unavailable\",\"message\":\"secret\"}}"
         }}
      end do
      assert {:error, %HTTPError{retryable: false, code: "byok:key_unavailable"} = error} =
               Client.call_raw("hi", [], [])

      refute inspect(error) =~ "secret"
      assert_called_exactly(AOS.HTTPClient.post(:_, :_, :_, :_), 1)
    end
  end

  test "streaming passes deltas through the role and returns final text" do
    wire =
      "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"hello\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"

    with_mock AOS.HTTPClient, [:passthrough],
      post_stream: fn _, body, _, reducer, state, _ ->
        assert Jason.decode!(body)["stream"]
        {_, state} = reducer.(wire, state)
        {:ok, %{status: 200, stream_state: state}}
      end do
      assert {:ok, %{text: "hello"}} =
               LLM.call_with_meta("hi",
                 use_tools: false,
                 stream: true,
                 notify: self()
               )

      assert_received {:llm_stream_started, ref}
      assert_received {:llm_stream_delta, ^ref, "hello"}
      assert_received {:llm_stream_finished, ^ref, :ok}
    end
  end

  test "partial streaming failure is never retried" do
    with_mock AOS.HTTPClient, [:passthrough],
      post_stream: fn _, _, _, reducer, state, _ ->
        {_, state} =
          reducer.(
            ~s(data: {"choices":[{"index":0,"delta":{"content":"partial"}}]}) <> "\n\n",
            state
          )

        {:ok, %{status: 200, stream_state: state}}
      end do
      assert {:error, {:stream_error, :incomplete_stream}} =
               Client.call_raw("hi", [], stream: true)

      assert_called_exactly(AOS.HTTPClient.post_stream(:_, :_, :_, :_, :_, :_), 1)
    end
  end

  test "role executes a streamed tool once and sends its result back" do
    {:ok, execution} = Executions.enqueue("stream tool test", start_immediately: false)

    with_mocks [
      {AOS.HTTPClient, [:passthrough],
       [
         post_stream: fn _, body, _, reducer, state, _ ->
           messages = Jason.decode!(body)["messages"]

           delta =
             if Enum.any?(messages, &(&1["role"] == "tool")) do
               assert Enum.any?(
                        messages,
                        &(&1["role"] == "tool" and &1["tool_call_id"] == "c1" and
                            String.contains?(&1["content"], "fixture"))
                      )

               %{content: "final answer"}
             else
               %{
                 tool_calls: [
                   %{
                     index: 0,
                     id: "c1",
                     type: "function",
                     function: %{
                       name: "internal__read_file",
                       arguments: Jason.encode!(%{path: "README.md"})
                     }
                   }
                 ]
               }
             end

           wire =
             "data: " <>
               Jason.encode!(%{choices: [%{index: 0, delta: delta, finish_reason: "stop"}]}) <>
               "\n\ndata: [DONE]\n\n"

           {_, state} = reducer.(wire, state)
           {:ok, %{status: 200, stream_state: state}}
         end
       ]},
      {Manager, [:passthrough],
       [
         call_tool: fn "internal", "read_file", %{"path" => "README.md"}, _ ->
           {:ok, %{content: [%{text: "fixture"}]}}
         end
       ]}
    ] do
      assert {:ok, %{text: "final answer"}} =
               LLM.call_with_meta("read README", stream: true, execution_id: execution.id)

      assert_called_exactly(Manager.call_tool(:_, :_, :_, :_), 1)
      assert_called_exactly(AOS.HTTPClient.post_stream(:_, :_, :_, :_, :_, :_), 2)
    end
  end

  test "free tier retries once and long retry-after returns immediately" do
    with_mock AOS.HTTPClient, [:passthrough],
      post: fn _, _, _, _ ->
        {:ok,
         %{
           status: 429,
           headers: %{"retry-after" => ["0"]},
           body: Jason.encode!(%{error: %{code: "free_rate_limited"}})
         }}
      end do
      assert {:error, %HTTPError{code: "free_rate_limited"}} = Client.call_raw("hi", [], [])
      assert_called_exactly(AOS.HTTPClient.post(:_, :_, :_, :_), 2)
    end

    with_mock AOS.HTTPClient, [:passthrough],
      post: fn _, _, _, _ ->
        {:ok, %{status: 429, headers: %{"retry-after" => ["3600"]}, body: ""}}
      end do
      assert {:error, %HTTPError{retry_after_ms: 3_600_000}} = Client.call_raw("hi", [], [])
      assert_called_exactly(AOS.HTTPClient.post(:_, :_, :_, :_), 1)
    end
  end
end
