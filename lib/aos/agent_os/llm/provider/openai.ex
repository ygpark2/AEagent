defmodule AOS.AgentOS.LLM.Provider.OpenAI do
  @moduledoc """
  API-backed provider for OpenAI-compatible chat completions.
  """

  alias AOS.AgentOS.Config
  alias AOS.AgentOS.LLM.{ChatStream, HTTPError, Usage}
  alias AOS.HTTPClient

  def call(prompt, history, opts) do
    model = Keyword.get(opts, :model) || Config.agent_model()
    tools = Keyword.get(opts, :tools)
    base_url = Config.agent_base_url()
    api_key = Config.agent_api_key()

    {url, body} = prepare_request(base_url, model, prompt, history, tools)
    headers = [{"Authorization", "Bearer #{api_key}"}, {"Content-Type", "application/json"}]

    if Keyword.get(opts, :stream, false) do
      stream(url, body, headers, opts)
    else
      request(url, body, headers)
    end
  end

  defp request(url, body, headers) do
    case HTTPClient.post(url, body, headers, request_options()) do
      {:ok, %{status: 200, body: resp_body}} ->
        parse_raw_response(resp_body)

      {:ok, response} ->
        {:error, HTTPError.from_response(response)}

      {:error, reason} ->
        {:error, {:transport_error, reason}}
    end
  end

  defp request_options do
    [
      connect_options: [timeout: 60_000],
      receive_timeout: 60_000,
      decode_body: false,
      retry: false,
      redirect: false
    ]
  end

  defp stream(url, body, headers, opts) do
    payload =
      body
      |> Jason.decode!()
      |> Map.merge(%{"stream" => true, "stream_options" => %{"include_usage" => true}})

    on_delta = Keyword.get(opts, :on_delta, fn _ -> :ok end)
    reducer = fn data, state -> ChatStream.feed(data, state, on_delta) end

    case HTTPClient.post_stream(
           url,
           Jason.encode!(payload),
           headers,
           reducer,
           %ChatStream{},
           request_options()
         ) do
      {:ok, %{status: 200, stream_state: state}} ->
        parse_stream(state)

      {:ok, response} ->
        {:error, HTTPError.from_response(response)}

      {:error, _reason} ->
        {:error, :stream_transport_error}
    end
  end

  defp parse_stream(state) do
    with {:ok, response} <- ChatStream.result(state),
         {:ok, result} <- parse_decoded_response(response) do
      {:ok, result}
    else
      {:error, reason} -> {:error, {:stream_error, reason}}
    end
  end

  def list_models do
    base_url = Config.agent_base_url()
    api_key = Config.agent_api_key()
    url = endpoint(base_url, "models")
    headers = [{"Authorization", "Bearer #{api_key}"}]

    case HTTPClient.get(url, headers, request_options()) do
      {:ok, %{status: 200, body: body}} ->
        parse_models(Jason.decode(body))

      _ ->
        {:error, :failed_to_list_models}
    end
  end

  defp parse_models({:ok, %{"data" => models}}) when is_list(models) do
    if Enum.all?(models, &(is_map(&1) and is_binary(&1["id"]))),
      do: {:ok, Enum.map(models, & &1["id"])},
      else: {:error, :invalid_models_response}
  end

  defp parse_models(_), do: {:error, :invalid_models_response}

  defp endpoint(base_url, path) do
    base = base_url |> String.trim_trailing("/") |> String.replace(~r{/(v1beta|v1)$}, "")
    "#{base}/v1/#{path}"
  end

  defp prepare_request(base_url, model, prompt, history, tools) do
    messages =
      Enum.flat_map(history, fn
        {"user", content} ->
          [%{role: "user", content: scrub_utf8(content)}]

        {"assistant", %{tool_calls: calls}} ->
          [
            %{
              role: "assistant",
              tool_calls:
                Enum.map(calls, fn c ->
                  %{
                    id: c["id"],
                    type: "function",
                    function: %{name: c["name"], arguments: Jason.encode!(c["arguments"])}
                  }
                end)
            }
          ]

        {"assistant", content} ->
          [%{role: "assistant", content: scrub_utf8(content)}]

        {"tool", %{id: id, name: name, content: content}} ->
          text_content =
            case content do
              %{content: [%{text: t} | _]} -> scrub_utf8(t)
              _ -> scrub_utf8(inspect(content))
            end

          [%{role: "tool", tool_call_id: id, name: name, content: text_content}]

        {"system", content} ->
          [%{role: "system", content: scrub_utf8(content)}]
      end)

    messages =
      if prompt, do: messages ++ [%{role: "user", content: scrub_utf8(prompt)}], else: messages

    payload = %{
      model: String.replace(model, ~r|^models/|, ""),
      messages: messages,
      tools:
        if(tools,
          do:
            Enum.map(tools, fn t ->
              %{
                type: "function",
                function: %{
                  name: "#{t["server_id"]}__#{t["name"]}",
                  description: t["description"],
                  parameters: t["inputSchema"]
                }
              }
            end)
        )
    }

    payload = if tools in [nil, []], do: Map.delete(payload, :tools), else: payload
    {endpoint(base_url, "chat/completions"), Jason.encode!(payload)}
  end

  defp scrub_utf8(text) when is_binary(text) do
    text |> String.chunk(:valid) |> Enum.filter(&String.valid?/1) |> Enum.join("")
  end

  defp scrub_utf8(any), do: any

  defp parse_raw_response(body) do
    case Jason.decode(body) do
      {:ok, data} -> parse_decoded_response(data)
      {:error, reason} -> {:error, {:invalid_json_response, reason}}
    end
  end

  defp parse_decoded_response(%{"choices" => [%{"message" => choice} | _]} = data) do
    usage = Usage.normalize_usage(data["usage"])
    model = data["model"]

    parse_choice(choice, usage, model)
  end

  defp parse_decoded_response(_), do: {:error, :invalid_chat_response}

  defp parse_choice(%{"tool_calls" => calls, "content" => content}, usage, model)
       when calls in [nil, []] and is_binary(content),
       do: {:ok, Usage.build_text_response(content, usage, model)}

  defp parse_choice(%{"tool_calls" => tool_calls}, usage, model) do
    case parse_tool_calls(tool_calls) do
      {:ok, calls} -> {:ok, Usage.build_tool_call_response(calls, usage, model)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_choice(%{"content" => content}, usage, model) when is_binary(content),
    do: {:ok, Usage.build_text_response(content, usage, model)}

  defp parse_choice(_choice, _usage, _model), do: {:error, :empty_response}

  defp parse_tool_calls(tool_calls) when is_list(tool_calls) do
    Enum.reduce_while(tool_calls, {:ok, []}, fn tool_call, {:ok, acc} ->
      case parse_tool_call(tool_call) do
        {:ok, call} -> {:cont, {:ok, [call | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, calls} -> {:ok, Enum.reverse(calls)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_tool_calls(_tool_calls), do: {:error, :invalid_tool_calls}

  defp parse_tool_call(%{
         "id" => id,
         "function" => %{"name" => name, "arguments" => arguments} = function
       })
       when is_binary(id) and id != "" and is_binary(name) and name != "" and is_binary(arguments) do
    case Jason.decode(function["arguments"] || "{}") do
      {:ok, arguments} when is_map(arguments) ->
        {:ok, %{"id" => id, "name" => name, "arguments" => arguments}}

      {:ok, _} ->
        {:error, {:invalid_tool_arguments, name}}

      {:error, reason} ->
        {:error, {:invalid_tool_arguments, name, reason}}
    end
  end

  defp parse_tool_call(_tool_call), do: {:error, :invalid_tool_call}
end
