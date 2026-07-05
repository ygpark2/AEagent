defmodule AOSWeb.JsonRestTest do
  use ExUnit.Case, async: false

  alias AOSWeb.JsonRest
  import Mock

  @url "https://collins.info"
  @body %{"nice" => "body"}

  describe "get_json/2" do
    test "returns a response" do
      response_data = %{status: 200, body: %{"ok" => "yes"}}

      with_mock Req,
        request: fn _opts -> {:ok, struct(Req.Response, response_data)} end do
        expected = {:ok, %{status_code: 200, body: %{"ok" => "yes"}}}
        assert expected == JsonRest.get_json(@url, [])
      end
    end

    test "returns an error for non-2xx" do
      response_data = %{status: 401, body: %{"error" => "unauthorized"}}

      with_mock Req,
        request: fn _opts -> {:ok, struct(Req.Response, response_data)} end do
        expected = {:error, %{status_code: 401, body: %{"error" => "unauthorized"}}}
        assert expected == JsonRest.get_json(@url, [])
      end
    end

    test "returns an error tuple for transport errors" do
      with_mock Req,
        request: fn _opts -> {:error, %Req.TransportError{reason: :timeout}} end do
        assert {:error, %Req.TransportError{reason: :timeout}} == JsonRest.get_json(@url, [])
      end
    end
  end

  describe "post_json/3" do
    test "returns a response" do
      response_data = %{status: 200, body: %{"ok" => "yes"}}

      with_mock Req,
        request: fn _opts -> {:ok, struct(Req.Response, response_data)} end do
        expected = {:ok, %{status_code: 200, body: %{"ok" => "yes"}}}
        assert expected == JsonRest.post_json(@url, [], @body)
      end
    end

    test "returns an error for non-2xx" do
      response_data = %{status: 302, body: "Redirecting..."}

      with_mock Req,
        request: fn _opts -> {:ok, struct(Req.Response, response_data)} end do
        expected = {:error, %{status_code: 302, body: "Redirecting..."}}
        assert expected == JsonRest.post_json(@url, [], @body)
      end
    end

    test "returns an error tuple for transport errors" do
      with_mock Req,
        request: fn _opts -> {:error, %Req.TransportError{reason: :econnrefused}} end do
        assert {:error, %Req.TransportError{reason: :econnrefused}} ==
                 JsonRest.post_json(@url, [], @body)
      end
    end
  end
end
