defmodule AOS.AgentOS.LLM.ChatStream do
  @moduledoc "Incremental SSE decoder and Chat Completions delta accumulator."

  defstruct buffer: "",
            data: [],
            text: "",
            calls: %{},
            usage: nil,
            model: nil,
            finished: false,
            done: false,
            error: nil

  def feed(chunk, state, on_delta) do
    consume(%{state | buffer: state.buffer <> chunk}, on_delta)
  end

  def result(%{error: error}) when not is_nil(error), do: {:error, error}

  def result(%{done: true, finished: true} = state) do
    message =
      if map_size(state.calls) > 0 do
        %{"tool_calls" => state.calls |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))}
      else
        %{"content" => state.text}
      end

    {:ok,
     %{"choices" => [%{"message" => message}], "usage" => state.usage, "model" => state.model}}
  end

  def result(_), do: {:error, :incomplete_stream}

  defp consume(%{error: error} = state, _) when not is_nil(error), do: {:halt, state}
  defp consume(%{done: true} = state, _), do: {:halt, state}

  defp consume(state, on_delta) do
    case :binary.split(state.buffer, "\n") do
      [line, rest] ->
        state = %{state | buffer: rest}
        line = String.trim_trailing(line, "\r")
        state = line(state, line, on_delta)
        consume(state, on_delta)

      [_] ->
        if byte_size(state.buffer) + Enum.reduce(state.data, 0, &(byte_size(&1) + &2)) >
             1_048_576,
           do: {:halt, %{state | error: :stream_event_too_large}},
           else: {:cont, state}
    end
  end

  defp line(state, "", on_delta) do
    data = state.data |> Enum.reverse() |> Enum.join("\n")
    event(%{state | data: []}, data, on_delta)
  end

  defp line(state, "data:" <> value, _) do
    value =
      if String.starts_with?(value, " "),
        do: binary_part(value, 1, byte_size(value) - 1),
        else: value

    %{state | data: [value | state.data]}
  end

  defp line(state, _, _), do: state

  defp event(state, "", _), do: state
  defp event(state, "[DONE]", _), do: %{state | done: true}

  defp event(state, data, on_delta) do
    case Jason.decode(data) do
      {:ok, %{"error" => _}} -> %{state | error: :stream_api_error}
      {:ok, chunk} when is_map(chunk) -> apply_chunk(state, chunk, on_delta)
      _ -> %{state | error: :invalid_stream_json}
    end
  end

  defp apply_chunk(state, chunk, on_delta) do
    state = %{state | model: chunk["model"] || state.model, usage: chunk["usage"] || state.usage}

    case chunk["choices"] do
      [] -> state
      [%{"index" => 0} = choice | _] -> apply_choice(state, choice, on_delta)
      _ -> %{state | error: :invalid_stream_choices}
    end
  end

  defp apply_choice(state, choice, on_delta) do
    delta = choice["delta"] || %{}

    if is_map(delta) do
      state
      |> Map.put(:finished, state.finished or not is_nil(choice["finish_reason"]))
      |> append_text(delta["content"], on_delta)
      |> append_calls(delta["tool_calls"])
    else
      %{state | error: :invalid_stream_delta}
    end
  end

  defp append_text(state, nil, _), do: state

  defp append_text(state, text, on_delta) when is_binary(text) do
    if text != "" and on_delta.(text) == :halt,
      do: %{state | error: :cancelled},
      else: %{state | text: state.text <> text}
  end

  defp append_text(state, _, _), do: %{state | error: :invalid_stream_content}

  defp append_calls(state, nil), do: state

  defp append_calls(state, calls) when is_list(calls) do
    Enum.reduce(calls, state, &append_call/2)
  end

  defp append_calls(state, _), do: %{state | error: :invalid_stream_tool_calls}

  defp append_call(%{"index" => index} = delta, state) when is_integer(index) and index >= 0 do
    previous =
      Map.get(state.calls, index, %{
        "id" => "",
        "type" => "function",
        "function" => %{"name" => "", "arguments" => ""}
      })

    function = delta["function"] || %{}

    if valid_call_delta?(delta, function) do
      call = %{
        "id" => previous["id"] <> (delta["id"] || ""),
        "type" => delta["type"] || previous["type"],
        "function" => %{
          "name" => previous["function"]["name"] <> (function["name"] || ""),
          "arguments" => previous["function"]["arguments"] <> (function["arguments"] || "")
        }
      }

      %{state | calls: Map.put(state.calls, index, call)}
    else
      %{state | error: :invalid_stream_tool_call}
    end
  end

  defp append_call(_, state), do: %{state | error: :invalid_stream_tool_call}

  defp valid_call_delta?(delta, function) when is_map(function) do
    delta["type"] in [nil, "function"] and
      Enum.all?(
        [delta["id"], function["name"], function["arguments"]],
        &(is_nil(&1) or is_binary(&1))
      )
  end

  defp valid_call_delta?(_, _), do: false
end
