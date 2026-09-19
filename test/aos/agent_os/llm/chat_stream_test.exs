defmodule AOS.AgentOS.LLM.ChatStreamTest do
  use ExUnit.Case, async: true
  alias AOS.AgentOS.LLM.ChatStream

  defp event(delta, finish \\ nil) do
    "data: " <>
      Jason.encode!(%{choices: [%{index: 0, delta: delta, finish_reason: finish}]}) <> "\r\n\r\n"
  end

  test "decodes every byte boundary, comments, usage and Korean text" do
    wire =
      ": keepalive\r\n\r\n" <>
        event(%{content: "안녕하세요"}) <>
        event(%{}, "stop") <>
        ~s(data: {"choices":[],"usage":{"total_tokens":4}}) <> "\n\ndata: [DONE]\n\n"

    state =
      Enum.reduce(:binary.bin_to_list(wire), %ChatStream{}, fn byte, state ->
        {_, next} = ChatStream.feed(<<byte>>, state, fn text -> send(self(), {:delta, text}) end)
        next
      end)

    assert {:ok,
            %{
              "choices" => [%{"message" => %{"content" => "안녕하세요"}}],
              "usage" => %{"total_tokens" => 4}
            }} = ChatStream.result(state)

    assert_received {:delta, "안녕하세요"}
  end

  test "assembles interleaved tool calls in index order" do
    wire =
      event(%{
        tool_calls: [
          %{index: 1, id: "b", function: %{name: "second", arguments: "{"}},
          %{index: 0, id: "a", function: %{name: "first", arguments: "{"}}
        ]
      }) <>
        event(
          %{
            tool_calls: [
              %{index: 0, function: %{arguments: "\"x\":1}"}},
              %{index: 1, function: %{arguments: "}"}}
            ]
          },
          "tool_calls"
        ) <> "data: [DONE]\n\n"

    assert {:halt, state} =
             ChatStream.feed(wire, %ChatStream{}, fn _ -> flunk("unexpected text") end)

    assert {:ok, %{"choices" => [%{"message" => %{"tool_calls" => [first, second]}}]}} =
             ChatStream.result(state)

    assert first["id"] == "a"
    assert first["function"]["arguments"] == "{\"x\":1}"
    assert second["id"] == "b"
  end

  test "rejects truncated streams and malformed or in-band errors" do
    for wire <- [event(%{content: "partial"}), "data: [DONE]\n\n"] do
      {_, state} = ChatStream.feed(wire, %ChatStream{}, fn _ -> :ok end)
      assert {:error, :incomplete_stream} = ChatStream.result(state)
    end

    for {wire, error} <- [
          {"data: invalid\n\n", :invalid_stream_json},
          {"data: {\"error\":{\"message\":\"private\"}}\n\n", :stream_api_error}
        ] do
      assert {:halt, state} = ChatStream.feed(wire, %ChatStream{}, fn _ -> :ok end)
      assert {:error, ^error} = ChatStream.result(state)
    end
  end

  test "callback cancellation halts before further deltas" do
    wire = event(%{content: "one"}) <> event(%{content: "two"})

    assert {:halt, state} =
             ChatStream.feed(wire, %ChatStream{}, fn text ->
               assert text == "one"
               :halt
             end)

    assert {:error, :cancelled} = ChatStream.result(state)
  end
end
