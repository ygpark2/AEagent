defmodule AOS.HTTPClientStreamTest do
  use ExUnit.Case, async: true

  test "streams using Req and retains status and headers for error responses" do
    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
      |> Plug.Conn.send_resp(200, "data: hello\n\n")
    end

    reducer = fn chunk, acc -> {:cont, acc <> chunk} end

    assert {:ok, %{status: 200, stream_state: "data: hello\n\n"}} =
             AOS.HTTPClient.post_stream("http://test", "{}", [], reducer, "",
               plug: plug,
               retry: false,
               decode_body: false
             )

    plug = fn conn ->
      conn |> Plug.Conn.put_resp_header("retry-after", "1") |> Plug.Conn.send_resp(429, "limited")
    end

    assert {:ok, %{status: 429, body: "limited", headers: %{"retry-after" => ["1"]}}} =
             AOS.HTTPClient.post_stream(
               "http://test",
               "{}",
               [],
               fn _, _ -> flunk("error body delivered as delta") end,
               "",
               plug: plug,
               retry: false,
               decode_body: false
             )
  end
end
