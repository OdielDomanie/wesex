defmodule Wesex.Adapter do
  @moduledoc """
  The behaviour for the connection adapter for `Wesex.Connection`.
  """
  alias Wesex.Connection

  @type state :: any

  @callback connect(url :: URI.t(), headers :: [{String.t(), String.t()}], opts :: Keyword.t()) ::
              {:ok, state()} | {:error, reason :: any}
  @callback event(state, raw_event :: any) :: {state(), [Connection.adapter_event()]} | false
  @callback send_pong(state, binary()) :: {state(), [Connection.adapter_event()]}
  @callback send_ping(state) :: {state(), [Connection.adapter_event()]}
  @callback local_close(state, code_reason :: {1000..4999, nil | binary()}) ::
              {state(), [Connection.adapter_event()]}
  @callback abort(state) :: {state(), [Connection.adapter_event()]}
  @callback send(state, message :: {:text | :binary, binary()}) ::
              {:ok, state, [Connection.adapter_event()]}
              | {:error, state, [Connection.adapter_event()], reason :: any}
end
