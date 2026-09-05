defmodule AOS.HTTPClient do
  @behaviour AOS.HTTPClient.Behaviour
  @moduledoc """
  Thin HTTP adapter so runtime services do not depend on Req directly.
  Uses Req for modern HTTP capabilities compatible with hackney 4.0.
  """

  def get(url, headers \\ [], opts \\ []) do
    req_opts = Keyword.merge(opts, headers: headers)

    case Req.get(url, req_opts) do
      {:ok, %Req.Response{status: status, body: body, headers: response_headers}} ->
        {:ok, %{status: status, body: body, headers: response_headers}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def post(url, body, headers \\ [], opts \\ []) do
    req_opts = Keyword.merge(opts, headers: headers, body: body)

    case Req.post(url, req_opts) do
      {:ok, %Req.Response{status: status, body: response_body, headers: response_headers}} ->
        {:ok, %{status: status, body: response_body, headers: response_headers}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def post_stream(url, body, headers, reducer, initial, opts \\ []) do
    into = fn {:data, data}, {request, response} ->
      if response.status == 200 do
        state = Map.get(response.private, :stream_state, initial)
        {action, state} = reducer.(data, state)
        {action, {request, Req.Response.put_private(response, :stream_state, state)}}
      else
        {:cont, {request, %{response | body: response.body <> data}}}
      end
    end

    case Req.post(url, Keyword.merge(opts, headers: headers, body: body, into: into)) do
      {:ok, response} ->
        {:ok,
         %{
           status: response.status,
           headers: response.headers,
           body: response.body,
           stream_state: Map.get(response.private, :stream_state, initial)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
