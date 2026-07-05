defmodule AOS.HTTPClient do
  @behaviour AOS.HTTPClient.Behaviour
  @moduledoc """
  Thin HTTP adapter so runtime services do not depend on Req directly.
  Uses Req for modern HTTP capabilities compatible with hackney 4.0.
  """

  def get(url, headers \\ [], opts \\ []) do
    req_opts = Keyword.merge(opts, headers: headers)

    case Req.get(url, req_opts) do
      {:ok, %Req.Response{status: status, body: body}} ->
        {:ok, %{status: status, body: body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def post(url, body, headers \\ [], opts \\ []) do
    req_opts = Keyword.merge(opts, headers: headers, body: body)

    case Req.post(url, req_opts) do
      {:ok, %Req.Response{status: status, body: response_body}} ->
        {:ok, %{status: status, body: response_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
