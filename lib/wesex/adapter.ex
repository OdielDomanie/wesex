defmodule Wesex.Adapter do
  @type impl :: module()

  @type websocket :: term
  @type con :: term
  @type headers :: [{String.t(), String.t()}]
  @type reason :: any

  @type response ::
          {:status, reference(), non_neg_integer()}
          | {:headers, reference(), headers()}
          | {:data, reference(), body_chunk :: binary()}
          | {:done, reference()}
          | {:error, reference(), reason :: term()}

  @type frame() ::
          {:text, String.t()}
          | {:binary, binary()}
          | {:ping, binary()}
          | {:pong, binary()}
          | {:close, code :: non_neg_integer() | nil, reason :: binary() | nil}

  @type shorthand_frame() :: :ping | :pong | :close

  @callback encode(websocket(), shorthand_frame() | frame()) ::
              {:ok, websocket(), binary()} | {:error, websocket(), any()}

  @callback decode(websocket(), data :: binary()) ::
              {:ok, websocket(), [frame() | {:error, reason()}]} | {:error, websocket(), reason()}

  @callback stream_request_body(
              con,
              reference(),
              iodata()
            ) :: {:ok, con()} | {:error, con(), reason()}

  @callback stream(con(), msg :: term()) ::
              {:ok, con, [response()]}
              | {:error, Mint.HTTP.t(), reason, [response()]}
              | :unknown

  @callback open?(con(), :read | :write) :: boolean()

  @callback connect(:http | :https, String.t(), 0..65535, keyword()) ::
              {:ok, con()} | {:error, reason()}

  @callback close(con()) :: {:ok, con()}

  @doc """
  After upgrading, messages should arrive at inbox to be input into `c:stream/2`
  """
  @callback upgrade(
              scheme :: :ws | :wss,
              conn :: con(),
              path :: String.t(),
              headers :: headers(),
              opts :: keyword()
            ) :: {:ok, con(), reference()} | {:error, con(), reason()}

  @callback new(
              con,
              reference(),
              response_status :: non_neg_integer(),
              response_headers :: headers(),
              keyword()
            ) ::
              {:ok, con(), websocket()} | {:error, con(), reason()}
end
