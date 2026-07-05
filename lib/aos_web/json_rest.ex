defmodule AOSWeb.JsonRest do
  @moduledoc """
  The JsonRest module provides wrapper functions using Req for JSON HTTP requests.
  """

  def get_json(url, options) do
    request(:get, url, nil, options)
  end

  def post_json(url, options, body) do
    request(:post, url, body, options)
  end

  ### PRIVATE ###

  defp request(method, url, body, options) do
    headers = Keyword.get(options, :headers, [])

    req_opts =
      options
      |> Keyword.delete(:headers)
      |> Keyword.put(:method, method)
      |> Keyword.put(:url, url)
      |> Keyword.put(:headers, headers)

    req_opts = if body, do: Keyword.put(req_opts, :json, body), else: req_opts

    case Req.request(req_opts) do
      {:ok, response} ->
        if trunc(response.status / 100) == 2 do
          # Map Req.Response back to a structure expected by callers if necessary
          {:ok, %{status_code: response.status, body: response.body}}
        else
          {:error, %{status_code: response.status, body: response.body}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
