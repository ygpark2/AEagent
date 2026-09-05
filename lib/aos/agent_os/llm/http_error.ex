defmodule AOS.AgentOS.LLM.HTTPError do
  @moduledoc "HTTP failure details and retry policy for compatible providers."

  defstruct [:status, :code, :type, :retry_after_ms, retryable: false]

  def from_response(%{status: status} = response) do
    body = decode(Map.get(response, :body))
    error = if is_map(body["error"]), do: body["error"], else: %{}
    code = error["code"]
    delay = retry_after(Map.get(response, :headers, %{}))

    retryable =
      cond do
        code in ["byok:key_unavailable", "model_not_found", "model_not_yet_available"] -> false
        code == "free_rate_limited" -> status == 429 and not is_nil(delay)
        true -> status in [429, 500, 502, 503, 504]
      end

    %__MODULE__{
      status: status,
      code: code,
      type: error["type"],
      retry_after_ms: delay,
      retryable: retryable
    }
  end

  defp decode(body) when is_map(body), do: body

  defp decode(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, data} when is_map(data) -> data
      _ -> %{}
    end
  end

  defp decode(_), do: %{}

  defp retry_after(headers) do
    value =
      Enum.find_value(headers, fn {key, value} ->
        if String.downcase(to_string(key)) == "retry-after", do: List.wrap(value) |> List.first()
      end)

    case value && Integer.parse(value) do
      {seconds, ""} when seconds >= 0 -> seconds * 1000
      _ -> date_delay(value)
    end
  end

  defp date_delay(nil), do: nil

  defp date_delay(value) do
    case :httpd_util.convert_request_date(String.to_charlist(value)) do
      {{_, _, _}, {_, _, _}} = date ->
        max(
          0,
          :calendar.datetime_to_gregorian_seconds(date) -
            :calendar.datetime_to_gregorian_seconds(:calendar.universal_time())
        ) * 1000

      _ ->
        nil
    end
  rescue
    ArgumentError -> nil
    FunctionClauseError -> nil
  end
end
