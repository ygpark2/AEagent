defmodule AOS.AgentOS.LLM.HTTPErrorTest do
  use ExUnit.Case, async: true
  alias AOS.AgentOS.LLM.HTTPError

  test "free capacity errors depend on retry-after and ordinary errors retain status" do
    response = %{status: 429, body: %{"error" => %{"code" => "free_rate_limited"}}}
    refute HTTPError.from_response(response).retryable
    error = HTTPError.from_response(Map.put(response, :headers, %{"retry-after" => ["12"]}))
    assert error.retryable
    assert error.retry_after_ms == 12_000

    for status <- [400, 401, 402, 403, 404, 425] do
      refute HTTPError.from_response(%{status: status, body: ""}).retryable
    end

    for status <- [429, 500, 502, 503, 504] do
      assert HTTPError.from_response(%{status: status, body: ""}).retryable
    end
  end

  test "live payment-required quota response is terminal" do
    assert %HTTPError{
             status: 402,
             code: "insufficient_user_quota",
             type: "insufficient_quota",
             retryable: false
           } =
             HTTPError.from_response(%{
               status: 402,
               body: %{
                 "error" => %{
                   "code" => "insufficient_user_quota",
                   "type" => "insufficient_quota"
                 }
               }
             })
  end

  test "handles invalid bodies and retry headers" do
    for body <- ["invalid", "null", "[]", nil], header <- ["bad", "-1", ""] do
      assert %HTTPError{retry_after_ms: nil} =
               HTTPError.from_response(%{
                 status: 500,
                 body: body,
                 headers: [{"Retry-After", header}]
               })
    end
  end
end
