defmodule Wesex.Websocket.Closed do
  @moduledoc false
  # The client is not connected.

  alias Wesex.Websocket.Opening
  alias __MODULE__, as: Closed

  @type t :: %__MODULE__{
          adapter: Wesex.Adapter.impl()
        }
  @enforce_keys [:adapter]
  defstruct [:adapter]

  @spec new :: t
  @spec new(Wesex.Adapter.impl()) :: t
  def new(adapter \\ Wesex.MintAdapter), do: %Closed{adapter: adapter}

  @doc """
  Start opening the connection.
  """
  @spec open(t, URI.t(), Mint.Types.headers(), timeout, keyword() | nil, keyword() | nil) ::
          {:ok, Opening.t()} | {:error, t, reason :: any}
  def open(
        %Closed{adapter: adapter},
        url,
        headers,
        timeout \\ Opening.default_timeout(),
        con_opts \\ [],
        ws_opts \\ []
      ) do
    true = url.scheme in ["http", "https"]
    scheme_atom = http_scheme(url.scheme)
    ws_scheme = http_to_ws_scheme(scheme_atom)
    path_str = %URI{url | host: nil, port: nil, scheme: nil} |> URI.to_string()

    with {:ok, con} <-
           adapter.connect(
             scheme_atom,
             url.host,
             url.port,
             con_opts || []
           ),
         {:ok, con, ref} <-
           adapter.upgrade(
             ws_scheme,
             con,
             path_str,
             headers,
             ws_opts || []
           ) do
      timer = Process.send_after(self(), {:open_timeout, ref}, timeout)
      {:ok, %Opening{con: con, ws_ref: ref, timer: timer, adapter: adapter}}
    else
      {:error, reason} ->
        {:error, new(), reason}

      {:error, con, reason} ->
        _ = adapter.close(con)
        {:error, new(), reason}
    end
  end

  defp http_scheme("http"), do: :http
  defp http_scheme("https"), do: :https
  defp http_to_ws_scheme(:http), do: :ws
  defp http_to_ws_scheme(:https), do: :wss
end
